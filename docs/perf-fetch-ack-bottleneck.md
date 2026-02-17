# Performance Analysis: Fetch+Ack Throughput Bottleneck

## Current State (2026-02-16)

| Metric | Enqueue | Fetch+Ack (lifecycle) |
|--------|---------|----------------------|
| ops/s | ~100-136k | ~39-40k |
| p99 | ~15ms | ~260ms |
| Server CPU | ~8% | ~9% |

Config: workers=32, concurrency=2, worker-queues, fetch-batch=64, ack-batch=64, badger raft store, indexed multi-mode, sqlite-mirror=false, durable=false.

## Key Finding: The Server Is Not CPU-Bound

CPU profile (30s capture during lifecycle bench):
- **Total CPU utilization: 19.5%** (5.86s samples in 30s)
- The server is mostly **idle/waiting**, not doing compute

The bottleneck is **pipeline latency** in the `applyLoop` -> `applyExecLoop` -> Raft -> FSM chain, not CPU per operation.

## Where CPU Time Goes (When It's Working)

### FSM goroutine: 56% of all CPU (3.28s / 5.86s)

```
runFSM                         3.28s  56.0%   (single goroutine, serial)
  applyMultiIndexed            1.93s  32.9%   (indexed batch path)
    applyFetchBatchIntoBatch   1.14s  19.5%   (fetch claim logic)
    applyAckBatchIntoBatch     0.44s   7.5%   (ack logic)
  applyExpireJobsOp            0.37s   6.3%   (scheduler - competes for FSM!)
  applyEnqueueBatchOp          0.33s   5.6%   (leftover enqueue phase)
  applyReclaimOp               0.25s   4.3%   (scheduler lease reclaim)
```

Scheduler ops (`applyExpireJobsOp` + `applyReclaimOp`) consume **10.6% of FSM CPU** during bench, competing with fetch+ack for the serial goroutine.

### Pebble operations

```
Iterator.First               1.20s  20.5%   (iterator scans - still happening!)
Batch.Get                    0.81s  13.8%   (point lookups for job docs)
Batch.Commit / DB.Apply      0.60s  10.2%   (write path)
decodeJobDoc (protobuf)      0.42s   7.2%   (deserialize job)
encodeJobDoc (protobuf)      0.40s   6.8%   (serialize job)
```

`Iterator.First` at 20.5% means iterator scans are still running despite pre-resolve. Sources: the indexed batch fallback path (`findPendingOrAppendJobFromReader`), scheduler expire/reclaim, and `preResolveFetch` itself.

### Pre-resolve + reservation overhead

```
preResolveFetch              0.28s   4.8%   (parallel, on stream goroutines)
sync.Map.LoadOrStore         0.06s   1.0%   (fetchReserved CAS)
sync.Map.Delete              0.06s   1.0%   (reservation cleanup)
```

Pre-resolve is cheap relative to the FSM work.

### Protobuf / Raft encoding

```
MarshalMulti                 0.23s   3.9%   (encoding ops for Raft log)
DecodeRaftOp                 0.13s   2.2%   (decoding in FSM)
MarshalOp                    0.19s   3.2%   (single op encoding)
```

~10% of CPU on protobuf serialization for the Raft log.

### RPC / HTTP overhead

```
StreamLifecycle              0.57s   9.7%   (stream handler total)
ConnectRPC marshal/unmarshal ~0.12s  2.0%
HTTP/2 framing               0.07s   1.2%
```

Minimal.

## Why Fetch+Ack Is 3x Slower Than Enqueue

### 1. More Pebble work per job

| Operation | Reads | Writes | Encode | Decode |
|-----------|-------|--------|--------|--------|
| Enqueue | 0 | 2-3 | 1 | 0 |
| Fetch | 1 | 5-6 | 1 | 1 |
| Ack | 1 | 2-3 | 1 | 1 |
| **Lifecycle total** | **2** | **7-9** | **2** | **2** |

Each lifecycle'd job does ~3x the Pebble I/O of an enqueue.

### 2. Two serial Raft round-trips per stream frame

The stream handler (`server.go`) processes ack and fetch **sequentially**:

```go
// Blocks until ack Raft apply completes
acked, err := s.store.AckBatch(acks)
// Only starts AFTER ack is done
jobs, err := s.store.FetchBatch(fetchReq, n)
```

Each Apply goes through: `applyCh` -> batch timer wait -> Raft commit -> FSM -> response. A lifecycle frame requires 2 of these round-trips vs 1 for enqueue.

### 3. The pipeline is latency-bound, not CPU-bound

At 19.5% CPU utilization, the server has plenty of compute headroom. The throughput is gated by:
- **Batch timer wait** (100us - 8ms window in `applyLoop`)
- **Raft commit latency** (~1ms single-node)
- **`applyExec` channel depth** (capacity 4, serial processing)

The formula: `throughput = batch_size / (batch_wait + raft_commit + fsm_time)`

With small batches (low per-queue concurrency), the batch timer dominates.

### 4. Scheduler competes for the serial FSM goroutine

`applyExpireJobsOp` and `applyReclaimOp` from the background scheduler consume 10.6% of FSM time during bench. These are iterator-heavy operations that block the FSM from processing fetch+ack batches.

### 5. Shards don't help

Tested with 1, 3, and 6 Raft shards — lifecycle throughput stays flat at ~38-40k. This confirms the bottleneck is not FSM compute time but the pipeline/batching overhead.

## Potential Improvements

### Parallel ack+fetch in stream handler
Fire both `AckBatch` and `FetchBatch` into `applyCh` concurrently. Both would land in the same Raft batch and complete in 1 round-trip instead of 2. The indexed mode already sorts acks before fetches within a batch.

### Reduce batch timer for lifecycle workloads
The adaptive timer (`chooseWait`) starts at 100us and extends to 8ms. With 2 streams per queue, batches are small and the timer wait is wasted. A lower floor or smarter backpressure-driven flushing could help.

### Skip scheduler during bench / deprioritize scheduler ops
The scheduler's expire+reclaim ops consume 10.6% of FSM time and use iterators. During high-throughput bursts, scheduler ops could be deferred or rate-limited to avoid competing with the hot path.

### Reduce per-job Pebble writes in FSM
- **RateLimitKey**: written for every fetched job even when no rate limit is configured. Could skip when queue has no rate limit.
- **Worker key**: `json.Marshal(worker)` + `batch.Set(WorkerKey)` on every fetch op. Could deduplicate within a batch (same worker ID written N times).

### Reduce protobuf overhead
`MarshalMulti` + `MarshalOp` + `DecodeRaftOp` = ~10% CPU. Could use a more efficient encoding or reduce the data serialized through the Raft log (e.g., don't send full job payload through Raft for fetches).

## Reproduction

```bash
# Profile a lifecycle bench run:
make bench-profile

# Or manually:
scripts/bench-profile.sh
```

See `scripts/bench-profile.sh` for the full profiling workflow.
