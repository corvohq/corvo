# Go ↔ Zig Parity Gaps

Tracking all remaining gaps between Go Corvo (`internal/`) and Zig Corvo (`src/`).
Enterprise features excluded (orgs, RBAC, webhooks admin, audit, SSO, billing).

## Critical — Clients Can't Function

- [x] **1. Fetch response missing fields** — FIXED. FetchedJob now includes attempt, max_retries, lease_duration_ms (set in handler). Server loads payload from KV (jp|), loads job header for checkpoint/tags/agent. Matches Go FetchResult.

- [x] **2. FindDueCrons missing** — FIXED. Added `DueCronRow` type and `findDueCrons(before, results)` method to `sqlite_read.zig`.

## High — Dashboard/Mirror Incomplete

- [x] **3. Mirror bulk_action uses direct SQL** — FIXED. Store uses `enqueueBulkActionJob()` ring-buffer wrapper. `applyOp` handles `.bulk_action_job` variant with delete/update_state actions.

- [x] **4. Mirror cron ops use direct SQL** — FIXED. Store/server use `enqueueCronUpsert()`, `enqueueCronDelete()`, `enqueueCronToggle()` ring-buffer wrappers. `applyOp` handles `.cron` variant with create/update/delete/toggle_enabled actions.

- [x] **5. Mirror budget ops use direct SQL** — FIXED. Store uses `enqueueBudgetUpsert()` and `enqueueBudgetDelete()` ring-buffer wrappers. `applyOp` handles `.budget_op` variant.

- [x] **6. Mirror batch ops use direct SQL** — FIXED. Store uses `enqueueBatchCreate()` and `enqueueBatchSeal()` ring-buffer wrappers. `applyOp` handles `.batch_op` variant.

- [x] **7. Mirror enqueue payload missing fields** — FIXED. EnqueuePayload now includes batch_id, unique_key, unique_period_s, retry config (backoff, base_delay_ms, max_delay_ms), parent_id, chain_id, chain_step, group_key, expire_at_ns. insert_job SQL expanded to 19 columns.

- [x] **8. Mirror ack payload missing fields** — FIXED. AckPayload now includes result, hold_reason, agent_iteration, agent_total_cost_usd. ack_job SQL sets all fields. Agent fields populated from KV readback.

- [x] **9. Mirror fail payload missing backtrace** — FIXED. FailPayload now includes backtrace field. insert_error SQL includes backtrace column.

- [x] **10. Mirror maintenance per-job updates missing** — FIXED. Store uses `enqueueMaintenance()` ring-buffer wrapper. `applyOp` handles `.maintenance` variant dispatching to promote/reclaim/expire/purge.

- [x] **11. SQLite getJob returns stripped fields** — FIXED. All job queries now SELECT 29 columns: tags, checkpoint, result, hold_reason, error_msg, batch_id, unique_key, parent_id, chain_id, chain_step, group_key, agent fields, all timestamps. readJobRow uses comptime inline loops.

- [x] **12. SQLite listQueues missing job counts** — NOT A GAP. The API handler (`handleListQueues`) already uses `getQueueStats()` which includes per-state counts. `listQueues()` exists for internal use without counts.

- [x] **13. SQLite getCron/listCrons missing fields** — FIXED. CronRow expanded with timezone, payload, unique_key, max_retries, next_run_at, last_run_at, created_at. Queries select all 12 columns. upsertCron expanded. findDueCrons column names fixed (cron→schedule, next_run→next_run_at).

- [x] **14. SQLite getWorkers missing fields** — FIXED. WorkerRow expanded with queues, last_heartbeat, started_at. Query selects all 5 columns.

- [x] **15. SQLite getJobIterations missing fields** — FIXED. IterationRow expanded with checkpoint, result. Query selects all 7 columns.

- [x] **16. GET /api/v1/batch/{id} route missing** — NOT A GAP. Go doesn't have this route either.

## Medium — Feature Gaps

- [x] **17. Enqueue unique conflict missing existing job ID** — FIXED. OpResult has unique_job_id_buf/len. handler_enqueue decodes unique lock value for existing job ID. Server returns `{"unique_existing":true,"unique_job_id":"..."}` with 409 status.

- [x] **18. Heartbeat response missing per-job status** — NOT A GAP. Zig already returns per-job `{"status":"ok"|"cancel"}`.

- [x] **19. Budget query methods missing (6)** — FIXED. Added `getBudget`, `fetchQueueBudgets`, `queueDailySpent`, `queueAvgJobCost`, `findPendingJobInQueue`, `jobTotalCost` to sqlite_read.zig.

- [x] **20. UsageGrouped missing** — FIXED. Added `usageGrouped(from, to, col, results)` with column validation (queue/model/provider only). Added `UsageSummaryGroup` result type and `prepareDynamic` to sqlite.zig.

- [x] **21. QueryJobSummaries missing** — FIXED. Added `queryJobsByQueueState(queue, state, limit, offset, results)` with optional queue/state filters and pagination. Uses full job_cols.

- [x] **22. QueryJobIDs missing** — Covered by `queryJobsByQueueState` returning full JobRow (ID accessible via `idSlice()`). Go's `QueryJobIDs` is a generic raw-SQL executor; Zig uses typed methods instead.

- [x] **23. GET /metrics (Prometheus) missing** — NOT A GAP. Already implemented via `handleMetrics()`.

## Low

- [x] **24. CountActiveWorkers missing** — FIXED. Added `countActiveWorkers(cutoff)` to sqlite_read.zig. Filters workers by last_heartbeat >= cutoff.

- [x] **25. GetJobCheckpointAtIteration missing** — FIXED. Added `getJobCheckpointAtIteration(job_id, iteration)` to sqlite_read.zig. Returns full IterationRow with checkpoint/result.

## Round 2 — Second Audit

- [x] **26. FlushMirror before reads** — FIXED. Added `flushAll()` to Mirror (loops flush until ring buffer empty), `flushMirror()` to Store. Server calls before GetJob, Search, BulkGetJobs, JobIterations, ListBudgets, ListApiKeys.

- [x] **27. `HasBudgets()` missing** — FIXED. Added `hasBudgets()` to sqlite_read.zig. `SELECT 1 FROM budgets LIMIT 1`.

- [x] **28. `GetJobQueueAndTags(jobID)` missing** — FIXED. Added `getJobQueueAndTags(job_id)` returning `JobQueueAndTags` struct with queue/tags + slice accessors.

- [x] **29. `ListPerJobBudgets()` missing** — FIXED. Added `listPerJobBudgets(results)` to sqlite_read.zig. Filters budgets WHERE per_job_usd IS NOT NULL.

- [x] **30. OpenAPI spec + Scalar docs UI** — FIXED (see #36). Hand-written `openapi.json` embedded at compile time. `GET /openapi.json` + `GET /docs` (Scalar UI).

- [x] **31. Async bulk operations** — UI doesn't use async bulk progress (synchronous POST + wait). Zig handles large bulks synchronously. NOT A GAP.

## Round 3 — Third Audit

- [x] **32. Approval policies** — FIXED. CRUD endpoints (`POST/GET/DELETE /api/v1/approval-policies`). SQLite table `approval_policies` with schema. Mirror ring-buffer ops `enqueueApprovalPolicyUpsert/Delete`. KV storage via `ModifyEntSetting`. `ApprovalPolicyRow` in sqlite_read with `matches()` method for queue/tag evaluation with any/all mode logic.

- [x] **33. Rate limiting** — FIXED. Token bucket per client in `rate_limiter.zig`. Separate read/write limits. Returns 429 with Retry-After header. Client identified by API key hash or "anon". Configurable via `ServerConfig.rate_limit`. Wired into `handleConnection` before routing.

- [x] **34. Request metrics** — FIXED. `request_metrics.zig` with per-route latency histograms (12 buckets), error counts, in-flight gauge, throttled counter. Fixed-capacity slot array (128 routes), lock-free fast path. Appended to `/metrics` Prometheus output.

- [x] **35. Prometheus metrics format** — FIXED. `/metrics` now outputs full Prometheus exposition format: `corvo_http_requests_total`, `corvo_http_request_errors_total`, `corvo_http_request_duration_seconds` histogram with cumulative buckets + sum + count, `corvo_http_requests_in_flight` gauge, `corvo_rate_limit_throttled_total`.

- [x] **36. OpenAPI spec + docs** — FIXED. Hand-written `openapi.json` embedded at compile time. `GET /openapi.json` returns spec. `GET /docs` serves Scalar API reference UI (CDN-loaded JS). Covers all routes: jobs, queues, crons, batches, budgets, approval policies, auth, webhooks, search, metrics, admin.

---

## Verification Status

Each item above needs: (a) verify the gap is real, (b) implement fix, (c) add test, (d) check box.

Round 1: all 25 gaps resolved (19 fixed, 6 not real gaps)
Round 2: 26-29 fixed, 30-31 tracked
Round 3: 32-36 all fixed
