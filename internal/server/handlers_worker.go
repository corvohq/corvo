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
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}

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
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
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
			writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
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

func (s *Server) handleAck(w http.ResponseWriter, r *http.Request) {
	jobID := chi.URLParam(r, "job_id")

	var body struct {
		Result json.RawMessage `json:"result"`
	}
	decodeJSON(r, &body)

	if err := s.store.Ack(jobID, body.Result); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "ACK_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
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
		writeError(w, http.StatusBadRequest, err.Error(), "FAIL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	var req store.HeartbeatRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}

	result, err := s.store.Heartbeat(req)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, result)
}
