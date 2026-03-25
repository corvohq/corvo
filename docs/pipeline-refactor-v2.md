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

### Step 6: Mirror events — NEXT

### Step 7: Wire into real uring backend
Add listen socket. Enables SDK bench (`../zig-sdk`).

### Step 8: Delete old stack
Remove engine.zig, store.zig, server.zig, pipeline.zig.

## Verification

After each step:
- `zig build test` — all unit tests pass
- `zig build sim` — simulator passes
- Benchmark: enqueue ≥ 340k ops/sec, lifecycle ≥ 80k ops/sec
  - SDK bench (`../zig-sdk`) cannot run until step 7 (memory leak in old server at 46e3f2d)
  - Benchmark targets still apply once pipeline_v2 has a network listener
