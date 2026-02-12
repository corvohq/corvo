# Jobbie Benchmarks

Benchmarks run on an 11th Gen Intel Core i7-11850H @ 2.50GHz, Linux 6.9.3, NVMe SSD.

## Enqueue Throughput (HTTP, end-to-end)

All numbers from `cmd/bench` hitting a local server — includes HTTP routing, JSON serialization, and full `Enqueue` transaction (unique lock check, queue upsert, job insert, event insert, stats update).

### Final configuration: SYNCHRONOUS=NORMAL + BatchWriter

| Concurrency | Enqueue ops/sec | Avg latency | p50     | p99      |
|-------------|----------------:|------------:|--------:|---------:|
| 1           | 2,532           | 395us       | 156us   | 11.7ms   |
| 10          | 7,928           | 1.26ms      | 536us   | 23.4ms   |
| 50          | 11,344          | 4.39ms      | 3.22ms  | 27.3ms   |

### Full lifecycle (enqueue + fetch + ack)

| Concurrency | Lifecycle ops/sec | Avg latency | p50     | p99      |
|-------------|------------------:|------------:|--------:|---------:|
| 1           | 636               | 1.57ms      | 788us   | 24.0ms   |
| 10          | 1,879             | 5.32ms      | 2.74ms  | 27.2ms   |
| 50          | 2,232             | 22.4ms      | 16.9ms  | 58.5ms   |

## Configuration comparison

Enqueue ops/sec across different configurations:

| Configuration                    | c=1     | c=10    | c=50     |
|----------------------------------|--------:|--------:|---------:|
| SYNCHRONOUS=FULL + DirectWriter  | 145     | 703     | 3,043    |
| SYNCHRONOUS=NORMAL + DirectWriter| 2,591   | 3,060   | 2,919    |
| SYNCHRONOUS=NORMAL + BatchWriter | **2,532** | **7,928** | **11,344** |

### Key takeaways

- **SYNCHRONOUS=NORMAL** eliminates per-commit fsync, improving serial throughput from ~145 to ~2,500 ops/sec. Safe in WAL mode — only risks the last transaction on power loss (not process crash). Same tradeoff Redis and PostgreSQL queues make.
- **BatchWriter** groups concurrent transactions into one commit, eliminating write lock contention. Without it, throughput degrades under concurrency as goroutines fight over SQLite's single writer lock.
- Both optimizations are complementary: NORMAL fixes serial, BatchWriter fixes concurrent. Together they're multiplicative.

## Comparison with other job queues

| System           | Backend          | Serial enqueue | Concurrent enqueue     |
|------------------|------------------|---------------:|-----------------------:|
| **Jobbie**       | SQLite (NORMAL)  | 2,532/s        | 11,344/s (c=50)        |
| BullMQ           | Redis            | ~5,800/s       | ~17,700/s (c=10)       |
| Faktory          | Embedded Redis   | ~10-20K/s (est)| higher with pipelining |
| pg-boss          | PostgreSQL       | ~1-3K/s (est)  | ~3-5K/s (est)          |

Jobbie is competitive with PostgreSQL-backed queues and within striking distance of Redis-backed systems — while being a single binary with zero external dependencies.

## Running benchmarks

### Go microbenchmarks (store layer, no HTTP)

```sh
go test ./internal/store/... -bench=BenchmarkEnqueue -benchtime=3s
```

### HTTP benchmarks (full stack)

```sh
# Terminal 1: start server
go run ./cmd/jobbie server --data-dir /tmp/bench-data

# Terminal 2: run bench
go run ./cmd/bench --jobs 10000 --concurrency 50
```

Options:
- `--server` — server URL (default `http://localhost:8080`)
- `--jobs` — total jobs to process (default 10000)
- `--concurrency` — concurrent goroutines (default 10)
- `--queue` — queue name (default `bench.q`)
