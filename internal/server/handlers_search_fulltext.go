package server

import (
	"database/sql"
	"net/http"
	"strconv"
	"strings"
)

// @Summary Full-text search jobs
// @Description Searches job payloads, tags, and queue names using SQLite FTS or LIKE fallback.
// @Tags Jobs
// @Produce json
// @Param q query string true "Search query"
// @Param limit query integer false "Max results (default: 50, max: 500)"
// @Success 200 {object} object
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /search/fulltext [get]
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

	queryFTS := `
		SELECT j.id, j.queue, j.state, j.payload, COALESCE(j.tags, ''), j.created_at
		FROM jobs_fts f
		JOIN jobs j ON j.id = f.job_id
		WHERE jobs_fts MATCH ?
		ORDER BY rank
		LIMIT ?
	`
	queryFallback := `
			SELECT j.id, j.queue, j.state, j.payload, COALESCE(j.tags, ''), j.created_at
			FROM jobs j
			WHERE j.payload LIKE '%' || ? || '%' OR COALESCE(j.tags, '') LIKE '%' || ? || '%' OR j.queue LIKE '%' || ? || '%'
			ORDER BY j.created_at DESC
			LIMIT ?
	`
	readRows := func(rows *sql.Rows) []map[string]any {
		defer func() { _ = rows.Close() }()
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
		return results
	}

	rows, err := s.store.ReadDB().Query(queryFTS, q, limit)
	if err != nil {
		rows, err = s.store.ReadDB().Query(queryFallback, q, q, q, limit)
		if err != nil {
			writeError(w, http.StatusInternalServerError, err.Error(), "SEARCH_ERROR")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"q": q, "results": readRows(rows)})
		return
	}
	results := readRows(rows)
	if len(results) == 0 {
		rows, err = s.store.ReadDB().Query(queryFallback, q, q, q, limit)
		if err == nil {
			results = readRows(rows)
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"q": q, "results": results})
}
