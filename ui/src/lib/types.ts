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
  parent_id?: string;
  chain_id?: string;
  chain_step?: number;
  lease_expires_at?: string;
  scheduled_at?: string;
  expire_at?: string;
  created_at: string;
  started_at?: string;
  completed_at?: string;
  failed_at?: string;
  hold_reason?: string;
  agent?: AgentState;
  errors?: JobError[];
}

export interface AgentState {
  max_iterations?: number;
  max_cost_usd?: number;
  iteration_timeout?: string;
  iteration?: number;
  total_cost_usd?: number;
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
  held: number;
  completed: number;
  dead: number;
  scheduled: number;
  retrying: number;
  enqueued: number;
  failed: number;
  oldest_pending_at?: string;
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
  payload_jq?: string;
  created_after?: string;
  created_before?: string;
  error_contains?: string;
  job_id_prefix?: string;
  batch_id?: string;
  worker_id?: string;
  parent_id?: string;
  chain_id?: string;
  chain_step?: number;
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

export interface UsageSummaryTotals {
  input_tokens: number;
  output_tokens: number;
  cache_creation_tokens: number;
  cache_read_tokens: number;
  cost_usd: number;
  count: number;
}

export interface UsageSummaryGroup extends UsageSummaryTotals {
  key: string;
}

export interface UsageSummaryResponse {
  period: string;
  from: string;
  to: string;
  totals: UsageSummaryTotals;
  groups?: UsageSummaryGroup[];
}

export interface Budget {
  id: string;
  scope: "queue" | "tag" | "global";
  target: string;
  daily_usd?: number;
  per_job_usd?: number;
  on_exceed: "hold" | "reject" | "alert_only";
  created_at: string;
}

export interface JobIteration {
  id: number;
  job_id: string;
  iteration: number;
  status: "continue" | "done" | "hold" | string;
  checkpoint?: unknown;
  trace?: unknown;
  hold_reason?: string;
  result?: unknown;
  input_tokens?: number;
  output_tokens?: number;
  cache_creation_tokens?: number;
  cache_read_tokens?: number;
  model?: string;
  provider?: string;
  cost_usd?: number;
  created_at: string;
}
