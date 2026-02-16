# Architecture: Pebble + Raft + SQLite Hybrid

## Context

SQLite write throughput caps at ~39k ops/sec single-node and doesn't support multi-node replication without Raft. We replaced the SQLite-only architecture with:

- **Pebble** (CockroachDB's pure-Go LSM-tree KV store) = source of truth for all job state
- **SQLite** = local materialized view per node for rich queries (search, dashboard, management UI)
- **hashicorp/raft** = consensus/replication, Pebble as the FSM state store

Single binary, no external dependencies. Pebble handles the write-heavy hot path, SQLite handles complex queries, Raft provides HA.

**Current throughput**: ~20–24k ops/sec (single-node, depending on concurrency).

## Architecture

```
Client → HTTP/RPC → Store.Enqueue()
  → Cluster.Apply(opType, data)
    → admission control (per-queue + global in-flight limits)
    → applyCh (buffered pending queue, capacity ApplyMaxPending)
    → applyLoop (group-commit batching with adaptive timer)
    → applyExecLoop → flushApplyBatch (sub-batch splitting)
      → raft.Apply(batch) → FSM.Apply():
                              ├─ Pebble batch (source of truth)
                              └─ SQLite mirror (materialized view, async or sync)

Client → HTTP → Store.SearchJobs() → SQLite read (local, no Raft round-trip)
```

- **Writes**: serialize as Op → admission control → group-commit batch → raft.Apply → FSM applies to Pebble + SQLite on all nodes
- **Reads** (GetJob, SearchJobs, ListQueues, ListWorkers): read directly from local SQLite
- **Fetch** is a write (claims a job) → goes through Raft
- **Leader forwarding**: followers proxy write requests to leader internally (transparent to clients)
- **Determinism**: all timestamps pre-computed by leader (FSM never calls `time.Now()`)
- **Backpressure**: overloaded requests rejected with `429 Too Many Requests` + dynamic `Retry-After`

## Dependencies

```
github.com/cockroachdb/pebble        # LSM-tree KV store (pure Go, no CGO)
github.com/hashicorp/raft             # Consensus protocol
github.com/hashicorp/raft-boltdb/v2   # Raft log/stable store (bolt backend)
github.com/dgraph-io/badger/v4        # Raft log/stable store (badger backend)
```

Raft log/stable store backend is selectable via `--raft-store`: `badger` (default), `bolt`, or `pebble`.

## Pebble Key Layout

Keys are byte-sortable. Prefix + `\x00` separator + big-endian integers:

| Key Pattern | Type | Purpose |
|---|---|---|
| `j\|{job_id}` | Job JSON | Full job data |
| `je\|{job_id}\x00{attempt:4BE}` | JobError JSON | Error per failed attempt |
| `p\|{queue}\x00{priority:1B}{created_ns:8BE}{job_id}` | empty | Pending sorted set (FIFO within priority) |
| `a\|{queue}\x00{job_id}` | lease_expires_ns:8BE | Active set |
| `s\|{queue}\x00{scheduled_ns:8BE}{job_id}` | empty | Scheduled sorted set |
| `r\|{queue}\x00{retry_ns:8BE}{job_id}` | empty | Retrying sorted set |
| `qc\|{queue}` | QueueConfig JSON | Queue config (paused, concurrency, rate) |
| `qn\|{queue}` | empty | Queue name registry |
| `u\|{queue}\x00{unique_key}` | `{job_id}\|{expires_ns:8BE}` | Unique lock with TTL |
| `l\|{queue}\x00{fetched_ns:8BE}{random:8BE}` | empty | Rate limit sliding window |
| `b\|{batch_id}` | Batch JSON | Batch counters + callback |
| `w\|{worker_id}` | Worker JSON | Worker registry |
| `sc\|{schedule_id}` | Schedule JSON | Cron schedule |
| `ev\|{seq:8BE}` | lifecycleEvent JSON | Per-job lifecycle events (optional) |

**Fetch = Seek to `p|{queue}\x00`**, first key is highest-priority oldest job. Delete pending key, add active key.

## Raft Operations

```go
// internal/raft/ops.go — internal/store/ops.go
type Op struct {
    Type OpType          `json:"t"`
    Data json.RawMessage `json:"d"`
}
```

OpTypes: `Enqueue`, `EnqueueBatch`, `Fetch`, `FetchBatch`, `Ack`, `Fail`, `Heartbeat`, `RetryJob`, `CancelJob`, `MoveJob`, `DeleteJob`, `PauseQueue`, `ResumeQueue`, `ClearQueue`, `DeleteQueue`, `SetConcurrency`, `SetThrottle`, `RemoveThrottle`, `Promote`, `Reclaim`, `BulkAction`, `CleanUnique`, `CleanRateLimit`, `ExpireJobs`, `PurgeJobs`, `Multi`

The `Multi` op type wraps multiple ops into a single Raft log entry for group-commit batching.

Each write operation in the store layer becomes: validate → pre-compute (jobID, timestamps) → serialize Op → `cluster.Apply(opType, data)` → unpack result.

## FSM Design

```go
// internal/raft/fsm.go
type FSM struct {
    pebble          *pebble.DB
    sqlite          *sql.DB
    pebbleNoSync    bool   // configurable per deployment mode
    sqliteMirror    bool   // enable/disable SQLite mirroring
    sqliteAsync     bool   // async mirror writes in background
    lifecycleEvents bool   // persist per-job event log in Pebble
}

func (f *FSM) Apply(log *raft.Log) interface{} {
    var op Op
    json.Unmarshal(log.Data, &op)
    switch op.Type {
    case OpEnqueue:     return f.applyEnqueue(op.Data)
    case OpFetch:       return f.applyFetch(op.Data)
    case OpMulti:       return f.applyMulti(op.Data)  // group-commit batch
    // ... one case per OpType
    }
}
```

Each `apply*` function:
1. Deserialize op data
2. Read current state from Pebble
3. Pebble batch: write mutations (with configurable NoSync)
4. Commit Pebble batch
5. SQLite mirror: sync or async depending on config (if SQLite write fails, log error but don't fail — SQLite is rebuildable)
6. Optionally append lifecycle event to Pebble event log
7. Return result

**Snapshot**: Pebble checkpoint (hard links, nearly free) + SQLite VACUUM INTO backup. Tar/gzip for transport.
**Restore**: Replace Pebble data dir + SQLite file from snapshot.

## Cluster and Write Pipeline

```go
// internal/raft/cluster.go
type Cluster struct {
    raft      *raft.Raft
    fsm       *FSM
    transport *raft.NetworkTransport
    logStore  raftStore              // bolt, badger, or pebble backend
    config    ClusterConfig
    applyCh   chan *applyRequest     // pending queue (capacity ApplyMaxPending)
    applyExec chan []*applyRequest   // batched pipeline (capacity 4)
    admitMu   sync.Mutex
    inFlight  map[string]int        // per-key admission counters
    inFlightN int                   // global in-flight count
    queueHist *durationHistogram    // queue wait time histogram
    applyHist *durationHistogram    // raft apply time histogram
}

func NewCluster(cfg ClusterConfig) (*Cluster, error)
func (c *Cluster) Apply(opType OpType, data any) *OpResult  // admission + group-commit
func (c *Cluster) IsLeader() bool
func (c *Cluster) LeaderAddr() string
func (c *Cluster) SQLiteReadDB() *sql.DB
func (c *Cluster) ClusterStatus() map[string]any  // histograms + in-flight stats
func (c *Cluster) EventLog(afterSeq uint64, limit int) ([]map[string]any, error)
func (c *Cluster) Shutdown() error
```

### Apply pipeline

```
Cluster.Apply(opType, data)
  ├─ admissionKey(opType, data) → "q:{queue}" or "g:*"
  ├─ tryAcquireAdmission(key) → reject if per-key or global limit hit
  ├─ applyCh <- req (reject if channel full)
  ├─ applyLoop: collect into batch, flush on timer or batch full
  │   Timer is adaptive:
  │   - Low load: flush at ApplyBatchMinWait (100µs)
  │   - Medium (≥ ExtendAt items): extend to ApplyBatchWindow (8ms)
  │   - High (global >75% capacity): halve timer
  │   - Extreme (global >90%): minimum 20µs
  ├─ applyExec <- batch (capacity 4 for pipelining)
  ├─ applyExecLoop → flushApplyBatch
  │   - Split into sub-batches if > ApplySubBatchMax (128)
  │   - Single-request batches skip multi-op marshaling
  │   - Marshal as Multi op → raft.Apply()
  └─ FSM.Apply on all nodes
```

### Admission control

| Limit | Default | Scope | Purpose |
|---|---|---|---|
| `ApplyMaxInFlight` | 96 | Per admission key (queue) | Prevent hot queue starvation |
| `ApplyMaxTotalInFly` | 2048 | Global | Bound memory and pipeline depth |
| `ApplyMaxPending` | 4096 | Pending queue | Backpressure on channel full |

Admission key derivation: queue-scoped ops (enqueue, fetch, pause, etc.) use `q:{queue_name}`. Multi-queue/global ops use `g:*`. For batch enqueues, if all jobs target the same queue, uses that queue's key; otherwise `g:*`.

On rejection, returns `OverloadedError` with dynamic `Retry-After` (1–10ms) based on backlog/in-flight ratio.

### Configuration

```go
// internal/raft/config.go
type ClusterConfig struct {
    NodeID             string
    DataDir            string
    RaftBind           string
    RaftAdvertise      string
    RaftStore          string        // "bolt", "badger", or "pebble"
    RaftNoSync         bool          // disable Raft log fsync
    PebbleNoSync       bool          // disable Pebble fsync
    SQLiteMirror       bool          // enable SQLite materialized view
    SQLiteMirrorAsync  bool          // async mirror writes
    Bootstrap          bool
    JoinAddr           string
    ApplyTimeout       time.Duration // default 10s
    ApplyBatchMax      int           // default 512
    ApplyBatchWindow   time.Duration // default 8ms
    ApplyBatchMinWait  time.Duration // default 100µs
    ApplyBatchExtendAt int           // default 32
    ApplyMaxPending    int           // default 4096
    ApplyMaxInFlight   int           // default 96
    ApplyMaxTotalInFly int           // default 2048
    ApplySubBatchMax   int           // default 128
    LifecycleEvents    bool          // persist per-job event log
}
```

## Durability Model

Defaults depend on deployment mode:

| Mode | pebbleNoSync | raftNoSync | Rationale |
|---|---|---|---|
| Single-node (`--bootstrap`) | false | false | Every write fsync'd — no replication to fall back on |
| Clustered (`--join` or `--bootstrap=false`) | true | true | Quorum replication provides durability; skip per-entry fsync for throughput |

On leader startup, an immediate Raft snapshot is forced to minimize the pre-first-snapshot recovery window.

SQLite is always rebuildable from Pebble. Mirror failures are logged but don't fail Raft applies.

## Raft Log Store Backends

Selectable via `--raft-store` flag:

| Backend | File | Notes |
|---|---|---|
| `bolt` | `raft_store.go` | BoltDB via `raft-boltdb/v2`. Stable, well-tested. |
| `badger` (default) | `raft_store_badger.go` | BadgerDB v4. Key-value separation, good for large log entries. Custom binary encoding for raft logs. |
| `pebble` | `raft_store_pebble.go` | Pebble. Same engine as FSM store. |

All backends implement the `raftStore` interface (raft.LogStore + raft.StableStore + io.Closer). NoSync is configurable per backend.

## Store Layer

**`store.Store` keeps the same public API** but internally routes writes through Raft:

```go
type Store struct {
    cluster *raft.Cluster  // writes
    sqliteR *sql.DB        // reads (materialized view)
}

// Write: serialize Op → cluster.Apply()
func (s *Store) Enqueue(req EnqueueRequest) (*EnqueueResult, error)
func (s *Store) Fetch(req FetchRequest) (*FetchResult, error)

// Read: query local SQLite directly
func (s *Store) GetJob(id string) (*Job, error)
func (s *Store) SearchJobs(filter search.Filter) (*SearchResult, error)
func (s *Store) ListQueues() ([]QueueInfo, error)
```

## Server Layer

- `server.Server` takes `*store.Store` + `*raft.Cluster`
- **Leader proxy middleware** on write routes: if not leader, proxy request to leader internally (transparent to client)
- Read routes serve from local SQLite on any node
- `handleClusterStatus` returns Raft state, admission stats, latency histograms
- `handleHealthz` pings both Pebble and SQLite
- Overloaded errors (from admission control) translated to `429 Too Many Requests` with `Retry-After` header

## Scheduler

- Takes `*store.Store` + `*raft.Cluster`
- Only runs on leader (`if !cluster.IsLeader() { return }`)
- Promote/reclaim submit Raft ops (iterate Pebble in FSM Apply)

## CLI Flags

```
--bind :8080              HTTP server bind address
--data-dir data           Directory for all data (pebble, sqlite, raft logs)
--raft-bind :9000         Raft transport address
--raft-advertise          Advertised Raft address for peers
--node-id node-1          Unique node ID
--bootstrap               Bootstrap new single-node cluster (default true)
--join <addr>             Join existing cluster
--raft-store badger       Raft log backend: badger, bolt, or pebble
--log-level info          Log level (debug, info, warn, error)
```

## Observability

The apply pipeline tracks two latency histograms (p50/p90/p99/avg with per-bucket counts):

- **Queue time** (`queueHist`): time from Apply() call to batch execution start
- **Apply time** (`applyHist`): time for raft.Apply() to complete

Exposed via `/api/v1/cluster/status` alongside current in-flight count, pending queue depth, and per-node Raft state.

Optional per-job lifecycle event log (`--lifecycle-events`): persists events (enqueued, started, failed, completed, etc.) in Pebble with monotonic sequence numbers. Queryable via `Cluster.EventLog()`.

## File Layout

| File | Purpose |
|---|---|
| `internal/kv/keys.go` | Key construction + prefix constants |
| `internal/kv/keys_test.go` | Round-trip + sort-order tests |
| `internal/kv/encoding.go` | Big-endian integer encoding |
| `internal/kv/encoding_test.go` | Encoding tests |
| `internal/raft/ops.go` | Op/OpType definitions, per-op data structs (shared with store) |
| `internal/raft/fsm.go` | FSM struct, Apply dispatch, mirror config |
| `internal/raft/fsm_ops.go` | One apply* function per OpType |
| `internal/raft/fsm_snapshot.go` | Snapshot (Pebble checkpoint + SQLite VACUUM INTO) + Restore |
| `internal/raft/fsm_sqlite.go` | SQLite sync helpers (upsertJob, deleteJob, etc.) |
| `internal/raft/eventlog.go` | Per-job lifecycle event log (optional, Pebble-backed) |
| `internal/raft/cluster.go` | Raft node setup, apply pipeline, admission control, histograms |
| `internal/raft/cluster_test.go` | Single + multi-node tests |
| `internal/raft/config.go` | ClusterConfig struct (all tuning parameters) |
| `internal/raft/raft_store.go` | Raft log/stable store interface + bolt backend |
| `internal/raft/raft_store_badger.go` | BadgerDB raft store implementation |
| `internal/raft/raft_store_pebble.go` | Pebble raft store implementation |
| `internal/raft/transport.go` | TCP transport config |
| `internal/store/ops.go` | OpInput, MarshalOp, MarshalMulti, OpResult, OverloadedError |

## Verification

1. `go test ./internal/kv/... -count=1` — key encoding
2. `go test ./internal/raft/... -count=1` — FSM + cluster + apply pipeline
3. `go test ./internal/store/... -count=1` — store API
4. `go test ./... -count=1` — full suite
5. `go build ./cmd/corvo`
6. `./corvo server --bootstrap --data-dir /tmp/corvo-test` — single node
7. Bench: `corvo bench` — HTTP benchmark tool for throughput + latency
