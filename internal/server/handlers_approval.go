package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/corvohq/corvo/internal/store"
)

// @Summary List approval policies
// @Tags Approvals
// @Produce json
// @Success 200 {array} store.ApprovalPolicy
// @Security ApiKeyAuth
// @Router /approval-policies [get]
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

// @Summary Create or update an approval policy
// @Description Configures human-in-the-loop review for jobs. Jobs matching the policy will be held awaiting approval before processing.
// @Tags Approvals
// @Accept json
// @Produce json
// @Param body body store.SetApprovalPolicyRequest true "Approval policy request"
// @Success 200 {object} store.ApprovalPolicy
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /approval-policies [post]
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

// @Summary Delete an approval policy
// @Tags Approvals
// @Produce json
// @Param id path string true "Policy ID"
// @Success 200 {object} StatusResponse
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /approval-policies/{id} [delete]
func (s *Server) handleDeleteApprovalPolicy(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if err := s.store.DeleteApprovalPolicy(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "POLICY_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}
