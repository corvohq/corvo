# Jobbie Benchmarks

This file tracks current Raft+Pebble performance numbers and benchmark commands.
Older SQLite-era benchmark sections were removed to avoid stale comparisons.

## Current Baseline (Fast Mode)

Date: 2026-02-12

Environment:
- CPU: 11th Gen Intel Core i7-11850H @ 2.50GHz
- OS: Linux 6.9.3
- Disk: NVMe SSD

Server profile:
- `--durable=false` (default)
- `raft_nosync=true`
- `pebble_nosync=true`
- `--raft-store badger`

Bench command pattern:
- `./bin/bench -protocol rpc -server http://127.0.0.1:18080 -jobs 10000 ...`

### Unary enqueue (`-enqueue-batch-size 1`)

| Concurrency | Enqueue ops/sec | Enqueue p99 | Lifecycle ops/sec | Lifecycle p99 |
|-------------|----------------:|------------:|------------------:|--------------:|
| 10          | 22,096.0        | 1.583ms     | 36,452.5          | 29.544ms      |
| 50          | 14,879.7        | 11.095ms    | 45,170.1          | 34.919ms      |
| 100         | 13,631.8        | 16.368ms    | 36,347.9          | 58.086ms      |
| 200         | 17,866.5        | 30.153ms    | 34,226.9          | 104.019ms     |

### Large enqueue batch (`-enqueue-batch-size 1000`)

| Concurrency | Enqueue ops/sec | Enqueue p99 | Lifecycle ops/sec | Lifecycle p99 |
|-------------|----------------:|------------:|------------------:|--------------:|
| 10          | 220,879.0       | 44.781ms    | 42,848.3          | 20.333ms      |

Notes:
- `enqueue-batch-size=1000` reports batch/frame latency, not per-job unary latency.
- High concurrency can still show tail spikes due to queueing/admission pressure.

## Durability Performance Tradeoff

`--durable` controls only Raft fsync behavior:
- `--durable=false` (default): `raft_nosync=true` for maximum throughput.
- `--durable=true`: `raft_nosync=false` for stronger power-loss durability at significant throughput/latency cost.

`pebble_nosync` is kept `true` as a global default because Pebble is treated as rebuildable materialized state.

## Running Benchmarks

### Start server

```sh
./bin/jobbie server \
  --bind 127.0.0.1:18080 \
  --raft-bind 127.0.0.1:19000 \
  --raft-advertise 127.0.0.1:19000 \
  --data-dir /tmp/jobbie-bench \
  --raft-store badger
```

### Run bench

```sh
./bin/bench \
  -server http://127.0.0.1:18080 \
  -protocol rpc \
  -jobs 10000 \
  -concurrency 50 \
  -enqueue-batch-size 1
```

Useful flags:
- `-protocol` = `rpc|http|matrix`
- `-repeats` and `-repeat-pause` for repeatability
- `-fetch-batch-size`, `-ack-batch-size`, `-work-duration` for lifecycle shaping

## E2E Perf Smoke Tests (CI/Local)

These are real end-to-end tests that start the actual `cmd/jobbie server` path and run HTTP/RPC flows through client libraries.

Run:

```sh
go test -tags perf ./tests/perf -v -count=1
# or
make perf
```

Latest run (2026-02-12):
- `TestPerfE2EEnqueueHTTP`: `15,329.0 ops/sec` (`total=4000`, `c=10`)
- `TestPerfE2ELifecycleRPC`: `27,833.5 ops/sec` (`total=3000`, `c=10`)

Thresholds are intentionally loose and env-configurable for machine stability:
- `JOBBIE_PERF_E2E_ENQ_TOTAL`
- `JOBBIE_PERF_E2E_ENQ_CONCURRENCY`
- `JOBBIE_PERF_E2E_ENQ_MIN_OPS`
- `JOBBIE_PERF_E2E_LC_TOTAL`
- `JOBBIE_PERF_E2E_LC_CONCURRENCY`
- `JOBBIE_PERF_E2E_LC_FETCH_BATCH`
- `JOBBIE_PERF_E2E_LC_ACK_BATCH`
- `JOBBIE_PERF_E2E_LC_MIN_OPS`
