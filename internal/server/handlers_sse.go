package server

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// @Summary Server-Sent Events stream
// @Description Real-time event stream for job and queue state changes. Use last_event_id to resume. Supports filtering via query params: queues, job_ids, types (comma-separated).
// @Tags System
// @Produce text/event-stream
// @Param last_event_id query integer false "Resume from sequence number"
// @Param queues query string false "Comma-separated queue names to filter by"
// @Param job_ids query string false "Comma-separated job IDs to filter by"
// @Param types query string false "Comma-separated event types to filter by"
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

	// Parse optional filters.
	filterQueues := parseCSVSet(r.URL.Query().Get("queues"))
	filterJobIDs := parseCSVSet(r.URL.Query().Get("job_ids"))
	filterTypes := parseCSVSet(r.URL.Query().Get("types"))

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
				seq := ev["seq"]

				// Always advance lastSeq to avoid replaying skipped events.
				if seqF, ok := seq.(float64); ok {
					lastSeq = uint64(seqF)
				}

				// Apply filters — skip non-matching events.
				if !matchSSEFilter(ev, filterQueues, filterJobIDs, filterTypes) {
					continue
				}

				data, err := json.Marshal(ev)
				if err != nil {
					continue
				}
				seqStr := fmt.Sprintf("%v", seq)
				evType, _ := ev["type"].(string)
				if evType == "" {
					evType = "message"
				}
				_, _ = fmt.Fprintf(w, "id: %s\nevent: %s\ndata: %s\n\n", seqStr, evType, data)
			}
			flusher.Flush()
		}
	}
}

// parseCSVSet splits a comma-separated string into a set for O(1) lookups.
// Returns nil if the input is empty (meaning "no filter / match all").
func parseCSVSet(s string) map[string]struct{} {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	set := make(map[string]struct{}, len(parts))
	for _, p := range parts {
		if v := strings.TrimSpace(p); v != "" {
			set[v] = struct{}{}
		}
	}
	if len(set) == 0 {
		return nil
	}
	return set
}

// matchSSEFilter returns true if the event matches all active filters.
// A nil filter means "match all" for that dimension.
func matchSSEFilter(ev map[string]any, queues, jobIDs, types map[string]struct{}) bool {
	if queues != nil {
		q, _ := ev["queue"].(string)
		if _, ok := queues[q]; !ok {
			return false
		}
	}
	if jobIDs != nil {
		j, _ := ev["job_id"].(string)
		if _, ok := jobIDs[j]; !ok {
			return false
		}
	}
	if types != nil {
		t, _ := ev["type"].(string)
		if _, ok := types[t]; !ok {
			return false
		}
	}
	return true
}
