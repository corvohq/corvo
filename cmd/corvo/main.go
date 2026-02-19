package main

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"github.com/corvohq/corvo/internal/enterprise"
	"github.com/corvohq/corvo/internal/observability"
	raftcluster "github.com/corvohq/corvo/internal/raft"
	rpcsvc "github.com/corvohq/corvo/internal/rpcconnect"
	"github.com/corvohq/corvo/internal/scheduler"
	"github.com/corvohq/corvo/internal/server"
	"github.com/corvohq/corvo/internal/store"
	uiassets "github.com/corvohq/corvo/ui"
)

var (
	logLevel string
)

func main() {
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

var rootCmd = &cobra.Command{
	Use:   "corvo",
	Short: "Corvo — language-agnostic job processing system",
	Long:  "A source-available, language-agnostic job processing system with embedded SQLite.",
	PersistentPreRun: func(cmd *cobra.Command, args []string) {
		setupLogging()
	},
}

var serverCmd = &cobra.Command{
	Use:   "server",
	Short: "Start the Corvo server",
	RunE:  runServer,
}

var (
	bindAddr            string
	dataDir             string
	raftBind            string
	raftAdvertise       string
	nodeID              string
	bootstrap           bool
	joinAddr            string
	durableMode         bool
	raftStore           = "badger"
	schedulerEnabled    = true
	schedulerInterval   = time.Second
	sqliteMirrorAsync = true
	applyTimeout        = 10 * time.Second
	shutdownTimeout     = 500 * time.Millisecond
	discoverMode        string
	discoverDNSName     string
	otelEnabled         bool
	otelEndpoint        string
	adminPassword       string
	licenseKey          string
	licensePublicKey    string
	oidcIssuerURL       string
	oidcClientID        string
	samlHeaderAuth      bool
	rateLimitEnabled            = true
	rateLimitReadRPS    float64 = 2000
	rateLimitReadBurst  float64 = 4000
	rateLimitWriteRPS   float64 = 1000
	rateLimitWriteBurst float64 = 2000
	raftShards          int     = 1
	retentionPeriod             = 7 * 24 * time.Hour
	retentionInterval           = 1 * time.Hour

	// Guardrail tuning flags
	streamMaxInFlight      = 2048
	streamMaxOpen          = 4096
	streamMaxFPS           = 500
	fetchPollInterval      = 100 * time.Millisecond
	idleFetchSleep         = 100 * time.Millisecond
	raftMaxPending         = 16384
	raftMaxFetchInflight   = 64
	applyMultiMode         = "grouped"
	noCompression          = true
	snapshotThreshold      = 0 // 0 = use default (4096)
	maxPayloadSize         = 256 * 1024 // 256KB default
	docsEnabled            = true
)

func init() {
	rootCmd.PersistentFlags().StringVar(&logLevel, "log-level", "info", "Log level (debug, info, warn, error)")

	serverCmd.Flags().StringVar(&bindAddr, "bind", ":8080", "HTTP server bind address")
	serverCmd.Flags().StringVar(&dataDir, "data-dir", "data", "Directory for SQLite database files")
	serverCmd.Flags().StringVar(&raftBind, "raft-bind", ":9000", "Raft transport bind address")
	serverCmd.Flags().StringVar(&raftAdvertise, "raft-advertise", "", "Raft advertised address for peers (defaults to 127.0.0.1:<raft-bind-port> when bind is wildcard)")
	serverCmd.Flags().StringVar(&nodeID, "node-id", "node-1", "Unique node ID")
	serverCmd.Flags().BoolVar(&bootstrap, "bootstrap", true, "Bootstrap a new single-node cluster")
	serverCmd.Flags().StringVar(&joinAddr, "join", "", "Join an existing cluster via leader address")
	serverCmd.Flags().StringVar(&discoverMode, "discover", "", "Peer discovery mode (supported: dns)")
	serverCmd.Flags().StringVar(&discoverDNSName, "discover-dns-name", "", "DNS name to resolve for cluster peer discovery when --discover=dns")
	serverCmd.Flags().BoolVar(&durableMode, "durable", false, "Enable power-loss durability mode (Raft fsync per write). Significantly reduces throughput/latency performance; enable only if absolutely required.")
	serverCmd.Flags().StringVar(&raftStore, "raft-store", "badger", "Raft log/stable backend: bolt, badger, or pebble")
	serverCmd.Flags().DurationVar(&shutdownTimeout, "shutdown-timeout", 500*time.Millisecond, "Graceful HTTP shutdown timeout before force-close (e.g. 500ms, 2s)")
	serverCmd.Flags().BoolVar(&otelEnabled, "otel-enabled", false, "Enable OpenTelemetry tracing")
	serverCmd.Flags().StringVar(&otelEndpoint, "otel-endpoint", "", "OTLP HTTP endpoint (host:port) for traces; if empty uses stdout exporter")
	serverCmd.Flags().StringVar(&adminPassword, "admin-password", "", "Global admin password for UI/API access (or set CORVO_ADMIN_PASSWORD)")
	serverCmd.Flags().StringVar(&licenseKey, "license-key", "", "Enterprise license token (or set CORVO_LICENSE_KEY)")
	serverCmd.Flags().StringVar(&licensePublicKey, "license-public-key", "", "Base64 Ed25519 public key for license validation (or set CORVO_LICENSE_PUBLIC_KEY)")
	serverCmd.Flags().StringVar(&oidcIssuerURL, "oidc-issuer-url", "", "OIDC issuer URL (enterprise sso feature)")
	serverCmd.Flags().StringVar(&oidcClientID, "oidc-client-id", "", "OIDC client/audience ID (enterprise sso feature)")
	serverCmd.Flags().BoolVar(&samlHeaderAuth, "saml-header-auth", false, "Enable trusted SAML header auth mode (enterprise sso feature)")
	serverCmd.Flags().BoolVar(&rateLimitEnabled, "rate-limit-enabled", true, "Enable server-side per-client request rate limiting")
	serverCmd.Flags().Float64Var(&rateLimitReadRPS, "rate-limit-read-rps", 2000, "Per-client sustained read requests/sec")
	serverCmd.Flags().Float64Var(&rateLimitReadBurst, "rate-limit-read-burst", 4000, "Per-client read burst tokens")
	serverCmd.Flags().Float64Var(&rateLimitWriteRPS, "rate-limit-write-rps", 1000, "Per-client sustained write requests/sec")
	serverCmd.Flags().Float64Var(&rateLimitWriteBurst, "rate-limit-write-burst", 2000, "Per-client write burst tokens")
	serverCmd.Flags().IntVar(&raftShards, "raft-shards", 1, "Number of in-process Raft shard groups for static queue sharding")
	serverCmd.Flags().DurationVar(&retentionPeriod, "retention", 7*24*time.Hour, "How long to keep completed/dead/cancelled jobs before purging")
	serverCmd.Flags().DurationVar(&retentionInterval, "retention-interval", 1*time.Hour, "How often to run the purge sweep for old terminal jobs")
	serverCmd.Flags().IntVar(&streamMaxInFlight, "stream-max-inflight", 2048, "Max concurrently processing lifecycle stream frames")
	serverCmd.Flags().IntVar(&streamMaxOpen, "stream-max-open", 4096, "Max concurrently open lifecycle streams")
	serverCmd.Flags().IntVar(&streamMaxFPS, "stream-max-fps", 500, "Max frames/sec per lifecycle stream (0 = unlimited)")
	serverCmd.Flags().DurationVar(&fetchPollInterval, "fetch-poll-interval", 100*time.Millisecond, "Unary Fetch/FetchBatch long-poll retry interval")
	serverCmd.Flags().DurationVar(&idleFetchSleep, "idle-fetch-sleep", 100*time.Millisecond, "Stream sleep when fetch returns zero jobs")
	serverCmd.Flags().IntVar(&raftMaxPending, "raft-max-pending", 16384, "Max pending Raft apply requests before backpressure")
	serverCmd.Flags().IntVar(&raftMaxFetchInflight, "raft-max-fetch-inflight", 64, "Max concurrent fetch/fetch-batch applies per queue")
	serverCmd.Flags().StringVar(&applyMultiMode, "apply-multi-mode", "grouped", "Multi-apply batch mode: grouped (2-3 commits), indexed (1 commit), individual (N commits)")
	serverCmd.Flags().BoolVar(&noCompression, "no-compression", true, "Disable gzip compression on ConnectRPC responses (enabled by default; set --no-compression=false to enable gzip)")
	serverCmd.Flags().IntVar(&snapshotThreshold, "snapshot-threshold", 0, "Raft log entries between snapshots (0 = default 4096)")
	serverCmd.Flags().IntVar(&maxPayloadSize, "max-payload-size", 256*1024, "Maximum job payload size in bytes (default 256KB; 0 to disable)")
	serverCmd.Flags().BoolVar(&docsEnabled, "docs-enabled", true, "Serve API docs at /docs and /openapi.json")

	rootCmd.AddCommand(serverCmd)
}

func setupLogging() {
	var level slog.Level
	switch logLevel {
	case "debug":
		level = slog.LevelDebug
	case "warn":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}
	handler := slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})
	slog.SetDefault(slog.New(handler))
}

func runServer(cmd *cobra.Command, args []string) error {
	if raftShards < 1 {
		return fmt.Errorf("raft-shards must be >= 1")
	}
	if discoverMode != "" && discoverMode != "dns" {
		return fmt.Errorf("unsupported discover mode %q", discoverMode)
	}

	// Pebble is treated as rebuildable materialized state; keep Pebble fsync
	// disabled for throughput in all modes. Durability is controlled by Raft.
	clusteredMode := joinAddr != "" || !bootstrap
	raftNoSync := !durableMode
	pebbleNoSync := true

	slog.Info("starting corvo server",
		"bind", bindAddr,
		"raft_bind", raftBind,
		"raft_advertise", raftAdvertise,
		"node_id", nodeID,
		"bootstrap", bootstrap,
		"join", joinAddr,
		"discover", discoverMode,
		"discover_dns_name", discoverDNSName,
		"raft_store", raftStore,
		"scheduler_enabled", schedulerEnabled,
		"scheduler_interval", schedulerInterval,
		"sqlite_mirror_async", sqliteMirrorAsync,
		"clustered_mode", clusteredMode,
		"durable_mode", durableMode,
		"durable_mode_note", "raft fsync per write; significant throughput/latency cost; use only when power-loss durability is required",
		"raft_nosync", raftNoSync,
		"pebble_nosync", pebbleNoSync,
		"raft_apply_timeout", applyTimeout,
		"shutdown_timeout", shutdownTimeout,
		"otel_enabled", otelEnabled,
		"otel_endpoint", otelEndpoint,
		"data_dir", dataDir,
		"raft_shards", raftShards,
	)

	otelShutdown, err := observability.InitTracer(otelEnabled, "corvo-server", otelEndpoint)
	if err != nil {
		return fmt.Errorf("init otel: %w", err)
	}
	defer func() {
		if err := otelShutdown(context.Background()); err != nil {
			slog.Warn("otel shutdown error", "error", err)
		}
	}()

	clusterCfg := raftcluster.DefaultClusterConfig()
	clusterCfg.NodeID = nodeID
	clusterCfg.DataDir = dataDir
	clusterCfg.RaftBind = raftBind
	clusterCfg.RaftAdvertise = raftAdvertise
	clusterCfg.RaftStore = raftStore
	clusterCfg.RaftNoSync = raftNoSync
	clusterCfg.PebbleNoSync = pebbleNoSync
	clusterCfg.SQLiteMirrorAsync = sqliteMirrorAsync
	clusterCfg.ApplyTimeout = applyTimeout
	clusterCfg.ApplyMaxPending = raftMaxPending
	clusterCfg.ApplyMaxFetchQueueInFly = raftMaxFetchInflight
	clusterCfg.ApplyMultiMode = applyMultiMode
	clusterCfg.Bootstrap = bootstrap
	clusterCfg.JoinAddr = joinAddr
	if snapshotThreshold > 0 {
		clusterCfg.SnapshotThreshold = uint64(snapshotThreshold)
	}

	type clusterRuntime interface {
		store.Applier
		SQLiteReadDB() *sql.DB
		Shutdown() error
		WaitForLeader(timeout time.Duration) error
		JoinCluster(leaderAddr string) error
		IsLeader() bool
		SnapshotAfterFirstApply(timeout time.Duration) error
		LeaderAddr() string
		ClusterStatus() map[string]any
		State() string
		EventLog(afterSeq uint64, limit int) ([]map[string]any, error)
		RebuildSQLiteFromPebble() error
	}
	var cluster clusterRuntime
	if raftShards == 1 {
		single, err := raftcluster.NewCluster(clusterCfg)
		if err != nil {
			return fmt.Errorf("start raft cluster: %w", err)
		}
		cluster = single
	} else {
		multi, err := raftcluster.NewMultiCluster(clusterCfg, raftShards)
		if err != nil {
			return fmt.Errorf("start multi-raft cluster: %w", err)
		}
		cluster = multi
	}
	defer cluster.Shutdown()

	joinTargets := []string{}
	if joinAddr != "" {
		joinTargets = append(joinTargets, joinAddr)
	}
	if !bootstrap && joinAddr == "" && discoverMode == "dns" {
		targets, err := discoverDNSJoinTargets(discoverDNSName, bindAddr)
		if err != nil {
			return fmt.Errorf("discover dns peers: %w", err)
		}
		joinTargets = append(joinTargets, targets...)
	}
	if !bootstrap && len(joinTargets) > 0 {
		var joined bool
		var lastErr error
		for _, target := range joinTargets {
			if err := cluster.JoinCluster(target); err != nil {
				lastErr = err
				slog.Warn("join attempt failed", "target", target, "error", err)
				continue
			}
			slog.Info("joined cluster", "target", target, "node_id", nodeID, "raft_shards", raftShards)
			joined = true
			break
		}
		if !joined && lastErr != nil {
			return fmt.Errorf("join cluster: %w", lastErr)
		}
	}

	if err := cluster.WaitForLeader(10 * time.Second); err != nil {
		return fmt.Errorf("wait for leader: %w", err)
	}
	// Trigger initial snapshot after the first real apply on leaders to
	// minimize pre-first-snapshot recovery ambiguity without noisy empty snapshots.
	if cluster.IsLeader() {
		go func() {
			if err := cluster.SnapshotAfterFirstApply(30 * time.Second); err != nil {
				slog.Warn("initial raft snapshot skipped/failed", "error", err)
				return
			}
			slog.Info("initial raft snapshot complete")
		}()
	}

	s := store.NewStore(cluster, cluster.SQLiteReadDB())

	schedMetrics := &scheduler.Metrics{}
	var schedCancel context.CancelFunc = func() {}
	if schedulerEnabled {
		schedCfg := scheduler.DefaultConfig()
		schedCfg.Interval = schedulerInterval
		schedCfg.RetentionPeriod = retentionPeriod
		schedCfg.PurgeInterval = retentionInterval
		sched := scheduler.New(s, cluster, schedCfg, schedMetrics)
		var schedCtx context.Context
		schedCtx, schedCancel = context.WithCancel(context.Background())
		go sched.Run(schedCtx)
	}

	// Start HTTP server
	// Mount embedded UI assets (dist/ subdirectory of the embed.FS).
	var uiFS fs.FS
	if sub, err := fs.Sub(uiassets.Assets, "dist"); err == nil {
		uiFS = sub
	}
	opts := []server.Option{}
	ap := strings.TrimSpace(adminPassword)
	if ap == "" {
		ap = strings.TrimSpace(os.Getenv("CORVO_ADMIN_PASSWORD"))
	}
	if ap != "" {
		opts = append(opts, server.WithAdminPassword(ap))
		slog.Info("admin password configured")
	} else {
		slog.Warn("no admin password set — if API keys are created you may be locked out; use --admin-password or CORVO_ADMIN_PASSWORD")
	}
	var lic *enterprise.License
	lk := strings.TrimSpace(licenseKey)
	if lk == "" {
		lk = strings.TrimSpace(os.Getenv("CORVO_LICENSE_KEY"))
	}
	lpk := strings.TrimSpace(licensePublicKey)
	if lpk == "" {
		lpk = strings.TrimSpace(os.Getenv("CORVO_LICENSE_PUBLIC_KEY"))
	}
	if lk != "" {
		if lpk == "" {
			slog.Warn("license key provided but no public key configured; enterprise features disabled")
		} else {
			pub, err := enterprise.ParsePublicKey(lpk)
			if err != nil {
				slog.Warn("invalid license public key; enterprise features disabled", "error", err)
			} else {
				lic, err = enterprise.Validate(lk, pub, time.Now().UTC())
				if err != nil {
					slog.Warn("license validation failed; enterprise features disabled", "error", err)
				} else {
					opts = append(opts, server.WithEnterpriseLicense(lic))
					features := lic.FeatureList()
					sort.Strings(features)
					slog.Info("enterprise license enabled", "tier", lic.Tier, "customer", lic.Customer, "features", features)
				}
			}
		}
	}
	if strings.TrimSpace(oidcIssuerURL) != "" || strings.TrimSpace(oidcClientID) != "" {
		if lic == nil || !lic.HasFeature("sso") {
			slog.Warn("oidc config ignored; enterprise sso feature is not enabled")
		} else {
			opts = append(opts, server.WithOIDCAuth(server.OIDCConfig{
				IssuerURL: strings.TrimSpace(oidcIssuerURL),
				ClientID:  strings.TrimSpace(oidcClientID),
			}))
		}
	}
	if samlHeaderAuth {
		if lic == nil || !lic.HasFeature("sso") {
			slog.Warn("saml header auth ignored; enterprise sso feature is not enabled")
		} else {
			opts = append(opts, server.WithSAMLHeaderAuth(server.SAMLHeaderConfig{Enabled: true}))
		}
	}
	opts = append(opts, server.WithRateLimit(server.RateLimitConfig{
		Enabled:    rateLimitEnabled,
		ReadRPS:    rateLimitReadRPS,
		ReadBurst:  rateLimitReadBurst,
		WriteRPS:   rateLimitWriteRPS,
		WriteBurst: rateLimitWriteBurst,
	}))
	streamCfg := rpcsvc.StreamConfig{
		MaxInFlight:       streamMaxInFlight,
		MaxOpenStreams:     streamMaxOpen,
		MaxFramesPerSec:   streamMaxFPS,
		FetchPollInterval:  fetchPollInterval,
		IdleFetchSleep:     idleFetchSleep,
		DisableCompression: noCompression,
	}
	if raftShards > 1 {
		streamCfg.MaxOpenStreams *= raftShards
	}
	opts = append(opts, server.WithRPCStreamConfig(streamCfg))
	opts = append(opts, server.WithSchedulerMetrics(schedMetrics))
	opts = append(opts, server.WithMaxPayloadSize(maxPayloadSize))
	if !docsEnabled {
		opts = append(opts, server.WithDocsDisabled())
	}
	srv := server.New(s, cluster, bindAddr, uiFS, opts...)
	go func() {
		if err := srv.Start(); err != nil && err != http.ErrServerClosed {
			slog.Error("HTTP server error", "error", err)
			os.Exit(1)
		}
	}()

	slog.Info("corvo server ready", "bind", bindAddr)

	// Wait for shutdown signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
	sig := <-sigCh
	slog.Info("received shutdown signal", "signal", sig)

	// Graceful shutdown sequence
	slog.Info("stopping HTTP server")
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("HTTP shutdown error; forcing close", "error", err)
		if closeErr := srv.Close(); closeErr != nil {
			slog.Error("HTTP force close error", "error", closeErr)
		}
	}

	slog.Info("stopping scheduler")
	schedCancel()

	slog.Info("stopping store")
	s.Close()

	slog.Info("corvo server stopped")
	return nil
}

func discoverDNSJoinTargets(name, bind string) ([]string, error) {
	if strings.TrimSpace(name) == "" {
		return nil, fmt.Errorf("discover-dns-name is required when --discover=dns")
	}
	httpPort, err := resolveHTTPPort(bind)
	if err != nil {
		return nil, err
	}
	hosts, err := net.LookupHost(name)
	if err != nil {
		return nil, err
	}
	if len(hosts) == 0 {
		return nil, fmt.Errorf("no DNS records found for %s", name)
	}

	uniq := make(map[string]struct{}, len(hosts))
	for _, h := range hosts {
		h = strings.TrimSpace(h)
		if h == "" {
			continue
		}
		uniq[h] = struct{}{}
	}
	out := make([]string, 0, len(uniq))
	for host := range uniq {
		out = append(out, net.JoinHostPort(host, httpPort))
	}
	sort.Strings(out)
	return out, nil
}

func resolveHTTPPort(bind string) (string, error) {
	addr, err := net.ResolveTCPAddr("tcp", bind)
	if err != nil {
		return "", fmt.Errorf("parse bind address: %w", err)
	}
	if addr.Port <= 0 {
		return "", fmt.Errorf("bind address missing valid port: %s", bind)
	}
	return fmt.Sprintf("%d", addr.Port), nil
}
