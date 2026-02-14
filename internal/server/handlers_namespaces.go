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
	_, err := s.store.ReadDB().Exec("INSERT INTO namespaces (name) VALUES (?)", req.Name)
	if err != nil {
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
	result, err := s.store.ReadDB().Exec("DELETE FROM namespaces WHERE name = ?", name)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
		return
	}
	n, _ := result.RowsAffected()
	if n == 0 {
		writeError(w, http.StatusNotFound, "namespace not found", "NOT_FOUND")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted"})
}
