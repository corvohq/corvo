package scheduler

import (
	"context"
	"log/slog"
	"sync/atomic"
	"time"

	"github.com/corvohq/corvo/internal/store"
)

// Metrics holds atomic counters for scheduler operations, safe for concurrent
// reads from the Prometheus handler.
type Metrics struct {
	PromoteRuns   atomic.Uint64
	PromoteErrors atomic.Uint64
	ReclaimRuns   atomic.Uint64
	ReclaimErrors atomic.Uint64
	ExpireRuns    atomic.Uint64
	ExpireErrors  atomic.Uint64
	PurgeRuns     atomic.Uint64
	PurgeErrors   atomic.Uint64
	LastPromote   atomic.Int64 // unix seconds
	LastReclaim   atomic.Int64
	LastExpire    atomic.Int64
	LastPurge     atomic.Int64
}

// Config holds scheduler configuration.
type Config struct {
	Interval               time.Duration // base tick cadence (default 1s)
	PromoteInterval        time.Duration // promote scheduled/retrying jobs
	ReclaimInterval        time.Duration // reclaim expired leases
	CleanUniqueInterval    time.Duration // clean expired unique locks
	CleanRateLimitInterval time.Duration // clean old rate limit windows
	ExpireInterval         time.Duration // expire jobs past their expire_at
	PurgeInterval          time.Duration // purge old terminal-state jobs
	RetentionPeriod        time.Duration // how long to keep terminal jobs
	MaxDeferDuration       time.Duration // max time to defer under-load ops before forcing a run (default 10s)
}

// DefaultConfig returns a Config with sensible defaults.
func DefaultConfig() Config {
	return Config{
		Interval:               1 * time.Second,
		PromoteInterval:        1 * time.Second,
		ReclaimInterval:        1 * time.Second,
		CleanUniqueInterval:    30 * time.Second,
		CleanRateLimitInterval: 30 * time.Second,
		ExpireInterval:         10 * time.Second,
		PurgeInterval:          1 * time.Hour,
		RetentionPeriod:        7 * 24 * time.Hour,
		MaxDeferDuration:       10 * time.Second,
	}
}

// LeaderCheck is an optional interface that, if provided, restricts the scheduler
// to only run on the Raft leader node.
type LeaderCheck interface {
	IsLeader() bool
}

// LoadChecker is an optional interface that LeaderCheck implementations can
// satisfy. When the system is under load, the scheduler skips expensive ops
// (Promote, Reclaim, ExpireJobs) to avoid competing with the hot path.
type LoadChecker interface {
	IsUnderLoad() bool
}

// Scheduler runs periodic maintenance tasks.
type Scheduler struct {
	store       *store.Store
	leaderCheck LeaderCheck
	config      Config
	metrics     *Metrics
	lastPromote time.Time
	lastReclaim time.Time
	lastUnique  time.Time
	lastRate    time.Time
	lastExpire  time.Time
	lastPurge   time.Time
}

// New creates a new Scheduler. If leaderCheck is nil, the scheduler always runs.
// If metrics is non-nil, scheduler operations will be counted.
func New(s *store.Store, leaderCheck LeaderCheck, config Config, metrics *Metrics) *Scheduler {
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
	if config.ExpireInterval == 0 {
		config.ExpireInterval = def.ExpireInterval
	}
	if config.PurgeInterval == 0 {
		config.PurgeInterval = def.PurgeInterval
	}
	if config.RetentionPeriod == 0 {
		config.RetentionPeriod = def.RetentionPeriod
	}
	if config.MaxDeferDuration == 0 {
		config.MaxDeferDuration = def.MaxDeferDuration
	}
	return &Scheduler{store: s, leaderCheck: leaderCheck, config: config, metrics: metrics}
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

	// When the apply pipeline is busy, skip expensive ops (Promote, Reclaim,
	// ExpireJobs) to avoid competing with fetch/ack on the serial FSM goroutine.
	// However, if an op has been deferred for longer than MaxDeferDuration, run
	// it anyway to guarantee liveness under sustained load.
	// Note: DirectApplier (used in tests) doesn't implement LoadChecker, so
	// underLoad stays false in test environments and force=true always works.
	underLoad := false
	if lc, ok := s.leaderCheck.(LoadChecker); ok {
		underLoad = lc.IsUnderLoad()
	}

	maxDefer := s.config.MaxDeferDuration
	promoteOverdue := now.Sub(s.lastPromote) >= maxDefer
	reclaimOverdue := now.Sub(s.lastReclaim) >= maxDefer
	expireOverdue := now.Sub(s.lastExpire) >= maxDefer

	if (force || now.Sub(s.lastPromote) >= s.config.PromoteInterval) && (!underLoad || promoteOverdue) {
		if err := s.store.Promote(); err != nil {
			slog.Error("promote scheduled jobs", "error", err)
			if s.metrics != nil {
				s.metrics.PromoteErrors.Add(1)
			}
		}
		if s.metrics != nil {
			s.metrics.PromoteRuns.Add(1)
			s.metrics.LastPromote.Store(now.Unix())
		}
		s.lastPromote = now
	}
	if (force || now.Sub(s.lastReclaim) >= s.config.ReclaimInterval) && (!underLoad || reclaimOverdue) {
		if err := s.store.Reclaim(); err != nil {
			slog.Error("reclaim expired leases", "error", err)
			if s.metrics != nil {
				s.metrics.ReclaimErrors.Add(1)
			}
		}
		if s.metrics != nil {
			s.metrics.ReclaimRuns.Add(1)
			s.metrics.LastReclaim.Store(now.Unix())
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
	if (force || now.Sub(s.lastExpire) >= s.config.ExpireInterval) && (!underLoad || expireOverdue) {
		if err := s.store.ExpireJobs(); err != nil {
			slog.Error("expire jobs past deadline", "error", err)
			if s.metrics != nil {
				s.metrics.ExpireErrors.Add(1)
			}
		}
		if s.metrics != nil {
			s.metrics.ExpireRuns.Add(1)
			s.metrics.LastExpire.Store(now.Unix())
		}
		s.lastExpire = now
	}
	if force || now.Sub(s.lastPurge) >= s.config.PurgeInterval {
		if err := s.store.PurgeJobs(s.config.RetentionPeriod); err != nil {
			slog.Error("purge old terminal jobs", "error", err)
			if s.metrics != nil {
				s.metrics.PurgeErrors.Add(1)
			}
		}
		if s.metrics != nil {
			s.metrics.PurgeRuns.Add(1)
			s.metrics.LastPurge.Store(now.Unix())
		}
		s.lastPurge = now
	}
}

// RunOnce executes a single scheduler tick. Useful for testing.
func (s *Scheduler) RunOnce() {
	s.tick(true)
}
