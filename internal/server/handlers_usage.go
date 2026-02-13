package server

import (
	"net/http"
	"time"

	"github.com/user/jobbie/internal/store"
)

func (s *Server) handleUsageSummary(w http.ResponseWriter, r *http.Request) {
	req := store.UsageSummaryRequest{
		Period:  r.URL.Query().Get("period"),
		GroupBy: r.URL.Query().Get("group_by"),
		Now:     time.Now(),
	}
	res, err := s.store.UsageSummary(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "USAGE_SUMMARY_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, res)
}
