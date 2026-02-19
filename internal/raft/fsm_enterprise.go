package raft

import (
	"github.com/corvohq/corvo/internal/store"
)

// Enterprise FSM handlers — SQLite-only operations (no Pebble writes).

func (f *FSM) applyCreateNamespaceOp(op store.CreateNamespaceOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec("INSERT INTO namespaces (name) VALUES (?)", op.Name)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyDeleteNamespaceOp(op store.DeleteNamespaceOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec("DELETE FROM namespaces WHERE name = ?", op.Name)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applySetAuthRoleOp(op store.SetAuthRoleOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec(`
			INSERT INTO auth_roles (name, permissions, created_at, updated_at)
			VALUES (?, ?, ?, ?)
			ON CONFLICT(name) DO UPDATE SET permissions = excluded.permissions, updated_at = excluded.updated_at
		`, op.Name, op.Permissions, op.Now, op.Now)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyDeleteAuthRoleOp(op store.DeleteAuthRoleOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec("DELETE FROM auth_roles WHERE name = ?", op.Name)
		if err != nil {
			return err
		}
		_, err = db.Exec("DELETE FROM auth_key_roles WHERE role_name = ?", op.Name)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyAssignAPIKeyRoleOp(op store.AssignAPIKeyRoleOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec(`
			INSERT INTO auth_key_roles (key_hash, role_name, created_at) VALUES (?, ?, ?)
			ON CONFLICT(key_hash, role_name) DO NOTHING
		`, op.KeyHash, op.Role, op.Now)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyUnassignAPIKeyRoleOp(op store.UnassignAPIKeyRoleOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec("DELETE FROM auth_key_roles WHERE key_hash = ? AND role_name = ?", op.KeyHash, op.Role)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applySetSSOSettingsOp(op store.SetSSOSettingsOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec(`
			INSERT INTO sso_settings (id, provider, oidc_issuer_url, oidc_client_id, saml_enabled, oidc_group_claim, group_role_mappings, updated_at)
			VALUES ('singleton', ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(id) DO UPDATE SET
				provider = excluded.provider,
				oidc_issuer_url = excluded.oidc_issuer_url,
				oidc_client_id = excluded.oidc_client_id,
				saml_enabled = excluded.saml_enabled,
				oidc_group_claim = excluded.oidc_group_claim,
				group_role_mappings = excluded.group_role_mappings,
				updated_at = excluded.updated_at
		`, op.Provider, op.OIDCIssuerURL, op.OIDCClientID, op.SAMLEnabled, op.OIDCGroupClaim, op.GroupRoleMappings, op.Now)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyUpsertAPIKeyOp(op store.UpsertAPIKeyOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		var expiresAt any
		if op.ExpiresAt != "" {
			expiresAt = op.ExpiresAt
		}
		_, err := db.Exec(`
			INSERT INTO api_keys (key_hash, name, namespace, role, queue_scope, enabled, created_at, expires_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
			ON CONFLICT(key_hash) DO UPDATE SET
				name = excluded.name,
				namespace = excluded.namespace,
				role = excluded.role,
				queue_scope = excluded.queue_scope,
				enabled = excluded.enabled,
				expires_at = excluded.expires_at
		`, op.KeyHash, op.Name, op.Namespace, op.Role, op.QueueScope, op.Enabled, op.CreatedAt, expiresAt)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyDeleteAPIKeyOp(op store.DeleteAPIKeyOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec("DELETE FROM api_keys WHERE key_hash = ?", op.KeyHash)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyInsertAuditLogOp(op store.InsertAuditLogOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec(`
			INSERT INTO audit_logs (namespace, principal, role, method, path, status_code, metadata, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		`, op.Namespace, op.Principal, op.Role, op.Method, op.Path, op.StatusCode, op.Metadata, op.CreatedAt)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyUpdateAPIKeyUsedOp(op store.UpdateAPIKeyUsedOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec("UPDATE api_keys SET last_used_at = ? WHERE key_hash = ?", op.Now, op.KeyHash)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyUpsertWebhookOp(op store.UpsertWebhookOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec(`
			INSERT INTO webhooks (id, url, events, secret, enabled, retry_limit, created_at)
			VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%f','now'))
			ON CONFLICT(id) DO UPDATE SET
				url = excluded.url,
				events = excluded.events,
				secret = excluded.secret,
				enabled = excluded.enabled,
				retry_limit = excluded.retry_limit
		`, op.ID, op.URL, op.Events, op.Secret, op.Enabled, op.RetryLimit)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyDeleteWebhookOp(op store.DeleteWebhookOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec("DELETE FROM webhooks WHERE id = ?", op.ID)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applyUpdateWebhookStatusOp(op store.UpdateWebhookStatusOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		var errVal any
		if op.LastError != "" {
			errVal = op.LastError
		}
		_, err := db.Exec(
			"UPDATE webhooks SET last_status_code = ?, last_error = ?, last_delivery_at = ? WHERE id = ?",
			op.LastStatusCode, errVal, op.LastDeliveryAt, op.ID,
		)
		return err
	})
	return &store.OpResult{}
}

func (f *FSM) applySetNamespaceRateLimitOp(op store.SetNamespaceRateLimitOp) *store.OpResult {
	f.syncSQLite(func(db sqlExecer) error {
		_, err := db.Exec(`UPDATE namespaces SET
			rate_limit_read_rps = ?, rate_limit_read_burst = ?,
			rate_limit_write_rps = ?, rate_limit_write_burst = ?
			WHERE name = ?`,
			op.ReadRPS, op.ReadBurst, op.WriteRPS, op.WriteBurst, op.Name)
		return err
	})
	return &store.OpResult{}
}

