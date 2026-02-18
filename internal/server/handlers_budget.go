package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/corvohq/corvo/internal/store"
)

// @Summary List budgets
// @Tags Budgets
// @Produce json
// @Success 200 {array} store.Budget
// @Failure 500 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /budgets [get]
func (s *Server) handleListBudgets(w http.ResponseWriter, r *http.Request) {
	out, err := s.store.ListBudgets()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "BUDGET_ERROR")
		return
	}
	if out == nil {
		out = []store.Budget{}
	}
	writeJSON(w, http.StatusOK, out)
}

// @Summary Create or update a budget
// @Description Sets a spending cap for AI/agent jobs by queue or globally. Jobs exceeding the budget will be failed with BUDGET_EXCEEDED.
// @Tags Budgets
// @Accept json
// @Produce json
// @Param body body store.SetBudgetRequest true "Budget request"
// @Success 200 {object} store.Budget
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /budgets [post]
func (s *Server) handleSetBudget(w http.ResponseWriter, r *http.Request) {
	var req store.SetBudgetRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	out, err := s.store.SetBudget(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "BUDGET_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// @Summary Delete a budget
// @Tags Budgets
// @Produce json
// @Param scope path string true "Scope: queue or global"
// @Param target path string true "Queue name or * for global"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /budgets/{scope}/{target} [delete]
func (s *Server) handleDeleteBudget(w http.ResponseWriter, r *http.Request) {
	scope := chi.URLParam(r, "scope")
	target := chi.URLParam(r, "target")
	if err := s.store.DeleteBudget(scope, target); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "BUDGET_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
