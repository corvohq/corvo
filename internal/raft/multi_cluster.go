package raft

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"io"
	"net"
	"net/http"
	neturl "net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/corvohq/corvo/internal/store"
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
	host, port, err := splitHostPort(base.RaftBind)
	if err != nil {
		return nil, fmt.Errorf("parse raft bind %q: %w", base.RaftBind, err)
	}

	rootDir := base.DataDir
	// Multi-shard always uses a shared SQLite so cross-shard reads work.
	sharedSQLite := strings.TrimSpace(base.SQLitePath)
	if sharedSQLite == "" {
		sharedSQLite = filepath.Join(rootDir, "corvo.db")
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
		cfg.JoinAddr = ""
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
	if idx, ok := parseShardTag(jobID, len(m.shards)); ok {
		return idx
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

func tagJobIDForShard(jobID string, idx int) string {
	if idx < 0 {
		return jobID
	}
	if _, ok := parseShardTag(jobID, idx+1); ok {
		return jobID
	}
	return fmt.Sprintf("s%02d_%s", idx, jobID)
}

func parseShardTag(jobID string, shardCount int) (int, bool) {
	if len(jobID) < 4 || jobID[0] != 's' {
		return -1, false
	}
	us := strings.IndexByte(jobID, '_')
	if us < 2 {
		return -1, false
	}
	n, err := strconv.Atoi(jobID[1:us])
	if err != nil || n < 0 {
		return -1, false
	}
	if shardCount > 0 && n >= shardCount {
		return -1, false
	}
	return n, true
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

// HasPendingJobs checks if any of the given queues have pending jobs across
// all relevant shards.
func (m *MultiCluster) HasPendingJobs(queues []string) bool {
	groups := m.shardsForQueues(queues)
	for idx, qs := range groups {
		if m.shards[idx].HasPendingJobs(qs) {
			return true
		}
	}
	return false
}

// FlushSQLiteMirror flushes all shards' SQLite mirrors. Implements store.Applier.
func (m *MultiCluster) FlushSQLiteMirror() {
	for _, shard := range m.shards {
		shard.FlushSQLiteMirror()
	}
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
		op.JobID = tagJobIDForShard(op.JobID, idx)
		res := m.shards[idx].Apply(opType, op)
		if res != nil && res.Err == nil {
			m.cacheJobShard(op.JobID, idx)
			m.shards[idx].InvalidatePendingCache(op.Queue)
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
			j.JobID = tagJobIDForShard(j.JobID, idx)
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
				m.shards[idx].InvalidatePendingCache(j.Queue)
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
		shardIDs := make([]int, 0, len(groups))
		for idx := range groups {
			shardIDs = append(shardIDs, idx)
		}
		sort.Ints(shardIDs)
		for _, idx := range shardIDs {
			qs := groups[idx]
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
		shardIDs := make([]int, 0, len(groups))
		for idx := range groups {
			shardIDs = append(shardIDs, idx)
		}
		sort.Ints(shardIDs)
		for _, idx := range shardIDs {
			qs := groups[idx]
			if remaining <= 0 {
				break
			}
			// Skip shards with no pending jobs to avoid wasted raft consensus.
			// Uses cached result; Raft FSM will return empty if nothing is actually pending.
			if !m.shards[idx].HasPendingJobs(qs) {
				// Only skip if the check is fast (cache hit). When the cache
				// says empty, skip; when it says pending or needs a fresh scan,
				// let the Raft FSM handle it — the FSM scan is authoritative
				// and we avoid the expensive tombstone walk on the read path.
				continue
			}
			sub := op
			sub.Queues = qs
			sub.Count = remaining
			res := m.shards[idx].Apply(opType, sub)
			if res.Err != nil {
				return res
			}
			jobs, _ := res.Data.([]store.FetchResult)
			if len(jobs) == 0 {
				// Shard had no pending jobs; cache this so future checks skip it.
				for _, q := range qs {
					m.shards[idx].MarkQueueEmpty(q)
				}
			}
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
			res := m.shards[idx].Apply(opType, op)
			if res != nil && res.Err == nil {
				m.cache.Delete(op.JobID)
			}
			return res
		}
		for _, s := range m.shards {
			res := s.Apply(opType, op)
			if res.Err == nil {
				m.cache.Delete(op.JobID)
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
			for _, s := range m.shards {
				res := s.Apply(store.OpAck, a)
				if res.Err == nil {
					total++
					break
				}
			}
		}
		return &store.OpResult{Data: total}
	case store.OpFail:
		op, ok := data.(store.FailOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("fail op type mismatch: %T", data)}
		}
		if idx := m.shardIndexForJobID(op.JobID); idx >= 0 {
			res := m.shards[idx].Apply(opType, op)
			if res != nil && res.Err == nil {
				m.cache.Delete(op.JobID)
			}
			return res
		}
		for _, s := range m.shards {
			res := s.Apply(opType, op)
			if res.Err == nil {
				m.cache.Delete(op.JobID)
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
		for _, s := range m.shards {
			res := s.Apply(opType, op)
			if res.Err == nil {
				return res
			}
		}
		return &store.OpResult{Err: fmt.Errorf("job %s not found on any shard", op.JobID)}
	case store.OpCancelJob:
		op, ok := data.(store.CancelJobOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("cancel op type mismatch: %T", data)}
		}
		if idx := m.shardIndexForJobID(op.JobID); idx >= 0 {
			res := m.shards[idx].Apply(opType, op)
			if res != nil && res.Err == nil {
				m.cache.Delete(op.JobID)
			}
			return res
		}
		for _, s := range m.shards {
			res := s.Apply(opType, op)
			if res.Err == nil {
				m.cache.Delete(op.JobID)
				return res
			}
		}
		return &store.OpResult{Err: fmt.Errorf("job %s not found on any shard", op.JobID)}
	case store.OpMoveJob:
		op, ok := data.(store.MoveJobOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("move op type mismatch: %T", data)}
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
	case store.OpDeleteJob:
		op, ok := data.(store.DeleteJobOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("delete op type mismatch: %T", data)}
		}
		if idx := m.shardIndexForJobID(op.JobID); idx >= 0 {
			res := m.shards[idx].Apply(opType, op)
			if res != nil && res.Err == nil {
				m.cache.Delete(op.JobID)
			}
			return res
		}
		for _, s := range m.shards {
			res := s.Apply(opType, op)
			if res.Err == nil {
				m.cache.Delete(op.JobID)
				return res
			}
		}
		return &store.OpResult{Err: fmt.Errorf("job %s not found on any shard", op.JobID)}
	case store.OpHeartbeat:
		op, ok := data.(store.HeartbeatOp)
		if !ok {
			return &store.OpResult{Err: fmt.Errorf("heartbeat op type mismatch: %T", data)}
		}
		grouped := make(map[int]map[string]store.HeartbeatJobOp)
		for jobID, upd := range op.Jobs {
			idx := m.shardIndexForJobID(jobID)
			if idx < 0 {
				// Unknown shard: broadcast to all shards so the owning
				// one picks it up. Each shard silently ignores unknown jobs.
				for i := range m.shards {
					if grouped[i] == nil {
						grouped[i] = make(map[string]store.HeartbeatJobOp)
					}
					grouped[i][jobID] = upd
				}
				continue
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
func (m *MultiCluster) ShardCount() int       { return len(m.shards) }
func (m *MultiCluster) LeaderAddr() string {
	if len(m.shards) == 0 {
		return ""
	}
	return m.shards[0].LeaderAddr()
}
func (m *MultiCluster) IsLeaderForShard(shard int) bool {
	if shard < 0 || shard >= len(m.shards) {
		return false
	}
	return m.shards[shard].IsLeader()
}
func (m *MultiCluster) LeaderAddrForShard(shard int) string {
	if shard < 0 || shard >= len(m.shards) {
		return ""
	}
	return m.shards[shard].LeaderAddr()
}
func (m *MultiCluster) ShardForQueue(queue string) int {
	return m.shardIndexForQueue(queue)
}
func (m *MultiCluster) ShardForJobID(jobID string) (int, bool) {
	idx := m.shardIndexForJobID(jobID)
	return idx, idx >= 0
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
func (m *MultiCluster) AddVoterForShard(shard int, nodeID, addr string) error {
	if shard < 0 || shard >= len(m.shards) {
		return fmt.Errorf("invalid shard index %d", shard)
	}
	return m.shards[shard].AddVoter(nodeID, addr)
}

func (m *MultiCluster) JoinCluster(leaderAddr string) error {
	if strings.TrimSpace(leaderAddr) == "" {
		return fmt.Errorf("leader address is required")
	}
	base := strings.TrimSpace(leaderAddr)
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") {
		base = "http://" + base
	}
	u, err := neturl.Parse(strings.TrimRight(base, "/"))
	if err != nil {
		return fmt.Errorf("parse leader address: %w", err)
	}
	joinURL := strings.TrimRight(u.String(), "/") + "/api/v1/cluster/join"
	timeout := 10 * time.Second
	if len(m.shards) > 0 && m.shards[0].config.ApplyTimeout > 0 {
		timeout = m.shards[0].config.ApplyTimeout
	}
	client := &http.Client{Timeout: timeout}

	for i, shard := range m.shards {
		body, _ := json.Marshal(map[string]any{
			"node_id":     shard.config.NodeID,
			"addr":        string(shard.transport.LocalAddr()),
			"shard":       i,
			"shard_count": len(m.shards),
		})
		req, err := http.NewRequest(http.MethodPost, joinURL, bytes.NewReader(body))
		if err != nil {
			return fmt.Errorf("create shard %d join request: %w", i, err)
		}
		req.Header.Set("Content-Type", "application/json")
		res, err := client.Do(req)
		if err != nil {
			return fmt.Errorf("shard %d join request: %w", i, err)
		}
		if res.StatusCode/100 != 2 {
			var payload map[string]any
			b, _ := io.ReadAll(io.LimitReader(res.Body, 32*1024))
			_ = json.Unmarshal(b, &payload)
			_ = res.Body.Close()
			if msg, ok := payload["error"].(string); ok && msg != "" {
				return fmt.Errorf("shard %d join rejected: %s", i, msg)
			}
			return fmt.Errorf("shard %d join rejected: status %d", i, res.StatusCode)
		}
		_ = res.Body.Close()
	}
	return nil
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
