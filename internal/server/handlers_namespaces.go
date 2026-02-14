package server

import (
	"net/http"
	"regexp"

	"github.com/go-chi/chi/v5"
)

var validNamespace = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

func (s *Server) handleListNamespaces(w http.ResponseWriter, r *http.Request) {
	rows, err := s.store.ReadDB().Query("SELECT name, created_at FROM namespaces ORDER BY name")
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
		return
	}
	defer rows.Close()

	out := []map[string]any{}
	for rows.Next() {
		var name, createdAt string
		if err := rows.Scan(&name, &createdAt); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
			return
		}
		out = append(out, map[string]any{"name": name, "created_at": createdAt})
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleCreateNamespace(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if !validNamespace.MatchString(req.Name) {
		writeError(w, http.StatusBadRequest, "invalid namespace name: must be lowercase alphanumeric with hyphens, 1-63 characters", "VALIDATION_ERROR")
		return
	}
	if err := s.store.CreateNamespace(req.Name); err != nil {
		writeError(w, http.StatusConflict, "namespace already exists", "CONFLICT")
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"name": req.Name, "status": "created"})
}

func (s *Server) handleDeleteNamespace(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if name == "default" {
		writeError(w, http.StatusBadRequest, "cannot delete the default namespace", "VALIDATION_ERROR")
		return
	}
	if err := s.store.DeleteNamespace(name); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted"})
}
