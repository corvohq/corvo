package server

import (
	"bufio"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/corvohq/corvo/internal/store"
)

type authPrincipal struct {
	KeyHash    string
	Name       string
	Namespace  string
	Role       string
	QueueScope string
	Roles      []string
}

type ctxKey string

const (
	ctxPrincipalKey ctxKey = "auth_principal"
)

func hashAPIKey(v string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(v)))
	return hex.EncodeToString(sum[:])
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, status, code, msg := s.resolvePrincipal(r)
		if status != 0 {
			writeError(w, status, msg, code)
			return
		}
		ctx := context.WithValue(r.Context(), ctxPrincipalKey, p)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func principalFromContext(ctx context.Context) authPrincipal {
	if ctx == nil {
		return authPrincipal{Namespace: "default", Role: "admin"}
	}
	if v, ok := ctx.Value(ctxPrincipalKey).(authPrincipal); ok {
		if strings.TrimSpace(v.Namespace) == "" {
			v.Namespace = "default"
		}
		if strings.TrimSpace(v.Role) == "" {
			v.Role = "admin"
		}
		return v
	}
	return authPrincipal{Namespace: "default", Role: "admin"}
}

// resolveCredential extracts an API key or admin password from the request.
// Checks X-API-Key header, Authorization: Bearer, and corvo_api_key cookie
// (for EventSource/SSE which cannot set custom headers).
func resolveCredential(r *http.Request) string {
	if key := strings.TrimSpace(r.Header.Get("X-API-Key")); key != "" {
		return key
	}
	if authz := strings.TrimSpace(r.Header.Get("Authorization")); strings.HasPrefix(strings.ToLower(authz), "bearer ") {
		if key := strings.TrimSpace(authz[len("Bearer "):]); key != "" {
			return key
		}
	}
	if c, err := r.Cookie("corvo_api_key"); err == nil {
		if key := strings.TrimSpace(c.Value); key != "" {
			return key
		}
	}
	return ""
}

func (s *Server) resolvePrincipal(r *http.Request) (authPrincipal, int, string, string) {
	defaults := authPrincipal{Namespace: "default", Role: "admin", Name: "anonymous"}
	if s.store == nil || s.store.ReadDB() == nil {
		return defaults, 0, "", ""
	}
	s.authMu.RLock()
	oidc := s.oidcAuth
	saml := s.samlAuth
	s.authMu.RUnlock()
	if oidc != nil {
		if p, ok := s.resolveOIDCPrincipal(r); ok {
			if !s.isAuthorized(p, r.Method, r.URL.Path) {
				return authPrincipal{}, http.StatusForbidden, "FORBIDDEN", "insufficient role permissions"
			}
			return p, 0, "", ""
		}
	}
	if saml != nil {
		if p, ok := s.resolveSAMLPrincipal(r); ok {
			if !s.isAuthorized(p, r.Method, r.URL.Path) {
				return authPrincipal{}, http.StatusForbidden, "FORBIDDEN", "insufficient role permissions"
			}
			return p, 0, "", ""
		}
	}
	// Extract credential from X-API-Key header, Authorization: Bearer, or ?api_key query param.
	cred := resolveCredential(r)

	// Admin password bypass — always grants full admin access.
	if s.adminPassword != "" && cred == s.adminPassword {
		p := authPrincipal{Name: "admin", Namespace: "default", Role: "admin"}
		ns := strings.TrimSpace(r.Header.Get("X-Corvo-Namespace"))
		if ns != "" {
			p.Namespace = ns
		}
		return p, 0, "", ""
	}
	db := s.store.ReadDB()
	var keyCount int
	if err := db.QueryRow("SELECT COUNT(*) FROM api_keys WHERE enabled = 1").Scan(&keyCount); err != nil {
		return defaults, 0, "", ""
	}
	if keyCount == 0 && s.adminPassword == "" {
		ns := strings.TrimSpace(r.Header.Get("X-Corvo-Namespace"))
		if ns != "" {
			defaults.Namespace = ns
		}
		return defaults, 0, "", ""
	}

	if cred == "" {
		return authPrincipal{}, http.StatusUnauthorized, "UNAUTHORIZED", "missing API key"
	}
	apiKey := cred
	h := hashAPIKey(apiKey)
	var p authPrincipal
	var enabled int
	var expiresAt sql.NullString
	err := db.QueryRow(`
		SELECT key_hash, name, namespace, role, queue_scope, enabled, expires_at
		FROM api_keys WHERE key_hash = ?
	`, h).Scan(&p.KeyHash, &p.Name, &p.Namespace, &p.Role, &p.QueueScope, &enabled, &expiresAt)
	if err == sql.ErrNoRows || enabled == 0 {
		return authPrincipal{}, http.StatusUnauthorized, "UNAUTHORIZED", "invalid API key"
	}
	if err != nil {
		return authPrincipal{}, http.StatusUnauthorized, "UNAUTHORIZED", "invalid API key"
	}
	if strings.TrimSpace(p.Namespace) == "" {
		p.Namespace = "default"
	}
	if strings.TrimSpace(p.Role) == "" {
		p.Role = "readonly"
	}
	if expiresAt.Valid {
		ts := strings.TrimSpace(expiresAt.String)
		if ts != "" {
			if exp, err := time.Parse(time.RFC3339Nano, ts); err == nil && time.Now().UTC().After(exp.UTC()) {
				return authPrincipal{}, http.StatusUnauthorized, "UNAUTHORIZED", "expired API key"
			}
		}
	}
	p.Roles = s.listAssignedRoles(p.KeyHash)
	if !s.isAuthorized(p, r.Method, r.URL.Path) {
		return authPrincipal{}, http.StatusForbidden, "FORBIDDEN", "insufficient role permissions"
	}
	s.store.UpdateAPIKeyLastUsed(store.UpdateAPIKeyUsedOp{
		KeyHash: p.KeyHash,
		Now:     time.Now().UTC().Format(time.RFC3339Nano),
	})
	return p, 0, "", ""
}

func (s *Server) isAuthorized(p authPrincipal, method, path string) bool {
	if isRoleAllowed(p.Role, method, path) {
		return true
	}
	if s.license == nil || !s.license.HasFeature("rbac") {
		return false
	}
	if len(p.Roles) == 0 {
		return false
	}
	resource, action := permissionForRoute(method, path)
	if resource == "" || action == "" {
		return false
	}
	perms := s.listPermissionsForRoles(p.Roles)
	return permissionAllows(perms, resource, action)
}

func isRoleAllowed(role, method, path string) bool {
	role = strings.ToLower(strings.TrimSpace(role))
	if role == "admin" {
		return true
	}
	if role == "readonly" {
		return method == http.MethodGet
	}
	if role == "worker" {
		if method != http.MethodPost {
			return method == http.MethodGet && strings.Contains(path, "/jobs/")
		}
		for _, allow := range []string{"/enqueue", "/fetch", "/ack", "/fail", "/heartbeat"} {
			if strings.Contains(path, allow) {
				return true
			}
		}
		return false
	}
	if role == "operator" {
		if strings.Contains(path, "/auth/keys") {
			return method == http.MethodGet
		}
		return true
	}
	return false
}

func namespaceQueue(ns, queue string) string {
	ns = strings.TrimSpace(ns)
	if ns == "" || ns == "default" {
		return queue
	}
	if strings.Contains(queue, "::") {
		return queue
	}
	return ns + "::" + queue
}

func visibleQueue(ns, queue string) string {
	ns = strings.TrimSpace(ns)
	if ns == "" || ns == "default" {
		return queue
	}
	prefix := ns + "::"
	if strings.HasPrefix(queue, prefix) {
		return strings.TrimPrefix(queue, prefix)
	}
	return queue
}

func isDefaultNamespace(ns string) bool {
	ns = strings.TrimSpace(ns)
	return ns == "" || ns == "default"
}

func enforceNamespaceJob(ns string, jobQueue string) bool {
	if isDefaultNamespace(ns) {
		return true
	}
	return strings.HasPrefix(jobQueue, ns+"::")
}

// enforceJobNamespace checks that the caller's namespace has access to the
// given job. For default-namespace callers it skips the read-path GetJob
// lookup entirely, avoiding raft read-lag issues.
func (s *Server) enforceJobNamespace(principal authPrincipal, jobID string) bool {
	if isDefaultNamespace(principal.Namespace) {
		return true
	}
	job, err := s.store.GetJob(jobID)
	if err != nil {
		return false
	}
	return enforceNamespaceJob(principal.Namespace, job.Queue)
}

func (s *Server) auditLogMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(ww, r)
		if r.Method == http.MethodGet || r.Method == http.MethodHead || s.store == nil || s.store.ReadDB() == nil {
			return
		}
		// Skip worker hot-path and read-only POST routes from audit logs.
		// Audit logs are for user/operator actions, not worker polling.
		switch r.URL.Path {
		case "/api/v1/jobs/search",
			"/api/v1/enqueue", "/api/v1/enqueue/batch",
			"/api/v1/fetch", "/api/v1/fetch/batch",
			"/api/v1/heartbeat",
			"/api/v1/ack/batch":
			return
		}
		if strings.HasPrefix(r.URL.Path, "/api/v1/ack/") ||
			strings.HasPrefix(r.URL.Path, "/api/v1/fail/") {
			return
		}
		p := principalFromContext(r.Context())
		meta, _ := json.Marshal(map[string]any{
			"duration_ms": time.Since(start).Milliseconds(),
			"query":       r.URL.RawQuery,
		})
		s.store.InsertAuditLog(store.InsertAuditLogOp{
			Namespace:  p.Namespace,
			Principal:  p.Name,
			Role:       p.Role,
			Method:     r.Method,
			Path:       r.URL.Path,
			StatusCode: ww.status,
			Metadata:   string(meta),
			CreatedAt:  time.Now().UTC().Format(time.RFC3339Nano),
		})
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (w *statusRecorder) WriteHeader(status int) {
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusRecorder) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if h, ok := w.ResponseWriter.(http.Hijacker); ok {
		return h.Hijack()
	}
	return nil, nil, fmt.Errorf("hijacker unsupported")
}

func (s *Server) listAPIKeys() ([]map[string]any, error) {
	rows, err := s.store.ReadDB().Query(`
		SELECT key_hash, name, namespace, role, queue_scope, enabled, created_at, last_used_at, expires_at
		FROM api_keys ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer func() { _ = rows.Close() }()
	out := []map[string]any{}
	for rows.Next() {
		var keyHash, name, ns, role string
		var scope sql.NullString
		var enabled int
		var createdAt string
		var lastUsed sql.NullString
		var expiresAt sql.NullString
		if err := rows.Scan(&keyHash, &name, &ns, &role, &scope, &enabled, &createdAt, &lastUsed, &expiresAt); err != nil {
			return nil, err
		}
		item := map[string]any{
			"key_hash":   keyHash,
			"name":       name,
			"namespace":  ns,
			"role":       role,
			"enabled":    enabled == 1,
			"created_at": createdAt,
		}
		if scope.Valid {
			item["queue_scope"] = scope.String
		}
		if lastUsed.Valid {
			item["last_used_at"] = lastUsed.String
		}
		if expiresAt.Valid {
			item["expires_at"] = expiresAt.String
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Server) upsertAPIKey(name, key, namespace, role, queueScope, expiresAt string, enabled bool) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", fmt.Errorf("name is required")
	}
	if strings.TrimSpace(key) == "" {
		key = "sk_" + strings.ReplaceAll(strings.ToLower(store.NewJobID()), "job_", "")
	}
	if strings.TrimSpace(namespace) == "" {
		namespace = "default"
	}
	if strings.TrimSpace(role) == "" {
		role = "readonly"
	}
	expiresAt = strings.TrimSpace(expiresAt)
	if expiresAt != "" {
		if _, err := time.Parse(time.RFC3339Nano, expiresAt); err != nil {
			return "", fmt.Errorf("expires_at must be RFC3339 timestamp")
		}
	}
	h := hashAPIKey(key)
	if err := s.store.UpsertAPIKey(store.UpsertAPIKeyOp{
		KeyHash:    h,
		Name:       name,
		Namespace:  namespace,
		Role:       role,
		QueueScope: strings.TrimSpace(queueScope),
		Enabled:    boolToInt(enabled),
		CreatedAt:  time.Now().UTC().Format(time.RFC3339Nano),
		ExpiresAt:  strings.TrimSpace(expiresAt),
	}); err != nil {
		return "", err
	}
	return key, nil
}

func (s *Server) deleteAPIKey(keyHash string) error {
	return s.store.DeleteAPIKey(strings.TrimSpace(keyHash))
}
