export interface Job {
  id: string;
  queue: string;
  state: string;
  payload: unknown;
  priority: number;
  attempt: number;
  max_retries: number;
  retry_backoff: string;
  retry_base_delay_ms: number;
  retry_max_delay_ms: number;
  unique_key?: string;
  batch_id?: string;
  worker_id?: string;
  hostname?: string;
  tags?: Record<string, string>;
  progress?: { current?: number; total?: number; message?: string };
  checkpoint?: unknown;
  result?: unknown;
  lease_expires_at?: string;
  scheduled_at?: string;
  expire_at?: string;
  created_at: string;
  started_at?: string;
  completed_at?: string;
  failed_at?: string;
  errors?: JobError[];
}

export interface JobError {
  id: number;
  job_id: string;
  attempt: number;
  error: string;
  backtrace?: string;
  created_at: string;
}

export interface Queue {
  name: string;
  paused: boolean;
  max_concurrency?: number;
  rate_limit?: number;
  rate_window_ms?: number;
  created_at: string;
}

export interface QueueInfo extends Queue {
  pending: number;
  active: number;
  completed: number;
  dead: number;
  scheduled: number;
  retrying: number;
  enqueued: number;
  failed: number;
}

export interface Worker {
  id: string;
  hostname?: string;
  queues?: string;
  last_heartbeat: string;
  started_at: string;
}

export interface Event {
  id: number;
  type: string;
  job_id?: string;
  queue?: string;
  data?: unknown;
  created_at: string;
}

export interface SearchFilter {
  queue?: string;
  state?: string[];
  priority?: string;
  tags?: Record<string, string>;
  payload_contains?: string;
  created_after?: string;
  created_before?: string;
  error_contains?: string;
  job_id_prefix?: string;
  batch_id?: string;
  worker_id?: string;
  unique_key?: string;
  has_errors?: boolean;
  attempt_min?: number;
  attempt_max?: number;
  sort?: string;
  order?: string;
  cursor?: string;
  limit?: number;
}

export interface SearchResult {
  jobs: Job[];
  total: number;
  cursor?: string;
  has_more: boolean;
}

export interface BulkRequest {
  job_ids?: string[];
  filter?: SearchFilter;
  action: string;
  move_to_queue?: string;
  priority?: string;
}

export interface BulkResult {
  affected: number;
  errors: number;
  duration_ms: number;
}

export interface ClusterStatus {
  mode: string;
  status: string;
  state?: string;
  leader?: string;
  nodes?: ClusterNode[];
  pipeline_stats?: Record<string, unknown>;
  admission_stats?: Record<string, unknown>;
}

export interface ClusterNode {
  id?: string;
  address?: string;
  role: string;
  status: string;
}
