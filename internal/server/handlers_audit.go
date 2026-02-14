package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
)

func (s *Server) handleListAuditLogs(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()

	limit := 100
	if raw := q.Get("limit"); raw != "" {
		v, err := strconv.Atoi(raw)
		if err != nil || v <= 0 {
			writeError(w, http.StatusBadRequest, "invalid limit", "VALIDATION_ERROR")
			return
		}
		if v > 1000 {
			v = 1000
		}
		limit = v
	}

	offset := 0
	if raw := q.Get("offset"); raw != "" {
		v, err := strconv.Atoi(raw)
		if err != nil || v < 0 {
			writeError(w, http.StatusBadRequest, "invalid offset", "VALIDATION_ERROR")
			return
		}
		offset = v
	}

	// Build query with optional filters.
	where := []string{"1=1"}
	args := []any{}

	if v := q.Get("principal"); v != "" {
		where = append(where, "principal = ?")
		args = append(args, v)
	}
	if v := q.Get("method"); v != "" {
		where = append(where, "method = ?")
		args = append(args, strings.ToUpper(v))
	}
	if v := q.Get("path_prefix"); v != "" {
		where = append(where, "path LIKE ?")
		args = append(args, v+"%")
	}
	if v := q.Get("namespace"); v != "" {
		where = append(where, "namespace = ?")
		args = append(args, v)
	}
	if v := q.Get("since"); v != "" {
		where = append(where, "created_at >= ?")
		args = append(args, v)
	}
	if v := q.Get("until"); v != "" {
		where = append(where, "created_at <= ?")
		args = append(args, v)
	}

	query := fmt.Sprintf(
		"SELECT id, namespace, principal, role, method, path, status_code, metadata, created_at FROM audit_logs WHERE %s ORDER BY created_at DESC LIMIT ? OFFSET ?",
		strings.Join(where, " AND "),
	)
	args = append(args, limit, offset)

	rows, err := s.store.ReadDB().Query(query, args...)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	defer rows.Close()

	type auditEntry struct {
		ID         int64           `json:"id"`
		Namespace  string          `json:"namespace"`
		Principal  *string         `json:"principal"`
		Role       *string         `json:"role"`
		Method     string          `json:"method"`
		Path       string          `json:"path"`
		StatusCode int             `json:"status_code"`
		Metadata   json.RawMessage `json:"metadata,omitempty"`
		CreatedAt  string          `json:"created_at"`
	}

	logs := []auditEntry{}
	for rows.Next() {
		var e auditEntry
		var meta *string
		if err := rows.Scan(&e.ID, &e.Namespace, &e.Principal, &e.Role, &e.Method, &e.Path, &e.StatusCode, &meta, &e.CreatedAt); err != nil {
			continue
		}
		if meta != nil {
			e.Metadata = json.RawMessage(*meta)
		}
		logs = append(logs, e)
	}
	writeJSON(w, http.StatusOK, map[string]any{"audit_logs": logs})
}
