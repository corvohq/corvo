# Corvo Usage Guide

## What is Corvo?

Corvo is a Raft-based distributed job queue written in Go. It provides durable, prioritized job scheduling with at-least-once delivery, agent/AI workload support, and a React dashboard UI.

## Quick Start

### Build
```bash
CGO_ENABLED=1 go build -o bin/corvo ./cmd/corvo
# Or:
make build  # builds UI + Go binary
```

### Start Server (Single Node)
```bash
bin/corvo server --bootstrap --node-id node-1 --bind :8080 --data-dir data
```

### Start 3-Node Cluster
```bash
# Leader
bin/corvo server --bootstrap --node-id node-1 --bind :8080 --raft-bind :9000 --data-dir data/node-1

# Followers
bin/corvo server --bootstrap=false --join http://localhost:8080 \
  --node-id node-2 --bind :8081 --raft-bind :9001 --data-dir data/node-2

bin/corvo server --bootstrap=false --join http://localhost:8080 \
  --node-id node-3 --bind :8082 --raft-bind :9002 --data-dir data/node-3
```

### Multi-Raft Sharding (Single Process)
```bash
bin/corvo server --bootstrap --raft-shards 4 --bind :8080 --raft-bind :9000
# Raft binds on :9000, :9001, :9002, :9003
```

## CLI Commands

### Job Operations
```bash
corvo enqueue <queue> '<payload-json>'                    # Enqueue a job
corvo enqueue emails '{"to":"a@b.com"}' --priority high   # With priority
corvo enqueue tasks '{}' --schedule "2025-01-01T00:00:00Z" # Scheduled
corvo enqueue tasks '{}' --unique-key "dedup-key"          # Deduplicated

corvo inspect <job-id>           # Show full job detail
corvo retry <job-id>             # Retry a failed/dead job
corvo cancel <job-id>            # Cancel a pending/active job
corvo hold <job-id>              # Move to held state
corvo approve <job-id>           # Approve held job
corvo reject <job-id>            # Reject held job to dead
corvo move <job-id> <queue>      # Move job to another queue
corvo delete <job-id>            # Delete a job
```

### Queue Management
```bash
corvo queues                     # List all queues with stats
corvo pause <queue>              # Pause (stops dispatch)
corvo resume <queue>             # Resume
corvo clear <queue>              # Clear all pending/scheduled jobs
corvo drain <queue>              # Pause + wait for active to finish
corvo destroy <queue> --confirm  # Delete queue and all its jobs
```

### Search & Bulk
```bash
corvo search --queue emails --state pending,active --limit 50
corvo search --tag env=prod --created-after 2025-01-01
corvo search --payload-contains "urgent"

# Pipe to bulk operations
corvo search --queue old --state dead | corvo bulk delete
corvo bulk cancel --filter '{"queue":"emails","state":["pending"]}'
```

### Admin
```bash
corvo status                     # Server status + queue summary
corvo workers                    # List connected workers
```

## HTTP API (key endpoints)

### Producer
```
POST /api/v1/enqueue              {"queue":"q","payload":{...}}
POST /api/v1/enqueue/batch        {"jobs":[...]}
```

### Worker
```
POST /api/v1/fetch                {"queues":["q"],"worker_id":"w1","timeout":30}
POST /api/v1/fetch/batch          {"queues":["q"],"worker_id":"w1","count":10}
POST /api/v1/ack/{job_id}         {"result":{...}}
POST /api/v1/ack/batch            {"acks":[{"job_id":"...","result":{}}]}
POST /api/v1/fail/{job_id}        {"error":"msg","backtrace":"..."}
POST /api/v1/heartbeat            {"jobs":{"id":{"progress_json":"..."}}}
```

### Reads (any node)
```
GET  /api/v1/queues
GET  /api/v1/jobs/{id}
POST /api/v1/jobs/search          {"queue":"q","state":["pending"],"limit":100}
GET  /api/v1/workers
GET  /api/v1/cluster/status
GET  /api/v1/metrics              # Prometheus format
GET  /healthz
```

### Queue Config
```
POST   /api/v1/queues/{name}/pause
POST   /api/v1/queues/{name}/resume
POST   /api/v1/queues/{name}/concurrency   {"max": 10}
POST   /api/v1/queues/{name}/throttle      {"rate": 100, "window_ms": 1000}
DELETE /api/v1/queues/{name}/throttle
```

## ConnectRPC (high-performance path)

`StreamLifecycle` is a bidirectional stream multiplexing enqueue+fetch+ack in one connection:

```go
wc := worker.New("http://localhost:8080")
stream := wc.OpenLifecycleStream(ctx)

resp, _ := stream.Exchange(worker.LifecycleRequest{
    RequestID:    1,
    Queues:       []string{"emails"},
    WorkerID:     "w1",
    FetchCount:   10,
    LeaseSeconds: 30,
    Acks:         []worker.AckBatchItem{{JobID: prevID, Result: json.RawMessage(`{}`)}},
})
// resp.Jobs = fetched jobs, resp.Acked = ack count
```

## Go SDK Worker

```go
w := client.NewWorker(client.WorkerConfig{
    URL:         "http://localhost:8080",
    Queues:      []string{"emails"},
    Concurrency: 10,
    ClientOptions: []client.ClientOption{client.WithAPIKey("sk_...")},
})
w.Register("emails", func(job client.FetchedJob, ctx *client.JobContext) error {
    ctx.Progress(1, 10, "processing")
    ctx.Checkpoint(map[string]any{"offset": 42})
    if ctx.Cancelled() { return fmt.Errorf("cancelled") }
    return nil // auto-acks on nil, auto-fails on error
})
w.Start(context.Background()) // blocks, handles SIGTERM
```

## Server Configuration Reference

### Key Flags
| Flag | Default | Description |
|------|---------|-------------|
| `--bind` | `:8080` | HTTP bind |
| `--data-dir` | `data` | Storage directory |
| `--raft-bind` | `:9000` | Raft transport bind |
| `--raft-store` | `badger` | Log backend: `bolt`, `badger`, `pebble` |
| `--raft-shards` | `1` | In-process Raft shard groups |
| `--durable` | `false` | Raft fsync per write (power-loss safe) |
| `--sqlite-mirror` | `true` | SQLite materialized view for reads |
| `--apply-multi-mode` | `grouped` | Batch mode: `grouped`, `indexed`, `individual` |
| `--stream-max-inflight` | `2048` | Max concurrent stream frames |
| `--stream-max-open` | `4096` | Max open streams |
| `--stream-max-fps` | `500` | Per-stream frame rate cap |
| `--fetch-poll-interval` | `100ms` | Unary fetch long-poll interval |
| `--idle-fetch-sleep` | `100ms` | Stream sleep when no jobs |
| `--snapshot-threshold` | `4096` | Log entries between snapshots |
| `--retention` | `168h` | TTL for completed/dead jobs |
| `--raft-max-pending` | `16384` | Apply queue backpressure |
| `--raft-max-fetch-inflight` | `64` | Per-queue concurrent fetches |

### Environment Variables
| Var | Description |
|-----|-------------|
| `CORVO_API_KEY` | API key for CLI/workers |
| `CORVO_ADMIN_PASSWORD` | Admin password |
| `CORVO_LICENSE_KEY` | Enterprise license |

## Benchmarking

### Quick Bench
```bash
bin/corvo bench --server http://localhost:8080 --protocol rpc --jobs 10000

# Combined (concurrent enqueue + fetch + ack)
bin/corvo bench --server http://localhost:8080 --combined --jobs 100000

# Save and compare
bin/corvo bench --save baseline.json
bin/corvo bench --compare baseline.json
```

### Multi-Configuration (store comparison)
```bash
./scripts/bench-modes.sh                           # all stores
STORES=badger SHARDS="1 4" ./scripts/bench-modes.sh  # specific config
PRESET=cluster ./scripts/bench-modes.sh             # 3-node cluster
COMBINED=true JOBS=100000 ./scripts/bench-modes.sh   # combined mode
```

### Baseline & Comparison (performance regression testing)
```bash
# Run structured baseline (results in bench-results/{commit}/)
./scripts/bench-baseline.sh              # standard mode (~10-15 min)
./scripts/bench-baseline.sh quick        # smoke test (~2 min)
./scripts/bench-baseline.sh full         # comprehensive (~45-60 min)
CI=true ./scripts/bench-baseline.sh standard  # GitHub Actions safe (~3 min)
STORE=pebble ./scripts/bench-baseline.sh      # override store backend

# Compare two baselines
./scripts/bench-compare.sh bench-results/abc1234 bench-results/def5678
```

### Profiling
```bash
./scripts/bench-profile.sh  # CPU profile + bench
PROFILE_TYPE=heap ./scripts/bench-profile.sh
```

## Job States
```
pending → active (fetch) → completed (ack)
                         → retrying (fail, retries left) → pending (promote)
                         → dead (fail, no retries)
                         → pending (lease expired, reclaim)

scheduled → pending (promote at scheduled_at)
held → pending (approve) / dead (reject)
any → cancelled (cancel)
```

## Priority Levels
- `critical` (0) — highest, always fetched first
- `high` (1)
- `normal` (2) — default, uses FIFO append log
