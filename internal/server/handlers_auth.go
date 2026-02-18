package server

import "net/http"

// @Summary Auth configuration status
// @Tags System
// @Produce json
// @Success 200 {object} object
// @Security ApiKeyAuth
// @Router /auth/status [get]
func (s *Server) handleAuthStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"admin_password_set": s.adminPassword != "",
	})
}

// @Summary List API keys
// @Tags System
// @Produce json
// @Success 200 {array} object
// @Security ApiKeyAuth
// @Router /auth/keys [get]
func (s *Server) handleListAPIKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := s.listAPIKeys()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "AUTH_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, keys)
}

// @Summary Create or update an API key
// @Tags System
// @Accept json
// @Produce json
// @Param body body SetAPIKeyRequest true "API key request"
// @Success 200 {object} SetAPIKeyResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /auth/keys [post]
func (s *Server) handleSetAPIKey(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name       string `json:"name"`
		Key        string `json:"key,omitempty"`
		Namespace  string `json:"namespace,omitempty"`
		Role       string `json:"role,omitempty"`
		QueueScope string `json:"queue_scope,omitempty"`
		ExpiresAt  string `json:"expires_at,omitempty"`
		Enabled    *bool  `json:"enabled,omitempty"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	enabled := true
	if req.Enabled != nil {
		enabled = *req.Enabled
	}
	key, err := s.upsertAPIKey(req.Name, req.Key, req.Namespace, req.Role, req.QueueScope, req.ExpiresAt, enabled)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "AUTH_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "api_key": key})
}

// @Summary Delete an API key
// @Tags System
// @Accept json
// @Produce json
// @Param body body DeleteAPIKeyRequest true "Delete API key request"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /auth/keys [delete]
func (s *Server) handleDeleteAPIKey(w http.ResponseWriter, r *http.Request) {
	var req struct {
		KeyHash string `json:"key_hash"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if req.KeyHash == "" {
		writeError(w, http.StatusBadRequest, "key_hash is required", "VALIDATION_ERROR")
		return
	}
	if err := s.deleteAPIKey(req.KeyHash); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "AUTH_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted"})
}
