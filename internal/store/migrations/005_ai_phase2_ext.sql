ALTER TABLE jobs ADD COLUMN result_schema TEXT;
ALTER TABLE jobs ADD COLUMN parent_id TEXT REFERENCES jobs(id);
ALTER TABLE jobs ADD COLUMN provider_error INTEGER NOT NULL DEFAULT 0;
ALTER TABLE jobs ADD COLUMN chain_config TEXT;
ALTER TABLE jobs ADD COLUMN chain_id TEXT;
ALTER TABLE jobs ADD COLUMN chain_step INTEGER;

CREATE INDEX IF NOT EXISTS idx_jobs_parent ON jobs(parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jobs_chain ON jobs(chain_id) WHERE chain_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jobs_provider_error ON jobs(provider_error) WHERE provider_error = 1;

CREATE TABLE IF NOT EXISTS job_scores (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    dimension  TEXT NOT NULL,
    value      REAL NOT NULL,
    scorer     TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_job_scores_job ON job_scores(job_id);
CREATE INDEX IF NOT EXISTS idx_job_scores_dimension ON job_scores(dimension, created_at);

CREATE TABLE IF NOT EXISTS providers (
    name             TEXT PRIMARY KEY,
    rpm_limit        INTEGER,
    input_tpm_limit  INTEGER,
    output_tpm_limit INTEGER,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
ALTER TABLE queues ADD COLUMN provider TEXT REFERENCES providers(name);
CREATE TABLE IF NOT EXISTS provider_usage_window (
    provider      TEXT NOT NULL,
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    recorded_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_provider_usage ON provider_usage_window(provider, recorded_at);
