package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
)

// @Summary Get bulk operation status
// @Tags Bulk
// @Produce json
// @Param id path string true "Bulk operation ID"
// @Success 200 {object} bulkTask
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /bulk/{id} [get]
func (s *Server) handleBulkStatus(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	task, ok := s.bulkAsync.get(id)
	if !ok {
		writeError(w, http.StatusNotFound, "bulk operation not found", "NOT_FOUND")
		return
	}
	writeJSON(w, http.StatusOK, task)
}

// @Summary Stream bulk operation progress
// @Description SSE stream for real-time progress updates on a bulk operation.
// @Tags Bulk
// @Produce text/event-stream
// @Param id path string true "Bulk operation ID"
// @Success 200 "SSE progress stream"
// @Failure 404 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /bulk/{id}/progress [get]
func (s *Server) handleBulkProgress(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	task, ok := s.bulkAsync.get(id)
	if !ok {
		writeError(w, http.StatusNotFound, "bulk operation not found", "NOT_FOUND")
		return
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported", "SSE_UNSUPPORTED")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	if task.Status == bulkTaskCompleted || task.Status == bulkTaskFailed {
		s.writeBulkTerminalEvent(w, task)
		flusher.Flush()
		return
	}

	ch, ok := s.bulkAsync.eventsFor(id)
	if !ok {
		s.writeBulkTerminalEvent(w, task)
		flusher.Flush()
		return
	}

	keepalive := time.NewTicker(15 * time.Second)
	defer keepalive.Stop()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case <-keepalive.C:
			_, _ = fmt.Fprint(w, ":keepalive\n\n")
			flusher.Flush()
		case ev, ok := <-ch:
			if !ok {
				if latest, found := s.bulkAsync.get(id); found {
					s.writeBulkTerminalEvent(w, latest)
					flusher.Flush()
				}
				return
			}
			body, err := json.Marshal(ev)
			if err != nil {
				continue
			}
			_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", ev.Type, body)
			flusher.Flush()
		}
	}
}

func (s *Server) writeBulkTerminalEvent(w http.ResponseWriter, task *bulkTask) {
	evType := "bulk.async.completed"
	if task.Status == bulkTaskFailed {
		evType = "bulk.async.failed"
	}
	ev := bulkTaskEvent{
		Type:        evType,
		TaskID:      task.ID,
		Status:      string(task.Status),
		Total:       task.Total,
		Processed:   task.Processed,
		Affected:    task.Affected,
		Error:       task.Error,
		CreatedAtNs: time.Now().UnixNano(),
	}
	body, _ := json.Marshal(ev)
	_, _ = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", ev.Type, body)
}
