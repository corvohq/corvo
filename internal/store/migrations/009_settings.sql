-- Organization settings
CREATE TABLE IF NOT EXISTS orgs (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL DEFAULT 'My Organization',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

INSERT OR IGNORE INTO orgs (id, name) VALUES ('org_default', 'My Organization');

-- Users with role for team management
CREATE TABLE IF NOT EXISTS users (
    id         TEXT PRIMARY KEY,
    org_id     TEXT NOT NULL DEFAULT 'org_default',
    name       TEXT NOT NULL,
    email      TEXT NOT NULL,
    role       TEXT NOT NULL DEFAULT 'member',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

-- Settings API keys (separate from auth api_keys)
CREATE TABLE IF NOT EXISTS org_api_keys (
    id         TEXT PRIMARY KEY,
    org_id     TEXT NOT NULL DEFAULT 'org_default',
    name       TEXT NOT NULL,
    prefix     TEXT NOT NULL,
    key_hash   TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
