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

export class JobbieClient {
  readonly baseURL: string;
  readonly fetchImpl: typeof fetch;

  constructor(baseURL: string, fetchImpl: typeof fetch = fetch) {
    this.baseURL = baseURL.replace(/\/$/, "");
    this.fetchImpl = fetchImpl;
  }

  async enqueue(queue: string, payload: unknown, extra: Record<string, unknown> = {}): Promise<EnqueueResult> {
    return this.request("/api/v1/enqueue", {
      method: "POST",
      body: JSON.stringify({ queue, payload, ...extra }),
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

  async ack(jobID: string, body: Record<string, unknown> = {}): Promise<{ status: string }> {
    return this.request(`/api/v1/ack/${encodeURIComponent(jobID)}`, {
      method: "POST",
      body: JSON.stringify(body),
    });
  }

  private async request<T>(path: string, init: RequestInit): Promise<T> {
    const res = await this.fetchImpl(this.baseURL + path, {
      ...init,
      headers: {
        "content-type": "application/json",
        ...(init.headers || {}),
      },
    });

    if (!res.ok) {
      let details = `HTTP ${res.status}`;
      try {
        const body = (await res.json()) as { error?: string };
        if (body.error) details = body.error;
      } catch {
        // ignore decode errors for non-JSON responses
      }
      throw new Error(details);
    }

    if (res.status === 204) {
      return {} as T;
    }
    return (await res.json()) as T;
  }
}
