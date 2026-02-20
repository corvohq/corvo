# Corvo Architecture

This document describes how Corvo works internally: storage model, execution model, replication, and failure behavior.

It is intended for engineers evaluating Corvo for production use.

---

# Design Goals

Corvo’s architecture is optimized for:

- predictable execution
- minimal infrastructure
- operational simplicity
- correctness under failure
- horizontal scaling

The system intentionally trades raw peak throughput for deterministic behavior and reliability guarantees.

---

# System Overview

Corvo is a distributed job system implemented as a deterministic state machine replicated via Raft.

Each node runs:

- API server
- scheduler
- storage engine
- worker coordinator
- cluster member

There are no external dependencies.

---

# High-Level Architecture

```
Clients → HTTP / Streaming API → Corvo Node
                                   ↓
                              Raft Consensus
                                   ↓
                              Pebble Storage
                                   ↓
                         SQLite Read Model
```

---

# Component Breakdown

## API Layer
Handles:

- enqueue
- fetch
- ack
- fail
- queries
- admin operations

All write operations go through Raft.

Read operations may be served locally.

---

## Scheduler
Runs on every node but is **leader-authoritative**.

Responsible for:

- promoting scheduled jobs
- reclaiming expired leases
- expiring TTL jobs
- enforcing guardrails
- evaluating approval policies

Scheduler ticks every second.

### Scheduling Latency

Scheduled and retrying jobs are promoted to pending by polling, not event-driven timers.

| Parameter | Default |
|-----------|---------|
| Promote interval | 1s |
| Max defer under load | 10s |

This means:

- A scheduled job becomes eligible up to **~1s** after its `scheduled_at` time
- Under heavy load, promotion may be deferred up to **~10s** to avoid competing with the enqueue/fetch hot path
- Timestamps are stored with nanosecond precision internally (for key ordering), but the effective resolution is 1 second

If your workload requires sub-second scheduling precision, Corvo is not the right fit today.

---

## Storage Model

Corvo uses a hybrid storage design.

---

### Pebble — Source of Truth

Pebble stores:

- job state
- queues
- leases
- metadata
- logs

Why Pebble:

- high write throughput
- pure Go (no CGO)
- deterministic iteration order
- embedded

Pebble is the authoritative state.

---

### SQLite — Query Layer

SQLite stores a materialized view optimized for queries:

- search
- filtering
- dashboard views
- reporting

SQLite can be rebuilt from Pebble at any time.

This separation allows:

> fast writes + rich queries

without compromising either.

---

## Replication Model

Corvo uses **hashicorp/raft** for consensus.

Properties:

- quorum writes required
- linearizable state transitions
- deterministic FSM
- leader-based ordering

---

### Deterministic Time

The FSM never calls `time.Now()`.

Instead:

- leader computes timestamp
- timestamp included in log entry
- followers replay same value

This prevents clock skew divergence.

---

## Execution Model

### Job Lifecycle

```
pending → active → completed
               ↘ failed → retry → pending
               ↘ dead
```

State transitions are Raft operations.

---

### Lease Locking

Fetching a job:

1. Raft transaction
2. job marked active
3. lease assigned

Workers must heartbeat to keep lease.

If lease expires:

- job returns to pending
- another worker can claim it

Guarantee:

> At-least-once execution

---

### Heartbeats

Workers periodically send heartbeats:

Used to:

- extend lease
- report progress
- report cost
- checkpoint state

If heartbeats stop → job reclaimed.

---

## Worker Protocols

Corvo supports two worker models.

---

### HTTP Workers
Simple integration.

Request → job
Response → ack

Best for:

- simple systems
- scripting languages
- debugging

---

### Streaming Workers
Bidirectional streaming protocol.

Advantages:

- lower overhead
- fewer connections
- lower latency
- higher throughput

Recommended for production.

---

## Scaling Model

Corvo scales by partitioning work across Raft groups and queues.

---

### Sharding

Shards distribute:

- queues
- state
- processing load

Increasing shards:

- reduces contention
- lowers latency
- increases throughput

Up to the point where coordination overhead dominates.

---

### Backpressure

Corvo applies backpressure at multiple layers:

- apply queue
- fetch semaphore
- stream limits

If overloaded:

- server returns retry hint
- clients back off

This prevents collapse under load.

---

## Clustering

Clusters form automatically.

Joining:

```
POST /api/v1/cluster/join
```

Cluster properties:

- automatic leader election
- transparent failover
- follower write proxying

If a follower receives a write:

- it forwards to leader
- client need not retry

---

## Failure Handling

### Node Crash
On restart:

- Raft log replayed
- snapshots restored
- state reconstructed

No manual recovery required.

---

### Worker Crash
If worker disappears:

- lease expires
- job requeued
- another worker processes it

---

### Leader Failure
If leader fails:

- election triggered
- new leader chosen
- service resumes

No manual intervention required.

---

## Snapshotting & Compaction

Snapshots:

- compress state
- truncate log
- accelerate restart

Process:

1. Pebble checkpoint
2. SQLite backup
3. gzip archive

Snapshots retained: 2

---

## Group Commit

Raft apply operations are batched.

Window:
```
100µs – 8ms
```

Max batch:
```
1024 ops
```

This improves throughput while preserving ordering.

---

## Observability Model

Corvo exposes state through:

- metrics
- tracing
- UI
- CLI
- APIs

No external monitoring stack is required, but integrations are supported.

---

## Security Model

Authentication:

- API keys
- role-based access

Keys:

- hashed at rest
- never shown again after creation
- optional expiry

Enterprise builds add:

- OIDC
- SAML
- namespace isolation

---

## AI Execution Model

Corvo includes server-enforced agent execution controls.

The server enforces:

- max iterations
- cost caps
- guardrails
- approval rules

Workers do not need to implement these.

---

## Correctness Guarantees

Corvo guarantees:

- at-least-once delivery
- deterministic state transitions
- quorum durability
- replayable logs

Corvo intentionally does **not** guarantee:

- exactly-once execution
- global ordering across queues

---

## Tradeoffs

Corvo prioritizes correctness and predictability over:

- raw peak throughput
- minimal latency at all costs
- client-side control

These tradeoffs simplify operations and failure handling.

---

## When Corvo Is a Good Fit

Corvo works best when you need:

- reliable background processing
- distributed execution
- minimal infrastructure
- predictable failure behavior

---

## When Corvo Is Not a Good Fit

Consider alternatives if you need:

- a workflow engine
- exactly-once semantics
- in-memory only queues
- ultra-low-latency (<1ms) execution

---

## Design Philosophy

Corvo is built around one principle:

> Distributed systems should be easy to operate.

That principle drives every architectural decision.

---
