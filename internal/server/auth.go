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

	"github.com/user/jobbie/internal/store"
)

type authPrincipal struct {
	KeyHash    string
	Name       string
	Namespace  string
	Role       string
	QueueScope string
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

func (s *Server) resolvePrincipal(r *http.Request) (authPrincipal, int, string, string) {
	defaults := authPrincipal{Namespace: "default", Role: "admin", Name: "anonymous"}
	if s.store == nil || s.store.ReadDB() == nil {
		return defaults, 0, "", ""
	}
	db := s.store.ReadDB()
	var keyCount int
	if err := db.QueryRow("SELECT COUNT(*) FROM api_keys WHERE enabled = 1").Scan(&keyCount); err != nil {
		return defaults, 0, "", ""
	}
	if keyCount == 0 {
		ns := strings.TrimSpace(r.Header.Get("X-Jobbie-Namespace"))
		if ns != "" {
			defaults.Namespace = ns
		}
		return defaults, 0, "", ""
	}

	apiKey := strings.TrimSpace(r.Header.Get("X-API-Key"))
	if apiKey == "" {
		return authPrincipal{}, http.StatusUnauthorized, "UNAUTHORIZED", "missing API key"
	}
	h := hashAPIKey(apiKey)
	var p authPrincipal
	var enabled int
	err := db.QueryRow(`
		SELECT key_hash, name, namespace, role, queue_scope, enabled
		FROM api_keys WHERE key_hash = ?
	`, h).Scan(&p.KeyHash, &p.Name, &p.Namespace, &p.Role, &p.QueueScope, &enabled)
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
	if !isRoleAllowed(p.Role, r.Method, r.URL.Path) {
		return authPrincipal{}, http.StatusForbidden, "FORBIDDEN", "insufficient role permissions"
	}
	_, _ = db.Exec("UPDATE api_keys SET last_used_at = ? WHERE key_hash = ?", time.Now().UTC().Format(time.RFC3339Nano), p.KeyHash)
	return p, 0, "", ""
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

func enforceNamespaceJob(ns string, jobQueue string) bool {
	ns = strings.TrimSpace(ns)
	if ns == "" || ns == "default" {
		return true
	}
	return strings.HasPrefix(jobQueue, ns+"::")
}

func (s *Server) auditLogMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := &statusRecorder{ResponseWriter: w, status: 200}
		next.ServeHTTP(ww, r)
		if r.Method == http.MethodGet || r.Method == http.MethodHead || s.store == nil || s.store.ReadDB() == nil {
			return
		}
		p := principalFromContext(r.Context())
		meta, _ := json.Marshal(map[string]any{
			"duration_ms": time.Since(start).Milliseconds(),
			"query":       r.URL.RawQuery,
		})
		_, _ = s.store.ReadDB().Exec(`
			INSERT INTO audit_logs (namespace, principal, role, method, path, status_code, metadata, created_at)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?)
		`, p.Namespace, p.Name, p.Role, r.Method, r.URL.Path, ww.status, string(meta), time.Now().UTC().Format(time.RFC3339Nano))
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
		SELECT key_hash, name, namespace, role, queue_scope, enabled, created_at, last_used_at
		FROM api_keys ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []map[string]any{}
	for rows.Next() {
		var keyHash, name, ns, role string
		var scope sql.NullString
		var enabled int
		var createdAt string
		var lastUsed sql.NullString
		if err := rows.Scan(&keyHash, &name, &ns, &role, &scope, &enabled, &createdAt, &lastUsed); err != nil {
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
		out = append(out, item)
	}
	return out, rows.Err()
}

func (s *Server) upsertAPIKey(name, key, namespace, role, queueScope string, enabled bool) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", fmt.Errorf("name is required")
	}
	if strings.TrimSpace(key) == "" {
		key = "jk_" + strings.ReplaceAll(strings.ToLower(store.NewJobID()), "job_", "")
	}
	if strings.TrimSpace(namespace) == "" {
		namespace = "default"
	}
	if strings.TrimSpace(role) == "" {
		role = "readonly"
	}
	h := hashAPIKey(key)
	_, err := s.store.ReadDB().Exec(`
		INSERT INTO api_keys (key_hash, name, namespace, role, queue_scope, enabled, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(key_hash) DO UPDATE SET
			name = excluded.name,
			namespace = excluded.namespace,
			role = excluded.role,
			queue_scope = excluded.queue_scope,
			enabled = excluded.enabled
	`, h, name, namespace, role, strings.TrimSpace(queueScope), boolToInt(enabled), time.Now().UTC().Format(time.RFC3339Nano))
	if err != nil {
		return "", err
	}
	return key, nil
}

func (s *Server) deleteAPIKey(keyHash string) error {
	_, err := s.store.ReadDB().Exec("DELETE FROM api_keys WHERE key_hash = ?", strings.TrimSpace(keyHash))
	return err
}
