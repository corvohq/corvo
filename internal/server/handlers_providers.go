package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/user/jobbie/internal/store"
)

func (s *Server) handleListProviders(w http.ResponseWriter, r *http.Request) {
	out, err := s.store.ListProviders()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "PROVIDER_ERROR")
		return
	}
	if out == nil {
		out = []store.Provider{}
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleSetProvider(w http.ResponseWriter, r *http.Request) {
	var req store.SetProviderRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	out, err := s.store.SetProvider(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "PROVIDER_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleDeleteProvider(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "name")
	if err := s.store.DeleteProvider(name); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "PROVIDER_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "deleted"})
}

func (s *Server) handleSetQueueProvider(w http.ResponseWriter, r *http.Request) {
	queue := chi.URLParam(r, "name")
	var req struct {
		Provider string `json:"provider"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if err := s.store.SetQueueProvider(queue, req.Provider); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "PROVIDER_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
