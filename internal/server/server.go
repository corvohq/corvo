package server

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	netpprof "net/http/pprof"
	"sync"
	"net/http/httputil"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/user/corvo/internal/enterprise"
	"github.com/user/corvo/internal/rpcconnect"
	"github.com/user/corvo/internal/scheduler"
	"github.com/user/corvo/internal/store"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

// Server is the HTTP server for Corvo.
type Server struct {
	store       *store.Store
	cluster     ClusterInfo
	httpServer  *http.Server
	router      chi.Router
	uiFS        fs.FS
	throughput  *ThroughputTracker
	bulkAsync   *asyncBulkManager
	webhookStop chan struct{}
	webhookDone chan struct{}
	license     *enterprise.License
	authMu            sync.RWMutex
	oidcAuth          *oidcAuthenticator
	samlAuth          *samlHeaderAuthenticator
	oidcGroupClaim    string
	oidcGroupMappings map[string]string
	reqMetrics       *requestMetrics
	rateLimiter      *rateLimiter
	streamCfg        *rpcconnect.StreamConfig
	rpcServer        *rpcconnect.Server
	schedulerMetrics *scheduler.Metrics
	adminPassword    string
	bindAddr         string
	h2cTransport     http.RoundTripper
}

// Option mutates server behavior.
type Option func(*Server) error

// WithEnterpriseLicense enables enterprise feature checks.
func WithEnterpriseLicense(lic *enterprise.License) Option {
	return func(s *Server) error {
		s.license = lic
		return nil
	}
}

// WithAdminPassword sets a global admin password that always grants full access.
func WithAdminPassword(pw string) Option {
	return func(s *Server) error {
		s.adminPassword = pw
		return nil
	}
}

// WithOIDCAuth enables OIDC bearer-token auth.
func WithOIDCAuth(cfg OIDCConfig) Option {
	return func(s *Server) error {
		if strings.TrimSpace(cfg.IssuerURL) == "" || strings.TrimSpace(cfg.ClientID) == "" {
			return fmt.Errorf("oidc issuer_url and client_id are required")
		}
		auth, err := newOIDCAuthenticator(context.Background(), cfg)
		if err != nil {
			return err
		}
		s.oidcAuth = auth
		return nil
	}
}

// WithSAMLHeaderAuth enables trusted-proxy SAML header auth mode.
func WithSAMLHeaderAuth(cfg SAMLHeaderConfig) Option {
	return func(s *Server) error {
		s.samlAuth = newSAMLHeaderAuthenticator(cfg)
		return nil
	}
}

// WithRateLimit configures server-side per-client request rate limiting.
func WithRateLimit(cfg RateLimitConfig) Option {
	return func(s *Server) error {
		s.rateLimiter = newRateLimiter(cfg)
		return nil
	}
}

// WithSchedulerMetrics sets the scheduler metrics for Prometheus export.
func WithSchedulerMetrics(m *scheduler.Metrics) Option {
	return func(s *Server) error {
		s.schedulerMetrics = m
		return nil
	}
}

// WithRPCStreamConfig overrides lifecycle stream admission settings.
func WithRPCStreamConfig(cfg rpcconnect.StreamConfig) Option {
	return func(s *Server) error {
		c := cfg
		s.streamCfg = &c
		return nil
	}
}

// ClusterInfo contains cluster state methods used by HTTP handlers/middleware.
type ClusterInfo interface {
	IsLeader() bool
	LeaderAddr() string
	ClusterStatus() map[string]any
	State() string
	EventLog(afterSeq uint64, limit int) ([]map[string]any, error)
	RebuildSQLiteFromPebble() error
}

type shardLeaderInfo interface {
	ShardCount() int
	IsLeaderForShard(shard int) bool
	LeaderAddrForShard(shard int) string
	ShardForQueue(queue string) int
	ShardForJobID(jobID string) (int, bool)
}

var errMixedShardLeaders = errors.New("request spans local and remote shard leaders; split request by shard")

// New creates a new Server.
// If uiAssets is non-nil the embedded SPA will be served at /ui/.
func New(s *store.Store, cluster ClusterInfo, bindAddr string, uiAssets fs.FS, opts ...Option) *Server {
	srv := &Server{
		store:       s,
		cluster:     cluster,
		uiFS:        uiAssets,
		throughput:  NewThroughputTracker(),
		bulkAsync:   newAsyncBulkManager(s),
		webhookStop: make(chan struct{}),
		webhookDone: make(chan struct{}),
		reqMetrics:  newRequestMetrics(),
		rateLimiter: newRateLimiter(RateLimitConfig{Enabled: true}),
		bindAddr:    bindAddr,
		h2cTransport: &http2.Transport{
			AllowHTTP: true,
			DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
				return (&net.Dialer{
					Timeout:   5 * time.Second,
					KeepAlive: 30 * time.Second,
				}).DialContext(ctx, network, addr)
			},
			ReadIdleTimeout: 30 * time.Second,
			PingTimeout:     10 * time.Second,
		},
	}
	for _, opt := range opts {
		if opt == nil {
			continue
		}
		if err := opt(srv); err != nil {
			slog.Warn("server option ignored", "error", err)
		}
	}
	if srv.rateLimiter != nil && srv.store != nil {
		srv.rateLimiter.setDBLoader(func() (*sql.DB, bool) {
			db := srv.store.ReadDB()
			return db, db != nil
		})
	}
	srv.router = srv.buildRouter()
	srv.httpServer = &http.Server{
		Addr: bindAddr,
		Handler: h2c.NewHandler(srv.router, &http2.Server{
			MaxConcurrentStreams: 2048,
		}),
	}
	return srv
}

func (s *Server) buildRouter() chi.Router {
	r := chi.NewRouter()

	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(s.rateLimitMiddleware)
	r.Use(s.requestMetricsMiddleware)
	r.Use(structuredLogger)
	r.Use(otelHTTPMiddleware)
	r.Use(middleware.Recoverer)
	r.Use(corsMiddleware)
	r.Use(s.auditLogMiddleware)

	r.Route("/api/v1", func(r chi.Router) {
		r.Use(s.authMiddleware)
		// Read endpoints
		r.Get("/queues", s.handleListQueues)
		r.Get("/jobs/{id}", s.handleGetJob)
		r.Get("/jobs/{id}/iterations", s.handleListJobIterations)
		r.Post("/jobs/search", s.handleSearch)
		r.Get("/search/fulltext", s.handleFullTextSearch)
		r.Get("/workers", s.handleListWorkers)
		r.Get("/cluster/status", s.handleClusterStatus)
		r.Get("/cluster/events", s.handleClusterEvents)
		r.Get("/events", s.handleSSE)
		r.Get("/metrics", s.handlePrometheusMetrics)
		r.Get("/metrics/throughput", s.handleThroughput)
		r.Get("/usage/summary", s.handleUsageSummary)
		r.Get("/budgets", s.handleListBudgets)
		r.Get("/approval-policies", s.handleListApprovalPolicies)
		r.Get("/webhooks", s.handleListWebhooks)
		r.Get("/auth/status", s.handleAuthStatus)
		r.Get("/auth/keys", s.handleListAPIKeys)
		r.Get("/audit-logs", s.requireEnterpriseFeature("audit", s.handleListAuditLogs))
		r.Get("/auth/roles", s.requireEnterpriseFeature("rbac", s.handleListAuthRoles))
		r.Get("/auth/keys/{key_hash}/roles", s.requireEnterpriseFeature("rbac", s.handleListAPIKeyRoles))
		r.Get("/namespaces", s.requireEnterpriseFeature("namespaces", s.handleListNamespaces))
		r.Get("/settings/sso", s.requireEnterpriseFeature("sso", s.handleGetSSOSettings))
		r.Get("/org", s.handleGetOrg)
		r.Get("/org/members", s.handleListMembers)
		r.Get("/org/api-keys", s.handleListOrgAPIKeys)
		r.Get("/billing/summary", s.handleBillingSummary)
		r.Get("/debug/runtime", s.handleDebugRuntime)

		// Write endpoints (leader only when clustered)
		r.Group(func(r chi.Router) {
			r.Use(s.requireLeader)

			// Worker endpoints
			r.Post("/enqueue", s.handleEnqueue)
			r.Post("/enqueue/batch", s.handleEnqueueBatch)
			r.Post("/fetch", s.handleFetch)
			r.Post("/fetch/batch", s.handleFetchBatch)
			r.Post("/ack/batch", s.handleAckBatch)
			r.Post("/ack/{job_id}", s.handleAck)
			r.Post("/fail/{job_id}", s.handleFail)
			r.Post("/heartbeat", s.handleHeartbeat)
			r.Post("/budgets", s.handleSetBudget)
			r.Delete("/budgets/{scope}/{target}", s.handleDeleteBudget)
			r.Post("/approval-policies", s.handleSetApprovalPolicy)
			r.Delete("/approval-policies/{id}", s.handleDeleteApprovalPolicy)
			r.Post("/webhooks", s.handleSetWebhook)
			r.Delete("/webhooks/{id}", s.handleDeleteWebhook)
			r.Put("/org", s.handleUpdateOrg)
			r.Delete("/org/members/{id}", s.handleRemoveMember)
			r.Post("/org/api-keys", s.handleCreateOrgAPIKey)
			r.Delete("/org/api-keys/{id}", s.handleDeleteOrgAPIKey)
			r.Post("/auth/keys", s.handleSetAPIKey)
			r.Delete("/auth/keys", s.handleDeleteAPIKey)
			r.Post("/auth/roles", s.requireEnterpriseFeature("rbac", s.handleSetAuthRole))
			r.Delete("/auth/roles/{name}", s.requireEnterpriseFeature("rbac", s.handleDeleteAuthRole))
			r.Post("/auth/keys/{key_hash}/roles", s.requireEnterpriseFeature("rbac", s.handleAssignAPIKeyRole))
			r.Delete("/auth/keys/{key_hash}/roles/{role}", s.requireEnterpriseFeature("rbac", s.handleUnassignAPIKeyRole))
			r.Post("/namespaces", s.requireEnterpriseFeature("namespaces", s.handleCreateNamespace))
			r.Delete("/namespaces/{name}", s.requireEnterpriseFeature("namespaces", s.handleDeleteNamespace))
			r.Put("/namespaces/{name}/rate-limit", s.requireEnterpriseFeature("namespaces", s.handleSetNamespaceRateLimit))
			r.Get("/namespaces/{name}/rate-limit", s.requireEnterpriseFeature("namespaces", s.handleGetNamespaceRateLimit))
			r.Post("/settings/sso", s.requireEnterpriseFeature("sso", s.handleSetSSOSettings))
			r.Get("/admin/backup", s.handleTenantBackup)
			r.Post("/admin/restore", s.handleTenantRestore)

			// Queue management
			r.Post("/queues/{name}/pause", s.handlePauseQueue)
			r.Post("/queues/{name}/resume", s.handleResumeQueue)
			r.Post("/queues/{name}/clear", s.handleClearQueue)
			r.Post("/queues/{name}/drain", s.handleDrainQueue)
			r.Post("/queues/{name}/concurrency", s.handleSetConcurrency)
			r.Post("/queues/{name}/throttle", s.handleSetThrottle)
			r.Delete("/queues/{name}/throttle", s.handleRemoveThrottle)
			r.Delete("/queues/{name}", s.handleDeleteQueue)

			// Job management
			r.Post("/jobs/{id}/retry", s.handleRetryJob)
			r.Post("/jobs/{id}/cancel", s.handleCancelJob)
			r.Post("/jobs/{id}/hold", s.handleHoldJob)
			r.Post("/jobs/{id}/approve", s.handleApproveJob)
			r.Post("/jobs/{id}/reject", s.handleRejectJob)
			r.Post("/jobs/{id}/replay", s.handleReplayJob)
			r.Post("/jobs/{id}/move", s.handleMoveJob)
			r.Delete("/jobs/{id}", s.handleDeleteJob)

			// Bulk
			r.Post("/jobs/bulk", s.handleBulk)
			r.Get("/bulk/{id}", s.handleBulkStatus)
			r.Get("/bulk/{id}/progress", s.handleBulkProgress)
			r.Post("/admin/rebuild-sqlite", s.handleRebuildSQLite)
			r.Post("/cluster/join", s.handleClusterJoin)
		})

	})

	// Worker lifecycle RPC (Connect: protobuf and JSON fallback).
	var rpcOpts []func(*rpcconnect.Server)
	if s.streamCfg != nil {
		rpcOpts = append(rpcOpts, rpcconnect.WithStreamConfig(*s.streamCfg))
	}
	if s.cluster != nil {
		rpcOpts = append(rpcOpts, rpcconnect.WithLeaderCheck(&leaderCheckAdapter{server: s}))
	}
	rpcPath, rpcHandler, rpcSrv := rpcconnect.NewHandler(s.store, rpcOpts...)
	s.rpcServer = rpcSrv
	r.Group(func(r chi.Router) {
		r.Use(s.requireLeader)
		r.Mount(strings.TrimSuffix(rpcPath, "/"), rpcHandler)
	})

	r.Get("/healthz", s.handleHealthz)
	r.Route("/debug/pprof", func(r chi.Router) {
		r.Get("/", netpprof.Index)
		r.Get("/cmdline", netpprof.Cmdline)
		r.Get("/profile", netpprof.Profile)
		r.Get("/symbol", netpprof.Symbol)
		r.Get("/trace", netpprof.Trace)
		r.Get("/{name}", netpprof.Index)
	})

	// Embedded UI SPA
	if s.uiFS != nil {
		s.mountUI(r)
	}

	return r
}

// mountUI serves the embedded SPA. Static assets are served directly;
// any other /ui/* path gets index.html for client-side routing.
func (s *Server) mountUI(r chi.Router) {
	// Read index.html once at startup for SPA fallback.
	indexHTML, _ := fs.ReadFile(s.uiFS, "index.html")

	r.Get("/ui/*", func(w http.ResponseWriter, r *http.Request) {
		// Strip /ui/ prefix and check if the file exists.
		uiPath := strings.TrimPrefix(r.URL.Path, "/ui/")
		if uiPath == "" {
			uiPath = "index.html"
		}

		// Try to open the file. If it exists, serve it directly.
		f, err := s.uiFS.Open(uiPath)
		if err == nil {
			defer f.Close()
			stat, _ := f.Stat()
			if stat != nil && !stat.IsDir() {
				if strings.HasPrefix(uiPath, "assets/") {
					w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
				} else {
					w.Header().Set("Cache-Control", "no-cache")
				}
				http.ServeContent(w, r, stat.Name(), stat.ModTime(), f.(io.ReadSeeker))
				return
			}
		}

		// File not found — serve index.html for SPA client-side routing.
		if indexHTML == nil {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(indexHTML)
	})

	// Redirect bare /ui to /ui/
	r.Get("/ui", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/ui/", http.StatusMovedPermanently)
	})
}

// Start begins listening for HTTP requests.
func (s *Server) Start() error {
	slog.Info("HTTP server starting", "addr", s.httpServer.Addr)
	go s.webhookDispatcherLoop()
	return s.httpServer.ListenAndServe()
}

// Shutdown gracefully stops the server.
func (s *Server) Shutdown(ctx context.Context) error {
	slog.Info("HTTP server shutting down")
	select {
	case <-s.webhookStop:
	default:
		close(s.webhookStop)
	}
	select {
	case <-s.webhookDone:
	case <-ctx.Done():
	}
	if s.rateLimiter != nil {
		s.rateLimiter.close()
	}
	return s.httpServer.Shutdown(ctx)
}

// Close force-closes all active connections immediately.
func (s *Server) Close() error {
	slog.Info("HTTP server force close")
	select {
	case <-s.webhookStop:
	default:
		close(s.webhookStop)
	}
	select {
	case <-s.webhookDone:
	default:
	}
	if s.rateLimiter != nil {
		s.rateLimiter.close()
	}
	return s.httpServer.Close()
}

// Handler returns the http.Handler for testing.
func (s *Server) Handler() http.Handler {
	return s.httpServer.Handler
}

// JSON response helpers

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string, code string) {
	writeJSON(w, status, map[string]string{"error": msg, "code": code})
}

func writeStoreError(w http.ResponseWriter, err error, fallbackStatus int, fallbackCode string) {
	if store.IsOverloadedError(err) {
		if ms, ok := store.OverloadRetryAfterMs(err); ok && ms > 0 {
			secs := float64(ms) / 1000.0
			w.Header().Set("Retry-After", fmt.Sprintf("%.3f", secs))
			writeJSON(w, http.StatusTooManyRequests, map[string]any{
				"error":          err.Error(),
				"code":           "OVERLOADED",
				"retry_after_ms": ms,
			})
			return
		}
		writeError(w, http.StatusTooManyRequests, err.Error(), "OVERLOADED")
		return
	}
	if store.IsBudgetExceededError(err) {
		writeError(w, http.StatusTooManyRequests, err.Error(), "BUDGET_EXCEEDED")
		return
	}
	writeError(w, fallbackStatus, err.Error(), fallbackCode)
}

func decodeJSON(r *http.Request, v interface{}) error {
	defer r.Body.Close()
	return json.NewDecoder(r.Body).Decode(v)
}

// Middleware

func structuredLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		slog.Debug("http request",
			"method", r.Method,
			"path", r.URL.Path,
			"status", ww.Status(),
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}

func otelHTTPMiddleware(next http.Handler) http.Handler {
	tracer := otel.Tracer("corvo/http")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ctx, span := tracer.Start(r.Context(), r.Method+" "+r.URL.Path)
		span.SetAttributes(
			attribute.String("http.method", r.Method),
			attribute.String("http.path", r.URL.Path),
		)
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r.WithContext(ctx))
		span.SetAttributes(attribute.Int("http.status_code", ww.Status()))
		if ww.Status() >= 500 {
			span.SetStatus(codes.Error, "server_error")
		}
		span.End()
	})
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-API-Key, X-Corvo-Namespace")
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) requireEnterpriseFeature(feature string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.license == nil || !s.license.HasFeature(feature) {
			writeError(w, http.StatusForbidden, "enterprise feature not enabled: "+feature, "LICENSE_ERROR")
			return
		}
		next(w, r)
	}
}

// serverTimingWriter injects a Server-Timing header with the server-side
// processing duration when the response status is written.
type serverTimingWriter struct {
	http.ResponseWriter
	start       time.Time
	wroteHeader bool
}

func (w *serverTimingWriter) WriteHeader(code int) {
	if !w.wroteHeader {
		w.wroteHeader = true
		dur := time.Since(w.start)
		w.ResponseWriter.Header().Set("Server-Timing", fmt.Sprintf("proc;dur=%.3f", float64(dur.Microseconds())/1000.0))
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *serverTimingWriter) Write(b []byte) (int, error) {
	if !w.wroteHeader {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(b)
}

func (w *serverTimingWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *serverTimingWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if h, ok := w.ResponseWriter.(http.Hijacker); ok {
		return h.Hijack()
	}
	return nil, nil, fmt.Errorf("underlying ResponseWriter does not support hijacking")
}

func (s *Server) requestMetricsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		route := r.URL.Path
		if rctx := chi.RouteContext(r.Context()); rctx != nil {
			if pat := strings.TrimSpace(rctx.RoutePattern()); pat != "" {
				route = pat
			}
		}
		counter := s.reqMetrics.begin(r.Method, route)
		stw := &serverTimingWriter{ResponseWriter: w, start: start}
		ww := middleware.NewWrapResponseWriter(stw, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		route = r.URL.Path
		if rctx := chi.RouteContext(r.Context()); rctx != nil {
			if pat := strings.TrimSpace(rctx.RoutePattern()); pat != "" {
				route = pat
			}
		}
		s.reqMetrics.finish(counter, ww.Status(), time.Since(start))
	})
}

func (s *Server) rateLimitMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.rateLimiter == nil || !isRateLimitedPath(r.URL.Path) || r.Method == http.MethodOptions {
			next.ServeHTTP(w, r)
			return
		}
		key := rateLimitClientKey(r)
		isWrite := isWriteMethod(r.Method)
		cost := batchRateLimitCost(r)
		if !s.rateLimiter.allowN(key, isWrite, cost, time.Now()) {
			if s.reqMetrics != nil {
				s.reqMetrics.incThrottled(r.Method, r.URL.Path)
			}
			w.Header().Set("Retry-After", "1")
			writeError(w, http.StatusTooManyRequests, "rate limit exceeded", "RATE_LIMITED")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// batchRateLimitCost peeks at the request body for batch endpoints and
// returns the number of items as the token cost. Non-batch endpoints cost 1.
func batchRateLimitCost(r *http.Request) int {
	path := r.URL.Path
	switch path {
	case "/api/v1/fetch/batch":
		body, err := peekJSONBody(r)
		if err != nil || body == nil {
			return 1
		}
		if count, ok := body["count"].(float64); ok && count > 1 {
			return int(count)
		}
		return 1
	case "/api/v1/ack/batch":
		body, err := peekJSONBody(r)
		if err != nil || body == nil {
			return 1
		}
		if acks, ok := body["acks"].([]any); ok && len(acks) > 1 {
			return len(acks)
		}
		return 1
	case "/api/v1/enqueue/batch":
		body, err := peekJSONBody(r)
		if err != nil || body == nil {
			return 1
		}
		if jobs, ok := body["jobs"].([]any); ok && len(jobs) > 1 {
			return len(jobs)
		}
		return 1
	default:
		return 1
	}
}

// peekJSONBody reads the request body, parses it as JSON, and replaces the
// body so downstream handlers can read it again. Limits read to 4MB.
func peekJSONBody(r *http.Request) (map[string]any, error) {
	if r.Body == nil {
		return nil, nil
	}
	buf, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	_ = r.Body.Close()
	r.Body = io.NopCloser(bytes.NewReader(buf))
	if len(bytes.TrimSpace(buf)) == 0 {
		return nil, nil
	}
	var out map[string]any
	if err := json.Unmarshal(buf, &out); err != nil {
		return nil, nil
	}
	return out, nil
}

func (s *Server) requireLeader(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.cluster == nil {
			next.ServeHTTP(w, r)
			return
		}
		// StreamLifecycle from direct SDK clients: let the handler return
		// NOT_LEADER so the client can reconnect to the leader directly.
		// Cloud-proxied streams (X-Corvo-Proxy-Stream: 1) still get proxied.
		if strings.HasSuffix(r.URL.Path, "/StreamLifecycle") &&
			r.Header.Get("X-Corvo-Proxy-Stream") != "1" {
			next.ServeHTTP(w, r)
			return
		}
		leaders, isLeader, err := s.resolveRequestLeaders(r)
		if err != nil {
			if errors.Is(err, errMixedShardLeaders) {
				writeError(w, http.StatusConflict, err.Error(), "SHARD_LEADER_CONFLICT")
				return
			}
			writeError(w, http.StatusBadRequest, err.Error(), "VALIDATION_ERROR")
			return
		}
		if isLeader {
			next.ServeHTTP(w, r)
			return
		}
		if r.Header.Get("X-Corvo-Forwarded") == "1" {
			writeError(w, http.StatusServiceUnavailable, "leader forwarding loop detected", "FORWARD_LOOP")
			return
		}

		if len(leaders) == 0 {
			writeError(w, http.StatusServiceUnavailable, "leader unavailable", "LEADER_UNAVAILABLE")
			return
		}
		if len(leaders) > 1 {
			writeError(w, http.StatusConflict, "request spans shards with different leaders; split request by shard", "SHARD_LEADER_CONFLICT")
			return
		}
		leader := leaders[0]

		target, err := s.leaderTargetURL(r, leader)
		if err != nil {
			writeError(w, http.StatusServiceUnavailable, err.Error(), "LEADER_UNAVAILABLE")
			return
		}

		if err := s.proxyToLeader(w, r, target); err != nil {
			slog.Warn("leader proxy failed", "target", target.String(), "error", err)
			writeError(w, http.StatusServiceUnavailable, "leader proxy unavailable", "LEADER_UNAVAILABLE")
		}
	})
}

func (s *Server) resolveRequestLeaders(r *http.Request) ([]string, bool, error) {
	sharded, ok := s.cluster.(shardLeaderInfo)
	if !ok || sharded.ShardCount() <= 1 {
		if s.cluster.IsLeader() {
			return nil, true, nil
		}
		leader := strings.TrimSpace(s.cluster.LeaderAddr())
		if leader == "" {
			return nil, false, nil
		}
		return []string{leader}, false, nil
	}

	shards, err := s.requestShardTargets(r, sharded)
	if err != nil {
		return nil, false, err
	}
	if len(shards) == 0 {
		if !strings.HasPrefix(r.URL.Path, "/api/v1/") {
			// ConnectRPC or other non-API paths: pass through.
			// The handler routes per-operation via MultiCluster.Apply.
			return nil, true, nil
		}
		for i := 0; i < sharded.ShardCount(); i++ {
			shards = append(shards, i)
		}
	}

	leadersSet := map[string]struct{}{}
	allLocal := true
	anyLocal := false
	for _, shard := range shards {
		if shard < 0 || shard >= sharded.ShardCount() {
			continue
		}
		if sharded.IsLeaderForShard(shard) {
			anyLocal = true
			continue
		}
		allLocal = false
		leader := strings.TrimSpace(sharded.LeaderAddrForShard(shard))
		if leader == "" {
			return nil, false, nil
		}
		leadersSet[leader] = struct{}{}
	}
	if allLocal {
		return nil, true, nil
	}
	if anyLocal && len(leadersSet) > 0 {
		return nil, false, errMixedShardLeaders
	}
	out := make([]string, 0, len(leadersSet))
	for leader := range leadersSet {
		out = append(out, leader)
	}
	return out, false, nil
}

func (s *Server) requestShardTargets(r *http.Request, sharded shardLeaderInfo) ([]int, error) {
	path := r.URL.Path
	method := r.Method
	shards := map[int]struct{}{}
	addQueue := func(queue string) {
		queue = strings.TrimSpace(queue)
		if queue == "" {
			return
		}
		shards[sharded.ShardForQueue(queue)] = struct{}{}
	}
	addJob := func(jobID string) {
		jobID = strings.TrimSpace(jobID)
		if jobID == "" {
			return
		}
		if idx, ok := sharded.ShardForJobID(jobID); ok {
			shards[idx] = struct{}{}
		}
	}

	if strings.HasPrefix(path, "/api/v1/queues/") {
		principal := principalFromContext(r.Context())
		addQueue(namespaceQueue(principal.Namespace, chi.URLParam(r, "name")))
		return sortedShards(shards), nil
	}
	if strings.HasPrefix(path, "/api/v1/jobs/") {
		addJob(chi.URLParam(r, "id"))
		return sortedShards(shards), nil
	}
	if strings.HasPrefix(path, "/api/v1/ack/") {
		addJob(chi.URLParam(r, "job_id"))
		return sortedShards(shards), nil
	}
	if strings.HasPrefix(path, "/api/v1/fail/") {
		addJob(chi.URLParam(r, "job_id"))
		return sortedShards(shards), nil
	}
	if method == http.MethodDelete && path == "/api/v1/auth/keys" {
		return nil, nil
	}

	// Don't parse body for non-API paths (e.g. ConnectRPC streaming/protobuf).
	// io.ReadAll on a bidi stream body deadlocks, and protobuf isn't JSON.
	if !strings.HasPrefix(path, "/api/v1/") {
		return nil, nil
	}

	body, err := decodeJSONBodyMap(r)
	if err != nil {
		return nil, err
	}
	if len(body) == 0 {
		return nil, nil
	}
	principal := principalFromContext(r.Context())
	switch path {
	case "/api/v1/enqueue":
		addQueue(namespaceQueue(principal.Namespace, getString(body, "queue")))
	case "/api/v1/enqueue/batch":
		for _, item := range getSlice(body, "jobs") {
			addQueue(namespaceQueue(principal.Namespace, getString(item, "queue")))
		}
	case "/api/v1/fetch", "/api/v1/fetch/batch":
		for _, queue := range getStringList(body, "queues") {
			addQueue(namespaceQueue(principal.Namespace, queue))
		}
	case "/api/v1/ack/batch":
		for _, item := range getSlice(body, "acks") {
			addJob(getString(item, "job_id"))
		}
	case "/api/v1/heartbeat":
		for jobID := range getMap(body, "jobs") {
			addJob(jobID)
		}
	}
	return sortedShards(shards), nil
}

func decodeJSONBodyMap(r *http.Request) (map[string]any, error) {
	if r.Body == nil {
		return nil, nil
	}
	buf, err := io.ReadAll(io.LimitReader(r.Body, 4<<20))
	if err != nil {
		return nil, err
	}
	_ = r.Body.Close()
	r.Body = io.NopCloser(bytes.NewReader(buf))
	if len(bytes.TrimSpace(buf)) == 0 {
		return nil, nil
	}
	var out map[string]any
	if err := json.Unmarshal(buf, &out); err != nil {
		return nil, nil
	}
	return out, nil
}

func sortedShards(in map[int]struct{}) []int {
	if len(in) == 0 {
		return nil
	}
	out := make([]int, 0, len(in))
	for idx := range in {
		out = append(out, idx)
	}
	sort.Ints(out)
	return out
}

func getString(m map[string]any, key string) string {
	v, _ := m[key].(string)
	return v
}

func getMap(m map[string]any, key string) map[string]any {
	v, _ := m[key].(map[string]any)
	return v
}

func getSlice(m map[string]any, key string) []map[string]any {
	raw, _ := m[key].([]any)
	if len(raw) == 0 {
		return nil
	}
	out := make([]map[string]any, 0, len(raw))
	for _, item := range raw {
		asMap, _ := item.(map[string]any)
		if len(asMap) == 0 {
			continue
		}
		out = append(out, asMap)
	}
	return out
}

func getStringList(m map[string]any, key string) []string {
	raw, _ := m[key].([]any)
	if len(raw) == 0 {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		v, _ := item.(string)
		if strings.TrimSpace(v) == "" {
			continue
		}
		out = append(out, v)
	}
	return out
}

func (s *Server) leaderTargetURL(r *http.Request, leaderAddr string) (*url.URL, error) {
	if strings.HasPrefix(leaderAddr, "http://") || strings.HasPrefix(leaderAddr, "https://") {
		u, err := url.Parse(strings.TrimRight(leaderAddr, "/"))
		if err != nil {
			return nil, err
		}
		return u, nil
	}

	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}

	leaderHost, leaderPort, err := net.SplitHostPort(leaderAddr)
	if err != nil {
		return nil, err
	}
	if leaderHost == "" || leaderHost == "0.0.0.0" || leaderHost == "::" {
		leaderHost = r.Host
		if h, _, err := net.SplitHostPort(r.Host); err == nil {
			leaderHost = h
		}
	}

	// Best-effort: forward to leader host on the same HTTP port as this node.
	httpPort := ""
	if _, p, err := net.SplitHostPort(s.httpServer.Addr); err == nil {
		httpPort = p
	}
	if httpPort == "" {
		// Fallback to raft port if HTTP port isn't parseable.
		httpPort = leaderPort
	}
	host := net.JoinHostPort(leaderHost, httpPort)

	return &url.URL{
		Scheme: scheme,
		Host:   host,
	}, nil
}

// leaderCheckAdapter bridges ClusterInfo to rpcconnect.LeaderCheck.
type leaderCheckAdapter struct {
	server *Server
}

func (a *leaderCheckAdapter) IsLeader() bool {
	return a.server.cluster.IsLeader()
}

func (a *leaderCheckAdapter) LeaderHTTPURL() string {
	leaderAddr := strings.TrimSpace(a.server.cluster.LeaderAddr())
	if leaderAddr == "" {
		return ""
	}
	if strings.HasPrefix(leaderAddr, "http://") || strings.HasPrefix(leaderAddr, "https://") {
		return strings.TrimRight(leaderAddr, "/")
	}
	leaderHost, _, err := net.SplitHostPort(leaderAddr)
	if err != nil {
		return ""
	}
	if leaderHost == "" || leaderHost == "0.0.0.0" || leaderHost == "::" {
		return ""
	}
	httpPort := ""
	if _, p, err := net.SplitHostPort(a.server.bindAddr); err == nil {
		httpPort = p
	}
	if httpPort == "" {
		return ""
	}
	return "http://" + net.JoinHostPort(leaderHost, httpPort)
}

func (s *Server) proxyToLeader(w http.ResponseWriter, r *http.Request, target *url.URL) error {
	if target == nil {
		return errors.New("missing leader target")
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.Transport = s.h2cTransport
	proxy.FlushInterval = -1
	var proxyErr error
	proxy.ErrorHandler = func(rw http.ResponseWriter, req *http.Request, err error) {
		proxyErr = err
		writeError(rw, http.StatusServiceUnavailable, "leader proxy unavailable", "LEADER_UNAVAILABLE")
	}
	origDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		origDirector(req)
		req.Header.Set("X-Corvo-Forwarded", "1")
	}
	proxy.ModifyResponse = func(resp *http.Response) error {
		resp.Header.Set("X-Corvo-Forwarded", "1")
		return nil
	}
	proxy.ServeHTTP(w, r)
	return proxyErr
}
