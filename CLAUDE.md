# Corvo — Agent Instructions

Read docs/architecture.md before doing anything. Follow it exactly. For any work
touching the cluster write path, read docs/raft-wiring.md first.

## Critical Rules

1. **ONE write path.** Pipeline.executeBatch() in pipeline.zig. No second implementation anywhere.
2. **Pipeline is glue.** It orchestrates stages. Business logic goes in OpHandler
   (handler.zig + handler_*.zig). Protocol/JSON goes in http.zig/rpc.zig/http_read.zig.
   IO strategy goes in io/*.zig. Read-only queries go in kv_read.zig.
3. **No new abstractions.** Do not create wrapper structs, coordinator layers, or
   "helper" modules for the write path. The code is simple — keep it that way.
4. **TigerStyle.** This is the house style — non-negotiable:
   - `assert.check(...)` for internal invariants. Errors ONLY at boundaries
     (client data, network, disk, OS). Client-provided data is a boundary:
     validate and return errors, never assert on it.
   - NEVER swallow errors. `catch {}` / `catch return` / `catch continue` on
     anything that loses durable data, drops a mutation, desyncs an index, or
     hides an invariant violation is a bug. If a failure is genuinely tolerable,
     say why in a comment at the catch site.
   - Default build is ReleaseSafe — asserts are LIVE in production.
   - Explicit bounds on ALL collections; maintenance loops capped per tick.
     Back-pressure, not asserts, for load-driven limits an operator can hit.
   - Deterministic core: time and randomness injected (clock_fn required on
     Pipeline config). No wall-clock or unseeded RNG in core logic.
   - No allocation and no logging on the hot path. Exhaustive switches.
   - Simulator (src/sim/) is the primary test strategy. New failure modes get a
     sim scenario, and never weaken an invariant to make a test pass.
5. **Raft is THE cluster stack.** Leader/follower KV state must be byte-identical:
   every mutation flows record → commit → propose (webhooks and maintenance
   included). Divergence is fail-stop, never silent.
6. **Do only what you're asked.** No bonus refactors. No "while I'm here"
   improvements. No features that weren't requested.

## Build & Test

```bash
zig build                          # build (ReleaseSafe default — asserts live)
zig build test                     # unit tests
zig build sim                      # VOPR simulator (primary test suite)
zig build -Doptimize=ReleaseFast   # benchmarks ONLY (never zig build run)
```

## File Layout

- `src/pipeline.zig` — THE write path. Tick loop, batching, stage orchestration. Glue only.
- `src/handler.zig` + `src/handler_*.zig` — OpHandler. Pure business logic.
- `src/rpc.zig` + `src/rpc/*.zig` — binary protocol encode/decode.
- `src/http.zig`, `src/http_read.zig` — HTTP parsing/routing/responses.
- `src/io.zig` + `src/io/*.zig` — IO backends (uring, kqueue, sim). Sacred — do not modify for features.
- `src/kv.zig` — KV store interface (Talon). `src/kv_read.zig` — read-only queries.
- `src/raft_*.zig` — cluster stack (host, runtime, batcher, fsm, storage, net, codec, gate, transport).
- `src/indexer.zig`, `src/pending_index.zig` — derived indexes over the KV.
- `src/keys.zig` — KV key encoding. `src/codec.zig` — vtprotobuf job encoding.
- `src/sim/` — deterministic simulator (sim.zig single-node, cluster.zig raft).
- `src/assert.zig` — `check(...)`: panic with context on invariant violation.
