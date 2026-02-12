package server

import (
	"net/http"
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
	// Single-node stub for Phase 1
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"mode":   "single",
		"status": "healthy",
		"nodes": []map[string]string{
			{"role": "leader", "status": "healthy"},
		},
	})
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	// Check DB is accessible
	if err := s.store.ReadDB().Ping(); err != nil {
		writeError(w, http.StatusServiceUnavailable, "database unavailable", "UNHEALTHY")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
