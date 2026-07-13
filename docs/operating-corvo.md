# Operating Corvo in Production

This guide explains how to deploy, run, scale, monitor, and maintain Corvo in real environments.

It is intended for operators, SREs, and platform engineers.

---

# Operational Model

Corvo is designed to run as:

- a single-node system
- or a clustered distributed system

Both modes use the same binary and configuration model.

There are no external infrastructure dependencies.

---

# Deployment Topologies

---

## Single Node (Simple Deployment)

Best for:

- small workloads
- internal tools
- staging environments
- edge deployments

Run:

```bash
corvo server
```

Properties:

- persistence enabled
- no clustering
- minimal resource use
- simplest operational model

---

## Three Node Cluster (Recommended Production)

Run 3 nodes for:

- high availability
- fault tolerance
- quorum durability

Why 3:

- tolerates one node failure
- maintains consensus
- avoids split-brain

---

## Larger Clusters

More nodes may be used for:

- geographic distribution
- read scaling
- failure domain isolation

Write throughput does not scale linearly with node count due to consensus coordination.

---

# Hardware Recommendations

Minimum:

- 2 CPU cores
- 2 GB RAM
- SSD storage

Recommended production:

- 4–8 cores
- 8–16 GB RAM
- NVMe SSD

Corvo is typically disk-bound before CPU-bound.

---

# Storage Requirements

Corvo requires persistent disk for:

- Raft log
- Pebble state
- snapshots

Recommendations:

- use SSD
- avoid network filesystems
- monitor disk space

Do not run Corvo on ephemeral disks unless durability is not required.

---

# Durability and fsync (`--sync`)

By default Corvo does **not** fsync on commit. Writes are committed to the
data store and handed to the operating system, which flushes them to disk on
its own schedule. A process crash loses nothing (the OS still holds the
pages), but a **power loss or kernel crash can lose the most recent commits**.

Enabling `--sync` (or `sync = true` in the config file) makes Corvo call
`fdatasync` on every commit: once a commit returns, it is on disk.

```bash
corvo --sync
```

## The tradeoff

fsync bounds every commit by your storage device's flush latency. On NVMe
this is tens of microseconds; on SATA SSDs or cloud block storage it can be
milliseconds. Throughput drops accordingly. This is why `--sync` is opt-in.

## Single node

Without `--sync`, a power loss can lose jobs enqueued (or acknowledged) in
the final moments before the outage. If your workload tolerates replaying or
re-submitting a few seconds of work, the default is a reasonable trade. If
every accepted job must survive power loss, run with `--sync`.

## Cluster mode — read this before going to production

**Running a cluster without `--sync` is not just a durability trade — it can
violate the consensus protocol's safety assumptions.**

The replication protocol assumes that once a node persists its vote or a log
entry, that state survives restarts. Without `--sync`, a power loss can roll
a node back to before a vote or entry it already reported as persisted:

- A node that voted in an election, lost power, and restarted without that
  vote on disk **can vote again in the same term** — allowing two leaders to
  be elected for one term, whose logs then diverge.
- Entries acknowledged toward a quorum can vanish from disk, so data the
  cluster reported as committed can be lost if the wrong combination of
  nodes loses power together.

An ordinary process crash or restart is safe either way; the risk is
specifically machine-level failure (power loss, kernel panic). Because
simultaneous power loss across nodes is exactly what shared-rack or
shared-AZ deployments experience, **`--sync` is recommended for cluster
production deployments.** Leave it off only when the cluster spans
independent failure domains and losing a recently-committed suffix in a
correlated outage is acceptable.

---

# Cluster Formation

Nodes join via:

```
POST /api/v1/cluster/join
```

Cluster behavior:

- leader elected automatically
- followers replicate log
- failover automatic

No external coordinator required.

---

# Upgrades

Safe upgrade process:

1. stop one node
2. upgrade binary
3. restart node
4. wait for it to rejoin
5. repeat for next node

This maintains quorum during upgrade.

Never upgrade all nodes simultaneously.

---

# Restart Behavior

On startup a node performs:

- log replay
- snapshot restore
- state reconstruction

Startup time depends on log size and snapshot freshness.

---

# Backups

Snapshots are created automatically.

Snapshot contents:

- Pebble state
- SQLite view

Recommended backup strategy:

- copy snapshot files periodically
- store off-node

Restore procedure:

- start node with snapshot
- node catches up from cluster

---

# Monitoring

Corvo exposes monitoring data via:

- Prometheus metrics endpoint
- tracing
- health endpoint
- CLI tools

---

## Critical Metrics to Monitor

You should monitor:

- queue depth
- lifecycle latency
- apply queue backlog
- Raft apply latency
- disk usage
- CPU usage

These indicate system health.

---

## Health Endpoint

```
GET /healthz
```

Healthy response means:

- node reachable
- storage available
- cluster communication functional

---

# Capacity Planning

System capacity is usually limited by:

- lifecycle throughput
- disk speed
- shard configuration
- concurrency level

Not worker count.

Recommended approach:

- start with small cluster
- increase shards
- measure p99 latency
- adjust concurrency

---

# Scaling Strategy

Corvo scales primarily through:

- sharding
- concurrency tuning
- hardware improvements

Adding nodes improves:

- fault tolerance
- read availability

Adding shards improves:

- throughput
- latency under load

---

# Load Management

Corvo protects itself under heavy load.

Protection mechanisms:

- bounded queues
- apply limits
- streaming limits
- backpressure responses

If overloaded:

- server slows acceptance rate
- clients receive retry hints

This prevents system collapse.

---

# Worker Fleet Management

Workers can be scaled independently of the cluster.

Recommended approach:

- increase workers gradually
- monitor queue depth
- watch latency

If workers exceed system capacity, throughput will plateau.

---

# Deployment in Kubernetes

Corvo runs well in Kubernetes using:

- StatefulSet
- persistent volumes
- readiness probe
- liveness probe

Example probes:

```
/healthz
```

Shutdown handling:

Corvo handles SIGTERM and drains cleanly.

---

# Networking

Recommended configuration:

- low-latency network between nodes
- stable connections
- no aggressive load balancer timeouts

Cluster nodes should not sit behind L7 proxies.

---

# Security Operations

Best practices:

- enable API keys
- restrict network access
- rotate keys regularly
- terminate TLS in production (Corvo does not serve TLS natively — use a reverse proxy or Kubernetes ingress)

Keys are hashed at rest and never shown again after creation.

---

# Failure Recovery Checklist

If something looks wrong:

Check:

- node reachable?
- disk full?
- leader elected?
- apply backlog growing?
- workers connected?

Most issues are environment-related.

---

# Troubleshooting Performance

Common causes of degraded performance:

| Symptom | Likely Cause |
|-------|--------------|
| High latency | disk I/O |
| Throughput plateau | concurrency too high |
| Frequent retries | worker crashes |
| Backpressure responses | system saturated |

---

# Operational Anti-Patterns

Avoid:

- running on slow disks
- using network storage
- setting concurrency extremely high
- running without monitoring
- deploying even-number clusters

---

# Safe Defaults

Corvo defaults are tuned for:

- stability
- predictability
- safe operation

Most production deployments do not need custom tuning initially.

---

# Maintenance Tasks

Periodic tasks:

- monitor disk usage
- rotate logs
- verify backups
- review metrics

Corvo does not require:

- manual compaction
- vacuuming
- rebalancing
- leader pinning

---

# Operational Philosophy

Corvo is designed so that:

> routine operation requires minimal intervention.

Most failure handling is automatic.

---

# When to Contact Support

If you encounter:

- persistent leader election loops
- repeated log replay failures
- unrecoverable snapshot corruption

These indicate environmental or disk issues.

---

# Summary

Corvo is intended to behave like infrastructure, not software you constantly manage.

If it requires frequent manual intervention, something outside Corvo is usually the cause.

---
