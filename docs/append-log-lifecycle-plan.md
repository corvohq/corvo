# Append-Only + Lifecycle Streaming Plan

## Goal
Shift Jobbie from per-operation state-machine mutation toward a log-first architecture with batched worker lifecycle interactions, while preserving existing rich queue features.

## Performance Targets
- Enqueue: 20k+ ops/sec on local single-node durable defaults
- Lifecycle (fetch -> ack/fail): 5k+ ops/sec with batched worker interactions
- Preserve correctness for retries, uniqueness, scheduling, batches, rate limits, and failover

## Constraints
- Clustered deployment remains first-class
- Durability boundary remains Raft log commit
- Maintain current HTTP/Connect APIs during migration

## Phases

### Phase 1: Event Log Foundation (in progress)
- Add append-only lifecycle event journal in Pebble with monotonic sequence
- Persist event sequence cursor in Pebble metadata
- Begin dual-write in FSM (current state mutation + event append)
- Start with enqueue/fetch/ack/fail paths

Deliverables:
- Event keyspace + event schema
- FSM helper to append events in same Pebble batch as state writes
- Non-breaking behavior parity tests

### Phase 2: Batched Lifecycle RPC
- Add Connect streaming endpoint for worker lifecycle frames
- Frame supports batched fetch intents, ack/fail, heartbeat/checkpoint updates
- Server coalesces frame operations into grouped Raft commits

Deliverables:
- New worker stream API + typed Go client support
- Bench mode using stream path
- Backpressure and max-frame controls

### Phase 3: Log-Driven Projection
- Introduce projector that consumes append-only events and updates query/read models
- Move SQLite materialized-view updates to projector ownership
- Keep deterministic replay + bootstrap rebuild from snapshots/log

Deliverables:
- Projector component
- Replay/rebuild tooling
- Consistency checkpoints + lag metrics

### Phase 4: Hot-Path Simplification
- Reduce synchronous FSM mutation to only scheduling-critical indexes
- Shift non-critical feature accounting to projection/events
- Minimize JSON encode/decode overhead in hot operations

Deliverables:
- Reduced write amplification in FSM
- Measurable p99 latency reduction

### Phase 5: API and Feature Cutover
- Flip worker path defaults to streaming lifecycle
- Keep HTTP/JSON fallback compatibility
- Validate rich feature parity against regression suite

Deliverables:
- Feature parity test matrix
- Migration docs

## Correctness Guardrails
- Every committed Raft op must map to deterministic event entries
- Event sequence strictly monotonic per node state machine
- Snapshot/restore preserves event cursor and event replay integrity
- No read-after-write regressions for synchronous API contracts unless explicitly documented

## Benchmark Gates Per Phase
- Phase 1: no regression >10% vs current defaults
- Phase 2: 2x lifecycle throughput improvement target
- Phase 3: maintain throughput while reducing sync SQLite cost
- Phase 4/5: hit target envelope (20k+ enqueue, 5k+ lifecycle)

## Immediate Next Steps
1. Implement Phase 1 event journal keyspace + FSM append helpers
2. Wire enqueue/fetch/ack/fail event emission
3. Add event-journal tests and rerun benchmark baseline
