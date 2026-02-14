package store

// Enterprise write operations routed through Raft consensus.

// CreateNamespace creates a namespace via Raft.
func (s *Store) CreateNamespace(name string) error {
	res := s.applyOp(OpCreateNamespace, CreateNamespaceOp{Name: name})
	return res.Err
}

// DeleteNamespace deletes a namespace via Raft.
func (s *Store) DeleteNamespace(name string) error {
	res := s.applyOp(OpDeleteNamespace, DeleteNamespaceOp{Name: name})
	return res.Err
}

// SetAuthRole creates or updates an RBAC role via Raft.
func (s *Store) SetAuthRole(op SetAuthRoleOp) error {
	res := s.applyOp(OpSetAuthRole, op)
	return res.Err
}

// DeleteAuthRole deletes an RBAC role via Raft.
func (s *Store) DeleteAuthRole(name string) error {
	res := s.applyOp(OpDeleteAuthRole, DeleteAuthRoleOp{Name: name})
	return res.Err
}

// AssignAPIKeyRole assigns a role to an API key via Raft.
func (s *Store) AssignAPIKeyRole(op AssignAPIKeyRoleOp) error {
	res := s.applyOp(OpAssignAPIKeyRole, op)
	return res.Err
}

// UnassignAPIKeyRole removes a role assignment from an API key via Raft.
func (s *Store) UnassignAPIKeyRole(keyHash, role string) error {
	res := s.applyOp(OpUnassignAPIKeyRole, UnassignAPIKeyRoleOp{KeyHash: keyHash, Role: role})
	return res.Err
}

// SetSSOSettings updates SSO configuration via Raft.
func (s *Store) SetSSOSettings(op SetSSOSettingsOp) error {
	res := s.applyOp(OpSetSSOSettings, op)
	return res.Err
}

// UpsertAPIKey creates or updates an API key via Raft.
func (s *Store) UpsertAPIKey(op UpsertAPIKeyOp) error {
	res := s.applyOp(OpUpsertAPIKey, op)
	return res.Err
}

// DeleteAPIKey deletes an API key via Raft.
func (s *Store) DeleteAPIKey(keyHash string) error {
	res := s.applyOp(OpDeleteAPIKey, DeleteAPIKeyOp{KeyHash: keyHash})
	return res.Err
}

// InsertAuditLog writes an audit log entry via Raft (background, fire-and-forget).
func (s *Store) InsertAuditLog(op InsertAuditLogOp) {
	s.applyBackground(OpInsertAuditLog, op)
}

// UpdateAPIKeyLastUsed updates last_used_at via Raft (background, fire-and-forget).
func (s *Store) UpdateAPIKeyLastUsed(op UpdateAPIKeyUsedOp) {
	s.applyBackground(OpUpdateAPIKeyUsed, op)
}

// UpsertWebhook creates or updates a webhook via Raft.
func (s *Store) UpsertWebhook(op UpsertWebhookOp) error {
	res := s.applyOp(OpUpsertWebhook, op)
	return res.Err
}

// DeleteWebhook deletes a webhook via Raft.
func (s *Store) DeleteWebhook(id string) error {
	res := s.applyOp(OpDeleteWebhook, DeleteWebhookOp{ID: id})
	return res.Err
}

// UpdateWebhookStatus updates webhook delivery status via Raft (background, fire-and-forget).
func (s *Store) UpdateWebhookStatus(op UpdateWebhookStatusOp) {
	s.applyBackground(OpUpdateWebhookStatus, op)
}

// applyBackground submits an op through Raft in a background goroutine.
func (s *Store) applyBackground(opType OpType, data any) {
	go s.applyOp(opType, data)
}
