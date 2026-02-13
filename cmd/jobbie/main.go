package main

import (
	"context"
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
	"github.com/user/jobbie/internal/observability"
	raftcluster "github.com/user/jobbie/internal/raft"
	"github.com/user/jobbie/internal/scheduler"
	"github.com/user/jobbie/internal/server"
	"github.com/user/jobbie/internal/store"
	uiassets "github.com/user/jobbie/ui"
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
	Use:   "jobbie",
	Short: "Jobbie — language-agnostic job processing system",
	Long:  "An open-source, language-agnostic job processing system with embedded SQLite.",
	PersistentPreRun: func(cmd *cobra.Command, args []string) {
		setupLogging()
	},
}

var serverCmd = &cobra.Command{
	Use:   "server",
	Short: "Start the Jobbie server",
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
	raftStore           = "bolt"
	schedulerEnabled    = true
	schedulerInterval   = time.Second
	sqliteMirrorEnabled = true
	sqliteMirrorAsync   = true
	applyTimeout        = 10 * time.Second
	shutdownTimeout     = 500 * time.Millisecond
	discoverMode        string
	discoverDNSName     string
	otelEnabled         bool
	otelEndpoint        string
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
	serverCmd.Flags().StringVar(&raftStore, "raft-store", "bolt", "Raft log/stable backend: bolt, badger, or pebble")
	serverCmd.Flags().DurationVar(&shutdownTimeout, "shutdown-timeout", 500*time.Millisecond, "Graceful HTTP shutdown timeout before force-close (e.g. 500ms, 2s)")
	serverCmd.Flags().BoolVar(&otelEnabled, "otel-enabled", false, "Enable OpenTelemetry tracing")
	serverCmd.Flags().StringVar(&otelEndpoint, "otel-endpoint", "", "OTLP HTTP endpoint (host:port) for traces; if empty uses stdout exporter")

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
	if discoverMode != "" && discoverMode != "dns" {
		return fmt.Errorf("unsupported discover mode %q", discoverMode)
	}

	// Pebble is treated as rebuildable materialized state; keep Pebble fsync
	// disabled for throughput in all modes. Durability is controlled by Raft.
	clusteredMode := joinAddr != "" || !bootstrap
	raftNoSync := !durableMode
	pebbleNoSync := true

	slog.Info("starting jobbie server",
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
		"sqlite_mirror_enabled", sqliteMirrorEnabled,
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
	)

	otelShutdown, err := observability.InitTracer(otelEnabled, "jobbie-server", otelEndpoint)
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
	clusterCfg.SQLiteMirror = sqliteMirrorEnabled
	clusterCfg.SQLiteMirrorAsync = sqliteMirrorAsync
	clusterCfg.ApplyTimeout = applyTimeout
	clusterCfg.Bootstrap = bootstrap
	clusterCfg.JoinAddr = joinAddr

	cluster, err := raftcluster.NewCluster(clusterCfg)
	if err != nil {
		return fmt.Errorf("start raft cluster: %w", err)
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
			slog.Info("joined cluster", "target", target, "node_id", nodeID)
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

	var schedCancel context.CancelFunc = func() {}
	if schedulerEnabled {
		schedCfg := scheduler.DefaultConfig()
		schedCfg.Interval = schedulerInterval
		sched := scheduler.New(s, cluster, schedCfg)
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
	srv := server.New(s, cluster, bindAddr, uiFS)
	go func() {
		if err := srv.Start(); err != nil && err != http.ErrServerClosed {
			slog.Error("HTTP server error", "error", err)
			os.Exit(1)
		}
	}()

	slog.Info("jobbie server ready", "bind", bindAddr)

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

	slog.Info("jobbie server stopped")
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
