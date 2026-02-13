package raft

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cockroachdb/pebble"
	"github.com/hashicorp/raft"
	"github.com/user/jobbie/internal/store"
)

func testRaftAddr(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	_ = ln.Close()
	return addr
}

func testCluster(t *testing.T, nodeID, raftBind string, bootstrap bool) *Cluster {
	t.Helper()
	cfg := DefaultClusterConfig()
	cfg.NodeID = nodeID
	cfg.DataDir = t.TempDir()
	cfg.RaftBind = raftBind
	cfg.Bootstrap = bootstrap

	c, err := NewCluster(cfg)
	if err != nil {
		t.Fatalf("NewCluster(%s): %v", nodeID, err)
	}
	return c
}

func waitFor(t *testing.T, timeout time.Duration, fn func() bool, msg string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if fn() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("timeout waiting for %s", msg)
}

func addVoterWithRetry(t *testing.T, leader *Cluster, nodeID, addr string) {
	t.Helper()
	var lastErr error
	waitFor(t, 8*time.Second, func() bool {
		lastErr = leader.AddVoter(nodeID, addr)
		return lastErr == nil
	}, fmt.Sprintf("add voter %s (%v)", nodeID, lastErr))
}

func waitForLeaderFrom(t *testing.T, clusters []*Cluster, timeout time.Duration) *Cluster {
	t.Helper()
	var leader *Cluster
	waitFor(t, timeout, func() bool {
		for _, c := range clusters {
			if c != nil && c.IsLeader() {
				leader = c
				return true
			}
		}
		return false
	}, "leader election")
	return leader
}

func waitForJob(t *testing.T, s *store.Store, jobID string, timeout time.Duration) {
	t.Helper()
	waitFor(t, timeout, func() bool {
		_, err := s.GetJob(jobID)
		return err == nil
	}, "job replication")
}

func waitForJobCount(t *testing.T, db *sql.DB, want int, timeout time.Duration) {
	t.Helper()
	waitFor(t, timeout, func() bool {
		var got int
		if err := db.QueryRow("SELECT COUNT(*) FROM jobs").Scan(&got); err != nil {
			return false
		}
		return got == want
	}, fmt.Sprintf("job count %d", want))
}

func TestClusterSingleNodeBootstrap(t *testing.T) {
	c1 := testCluster(t, "node-1", testRaftAddr(t), true)
	defer c1.Shutdown()

	if err := c1.WaitForLeader(5 * time.Second); err != nil {
		t.Fatalf("WaitForLeader: %v", err)
	}
	if !c1.IsLeader() {
		t.Fatal("expected node-1 to be leader")
	}

	s := store.NewStore(c1, c1.SQLiteReadDB())
	result, err := s.Enqueue(store.EnqueueRequest{
		Queue:   "raft.single",
		Payload: json.RawMessage(`{"hello":"world"}`),
	})
	if err != nil {
		t.Fatalf("Enqueue: %v", err)
	}

	job, err := s.GetJob(result.JobID)
	if err != nil {
		t.Fatalf("GetJob: %v", err)
	}
	if job.Queue != "raft.single" {
		t.Fatalf("queue = %s, want raft.single", job.Queue)
	}
}

func TestClusterThreeNodeFailover(t *testing.T) {
	addr1 := testRaftAddr(t)
	addr2 := testRaftAddr(t)
	addr3 := testRaftAddr(t)

	c1 := testCluster(t, "node-1", addr1, true)
	defer func() {
		if c1 != nil {
			c1.Shutdown()
		}
	}()
	if err := c1.WaitForLeader(5 * time.Second); err != nil {
		t.Fatalf("node-1 WaitForLeader: %v", err)
	}

	c2 := testCluster(t, "node-2", addr2, false)
	defer c2.Shutdown()
	c3 := testCluster(t, "node-3", addr3, false)
	defer c3.Shutdown()

	addVoterWithRetry(t, c1, "node-2", addr2)
	addVoterWithRetry(t, c1, "node-3", addr3)

	waitFor(t, 8*time.Second, func() bool {
		servers, err := c1.Configuration()
		return err == nil && len(servers) == 3
	}, "3-node configuration")

	clusters := []*Cluster{c1, c2, c3}
	leader := waitForLeaderFrom(t, clusters, 8*time.Second)

	leaderStore := store.NewStore(leader, leader.SQLiteReadDB())
	r1, err := leaderStore.Enqueue(store.EnqueueRequest{
		Queue:   "raft.failover",
		Payload: json.RawMessage(`{"step":1}`),
	})
	if err != nil {
		t.Fatalf("enqueue on leader: %v", err)
	}

	s1 := store.NewStore(c1, c1.SQLiteReadDB())
	s2 := store.NewStore(c2, c2.SQLiteReadDB())
	s3 := store.NewStore(c3, c3.SQLiteReadDB())
	waitForJob(t, s1, r1.JobID, 5*time.Second)
	waitForJob(t, s2, r1.JobID, 5*time.Second)
	waitForJob(t, s3, r1.JobID, 5*time.Second)

	leader.Shutdown()
	if leader == c1 {
		c1 = nil
	}
	if leader == c2 {
		c2 = nil
	}
	if leader == c3 {
		c3 = nil
	}

	var remaining []*Cluster
	if c1 != nil {
		remaining = append(remaining, c1)
	}
	if c2 != nil {
		remaining = append(remaining, c2)
	}
	if c3 != nil {
		remaining = append(remaining, c3)
	}

	newLeader := waitForLeaderFrom(t, remaining, 10*time.Second)
	newLeaderStore := store.NewStore(newLeader, newLeader.SQLiteReadDB())
	r2, err := newLeaderStore.Enqueue(store.EnqueueRequest{
		Queue:   "raft.failover",
		Payload: json.RawMessage(`{"step":2}`),
	})
	if err != nil {
		t.Fatalf("enqueue on new leader: %v", err)
	}

	for _, c := range remaining {
		waitForJob(t, store.NewStore(c, c.SQLiteReadDB()), r2.JobID, 5*time.Second)
	}
}

func TestClusterLateJoinAfterSnapshot(t *testing.T) {
	addr1 := testRaftAddr(t)
	addr2 := testRaftAddr(t)
	addr3 := testRaftAddr(t)

	c1 := testCluster(t, "node-1", addr1, true)
	defer c1.Shutdown()
	if err := c1.WaitForLeader(5 * time.Second); err != nil {
		t.Fatalf("node-1 WaitForLeader: %v", err)
	}

	c2 := testCluster(t, "node-2", addr2, false)
	defer c2.Shutdown()
	addVoterWithRetry(t, c1, "node-2", addr2)

	s1 := store.NewStore(c1, c1.SQLiteReadDB())
	const jobs = 150
	for i := 0; i < jobs; i++ {
		_, err := s1.Enqueue(store.EnqueueRequest{
			Queue:   "raft.snapshot",
			Payload: json.RawMessage(fmt.Sprintf(`{"i":%d}`, i)),
		})
		if err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
	}
	waitForJobCount(t, c2.SQLiteReadDB(), jobs, 8*time.Second)

	if err := c1.Raft().Snapshot().Error(); err != nil {
		t.Fatalf("snapshot: %v", err)
	}

	c3 := testCluster(t, "node-3", addr3, false)
	defer c3.Shutdown()
	addVoterWithRetry(t, c1, "node-3", addr3)

	waitForJobCount(t, c3.SQLiteReadDB(), jobs, 12*time.Second)
}

func TestPrepareFSMForRecoveryClearsPebbleWhenNoSnapshot(t *testing.T) {
	root := t.TempDir()
	pebbleDir := filepath.Join(root, "pebble")
	if err := os.MkdirAll(pebbleDir, 0o755); err != nil {
		t.Fatalf("mkdir pebble dir: %v", err)
	}
	pdb, err := pebble.Open(pebbleDir, &pebble.Options{})
	if err != nil {
		t.Fatalf("open pebble: %v", err)
	}
	defer pdb.Close()

	if err := pdb.Set([]byte("j|job-1"), []byte(`{"id":"job-1"}`), pebble.Sync); err != nil {
		t.Fatalf("seed pebble: %v", err)
	}

	snapDir := filepath.Join(root, "raft")
	if err := os.MkdirAll(snapDir, 0o755); err != nil {
		t.Fatalf("mkdir raft dir: %v", err)
	}
	ss, err := raft.NewFileSnapshotStore(snapDir, 2, os.Stderr)
	if err != nil {
		t.Fatalf("new snapshot store: %v", err)
	}

	if err := prepareFSMForRecovery(pdb, ss); err != nil {
		t.Fatalf("prepareFSMForRecovery: %v", err)
	}

	iter, err := pdb.NewIter(nil)
	if err != nil {
		t.Fatalf("iter: %v", err)
	}
	defer iter.Close()
	if iter.First() {
		t.Fatalf("expected empty pebble after recovery prep with no snapshots")
	}
}

func TestClusterOverloadPressureReturnsRetryHint(t *testing.T) {
	cfg := DefaultClusterConfig()
	cfg.NodeID = "node-overload"
	cfg.DataDir = t.TempDir()
	cfg.RaftBind = testRaftAddr(t)
	cfg.Bootstrap = true
	// Force admission pressure so burst traffic triggers overload signaling.
	cfg.ApplyMaxPending = 8
	cfg.ApplyBatchMax = 16
	cfg.ApplyBatchMinWait = 200 * time.Microsecond
	cfg.ApplyBatchWindow = 1 * time.Millisecond

	c, err := NewCluster(cfg)
	if err != nil {
		t.Fatalf("NewCluster: %v", err)
	}
	defer c.Shutdown()
	if err := c.WaitForLeader(5 * time.Second); err != nil {
		t.Fatalf("WaitForLeader: %v", err)
	}

	s := store.NewStore(c, c.SQLiteReadDB())

	const total = 256
	start := make(chan struct{})
	var wg sync.WaitGroup
	var overloaded atomic.Int64
	var overloadedWithRetry atomic.Int64
	var succeeded atomic.Int64

	for i := 0; i < total; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, err := s.Enqueue(store.EnqueueRequest{
				Queue:   "raft.overload",
				Payload: json.RawMessage(fmt.Sprintf(`{"i":%d}`, i)),
			})
			if err == nil {
				succeeded.Add(1)
				return
			}
			if store.IsOverloadedError(err) {
				overloaded.Add(1)
				if retryMs, ok := store.OverloadRetryAfterMs(err); ok && retryMs > 0 {
					overloadedWithRetry.Add(1)
				}
			}
		}()
	}

	close(start)
	wg.Wait()

	if overloaded.Load() == 0 {
		t.Fatalf("expected at least one overloaded result under burst pressure")
	}
	if overloadedWithRetry.Load() == 0 {
		t.Fatalf("expected overloaded results to include retry hint")
	}
	if succeeded.Load() == 0 {
		t.Fatalf("expected at least one successful enqueue")
	}
}

func TestClusterRestartRecoveryWithoutSnapshot(t *testing.T) {
	dataDir := t.TempDir()
	raftBind := testRaftAddr(t)
	cfg := DefaultClusterConfig()
	cfg.NodeID = "node-restart-nosnap"
	cfg.DataDir = dataDir
	cfg.RaftBind = raftBind
	cfg.Bootstrap = true
	cfg.SnapshotThreshold = 1_000_000 // keep this run in log-replay path
	cfg.SnapshotInterval = 10 * time.Minute

	c1, err := NewCluster(cfg)
	if err != nil {
		t.Fatalf("NewCluster(initial): %v", err)
	}
	if err := c1.WaitForLeader(5 * time.Second); err != nil {
		t.Fatalf("WaitForLeader(initial): %v", err)
	}

	s1 := store.NewStore(c1, c1.SQLiteReadDB())
	const jobs = 64
	for i := 0; i < jobs; i++ {
		_, err := s1.Enqueue(store.EnqueueRequest{
			Queue:   "raft.restart.nosnap",
			Payload: json.RawMessage(fmt.Sprintf(`{"i":%d}`, i)),
		})
		if err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
	}
	waitForJobCount(t, c1.SQLiteReadDB(), jobs, 5*time.Second)
	c1.Shutdown()

	c2, err := NewCluster(cfg)
	if err != nil {
		t.Fatalf("NewCluster(restart): %v", err)
	}
	defer c2.Shutdown()
	if err := c2.WaitForLeader(5 * time.Second); err != nil {
		t.Fatalf("WaitForLeader(restart): %v", err)
	}

	waitForJobCount(t, c2.SQLiteReadDB(), jobs, 5*time.Second)
	s2 := store.NewStore(c2, c2.SQLiteReadDB())
	_, err = s2.Enqueue(store.EnqueueRequest{
		Queue:   "raft.restart.nosnap",
		Payload: json.RawMessage(`{"after":"restart"}`),
	})
	if err != nil {
		t.Fatalf("enqueue after restart: %v", err)
	}
	waitForJobCount(t, c2.SQLiteReadDB(), jobs+1, 5*time.Second)
}

func TestClusterRestartRecoveryAfterSnapshot(t *testing.T) {
	dataDir := t.TempDir()
	raftBind := testRaftAddr(t)
	cfg := DefaultClusterConfig()
	cfg.NodeID = "node-restart-snap"
	cfg.DataDir = dataDir
	cfg.RaftBind = raftBind
	cfg.Bootstrap = true
	cfg.SnapshotThreshold = 1_000_000
	cfg.SnapshotInterval = 10 * time.Minute

	c1, err := NewCluster(cfg)
	if err != nil {
		t.Fatalf("NewCluster(initial): %v", err)
	}
	if err := c1.WaitForLeader(5 * time.Second); err != nil {
		t.Fatalf("WaitForLeader(initial): %v", err)
	}

	s1 := store.NewStore(c1, c1.SQLiteReadDB())
	const jobs = 96
	for i := 0; i < jobs; i++ {
		_, err := s1.Enqueue(store.EnqueueRequest{
			Queue:   "raft.restart.snap",
			Payload: json.RawMessage(fmt.Sprintf(`{"i":%d}`, i)),
		})
		if err != nil {
			t.Fatalf("enqueue %d: %v", i, err)
		}
	}
	waitForJobCount(t, c1.SQLiteReadDB(), jobs, 5*time.Second)
	if err := c1.Raft().Snapshot().Error(); err != nil {
		t.Fatalf("snapshot: %v", err)
	}
	c1.Shutdown()

	c2, err := NewCluster(cfg)
	if err != nil {
		t.Fatalf("NewCluster(restart): %v", err)
	}
	defer c2.Shutdown()
	if err := c2.WaitForLeader(5 * time.Second); err != nil {
		t.Fatalf("WaitForLeader(restart): %v", err)
	}
	waitForJobCount(t, c2.SQLiteReadDB(), jobs, 8*time.Second)
}
