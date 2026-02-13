package server

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/user/jobbie/internal/store"
)

func (s *Server) handleEnqueue(w http.ResponseWriter, r *http.Request) {
	var req store.EnqueueRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if req.Queue == "" {
		writeError(w, http.StatusBadRequest, "queue is required", "VALIDATION_ERROR")
		return
	}
	if len(req.Payload) == 0 {
		req.Payload = json.RawMessage(`{}`)
	}

	result, err := s.store.Enqueue(req)
	if err != nil {
		writeStoreError(w, err, http.StatusInternalServerError, "INTERNAL_ERROR")
		return
	}
	s.throughput.Inc("enqueued")

	status := http.StatusCreated
	if result.UniqueExisting {
		status = http.StatusOK
	}
	writeJSON(w, status, result)
}

func (s *Server) handleEnqueueBatch(w http.ResponseWriter, r *http.Request) {
	var req store.BatchEnqueueRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if len(req.Jobs) == 0 {
		writeError(w, http.StatusBadRequest, "jobs array is required", "VALIDATION_ERROR")
		return
	}
	for i, j := range req.Jobs {
		if j.Queue == "" {
			writeError(w, http.StatusBadRequest, "queue is required for each job", "VALIDATION_ERROR")
			return
		}
		if len(j.Payload) == 0 {
			req.Jobs[i].Payload = json.RawMessage(`{}`)
		}
	}

	result, err := s.store.EnqueueBatch(req)
	if err != nil {
		writeStoreError(w, err, http.StatusInternalServerError, "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusCreated, result)
}

func (s *Server) handleFetch(w http.ResponseWriter, r *http.Request) {
	var req store.FetchRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if len(req.Queues) == 0 {
		writeError(w, http.StatusBadRequest, "queues is required", "VALIDATION_ERROR")
		return
	}

	timeout := req.LeaseDuration
	if timeout <= 0 {
		timeout = 30
	}
	if timeout > 60 {
		timeout = 60
	}

	deadline := time.Now().Add(time.Duration(timeout) * time.Second)

	for {
		result, err := s.store.Fetch(req)
		if err != nil {
			writeStoreError(w, err, http.StatusInternalServerError, "INTERNAL_ERROR")
			return
		}
		if result != nil {
			writeJSON(w, http.StatusOK, result)
			return
		}

		// Long poll: wait and retry
		if time.Now().After(deadline) {
			w.WriteHeader(http.StatusNoContent)
			return
		}

		// Check if client disconnected
		select {
		case <-r.Context().Done():
			w.WriteHeader(http.StatusNoContent)
			return
		case <-time.After(500 * time.Millisecond):
			// retry
		}
	}
}

func (s *Server) handleFetchBatch(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Queues        []string `json:"queues"`
		WorkerID      string   `json:"worker_id"`
		Hostname      string   `json:"hostname"`
		LeaseDuration int      `json:"timeout"`
		Count         int      `json:"count"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if len(req.Queues) == 0 {
		writeError(w, http.StatusBadRequest, "queues is required", "VALIDATION_ERROR")
		return
	}
	if req.Count <= 0 {
		req.Count = 1
	}
	if req.Count > 512 {
		req.Count = 512
	}
	timeout := req.LeaseDuration
	if timeout <= 0 {
		timeout = 30
	}
	if timeout > 60 {
		timeout = 60
	}
	deadline := time.Now().Add(time.Duration(timeout) * time.Second)
	for {
		jobs, err := s.store.FetchBatch(store.FetchRequest{
			Queues:        req.Queues,
			WorkerID:      req.WorkerID,
			Hostname:      req.Hostname,
			LeaseDuration: req.LeaseDuration,
		}, req.Count)
		if err != nil {
			writeStoreError(w, err, http.StatusInternalServerError, "INTERNAL_ERROR")
			return
		}
		if len(jobs) > 0 {
			writeJSON(w, http.StatusOK, map[string]any{"jobs": jobs})
			return
		}
		if time.Now().After(deadline) {
			writeJSON(w, http.StatusOK, map[string]any{"jobs": []any{}})
			return
		}
		select {
		case <-r.Context().Done():
			writeJSON(w, http.StatusOK, map[string]any{"jobs": []any{}})
			return
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func (s *Server) handleAck(w http.ResponseWriter, r *http.Request) {
	jobID := chi.URLParam(r, "job_id")

	var body struct {
		Result json.RawMessage    `json:"result"`
		Usage  *store.UsageReport `json:"usage"`
	}
	decodeJSON(r, &body)

	if err := s.store.AckWithUsage(jobID, body.Result, body.Usage); err != nil {
		writeStoreError(w, err, http.StatusBadRequest, "ACK_ERROR")
		return
	}
	s.throughput.Inc("completed")
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleAckBatch(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Acks []struct {
			JobID  string             `json:"job_id"`
			Result json.RawMessage    `json:"result"`
			Usage  *store.UsageReport `json:"usage"`
		} `json:"acks"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if len(req.Acks) == 0 {
		writeError(w, http.StatusBadRequest, "acks array is required", "VALIDATION_ERROR")
		return
	}

	acks := make([]store.AckOp, 0, len(req.Acks))
	for _, ack := range req.Acks {
		if ack.JobID == "" {
			writeError(w, http.StatusBadRequest, "job_id is required for each ack", "VALIDATION_ERROR")
			return
		}
		acks = append(acks, store.AckOp{
			JobID:  ack.JobID,
			Result: ack.Result,
			Usage:  ack.Usage,
		})
	}

	acked, err := s.store.AckBatch(acks)
	if err != nil {
		writeStoreError(w, err, http.StatusBadRequest, "ACK_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]int{"acked": acked})
}

func (s *Server) handleFail(w http.ResponseWriter, r *http.Request) {
	jobID := chi.URLParam(r, "job_id")

	var body struct {
		Error     string `json:"error"`
		Backtrace string `json:"backtrace"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}

	result, err := s.store.Fail(jobID, body.Error, body.Backtrace)
	if err != nil {
		writeStoreError(w, err, http.StatusBadRequest, "FAIL_ERROR")
		return
	}
	s.throughput.Inc("failed")
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleThroughput(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.throughput.Snapshot())
}

func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	var req store.HeartbeatRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}

	result, err := s.store.Heartbeat(req)
	if err != nil {
		writeStoreError(w, err, http.StatusInternalServerError, "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, result)
}
