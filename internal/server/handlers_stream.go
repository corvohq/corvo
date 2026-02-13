package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
)

// handleJobStreamSSE streams incremental LLM/job output deltas for a single job.
func (s *Server) handleJobStreamSSE(w http.ResponseWriter, r *http.Request) {
	jobID := chi.URLParam(r, "id")
	if jobID == "" {
		writeError(w, http.StatusBadRequest, "job id is required", "VALIDATION_ERROR")
		return
	}
	if s.cluster == nil {
		writeError(w, http.StatusNotImplemented, "stream events unavailable", "UNSUPPORTED")
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
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	lastSeq := uint64(0)
	if raw := r.URL.Query().Get("last_event_id"); raw != "" {
		if v, err := strconv.ParseUint(raw, 10, 64); err == nil {
			lastSeq = v
		}
	}

	ticker := time.NewTicker(250 * time.Millisecond)
	defer ticker.Stop()
	keepalive := time.NewTicker(15 * time.Second)
	defer keepalive.Stop()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case <-keepalive.C:
			fmt.Fprintf(w, ":keepalive\n\n")
			flusher.Flush()
		case <-ticker.C:
			events, err := s.cluster.EventLog(lastSeq, 100)
			if err != nil || len(events) == 0 {
				continue
			}
			for _, ev := range events {
				seq, _ := toUint64(ev["seq"])
				if seq > lastSeq {
					lastSeq = seq
				}
				evType, _ := ev["type"].(string)
				if evType != "job.stream" {
					continue
				}
				evJobID, _ := ev["job_id"].(string)
				if evJobID != jobID {
					continue
				}
				payload := map[string]any{
					"job_id":       evJobID,
					"queue":        ev["queue"],
					"stream_delta": ev["stream_delta"],
					"at_ns":        ev["at_ns"],
					"seq":          seq,
				}
				data, err := json.Marshal(payload)
				if err != nil {
					continue
				}
				fmt.Fprintf(w, "id: %d\nevent: job.stream\ndata: %s\n\n", seq, data)
			}
			flusher.Flush()
		}
	}
}
