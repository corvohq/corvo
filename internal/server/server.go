package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/user/jobbie/internal/rpcconnect"
	"github.com/user/jobbie/internal/store"
	"golang.org/x/net/http2"
	"golang.org/x/net/http2/h2c"
)

// Server is the HTTP server for Jobbie.
type Server struct {
	store      *store.Store
	cluster    ClusterInfo
	httpServer *http.Server
	router     chi.Router
	uiFS       fs.FS
	throughput *ThroughputTracker
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

// New creates a new Server.
// If uiAssets is non-nil the embedded SPA will be served at /ui/.
func New(s *store.Store, cluster ClusterInfo, bindAddr string, uiAssets fs.FS) *Server {
	srv := &Server{store: s, cluster: cluster, uiFS: uiAssets, throughput: NewThroughputTracker()}
	srv.router = srv.buildRouter()
	srv.httpServer = &http.Server{
		Addr: bindAddr,
		Handler: h2c.NewHandler(srv.router, &http2.Server{
			MaxConcurrentStreams: 4096,
		}),
	}
	return srv
}

func (s *Server) buildRouter() chi.Router {
	r := chi.NewRouter()

	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(structuredLogger)
	r.Use(middleware.Recoverer)
	r.Use(corsMiddleware)

	r.Route("/api/v1", func(r chi.Router) {
		// Read endpoints
		r.Get("/queues", s.handleListQueues)
		r.Get("/jobs/{id}", s.handleGetJob)
		r.Get("/jobs/{id}/iterations", s.handleListJobIterations)
		r.Post("/jobs/search", s.handleSearch)
		r.Get("/workers", s.handleListWorkers)
		r.Get("/cluster/status", s.handleClusterStatus)
		r.Get("/cluster/events", s.handleClusterEvents)
		r.Get("/events", s.handleSSE)
		r.Get("/metrics/throughput", s.handleThroughput)
		r.Get("/usage/summary", s.handleUsageSummary)
		r.Get("/budgets", s.handleListBudgets)
		r.Get("/providers", s.handleListProviders)
		r.Get("/scores/summary", s.handleScoreSummary)
		r.Get("/jobs/{id}/scores", s.handleListJobScores)

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
			r.Post("/providers", s.handleSetProvider)
			r.Delete("/providers/{name}", s.handleDeleteProvider)
			r.Post("/queues/{name}/provider", s.handleSetQueueProvider)
			r.Post("/scores", s.handleAddScore)

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
			r.Post("/admin/rebuild-sqlite", s.handleRebuildSQLite)
		})

	})

	// Worker lifecycle RPC (Connect: protobuf and JSON fallback).
	rpcPath, rpcHandler := rpcconnect.NewHandler(s.store)
	r.Group(func(r chi.Router) {
		r.Use(s.requireLeader)
		r.Mount(strings.TrimSuffix(rpcPath, "/"), rpcHandler)
	})

	r.Get("/healthz", s.handleHealthz)

	// Embedded UI SPA
	if s.uiFS != nil {
		s.mountUI(r)
	}

	return r
}

// mountUI serves the embedded SPA. Static assets are served directly;
// any other /ui/* path gets index.html for client-side routing.
func (s *Server) mountUI(r chi.Router) {
	fileServer := http.FileServer(http.FS(s.uiFS))

	r.Get("/ui/*", func(w http.ResponseWriter, r *http.Request) {
		// Strip /ui/ prefix and check if the file exists.
		path := strings.TrimPrefix(r.URL.Path, "/ui/")
		if path == "" {
			path = "index.html"
		}

		// Try to open the file. If it exists, serve it.
		f, err := s.uiFS.Open(path)
		if err == nil {
			f.Close()
			// Set cache headers: hashed assets get long-lived cache, index.html always revalidates.
			if strings.HasPrefix(path, "assets/") {
				w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
			} else if path == "index.html" {
				w.Header().Set("Cache-Control", "no-cache")
			}
			// Serve via file server (with /ui/ prefix stripped).
			http.StripPrefix("/ui/", fileServer).ServeHTTP(w, r)
			return
		}

		// File not found — serve index.html for SPA routing.
		f, err = s.uiFS.Open("index.html")
		if err != nil {
			http.NotFound(w, r)
			return
		}
		f.Close()

		w.Header().Set("Cache-Control", "no-cache")
		r.URL.Path = "/ui/index.html"
		http.StripPrefix("/ui/", fileServer).ServeHTTP(w, r)
	})

	// Redirect bare /ui to /ui/
	r.Get("/ui", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/ui/", http.StatusMovedPermanently)
	})
}

// Start begins listening for HTTP requests.
func (s *Server) Start() error {
	slog.Info("HTTP server starting", "addr", s.httpServer.Addr)
	return s.httpServer.ListenAndServe()
}

// Shutdown gracefully stops the server.
func (s *Server) Shutdown(ctx context.Context) error {
	slog.Info("HTTP server shutting down")
	return s.httpServer.Shutdown(ctx)
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
	if vErr, ok := store.AsResultSchemaValidationError(err); ok {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{
			"error":             vErr.Message,
			"code":              "RESULT_SCHEMA_VALIDATION_ERROR",
			"validation_errors": vErr.Errors,
		})
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

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) requireLeader(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.cluster == nil || s.cluster.IsLeader() {
			next.ServeHTTP(w, r)
			return
		}
		if r.Header.Get("X-Jobbie-Forwarded") == "1" {
			writeError(w, http.StatusServiceUnavailable, "leader forwarding loop detected", "FORWARD_LOOP")
			return
		}

		leader := s.cluster.LeaderAddr()
		if leader == "" {
			writeError(w, http.StatusServiceUnavailable, "leader unavailable", "LEADER_UNAVAILABLE")
			return
		}

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

func (s *Server) proxyToLeader(w http.ResponseWriter, r *http.Request, target *url.URL) error {
	if target == nil {
		return errors.New("missing leader target")
	}

	proxy := httputil.NewSingleHostReverseProxy(target)
	var proxyErr error
	proxy.ErrorHandler = func(rw http.ResponseWriter, req *http.Request, err error) {
		proxyErr = err
		writeError(rw, http.StatusServiceUnavailable, "leader proxy unavailable", "LEADER_UNAVAILABLE")
	}
	origDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		origDirector(req)
		req.Header.Set("X-Jobbie-Forwarded", "1")
	}
	proxy.ModifyResponse = func(resp *http.Response) error {
		resp.Header.Set("X-Jobbie-Forwarded", "1")
		return nil
	}
	proxy.ServeHTTP(w, r)
	return proxyErr
}
