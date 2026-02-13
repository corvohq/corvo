package raft

import "time"

// ClusterConfig configures the Raft cluster node.
type ClusterConfig struct {
	NodeID                  string        // Unique node identifier
	DataDir                 string        // Base directory for all data (pebble, sqlite, raft logs)
	RaftBind                string        // Raft transport bind address (e.g. ":9000")
	RaftAdvertise           string        // Advertised Raft address peers should dial (e.g. "127.0.0.1:9000")
	RaftStore               string        // Raft log/stable backend: bolt or badger
	RaftNoSync              bool          // Disable Raft log fsync (unsafe; benchmark only)
	PebbleNoSync            bool          // Disable Pebble fsync (unsafe; benchmark only)
	SQLiteMirror            bool          // Synchronously mirror Pebble mutations into SQLite
	SQLiteMirrorAsync       bool          // Apply SQLite mirror writes asynchronously in background batches
	Bootstrap               bool          // Bootstrap as single-node cluster
	JoinAddr                string        // Address of existing leader to join
	SnapshotThreshold       uint64        // Raft log entries between snapshots
	SnapshotInterval        time.Duration // Periodic snapshot check interval
	ApplyTimeout            time.Duration // Timeout for raft.Apply (default 10s)
	ApplyBatchMax           int           // Max ops per Raft group-commit batch
	ApplyBatchWindow        time.Duration // Max time to wait before flushing a partial batch
	ApplyBatchMinWait       time.Duration // Initial wait for low-load latency before widening to ApplyBatchWindow
	ApplyBatchExtendAt      int           // Batch size threshold to widen timer from ApplyBatchMinWait to ApplyBatchWindow
	ApplyMaxPending         int           // Max pending apply requests before fail-fast backpressure
	ApplyMaxFetchQueueInFly int           // Max concurrent in-flight fetch/fetch-batch applies per queue
	ApplySubBatchMax        int           // Max requests per raft.Apply execution (splits large mixed batches)
	LifecycleEvents         bool          // Persist per-job lifecycle event log in Pebble
	SQLitePath              string        // Optional explicit SQLite mirror path (defaults to <DataDir>/jobbie.db)
}

// DefaultClusterConfig returns a ClusterConfig with sensible defaults.
// Tuned to support 10-20K concurrent lifecycle streams.
func DefaultClusterConfig() ClusterConfig {
	return ClusterConfig{
		NodeID:                  "node-1",
		DataDir:                 "data",
		RaftBind:                ":9000",
		RaftStore:               "bolt",
		SQLiteMirror:            true,
		Bootstrap:               true,
		SnapshotThreshold:       4096,
		SnapshotInterval:        1 * time.Minute,
		ApplyTimeout:            10 * time.Second,
		ApplyBatchMax:           1024,
		ApplyBatchWindow:        8 * time.Millisecond,
		ApplyBatchMinWait:       100 * time.Microsecond,
		ApplyBatchExtendAt:      64,
		ApplyMaxPending:         16384,
		ApplyMaxFetchQueueInFly: 64,
		ApplySubBatchMax:        1024,
		LifecycleEvents:         false,
	}
}
