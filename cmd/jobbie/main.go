package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	raftcluster "github.com/user/jobbie/internal/raft"
	"github.com/user/jobbie/internal/scheduler"
	"github.com/user/jobbie/internal/server"
	"github.com/user/jobbie/internal/store"
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
	serverCmd.Flags().BoolVar(&durableMode, "durable", false, "Enable power-loss durability mode (Raft fsync per write). Significantly reduces throughput/latency performance; enable only if absolutely required.")
	serverCmd.Flags().StringVar(&raftStore, "raft-store", "bolt", "Raft log/stable backend: bolt, badger, or pebble")

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
		"data_dir", dataDir,
	)

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

	// Join workflow placeholder; full join flow requires leader-side join endpoint.
	if joinAddr != "" && !bootstrap {
		slog.Warn("join requested; ensure leader has added this node as a voter",
			"join_addr", joinAddr, "node_id", nodeID, "raft_bind", raftBind)
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
	srv := server.New(s, cluster, bindAddr)
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
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("HTTP shutdown error", "error", err)
	}

	slog.Info("stopping scheduler")
	schedCancel()

	slog.Info("stopping store")
	s.Close()

	slog.Info("jobbie server stopped")
	return nil
}
