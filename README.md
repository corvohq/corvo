# Corvo

**Corvo is an open-source distributed job system with automatic clustering.**

Single binary. No external dependencies. Production-ready.

---

## Quickstart (30 seconds)

Run a single node:

```bash
corvo server
```

Enqueue a job:

```bash
corvo enqueue emails.send '{"to":"user@example.com"}'
```

Start a worker:

```bash
corvo worker emails.send
```

That’s it. No Redis. No Postgres. No coordinator.

---

## What Corvo Is

Corvo is a distributed background job system designed for predictable execution and simple operations.

It provides:

- reliable job processing
- automatic clustering
- built-in persistence
- scheduling and retries
- observability tools
- language-agnostic workers

All in one binary.

---

## Why Corvo Exists

Many teams eventually build their own queue system because existing options often:

- require external infrastructure
- are tied to one language
- lack reliability guarantees
- or are operationally heavy

Corvo was built to remove those tradeoffs.

---

## Core Features

### Job System
- enqueue / fetch / ack lifecycle
- priorities (high / normal / low)
- delayed and scheduled jobs
- retries with backoff
- dead letter queue
- TTL expiration
- unique jobs
- cancellation
- dependencies and chains
- batches + callbacks
- rate limiting per queue
- concurrency limits per queue
- bulk operations
- tags and metadata
- result storage
- webhooks

---

### Reliability Model
- Raft consensus replication
- quorum writes
- lease-based locking
- automatic lease reclaim
- crash recovery via log replay
- snapshot compaction
- deterministic timestamps
- group commit batching

Delivery guarantee:

> **At-least-once processing**

---

### Worker Model
- HTTP workers (simple integrations)
- streaming workers (high throughput)
- long polling
- heartbeats
- progress reporting
- graceful shutdown
- multi-queue fetch
- backpressure signaling

Workers can be written in any language that can send HTTP.

---

### Scaling
- automatic clustering
- leader election + failover
- follower write proxying
- per-queue isolation
- apply pipeline backpressure
- configurable Raft storage backend
- Kubernetes-friendly deployment

---

### Observability
- built-in web UI
- CLI tooling
- Prometheus metrics
- OpenTelemetry tracing
- cluster health endpoints
- job search
- lifecycle logs
- real-time event stream

---

### Security
- API keys
- role system
- queue-scoped permissions
- key expiration
- enterprise SSO / RBAC options

---

### AI / Agent Workloads (Built-In)
Corvo includes primitives for long-running agent jobs:

- iteration tracking
- budget enforcement
- cost tracking
- approval policies
- checkpoints
- replay from iteration
- human-in-the-loop states
- tool-as-child-job pattern

These run server-side — workers do not need to implement them.

---

## Architecture Overview

Corvo’s architecture is designed to minimize operational overhead:

| Component | Purpose |
|--------|---------|
| Pebble | primary state store |
| SQLite | query layer |
| Raft | replication + consensus |

Key properties:

- no external database required
- deterministic state machine
- replayable logs
- rebuildable read views

---

## Performance

Measured locally:

| Mode | Throughput |
|-----|-------------|
| Steady-state | ~40k ops/sec |
| Enqueue burst | ~170k/sec |

Notes:

- lifecycle throughput defines system capacity
- sharding improves latency under load
- benchmarks reproducible with CLI

---

## When NOT to Use Corvo

Corvo is not the right tool if:

- you only run a few background jobs
- you don’t need reliability guarantees
- you already operate a queue system you’re happy with
- you want a workflow engine instead of a job system

---

## Comparison Snapshot

| System | Infra Required | Language Locked | Built-in Clustering |
|------|----------------|----------------|----------------|
| Corvo | none | no | yes |
| BullMQ | Redis | Node | no |
| pgboss | Postgres | Node | no |
| Temporal | multiple services | no | yes |

---

## CLI Examples

Inspect jobs:

```bash
corvo jobs list
```

Retry failed:

```bash
corvo jobs retry --state dead
```

Pause queue:

```bash
corvo queue pause emails.send
```

---

## Production Deployment

Corvo runs well:

- as a single node
- in a 3-node cluster
- in Kubernetes (StatefulSet)

Health endpoint:

```
GET /healthz
```

Graceful shutdown is supported via SIGTERM.

---

## Enterprise Features (Optional)

Corvo is fully open-source and production-ready.

Optional enterprise features provide:

- SSO / OIDC
- SAML auth
- fine-grained RBAC
- multi-tenant namespaces

These add organizational controls.
They do not affect runtime performance or reliability.

---

## Roadmap

Future work is driven by real workloads.
Feature priorities are based on production feedback.

---

## License

MIT (core)
Enterprise extensions available separately.

---

## Support

If you’re evaluating Corvo and want help running it:

```
hello@corvohq.com
```

---

## Design Philosophy

Corvo prioritizes:

- predictable behavior
- operational simplicity
- correctness guarantees
- transparent tradeoffs

Not feature count.

---
