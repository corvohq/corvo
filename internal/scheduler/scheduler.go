package scheduler

import (
	"context"
	"log/slog"
	"time"

	"github.com/user/jobbie/internal/store"
)

// Config holds scheduler configuration.
type Config struct {
	Interval               time.Duration // base tick cadence (default 1s)
	PromoteInterval        time.Duration // promote scheduled/retrying jobs
	ReclaimInterval        time.Duration // reclaim expired leases
	CleanUniqueInterval    time.Duration // clean expired unique locks
	CleanRateLimitInterval time.Duration // clean old rate limit windows
}

// DefaultConfig returns a Config with sensible defaults.
func DefaultConfig() Config {
	return Config{
		Interval:               1 * time.Second,
		PromoteInterval:        1 * time.Second,
		ReclaimInterval:        1 * time.Second,
		CleanUniqueInterval:    30 * time.Second,
		CleanRateLimitInterval: 30 * time.Second,
	}
}

// LeaderCheck is an optional interface that, if provided, restricts the scheduler
// to only run on the Raft leader node.
type LeaderCheck interface {
	IsLeader() bool
}

// Scheduler runs periodic maintenance tasks.
type Scheduler struct {
	store       *store.Store
	leaderCheck LeaderCheck
	config      Config
	lastPromote time.Time
	lastReclaim time.Time
	lastUnique  time.Time
	lastRate    time.Time
}

// New creates a new Scheduler. If leaderCheck is nil, the scheduler always runs.
func New(s *store.Store, leaderCheck LeaderCheck, config Config) *Scheduler {
	def := DefaultConfig()
	if config.Interval == 0 {
		config.Interval = def.Interval
	}
	if config.PromoteInterval == 0 {
		config.PromoteInterval = def.PromoteInterval
	}
	if config.ReclaimInterval == 0 {
		config.ReclaimInterval = def.ReclaimInterval
	}
	if config.CleanUniqueInterval == 0 {
		config.CleanUniqueInterval = def.CleanUniqueInterval
	}
	if config.CleanRateLimitInterval == 0 {
		config.CleanRateLimitInterval = def.CleanRateLimitInterval
	}
	return &Scheduler{store: s, leaderCheck: leaderCheck, config: config}
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
			s.tick(false)
		}
	}
}

func (s *Scheduler) tick(force bool) {
	// Only run on the leader node
	if s.leaderCheck != nil && !s.leaderCheck.IsLeader() {
		return
	}

	now := time.Now()

	if force || now.Sub(s.lastPromote) >= s.config.PromoteInterval {
		if err := s.store.Promote(); err != nil {
			slog.Error("promote scheduled jobs", "error", err)
		}
		s.lastPromote = now
	}
	if force || now.Sub(s.lastReclaim) >= s.config.ReclaimInterval {
		if err := s.store.Reclaim(); err != nil {
			slog.Error("reclaim expired leases", "error", err)
		}
		s.lastReclaim = now
	}
	if force || now.Sub(s.lastUnique) >= s.config.CleanUniqueInterval {
		if err := s.store.CleanUniqueLocks(); err != nil {
			slog.Error("clean expired unique locks", "error", err)
		}
		s.lastUnique = now
	}
	if force || now.Sub(s.lastRate) >= s.config.CleanRateLimitInterval {
		if err := s.store.CleanRateLimits(); err != nil {
			slog.Error("clean old rate limit entries", "error", err)
		}
		s.lastRate = now
	}
}

// RunOnce executes a single scheduler tick. Useful for testing.
func (s *Scheduler) RunOnce() {
	s.tick(true)
}
