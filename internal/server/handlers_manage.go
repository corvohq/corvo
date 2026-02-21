package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/corvohq/corvo/internal/search"
	"github.com/corvohq/corvo/internal/store"
)

// Queue management

// @Summary List queues
// @Tags Queues
// @Produce json
// @Success 200 {array} store.QueueInfo
// @Security ApiKeyAuth
// @Router /queues [get]
func (s *Server) handleListQueues(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	queues, err := s.store.ListQueues()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	filtered := make([]store.QueueInfo, 0, len(queues))
	for _, q := range queues {
		if !enforceNamespaceJob(principal.Namespace, q.Name) {
			continue
		}
		q.Name = visibleQueue(principal.Namespace, q.Name)
		filtered = append(filtered, q)
	}
	if filtered == nil {
		filtered = []store.QueueInfo{}
	}
	writeJSON(w, http.StatusOK, filtered)
}

// @Summary Pause a queue
// @Description Paused queues stop dispatching jobs to workers. In-flight jobs continue.
// @Tags Queues
// @Produce json
// @Param name path string true "Queue name"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /queues/{name}/pause [post]
func (s *Server) handlePauseQueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.PauseQueue(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "paused"})
}

// @Summary Resume a paused queue
// @Tags Queues
// @Produce json
// @Param name path string true "Queue name"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /queues/{name}/resume [post]
func (s *Server) handleResumeQueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.ResumeQueue(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "resumed"})
}

// @Summary Clear all jobs from a queue
// @Description Deletes all pending (non-active) jobs from the queue.
// @Tags Queues
// @Produce json
// @Param name path string true "Queue name"
// @Success 200 {object} StatusResponse
// @Security ApiKeyAuth
// @Router /queues/{name}/clear [post]
func (s *Server) handleClearQueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.ClearQueue(name); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "cleared"})
}

// @Summary Drain a queue
// @Description Stops new jobs from being fetched while allowing in-flight jobs to complete.
// @Tags Queues
// @Produce json
// @Param name path string true "Queue name"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /queues/{name}/drain [post]
func (s *Server) handleDrainQueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.DrainQueue(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "draining"})
}

// @Summary Set queue concurrency limit
// @Description Limits the number of jobs from this queue that can be active (in-flight) at once.
// @Tags Queues
// @Accept json
// @Produce json
// @Param name path string true "Queue name"
// @Param body body SetConcurrencyRequest true "Concurrency request"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /queues/{name}/concurrency [post]
func (s *Server) handleSetConcurrency(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	var body struct {
		Max int `json:"max"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if err := s.store.SetConcurrency(name, body.Max); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// @Summary Set queue rate throttle
// @Description Limits the rate at which jobs are dispatched from the queue.
// @Tags Queues
// @Accept json
// @Produce json
// @Param name path string true "Queue name"
// @Param body body SetThrottleRequest true "Throttle request"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /queues/{name}/throttle [post]
func (s *Server) handleSetThrottle(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	var body struct {
		Rate     int `json:"rate"`
		WindowMs int `json:"window_ms"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if body.Rate <= 0 || body.WindowMs <= 0 {
		writeError(w, http.StatusBadRequest, "rate and window_ms must be positive", "VALIDATION_ERROR")
		return
	}
	if err := s.store.SetThrottle(name, body.Rate, body.WindowMs); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// @Summary Remove queue throttle
// @Tags Queues
// @Produce json
// @Param name path string true "Queue name"
// @Success 200 {object} StatusResponse
// @Security ApiKeyAuth
// @Router /queues/{name}/throttle [delete]
func (s *Server) handleRemoveThrottle(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.RemoveThrottle(name); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// @Summary Delete a queue
// @Description Deletes the queue and all its pending jobs.
// @Tags Queues
// @Produce json
// @Param name path string true "Queue name"
// @Success 200 {object} StatusResponse
// @Security ApiKeyAuth
// @Router /queues/{name} [delete]
func (s *Server) handleDeleteQueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.DeleteQueue(name); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// Job management

// @Summary Get a job
// @Tags Jobs
// @Produce json
// @Param id path string true "Job ID"
// @Success 200 {object} store.Job
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id} [get]
func (s *Server) handleGetJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	job, err := s.store.GetJob(id)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error(), "NOT_FOUND")
		return
	}
	if !enforceNamespaceJob(principal.Namespace, job.Queue) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	job.Queue = visibleQueue(principal.Namespace, job.Queue)
	writeJSON(w, http.StatusOK, job)
}

// @Summary Bulk get jobs
// @Description Returns multiple jobs by ID in a single request. Missing jobs are silently skipped.
// @Tags Jobs
// @Accept json
// @Produce json
// @Param body body object true "Request body with job_ids array"
// @Success 200 {object} object
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/bulk-get [post]
func (s *Server) handleBulkGetJobs(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	var body struct {
		JobIDs []string `json:"job_ids"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if len(body.JobIDs) == 0 {
		writeJSON(w, http.StatusOK, map[string]any{"jobs": []any{}})
		return
	}
	jobs, err := s.store.BulkGetJobs(body.JobIDs)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "VALIDATION_ERROR")
		return
	}
	filtered := make([]*store.Job, 0, len(jobs))
	for _, j := range jobs {
		if !enforceNamespaceJob(principal.Namespace, j.Queue) {
			continue
		}
		j.Queue = visibleQueue(principal.Namespace, j.Queue)
		filtered = append(filtered, j)
	}
	writeJSON(w, http.StatusOK, map[string]any{"jobs": filtered})
}

// @Summary List agent iterations
// @Description Returns the iteration history for an agent job (AI loop tracking).
// @Tags Jobs
// @Produce json
// @Param id path string true "Job ID"
// @Success 200 {object} IterationsResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id}/iterations [get]
func (s *Server) handleListJobIterations(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if _, err := s.store.GetJob(id); err != nil {
		writeError(w, http.StatusNotFound, err.Error(), "NOT_FOUND")
		return
	}
	iterations, err := s.store.ListJobIterations(id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	if iterations == nil {
		iterations = []store.JobIteration{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"iterations": iterations})
}

// @Summary Retry a failed job
// @Tags Jobs
// @Produce json
// @Param id path string true "Job ID"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id}/retry [post]
func (s *Server) handleRetryJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if !s.enforceJobNamespace(principal, id) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.RetryJob(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "RETRY_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "retried"})
}

// @Summary Cancel a job
// @Tags Jobs
// @Produce json
// @Param id path string true "Job ID"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id}/cancel [post]
func (s *Server) handleCancelJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if !s.enforceJobNamespace(principal, id) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	status, err := s.store.CancelJob(id)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "CANCEL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": status})
}

// @Summary Move a job to another queue
// @Tags Jobs
// @Accept json
// @Produce json
// @Param id path string true "Job ID"
// @Param body body MoveJobRequest true "Move request"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id}/move [post]
func (s *Server) handleMoveJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if !s.enforceJobNamespace(principal, id) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	var body struct {
		Queue string `json:"queue"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if body.Queue == "" {
		writeError(w, http.StatusBadRequest, "queue is required", "VALIDATION_ERROR")
		return
	}
	body.Queue = namespaceQueue(principal.Namespace, body.Queue)
	if err := s.store.MoveJob(id, body.Queue); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "MOVE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "moved"})
}

// @Summary Delete a job
// @Tags Jobs
// @Produce json
// @Param id path string true "Job ID"
// @Success 200 {object} StatusResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id} [delete]
func (s *Server) handleDeleteJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if !s.enforceJobNamespace(principal, id) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.DeleteJob(id); err != nil {
		writeError(w, http.StatusNotFound, err.Error(), "NOT_FOUND")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// @Summary Hold a job for approval
// @Tags Jobs
// @Produce json
// @Param id path string true "Job ID"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id}/hold [post]
func (s *Server) handleHoldJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if !s.enforceJobNamespace(principal, id) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.HoldJob(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "HOLD_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": store.StateHeld})
}

// @Summary Approve a held job
// @Tags Jobs
// @Produce json
// @Param id path string true "Job ID"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id}/approve [post]
func (s *Server) handleApproveJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if !s.enforceJobNamespace(principal, id) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.ApproveJob(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "APPROVE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": store.StatePending})
}

// @Summary Reject a held job
// @Tags Jobs
// @Produce json
// @Param id path string true "Job ID"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id}/reject [post]
func (s *Server) handleRejectJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if !s.enforceJobNamespace(principal, id) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.RejectJob(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "REJECT_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": store.StateDead})
}

// @Summary Replay a completed job from an iteration
// @Description Re-enqueues the job from a specific iteration checkpoint.
// @Tags Jobs
// @Accept json
// @Produce json
// @Param id path string true "Job ID"
// @Param body body ReplayJobRequest true "Replay request"
// @Success 201 {object} store.EnqueueResult
// @Failure 400 {object} ErrorResponse
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/{id}/replay [post]
func (s *Server) handleReplayJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if !s.enforceJobNamespace(principal, id) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	var body struct {
		From int `json:"from"`
	}
	if err := decodeJSON(r, &body); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if body.From <= 0 {
		writeError(w, http.StatusBadRequest, "from must be > 0", "VALIDATION_ERROR")
		return
	}
	result, err := s.store.ReplayFromIteration(id, body.From)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "REPLAY_ERROR")
		return
	}
	writeJSON(w, http.StatusCreated, result)
}

// Search and bulk

// @Summary Search jobs
// @Tags Jobs
// @Accept json
// @Produce json
// @Param body body search.Filter true "Search filter"
// @Success 200 {object} object
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/search [post]
func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	var filter search.Filter
	if err := decodeJSON(r, &filter); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if filter.Queue != "" {
		filter.Queue = namespaceQueue(principal.Namespace, filter.Queue)
	}

	result, err := s.store.SearchJobs(filter)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	for i := range result.Jobs {
		result.Jobs[i].Queue = visibleQueue(principal.Namespace, result.Jobs[i].Queue)
	}
	writeJSON(w, http.StatusOK, result)
}

// @Summary Bulk operation on jobs
// @Description Perform bulk actions by ID list or search filter. Supported actions: retry, delete, cancel, move, requeue, change_priority, hold, approve, reject.
// @Tags Bulk
// @Accept json
// @Produce json
// @Param body body BulkWithAsyncRequest true "Bulk request"
// @Success 200 {object} store.BulkResult
// @Success 202 {object} BulkAsyncAcceptedResponse "Async operation accepted"
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /jobs/bulk [post]
func (s *Server) handleBulk(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	var req struct {
		store.BulkRequest
		Async *bool `json:"async,omitempty"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if req.Action == "" {
		writeError(w, http.StatusBadRequest, "action is required", "VALIDATION_ERROR")
		return
	}

	const asyncThreshold = 10000
	useAsync := req.Async != nil && *req.Async
	if !useAsync {
		if len(req.JobIDs) > asyncThreshold {
			useAsync = true
		} else if len(req.JobIDs) == 0 && req.Filter != nil {
			count, err := s.bulkAsync.countFilter(*req.Filter)
			if err != nil {
				writeError(w, http.StatusBadRequest, err.Error(), "BULK_ERROR")
				return
			}
			if count > asyncThreshold {
				useAsync = true
			}
		}
	}

	if req.Filter != nil && req.Filter.Queue != "" {
		req.Filter.Queue = namespaceQueue(principal.Namespace, req.Filter.Queue)
	}
	if req.MoveToQueue != "" {
		req.MoveToQueue = namespaceQueue(principal.Namespace, req.MoveToQueue)
	}
	if useAsync {
		task, err := s.bulkAsync.start(req.BulkRequest)
		if err != nil {
			writeError(w, http.StatusBadRequest, err.Error(), "BULK_ERROR")
			return
		}
		writeJSON(w, http.StatusAccepted, map[string]any{
			"bulk_operation_id": task.ID,
			"status":            string(task.Status),
			"estimated_total":   task.Total,
			"progress_url":      "/api/v1/bulk/" + task.ID + "/progress",
		})
		return
	}

	result, err := s.store.BulkAction(req.BulkRequest)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "BULK_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, result)
}
