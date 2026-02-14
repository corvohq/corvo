ALTER TABLE sso_settings ADD COLUMN oidc_group_claim TEXT NOT NULL DEFAULT 'groups';
ALTER TABLE sso_settings ADD COLUMN group_role_mappings TEXT NOT NULL DEFAULT '{}';
