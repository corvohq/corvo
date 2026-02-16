package store

import (
	"context"
	"database/sql"
	"fmt"
	"sync/atomic"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

// Store is the main data access layer for Corvo.
// Writes go through Raft consensus via the Applier; reads come from local SQLite.
type Store struct {
	applier Applier
	sqliteR *sql.DB // read-only SQLite connection (materialized view)
	// Tri-state flag: -1 unknown, 0 none configured, 1 configured.
	budgetConfigState   atomic.Int32
}

// NewStore creates a new Store backed by a Raft cluster.
func NewStore(applier Applier, sqliteR *sql.DB) *Store {
	s := &Store{
		applier: applier,
		sqliteR: sqliteR,
	}
	s.budgetConfigState.Store(-1)
	return s
}

// Close is a no-op — the Cluster owns the lifecycle of Pebble and SQLite.
func (s *Store) Close() error {
	return nil
}

// FlushAsync is a no-op in the Raft architecture — writes are synchronous.
func (s *Store) FlushAsync() {}

// ReadDB returns the read-only SQLite connection for queries.
func (s *Store) ReadDB() *sql.DB {
	return s.sqliteR
}

// applyOp submits an operation through Raft and returns the result.
func (s *Store) applyOp(opType OpType, data any) *OpResult {
	ctx := context.Background()
	tracer := otel.Tracer("corvo/store")
	ctx, span := tracer.Start(ctx, "raft.apply")
	span.SetAttributes(attribute.Int("corvo.op_type", int(opType)))
	res := s.applier.Apply(opType, data)
	if res != nil && res.Err != nil {
		span.RecordError(res.Err)
		span.SetStatus(codes.Error, res.Err.Error())
	}
	span.End()
	_ = ctx
	return res
}

// applyOpResult submits an operation and extracts a typed result.
func applyOpResult[T any](s *Store, opType OpType, data any) (*T, error) {
	result := s.applyOp(opType, data)
	if result.Err != nil {
		return nil, result.Err
	}
	if result.Data == nil {
		return nil, nil
	}
	typed, ok := result.Data.(*T)
	if !ok {
		return nil, fmt.Errorf("unexpected result type: %T", result.Data)
	}
	return typed, nil
}

// Maintenance operations (used by the scheduler).

// Promote moves scheduled/retrying jobs to pending when their time has passed.
func (s *Store) Promote() error {
	now := time.Now()
	return s.applyOp(OpPromote, PromoteOp{NowNs: uint64(now.UnixNano())}).Err
}

// Reclaim resets active jobs with expired leases back to pending.
func (s *Store) Reclaim() error {
	now := time.Now()
	return s.applyOp(OpReclaim, ReclaimOp{NowNs: uint64(now.UnixNano())}).Err
}

// CleanUniqueLocks removes expired unique locks.
func (s *Store) CleanUniqueLocks() error {
	now := time.Now()
	return s.applyOp(OpCleanUnique, CleanUniqueOp{NowNs: uint64(now.UnixNano())}).Err
}

// CleanRateLimits removes old rate limit window entries.
func (s *Store) CleanRateLimits() error {
	cutoff := time.Now().Add(-5 * time.Minute)
	return s.applyOp(OpCleanRateLimit, CleanRateLimitOp{CutoffNs: uint64(cutoff.UnixNano())}).Err
}

// ExpireJobs moves non-terminal jobs past their expire_at to dead state.
func (s *Store) ExpireJobs() error {
	now := time.Now()
	return s.applyOp(OpExpireJobs, ExpireJobsOp{NowNs: uint64(now.UnixNano())}).Err
}

// PurgeJobs deletes terminal-state jobs older than the given retention period.
func (s *Store) PurgeJobs(retention time.Duration) error {
	cutoff := time.Now().Add(-retention)
	return s.applyOp(OpPurgeJobs, PurgeJobsOp{CutoffNs: uint64(cutoff.UnixNano())}).Err
}
