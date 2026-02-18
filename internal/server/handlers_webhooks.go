package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
)

// @Summary List webhooks
// @Tags System
// @Produce json
// @Success 200 {array} webhookConfig
// @Security ApiKeyAuth
// @Router /webhooks [get]
func (s *Server) handleListWebhooks(w http.ResponseWriter, r *http.Request) {
	items, err := s.listWebhooks()
	if err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "WEBHOOK_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, items)
}

// @Summary Create or update a webhook
// @Tags System
// @Accept json
// @Produce json
// @Param body body webhookConfig true "Webhook config"
// @Success 200 {object} object
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /webhooks [post]
func (s *Server) handleSetWebhook(w http.ResponseWriter, r *http.Request) {
	var req webhookConfig
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	if err := s.upsertWebhook(req); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "WEBHOOK_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok", "id": req.ID})
}

// @Summary Delete a webhook
// @Tags System
// @Produce json
// @Param id path string true "Webhook ID"
// @Success 200 {object} object
// @Failure 400 {object} ErrorResponse
// @Security ApiKeyAuth
// @Router /webhooks/{id} [delete]
func (s *Server) handleDeleteWebhook(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")
	if id == "" {
		writeError(w, http.StatusBadRequest, "id is required", "VALIDATION_ERROR")
		return
	}
	if err := s.deleteWebhook(id); err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "WEBHOOK_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "deleted", "id": id})
}
