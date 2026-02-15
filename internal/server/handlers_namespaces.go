package server

import (
	"database/sql"
	"net/http"
	"regexp"

	"github.com/go-chi/chi/v5"
	"github.com/user/corvo/internal/store"
)

var validNamespace = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)

func (s *Server) handleListNamespaces(w http.ResponseWriter, r *http.Request) {
	rows, err := s.store.ReadDB().Query(`SELECT name, created_at,
		rate_limit_read_rps, rate_limit_read_burst,
		rate_limit_write_rps, rate_limit_write_burst
		FROM namespaces ORDER BY name`)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
		return
	}
	defer rows.Close()

	out := []map[string]any{}
	for rows.Next() {
		var name, createdAt string
		var readRPS, readBurst, writeRPS, writeBurst sql.NullFloat64
		if err := rows.Scan(&name, &createdAt, &readRPS, &readBurst, &writeRPS, &writeBurst); err != nil {
			writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
			return
		}
		entry := map[string]any{"name": name, "created_at": createdAt}
		if readRPS.Valid || readBurst.Valid || writeRPS.Valid || writeBurst.Valid {
			rl := map[string]any{}
			if readRPS.Valid {
				rl["read_rps"] = readRPS.Float64
			}
			if readBurst.Valid {
				rl["read_burst"] = readBurst.Float64
			}
			if writeRPS.Valid {
				rl["write_rps"] = writeRPS.Float64
			}
			if writeBurst.Valid {
				rl["write_burst"] = writeBurst.Float64
			}
			entry["rate_limit"] = rl
		}
		out = append(out, entry)
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

func (s *Server) handleSetNamespaceRateLimit(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")

	var req struct {
		ReadRPS    *float64 `json:"read_rps"`
		ReadBurst  *float64 `json:"read_burst"`
		WriteRPS   *float64 `json:"write_rps"`
		WriteBurst *float64 `json:"write_burst"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}

	// Validate that the namespace exists.
	var exists int
	if err := s.store.ReadDB().QueryRow("SELECT COUNT(*) FROM namespaces WHERE name = ?", name).Scan(&exists); err != nil || exists == 0 {
		writeError(w, http.StatusNotFound, "namespace not found", "NOT_FOUND")
		return
	}

	op := store.SetNamespaceRateLimitOp{
		Name:       name,
		ReadRPS:    req.ReadRPS,
		ReadBurst:  req.ReadBurst,
		WriteRPS:   req.WriteRPS,
		WriteBurst: req.WriteBurst,
	}
	if err := s.store.SetNamespaceRateLimit(op); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
		return
	}

	// Immediately refresh the rate limiter cache on the leader for instant effect.
	if s.rateLimiter != nil {
		s.rateLimiter.loadNamespaceConfigs()
	}

	writeJSON(w, http.StatusOK, map[string]any{"status": "updated"})
}

func (s *Server) handleGetNamespaceRateLimit(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")

	var readRPS, readBurst, writeRPS, writeBurst sql.NullFloat64
	err := s.store.ReadDB().QueryRow(`SELECT rate_limit_read_rps, rate_limit_read_burst,
		rate_limit_write_rps, rate_limit_write_burst FROM namespaces WHERE name = ?`, name).
		Scan(&readRPS, &readBurst, &writeRPS, &writeBurst)
	if err == sql.ErrNoRows {
		writeError(w, http.StatusNotFound, "namespace not found", "NOT_FOUND")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
		return
	}

	if !readRPS.Valid && !readBurst.Valid && !writeRPS.Valid && !writeBurst.Valid {
		writeJSON(w, http.StatusOK, map[string]any{"using_defaults": true})
		return
	}

	out := map[string]any{"using_defaults": false}
	if readRPS.Valid {
		out["read_rps"] = readRPS.Float64
	}
	if readBurst.Valid {
		out["read_burst"] = readBurst.Float64
	}
	if writeRPS.Valid {
		out["write_rps"] = writeRPS.Float64
	}
	if writeBurst.Valid {
		out["write_burst"] = writeBurst.Float64
	}
	writeJSON(w, http.StatusOK, out)
}
