package server

import "net/http"

func (s *Server) handleListAPIKeys(w http.ResponseWriter, r *http.Request) {
	keys, err := s.listAPIKeys()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "AUTH_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, keys)
}

func (s *Server) handleSetAPIKey(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name       string `json:"name"`
		Key        string `json:"key,omitempty"`
		Namespace  string `json:"namespace,omitempty"`
		Role       string `json:"role,omitempty"`
		QueueScope string `json:"queue_scope,omitempty"`
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
	key, err := s.upsertAPIKey(req.Name, req.Key, req.Namespace, req.Role, req.QueueScope, enabled)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "AUTH_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "api_key": key})
}

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
