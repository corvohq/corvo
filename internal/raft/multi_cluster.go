package raft

import (
	"database/sql"
	"fmt"
	"hash/fnv"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/user/jobbie/internal/store"
)

// MultiCluster runs N independent raft groups in one process and routes ops
// by queue hash. This is a static sharding MVP (no live rebalancing).
type MultiCluster struct {
	shards []*Cluster
	readDB *sql.DB
	cache  sync.Map // job_id -> shard index
}

// NewMultiCluster starts shardCount raft groups with independent raft/pebble
// state and a shared SQLite mirror database for cross-shard reads.
func NewMultiCluster(base ClusterConfig, shardCount int) (*MultiCluster, error) {
	if shardCount < 2 {
		return nil, fmt.Errorf("shardCount must be >= 2")
	}
	if strings.TrimSpace(base.JoinAddr) != "" {
		return nil, fmt.Errorf("join is not supported with multi-raft sharding yet")
	}
	if !base.Bootstrap {
		return nil, fmt.Errorf("multi-raft sharding currently requires bootstrap=true")
	}
	host, port, err := splitHostPort(base.RaftBind)
	if err != nil {
		return nil, fmt.Errorf("parse raft bind %q: %w", base.RaftBind, err)
	}

	rootDir := base.DataDir
	sharedSQLite := strings.TrimSpace(base.SQLitePath)
	if sharedSQLite == "" {
		sharedSQLite = filepath.Join(rootDir, "jobbie.db")
	}
	if err := ensureDir(filepath.Dir(sharedSQLite)); err != nil {
		return nil, err
	}

	m := &MultiCluster{shards: make([]*Cluster, 0, shardCount)}
	for i := 0; i < shardCount; i++ {
		cfg := base
		cfg.NodeID = fmt.Sprintf("%s-s%02d", base.NodeID, i)
		cfg.DataDir = filepath.Join(rootDir, fmt.Sprintf("shard-%02d", i))
		cfg.RaftBind = net.JoinHostPort(host, fmt.Sprintf("%d", port+i))
		cfg.RaftAdvertise = "" // derive from bind per shard
		cfg.SQLitePath = sharedSQLite
		shard, err := NewCluster(cfg)
		if err != nil {
			_ = m.Shutdown()
			return nil, fmt.Errorf("start shard %d: %w", i, err)
		}
		m.shards = append(m.shards, shard)
	}
	if len(m.shards) > 0 {
		m.readDB = m.shards[0].SQLiteReadDB()
	}
	return m, nil
}

func splitHostPort(bind string) (host string, port int, err error) {
	addr, err := net.ResolveTCPAddr("tcp", bind)
	if err != nil {
		return "", 0, err
	}
	h := addr.IP.String()
	if addr.IP == nil || addr.IP.IsUnspecified() {
		h = "127.0.0.1"
	}
	return h, addr.Port, nil
}

func ensureDir(path string) error {
	if strings.TrimSpace(path) == "" {
		return nil
	}
	return os.MkdirAll(path, 0755)
}

func (m *MultiCluster) shardIndexForQueue(queue string) int {
	if len(m.shards) == 0 {
		return 0
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(queue))
	return int(h.Sum32() % uint32(len(m.shards)))
}

func (m *MultiCluster) shardForQueue(queue string) *Cluster {
	return m.shards[m.shardIndexForQueue(queue)]
}

func (m *MultiCluster) cacheJobShard(jobID string, idx int) {
	if strings.TrimSpace(jobID) == "" || idx < 0 {
		return
	}
	m.cache.Store(jobID, idx)
}

func (m *MultiCluster) shardIndexForJobID(jobID string) int {
	if strings.TrimSpace(jobID) == "" {
		return -1
	}
	if v, ok := m.cache.Load(jobID); ok {
		if idx, ok := v.(int); ok && idx >= 0 && idx < len(m.shards) {
			return idx
		}
	}
	if m.readDB != nil {
		var queue string
		err := m.readDB.QueryRow("SELECT queue FROM jobs WHERE id = ? LIMIT 1", jobID).Scan(&queue)
		if err == nil && queue != "" {
			idx := m.shardIndexForQueue(queue)
			m.cacheJobShard(jobID, idx)
			return idx
		}
	}
	return -1
}

func (m *MultiCluster) shardsForQueues(queues []string) map[int][]string {
	out := make(map[int][]string)
	for _, q := range queues {
		if strings.TrimSpace(q) == "" {
			continue
		}
		idx := m.shardIndexForQueue(q)
		out[idx] = append(out[idx], q)
	}
	return out
}

// Apply routes mutating operations to the owning shard.
func (m *MultiCluster) Apply(opType store.OpType, data any) *store.OpResult {
	if len(m.shards) == 0 {
		return &store.OpResult{Err: fmt.Errorf("no shards configured")}
	}
	switch opType {
	case store.OpEnqueue:
		op, ok := data.(store.EnqueueOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("enqueue op type mismatch: %T", data)}
		}
		idx := m.shardIndexForQueue(op.Queue)
		res := m.shards[idx].Apply(opType, op)
		if res != nil && res.Err == nil {
			m.cacheJobShard(op.JobID, idx)
		}
		return res
	case store.OpEnqueueBatch:
		op, ok := data.(store.EnqueueBatchOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("enqueue batch op type mismatch: %T", data)}
		}
		if len(op.Jobs) == 0 {
			return &store.OpResult{Data: &store.BatchEnqueueResult{JobIDs: nil, BatchID: op.BatchID}}
		}
		groups := make(map[int][]store.EnqueueOp)
		for _, j := range op.Jobs {
			idx := m.shardIndexForQueue(j.Queue)
			groups[idx] = append(groups[idx], j)
		}
		if op.Batch != nil && len(groups) > 1 {
			return &store.OpResult{Err: fmt.Errorf("cross-shard batch callback is not supported yet")}
		}
		merged := &store.BatchEnqueueResult{BatchID: op.BatchID}
		for idx, jobs := range groups {
			sub := store.EnqueueBatchOp{Jobs: jobs, BatchID: op.BatchID, Batch: op.Batch}
			res := m.shards[idx].Apply(opType, sub)
			if res.Err != nil {
				return res
			}
			for _, j := range jobs {
				m.cacheJobShard(j.JobID, idx)
			}
			if out, ok := res.Data.(*store.BatchEnqueueResult); ok && out != nil {
				merged.JobIDs = append(merged.JobIDs, out.JobIDs...)
			}
		}
		return &store.OpResult{Data: merged}
	case store.OpFetch:
		op, ok := data.(store.FetchOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("fetch op type mismatch: %T", data)}
		}
		groups := m.shardsForQueues(op.Queues)
		for idx, qs := range groups {
			sub := op
			sub.Queues = qs
			res := m.shards[idx].Apply(opType, sub)
			if res.Err != nil {
				return res
			}
			if res.Data != nil {
				return res
			}
		}
		return &store.OpResult{Data: nil}
	case store.OpFetchBatch:
		op, ok := data.(store.FetchBatchOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("fetch batch op type mismatch: %T", data)}
		}
		groups := m.shardsForQueues(op.Queues)
		remaining := op.Count
		merged := make([]store.FetchResult, 0, op.Count)
		for idx, qs := range groups {
			if remaining <= 0 {
				break
			}
			sub := op
			sub.Queues = qs
			sub.Count = remaining
			res := m.shards[idx].Apply(opType, sub)
			if res.Err != nil {
				return res
			}
			jobs, _ := res.Data.([]store.FetchResult)
			for _, j := range jobs {
				m.cacheJobShard(j.JobID, idx)
			}
			merged = append(merged, jobs...)
			remaining = op.Count - len(merged)
		}
		return &store.OpResult{Data: merged}
	case store.OpAck:
		op, ok := data.(store.AckOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("ack op type mismatch: %T", data)}
		}
		if idx := m.shardIndexForJobID(op.JobID); idx >= 0 {
			return m.shards[idx].Apply(opType, op)
		}
		for _, s := range m.shards {
			res := s.Apply(opType, op)
			if res.Err == nil {
				return res
			}
		}
		return &store.OpResult{Err: fmt.Errorf("job %s not found on any shard", op.JobID)}
	case store.OpAckBatch:
		op, ok := data.(store.AckBatchOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("ack batch op type mismatch: %T", data)}
		}
		grouped := make(map[int][]store.AckOp)
		unknown := make([]store.AckOp, 0)
		for _, a := range op.Acks {
			idx := m.shardIndexForJobID(a.JobID)
			if idx < 0 {
				unknown = append(unknown, a)
				continue
			}
			grouped[idx] = append(grouped[idx], a)
		}
		total := 0
		for idx, acks := range grouped {
			res := m.shards[idx].Apply(opType, store.AckBatchOp{Acks: acks, NowNs: op.NowNs})
			if res.Err != nil {
				return res
			}
			if n, ok := res.Data.(int); ok {
				total += n
			}
		}
		for _, a := range unknown {
			acked := false
			for i, s := range m.shards {
				res := s.Apply(store.OpAck, a)
				if res.Err == nil {
					m.cacheJobShard(a.JobID, i)
					total++
					acked = true
					break
				}
			}
			if !acked {
				// Best-effort batch behavior: keep going.
				continue
			}
		}
		return &store.OpResult{Data: total}
	case store.OpFail:
		op, ok := data.(store.FailOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("fail op type mismatch: %T", data)}
		}
		if idx := m.shardIndexForJobID(op.JobID); idx >= 0 {
			return m.shards[idx].Apply(opType, op)
		}
		for _, s := range m.shards {
			res := s.Apply(opType, op)
			if res.Err == nil {
				return res
			}
		}
		return &store.OpResult{Err: fmt.Errorf("job %s not found on any shard", op.JobID)}
	case store.OpRetryJob:
		op, ok := data.(store.RetryJobOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("retry op type mismatch: %T", data)}
		}
		if idx := m.shardIndexForJobID(op.JobID); idx >= 0 {
			return m.shards[idx].Apply(opType, op)
		}
		return m.shards[0].Apply(opType, op)
	case store.OpCancelJob:
		op, ok := data.(store.CancelJobOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("cancel op type mismatch: %T", data)}
		}
		if idx := m.shardIndexForJobID(op.JobID); idx >= 0 {
			return m.shards[idx].Apply(opType, op)
		}
		return m.shards[0].Apply(opType, op)
	case store.OpMoveJob:
		op, ok := data.(store.MoveJobOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("move op type mismatch: %T", data)}
		}
		if idx := m.shardIndexForJobID(op.JobID); idx >= 0 {
			return m.shards[idx].Apply(opType, op)
		}
		return m.shards[0].Apply(opType, op)
	case store.OpDeleteJob:
		op, ok := data.(store.DeleteJobOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("delete op type mismatch: %T", data)}
		}
		if idx := m.shardIndexForJobID(op.JobID); idx >= 0 {
			return m.shards[idx].Apply(opType, op)
		}
		return m.shards[0].Apply(opType, op)
	case store.OpHeartbeat:
		op, ok := data.(store.HeartbeatOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("heartbeat op type mismatch: %T", data)}
		}
		grouped := make(map[int]map[string]store.HeartbeatJobOp)
		for jobID, upd := range op.Jobs {
			idx := m.shardIndexForJobID(jobID)
			if idx < 0 {
				idx = 0
			}
			if grouped[idx] == nil {
				grouped[idx] = make(map[string]store.HeartbeatJobOp)
			}
			grouped[idx][jobID] = upd
		}
		ack := &store.HeartbeatResponse{Jobs: make(map[string]store.HeartbeatJobResponse, len(op.Jobs))}
		for idx, jobs := range grouped {
			res := m.shards[idx].Apply(opType, store.HeartbeatOp{Jobs: jobs, NowNs: op.NowNs})
			if res.Err != nil {
				return res
			}
			if out, ok := res.Data.(*store.HeartbeatResponse); ok && out != nil {
				for id, job := range out.Jobs {
					ack.Jobs[id] = job
				}
			}
		}
		return &store.OpResult{Data: ack}
	case store.OpPauseQueue, store.OpResumeQueue, store.OpClearQueue, store.OpDeleteQueue,
		store.OpSetConcurrency, store.OpSetThrottle, store.OpRemoveThrottle:
		switch op := data.(type) {
		case store.QueueOp:
			return m.shardForQueue(op.Queue).Apply(opType, op)
		case store.SetConcurrencyOp:
			return m.shardForQueue(op.Queue).Apply(opType, op)
		case store.SetThrottleOp:
			return m.shardForQueue(op.Queue).Apply(opType, op)
		default:
			return &store.OpResult{Err: fmt.Errorf("queue op type mismatch for %d: %T", opType, data)}
		}
	case store.OpPromote, store.OpReclaim, store.OpCleanUnique, store.OpCleanRateLimit:
		for _, s := range m.shards {
			res := s.Apply(opType, data)
			if res.Err != nil {
				return res
			}
		}
		return &store.OpResult{Data: nil}
	default:
		// Conservative fallback: execute on shard 0.
		return m.shards[0].Apply(opType, data)
	}
}

func (m *MultiCluster) SQLiteReadDB() *sql.DB { return m.readDB }
func (m *MultiCluster) IsLeader() bool        { return len(m.shards) > 0 && m.shards[0].IsLeader() }
func (m *MultiCluster) LeaderAddr() string {
	if len(m.shards) == 0 {
		return ""
	}
	return m.shards[0].LeaderAddr()
}
func (m *MultiCluster) State() string {
	if len(m.shards) == 0 {
		return "stopped"
	}
	return m.shards[0].State()
}
func (m *MultiCluster) EventLog(afterSeq uint64, limit int) ([]map[string]any, error) {
	if len(m.shards) == 0 {
		return nil, nil
	}
	return m.shards[0].EventLog(afterSeq, limit)
}
func (m *MultiCluster) RebuildSQLiteFromPebble() error {
	for _, s := range m.shards {
		if err := s.RebuildSQLiteFromPebble(); err != nil {
			return err
		}
	}
	return nil
}
func (m *MultiCluster) WaitForLeader(timeout time.Duration) error {
	for _, s := range m.shards {
		if err := s.WaitForLeader(timeout); err != nil {
			return err
		}
	}
	return nil
}
func (m *MultiCluster) JoinCluster(string) error {
	return fmt.Errorf("multi-raft join is not supported yet")
}
func (m *MultiCluster) SnapshotAfterFirstApply(timeout time.Duration) error {
	for _, s := range m.shards {
		if err := s.SnapshotAfterFirstApply(timeout); err != nil {
			return err
		}
	}
	return nil
}
func (m *MultiCluster) ClusterStatus() map[string]any {
	out := map[string]any{
		"mode":   "multi-raft",
		"shards": len(m.shards),
	}
	shards := make([]map[string]any, 0, len(m.shards))
	for i, s := range m.shards {
		st := s.ClusterStatus()
		st["shard"] = i
		shards = append(shards, st)
	}
	out["groups"] = shards
	return out
}
func (m *MultiCluster) Shutdown() error {
	var firstErr error
	for i := len(m.shards) - 1; i >= 0; i-- {
		if err := m.shards[i].Shutdown(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}
