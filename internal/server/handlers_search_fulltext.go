package server

import (
	"net/http"
	"strconv"
	"strings"
)

func (s *Server) handleFullTextSearch(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" {
		writeError(w, http.StatusBadRequest, "q is required", "VALIDATION_ERROR")
		return
	}
	limit := 50
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v > 0 && v <= 500 {
			limit = v
		}
	}

	rows, err := s.store.ReadDB().Query(`
		SELECT j.id, j.queue, j.state, j.payload, COALESCE(j.tags, ''), j.created_at
		FROM jobs_fts f
		JOIN jobs j ON j.id = f.job_id
		WHERE jobs_fts MATCH ?
		ORDER BY rank
		LIMIT ?
	`, q, limit)
	if err != nil {
		rows, err = s.store.ReadDB().Query(`
			SELECT j.id, j.queue, j.state, j.payload, COALESCE(j.tags, ''), j.created_at
			FROM jobs_search s
			JOIN jobs j ON j.id = s.job_id
			WHERE s.payload LIKE '%' || ? || '%' OR s.tags LIKE '%' || ? || '%' OR s.queue LIKE '%' || ? || '%'
			ORDER BY j.created_at DESC
			LIMIT ?
		`, q, q, q, limit)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err.Error(), "SEARCH_ERROR")
			return
		}
	}
	defer rows.Close()
	results := []map[string]any{}
	for rows.Next() {
		var id, queue, state, payload, tags, createdAt string
		if err := rows.Scan(&id, &queue, &state, &payload, &tags, &createdAt); err != nil {
			continue
		}
		if !enforceNamespaceJob(principal.Namespace, queue) {
			continue
		}
		results = append(results, map[string]any{
			"id":         id,
			"queue":      visibleQueue(principal.Namespace, queue),
			"state":      state,
			"payload":    payload,
			"tags":       tags,
			"created_at": createdAt,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"q": q, "results": results})
}
