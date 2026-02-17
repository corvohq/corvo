# Corvo Runbook: Investigating Issues

## Health Check

```bash
curl -s http://localhost:8080/healthz | jq .
# {"status":"ok","raft_state":"Leader","leader":true}
```

`raft_state` values: `Leader`, `Follower`, `Candidate`, `Shutdown`.

## Key Diagnostic Endpoints

```bash
# Cluster state, apply pipeline depth, SQLite mirror stats
curl -s http://localhost:8080/api/v1/cluster/status | jq .

# Go runtime: goroutines, heap, GC
curl -s http://localhost:8080/api/v1/debug/runtime | jq .

# Prometheus metrics
curl -s http://localhost:8080/api/v1/metrics

# Queue stats
curl -s http://localhost:8080/api/v1/queues | jq .

# Connected workers
curl -s http://localhost:8080/api/v1/workers | jq .
```

## Critical Metrics to Monitor

### Apply Pipeline Pressure
```
corvo_raft_apply_pending              # Current queue depth (normal < 1000)
corvo_raft_apply_max_pending          # Max (default 16384)
corvo_raft_apply_overload_total       # Queue-full rejections (should be 0)
corvo_raft_queue_time_seconds         # Wait time in apply queue (p99 > 50ms = problem)
corvo_raft_apply_time_seconds         # FSM apply time
```

### Stream Health
```
corvo_lifecycle_streams_open          # Current open streams
corvo_lifecycle_frames_inflight       # Frames being processed now
corvo_lifecycle_frames_max_inflight   # Max (default 2048)
corvo_lifecycle_overload_total        # Rejected frames
corvo_lifecycle_idle_fetch_total      # Empty fetches (high = no pending work)
```

### Raft Health
```
corvo_cluster_is_leader               # 1 = leader, 0 = follower
corvo_raft_state                      # 0=follower, 1=candidate, 2=leader, 3=shutdown
corvo_raft_applied_index              # Should grow steadily
corvo_raft_commit_index               # commit - applied = replication lag
corvo_raft_snapshot_latest_index      # 0 for a long time = snapshots failing
```

### SQLite Mirror
```
corvo_sqlite_mirror_lag_updates       # Pending queue depth (high = SQLite falling behind)
corvo_sqlite_mirror_dropped_total     # Dropped updates (> 0 = SQLite diverged)
```

### Scheduler
```
corvo_scheduler_{promote,reclaim,expire,purge}_errors_total  # Should be 0
time() - corvo_scheduler_last_promote_seconds > 10           # Stalled scheduler
```

## Common Issues

### Jobs Stuck Active (Not Being Processed)

**Symptoms:** Jobs in `active` state with expired leases, not being reclaimed.

**Diagnosis:**
```bash
# Check scheduler reclaim
curl -s http://localhost:8080/api/v1/metrics | grep scheduler_reclaim
# corvo_scheduler_reclaim_errors_total should be 0
# corvo_scheduler_last_reclaim_seconds should be recent (within 2s)

# Check active jobs with expired leases
curl -s http://localhost:8080/api/v1/jobs/search \
  -d '{"state":["active"],"limit":10}' | jq '.jobs[] | {id, lease_expires_at}'
```

**Fix:**
- If reclaim scheduler is erroring: check logs, may need restart.
- Manual: `corvo retry <job-id>` to move back to pending.
- Nuclear: `POST /api/v1/admin/rebuild-sqlite` if SQLite diverged.

### Jobs Stuck Pending (Workers Not Fetching)

**Diagnosis:**
```bash
# Is the queue paused?
curl -s http://localhost:8080/api/v1/queues | jq '.[] | select(.name=="QUEUE") | {paused, max_concurrency}'

# Are workers connected?
curl -s http://localhost:8080/api/v1/workers | jq '.[].last_heartbeat'

# Is the apply pipeline overloaded?
curl -s http://localhost:8080/api/v1/metrics | grep apply_pending

# Is this a leadership issue?
curl -s http://localhost:8080/healthz | jq .raft_state
# Workers must connect to the leader for fetching
```

**Possible causes:**
- Queue is paused → `corvo resume <queue>`
- `max_concurrency` set too low → `POST /api/v1/queues/{name}/concurrency {"max": null}` to remove
- Rate limit too restrictive → `DELETE /api/v1/queues/{name}/throttle`
- No workers connected or all crashed
- Workers connected to a follower (streams return `NOT_LEADER`)
- HasPendingJobs cache returning false (50ms TTL, self-heals)

### SQLite Diverged from Pebble

**Symptoms:** Dashboard/search shows stale data, `corvo_sqlite_mirror_dropped_total > 0`.

**Fix:**
```bash
POST /api/v1/admin/rebuild-sqlite
# Returns: {"status":"ok","rebuilt":true,"duration_ms":1234}
```
This is safe to run anytime. It rebuilds all SQLite tables from Pebble (source of truth).

### Apply Pipeline Overloaded (429 / OVERLOADED)

**Symptoms:** Clients getting 429 errors, `corvo_raft_apply_overload_total` incrementing.

**Diagnosis:**
```bash
curl -s http://localhost:8080/api/v1/metrics | grep -E 'apply_pending|apply_overload'
```

**Causes:**
- Too many concurrent writes for the hardware
- Slow disk (especially with `--durable`)
- Large Pebble compactions blocking writes
- Single queue with many concurrent fetches

**Mitigations:**
- Increase `--raft-max-pending` (default 16384)
- Use `--raft-shards N` for write parallelism
- Switch `--raft-store` (badger usually fastest)
- Reduce `--raft-max-fetch-inflight` to limit per-queue fetch pressure
- Workers should respect `retry_after_ms` in error responses

### Stream Overloaded

**Symptoms:** `corvo_lifecycle_overload_total` incrementing, workers getting `RESOURCE_EXHAUSTED`.

**Mitigations:**
- Increase `--stream-max-inflight` (default 2048)
- Increase `--stream-max-open` (default 4096)
- Reduce `--stream-max-fps` (default 500) to throttle fast clients
- Increase `--idle-fetch-sleep` to reduce empty fetch pressure

### Leader Instability / Frequent Elections

**Diagnosis:**
```bash
# Check Raft state changes
curl -s http://localhost:8080/api/v1/metrics | grep raft_state
# Watch for state flapping

# Check cluster connectivity
curl -s http://localhost:8080/api/v1/cluster/status | jq .
```

**Causes:**
- Network partitions between nodes
- Raft port (`--raft-bind`) blocked by firewall
- Node overloaded (can't respond to heartbeats in time)
- Disk I/O stalls (especially with `--durable`)

### Slow Fetches / High Latency

**Diagnosis:**
```bash
# Check apply queue time (time waiting for Raft)
curl -s http://localhost:8080/api/v1/metrics | grep raft_queue_time

# Check fetch overloads (per-queue semaphore)
curl -s http://localhost:8080/api/v1/metrics | grep fetch_overload

# Check idle fetch sleep (workers polling empty queues)
curl -s http://localhost:8080/api/v1/metrics | grep idle_fetch
```

**Tuning for lower latency:**
- `--idle-fetch-sleep 10ms` (default 100ms) — faster job pickup
- `--fetch-poll-interval 10ms` (default 100ms) — faster unary fetch
- `--stream-max-fps 0` — remove per-stream rate limit
- `--apply-multi-mode indexed` — single Raft commit for mixed ops

### Snapshot Issues

**Symptoms:** New nodes can't join (no snapshot to bootstrap from), `corvo_raft_snapshot_latest_index` stuck at 0.

**Diagnosis:**
```bash
# Check disk space
df -h /path/to/data-dir

# Check snapshot index
curl -s http://localhost:8080/api/v1/metrics | grep snapshot
```

**Fixes:**
- Ensure enough disk space (~2x data size for checkpoint + tar)
- Lower `--snapshot-threshold` if snapshots are too infrequent
- For benchmarks: raise `--snapshot-threshold 1000000` to avoid storms

### Cluster Join Failures

**Error codes:**
- `SHARD_COUNT_MISMATCH` — joining node has different `--raft-shards` than leader
- `JOIN_ERROR` — general join failure, check leader logs

**Manual join:**
```bash
curl -X POST http://leader:8080/api/v1/cluster/join \
  -d '{"node_id":"node-2","addr":"node-2-host:9000"}'
```

## Log Messages to Watch

```
"sqlite mirror queue full; dropping mirror update"  → SQLite can't keep up
"raft apply overloaded"                             → Apply queue full
"reclaim expired leases" error=...                  → Reclaim scheduler failing
"promote scheduled jobs" error=...                  → Promote scheduler failing
"recovery prep: no snapshot found; cleared local pebble state" → Fresh start
```

## Profiling

```bash
# CPU profile (30 seconds)
curl -o cpu.prof "http://localhost:8080/debug/pprof/profile?seconds=30"
go tool pprof -http=:8081 cpu.prof

# Heap
curl -o heap.prof "http://localhost:8080/debug/pprof/heap"
go tool pprof -http=:8081 heap.prof

# Goroutines (text dump)
curl "http://localhost:8080/debug/pprof/goroutine?debug=2"

# Block / Mutex
curl -o block.prof "http://localhost:8080/debug/pprof/block"
curl -o mutex.prof "http://localhost:8080/debug/pprof/mutex"
```

## Emergency Procedures

### Force Rebuild SQLite
```bash
POST /api/v1/admin/rebuild-sqlite
```

### Kill Stuck Server
```bash
# Graceful
kill -TERM <pid>
# Wait shutdown-timeout (default 500ms), then force:
kill -9 <pid>
```

### Recover from Corrupted State
1. Stop the node
2. Delete `data/` directory
3. Restart with `--bootstrap=false --join http://leader:8080`
4. Node will receive snapshot from leader and rebuild

### Backup / Restore
```bash
# Backup
curl -o backup.tar.gz http://localhost:8080/api/v1/admin/backup

# Restore
curl -X POST http://localhost:8080/api/v1/admin/restore \
  -H "Content-Type: application/octet-stream" \
  --data-binary @backup.tar.gz
```
