package raft

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cockroachdb/pebble"
	"github.com/cockroachdb/pebble/bloom"
	"github.com/hashicorp/raft"
	"github.com/user/corvo/internal/kv"
	"github.com/user/corvo/internal/store"
)

// Cluster manages the Raft node, Pebble KV store, and SQLite materialized view.
type Cluster struct {
	raft      *raft.Raft
	fsm       *FSM
	transport *raft.NetworkTransport
	logStore  raftStore
	snapshot  raft.SnapshotStore
	config    ClusterConfig
	applyCh   chan *applyRequest
	applyExec chan []*applyRequest
	fetchMu   sync.Mutex
	fetchSem  map[string]chan struct{}
	queueHist *durationHistogram
	applyHist *durationHistogram
	stopCh    chan struct{}
	doneCh    chan struct{}
	workerCh  chan struct{}

	// fetchReserved tracks job IDs that have been pre-resolved by a stream
	// goroutine but not yet committed by the FSM. Prevents two concurrent
	// streams from pre-resolving the same job.
	fetchReserved sync.Map

	// pendingCache caches HasPendingJobs results; maps queue name → pendingCacheEntry.
	// Avoids hammering Pebble iterators when many workers poll the same queues.
	pendingCache sync.Map

	overloadTotal      atomic.Uint64
	fetchOverloadTotal atomic.Uint64
	appliedTotal       atomic.Uint64
}

type applyRequest struct {
	opType store.OpType
	data   any
	enqAt  time.Time
	respCh chan *store.OpResult
}

type durationHistogram struct {
	mu      sync.Mutex
	buckets []time.Duration
	counts  []uint64
	total   uint64
	sumNs   uint64
}

// NewCluster creates and starts a Raft cluster node.
func NewCluster(cfg ClusterConfig) (*Cluster, error) {
	if cfg.ApplyTimeout == 0 {
		cfg.ApplyTimeout = 10 * time.Second
	}
	if cfg.ApplyBatchMax <= 0 {
		cfg.ApplyBatchMax = 128
	}
	if cfg.ApplyBatchWindow <= 0 {
		cfg.ApplyBatchWindow = 2 * time.Millisecond
	}
	if cfg.ApplyBatchMinWait <= 0 {
		cfg.ApplyBatchMinWait = 100 * time.Microsecond
	}
	if cfg.ApplyBatchMinWait > cfg.ApplyBatchWindow {
		cfg.ApplyBatchMinWait = cfg.ApplyBatchWindow
	}
	if cfg.ApplyBatchExtendAt <= 1 {
		cfg.ApplyBatchExtendAt = 32
	}
	if cfg.ApplyBatchExtendAt > cfg.ApplyBatchMax {
		cfg.ApplyBatchExtendAt = cfg.ApplyBatchMax
	}
	if cfg.ApplyMaxPending <= 0 {
		cfg.ApplyMaxPending = cfg.ApplyBatchMax * 16
	}
	if cfg.ApplyMaxFetchQueueInFly <= 0 {
		cfg.ApplyMaxFetchQueueInFly = 32
	}
	if cfg.ApplySubBatchMax <= 0 {
		cfg.ApplySubBatchMax = 128
	}
	if cfg.ApplySubBatchMax > cfg.ApplyBatchMax {
		cfg.ApplySubBatchMax = cfg.ApplyBatchMax
	}
	if cfg.RaftStore == "" {
		cfg.RaftStore = "bolt"
	}
	if cfg.SnapshotThreshold == 0 {
		cfg.SnapshotThreshold = 2048
	}
	if cfg.SnapshotInterval <= 0 {
		cfg.SnapshotInterval = 1 * time.Minute
	}
	cfg.RaftStore = strings.ToLower(cfg.RaftStore)

	// Ensure directories exist
	pebbleDir := filepath.Join(cfg.DataDir, "pebble")
	raftDir := filepath.Join(cfg.DataDir, "raft")
	for _, dir := range []string{pebbleDir, raftDir} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			return nil, fmt.Errorf("create dir %s: %w", dir, err)
		}
	}

	// Open Pebble with write-heavy tuning to reduce flush/compaction stalls
	// on enqueue-heavy workloads.
	cache := pebble.NewCache(128 << 20) // 128 MB block cache
	defer cache.Unref()

	pebbleOpts := &pebble.Options{
		Cache:                       cache,
		MemTableSize:                64 << 20, // 64MB
		L0CompactionThreshold:       8,
		L0CompactionFileThreshold:   4,
		L0StopWritesThreshold:       24,
		MaxConcurrentCompactions: func() int {
			return 4
		},
		// Bloom filter on L0 only to reduce SSTable reads on point lookups
		// (job doc fetches by key). L1+ levels are not covered, so reads that
		// miss L0 still walk the full level stack — acceptable given L0 absorbs
		// most recent writes and the 128MB block cache covers hot keys.
		Levels: []pebble.LevelOptions{
			{FilterPolicy: bloom.FilterPolicy(10)},
		},
	}
	// PebbleNoSync=true means non-durable mode (no fsync); WAL sync batching
	// only makes sense when durability is enabled, since it amortizes fsync
	// cost across writes within a 2ms window.
	if !cfg.PebbleNoSync {
		pebbleOpts.WALMinSyncInterval = func() time.Duration { return 2 * time.Millisecond }
	}

	pdb, err := pebble.Open(pebbleDir, pebbleOpts)
	if err != nil {
		return nil, fmt.Errorf("open pebble: %w", err)
	}

	// Open SQLite materialized view.
	sqlitePath := strings.TrimSpace(cfg.SQLitePath)
	if sqlitePath == "" {
		sqlitePath = filepath.Join(cfg.DataDir, "corvo.db")
	}
	sqliteDB, err := openMaterializedView(sqlitePath)
	if err != nil {
		pdb.Close()
		return nil, fmt.Errorf("open sqlite: %w", err)
	}

	// Create FSM
	fsm := NewFSM(pdb, sqliteDB)
	fsm.SetPebbleNoSync(cfg.PebbleNoSync)
	fsm.SetSQLiteMirrorEnabled(cfg.SQLiteMirror)
	fsm.SetSQLiteMirrorAsync(cfg.SQLiteMirrorAsync)
	fsm.SetLifecycleEventsEnabled(cfg.LifecycleEvents)
	fsm.SetApplyMultiMode(cfg.ApplyMultiMode)

	// Raft config
	raftConfig := raft.DefaultConfig()
	raftConfig.LocalID = raft.ServerID(cfg.NodeID)
	raftConfig.SnapshotThreshold = cfg.SnapshotThreshold
	raftConfig.SnapshotInterval = cfg.SnapshotInterval

	// Transport
	transport, err := newTCPTransport(cfg.RaftBind, cfg.RaftAdvertise)
	if err != nil {
		pdb.Close()
		sqliteDB.Close()
		return nil, fmt.Errorf("create transport: %w", err)
	}

	// Log store + stable store
	logStore, err := openRaftStore(raftDir, cfg)
	if err != nil {
		pdb.Close()
		sqliteDB.Close()
		transport.Close()
		return nil, err
	}

	// Snapshot store
	snapshotStore, err := raft.NewFileSnapshotStore(raftDir, 2, os.Stderr)
	if err != nil {
		pdb.Close()
		sqliteDB.Close()
		transport.Close()
		logStore.Close()
		return nil, fmt.Errorf("create snapshot store: %w", err)
	}
	if err := prepareFSMForRecovery(pdb, snapshotStore); err != nil {
		pdb.Close()
		sqliteDB.Close()
		transport.Close()
		logStore.Close()
		return nil, fmt.Errorf("prepare fsm recovery: %w", err)
	}

	// Create Raft instance
	r, err := raft.NewRaft(raftConfig, fsm, logStore, logStore, snapshotStore, transport)
	if err != nil {
		pdb.Close()
		sqliteDB.Close()
		transport.Close()
		logStore.Close()
		return nil, fmt.Errorf("create raft: %w", err)
	}

	// Bootstrap if requested
	if cfg.Bootstrap {
		configuration := raft.Configuration{
			Servers: []raft.Server{
				{
					ID:      raft.ServerID(cfg.NodeID),
					Address: transport.LocalAddr(),
				},
			},
		}
		f := r.BootstrapCluster(configuration)
		if err := f.Error(); err != nil && err != raft.ErrCantBootstrap {
			slog.Warn("bootstrap cluster", "error", err)
		}
	}

	cluster := &Cluster{
		raft:      r,
		fsm:       fsm,
		transport: transport,
		logStore:  logStore,
		snapshot:  snapshotStore,
		config:    cfg,
		applyCh:   make(chan *applyRequest, cfg.ApplyMaxPending),
		applyExec: make(chan []*applyRequest, 4),
		fetchSem:  make(map[string]chan struct{}),
		queueHist: newDurationHistogram(),
		applyHist: newDurationHistogram(),
		stopCh:    make(chan struct{}),
		doneCh:    make(chan struct{}),
		workerCh:  make(chan struct{}),
	}
	go cluster.applyExecLoop()
	go cluster.applyLoop()

	slog.Info("raft cluster started",
		"node_id", cfg.NodeID,
		"raft_bind", cfg.RaftBind,
		"raft_store", cfg.RaftStore,
		"raft_no_sync", cfg.RaftNoSync,
		"pebble_no_sync", cfg.PebbleNoSync,
		"sqlite_mirror", cfg.SQLiteMirror,
		"sqlite_mirror_async", cfg.SQLiteMirrorAsync,
		"lifecycle_events", cfg.LifecycleEvents,
		"snapshot_threshold", cfg.SnapshotThreshold,
		"snapshot_interval", cfg.SnapshotInterval,
		"apply_batch_max", cfg.ApplyBatchMax,
		"apply_batch_min_wait", cfg.ApplyBatchMinWait,
		"apply_batch_extend_at", cfg.ApplyBatchExtendAt,
		"apply_batch_window", cfg.ApplyBatchWindow,
		"apply_max_pending", cfg.ApplyMaxPending,
		"apply_max_fetch_queue_inflight", cfg.ApplyMaxFetchQueueInFly,
		"apply_sub_batch_max", cfg.ApplySubBatchMax,
		"bootstrap", cfg.Bootstrap,
	)

	return cluster, nil
}

func prepareFSMForRecovery(pdb *pebble.DB, snapshotStore raft.SnapshotStore) error {
	snapshots, err := snapshotStore.List()
	if err != nil {
		return fmt.Errorf("list snapshots: %w", err)
	}
	if len(snapshots) > 0 {
		return nil
	}
	// No snapshot exists yet. Clear local Pebble state so any Raft log replay
	// starts from a deterministic empty FSM baseline after crash/power loss.
	if err := clearPebbleAll(pdb); err != nil {
		return err
	}
	slog.Info("recovery prep: no snapshot found; cleared local pebble state before raft replay")
	return nil
}

func clearPebbleAll(pdb *pebble.DB) error {
	// Use a single range tombstone to clear all keys in O(1) memory,
	// regardless of DB size. All Corvo keys use ASCII prefixes (0x61–0x77),
	// so [0x00, 0xff) covers the entire practical keyspace.
	batch := pdb.NewBatch()
	defer batch.Close()
	if err := batch.DeleteRange([]byte{0x00}, []byte{0xff}, pebble.Sync); err != nil {
		return fmt.Errorf("delete range pebble: %w", err)
	}
	return batch.Commit(pebble.Sync)
}

// Apply submits an operation to the Raft cluster and returns the result.
func (c *Cluster) Apply(opType store.OpType, data any) *store.OpResult {
	releaseFetch, err := c.acquireFetchQueuePermit(opType, data)
	if err != nil {
		return &store.OpResult{Err: err}
	}
	if releaseFetch != nil {
		defer releaseFetch()
	}

	// Pre-resolve fetch candidates outside the serial FSM goroutine.
	var reservedIDs []string
	if opType == store.OpFetchBatch {
		if op, ok := data.(store.FetchBatchOp); ok && len(op.Queues) > 0 && op.Count > 0 {
			data, reservedIDs = c.preResolveFetch(op)
		}
	}
	if len(reservedIDs) > 0 {
		defer func() {
			for _, id := range reservedIDs {
				c.fetchReserved.Delete(id)
			}
		}()
	}

	req := &applyRequest{
		opType: opType,
		data:   data,
		enqAt:  time.Now(),
		respCh: make(chan *store.OpResult, 1),
	}
	select {
	case c.applyCh <- req:
	default:
		c.overloadTotal.Add(1)
		return c.overloadedResult("raft apply overloaded: pending queue is full")
	case <-c.stopCh:
		return &store.OpResult{Err: fmt.Errorf("raft cluster stopping")}
	}

	select {
	case res := <-req.respCh:
		return res
	case <-c.stopCh:
		return &store.OpResult{Err: fmt.Errorf("raft cluster stopping")}
	}
}

// preResolveFetch scans Pebble for candidate pending/append jobs outside the
// serial FSM goroutine. This moves the expensive iterator work to the calling
// stream goroutine (which runs on any CPU), leaving only cheap O(1) point
// lookups for the FSM. Returns the modified op and the list of reserved IDs
// (caller must release via fetchReserved.Delete).
func (c *Cluster) preResolveFetch(op store.FetchBatchOp) (store.FetchBatchOp, []string) {
	pdb := c.fsm.PebbleDB()
	candidateIDs := make([]string, 0, op.Count)
	candidateQueues := make([]string, 0, op.Count)
	var reservedIDs []string

	for _, queue := range op.Queues {
		if len(candidateIDs) >= op.Count {
			break
		}

		// Scan priority-indexed pending keys first.
		prefix := kv.PendingPrefix(queue)
		iter, err := pdb.NewIter(&pebble.IterOptions{
			LowerBound: prefix,
			UpperBound: prefixUpperBound(prefix),
		})
		if err == nil {
			idOffset := len(prefix) + 1 + 8 // sep already in prefix, +priority(1)+createdNs(8)
			for valid := iter.First(); valid && len(candidateIDs) < op.Count; valid = iter.Next() {
				key := iter.Key()
				if len(key) <= idOffset {
					continue
				}
				id := string(key[idOffset:])
				if _, loaded := c.fetchReserved.LoadOrStore(id, struct{}{}); !loaded {
					reservedIDs = append(reservedIDs, id)
					candidateIDs = append(candidateIDs, id)
					candidateQueues = append(candidateQueues, queue)
				}
			}
			iter.Close()
		}

		if len(candidateIDs) >= op.Count {
			break
		}

		// Scan append-log keys from cursor position, with fallback before
		// cursor for entries with out-of-order timestamps.
		appendPrefix := kv.QueueAppendPrefix(queue)
		var cursor []byte
		if c, closer, err := pdb.Get(kv.QueueCursorKey(queue)); err == nil {
			cursor = append([]byte(nil), c...)
			closer.Close()
		}
		iter, err = pdb.NewIter(&pebble.IterOptions{
			LowerBound: appendPrefix,
			UpperBound: prefixUpperBound(appendPrefix),
		})
		if err == nil {
			idOffset := len(appendPrefix) + 8 // createdNs(8)
			var valid bool
			if len(cursor) > 0 {
				valid = iter.SeekGE(cursor)
				if valid && bytes.Equal(iter.Key(), cursor) {
					valid = iter.Next()
				}
			} else {
				valid = iter.First()
			}
			for ; valid && len(candidateIDs) < op.Count; valid = iter.Next() {
				key := iter.Key()
				if len(key) <= idOffset {
					continue
				}
				id := string(key[idOffset:])
				if _, loaded := c.fetchReserved.LoadOrStore(id, struct{}{}); !loaded {
					reservedIDs = append(reservedIDs, id)
					candidateIDs = append(candidateIDs, id)
					candidateQueues = append(candidateQueues, queue)
				}
			}
			// Fallback: scan before cursor for stranded entries.
			if len(candidateIDs) < op.Count && len(cursor) > 0 {
				for valid := iter.SeekGE(appendPrefix); valid && len(candidateIDs) < op.Count; valid = iter.Next() {
					if bytes.Compare(iter.Key(), cursor) >= 0 {
						break
					}
					key := iter.Key()
					if len(key) <= idOffset {
						continue
					}
					id := string(key[idOffset:])
					if _, loaded := c.fetchReserved.LoadOrStore(id, struct{}{}); !loaded {
						reservedIDs = append(reservedIDs, id)
						candidateIDs = append(candidateIDs, id)
						candidateQueues = append(candidateQueues, queue)
					}
				}
			}
			iter.Close()
		}
	}

	op.CandidateJobIDs = candidateIDs
	op.CandidateQueues = candidateQueues
	return op, reservedIDs
}

func fetchQueueForOp(opType store.OpType, data any) string {
	switch opType {
	case store.OpFetch:
		if op, ok := data.(store.FetchOp); ok && len(op.Queues) > 0 {
			return op.Queues[0]
		}
	case store.OpFetchBatch:
		if op, ok := data.(store.FetchBatchOp); ok && len(op.Queues) > 0 {
			return op.Queues[0]
		}
	}
	return ""
}

func (c *Cluster) acquireFetchQueuePermit(opType store.OpType, data any) (func(), error) {
	queue := fetchQueueForOp(opType, data)
	if queue == "" || c.config.ApplyMaxFetchQueueInFly <= 0 {
		return nil, nil
	}
	sem := c.fetchSemaphore(queue)
	select {
	case sem <- struct{}{}:
		return func() {
			<-sem
		}, nil
	default:
		c.fetchOverloadTotal.Add(1)
		return nil, store.NewOverloadedErrorRetry(
			fmt.Sprintf("raft apply overloaded for fetch queue %q", queue),
			2+retryJitterMs(6),
		)
	case <-c.stopCh:
		return nil, fmt.Errorf("raft cluster stopping")
	}
}

func (c *Cluster) fetchSemaphore(queue string) chan struct{} {
	c.fetchMu.Lock()
	defer c.fetchMu.Unlock()
	sem, ok := c.fetchSem[queue]
	if ok {
		return sem
	}
	sem = make(chan struct{}, c.config.ApplyMaxFetchQueueInFly)
	c.fetchSem[queue] = sem
	return sem
}

func (c *Cluster) overloadedResult(msg string) *store.OpResult {
	return &store.OpResult{Err: store.NewOverloadedErrorRetry(msg, c.overloadRetryAfterMs())}
}

// cleanupDeletedQueue removes fetchSem and pendingCache entries for a deleted
// queue. Called after a successful OpDeleteQueue apply so the map does not
// grow without bound as queues are created and deleted over time.
func (c *Cluster) cleanupDeletedQueue(queue string) {
	c.fetchMu.Lock()
	delete(c.fetchSem, queue)
	c.fetchMu.Unlock()
	c.pendingCache.Delete(queue)
}

func (c *Cluster) overloadRetryAfterMs() int {
	backlog := len(c.applyCh)
	pendingLimit := c.config.ApplyMaxPending
	if pendingLimit <= 0 {
		pendingLimit = 1
	}
	score := 1 + (backlog*8)/pendingLimit
	switch {
	case score >= 12:
		return 10 + retryJitterMs(3)
	case score >= 8:
		return 5 + retryJitterMs(3)
	case score >= 5:
		return 2 + retryJitterMs(2)
	default:
		return 1 + retryJitterMs(2)
	}
}

func retryJitterMs(span int) int {
	if span <= 0 {
		return 0
	}
	n := time.Now().UnixNano()
	if n < 0 {
		n = -n
	}
	return int(n % int64(span))
}

func (c *Cluster) applyLoop() {
	defer close(c.doneCh)
	defer close(c.applyExec)

	enqueueExec := func(b []*applyRequest) {
		if len(b) == 0 {
			return
		}
		out := make([]*applyRequest, len(b))
		copy(out, b)
		select {
		case c.applyExec <- out:
		case <-c.stopCh:
			for _, req := range out {
				req.respCh <- &store.OpResult{Err: fmt.Errorf("raft cluster stopping")}
			}
		}
	}

	maxBatch := c.config.ApplyBatchMax
	maxWindow := c.config.ApplyBatchWindow
	minWindow := c.config.ApplyBatchMinWait
	extendAt := c.config.ApplyBatchExtendAt
	batch := make([]*applyRequest, 0, maxBatch)
	timer := time.NewTimer(maxWindow)
	if !timer.Stop() {
		<-timer.C
	}
	defer timer.Stop()
	timerActive := false
	var firstAt time.Time
	var deadline time.Time
	extended := false

	resetTimer := func(wait time.Duration) {
		if wait <= 0 {
			wait = time.Microsecond
		}
		if timerActive {
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
		}
		timer.Reset(wait)
		timerActive = true
	}

	flush := func() {
		if len(batch) == 0 {
			return
		}
		enqueueExec(batch)
		batch = batch[:0]
		timerActive = false
		extended = false
		firstAt = time.Time{}
		deadline = time.Time{}
	}

	chooseWait := func(backlog int) time.Duration {
		wait := minWindow
		switch {
		case backlog >= maxBatch:
			wait = 10 * time.Microsecond
		case backlog >= extendAt:
			wait = 20 * time.Microsecond
		case backlog >= extendAt/2:
			wait = minWindow / 4
		case backlog > 0:
			wait = minWindow / 2
		}
		// When the exec pipeline is idle, flush sooner — accumulating
		// adds latency without improving throughput.
		if len(c.applyExec) < cap(c.applyExec) && wait > 20*time.Microsecond {
			wait = 20 * time.Microsecond
		}
		if wait < 20*time.Microsecond {
			wait = 20 * time.Microsecond
		}
		return wait
	}

	for {
		if len(batch) == 0 {
			select {
			case req := <-c.applyCh:
				batch = append(batch, req)
				firstAt = time.Now()
				wait := chooseWait(len(c.applyCh))
				deadline = firstAt.Add(wait)
				extended = false
				resetTimer(time.Until(deadline))
			case <-c.stopCh:
				// Drain what is queued and hand off for execution.
				for {
					select {
					case req := <-c.applyCh:
						batch = append(batch, req)
						if len(batch) >= maxBatch {
							flush()
						}
					default:
						flush()
						return
					}
				}
			case <-c.workerCh:
				return
			}
			continue
		}

		select {
		case req := <-c.applyCh:
			batch = append(batch, req)
			if len(batch) >= extendAt/2 {
				age := time.Since(firstAt)
				if age >= minWindow/2 {
					flush()
					continue
				}
			}
			if !extended && len(batch) >= extendAt {
				maxDeadline := firstAt.Add(maxWindow)
				if maxDeadline.After(deadline) {
					deadline = maxDeadline
					resetTimer(time.Until(deadline))
				}
				extended = true
			}
			if len(batch) >= maxBatch {
				flush()
			}
		case <-timer.C:
			timerActive = false
			flush()
		case <-c.stopCh:
			// Drain queued requests before exit.
			for {
				select {
				case req := <-c.applyCh:
					batch = append(batch, req)
					if len(batch) >= maxBatch {
						flush()
					}
				default:
					flush()
					return
				}
			}
		}
	}
}

func (c *Cluster) applyExecLoop() {
	defer close(c.workerCh)
	for batch := range c.applyExec {
		now := time.Now()
		for _, req := range batch {
			if !req.enqAt.IsZero() {
				c.queueHist.observe(now.Sub(req.enqAt))
			}
		}
		c.flushApplyBatch(batch)
	}
}

func (c *Cluster) flushApplyBatch(batch []*applyRequest) {
	if len(batch) > c.config.ApplySubBatchMax {
		for i := 0; i < len(batch); i += c.config.ApplySubBatchMax {
			j := i + c.config.ApplySubBatchMax
			if j > len(batch) {
				j = len(batch)
			}
			c.flushApplyBatch(batch[i:j])
		}
		return
	}

	if len(batch) == 1 {
		req := batch[0]
		start := time.Now()
		req.respCh <- c.applyImmediate(req.opType, req.data)
		c.applyHist.observe(time.Since(start))
		c.appliedTotal.Add(1)
		if req.opType == store.OpDeleteQueue {
			if op, ok := req.data.(store.QueueOp); ok {
				c.cleanupDeletedQueue(op.Queue)
			}
		}
		return
	}

	inputs := make([]store.OpInput, 0, len(batch))
	validReqs := make([]*applyRequest, 0, len(batch))
	for _, req := range batch {
		inputs = append(inputs, store.OpInput{
			Type: req.opType,
			Data: req.data,
		})
		validReqs = append(validReqs, req)
	}
	if len(inputs) == 0 {
		return
	}

	multiBytes, err := store.MarshalMulti(inputs)
	if err != nil {
		for _, req := range batch {
			req.respCh <- &store.OpResult{Err: fmt.Errorf("marshal multi op: %w", err)}
		}
		return
	}

	start := time.Now()
	res := c.applyBytes(multiBytes)
	c.applyHist.observe(time.Since(start))
	c.appliedTotal.Add(uint64(len(validReqs)))
	if res.Err != nil {
		for _, req := range validReqs {
			req.respCh <- &store.OpResult{Err: res.Err}
		}
		return
	}

	subResults, ok := res.Data.([]*store.OpResult)
	if !ok || len(subResults) != len(validReqs) {
		err := fmt.Errorf("unexpected multi response type/count: %T (%d)", res.Data, len(subResults))
		for _, req := range validReqs {
			req.respCh <- &store.OpResult{Err: err}
		}
		return
	}

	for i, req := range validReqs {
		req.respCh <- subResults[i]
		if req.opType == store.OpDeleteQueue {
			if op, ok := req.data.(store.QueueOp); ok {
				c.cleanupDeletedQueue(op.Queue)
			}
		}
	}
}

func (c *Cluster) applyImmediate(opType store.OpType, data any) *store.OpResult {
	opBytes, err := store.MarshalOp(opType, data)
	if err != nil {
		return &store.OpResult{Err: fmt.Errorf("marshal op: %w", err)}
	}
	return c.applyBytes(opBytes)
}

func (c *Cluster) applyBytes(opBytes []byte) *store.OpResult {
	future := c.raft.Apply(opBytes, c.config.ApplyTimeout)
	if err := future.Error(); err != nil {
		return &store.OpResult{Err: fmt.Errorf("raft apply: %w", err)}
	}
	result, ok := future.Response().(*store.OpResult)
	if !ok {
		return &store.OpResult{Err: fmt.Errorf("unexpected response type: %T", future.Response())}
	}
	return result
}

// IsLeader returns true if this node is the Raft leader.
func (c *Cluster) IsLeader() bool {
	return c.raft.State() == raft.Leader
}

// IsUnderLoad returns true when the apply pipeline has pending work. Used by
// the scheduler to skip expensive maintenance ops during high throughput.
// Note: any non-zero depth triggers "under load" (threshold=1). Under sustained
// traffic this may indefinitely defer Promote/Reclaim/ExpireJobs. If that
// becomes an issue, consider a higher threshold or a max-deferral duration.
func (c *Cluster) IsUnderLoad() bool {
	return len(c.applyCh) > 0
}

// LeaderAddr returns the address of the current Raft leader.
func (c *Cluster) LeaderAddr() string {
	addr, _ := c.raft.LeaderWithID()
	return string(addr)
}

// LeaderID returns the ID of the current leader.
func (c *Cluster) LeaderID() string {
	_, id := c.raft.LeaderWithID()
	return string(id)
}

// SQLiteReadDB returns the local SQLite database for read queries.
func (c *Cluster) SQLiteReadDB() *sql.DB {
	return c.fsm.SQLiteDB()
}

// PebbleDB returns the underlying Pebble database.
func (c *Cluster) PebbleDB() *pebble.DB {
	return c.fsm.PebbleDB()
}

// pendingCacheEntry caches the result of a Pebble prefix scan.
type pendingCacheEntry struct {
	hasPending bool
	deadline   int64 // UnixNano
}

// HasPendingJobs checks if any of the given queues have pending or append-log
// jobs. Uses a per-queue cache to avoid expensive Pebble tombstone walks.
// False positives are cheap (one wasted Raft apply that returns empty).
// False negatives add up to 500ms latency to job pickup.
func (c *Cluster) HasPendingJobs(queues []string) bool {
	now := time.Now().UnixNano()
	allCached := true
	for _, q := range queues {
		if entry, ok := c.pendingCache.Load(q); ok {
			e := entry.(pendingCacheEntry)
			if now < e.deadline {
				if e.hasPending {
					return true
				}
				continue // cached as empty, skip
			}
		}
		// Cache miss or expired — assume jobs exist rather than doing
		// an expensive Pebble scan (tombstone walks are costly).
		// The Raft FSM will return empty results if wrong.
		allCached = false
	}
	if allCached {
		return false // all queues cached as empty
	}
	return true // at least one queue has expired/missing cache → assume pending
}

// InvalidatePendingCache marks a queue as having pending jobs, called after
// the FSM enqueues a job so workers discover it without waiting for cache expiry.
func (c *Cluster) InvalidatePendingCache(queue string) {
	c.pendingCache.Store(queue, pendingCacheEntry{
		hasPending: true,
		deadline:   time.Now().UnixNano() + 500_000_000, // 500ms
	})
}

// MarkQueueEmpty caches that a queue has no pending jobs, called when a fetch
// returns zero results so we avoid repeated Raft applies for empty queues.
func (c *Cluster) MarkQueueEmpty(queue string) {
	c.pendingCache.Store(queue, pendingCacheEntry{
		hasPending: false,
		deadline:   time.Now().UnixNano() + 50_000_000, // 50ms — short to avoid missing new jobs
	})
}

// prefixHasKey returns true if there is at least one key with the given prefix.
func prefixHasKey(pdb *pebble.DB, prefix []byte) bool {
	iter, err := pdb.NewIter(&pebble.IterOptions{
		LowerBound: prefix,
		UpperBound: prefixUpperBound(prefix),
	})
	if err != nil {
		return false
	}
	defer iter.Close()
	return iter.First()
}

// Stats returns Raft cluster statistics.
func (c *Cluster) Stats() map[string]string {
	return c.raft.Stats()
}

// State returns the Raft state (leader, follower, candidate).
func (c *Cluster) State() string {
	return c.raft.State().String()
}

// AddVoter adds a new voting member to the cluster.
func (c *Cluster) AddVoter(nodeID, addr string) error {
	f := c.raft.AddVoter(raft.ServerID(nodeID), raft.ServerAddress(addr), 0, c.config.ApplyTimeout)
	return f.Error()
}

// RemoveServer removes a node from the cluster.
func (c *Cluster) RemoveServer(nodeID string) error {
	f := c.raft.RemoveServer(raft.ServerID(nodeID), 0, c.config.ApplyTimeout)
	return f.Error()
}

// Shutdown gracefully shuts down the Raft node and closes all stores.
func (c *Cluster) Shutdown() error {
	slog.Info("shutting down raft cluster")
	close(c.stopCh)
	<-c.doneCh

	if err := c.raft.Shutdown().Error(); err != nil {
		slog.Error("raft shutdown error", "error", err)
	}
	c.fsm.Close()

	if err := c.transport.Close(); err != nil {
		slog.Error("transport close error", "error", err)
	}

	if err := c.logStore.Close(); err != nil {
		slog.Error("log store close error", "error", err)
	}

	if err := c.fsm.pebble.Close(); err != nil {
		slog.Error("pebble close error", "error", err)
	}

	if err := c.fsm.sqlite.Close(); err != nil {
		slog.Error("sqlite close error", "error", err)
	}

	slog.Info("raft cluster shut down")
	return nil
}

// openMaterializedView opens a SQLite database for the materialized view.
// It creates tables if they don't exist and configures WAL mode.
func openMaterializedView(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(64)
	db.SetMaxIdleConns(32)
	db.SetConnMaxLifetime(5 * time.Minute)
	for _, pragma := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA synchronous=OFF",
		"PRAGMA foreign_keys=ON",
		"PRAGMA busy_timeout=5000",
	} {
		if _, err := db.Exec(pragma); err != nil {
			db.Close()
			return nil, fmt.Errorf("apply sqlite pragma %q: %w", pragma, err)
		}
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, err
	}

	// Create tables for the materialized view
	// These mirror the main schema but without events tables (no longer needed).
	_, err = db.Exec(materializedViewSchema)
	if err != nil {
		db.Close()
		return nil, fmt.Errorf("create materialized view schema: %w", err)
	}
	if err := ensureMaterializedViewSchema(db); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrate materialized view schema: %w", err)
	}
	if err := ensureTextSearchSchema(db); err != nil {
		db.Close()
		return nil, fmt.Errorf("ensure text search schema: %w", err)
	}

	return db, nil
}

func ensureMaterializedViewSchema(db *sql.DB) error {
	// Existing materialized-view DBs may predate newer AI columns.
	// Add missing columns before creating indexes that depend on them.
	type columnSpec struct {
		table string
		name  string
		sql   string
	}
	columns := []columnSpec{
		{table: "jobs", name: "result_schema", sql: "ALTER TABLE jobs ADD COLUMN result_schema TEXT"},
		{table: "jobs", name: "parent_id", sql: "ALTER TABLE jobs ADD COLUMN parent_id TEXT REFERENCES jobs(id)"},
		{table: "jobs", name: "chain_id", sql: "ALTER TABLE jobs ADD COLUMN chain_id TEXT"},
		{table: "jobs", name: "chain_step", sql: "ALTER TABLE jobs ADD COLUMN chain_step INTEGER"},
		{table: "jobs", name: "chain_config", sql: "ALTER TABLE jobs ADD COLUMN chain_config TEXT"},
		{table: "jobs", name: "provider_error", sql: "ALTER TABLE jobs ADD COLUMN provider_error INTEGER NOT NULL DEFAULT 0"},
		{table: "jobs", name: "routing", sql: "ALTER TABLE jobs ADD COLUMN routing TEXT"},
		{table: "jobs", name: "routing_target", sql: "ALTER TABLE jobs ADD COLUMN routing_target TEXT"},
		{table: "jobs", name: "routing_index", sql: "ALTER TABLE jobs ADD COLUMN routing_index INTEGER NOT NULL DEFAULT 0"},
		{table: "job_iterations", name: "trace", sql: "ALTER TABLE job_iterations ADD COLUMN trace TEXT"},
		{table: "queues", name: "provider", sql: "ALTER TABLE queues ADD COLUMN provider TEXT REFERENCES providers(name)"},
		{table: "api_keys", name: "expires_at", sql: "ALTER TABLE api_keys ADD COLUMN expires_at TEXT"},
		{table: "sso_settings", name: "oidc_group_claim", sql: "ALTER TABLE sso_settings ADD COLUMN oidc_group_claim TEXT NOT NULL DEFAULT 'groups'"},
		{table: "sso_settings", name: "group_role_mappings", sql: "ALTER TABLE sso_settings ADD COLUMN group_role_mappings TEXT NOT NULL DEFAULT '{}'"},
		{table: "namespaces", name: "rate_limit_read_rps", sql: "ALTER TABLE namespaces ADD COLUMN rate_limit_read_rps REAL"},
		{table: "namespaces", name: "rate_limit_read_burst", sql: "ALTER TABLE namespaces ADD COLUMN rate_limit_read_burst REAL"},
		{table: "namespaces", name: "rate_limit_write_rps", sql: "ALTER TABLE namespaces ADD COLUMN rate_limit_write_rps REAL"},
		{table: "namespaces", name: "rate_limit_write_burst", sql: "ALTER TABLE namespaces ADD COLUMN rate_limit_write_burst REAL"},
	}
	for _, c := range columns {
		ok, err := sqliteHasColumn(db, c.table, c.name)
		if err != nil {
			return err
		}
		if ok {
			continue
		}
		if _, err := db.Exec(c.sql); err != nil {
			return err
		}
	}
	_, err := db.Exec(`
CREATE INDEX IF NOT EXISTS idx_jobs_parent ON jobs(parent_id) WHERE parent_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jobs_chain ON jobs(chain_id) WHERE chain_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jobs_provider_error ON jobs(provider_error) WHERE provider_error = 1;
CREATE INDEX IF NOT EXISTS idx_jobs_routing_target ON jobs(routing_target) WHERE routing_target IS NOT NULL;
CREATE TABLE IF NOT EXISTS approval_policies (
    id               TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    mode             TEXT NOT NULL DEFAULT 'any',
    enabled          INTEGER NOT NULL DEFAULT 1,
    queue            TEXT,
    tag_key          TEXT,
    tag_value        TEXT,

    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_approval_policies_enabled ON approval_policies(enabled);
CREATE TABLE IF NOT EXISTS auth_roles (
    name        TEXT PRIMARY KEY,
    permissions TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    updated_at  TEXT
);
CREATE TABLE IF NOT EXISTS auth_key_roles (
    key_hash   TEXT NOT NULL,
    role_name  TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    PRIMARY KEY(key_hash, role_name)
);
CREATE INDEX IF NOT EXISTS idx_auth_key_roles_role ON auth_key_roles(role_name);
	`)
	return err
}

func sqliteHasColumn(db *sql.DB, table, column string) (bool, error) {
	rows, err := db.Query("PRAGMA table_info(" + table + ")")
	if err != nil {
		return false, err
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name string
		var ctype string
		var notNull int
		var dflt sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &ctype, &notNull, &dflt, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

func ensureTextSearchSchema(db *sql.DB) error {
	if _, err := db.Exec(`
CREATE VIRTUAL TABLE IF NOT EXISTS jobs_fts USING fts5(
    job_id UNINDEXED,
    queue,
    state,
    payload,
    tags,
    content='',
    tokenize = 'unicode61'
);
CREATE TRIGGER IF NOT EXISTS jobs_fts_insert AFTER INSERT ON jobs BEGIN
    INSERT INTO jobs_fts(job_id, queue, state, payload, tags)
    VALUES (new.id, new.queue, new.state, new.payload, COALESCE(new.tags, ''));
END;
CREATE TRIGGER IF NOT EXISTS jobs_fts_update AFTER UPDATE ON jobs BEGIN
    DELETE FROM jobs_fts WHERE job_id = old.id;
    INSERT INTO jobs_fts(job_id, queue, state, payload, tags)
    VALUES (new.id, new.queue, new.state, new.payload, COALESCE(new.tags, ''));
END;
CREATE TRIGGER IF NOT EXISTS jobs_fts_delete AFTER DELETE ON jobs BEGIN
    DELETE FROM jobs_fts WHERE job_id = old.id;
END;
`); err == nil {
		return nil
	} else if !strings.Contains(strings.ToLower(err.Error()), "fts5") {
		return err
	}

	_, err := db.Exec(`
DROP TABLE IF EXISTS jobs_search;
CREATE TABLE jobs_search (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id   TEXT NOT NULL,
    queue    TEXT NOT NULL,
    state    TEXT NOT NULL,
    payload  TEXT NOT NULL,
    tags     TEXT
);
CREATE INDEX IF NOT EXISTS idx_jobs_search_queue ON jobs_search(queue);
CREATE INDEX IF NOT EXISTS idx_jobs_search_job_id ON jobs_search(job_id);
DROP TRIGGER IF EXISTS jobs_search_insert;
DROP TRIGGER IF EXISTS jobs_search_update;
DROP TRIGGER IF EXISTS jobs_search_delete;
CREATE TRIGGER IF NOT EXISTS jobs_search_insert AFTER INSERT ON jobs BEGIN
    DELETE FROM jobs_search WHERE job_id = new.id;
    INSERT INTO jobs_search(job_id, queue, state, payload, tags)
    VALUES (new.id, new.queue, new.state, new.payload, COALESCE(new.tags, ''));
END;
CREATE TRIGGER IF NOT EXISTS jobs_search_update AFTER UPDATE ON jobs BEGIN
    DELETE FROM jobs_search WHERE job_id = new.id;
    INSERT INTO jobs_search(job_id, queue, state, payload, tags)
    VALUES (new.id, new.queue, new.state, new.payload, COALESCE(new.tags, ''));
END;
CREATE TRIGGER IF NOT EXISTS jobs_search_delete AFTER DELETE ON jobs BEGIN
    DELETE FROM jobs_search WHERE job_id = old.id;
END;
INSERT INTO jobs_search(job_id, queue, state, payload, tags)
SELECT id, queue, state, payload, COALESCE(tags, '') FROM jobs;
`)
	return err
}

const materializedViewSchema = `
CREATE TABLE IF NOT EXISTS jobs (
    id              TEXT PRIMARY KEY,
    queue           TEXT NOT NULL,
    state           TEXT NOT NULL DEFAULT 'pending',
    payload         TEXT NOT NULL,
    priority        INTEGER NOT NULL DEFAULT 2,
    attempt         INTEGER NOT NULL DEFAULT 0,
    max_retries     INTEGER NOT NULL DEFAULT 3,
    retry_backoff   TEXT NOT NULL DEFAULT 'exponential',
    retry_base_delay_ms INTEGER NOT NULL DEFAULT 5000,
    retry_max_delay_ms  INTEGER NOT NULL DEFAULT 600000,
    unique_key      TEXT,
    batch_id        TEXT,
    worker_id       TEXT,
    hostname        TEXT,
    tags            TEXT,
    progress        TEXT,
    checkpoint      TEXT,
    result          TEXT,
    result_schema   TEXT,
    parent_id       TEXT REFERENCES jobs(id),
    chain_id        TEXT,
    chain_step      INTEGER,
    chain_config    TEXT,
    provider_error  INTEGER NOT NULL DEFAULT 0,
    routing         TEXT,
    routing_target  TEXT,
    routing_index   INTEGER NOT NULL DEFAULT 0,
    agent_max_iterations INTEGER,
    agent_max_cost_usd REAL,
    agent_iteration_timeout TEXT,
    agent_iteration INTEGER NOT NULL DEFAULT 0,
    agent_total_cost_usd REAL NOT NULL DEFAULT 0,
    hold_reason     TEXT,
    lease_expires_at TEXT,
    scheduled_at    TEXT,
    expire_at       TEXT,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    started_at      TEXT,
    completed_at    TEXT,
    failed_at       TEXT
);
CREATE INDEX IF NOT EXISTS idx_jobs_queue_state_priority ON jobs(queue, state, priority, created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state);
CREATE INDEX IF NOT EXISTS idx_jobs_scheduled ON jobs(state, scheduled_at) WHERE state IN ('scheduled', 'retrying');
CREATE INDEX IF NOT EXISTS idx_jobs_lease ON jobs(state, lease_expires_at) WHERE state = 'active';
CREATE INDEX IF NOT EXISTS idx_jobs_unique ON jobs(queue, unique_key) WHERE unique_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jobs_batch ON jobs(batch_id) WHERE batch_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jobs_expire ON jobs(expire_at) WHERE expire_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_jobs_created ON jobs(created_at);

CREATE TABLE IF NOT EXISTS job_errors (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    attempt    INTEGER NOT NULL,
    error      TEXT NOT NULL,
    backtrace  TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_job_errors_job ON job_errors(job_id);

CREATE TABLE IF NOT EXISTS unique_locks (
    queue      TEXT NOT NULL,
    unique_key TEXT NOT NULL,
    job_id     TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    PRIMARY KEY (queue, unique_key)
);

CREATE TABLE IF NOT EXISTS batches (
    id               TEXT PRIMARY KEY,
    total            INTEGER NOT NULL,
    pending          INTEGER NOT NULL,
    succeeded        INTEGER NOT NULL DEFAULT 0,
    failed           INTEGER NOT NULL DEFAULT 0,
    callback_queue   TEXT,
    callback_payload TEXT,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

CREATE TABLE IF NOT EXISTS queues (
    name            TEXT PRIMARY KEY,
    paused          INTEGER NOT NULL DEFAULT 0,
    max_concurrency INTEGER,
    rate_limit      INTEGER,
    rate_window_ms  INTEGER,
    provider        TEXT REFERENCES providers(name),
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

CREATE TABLE IF NOT EXISTS rate_limit_window (
    queue      TEXT NOT NULL,
    fetched_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_rate_limit ON rate_limit_window(queue, fetched_at);

CREATE TABLE IF NOT EXISTS schedules (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL UNIQUE,
    queue      TEXT NOT NULL,
    cron       TEXT NOT NULL,
    timezone   TEXT NOT NULL DEFAULT 'UTC',
    payload    TEXT NOT NULL,
    unique_key TEXT,
    max_retries INTEGER NOT NULL DEFAULT 3,
    last_run   TEXT,
    next_run   TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);

CREATE TABLE IF NOT EXISTS workers (
    id              TEXT PRIMARY KEY,
    hostname        TEXT,
    queues          TEXT,
    last_heartbeat  TEXT NOT NULL,
    started_at      TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS job_usage (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id                TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    queue                 TEXT NOT NULL,
    attempt               INTEGER NOT NULL,
    phase                 TEXT NOT NULL,
    input_tokens          INTEGER NOT NULL DEFAULT 0,
    output_tokens         INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
    model                 TEXT,
    provider              TEXT,
    cost_usd              REAL NOT NULL DEFAULT 0,
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_job_usage_job ON job_usage(job_id);
CREATE INDEX IF NOT EXISTS idx_job_usage_provider ON job_usage(provider, created_at);
CREATE INDEX IF NOT EXISTS idx_job_usage_model ON job_usage(model, created_at);
CREATE INDEX IF NOT EXISTS idx_job_usage_queue ON job_usage(queue, created_at);

CREATE TABLE IF NOT EXISTS budgets (
    id          TEXT PRIMARY KEY,
    scope       TEXT NOT NULL,
    target      TEXT NOT NULL,
    daily_usd   REAL,
    per_job_usd REAL,
    on_exceed   TEXT NOT NULL DEFAULT 'hold',
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_budgets_scope ON budgets(scope, target);
CREATE INDEX IF NOT EXISTS idx_budgets_target ON budgets(target);

CREATE TABLE IF NOT EXISTS job_iterations (
    id                    INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id                TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    iteration             INTEGER NOT NULL,
    status                TEXT NOT NULL,
    checkpoint            TEXT,
    trace                 TEXT,
    hold_reason           TEXT,
    result                TEXT,
    input_tokens          INTEGER NOT NULL DEFAULT 0,
    output_tokens         INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
    model                 TEXT,
    provider              TEXT,
    cost_usd              REAL NOT NULL DEFAULT 0,
    created_at            TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_job_iterations_job ON job_iterations(job_id, iteration);

CREATE TABLE IF NOT EXISTS job_scores (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id     TEXT NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
    dimension  TEXT NOT NULL,
    value      REAL NOT NULL,
    scorer     TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_job_scores_job ON job_scores(job_id);
CREATE INDEX IF NOT EXISTS idx_job_scores_dimension ON job_scores(dimension, created_at);

CREATE TABLE IF NOT EXISTS providers (
    name             TEXT PRIMARY KEY,
    rpm_limit        INTEGER,
    input_tpm_limit  INTEGER,
    output_tpm_limit INTEGER,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE TABLE IF NOT EXISTS provider_usage_window (
    provider      TEXT NOT NULL,
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    recorded_at   TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_provider_usage ON provider_usage_window(provider, recorded_at);

CREATE TABLE IF NOT EXISTS approval_policies (
    id               TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    mode             TEXT NOT NULL DEFAULT 'any',
    enabled          INTEGER NOT NULL DEFAULT 1,
    queue            TEXT,
    tag_key          TEXT,
    tag_value        TEXT,

    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_approval_policies_enabled ON approval_policies(enabled);

CREATE TABLE IF NOT EXISTS webhooks (
    id               TEXT PRIMARY KEY,
    url              TEXT NOT NULL,
    events           TEXT NOT NULL,
    secret           TEXT,
    enabled          INTEGER NOT NULL DEFAULT 1,
    retry_limit      INTEGER NOT NULL DEFAULT 3,
    created_at       TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    last_status_code INTEGER,
    last_error       TEXT,
    last_delivery_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_webhooks_enabled ON webhooks(enabled, created_at);

CREATE TABLE IF NOT EXISTS api_keys (
    key_hash     TEXT PRIMARY KEY,
    name         TEXT NOT NULL,
    namespace    TEXT NOT NULL DEFAULT 'default',
    role         TEXT NOT NULL DEFAULT 'readonly',
    queue_scope  TEXT,
    enabled      INTEGER NOT NULL DEFAULT 1,
    expires_at   TEXT,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    last_used_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_api_keys_enabled ON api_keys(enabled, namespace, role);

CREATE TABLE IF NOT EXISTS auth_roles (
    name        TEXT PRIMARY KEY,
    permissions TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    updated_at  TEXT
);

CREATE TABLE IF NOT EXISTS auth_key_roles (
    key_hash   TEXT NOT NULL,
    role_name  TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now')),
    PRIMARY KEY(key_hash, role_name)
);
CREATE INDEX IF NOT EXISTS idx_auth_key_roles_role ON auth_key_roles(role_name);

CREATE TABLE IF NOT EXISTS audit_logs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    namespace   TEXT NOT NULL DEFAULT 'default',
    principal   TEXT,
    role        TEXT,
    method      TEXT NOT NULL,
    path        TEXT NOT NULL,
    status_code INTEGER NOT NULL,
    metadata    TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created ON audit_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_audit_logs_ns ON audit_logs(namespace, created_at);

CREATE TABLE IF NOT EXISTS namespaces (
    name       TEXT PRIMARY KEY,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
INSERT OR IGNORE INTO namespaces (name) VALUES ('default');

CREATE TABLE IF NOT EXISTS sso_settings (
    id                  TEXT PRIMARY KEY DEFAULT 'singleton',
    provider            TEXT NOT NULL DEFAULT '',
    oidc_issuer_url     TEXT NOT NULL DEFAULT '',
    oidc_client_id      TEXT NOT NULL DEFAULT '',
    saml_enabled        INTEGER NOT NULL DEFAULT 0,
    oidc_group_claim    TEXT NOT NULL DEFAULT 'groups',
    group_role_mappings TEXT NOT NULL DEFAULT '{}',
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%f', 'now'))
);
INSERT OR IGNORE INTO sso_settings (id) VALUES ('singleton');

`

// WaitForLeader blocks until the cluster has a leader or timeout.
func (c *Cluster) WaitForLeader(timeout time.Duration) error {
	deadline := time.After(timeout)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-deadline:
			return fmt.Errorf("timeout waiting for leader")
		case <-ticker.C:
			addr, _ := c.raft.LeaderWithID()
			if addr != "" {
				return nil
			}
		}
	}
}

// JoinCluster sends a join request to the given leader address.
// The leader must call AddVoter to add this node.
func (c *Cluster) JoinCluster(leaderAddr string) error {
	if strings.TrimSpace(leaderAddr) == "" {
		return fmt.Errorf("leader address is required")
	}
	base := strings.TrimSpace(leaderAddr)
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") {
		base = "http://" + base
	}
	u, err := url.Parse(strings.TrimRight(base, "/"))
	if err != nil {
		return fmt.Errorf("parse leader address: %w", err)
	}
	joinURL := strings.TrimRight(u.String(), "/") + "/api/v1/cluster/join"

	body, _ := json.Marshal(map[string]string{
		"node_id": c.config.NodeID,
		"addr":    string(c.transport.LocalAddr()),
	})
	timeout := c.config.ApplyTimeout
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequest(http.MethodPost, joinURL, bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create join request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("join request: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		var m map[string]any
		_ = json.NewDecoder(res.Body).Decode(&m)
		if msg, ok := m["error"].(string); ok && msg != "" {
			return fmt.Errorf("join rejected: %s", msg)
		}
		return fmt.Errorf("join rejected: status %d", res.StatusCode)
	}
	return nil
}

// Configuration returns the current Raft cluster configuration.
func (c *Cluster) Configuration() ([]ServerInfo, error) {
	future := c.raft.GetConfiguration()
	if err := future.Error(); err != nil {
		return nil, err
	}

	var servers []ServerInfo
	for _, s := range future.Configuration().Servers {
		servers = append(servers, ServerInfo{
			ID:      string(s.ID),
			Address: string(s.Address),
			Voter:   s.Suffrage == raft.Voter,
		})
	}
	return servers, nil
}

// ServerInfo describes a node in the cluster.
type ServerInfo struct {
	ID      string `json:"id"`
	Address string `json:"address"`
	Voter   bool   `json:"voter"`
}

func newDurationHistogram() *durationHistogram {
	// Buckets optimized for queue/apply timing visibility.
	b := []time.Duration{
		50 * time.Microsecond,
		100 * time.Microsecond,
		200 * time.Microsecond,
		500 * time.Microsecond,
		1 * time.Millisecond,
		2 * time.Millisecond,
		5 * time.Millisecond,
		10 * time.Millisecond,
		20 * time.Millisecond,
		50 * time.Millisecond,
		100 * time.Millisecond,
		200 * time.Millisecond,
		500 * time.Millisecond,
		1 * time.Second,
	}
	return &durationHistogram{
		buckets: b,
		counts:  make([]uint64, len(b)+1), // +Inf bucket
	}
}

func (h *durationHistogram) observe(d time.Duration) {
	if d < 0 {
		d = 0
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	idx := len(h.buckets)
	for i, b := range h.buckets {
		if d <= b {
			idx = i
			break
		}
	}
	h.counts[idx]++
	h.total++
	h.sumNs += uint64(d)
}

func (h *durationHistogram) snapshot() map[string]any {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.total == 0 {
		return map[string]any{
			"count": 0,
		}
	}
	p50 := h.quantileLocked(0.50)
	p90 := h.quantileLocked(0.90)
	p99 := h.quantileLocked(0.99)
	avg := time.Duration(0)
	if h.total > 0 {
		avg = time.Duration(h.sumNs / h.total)
	}
	buckets := make([]map[string]any, 0, len(h.counts))
	for i, c := range h.counts {
		label := "+Inf"
		if i < len(h.buckets) {
			label = h.buckets[i].String()
		}
		buckets = append(buckets, map[string]any{
			"le":    label,
			"count": c,
		})
	}
	return map[string]any{
		"count":   h.total,
		"avg":     avg.String(),
		"p50":     p50.String(),
		"p90":     p90.String(),
		"p99":     p99.String(),
		"buckets": buckets,
	}
}

// PromBucket holds one histogram bucket for Prometheus exposition.
type PromBucket struct {
	Le    float64 // upper bound in seconds; math.Inf(1) for +Inf
	Count uint64  // cumulative count
}

// PromSnapshot holds histogram data for Prometheus text format rendering.
type PromSnapshot struct {
	Buckets []PromBucket
	Sum     float64 // sum in seconds
	Count   uint64
}

func (h *durationHistogram) promSnapshot() PromSnapshot {
	h.mu.Lock()
	defer h.mu.Unlock()

	snap := PromSnapshot{
		Count:   h.total,
		Sum:     float64(h.sumNs) / 1e9,
		Buckets: make([]PromBucket, 0, len(h.counts)),
	}
	var cumulative uint64
	for i, c := range h.counts {
		cumulative += c
		le := math.Inf(1)
		if i < len(h.buckets) {
			le = h.buckets[i].Seconds()
		}
		snap.Buckets = append(snap.Buckets, PromBucket{Le: le, Count: cumulative})
	}
	return snap
}

func (h *durationHistogram) quantileLocked(q float64) time.Duration {
	if h.total == 0 {
		return 0
	}
	if q <= 0 {
		return 0
	}
	if q > 1 {
		q = 1
	}
	target := uint64(math.Ceil(q * float64(h.total)))
	if target == 0 {
		target = 1
	}
	var acc uint64
	for i, c := range h.counts {
		acc += c
		if acc >= target {
			if i < len(h.buckets) {
				return h.buckets[i]
			}
			if len(h.buckets) == 0 {
				return 0
			}
			return h.buckets[len(h.buckets)-1]
		}
	}
	if len(h.buckets) == 0 {
		return 0
	}
	return h.buckets[len(h.buckets)-1]
}

// QueueTimeHistogram returns Prometheus-formatted histogram data for queue wait time.
func (c *Cluster) QueueTimeHistogram() PromSnapshot {
	return c.queueHist.promSnapshot()
}

// ApplyTimeHistogram returns Prometheus-formatted histogram data for apply execution time.
func (c *Cluster) ApplyTimeHistogram() PromSnapshot {
	return c.applyHist.promSnapshot()
}

// ClusterStatus returns a JSON-friendly status of the cluster.
func (c *Cluster) ClusterStatus() map[string]any {
	stats := c.raft.Stats()
	servers, _ := c.Configuration()

	var serverMaps []map[string]any
	for _, s := range servers {
		m := map[string]any{
			"id":      s.ID,
			"address": s.Address,
			"voter":   s.Voter,
		}
		if s.ID == c.config.NodeID {
			m["role"] = c.State()
			m["self"] = true
		}
		serverMaps = append(serverMaps, m)
	}

	return map[string]any{
		"mode":                           "cluster",
		"state":                          c.State(),
		"leader_id":                      c.LeaderID(),
		"leader_addr":                    c.LeaderAddr(),
		"node_id":                        c.config.NodeID,
		"applied_index":                  stats["applied_index"],
		"commit_index":                   stats["commit_index"],
		"raft_nosync":                    c.config.RaftNoSync,
		"raft_store":                     c.config.RaftStore,
		"pebble_nosync":                  c.config.PebbleNoSync,
		"sqlite_mirror_enabled":          c.config.SQLiteMirror,
		"sqlite_mirror_async":            c.config.SQLiteMirrorAsync,
		"lifecycle_events":               c.config.LifecycleEvents,
		"snapshot_threshold":             c.config.SnapshotThreshold,
		"snapshot_interval":              c.config.SnapshotInterval.String(),
		"apply_batch_max":                c.config.ApplyBatchMax,
		"apply_batch_min_wait":           c.config.ApplyBatchMinWait.String(),
		"apply_batch_extend_at":          c.config.ApplyBatchExtendAt,
		"apply_batch_window":             c.config.ApplyBatchWindow.String(),
		"apply_max_pending":              c.config.ApplyMaxPending,
		"apply_max_fetch_queue_inflight": c.config.ApplyMaxFetchQueueInFly,
		"apply_pending_now":              len(c.applyCh),
		"apply_sub_batch_max":            c.config.ApplySubBatchMax,
		"overload_total":                 c.overloadTotal.Load(),
		"fetch_overload_total":           c.fetchOverloadTotal.Load(),
		"applied_total":                  c.appliedTotal.Load(),
		"queue_time_hist":                c.queueHist.snapshot(),
		"apply_time_hist":                c.applyHist.snapshot(),
		"snapshot":                       c.snapshotStatus(),
		"sqlite_mirror":                  c.fsm.SQLiteMirrorStatus(),
		"sqlite_rebuild":                 c.fsm.SQLiteRebuildStatus(),
		"nodes":                          serverMaps,
	}
}

func (c *Cluster) snapshotStatus() map[string]any {
	if c.snapshot == nil {
		return map[string]any{"count": 0}
	}
	list, err := c.snapshot.List()
	if err != nil {
		return map[string]any{
			"count": 0,
			"error": err.Error(),
		}
	}
	out := map[string]any{
		"count": len(list),
	}
	if len(list) == 0 {
		return out
	}
	latest := list[0]
	out["latest_id"] = latest.ID
	out["latest_index"] = latest.Index
	out["latest_term"] = latest.Term
	out["latest_size"] = latest.Size
	return out
}

// EventLog returns events after afterSeq (exclusive), up to limit entries.
func (c *Cluster) EventLog(afterSeq uint64, limit int) ([]map[string]any, error) {
	if limit <= 0 {
		limit = 100
	}
	if limit > 1000 {
		limit = 1000
	}

	start := afterSeq + 1
	iter, err := c.fsm.pebble.NewIter(&pebble.IterOptions{
		LowerBound: kv.EventLogKey(start),
	})
	if err != nil {
		return nil, err
	}
	defer iter.Close()

	prefix := kv.EventLogPrefix()
	events := make([]map[string]any, 0, limit)
	for iter.First(); iter.Valid() && len(events) < limit; iter.Next() {
		if !bytes.HasPrefix(iter.Key(), prefix) {
			break
		}
		var ev lifecycleEvent
		if err := json.Unmarshal(iter.Value(), &ev); err != nil {
			continue
		}
		item := map[string]any{
			"seq":   ev.Seq,
			"type":  ev.Type,
			"at_ns": ev.AtNs,
		}
		if ev.JobID != "" {
			item["job_id"] = ev.JobID
		}
		if ev.Queue != "" {
			item["queue"] = ev.Queue
		}
		events = append(events, item)
	}
	if err := iter.Error(); err != nil {
		return nil, err
	}
	return events, nil
}

// ApplyJSON is a convenience for applying a pre-serialized Op byte slice.
func (c *Cluster) ApplyJSON(data []byte) *store.OpResult {
	return c.applyBytes(data)
}

// Raft returns the underlying raft.Raft instance.
func (c *Cluster) Raft() *raft.Raft {
	return c.raft
}

// RebuildSQLiteFromPebble rebuilds local SQLite materialized state from Pebble.
func (c *Cluster) RebuildSQLiteFromPebble() error {
	return c.fsm.RebuildSQLiteFromPebble()
}

// SnapshotAfterFirstApply waits until the first user-applied Raft entry exists,
// then attempts a snapshot. It avoids the "nothing new to snapshot" startup noise.
func (c *Cluster) SnapshotAfterFirstApply(timeout time.Duration) error {
	if !c.IsLeader() {
		return nil
	}
	deadline := time.Now().Add(timeout)
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		stats := c.raft.Stats()
		applied, _ := strconv.ParseUint(stats["applied_index"], 10, 64)
		if applied > 0 {
			if err := c.raft.Snapshot().Error(); err != nil && !strings.Contains(strings.ToLower(err.Error()), "nothing new to snapshot") {
				return err
			}
			return nil
		}
		if timeout > 0 && time.Now().After(deadline) {
			return fmt.Errorf("timeout waiting for first apply before snapshot")
		}
		select {
		case <-c.stopCh:
			return fmt.Errorf("cluster stopping")
		case <-ticker.C:
		}
	}
}
