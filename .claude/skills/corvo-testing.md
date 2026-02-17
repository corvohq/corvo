# Corvo Testing Guide

## Running Tests

```bash
# All unit + integration tests
make test
# equivalent: go test ./... -v -count=1

# Perf tests only (gated by build tag)
make perf
# equivalent: go test -tags perf ./tests/perf -v -count=1

# Raft benchmarks (excluded under race detector via !race tag)
go test ./internal/raft -bench=. -run='^$' -v

# With race detector (bench_test.go auto-excluded)
go test -race ./...

# Specific package
go test ./internal/store -v -run TestGetJob

# Bench command (not go test — uses the built binary)
make bench
```

No CGO needed — Corvo uses `modernc.org/sqlite` (pure Go).

## Build Tags

| Tag | Purpose | Files |
|-----|---------|-------|
| `perf` | Perf tests only | `tests/perf/perf_test.go` |
| `!race` | Exclude under race detector | `internal/raft/bench_test.go` |

No `integration` build tag — integration tests run with `go test ./...`.

## Test Tiers

### Unit Tests (`internal/**/*_test.go`)
Standard `go test`, no build tags, in-process. Every package has them.

### Integration Tests (`tests/integration/integration_test.go`)
Full in-process stack: DirectApplier + Store + Scheduler + httptest.Server. Exercise real HTTP API paths via the Go SDK client. Run as part of `go test ./...`.

### Perf Tests (`tests/perf/perf_test.go`)
Start a **real `corvo server` subprocess** via `exec.Command("go", "run", "./cmd/corvo", "server", ...)`. Drive with concurrent SDK clients. Gated by `//go:build perf`.

## The Core Test Primitive: `DirectApplier`

**File:** `internal/raft/direct.go`

`DirectApplier` bypasses Raft networking and applies FSM operations directly. It opens a real Pebble store + SQLite DB in `t.TempDir()`.

```go
da, err := raft.NewDirectApplier(t.TempDir())
t.Cleanup(func() { da.Close() })
```

It implements the `store.Applier` interface:
```go
func (d *DirectApplier) Apply(opType store.OpType, data any) *store.OpResult
```

### Standard Test Setup (used everywhere)

```go
func testStore(t *testing.T) *store.Store {
    t.Helper()
    da, _ := raft.NewDirectApplier(t.TempDir())
    t.Cleanup(func() { da.Close() })
    return store.NewStore(da, da.SQLiteDB())
}
```

This exact pattern appears in:
- `internal/store/store_test.go` → `testStore(t)`
- `internal/server/server_test.go` → `testServer(t)`
- `internal/rpc/server_test.go` → `setupTest(t)`
- `internal/scheduler/scheduler_test.go` → `testSetup(t)`
- `tests/integration/integration_test.go` → `setup(t)`

## Test Patterns by Package

### Store Tests (`internal/store/*_test.go`)
Package `store_test` (external test package). Use `testStore(t)`.

```go
func TestCancelJob(t *testing.T) {
    s := testStore(t)

    // Enqueue
    enqResult, _ := s.Enqueue(store.EnqueueRequest{
        Queue:   "test.q",
        Payload: json.RawMessage(`{"key":"value"}`),
    })

    // Act
    status, err := s.CancelJob(enqResult.JobID)
    require.NoError(t, err)
    assert.Equal(t, "cancelled", status)

    // Verify via second store call
    job, err := s.GetJob(enqResult.JobID)
    require.NoError(t, err)
    assert.Equal(t, "cancelled", job.State)
}
```

For verifying internal state, query SQLite directly:
```go
da, _ := raft.NewDirectApplier(t.TempDir())
var state string
da.SQLiteDB().QueryRow("SELECT state FROM jobs WHERE id = ?", jobID).Scan(&state)
```

### Server Tests (`internal/server/server_test.go`)
Use `testServer(t)` which returns `*httptest.Server`. Test HTTP API directly:

```go
func testServer(t *testing.T) (*httptest.Server, *store.Store) {
    da, _ := raft.NewDirectApplier(t.TempDir())
    t.Cleanup(func() { da.Close() })
    s := store.NewStore(da, da.SQLiteDB())
    srv := server.New(s, mockCluster{isLeader: true}, ":0", nil)
    ts := httptest.NewServer(srv.Handler())
    t.Cleanup(ts.Close)
    return ts, s
}
```

Mock cluster types for server tests:
```go
type mockCluster struct {
    isLeader   bool
    leaderAddr string
}
func (m mockCluster) IsLeader() bool     { return m.isLeader }
func (m mockCluster) LeaderAddr() string { return m.leaderAddr }
// ... other interface methods
```

Also: `mockClusterWithVoter` (records `AddVoter` calls), `mockShardCluster` (shard-aware routing).

### FSM Tests (`internal/raft/fsm_*_test.go`)
Test at the `DirectApplier.Apply()` level, bypassing the Store wrapper:

```go
func TestMultiEnqueue(t *testing.T) {
    da, _ := NewDirectApplier(t.TempDir())
    defer da.Close()

    result := da.Apply(store.OpEnqueue, store.EnqueueOp{
        Queue:   "test",
        Payload: json.RawMessage(`{}`),
    })
    require.NoError(t, result.Err)
}
```

### Raft Cluster Tests (`internal/raft/cluster_test.go`)
Test real multi-node Raft clusters:

```go
func testCluster(t *testing.T, nodeID, addr string, bootstrap bool) *Cluster
func testRaftAddr(t *testing.T) string                    // free port
func waitFor(t *testing.T, timeout time.Duration, fn func() bool, msg string)
func waitForLeaderFrom(t *testing.T, clusters []*Cluster, timeout time.Duration) *Cluster
func addVoterWithRetry(t *testing.T, leader *Cluster, nodeID, addr string)
func waitForJob(t *testing.T, s *store.Store, jobID string, timeout time.Duration)
func waitForJobCount(t *testing.T, db *sql.DB, want int, timeout time.Duration)
```

### Integration Tests (`tests/integration/integration_test.go`)
Full-stack via `httptest.Server`:

```go
type testEnv struct {
    client *client.Client
    sched  *scheduler.Scheduler
    url    string
    httpC  *http.Client
}

func setup(t *testing.T) *testEnv {
    da, _ := raft.NewDirectApplier(t.TempDir())
    s := store.NewStore(da, da.SQLiteDB())
    sched := scheduler.New(s, nil, scheduler.DefaultConfig(), nil)
    srv := server.New(s, nil, ":0", nil)
    ts := httptest.NewServer(srv.Handler())
    return &testEnv{client: client.New(ts.URL), sched: sched, url: ts.URL, httpC: ts.Client()}
}
```

Call `e.sched.RunOnce()` to synchronously trigger the scheduler (promote/reclaim).

### Perf Tests (`tests/perf/perf_test.go`)
Start real server subprocess:

```go
func startRealServer(t *testing.T, durable bool) string {
    cmd := exec.Command("go", "run", "./cmd/corvo", "server",
        "--bind", httpAddr, "--data-dir", dataDir,
        "--raft-bind", raftAddr, "--raft-advertise", raftAddr,
        "--rate-limit-enabled=false",
    )
    cmd.Dir = repoRoot(t)
    cmd.Start()
    waitForHealth(t, "http://"+httpAddr, 20*time.Second)
    return "http://" + httpAddr
}
```

Perf env vars (with defaults):
| Variable | Default |
|----------|---------|
| `CORVO_PERF_E2E_ENQ_TOTAL` | 4000 |
| `CORVO_PERF_E2E_ENQ_CONCURRENCY` | 10 |
| `CORVO_PERF_E2E_ENQ_MIN_OPS` | 100.0 |
| `CORVO_PERF_E2E_LC_TOTAL` | 3000 |
| `CORVO_PERF_E2E_STREAM_MIN_OPS` | 200.0 |

## No Mocks for Storage

The codebase uses `DirectApplier` (real Pebble + SQLite) instead of mocking the storage layer. The only mocks are for the cluster interface (`mockCluster`, `mockShardCluster`) used in HTTP server tests to control leader/follower behavior.

## Test Data

No static fixtures. All test data is created inline:
```go
s.Enqueue(store.EnqueueRequest{
    Queue:   "test.queue",
    Payload: json.RawMessage(`{"key":"value"}`),
})
```

Temp directories always via `t.TempDir()` (auto-cleaned).
