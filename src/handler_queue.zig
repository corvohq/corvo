//! Queue handler — queue config, clear, delete.
//! Ported from Go internal/ops/ops_queue.go + helpers.go.

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;
const batcher = @import("raft_batcher.zig");

/// Byte budget for ONE clear/delete invocation's recorded mutations. In
/// cluster mode a client frame's mutations are replicated as a single raft
/// entry (the pipeline's proposeRecordedFrames splits at frame boundaries
/// only — one op's mutations must apply atomically on followers), capped at
/// raft_batcher.max_entry_bytes. An unbounded clear/delete would blow that
/// cap AFTER the local commit — a divergence panic on legal input (B2) — so
/// each invocation deletes only as many jobs as provably fit and reports the
/// partial count in OpResult.affected; the client repeats until affected
/// drops to zero (clear) / the metadata pass completes (delete). Single-node
/// has no entry cap but uses the same budget to keep one code path (and
/// bound the tick latency of a huge clear).
/// The 8 KiB headroom covers the op's non-per-job mutations: qc| counter
/// rewrite, qa|/rate-limit/unique deleteRanges, queue metadata deletes, and
/// the HTTP audit entry that shares the frame's proposal segment.
const max_clear_mutation_bytes: usize = batcher.max_entry_bytes - 8192;

/// b| re-encode plus a possible batch-completion callback enqueue: the
/// callback job's queue and payload come from the batch record (each ≤
/// max_batch_encoded_size), plus the callback's own record, read indexes,
/// queue marker/counter and framing (< 4096).
const batch_adjust_bound: usize = 2 * codec.max_batch_encoded_size + 4096;

/// Deletion budget for one clear/delete invocation (B2).
const DeleteBudget = struct {
    remaining: usize = max_clear_mutation_bytes,
    exhausted: bool = false,

    /// Spend `cost` bytes; returns false (and latches exhausted) when the
    /// budget cannot cover it — the caller must stop BEFORE mutating.
    fn spend(self: *DeleteBudget, cost: usize) bool {
        if (self.exhausted or cost > self.remaining) {
            self.exhausted = true;
            return false;
        }
        self.remaining -= cost;
        return true;
    }
};

/// Per-state deletion counts for one clear/delete invocation, used to keep
/// queue counters consistent on a partial (budget-exhausted) pass.
const StateCounts = struct {
    counts: [8]u32 = [_]u32{0} ** 8,

    fn add(self: *StateCounts, state: types.JobState) void {
        self.counts[@intFromEnum(state)] += 1;
    }
    fn addN(self: *StateCounts, state: types.JobState, n: u32) void {
        self.counts[@intFromEnum(state)] += n;
    }
    fn total(self: *const StateCounts) u32 {
        var sum: u32 = 0;
        for (self.counts) |c| sum += c;
        return sum;
    }
    fn subtractFrom(self: *const StateCounts, q: *types.Queue) void {
        q.pending_count -|= self.counts[@intFromEnum(types.JobState.pending)];
        q.active_count -|= self.counts[@intFromEnum(types.JobState.active)];
        q.retrying_count -|= self.counts[@intFromEnum(types.JobState.retrying)];
        q.completed_count -|= self.counts[@intFromEnum(types.JobState.completed)];
        q.dead_count -|= self.counts[@intFromEnum(types.JobState.dead)];
        q.cancelled_count -|= self.counts[@intFromEnum(types.JobState.cancelled)];
        q.scheduled_count -|= self.counts[@intFromEnum(types.JobState.scheduled)];
        q.held_count -|= self.counts[@intFromEnum(types.JobState.held)];
    }
};

/// Over-estimate of the recorded-mutation bytes deleting ONE job produces:
/// ≤ 12 fixed-shape keys (the triggering index entry or dead key, expire,
/// active, the 4 read indexes, job record, payload, and both error-range
/// bounds) each ≤ framing + 14B prefix/timestamp + queue + id; plus the
/// tag-index deletes (tag pairs parse into ≥5-byte chunks whose content is
/// a subset of the tag string), the unique lock, and the batch-record
/// adjustment with its possible completion-callback enqueue.
fn jobDeleteBound(job: *const types.Job) usize {
    const fr: usize = 7; // oplog framing per mutation (op + keylen + vallen)
    const id = job.id.len;
    const q = job.queue.len;
    var total: usize = 12 * (fr + 14 + q + id);
    if (job.tags) |t| {
        if (t.len > 0) total += t.len + (t.len / 5) * (q + id + 13 + fr);
    }
    if (job.unique_key) |u| {
        if (u.len > 0) total += fr + (2 + q + 1 + u.len);
    }
    if (job.batch_id) |bid| {
        if (bid.len > 0) total += batch_adjust_bound;
    }
    return total;
}

pub fn applyQueueConfig(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.QueueOp) ops.OpResult {
    if (op.queue.len == 0 or op.queue.len > types.max_queue_name_len or
        std.mem.indexOfScalar(u8, op.queue, 0) != null)
        return .{ .err = "invalid queue" };
    var qn_buf: keys.KeyBuf = undefined;
    var qc_buf: keys.KeyBuf = undefined;
    const qc_key = keys.queueConfigKey(&qc_buf, op.queue);
    const qc_bytes = b.get(qc_key);
    const is_new = qc_bytes == null;

    // New queue — enforce resource limit.
    if (is_new and self.queue_configs.count() >= self.max_queues) {
        return .{ .err = "max queues exceeded" };
    }

    // Auto-create the queue name key if it doesn't exist yet.
    if (b.get(keys.queueNameKey(&qn_buf, op.queue)) == null) {
        b.set(keys.queueNameKey(&qn_buf, op.queue), "");
    }

    // Read from in-memory cache for existing queues to preserve counter
    // accuracy. The KV batch overlay may have stale counters when indexer
    // deltas (from enqueue/fetch in the same batch) haven't flushed yet.
    // For new queues, start from default; for existing, start from cache.
    var queue = if (self.queue_configs.get(op.queue)) |cached|
        cached
    else if (!is_new)
        codec.decodeQueue(qc_bytes.?)
    else
        types.Queue{};
    queue.name = op.queue;

    switch (op.action) {
        .concurrency => {
            queue.max_concurrency = op.max_concurrency;
        },
        .fairness => {
            queue.fairness = op.fairness;
        },
        .pause => {
            queue.paused = true;
        },
        .@"resume" => {
            queue.paused = false;
        },
        .throttle => {
            queue.rate_limit = op.rate_limit;
            queue.rate_window_ms = op.rate_window_ms;
            self.recomputeMaxRateWindow();
        },
        .clear, .delete => {
            assert.fail("clear/delete should not use applyQueueConfig", .{});
        },
    }

    var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
    b.set(qc_key, codec.encodeQueue(&qc_enc_buf, &queue));

    // Update in-memory cache.
    _ = self.putQueueConfig(op.queue, queue);
    return .{ .affected = 1 };
}

pub fn applyClearQueue(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.ClearQueueOp) ops.OpResult {
    if (op.queue.len == 0 or op.queue.len > types.max_queue_name_len or
        std.mem.indexOfScalar(u8, op.queue, 0) != null)
        return .{ .err = "invalid queue" };
    if (op.now_ns == 0) return .{ .err = "invalid queue timestamp" };
    var qn_buf: keys.KeyBuf = undefined;
    if (b.get(keys.queueNameKey(&qn_buf, op.queue)) == null) {
        return .{ .err = "queue not found" };
    }
    var budget = DeleteBudget{};
    var counts = StateCounts{};
    deleteAllQueueJobs(self, b, op.queue, op.now_ns, &budget, &counts);
    const deleted = counts.total();
    self.total_jobs -|= deleted;
    // PendingIndex already drained inside deleteAllQueueJobs.

    if (budget.exhausted) {
        // Partial clear (B2): one invocation's deletes are byte-budgeted so
        // the frame's raft proposal provably fits one entry. Subtract exactly
        // what was deleted from the counters (memory + KV); the completing
        // pass below hard-resets them. The client repeats until affected
        // reaches zero.
        if (self.queue_configs.getPtr(op.queue)) |q| counts.subtractFrom(q);
        var pqc_buf: keys.KeyBuf = undefined;
        var pqc_val_buf: [codec.max_queue_encoded_size]u8 = undefined;
        const pqc_key = keys.queueConfigKey(&pqc_buf, op.queue);
        if (b.getInto(pqc_key, &pqc_val_buf)) |qc_bytes| {
            var q = codec.decodeQueue(qc_bytes);
            counts.subtractFrom(&q);
            var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
            b.set(pqc_key, codec.encodeQueue(&qc_enc_buf, &q));
        }
        return .{
            .affected = deleted,
            .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
        };
    }

    // Reset in-memory counters for cleared states. deleteAllQueueJobs removes
    // pending, scheduled, and retrying jobs. Active and held jobs are NOT
    // deleted — active are in-flight, held need explicit approve/reject.
    if (self.queue_configs.getPtr(op.queue)) |q| {
        q.pending_count = 0;
        q.scheduled_count = 0;
        q.retrying_count = 0;
    }

    // Also zero counters in KV.
    var qc_buf: keys.KeyBuf = undefined;
    var qc_val_buf: [codec.max_queue_encoded_size]u8 = undefined;
    const qc_key = keys.queueConfigKey(&qc_buf, op.queue);
    if (b.getInto(qc_key, &qc_val_buf)) |qc_bytes| {
        var q = codec.decodeQueue(qc_bytes);
        q.pending_count = 0;
        q.scheduled_count = 0;
        q.retrying_count = 0;
        var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
        b.set(qc_key, codec.encodeQueue(&qc_enc_buf, &q));
    }

    // Drop this tick's accumulated pending/scheduled/retrying deltas for the
    // cleared queue. Otherwise the indexer's end-of-tick flush would re-apply
    // deltas from enqueues that happened earlier this tick (whose jobs the
    // clear just deleted) on top of the zeroed qc| counter — leaving KV
    // non-zero while memory says zero (M11). Post-clear enqueues in the same
    // tick re-accumulate their own deltas and flush correctly on top of zero.
    self.indexer.resetQueueStateDeltas(op.queue, &.{ .pending, .scheduled, .retrying });

    return .{
        .affected = deleted,
        .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
    };
}

pub fn applyDeleteQueue(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.DeleteQueueOp) ops.OpResult {
    if (op.queue.len == 0 or op.queue.len > types.max_queue_name_len or
        std.mem.indexOfScalar(u8, op.queue, 0) != null)
        return .{ .err = "invalid queue" };
    if (op.now_ns == 0) return .{ .err = "invalid queue timestamp" };
    var qn_buf: keys.KeyBuf = undefined;
    if (b.get(keys.queueNameKey(&qn_buf, op.queue)) == null) {
        return .{ .err = "queue not found" };
    }
    var budget = DeleteBudget{};
    var counts = StateCounts{};
    deleteAllQueueJobs(self, b, op.queue, op.now_ns, &budget, &counts);
    if (!budget.exhausted) deleteTerminalQueueJobs(self, b, op.queue, op.now_ns, &budget, &counts);
    const deleted = counts.total();
    self.total_jobs -|= deleted;
    // PendingIndex already drained inside deleteAllQueueJobs.

    if (budget.exhausted) {
        // Partial delete (B2): keep the queue registered (qn|/qc| survive) so
        // the client repeats the delete until the metadata pass below runs;
        // subtract the deleted jobs from the counters so reads stay sane
        // meanwhile.
        if (self.queue_configs.getPtr(op.queue)) |q| counts.subtractFrom(q);
        var pqc_buf: keys.KeyBuf = undefined;
        var pqc_val_buf: [codec.max_queue_encoded_size]u8 = undefined;
        const pqc_key = keys.queueConfigKey(&pqc_buf, op.queue);
        if (b.getInto(pqc_key, &pqc_val_buf)) |qc_bytes| {
            var q = codec.decodeQueue(qc_bytes);
            counts.subtractFrom(&q);
            var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
            b.set(pqc_key, codec.encodeQueue(&qc_enc_buf, &q));
        }
        return .{
            .affected = deleted,
            .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
        };
    }

    self.removeQueueConfig(op.queue);

    // Remove queue metadata and auxiliary data.
    b.delete(keys.queueNameKey(&qn_buf, op.queue));
    var qc_buf: keys.KeyBuf = undefined;
    b.delete(keys.queueConfigKey(&qc_buf, op.queue));
    var qcur_buf: keys.KeyBuf = undefined;
    b.delete(keys.queueCursorKey(&qcur_buf, op.queue));
    var up_buf: keys.KeyBuf = undefined;
    var upe_buf: keys.KeyBuf = undefined;
    const up = keys.uniquePrefix(&up_buf, op.queue);
    if (keys.prefixEnd(&upe_buf, up)) |end| {
        b.deleteRange(up, end);
    }

    return .{
        .affected = deleted,
        .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
    };
}

// ============================================================================
// Internal helpers
// ============================================================================

fn deleteAllQueueJobs(
    self: *OpHandler,
    b: *kv.WriteBatch,
    queue: []const u8,
    now_ns: u64,
    budget: *DeleteBudget,
    counts: *StateCounts,
) void {
    // NOTE: active jobs are NOT deleted — they have a worker processing them.
    // They will complete naturally via ack/fail, or be reclaimed by maintenance.

    // Delete scheduled jobs
    var sp_buf: keys.KeyBuf = undefined;
    var spe_buf: keys.KeyBuf = undefined;
    const sp = keys.scheduledScanPrefix(&sp_buf, queue);
    if (keys.prefixEnd(&spe_buf, sp)) |end| {
        counts.addN(.scheduled, deleteJobsByPrefix(self, b, sp, end, extractJobIDFromTimeSorted, now_ns, budget));
    }

    // Delete retrying jobs
    var rp_buf: keys.KeyBuf = undefined;
    var rpe_buf: keys.KeyBuf = undefined;
    const rp = keys.retryingScanPrefix(&rp_buf, queue);
    if (keys.prefixEnd(&rpe_buf, rp)) |end| {
        counts.addN(.retrying, deleteJobsByPrefix(self, b, rp, end, extractJobIDFromTimeSorted, now_ns, budget));
    }

    // Delete pending jobs — tracked in PendingIndex only (no KV index key).
    // Drain the index to get job IDs, then delete their KV data. Stale
    // entries (missing/moved/non-pending jobs) cost no mutations and are
    // dropped without touching the budget, exactly as before.
    while (!budget.exhausted) {
        const entry = self.pending.pop(queue) orelse break;
        const pjob_id = entry.jobId();
        var pjk_buf: keys.KeyBuf = undefined;
        const pjob_bytes = b.get(keys.jobKey(&pjk_buf, pjob_id));
        if (pjob_bytes == null) continue; // stale entry
        const pjob = codec.decodeJob(pjob_bytes.?);
        if (pjob.state != .pending) continue; // stale
        if (!std.mem.eql(u8, pjob.queue, queue)) continue; // wrong queue

        // Budget check BEFORE any of this job's mutations (B2). Restore the
        // popped entry so the repeat invocation deletes it.
        if (!budget.spend(jobDeleteBound(&pjob))) {
            self.pending.push(queue, 255 - entry.inv_priority, entry.created_ns, pjob_id);
            break;
        }

        // Clean up unique lock
        var puk_buf: keys.KeyBuf = undefined;
        if (OpHandler.jobUniqueKey(&puk_buf, &pjob)) |ukey| {
            if (b.get(ukey)) |ub| {
                const decoded = keys.decodeUniqueValue(ub);
                if (std.mem.eql(u8, decoded.job_id, pjob_id)) {
                    b.delete(ukey);
                }
            }
        }
        // Adjust batch
        if (pjob.batch_id) |batch_id| {
            if (batch_id.len > 0) {
                adjustBatchForDeletedJob(self, b, batch_id, now_ns);
            }
        }
        // Clear expire key
        if (pjob.expire_after_ms > 0 and pjob.expire_at_ns > 0) {
            var pxk_buf: keys.KeyBuf = undefined;
            b.delete(keys.expireKey(&pxk_buf, pjob.expire_at_ns, pjob_id));
        }
        // Clean up read indexes + tag indexes.
        OpHandler.deleteReadIndexes(b, &pjob);
        OpHandler.deleteTagIndexes(b, &pjob);
        b.delete(keys.jobKey(&pjk_buf, pjob_id));
        var pjpk_buf: keys.KeyBuf = undefined;
        b.delete(keys.jobPayloadKey(&pjpk_buf, pjob_id));
        var pjep_buf: keys.KeyBuf = undefined;
        var pjee_buf: keys.KeyBuf = undefined;
        const perr_prefix = keys.jobErrorPrefix(&pjep_buf, pjob_id);
        if (keys.prefixEnd(&pjee_buf, perr_prefix)) |perr_end| {
            b.deleteRange(perr_prefix, perr_end);
        }
        counts.add(.pending);
    }

    // Queue-wide cleanup runs only on the COMPLETING pass: qa| entries and
    // rate-limit data are still referenced while jobs remain, and the repeat
    // invocation reaches here once the budget covers the final job batch.
    if (budget.exhausted) return;

    // Clean up qa| with DeleteRange — do NOT iterate because qa| entries
    // persist for moved/completed/re-enqueued jobs.
    var qa_buf: keys.KeyBuf = undefined;
    var qae_buf: keys.KeyBuf = undefined;
    const qa = keys.queueAppendPrefix(&qa_buf, queue);
    if (keys.prefixEnd(&qae_buf, qa)) |end| {
        b.deleteRange(qa, end);
    }

    // Don't reset active counts — active jobs are still in flight.
    // Free the inner fairness map before removing — remove() drops the
    // entry but doesn't deinit the nested StringHashMap or its keys.
    if (self.fairness_served.getPtr(queue)) |inner| {
        var inner_it = inner.iterator();
        while (inner_it.next()) |ie| self.allocator.free(@constCast(ie.key_ptr.*));
        inner.deinit();
    }
    if (self.fairness_served.fetchRemove(queue)) |entry| {
        self.allocator.free(@constCast(entry.key));
    }

    // Delete rate limit data
    var rl_buf: keys.KeyBuf = undefined;
    var rle_buf: keys.KeyBuf = undefined;
    const rl = keys.rateLimitPrefix(&rl_buf, queue);
    if (keys.prefixEnd(&rle_buf, rl)) |end| {
        b.deleteRange(rl, end);
    }
}

fn deleteTerminalQueueJobs(
    self: *OpHandler,
    b: *kv.WriteBatch,
    queue: []const u8,
    now_ns: u64,
    budget: *DeleteBudget,
    counts: *StateCounts,
) void {
    var jp_buf: keys.KeyBuf = undefined;
    var jpe_buf: keys.KeyBuf = undefined;
    const jp = keys.prefix_job;
    @memcpy(jp_buf[0..jp.len], jp);
    const jp_slice = jp_buf[0..jp.len];
    if (keys.prefixEnd(&jpe_buf, jp_slice)) |end| {
        var iter = b.newIter(jp_slice, end);
        defer iter.close();

        if (iter.first()) {
            while (true) {
                const key = iter.key();
                const val = iter.value();
                const job = codec.decodeJob(val);
                if (!std.mem.eql(u8, job.queue, queue)) {
                    if (!iter.next()) break;
                    continue;
                }

                // Budget check BEFORE any of this job's mutations (B2).
                if (!budget.spend(jobDeleteBound(&job))) break;

                const job_id = key[jp.len..];

                // Held and active jobs haven't decremented their batch
                // Pending counter (fetch doesn't touch batch counters).
                if (job.state == .held or job.state == .active) {
                    if (job.batch_id) |batch_id| {
                        if (batch_id.len > 0) {
                            adjustBatchForDeletedJob(self, b, batch_id, now_ns);
                        }
                    }
                }

                // Active jobs: clean up a| key and in-memory counts.
                // deleteAllQueueJobs leaves active jobs alone, but
                // deleteTerminalQueueJobs (full delete) removes everything.
                if (job.state == .active) {
                    var ak_buf: keys.KeyBuf = undefined;
                    b.delete(OpHandler.jobActiveKey(&ak_buf, &job));
                    self.decrActiveCount(job.queue);
                    if (job.group) |g| self.decrFairnessActive(job.queue, g);
                }

                // Clean up read indexes + tag indexes.
                OpHandler.deleteReadIndexes(b, &job);
                OpHandler.deleteTagIndexes(b, &job);

                var jk_buf: keys.KeyBuf = undefined;
                b.delete(keys.jobKey(&jk_buf, job_id));
                var jpk_buf: keys.KeyBuf = undefined;
                b.delete(keys.jobPayloadKey(&jpk_buf, job_id));
                var jep_buf: keys.KeyBuf = undefined;
                var jee_buf: keys.KeyBuf = undefined;
                const err_prefix = keys.jobErrorPrefix(&jep_buf, job_id);
                if (keys.prefixEnd(&jee_buf, err_prefix)) |err_end| {
                    b.deleteRange(err_prefix, err_end);
                }
                if (job.completed_at_ns > 0) {
                    var dk_buf: keys.KeyBuf = undefined;
                    b.delete(keys.deadKey(&dk_buf, job.completed_at_ns, job_id));
                }
                counts.add(job.state);

                if (!iter.next()) break;
            }
        }
    }
}

/// Iterate a prefix, extract job IDs, delete index key + job data.
/// Returns count of jobs deleted. Stops (leaving the remainder for a repeat
/// invocation) when the deletion budget cannot cover the next job (B2).
fn deleteJobsByPrefix(
    self: *OpHandler,
    b: *kv.WriteBatch,
    prefix: []const u8,
    end: []const u8,
    extractJobID: *const fn (key: []const u8, prefix_len: usize) []const u8,
    now_ns: u64,
    budget: *DeleteBudget,
) u32 {
    var deleted: u32 = 0;
    var iter = b.newIter(prefix, end);
    defer iter.close();
    const prefix_len = prefix.len;

    if (!iter.first()) return 0;
    while (true) {
        const key = iter.key();

        const job_id = extractJobID(key, prefix_len);
        if (job_id.len == 0) {
            // Malformed index entry: only the index-key delete below.
            if (!budget.spend(7 + key.len)) break;
            b.delete(key);
            if (!iter.next()) break;
            continue;
        }

        // Load job to check unique lock + batch
        var jk_buf: keys.KeyBuf = undefined;
        const job_bytes = b.get(keys.jobKey(&jk_buf, job_id));
        if (job_bytes != null) {
            const job = codec.decodeJob(job_bytes.?);

            // Budget check BEFORE any of this job's mutations (B2); the
            // triggering index delete is part of jobDeleteBound's key count.
            if (!budget.spend(jobDeleteBound(&job))) break;
            b.delete(key);

            // Delete unique lock if owned by this job
            var uk_buf: keys.KeyBuf = undefined;
            if (OpHandler.jobUniqueKey(&uk_buf, &job)) |ukey| {
                if (b.get(ukey)) |ub| {
                    const decoded = keys.decodeUniqueValue(ub);
                    if (std.mem.eql(u8, decoded.job_id, job_id)) {
                        b.delete(ukey);
                    }
                }
            }

            // Adjust batch for non-terminal jobs
            if (job.batch_id) |batch_id| {
                if (batch_id.len > 0 and !job.state.isTerminal()) {
                    adjustBatchForDeletedJob(self, b, batch_id, now_ns);
                }
            }

            // Clean up read indexes + tag indexes.
            OpHandler.deleteReadIndexes(b, &job);
            OpHandler.deleteTagIndexes(b, &job);
        } else {
            // Dangling index entry: index + job/payload/error-range deletes.
            if (!budget.spend(4 * (7 + 8 + key.len))) break;
            b.delete(key);
        }

        b.delete(keys.jobKey(&jk_buf, job_id));
        var jpk_buf: keys.KeyBuf = undefined;
        b.delete(keys.jobPayloadKey(&jpk_buf, job_id));
        var jep_buf: keys.KeyBuf = undefined;
        var jee_buf: keys.KeyBuf = undefined;
        const err_prefix = keys.jobErrorPrefix(&jep_buf, job_id);
        if (keys.prefixEnd(&jee_buf, err_prefix)) |err_end| {
            b.deleteRange(err_prefix, err_end);
        }

        deleted += 1;
        if (!iter.next()) break;
    }
    return deleted;
}

/// Adjust batch counters when a non-terminal job is force-deleted (clear/delete queue).
/// The job was still "pending" from the batch's perspective, so decrement pending
/// and increment failed.
fn adjustBatchForDeletedJob(self: *OpHandler, b: *kv.WriteBatch, batch_id: []const u8, now_ns: u64) void {
    var bk_buf: keys.KeyBuf = undefined;
    const bkey = keys.batchKey(&bk_buf, batch_id);
    const batch_bytes = b.get(bkey);
    if (batch_bytes == null) return;

    var batch = codec.decodeBatch(batch_bytes.?);
    if (batch.total == 0) return;

    assert.check(batch.pending > 0, "adjustBatchForDeletedJob: pending underflow for batch {s} (pending={d} failed={d} total={d})", .{ batch_id, batch.pending, batch.failed, batch.total });
    batch.pending -= 1;
    batch.failed += 1;
    assert.check(batch.succeeded + batch.failed <= batch.total, "adjustBatchForDeletedJob: completed ({d}+{d}) exceeds total ({d}) for batch {s}", .{ batch.succeeded, batch.failed, batch.total, batch_id });

    if (batch.pending == 0 and !batch.open and batch.total > 0) {
        if (self.enqueueBatchCallback(b, &batch, now_ns)) batch.completed_at_ns = now_ns;
    }

    var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
    b.set(bkey, codec.encodeBatch(&batch_enc_buf, &batch));
}

// ============================================================================
// Job ID extractors for different key formats
// ============================================================================

/// Extract job ID from active key: a|{queue}\x00{jobID}
fn extractJobIDFromActive(key: []const u8, prefix_len: usize) []const u8 {
    if (key.len <= prefix_len) return "";
    return key[prefix_len..];
}

/// Extract job ID from time-sorted key: prefix|{queue}\x00{ns:8BE}{jobID}
fn extractJobIDFromTimeSorted(key: []const u8, prefix_len: usize) []const u8 {
    const id_offset = prefix_len + 8; // ns(8)
    if (key.len <= id_offset) return "";
    return key[id_offset..];
}
