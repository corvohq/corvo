CREATE TABLE IF NOT EXISTS approval_policies (
    id               TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    mode             TEXT NOT NULL DEFAULT 'any',
    enabled          INTEGER NOT NULL DEFAULT 1,
    queue            TEXT,
    tag_key          TEXT,
    tag_value        TEXT,
    trace_action_in  TEXT,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_approval_policies_enabled ON approval_policies(enabled);
