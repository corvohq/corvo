package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/user/jobbie/internal/search"
	"github.com/user/jobbie/internal/store"
)

// Queue management

func (s *Server) handleListQueues(w http.ResponseWriter, r *http.Request) {
	queues, err := s.store.ListQueues()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	if queues == nil {
		queues = []store.QueueInfo{}
	}
	writeJSON(w, http.StatusOK, queues)
}

func (s *Server) handlePauseQueue(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if err := s.store.PauseQueue(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "paused"})
}

func (s *Server) handleResumeQueue(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if err := s.store.ResumeQueue(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "resumed"})
}

func (s *Server) handleClearQueue(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if err := s.store.ClearQueue(name); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "cleared"})
}

func (s *Server) handleDrainQueue(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if err := s.store.DrainQueue(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "QUEUE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "draining"})
}

func (s *Server) handleSetConcurrency(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
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
	name := chi.URLParam(r, "name")
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
	name := chi.URLParam(r, "name")
	if err := s.store.RemoveThrottle(name); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleDeleteQueue(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if err := s.store.DeleteQueue(name); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// Job management

func (s *Server) handleGetJob(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	job, err := s.store.GetJob(id)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error(), "NOT_FOUND")
		return
	}
	writeJSON(w, http.StatusOK, job)
}

func (s *Server) handleRetryJob(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if err := s.store.RetryJob(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "RETRY_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "retried"})
}

func (s *Server) handleCancelJob(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	status, err := s.store.CancelJob(id)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "CANCEL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": status})
}

func (s *Server) handleMoveJob(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
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
	if err := s.store.MoveJob(id, body.Queue); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "MOVE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "moved"})
}

func (s *Server) handleDeleteJob(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if err := s.store.DeleteJob(id); err != nil {
		writeError(w, http.StatusNotFound, err.Error(), "NOT_FOUND")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

// Search and bulk

func (s *Server) handleSearch(w http.ResponseWriter, r *http.Request) {
	var filter search.Filter
	if err := decodeJSON(r, &filter); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}

	result, err := s.store.SearchJobs(filter)
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "INTERNAL_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, result)
}

func (s *Server) handleBulk(w http.ResponseWriter, r *http.Request) {
	var req store.BulkRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if req.Action == "" {
		writeError(w, http.StatusBadRequest, "action is required", "VALIDATION_ERROR")
		return
	}

	result, err := s.store.BulkAction(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "BULK_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, result)
}
