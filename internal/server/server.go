package server

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/user/jobbie/internal/store"
)

// Server is the HTTP server for Jobbie.
type Server struct {
	store      *store.Store
	httpServer *http.Server
	router     chi.Router
}

// New creates a new Server.
func New(s *store.Store, bindAddr string) *Server {
	srv := &Server{store: s}
	srv.router = srv.buildRouter()
	srv.httpServer = &http.Server{
		Addr:    bindAddr,
		Handler: srv.router,
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
		// Worker endpoints
		r.Post("/enqueue", s.handleEnqueue)
		r.Post("/enqueue/batch", s.handleEnqueueBatch)
		r.Post("/fetch", s.handleFetch)
		r.Post("/ack/{job_id}", s.handleAck)
		r.Post("/fail/{job_id}", s.handleFail)
		r.Post("/heartbeat", s.handleHeartbeat)

		// Queue management
		r.Get("/queues", s.handleListQueues)
		r.Post("/queues/{name}/pause", s.handlePauseQueue)
		r.Post("/queues/{name}/resume", s.handleResumeQueue)
		r.Post("/queues/{name}/clear", s.handleClearQueue)
		r.Post("/queues/{name}/drain", s.handleDrainQueue)
		r.Post("/queues/{name}/concurrency", s.handleSetConcurrency)
		r.Post("/queues/{name}/throttle", s.handleSetThrottle)
		r.Delete("/queues/{name}/throttle", s.handleRemoveThrottle)
		r.Delete("/queues/{name}", s.handleDeleteQueue)

		// Job management
		r.Get("/jobs/{id}", s.handleGetJob)
		r.Post("/jobs/{id}/retry", s.handleRetryJob)
		r.Post("/jobs/{id}/cancel", s.handleCancelJob)
		r.Post("/jobs/{id}/move", s.handleMoveJob)
		r.Delete("/jobs/{id}", s.handleDeleteJob)

		// Search and bulk
		r.Post("/jobs/search", s.handleSearch)
		r.Post("/jobs/bulk", s.handleBulk)

		// Admin
		r.Get("/workers", s.handleListWorkers)
		r.Get("/cluster/status", s.handleClusterStatus)
	})

	r.Get("/healthz", s.handleHealthz)

	return r
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
	return s.router
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
