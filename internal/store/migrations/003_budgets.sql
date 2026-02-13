CREATE TABLE IF NOT EXISTS budgets (
    id          TEXT PRIMARY KEY,
    scope       TEXT NOT NULL,                -- 'queue', 'tag', 'global'
    target      TEXT NOT NULL,                -- queue name, 'tenant:acme', '*'
    daily_usd   REAL,
    per_job_usd REAL,
    on_exceed   TEXT NOT NULL DEFAULT 'hold', -- 'hold', 'reject', 'alert_only'
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_budgets_scope ON budgets(scope, target);
CREATE INDEX IF NOT EXISTS idx_budgets_target ON budgets(target);
