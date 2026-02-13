# Performance Analysis: Raft + Pebble Enqueue Throughput

## Current State

With `raftNoSync=true`, `pebbleNoSync=true`, `sqliteMirrorAsync=true`, the system achieves ~3k enqueue ops/sec. This document traces the bottlenecks and proposes fixes.

## Architecture: Write Path

```
Bench Client (10 goroutines, batch=64 enqueues per Exchange)
  ↓ WebSocket bidi stream (protobuf)
StreamLifecycle handler (1 goroutine per connection)
  ↓ Converts enqueues → store.EnqueueBatch() [single call per stream message]
Store.EnqueueBatch()
  ↓ json.Marshal(EnqueueBatchOp) → BuildOp → MarshalOp
Cluster.Apply(OpEnqueueBatch, data)
  ↓ Sends applyRequest to applyCh, blocks on respCh
applyLoop (single goroutine)
  ↓ Collects batch, waits 500µs–8ms, flushes
flushApplyBatch()
  ↓ Wraps N requests in MultiOp, json.Marshal
raft.Apply(bytes) → BoltDB write → FSM.Apply()
  ↓
FSM.Apply → applyMulti → applyMultiEnqueueBatch (fast path)
  ↓ Single Pebble batch commit + async SQLite mirror
Results propagate back through respCh → store → handler → client
```

## Bottleneck Analysis

### 1. CRITICAL: Double-batching creates tiny Raft batches

The bench client sends 64 enqueues per stream message. The lifecycle handler converts these into a **single** `store.EnqueueBatch()` call. This means each of the 10 goroutines submits **one** `applyRequest` to the `applyCh`.

The `applyLoop` (cluster.go) then batches these:
- `ApplyBatchMinWait = 500µs`, `ApplyBatchExtendAt = 32`, `ApplyBatchMax = 128`
- With only 10 concurrent requests (one per goroutine), the batch never reaches `extendAt=32`
- Timer fires after **500µs** with a batch of ~10 items
- Each item is an `OpEnqueueBatch` containing 64 jobs

So the Raft layer sees **10 items per batch** (not 640). Each batch goes through one `raft.Apply()` round-trip.

**The double-batching means:**
- Client batches 64 jobs into 1 EnqueueBatch op
- applyLoop batches 10 EnqueueBatch ops into 1 MultiOp
- Total: 640 jobs per Raft log entry
- But the overhead is dominated by the Raft round-trip time, not the batch size

The math: at 10 concurrent goroutines, each Exchange is synchronous (send frame → wait for response → send next). So the throughput is:

```
ops/sec = (jobs_per_raft_apply) / (raft_apply_latency)
        = 640 / (serialization + raft_overhead + FSM_apply)
```

### 2. CRITICAL: JSON serialization — 7+ passes per job

Every enqueue goes through this serialization gauntlet:

| Step | Operation | Location |
|------|-----------|----------|
| 1 | `json.Marshal(EnqueueBatchOp)` | `store.BuildOp` (ops.go:73) |
| 2 | `json.Marshal(Op{EnqueueBatch})` | `store.MarshalOp` (ops.go:63-67) |
| 3 | For MultiOp: `json.Marshal([]Op)` | `flushApplyBatch` → `store.MarshalOp` |
| 4 | `json.Marshal(Op{Multi})` | outer envelope |
| 5 | `json.Unmarshal(Op)` | `FSM.Apply` (fsm.go:46) |
| 6 | `json.Unmarshal(MultiOp)` | `applyMulti` (fsm.go:113) |
| 7 | `json.Unmarshal(EnqueueBatchOp)` | `applyMultiEnqueueBatch` |
| 8 | `json.Marshal(jobToDoc(op))` per job | fsm_ops.go:301 |

For a batch of 640 jobs, that's:
- **Steps 1-4**: Marshal 10 EnqueueBatchOps (each containing 64 jobs) + MultiOp wrapping. The EnqueueBatchOp contains 64 fully-serialized EnqueueOps, each ~200-400 bytes. Total payload: **~200KB+** of JSON.
- **Steps 5-7**: Unmarshal the entire ~200KB payload back into Go structs.
- **Step 8**: Marshal each of the 640 jobs individually for Pebble storage.

Estimated JSON overhead: **2-5ms per batch** for 640 jobs. This is a significant chunk of the ~200ms total per batch.

### 3. HIGH: Lifecycle event writes — 2 extra KV ops per job

Every enqueue calls `appendLifecycleEvent()` (eventlog.go:31-52), which adds:
1. `batch.Set(kv.EventLogKey(seq), eventJSON)` — the event itself
2. `batch.Set(kv.EventCursorKey(), cursor)` — the cursor (overwritten N times per batch!)

For 640 jobs per Raft batch, that's **1,280 extra Pebble KV writes**. The cursor is pointlessly written 640 times when only the last write matters.

Additionally, each event requires its own `json.Marshal(lifecycleEvent)` — another 640 JSON marshal operations.

### 4. MEDIUM: `applyLoop` timer too short for this workload

With only 10 applyRequests arriving per batch cycle (one per goroutine), the 500µs minWait fires before more can accumulate. The batch never extends because `len(batch) < extendAt(32)`.

After a flush, each goroutine is blocked waiting for its response. The next round of 10 requests arrives only after the previous `raft.Apply()` completes and responses propagate back through the WebSocket stream. This creates a **serial pipeline**:

```
[batch 10 items] → raft.Apply(~Xms) → [responses sent] → [clients send next frame] → [batch 10 items] → ...
```

### 5. MEDIUM: `flushApplyBatch` single-item path

When `len(batch) == 1` (cluster.go:308-311), the request goes through `applyImmediate` — skipping MultiOp wrapping but still doing a full `raft.Apply()` round-trip for a single op. At low concurrency or bursty traffic, many requests may hit this path.

### 6. LOW: SQLite mirror SAVEPOINTs in async loop

The `sqliteMirrorLoop` (fsm.go:271-285) wraps each queued function in a `SAVEPOINT`/`RELEASE` pair. With 256 ops per flush batch, that's 256 extra SQL round-trips inside the transaction. Since this is async, it doesn't block the write path but causes the mirror to lag.

### 7. LOW: `json.Marshal(jobToDoc(op))` allocates per job

In `applyMultiEnqueueBatch` (fsm_ops.go:301), each job is individually marshaled to JSON for Pebble storage. This creates 640 allocations per batch. A pre-allocated buffer or binary encoding would eliminate this.

## HTTP vs WebSocket Path Comparison

The HTTP enqueue endpoint uses an `enqueueBatcher` (server/enqueue_batcher.go) that collects concurrent POST requests and batches them at the HTTP layer before calling `store.EnqueueBatch()`. This means:

| Aspect | HTTP + enqueueBatcher | WebSocket Lifecycle Stream |
|--------|----------------------|---------------------------|
| Batching layer | HTTP batcher → applyLoop | applyLoop only |
| Items per applyRequest | N (from batcher) | 1 EnqueueBatch (64 jobs) |
| applyLoop batch size | Higher (many individual items) | Lower (10 EnqueueBatch ops) |
| Fast path hit? | `applyMultiEnqueue` (all OpEnqueue) | `applyMultiEnqueueBatch` (all OpEnqueueBatch) |

The WebSocket path may actually be **less efficient** for pure enqueue benchmarks because it pre-batches at the client level, reducing the number of items the `applyLoop` can batch together.

## Throughput Math

Assuming `raftNoSync=true` (BoltDB doesn't fsync):

```
Per raft.Apply() cycle:
  - JSON marshal MultiOp (~200KB):     ~1-2ms
  - BoltDB write (no fsync):           ~0.2ms
  - JSON unmarshal in FSM:             ~1-2ms
  - Pebble batch (640 jobs + 1280 events): ~0.5-1ms
  - Pebble batch.Commit (NoSync):      ~0.1ms
  - Result propagation:                ~0.1ms
  Total: ~3-5ms per batch of 640 jobs

Theoretical max: 640 / 4ms = 160,000 ops/sec
```

But the actual pipeline is serial:
```
  raft.Apply(4ms) → response propagation(0.5ms) → client receives + sends next(0.5ms) → applyLoop wait(0.5ms)
  Total cycle: ~5.5ms per round of 640 jobs
  = 640 / 5.5ms = ~116,000 ops/sec
```

**Measured: ~3,000 ops/sec → something is 40x slower than the theoretical calculation.**

## Root Cause Hypothesis

The gap between theoretical (~100k+) and measured (~3k) suggests one of:

1. **The bench measures latency, not throughput** — Each goroutine is serialized on `Exchange()`. The 10 goroutines don't fully overlap if the `applyLoop` serializes their batches. Effective concurrency may be much lower than 10.

2. **BoltDB write is slower than estimated** — Even with `NoSync`, BoltDB's B+tree operations on a 200KB+ payload may take 5-10ms+. BoltDB uses a single writer lock internally.

3. **The JSON payload is enormous** — A MultiOp containing 10 EnqueueBatchOps × 64 jobs each = ~200-400KB of JSON. Marshaling and unmarshaling this is expensive.

4. **Pebble batch with 1,920 KV writes** — 640 jobs × 3 keys each (job, pending, queue name) + 1,280 event writes = ~2,560 KV operations per batch. Even with NoSync, Pebble must process all these in the memtable.

5. **The `applyLoop` pipeline stalls** — While `raft.Apply()` is running (~5ms), no new batches can start. The 10 goroutines are all blocked waiting. When results return, all 10 send their next frame simultaneously, but the next batch can only start after the previous `raft.Apply()` finishes.

## Recommended Fixes (ordered by impact)

### Fix 1: Eliminate lifecycle events for enqueue path
Remove `appendLifecycleEvent` from `applyMultiEnqueue` and `applyMultiEnqueueBatch`. This removes **2 KV writes + 1 JSON marshal per job**. For 640 jobs, that's 1,280 fewer Pebble writes and 640 fewer `json.Marshal` calls.

```go
// In applyMultiEnqueueBatch, remove:
if err := f.appendLifecycleEvent(batch, "enqueued", job.JobID, job.Queue, job.NowNs); err != nil {
    return &store.OpResult{Err: err}
}
```

**Expected improvement: 1.5-2x**

### Fix 2: Switch to binary encoding for Raft log entries
Replace `encoding/json` with `encoding/gob`, MessagePack, or a custom binary format for the `Op` envelope and inner data. This eliminates the 7+ JSON passes per job.

For a quick win, at minimum avoid the double-wrapping: store pre-serialized `json.RawMessage` in the `Op.Data` field instead of re-marshaling.

**Expected improvement: 2-3x**

### Fix 3: Store job data as-is in Pebble (skip `jobToDoc` marshal)
The `EnqueueOp` already contains all job fields. Instead of creating a `store.Job` struct and marshaling it, store the `EnqueueOp` JSON directly (or a subset) as the Pebble value. This eliminates one `json.Marshal` per job in the FSM.

**Expected improvement: 1.2-1.5x**

### Fix 4: Tune applyLoop for this workload
For the WebSocket bench with 10 goroutines sending EnqueueBatch ops:
- Increase `ApplyBatchMinWait` to `1-2ms` to catch more items per batch
- Or decrease `ApplyBatchExtendAt` to `4` so even small batches extend the window

**Expected improvement: 1.2-1.5x**

### Fix 5: Pipeline raft.Apply with next batch collection
Currently `applyLoop` blocks on `flushApplyBatch()`. If we could start collecting the next batch while the current `raft.Apply()` is in flight, we'd eliminate the pipeline stall. This requires running `raft.Apply` in a separate goroutine and using a semaphore to limit concurrency.

```go
// Sketch:
go func() {
    res := c.applyBytes(multiBytes)
    // distribute results
}()
// immediately start collecting next batch
```

Note: hashicorp/raft serializes Apply calls internally, so multiple concurrent Apply calls would just queue up. But collecting the next batch while the previous is in flight would eliminate the gap between batches.

**Expected improvement: 1.5-2x**

### Fix 6: Avoid BoltDB entirely — use Pebble for Raft log store
BoltDB's single-writer lock and B+tree structure is suboptimal for append-only workloads. Pebble (or any LSM) is much faster for sequential writes. Consider using `raft-pebble` or implementing a Pebble-backed `raft.LogStore`.

**Expected improvement: 2-5x (eliminates BoltDB overhead entirely)**

### Fix 7: Write event cursor once per batch, not per job
In `appendLifecycleEvent`, the cursor is overwritten on every call. For a batch of N jobs, only the last write matters. Move the cursor write to after the loop.

**Expected improvement: minor, but reduces Pebble batch size**

## Combined Impact Estimate

| Fix | Improvement | Cumulative |
|-----|-------------|------------|
| Baseline | 3,000 ops/sec | 3,000 |
| #1 Remove lifecycle events | 1.5-2x | 5,000-6,000 |
| #2 Binary encoding | 2-3x | 12,000-15,000 |
| #5 Pipeline raft.Apply | 1.5x | 18,000-22,000 |
| #6 Pebble log store | 2x | 36,000-45,000 |

With all fixes: estimated **30,000-50,000 enqueue ops/sec** on a single node.
