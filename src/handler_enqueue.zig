//! Enqueue handler — creates new jobs in the KV store.
//! Ported from Go internal/ops/ops_enqueue.go.

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

pub fn applyEnqueue(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.EnqueueOp) ops.OpResult {
    if (op.jobs.len == 0) {
        return .{ .err = "no jobs provided" };
    }

    var affected: u32 = 0;

    // Track last queue to skip redundant queueNameKey writes and
    // queueConfigKey reads. Saves N-1 writes + N-1 O(n) reverse scans
    // per batch when all jobs target the same queue (common case).
    var last_queue_buf: [64]u8 = undefined;
    var last_queue_len: u8 = 0;

    for (op.jobs) |*enq| {
        if (enq.queue.len == 0) return .{ .err = "missing queue" };
        if (enq.job_id.len == 0) return .{ .err = "missing job_id" };

        assert.check(op.now_ns > 0, "enqueue op missing now_ns", .{});
        assert.check(enq.state == .pending or enq.state == .scheduled, "enqueue op has invalid state", .{});

        // Validate batch BEFORE writing any job data to KV.
        if (enq.batch_id) |batch_id| {
            if (batch_id.len > 0) {
                var bk_buf: keys.KeyBuf = undefined;
                var batch_val_buf: [codec.max_batch_encoded_size]u8 = undefined;
                const batch_bytes = b.getInto(keys.batchKey(&bk_buf, batch_id), &batch_val_buf);
                if (batch_bytes == null) return .{ .err = "batch not found" };
                const batch = codec.decodeBatch(batch_bytes.?);
                if (!batch.open) return .{ .err = "batch sealed" };
            }
        }

        // Check unique constraint
        var unique_key_val: ?[]const u8 = null;
        if (enq.unique_key) |uk| {
            if (uk.len > 0) {
                var uk_buf: keys.KeyBuf = undefined;
                const uk_key = keys.uniqueKey(&uk_buf, enq.queue, uk);
                var uk_val_buf: [256]u8 = undefined;
                const existing = b.getInto(uk_key, &uk_val_buf);
                if (existing != null) {
                    // Unique key already exists — return existing job ID.
                    const decoded = keys.decodeUniqueValue(existing.?);
                    var result: ops.OpResult = .{ .err = "unique_existing" };
                    const id_len = @min(decoded.job_id.len, result.unique_job_id_buf.len);
                    @memcpy(result.unique_job_id_buf[0..id_len], decoded.job_id[0..id_len]);
                    result.unique_job_id_len = @intCast(id_len);
                    return result;
                }
                unique_key_val = uk_key;
            }
        }

        // Ensure queue exists — skip if same queue as previous job.
        const same_queue = last_queue_len > 0 and
            last_queue_len == enq.queue.len and
            std.mem.eql(u8, last_queue_buf[0..last_queue_len], enq.queue);

        if (!same_queue) {
            var qc_buf: keys.KeyBuf = undefined;
            var qc_val_buf: [codec.max_queue_encoded_size]u8 = undefined;
            if (b.getInto(keys.queueConfigKey(&qc_buf, enq.queue), &qc_val_buf) == null) {
                // New queue — enforce resource limit.
                if (self.queue_configs.count() >= self.max_queues) {
                    return .{ .err = "max queues exceeded" };
                }
                var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
                const default_q = types.Queue{ .name = enq.queue };
                const qc_data = codec.encodeQueue(&qc_enc_buf, &default_q);
                b.set(keys.queueConfigKey(&qc_buf, enq.queue), qc_data);
                _ = self.putQueueConfig(enq.queue, default_q);
            }

            var qn_buf: keys.KeyBuf = undefined;
            b.set(keys.queueNameKey(&qn_buf, enq.queue), "");

            const ql = @min(enq.queue.len, last_queue_buf.len);
            @memcpy(last_queue_buf[0..ql], enq.queue[0..ql]);
            last_queue_len = @intCast(ql);
        }

        // Build job from enqueue op
        var job = enqueueToJob(enq);
        if (job.expire_after_ms > 0) {
            job.expire_at_ns = op.now_ns + @as(u64, job.expire_after_ms) * 1_000_000;
            var xk_buf: keys.KeyBuf = undefined;
            b.set(keys.expireKey(&xk_buf, job.expire_at_ns, job.id), "");
        }

        // Write job header
        var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
        var jk_buf: keys.KeyBuf = undefined;
        b.set(keys.jobKey(&jk_buf, job.id), codec.encodeJob(&job_enc_buf, &job));

        // Write payload separately (skip empty payloads — saves a KV set per job).
        if (enq.payload) |p| {
            if (p.len > 0) {
                var jpk_buf: keys.KeyBuf = undefined;
                b.set(keys.jobPayloadKey(&jpk_buf, job.id), p);
            }
        }

        // Write state index
        if (job.state == .scheduled) {
            if (job.scheduled_at_ns == 0) return .{ .err = "invalid scheduled time" };
            var sk_buf: keys.KeyBuf = undefined;
            b.set(OpHandler.jobScheduledKey(&sk_buf, &job), "");
        } else {
            // Pending jobs use the in-memory PendingIndex for fetch.
            // No KV p| key needed — rebuild from j| on restart.
            self.pending.push(job.queue, job.priority, job.created_at_ns, job.id);
        }

        // Write unique lock
        if (unique_key_val != null and enq.unique_key != null) {
            var uv_buf: keys.KeyBuf = undefined;
            var unique_expires_ns: u64 = 0;
            if (enq.unique_period_s > 0) {
                unique_expires_ns = op.now_ns + @as(u64, enq.unique_period_s) * 1_000_000_000;
            }
            var unique_kk_buf: keys.KeyBuf = undefined;
            b.set(
                keys.uniqueKey(&unique_kk_buf, enq.queue, enq.unique_key.?),
                keys.encodeUniqueValue(&uv_buf, job.id, unique_expires_ns),
            );
        }

        // Update batch counter
        if (enq.batch_id) |batch_id| {
            if (batch_id.len > 0) {
                var bk_buf2: keys.KeyBuf = undefined;
                const bkey = keys.batchKey(&bk_buf2, batch_id);
                var batch_val_buf2: [codec.max_batch_encoded_size]u8 = undefined;
                const batch_bytes = b.getInto(bkey, &batch_val_buf2);
                assert.check(batch_bytes != null, "batch disappeared between validation and update", .{});
                var batch = codec.decodeBatch(batch_bytes.?);
                assert.check(batch.open, "batch sealed between validation and update", .{});
                batch.total += 1;
                batch.pending += 1;
                assert.check(batch.pending <= batch.total, "enqueue: batch {s} pending ({d}) > total ({d})", .{ batch_id, batch.pending, batch.total });
                var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
                b.set(bkey, codec.encodeBatch(&batch_enc_buf, &batch));
            }
        }

        self.verifyJobIndexes(b, &job, "enqueue");
        affected += 1;
    }

    return .{ .affected = affected };
}

fn enqueueToJob(enq: *const ops.EnqueueJob) types.Job {
    return .{
        .id = enq.job_id,
        .queue = enq.queue,
        .state = enq.state,
        .priority = enq.priority,
        .max_retries = enq.max_retries,
        .retry_backoff = enq.backoff,
        .retry_base_delay_ms = enq.base_delay_ms,
        .retry_max_delay_ms = enq.max_delay_ms,
        .created_at_ns = enq.created_at_ns,
        .unique_key = enq.unique_key,
        .unique_period_s = enq.unique_period_s,
        .tags = enq.tags,
        .scheduled_at_ns = enq.scheduled_at_ns,
        .expire_after_ms = enq.expire_after_ms,
        .expire_at_ns = enq.expire_at_ns,
        .batch_id = enq.batch_id,
        .parent_id = enq.parent_id,
        .chain_id = enq.chain_id,
        .chain_step = enq.chain_step,
        .chain_config = enq.chain_config,
        .group = enq.group,
        .checkpoint = enq.checkpoint,
    };
}
