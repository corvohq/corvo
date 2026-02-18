package server

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/corvohq/corvo/internal/store"
)

type authPermission struct {
	Resource string   `json:"resource"`
	Actions  []string `json:"actions"`
}

func permissionForRoute(method, path string) (resource, action string) {
	path = strings.TrimPrefix(path, "/")
	parts := strings.Split(path, "/")
	if len(parts) < 3 || parts[0] != "api" || parts[1] != "v1" {
		return "", ""
	}
	resource = parts[2]
	if method == http.MethodGet || method == http.MethodHead {
		return resource, "read"
	}
	if len(parts) >= 5 {
		last := strings.ToLower(strings.TrimSpace(parts[len(parts)-1]))
		switch last {
		case "pause", "resume", "drain", "clear", "retry", "cancel", "approve", "reject", "hold", "move", "replay":
			return resource, last
		}
	}
	switch method {
	case http.MethodPost, http.MethodPut, http.MethodPatch:
		return resource, "write"
	case http.MethodDelete:
		return resource, "delete"
	default:
		return resource, "write"
	}
}

func permissionAllows(perms []authPermission, resource, action string) bool {
	resource = strings.ToLower(strings.TrimSpace(resource))
	action = strings.ToLower(strings.TrimSpace(action))
	for _, p := range perms {
		pr := strings.ToLower(strings.TrimSpace(p.Resource))
		if pr == "" {
			continue
		}
		resourceMatch := pr == "*" || pr == resource || pr == resource+"/*" || strings.HasPrefix(resource, strings.TrimSuffix(pr, "*"))
		if !resourceMatch {
			continue
		}
		for _, a := range p.Actions {
			a = strings.ToLower(strings.TrimSpace(a))
			if a == "*" || a == action || (a == "write" && action != "read") {
				return true
			}
		}
	}
	return false
}

func (s *Server) listAssignedRoles(keyHash string) []string {
	rows, err := s.store.ReadDB().Query(`SELECT role_name FROM auth_key_roles WHERE key_hash = ? ORDER BY role_name`, strings.TrimSpace(keyHash))
	if err != nil {
		return nil
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var role string
		if rows.Scan(&role) == nil {
			role = strings.TrimSpace(role)
			if role != "" {
				out = append(out, role)
			}
		}
	}
	return out
}

func (s *Server) listPermissionsForRoles(roles []string) []authPermission {
	if len(roles) == 0 {
		return nil
	}
	out := []authPermission{}
	for _, role := range roles {
		role = strings.TrimSpace(role)
		if role == "" {
			continue
		}
		var raw string
		if err := s.store.ReadDB().QueryRow(`SELECT permissions FROM auth_roles WHERE name = ?`, role).Scan(&raw); err != nil {
			continue
		}
		var perms []authPermission
		if err := json.Unmarshal([]byte(raw), &perms); err != nil {
			continue
		}
		out = append(out, perms...)
	}
	return out
}

func (s *Server) handleListAuthRoles(w http.ResponseWriter, r *http.Request) {
	rows, err := s.store.ReadDB().Query(`SELECT name, permissions, created_at, updated_at FROM auth_roles ORDER BY name`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "AUTH_ERROR")
		return
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var name, raw, createdAt string
		var updatedAt sql.NullString
		if err := rows.Scan(&name, &raw, &createdAt, &updatedAt); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error(), "AUTH_ERROR")
			return
		}
		item := map[string]any{
			"name":       name,
			"created_at": createdAt,
		}
		var perms []authPermission
		if err := json.Unmarshal([]byte(raw), &perms); err == nil {
			item["permissions"] = perms
		}
		if updatedAt.Valid {
			item["updated_at"] = updatedAt.String
		}
		out = append(out, item)
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleSetAuthRole(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name        string           `json:"name"`
		Permissions []authPermission `json:"permissions"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if strings.TrimSpace(req.Name) == "" || len(req.Permissions) == 0 {
		writeError(w, http.StatusBadRequest, "name and permissions are required", "VALIDATION_ERROR")
		return
	}
	raw, _ := json.Marshal(req.Permissions)
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if err := s.store.SetAuthRole(store.SetAuthRoleOp{
		Name:        strings.TrimSpace(req.Name),
		Permissions: string(raw),
		Now:         now,
	}); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "AUTH_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func (s *Server) handleDeleteAuthRole(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimSpace(chi.URLParam(r, "name"))
	if name == "" {
		writeError(w, http.StatusBadRequest, "role name is required", "VALIDATION_ERROR")
		return
	}
	if err := s.store.DeleteAuthRole(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "AUTH_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted"})
}

func (s *Server) handleAssignAPIKeyRole(w http.ResponseWriter, r *http.Request) {
	keyHash := strings.TrimSpace(chi.URLParam(r, "key_hash"))
	var req struct {
		Role string `json:"role"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	role := strings.TrimSpace(req.Role)
	if keyHash == "" || role == "" {
		writeError(w, http.StatusBadRequest, "key_hash and role are required", "VALIDATION_ERROR")
		return
	}
	if err := s.store.AssignAPIKeyRole(store.AssignAPIKeyRoleOp{
		KeyHash: keyHash,
		Role:    role,
		Now:     time.Now().UTC().Format(time.RFC3339Nano),
	}); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "AUTH_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func (s *Server) handleUnassignAPIKeyRole(w http.ResponseWriter, r *http.Request) {
	keyHash := strings.TrimSpace(chi.URLParam(r, "key_hash"))
	role := strings.TrimSpace(chi.URLParam(r, "role"))
	if keyHash == "" || role == "" {
		writeError(w, http.StatusBadRequest, "key_hash and role are required", "VALIDATION_ERROR")
		return
	}
	if err := s.store.UnassignAPIKeyRole(keyHash, role); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "AUTH_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted"})
}

func (s *Server) handleListAPIKeyRoles(w http.ResponseWriter, r *http.Request) {
	keyHash := strings.TrimSpace(chi.URLParam(r, "key_hash"))
	if keyHash == "" {
		writeError(w, http.StatusBadRequest, "key_hash is required", "VALIDATION_ERROR")
		return
	}
	rows, err := s.store.ReadDB().Query(`SELECT role_name FROM auth_key_roles WHERE key_hash = ? ORDER BY role_name`, keyHash)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "AUTH_ERROR")
		return
	}
	defer rows.Close()
	out := []string{}
	for rows.Next() {
		var role string
		if err := rows.Scan(&role); err == nil {
			out = append(out, role)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"key_hash": keyHash, "roles": out})
}
