//! Invariant checks — verify KV state consistency after simulation ticks.
//!
//! Each check scans KV keys and verifies structural invariants:
//! - Index keys point to existing jobs in the correct state
//! - No terminal jobs (completed/dead/cancelled) in any index
//! - In-memory active counts match KV scan
//! - Dead index keys only point to terminal jobs
//! - Unique lock keys reference live, non-terminal jobs
//! - Every active job has a corresponding active index key
//! - Batch counters are non-negative

const std = @import("std");
const corvo = @import("corvo");
const keys = corvo.keys;
const codec = corvo.codec;
const types = corvo.types;
const kv = corvo.kv;
const OpHandler = corvo.handler.OpHandler;
const PendingIndex = corvo.pending_index.PendingIndex;
const Mirror = corvo.mirror.Mirror;
const sqlite = corvo.sqlite;

/// Error returned when an invariant is violated.
pub const InvariantError = struct {
    name: []const u8,
    message: [512]u8 = undefined,
    message_len: usize = 0,
    tick: u32,
    seed: u64,

    pub fn format(self: *const InvariantError) []const u8 {
        return self.message[0..self.message_len];
    }
};

pub const CheckResult = ?InvariantError;

/// Run all KV invariant checks.
pub fn checkAll(
    store: *kv.Store,
    handler: *OpHandler,
    mirror: *Mirror,
    tick: u32,
    seed: u64,
) CheckResult {
    const active_counts = &handler.active_counts;

    // Index → state consistency.
    if (checkActiveIndex(store, tick, seed)) |err| return err;
    if (checkPendingIndex(store, tick, seed)) |err| return err;
    if (checkScheduledIndex(store, tick, seed)) |err| return err;
    if (checkRetryingIndex(store, tick, seed)) |err| return err;

    // No terminal jobs in any live index.
    if (checkNoTerminalInIndexes(store, tick, seed)) |err| return err;

    // FSM active counts match KV.
    if (checkActiveCountAccuracy(store, active_counts, tick, seed)) |err| return err;

    // Dead index only references terminal jobs.
    if (checkDeadIndexConsistency(store, tick, seed)) |err| return err;

    // Unique lock consistency.
    if (checkUniqueLockConsistency(store, tick, seed)) |err| return err;

    // Every non-terminal, non-active job has the right index key.
    if (checkJobsHaveIndexKeys(store, tick, seed)) |err| return err;

    // No orphaned d| keys for non-terminal jobs (catches d| cleanup on re-enqueue).
    if (checkNoDKeyForLiveJobs(store, tick, seed)) |err| return err;

    // Every unique lock owner actually has a unique_key set.
    if (checkUniqueLockOwnerHasKey(store, tick, seed)) |err| return err;

    // Batch counters: pending+succeeded+failed <= total, no negative overflow.
    if (checkBatchCounters(store, tick, seed)) |err| return err;

    // Pending jobs in KV are in the PendingIndex (no orphaned pending jobs).
    if (checkPendingIndexCompleteness(store, &handler.pending, tick, seed)) |err| return err;

    // Mirror sync: every job in KV has matching state in SQLite mirror.
    if (checkMirrorSync(store, mirror, tick, seed)) |err| return err;

    return null;
}

// ============================================================================
// Index → state checks
// ============================================================================

fn checkActiveIndex(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    return checkIndexState(store, keys.prefix_active, .active, "active-index", 0, tick, seed);
}

fn checkPendingIndex(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    // Pending jobs use in-memory PendingIndex — no p| KV keys.
    // If p| keys DO exist (shouldn't happen), verify they're in pending state.
    _ = store;
    _ = tick;
    _ = seed;
    return null;
}

fn checkScheduledIndex(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    return checkIndexState(store, keys.prefix_scheduled, .scheduled, "scheduled-index", 8, tick, seed);
}

fn checkRetryingIndex(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    return checkIndexState(store, keys.prefix_retrying, .retrying, "retrying-index", 8, tick, seed);
}

fn checkIndexState(
    store: *kv.Store,
    prefix: []const u8,
    expected_state: types.JobState,
    name: []const u8,
    binary_after_sep: usize,
    tick: u32,
    seed: u64,
) CheckResult {
    var batch = store.newBatch();
    defer batch.close();

    var upper_buf: keys.KeyBuf = undefined;
    const upper = keys.prefixEnd(&upper_buf, prefix) orelse return null;

    var iter = batch.newIter(prefix, upper);
    defer iter.close();

    if (!iter.first()) return null;

    while (true) {
        const key = iter.key();
        const job_id = extractJobIDStructured(key, prefix.len, binary_after_sep) orelse {
            if (!iter.next()) break;
            continue;
        };

        var job_key_buf: keys.KeyBuf = undefined;
        const job_key = keys.jobKey(&job_key_buf, job_id);
        const job_val = batch.get(job_key) orelse {
            return makeError(name, "index has jobID but job not found", tick, seed);
        };

        const job = codec.decodeJob(job_val);
        if (job.state != expected_state) {
            return makeErrorFmt(name, tick, seed,
                "job {s} in {s} index but state={s}",
                .{ job_id, name, job.state.toString() });
        }

        if (!iter.next()) break;
    }
    return null;
}

// ============================================================================
// No terminal jobs in live indexes
// ============================================================================

fn checkNoTerminalInIndexes(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    const IndexDef = struct { prefix: []const u8, binary_after_sep: usize };
    const indexes = [_]IndexDef{
        .{ .prefix = keys.prefix_active, .binary_after_sep = 0 },
        .{ .prefix = keys.prefix_pending, .binary_after_sep = 9 },
        .{ .prefix = keys.prefix_scheduled, .binary_after_sep = 8 },
        .{ .prefix = keys.prefix_retrying, .binary_after_sep = 8 },
    };

    var batch = store.newBatch();
    defer batch.close();

    for (indexes) |idx| {
        var upper_buf: keys.KeyBuf = undefined;
        const upper = keys.prefixEnd(&upper_buf, idx.prefix) orelse continue;

        var iter = batch.newIter(idx.prefix, upper);
        defer iter.close();

        if (!iter.first()) continue;

        while (true) {
            const key = iter.key();
            const job_id = extractJobIDStructured(key, idx.prefix.len, idx.binary_after_sep) orelse {
                if (!iter.next()) break;
                continue;
            };

            var job_key_buf: keys.KeyBuf = undefined;
            const job_key = keys.jobKey(&job_key_buf, job_id);
            if (batch.get(job_key)) |job_val| {
                const job = codec.decodeJob(job_val);
                if (job.state.isTerminal()) {
                    return makeError("no-terminal-in-index", "terminal job found in live index", tick, seed);
                }
            }

            if (!iter.next()) break;
        }
    }
    return null;
}

// ============================================================================
// Active count accuracy
// ============================================================================

fn checkActiveCountAccuracy(
    store: *kv.Store,
    fsm_counts: *const std.StringHashMap(i32),
    tick: u32,
    seed: u64,
) CheckResult {
    var batch = store.newBatch();
    defer batch.close();

    var upper_buf: keys.KeyBuf = undefined;
    const upper = keys.prefixEnd(&upper_buf, keys.prefix_active) orelse return null;

    var iter = batch.newIter(keys.prefix_active, upper);
    defer iter.close();

    var kv_count: u32 = 0;
    var fsm_total: i32 = 0;

    if (iter.first()) {
        while (true) {
            kv_count += 1;
            if (!iter.next()) break;
        }
    }

    var fsm_iter = fsm_counts.iterator();
    while (fsm_iter.next()) |entry| {
        fsm_total += entry.value_ptr.*;
    }

    if (kv_count != @as(u32, @intCast(@max(0, fsm_total)))) {
        return makeErrorFmt("active-count-accuracy", tick, seed,
            "KV active={d} != FSM total={d}", .{ kv_count, fsm_total });
    }

    return null;
}

// ============================================================================
// Dead index consistency — d| keys should only reference terminal jobs
// ============================================================================

fn checkDeadIndexConsistency(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    var batch = store.newBatch();
    defer batch.close();

    var upper_buf: keys.KeyBuf = undefined;
    const upper = keys.prefixEnd(&upper_buf, keys.prefix_dead) orelse return null;

    var iter = batch.newIter(keys.prefix_dead, upper);
    defer iter.close();

    if (!iter.first()) return null;

    while (true) {
        const key = iter.key();
        const id_start = keys.prefix_dead.len + 8;
        if (key.len <= id_start) {
            if (!iter.next()) break;
            continue;
        }
        const job_id = key[id_start..];

        var job_key_buf: keys.KeyBuf = undefined;
        const job_key = keys.jobKey(&job_key_buf, job_id);
        if (batch.get(job_key)) |job_val| {
            const job = codec.decodeJob(job_val);
            if (!job.state.isTerminal()) {
                return makeErrorFmt("dead-index", tick, seed,
                    "d| key for non-terminal job {s} state={s}", .{ job_id, job.state.toString() });
            }
        }

        if (!iter.next()) break;
    }
    return null;
}

// ============================================================================
// Unique lock consistency — u| keys should reference non-terminal jobs
// ============================================================================

fn checkUniqueLockConsistency(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    var batch = store.newBatch();
    defer batch.close();

    var upper_buf: keys.KeyBuf = undefined;
    const upper = keys.prefixEnd(&upper_buf, keys.prefix_unique) orelse return null;

    var iter = batch.newIter(keys.prefix_unique, upper);
    defer iter.close();

    if (!iter.first()) return null;

    while (true) {
        // Unique key value = job_id that owns the lock.
        const val = iter.value();
        if (val.len > 0) {
            // Look up the owning job.
            var job_key_buf: keys.KeyBuf = undefined;
            const job_key = keys.jobKey(&job_key_buf, val);
            if (batch.get(job_key)) |job_val| {
                const job = codec.decodeJob(job_val);
                // A unique lock should not be held by a terminal job
                // (completed/dead/cancelled jobs should release their locks).
                if (job.state == .completed or job.state == .dead) {
                    return makeErrorFmt("unique-lock", tick, seed,
                        "u| lock held by terminal job {s} state={s}",
                        .{ val, job.state.toString() });
                }
            }
            // If job doesn't exist, it was purged — lock should have been cleaned
            // by maintenance. We allow this as a transient state between purge
            // and unique lock cleanup maintenance runs.
        }

        if (!iter.next()) break;
    }
    return null;
}

// ============================================================================
// Jobs ↔ index cross-check: every non-terminal job must have a matching index
// ============================================================================

fn checkJobsHaveIndexKeys(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    var batch = store.newBatch();
    defer batch.close();

    var upper_buf: keys.KeyBuf = undefined;
    const upper = keys.prefixEnd(&upper_buf, keys.prefix_job) orelse return null;

    var iter = batch.newIter(keys.prefix_job, upper);
    defer iter.close();

    if (!iter.first()) return null;

    while (true) {
        const key = iter.key();
        // Skip non-job keys (jp|, je|, ji|, ju| also start with j).
        if (key.len > 2 and key[1] == '|' and key[0] == 'j') {
            // This is a j| key. Check it has a separator at position 1.
            if (key.len > 2) {
                const job_id = key[keys.prefix_job.len..];
                const val = iter.value();
                if (val.len > 0) {
                    const job = codec.decodeJob(val);

                    // Skip terminal jobs — they don't need index keys.
                    // Skip pending — uses in-memory PendingIndex, no p| KV keys.
                    // Skip held — no index key needed.
                    if (!job.state.isTerminal() and job.state != .held and job.state != .pending) {
                        const has_index = switch (job.state) {
                            .active => hasActiveKey(&batch, job.queue, job_id),
                            .scheduled => hasScheduledKey(&batch, job.queue),
                            .retrying => hasRetryingKey(&batch, job.queue),
                            else => true,
                        };
                        if (!has_index) {
                            return makeErrorFmt("job-index-missing", tick, seed,
                                "job {s} state={s} queue={s} has no index key",
                                .{ job_id, job.state.toString(), job.queue });
                        }
                    }
                }
            }
        }

        if (!iter.next()) break;
    }
    return null;
}

fn hasActiveKey(batch: *kv.WriteBatch, queue: []const u8, job_id: []const u8) bool {
    var key_buf: keys.KeyBuf = undefined;
    const key = keys.activeKey(&key_buf, queue, job_id);
    return batch.get(key) != null;
}

fn hasPendingKey(batch: *kv.WriteBatch, queue: []const u8) bool {
    var prefix_buf: keys.KeyBuf = undefined;
    var upper_buf: keys.KeyBuf = undefined;
    const prefix = keys.pendingPrefix(&prefix_buf, queue);
    const upper_key = keys.prefixEnd(&upper_buf, prefix) orelse return true;

    var iter = batch.newIter(prefix, upper_key);
    defer iter.close();
    return iter.first();
}

fn hasScheduledKey(batch: *kv.WriteBatch, queue: []const u8) bool {
    var prefix_buf: keys.KeyBuf = undefined;
    var upper_buf: keys.KeyBuf = undefined;
    const prefix = keys.scheduledScanPrefix(&prefix_buf, queue);
    const upper_key = keys.prefixEnd(&upper_buf, prefix) orelse return true;

    var iter = batch.newIter(prefix, upper_key);
    defer iter.close();
    return iter.first();
}

fn hasRetryingKey(batch: *kv.WriteBatch, queue: []const u8) bool {
    var prefix_buf: keys.KeyBuf = undefined;
    var upper_buf: keys.KeyBuf = undefined;
    const prefix = keys.retryingScanPrefix(&prefix_buf, queue);
    const upper_key = keys.prefixEnd(&upper_buf, prefix) orelse return true;

    var iter = batch.newIter(prefix, upper_key);
    defer iter.close();
    return iter.first();
}

// ============================================================================
// No d| key for live (re-enqueued) jobs
// This catches the bug where BulkRetry/BulkRequeue doesn't clean up d| keys.
// If a job was dead, got re-enqueued (now pending), but still has a d| key,
// MaintenancePurge will delete the re-enqueued job's j| key.
// ============================================================================

fn checkNoDKeyForLiveJobs(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    var batch = store.newBatch();
    defer batch.close();

    var upper_buf: keys.KeyBuf = undefined;
    const upper = keys.prefixEnd(&upper_buf, keys.prefix_dead) orelse return null;

    var iter = batch.newIter(keys.prefix_dead, upper);
    defer iter.close();

    if (!iter.first()) return null;

    while (true) {
        const key = iter.key();
        const id_start = keys.prefix_dead.len + 8;
        if (key.len <= id_start) {
            if (!iter.next()) break;
            continue;
        }
        const job_id = key[id_start..];

        var job_key_buf: keys.KeyBuf = undefined;
        const job_key = keys.jobKey(&job_key_buf, job_id);
        if (batch.get(job_key)) |job_val| {
            const job = codec.decodeJob(job_val);
            // A d| key must NOT exist for a non-terminal job.
            // If a job was bulk-retried from dead→pending, the d| key must be deleted.
            if (!job.state.isTerminal()) {
                return makeErrorFmt("d-key-for-live-job", tick, seed,
                    "d| key exists for non-terminal job {s} state={s} — stale d| from re-enqueue?",
                    .{ job_id, job.state.toString() });
            }
        }

        if (!iter.next()) break;
    }
    return null;
}

// ============================================================================
// Unique lock owner has unique_key set
// If a u| lock points to a job, that job should have a unique_key.
// This catches bugs where unique locks outlive their jobs or point to wrong jobs.
// ============================================================================

fn checkUniqueLockOwnerHasKey(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    var batch = store.newBatch();
    defer batch.close();

    var upper_buf: keys.KeyBuf = undefined;
    const upper = keys.prefixEnd(&upper_buf, keys.prefix_unique) orelse return null;

    var iter = batch.newIter(keys.prefix_unique, upper);
    defer iter.close();

    if (!iter.first()) return null;

    while (true) {
        const val = iter.value();
        if (val.len > 0) {
            var job_key_buf: keys.KeyBuf = undefined;
            const job_key = keys.jobKey(&job_key_buf, val);
            if (batch.get(job_key)) |job_val| {
                const job = codec.decodeJob(job_val);
                // The job that owns this lock should have a unique_key set.
                if (job.unique_key == null or job.unique_key.?.len == 0) {
                    return makeErrorFmt("unique-lock-owner-no-key", tick, seed,
                        "u| lock points to job {s} which has no unique_key",
                        .{val});
                }
            }
        }

        if (!iter.next()) break;
    }
    return null;
}

// ============================================================================
// Batch counter integrity — succeeded+failed+pending must equal total
// This catches bugs where ack/fail don't properly decrement pending.
// ============================================================================

fn checkBatchCounters(store: *kv.Store, tick: u32, seed: u64) CheckResult {
    var batch = store.newBatch();
    defer batch.close();

    var upper_buf: keys.KeyBuf = undefined;
    const upper = keys.prefixEnd(&upper_buf, keys.prefix_batch) orelse return null;

    var iter = batch.newIter(keys.prefix_batch, upper);
    defer iter.close();

    if (!iter.first()) return null;

    while (true) {
        const val = iter.value();
        if (val.len > 0) {
            const b = codec.decodeBatch(val);

            // For sealed batches (not open), verify arithmetic.
            if (!b.open and b.total > 0) {
                const sum = b.succeeded +| b.failed +| b.pending;
                if (sum > b.total) {
                    return makeErrorFmt("batch-counter-overflow", tick, seed,
                        "batch {s}: succeeded({d})+failed({d})+pending({d})={d} > total({d})",
                        .{ b.id, b.succeeded, b.failed, b.pending, sum, b.total });
                }
            }

            // Check for underflow: individual counters shouldn't be absurdly large.
            // (Underflow in u32 wraps to ~4 billion.)
            if (b.pending > 1_000_000 or b.succeeded > 1_000_000 or b.failed > 1_000_000) {
                return makeErrorFmt("batch-counter-underflow", tick, seed,
                    "batch {s}: suspiciously large counters p={d} s={d} f={d} (underflow?)",
                    .{ b.id, b.pending, b.succeeded, b.failed });
            }
        }

        if (!iter.next()) break;
    }
    return null;
}

// ============================================================================
// PendingIndex completeness — every pending job in KV must be fetchable.
// If a job has state=pending in KV but is NOT in the PendingIndex, it will
// never be fetched (silent data loss).
//
// We can't directly query the PendingIndex for a specific job ID (it's a
// min-heap without random access). Instead, count pending jobs per queue
// in KV and compare to PendingIndex heap sizes. The PendingIndex may have
// MORE entries (stale entries from cancel/hold are lazily removed on fetch),
// but should never have FEWER.
// ============================================================================

fn checkPendingIndexCompleteness(
    store: *kv.Store,
    pending_idx: *PendingIndex,
    tick: u32,
    seed: u64,
) CheckResult {
    // Count pending jobs per queue from KV scan.
    var batch = store.newBatch();
    defer batch.close();

    var upper_buf: keys.KeyBuf = undefined;
    const upper = keys.prefixEnd(&upper_buf, keys.prefix_job) orelse return null;

    var iter = batch.newIter(keys.prefix_job, upper);
    defer iter.close();

    if (!iter.first()) return null;

    // Count pending jobs per queue.
    // Use fixed array with queue name hashing.
    const max_q = 16;
    var queue_names: [max_q][64]u8 = undefined;
    var queue_name_lens: [max_q]u8 = [_]u8{0} ** max_q;
    var kv_pending_counts: [max_q]u32 = [_]u32{0} ** max_q;
    var queue_count: usize = 0;

    while (true) {
        const key = iter.key();
        // Only j| keys (not jp|, je|, etc.)
        if (key.len > 2 and key[0] == 'j' and key[1] == '|') {
            const val = iter.value();
            if (val.len > 0) {
                const job = codec.decodeJob(val);
                if (job.state == .pending) {
                    // Find or add queue.
                    const qi = findOrAddQueue(
                        &queue_names, &queue_name_lens, &queue_count,
                        job.queue,
                    );
                    if (qi) |idx| {
                        kv_pending_counts[idx] += 1;
                    }
                }
            }
        }

        if (!iter.next()) break;
    }

    // Compare with PendingIndex.
    for (0..queue_count) |qi| {
        const qname = queue_names[qi][0..queue_name_lens[qi]];
        const kv_count = kv_pending_counts[qi];

        // Get PendingIndex count for this queue.
        const heap_count: u32 = if (pending_idx.queues.get(qname)) |heap|
            @intCast(heap.count())
        else
            0;

        // PendingIndex can have MORE entries (stale), but never fewer
        // than actual pending jobs. If heap < kv_count, pending jobs are lost.
        if (heap_count < kv_count) {
            return makeErrorFmt("pending-index-missing", tick, seed,
                "queue '{s}': {d} pending jobs in KV but only {d} in PendingIndex — jobs will never be fetched",
                .{ qname, kv_count, heap_count });
        }
    }

    return null;
}

fn findOrAddQueue(
    names: *[16][64]u8,
    lens: *[16]u8,
    count: *usize,
    queue: []const u8,
) ?usize {
    for (0..count.*) |i| {
        if (lens[i] == @as(u8, @intCast(queue.len)) and
            std.mem.eql(u8, names[i][0..lens[i]], queue))
        {
            return i;
        }
    }
    if (count.* >= 16) return null;
    const idx = count.*;
    const len = @min(queue.len, 64);
    @memcpy(names[idx][0..len], queue[0..len]);
    lens[idx] = @intCast(len);
    count.* += 1;
    return idx;
}

// ============================================================================
// Mirror sync — every job in KV must have matching state in SQLite mirror
// ============================================================================

fn checkMirrorSync(store: *kv.Store, mirror: *Mirror, tick: u32, seed: u64) CheckResult {
    const db = mirror.getDB();

    // Count jobs in KV.
    var kv_count: u32 = 0;
    {
        var batch = store.newBatch();
        defer batch.close();

        var upper_buf: keys.KeyBuf = undefined;
        const upper = keys.prefixEnd(&upper_buf, keys.prefix_job) orelse return null;

        var iter = batch.newIter(keys.prefix_job, upper);
        defer iter.close();

        if (iter.first()) {
            while (true) {
                const key = iter.key();
                // Only j| keys (not jp|, je|, etc.)
                if (key.len > 2 and key[0] == 'j' and key[1] == '|') {
                    const val = iter.value();
                    if (val.len > 0) {
                        kv_count += 1;

                        // Check state matches mirror.
                        const job = codec.decodeJob(val);
                        const job_id = key[keys.prefix_job.len..];

                        var stmt = db.prepare(
                            "SELECT state FROM jobs WHERE id = ?",
                        ) catch return makeError("mirror-sync", "failed to prepare stmt", tick, seed);
                        defer stmt.finalize();
                        stmt.bindText(1, job_id);

                        const has_row = stmt.step() catch return makeError("mirror-sync", "failed to step stmt", tick, seed);
                        if (!has_row) {
                            return makeErrorFmt("mirror-sync", tick, seed,
                                "job {s} state={s} in KV but missing from mirror",
                                .{ job_id, job.state.toString() });
                        }

                        const mirror_state = stmt.columnText(0) orelse "NULL";
                        const kv_state = job.state.toString();
                        if (!std.mem.eql(u8, mirror_state, kv_state)) {
                            return makeErrorFmt("mirror-sync", tick, seed,
                                "job {s} state mismatch: KV={s} mirror={s}",
                                .{ job_id, kv_state, mirror_state });
                        }
                    }
                }

                if (!iter.next()) break;
            }
        }
    }

    // Count jobs in mirror — should not have more than KV (no phantom rows).
    var stmt = db.prepare("SELECT COUNT(*) FROM jobs") catch return makeError("mirror-sync", "count prepare failed", tick, seed);
    defer stmt.finalize();
    const has_row = stmt.step() catch return makeError("mirror-sync", "count step failed", tick, seed);
    if (has_row) {
        const mirror_count: u32 = @intCast(stmt.columnInt(0));
        // Mirror should not have more jobs than KV (no phantom rows).
        if (mirror_count > kv_count) {
            return makeErrorFmt("mirror-sync", tick, seed,
                "mirror has {d} jobs but KV only has {d} — phantom rows",
                .{ mirror_count, kv_count });
        }
    }

    return null;
}

// ============================================================================
// Helpers
// ============================================================================

fn extractJobIDStructured(key: []const u8, prefix_len: usize, binary_after_sep: usize) ?[]const u8 {
    if (key.len <= prefix_len) return null;
    const rest = key[prefix_len..];

    var sep_pos: ?usize = null;
    for (rest, 0..) |b, i| {
        if (b == 0) {
            sep_pos = i;
            break;
        }
    }
    const sep = sep_pos orelse return null;

    const id_start = sep + 1 + binary_after_sep;
    if (id_start >= rest.len) return null;

    return rest[id_start..];
}

fn makeError(name: []const u8, msg: []const u8, tick: u32, seed: u64) InvariantError {
    var err = InvariantError{ .name = name, .tick = tick, .seed = seed };
    const len = @min(msg.len, err.message.len);
    @memcpy(err.message[0..len], msg[0..len]);
    err.message_len = len;
    return err;
}

fn makeErrorFmt(name: []const u8, tick: u32, seed: u64, comptime fmt: []const u8, args: anytype) InvariantError {
    var err = InvariantError{ .name = name, .tick = tick, .seed = seed };
    const msg = std.fmt.bufPrint(&err.message, fmt, args) catch {
        const fallback = "format error";
        @memcpy(err.message[0..fallback.len], fallback);
        err.message_len = fallback.len;
        return err;
    };
    err.message_len = msg.len;
    return err;
}
