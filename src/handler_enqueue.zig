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
const metrics_mod = handler.metrics_mod;

pub fn applyEnqueue(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.EnqueueOp) ops.OpResult {
    // Validate the WHOLE operation before touching KV or in-memory indexes.
    // Enqueue is one RPC/HTTP batch with one success bit; partially applying a
    // prefix and then returning an error makes a retry fail on those duplicate
    // IDs forever, so the suffix is silently lost. Besides atomicity, this
    // pre-pass keeps all external lengths inside the fixed hot-path buffers.
    if (validateEnqueue(self, b, op)) |err| return err;

    var affected: u32 = 0;

    // Track last queue to skip redundant queueNameKey writes and
    // queueConfigKey reads. Saves N-1 writes + N-1 O(n) reverse scans
    // per batch when all jobs target the same queue (common case).
    var last_queue_buf: [64]u8 = undefined;
    var last_queue_len: u8 = 0;

    for (op.jobs) |*enq| {
        assert.check(op.now_ns > 0, "enqueue op missing now_ns", .{});
        assert.check(enq.state == .pending or enq.state == .scheduled, "enqueue op has invalid state", .{});

        // Validate batch BEFORE writing any job data to KV.
        if (enq.batch_id) |batch_id| {
            if (batch_id.len > 0) {
                var bk_buf: keys.KeyBuf = undefined;
                var batch_val_buf: [codec.max_batch_encoded_size]u8 = undefined;
                const batch_bytes = b.getInto(keys.batchKey(&bk_buf, batch_id), &batch_val_buf);
                assert.check(batch_bytes != null, "validated enqueue batch disappeared", .{});
                const batch = codec.decodeBatch(batch_bytes.?);
                assert.check(batch.open, "validated enqueue batch became sealed", .{});
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
                assert.check(existing == null, "validated unique key became occupied", .{});
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
                assert.check(self.queue_configs.count() < self.max_queues, "validated queue capacity exceeded", .{});
                var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
                const default_q = types.Queue{ .name = enq.queue };
                const qc_data = codec.encodeQueue(&qc_enc_buf, &default_q);
                b.set(keys.queueConfigKey(&qc_buf, enq.queue), qc_data);
                assert.check(self.putQueueConfig(enq.queue, default_q), "enqueue: failed to cache validated queue {s}", .{enq.queue});
            }

            var qn_buf: keys.KeyBuf = undefined;
            b.set(keys.queueNameKey(&qn_buf, enq.queue), "");

            assert.check(enq.queue.len <= last_queue_buf.len, "enqueue: validated queue exceeds cache buffer", .{});
            const ql = enq.queue.len;
            @memcpy(last_queue_buf[0..ql], enq.queue);
            last_queue_len = @intCast(ql);
        }

        // Build job from enqueue op
        var job = enqueueToJob(enq);

        // Reject duplicate job IDs — client-provided IDs are external input.
        var jk_buf: keys.KeyBuf = undefined;
        var existing_buf: [codec.max_job_encoded_size]u8 = undefined;
        assert.check(b.getInto(keys.jobKey(&jk_buf, job.id), &existing_buf) == null, "validated job id became occupied", .{});

        if (job.expire_after_ms > 0) {
            job.expire_at_ns = op.now_ns + @as(u64, job.expire_after_ms) * 1_000_000;
            var xk_buf: keys.KeyBuf = undefined;
            b.set(keys.expireKey(&xk_buf, job.expire_at_ns, job.id), "");
        }

        // Write job header
        var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
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
            assert.check(job.scheduled_at_ns > 0, "validated scheduled job lost its timestamp", .{});
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
                assert.check(batch.total < std.math.maxInt(u32), "enqueue: batch total overflow", .{});
                batch.total += 1;
                batch.pending += 1;
                assert.check(batch.pending <= batch.total, "enqueue: batch {s} pending ({d}) > total ({d})", .{ batch_id, batch.pending, batch.total });
                var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
                b.set(bkey, codec.encodeBatch(&batch_enc_buf, &batch));
            }
        }

        // Defer read indexes + tag indexes + queue counter to indexer.
        self.indexer.recordCreate(job.id, job.queue, job.state, job.created_at_ns);
        self.incrQueueCounterMem(job.queue, job.state);

        self.verifyJobIndexes(b, &job, "enqueue");
        self.metrics.recordEnqueue(job.queue, 1, op.now_ns);
        affected += 1;
    }

    assert.check(self.total_jobs <= std.math.maxInt(u32) - affected, "enqueue: total_jobs overflow", .{});
    self.total_jobs += affected;
    return .{ .affected = affected };
}

/// Boundary validation for an enqueue operation. Returns the same OpResult
/// shape as applyEnqueue so unique conflicts can still report their owner.
/// O(n^2) duplicate checks are deliberately bounded by MAX_BATCH_JOBS (256)
/// and avoid heap allocation on the hot path.
fn validateEnqueue(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.EnqueueOp) ?ops.OpResult {
    if (op.jobs.len == 0) return .{ .err = "no jobs provided" };
    if (op.now_ns == 0) return .{ .err = "invalid enqueue timestamp" };

    const job_count: u32 = @intCast(op.jobs.len);
    if (self.max_jobs > 0 and
        (job_count > self.max_jobs or self.total_jobs > self.max_jobs - job_count))
    {
        return .{ .err = "max jobs exceeded" };
    }

    var new_queue_count: u32 = 0;

    for (op.jobs, 0..) |*enq, i| {
        if (enq.queue.len == 0) return .{ .err = "missing queue" };
        if (enq.queue.len > types.max_queue_name_len or
            std.mem.indexOfScalar(u8, enq.queue, 0) != null)
            return .{ .err = "invalid queue" };
        if (enq.job_id.len == 0) return .{ .err = "missing job_id" };
        if (enq.job_id.len > types.max_job_id_len or
            std.mem.indexOfScalar(u8, enq.job_id, 0) != null)
            return .{ .err = "job_id too long" };
        if (enq.state != .pending and enq.state != .scheduled)
            return .{ .err = "invalid job state" };
        if (enq.state == .scheduled and enq.scheduled_at_ns == 0)
            return .{ .err = "invalid scheduled time" };
        if (enq.expire_after_ms > 0 and
            op.now_ns > std.math.maxInt(u64) - @as(u64, enq.expire_after_ms) * 1_000_000)
            return .{ .err = "job expiry timestamp overflow" };
        if (enq.unique_period_s > 0 and
            op.now_ns > std.math.maxInt(u64) - @as(u64, enq.unique_period_s) * 1_000_000_000)
            return .{ .err = "unique timestamp overflow" };
        if (enq.unique_key) |value| {
            if (value.len > 255 or std.mem.indexOfScalar(u8, value, 0) != null)
                return .{ .err = "invalid unique_key" };
        }
        if (enq.tags) |value| {
            // One parsed tag pair is embedded in tq| alongside queue+job ID.
            // 256 keeps the worst possible pair below keys.max_key_len.
            if (value.len > 256) return .{ .err = "tags too large" };
        }
        if (enq.parent_id) |value| {
            if (value.len > types.max_job_id_len or std.mem.indexOfScalar(u8, value, 0) != null)
                return .{ .err = "parent_id too long" };
        }
        if (enq.chain_id) |value| {
            if (value.len > types.max_entity_id_len or std.mem.indexOfScalar(u8, value, 0) != null)
                return .{ .err = "chain_id too long" };
        }
        if (enq.group) |value| {
            if (value.len > types.max_entity_id_len) return .{ .err = "group too long" };
        }
        const encoded_job = enqueueToJob(enq);
        if (codec.jobEncodedSize(&encoded_job) > codec.max_enqueue_job_encoded_size)
            return .{ .err = "job metadata too large" };

        // Existing or intra-batch duplicate job IDs reject the whole batch.
        var jk_buf: keys.KeyBuf = undefined;
        if (b.get(keys.jobKey(&jk_buf, enq.job_id)) != null)
            return .{ .err = "job already exists" };
        for (op.jobs[0..i]) |*prior| {
            if (std.mem.eql(u8, prior.job_id, enq.job_id))
                return .{ .err = "duplicate job_id in batch" };
        }

        // Count distinct queues this operation would create, before creating
        // any of them, so max_queues can never yield a partial prefix.
        var qc_buf: keys.KeyBuf = undefined;
        if (b.get(keys.queueConfigKey(&qc_buf, enq.queue)) == null) {
            var seen = false;
            for (op.jobs[0..i]) |*prior| {
                if (std.mem.eql(u8, prior.queue, enq.queue)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) new_queue_count += 1;
        }

        if (enq.batch_id) |batch_id| {
            if (batch_id.len > 0) {
                if (batch_id.len > types.max_entity_id_len or
                    std.mem.indexOfScalar(u8, batch_id, 0) != null)
                    return .{ .err = "batch_id too long" };
                var bk_buf: keys.KeyBuf = undefined;
                const batch_bytes = b.get(keys.batchKey(&bk_buf, batch_id)) orelse
                    return .{ .err = "batch not found" };
                const batch = codec.decodeBatch(batch_bytes);
                if (!batch.open) return .{ .err = "batch sealed" };

                var additions: u32 = 1;
                for (op.jobs[0..i]) |*prior| {
                    if (prior.batch_id) |prior_id| {
                        if (std.mem.eql(u8, prior_id, batch_id)) additions += 1;
                    }
                }
                if (batch.total > std.math.maxInt(u32) - additions)
                    return .{ .err = "batch job limit exceeded" };
            }
        }

        if (enq.unique_key) |unique_key| {
            if (unique_key.len > 0) {
                var uk_buf: keys.KeyBuf = undefined;
                if (b.get(keys.uniqueKey(&uk_buf, enq.queue, unique_key))) |existing| {
                    return uniqueConflict(existing);
                }
                for (op.jobs[0..i]) |*prior| {
                    const prior_key = prior.unique_key orelse continue;
                    if (std.mem.eql(u8, prior.queue, enq.queue) and
                        std.mem.eql(u8, prior_key, unique_key))
                    {
                        var result: ops.OpResult = .{ .err = "unique_existing" };
                        assert.check(prior.job_id.len <= result.unique_job_id_buf.len, "enqueue: validated unique owner exceeds response buffer", .{});
                        const n = prior.job_id.len;
                        @memcpy(result.unique_job_id_buf[0..n], prior.job_id);
                        result.unique_job_id_len = @intCast(n);
                        return result;
                    }
                }
            }
        }
    }

    if (new_queue_count > self.max_queues or
        self.queue_configs.count() > self.max_queues - new_queue_count)
        return .{ .err = "max queues exceeded" };

    return null;
}

fn uniqueConflict(existing: []const u8) ops.OpResult {
    const decoded = keys.decodeUniqueValue(existing);
    var result: ops.OpResult = .{ .err = "unique_existing" };
    assert.check(decoded.job_id.len <= result.unique_job_id_buf.len, "enqueue: stored unique owner exceeds response buffer", .{});
    const n = decoded.job_id.len;
    @memcpy(result.unique_job_id_buf[0..n], decoded.job_id);
    result.unique_job_id_len = @intCast(n);
    return result;
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
