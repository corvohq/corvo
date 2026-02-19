package server

import (
	"net/http"
	"strconv"
	"strings"
	"time"
)

// @Summary List connected workers
// @Tags System
// @Produce json
// @Success 200 {array} object
// @Security ApiKeyAuth
// @Router /workers [get]
func (s *Server) handleListWorkers(w http.ResponseWriter, r *http.Request) {
	rows, err := s.store.ReadDB().Query(
		"SELECT id, hostname, queues, last_heartbeat, started_at FROM workers ORDER BY last_heartbeat DESC",
	)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	defer func() { _ = rows.Close() }()

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

// @Summary Cluster status
// @Tags Cluster
// @Produce json
// @Success 200 {object} object
// @Security ApiKeyAuth
// @Router /cluster/status [get]
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

// @Summary Health check
// @Tags System
// @Produce json
// @Success 200 {object} object
// @Failure 503 {object} ErrorResponse
// @Router /healthz [get]
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

// @Summary Cluster event log
// @Tags Cluster
// @Produce json
// @Param after_seq query integer false "Return events after this sequence number"
// @Param limit query integer false "Max events to return (default: 100)"
// @Success 200 {object} object
// @Security ApiKeyAuth
// @Router /cluster/events [get]
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

func (s *Server) handleRebuildSQLite(w http.ResponseWriter, r *http.Request) {
	if s.cluster == nil {
		writeError(w, http.StatusNotImplemented, "cluster rebuild unavailable", "UNSUPPORTED")
		return
	}
	start := time.Now()
	if err := s.cluster.RebuildSQLiteFromPebble(); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":      "ok",
		"rebuilt":     true,
		"duration_ms": time.Since(start).Milliseconds(),
	})
}

type clusterVoter interface {
	AddVoter(nodeID, addr string) error
}

type clusterShardVoter interface {
	AddVoterForShard(shard int, nodeID, addr string) error
	ShardCount() int
}

// @Summary Join a cluster node
// @Tags Cluster
// @Accept json
// @Produce json
// @Param body body object true "Join request"
// @Success 200 {object} object
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /cluster/join [post]
func (s *Server) handleClusterJoin(w http.ResponseWriter, r *http.Request) {
	if s.cluster == nil {
		writeError(w, http.StatusNotImplemented, "cluster join unavailable", "UNSUPPORTED")
		return
	}
	cv, hasCV := s.cluster.(clusterVoter)
	sv, hasSV := s.cluster.(clusterShardVoter)
	if !hasCV && !hasSV {
		writeError(w, http.StatusNotImplemented, "cluster membership unavailable", "UNSUPPORTED")
		return
	}

	var req struct {
		NodeID     string `json:"node_id"`
		Addr       string `json:"addr"`
		Shard      *int   `json:"shard,omitempty"`
		ShardCount *int   `json:"shard_count,omitempty"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if req.NodeID == "" || req.Addr == "" {
		writeError(w, http.StatusBadRequest, "node_id and addr are required", "VALIDATION_ERROR")
		return
	}

	if hasSV {
		if req.ShardCount != nil && *req.ShardCount != sv.ShardCount() {
			writeError(w, http.StatusConflict, "shard_count mismatch", "SHARD_COUNT_MISMATCH")
			return
		}
		shard := 0
		if req.Shard != nil {
			shard = *req.Shard
		}
		if err := sv.AddVoterForShard(shard, req.NodeID, req.Addr); err != nil {
			msg := err.Error()
			if strings.Contains(msg, "already") || strings.Contains(msg, "exists") || strings.Contains(msg, "voter") {
				writeJSON(w, http.StatusOK, map[string]any{
					"status":      "ok",
					"added":       false,
					"node_id":     req.NodeID,
					"addr":        req.Addr,
					"shard":       shard,
					"shard_count": sv.ShardCount(),
				})
				return
			}
			writeError(w, http.StatusBadRequest, msg, "JOIN_ERROR")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"status":      "ok",
			"added":       true,
			"node_id":     req.NodeID,
			"addr":        req.Addr,
			"shard":       shard,
			"shard_count": sv.ShardCount(),
		})
		return
	}

	if !hasCV {
		writeError(w, http.StatusNotImplemented, "cluster membership unavailable", "UNSUPPORTED")
		return
	}
	if err := cv.AddVoter(req.NodeID, req.Addr); err != nil {
		msg := err.Error()
		if strings.Contains(msg, "already") || strings.Contains(msg, "exists") || strings.Contains(msg, "voter") {
			writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "added": false, "node_id": req.NodeID, "addr": req.Addr})
			return
		}
		writeError(w, http.StatusBadRequest, msg, "JOIN_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "added": true, "node_id": req.NodeID, "addr": req.Addr})
}
