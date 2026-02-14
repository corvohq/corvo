# Phase 1 — MVP Implementation Plan

## Overview

Single-node Corvo server: Go binary with embedded SQLite, HTTP/JSON API, CLI, and Go client library. No Raft/clustering yet — the store layer uses a `Writer` interface so Raft can be inserted later without changing callers.

**Go dependencies:**
- `github.com/mattn/go-sqlite3` — SQLite via CGo
- `github.com/go-chi/chi/v5` — HTTP router
- `github.com/spf13/cobra` — CLI framework
- `github.com/oklog/ulid/v2` — sortable job IDs
- `log/slog` — structured logging (stdlib)

## Task Groups

### 1. Project Scaffold

Files: `go.mod`, `cmd/corvo/main.go`, `Makefile`, directory structure

- [x] `go mod init github.com/user/corvo`
- [x] Create directory structure (`cmd/corvo/`, `internal/server/`, `internal/store/`, `internal/scheduler/`, `internal/search/`, `pkg/client/`, `migrations/`, `tests/integration/`)
- [x] `cmd/corvo/main.go` — cobra root command + `server` subcommand
- [x] `Makefile` — `build`, `run`, `test`, `lint` targets
- [x] Add Go dependencies (`go get`)

### 2. SQLite Database Layer

Files: `internal/store/db.go`, `migrations/001_initial.sql`

- [x] `migrations/001_initial.sql` — full schema from DESIGN.md (jobs, job_errors, unique_locks, batches, queues, rate_limit_window, schedules, workers, events, queue_stats tables + all indexes)
- [x] `internal/store/db.go` — open SQLite, configure WAL mode + `synchronous=FULL` + `foreign_keys=ON`, run migrations
- [x] Single write connection (`MaxOpenConns=1`), separate read connection pool

### 3. Domain Models and ID Generation

Files: `internal/store/models.go`, `internal/store/ids.go`

- [x] Job struct (all fields from DESIGN.md data model)
- [x] Queue, JobError, Batch, Schedule, Worker, Event structs
- [x] Job state enum (pending, active, completed, retrying, dead, cancelled, scheduled)
- [x] Priority enum (0=critical, 1=high, 2=normal)
- [x] Backoff strategy enum (none, fixed, linear, exponential)
- [x] ULID-based ID generation (`job_`, `batch_`, `sched_` prefixes)

### 4. Store Layer — Core Job Operations

Files: `internal/store/store.go`, `internal/store/enqueue.go`, `internal/store/fetch.go`, `internal/store/ack.go`, `internal/store/fail.go`, `internal/store/heartbeat.go`

- [x] `Store` struct with `Writer` interface (direct SQLite for now, Raft later)
  ```go
  type Writer interface {
      Execute(sql string, args ...interface{}) (sql.Result, error)
      ExecuteTx(fn func(tx *sql.Tx) error) error
  }
  ```
- [x] `Enqueue(req EnqueueRequest) (*Job, error)` — insert job, handle unique lock check, update queue_stats, emit event
- [x] `EnqueueBatch(req BatchEnqueueRequest) (*Batch, []Job, error)` — batch insert + create batch row
- [x] `Fetch(queues []string, workerID, hostname string, leaseDuration int) (*Job, error)` — priority fetch with pause check, concurrency check, rate limit check
- [x] `Ack(jobID string, result json.RawMessage) error` — mark completed, clean unique lock, update batch counter if batched, update queue_stats
- [x] `Fail(jobID string, errMsg, backtrace string) (*FailResult, error)` — calculate backoff, insert job_error, transition to retrying or dead
- [x] `Heartbeat(req HeartbeatRequest) (*HeartbeatResponse, error)` — extend leases, update progress/checkpoint, return cancel signals
- [x] Backoff calculation helper (none/fixed/linear/exponential with max_delay cap)

### 5. Scheduler

Files: `internal/scheduler/scheduler.go`

- [x] Background goroutine, runs on configurable interval
- [x] Promote scheduled/retrying jobs: `UPDATE jobs SET state='pending' WHERE state IN ('scheduled','retrying') AND scheduled_at <= now`
- [x] Reclaim expired leases: `UPDATE jobs SET state='pending', worker_id=NULL WHERE state='active' AND lease_expires_at < now`
- [x] Clean expired unique locks: `DELETE FROM unique_locks WHERE expires_at < now`
- [x] Clean old events: `DELETE FROM events WHERE created_at < now - retention`
- [x] Clean old rate_limit_window entries
- [x] Graceful stop via context cancellation

### 6. Queue Management

Files: `internal/store/queues.go`

- [x] `ListQueues() ([]QueueInfo, error)` — queue list with live counts from jobs table
- [x] `PauseQueue(name string) error`
- [x] `ResumeQueue(name string) error`
- [x] `ClearQueue(name string) error` — delete pending/scheduled jobs
- [x] `DrainQueue(name string) error` — pause + mark draining
- [x] `DeleteQueue(name string) error` — delete queue and all its jobs
- [x] `SetConcurrency(name string, max int) error`
- [x] `SetThrottle(name string, rate int, windowMs int) error`
- [x] `RemoveThrottle(name string) error`
- [x] Auto-create queue row on first enqueue if not exists

### 7. Job Management

Files: `internal/store/jobs.go`

- [x] `GetJob(id string) (*Job, error)` — full job detail with errors
- [x] `RetryJob(id string) error` — reset attempt, move to pending
- [x] `CancelJob(id string) error` — mark cancelled (or cancelling if active)
- [x] `MoveJob(id, targetQueue string) error`
- [x] `DeleteJob(id string) error`

### 8. Search

Files: `internal/search/builder.go`, `internal/store/search.go`

- [x] `SearchFilter` struct matching all API filter fields
- [x] `BuildQuery(filter SearchFilter) (sql string, args []interface{}, error)` — dynamic WHERE clause builder
- [x] All filter types: queue, state, priority, tags (json_extract), payload_contains (LIKE), created_after/before, scheduled_after/before, started_after/before, completed_after/before, expire_before/after, attempt_min/max, unique_key, batch_id, worker_id, has_errors, error_contains, job_id_prefix
- [x] Sort options (created_at, priority, started_at, etc.) + order (asc/desc)
- [x] Cursor-based pagination (encode/decode cursor as base64 offset)
- [x] `SearchJobs(filter SearchFilter) (*SearchResult, error)` — execute built query, return jobs + total + cursor
- [x] `payload_jq` deferred to Phase 2 (needs expression parser -> json_extract translation)

### 9. Bulk Operations

Files: `internal/store/bulk.go`

- [x] `BulkAction(req BulkRequest) (*BulkResult, error)`
- [x] By explicit job IDs or by search filter
- [x] Actions: retry, delete, cancel, move, requeue, change_priority
- [x] Each action is a single UPDATE/DELETE ... WHERE statement
- [x] Return affected count, error count, duration_ms
- [x] Async bulk (>10k) deferred to Phase 2

### 10. HTTP Server and API Handlers

Files: `internal/server/server.go`, `internal/server/handlers_worker.go`, `internal/server/handlers_manage.go`, `internal/server/handlers_admin.go`, `internal/server/middleware.go`

- [x] `server.go` — chi router setup, wire all routes, start/stop lifecycle
- [x] Middleware: request ID, structured logging, recovery, CORS, content-type enforcement
- [x] `handlers_worker.go`:
  - `POST /api/v1/enqueue`
  - `POST /api/v1/enqueue/batch`
  - `POST /api/v1/fetch` (with long-poll: loop with 500ms sleep, respect timeout param)
  - `POST /api/v1/ack/{job_id}`
  - `POST /api/v1/fail/{job_id}`
  - `POST /api/v1/heartbeat`
- [x] `handlers_manage.go`:
  - `GET /api/v1/queues`
  - `POST /api/v1/queues/{name}/pause`
  - `POST /api/v1/queues/{name}/resume`
  - `POST /api/v1/queues/{name}/clear`
  - `POST /api/v1/queues/{name}/drain`
  - `POST /api/v1/queues/{name}/concurrency`
  - `POST /api/v1/queues/{name}/throttle`
  - `DELETE /api/v1/queues/{name}/throttle`
  - `DELETE /api/v1/queues/{name}`
  - `GET /api/v1/jobs/{id}`
  - `POST /api/v1/jobs/{id}/retry`
  - `POST /api/v1/jobs/{id}/cancel`
  - `POST /api/v1/jobs/{id}/move`
  - `DELETE /api/v1/jobs/{id}`
  - `POST /api/v1/jobs/search`
  - `POST /api/v1/jobs/bulk`
- [x] `handlers_admin.go`:
  - `GET /api/v1/workers`
  - `GET /api/v1/cluster/status` (single-node stub for now)
  - `GET /healthz`
- [x] Request validation and error response format: `{"error": "message", "code": "VALIDATION_ERROR"}`

### 11. Graceful Shutdown

Files: updates to `cmd/corvo/main.go`, `internal/server/server.go`

- [x] Trap SIGTERM + SIGINT
- [x] Stop accepting new HTTP connections
- [x] Wait for in-flight requests (with timeout)
- [x] Stop scheduler
- [x] Close SQLite connections
- [x] Log shutdown sequence

### 12. CLI

Files: `cmd/corvo/` (one file per command group)

- [x] `server` — start the server (bind addr, data dir, log level flags)
- [x] `enqueue <queue> <payload>` — enqueue a job (flags for priority, unique_key, max_retries, scheduled_at, tags)
- [x] `inspect <job-id>` — show full job detail
- [x] `retry <job-id>`, `cancel <job-id>`, `move <job-id> <queue>`, `delete <job-id>`
- [x] `queues` — list queues with stats
- [x] `pause <queue>`, `resume <queue>`, `clear <queue>`, `drain <queue>`, `destroy <queue> --confirm`
- [x] `search` — all filter flags, `--output json` support
- [x] `bulk <action>` — reads job IDs from stdin (piped from search) or `--filter` flag
- [x] `status` — server/queue summary
- [x] `workers` — list connected workers
- [x] `--server` flag (default `http://localhost:8080`) on all client commands
- [x] `--output json` flag on all commands for scripting

### 13. Go Client Library

Files: `pkg/client/client.go`, `pkg/client/worker.go`

- [x] `Client` struct — thin HTTP wrapper for all API endpoints
  - `Enqueue(queue string, payload interface{}, opts ...Option) (*Job, error)`
  - `EnqueueBatch(req BatchRequest) (*BatchResult, error)`
  - `GetJob(id string) (*Job, error)`
  - `Search(filter SearchFilter) (*SearchResult, error)`
  - Queue management methods
- [x] `Worker` struct — concurrent fetch loops + heartbeat
  - `Register(queue string, handler func(Job, Context) error)`
  - `Start(ctx context.Context) error`
  - Configurable concurrency
  - Background heartbeat loop (batched, every 15s)
  - Graceful shutdown: two-phase drain (stop fetching, wait for handlers, fail stuck jobs)
  - `Context` with `Checkpoint()`, `Progress()`, `Cancelled()` methods

### 14. Docker

Files: `deploy/Dockerfile`, `deploy/docker-compose.yml`

- [x] Multi-stage Dockerfile (Go build with CGo enabled -> scratch/alpine runtime)
- [x] `docker-compose.yml` — single-node quick start with volume mount

### 15. Integration Tests

Files: `tests/integration/`

- [x] Test helper: start server in-process, return client pointing at it
- [x] Full job lifecycle: enqueue -> fetch -> ack, verify completed
- [x] Fail + retry: enqueue -> fetch -> fail, verify retrying, wait for scheduler promotion, fetch again
- [x] Dead letter: exhaust retries, verify state=dead
- [x] Priority ordering: enqueue normal + critical, verify critical fetched first
- [x] Unique jobs: enqueue same unique_key twice, verify duplicate response
- [x] Queue pause/resume: pause queue, fetch returns nothing, resume, fetch works
- [x] Search: enqueue several jobs, search by various filters, verify results
- [x] Bulk operations: enqueue jobs, bulk retry/move/delete, verify
- [x] Cancellation: enqueue -> fetch -> cancel -> heartbeat returns cancel signal
- [x] Heartbeat + checkpoint: fetch -> checkpoint via heartbeat -> fail -> re-fetch, verify checkpoint preserved
- [ ] CLI smoke test: run CLI commands against live server

## Verification

After implementation, verify with:

1. `make build` — compiles to single binary
2. `./corvo server` — starts, SQLite created, logs show ready
3. `curl` the quick start sequence from DESIGN.md (enqueue -> fetch -> ack)
4. `make test` — all integration tests pass
5. `docker build` + `docker run` — works in container
