# Phase 2 — Platform Hardening + AI Foundations

This plan combines the current distributed core in `docs/DESIGN.md` with the AI roadmap in `docs/AI.md`.

## Outcome

By the end of Phase 2, Jobbie should be:
- Fast by default (`--durable=false`) with stable tail latency under load
- Operationally safe (clear durability behavior, deterministic recovery paths)
- Ready for AI workloads (usage/cost tracking, budgets, held jobs, first agent-loop primitives)

## Non-Negotiable Performance Constraint

Performance is a hard requirement for all Phase 2 work.

- [ ] No major default-path throughput regression is acceptable for new features.
- [ ] Any feature that risks hot-path slowdown must be:
  - async/off-path, or
  - opt-in and disabled by default, or
  - backed by benchmark evidence showing negligible impact.
- [ ] Every Phase 2 milestone must pass benchmark gates before merge.

## Scope Boundaries

In scope:
- Reliability, recovery, and operability hardening of Raft + Pebble + SQLite mirror
- Throughput/tail-latency improvements on enqueue + lifecycle paths
- AI Phase 2a features from `docs/AI.md`

Out of scope:
- Full workflow/DAG orchestration
- Full eval platform
- Multi-tenant/cloud billing (later phase)

## Track A — Reliability + Durability

Files: `internal/raft/*`, `internal/server/*`, `cmd/jobbie/main.go`, `docs/DESIGN.md`

- [x] Deterministic pre-snapshot recovery:
  - On startup without snapshot, ensure FSM local state cannot replay on top of stale Pebble
  - Add regression test coverage for no-snapshot recovery guard
- [x] Snapshot policy hardening:
  - Trigger first snapshot after meaningful apply index (not empty snapshot)
  - Tune threshold/interval defaults for faster safe checkpoints
- [x] SQLite mirror safety net:
  - Add admin endpoint to rebuild SQLite from Pebble
  - Add mirror lag / dropped-update counters
- [x] Durability UX:
  - Keep `pebbleNoSync=true` default
  - `--durable` controls only Raft fsync behavior
  - Improve docs/CLI wording and status endpoints to make risk explicit

Exit criteria:
- Crash/restart tests pass for with/without snapshot cases
- `--durable` mode behavior is explicit in `/cluster/status`, CLI help, and docs

## Track B — Performance + Tail Latency

Files: `internal/raft/cluster.go`, `internal/store/*`, `internal/rpcconnect/*`, `cmd/bench/main.go`, `docs/BENCHMARKS.md`

- [x] Finish protobuf-first hot path:
  - [x] Remove remaining JSON marshalling in enqueue/lifecycle apply path where possible
  - [x] Keep Connect JSON as debug fallback only
- [x] Admission and fairness:
  - Simplify apply admission to bounded pending queue (`ApplyMaxPending`) + overload retry hints
  - Add per-queue fetch permit limits (`ApplyMaxFetchQueueInFly`) to contain fetch storms
  - Keep overload signaling (`429` / `ResourceExhausted`) with retry hints
- [x] Fetch-path protocol/runtime scaling:
  - Increased server HTTP/2 `MaxConcurrentStreams` for high worker counts
  - Bench now supports pooled RPC clients and worker/queue topology shaping (`-workers`, `-worker-queues`)
- [x] Long-poll fetch alignment:
  - Added long-poll behavior to HTTP `fetch/batch`
  - Added long-poll behavior to Connect RPC `Fetch`, `FetchBatch`, and stream lifecycle fetch leg
- [ ] Batch control tuning:
  - [x] Validate adaptive wait + sub-batch split settings under c10/c50/c100/c200
  - [ ] Reduce c200 p99 spikes without sacrificing c10 throughput
- [ ] Bench stability:
  - [x] Fix RPC stream EOF churn in high-concurrency lifecycle benchmark runs
  - [ ] Make bench output aggregate overloads/errors instead of spam

Benchmark gates:
- [ ] Unary enqueue (`rpc`, batch=1): >=20k ops/sec at c10 in fast mode
- [ ] Lifecycle (`rpc`): >=4k ops/sec at c10 in fast mode
- [ ] No unbounded p99 blow-up at c200 (documented envelope and overload behavior)
- [ ] Feature-on vs feature-off delta on hot path remains within agreed budget (target: <=10% unless explicitly approved)

## Track C — AI Foundations (AI.md Phase 2a)

Files: `docs/AI.md`, `internal/store/*`, `internal/server/*`, `pkg/client/*`, `cmd/jobbie/*`, UI files

- [ ] Usage accounting:
  - [x] `job_usage` storage + usage reporting via ack/heartbeat
  - [x] Usage summary API (`GET /api/v1/usage/summary`)
  - [x] Usage summary CLI (`jobbie usage`)
- [ ] Budget enforcement:
  - Budget table + checks on fetch/ack paths
  - Queue/namespace/per-job budget APIs + CLI (`jobbie budget`)
- [ ] Human-in-the-loop baseline:
  - `held` state and approve/reject API
  - CLI (`jobbie held`, `jobbie approve`, `jobbie reject`)
  - UI held-jobs view

Exit criteria:
- AI usage and budget limits are enforced server-side (not client best effort)
- Held-job flow works end-to-end with audit trail

## Track D — Agent Loop Starter (AI.md Phase 2b, reduced slice)

Files: `internal/store/*`, `internal/server/*`, `pkg/client/*`, UI files

- [ ] Minimal agent fields on enqueue (`agent` config)
- [ ] Ack handling for `agent_status` (`continue`, `done`, `hold`)
- [ ] `job_iterations` table and iteration counter
- [ ] Guardrails:
  - max iterations
  - max cost
- [ ] Replay baseline:
  - replay from iteration endpoint + CLI

Exit criteria:
- One iterative agent workload can run safely with enforced server guardrails

## Delivery Sequence

1. Reliability hardening (Track A)  
2. Performance stabilization (Track B)  
3. AI foundations (Track C)  
4. Agent loop starter slice (Track D)

## Validation Cadence

- [x] Weekly benchmark run and update `docs/BENCHMARKS.md`
- [x] Regression suite on every durability/perf change: `go test ./... -count=1`
- [x] Add targeted chaos test cases for restart/recovery and overload pressure
- [ ] For each AI/platform feature PR: include before/after bench snippet for c10 and c50 unary enqueue + lifecycle

## Recent Progress Notes

- [x] Worker client stream hardening:
  - Removed global HTTP client timeout for long-lived lifecycle streams
  - Added HTTP/2 keepalive/read-idle transport settings
  - Serialized lifecycle stream `Exchange`/`Close` to avoid client-side race/EOF churn
- [x] FSM typed decode expansion:
  - Protobuf decode now dispatches directly to typed handlers for heartbeat/retry/cancel/move/delete/queue-control/promote/reclaim/bulk/cleanup ops
  - Removed JSON bridge conversion in protobuf dispatch path (`applyTypedViaJSON`)
- [x] Overload pressure regression coverage:
  - Added `internal/raft/cluster_test.go` burst test to assert overload errors include retry hints under constrained admission
- [x] Restart/recovery chaos coverage:
  - Added `internal/raft/cluster_test.go` restart tests for no-snapshot log replay recovery and post-snapshot recovery
- [x] Backpressure model simplification:
  - Removed complex per-key/global admission counters from the hot path
  - Kept bounded apply queue backpressure and queue-scoped fetch permits
- [x] AI usage accounting foundation:
  - Added `job_usage` migration + summary query path in store
  - Wired usage payloads through HTTP and Connect ack/ack-batch/heartbeat APIs
  - Added protobuf usage fields and dual-mode compatibility via regenerated RPC stubs
