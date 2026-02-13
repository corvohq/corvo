ALTER TABLE jobs ADD COLUMN agent_max_iterations INTEGER;
ALTER TABLE jobs ADD COLUMN agent_max_cost_usd REAL;
ALTER TABLE jobs ADD COLUMN agent_iteration_timeout TEXT;
ALTER TABLE jobs ADD COLUMN agent_iteration INTEGER NOT NULL DEFAULT 0;
ALTER TABLE jobs ADD COLUMN agent_total_cost_usd REAL NOT NULL DEFAULT 0;
ALTER TABLE jobs ADD COLUMN hold_reason TEXT;

CREATE TABLE IF NOT EXISTS job_iterations (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id                TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    iteration             INTEGER NOT NULL,
    status                TEXT NOT NULL,
    checkpoint            TEXT,
    hold_reason           TEXT,
    result                TEXT,
    input_tokens          INTEGER NOT NULL DEFAULT 0,
    output_tokens         INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
    model                 TEXT,
    provider              TEXT,
    cost_usd              REAL NOT NULL DEFAULT 0,
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_job_iterations_job ON job_iterations(job_id, iteration);
