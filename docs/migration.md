# Migrating to Corvo

This guide explains how to move from an existing job system to Corvo safely and incrementally.

It focuses on practical migration paths, not theory.

---

# Migration Philosophy

Corvo is designed so you do not need a “big bang” migration.

Most teams migrate in stages:

1. run Corvo alongside existing system
2. move one queue or job type
3. validate behavior
4. move remaining workloads

This approach avoids downtime and risk.

---

# What Changes When Switching to Corvo

Moving to Corvo typically means changing:

- enqueue API calls
- worker client
- retry configuration
- job metadata format

You usually do **not** need to change:

- job logic
- business code
- infrastructure layout
- deployment topology

---

# Migration Strategy Options

---

## Option 1 — Parallel Run (Recommended)

Run Corvo alongside your existing system.

Route new jobs to Corvo while old jobs finish in the old system.

Benefits:

- zero downtime
- easy rollback
- safe validation

---

## Option 2 — Queue-by-Queue Migration

Move queues individually.

Example:

```
emails → Corvo
video-processing → old system
billing → old system
```

Benefits:

- isolates risk
- validates performance gradually

---

## Option 3 — Worker-by-Worker Migration

Keep existing enqueue system.

Replace workers first.

This works when:

- your current queue supports HTTP fetch
- you want to test Corvo workers first

---

## Option 4 — Cold Cutover (Not Recommended)

Stop old system. Start Corvo.

Only safe if:

- system has very low traffic
- jobs are disposable
- or environment is non-production

---

# Mapping Common Queue Concepts

| Concept | Typical Queue | Corvo |
|--------|----------------|-------|
| enqueue | push job | enqueue |
| fetch | reserve | fetch |
| ack | done | ack |
| fail | retry | fail |
| visibility timeout | lease | lease |
| dead letter | DLQ | dead state |

---

# Migrating from Specific Systems

---

## From Redis Queues

Typical changes:

- replace Redis enqueue calls with HTTP requests
- replace polling workers with Corvo workers
- remove Redis dependency

Common improvement after migration:

- fewer operational issues
- simpler deployment

---

## From BullMQ

Changes:

- remove Redis connection
- replace worker loop
- adjust retry logic

No change required:

- job handler code
- payload format

---

## From pgboss

Changes:

- remove Postgres queue tables
- update enqueue client
- update worker fetch

Benefits:

- removes database contention
- separates jobs from OLTP database

---

## From Faktory

Changes:

- replace Faktory client with HTTP or streaming client
- update worker lifecycle calls

Most job definitions transfer directly.

---

## From Custom Queue

Typical process:

1. map job schema
2. implement enqueue adapter
3. implement worker adapter
4. run side-by-side

---

# Data Migration

Most teams do **not** migrate existing jobs.

Instead:

- let old queue drain
- start new jobs in Corvo

Reasons:

- simpler
- safer
- faster

If migration is required:

- export old jobs
- transform format
- enqueue into Corvo

---

# Worker Migration

Workers must support:

- fetch
- heartbeat
- ack
- fail

Minimal worker loop:

```
loop:
    job = fetch()
    result = run(job)
    ack(result)
```

Workers can be written in any language that can make HTTP requests.

---

# Testing Before Switching

Before moving production workloads:

Test:

- retries
- failure handling
- job timeouts
- concurrency
- load behavior

Recommended validation:

Run staging traffic through Corvo for at least one full workload cycle.

---

# Rollback Plan

If something goes wrong:

- stop sending jobs to Corvo
- restart old workers
- resume old queue

Because migration is incremental, rollback is trivial.

---

# Operational Differences You Should Expect

Compared to many queue systems:

Corvo:

- does not require Redis/Postgres
- does not need external coordination
- does not rely on polling loops

This usually reduces operational overhead.

---

# Common Migration Pitfalls

Avoid:

- migrating all queues at once
- benchmarking only enqueue speed
- ignoring retry behavior
- running without monitoring
- forgetting idempotency

---

# Idempotency Reminder

Corvo guarantees:

> at-least-once delivery

Jobs should be safe to run multiple times.

This is standard practice for distributed systems.

---

# Verification Checklist

Before switching production traffic:

Confirm:

- jobs execute correctly
- retries behave as expected
- failures recover automatically
- metrics look healthy
- queue depth stabilizes

---

# Example Migration Timeline

Typical real-world migration:

Week 1:
deploy Corvo cluster

Week 2:
move one queue

Week 3:
move high-volume queues

Week 4:
retire old system

---

# When Migration Is Easy

Migration is usually straightforward if:

- jobs are stateless
- payloads are JSON
- handlers are idempotent

---

# When Migration Takes Longer

Expect more work if:

- jobs depend on queue internals
- job state is stored in queue
- workflows are tightly coupled

---

# Support During Migration

If you are evaluating Corvo for production migration, testing with real workloads is recommended.

Real workloads expose:

- concurrency patterns
- failure modes
- throughput limits

---

# Summary

Most migrations to Corvo involve:

- replacing enqueue calls
- replacing workers
- running both systems briefly

No infrastructure rewrite required.

---

# Design Principle

Corvo migrations are designed to be:

> incremental, reversible, and low risk

---
