-- Core job table
CREATE TABLE jobs (
    id              TEXT PRIMARY KEY,
    queue           TEXT NOT NULL,
    state           TEXT NOT NULL DEFAULT 'pending',
    payload         TEXT NOT NULL,
    priority        INTEGER NOT NULL DEFAULT 2,
    attempt         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    retry_backoff   TEXT NOT NULL DEFAULT 'exponential',
    retry_base_delay_ms INTEGER NOT NULL DEFAULT 5000,
    retry_max_delay_ms  INTEGER NOT NULL DEFAULT 600000,
    unique_key      TEXT,
    batch_id        TEXT,
    worker_id       TEXT,
    hostname        TEXT,
    tags            TEXT,
    progress        TEXT,
    checkpoint      TEXT,
    result          TEXT,
    lease_expires_at TEXT,
    scheduled_at    TEXT,
    expire_at       TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    started_at      TEXT,
    completed_at    TEXT,
    failed_at       TEXT
);

CREATE INDEX idx_jobs_queue_state_priority ON jobs(queue, state, priority, created_at);
CREATE INDEX idx_jobs_state ON jobs(state);
CREATE INDEX idx_jobs_scheduled ON jobs(state, scheduled_at) WHERE state IN ('scheduled', 'retrying');
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
    callback_payload TEXT,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

-- Queue configuration
CREATE TABLE queues (
    name            TEXT PRIMARY KEY,
    paused          INTEGER NOT NULL DEFAULT 0,
    max_concurrency INTEGER,
    rate_limit      INTEGER,
    rate_window_ms  INTEGER,
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
    payload    TEXT NOT NULL,
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
    queues          TEXT,
    last_heartbeat  TEXT NOT NULL,
    started_at      TEXT NOT NULL
);

-- Event log
CREATE TABLE events (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    type       TEXT NOT NULL,
    job_id     TEXT,
    queue      TEXT,
    data       TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX idx_events_created ON events(created_at);

-- Queue stats
CREATE TABLE queue_stats (
    queue      TEXT PRIMARY KEY,
    enqueued   INTEGER NOT NULL DEFAULT 0,
    completed  INTEGER NOT NULL DEFAULT 0,
    failed     INTEGER NOT NULL DEFAULT 0,
    dead       INTEGER NOT NULL DEFAULT 0
);