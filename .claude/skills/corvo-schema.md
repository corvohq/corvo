# Corvo Schema Reference

## Pebble Key Layout

All keys use `|` as prefix separator and `\x00` as internal separator. Numeric fields are big-endian for lexicographic = numeric ordering.

### Prefix Constants (`internal/kv/keys.go`)

```
j|    → job document (msgpack)
je|   → job error record
p|    → priority-indexed pending set
a|    → active set
s|    → scheduled set
r|    → retrying set
qa|   → append log (normal-priority FIFO)
qac|  → append log cursor
qc|   → queue config (JSON)
qn|   → queue name registry
u|    → unique lock
l|    → rate limit window entry
b|    → batch counter
w|    → worker doc
sc|   → cron schedule
ev|   → event log entry
evc|  → event log cursor (singleton)
bg|   → budget config
pv|   → provider config
qp|   → queue-provider mapping
```

### Key Formats

| Function | Key Format | Value |
|----------|-----------|-------|
| `JobKey(jobID)` | `j\|{jobID}` | msgpack-encoded job doc |
| `JobErrorKey(jobID, attempt)` | `je\|{jobID}\x00{attempt:4BE}` | error JSON |
| `PendingKey(queue, priority, createdNs, jobID)` | `p\|{queue}\x00{priority:1B}{createdNs:8BE}{jobID}` | nil |
| `ActiveKey(queue, jobID)` | `a\|{queue}\x00{jobID}` | `{leaseExpiresNs:8BE}` |
| `ScheduledKey(queue, scheduledNs, jobID)` | `s\|{queue}\x00{scheduledNs:8BE}{jobID}` | nil |
| `RetryingKey(queue, retryNs, jobID)` | `r\|{queue}\x00{retryNs:8BE}{jobID}` | nil |
| `QueueAppendKey(queue, createdNs, jobID)` | `qa\|{queue}\x00{createdNs:8BE}{jobID}` | nil |
| `QueueCursorKey(queue)` | `qac\|{queue}` | last consumed `qa\|` key bytes |
| `QueueConfigKey(queue)` | `qc\|{queue}` | JSON: `{paused, max_concurrency, ...}` |
| `QueueNameKey(queue)` | `qn\|{queue}` | nil (presence key) |
| `UniqueKey(queue, uniqueKey)` | `u\|{queue}\x00{uniqueKey}` | `{jobID}\|{expiresNs:8BE}` |
| `RateLimitKey(queue, fetchedNs, random)` | `l\|{queue}\x00{fetchedNs:8BE}{random:8BE}` | nil |
| `BatchKey(batchID)` | `b\|{batchID}` | JSON batch counter |
| `WorkerKey(workerID)` | `w\|{workerID}` | JSON worker doc |
| `ScheduleKey(scheduleID)` | `sc\|{scheduleID}` | JSON schedule config |
| `EventLogKey(seq)` | `ev\|{seq:8BE}` | JSON event |
| `EventCursorKey()` | `evc\|` | `{seq:8BE}` |
| `BudgetKey(scope, target)` | `bg\|{scope}\x00{target}` | JSON budget config |
| `ProviderKey(name)` | `pv\|{name}` | JSON provider config |
| `QueueProviderKey(queue)` | `qp\|{queue}` | provider name string |

### Prefix Scan Functions

| Function | Returns | Use |
|----------|---------|-----|
| `PendingPrefix(queue)` | `p\|{queue}\x00` | Fetch: scan for highest-priority job |
| `ActivePrefix(queue)` | `a\|{queue}\x00` | Reclaim: scan for expired leases |
| `ScheduledScanPrefix(queue)` | `s\|{queue}\x00` | Promote: scan for ready scheduled jobs |
| `RetryingScanPrefix(queue)` | `r\|{queue}\x00` | Promote: scan for ready retrying jobs |
| `QueueAppendPrefix(queue)` | `qa\|{queue}\x00` | Fetch: FIFO scan for normal-priority |
| `JobErrorPrefix(jobID)` | `je\|{jobID}\x00` | Get all errors for a job |
| `UniquePrefix(queue)` | `u\|{queue}\x00` | Clean: scan expired unique locks |
| `RateLimitPrefix(queue)` | `l\|{queue}\x00` | Rate limit window scan |
| `EventLogPrefix()` | `ev\|` | Scan all events |
| `BudgetPrefix()` | `bg\|` | Scan all budgets |
| `ProviderPrefix()` | `pv\|` | Scan all providers |

### Encoding Helpers (`internal/kv/encoding.go`)

```go
PutUint8(dst []byte, v uint8) []byte       // append 1 byte
PutUint32BE(dst []byte, v uint32) []byte    // append 4 bytes big-endian
PutUint64BE(dst []byte, v uint64) []byte    // append 8 bytes big-endian
GetUint32BE(b []byte) uint32                // read 4 bytes big-endian
GetUint64BE(b []byte) uint64                // read 8 bytes big-endian
```

### Priority Values
Single `uint8` byte. Lower = higher priority (fetched first in byte-order scan):
- `0` = critical
- `1` = high
- `2` = normal (default — uses append log `qa|` instead of `p|`)

### Append Log vs Priority Queue
- **Normal priority (2):** goes to `qa|` — pure FIFO, cursor-based scan
- **High/Critical (0-1):** goes to `p|` — sorted by `(priority, createdNs, jobID)`

Fetch checks `p|` first, then falls back to `qa|`.

### Unique Key Value Encoding
`EncodeUniqueValue(jobID, expiresNs)` → `{jobID}|{expiresNs:8BE}`

Decoded by scanning backward 9 bytes (8-byte timestamp + `|` separator).

---

## SQLite Materialized View Schema

Source: `internal/raft/cluster.go` `materializedViewSchema`

### Core Tables

```sql
CREATE TABLE jobs (
    id                    TEXT PRIMARY KEY,
    queue                 TEXT NOT NULL,
    state                 TEXT NOT NULL DEFAULT 'pending',
    payload               TEXT NOT NULL,
    priority              INTEGER NOT NULL DEFAULT 2,
    attempt               INTEGER NOT NULL DEFAULT 0,
    max_retries           INTEGER NOT NULL DEFAULT 3,
    retry_backoff         TEXT NOT NULL DEFAULT 'exponential',
    retry_base_delay_ms   INTEGER NOT NULL DEFAULT 5000,
    retry_max_delay_ms    INTEGER NOT NULL DEFAULT 600000,
    unique_key            TEXT,
    batch_id              TEXT,
    worker_id             TEXT,
    hostname              TEXT,
    tags                  TEXT,        -- JSON object
    progress              TEXT,        -- JSON: {current, total, message}
    checkpoint            TEXT,        -- JSON blob
    result                TEXT,        -- JSON blob
    result_schema         TEXT,
    parent_id             TEXT REFERENCES jobs(id),
    chain_id              TEXT,
    chain_step            INTEGER,
    chain_config          TEXT,        -- JSON: {steps, on_failure, on_exit}
    provider_error        INTEGER NOT NULL DEFAULT 0,
    routing               TEXT,
    routing_target        TEXT,
    routing_index         INTEGER NOT NULL DEFAULT 0,
    agent_max_iterations  INTEGER,
    agent_max_cost_usd    REAL,
    agent_iteration_timeout TEXT,
    agent_iteration       INTEGER NOT NULL DEFAULT 0,
    agent_total_cost_usd  REAL NOT NULL DEFAULT 0,
    hold_reason           TEXT,
    lease_expires_at      TEXT,        -- RFC3339
    scheduled_at          TEXT,        -- RFC3339
    expire_at             TEXT,        -- RFC3339
    created_at            TEXT NOT NULL,
    started_at            TEXT,
    completed_at          TEXT,
    failed_at             TEXT
);

-- Key indexes
CREATE INDEX idx_jobs_queue_state_priority ON jobs(queue, state, priority, created_at);
CREATE INDEX idx_jobs_state ON jobs(state);
CREATE INDEX idx_jobs_scheduled ON jobs(state, scheduled_at) WHERE state IN ('scheduled','retrying');
CREATE INDEX idx_jobs_lease ON jobs(state, lease_expires_at) WHERE state = 'active';
CREATE INDEX idx_jobs_unique ON jobs(queue, unique_key) WHERE unique_key IS NOT NULL;
CREATE INDEX idx_jobs_batch ON jobs(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX idx_jobs_expire ON jobs(expire_at) WHERE expire_at IS NOT NULL;
CREATE INDEX idx_jobs_created ON jobs(created_at);
```

```sql
CREATE TABLE job_errors (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    attempt    INTEGER NOT NULL,
    error      TEXT NOT NULL,
    backtrace  TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE unique_locks (
    queue      TEXT NOT NULL,
    unique_key TEXT NOT NULL,
    job_id     TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    PRIMARY KEY (queue, unique_key)
);

CREATE TABLE batches (
    id               TEXT PRIMARY KEY,
    total            INTEGER NOT NULL,
    pending          INTEGER NOT NULL,
    succeeded        INTEGER NOT NULL DEFAULT 0,
    failed           INTEGER NOT NULL DEFAULT 0,
    callback_queue   TEXT,
    callback_payload TEXT,
    created_at       TEXT NOT NULL
);

CREATE TABLE queues (
    name            TEXT PRIMARY KEY,
    paused          INTEGER NOT NULL DEFAULT 0,
    max_concurrency INTEGER,
    rate_limit      INTEGER,
    rate_window_ms  INTEGER,
    provider        TEXT REFERENCES providers(name),
    created_at      TEXT NOT NULL
);

CREATE TABLE workers (
    id             TEXT PRIMARY KEY,
    hostname       TEXT,
    queues         TEXT,
    last_heartbeat TEXT NOT NULL,
    started_at     TEXT NOT NULL
);

CREATE TABLE schedules (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    queue       TEXT NOT NULL,
    cron        TEXT NOT NULL,
    timezone    TEXT NOT NULL DEFAULT 'UTC',
    payload     TEXT NOT NULL,
    unique_key  TEXT,
    max_retries INTEGER NOT NULL DEFAULT 3,
    last_run    TEXT,
    next_run    TEXT,
    created_at  TEXT NOT NULL
);
```

### AI / Agent Tables

```sql
CREATE TABLE job_usage (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id                TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    queue                 TEXT NOT NULL,
    attempt               INTEGER NOT NULL,
    phase                 TEXT NOT NULL,
    input_tokens          INTEGER NOT NULL DEFAULT 0,
    output_tokens         INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
    model                 TEXT,
    provider              TEXT,
    cost_usd              REAL NOT NULL DEFAULT 0,
    created_at            TEXT NOT NULL
);

CREATE TABLE budgets (
    id          TEXT PRIMARY KEY,
    scope       TEXT NOT NULL,
    target      TEXT NOT NULL,
    daily_usd   REAL,
    per_job_usd REAL,
    on_exceed   TEXT NOT NULL DEFAULT 'hold',
    created_at  TEXT NOT NULL
);

CREATE TABLE job_iterations (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id                TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    iteration             INTEGER NOT NULL,
    status                TEXT NOT NULL,
    checkpoint            TEXT,
    trace                 TEXT,
    hold_reason           TEXT,
    result                TEXT,
    input_tokens          INTEGER NOT NULL DEFAULT 0,
    output_tokens         INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
    model                 TEXT,
    provider              TEXT,
    cost_usd              REAL NOT NULL DEFAULT 0,
    created_at            TEXT NOT NULL
);

CREATE TABLE job_scores (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    dimension  TEXT NOT NULL,
    value      REAL NOT NULL,
    scorer     TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE providers (
    name             TEXT PRIMARY KEY,
    rpm_limit        INTEGER,
    input_tpm_limit  INTEGER,
    output_tpm_limit INTEGER,
    created_at       TEXT NOT NULL
);

CREATE TABLE approval_policies (
    id       TEXT PRIMARY KEY,
    name     TEXT NOT NULL,
    mode     TEXT NOT NULL DEFAULT 'any',
    enabled  INTEGER NOT NULL DEFAULT 1,
    queue    TEXT,
    tag_key  TEXT,
    tag_value TEXT,
    created_at TEXT NOT NULL
);

CREATE TABLE webhooks (
    id               TEXT PRIMARY KEY,
    url              TEXT NOT NULL,
    events           TEXT NOT NULL,
    secret           TEXT,
    enabled          INTEGER NOT NULL DEFAULT 1,
    retry_limit      INTEGER NOT NULL DEFAULT 3,
    created_at       TEXT NOT NULL,
    last_status_code INTEGER,
    last_error       TEXT,
    last_delivery_at TEXT
);
```

### Enterprise Tables

```sql
CREATE TABLE api_keys (
    key_hash     TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    namespace    TEXT NOT NULL DEFAULT 'default',
    role         TEXT NOT NULL DEFAULT 'readonly',
    queue_scope  TEXT,
    enabled      INTEGER NOT NULL DEFAULT 1,
    expires_at   TEXT,
    created_at   TEXT NOT NULL,
    last_used_at TEXT
);

CREATE TABLE auth_roles (
    name        TEXT PRIMARY KEY,
    permissions TEXT NOT NULL,   -- JSON
    created_at  TEXT NOT NULL,
    updated_at  TEXT
);

CREATE TABLE auth_key_roles (
    key_hash   TEXT NOT NULL,
    role_name  TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY(key_hash, role_name)
);

CREATE TABLE audit_logs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    namespace   TEXT NOT NULL DEFAULT 'default',
    principal   TEXT,
    role        TEXT,
    method      TEXT NOT NULL,
    path        TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    metadata    TEXT,
    created_at  TEXT NOT NULL
);

CREATE TABLE namespaces (
    name       TEXT PRIMARY KEY,
    created_at TEXT NOT NULL
);
-- Pre-seeded: INSERT OR IGNORE INTO namespaces (name) VALUES ('default');

CREATE TABLE sso_settings (
    id                  TEXT PRIMARY KEY DEFAULT 'singleton',
    provider            TEXT NOT NULL DEFAULT '',
    oidc_issuer_url     TEXT NOT NULL DEFAULT '',
    oidc_client_id      TEXT NOT NULL DEFAULT '',
    saml_enabled        INTEGER NOT NULL DEFAULT 0,
    oidc_group_claim    TEXT NOT NULL DEFAULT 'groups',
    group_role_mappings TEXT NOT NULL DEFAULT '{}',
    updated_at          TEXT NOT NULL
);
-- Pre-seeded: INSERT OR IGNORE INTO sso_settings (id) VALUES ('singleton');
```

### FTS5 (Full-Text Search)
```sql
CREATE VIRTUAL TABLE jobs_fts USING fts5(id, queue, payload, tags, content=jobs);
-- Maintained via triggers on jobs INSERT/UPDATE/DELETE
-- Falls back to jobs_search table if FTS5 unavailable
```

### SQLite Settings
```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = OFF;      -- Pebble is source of truth
PRAGMA foreign_keys = ON;
```
