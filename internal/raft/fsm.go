package raft

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cockroachdb/pebble"
	"github.com/hashicorp/raft"
	"github.com/user/corvo/internal/kv"
	"github.com/user/corvo/internal/store"

	_ "modernc.org/sqlite"
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
	sqliteQueued atomic.Uint64
	sqliteDoneN  atomic.Uint64

	rebuildMu       sync.Mutex
	lastRebuildAt   time.Time
	lastRebuildDur  time.Duration
	lastRebuildErr  string
	lastRebuildGood bool

	// activeCount caches the number of active keys per queue, maintained
	// deterministically during FSM.Apply to avoid O(n) Pebble prefix scans.
	activeCount map[string]int

	// applyMultiMode controls how mixed-type OpMulti batches are executed:
	// "grouped" (default): group ops by type, 2-3 Pebble commits per batch
	// "indexed": single indexed Pebble batch for all ops, 1 commit
	// "individual": legacy per-op commits (N commits)
	applyMultiMode string
}

// NewFSM creates a new FSM with the given Pebble and SQLite databases.
func NewFSM(pdb *pebble.DB, sqliteDB *sql.DB) *FSM {
	f := &FSM{
		pebble:       pdb,
		sqlite:       sqliteDB,
		writeOpts:    pebble.Sync,
		sqliteMirror: true,
		lifecycleOn:  false,
		eventSeq:     loadEventCursor(pdb),
	}
	f.rebuildActiveCount()
	return f
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
	case store.OpCreateNamespace:
		return f.applyCreateNamespace(data)
	case store.OpDeleteNamespace:
		return f.applyDeleteNamespace(data)
	case store.OpSetAuthRole:
		return f.applySetAuthRole(data)
	case store.OpDeleteAuthRole:
		return f.applyDeleteAuthRole(data)
	case store.OpAssignAPIKeyRole:
		return f.applyAssignAPIKeyRole(data)
	case store.OpUnassignAPIKeyRole:
		return f.applyUnassignAPIKeyRole(data)
	case store.OpSetSSOSettings:
		return f.applySetSSOSettings(data)
	case store.OpUpsertAPIKey:
		return f.applyUpsertAPIKey(data)
	case store.OpDeleteAPIKey:
		return f.applyDeleteAPIKey(data)
	case store.OpInsertAuditLog:
		return f.applyInsertAuditLog(data)
	case store.OpUpdateAPIKeyUsed:
		return f.applyUpdateAPIKeyUsed(data)
	case store.OpUpsertWebhook:
		return f.applyUpsertWebhook(data)
	case store.OpDeleteWebhook:
		return f.applyDeleteWebhook(data)
	case store.OpUpdateWebhookStatus:
		return f.applyUpdateWebhookStatus(data)
	case store.OpSetNamespaceRateLimit:
		return f.applySetNamespaceRateLimit(data)
	case store.OpExpireJobs:
		return f.applyExpireJobs(data)
	case store.OpPurgeJobs:
		return f.applyPurgeJobs(data)
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
	case store.OpCreateNamespace:
		if op.CreateNamespace != nil {
			return f.applyCreateNamespaceOp(*op.CreateNamespace)
		}
		return &store.OpResult{Err: fmt.Errorf("create namespace op missing payload")}
	case store.OpDeleteNamespace:
		if op.DeleteNamespace != nil {
			return f.applyDeleteNamespaceOp(*op.DeleteNamespace)
		}
		return &store.OpResult{Err: fmt.Errorf("delete namespace op missing payload")}
	case store.OpSetAuthRole:
		if op.SetAuthRole != nil {
			return f.applySetAuthRoleOp(*op.SetAuthRole)
		}
		return &store.OpResult{Err: fmt.Errorf("set auth role op missing payload")}
	case store.OpDeleteAuthRole:
		if op.DeleteAuthRole != nil {
			return f.applyDeleteAuthRoleOp(*op.DeleteAuthRole)
		}
		return &store.OpResult{Err: fmt.Errorf("delete auth role op missing payload")}
	case store.OpAssignAPIKeyRole:
		if op.AssignAPIKeyRole != nil {
			return f.applyAssignAPIKeyRoleOp(*op.AssignAPIKeyRole)
		}
		return &store.OpResult{Err: fmt.Errorf("assign api key role op missing payload")}
	case store.OpUnassignAPIKeyRole:
		if op.UnassignAPIKeyRole != nil {
			return f.applyUnassignAPIKeyRoleOp(*op.UnassignAPIKeyRole)
		}
		return &store.OpResult{Err: fmt.Errorf("unassign api key role op missing payload")}
	case store.OpSetSSOSettings:
		if op.SetSSOSettings != nil {
			return f.applySetSSOSettingsOp(*op.SetSSOSettings)
		}
		return &store.OpResult{Err: fmt.Errorf("set sso settings op missing payload")}
	case store.OpUpsertAPIKey:
		if op.UpsertAPIKey != nil {
			return f.applyUpsertAPIKeyOp(*op.UpsertAPIKey)
		}
		return &store.OpResult{Err: fmt.Errorf("upsert api key op missing payload")}
	case store.OpDeleteAPIKey:
		if op.DeleteAPIKey != nil {
			return f.applyDeleteAPIKeyOp(*op.DeleteAPIKey)
		}
		return &store.OpResult{Err: fmt.Errorf("delete api key op missing payload")}
	case store.OpInsertAuditLog:
		if op.InsertAuditLog != nil {
			return f.applyInsertAuditLogOp(*op.InsertAuditLog)
		}
		return &store.OpResult{Err: fmt.Errorf("insert audit log op missing payload")}
	case store.OpUpdateAPIKeyUsed:
		if op.UpdateAPIKeyUsed != nil {
			return f.applyUpdateAPIKeyUsedOp(*op.UpdateAPIKeyUsed)
		}
		return &store.OpResult{Err: fmt.Errorf("update api key used op missing payload")}
	case store.OpUpsertWebhook:
		if op.UpsertWebhook != nil {
			return f.applyUpsertWebhookOp(*op.UpsertWebhook)
		}
		return &store.OpResult{Err: fmt.Errorf("upsert webhook op missing payload")}
	case store.OpDeleteWebhook:
		if op.DeleteWebhook != nil {
			return f.applyDeleteWebhookOp(*op.DeleteWebhook)
		}
		return &store.OpResult{Err: fmt.Errorf("delete webhook op missing payload")}
	case store.OpUpdateWebhookStatus:
		if op.UpdateWebhookStatus != nil {
			return f.applyUpdateWebhookStatusOp(*op.UpdateWebhookStatus)
		}
		return &store.OpResult{Err: fmt.Errorf("update webhook status op missing payload")}
	case store.OpSetNamespaceRateLimit:
		if op.SetNamespaceRateLimit != nil {
			return f.applySetNamespaceRateLimitOp(*op.SetNamespaceRateLimit)
		}
		return &store.OpResult{Err: fmt.Errorf("set namespace rate limit op missing payload")}
	case store.OpExpireJobs:
		if op.ExpireJobs != nil {
			return f.applyExpireJobsOp(*op.ExpireJobs)
		}
		return &store.OpResult{Err: fmt.Errorf("expire jobs op missing payload")}
	case store.OpPurgeJobs:
		if op.PurgeJobs != nil {
			return f.applyPurgeJobsOp(*op.PurgeJobs)
		}
		return &store.OpResult{Err: fmt.Errorf("purge jobs op missing payload")}
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

	// Fast path: all-same-type batches use a single Pebble commit regardless of mode.
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

	allAckBatch := true
	for _, sub := range ops {
		if sub.Type != store.OpAckBatch || sub.AckBatch == nil {
			allAckBatch = false
			break
		}
	}
	if allAckBatch {
		return f.applyMultiAckBatch(ops)
	}

	allFetchBatch := true
	for _, sub := range ops {
		if sub.Type != store.OpFetchBatch || sub.FetchBatch == nil {
			allFetchBatch = false
			break
		}
	}
	if allFetchBatch {
		return f.applyMultiFetchBatch(ops)
	}

	// Mixed-type batch: dispatch based on configured mode.
	switch f.applyMultiMode {
	case "indexed":
		return f.applyMultiIndexed(ops)
	case "individual":
		return f.applyMultiIndividual(ops)
	default: // "grouped"
		return f.applyMultiGrouped(ops)
	}
}

// applyMultiIndividual processes each op individually with its own Pebble commit.
// This is the legacy behavior — N ops = N commits.
func (f *FSM) applyMultiIndividual(ops []*store.DecodedRaftOp) *store.OpResult {
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

// applyMultiGrouped groups ops by type and processes each group with a merged
// handler that shares a single Pebble commit. Mixed types use 2-3 commits
// instead of N individual commits.
func (f *FSM) applyMultiGrouped(ops []*store.DecodedRaftOp) *store.OpResult {
	results := make([]*store.OpResult, len(ops))

	// Partition ops by type, preserving original indices for result placement.
	type indexedOp struct {
		idx int
		op  *store.DecodedRaftOp
	}
	var ackBatchOps, fetchBatchOps, otherOps []indexedOp

	for i, sub := range ops {
		switch sub.Type {
		case store.OpAckBatch:
			if sub.AckBatch != nil {
				ackBatchOps = append(ackBatchOps, indexedOp{i, sub})
			} else {
				otherOps = append(otherOps, indexedOp{i, sub})
			}
		case store.OpFetchBatch:
			if sub.FetchBatch != nil {
				fetchBatchOps = append(fetchBatchOps, indexedOp{i, sub})
			} else {
				otherOps = append(otherOps, indexedOp{i, sub})
			}
		default:
			otherOps = append(otherOps, indexedOp{i, sub})
		}
	}

	// Process acks first — frees active slots that fetches can use.
	if len(ackBatchOps) > 0 {
		grouped := make([]*store.DecodedRaftOp, len(ackBatchOps))
		for i, iop := range ackBatchOps {
			grouped[i] = iop.op
		}
		res := f.applyMultiAckBatch(grouped)
		subResults := res.Data.([]*store.OpResult)
		for i, iop := range ackBatchOps {
			results[iop.idx] = subResults[i]
		}
	}

	// Then fetches — benefits from ack-freed capacity.
	if len(fetchBatchOps) > 0 {
		grouped := make([]*store.DecodedRaftOp, len(fetchBatchOps))
		for i, iop := range fetchBatchOps {
			grouped[i] = iop.op
		}
		res := f.applyMultiFetchBatch(grouped)
		subResults := res.Data.([]*store.OpResult)
		for i, iop := range fetchBatchOps {
			results[iop.idx] = subResults[i]
		}
	}

	// Remaining ops processed individually.
	for _, iop := range otherOps {
		if iop.op.Type == store.OpMulti {
			results[iop.idx] = &store.OpResult{Err: fmt.Errorf("nested multi op is not allowed")}
		} else {
			results[iop.idx] = f.applyDecoded(iop.op)
		}
	}

	return &store.OpResult{Data: results}
}

// applyMultiIndexed processes all ops using a single indexed Pebble batch.
// For ack and fetch ops, reads go through the batch (seeing prior writes) and
// a single Commit() flushes them together. For other op types (the default
// case), applyDecoded is called which commits its own internal batch, so mixed
// batches do not achieve a single Pebble commit. In practice, "indexed" mode
// is opt-in and mixed batches are uncommon since the homogeneous fast paths
// (all-enqueue, all-fetch, all-ack) fire first.
func (f *FSM) applyMultiIndexed(ops []*store.DecodedRaftOp) *store.OpResult {
	results := make([]*store.OpResult, len(ops))

	batch := f.pebble.NewIndexedBatch()
	defer batch.Close()

	// Sort: acks before fetches before others. Acks free active slots that
	// subsequent fetches can use. We track original indices for result placement.
	type indexedOp struct {
		idx int
		op  *store.DecodedRaftOp
	}
	sorted := make([]indexedOp, 0, len(ops))

	// Pass 1: ack-batch ops.
	for i, sub := range ops {
		if sub.Type == store.OpAckBatch {
			sorted = append(sorted, indexedOp{i, sub})
		}
	}
	// Pass 2: fetch-batch ops.
	for i, sub := range ops {
		if sub.Type == store.OpFetchBatch {
			sorted = append(sorted, indexedOp{i, sub})
		}
	}
	// Pass 3: everything else.
	for i, sub := range ops {
		if sub.Type != store.OpAckBatch && sub.Type != store.OpFetchBatch {
			sorted = append(sorted, indexedOp{i, sub})
		}
	}

	// Track claimed jobs across all FetchBatch ops to prevent double-fetch.
	claimed := make(map[string]struct{})
	// Track workers already written in this batch to skip redundant json.Marshal + Set.
	seenWorkers := make(map[string]struct{})
	var allSqliteCallbacks []func(db sqlExecer) error
	anyWrite := false

	for _, iop := range sorted {
		sub := iop.op
		switch sub.Type {
		case store.OpAckBatch:
			res := f.applyAckBatchIntoBatch(batch, *sub.AckBatch, &allSqliteCallbacks)
			results[iop.idx] = res
			if res.Err == nil {
				anyWrite = true
			}
		case store.OpFetchBatch:
			res := f.applyFetchBatchIntoBatch(batch, *sub.FetchBatch, claimed, seenWorkers, &allSqliteCallbacks)
			results[iop.idx] = res
			if res.Err == nil {
				anyWrite = true
			}
		case store.OpMulti:
			results[iop.idx] = &store.OpResult{Err: fmt.Errorf("nested multi op is not allowed")}
		default:
			// For non-hot-path ops, apply individually but into the shared batch.
			// Fall back to per-op processing with its own internal batch.
			results[iop.idx] = f.applyDecoded(sub)
			anyWrite = true
		}
	}

	if !anyWrite {
		return &store.OpResult{Data: results}
	}

	if err := f.appendLifecycleCursor(batch); err != nil {
		errResult := &store.OpResult{Err: err}
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = errResult
			}
		}
		return &store.OpResult{Data: results}
	}

	if err := batch.Commit(f.writeOpts); err != nil {
		errResult := &store.OpResult{Err: fmt.Errorf("pebble commit multi indexed: %w", err)}
		for i := range results {
			if results[i] == nil || results[i].Err == nil {
				results[i] = errResult
			}
		}
		return &store.OpResult{Data: results}
	}

	if len(allSqliteCallbacks) > 0 {
		f.syncSQLite(func(db sqlExecer) error {
			for _, cb := range allSqliteCallbacks {
				if err := cb(db); err != nil {
					return err
				}
			}
			return nil
		})
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
	if err := restoreFromSnapshot(f.pebble, f.sqlite, rc); err != nil {
		return err
	}
	f.rebuildActiveCount()
	return nil
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
			f.sqliteQueued.Add(1)
			return
		default:
			n := f.sqliteDrops.Add(1)
			if n == 1 || n%10000 == 0 {
				slog.Warn("sqlite mirror queue full; dropping mirror updates", "total_drops", n)
			}
			return
		}
	}
	f.sqliteMu.Lock()
	defer f.sqliteMu.Unlock()
	if err := fn(f.sqlite); err != nil {
		slog.Error("sqlite sync failed (non-fatal)", "error", err)
	}
	f.sqliteDoneN.Add(1)
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
		f.sqliteQueue = make(chan func(db sqlExecer) error, 131072)
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

// SetApplyMultiMode sets how mixed-type multi-apply batches are processed.
func (f *FSM) SetApplyMultiMode(mode string) {
	switch mode {
	case "indexed", "individual":
		f.applyMultiMode = mode
	default:
		f.applyMultiMode = "grouped"
	}
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
	queued := f.sqliteQueued.Load()
	done := f.sqliteDoneN.Load()
	dropped := f.sqliteDrops.Load()
	pending := uint64(0)
	if queued > done+dropped {
		pending = queued - done - dropped
	}
	out := map[string]any{
		"enabled": f.sqliteMirror,
		"async":   f.sqliteAsync,
		"dropped": dropped,
		"queued":  queued,
		"applied": done,
		"lag":     pending,
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

func isSQLiteBusy(err error) bool {
	if err == nil {
		return false
	}
	s := err.Error()
	return strings.Contains(s, "SQLITE_BUSY") || strings.Contains(s, "database is locked")
}

func tryFlush(f *FSM, batch []func(db sqlExecer) error) bool {
	tx, err := f.sqlite.Begin()
	if err != nil {
		if isSQLiteBusy(err) {
			return false
		}
		slog.Error("sqlite mirror begin failed", "error", err)
		return true // don't retry non-busy errors
	}
	f.sqliteMu.Lock()
	defer f.sqliteMu.Unlock()

	for i, fn := range batch {
		sp := fmt.Sprintf("sp%d", i)
		if _, err := tx.Exec("SAVEPOINT " + sp); err != nil {
			if isSQLiteBusy(err) {
				tx.Rollback()
				return false
			}
			slog.Error("sqlite mirror savepoint failed", "error", err)
			f.sqliteDoneN.Add(1)
			continue
		}
		if err := fn(tx); err != nil {
			if isSQLiteBusy(err) {
				tx.Rollback()
				return false
			}
			_, _ = tx.Exec("ROLLBACK TO " + sp)
			_, _ = tx.Exec("RELEASE " + sp)
			slog.Error("sqlite mirror apply failed", "error", err)
			f.sqliteDoneN.Add(1)
			continue
		}
		if _, err := tx.Exec("RELEASE " + sp); err != nil {
			slog.Error("sqlite mirror release failed", "error", err)
		}
		f.sqliteDoneN.Add(1)
	}

	if err := tx.Commit(); err != nil {
		if isSQLiteBusy(err) {
			tx.Rollback()
			return false
		}
		slog.Error("sqlite mirror commit failed", "error", err)
	}
	return true
}

func (f *FSM) sqliteMirrorLoop() {
	defer close(f.sqliteDone)

	const maxBatch = 1024
	flushInterval := 2 * time.Millisecond
	timer := time.NewTimer(flushInterval)
	defer timer.Stop()

	batch := make([]func(db sqlExecer) error, 0, maxBatch)

	flush := func() {
		if len(batch) == 0 {
			return
		}
		const maxRetries = 3
		for attempt := range maxRetries {
			if attempt > 0 {
				time.Sleep(time.Duration(attempt) * 5 * time.Millisecond)
			}
			if tryFlush(f, batch) {
				break
			}
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

// rebuildActiveCount scans Pebble for all active keys and populates the
// in-memory activeCount map. Called on startup and after snapshot restore.
func (f *FSM) rebuildActiveCount() {
	m := make(map[string]int)
	prefix := []byte(kv.PrefixActive)
	iter, err := f.pebble.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		f.activeCount = m
		return
	}
	defer iter.Close()
	for iter.First(); iter.Valid(); iter.Next() {
		key := iter.Key()
		// Active key format: a|{queue}\x00{job_id}
		rest := key[len(kv.PrefixActive):]
		if idx := bytes.IndexByte(rest, 0); idx >= 0 {
			queue := string(rest[:idx])
			m[queue]++
		}
	}
	f.activeCount = m
}

// incrActive increments the in-memory active count for a queue.
func (f *FSM) incrActive(queue string) {
	f.activeCount[queue]++
}

// decrActive decrements the in-memory active count for a queue.
func (f *FSM) decrActive(queue string) {
	if n := f.activeCount[queue] - 1; n > 0 {
		f.activeCount[queue] = n
	} else {
		delete(f.activeCount, queue)
	}
}

// resetActiveCount sets the active count for a queue to zero.
func (f *FSM) resetActiveCount(queue string) {
	delete(f.activeCount, queue)
}

// getActiveCount returns the cached active count for a queue.
func (f *FSM) getActiveCount(queue string) int {
	return f.activeCount[queue]
}
