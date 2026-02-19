package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"
)

// @Summary Server-Sent Events stream
// @Description Real-time event stream for job and queue state changes. Use last_event_id to resume.
// @Tags System
// @Produce text/event-stream
// @Param last_event_id query integer false "Resume from sequence number"
// @Success 200 "SSE stream"
// @Security ApiKeyAuth
// @Router /events [get]
func (s *Server) handleSSE(w http.ResponseWriter, r *http.Request) {
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

	// Parse optional last_event_id for resume.
	var lastSeq uint64
	if raw := r.URL.Query().Get("last_event_id"); raw != "" {
		if v, err := strconv.ParseUint(raw, 10, 64); err == nil {
			lastSeq = v
		}
	}

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	keepalive := time.NewTicker(15 * time.Second)
	defer keepalive.Stop()

	ctx := r.Context()
	for {
		select {
		case <-ctx.Done():
			return
		case <-keepalive.C:
			_, _ = fmt.Fprintf(w, ":keepalive\n\n")
			flusher.Flush()
		case <-ticker.C:
			if s.cluster == nil {
				continue
			}
			events, err := s.cluster.EventLog(lastSeq, 50)
			if err != nil || len(events) == 0 {
				continue
			}
			for _, ev := range events {
				data, err := json.Marshal(ev)
				if err != nil {
					continue
				}
				seq := ev["seq"]
				seqStr := fmt.Sprintf("%v", seq)
				evType, _ := ev["type"].(string)
				if evType == "" {
					evType = "message"
				}
				_, _ = fmt.Fprintf(w, "id: %s\nevent: %s\ndata: %s\n\n", seqStr, evType, data)

				// Update lastSeq from the event.
				if seqF, ok := seq.(float64); ok {
					lastSeq = uint64(seqF)
				}
			}
			flusher.Flush()
		}
	}
}
