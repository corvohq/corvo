package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/user/corvo/internal/store"
)

func (s *Server) handleListApprovalPolicies(w http.ResponseWriter, r *http.Request) {
	out, err := s.store.ListApprovalPolicies()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "POLICY_ERROR")
		return
	}
	if out == nil {
		out = []store.ApprovalPolicy{}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleSetApprovalPolicy(w http.ResponseWriter, r *http.Request) {
	var req store.SetApprovalPolicyRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	out, err := s.store.SetApprovalPolicy(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "POLICY_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleDeleteApprovalPolicy(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if err := s.store.DeleteApprovalPolicy(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "POLICY_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
