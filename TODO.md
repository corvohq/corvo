# TODO

## UI End-to-End Tests

- [x] Run UI e2e tests against pipeline v2 — 61 Playwright tests passing (pages, actions, state transitions, bulk ops, payload, dark mode, API edge cases)
- [x] State-conditional button tests — pending/cancelled/scheduled show correct buttons
- [x] Job action route tests — DELETE/CANCEL/REQUEUE/PROMOTE return 200
- [x] Confirm dialog tests — Cancel/Delete handle browser confirm
- [x] Timestamp formatting test — time elements render relative, not raw ISO
- [x] State change verification — pause flips badge to "Paused", cancel changes state to "cancelled", promote changes to "pending", delete removes job
- [x] Error toast content — verify error message from server appears in toast
- [x] Bulk action end-to-end — click Cancel All / Delete All, verify jobs change state
- [x] Job detail with payload — enqueue with payload, verify payload section renders with Copy button
- [x] Requeued job shows parent link — requeue a cancelled job, verify "Requeued From" link on new job
- [x] Dark mode toggle — click toggle, verify `dark` class on `<html>`
- [x] API edge cases — requeue on pending returns no-op, delete on active fails, cancel on completed is no-op

## Server

- [x] Mirror rebuild on overflow — when ring buffer drops ops, `needs_rebuild` flag triggers full KV→SQLite rebuild on next `flushAll()`. Scans all entity prefixes (j|, jp|, qc|, w|, sc|, b|, bg|) and restores complete mirror state. Metrics endpoint exposes rebuild count.
- [x] Rate limiting — sliding window per-queue (existing) + global (`POST /api/v1/throttle`) + enterprise namespace (`POST /api/v1/namespaces/{ns}/throttle`), queue namespace assignment (`POST /api/v1/queues/{name}/namespace`), cleanup cutoff fix
- [x] **KV-only reads — eliminate SQLite mirror** — `kv_read.zig` reads directly from Talon KV via prefix scans. New read indexes (jt|, jq|, js|, jqs|, tq|). Queue stats via counters in qc| codec. SQLite dependency removed entirely. Tag search replaces FTS5.
- [x] **Tag search** — `tq|{queue}\x00{tag_key}\x00{tag_value}\x00{job_id}` index, queue-first for locality. `searchByTag()` with queue+state filtering. HTTP endpoint `GET /api/v1/jobs/search-by-tag`. UI tag search on queue detail page. Payload search kept as API-only (`searchPayload`). Dead wrappers removed.
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

- [x] API documentation — endpoint reference, RPC protocol spec, SDK usage guides
- [x] Getting started guide — install, run, enqueue/fetch/ack walkthrough
- [x] Update `../site` — Zig rewrite, new architecture, updated benchmarks (pipelined prepares, sync-repl scaling)
- [x] Configuration reference — all CLI flags, config file keys, maintenance intervals

## Server

- [x] Admin password auth — `--admin-password` flag, UI login form + session cookie, HTTP Bearer auth. Bootstrap key: locks system, then create scoped API keys. Layers: no auth (dev) → admin password (simple) → API keys (roles).
- [x] Enterprise naming removed — `EntSetting` → `Setting`, `handler_ent.zig` → `handler_settings.zig`, `MSG_MODIFY_ENT_SETTING` → `MSG_MODIFY_SETTING`, `prefix_ent_*` → `prefix_*`. Dead features stripped: namespaces, roles, SSO, approval policies.
- [x] API keys e2e tests — 9 Playwright tests: page rendering, form toggle, CRUD (create shows one-time key, table row, delete). Auth infrastructure: server runs with `--admin-password`, session cookie storageState, Bearer auth on all fetch calls.

## Server

- [ ] `--max-jobs` flag — explicit resource limit on total job count. Handler rejects enqueue when `total_jobs >= max_jobs` (boundary error, not assert). Same pattern as max_queues/max_namespaces. Enables Corvo Cloud tiered plans.

## V1 Release

- [ ] SDK publishing — git init + publish for all SDK repos
- [ ] Dockerfile + CI/release workflows verified end-to-end

## Scoped API Keys

- [x] API key generation — random key, SHA256 hash as KV key, JSON value with name/role/enabled/key_hash/created_at_ns
- [x] Role enforcement — admin (full), producer (enqueue/batch), worker (fetch/ack/fail/heartbeat). authorizeWrite in http.zig.
- [x] KV read stubs fixed — apiKeyFromValue parses JSON, getApiKeyByHash returns populated ApiKeyRow
- [x] API keys UI — JS fetch for create/delete, one-time key display, role descriptions
- [x] Admin password required for key creation, delete allowed without (escape hatch)
- [x] API keys e2e tests — 9 Playwright tests covering page, form, CRUD lifecycle

## Webhooks

- [x] Webhook registration — POST /api/v1/webhooks, KV-backed, URL + events (job.completed, job.failed, job.dead)
- [x] Webhook dispatch — fire-and-forget HTTP POST on job state transitions via io_uring outbound TCP connect
- [x] Webhooks UI page — zigstache template, CRUD, nav link
- [x] Webhooks e2e tests — Playwright (page rendering, CRUD, API)

## Audit Log

Management operations only — cancel, delete, pause, promote, requeue, queue create/modify, rate limit changes, key create/delete. Not enqueue/fetch/ack. Logged with API key name or "admin". Console enriches with user identity.

- [ ] Audit entries in KV (`audit|{ts}_{seq}`) — key, operation, target (queue/job), count, timestamp
- [ ] GET /api/v1/audit-logs — paginated read endpoint with time range filter
- [ ] UI page — audit log viewer

## TigerStyle Audit (last)

- [x] Loop bounds — all 32 `while(true)` loops verified bounded (iterators, counters, break conditions)
- [x] Exhaustive switches — 10 `else =>` catch-alls replaced with explicit enum variants across handler_bulk.zig, handler.zig, tcp_transport.zig, sim/invariants.zig, pipeline.zig
- [x] Assertion coverage — 6 missing assertions added: heartbeat parallel slice precondition, fetch array bounds (normal + fairness), fairness candidate bounds, counter overflow/underflow
- [x] Resource limit enforcement — 10 collection bounds assertions across handler.zig (max_queues on active_counts/fairness maps, max_namespaces on ns_rate_limits), pending_index.zig, notify.zig, replicator.zig (max_waiters), election.zig (max_peers)
- [x] Dead code — none found (all pub fns, consts, imports actively used)
- [ ] Dead code cleanup — `rpc.zig` exports, unused helpers, stale function signatures across codebase (audit found nothing, but worth a manual pass)

## Cancellable Jobs

- [x] **Server**: Cancel signal push via `MSG_CANCEL_SIGNAL` (0x08). Handler records worker_id before transition, pipeline scans waiting_conns to push signal to worker's connection. Bulk cancel also notifies queue (frees concurrency slot for waiting subscribers). Pipeline overrides RPC bulk action `now_ns` with server clock.
- [x] **SDK cancel signal handling**: All 6 SDKs handle CANCEL_SIGNAL in message loop (Zig, Go, Python, TypeScript, Rust, Haskell).

## V2

- [ ] SSE streaming (`/events`) — pipeline-level connection tracking, push job lifecycle events to subscribers. Was planned for mirror-lag workaround; unnecessary now that reads go direct to KV. Revisit for API consumers who want push notifications.
