export type EnqueueResult = {
  job_id: string;
  status: string;
  unique_existing?: boolean;
};

export type SearchFilter = {
  queue?: string;
  state?: string[];
  priority?: string;
  tags?: Record<string, string>;
  payload_contains?: string;
  payload_jq?: string;
  sort?: string;
  order?: "asc" | "desc";
  limit?: number;
  cursor?: string;
};

export type SearchResult<T = Record<string, unknown>> = {
  jobs: T[];
  total: number;
  cursor?: string;
  has_more: boolean;
};

export type BulkRequest = {
  job_ids?: string[];
  filter?: SearchFilter;
  action: "retry" | "delete" | "cancel" | "move" | "requeue" | "change_priority" | "hold" | "approve" | "reject";
  move_to_queue?: string;
  priority?: string;
  async?: boolean;
};

export type BulkResult = {
  affected: number;
  errors: number;
  duration_ms: number;
};

export type BulkAsyncStart = {
  bulk_operation_id: string;
  status: string;
  estimated_total: number;
  progress_url: string;
};

export type BulkTask = {
  id: string;
  status: "queued" | "running" | "completed" | "failed";
  action: string;
  total: number;
  processed: number;
  affected: number;
  errors: number;
  error?: string;
  created_at: string;
  updated_at: string;
  finished_at?: string;
};

export type BatchJob = {
  queue: string;
  payload: unknown;
  [key: string]: unknown;
};

export type BatchConfig = {
  callback_queue: string;
  callback_payload?: unknown;
};

export type BatchResult = {
  job_ids: string[];
  batch_id: string;
};

export type FetchedJob = {
  job_id: string;
  queue: string;
  payload: unknown;
  attempt: number;
};

export type HeartbeatResult = {
  acked: string[];
  unknown: string[];
  canceled: string[];
};

export type ChainStep = {
  queue: string;
  payload: unknown;
};

export type ChainConfig = {
  steps: ChainStep[];
  on_failure?: "stop" | "continue";
  on_exit?: ChainStep;
};

export type EnqueueOptions = {
  queue: string;
  payload: unknown;
  priority?: string;
  unique_key?: string;
  unique_period?: number;
  max_retries?: number;
  scheduled_at?: string;
  tags?: Record<string, string>;
  expire_after?: string;
  retry_backoff?: string;
  retry_base_delay?: string;
  retry_max_delay?: string;
  chain?: ChainConfig;
};

export type AuthOptions = {
  headers?: Record<string, string>;
  bearerToken?: string;
  apiKey?: string;
  apiKeyHeader?: string;
  tokenProvider?: () => Promise<string> | string;
};

export class PayloadTooLargeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PayloadTooLargeError";
  }
}

export function isPayloadTooLargeError(err: unknown): err is PayloadTooLargeError {
  return err instanceof PayloadTooLargeError;
}

export class CorvoClient {
  readonly baseURL: string;
  readonly fetchImpl: typeof fetch;
  readonly auth: AuthOptions;

  constructor(baseURL: string, fetchImpl: typeof fetch = fetch, auth: AuthOptions = {}) {
    this.baseURL = baseURL.replace(/\/$/, "");
    this.fetchImpl = fetchImpl;
    this.auth = auth;
  }

  async enqueue(queue: string, payload: unknown, extra: Record<string, unknown> = {}): Promise<EnqueueResult> {
    return this.request("/api/v1/enqueue", {
      method: "POST",
      body: JSON.stringify({ queue, payload, ...extra }),
    });
  }

  async enqueueWith(opts: EnqueueOptions): Promise<EnqueueResult> {
    return this.request("/api/v1/enqueue", {
      method: "POST",
      body: JSON.stringify(opts),
    });
  }

  async getJob<T = Record<string, unknown>>(id: string): Promise<T> {
    return this.request(`/api/v1/jobs/${encodeURIComponent(id)}`, { method: "GET" });
  }

  async search<T = Record<string, unknown>>(filter: SearchFilter): Promise<SearchResult<T>> {
    return this.request("/api/v1/jobs/search", {
      method: "POST",
      body: JSON.stringify(filter),
    });
  }

  async bulk(req: BulkRequest): Promise<BulkResult | BulkAsyncStart> {
    return this.request("/api/v1/jobs/bulk", {
      method: "POST",
      body: JSON.stringify(req),
    });
  }

  async bulkStatus(id: string): Promise<BulkTask> {
    return this.request(`/api/v1/bulk/${encodeURIComponent(id)}`, { method: "GET" });
  }

  async fetchBatch(
    queues: string[],
    workerID: string,
    hostname = "corvo-worker",
    timeout = 30,
    count = 10,
  ): Promise<{ jobs: FetchedJob[] }> {
    return this.request("/api/v1/fetch/batch", {
      method: "POST",
      body: JSON.stringify({ queues, worker_id: workerID, hostname, timeout, count }),
    });
  }

  async ackBatch(acks: { job_id: string; result?: Record<string, unknown> }[]): Promise<{ acked: number }> {
    return this.request("/api/v1/ack/batch", {
      method: "POST",
      body: JSON.stringify({ acks }),
    });
  }

  async enqueueBatch(jobs: BatchJob[], batch?: BatchConfig): Promise<BatchResult> {
    return this.request("/api/v1/enqueue/batch", {
      method: "POST",
      body: JSON.stringify({ jobs, batch }),
    });
  }

  async fetch(queues: string[], workerID: string, hostname = "corvo-worker", timeout = 30): Promise<FetchedJob | null> {
    const result = await this.request<FetchedJob>("/api/v1/fetch", {
      method: "POST",
      body: JSON.stringify({ queues, worker_id: workerID, hostname, timeout }),
    });
    if (!result || !(result as FetchedJob).job_id) return null;
    return result;
  }

  async ack(jobID: string, body: Record<string, unknown> = {}): Promise<{ status: string }> {
    return this.request(`/api/v1/ack/${encodeURIComponent(jobID)}`, {
      method: "POST",
      body: JSON.stringify(body),
    });
  }

  async fail(jobID: string, error: string, backtrace?: string): Promise<{ status: string }> {
    return this.request(`/api/v1/fail/${encodeURIComponent(jobID)}`, {
      method: "POST",
      body: JSON.stringify({ error, backtrace }),
    });
  }

  async heartbeat(jobs: Record<string, Record<string, unknown>>): Promise<HeartbeatResult> {
    return this.request("/api/v1/heartbeat", {
      method: "POST",
      body: JSON.stringify({ jobs }),
    });
  }

  async retryJob(id: string): Promise<void> {
    await this.request(`/api/v1/jobs/${encodeURIComponent(id)}/retry`, { method: "POST" });
  }

  async cancelJob(id: string): Promise<void> {
    await this.request(`/api/v1/jobs/${encodeURIComponent(id)}/cancel`, { method: "POST" });
  }

  async moveJob(id: string, targetQueue: string): Promise<void> {
    await this.request(`/api/v1/jobs/${encodeURIComponent(id)}/move`, {
      method: "POST",
      body: JSON.stringify({ queue: targetQueue }),
    });
  }

  async deleteJob(id: string): Promise<void> {
    await this.request(`/api/v1/jobs/${encodeURIComponent(id)}`, { method: "DELETE" });
  }

  private async request<T>(path: string, init: RequestInit): Promise<T> {
    const authHeaders = await this.authHeaders();
    const res = await this.fetchImpl(this.baseURL + path, {
      ...init,
      headers: {
        "content-type": "application/json",
        ...authHeaders,
        ...(init.headers || {}),
      },
    });

    if (!res.ok) {
      let details = `HTTP ${res.status}`;
      let code = "";
      try {
        const body = (await res.json()) as { error?: string; code?: string };
        if (body.error) details = body.error;
        if (body.code) code = body.code;
      } catch {
        // ignore decode errors for non-JSON responses
      }
      if (code === "PAYLOAD_TOO_LARGE") throw new PayloadTooLargeError(details);
      throw new Error(details);
    }

    if (res.status === 204) {
      return {} as T;
    }
    return (await res.json()) as T;
  }

  async authHeaders(): Promise<Record<string, string>> {
    const out: Record<string, string> = {};
    if (this.auth.headers) {
      Object.assign(out, this.auth.headers);
    }
    if (this.auth.apiKey) {
      out[this.auth.apiKeyHeader || "X-API-Key"] = this.auth.apiKey;
    }
    let token = this.auth.bearerToken || "";
    if (this.auth.tokenProvider) {
      token = await this.auth.tokenProvider();
    }
    if (token) {
      out.Authorization = `Bearer ${token}`;
    }
    return out;
  }
}
