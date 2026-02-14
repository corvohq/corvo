package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"
)

type OIDCConfig struct {
	IssuerURL string
	ClientID  string
}

type oidcAuthenticator struct {
	verifier *oidc.IDTokenVerifier
}

func newOIDCAuthenticator(ctx context.Context, cfg OIDCConfig) (*oidcAuthenticator, error) {
	provider, err := oidc.NewProvider(ctx, strings.TrimSpace(cfg.IssuerURL))
	if err != nil {
		return nil, err
	}
	verifier := provider.Verifier(&oidc.Config{ClientID: strings.TrimSpace(cfg.ClientID)})
	return &oidcAuthenticator{verifier: verifier}, nil
}

func (s *Server) resolveOIDCPrincipal(r *http.Request) (authPrincipal, bool) {
	authz := strings.TrimSpace(r.Header.Get("Authorization"))
	if !strings.HasPrefix(strings.ToLower(authz), "bearer ") {
		return authPrincipal{}, false
	}
	raw := strings.TrimSpace(authz[len("Bearer "):])
	if raw == "" {
		return authPrincipal{}, false
	}
	idToken, err := s.oidcAuth.verifier.Verify(r.Context(), raw)
	if err != nil {
		slog.Debug("oidc token rejected", "error", err)
		return authPrincipal{}, false
	}
	var claims map[string]any
	if err := idToken.Claims(&claims); err != nil {
		return authPrincipal{}, false
	}
	p := authPrincipal{
		Name:      claimString(claims, "email", "preferred_username", "sub"),
		Namespace: claimString(claims, "corvo_namespace", "namespace"),
		Role:      claimString(claims, "corvo_role", "role"),
	}
	if p.Name == "" {
		p.Name = "oidc-user"
	}
	if p.Namespace == "" {
		p.Namespace = "default"
	}
	if p.Role == "" {
		p.Role = "readonly"
	}
	if rawRoles, ok := claims["corvo_roles"]; ok {
		p.Roles = claimsStringSlice(rawRoles)
	}
	return p, true
}

type SAMLHeaderConfig struct {
	Enabled         bool
	SubjectHeader   string
	RoleHeader      string
	NamespaceHeader string
	RolesHeader     string
}

type samlHeaderAuthenticator struct {
	enabled         bool
	subjectHeader   string
	roleHeader      string
	namespaceHeader string
	rolesHeader     string
}

func newSAMLHeaderAuthenticator(cfg SAMLHeaderConfig) *samlHeaderAuthenticator {
	if !cfg.Enabled {
		return nil
	}
	subject := strings.TrimSpace(cfg.SubjectHeader)
	if subject == "" {
		subject = "X-Corvo-SAML-Subject"
	}
	role := strings.TrimSpace(cfg.RoleHeader)
	if role == "" {
		role = "X-Corvo-SAML-Role"
	}
	ns := strings.TrimSpace(cfg.NamespaceHeader)
	if ns == "" {
		ns = "X-Corvo-SAML-Namespace"
	}
	roles := strings.TrimSpace(cfg.RolesHeader)
	if roles == "" {
		roles = "X-Corvo-SAML-Roles"
	}
	return &samlHeaderAuthenticator{
		enabled:         true,
		subjectHeader:   subject,
		roleHeader:      role,
		namespaceHeader: ns,
		rolesHeader:     roles,
	}
}

func (s *Server) resolveSAMLPrincipal(r *http.Request) (authPrincipal, bool) {
	if s.samlAuth == nil || !s.samlAuth.enabled {
		return authPrincipal{}, false
	}
	name := strings.TrimSpace(r.Header.Get(s.samlAuth.subjectHeader))
	if name == "" {
		return authPrincipal{}, false
	}
	p := authPrincipal{
		Name:      name,
		Role:      strings.TrimSpace(r.Header.Get(s.samlAuth.roleHeader)),
		Namespace: strings.TrimSpace(r.Header.Get(s.samlAuth.namespaceHeader)),
	}
	if p.Role == "" {
		p.Role = "readonly"
	}
	if p.Namespace == "" {
		p.Namespace = "default"
	}
	if raw := strings.TrimSpace(r.Header.Get(s.samlAuth.rolesHeader)); raw != "" {
		for _, part := range strings.Split(raw, ",") {
			part = strings.TrimSpace(part)
			if part != "" {
				p.Roles = append(p.Roles, part)
			}
		}
	}
	return p, true
}

func claimString(claims map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := claims[k]; ok {
			if s, ok := v.(string); ok {
				return strings.TrimSpace(s)
			}
		}
	}
	return ""
}

func claimsStringSlice(v any) []string {
	out := []string{}
	switch x := v.(type) {
	case []any:
		for _, it := range x {
			if s, ok := it.(string); ok && strings.TrimSpace(s) != "" {
				out = append(out, strings.TrimSpace(s))
			}
		}
	case []string:
		for _, s := range x {
			if strings.TrimSpace(s) != "" {
				out = append(out, strings.TrimSpace(s))
			}
		}
	case string:
		if strings.HasPrefix(strings.TrimSpace(x), "[") {
			var arr []string
			if err := json.Unmarshal([]byte(x), &arr); err == nil {
				for _, s := range arr {
					if strings.TrimSpace(s) != "" {
						out = append(out, strings.TrimSpace(s))
					}
				}
			}
		}
	}
	return out
}
