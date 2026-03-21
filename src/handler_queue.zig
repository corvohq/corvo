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

pub fn applyQueueConfig(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.QueueOp) ops.OpResult {
    // Auto-create the queue if it doesn't exist yet.
    var qn_buf: keys.KeyBuf = undefined;
    if (b.get(keys.queueNameKey(&qn_buf, op.queue)) == null) {
        b.set(keys.queueNameKey(&qn_buf, op.queue), "");
    }

    var qc_buf: keys.KeyBuf = undefined;
    const qc_key = keys.queueConfigKey(&qc_buf, op.queue);
    const qc_bytes = b.get(qc_key);
    var queue = if (qc_bytes != null) codec.decodeQueue(qc_bytes.?) else types.Queue{};
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
        },
        .clear, .delete => {
            assert.fail("clear/delete should not use applyQueueConfig", .{});
        },
    }

    var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
    b.set(qc_key, codec.encodeQueue(&qc_enc_buf, &queue));

    // Update in-memory cache.
    self.putQueueConfig(op.queue, queue);
    return .{ .affected = 1 };
}

pub fn applyClearQueue(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.ClearQueueOp) ops.OpResult {
    var qn_buf: keys.KeyBuf = undefined;
    if (b.get(keys.queueNameKey(&qn_buf, op.queue)) == null) {
        return .{ .err = "queue not found" };
    }
    deleteAllQueueJobs(self, b, op.queue, op.now_ns);
    // PendingIndex already drained inside deleteAllQueueJobs.
    return .{};
}

pub fn applyDeleteQueue(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.DeleteQueueOp) ops.OpResult {
    var qn_buf: keys.KeyBuf = undefined;
    if (b.get(keys.queueNameKey(&qn_buf, op.queue)) == null) {
        return .{ .err = "queue not found" };
    }
    deleteAllQueueJobs(self, b, op.queue, op.now_ns);
    deleteTerminalQueueJobs(self, b, op.queue, op.now_ns);
    // PendingIndex already drained inside deleteAllQueueJobs.
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

    return .{};
}

// ============================================================================
// Internal helpers
// ============================================================================

fn deleteAllQueueJobs(self: *OpHandler, b: *kv.WriteBatch, queue: []const u8, now_ns: u64) void {
    // NOTE: active jobs are NOT deleted — they have a worker processing them.
    // They will complete naturally via ack/fail, or be reclaimed by maintenance.

    // Delete scheduled jobs
    var sp_buf: keys.KeyBuf = undefined;
    var spe_buf: keys.KeyBuf = undefined;
    const sp = keys.scheduledScanPrefix(&sp_buf, queue);
    if (keys.prefixEnd(&spe_buf, sp)) |end| {
        deleteJobsByPrefix(self, b, sp, end, extractJobIDFromTimeSorted, now_ns);
    }

    // Delete retrying jobs
    var rp_buf: keys.KeyBuf = undefined;
    var rpe_buf: keys.KeyBuf = undefined;
    const rp = keys.retryingScanPrefix(&rp_buf, queue);
    if (keys.prefixEnd(&rpe_buf, rp)) |end| {
        deleteJobsByPrefix(self, b, rp, end, extractJobIDFromTimeSorted, now_ns);
    }

    // Delete pending jobs — tracked in PendingIndex only (no KV index key).
    // Drain the index to get job IDs, then delete their KV data.
    while (self.pending.pop(queue)) |entry| {
        const pjob_id = entry.jobId();
        var pjk_buf: keys.KeyBuf = undefined;
        const pjob_bytes = b.get(keys.jobKey(&pjk_buf, pjob_id));
        if (pjob_bytes == null) continue; // stale entry
        const pjob = codec.decodeJob(pjob_bytes.?);
        if (pjob.state != .pending) continue; // stale
        if (!std.mem.eql(u8, pjob.queue, queue)) continue; // wrong queue

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
        b.delete(keys.jobKey(&pjk_buf, pjob_id));
        var pjpk_buf: keys.KeyBuf = undefined;
        b.delete(keys.jobPayloadKey(&pjpk_buf, pjob_id));
        var pjep_buf: keys.KeyBuf = undefined;
        var pjee_buf: keys.KeyBuf = undefined;
        const perr_prefix = keys.jobErrorPrefix(&pjep_buf, pjob_id);
        if (keys.prefixEnd(&pjee_buf, perr_prefix)) |perr_end| {
            b.deleteRange(perr_prefix, perr_end);
        }
    }

    // Clean up qa| with DeleteRange — do NOT iterate because qa| entries
    // persist for moved/completed/re-enqueued jobs.
    var qa_buf: keys.KeyBuf = undefined;
    var qae_buf: keys.KeyBuf = undefined;
    const qa = keys.queueAppendPrefix(&qa_buf, queue);
    if (keys.prefixEnd(&qae_buf, qa)) |end| {
        b.deleteRange(qa, end);
    }

    // Don't reset active counts — active jobs are still in flight.
    _ = self.fairness_served.remove(queue);

    // Delete rate limit data
    var rl_buf: keys.KeyBuf = undefined;
    var rle_buf: keys.KeyBuf = undefined;
    const rl = keys.rateLimitPrefix(&rl_buf, queue);
    if (keys.prefixEnd(&rle_buf, rl)) |end| {
        b.deleteRange(rl, end);
    }
}

fn deleteTerminalQueueJobs(self: *OpHandler, b: *kv.WriteBatch, queue: []const u8, now_ns: u64) void {
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

                const job_id = key[jp.len..];

                // Held jobs haven't decremented their batch Pending counter.
                if (job.state == .held) {
                    if (job.batch_id) |batch_id| {
                        if (batch_id.len > 0) {
                            adjustBatchForDeletedJob(self, b, batch_id, now_ns);
                        }
                    }
                }

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

                if (!iter.next()) break;
            }
        }
    }
}

/// Iterate a prefix, extract job IDs, delete index key + job data.
fn deleteJobsByPrefix(
    self: *OpHandler,
    b: *kv.WriteBatch,
    prefix: []const u8,
    end: []const u8,
    extractJobID: *const fn (key: []const u8, prefix_len: usize) []const u8,
    now_ns: u64,
) void {
    var iter = b.newIter(prefix, end);
    defer iter.close();
    const prefix_len = prefix.len;

    if (!iter.first()) return;
    while (true) {
        const key = iter.key();
        b.delete(key);

        const job_id = extractJobID(key, prefix_len);
        if (job_id.len == 0) {
            if (!iter.next()) break;
            continue;
        }

        // Load job to check unique lock + batch
        var jk_buf: keys.KeyBuf = undefined;
        const job_bytes = b.get(keys.jobKey(&jk_buf, job_id));
        if (job_bytes != null) {
            const job = codec.decodeJob(job_bytes.?);

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

        if (!iter.next()) break;
    }
}

/// Adjust batch counters when a non-terminal job is force-deleted (clear/delete queue).
/// The job was still "pending" from the batch's perspective, so decrement pending
/// and increment failed.
fn adjustBatchForDeletedJob(_: *OpHandler, b: *kv.WriteBatch, batch_id: []const u8, now_ns: u64) void {
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
        batch.completed_at_ns = now_ns;
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
