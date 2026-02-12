# Jobbie

An open-source, language-agnostic job processing system built in Go with embedded SQLite and Raft consensus.

Single binary. Single process. Automatic clustering. Great UI. Built for Kubernetes. Thin HTTP clients for every language.

## Why

Every team ends up building their own job queue. They start with Postgres polling, graduate to pgboss or Faktory, and then spend months bolting on unique jobs, retries, priority, graceful shutdown, and observability. Temporal solves the hard orchestration cases but is overkill (and operationally heavy) for the 80% of jobs that are "take task, do work, report result."

Faktory gets the architecture right (language-agnostic server, polyglot clients) but gates its best features behind an Enterprise license ($149–$949/month) and has a lacking UI. pgboss nails the DX but is Node-only and Postgres-bound.

Jobbie takes the best ideas from both, gives away every feature for free in OSS, and adds automatic clustering, a modern UI, and first-class Kubernetes support.

## Design principles

1. **Smart server, dumb clients** — all job lifecycle logic (retries, backoff, unique enforcement, priority routing, rate limiting, scheduling) lives in the server. Clients are thin HTTP wrappers. Fixing a bug in the server is one deploy; fixing a bug in a client is N upgrades across N teams.
2. **Single binary, single process, zero dependencies** — `jobbie server` starts everything: the HTTP API, the web UI, the scheduler, and an embedded SQLite database. No external database, message broker, or infrastructure to set up.
3. **Clustering that manages itself** — run 3 replicas and Jobbie handles Raft leader election, data replication, and automatic failover. No external coordination service (no Consul, no etcd, no Zookeeper).
4. **Language-agnostic by default** — the wire protocol is HTTP/JSON. A client library is ~100–200 lines in any language. You can enqueue a job with `curl`.
5. **Kubernetes-native** — graceful shutdown, horizontal scaling, health checks, and StatefulSet clustering are first-class, not afterthoughts.
6. **Observable** — every job has a full lifecycle trail visible in the UI. No "fire and forget into a black hole."

---

## Feature set

Everything pgboss and Faktory Enterprise offer, in a single free OSS package:

| Feature | Jobbie OSS | pgboss | Faktory OSS | Faktory Enterprise |
|---|---|---|---|---|
| Enqueue / process / ack | yes | yes | yes | yes |
| Retries + configurable backoff | yes | yes | yes | yes |
| Scheduled / delayed jobs | yes | yes | yes | yes |
| Cron / recurring jobs | yes | yes | no | yes |
| Priority (3 tiers) | yes | yes (integer) | yes (weighted) | yes |
| Unique / singleton jobs | yes | yes | no | yes |
| Dead letter queue | yes | yes | yes | yes |
| Job expiration (TTL) | yes | yes | no | yes |
| Queue pause / resume | yes | no | yes | yes |
| Throttling / rate limiting | yes | partial | no | yes |
| Batches (job groups + callback) | yes | no | no | yes |
| Job progress tracking | yes | no | no | yes |
| Completion callbacks | yes | yes | no | yes |
| Mutate API (bulk ops) | yes | no | yes | yes |
| Singleton queues (max 1 active) | yes | yes | no | no |
| Web UI | yes (modern) | no | yes (basic) | yes (basic) |
| Language agnostic | yes | no (Node) | yes | yes |
| Clustering / HA | yes (automatic) | no (Postgres) | no | no |
| Checkpointing (long-running jobs) | yes | no | no | no |
| Cancellation (pending + active) | yes | no | no | no |
| Prometheus metrics | yes | no | no | yes (Statsd) |

---

## Architecture overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  Jobbie Server (single Go binary)                                    │
│                                                                      │
│  ┌─────────────────┐  ┌──────────────┐  ┌────────────────────────┐  │
│  │ Embedded SQLite  │  │  HTTP API    │  │  Web UI (embedded SPA) │  │
│  │ (in-process)     │  │  :8080       │  │  :8080/ui              │  │
│  │                  │  │              │  │                        │  │
│  │  WAL mode        │  │  JSON API    │  │  Real-time via SSE     │  │
│  │  json_extract()  │  │  for all     │  │                        │  │
│  │  SQL txns        │  │  operations  │  │                        │  │
│  └────────┬─────────┘  └──────┬───────┘  └────────────────────────┘  │
│           │                   │                                      │
│  ┌────────┴───────────────────┴──────────────────────────────────┐   │
│  │  Jobbie Core                                                  │   │
│  │  - Job lifecycle engine (enqueue, retry, backoff, DLQ)        │   │
│  │  - Unique job enforcement (atomic SQL transactions)           │   │
│  │  - Scheduler (cron + delayed jobs)                            │   │
│  │  - Batch tracker                                              │   │
│  │  - Rate limiter                                               │   │
│  │  - Raft consensus (leader election, replication, failover)    │   │
│  │  - Metrics collector (Prometheus)                             │   │
│  └───────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  Exposed ports:                                                      │
│    :8080  — HTTP API + UI + worker protocol (public)                 │
│    :9400  — Raft consensus + cluster communication (internal)        │
└──────────────────────────────────────────────────────────────────────┘
         ▲
         │ HTTP/JSON
         │
   ┌─────┴──────────────────────────────┐
   │            Workers                  │
   │  ┌────┐  ┌────┐  ┌────┐  ┌──────┐ │
   │  │ TS │  │Rust│  │ Go │  │Haskell│ │
   │  └────┘  └────┘  └────┘  └──────┘ │
   │  All are thin HTTP clients         │
   │  ~100-200 lines per language       │
   └────────────────────────────────────┘
```

### Components

**Embedded SQLite** (in-process via mattn/go-sqlite3, no child process)
- SQLite is compiled into the Go binary via CGo — truly single process
- WAL mode for concurrent reads during writes
- All job state, queues, indexes, and metadata stored in SQL tables
- SQL transactions provide atomicity for complex features (unique jobs, rate limiting, batch tracking)
- Durable by default — WAL with `synchronous=FULL`

**Raft consensus** (hashicorp/raft, built into the binary)
- All write operations (enqueue, ack, fail, state transitions) go through Raft log
- Reads served directly from local SQLite (no Raft round-trip)
- Snapshots are full SQLite database copies
- Log compaction keeps disk usage bounded

**Jobbie HTTP Server** (Go, net/http + chi router)
- Serves the worker protocol (enqueue, fetch, ack, fail, heartbeat, progress)
- Serves the management API (pause, resume, retry, cancel, inspect)
- Serves the web UI (embedded SPA via `embed.FS`, SSE for real-time updates)
- Runs the scheduler (cron evaluation, delayed job promotion — leader only)
- Manages cluster state (Raft leader election, follower write proxying)

**Workers** (your code + a thin Jobbie client library)
- Connect to Jobbie via HTTP/JSON
- Long-poll for jobs, heartbeat while processing, ack/fail when done
- Handle SIGTERM for graceful shutdown
- Know nothing about SQLite, Raft, clustering, or job lifecycle logic

**Jobbie CLI** (ships with the server binary)

Job operations:
- `jobbie enqueue <queue> <payload>` — enqueue a job
- `jobbie inspect <job-id>` — show full job detail
- `jobbie retry <job-id>` — retry a failed/dead job
- `jobbie cancel <job-id>` — cancel a pending/active job
- `jobbie move <job-id> <target-queue>` — move a job to another queue
- `jobbie delete <job-id>` — delete a job

Queue management:
- `jobbie queues` — list all queues with stats
- `jobbie pause <queue>` — pause a queue
- `jobbie resume <queue>` — resume a paused queue
- `jobbie clear <queue>` — clear all pending jobs in a queue
- `jobbie drain <queue>` — pause + wait for active jobs to finish
- `jobbie destroy <queue> --confirm` — delete a queue and all its jobs

Search and bulk operations:
- `jobbie search --queue emails.send --state dead` — search jobs
- `jobbie search --queue emails.send --payload-contains "user@example.com"` — payload search
- `jobbie search --queue emails.send --payload-jq '.amount > 100'` — jq filter
- `jobbie search --tag tenant=acme-corp --state pending` — search by tag
- `jobbie search --error-contains "SMTP" --created-after 2026-02-10` — error search
- `jobbie search --queue emails.send --state dead | jobbie bulk retry` — pipe search to bulk
- `jobbie search --queue old.queue --state pending | jobbie bulk move new.queue` — bulk move
- `jobbie search --payload-jq '.legacy == true' | jobbie bulk delete` — bulk delete by payload
- `jobbie bulk retry --filter '{"queue":"emails.send","state":["dead"]}'` — inline filter

Server and cluster:
- `jobbie server` — start the server
- `jobbie status` — show queue stats + cluster health
- `jobbie top` — live TUI dashboard (active workers, jobs, throughput)
- `jobbie workers` — list connected workers
- `jobbie schedules` — list cron schedules
- `jobbie cluster status` — show cluster topology and replication lag

The CLI supports `--output json` for all commands, enabling scripting:
```bash
# Find all dead jobs with SMTP errors, retry them
jobbie search --queue emails.send --state dead --error-contains "SMTP" --output json \
  | jobbie bulk retry

# Move all pending jobs from one queue to another
jobbie search --queue old.emails --state pending --output json \
  | jobbie bulk move emails.v2

# Delete all completed jobs older than 7 days
jobbie search --state completed --created-before "$(date -d '7 days ago' -Iseconds)" --output json \
  | jobbie bulk delete

# Count dead jobs per queue
jobbie search --state dead --output json | jq 'group_by(.queue) | map({queue: .[0].queue, count: length})'

# Export all jobs matching a payload condition
jobbie search --queue reports --payload-jq '.customer_id == "cust_42"' --output json > jobs.json
```

---

## HTTP Protocol

All communication between clients and the Jobbie server is HTTP/JSON. No custom protocols, no binary encoding, no protobuf. You can test every endpoint with `curl`.

### Producer endpoints

**Enqueue a single job:**
```
POST /api/v1/enqueue
Content-Type: application/json

{
  "queue": "emails.send",
  "payload": { "to": "user@example.com", "template": "welcome" },
  "priority": "normal",
  "unique_key": "send-welcome-user@example.com",
  "unique_period": 3600,
  "max_retries": 5,
  "retry_backoff": "exponential",
  "retry_base_delay": "5s",
  "retry_max_delay": "10m",
  "scheduled_at": null,
  "expire_after": "1h",
  "tags": { "tenant": "acme-corp" }
}

→ 201 Created
{
  "job_id": "job_01HX7Y2K3M...",
  "status": "pending",
  "unique_existing": false
}
```

**Enqueue a batch:**
```
POST /api/v1/enqueue/batch
Content-Type: application/json

{
  "jobs": [
    { "queue": "emails.send", "payload": { "to": "a@example.com" } },
    { "queue": "emails.send", "payload": { "to": "b@example.com" } },
    { "queue": "emails.send", "payload": { "to": "c@example.com" } }
  ],
  "batch": {
    "callback_queue": "emails.batch-complete",
    "callback_payload": { "campaign_id": "camp_123" }
  }
}

→ 201 Created
{
  "job_ids": ["job_01...", "job_02...", "job_03..."],
  "batch_id": "batch_01..."
}
```

### Worker endpoints

**Fetch a job (long-poll):**
```
POST /api/v1/fetch
Content-Type: application/json

{
  "queues": ["emails.send", "emails.bulk"],
  "worker_id": "worker-abc",
  "hostname": "pod-xyz-123",
  "timeout": 30
}

→ 200 OK (when a job is available)
{
  "job_id": "job_01HX7Y2K3M...",
  "queue": "emails.send",
  "payload": { "to": "user@example.com", "template": "welcome" },
  "attempt": 1,
  "max_retries": 5,
  "lease_duration": 60,
  "checkpoint": null,
  "tags": { "tenant": "acme-corp" }
}

→ 204 No Content (timeout, no jobs available — client should retry)
```

**Acknowledge (complete a job):**
```
POST /api/v1/ack/{job_id}
Content-Type: application/json

{
  "result": { "sent": true, "message_id": "msg_123" }
}

→ 200 OK
```

**Fail a job:**
```
POST /api/v1/fail/{job_id}
Content-Type: application/json

{
  "error": "SMTP connection timeout",
  "backtrace": "at send_email:42\nat worker:18"
}

→ 200 OK
{
  "status": "retrying",
  "next_attempt_at": "2026-02-11T10:00:15Z",
  "attempts_remaining": 4
}
```

**Heartbeat (extend lease + check for cancellation):**
```
POST /api/v1/heartbeat
Content-Type: application/json

{
  "jobs": {
    "job_01HX...": {},
    "job_02HX...": { "progress": { "current": 450, "total": 1000, "message": "Sending batch" } },
    "job_03HX...": { "checkpoint": { "offset": 47000 } }
  }
}

→ 200 OK
{
  "jobs": {
    "job_01HX...": { "status": "ok" },
    "job_02HX...": { "status": "ok" },
    "job_03HX...": { "status": "cancel" }
  }
}
```

The heartbeat endpoint is batched — one request for all active jobs on a worker. The response carries cancel signals so clients don't need a separate channel for cancellation.

### Queue management endpoints

```
GET    /api/v1/queues                    — list all queues with stats
POST   /api/v1/queues/{name}/pause       — pause a queue (workers get no jobs)
POST   /api/v1/queues/{name}/resume      — resume a paused queue
POST   /api/v1/queues/{name}/clear       — delete ALL jobs in a queue (pending, scheduled)
POST   /api/v1/queues/{name}/drain       — stop new jobs, wait for active to finish
POST   /api/v1/queues/{name}/concurrency — set max global concurrency
POST   /api/v1/queues/{name}/throttle    — set rate limit
DELETE /api/v1/queues/{name}/throttle    — remove rate limit
DELETE /api/v1/queues/{name}             — delete queue and ALL its jobs (requires ?confirm=true)
```

### Job management endpoints

```
GET    /api/v1/jobs/{id}               — get full job detail
POST   /api/v1/jobs/{id}/retry         — retry a dead/failed job
POST   /api/v1/jobs/{id}/cancel        — cancel a pending/active job
POST   /api/v1/jobs/{id}/move          — move job to a different queue
DELETE /api/v1/jobs/{id}               — delete a job
```

### Search and filter

```
POST /api/v1/jobs/search               — search jobs with filters + payload matching
```

**Search request:**
```json
POST /api/v1/jobs/search
{
  "queue": "emails.send",
  "state": ["pending", "dead"],
  "priority": "normal",
  "tags": { "tenant": "acme-corp" },
  "payload_contains": "user@example.com",
  "payload_jq": ".template == \"welcome\"",
  "created_after": "2026-02-10T00:00:00Z",
  "created_before": "2026-02-11T23:59:59Z",
  "worker_id": "worker-abc",
  "has_errors": true,
  "error_contains": "SMTP",
  "sort": "created_at",
  "order": "desc",
  "cursor": null,
  "limit": 50
}
```

All fields are optional. They combine with AND logic. Omit a field to skip that filter.

**Search response:**
```json
{
  "jobs": [
    {
      "id": "job_01HX...",
      "queue": "emails.send",
      "state": "dead",
      "payload": { "to": "user@example.com", "template": "welcome" },
      "created_at": "2026-02-11T10:00:00Z",
      "attempt": 5,
      "last_error": "SMTP timeout",
      "tags": { "tenant": "acme-corp" }
    }
  ],
  "total": 142,
  "cursor": "eyJvZmZzZXQiOjUwfQ==",
  "has_more": true
}
```

**Search filters explained:**

| Filter | Type | Description |
|---|---|---|
| `queue` | string | Exact match on queue name |
| `state` | string[] | Match any of these states |
| `priority` | string | Exact match (critical/high/normal) |
| `tags` | object | All specified tags must match (AND) |
| `payload_contains` | string | Substring search in JSON-serialized payload |
| `payload_jq` | string | jq-style expression evaluated against payload (see below) |
| `created_after` | datetime | Jobs created after this time |
| `created_before` | datetime | Jobs created before this time |
| `worker_id` | string | Jobs processed by this worker |
| `has_errors` | bool | Jobs that have at least one error |
| `error_contains` | string | Substring search in error messages |
| `batch_id` | string | Jobs belonging to this batch |
| `unique_key` | string | Match on unique key |
| `expire_before` | datetime | Jobs expiring before this time |
| `expire_after` | datetime | Jobs expiring after this time |
| `scheduled_before` | datetime | Jobs scheduled before this time |
| `scheduled_after` | datetime | Jobs scheduled after this time |
| `started_after` | datetime | Jobs started after this time |
| `started_before` | datetime | Jobs started before this time |
| `completed_after` | datetime | Jobs completed after this time |
| `completed_before` | datetime | Jobs completed before this time |
| `attempt_min` | int | Jobs with at least N attempts |
| `attempt_max` | int | Jobs with at most N attempts |
| `job_id_prefix` | string | Match job IDs starting with prefix |

**Payload query language (`payload_jq`):**

A subset of jq syntax for filtering jobs by payload content:

```
.email == "user@example.com"          — exact field match
.amount > 100                          — numeric comparison
.tags | contains("vip")                — array contains
.metadata.region == "us-east"          — nested field access
.template | startswith("welcome")      — string prefix
.items | length > 5                    — array length
```

Not full jq — a safe, sandboxed subset. The server evaluates expressions against each job's payload during the search scan. Complex queries on large result sets may be slow — the response includes timing info so users know.

### Bulk operations

```
POST /api/v1/jobs/bulk                 — apply an action to multiple jobs
```

**Bulk by explicit IDs:**
```json
POST /api/v1/jobs/bulk
{
  "job_ids": ["job_01HX...", "job_02HX...", "job_03HX..."],
  "action": "retry"
}
```

**Bulk by search filter (apply action to all matching jobs):**
```json
POST /api/v1/jobs/bulk
{
  "filter": {
    "queue": "emails.send",
    "state": ["dead"],
    "error_contains": "SMTP timeout",
    "created_after": "2026-02-11T00:00:00Z"
  },
  "action": "retry"
}
```

**Supported bulk actions:**

| Action | Applies to states | Description |
|---|---|---|
| `retry` | dead, cancelled, completed | Re-enqueue jobs (reset attempt counter) |
| `delete` | any | Permanently delete jobs |
| `cancel` | pending, active, scheduled, retrying | Cancel jobs |
| `move` | pending, dead, scheduled, completed | Move jobs to a different queue |
| `requeue` | dead | Move back to pending in same queue (keep attempt history) |
| `change_priority` | pending, scheduled | Change priority tier |

**Bulk move to a different queue:**
```json
POST /api/v1/jobs/bulk
{
  "filter": {
    "queue": "emails.send",
    "state": ["dead"],
    "payload_jq": ".template == \"legacy\""
  },
  "action": "move",
  "move_to_queue": "emails.legacy"
}
```

**Bulk change priority:**
```json
POST /api/v1/jobs/bulk
{
  "filter": {
    "queue": "emails.send",
    "state": ["pending"],
    "tags": { "tenant": "acme-corp" }
  },
  "action": "change_priority",
  "priority": "critical"
}
```

**Bulk response:**
```json
{
  "affected": 142,
  "errors": 0,
  "duration_ms": 230
}
```

For large bulk operations (>10,000 jobs), the server processes them in batches internally and streams progress via SSE. The API returns immediately with a bulk operation ID:

```json
{
  "bulk_operation_id": "bulk_01HX...",
  "status": "processing",
  "estimated_total": 142000,
  "progress_url": "/api/v1/bulk/{id}/progress"
}
```

### Other management endpoints

```
GET    /api/v1/dead                    — list dead letter jobs (shortcut for search with state=dead)
GET    /api/v1/workers                 — list connected workers
GET    /api/v1/schedules               — list cron schedules
POST   /api/v1/schedules               — create a cron schedule
PUT    /api/v1/schedules/{id}          — update a cron schedule
DELETE /api/v1/schedules/{id}          — delete a cron schedule
GET    /api/v1/cluster/status          — cluster health and topology
GET    /api/v1/metrics                 — Prometheus metrics endpoint
GET    /api/v1/events                  — SSE stream for real-time UI updates
```

---

## Data model

### Job

```json
{
  "id": "job_01HX7Y2K3M...",
  "queue": "emails.send",
  "payload": { "to": "user@example.com", "template": "welcome" },
  "state": "active",
  "priority": "normal",
  "attempt": 2,
  "max_retries": 5,
  "retry_backoff": "exponential",
  "retry_base_delay": "5s",
  "retry_max_delay": "10m",
  "created_at": "2026-02-11T10:00:00Z",
  "scheduled_at": null,
  "started_at": "2026-02-11T10:00:01Z",
  "completed_at": null,
  "expire_after": "1h",
  "unique_key": "send-welcome-user@example.com",
  "unique_period": 3600,
  "batch_id": null,
  "tags": { "tenant": "acme-corp" },
  "progress": { "current": 450, "total": 1000, "message": "Sending batch 450/1000" },
  "checkpoint": null,
  "result": null,
  "errors": [
    { "attempt": 1, "error": "SMTP timeout", "backtrace": "...", "at": "2026-02-11T10:00:05Z" }
  ],
  "worker": { "id": "worker-abc", "hostname": "pod-xyz-123" }
}
```

### Job states

```
                  ┌───────────┐
                  │ scheduled │ (delayed or cron — waiting for scheduled_at)
                  └─────┬─────┘
                        │ time arrives (server promotes)
                        ▼
┌────────┐ enqueue ┌─────────┐ worker fetches ┌────────┐
│producer│────────►│ pending │───────────────►│ active │
└────────┘        └─────────┘               └───┬────┘
                       ▲                        │
                       │               ┌────────┼───────────┐
                       │               │        │           │
                  retry (with     success    failure     failure
                   backoff)         │     (retries left) (no retries)
                       │            │        │           │
                       │            ▼        │           ▼
                       │     ┌───────────┐   │    ┌──────────┐
                       │     │ completed │   │    │   dead   │
                       │     └───────────┘   │    └──────────┘
                       │                     │         │
                       └─────────────────────┘    manual retry
                                                  from UI/CLI/API
```

**States:**
- `scheduled` — waiting for `scheduled_at` time. Server promotes to `pending` when due.
- `pending` — in queue, waiting for a worker to fetch it.
- `active` — a worker is processing it. Server tracks lease expiry via heartbeats.
- `completed` — finished successfully. Kept for visibility, pruned after retention period.
- `retrying` — attempt failed, waiting for backoff delay before returning to `pending`.
- `dead` — all retries exhausted. Sits in dead letter queue for manual inspection/retry.
- `cancelled` — cancelled via API/UI. Worker notified via heartbeat response.

---

## SQLite schema

All job state lives in SQLite. The server uses SQL transactions for atomic operations.

### Tables

```sql
-- Core job table
CREATE TABLE jobs (
    id              TEXT PRIMARY KEY,
    queue           TEXT NOT NULL,
    state           TEXT NOT NULL DEFAULT 'pending',  -- pending, active, completed, retrying, dead, cancelled, scheduled
    payload         TEXT NOT NULL,                      -- JSON
    priority        INTEGER NOT NULL DEFAULT 2,        -- 0=critical, 1=high, 2=normal
    attempt         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    retry_backoff   TEXT NOT NULL DEFAULT 'exponential', -- none, fixed, linear, exponential
    retry_base_delay_ms INTEGER NOT NULL DEFAULT 5000,
    retry_max_delay_ms  INTEGER NOT NULL DEFAULT 600000,
    unique_key      TEXT,
    batch_id        TEXT,
    worker_id       TEXT,
    hostname        TEXT,
    tags            TEXT,                               -- JSON object
    progress        TEXT,                               -- JSON: {current, total, message}
    checkpoint      TEXT,                               -- JSON: arbitrary checkpoint data
    result          TEXT,                               -- JSON: completion result
    lease_expires_at TEXT,
    scheduled_at    TEXT,
    expire_at       TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    started_at      TEXT,
    completed_at    TEXT,
    failed_at       TEXT
);

-- Indexes for the query patterns we care about
CREATE INDEX idx_jobs_queue_state_priority ON jobs(queue, state, priority, created_at);
CREATE INDEX idx_jobs_state ON jobs(state);
CREATE INDEX idx_jobs_scheduled ON jobs(state, scheduled_at) WHERE state = 'scheduled';
CREATE INDEX idx_jobs_lease ON jobs(state, lease_expires_at) WHERE state = 'active';
CREATE INDEX idx_jobs_unique ON jobs(queue, unique_key) WHERE unique_key IS NOT NULL;
CREATE INDEX idx_jobs_batch ON jobs(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX idx_jobs_expire ON jobs(expire_at) WHERE expire_at IS NOT NULL;
CREATE INDEX idx_jobs_created ON jobs(created_at);

-- Job errors (one row per failed attempt)
CREATE TABLE job_errors (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    attempt    INTEGER NOT NULL,
    error      TEXT NOT NULL,
    backtrace  TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX idx_job_errors_job ON job_errors(job_id);

-- Unique locks (separate table for clean TTL expiry)
CREATE TABLE unique_locks (
    queue      TEXT NOT NULL,
    unique_key TEXT NOT NULL,
    job_id     TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    PRIMARY KEY (queue, unique_key)
);

-- Batches
CREATE TABLE batches (
    id               TEXT PRIMARY KEY,
    total            INTEGER NOT NULL,
    pending          INTEGER NOT NULL,
    succeeded        INTEGER NOT NULL DEFAULT 0,
    failed           INTEGER NOT NULL DEFAULT 0,
    callback_queue   TEXT,
    callback_payload TEXT,                              -- JSON
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

-- Queue configuration (pause state, rate limits, concurrency)
CREATE TABLE queues (
    name            TEXT PRIMARY KEY,
    paused          INTEGER NOT NULL DEFAULT 0,
    max_concurrency INTEGER,                            -- NULL = unlimited
    rate_limit      INTEGER,                            -- max jobs per window
    rate_window_ms  INTEGER,                            -- window size in ms
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

-- Rate limiting sliding window
CREATE TABLE rate_limit_window (
    queue      TEXT NOT NULL,
    fetched_at TEXT NOT NULL
);
CREATE INDEX idx_rate_limit ON rate_limit_window(queue, fetched_at);

-- Cron schedules
CREATE TABLE schedules (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    queue      TEXT NOT NULL,
    cron       TEXT NOT NULL,
    timezone   TEXT NOT NULL DEFAULT 'UTC',
    payload    TEXT NOT NULL,                            -- JSON
    unique_key TEXT,
    max_retries INTEGER NOT NULL DEFAULT 3,
    last_run   TEXT,
    next_run   TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

-- Workers (tracked via heartbeat)
CREATE TABLE workers (
    id              TEXT PRIMARY KEY,
    hostname        TEXT,
    queues          TEXT,                                -- JSON array
    last_heartbeat  TEXT NOT NULL,
    started_at      TEXT NOT NULL
);

-- Event log (ring buffer for SSE, capped by periodic cleanup)
CREATE TABLE events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    type       TEXT NOT NULL,                            -- enqueued, started, completed, failed, dead, cancelled, etc.
    job_id     TEXT,
    queue      TEXT,
    data       TEXT,                                     -- JSON
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX idx_events_created ON events(created_at);

-- Queue stats (rolling counters, updated on each state transition)
CREATE TABLE queue_stats (
    queue      TEXT PRIMARY KEY,
    enqueued   INTEGER NOT NULL DEFAULT 0,
    completed  INTEGER NOT NULL DEFAULT 0,
    failed     INTEGER NOT NULL DEFAULT 0,
    dead       INTEGER NOT NULL DEFAULT 0
);
```

### Search implementation

Search is just SQL. Every filter maps directly to a WHERE clause:

```sql
-- Example: find dead jobs in emails.send with SMTP errors and a specific payload field
SELECT j.*, GROUP_CONCAT(je.error, '|||') as errors
FROM jobs j
LEFT JOIN job_errors je ON je.job_id = j.id
WHERE j.queue = 'emails.send'
  AND j.state = 'dead'
  AND json_extract(j.payload, '$.template') = 'welcome'
  AND j.created_at > '2026-02-10T00:00:00'
  AND je.error LIKE '%SMTP%'
GROUP BY j.id
ORDER BY j.created_at DESC
LIMIT 50 OFFSET 0;
```

Every search filter from the API maps to SQL:

| Filter | SQL clause |
|---|---|
| `queue` | `WHERE queue = ?` |
| `state` | `WHERE state IN (?, ?, ...)` |
| `priority` | `WHERE priority = ?` |
| `tags` | `WHERE json_extract(tags, '$.tenant') = ?` |
| `payload_contains` | `WHERE payload LIKE '%' \|\| ? \|\| '%'` |
| `payload_jq` | `WHERE json_extract(payload, ?) = ?` (translated from jq syntax) |
| `created_after/before` | `WHERE created_at > ? / < ?` |
| `scheduled_after/before` | `WHERE scheduled_at > ? / < ?` |
| `started_after/before` | `WHERE started_at > ? / < ?` |
| `completed_after/before` | `WHERE completed_at > ? / < ?` |
| `expire_before/after` | `WHERE expire_at < ? / > ?` |
| `attempt_min/max` | `WHERE attempt >= ? / <= ?` |
| `unique_key` | `WHERE unique_key = ?` |
| `batch_id` | `WHERE batch_id = ?` |
| `worker_id` | `WHERE worker_id = ?` |
| `has_errors` | `WHERE id IN (SELECT DISTINCT job_id FROM job_errors)` |
| `error_contains` | `WHERE id IN (SELECT job_id FROM job_errors WHERE error LIKE '%' \|\| ? \|\| '%')` |
| `job_id_prefix` | `WHERE id LIKE ? \|\| '%'` |

No secondary index sets to maintain, no Lua scan loops. SQLite's query planner handles index selection automatically.

**Performance expectations:**
- Indexed queries (queue + state): <5ms for up to 100k jobs
- Payload search via `json_extract`: ~50ms per 100k jobs (SQLite json is fast)
- `payload LIKE` substring search: ~100ms per 100k jobs
- `payload_jq` expressions: translated to `json_extract` at query time
- The response includes `"duration_ms"` so users can see query cost

### Atomic operations via SQL transactions

Complex features are implemented as SQL transactions:

**Enqueue with unique check:**
```sql
BEGIN;
-- Check unique lock
SELECT job_id FROM unique_locks
WHERE queue = ? AND unique_key = ? AND expires_at > datetime('now');

-- If no existing lock:
INSERT INTO unique_locks (queue, unique_key, job_id, expires_at)
VALUES (?, ?, ?, datetime('now', '+' || ? || ' seconds'));

INSERT INTO jobs (id, queue, payload, state, priority, unique_key, max_retries,
                  retry_backoff, retry_base_delay_ms, retry_max_delay_ms, tags, expire_at)
VALUES (?, ?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?);

INSERT INTO events (type, job_id, queue) VALUES ('enqueued', ?, ?);

UPDATE queue_stats SET enqueued = enqueued + 1 WHERE queue = ?;
COMMIT;
```

**Fetch with priority + pause check:**
```sql
BEGIN;
-- Atomic: find highest-priority pending job, claim it
UPDATE jobs SET
    state = 'active',
    worker_id = ?,
    hostname = ?,
    started_at = strftime('%Y-%m-%dT%H:%M:%f', 'now'),
    lease_expires_at = strftime('%Y-%m-%dT%H:%M:%f', 'now', '+' || ? || ' seconds'),
    attempt = attempt + 1
WHERE id = (
    SELECT j.id FROM jobs j
    JOIN queues q ON q.name = j.queue
    WHERE j.queue IN (?, ?, ?)
      AND j.state = 'pending'
      AND q.paused = 0
    ORDER BY j.priority ASC, j.created_at ASC
    LIMIT 1
)
RETURNING *;

INSERT INTO events (type, job_id, queue) VALUES ('started', ?, ?);
COMMIT;
```

**Batch completion tracking:**
```sql
BEGIN;
UPDATE batches SET
    pending = pending - 1,
    succeeded = CASE WHEN ? = 'success' THEN succeeded + 1 ELSE succeeded END,
    failed = CASE WHEN ? = 'failure' THEN failed + 1 ELSE failed END
WHERE id = ?
RETURNING pending, callback_queue, callback_payload;

-- If pending = 0, enqueue the callback job:
INSERT INTO jobs (id, queue, payload, state, priority)
VALUES (?, ?, ?, 'pending', 2);
COMMIT;
```

**Bulk operations (single statement):**
```sql
-- Bulk retry: move all matching dead jobs back to pending
UPDATE jobs SET state = 'pending', attempt = 0, failed_at = NULL
WHERE queue = 'emails.send' AND state = 'dead'
  AND id IN (SELECT job_id FROM job_errors WHERE error LIKE '%SMTP%');

-- Bulk move: move jobs to a different queue
UPDATE jobs SET queue = 'emails.v2'
WHERE queue = 'emails.send' AND state = 'dead'
  AND json_extract(payload, '$.legacy') = true;

-- Bulk delete: remove completed jobs older than 7 days
DELETE FROM jobs WHERE state = 'completed'
  AND created_at < datetime('now', '-7 days');
```

---

## Priority system

Three tiers: `critical` (0), `high` (1), `normal` (2, default).

Implemented via `ORDER BY priority ASC, created_at ASC` in the fetch query:

```sql
SELECT id FROM jobs
WHERE queue = ? AND state = 'pending'
ORDER BY priority ASC, created_at ASC
LIMIT 1;
```

Lower priority value = fetched first. Critical (0) before high (1) before normal (2). Within a tier, jobs are FIFO by creation time.

The composite index `idx_jobs_queue_state_priority` on `(queue, state, priority, created_at)` makes this a single index scan — no table scan, no client-side priority logic.

---

## Unique jobs

Unique jobs ensure only one job with a given key exists within a time window.

```sql
-- Inside a transaction:
-- 1. Check for existing lock
SELECT job_id FROM unique_locks
WHERE queue = 'emails.send' AND unique_key = 'sync-user-42'
  AND expires_at > datetime('now');

-- 2. If no rows → insert lock + enqueue job
INSERT INTO unique_locks (queue, unique_key, job_id, expires_at)
VALUES ('emails.send', 'sync-user-42', 'job_01HX...', datetime('now', '+3600 seconds'));

INSERT INTO jobs (...) VALUES (...);

-- 3. If row exists → return existing job_id, status "duplicate"

-- 4. On job completion → DELETE FROM unique_locks WHERE job_id = ?
--    (or let the expires_at act as safety net)
```

No race conditions — SQLite serializes transactions. The unique constraint on `(queue, unique_key)` is enforced at the database level.

---

## Retry and backoff

Configured per job at enqueue time. The server handles all retry logic — the client just calls `POST /fail/{job_id}` with an error message.

**Backoff strategies:**
- `none` — immediate retry
- `fixed` — same delay every time (e.g., 5s, 5s, 5s)
- `linear` — base_delay * attempt (5s, 10s, 15s, 20s)
- `exponential` — base_delay * 2^attempt (5s, 10s, 20s, 40s, capped at max_delay)

**Server-side implementation:**

On `POST /fail/{job_id}`:
1. Server calculates next retry time based on backoff policy
2. If attempts remaining > 0:
   - Set job state to `retrying`, set `scheduled_at` to retry time
   - Scheduler will promote it to `pending` when the time comes
3. If attempts exhausted:
   - Set job state to `dead`
   - Emit `dead` lifecycle event

The client never calculates backoff, never decides whether to retry. It just says "this failed" and the server handles the rest.

---

## Rate limiting / throttling

Per-queue rate limiting prevents overwhelming downstream services:

```
POST /api/v1/queues/emails.send/throttle
{ "rate": 100, "period": "1m" }   →  max 100 jobs/minute fetched from this queue
```

Implemented via a sliding window in SQL:

```sql
-- On each fetch, check rate limit within the transaction:
SELECT COUNT(*) FROM rate_limit_window
WHERE queue = ? AND fetched_at > datetime('now', '-' || ? || ' seconds');

-- If count < max_rate → allow fetch, record it:
INSERT INTO rate_limit_window (queue, fetched_at)
VALUES (?, strftime('%Y-%m-%dT%H:%M:%f', 'now'));

-- If count >= max_rate → don't return a job (rate limited)

-- Periodic cleanup removes old entries:
DELETE FROM rate_limit_window
WHERE fetched_at < datetime('now', '-' || ? || ' seconds');
```

Workers that long-poll a throttled queue simply wait longer between jobs. They don't need to know about rate limits.

---

## Batches

Batches group jobs together and fire a callback when all jobs in the batch complete:

```
POST /api/v1/enqueue/batch
{
  "jobs": [
    { "queue": "images.resize", "payload": { "image_id": 1, "size": "thumb" } },
    { "queue": "images.resize", "payload": { "image_id": 2, "size": "thumb" } },
    { "queue": "images.resize", "payload": { "image_id": 3, "size": "thumb" } }
  ],
  "batch": {
    "callback_queue": "images.batch-done",
    "callback_payload": { "album_id": "album_42" }
  }
}
```

Server tracks batch state in the `batches` table:
```sql
INSERT INTO batches (id, total, pending, callback_queue, callback_payload)
VALUES ('batch_01...', 3, 3, 'images.batch-done', '{"album_id":"album_42"}');
```

Each time a job in the batch completes or fails, the server atomically decrements `pending` inside a transaction. When `pending` reaches 0, the server enqueues the callback job with a payload containing the batch results (how many succeeded, how many failed).

---

## Scheduled and recurring jobs

### Delayed jobs

```
POST /api/v1/enqueue
{
  "queue": "emails.send",
  "payload": { ... },
  "scheduled_at": "2026-02-12T09:00:00Z"
}
```

The job is inserted with `state = 'scheduled'` and `scheduled_at` set. The server's scheduler loop runs every second, promoting due jobs:

```sql
UPDATE jobs SET state = 'pending', scheduled_at = NULL
WHERE state IN ('scheduled', 'retrying')
  AND scheduled_at <= strftime('%Y-%m-%dT%H:%M:%f', 'now');
```

### Cron / recurring jobs

```
POST /api/v1/schedules
{
  "name": "daily-report",
  "queue": "reports.generate",
  "cron": "0 9 * * *",
  "timezone": "America/New_York",
  "payload": { "type": "daily" },
  "unique_key": "daily-report"
}
```

Stored in the `schedules` table. The server evaluates cron expressions and enqueues jobs at the right time. Only the Raft leader runs the scheduler. Unique job enforcement is a safety net against double-enqueue during leader transitions.

---

## Job expiration

Jobs can have a TTL. If a job hasn't completed within `expire_after`, it's moved to `dead`:

```
POST /api/v1/enqueue
{
  "queue": "emails.send",
  "payload": { ... },
  "expire_after": "1h"
}
```

The server checks expiry on each state transition and during periodic sweeps. Expired jobs skip the retry cycle and go directly to `dead` with reason "expired."

---

## Cancellation

### Cancel a pending job

```
POST /api/v1/jobs/{id}/cancel

→ 200 OK { "status": "cancelled" }
```

Server removes the job from the pending set and updates state to `cancelled`.

### Cancel an active job

```
POST /api/v1/jobs/{id}/cancel

→ 200 OK { "status": "cancelling" }
```

Server marks the job for cancellation. On the worker's next heartbeat, the response includes `"status": "cancel"` for that job. The client library sets `ctx.cancelled = true` and the worker's handler is expected to check it and return early.

Workers MUST cooperatively check for cancellation. There is no preemptive kill.

---

## Graceful shutdown and Kubernetes

### Worker shutdown sequence

```
1. K8s sends SIGTERM to worker pod
2. Client library receives signal, enters drain mode:
   a. Stop calling POST /fetch (no new jobs)
   b. Wait for in-flight jobs to complete (up to terminationGracePeriodSeconds)
   c. For jobs that won't finish in time:
      - Call POST /heartbeat with final checkpoint
      - Call POST /fail/{job_id} with error "worker_shutdown"
      - Server will retry with backoff, preserving the checkpoint
   d. Exit 0
```

The server handles everything else:
- Detecting that a worker stopped heartbeating → reclaiming the lease
- Re-enqueuing jobs whose leases expired
- Preserving checkpoint data so resumed jobs continue from where they left off

### Lease reclamation

The server runs a periodic sweep (every 10s) checking for expired leases:

```sql
UPDATE jobs SET state = 'pending', worker_id = NULL, hostname = NULL
WHERE state = 'active'
  AND lease_expires_at < strftime('%Y-%m-%dT%H:%M:%f', 'now');
-- Checkpoint data is preserved on the job row — resumed workers pick up where they left off
```

### K8s worker configuration

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jobbie-worker-emails
spec:
  replicas: 3
  template:
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: worker
          env:
            - name: JOBBIE_URL
              value: "http://jobbie:8080"
            - name: JOBBIE_QUEUES
              value: "emails.send,emails.bulk"
            - name: JOBBIE_CONCURRENCY
              value: "10"
          readinessProbe:
            httpGet:
              path: /healthz
              port: 9090
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "sleep 5"]
```

### Checkpointing for long-running jobs

```typescript
worker.register("reports.generate", async (job, ctx) => {
  // Resume from checkpoint if this job was interrupted
  let offset = ctx.checkpoint?.offset ?? 0;

  const rows = await db.query("SELECT * FROM data OFFSET $1", [offset]);

  for (let i = 0; i < rows.length; i++) {
    await processRow(rows[i]);

    if (i % 1000 === 0) {
      // Save checkpoint — server stores it, extends lease
      await ctx.checkpoint({ offset: offset + i });

      // Check if we've been asked to stop (k8s shutdown or cancellation)
      if (ctx.cancelled) {
        return; // checkpoint is saved, job will be retried from here
      }
    }
  }

  return { processed: rows.length };
});
```

Under the hood, `ctx.checkpoint()` sends a heartbeat with checkpoint data. The server stores it in the job hash. When the job is retried (after shutdown or failure), the checkpoint is included in the fetch response.

---

## Concurrency control

### Per-worker concurrency

How many jobs a single worker process handles simultaneously:

```typescript
const worker = new JobbieWorker({
  url: "http://jobbie:8080",
  queues: ["emails.send"],
  concurrency: 10,
});
```

The client library manages this locally — it maintains up to N in-flight fetch requests. This is client-side logic because it depends on the worker's resources.

### Per-queue global concurrency (singleton queues)

Max jobs active across ALL workers for a queue:

```
POST /api/v1/queues/payments.process/concurrency
{ "max": 1 }    →  singleton queue: only 1 job active at a time
```

Server enforces this in the fetch query — the fetch transaction checks `SELECT COUNT(*) FROM jobs WHERE queue = ? AND state = 'active'` and only proceeds if the count is below `max_concurrency`. Workers just wait (long-poll returns nothing until a slot opens).

---

## Clustering

### Overview

Jobbie servers cluster automatically using hashicorp/raft for consensus and SQLite for storage. The user runs 3+ instances; Jobbie handles leader election, data replication, and automatic failover. No external coordination service required.

```
┌──────────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
│  Jobbie-0 (leader)   │   │  Jobbie-1 (follower)  │   │  Jobbie-2 (follower)  │
│                      │   │                       │   │                       │
│  ┌────────────────┐  │   │  ┌────────────────┐   │   │  ┌────────────────┐   │
│  │ SQLite (WAL)   │  │   │  │ SQLite (WAL)   │   │   │  │ SQLite (WAL)   │   │
│  │ via Raft FSM   │  │   │  │ via Raft FSM   │   │   │  │ via Raft FSM   │   │
│  └────────────────┘  │   │  └────────────────┘   │   │  └────────────────┘   │
│                      │   │                       │   │                       │
│  HTTP API ✓          │   │  HTTP API ✓            │   │  HTTP API ✓            │
│  Scheduler ✓         │   │  Scheduler ✗ (standby) │   │  Scheduler ✗ (standby) │
│  Accepts writes ✓    │   │  Proxies writes →      │   │  Proxies writes →      │
└──────────────────────┘   └───────────────────────┘   └───────────────────────┘
         ▲                          ▲                           ▲
         └──────────────────────────┴───────────────────────────┘
                          Load balancer / k8s Service
                                     ▲
                                     │
                               ┌─────┴─────┐
                               │  Workers   │
                               └───────────┘
```

### How it works

**Write path (through Raft):**
```
Client → HTTP POST /api/v1/enqueue → any Jobbie node
  → If leader: serialize SQL command → raft.Apply() → committed to quorum → applied to local SQLite → respond
  → If follower: proxy request to leader internally → leader applies via Raft → respond
```

**Read path (local):**
```
Client → HTTP GET /api/v1/jobs/search → any Jobbie node
  → Query local SQLite directly (no Raft round-trip)
  → Reads may be slightly stale on followers (typically <1ms)
```

**Raft FSM (Finite State Machine) — ~600 lines of glue:**

```go
type JobbieFSM struct {
    db *sql.DB  // local SQLite
}

// Apply is called by Raft when a log entry is committed by quorum.
// Every write to SQLite goes through here.
func (f *JobbieFSM) Apply(log *raft.Log) interface{} {
    var cmd Command
    json.Unmarshal(log.Data, &cmd)
    switch cmd.Type {
    case "execute":
        result, err := f.db.Exec(cmd.SQL, cmd.Args...)
        return &ApplyResult{Result: result, Error: err}
    case "execute_multi":
        tx, _ := f.db.Begin()
        for _, stmt := range cmd.Statements {
            tx.Exec(stmt.SQL, stmt.Args...)
        }
        tx.Commit()
        return &ApplyResult{}
    }
    return nil
}

// Snapshot creates a point-in-time copy of the SQLite database.
// Used for log compaction and bootstrapping new nodes.
func (f *JobbieFSM) Snapshot() (raft.FSMSnapshot, error) {
    return &sqliteSnapshot{db: f.db}, nil
}

// Restore replaces the local SQLite from a snapshot (new node joining).
func (f *JobbieFSM) Restore(rc io.ReadCloser) error {
    return restoreSQLiteFromReader(f.db, rc)
}
```

**Store layer (abstraction over Raft + SQLite):**

```go
type Store struct {
    raft *raft.Raft
    fsm  *JobbieFSM
}

// Execute sends a write through Raft consensus.
// Blocks until committed by quorum.
func (s *Store) Execute(sql string, args ...interface{}) error {
    cmd := Command{Type: "execute", SQL: sql, Args: args}
    data, _ := json.Marshal(cmd)
    f := s.raft.Apply(data, 5*time.Second)
    return f.Error()
}

// Query reads directly from local SQLite (no Raft round-trip).
func (s *Store) Query(sql string, args ...interface{}) (*sql.Rows, error) {
    return s.fsm.db.Query(sql, args...)
}

func (s *Store) IsLeader() bool {
    return s.raft.State() == raft.Leader
}
```

This pattern is battle-tested — it's essentially what rqlite does, and hashicorp/raft powers Consul, Nomad, and Vault in production.

**Peer discovery:**
- Static: `--peers jobbie-1:9400,jobbie-2:9400`
- Kubernetes: `--discover=dns` resolves peers via headless service DNS
  (`jobbie-0.jobbie.ns.svc.cluster.local`, `jobbie-1.jobbie...`, etc.)

**Leader election:**
- Handled entirely by hashicorp/raft (Raft protocol)
- Automatic leader election on startup
- Automatic re-election if leader fails (configurable timeout, default 10s)
- No custom gossip protocol needed — Raft handles it all

**Data replication:**
```
1. All writes go through Raft leader
2. Leader replicates log entries to followers
3. Once a quorum (2 of 3) acknowledges, the write is committed
4. Each node applies committed entries to its local SQLite
5. All nodes have identical SQLite databases
```

**Write proxying:**
- Workers connect to any Jobbie node (via load balancer)
- Read operations (queue stats, job inspect, search) are served from local SQLite — no Raft round-trip
- Write operations (enqueue, ack, fail, etc.) are proxied to the Raft leader internally
- The client has no idea which node is the leader — the API is identical on every node

**Automatic failover:**
```
1. Leader (Jobbie-0) dies
2. Raft detects missing heartbeats (election timeout)
3. Remaining nodes hold Raft election
4. Jobbie-1 wins election, becomes new leader
5. Jobbie-1 starts accepting writes via Raft
6. Jobbie-1 starts the scheduler (only leader runs scheduler)
7. Workers notice nothing — their HTTP requests still go through the LB
```

**Rejoining:**
```
1. Jobbie-0 comes back online
2. Rejoins the Raft cluster as a follower
3. Raft replays missed log entries (or sends a snapshot if too far behind)
4. Jobbie-0's SQLite catches up to current state
5. Cluster is back to 3 nodes
```

**Snapshots and compaction:**
- Raft log grows indefinitely without snapshots
- Jobbie takes periodic snapshots (configurable, default every 10,000 log entries)
- A snapshot is a complete copy of the SQLite database file
- After a snapshot, old log entries are discarded
- New nodes joining the cluster receive the latest snapshot + recent log entries

### Ports

| Port | Purpose | Exposed to |
|---|---|---|
| 8080 | HTTP API + UI + worker protocol | Workers, users, load balancer |
| 9400 | Raft consensus + peer communication | Other Jobbie instances only |

Workers and users only ever see port 8080. Port 9400 is internal cluster traffic only.

### K8s deployment (clustered)

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: jobbie
spec:
  serviceName: jobbie-internal
  replicas: 3
  selector:
    matchLabels:
      app: jobbie
  template:
    metadata:
      labels:
        app: jobbie
    spec:
      containers:
        - name: jobbie
          image: jobbie:latest
          args: ["server", "--cluster", "--discover=dns"]
          ports:
            - containerPort: 8080
              name: api
            - containerPort: 9400
              name: raft
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
---
# Headless service for Raft peer discovery
apiVersion: v1
kind: Service
metadata:
  name: jobbie-internal
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  selector:
    app: jobbie
  ports:
    - name: raft
      port: 9400
---
# Regular service for workers/users
apiVersion: v1
kind: Service
metadata:
  name: jobbie
spec:
  selector:
    app: jobbie
  ports:
    - name: api
      port: 8080
```

### Deployment modes summary

```
Mode 1: Single node (default)
  $ jobbie server --data-dir /var/lib/jobbie
  → Embedded SQLite, everything in one process, no clustering overhead
  → Raft runs in single-node mode (commits locally, no quorum needed)
  → Good for: dev, staging, small production, single server
  → ~5,000 jobs/sec

Mode 2: Clustered (automatic HA)
  $ jobbie server --cluster --peers node2:9400,node3:9400
  or in k8s: --cluster --discover=dns
  → 3-node Raft group, automatic leader election + failover
  → Good for: production HA, medium-to-large scale
  → ~5,000 jobs/sec with fault tolerance (survives 1 node failure)

Mode 3: Federated clusters (horizontal scaling)
  → Multiple independent Jobbie clusters, each handling a subset of queues
  → Queues are assigned to clusters; workers/producers point at the right cluster
  → No code changes — just deployment configuration
  → Good for: high-throughput production, >5,000 jobs/sec
  → Scales linearly: N clusters × ~5,000 jobs/sec

Mode 4: Jobbie Cloud (managed)
  → Customers configure workers with an API key + URL
  → Infrastructure is Jobbie's problem
```

### Federated clusters

When a single Raft cluster isn't enough (~5,000 jobs/sec ceiling), scale by running multiple independent clusters. Each cluster handles a subset of queues.

```
                    ┌──────────────────────────────┐
                    │       Jobbie Federation       │
                    │       (optional gateway)      │
                    └──────┬──────────────┬─────────┘
                           │              │
              ┌────────────┴──┐     ┌─────┴───────────┐
              │  Cluster A    │     │  Cluster B       │
              │  (3 nodes)    │     │  (3 nodes)       │
              │               │     │                  │
              │  emails.*     │     │  reports.*       │
              │  notifs.*     │     │  sync.*          │
              │               │     │  analytics.*     │
              │  ~5,000 j/s   │     │  ~5,000 j/s      │
              └───────────────┘     └──────────────────┘
```

This works today without any special support because:
- Queues are naturally independent (no cross-queue state)
- Workers already specify which queues they consume
- Producers already target a specific queue when enqueuing

Future work could add a **federation gateway** — a thin proxy that routes requests to the correct cluster based on queue name, providing a single endpoint for clients and a unified UI across clusters. But this is a convenience layer, not a requirement — federation works with just DNS/config today.

---

## The UI

Served by the Jobbie server as an embedded SPA (via Go's `embed.FS`). Real-time updates via SSE from the `events` table.

### Dashboard

```
┌──────────────────────────────────────────────────────────────────────┐
│  Jobbie                                    cluster: prod (3 nodes)   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Queues                                                              │
│  ┌──────────────┬────────┬────────┬───────┬──────┬─────────┬──────┐ │
│  │ Queue        │Pending │ Active │ Done  │ Dead │ Rate    │      │ │
│  ├──────────────┼────────┼────────┼───────┼──────┼─────────┼──────┤ │
│  │ emails.send  │    42  │    10  │ 12.4k │    3 │ 124/min │  ▶   │ │
│  │ emails.bulk  │ 1,203  │     5  │   892 │    0 │  18/min │  ▶   │ │
│  │ reports.gen  │     0  │     1  │    47 │    1 │   2/min │  ▶   │ │
│  │ sync.users   │     — paused —  │  3.2k │    0 │       — │  ⏸   │ │
│  └──────────────┴────────┴────────┴───────┴──────┴─────────┴──────┘ │
│                                                                      │
│  Workers (8 connected)                                               │
│  ┌───────────────────┬────────────┬──────┬───────────────────────┐   │
│  │ Worker            │ Host       │ Jobs │ Uptime                │   │
│  ├───────────────────┼────────────┼──────┼───────────────────────┤   │
│  │ worker-a1b2c3     │ pod-xyz-1  │ 3/10 │ 4h 22m                │   │
│  │ worker-d4e5f6     │ pod-xyz-2  │ 7/10 │ 4h 22m                │   │
│  │ worker-g7h8i9     │ pod-abc-1  │ 1/5  │ 12m (draining)        │   │
│  └───────────────────┴────────────┴──────┴───────────────────────┘   │
│                                                                      │
│  Cluster                                                             │
│  ┌───────────┬────────────┬──────────┬──────────────────────────┐    │
│  │ Node      │ Role       │ Raft     │ Status                   │    │
│  ├───────────┼────────────┼──────────┼──────────────────────────┤    │
│  │ jobbie-0  │ leader     │ leader   │ healthy                  │    │
│  │ jobbie-1  │ follower   │ follower │ healthy, log: current    │    │
│  │ jobbie-2  │ follower   │ follower │ healthy, log: current    │    │
│  └───────────┴────────────┴──────────┴──────────────────────────┘    │
│                                                                      │
│  Recent failures                                                     │
│  ┌─────────────────────────────────────────────────────┬───────────┐ │
│  │ job_01HX... emails.send SMTP timeout (attempt 3/5)  │ 2m ago    │ │
│  │ job_01HX... reports.gen OOM killed                   │ 14m ago   │ │
│  └─────────────────────────────────────────────────────┴───────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

### Queue detail view

```
┌──────────────────────────────────────────────────────────────────────┐
│  Queue: emails.send                          [Pause] [Clear] [Drain]│
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Status: ▶ active          Throughput: 124/min     Concurrency: 10   │
│  Pending: 42     Active: 10    Completed: 12.4k    Dead: 3           │
│  Rate limit: 200/min          Unique jobs: 7 active locks            │
│                                                                      │
│  ┌─── Search ───────────────────────────────────────────────────┐    │
│  │ State: [All ▾]  Priority: [All ▾]  Tag: [tenant=acme ✕]     │    │
│  │                                                               │    │
│  │ Payload search: [user@example.com_____________]               │    │
│  │ jq filter:      [.template == "welcome"_______]               │    │
│  │ Error contains: [_____________________________]               │    │
│  │                                                               │    │
│  │ Created: [2026-02-10] → [2026-02-11]                         │    │
│  │                                             [Search] [Reset] │    │
│  └───────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  142 results (12ms)                [Select All] [Bulk: Retry ▾]     │
│  ┌──┬──────────────┬─────────┬────────┬─────────────┬────────────┐   │
│  │☐ │ Job ID       │ State   │Attempt │ Payload     │ Created    │   │
│  ├──┼──────────────┼─────────┼────────┼─────────────┼────────────┤   │
│  │☐ │ job_01HX7... │ ● dead  │  5/5   │ {to:"a@e..  │ 2m ago     │   │
│  │☑ │ job_01HX8... │ ● dead  │  5/5   │ {to:"b@e..  │ 5m ago     │   │
│  │☑ │ job_01HX9... │ ◌ pend  │  0/3   │ {to:"c@e..  │ 8m ago     │   │
│  │☐ │ job_01HXA... │ ● actv  │  2/5   │ {to:"d@e..  │ 12m ago    │   │
│  │☐ │ job_01HXB... │ ✓ done  │  1/3   │ {to:"e@e..  │ 15m ago    │   │
│  └──┴──────────────┴─────────┴────────┴─────────────┴────────────┘   │
│                                                                      │
│  ◀ 1 2 3 ... 12 ▶                                                   │
│                                                                      │
│  Bulk actions for 2 selected:                                        │
│  [Retry] [Delete] [Move to queue...] [Change priority...] [Cancel]  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Job detail view

```
┌──────────────────────────────────────────────────────────────────────┐
│  Job job_01HX7Y2K3MN...              [Retry] [Cancel] [Move] [Delete]│
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Queue:       emails.send                                            │
│  State:       ● active (attempt 2 of 5)                              │
│  Priority:    normal                                                 │
│  Worker:      worker-a1b2c3 on pod-xyz-1                             │
│  Created:     2026-02-11 10:00:00 UTC                                │
│  Started:     2026-02-11 10:00:01 UTC (1s queue time)                │
│  Unique key:  send-welcome-user@example.com                          │
│  Tags:        tenant:acme-corp                                       │
│  Batch:       batch_01... (2 of 3 complete)                          │
│                                                                      │
│  Progress     ████████████░░░░░░░░ 450/1000 "Sending batch"          │
│                                                                      │
│  Payload                                                             │
│  ┌──────────────────────────────────────────────────────────────────┐│
│  │ { "to": "user@example.com", "template": "welcome" }             ││
│  └──────────────────────────────────────────────────────────────────┘│
│                                                                      │
│  Attempt history                                                     │
│  ┌─────┬────────────┬──────────┬─────────────────────────────────┐   │
│  │ #   │ Started    │ Duration │ Result                          │   │
│  ├─────┼────────────┼──────────┼─────────────────────────────────┤   │
│  │ 1   │ 10:00:00   │ 4.2s     │ SMTP timeout                    │   │
│  │ 2   │ 10:00:10   │ ...      │ running                         │   │
│  └─────┴────────────┴──────────┴─────────────────────────────────┘   │
│                                                                      │
│  Timeline                                                            │
│  10:00:00.000  enqueued                                              │
│  10:00:00.124  started by worker-d4e5f6                              │
│  10:00:04.301  failed: SMTP connection timeout                       │
│  10:00:04.302  scheduled retry in 10s (exponential backoff)          │
│  10:00:14.302  started by worker-a1b2c3 (attempt 2)                 │
│  10:00:15.100  progress: 100/1000                                    │
│  10:00:16.200  progress: 450/1000                                    │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Move job dialog

```
┌─────────────────────────────────────────┐
│  Move job to queue                      │
│                                         │
│  Current queue: emails.send             │
│                                         │
│  Target queue:  [emails.legacy_____▾]   │
│                                         │
│  ☑ Reset attempt counter                │
│  ☐ Keep current priority                │
│                                         │
│  [Cancel]                       [Move]  │
└─────────────────────────────────────────┘
```

### Bulk operation confirmation dialog

```
┌──────────────────────────────────────────────────────┐
│  Bulk operation: Retry                               │
│                                                      │
│  This will retry 142 dead jobs in emails.send        │
│  matching: error contains "SMTP timeout"             │
│                                                      │
│  ⚠ This action cannot be undone.                     │
│                                                      │
│  Preview (first 5):                                  │
│  ┌────────────────┬───────────────────────────────┐  │
│  │ job_01HX7...   │ {to: "a@ex.com", ...}        │  │
│  │ job_01HX8...   │ {to: "b@ex.com", ...}        │  │
│  │ job_01HX9...   │ {to: "c@ex.com", ...}        │  │
│  │ job_01HXA...   │ {to: "d@ex.com", ...}        │  │
│  │ job_01HXB...   │ {to: "e@ex.com", ...}        │  │
│  └────────────────┴───────────────────────────────┘  │
│  ... and 137 more                                    │
│                                                      │
│  [Cancel]                           [Retry 142 jobs] │
└──────────────────────────────────────────────────────┘
```

### Bulk operation progress (for large operations)

```
┌──────────────────────────────────────────────────────┐
│  Bulk operation: Move to emails.v2                   │
│                                                      │
│  Progress  ██████████████░░░░░░ 71,204 / 142,000     │
│                                                      │
│  Elapsed: 12s    Remaining: ~6s    Rate: 5,934/s     │
│                                                      │
│  Errors: 3 (will be listed when complete)            │
│                                                      │
│  [Cancel operation]                                  │
└──────────────────────────────────────────────────────┘
```

---

## Client library contract

A Jobbie client library is a thin HTTP wrapper. It contains zero job lifecycle logic.

### What a client does

```
1. Make HTTP requests to Jobbie server
2. Parse JSON responses
3. Manage a pool of concurrent fetch loops (for concurrency)
4. Handle SIGTERM → stop fetching, wait for in-flight, fail remaining
5. Run heartbeat loop in background (single batched request every N seconds)
```

### What a client does NOT do

```
- Calculate retry backoff        → server does this
- Enforce unique jobs            → server does this
- Check rate limits              → server does this
- Know about priority tiers      → server does this
- Know about SQLite or Raft      → server does this
- Know about clustering          → server does this
- Know about batches             → server does this
```

### Example client: TypeScript (~150 lines of real logic)

```typescript
class JobbieWorker {
  private url: string;
  private queues: string[];
  private concurrency: number;
  private handlers: Map<string, Handler>;
  private activeJobs: Map<string, AbortController>;
  private draining: boolean = false;

  constructor(opts: { url: string; queues: string[]; concurrency?: number }) {
    this.url = opts.url;
    this.queues = opts.queues;
    this.concurrency = opts.concurrency ?? 10;
  }

  register(queue: string, handler: (job: Job, ctx: Context) => Promise<any>) {
    this.handlers.set(queue, handler);
  }

  async start() {
    // Start heartbeat loop (every 15s, batched for all active jobs)
    this.heartbeatLoop();

    // Start N concurrent fetch loops
    for (let i = 0; i < this.concurrency; i++) {
      this.fetchLoop();
    }

    // Handle SIGTERM
    process.on("SIGTERM", () => this.shutdown());
  }

  private async fetchLoop() {
    while (!this.draining) {
      const res = await fetch(`${this.url}/api/v1/fetch`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          queues: this.queues,
          worker_id: this.workerId,
          hostname: os.hostname(),
          timeout: 30,
        }),
      });

      if (res.status === 204) continue; // no jobs, retry
      const job = await res.json();

      try {
        const ctx = new Context(this, job);
        const result = await this.handlers.get(job.queue)(job, ctx);
        await this.ack(job.job_id, result);
      } catch (err) {
        await this.fail(job.job_id, err.message, err.stack);
      }
    }
  }

  private async ack(jobId: string, result: any) {
    await fetch(`${this.url}/api/v1/ack/${jobId}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ result }),
    });
  }

  private async fail(jobId: string, error: string, backtrace?: string) {
    await fetch(`${this.url}/api/v1/fail/${jobId}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ error, backtrace }),
    });
  }

  async shutdown() {
    this.draining = true;
    // Wait for in-flight jobs to finish (with timeout)
    // Fail any that don't finish in time
  }
}
```

### Example: enqueue a job with curl

```bash
curl -X POST http://localhost:8080/api/v1/enqueue \
  -H "Content-Type: application/json" \
  -d '{
    "queue": "emails.send",
    "payload": { "to": "user@example.com" },
    "unique_key": "welcome-user@example.com",
    "max_retries": 3
  }'
```

---

## Project structure

```
jobbie/
├── cmd/
│   └── jobbie/
│       └── main.go              # Entry point — server, CLI subcommands
├── internal/
│   ├── server/
│   │   ├── server.go            # HTTP server setup, middleware, routing
│   │   ├── handlers_worker.go   # enqueue, fetch, ack, fail, heartbeat
│   │   ├── handlers_manage.go   # queues, jobs, search, bulk operations
│   │   └── handlers_admin.go    # cluster status, metrics, events SSE
│   ├── store/
│   │   ├── store.go             # Store struct (Raft + SQLite integration)
│   │   ├── fsm.go               # Raft FSM: Apply, Snapshot, Restore
│   │   ├── schema.go            # SQLite schema + migrations
│   │   └── queries.go           # Job lifecycle SQL (enqueue, fetch, ack, etc.)
│   ├── cluster/
│   │   ├── raft.go              # Raft setup, bootstrap, join
│   │   ├── transport.go         # Raft transport over TCP
│   │   └── discovery.go         # DNS-based peer discovery for k8s
│   ├── scheduler/
│   │   └── scheduler.go         # Cron evaluation, delayed job promotion
│   ├── search/
│   │   └── builder.go           # Build SQL WHERE clauses from search filters
│   └── worker/
│       └── tracker.go           # Worker heartbeat tracking, lease management
├── pkg/
│   └── client/
│       └── client.go            # Go client library (thin HTTP wrapper)
├── clients/
│   ├── typescript/              # npm package — ~200 lines
│   ├── python/                  # pip package — ~200 lines
│   ├── rust/                    # crates.io package — ~200 lines
│   └── haskell/                 # Cabal package — ~200 lines
├── ui/                          # SPA (React/Solid/Svelte)
│   └── dist/                    # Built assets, embedded via go:embed
├── migrations/
│   └── 001_initial.sql          # SQLite schema
├── deploy/
│   ├── Dockerfile
│   ├── docker-compose.yml       # Single node quick start
│   ├── docker-compose-cluster.yml
│   └── helm/
│       └── jobbie/              # Helm chart (single node + clustered)
└── tests/
    ├── integration/             # Spin up real server + workers, test full lifecycle
    └── chaos/                   # Kill nodes, simulate failures, verify recovery
```

---

## Deployment

### Quick start (single binary)

```bash
# Download
curl -fsSL https://get.jobbie.dev | sh

# Start (embedded SQLite, serves UI on :8080)
jobbie server

# In another terminal — enqueue a job
curl -X POST http://localhost:8080/api/v1/enqueue \
  -H "Content-Type: application/json" \
  -d '{"queue": "test", "payload": {"hello": "world"}}'

# Run a worker (any language — this is curl for demo)
while true; do
  JOB=$(curl -s -X POST http://localhost:8080/api/v1/fetch \
    -H "Content-Type: application/json" \
    -d '{"queues": ["test"], "worker_id": "demo", "timeout": 30}')
  [ -z "$JOB" ] && continue
  JOB_ID=$(echo $JOB | jq -r .job_id)
  echo "Processing: $JOB"
  curl -s -X POST "http://localhost:8080/api/v1/ack/$JOB_ID" \
    -H "Content-Type: application/json" -d '{}'
done
```

### Docker

```bash
docker run -d -p 8080:8080 -v jobbie-data:/data jobbie/jobbie
```

### Docker Compose (clustered)

```yaml
services:
  jobbie-0:
    image: jobbie/jobbie
    command: server --cluster --peers jobbie-1:9400,jobbie-2:9400
    ports: ["8080:8080"]
    volumes: ["jobbie-0-data:/data"]

  jobbie-1:
    image: jobbie/jobbie
    command: server --cluster --peers jobbie-0:9400,jobbie-2:9400
    volumes: ["jobbie-1-data:/data"]

  jobbie-2:
    image: jobbie/jobbie
    command: server --cluster --peers jobbie-0:9400,jobbie-1:9400
    volumes: ["jobbie-2-data:/data"]

volumes:
  jobbie-0-data:
  jobbie-1-data:
  jobbie-2-data:
```

### Kubernetes (clustered, automatic discovery)

```bash
helm install jobbie jobbie/jobbie --set cluster.enabled=true --set replicas=3
```

---

## Paid service (Jobbie Cloud)

The OSS version is fully functional — every feature described above is free.

The paid Cloud offering adds operational convenience and enterprise requirements:

- **Fully managed** — no infrastructure to run, no servers to think about
- **Multi-tenant isolation** — namespace per team/environment
- **SSO / RBAC** — who can enqueue, who can view, who can retry/cancel
- **Webhooks** — call your URL on job complete/fail/dead
- **Alerting** — built-in rules (queue depth > N, dead jobs > N, worker count < N)
- **Extended retention** — longer job history, full-text search
- **Encryption at rest** — job payloads encrypted
- **Audit log** — who did what, when
- **SLA** — uptime guarantees
- **Support** — dedicated support channel

The boundary is clear: **OSS handles all job processing features. Cloud handles the ops you don't want to do.**

---

## What Jobbie is NOT

- **Not a workflow engine** — no DAGs, no step-by-step orchestration, no replay. If you need sagas or multi-step workflows, use Temporal. Jobbie does one job at a time, well.
- **Not a cron replacement** — it has cron support, but it's for recurring jobs that go through the job lifecycle (retries, monitoring, etc.), not arbitrary shell commands.
- **Not a message broker** — it's a job queue. Jobs are processed exactly once. If you need pub/sub or event streaming, use NATS/Kafka/etc.

---

## Implementation plan

### Phase 1 — Core (MVP)

- [ ] Go project scaffold (`cmd/jobbie`, `internal/server`, `internal/store`, etc.)
- [ ] SQLite schema + migrations (mattn/go-sqlite3, WAL mode)
- [ ] Raft FSM integration (hashicorp/raft, ~600 lines: Apply, Snapshot, Restore)
- [ ] Store layer (writes through Raft, reads from local SQLite)
- [ ] HTTP API: enqueue, enqueue/batch, fetch, ack, fail, heartbeat
- [ ] Job lifecycle: pending → active → completed/failed/dead
- [ ] Retries with configurable backoff (none, fixed, linear, exponential)
- [ ] Priority (3 tiers via `ORDER BY priority ASC, created_at ASC`)
- [ ] Unique jobs (unique_locks table + SQL transactions)
- [ ] Dead letter queue
- [ ] Lease management + automatic reclamation
- [ ] Scheduler: delayed job promotion + lease expiry sweep
- [ ] Queue management: pause, resume, clear, drain, delete
- [ ] Job operations: cancel, delete, move to queue
- [ ] Search API: full SQL-backed filter (queue, state, tags, timestamps, json_extract, payload_contains, etc.)
- [ ] Bulk operations API: retry, delete, cancel, move, requeue, change_priority (by IDs + by filter)
- [ ] Graceful shutdown (SIGTERM handling)
- [ ] Web UI: dashboard, queue detail with search/filter, job detail, bulk actions
- [ ] CLI: full management commands + search + piped bulk operations
- [ ] TypeScript client library
- [ ] Go client library (in `pkg/client/`)
- [ ] Docker image
- [ ] Integration tests

### Phase 2 — Production ready

- [ ] payload_jq filter (translate jq subset to json_extract queries)
- [ ] Async bulk operations (>10k jobs — background processing with progress SSE)
- [ ] Cron jobs with leader-only execution
- [ ] Checkpointing API for long-running jobs
- [ ] Progress reporting
- [ ] Cancellation (pending + active via heartbeat)
- [ ] Concurrency control (per-worker + per-queue / singleton queues)
- [ ] Rate limiting / throttling (sliding window via rate_limit_window table)
- [ ] Batches with completion callbacks
- [ ] Job expiration (TTL)
- [ ] Real-time UI updates via SSE
- [ ] Prometheus metrics endpoint
- [ ] Python client library
- [ ] Helm chart (single node)

### Phase 3 — Clustering + Ecosystem

- [ ] Multi-node Raft clustering (bootstrap, join, remove)
- [ ] Write proxying (follower → Raft leader)
- [ ] Automatic failover + rejoin
- [ ] Raft snapshots + log compaction
- [ ] DNS-based peer discovery for Kubernetes
- [ ] Helm chart (clustered StatefulSet)
- [ ] Webhooks on job lifecycle events
- [ ] Job dependencies (job B waits for job A)
- [ ] UI: cluster status view, Raft log monitoring
- [ ] Rust client library
- [ ] Haskell client library
- [ ] OpenTelemetry integration (trace job from enqueue to complete)
- [ ] Chaos tests (kill nodes, verify recovery)

### Phase 4 — Cloud

- [ ] Multi-tenancy and namespaces
- [ ] Auth (API keys, SSO)
- [ ] RBAC (per-queue permissions)
- [ ] Managed infrastructure
- [ ] Billing and usage metering
- [ ] Audit logging
- [ ] Extended retention + full-text search (SQLite FTS5)
- [ ] Terraform provider
