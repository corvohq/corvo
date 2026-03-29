# TODO

## UI End-to-End Tests

- [x] Run UI e2e tests against pipeline v2 — 40 Playwright tests passing (pages, actions, filters, exports, HTMX refresh, API endpoints)

## Server

- [x] Mirror rebuild on overflow — when ring buffer drops ops, `needs_rebuild` flag triggers full KV→SQLite rebuild on next `flushAll()`. Scans all entity prefixes (j|, jp|, qc|, w|, sc|, b|, bg|) and restores complete mirror state. Metrics endpoint exposes rebuild count.
- [x] Rate limiting — sliding window per-queue (existing) + global (`POST /api/v1/throttle`) + enterprise namespace (`POST /api/v1/namespaces/{ns}/throttle`), queue namespace assignment (`POST /api/v1/queues/{name}/namespace`), cleanup cutoff fix
- [x] **KV-only reads — eliminate SQLite mirror** — `kv_read.zig` reads directly from Talon KV via prefix scans. New read indexes (jt|, jq|, js|, jqs|, ti|). Queue stats via counters in qc| codec. SQLite dependency removed entirely. Tag search replaces FTS5.
- [x] Throughput metrics (`/metrics/throughput`) — rolling 60-second window, per-second ops/sec for enqueued/completed/failed
- [x] Cluster events (`/cluster/events`) — ring buffer of last 64 state transitions (leader elected, stepped down, follower started, snapshots)
- [x] Cluster Prometheus metrics — `corvo_cluster_state`, `corvo_cluster_epoch`, `corvo_cluster_lease_valid`, `corvo_cluster_peers_total` on `/metrics`
- [x] Purge: limit-based trigger — `purge_threshold` config (default 10k); handler tracks `dead_since_purge`, pipeline triggers early purge when exceeded
- [x] Explicit `--cluster-port` flag — overrides default (server port + 1000); peer spec port is now the cluster transport port directly

## Persistent Fetch Subscriptions (prefetch)

- [x] **Server**: Permanent subscriptions with prefetch flow control. Worker subscribes once with prefetch=N, server pushes up to N jobs, acks replenish prefetch. Partition round-robin for fair distribution. 37k lifecycle/sec 4+4, 73k 1+1.
- [x] **Bench tool**: Message loop handles interleaved FETCH_RESP/ACK_RESP, subscribe once with prefetch=batch_size.
- [x] **Zig SDK** (`~/dev/corvohq/zig-sdk`): `readFrame()` message loop dispatches FETCH_RESP/ACK_RESP/FAIL_RESP/CANCEL_SIGNAL. `sendAck()`/`sendFail()` fire-and-forget. `cancel()` via bulk action.
- [x] **Go SDK** (`~/dev/corvohq/go-sdk`): `ReadFrame()` dispatches FETCH_RESP/ACK_RESP/FAIL_RESP/CANCEL_SIGNAL. `SendAck()`/`SendFail()` fire-and-forget. `Cancel()` via bulk action.
- [x] **Python SDK** (`~/dev/corvohq/python-sdk`): `read_frame()` returns typed dicts. `send_ack()`/`send_fail()` fire-and-forget. `cancel()` via bulk action.
- [x] **TypeScript SDK** (`~/dev/corvohq/typescript-sdk`): `readFrame()` returns discriminated union. `sendAck()`/`sendFail()` fire-and-forget. `cancel()` via bulk action. processFrames routes all non-pending frames to push queue.
- [x] **Rust SDK** (`~/dev/corvohq/rust-sdk`): `read_frame()` returns `Frame` enum. `send_ack()`/`send_fail()` fire-and-forget. `cancel()` via bulk action.
- [x] **Haskell SDK** (`~/dev/corvohq/haskell-sdk`): `readFrame` returns `Frame` ADT. `sendAck`/`sendFail` fire-and-forget. `cancel` via bulk action.

## bench (saturation benchmark)

- [x] Server-side latency metrics — delivery (enqueue→fetch) + e2e (enqueue→ack) histograms, per-queue + system-wide, Prometheus /metrics
- [x] Combined mode — producers + consumers simultaneously, server-side latency from /metrics
- [x] Throughput mode — sequential enqueue then lifecycle phases
- [ ] Scale mode — needs testing with persistent subscriptions (currently slow due to re-subscribe overhead)
- [ ] HTTP combined mode — currently RPC only for combined (HTTP fetch is request-response, not subscribe)

## Docs & Site

- [ ] API documentation — endpoint reference, RPC protocol spec, SDK usage guides
- [ ] Getting started guide — install, run, enqueue/fetch/ack walkthrough
- [ ] Update `../site` — Zig rewrite, new architecture, updated benchmarks (pipelined prepares, sync-repl scaling)
- [ ] Configuration reference — all CLI flags, config file keys, maintenance intervals

## V1 Release

- [ ] SDK publishing — git init + publish for all SDK repos
- [ ] Dockerfile + CI/release workflows verified end-to-end

## TigerStyle Audit (last)

- [ ] Full audit — memory allocation audit done (step 13), but need to check: infinite loops (all while loops bounded?), exhaustive switches, assertion coverage, resource limit enforcement, no unbounded retries
- [ ] Dead code cleanup — `rpc.zig` exports, unused helpers, stale function signatures across codebase

## Cancellable Jobs

- [x] **Server**: Cancel signal push via `MSG_CANCEL_SIGNAL` (0x08). Handler records worker_id before transition, pipeline scans waiting_conns to push signal to worker's connection. Bulk cancel also notifies queue (frees concurrency slot for waiting subscribers). Pipeline overrides RPC bulk action `now_ns` with server clock.
- [x] **SDK cancel signal handling**: All 6 SDKs handle CANCEL_SIGNAL in message loop (Zig, Go, Python, TypeScript, Rust, Haskell).

## V2

- [ ] SSE streaming (`/events`) — pipeline-level connection tracking, push job lifecycle events to subscribers. Was planned for mirror-lag workaround; unnecessary now that reads go direct to KV. Revisit for API consumers who want push notifications.
