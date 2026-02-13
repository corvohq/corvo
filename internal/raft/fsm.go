package raft

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cockroachdb/pebble"
	"github.com/hashicorp/raft"
	"github.com/user/jobbie/internal/store"

	_ "github.com/mattn/go-sqlite3"
)

// FSM implements the raft.FSM interface. It applies log entries to both
// Pebble (source of truth) and SQLite (materialized view for queries).
type FSM struct {
	pebble       *pebble.DB
	sqlite       *sql.DB
	writeOpts    *pebble.WriteOptions
	sqliteMirror bool
	lifecycleOn  bool
	eventSeq     uint64
	sqliteAsync  bool
	sqliteQueue  chan func(db sqlExecer) error
	sqliteStop   chan struct{}
	sqliteDone   chan struct{}
	sqliteMu     sync.Mutex
	sqliteDrops  atomic.Uint64

	rebuildMu       sync.Mutex
	lastRebuildAt   time.Time
	lastRebuildDur  time.Duration
	lastRebuildErr  string
	lastRebuildGood bool
}

// NewFSM creates a new FSM with the given Pebble and SQLite databases.
func NewFSM(pdb *pebble.DB, sqliteDB *sql.DB) *FSM {
	return &FSM{
		pebble:       pdb,
		sqlite:       sqliteDB,
		writeOpts:    pebble.Sync,
		sqliteMirror: true,
		lifecycleOn:  false,
		eventSeq:     loadEventCursor(pdb),
	}
}

// Apply implements raft.FSM. It dispatches the log entry to the appropriate handler.
func (f *FSM) Apply(log *raft.Log) interface{} {
	op, err := store.DecodeRaftOp(log.Data)
	if err != nil {
		return &store.OpResult{Err: fmt.Errorf("decode op: %w", err)}
	}
	return f.applyDecoded(op)
}

func (f *FSM) applyByType(opType store.OpType, data json.RawMessage) *store.OpResult {
	switch opType {
	case store.OpMulti:
		return f.applyMulti(data)

	case store.OpEnqueue:
		return f.applyEnqueue(data)
	case store.OpEnqueueBatch:
		return f.applyEnqueueBatch(data)
	case store.OpFetch:
		return f.applyFetch(data)
	case store.OpFetchBatch:
		return f.applyFetchBatch(data)
	case store.OpAck:
		return f.applyAck(data)
	case store.OpAckBatch:
		return f.applyAckBatch(data)
	case store.OpFail:
		return f.applyFail(data)
	case store.OpHeartbeat:
		return f.applyHeartbeat(data)
	case store.OpRetryJob:
		return f.applyRetryJob(data)
	case store.OpCancelJob:
		return f.applyCancelJob(data)
	case store.OpMoveJob:
		return f.applyMoveJob(data)
	case store.OpDeleteJob:
		return f.applyDeleteJob(data)
	case store.OpPauseQueue:
		return f.applyPauseQueue(data)
	case store.OpResumeQueue:
		return f.applyResumeQueue(data)
	case store.OpClearQueue:
		return f.applyClearQueue(data)
	case store.OpDeleteQueue:
		return f.applyDeleteQueue(data)
	case store.OpSetConcurrency:
		return f.applySetConcurrency(data)
	case store.OpSetThrottle:
		return f.applySetThrottle(data)
	case store.OpRemoveThrottle:
		return f.applyRemoveThrottle(data)
	case store.OpPromote:
		return f.applyPromote(data)
	case store.OpReclaim:
		return f.applyReclaim(data)
	case store.OpBulkAction:
		return f.applyBulkAction(data)
	case store.OpCleanUnique:
		return f.applyCleanUnique(data)
	case store.OpCleanRateLimit:
		return f.applyCleanRateLimit(data)
	case store.OpSetBudget:
		return f.applySetBudget(data)
	case store.OpDeleteBudget:
		return f.applyDeleteBudget(data)
	default:
		return &store.OpResult{Err: fmt.Errorf("unknown op type: %d", opType)}
	}
}

func (f *FSM) applyDecoded(op *store.DecodedRaftOp) *store.OpResult {
	switch op.Type {
	case store.OpMulti:
		if len(op.Multi) > 0 {
			return f.applyMultiDecoded(op.Multi)
		}
		return &store.OpResult{Err: fmt.Errorf("multi op missing payload")}
	case store.OpEnqueue:
		if op.Enqueue != nil {
			return f.applyEnqueueOp(*op.Enqueue)
		}
		return &store.OpResult{Err: fmt.Errorf("enqueue op missing payload")}
	case store.OpEnqueueBatch:
		if op.EnqueueBatch != nil {
			return f.applyEnqueueBatchOp(*op.EnqueueBatch)
		}
		return &store.OpResult{Err: fmt.Errorf("enqueue batch op missing payload")}
	case store.OpFetch:
		if op.Fetch != nil {
			return f.applyFetchOp(*op.Fetch)
		}
		return &store.OpResult{Err: fmt.Errorf("fetch op missing payload")}
	case store.OpFetchBatch:
		if op.FetchBatch != nil {
			return f.applyFetchBatchOp(*op.FetchBatch)
		}
		return &store.OpResult{Err: fmt.Errorf("fetch batch op missing payload")}
	case store.OpAck:
		if op.Ack != nil {
			return f.applyAckOp(*op.Ack)
		}
		return &store.OpResult{Err: fmt.Errorf("ack op missing payload")}
	case store.OpAckBatch:
		if op.AckBatch != nil {
			return f.applyAckBatchOp(*op.AckBatch)
		}
		return &store.OpResult{Err: fmt.Errorf("ack batch op missing payload")}
	case store.OpFail:
		if op.Fail != nil {
			return f.applyFailOp(*op.Fail)
		}
		return &store.OpResult{Err: fmt.Errorf("fail op missing payload")}
	case store.OpHeartbeat:
		if op.Heartbeat != nil {
			return f.applyHeartbeatOp(*op.Heartbeat)
		}
		return &store.OpResult{Err: fmt.Errorf("heartbeat op missing payload")}
	case store.OpRetryJob:
		if op.RetryJob != nil {
			return f.applyRetryJobOp(*op.RetryJob)
		}
		return &store.OpResult{Err: fmt.Errorf("retry op missing payload")}
	case store.OpCancelJob:
		if op.CancelJob != nil {
			return f.applyCancelJobOp(*op.CancelJob)
		}
		return &store.OpResult{Err: fmt.Errorf("cancel op missing payload")}
	case store.OpMoveJob:
		if op.MoveJob != nil {
			return f.applyMoveJobOp(*op.MoveJob)
		}
		return &store.OpResult{Err: fmt.Errorf("move op missing payload")}
	case store.OpDeleteJob:
		if op.DeleteJob != nil {
			return f.applyDeleteJobOp(*op.DeleteJob)
		}
		return &store.OpResult{Err: fmt.Errorf("delete op missing payload")}
	case store.OpPauseQueue:
		if op.PauseQueue != nil {
			return f.applyPauseQueueOp(*op.PauseQueue)
		}
		return &store.OpResult{Err: fmt.Errorf("pause queue op missing payload")}
	case store.OpResumeQueue:
		if op.ResumeQueue != nil {
			return f.applyResumeQueueOp(*op.ResumeQueue)
		}
		return &store.OpResult{Err: fmt.Errorf("resume queue op missing payload")}
	case store.OpClearQueue:
		if op.ClearQueue != nil {
			return f.applyClearQueueOp(*op.ClearQueue)
		}
		return &store.OpResult{Err: fmt.Errorf("clear queue op missing payload")}
	case store.OpDeleteQueue:
		if op.DeleteQueue != nil {
			return f.applyDeleteQueueOp(*op.DeleteQueue)
		}
		return &store.OpResult{Err: fmt.Errorf("delete queue op missing payload")}
	case store.OpSetConcurrency:
		if op.SetConc != nil {
			return f.applySetConcurrencyOp(*op.SetConc)
		}
		return &store.OpResult{Err: fmt.Errorf("set concurrency op missing payload")}
	case store.OpSetThrottle:
		if op.SetThrottle != nil {
			return f.applySetThrottleOp(*op.SetThrottle)
		}
		return &store.OpResult{Err: fmt.Errorf("set throttle op missing payload")}
	case store.OpRemoveThrottle:
		if op.RemoveThr != nil {
			return f.applyRemoveThrottleOp(*op.RemoveThr)
		}
		return &store.OpResult{Err: fmt.Errorf("remove throttle op missing payload")}
	case store.OpPromote:
		if op.Promote != nil {
			return f.applyPromoteOp(*op.Promote)
		}
		return &store.OpResult{Err: fmt.Errorf("promote op missing payload")}
	case store.OpReclaim:
		if op.Reclaim != nil {
			return f.applyReclaimOp(*op.Reclaim)
		}
		return &store.OpResult{Err: fmt.Errorf("reclaim op missing payload")}
	case store.OpBulkAction:
		if op.BulkAction != nil {
			return f.applyBulkActionOp(*op.BulkAction)
		}
		return &store.OpResult{Err: fmt.Errorf("bulk action op missing payload")}
	case store.OpCleanUnique:
		if op.CleanUnique != nil {
			return f.applyCleanUniqueOp(*op.CleanUnique)
		}
		return &store.OpResult{Err: fmt.Errorf("clean unique op missing payload")}
	case store.OpCleanRateLimit:
		if op.CleanRate != nil {
			return f.applyCleanRateLimitOp(*op.CleanRate)
		}
		return &store.OpResult{Err: fmt.Errorf("clean rate op missing payload")}
	case store.OpSetBudget:
		if op.SetBudget != nil {
			return f.applySetBudgetOp(*op.SetBudget)
		}
		return &store.OpResult{Err: fmt.Errorf("set budget op missing payload")}
	case store.OpDeleteBudget:
		if op.DeleteBudget != nil {
			return f.applyDeleteBudgetOp(*op.DeleteBudget)
		}
		return &store.OpResult{Err: fmt.Errorf("delete budget op missing payload")}
	default:
		return &store.OpResult{Err: fmt.Errorf("unknown op type: %d", op.Type)}
	}
}

func (f *FSM) applyMulti(data json.RawMessage) *store.OpResult {
	var op store.MultiOp
	if err := json.Unmarshal(data, &op); err != nil {
		return &store.OpResult{Err: fmt.Errorf("unmarshal multi op: %w", err)}
	}
	if len(op.Ops) == 0 {
		return &store.OpResult{Data: []*store.OpResult{}}
	}

	// Fast path for enqueue-heavy workloads: apply all enqueues in a single
	// Pebble batch and single SQLite mirror callback.
	allEnqueue := true
	enqueues := make([]store.EnqueueOp, len(op.Ops))
	for i, sub := range op.Ops {
		if sub.Type != store.OpEnqueue {
			allEnqueue = false
			break
		}
		if err := json.Unmarshal(sub.Data, &enqueues[i]); err != nil {
			allEnqueue = false
			break
		}
	}
	if allEnqueue {
		return f.applyMultiEnqueue(enqueues)
	}

	// Fast path when the group-commit batch contains only enqueue-batch ops.
	allEnqueueBatch := true
	enqueueBatches := make([]store.EnqueueBatchOp, len(op.Ops))
	for i, sub := range op.Ops {
		if sub.Type != store.OpEnqueueBatch {
			allEnqueueBatch = false
			break
		}
		if err := json.Unmarshal(sub.Data, &enqueueBatches[i]); err != nil {
			allEnqueueBatch = false
			break
		}
	}
	if allEnqueueBatch {
		return f.applyMultiEnqueueBatch(enqueueBatches)
	}

	results := make([]*store.OpResult, 0, len(op.Ops))
	for _, sub := range op.Ops {
		if sub.Type == store.OpMulti {
			results = append(results, &store.OpResult{Err: fmt.Errorf("nested multi op is not allowed")})
			continue
		}
		results = append(results, f.applyByType(sub.Type, sub.Data))
	}
	return &store.OpResult{Data: results}
}

func (f *FSM) applyMultiDecoded(ops []*store.DecodedRaftOp) *store.OpResult {
	if len(ops) == 0 {
		return &store.OpResult{Data: []*store.OpResult{}}
	}

	allEnqueue := true
	enqueues := make([]store.EnqueueOp, len(ops))
	for i, sub := range ops {
		if sub.Type != store.OpEnqueue || sub.Enqueue == nil {
			allEnqueue = false
			break
		}
		enqueues[i] = *sub.Enqueue
	}
	if allEnqueue {
		return f.applyMultiEnqueue(enqueues)
	}

	allEnqueueBatch := true
	enqueueBatches := make([]store.EnqueueBatchOp, len(ops))
	for i, sub := range ops {
		if sub.Type != store.OpEnqueueBatch || sub.EnqueueBatch == nil {
			allEnqueueBatch = false
			break
		}
		enqueueBatches[i] = *sub.EnqueueBatch
	}
	if allEnqueueBatch {
		return f.applyMultiEnqueueBatch(enqueueBatches)
	}

	results := make([]*store.OpResult, 0, len(ops))
	for _, sub := range ops {
		if sub.Type == store.OpMulti {
			results = append(results, &store.OpResult{Err: fmt.Errorf("nested multi op is not allowed")})
			continue
		}
		results = append(results, f.applyDecoded(sub))
	}
	return &store.OpResult{Data: results}
}

// Snapshot implements raft.FSM.
func (f *FSM) Snapshot() (raft.FSMSnapshot, error) {
	return &fsmSnapshot{pebble: f.pebble, sqlite: f.sqlite}, nil
}

// Restore implements raft.FSM.
func (f *FSM) Restore(rc io.ReadCloser) error {
	defer rc.Close()
	return restoreFromSnapshot(f.pebble, f.sqlite, rc)
}

// PebbleDB returns the underlying Pebble database.
func (f *FSM) PebbleDB() *pebble.DB {
	return f.pebble
}

// SQLiteDB returns the underlying SQLite database.
func (f *FSM) SQLiteDB() *sql.DB {
	return f.sqlite
}

// syncSQLite runs a function against SQLite. If it fails, we log the error
// but don't fail the Raft apply — SQLite is a rebuildable materialized view.
func (f *FSM) syncSQLite(fn func(db sqlExecer) error) {
	if !f.sqliteMirror {
		return
	}
	if f.sqliteAsync {
		select {
		case f.sqliteQueue <- fn:
			return
		default:
			f.sqliteDrops.Add(1)
			slog.Warn("sqlite mirror queue full; dropping mirror update")
			return
		}
	}
	f.sqliteMu.Lock()
	defer f.sqliteMu.Unlock()
	if err := fn(f.sqlite); err != nil {
		slog.Error("sqlite sync failed (non-fatal)", "error", err)
	}
}

// SetSQLiteMirrorEnabled toggles synchronous SQLite materialized-view writes.
func (f *FSM) SetSQLiteMirrorEnabled(enabled bool) {
	f.sqliteMirror = enabled
}

// SetLifecycleEventsEnabled toggles lifecycle event persistence.
func (f *FSM) SetLifecycleEventsEnabled(enabled bool) {
	f.lifecycleOn = enabled
}

// SetSQLiteMirrorAsync toggles async SQLite materialized-view writes.
func (f *FSM) SetSQLiteMirrorAsync(async bool) {
	if async == f.sqliteAsync {
		return
	}
	if async {
		f.sqliteQueue = make(chan func(db sqlExecer) error, 16384)
		f.sqliteStop = make(chan struct{})
		f.sqliteDone = make(chan struct{})
		f.sqliteAsync = true
		go f.sqliteMirrorLoop()
		return
	}

	f.sqliteAsync = false
	if f.sqliteStop != nil {
		close(f.sqliteStop)
		<-f.sqliteDone
	}
	f.sqliteQueue = nil
	f.sqliteStop = nil
	f.sqliteDone = nil
}

// SetPebbleNoSync toggles Pebble fsync behavior for benchmark mode.
func (f *FSM) SetPebbleNoSync(noSync bool) {
	if noSync {
		f.writeOpts = pebble.NoSync
		return
	}
	f.writeOpts = pebble.Sync
}

// Close flushes background workers.
func (f *FSM) Close() {
	f.SetSQLiteMirrorAsync(false)
}

// SQLiteMirrorStatus returns internal SQLite mirror health counters.
func (f *FSM) SQLiteMirrorStatus() map[string]any {
	out := map[string]any{
		"enabled": f.sqliteMirror,
		"async":   f.sqliteAsync,
		"dropped": f.sqliteDrops.Load(),
	}
	if f.sqliteQueue != nil {
		out["queue_depth"] = len(f.sqliteQueue)
		out["queue_capacity"] = cap(f.sqliteQueue)
	} else {
		out["queue_depth"] = 0
		out["queue_capacity"] = 0
	}
	return out
}

func (f *FSM) setRebuildStatus(err error, startedAt time.Time, dur time.Duration) {
	f.rebuildMu.Lock()
	defer f.rebuildMu.Unlock()
	f.lastRebuildAt = startedAt
	f.lastRebuildDur = dur
	f.lastRebuildGood = err == nil
	if err != nil {
		f.lastRebuildErr = err.Error()
	} else {
		f.lastRebuildErr = ""
	}
}

// SQLiteRebuildStatus returns last rebuild metadata.
func (f *FSM) SQLiteRebuildStatus() map[string]any {
	f.rebuildMu.Lock()
	defer f.rebuildMu.Unlock()
	out := map[string]any{
		"ran": false,
	}
	if f.lastRebuildAt.IsZero() {
		return out
	}
	out["ran"] = true
	out["last_started_at"] = f.lastRebuildAt.UTC().Format(time.RFC3339Nano)
	out["last_duration_ms"] = f.lastRebuildDur.Milliseconds()
	out["last_success"] = f.lastRebuildGood
	if f.lastRebuildErr != "" {
		out["last_error"] = f.lastRebuildErr
	}
	return out
}

func (f *FSM) sqliteMirrorLoop() {
	defer close(f.sqliteDone)

	const maxBatch = 256
	flushInterval := 2 * time.Millisecond
	timer := time.NewTimer(flushInterval)
	defer timer.Stop()

	batch := make([]func(db sqlExecer) error, 0, maxBatch)

	flush := func() {
		if len(batch) == 0 {
			return
		}
		tx, err := f.sqlite.Begin()
		if err != nil {
			slog.Error("sqlite mirror begin failed", "error", err)
			batch = batch[:0]
			return
		}
		f.sqliteMu.Lock()
		defer f.sqliteMu.Unlock()

		for i, fn := range batch {
			sp := fmt.Sprintf("sp%d", i)
			if _, err := tx.Exec("SAVEPOINT " + sp); err != nil {
				slog.Error("sqlite mirror savepoint failed", "error", err)
				continue
			}
			if err := fn(tx); err != nil {
				_, _ = tx.Exec("ROLLBACK TO " + sp)
				_, _ = tx.Exec("RELEASE " + sp)
				slog.Error("sqlite mirror apply failed", "error", err)
				continue
			}
			if _, err := tx.Exec("RELEASE " + sp); err != nil {
				slog.Error("sqlite mirror release failed", "error", err)
			}
		}

		if err := tx.Commit(); err != nil {
			slog.Error("sqlite mirror commit failed", "error", err)
		}
		batch = batch[:0]
	}

	for {
		select {
		case fn := <-f.sqliteQueue:
			batch = append(batch, fn)
		case <-timer.C:
			flush()
			timer.Reset(flushInterval)
			continue
		case <-f.sqliteStop:
			for {
				select {
				case fn := <-f.sqliteQueue:
					batch = append(batch, fn)
					if len(batch) >= maxBatch {
						flush()
					}
				default:
					flush()
					return
				}
			}
		}

		for len(batch) < maxBatch {
			select {
			case fn := <-f.sqliteQueue:
				batch = append(batch, fn)
			default:
				flush()
				if !timer.Stop() {
					select {
					case <-timer.C:
					default:
					}
				}
				timer.Reset(flushInterval)
				goto next
			}
		}
		flush()
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer.Reset(flushInterval)
	next:
	}
}
