import { JobbieClient } from "@jobbie/client";

declare const process:
  | {
      on: (event: string, handler: () => void) => void;
      off: (event: string, handler: () => void) => void;
    }
  | undefined;

export type FetchedJob = {
  job_id: string;
  queue: string;
  payload: Record<string, unknown>;
  attempt: number;
  max_retries: number;
  lease_duration: number;
  checkpoint?: Record<string, unknown>;
  tags?: Record<string, string>;
  agent?: Record<string, unknown>;
};

export type WorkerHandler = (job: FetchedJob, ctx: WorkerJobContext) => Promise<void> | void;

export type WorkerConfig = {
  queues: string[];
  workerID: string;
  hostname?: string;
  concurrency?: number;
  shutdownTimeoutMs?: number;
};

export type WorkerJobContext = {
  isCancelled: () => boolean;
  checkpoint: (checkpoint: Record<string, unknown>) => Promise<void>;
  progress: (current: number, total: number, message: string) => Promise<void>;
};

export class JobbieWorker {
  private readonly client: JobbieClient;
  private readonly cfg: Required<WorkerConfig>;
  private readonly handlers: Map<string, WorkerHandler> = new Map();
  private readonly active: Map<string, { cancelled: boolean }> = new Map();
  private stopping = false;

  constructor(client: JobbieClient, cfg: WorkerConfig) {
    this.client = client;
    this.cfg = {
      ...cfg,
      hostname: cfg.hostname ?? "jobbie-worker",
      concurrency: cfg.concurrency ?? 10,
      shutdownTimeoutMs: cfg.shutdownTimeoutMs ?? 30000,
    };
  }

  register(queue: string, handler: WorkerHandler): void {
    this.handlers.set(queue, handler);
  }

  async start(): Promise<void> {
    const loops = Array.from({ length: this.cfg.concurrency }, () => this.fetchLoop());
    const heartbeat = this.heartbeatLoop();

    const onSignal = () => {
      this.stop().catch(() => {});
    };
    if (typeof process !== "undefined") {
      process.on("SIGINT", onSignal);
      process.on("SIGTERM", onSignal);
    }

    await Promise.race([Promise.all(loops), heartbeat]);

    if (typeof process !== "undefined") {
      process.off("SIGINT", onSignal);
      process.off("SIGTERM", onSignal);
    }
  }

  async stop(): Promise<void> {
    if (this.stopping) return;
    this.stopping = true;

    const deadline = Date.now() + this.cfg.shutdownTimeoutMs;
    while (this.active.size > 0 && Date.now() < deadline) {
      await sleep(100);
    }
    for (const [jobID] of this.active) {
      await this.fail(jobID, "worker_shutdown");
    }
  }

  private async fetchLoop(): Promise<void> {
    while (!this.stopping) {
      try {
        const job = await this.fetch();
        if (!job) continue;

        const handler = this.handlers.get(job.queue);
        if (!handler) {
          await this.client.ack(job.job_id, {});
          continue;
        }

        this.active.set(job.job_id, { cancelled: false });
        const ctx: WorkerJobContext = {
          isCancelled: () => this.active.get(job.job_id)?.cancelled === true,
          checkpoint: async (checkpoint) => {
            await this.heartbeat({ [job.job_id]: { checkpoint } });
          },
          progress: async (current, total, message) => {
            await this.heartbeat({
              [job.job_id]: { progress: { current, total, message } },
            });
          },
        };

        try {
          await handler(job, ctx);
          await this.client.ack(job.job_id, {});
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          await this.fail(job.job_id, message);
        } finally {
          this.active.delete(job.job_id);
        }
      } catch {
        await sleep(1000);
      }
    }
  }

  private async heartbeatLoop(): Promise<void> {
    while (!this.stopping) {
      await sleep(15000);
      if (this.stopping || this.active.size === 0) continue;

      const jobs: Record<string, { progress?: Record<string, unknown>; checkpoint?: Record<string, unknown> }> = {};
      for (const [jobID] of this.active) jobs[jobID] = {};

      try {
        const result = await this.heartbeat(jobs);
        for (const [jobID, info] of Object.entries(result.jobs || {})) {
          if (info.status === "cancel") {
            const state = this.active.get(jobID);
            if (state) state.cancelled = true;
          }
        }
      } catch {
        // Best-effort heartbeat.
      }
    }
  }

  private async fetch(): Promise<FetchedJob | null> {
    const job = await this.request<FetchedJob | Record<string, never>>("/api/v1/fetch", {
      method: "POST",
      body: JSON.stringify({
        queues: this.cfg.queues,
        worker_id: this.cfg.workerID,
        hostname: this.cfg.hostname,
        timeout: 30,
      }),
    });
    const j = job as Partial<FetchedJob>;
    if (!j.job_id) return null;
    return j as FetchedJob;
  }

  private async fail(jobID: string, error: string, backtrace = ""): Promise<void> {
    await this.request(`/api/v1/fail/${encodeURIComponent(jobID)}`, {
      method: "POST",
      body: JSON.stringify({ error, backtrace }),
    });
  }

  private async heartbeat(
    jobs: Record<string, { progress?: Record<string, unknown>; checkpoint?: Record<string, unknown>; usage?: Record<string, unknown> }>
  ): Promise<{ jobs: Record<string, { status: string }> }> {
    return this.request("/api/v1/heartbeat", {
      method: "POST",
      body: JSON.stringify({ jobs }),
    });
  }

  private async request<T>(path: string, init: RequestInit): Promise<T> {
    const authHeaders = await this.client.authHeaders();
    const res = await this.client.fetchImpl(this.client.baseURL + path, {
      ...init,
      headers: {
        "content-type": "application/json",
        ...authHeaders,
        ...(init.headers || {}),
      },
    });
    if (!res.ok) {
      let details = `HTTP ${res.status}`;
      try {
        const body = (await res.json()) as { error?: string };
        if (body.error) details = body.error;
      } catch {
        // ignore
      }
      throw new Error(details);
    }
    if (res.status === 204) return {} as T;
    return (await res.json()) as T;
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
