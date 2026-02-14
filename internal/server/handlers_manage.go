package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/user/corvo/internal/search"
	"github.com/user/corvo/internal/store"
)

// Queue management

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

func (s *Server) handlePauseQueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.PauseQueue(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "paused"})
}

func (s *Server) handleResumeQueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.ResumeQueue(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "resumed"})
}

func (s *Server) handleClearQueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.ClearQueue(name); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "cleared"})
}

func (s *Server) handleDrainQueue(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.DrainQueue(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "draining"})
}

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

func (s *Server) handleRemoveThrottle(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	name := namespaceQueue(principal.Namespace, chi.URLParam(r, "name"))
	if err := s.store.RemoveThrottle(name); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

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

func (s *Server) handleRetryJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if job, err := s.store.GetJob(id); err != nil || !enforceNamespaceJob(principal.Namespace, job.Queue) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.RetryJob(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "RETRY_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "retried"})
}

func (s *Server) handleCancelJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if job, err := s.store.GetJob(id); err != nil || !enforceNamespaceJob(principal.Namespace, job.Queue) {
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

func (s *Server) handleMoveJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if job, err := s.store.GetJob(id); err != nil || !enforceNamespaceJob(principal.Namespace, job.Queue) {
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

func (s *Server) handleDeleteJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if job, err := s.store.GetJob(id); err != nil || !enforceNamespaceJob(principal.Namespace, job.Queue) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.DeleteJob(id); err != nil {
		writeError(w, http.StatusNotFound, err.Error(), "NOT_FOUND")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

func (s *Server) handleHoldJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if job, err := s.store.GetJob(id); err != nil || !enforceNamespaceJob(principal.Namespace, job.Queue) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.HoldJob(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "HOLD_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": store.StateHeld})
}

func (s *Server) handleApproveJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if job, err := s.store.GetJob(id); err != nil || !enforceNamespaceJob(principal.Namespace, job.Queue) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.ApproveJob(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "APPROVE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": store.StatePending})
}

func (s *Server) handleRejectJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if job, err := s.store.GetJob(id); err != nil || !enforceNamespaceJob(principal.Namespace, job.Queue) {
		writeError(w, http.StatusNotFound, "job not found", "NOT_FOUND")
		return
	}
	if err := s.store.RejectJob(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "REJECT_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": store.StateDead})
}

func (s *Server) handleReplayJob(w http.ResponseWriter, r *http.Request) {
	principal := principalFromContext(r.Context())
	id := chi.URLParam(r, "id")
	if job, err := s.store.GetJob(id); err != nil || !enforceNamespaceJob(principal.Namespace, job.Queue) {
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
	if req.BulkRequest.Action == "" {
		writeError(w, http.StatusBadRequest, "action is required", "VALIDATION_ERROR")
		return
	}

	const asyncThreshold = 10000
	useAsync := req.Async != nil && *req.Async
	if !useAsync {
		if len(req.BulkRequest.JobIDs) > asyncThreshold {
			useAsync = true
		} else if len(req.BulkRequest.JobIDs) == 0 && req.BulkRequest.Filter != nil {
			count, err := s.bulkAsync.countFilter(*req.BulkRequest.Filter)
			if err != nil {
				writeError(w, http.StatusBadRequest, err.Error(), "BULK_ERROR")
				return
			}
			if count > asyncThreshold {
				useAsync = true
			}
		}
	}

	if req.BulkRequest.Filter != nil && req.BulkRequest.Filter.Queue != "" {
		req.BulkRequest.Filter.Queue = namespaceQueue(principal.Namespace, req.BulkRequest.Filter.Queue)
	}
	if req.BulkRequest.MoveToQueue != "" {
		req.BulkRequest.MoveToQueue = namespaceQueue(principal.Namespace, req.BulkRequest.MoveToQueue)
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
