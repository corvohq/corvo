# TODO

## UI End-to-End Tests

- [ ] Run UI e2e tests against pipeline v2 — verify dashboard works with all HTTP read/write endpoints

## Server

- [x] Mirror rebuild on overflow — when ring buffer drops ops, `needs_rebuild` flag triggers full KV→SQLite rebuild on next `flushAll()`. Scans all entity prefixes (j|, jp|, qc|, w|, sc|, b|, bg|) and restores complete mirror state. Metrics endpoint exposes rebuild count.
- [x] Rate limiting — sliding window per-queue (existing) + global (`POST /api/v1/throttle`) + enterprise namespace (`POST /api/v1/namespaces/{ns}/throttle`), queue namespace assignment (`POST /api/v1/queues/{name}/namespace`), cleanup cutoff fix
- [ ] **KV-only reads — eliminate SQLite mirror** — rewrite `http_read.zig` + `sqlite_read.zig` to read directly from Talon KV via prefix scans. Removes mirror buffer, rebuild-on-overflow, SQLite dependency for reads. Keeps SQLite only for FTS5 search (optional). Pagination via cursor-based key seek.
- [ ] SSE streaming (`/events`) — pipeline-level connection tracking, push events to subscribers (currently returns error stub)
- [ ] Throughput metrics (`/metrics/throughput`) — ring buffer for ops/sec (currently returns zeroes)
- [ ] Cluster events (`/cluster/events`) — real event stream (currently returns empty array)
- [x] Purge: limit-based trigger — `purge_threshold` config (default 10k); handler tracks `dead_since_purge`, pipeline triggers early purge when exceeded
- [x] Explicit `--cluster-port` flag — overrides default (server port + 1000); peer spec port is now the cluster transport port directly

## bench-rpc

- [ ] Add `--mode` flag — allow running enqueue-only or lifecycle-only phases

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
