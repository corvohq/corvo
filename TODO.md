# TODO

## UI End-to-End Tests

- [ ] Run UI e2e tests against pipeline v2 — verify dashboard works with all HTTP read/write endpoints

## Server

- [x] Mirror rebuild on overflow — when ring buffer drops ops, `needs_rebuild` flag triggers full KV→SQLite rebuild on next `flushAll()`. Scans all entity prefixes (j|, jp|, qc|, w|, sc|, b|, bg|) and restores complete mirror state. Metrics endpoint exposes rebuild count.
- [x] Rate limiting — sliding window per-queue (existing) + global (`POST /api/v1/throttle`) + enterprise namespace (`POST /api/v1/namespaces/{ns}/throttle`), queue namespace assignment (`POST /api/v1/queues/{name}/namespace`), cleanup cutoff fix
- [x] **KV-only reads — eliminate SQLite mirror** — `kv_read.zig` reads directly from Talon KV via prefix scans. New read indexes (jt|, jq|, js|, jqs|, ti|). Queue stats via counters in qc| codec. SQLite dependency removed entirely. Tag search replaces FTS5.
- [ ] SSE streaming (`/events`) — pipeline-level connection tracking, push events to subscribers (currently returns error stub)
- [ ] Throughput metrics (`/metrics/throughput`) — ring buffer for ops/sec (currently returns zeroes)
- [ ] Cluster events (`/cluster/events`) — real event stream (currently returns empty array)
- [x] Purge: limit-based trigger — `purge_threshold` config (default 10k); handler tracks `dead_since_purge`, pipeline triggers early purge when exceeded
- [x] Explicit `--cluster-port` flag — overrides default (server port + 1000); peer spec port is now the cluster transport port directly

## Persistent Fetch Subscriptions (credits)

- [ ] **Server**: Keep subscription alive after fulfillment — decrement credits by jobs pushed instead of clearing. If credits remain, keep connection in waiting list. Only remove when credits reach 0.
  - Change in `pipeline.zig` `fulfillSubscriptions()` lines 1355-1364: replace `c.waiting = false; c.credits = 0;` with `c.credits -= result.affected; if (c.credits == 0) { clear + remove }`.
  - Eliminates subscribe-per-batch round-trip. One subscribe per connection lifetime.
  - Client sends credits via fetch frame, server pushes until credits exhausted.
  - Client acks don't need to replenish credits — client re-subscribes with new credits when ready for more.
- [ ] **Zig SDK** (`~/dev/corvohq/zig-sdk`): Update `subscribe()` + `readPushedJobs()` to send high credits once, read multiple pushes without re-subscribing.
- [ ] **Go SDK** (`~/dev/corvohq/go-sdk`): Same pattern — subscribe with high credits, persistent connection.
- [ ] **Python SDK** (`~/dev/corvohq/python-sdk`): Same.
- [ ] **TypeScript SDK** (`~/dev/corvohq/typescript-sdk`): Same.
- [ ] **Rust SDK** (`~/dev/corvohq/rust-sdk`): Same.
- [ ] **Haskell SDK** (`~/dev/corvohq/haskell-sdk`): Same.
- [ ] **Bench tool**: Update `rpcLifecycleWorker` to subscribe once with high credits, remove re-subscribe loop.

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

## Cancellable Jobs

- [ ] Cancellable jobs — allow in-flight active jobs to be cancelled. Worker receives cancel signal via heartbeat response or dedicated channel, transitions job to cancelled state. Requires cancel token propagation + SDK support.
