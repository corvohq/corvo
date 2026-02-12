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
	bindAddr string
	dataDir  string
)

func init() {
	rootCmd.PersistentFlags().StringVar(&logLevel, "log-level", "info", "Log level (debug, info, warn, error)")

	serverCmd.Flags().StringVar(&bindAddr, "bind", ":8080", "HTTP server bind address")
	serverCmd.Flags().StringVar(&dataDir, "data-dir", "data", "Directory for SQLite database files")

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
	slog.Info("starting jobbie server", "bind", bindAddr, "data_dir", dataDir)

	// Open database
	db, err := store.Open(dataDir)
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}

	// Create batch writer and store
	bw := store.NewBatchWriter(db.Write, store.DefaultBatchWriterConfig())
	s := store.NewStoreWithWriter(db, bw)

	// Start scheduler
	sched := scheduler.New(db.Write, scheduler.DefaultConfig())
	schedCtx, schedCancel := context.WithCancel(context.Background())
	go sched.Run(schedCtx)

	// Start HTTP server
	srv := server.New(s, bindAddr)
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

	slog.Info("stopping store async writer")
	s.Close()

	slog.Info("stopping batch writer")
	bw.Stop()

	slog.Info("closing database")
	if err := db.Close(); err != nil {
		slog.Error("database close error", "error", err)
	}

	slog.Info("jobbie server stopped")
	return nil
}
