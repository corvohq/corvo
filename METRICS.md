# Corvo Prometheus Metrics

All metrics are available at `GET /api/v1/metrics` in Prometheus text exposition format.

## Throughput

| Metric | Type | Description |
|--------|------|-------------|
| `corvo_throughput_enqueued_total` | counter | Jobs enqueued (in-memory throughput window) |
| `corvo_throughput_completed_total` | counter | Jobs completed (in-memory throughput window) |
| `corvo_throughput_failed_total` | counter | Jobs failed (in-memory throughput window) |

## Queue Jobs

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `corvo_queues_total` | gauge | | Number of known queues |
| `corvo_queue_jobs` | gauge | `queue`, `state` | Jobs per queue and state |
| `corvo_jobs` | gauge | `state` | Jobs aggregated across all queues by state |

States: `pending`, `active`, `held`, `completed`, `dead`, `scheduled`, `retrying`.

## Lifecycle Stream

Sourced from the ConnectRPC lifecycle stream server.

| Metric | Type | Description |
|--------|------|-------------|
| `corvo_lifecycle_streams_open` | gauge | Currently open lifecycle streams |
| `corvo_lifecycle_streams_max` | gauge | Configured max open streams (`--stream-max-open`) |
| `corvo_lifecycle_frames_inflight` | gauge | Currently processing frames |
| `corvo_lifecycle_frames_max_inflight` | gauge | Configured max in-flight frames (`--stream-max-inflight`) |
| `corvo_lifecycle_frames_total` | counter | Total frames processed (lifetime) |
| `corvo_lifecycle_streams_total` | counter | Total streams opened (lifetime) |
| `corvo_lifecycle_overload_total` | counter | Frames rejected due to stream saturation |

**Usage:** Alert when `corvo_lifecycle_frames_inflight / corvo_lifecycle_frames_max_inflight > 0.8` to detect in-flight pressure. If `corvo_lifecycle_overload_total` is increasing, raise `--stream-max-inflight` or add nodes.

## Raft Apply Pipeline

| Metric | Type | Description |
|--------|------|-------------|
| `corvo_raft_apply_pending` | gauge | Current apply queue depth |
| `corvo_raft_apply_max_pending` | gauge | Configured max pending (`--raft-max-pending`) |
| `corvo_raft_apply_overload_total` | counter | Rejected: apply queue full |
| `corvo_raft_fetch_overload_total` | counter | Rejected: per-queue fetch sem full |
| `corvo_raft_applied_total` | counter | Total ops applied through Raft |
| `corvo_raft_queue_time_seconds` | histogram | Wait time in apply queue (14 buckets: 50us..1s) |
| `corvo_raft_apply_time_seconds` | histogram | FSM apply execution time (14 buckets: 50us..1s) |

**Usage:** If `corvo_raft_apply_pending / corvo_raft_apply_max_pending > 0.7`, the apply pipeline is under pressure. Rising `corvo_raft_apply_overload_total` means requests are being rejected — increase `--raft-max-pending` or check disk I/O. Use the histogram p99 to understand tail latency.

## Raft Health

| Metric | Type | Description |
|--------|------|-------------|
| `corvo_cluster_is_leader` | gauge | 1 when this node is leader, else 0 |
| `corvo_raft_state` | gauge | 0=follower, 1=candidate, 2=leader, 3=shutdown |
| `corvo_raft_applied_index` | gauge | Last applied log index |
| `corvo_raft_commit_index` | gauge | Last committed log index |
| `corvo_raft_snapshot_latest_index` | gauge | Latest snapshot index |

**Usage:** Alert when `corvo_raft_commit_index - corvo_raft_applied_index > 1000` to detect apply lag. Monitor `corvo_raft_state` for unexpected leadership changes.

## SQLite Mirror

| Metric | Type | Description |
|--------|------|-------------|
| `corvo_sqlite_mirror_lag_updates` | gauge | Pending SQLite mirror updates |
| `corvo_sqlite_mirror_dropped_total` | counter | Dropped mirror updates due to backpressure |

## Workers

| Metric | Type | Description |
|--------|------|-------------|
| `corvo_workers_registered` | gauge | Total registered workers |
| `corvo_workers_active` | gauge | Workers with heartbeat within last 5 minutes |

## Process Resources

| Metric | Type | Description |
|--------|------|-------------|
| `corvo_process_goroutines` | gauge | Number of goroutines |
| `corvo_process_heap_inuse_bytes` | gauge | Heap memory in use |
| `corvo_process_stack_inuse_bytes` | gauge | Stack memory in use |
| `corvo_process_gc_pause_ns` | gauge | Last GC pause duration (ns) |

## Scheduler

| Metric | Type | Description |
|--------|------|-------------|
| `corvo_scheduler_promote_total` | counter | Promote ops executed |
| `corvo_scheduler_promote_errors_total` | counter | Promote errors |
| `corvo_scheduler_reclaim_total` | counter | Reclaim ops executed |
| `corvo_scheduler_reclaim_errors_total` | counter | Reclaim errors |
| `corvo_scheduler_expire_total` | counter | Expire ops executed |
| `corvo_scheduler_expire_errors_total` | counter | Expire errors |
| `corvo_scheduler_purge_total` | counter | Purge ops executed |
| `corvo_scheduler_purge_errors_total` | counter | Purge errors |
| `corvo_scheduler_last_promote_seconds` | gauge | Unix timestamp of last promote |
| `corvo_scheduler_last_reclaim_seconds` | gauge | Unix timestamp of last reclaim |
| `corvo_scheduler_last_expire_seconds` | gauge | Unix timestamp of last expire |
| `corvo_scheduler_last_purge_seconds` | gauge | Unix timestamp of last purge |

**Usage:** If `corvo_scheduler_promote_errors_total` or `corvo_scheduler_reclaim_errors_total` are increasing, the scheduler is failing operations — check logs for details. Use `time() - corvo_scheduler_last_promote_seconds > 10` to detect a stalled scheduler.

## HTTP Request Metrics

Request metrics are emitted by the `requestMetrics` middleware (see output of `/api/v1/metrics` for `corvo_http_*` lines with `method`, `route`, and `status` labels).
