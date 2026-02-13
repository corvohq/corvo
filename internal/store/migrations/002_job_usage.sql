CREATE TABLE IF NOT EXISTS job_usage (
    id                     INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id                 TEXT NOT NULL,
    queue                  TEXT,
    attempt                INTEGER,
    phase                  TEXT NOT NULL DEFAULT 'ack',
    input_tokens           INTEGER NOT NULL DEFAULT 0,
    output_tokens          INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens  INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens      INTEGER NOT NULL DEFAULT 0,
    model                  TEXT,
    provider               TEXT,
    cost_usd               REAL NOT NULL DEFAULT 0,
    created_at             TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_job_usage_job ON job_usage(job_id);
CREATE INDEX IF NOT EXISTS idx_job_usage_provider ON job_usage(provider, created_at);
CREATE INDEX IF NOT EXISTS idx_job_usage_model ON job_usage(model, created_at);
CREATE INDEX IF NOT EXISTS idx_job_usage_queue ON job_usage(queue, created_at);
