# sqlite-queue-counts Invariant Failure Analysis

**Date**: 2026-03-10
**Issue**: 47/50 seeds fail with KV vs SQLite state mismatch

## Root Cause: `sqliteBulkAction` Move has no state guard

Compare the KV and SQLite handlers for `BulkActionMove`:

**KV side** (`ops_bulk.go:161-164`):
```go
case store.BulkActionMove:
    if !canMove(job) {   // only allows Pending, Scheduled, Retrying
        errCount++
        continue         // SKIP — job not moved in KV
    }
```

**SQLite mirror** (`queries.go:620-628`):
```go
case store.BulkActionMove:
    db.Exec("UPDATE jobs SET queue = ? WHERE id IN (%s)", ...)  // NO state guard!
```

The SQLite handler unconditionally updates the queue for **all** listed job IDs. When a job has changed state since the client tracked it (e.g., enqueued as pending, then fetched by another client → now active), the KV side correctly skips the move, but SQLite blindly changes the queue. This produces:

- **KV**: job X in `sim-queue-0`, state=active
- **SQLite**: job X in `sim-queue-1`, state=active (wrongly moved)

The invariant then sees different counts for both queues.

**Why 47/50**: The simulator's `maybeBulkAction` and `maybeMoveJob` pick from `pendingJobs`, a list that gets stale as other clients fetch those jobs. With 3+ clients and high operation rates, it's nearly guaranteed that at least one move attempt targets a now-active job in every seed.

## Secondary Bug: `sqliteBulkAction` Delete has no state guard

**KV side** (`ops_bulk.go:57-60`):
```go
case store.BulkActionDelete:
    if job.State == store.StateActive {
        errCount++
        continue         // Active jobs are NOT deleted
    }
```

**SQLite mirror** (`queries.go:608-614`):
```go
case store.BulkActionDelete:
    db.Exec("DELETE FROM jobs WHERE id IN (%s)", ...)  // Deletes ALL, including active
```

If `maybeDeleteJob` targets a terminal job that was retried and is now active/pending, SQLite deletes it while KV keeps it.

## Minor Bug: `sqliteBulkAction` Hold state mismatch

**KV** allows hold from: `Pending, Scheduled, Retrying` (NOT Active)
**SQLite** allows: `'pending', 'active', 'scheduled', 'retrying'` (includes Active)

The simulator only holds from `pendingJobs` so this likely doesn't trigger, but it's an inconsistency.

## Invariant Audit (Post-Refactor)

The invariants are **structurally sound** for the new architecture:

1. **`StateCancelled` not counted by either side** — Both the KV switch and SQLite switch skip `StateCancelled`. Symmetric (won't cause count mismatch), but cancelled jobs are invisible to the invariant.

2. **Single-shard assumption is safe** — `SimNode.KVStore()` returns `KVShard(0)`, sim defaults to 1 shard. If multi-shard simulation is added, the `j|` prefix scan would need to iterate all shards.

3. **`deleteAllQueueJobs` leaves terminal/held jobs** — `ClearQueue`'s SQLite handler correctly mirrors this by only deleting `state IN ('pending', 'active', 'scheduled', 'retrying')`. `DeleteQueue` removes `qn|`, making the invariant skip orphaned terminal jobs. Both correct.

4. **KV invariants still valid** — All index checks use the same key prefixes and `ops.DecodeJob()` vtprotobuf decoding, consistent with the refactored write path.

5. **Mirror WaitForDrain works with SimClock** — Ticker fires on `clock.Advance()`, mirror flushes from ticks or eager-drain. `WaitForDrain()` busy-waits on atomics correctly.

## Fix

Add state guards to `sqliteBulkAction` matching the KV-side guards:

- **Move**: `WHERE id IN (%s) AND state IN ('pending', 'scheduled', 'retrying')`
- **Delete**: `WHERE id IN (%s) AND state != 'active'`
- **Hold**: Remove `'active'` from the WHERE clause
- **Invariant**: Consider adding `StateCancelled` to both count switches
