CREATE TABLE IF NOT EXISTS namespaces (
    name       TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
INSERT OR IGNORE INTO namespaces (name) VALUES ('default');
