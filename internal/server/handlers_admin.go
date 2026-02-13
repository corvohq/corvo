package server

import (
	"net/http"
	"strconv"
)

func (s *Server) handleListWorkers(w http.ResponseWriter, r *http.Request) {
	rows, err := s.store.ReadDB().Query(
		"SELECT id, hostname, queues, last_heartbeat, started_at FROM workers ORDER BY last_heartbeat DESC",
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	defer rows.Close()

	type workerRow struct {
		ID            string  `json:"id"`
		Hostname      *string `json:"hostname"`
		Queues        *string `json:"queues"`
		LastHeartbeat string  `json:"last_heartbeat"`
		StartedAt     string  `json:"started_at"`
	}

	var workers []workerRow
	for rows.Next() {
		var w workerRow
		if err := rows.Scan(&w.ID, &w.Hostname, &w.Queues, &w.LastHeartbeat, &w.StartedAt); err != nil {
			continue
		}
		workers = append(workers, w)
	}
	if workers == nil {
		workers = []workerRow{}
	}
	writeJSON(w, http.StatusOK, workers)
}

func (s *Server) handleClusterStatus(w http.ResponseWriter, r *http.Request) {
	if s.cluster == nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"mode":   "single",
			"status": "healthy",
			"nodes": []map[string]string{
				{"role": "leader", "status": "healthy"},
			},
		})
		return
	}

	writeJSON(w, http.StatusOK, s.cluster.ClusterStatus())
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	// Check DB is accessible
	if err := s.store.ReadDB().Ping(); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable", "UNHEALTHY")
		return
	}

	resp := map[string]any{"status": "ok"}
	if s.cluster != nil {
		resp["raft_state"] = s.cluster.State()
		resp["leader"] = s.cluster.IsLeader()
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleClusterEvents(w http.ResponseWriter, r *http.Request) {
	if s.cluster == nil {
		writeJSON(w, http.StatusOK, map[string]any{"events": []map[string]any{}})
		return
	}

	afterSeq := uint64(0)
	if raw := r.URL.Query().Get("after_seq"); raw != "" {
		v, err := strconv.ParseUint(raw, 10, 64)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid after_seq", "VALIDATION_ERROR")
			return
		}
		afterSeq = v
	}

	limit := 100
	if raw := r.URL.Query().Get("limit"); raw != "" {
		v, err := strconv.Atoi(raw)
		if err != nil || v <= 0 {
			writeError(w, http.StatusBadRequest, "invalid limit", "VALIDATION_ERROR")
			return
		}
		limit = v
	}

	events, err := s.cluster.EventLog(afterSeq, limit)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"events": events})
}
