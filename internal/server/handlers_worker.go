package server

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/corvohq/corvo/internal/store"
)

// @Summary Enqueue via webhook
// @Description Enqueues a job using the raw HTTP body as payload. Useful for receiving webhooks from third-party services.
// @Tags Jobs
// @Accept json
// @Produce json
// @Param queue path string true "Queue name"
// @Param priority query string false "Priority: low, normal, high, critical"
// @Param unique_key query string false "Deduplication key"
// @Param max_retries query integer false "Max retry attempts"
// @Param scheduled_at query string false "RFC3339 schedule time"
// @Param tags query string false "Tags as comma-separated key:value pairs"
// @Success 201 {object} store.EnqueueResult "Job enqueued"
// @Success 200 {object} store.EnqueueResult "Duplicate exists (unique_key)"
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /webhooks/{queue} [post]
func (s *Server) handleWebhookEnqueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	queue := chi.URLParam(r, "queue")
	if queue == "" {
		writeError(w, http.StatusBadRequest, "queue is required in URL path", "VALIDATION_ERROR")
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
	if err != nil {
		writeError(w, http.StatusBadRequest, "failed to read request body", "PARSE_ERROR")
		return
	}

	var payload json.RawMessage
	if len(body) == 0 {
		payload = json.RawMessage(`{}`)
	} else if json.Valid(body) {
		payload = json.RawMessage(body)
	} else {
		quoted, _ := json.Marshal(string(body))
		payload = json.RawMessage(quoted)
	}
	if s.maxPayloadBytes > 0 && len(payload) > s.maxPayloadBytes {
		writeError(w, http.StatusRequestEntityTooLarge,
			fmt.Sprintf("payload too large: %d bytes (max %d)", len(payload), s.maxPayloadBytes),
			"PAYLOAD_TOO_LARGE")
		return
	}

	req := store.EnqueueRequest{
		Queue:   namespaceQueue(principal.Namespace, queue),
		Payload: payload,
	}

	q := r.URL.Query()
	if v := q.Get("priority"); v != "" {
		req.Priority = v
	}
	if v := q.Get("unique_key"); v != "" {
		req.UniqueKey = v
	}
	if v := q.Get("max_retries"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid max_retries value", "VALIDATION_ERROR")
			return
		}
		req.MaxRetries = &n
	}
	if v := q.Get("scheduled_at"); v != "" {
		t, err := time.Parse(time.RFC3339, v)
		if err != nil {
			writeError(w, http.StatusBadRequest, "invalid scheduled_at value (use RFC3339)", "VALIDATION_ERROR")
			return
		}
		req.ScheduledAt = &t
	}
	if v := q.Get("tags"); v != "" {
		tags := map[string]string{}
		for _, pair := range strings.Split(v, ",") {
			pair = strings.TrimSpace(pair)
			if pair == "" {
				continue
			}
			parts := strings.SplitN(pair, ":", 2)
			if len(parts) == 2 {
				tags[strings.TrimSpace(parts[0])] = strings.TrimSpace(parts[1])
			} else {
				writeError(w, http.StatusBadRequest, fmt.Sprintf("invalid tag format %q (expected key:value)", pair), "VALIDATION_ERROR")
				return
			}
		}
		tagsJSON, _ := json.Marshal(tags)
		req.Tags = json.RawMessage(tagsJSON)
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

// @Summary Enqueue a job
// @Tags Jobs
// @Accept json
// @Produce json
// @Param body body store.EnqueueRequest true "Enqueue request"
// @Success 201 {object} store.EnqueueResult "Job enqueued"
// @Success 200 {object} store.EnqueueResult "Duplicate exists (unique_key)"
// @Failure 400 {object} ErrorResponse
// @Failure 429 {object} ErrorResponse "Rate limited or budget exceeded"
// @Security ApiKeyAuth
// @Router /enqueue [post]
func (s *Server) handleEnqueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
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
	if s.maxPayloadBytes > 0 && len(req.Payload) > s.maxPayloadBytes {
		writeError(w, http.StatusRequestEntityTooLarge,
			fmt.Sprintf("payload too large: %d bytes (max %d)", len(req.Payload), s.maxPayloadBytes),
			"PAYLOAD_TOO_LARGE")
		return
	}
	req.Queue = namespaceQueue(principal.Namespace, req.Queue)
	if req.Chain != nil {
		for i := range req.Chain.Steps {
			if req.Chain.Steps[i].Queue == "" {
				writeError(w, http.StatusBadRequest, "chain step has empty queue", "VALIDATION_ERROR")
				return
			}
			req.Chain.Steps[i].Queue = namespaceQueue(principal.Namespace, req.Chain.Steps[i].Queue)
		}
		if req.Chain.OnFailure != nil {
			req.Chain.OnFailure.Queue = namespaceQueue(principal.Namespace, req.Chain.OnFailure.Queue)
		}
		if req.Chain.OnExit != nil {
			req.Chain.OnExit.Queue = namespaceQueue(principal.Namespace, req.Chain.OnExit.Queue)
		}
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

// @Summary Enqueue a batch of jobs
// @Tags Jobs
// @Accept json
// @Produce json
// @Param body body store.BatchEnqueueRequest true "Batch enqueue request"
// @Success 201 {object} store.BatchEnqueueResult
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /enqueue/batch [post]
func (s *Server) handleEnqueueBatch(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
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
		if s.maxPayloadBytes > 0 && len(req.Jobs[i].Payload) > s.maxPayloadBytes {
			writeError(w, http.StatusRequestEntityTooLarge,
				fmt.Sprintf("job %d payload too large: %d bytes (max %d)", i, len(req.Jobs[i].Payload), s.maxPayloadBytes),
				"PAYLOAD_TOO_LARGE")
			return
		}
		req.Jobs[i].Queue = namespaceQueue(principal.Namespace, req.Jobs[i].Queue)
	}

	result, err := s.store.EnqueueBatch(req)
	if err != nil {
		writeStoreError(w, err, http.StatusInternalServerError, "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusCreated, result)
}

// @Summary Fetch a job (long-poll)
// @Description Long-polls until a job is available or timeout expires. Returns one job or 204 if none available.
// @Tags Worker
// @Accept json
// @Produce json
// @Param body body store.FetchRequest true "Fetch request"
// @Success 200 {object} store.FetchResult
// @Success 204 "No job available"
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /fetch [post]
func (s *Server) handleFetch(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	var req store.FetchRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if len(req.Queues) == 0 {
		writeError(w, http.StatusBadRequest, "queues is required", "VALIDATION_ERROR")
		return
	}
	for i := range req.Queues {
		req.Queues[i] = namespaceQueue(principal.Namespace, req.Queues[i])
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
			result.Queue = visibleQueue(principal.Namespace, result.Queue)
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

// @Summary Fetch multiple jobs (long-poll)
// @Description Long-polls until jobs are available or timeout expires. Returns up to count jobs.
// @Tags Worker
// @Accept json
// @Produce json
// @Param body body FetchBatchRequest true "Fetch batch request"
// @Success 200 {object} FetchBatchResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /fetch/batch [post]
func (s *Server) handleFetchBatch(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
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
	for i := range req.Queues {
		req.Queues[i] = namespaceQueue(principal.Namespace, req.Queues[i])
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
			for i := range jobs {
				jobs[i].Queue = visibleQueue(principal.Namespace, jobs[i].Queue)
			}
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

// @Summary Acknowledge (complete) a job
// @Tags Worker
// @Accept json
// @Produce json
// @Param job_id path string true "Job ID"
// @Param body body AckBody false "Ack body"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /ack/{job_id} [post]
func (s *Server) handleAck(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	jobID := chi.URLParam(r, "job_id")
	if !s.enforceJobNamespace(principal, jobID) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}

	var body struct {
		Result      json.RawMessage    `json:"result"`
		Checkpoint  json.RawMessage    `json:"checkpoint"`
		Usage       *store.UsageReport `json:"usage"`
		AgentStatus string             `json:"agent_status"`
		HoldReason  string             `json:"hold_reason"`
		StepStatus  string             `json:"step_status"`
		ExitReason  string             `json:"exit_reason"`
	}
	_ = decodeJSON(r, &body)

	if err := s.store.AckJob(store.AckRequest{
		JobID:       jobID,
		Result:      body.Result,
		Checkpoint:  body.Checkpoint,
		Usage:       body.Usage,
		AgentStatus: body.AgentStatus,
		HoldReason:  body.HoldReason,
		StepStatus:  body.StepStatus,
		ExitReason:  body.ExitReason,
	}); err != nil {
		writeStoreError(w, err, http.StatusBadRequest, "ACK_ERROR")
		return
	}
	s.throughput.Inc("completed")
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// @Summary Acknowledge multiple jobs
// @Tags Worker
// @Accept json
// @Produce json
// @Param body body AckBatchRequest true "Ack batch request"
// @Success 200 {object} AckedCountResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /ack/batch [post]
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
	if len(req.Acks) > 512 {
		writeError(w, http.StatusBadRequest, "ack batch exceeds maximum of 512 items", "VALIDATION_ERROR")
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

// @Summary Fail a job
// @Description Marks the job as failed. If retries remain it will be retried according to the backoff policy.
// @Tags Worker
// @Accept json
// @Produce json
// @Param job_id path string true "Job ID"
// @Param body body FailBody false "Fail body"
// @Success 200 {object} object
// @Failure 400 {object} ErrorResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /fail/{job_id} [post]
func (s *Server) handleFail(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	jobID := chi.URLParam(r, "job_id")
	if !s.enforceJobNamespace(principal, jobID) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}

	var body struct {
		Error     string `json:"error"`
		Backtrace string `json:"backtrace"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}

	result, err := s.store.Fail(jobID, body.Error, body.Backtrace, false)
	if err != nil {
		writeStoreError(w, err, http.StatusBadRequest, "FAIL_ERROR")
		return
	}
	s.throughput.Inc("failed")
	writeJSON(w, http.StatusOK, result)
}

// @Summary Real-time throughput stats
// @Tags System
// @Produce json
// @Success 200 {object} object
// @Security ApiKeyAuth
// @Router /metrics/throughput [get]
func (s *Server) handleThroughput(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.throughput.Snapshot())
}

// @Summary Worker heartbeat
// @Description Extends leases for active jobs. Can include progress and checkpoint data. Returns cancellation signals.
// @Tags Worker
// @Accept json
// @Produce json
// @Param body body store.HeartbeatRequest true "Heartbeat request"
// @Success 200 {object} store.HeartbeatResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /heartbeat [post]
func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	var req store.HeartbeatRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if !isDefaultNamespace(principal.Namespace) {
		for jobID := range req.Jobs {
			if !s.enforceJobNamespace(principal, jobID) {
				delete(req.Jobs, jobID)
			}
		}
	}

	result, err := s.store.Heartbeat(req)
	if err != nil {
		writeStoreError(w, err, http.StatusInternalServerError, "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, result)
}
