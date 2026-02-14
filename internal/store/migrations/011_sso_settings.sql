CREATE TABLE IF NOT EXISTS sso_settings (
    id              TEXT PRIMARY KEY DEFAULT 'singleton',
    provider        TEXT NOT NULL DEFAULT '',
    oidc_issuer_url TEXT NOT NULL DEFAULT '',
    oidc_client_id  TEXT NOT NULL DEFAULT '',
    saml_enabled    INTEGER NOT NULL DEFAULT 0,
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
INSERT OR IGNORE INTO sso_settings (id) VALUES ('singleton');
