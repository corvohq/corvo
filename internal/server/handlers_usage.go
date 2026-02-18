package server

import (
	"net/http"
	"time"

	"github.com/corvohq/corvo/internal/store"
)

// @Summary Token and cost usage summary
// @Description Returns aggregate token and cost data for AI/agent jobs.
// @Tags Budgets
// @Produce json
// @Param period query string false "Time period (e.g. 24h, 168h)"
// @Param group_by query string false "Group by field"
// @Success 200 {object} object
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /usage/summary [get]
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
