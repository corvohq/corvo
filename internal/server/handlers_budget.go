package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/corvohq/corvo/internal/store"
)

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

func (s *Server) handleDeleteBudget(w http.ResponseWriter, r *http.Request) {
	scope := chi.URLParam(r, "scope")
	target := chi.URLParam(r, "target")
	if err := s.store.DeleteBudget(scope, target); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "BUDGET_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
