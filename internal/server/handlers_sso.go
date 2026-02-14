package server

import (
	"context"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/user/corvo/internal/store"
)

func (s *Server) handleGetSSOSettings(w http.ResponseWriter, r *http.Request) {
	var provider, oidcIssuerURL, oidcClientID string
	var samlEnabled int
	var updatedAt string
	err := s.store.ReadDB().QueryRow(`
		SELECT provider, oidc_issuer_url, oidc_client_id, saml_enabled, updated_at
		FROM sso_settings WHERE id = 'singleton'
	`).Scan(&provider, &oidcIssuerURL, &oidcClientID, &samlEnabled, &updatedAt)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"provider":        "",
			"oidc_issuer_url": "",
			"oidc_client_id":  "",
			"saml_enabled":    false,
		})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"provider":        provider,
		"oidc_issuer_url": oidcIssuerURL,
		"oidc_client_id":  oidcClientID,
		"saml_enabled":    samlEnabled != 0,
		"updated_at":      updatedAt,
	})
}

func (s *Server) handleSetSSOSettings(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Provider       string `json:"provider"`
		OIDCIssuerURL  string `json:"oidc_issuer_url"`
		OIDCClientID   string `json:"oidc_client_id"`
		SAMLEnabled    bool   `json:"saml_enabled"`
	}
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}

	if req.Provider == "oidc" {
		if strings.TrimSpace(req.OIDCIssuerURL) == "" || strings.TrimSpace(req.OIDCClientID) == "" {
			writeError(w, http.StatusBadRequest, "oidc_issuer_url and oidc_client_id are required for OIDC provider", "VALIDATION_ERROR")
			return
		}
		u, err := url.Parse(req.OIDCIssuerURL)
		if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			writeError(w, http.StatusBadRequest, "oidc_issuer_url must be a valid http:// or https:// URL", "VALIDATION_ERROR")
			return
		}
	}

	samlInt := 0
	if req.SAMLEnabled {
		samlInt = 1
	}

	now := time.Now().UTC().Format(time.RFC3339Nano)
	if err := s.store.SetSSOSettings(store.SetSSOSettingsOp{
		Provider:      req.Provider,
		OIDCIssuerURL: req.OIDCIssuerURL,
		OIDCClientID:  req.OIDCClientID,
		SAMLEnabled:   samlInt,
		Now:           now,
	}); err != nil {
		writeError(w, http.StatusInternalServerError, err.Error(), "STORE_ERROR")
		return
	}

	// Hot-reload auth configuration
	s.authMu.Lock()
	defer s.authMu.Unlock()

	switch req.Provider {
	case "oidc":
		if req.OIDCIssuerURL != "" && req.OIDCClientID != "" {
			auth, err := newOIDCAuthenticator(context.Background(), OIDCConfig{
				IssuerURL: req.OIDCIssuerURL,
				ClientID:  req.OIDCClientID,
			})
			if err != nil {
				slog.Warn("failed to reload OIDC auth", "error", err)
			} else {
				s.oidcAuth = auth
				slog.Info("OIDC authenticator reloaded")
			}
		}
		s.samlAuth = nil
	case "saml":
		s.samlAuth = newSAMLHeaderAuthenticator(SAMLHeaderConfig{Enabled: req.SAMLEnabled})
		s.oidcAuth = nil
	default:
		s.oidcAuth = nil
		s.samlAuth = nil
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}
