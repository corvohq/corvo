# Corvo Performance & Benchmark Methodology

This document explains how Corvo performance is measured, what the numbers mean, and how to reproduce results locally.

It is intended for engineers evaluating throughput, latency, and scaling behavior.

---

# Measurement Philosophy

Corvo benchmarks aim to measure **realistic system behavior**, not synthetic peak numbers.

All published results follow these principles:

- reproducible
- configuration disclosed
- limits documented
- workloads described
- tradeoffs explained

Benchmarks are not marketing claims. They are engineering measurements.

---

# Benchmark Types

Corvo measures performance in two distinct modes.

---

## 1. Steady-State Mode

Enqueue and lifecycle operations run concurrently.

Measures:

- real-world throughput
- tail latency
- contention effects
- coordination overhead

This is the most realistic workload.

---

## 2. Burst Mode

Phases run separately:

1) enqueue phase
2) lifecycle phase

Measures:

- enqueue ceiling
- processing ceiling
- storage limits
- coordination limits

This isolates subsystem performance.

---

# Key Metrics

---

## Throughput

Measured as:

```
operations per second
```

Depending on test:

- enqueue ops/sec
- lifecycle ops/sec
- combined ops/sec

---

## Latency

Reported as:

```
p99 latency
```

Not averages.

Tail latency is more important for distributed systems than mean latency.

---

## Consistency (CV)

Coefficient of variation is reported for steady-state runs.

```
CV = stddev / mean
```

Interpretation:

| CV | Meaning |
|----|--------|
| < 15% | very stable |
| 15–30% | normal |
| > 30% | bursty |

---

## Saturation

Benchmarks observe when performance plateaus.

Plateau indicates:

- coordination limit
- storage limit
- or configured guardrail

---

# Test Environment Disclosure

Every benchmark must include:

- CPU model
- core count
- RAM
- disk type
- node count
- shard count
- concurrency
- worker count
- job payload size

Without environment data, performance numbers are meaningless.

---

# Example Baseline Results

Representative single-node results:

| Mode | Throughput |
|-----|-------------|
| Steady-state | ~40k ops/sec |
| Enqueue burst | ~170k ops/sec |

Interpretation:

- enqueue path scales higher than lifecycle
- lifecycle defines real capacity
- scaling improves with sharding
- latency decreases as contention decreases

---

# Scaling Behavior

Corvo scaling follows predictable patterns.

---

## Shards

Increasing shards typically:

- increases throughput
- reduces contention
- lowers tail latency

Until coordination overhead dominates.

---

## Concurrency

Higher concurrency eventually reduces throughput.

Reason:

- scheduling contention
- coordination overhead
- queue arbitration

Optimal concurrency depends on workload.

---

## Workers

Worker count does not always increase throughput.

If throughput remains constant as workers increase, the system is:

> coordination-limited, not worker-limited

---

# Guardrails vs Capacity

Corvo includes internal safety limits:

- in-flight caps
- apply buffers
- stream limits

These prevent overload collapse.

Benchmarks must specify whether guardrails were:

- enabled (production profile)
- raised (capacity profile)

---

# How To Reproduce Benchmarks

Example:

```bash
# Start server (shards are a server-side config)
corvo server --raft-shards 3

# Run benchmark
corvo bench \
  --jobs 50000 \
  --workers 8 \
  --concurrency 32 \
  --combined
```

All official benchmark reports include command used.

---

# Interpreting Results

Important guidelines:

---

### Throughput alone is not enough

High throughput with unstable latency is not desirable.

Stability matters.

---

### Burst throughput is not capacity

Burst tests measure subsystem limits.

Steady-state tests measure production behavior.

---

### Lifecycle throughput defines system ceiling

Enqueue is usually faster because lifecycle includes:

- coordination
- locking
- replication
- acknowledgement

---

# Comparing Corvo to Other Systems

Fair comparison requires:

- identical hardware
- identical workloads
- identical job sizes
- identical concurrency
- identical guarantees

Comparisons without these are invalid.

---

# What Corvo Optimizes For

Corvo prioritizes:

- predictable performance
- stability under load
- graceful degradation
- deterministic behavior

Corvo does not optimize for:

- maximum theoretical throughput
- minimal latency at all costs

---

# Known Performance Tradeoffs

Corvo intentionally trades some peak throughput for:

- consensus durability
- deterministic execution
- recovery guarantees

These tradeoffs improve reliability and observability.

---

# Recommended Benchmark Practice

When evaluating Corvo for your workload:

1. test with real job payloads
2. test with realistic worker counts
3. test with retries enabled
4. test failure scenarios
5. test steady-state load

Synthetic tests rarely reflect production behavior.

---

# Performance Debugging Signals

If performance is lower than expected, check:

- apply queue saturation
- worker concurrency
- disk I/O limits
- network latency
- shard count
- GC pauses

Most performance issues come from environment constraints, not Corvo itself.

---

# Reporting Results

When publishing results, include:

```
machine specs
config flags
workload description
test command
```

This allows others to validate results independently.

---

# Design Principle

Corvo performance is designed to be:

> predictable, stable, and explainable

Not just fast.

---
