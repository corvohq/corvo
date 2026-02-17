# Corvo Performance Knowledge

## Lessons learned from benchmarking and optimization sessions.

## Key Architecture Decisions for Performance

### Group-Commit Batching (`cluster.go:applyLoop`)
Multiple operations from different goroutines are batched into a single Raft log entry. The timer-based window (100us min, 2ms max, extends at 32 ops, caps at 128 ops) amortizes Raft consensus cost. This is the single biggest throughput multiplier.

### CB1 Binary Codec (`raft_binary_codec.go`)
Hand-written binary encoding for hot-path ops (`OpFetchBatch`, `OpAckBatch`) instead of JSON/protobuf. Pre-decodes into typed structs at FSM apply time — no JSON re-parsing. Significant improvement over the previous protobuf codec.

### preResolveFetch (`cluster.go`)
Expensive Pebble iterator scans for candidate jobs run on the **caller goroutine** (outside the serial FSM goroutine). The FSM then uses O(1) point lookups (`batch.Get`) for the pre-resolved candidates. This unblocks the FSM from iterator-heavy fetch operations.

### HasPendingJobs In-Memory Cache (`cluster.go`)
`sync.Map` of `queue → {hasPending, deadline}`. Avoids expensive Pebble scans on every fetch.
- After enqueue: `InvalidatePendingCache()` → `hasPending=true`, TTL=500ms
- After empty fetch: `MarkQueueEmpty()` → `hasPending=false`, TTL=50ms
- Cache miss/expired → assume pending (false positives are cheap)

In multi-raft, this check happens BEFORE shard Raft apply — empty shards are skipped entirely.

### applyMultiIndexed (`fsm.go`)
Single `pebble.IndexedBatch` for mixed ops. Sorts: acks first, fetches second. Acks free concurrency slots visible to subsequent fetches in the same batch. One Pebble commit for everything.

### Append Log with Cursor (`qa|` keys)
Normal-priority jobs use FIFO append log instead of the priority-indexed `p|` prefix. Cursor-based scan (`qac|` key) skips already-consumed entries. Much faster than scanning through the priority index for the common case.

## Known Issues and Gotchas

### Append Log Cursor-Skip Race (Multi-Raft)
**Problem:** Client-side `CreatedAt` timestamps (captured BEFORE Raft submission in `store.EnqueueBatch`) are used for `QueueAppendKey` ordering. Concurrent producers can have out-of-order timestamps relative to Raft apply order. When the cursor advances past a late-arriving enqueue with an earlier timestamp, that job is stranded behind the cursor.

**Fix:** Cursor+fallback approach. `findAppendJobForQueue` first scans after cursor, then if nothing found, rescans `[prefix, cursor)` for stranded entries.

**Caveat:** The fallback only triggers when the after-cursor scan finds ZERO entries. During high-concurrency combined workloads, there are usually entries after the cursor, so the fallback doesn't fire while stranded entries exist. This means a small number of jobs may have delayed fetch (until the queue drains enough for the fallback to trigger). Single-raft is not affected.

**Rejected alternative:** Removing cursor entirely. Catches all stranded entries but scans through tombstones from deleted append keys — drops throughput from ~77k to ~35k ops/sec.

### Bench `completed` vs `completedN`
The combined bench output shows `completed: N` where N = `latIdx` (latency recordings), NOT `completedN` (total completions including ack-miss drops). The gap (~6% typically) is jobs that went through the ack-miss retry path — they were fully processed server-side but didn't record latency in the bench. Check `acked: M` line for true completion count.

### Ack-Miss in Combined Bench
The bench worker assumes acks are processed in FIFO order. When the server processes acks out-of-order (due to batching), `resp.Acked < len(ackIDs)`. After 3 consecutive misses, the bench drops the job (calls `markCompleted` without recording latency). This is a bench bookkeeping artifact, not a server bug.

### Parallel Ack+Fetch in StreamLifecycle
Commit `b1967ba` parallelized ack and fetch Apply calls in the stream handler. Both fire concurrently via goroutines and may land in the same Raft batch window. `applyMultiIndexed` sorts acks before fetches so freed slots are visible. This is correct but can interact with the HasPendingJobs cache — an ack may free a slot that a concurrent fetch doesn't see because the cache still says "empty".

### SQLite Mirror Under Load
At very high throughput (>100k ops/sec), the synchronous SQLite mirror adds significant FSM latency. Disabling it (`--sqlite-mirror=false`) in benchmarks removes this bottleneck. In production, use async mode or accept the latency cost for query capability.

### Tombstone Accumulation
Deleted Pebble keys (append log entries after fetch) leave tombstones until compaction. Under sustained high-throughput workloads, scanning through tombstones is expensive. The cursor mechanism avoids this, but the fallback scan (before cursor) traverses them.

## Tuning for Maximum Throughput

### Server Flags
```bash
bin/corvo server \
  --raft-store badger \           # usually fastest for Raft log
  --raft-shards 4 \               # parallelize writes across shards
  --sqlite-mirror=false \          # remove SQLite overhead (no search/dashboard)
  --durable=false \                # no fsync (default, use Raft for durability)
  --stream-max-fps 0 \             # remove per-stream rate limit
  --idle-fetch-sleep 10ms \        # faster job pickup
  --apply-multi-mode indexed \     # single commit for mixed ops
  --snapshot-threshold 1000000 \   # avoid snapshot storms during bench
  --raft-max-pending 32768         # allow deeper apply queue
```

### Bench Flags
```bash
bin/corvo bench \
  --protocol rpc \                 # ConnectRPC streaming (fastest)
  --jobs 100000 \
  --concurrency 16 \
  --workers 4 \
  --enqueue-batch-size 64 \
  --fetch-batch-size 64 \
  --ack-batch-size 64 \
  --combined                       # concurrent enqueue+fetch+ack
```

### Tuning for Lower Latency
- `--idle-fetch-sleep 10ms` (default 100ms)
- `--fetch-poll-interval 10ms` (default 100ms)
- `--stream-max-fps 0` (remove rate limit)
- `--apply-multi-mode indexed` (single commit)

## Performance Numbers (Reference)

From `docs/BENCHMARKS.md`, Intel i7-11850H, Linux, NVMe, badger, non-durable:

| Benchmark | ops/sec | p99 |
|-----------|---------|-----|
| Unary enqueue (c=10) | 22,096 | 1.58ms |
| Lifecycle fetch+ack (c=10) | 36,452 | 29.5ms |
| Large batch enqueue (bs=1000, c=10) | 220,879 | - |
| Stream lifecycle (optimized) | ~214,000 | - |

Combined mode (concurrent enqueue+fetch+ack) with cursor+fallback: ~65-80k ops/sec e2e.

## Profiling

```bash
# CPU profile during bench
./scripts/bench-profile.sh

# Or manually:
curl -o cpu.prof "http://localhost:8080/debug/pprof/profile?seconds=30"
go tool pprof -http=:8081 cpu.prof

# Heap
curl -o heap.prof "http://localhost:8080/debug/pprof/heap"

# Server runtime stats (used by bench to measure CPU/RSS)
curl http://localhost:8080/api/v1/debug/runtime
```

## What NOT to Optimize

- **HasPendingJobs with Pebble scans:** We tried this and it was a bottleneck. The pure in-memory cache with TTLs is the right approach.
- **Removing the cursor entirely:** Scanning from `iter.First()` every time traverses tombstones and drops throughput significantly.
- **Synchronous SQLite for benchmarks:** Disable it (`--sqlite-mirror=false`) when measuring pure throughput.
- **Individual Raft applies:** Always use batched mode (`grouped` or `indexed`). The `individual` mode exists only for debugging.
