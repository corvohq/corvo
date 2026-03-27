# Pipeline Refactor v2 — Clean Restart

## Base Commit

`46e3f2d` — last commit before the epoll RPC rewrite. Thread-per-connection RPC. Sim works. Everything stable.

### Baseline Numbers (2026-03-25)

- **Enqueue:** 346,752 ops/sec
- **Lifecycle:** 83,902 ops/sec
- **Unit tests:** pass
- **Sim:** pass

## What Happened After (and why we're reverting)

Everything after `46e3f2d` was attempting to replace the old RPC server and HTTP server with a single-threaded pipeline. The goal was correct (TigerBeetle style: one thread, one event loop, two wire formats). The execution went sideways:

1. **Epoll rewrite (2a75521)** — Rewrote RPC from thread-per-connection to epoll event loop. Caused 444k→154k throughput regression because the event loop blocked on pipeline.submit().
2. **Async event loop attempt (3170d65→abf0e16)** — Tried SPSC rings between reactor and pipeline. Got enqueue to 207k but lifecycle regressed to 4.6k. Reverted.
3. **Pipeline rewrite (fb92332→46fd344)** — Rebuilt pipeline from scratch: generic over IoBackend, new RPC protocol module, tick loop. This was good work.
4. **Sim rewrite (a2e5ef4→92b0376)** — SimClient rewritten to use RPC-over-SimBackend. Good work but dependent on pipeline changes.
5. **HTTP stuffed into pipeline (f5035f7→10f6174)** — Deleted Engine/Store/server.zig. Ported ALL HTTP handling into pipeline.zig (~1500 lines). Pipeline became a god object. Sim hangs.

## Approach: Build Incrementally, No Cherry-Picks

Cherry-picking from the old branch failed — commits are too entangled, API mismatches cascade. Instead:

1. Start from `46e3f2d` where everything works
2. Build new functionality incrementally, one step at a time
3. Use old branch commits as *spec reference* — read them to know what to build, copy code when it fits
4. After EVERY change: `zig build test` passes, `zig build sim` passes, benchmark runs
5. Never leave the codebase in a broken state

## Reference Commits (spec, not cherry-pick)

Good work from the old branch to reimplement:

### Bug fixes
```
689d050  Fix wall clock bypass, TOCTOU long-poll race, pipeline leak
0c34c2d  Fix mirror/KV sync bugs, chain-on-failure
635c07e  Fix fairness enable bug
804f7ec  Fix mirror event loss, notifier crash
```

### Single-writer mirror
```
aa136e8  Add effect buffers to OpHandler for single-writer mirror
1d8ca36  Add mirror_events.zig — single-writer mirror event generation
b5fce9e  Wire mirror into apply loop (single-writer event generation)
4b0067d  Remove mirror write code from store/server
e99ca11  Remove enqueue_mu (single-writer, no lock needed)
9b9e1f9  mirror_events: handle approval policy ops
b733790  Sim mirror invariant check, fix 7 bugs
```

### Sim cluster
```
40303f2  Sim cluster config fields
7576c71  SimNode — full production stack per cluster node
e52e4b9  Replication consistency invariant
515f04f  retargetLeader with safe waiter cleanup
933bab7  Cluster — orchestrates N SimNodes
1591c18  Unify sim.zig for single-node and multi-node
```

### IO + Pipeline (the core rewrite)
```
b5ce697  IO abstraction: io.zig + io/uring.zig + io/kqueue.zig
6f0d0e0  RPC protocol module: constants, frame types, parse/encode
be7983f  Pipeline: single-threaded tick loop (781 lines, before HTTP bloat)
32e411f  Pipeline generic over IoBackend
9c262ed  RPC lifecycle split into rpc/lifecycle.zig
d57aaa1  RPC management message types
732af0a  RPC bulk, batch, cron message types
46fd344  Pipeline handles all RPC message types
a2e5ef4  SimBackend, Pipeline.initHeap
92b0376  SimClient rewritten for RPC-over-SimBackend
```

### Standalone features
```
7c53612  JsonWriter — zero-alloc fixed-buffer JSON writer
341e8dd  corvo-inspect CLI for reading KV data
ac0f8e1  Align UI with Zig backend rewrite (richer HTTP responses)
2668e68  Extract testable Client from CLI, add integration tests
6273fb5  HTTP endpoint tests + stress test extraction
de9adef  Dockerfile
1a40aea  CI/release workflows
```

## Architecture: What to Build Fresh

### Delete (same as before, correct decision)
- `engine.zig` — Pipeline replaces it
- `store.zig` — Pipeline replaces it
- `server.zig` + `server/*.zig` — Pipeline's IO layer replaces the HTTP framework

### New Modules

**`src/io.zig` + `src/io/uring.zig` + `src/io/kqueue.zig` + `src/io/sim.zig`**
Platform IO abstraction. One thread, one event loop. Accepts connections, manages recv/send buffers. Protocol-agnostic.

**`src/pipeline.zig`**
THE write path. Generic over IoBackend. Tick loop:
```
io.drain() → completions
decode(completions) → RequestDesc[]     // dispatches to rpc or http decoder
executeBatch(requests)                  // apply + commit
record(requests)                       // oplog.append
replicate(requests)                    // PBR
emitMirrorOps(requests)                // SQLite read cache
encodeResponses(requests)              // dispatches to rpc or http encoder
fulfillSubscriptions(requests)         // wake waiting fetch connections
io.submit()                            // one syscall
```

Pipeline is glue. No JSON, no SQL, no protocol details. ~300 lines.

**`src/rpc.zig` + `src/rpc/*.zig`**
Binary protocol encode/decode. Split by domain: lifecycle, management, bulk, batch, cron. Pure functions, zero IO.

**`src/http.zig`**
HTTP parser, route matching, response framing. Decode: parse HTTP request → RequestDesc (for writes) or dispatch to http_read (for reads). Encode: RequestDesc result → JSON HTTP response.

**`src/http_read.zig`**
Read-only HTTP handlers. Query SQLite mirror, build JSON, return response bytes. Pure functions taking (send_buf, reader) → response length. No IO, no pipeline. Called from decode stage for read routes — bypasses the batch entirely.

**`src/sse.zig`**
Server-sent events. Pipeline emits events to a ring after commit. SSE module pushes to subscribed connections via IO.

### Key Rules
- Pipeline is glue — no logic, no SQL, no JSON
- One write path: executeBatch()
- HTTP reads bypass the batch (they're just SQLite queries)
- HTTP writes produce the same RequestDesc as RPC
- Maintenance produces RequestDesc entries, flows through executeBatch (not a second write path)
- Sim calls pipeline.tick() and gets identical behavior to production

## Progress

### Step 1: IO abstraction — DONE (commit 58fc624)
`src/io.zig` + `src/io/uring.zig` + `src/io/kqueue.zig` + `src/io/sim.zig`

### Step 2: RPC protocol module — DONE (commit 58fc624)
`src/rpc.zig` rewritten as pure protocol + `src/rpc/lifecycle.zig`, `management.zig`, `bulk.zig`, `batch.zig`, `cron.zig`.

### Step 3: Pipeline v2 — DONE (commit c5ed20c)
`src/pipeline_v2.zig` — built ALONGSIDE old stack (old engine/store/server/sim untouched).
Generic over IoBackend. ~625 lines implementation. All RPC message types.
Tick loop: drain → extractFrames → executeBatch → encodeResponses → submit.
6 SimBackend tests: ping, enqueue, multi-frame, fetch+payload, partial frame, compaction.

### Step 4: Sim rewrite — DONE (commit 2ec5fbf)
SimClient over SimBackend, exercising pipeline_v2 directly.

### Step 5: HTTP layer — DONE
- `src/json_writer.zig` — zero-alloc fixed-buffer JSON writer (from git history 7c53612)
- `src/http.zig` — HTTP parser, route classification, JSON decode/encode. Protocol detection
  (`isHttpByte`), read dispatch to http_read, write decode (enqueue/fetch/ack/fail/heartbeat),
  response encoding. Pure functions, no IO.
- `src/http_read.zig` — read-only HTTP handlers (SQLite mirror queries). Fixed to match current structs.
- `src/io.zig` — added `Protocol` enum (unknown/rpc/http) to `ConnState`
- `src/pipeline_v2.zig` — protocol detection on first byte, `extractHttpFrames` delegates reads
  to http_read (bypasses batch), writes produce FrameDescs. `decodeAndApplyHttp` for JSON→OpData.
  HTTP enqueue generates server-side job_ids deterministically.
- 5 HTTP integration tests: GET info, 404, POST enqueue, mixed protocol, incomplete request.
- Write routes supported: enqueue, fetch, ack, fail, heartbeat.
- Write routes deferred: bulk actions, queue config, cron CRUD, budgets, approval policies, API keys.

### Step 6: Mirror events — DONE (commit eafb5b1)
handler effect buffers, mirror_events.zig, pipeline emitMirrorOp/mirrorEffects.

### Step 7: Wire into real uring backend — DONE
- `src/main_v2.zig` — new entry point: listen socket, IO backend, signal handling, tick loop.
- `build.zig` — `corvo-v2` executable, `zig build run-v2` step.
- Fixed partial-frame deadlock: `requeueRecvs()` re-queues recv for connections
  with incomplete frames (no send pending → no send_done → recv never re-queued).
- Removed redundant `queueAccept()` from pipeline tick (uring backend handles internally).
- SDK bench verified:
  - **Enqueue: 317k ops/sec** (baseline 346k at 46e3f2d — 92%)
  - **Lifecycle: 228k ops/sec** at 4 workers (baseline 83k — 2.7x faster)
  - Lifecycle at 64 workers degrades to 8k due to bench contention (empty fetch → 1ms sleep).

### Step 8: Fetch subscriptions (bidi push) — NEXT
Without this, idle workers spin-poll KV on every fetch. With 20k workers that melts
the pipeline. All SDKs use subscribe+push model.

ConnState already has the plumbing: `waiting`, `credits`, `queue_bufs`, `worker_id_buf`.
- Fetch returns 0 jobs → store subscription in ConnState (`waiting=true`, queues, credits)
- Don't send a response yet — connection stays open
- When enqueue/ack/fail/maintenance makes jobs available → `notifyForFrame` already fires
- Pipeline scans waiting connections for matching queues → fetches jobs → pushes
  `MSG_FETCH_BATCH_RESP` to subscribed connections
- Zero-cost idle workers. No KV polling.

Old HTTP server used thread-blocking long-poll (`waiter.thread.wait`). Old RPC server
never implemented bidi push. Pipeline_v2 does it properly: event-driven, single-threaded,
no threads blocked.

Sim impact: SimClient.processResponse must tolerate no response for fetch (response
arrives on a later tick when enqueue pushes jobs). Small tweak, not a rewrite.

### Step 9: Maintenance scheduling — DONE
Timer-based maintenance in the tick loop. `runMaintenance()` checks clock_fn each tick,
runs due actions (promote, reclaim, unique, rate_limit, expire, purge) in a separate
kv.Batch committed before client frames. Separate batch avoids WriteBatch conflicts
(reclaim + ack on same job would double-decrement active counts if batched together).

Config: intervals in Pipeline.Config (nanoseconds, 0=disabled). Production defaults
in main_v2.zig match old scheduler.zig intervals. Sim gets pipeline-internal maintenance;
sim clients no longer send maintenance frames (maintenance_rate=0).

Bug fix: RPC parser (lifecycle.zig) now sets `state = .scheduled` when `scheduled_at_ns > 0`.
Old server.zig did this; the v2 RPC parser missed it, so scheduled jobs went straight to
pending and promote was always a no-op.

Bug fix: TestContext heap-allocated (create/destroy) — was ~7MB on the stack, segfaulted
the test runner's thread.

Promote/reclaim notify_queues: handler_maintenance.zig now tracks which queues had jobs
promoted via `recordPromoteQueue()`, returns them in `OpResult.notify_queues`. Pipeline
uses this to fulfill fetch subscriptions after maintenance.

### Step 10: Remaining HTTP write routes — DONE
All HTTP write routes wired through pipeline_v2. Added to `classifyRoute`:
- Bulk actions: POST /jobs/bulk, POST /jobs/{id}/{action}, DELETE /jobs/{id}
- Queue config: POST /queues/{name}/{pause,resume,concurrency,throttle,fairness,clear,drain},
  DELETE /queues/{name}[/{throttle,fairness}], DELETE /queues/{name}
- Batch: POST /batch, POST /batch/{id}/seal
- Cron: POST /cron-jobs, PUT /cron-jobs/{id}, DELETE /cron-jobs/{id},
  POST /cron-jobs/{id}/{pause,resume,trigger}
- Budgets: POST /budgets, DELETE /budgets/{scope}/{target}
- Approval policies: POST /approval-policies, DELETE /approval-policies/{id}
- API keys: POST /auth/keys, DELETE /auth/keys

Added `sub_action` to RouteAction.write and FrameDesc for URL-embedded actions.
Added JSON decode functions for all new op types in http.zig.
Added `extractJSONBool`, `extractJSONFloat` helpers.
New MSG_* constants in rpc.zig: SET_BUDGET, DELETE_BUDGET, MODIFY_ENT_SETTING.
Extended `notifyForFrame` to propagate `notify_queues` from any op (was only
handling enqueue/ack/fail/maintenance — bulk requeue, queue resume, etc. now
properly wake fetch subscribers).
9 new unit tests. 279/283 pass (same 4 old-stack failures).

Known gap: HTTP enqueue doesn't trigger notifyForFrame because the payload
is JSON but notifyForFrame re-parses as RPC binary. Pre-existing issue —
HTTP fetch doesn't use subscriptions anyway (request-response, no push).
Fix in step 14 (consistency audit).

### Step 11: Oplog recording — DONE (commit 4dc59e1)
Pipeline_v2 records mutations via WriteBatch.enableRecording, encodes post-commit,
appends to oplog. ReplHook vtable on Config for cluster replication callback.
main_v2 wired to file-backed oplog at `{data-dir}/oplog`.

Also fixed lifecycle stall: SDK client was sending header+payload as two TCP writes.
With TCP_NODELAY each became a separate TCP segment → server io_uring recv completed
on 9-byte header alone → partial frame → extra tick per message. Fixed in zig-sdk:
all methods build header+payload contiguously, single writeAll. io_uring drain()
optimized to peek CQEs first, then submit_and_wait(1) in single syscall.

Bench (ReleaseFast, concurrency=8): enqueue 633k ops/sec, lifecycle 79k ops/sec.

### Step 12: Cluster replication + sim cluster merge — DONE
**ReplHook at module level** — moved out of generic `Pipeline(Backend)` so cluster.zig
can reference it without knowing the backend type. Module-level `pipeline_v2.ReplHook`.

**Sync replication** — pipeline_v2 defers client responses until follower ack arrives.
Single atomic `last_acked_seq` shared between TCP receive thread and pipeline tick.
TigerBeetle style: one batch at a time, don't process new frames while waiting for ack.
When `sync_replication=true` and repl_hook is set: executeBatch → recordOplog → replicate,
then check atomic. If ack already arrived (fast-path), encode immediately. Otherwise defer
frames/results until next tick where ack is observed. During wait: drain IO (close/send_done)
but skip new client frames.

**cluster.zig updated** — imports pipeline_v2.ReplHook, uses g_ack_seq_ptr atomic for
TCP fast-path ack notification. Legacy compat methods (replHookLegacy, leaseCheck,
g_pipeline_for_ack) kept for old main.zig, removed in step 16.

**main_v2.zig cluster mode** — `--node-id`, `--peers id@host:port,...`, `--sync-repl`.
Creates ClusterNode, starts transport, wires replHook into pipeline config, wires
g_ack_seq_ptr for TCP ack fast-path. Cluster transport binds on server port + 1000.

**sim/cluster.zig** — cluster sim with Pipeline(SimBackend) on the leader. Each node:
Talon DB, OpHandler, Oplog, QueueNotifier, Election, InMemTransport. Leader runs full
pipeline (RPC frames → decode → execute → oplog → replicate). Followers apply replicated
KV mutations via follower.step(). Replication consistency checked mid-sim and at end.
3 tests: 3-node basic, 3-node multi-queue, 5-node. All pass.

**Bug fix: fulfillSubscriptions oplog recording** — fetch subscription fulfillment
(push model) was writing to KV without recording mutations to the oplog. Worker
registration (`w|`) and active count (`a|`) keys were invisible to replication.
Fixed by enabling mutation recording in fulfillSubscriptions' kv.Batch.

**Bug fix: mutation recording with repl_hook but no file** — pipeline only recorded
mutations when `oplog.hasFile()`. In cluster sim (no file, in-memory oplog), mutations
were never recorded. Fixed: record when `hasFile() or repl_hook != null`.

### Step 13: Memory allocation audit (TigerStyle) — DONE
All collections have explicit resource limits — no unbounded growth.

**Oplog ring buffer**: `oplog.entries` ArrayList replaced with bounded ring buffer.
`max_entries` parameter at init (default 8192 for production, 1024 for sim/tests).
Oldest entries evicted on overflow. `readAfter` returns contiguous slice clamped at
ring wrap boundary — callers loop naturally. Recovery caps at max_entries (older
file entries evicted during scan). New tests: ring wrap, eviction, recovery capping.

**Payload / buffer alignment**: `MAX_PAYLOAD_SIZE` fixed from 4MiB to 256KiB.
`--max-payload-size` CLI arg on main_v2 (default 256KB). Buffer sizes derived:
`recv_buf_size = send_buf_size = max_payload_size + FRAME_HEADER_SIZE + 1024`.
Pipeline Config has `max_payload_size` field, used in frame extraction check.

**Handler resource limits**: `max_queues` (default 100) and `max_tags_per_queue`
(default 1000) on OpHandler. Enforced at:
- `applyEnqueue`: new queue auto-creation → error if at limit
- `applyQueueConfig`: new queue config → error if at limit
- `putQueueConfig`: cache insertion → returns false if at limit
- `incrFairnessActive/Served`: new tag → saturates (skips) if at limit

**Already bounded (verified)**:
- `pipeline.mut_list` — cleared each tick, capacity stabilizes (bounded by batch_max)
- `handler.active_counts` — bounded by queue count (max_queues)
- `handler.pending` — bounded by job count (data set, not a memory issue)
- `notify.QueueNotifier.waiters` — bounded by max_conns × queue count
- All connection buffers — fixed-size (recv_buf, send_buf) ✓
- All per-tick arrays — compile-time sized (frames, completions, etc.) ✓

### Step 14: SDK verification — DONE (570d8dd)
All 5 SDKs verified against pipeline_v2. Results: go 18/18, python 6/6,
typescript 6/6, rust 5/5, haskell 4/4.

**Bugs fixed (570d8dd):**
- HTTP fetch response: flat `{"job_id","payload",...}` matching old server format.
  Payload/checkpoint/tags loaded from KV via `*kv.Store` passed to http.zig.
- HTTP keep-alive: (a) compactRecvBufs missing from early-return path when frame_count==0
  (HTTP reads record compactions but early return skipped applying them — second request
  on same connection got stale data). (b) send_done: check recv_pos > 0 before queueRecv
  (pipelined data already in buffer needs processing this tick, not next recv).
- JSON whitespace: extractJSONString/extractJSONStringArray now handle spaces after `:`.
- Priority string parsing: "high"=75, "critical"=100, "low"=25 in http.zig.
- Search route: `/jobs/search` checked before `/jobs/{param}` wildcard in http_read.zig.
- Batch enqueue: `/enqueue` handles both single and `{"jobs":[...]}` format. JSON array
  parsing in http.zig decodeEnqueueBatch (not pipeline). Response `{"job_ids":[...]}`.
- Mirror flushAll before HTTP read dispatch (matches old server's flushMirror).
- Rust SDK: two-write TCP bug — contiguous frame buffer, single write_all.

**SDK endpoint consolidation:**
- Removed /enqueue/batch (all 5 SDKs updated to use /enqueue)
- Removed /fetch/batch (unused by any SDK)

**Build:**
- preferred_optimize_mode=.ReleaseSafe — prevents 25GB Debug-mode spikes from `zig build run-v2`.
  Use `-Drelease` for release builds, `-Doptimize=ReleaseFast` no longer works (Zig 0.15 API change).

**Earlier (e8c5e5b, 7ca92c7):**
- zig-sdk + bench-rpc verified. sync-repl deferred recv, lease_token check, bench-rpc protocol.
- Sync-repl cluster fix: oplog re-send in production cluster tick.
- Memory stability: 1.8GB stable after 7.2M ops (ReleaseSafe, default max-conns=4096).

### Step 15: RPC & HTTP consistency audit — DONE
Systematic audit of all operations comparing old server.zig against pipeline_v2's
HTTP decode (http.zig) and response encoding. All discrepancies identified and fixed.

**Field parsing fixes (http.zig):**
- `scheduled_at` now accepts RFC3339 strings (was `scheduled_at_ns` integer — broken for
  all HTTP SDKs). Added `parseRfc3339Ns()` ported from server.zig.
- `ack_status` field parsed on ack (`"hold"` sets `.hold` status)
- `chain_config` and `chain` (object) parsed on enqueue, auto-sets chain_id = job_id
- `hostname` parsed on fetch requests
- Enqueue defaults match old server: max_retries=3, backoff=exponential,
  base_delay_ms=5000, max_delay_ms=600000 (were all 0)
- `decodeSingleJob` (batch enqueue) now parses all fields: parent_id, chain_id,
  chain_step, chain_config, expire_after_ms, retry_backoff, retry delays

**Route consolidation:**
- `POST /ack` added — handles single `{"job_id":"..."}` and batch
  `{"acks":[...]}` / `{"job_ids":[...]}`. Response: `{"status":"ok"}` for single,
  `{"acked":N}` for batch. SDKs to be updated from /ack/batch.
- Replay route intentionally skipped (no SDK uses it, UI doesn't have it)

**New routes added:**
- `POST /webhooks/{queue}` — enqueue via webhook, body = payload, query params
  for priority/unique_key/max_retries/scheduled_at (RFC3339)
- `OPTIONS *` — CORS preflight with Access-Control-Allow-Methods/Headers/Max-Age
- `GET /healthz` — returns `{"status":"ok"}`
- `POST /jobs/bulk-get` — get multiple jobs by ID, max 100
- `GET /auth/status` — returns `{"admin_password_set":false}`
- `GET /cluster/events`, `GET /metrics/throughput` — stub responses
- `GET /events` — SSE stub (needs pipeline-level streaming, deferred)

**Response format fixes:**
- Heartbeat returns per-job status map: `{"jobs":{"id":{"status":"ok|cancel"}}}`
  with KV lookup per job (zero-alloc via getInto)

**Middleware:**
- Auth: extracts X-API-Key / Authorization: Bearer from HTTP headers, SHA256 hash
  → SQLite lookup. Role-based: readonly can only GET. Skips /healthz, /auth/status,
  /metrics. When no API keys configured, auth is disabled.
- Payload size validation: returns 413 for bodies exceeding config.max_payload_size
  (error return, not assert — external input boundary)
- CORS: Access-Control-Allow-Origin: * on all responses, full preflight on OPTIONS

**Intentionally deferred:**
- Rate limiting (needs token bucket module, production hardening)
- SSE streaming (needs pipeline-level connection tracking)
- Throughput metrics (needs throughput ring buffer)

All tests pass. Sim passes. No regressions.

### Step 16: Configuration file + cluster config consensus — DONE

**`src/config.zig`** — ServerConfig struct with all server parameters. Simple
key=value file parser (`--config <path>`). Load order: defaults → file → CLI args.
`clusterHash()` computes FNV-1a over shared params that must match across nodes.
`validate()` checks invariants (payload size, cluster peer requirements).

**Config file format**: `key = value`, `#` comments, blank lines. Unknown keys
are errors (catch typos). Supported keys: bind, port, data-dir, mirror, max-conns,
max-payload-size, max-queues, max-tags-per-queue, promote-interval, reclaim-interval,
unique-interval, rate-limit-interval, expire-interval, purge-interval,
sync-replication, node-id, peers.

**Cluster config consensus**: Election messages now carry `config_hash` (u64).
Added to `Election.Message`, `ElectionMsg` transport struct, and TCP wire format
(election frame: 19 → 27 bytes). Validation in election state machine:
- `handlePropose`: config hash mismatch → reject vote without advancing epoch
- `handleHeartbeat`: config hash mismatch → ignore (don't extend lease)
- All outgoing messages include sender's config_hash

**Shared params** (included in hash): max_payload_size, max_queues,
max_tags_per_queue, all maintenance intervals, sync_replication.
**Node-local** (excluded): bind, port, data_dir, mirror, max_conns, node_id, peers.

**main_v2.zig** refactored: uses ServerConfig, two-pass CLI parsing (find --config
first, load file, then apply all CLI overrides). Added --help. Maintenance intervals
now configurable (were hardcoded). Config hash passed to ClusterNode.

All tests pass. Sim passes. 13 new tests (config + election).

### Step 17: Reference commit functionality audit — IN PROGRESS

Audited all reference commits against v2. IO+Pipeline (10 commits): all present.
Sim cluster (6 commits): all present (different architecture, Pipeline_v2-based).

**Correctness fixes applied (step 17a):**
- PendingIndex pop budget: `@max(remaining * 2, 64)` in handler_fetch.zig
- Mirror effect ordering: `emitMirrorOp` now drains handler effects BEFORE
  the primary op's mirror event, preventing insert-after-update races
- Mirror per-job effects for maintenance: promote, reclaim, expire, purge all
  record BulkResults instead of relying on bulk SQL. Single path through mirrorEffects.
- Side effect guards: `recordSideEffect` only called when `applyEnqueue` succeeds
  (prevents phantom mirror rows from failed unique/batch constraints)
- Mirror SQL fixes: CAST(col AS INTEGER) for timestamp comparisons (4 functions),
  `AND state = 'active'` on ack SQL, expire uses `state = 'pending'` (not active),
  clearQueueJobs filters by state (pending/scheduled/retrying only)
- Sim mirror invariant: in-memory Mirror passed to pipeline, `checkMirrorSync`
  verifies every KV job has matching state in SQLite mirror
- max_bulk_results increased to 4096 (purge can delete hundreds per tick)

**Step 17b complete (2026-03-27):**
- Deep replication consistency: `checkReplicationConsistency` in sim/cluster.zig now
  compares every key-value pair byte-for-byte between leader and each follower in
  lockstep iteration. Detects key mismatches, value corruption, and extra keys on
  either side. Diagnostic output prints exact key names on mismatch.
- HTTP response enrichment: job detail now includes `retry_backoff`, `retry_base_delay_ms`,
  `retry_max_delay_ms`, `progress`, `expire_at`, and `payload` (from job_payloads table).
  Queue list includes `held` count and `oldest_pending_at`. Metrics include held state.
- `src/inspect.zig` + build target: corvo-inspect CLI for reading KV data. Commands:
  get, scan, job, count. Auto-decodes all known key prefixes (jobs, queues, workers,
  crons, batches, budgets).
- `src/cli.zig` wired into corvo-v2 binary: first non-flag arg dispatches to CLI
  (enqueue, inspect, search, queues, cron CRUD, etc.). Testable Client struct,
  pure HTTP, no corvo module dependencies beyond std.
- Pipeline `initHeap`/`destroyHeap`: struct is ~5MB (inline scratch buffers), must
  be heap-allocated. TigerBeetle pattern — one alloc at startup, zero on hot path.
- Dockerfile: multi-stage build (Debian bookworm + Zig 0.15.2). Copies corvo-v2,
  corvo-inspect. Supports amd64/arm64 via TARGETARCH.
- CI/release workflows: `.github/workflows/ci.yml` (build + test + sim + docker smoke),
  `.github/workflows/release.yml` (4-platform matrix build, GitHub Release, Docker push).

### Step 18: Delete old stack, rename v2 → corvo — DONE (commit 9f2d2ca)

**Deleted (11 files, ~10,700 lines):**
- engine.zig, store.zig, server.zig, pipeline.zig (old), scheduler.zig, main.zig (old)
- rpc_uring.zig, poller.zig, request_metrics.zig, rate_limiter.zig, bench.zig

**Renamed:** pipeline_v2→pipeline, main_v2→main, corvo-v2→corvo (build targets,
Dockerfile, CI/release workflows).

**Cleaned up:**
- root.zig: removed all old exports + test refs, removed ui_mod dependency
- rpc.zig: removed legacy RpcServer + 5 process* handler functions
- cluster.zig: removed replHookLegacy, leaseCheck, g_pipeline_for_ack
- build.zig: single `corvo` server target, single `bench-rpc` bench target

**Bug fix:** Maintenance bulk_results overflow. Purge/reclaim/expire loops now cap at
max_bulk_results per tick. Previously, purging 200k+ expired jobs in one tick overflowed
the 4096-entry buffer (assert panic). Remaining work is done on subsequent ticks.

**Results:** 203/203 tests pass, sim passes.

**Benchmarks (ReleaseFast, 8 conns, batch-64, 200k jobs):**

| Config | Enqueue (ops/sec) | Lifecycle (ops/sec) |
|--------|------------------|---------------------|
| 1-node | 478k | 245k |
| 3-node async repl | 420k | 181k |
| 3-node sync repl | 6.9k (50k jobs) | 5.0k (50k jobs) |

Sync repl uses adaptive batch coalescing (commit c88338c): pipeline accumulates frames for
up to 200µs (`coalesce_window_ns`) before executing when batch is not full. Under high load
the batch fills instantly (zero extra latency). Coalescing disabled for non-sync modes.

| Config | Enqueue | Lifecycle | Notes |
|--------|---------|-----------|-------|
| 1-node | 559k | 253k | baseline |
| 3-node async | 420k | 181k | ~12% overhead |
| 3-node sync | 15.9k | 9.8k | RTT-bound, 2.3x vs pre-coalescing |

Further sync-repl optimization: pipelined acks (allow N batches in-flight).

## Verification

After each step:
- `zig build test` — all unit tests pass (203/203 after old stack deletion)
- `zig build sim` — simulator passes
- Benchmark: enqueue ≥ 340k ops/sec, lifecycle ≥ 80k ops/sec (single-node)
  - `zig build --release=fast` then run `./zig-out/bin/corvo` + `./zig-out/bin/bench-rpc`
