package scheduler

import (
	"context"
	"database/sql"
	"log/slog"
	"time"
)

// Config holds scheduler configuration.
type Config struct {
	Interval       time.Duration // how often to run sweep (default 1s)
	EventRetention time.Duration // how long to keep events (default 24h)
}

// DefaultConfig returns a Config with sensible defaults.
func DefaultConfig() Config {
	return Config{
		Interval:       1 * time.Second,
		EventRetention: 24 * time.Hour,
	}
}

// Scheduler runs periodic maintenance tasks.
type Scheduler struct {
	writeDB *sql.DB
	config  Config
}

// New creates a new Scheduler.
func New(writeDB *sql.DB, config Config) *Scheduler {
	if config.Interval == 0 {
		config.Interval = 1 * time.Second
	}
	if config.EventRetention == 0 {
		config.EventRetention = 24 * time.Hour
	}
	return &Scheduler{writeDB: writeDB, config: config}
}

// Run starts the scheduler loop. It blocks until the context is cancelled.
func (s *Scheduler) Run(ctx context.Context) {
	slog.Info("scheduler started", "interval", s.config.Interval)
	ticker := time.NewTicker(s.config.Interval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			slog.Info("scheduler stopped")
			return
		case <-ticker.C:
			s.tick()
		}
	}
}

func (s *Scheduler) tick() {
	s.promoteScheduledJobs()
	s.reclaimExpiredLeases()
	s.cleanExpiredUniqueLocks()
	s.cleanOldEvents()
	s.cleanOldRateLimitEntries()
}

// promoteScheduledJobs moves scheduled/retrying jobs to pending when their scheduled_at time has passed.
func (s *Scheduler) promoteScheduledJobs() {
	result, err := s.writeDB.Exec(`
		UPDATE jobs SET state = 'pending', scheduled_at = NULL
		WHERE state IN ('scheduled', 'retrying')
		  AND scheduled_at <= strftime('%Y-%m-%dT%H:%M:%f', 'now')
	`)
	if err != nil {
		slog.Error("promote scheduled jobs", "error", err)
		return
	}
	if n, _ := result.RowsAffected(); n > 0 {
		slog.Debug("promoted jobs", "count", n)
	}
}

// reclaimExpiredLeases resets active jobs whose leases have expired back to pending.
func (s *Scheduler) reclaimExpiredLeases() {
	result, err := s.writeDB.Exec(`
		UPDATE jobs SET state = 'pending', worker_id = NULL, hostname = NULL, lease_expires_at = NULL
		WHERE state = 'active'
		  AND lease_expires_at < strftime('%Y-%m-%dT%H:%M:%f', 'now')
	`)
	if err != nil {
		slog.Error("reclaim expired leases", "error", err)
		return
	}
	if n, _ := result.RowsAffected(); n > 0 {
		slog.Warn("reclaimed expired leases", "count", n)
	}
}

// cleanExpiredUniqueLocks removes unique locks that have expired.
func (s *Scheduler) cleanExpiredUniqueLocks() {
	result, err := s.writeDB.Exec(`
		DELETE FROM unique_locks WHERE expires_at < strftime('%Y-%m-%dT%H:%M:%f', 'now')
	`)
	if err != nil {
		slog.Error("clean expired unique locks", "error", err)
		return
	}
	if n, _ := result.RowsAffected(); n > 0 {
		slog.Debug("cleaned expired unique locks", "count", n)
	}
}

// cleanOldEvents removes events older than the retention period.
func (s *Scheduler) cleanOldEvents() {
	retentionSeconds := int(s.config.EventRetention.Seconds())
	result, err := s.writeDB.Exec(`
		DELETE FROM events WHERE created_at < strftime('%Y-%m-%dT%H:%M:%f', 'now', '-' || ? || ' seconds')
	`, retentionSeconds)
	if err != nil {
		slog.Error("clean old events", "error", err)
		return
	}
	if n, _ := result.RowsAffected(); n > 0 {
		slog.Debug("cleaned old events", "count", n)
	}
}

// cleanOldRateLimitEntries removes rate limit window entries older than 5 minutes.
func (s *Scheduler) cleanOldRateLimitEntries() {
	result, err := s.writeDB.Exec(`
		DELETE FROM rate_limit_window WHERE fetched_at < strftime('%Y-%m-%dT%H:%M:%f', 'now', '-300 seconds')
	`)
	if err != nil {
		slog.Error("clean old rate limit entries", "error", err)
		return
	}
	if n, _ := result.RowsAffected(); n > 0 {
		slog.Debug("cleaned old rate limit entries", "count", n)
	}
}

// RunOnce executes a single scheduler tick. Useful for testing.
func (s *Scheduler) RunOnce() {
	s.tick()
}
