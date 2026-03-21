//! SQLite materialized view schema — DDL for the mirror database.
//!
//! Ported from Go internal/sqlite/db.go materializedViewSchema.
//! Covers core tables: jobs, job_errors, queues, workers, batches,
//! crons, budgets. Enterprise tables (SSO, audit, etc.) omitted for now.

const sqlite = @import("sqlite.zig");

/// Create all tables and indexes. Idempotent (uses IF NOT EXISTS).
pub fn createSchema(db: *sqlite.DB) !void {
    try db.execMulti(ddl);
}

const ddl =
    \\-- ============================================================
    \\-- Jobs
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS jobs (
    \\    id TEXT PRIMARY KEY,
    \\    queue TEXT NOT NULL,
    \\    state TEXT NOT NULL DEFAULT 'pending',
    \\    priority INTEGER NOT NULL DEFAULT 2,
    \\    attempt INTEGER NOT NULL DEFAULT 0,
    \\    max_retries INTEGER NOT NULL DEFAULT 0,
    \\    retry_backoff TEXT NOT NULL DEFAULT 'none',
    \\    retry_base_delay_ms INTEGER NOT NULL DEFAULT 0,
    \\    retry_max_delay_ms INTEGER NOT NULL DEFAULT 0,
    \\    unique_key TEXT,
    \\    unique_period_s INTEGER NOT NULL DEFAULT 0,
    \\    batch_id TEXT,
    \\    worker_id TEXT,
    \\    hostname TEXT,
    \\    tags TEXT,
    \\    progress TEXT,
    \\    checkpoint TEXT,
    \\    result TEXT,
    \\    parent_id TEXT,
    \\    chain_id TEXT,
    \\    chain_step INTEGER NOT NULL DEFAULT 0,
    \\    chain_config TEXT,
    \\    group_key TEXT,
    \\    hold_reason TEXT,
    \\    error_msg TEXT,
    \\    lease_expires_at TEXT,
    \\    scheduled_at TEXT,
    \\    expire_at TEXT,
    \\    created_at TEXT,
    \\    started_at TEXT,
    \\    completed_at TEXT,
    \\    failed_at TEXT
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_jobs_queue_state_priority
    \\    ON jobs (queue, state, priority);
    \\CREATE INDEX IF NOT EXISTS idx_jobs_state
    \\    ON jobs (state);
    \\CREATE INDEX IF NOT EXISTS idx_jobs_scheduled
    \\    ON jobs (scheduled_at) WHERE state = 'scheduled';
    \\CREATE INDEX IF NOT EXISTS idx_jobs_lease
    \\    ON jobs (lease_expires_at) WHERE state = 'active';
    \\CREATE INDEX IF NOT EXISTS idx_jobs_unique
    \\    ON jobs (queue, unique_key) WHERE unique_key IS NOT NULL;
    \\CREATE INDEX IF NOT EXISTS idx_jobs_batch
    \\    ON jobs (batch_id) WHERE batch_id IS NOT NULL;
    \\CREATE INDEX IF NOT EXISTS idx_jobs_expire
    \\    ON jobs (expire_at) WHERE expire_at IS NOT NULL;
    \\CREATE INDEX IF NOT EXISTS idx_jobs_created
    \\    ON jobs (created_at);
    \\CREATE INDEX IF NOT EXISTS idx_jobs_parent
    \\    ON jobs (parent_id) WHERE parent_id IS NOT NULL;
    \\CREATE INDEX IF NOT EXISTS idx_jobs_chain
    \\    ON jobs (chain_id) WHERE chain_id IS NOT NULL;
    \\
    \\-- ============================================================
    \\-- Job payloads (raw payload blob, separate from job metadata)
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS job_payloads (
    \\    job_id TEXT PRIMARY KEY REFERENCES jobs(id) ON DELETE CASCADE,
    \\    payload BLOB
    \\);
    \\
    \\-- ============================================================
    \\-- FTS5 full-text search (contentless, write-once)
    \\-- ============================================================
    \\CREATE VIRTUAL TABLE IF NOT EXISTS jobs_fts USING fts5(
    \\    job_id UNINDEXED, payload, content='', tokenize='unicode61'
    \\);
    \\
    \\-- ============================================================
    \\-- Job errors
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS job_errors (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    job_id TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    \\    attempt INTEGER NOT NULL,
    \\    error TEXT,
    \\    backtrace TEXT,
    \\    created_at TEXT NOT NULL
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_job_errors_job
    \\    ON job_errors (job_id);
    \\
    \\-- ============================================================
    \\-- Queues
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS queues (
    \\    name TEXT PRIMARY KEY,
    \\    paused INTEGER NOT NULL DEFAULT 0,
    \\    max_concurrency INTEGER,
    \\    rate_limit INTEGER,
    \\    rate_window_ms INTEGER,
    \\    created_at TEXT
    \\);
    \\
    \\-- ============================================================
    \\-- Workers
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS workers (
    \\    id TEXT PRIMARY KEY,
    \\    hostname TEXT,
    \\    queues TEXT,
    \\    last_heartbeat TEXT,
    \\    started_at TEXT
    \\);
    \\
    \\-- ============================================================
    \\-- Batches
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS batches (
    \\    id TEXT PRIMARY KEY,
    \\    open INTEGER NOT NULL DEFAULT 0,
    \\    total INTEGER NOT NULL DEFAULT 0,
    \\    pending INTEGER NOT NULL DEFAULT 0,
    \\    succeeded INTEGER NOT NULL DEFAULT 0,
    \\    failed INTEGER NOT NULL DEFAULT 0,
    \\    callback_queue TEXT,
    \\    callback_payload TEXT,
    \\    created_at TEXT
    \\);
    \\
    \\-- ============================================================
    \\-- Crons
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS crons (
    \\    id TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    queue TEXT NOT NULL,
    \\    schedule TEXT NOT NULL,
    \\    timezone TEXT NOT NULL DEFAULT 'UTC',
    \\    payload TEXT,
    \\    unique_key TEXT,
    \\    max_retries INTEGER NOT NULL DEFAULT 0,
    \\    enabled INTEGER NOT NULL DEFAULT 1,
    \\    next_run_at TEXT,
    \\    last_run_at TEXT,
    \\    created_at TEXT
    \\);
    \\
    \\-- ============================================================
    \\-- Budgets
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS budgets (
    \\    id TEXT PRIMARY KEY,
    \\    scope TEXT NOT NULL,
    \\    target TEXT NOT NULL,
    \\    daily_usd REAL NOT NULL DEFAULT 0,
    \\    per_job_usd REAL NOT NULL DEFAULT 0,
    \\    on_exceed TEXT NOT NULL DEFAULT 'hold',
    \\    created_at TEXT
    \\);
    \\
    \\CREATE UNIQUE INDEX IF NOT EXISTS idx_budgets_scope_target
    \\    ON budgets (scope, target);
    \\
    \\-- ============================================================
    \\-- API Keys
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS api_keys (
    \\    key_hash TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    role TEXT NOT NULL DEFAULT 'admin',
    \\    enabled INTEGER NOT NULL DEFAULT 1,
    \\    expires_at TEXT,
    \\    created_at TEXT NOT NULL
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_api_keys_enabled
    \\    ON api_keys (enabled);
    \\
    \\-- ============================================================
    \\-- Approval Policies
    \\-- ============================================================
    \\CREATE TABLE IF NOT EXISTS approval_policies (
    \\    id TEXT PRIMARY KEY,
    \\    name TEXT NOT NULL,
    \\    mode TEXT NOT NULL DEFAULT 'any',
    \\    enabled INTEGER NOT NULL DEFAULT 1,
    \\    queue TEXT,
    \\    tag_key TEXT,
    \\    tag_value TEXT,
    \\    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_approval_policies_enabled
    \\    ON approval_policies (enabled);
;
