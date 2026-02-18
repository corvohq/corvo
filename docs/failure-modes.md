# Corvo Failure Modes & Recovery Behavior

This document describes how Corvo behaves under failure conditions and what guarantees the system provides.

It is intended for engineers evaluating operational reliability.

---

# Failure Model Overview

Corvo is designed around the assumption that failures are normal and unavoidable.

The system explicitly handles failure of:

- workers
- nodes
- leaders
- disks
- network links
- clients

Recovery is automatic whenever possible.

Manual intervention should not be required for common failures.

---

# Guarantees Summary

Corvo provides:

- at-least-once job execution
- quorum durability
- deterministic state replay
- automatic failover
- automatic job recovery

Corvo intentionally does **not** guarantee:

- exactly-once execution
- global ordering across queues
- zero duplicate execution

---

# Failure Categories

---

## 1. Worker Failure

### Scenario
Worker crashes or loses network connection while processing a job.

### Detection
Workers must heartbeat periodically.
If heartbeat stops:

```
lease expires → job reclaimed
```

Scheduler checks leases every second.

### Result
- job returns to pending
- another worker may claim it
- job may execute again

### Guarantee
No job is permanently lost.

---

## 2. Node Crash

### Scenario
Corvo node process exits unexpectedly.

### On Restart
Node performs:

1. Raft log replay
2. snapshot restore (if present)
3. state reconstruction

No manual repair required.

### Result
Node rejoins cluster automatically.

---

## 3. Leader Failure

### Scenario
Leader node crashes or becomes unreachable.

### Detection
Followers detect missed heartbeats.

### Response
Raft election occurs.

Typical election time:
```
< few seconds
```

### Result
New leader chosen automatically.

Clients may briefly see:

- redirect responses
- reconnect requests

No data loss occurs.

---

## 4. Network Partition

### Scenario
Cluster splits into two or more groups.

### Behavior
Only the partition with quorum can continue processing writes.

Minority partitions:

- cannot commit writes
- remain read-only

### Result
Prevents split-brain writes.

---

## 5. Disk Failure

### Scenario
Node storage becomes unavailable or corrupted.

### Behavior
That node stops participating in consensus.

Cluster continues if quorum remains.

Replacement node can join and catch up from Raft log.

---

## 6. Job Handler Crash

### Scenario
Worker crashes mid-job.

### Behavior
Lease expires → job reclaimed → reassigned.

---

## 7. Client Crash During Enqueue

### Scenario
Client sends enqueue request but disconnects.

### Behavior
If request committed in Raft:

- job exists

If not committed:

- job never created

Corvo does not create partial jobs.

---

## 8. Overload

### Scenario
Too many concurrent requests.

### Behavior
Corvo applies backpressure:

- bounded apply queues
- bounded fetch concurrency
- streaming strike delays

Server returns:

```
OVERLOADED + retry_after_ms
```

### Result
System slows gracefully instead of collapsing.

---

## 9. Clock Skew

### Scenario
Nodes have different system clocks.

### Behavior
FSM never reads local clock.

Leader supplies timestamps for all writes.

### Result
No state divergence due to clock drift.

---

## 10. SQLite View Corruption

SQLite is a derived read model.

If corrupted:

```
RebuildSQLiteFromPebble()
```

Rebuild source: Pebble state.

No job data lost.

---

## 11. Snapshot Failure

If snapshot creation fails:

- cluster continues normally
- next snapshot attempt runs later

Snapshots are optimization, not correctness requirement.

---

## 12. Raft Log Growth

Logs grow until snapshot compaction.

If compaction delayed:

- disk usage increases
- correctness unaffected

---

# Data Loss Scenarios

Corvo only risks permanent data loss if:

- quorum is permanently lost AND
- majority disks are destroyed

This is true for any quorum-based system.

---

# Duplicate Execution Scenarios

Duplicate job execution can occur if:

- worker crashes after completing job but before ack
- network fails before ack reaches server
- lease expires due to heartbeat failure

Design implication:

> Jobs should be idempotent.

This is standard practice for distributed job systems.

---

# Recovery Guarantees Matrix

| Failure | Data Loss | Duplicate Jobs | Manual Action |
|--------|-----------|----------------|---------------|
| Worker crash | No | Possible | No |
| Node crash | No | No | No |
| Leader crash | No | No | No |
| Network partition | No | No | No |
| Disk failure (single node) | No | No | No |
| Client crash | No | No | No |
| Overload | No | No | No |

---

# Operational Safety Properties

Corvo is designed so that:

- no single node can corrupt state
- no client can bypass consensus
- no clock drift can diverge state
- no worker crash can lose jobs

---

# Why Corvo Uses At-Least-Once Delivery

Exactly-once delivery in distributed systems requires:

- global coordination
- external transaction systems
- or performance tradeoffs

Corvo instead guarantees:

> jobs will run at least once and never be silently lost

This model is:

- simpler
- safer
- more predictable

---

# Recommended Operational Practices

For production deployments:

- run ≥3 nodes
- monitor disk space
- monitor Raft apply latency
- design idempotent jobs
- set retry limits
- configure queue rate limits

---

# Design Principle

Corvo is built on a single reliability principle:

> Failures should slow the system, not break it.

---
