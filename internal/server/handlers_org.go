package server

import (
	"database/sql"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/user/jobbie/internal/store"
)

func (s *Server) handleGetOrg(w http.ResponseWriter, r *http.Request) {
	db := s.store.ReadDB()
	if db == nil {
		writeError(w, http.StatusInternalServerError, "database unavailable", "INTERNAL_ERROR")
		return
	}
	var id, name, createdAt string
	err := db.QueryRow("SELECT id, name, created_at FROM orgs LIMIT 1").Scan(&id, &name, &createdAt)
	if err == sql.ErrNoRows {
		writeError(w, http.StatusNotFound, "org not found", "NOT_FOUND")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"id":         id,
		"name":       name,
		"created_at": createdAt,
	})
}

func (s *Server) handleUpdateOrg(w http.ResponseWriter, r *http.Request) {
	db := s.store.ReadDB()
	if db == nil {
		writeError(w, http.StatusInternalServerError, "database unavailable", "INTERNAL_ERROR")
		return
	}
	var req struct {
		Name string `json:"name"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "name is required", "VALIDATION_ERROR")
		return
	}
	_, err := db.Exec("UPDATE orgs SET name = ? WHERE id = (SELECT id FROM orgs LIMIT 1)", req.Name)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleListMembers(w http.ResponseWriter, r *http.Request) {
	db := s.store.ReadDB()
	if db == nil {
		writeError(w, http.StatusInternalServerError, "database unavailable", "INTERNAL_ERROR")
		return
	}
	rows, err := db.Query("SELECT id, name, email, role, created_at FROM users ORDER BY created_at ASC")
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	defer rows.Close()

	members := []map[string]string{}
	for rows.Next() {
		var id, name, email, role, createdAt string
		if err := rows.Scan(&id, &name, &email, &role, &createdAt); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
			return
		}
		members = append(members, map[string]string{
			"id":         id,
			"name":       name,
			"email":      email,
			"role":       role,
			"created_at": createdAt,
		})
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, members)
}

func (s *Server) handleRemoveMember(w http.ResponseWriter, r *http.Request) {
	db := s.store.ReadDB()
	if db == nil {
		writeError(w, http.StatusInternalServerError, "database unavailable", "INTERNAL_ERROR")
		return
	}
	memberID := chi.URLParam(r, "id")
	if memberID == "" {
		writeError(w, http.StatusBadRequest, "member id is required", "VALIDATION_ERROR")
		return
	}

	// Check the member exists and isn't the owner
	var role string
	err := db.QueryRow("SELECT role FROM users WHERE id = ?", memberID).Scan(&role)
	if err == sql.ErrNoRows {
		writeError(w, http.StatusNotFound, "member not found", "NOT_FOUND")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	if role == "owner" {
		writeError(w, http.StatusForbidden, "cannot remove the owner", "FORBIDDEN")
		return
	}

	_, err = db.Exec("DELETE FROM users WHERE id = ?", memberID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// handleListOrgAPIKeys lists all org API keys (prefix only, never the full key).
func (s *Server) handleListOrgAPIKeys(w http.ResponseWriter, r *http.Request) {
	db := s.store.ReadDB()
	if db == nil {
		writeError(w, http.StatusInternalServerError, "database unavailable", "INTERNAL_ERROR")
		return
	}
	rows, err := db.Query("SELECT id, name, prefix, created_at FROM org_api_keys ORDER BY created_at DESC")
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	defer rows.Close()

	keys := []map[string]string{}
	for rows.Next() {
		var id, name, prefix, createdAt string
		if err := rows.Scan(&id, &name, &prefix, &createdAt); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
			return
		}
		keys = append(keys, map[string]string{
			"id":         id,
			"name":       name,
			"prefix":     prefix,
			"created_at": createdAt,
		})
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, keys)
}

// handleCreateOrgAPIKey creates a new org API key. Returns the raw key once.
func (s *Server) handleCreateOrgAPIKey(w http.ResponseWriter, r *http.Request) {
	db := s.store.ReadDB()
	if db == nil {
		writeError(w, http.StatusInternalServerError, "database unavailable", "INTERNAL_ERROR")
		return
	}
	var req struct {
		Name string `json:"name"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	req.Name = strings.TrimSpace(req.Name)
	if req.Name == "" {
		writeError(w, http.StatusBadRequest, "name is required", "VALIDATION_ERROR")
		return
	}

	id := "key_" + store.NewJobID()[4:] // reuse sortable ID generation
	rawKey := "jb_" + id[4:]            // full key starts with jb_ prefix
	prefix := rawKey[:8]
	keyHash := hashAPIKey(rawKey)
	now := time.Now().UTC().Format(time.RFC3339Nano)

	_, err := db.Exec(
		"INSERT INTO org_api_keys (id, org_id, name, prefix, key_hash, created_at) VALUES (?, 'org_default', ?, ?, ?, ?)",
		id, req.Name, prefix, keyHash, now,
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}

	writeJSON(w, http.StatusCreated, map[string]string{
		"id":         id,
		"name":       req.Name,
		"key":        rawKey,
		"prefix":     prefix,
		"created_at": now,
	})
}

// handleDeleteOrgAPIKey deletes an org API key by ID.
func (s *Server) handleDeleteOrgAPIKey(w http.ResponseWriter, r *http.Request) {
	db := s.store.ReadDB()
	if db == nil {
		writeError(w, http.StatusInternalServerError, "database unavailable", "INTERNAL_ERROR")
		return
	}
	keyID := chi.URLParam(r, "id")
	if keyID == "" {
		writeError(w, http.StatusBadRequest, "key id is required", "VALIDATION_ERROR")
		return
	}
	res, err := db.Exec("DELETE FROM org_api_keys WHERE id = ?", keyID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	affected, _ := res.RowsAffected()
	if affected == 0 {
		writeError(w, http.StatusNotFound, "api key not found", "NOT_FOUND")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
