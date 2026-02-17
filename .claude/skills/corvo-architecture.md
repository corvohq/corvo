# Corvo Architecture: How It Works

## Project Structure

```
cmd/corvo/              CLI + server entry point (all commands)
internal/
  raft/                 Raft cluster, FSM, MultiCluster, storage backends
    cluster.go          Single Raft group: apply pipeline, batching, HasPendingJobs cache
    multi_cluster.go    Multi-raft sharding: queue→shard routing, fan-out
    fsm.go              FSM.Apply dispatch, applyMultiIndexed, snapshot/restore
    fsm_ops.go          All 47 FSM operation handlers (enqueue, fetch, ack, etc.)
    fsm_snapshot.go     Snapshot: Pebble checkpoint + SQLite VACUUM INTO → tar.gz
    raft_binary_codec.go  CB1 binary encoding for batched Raft entries
    eventlog.go         Lifecycle event log in Pebble
  kv/                   Pebble key encoding: prefixes, sort order, key builders
  store/                Store layer: typed ops, models, backoff, op marshaling
  rpcconnect/           ConnectRPC server (StreamLifecycle handler)
    gen/corvo/v1/       Generated proto + Connect stubs
  server/               HTTP server, route handlers, auth, metrics, leader proxy
  scheduler/            Background tasks: promote, reclaim, expire, purge
  enterprise/           License validation, RBAC, SSO, audit, namespaces
sdk/go/
  client/               HTTP client + Worker runtime (long-poll fetch + heartbeat)
  worker/               ConnectRPC client (StreamLifecycle)
proto/corvo/v1/         worker.proto definition
ui/                     React SPA (embedded into binary at build)
```

## Write Path: Every Mutation Goes Through Raft

```
HTTP/RPC handler
  → store.Method() (e.g. Fetch, AckJob, Enqueue)
    → store.applyOp(opType, data)
      → Applier.Apply(opType, data)        ← Cluster or MultiCluster
        → Cluster.Apply()
          → [preResolveFetch() if OpFetchBatch — runs on caller goroutine]
          → applyRequest{} → applyCh (buffered channel)
            → applyLoop() goroutine — timer-based batching
              → applyExecLoop() goroutine
                → store.MarshalMulti() → CB1 binary encoding
                  → raft.Apply(bytes, timeout)   ← consensus
                    → FSM.Apply() on ALL nodes
                      → Pebble batch + SQLite mirror
                    → future.Response() → *store.OpResult
```

## Group-Commit Batching (applyLoop)

The `applyLoop` goroutine collects operations from `applyCh` into batches:

- **Min wait:** 100us (low-load fast path)
- **Extended at:** 32 ops → widens timer to 2ms
- **Max batch:** 128 ops or 2ms window, whichever first
- **Pipeline:** batcher → `applyExec` channel (cap 4) → executor

`applyExecLoop` calls `flushApplyBatch`:
- 1 op → `applyImmediate` (single JSON marshal → raft.Apply)
- N ops → `store.MarshalMulti` → CB1 binary → single raft.Apply

## CB1 Binary Codec

```
CB1 header (3 bytes) | numOps:uvarint | (opType:uvarint | len:uvarint | opData:bytes) * N
```

Hot-path ops (`OpFetchBatch`, `OpAckBatch`) get hand-written binary encoding. Others fall back to protobuf. The FSM decoder pre-decodes all ops into typed structs — no JSON re-parsing at apply time.

## FSM Apply Modes (applyMultiMode)

- **`grouped`** (default): sorts ops — acks first, fetches second, others individually. 2-3 Pebble commits per batch.
- **`indexed`**: single `pebble.IndexedBatch` for all ops. Acks see prior writes within the batch. 1 commit.
- **`individual`**: legacy per-op commits. N commits.

`applyMultiIndexed` sorts: acks → fetches → others. This means freed concurrency slots from acks are visible to fetches in the same Raft entry.

## Pebble Key Layout (kv/ package)

All keys are byte-sortable. `|` namespace separator, `\x00` internal separator.

```
j|{job_id}                                              → job document (msgpack)
je|{job_id}\x00{attempt:4BE}                            → error record
p|{queue}\x00{priority:1B}{created_ns:8BE}{job_id}      → priority-indexed pending
a|{queue}\x00{job_id}                                   → active set (value=lease_ns:8BE)
s|{queue}\x00{scheduled_ns:8BE}{job_id}                 → scheduled set
r|{queue}\x00{retry_ns:8BE}{job_id}                     → retrying set
qa|{queue}\x00{created_ns:8BE}{job_id}                  → append log (normal priority FIFO)
qac|{queue}                                             → cursor (last consumed qa| key)
qc|{queue}                                              → queue config JSON
qn|{queue}                                              → queue name registry
u|{queue}\x00{unique_key}                               → unique lock
w|{worker_id}                                           → worker doc
b|{batch_id}                                            → batch counter
ev|{seq:8BE}                                            → event log entry
```

### Append Log vs Priority Queue
- **Normal priority** (2): goes to `qa|` (append log) — pure FIFO, cursor-based scan
- **High/Critical priority** (0-1): goes to `p|` (priority queue) — sorted by priority then time

### Cursor-Based Fetch (qa| keys)

`findAppendJobForQueue`:
1. Read cursor from `qac|{queue}`
2. `SeekGE(cursor)` → skip past already-consumed entries
3. Find first valid pending job after cursor
4. **Fallback:** if nothing found after cursor, rescan `[prefix, cursor)` for entries with out-of-order timestamps (concurrent producers can have earlier timestamps that arrive via Raft after the cursor advances)
5. Update cursor to consumed key position

## preResolveFetch (cluster.go)

Expensive Pebble iterator scans run on the **caller goroutine** (not the FSM goroutine) to avoid blocking the serial apply path:

1. Scan `p|` and `qa|` prefixes for candidate job IDs
2. Mark candidates in `fetchReserved` sync.Map (prevents duplicate pre-resolution)
3. Pass `CandidateJobIDs` in the FetchBatchOp
4. FSM uses O(1) point lookups (`batch.Get`) instead of iterator scans

## HasPendingJobs Cache (cluster.go)

In-memory `sync.Map` of `queue → {hasPending, deadline}`.

- **Cache miss / expired → true** (assume pending, let FSM decide)
- After enqueue: `InvalidatePendingCache()` → `hasPending=true`, TTL=500ms
- After empty fetch: `MarkQueueEmpty()` → `hasPending=false`, TTL=50ms

False positives are cheap (one wasted Raft apply). False negatives cost up to 50ms latency. Used by MultiCluster to skip empty shards entirely.

## Multi-Raft Sharding (multi_cluster.go)

N independent `Cluster` instances in one process, each with separate Pebble store and Raft group.

### Routing
- **Queue → shard:** `fnv32a(queue_name) % shard_count` (static, no rebalancing)
- **Job ID → shard:** tagged format `s{NN}_{jobID}` — parsed directly from ID for O(1) routing
  - Fallback: in-memory cache → SQLite lookup by queue

### Fan-out
- **Fetch:** groups queues by shard, checks `HasPendingJobs` per shard, applies to relevant shards
- **Enqueue:** routes to shard by queue, calls `InvalidatePendingCache` after
- **Ack:** routes to shard by job ID tag
- **Maintenance** (promote, reclaim, expire): broadcast to ALL shards

### Shared SQLite
All shards share one SQLite file for cross-shard reads (search, dashboard).

## StreamLifecycle (rpcconnect/server.go)

Bidirectional ConnectRPC stream. Each frame carries acks + fetch request + enqueues:

```
Request frame: {request_id, acks[], fetch_count, queues[], enqueues[]}
Response frame: {request_id, acked, jobs[], enqueued_job_ids[], error, leader_addr}
```

### Per-frame processing
1. Rate limit: `1s / MaxFramesPerSec` (default 500/s per stream)
2. Semaphore: `frameSem` (default 2048 concurrent frames across all streams)
3. Leadership check every frame → `NOT_LEADER` + `leader_addr` on change
4. **Acks and fetches fire concurrently** via goroutines + WaitGroup
5. Both land in the same apply batch window → `applyMultiIndexed` sorts acks before fetches
6. Empty fetch → `idleFetchSleep` (100ms) outside semaphore

### Overload protection layers
1. Per-queue fetch semaphore (64 concurrent) → OVERLOADED with 2-8ms retry hint
2. Apply channel (16384 deep) → OVERLOADED
3. Stream in-flight semaphore (2048) → OVERLOADED
4. Per-stream rate limiter (500 fps) → throttle
5. Strike system (10 consecutive errors → close stream)
6. HTTP per-client rate limiter (2000 read / 1000 write RPS)

## SQLite Mirror

Materialized view rebuilt from Pebble. All source of truth is in Pebble.

### Write modes
- **Synchronous** (default): `syncSQLite(fn)` blocks FSM until SQLite updated
- **Async** (`SQLiteMirrorAsync=true`): enqueue callback → background goroutine batches up to 1024 per transaction

### Key tables
`jobs`, `job_errors`, `job_usage`, `job_iterations`, `queues`, `workers`, `batches`, `unique_locks`, `schedules`, `api_keys`, `audit_logs`, `namespaces`

FTS5 on `jobs` for full-text search. Rebuild: `POST /api/v1/admin/rebuild-sqlite`.

## Snapshot / Restore (fsm_snapshot.go)

### Snapshot (Persist)
1. `pdb.Checkpoint(tmpDir)` — Pebble hard-links SST files (near-instant)
2. `VACUUM INTO` — defragmented SQLite copy
3. tar.gz both into Raft SnapshotSink

### Restore
1. Extract tar.gz
2. Bulk-copy all Pebble keys from snapshot into current store
3. Bulk-copy all SQLite rows
4. Rebuild in-memory `activeCount` cache

Triggered at `SnapshotThreshold` (default 4096 entries) or `SnapshotInterval` (1 min).

## Job State Machine

```
enqueue → pending
  → [scheduled_at in future] → scheduled → [promote] → pending
  → [fetch] → active
    → [ack] → completed
    → [ack(continue)] → pending  (agent iteration loop)
    → [ack(hold)] → held
    → [fail, retries left] → retrying → [promote after backoff] → pending
    → [fail, no retries] → dead
    → [lease expired] → pending  (reclaim)
    → [cancel] → cancelled
  → [hold] → held → [approve] → pending / [reject] → dead
```

### Retry Backoff Strategies
- `none` — immediate
- `fixed` — `base_delay` every time
- `linear` — `base_delay * attempt`
- `exponential` (default) — `base_delay * 2^(attempt-1)`, capped at `max_delay`

Default: exponential, 5s base, 10min max.

## Scheduler (leader-only, background ticks)

| Task | Interval | Description |
|------|----------|-------------|
| Promote | 1s | `scheduled`/`retrying` → `pending` when `scheduled_at ≤ now` |
| Reclaim | 1s | `active` with expired lease → `pending` |
| CleanUnique | 30s | Delete expired unique locks |
| CleanRateLimits | 30s | Purge old rate limit window entries |
| ExpireJobs | 10s | Jobs past `expire_at` → `dead` |
| PurgeJobs | `retention-interval` (1h) | Delete terminal jobs older than `retention` (7d) |

## Active Count Cache (fsm.go)

In-memory `map[string]int` tracking active job count per queue. Updated atomically in FSM:
- `incrActive(queue)` on fetch
- `decrActive(queue)` on ack/fail/reclaim
- Checked on fetch to enforce `max_concurrency`

Rebuilt from Pebble scan on startup/restore via `rebuildActiveCount()`.

## Concurrency Control (on fetch)

Checks in order:
1. Queue paused? → skip
2. `activeCount >= max_concurrency`? → skip
3. Rate limit check (sliding window from `l|` keys)
4. Per-queue fetch semaphore (64 in-flight) → OVERLOADED
5. Apply channel depth → OVERLOADED

## Chain Jobs

Jobs with `ChainConfig{Steps, OnFailure, OnExit}`:
- On ack: `progressChain()` creates next step job
- On dead: `progressChainFailure()` creates `on_failure` job
- Dependencies: `dependenciesSatisfied()` checks all `depends_on` job IDs are completed before allowing fetch

## Batch Jobs

`b|{batch_id}` stores `{Total, Pending, Succeeded, Failed, CallbackQueue, CallbackPayload}`:
- On ack: decrement pending, increment succeeded
- On fail(dead): decrement pending, increment failed
- When `Pending == 0`: enqueue callback job if configured

## Unique Keys

`u|{queue}\x00{unique_key}` → `{jobID}|{expiresNs:8BE}`:
- Checked atomically in FSM before creating job → `status: "duplicate"` if exists
- Deleted on completion
- Cleaned by scheduler (30s tick) for expired locks

## Key Files for Common Changes

| Area | Files |
|------|-------|
| Add new FSM op | `store/ops.go` (op type), `fsm_ops.go` (handler), `fsm.go` (dispatch) |
| Add new API endpoint | `server/server.go` (HTTP routes), `server/handlers_*.go` (handlers), `rpcconnect/server.go` (RPC) |
| Change Pebble key layout | `kv/keys.go` |
| Change batching behavior | `cluster.go` (`applyLoop`, `flushApplyBatch`) |
| Change stream behavior | `rpcconnect/server.go` (`StreamLifecycle`) |
| Change fetch logic | `fsm_ops.go` (`applyFetchBatchOp`, `findAppendJobForQueue`) |
| Change sharding | `multi_cluster.go` |
| Add CLI command | `cmd/corvo/cmd_*.go` |
| Change SQLite schema | `cluster.go` (`materializedViewSchema`) |
| Change worker SDK | `sdk/go/client/worker.go` (HTTP), `sdk/go/worker/client.go` (RPC) |
| Change snapshot format | `fsm_snapshot.go` |
| Add scheduler task | `scheduler/scheduler.go` |
