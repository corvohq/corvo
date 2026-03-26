//! Fail handler — marks active jobs as retrying or dead.
//! Ported from Go internal/ops/ops_ack_fail.go (fail portion).

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

// Chain step sentinel values (matching handler_ack.zig).
const chain_step_failure: u16 = 0xFFFE;
const chain_step_max: u16 = 0xFFFD;

pub fn applyFail(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.FailOp) ops.OpResult {
    if (op.jobs.len == 0) return .{ .err = "no jobs provided" };

    var affected: u32 = 0;

    for (op.jobs) |*fail_job| {
        if (fail_job.job_id.len == 0) continue;

        var jk_buf: keys.KeyBuf = undefined;
        const job_bytes = b.get(keys.jobKey(&jk_buf, fail_job.job_id));
        if (job_bytes == null) continue;

        var job = codec.decodeJob(job_bytes.?);
        if (job.state != .active) continue;

        // Lease token check: reject stale fails from workers whose lease was reclaimed.
        // fail.lease_token=0 means "don't check" (client doesn't have the token).
        if (fail_job.lease_token != 0 and fail_job.lease_token != job.lease_token) continue;

        // Delete active key + decrement counts
        var ak_buf: keys.KeyBuf = undefined;
        b.delete(OpHandler.jobActiveKey(&ak_buf, &job));
        self.decrActiveCount(job.queue);
        if (job.group) |g| self.decrFairnessActive(job.queue, g);

        // Write job error to KV: je|{job_id}\x00{attempt:4BE} → error JSON.
        {
            var ek_buf: keys.KeyBuf = undefined;
            var err_val_buf: [1024]u8 = undefined;
            const bt = fail_job.backtrace orelse "";
            const err_json = if (bt.len > 0)
                std.fmt.bufPrint(&err_val_buf, "{{\"job_id\":\"{s}\",\"attempt\":{d},\"error\":\"{s}\",\"backtrace\":\"{s}\",\"created_at_ns\":{d}}}", .{
                    fail_job.job_id,
                    job.attempt,
                    fail_job.error_msg,
                    bt,
                    op.now_ns,
                }) catch ""
            else
                std.fmt.bufPrint(&err_val_buf, "{{\"job_id\":\"{s}\",\"attempt\":{d},\"error\":\"{s}\",\"created_at_ns\":{d}}}", .{
                    fail_job.job_id,
                    job.attempt,
                    fail_job.error_msg,
                    op.now_ns,
                }) catch "";
            if (err_json.len > 0) {
                b.set(keys.jobErrorKey(&ek_buf, fail_job.job_id, @intCast(job.attempt)), err_json);
            }
        }

        // Clear expire key
        if (job.expire_after_ms > 0 and job.expire_at_ns > 0) {
            var xk_buf: keys.KeyBuf = undefined;
            b.delete(keys.expireKey(&xk_buf, job.expire_at_ns, job.id));
            job.expire_at_ns = 0;
        }

        const attempts_remaining = if (job.max_retries > job.attempt)
            job.max_retries - job.attempt
        else
            0;

        if (attempts_remaining > 0) {
            // Retry
            const delay_ns = handler.calculateBackoffNs(
                job.retry_backoff,
                job.attempt,
                job.retry_base_delay_ms,
                job.retry_max_delay_ms,
            );
            const next_attempt_ns = op.now_ns + delay_ns;

            job.state = .retrying;
            job.failed_at_ns = op.now_ns;
            job.scheduled_at_ns = next_attempt_ns;
            job.worker_id = null;
            job.hostname = null;
            job.lease_expires_at_ns = 0;

            var rk_buf: keys.KeyBuf = undefined;
            b.set(OpHandler.jobRetryingKey(&rk_buf, &job), "");
        } else {
            // Dead
            job.state = .dead;
            job.completed_at_ns = op.now_ns;
            job.failed_at_ns = op.now_ns;
            job.worker_id = null;
            job.hostname = null;
            job.lease_expires_at_ns = 0;

            var dk_buf: keys.KeyBuf = undefined;
            b.set(keys.deadKey(&dk_buf, op.now_ns, fail_job.job_id), "");

            // Release unique lock if we own it
            var uk_buf: keys.KeyBuf = undefined;
            if (OpHandler.jobUniqueKey(&uk_buf, &job)) |ukey| {
                var uk_val_buf: [256]u8 = undefined;
                if (b.getInto(ukey, &uk_val_buf)) |ub| {
                    const decoded = keys.decodeUniqueValue(ub);
                    if (std.mem.eql(u8, decoded.job_id, job.id)) {
                        b.delete(ukey);
                    }
                }
            }

            // Batch completion tracking.
            if (job.batch_id) |bid| {
                if (bid.len > 0) self.handleBatchJobComplete(b, bid, false, op.now_ns);
            }

            // Chain on_failure handler
            if (job.chain_config) |cc| {
                if (cc.len > 0 and job.chain_step <= chain_step_max) {
                    fireChainOnFailure(self, b, &job, op.now_ns);
                }
            }
        }

        self.recordFailResult(
            fail_job.job_id,
            fail_job.error_msg,
            fail_job.backtrace,
            job.state,
            job.attempt,
            if (job.state == .retrying) job.scheduled_at_ns else 0,
            op.now_ns,
        );

        // Write updated job
        var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
        b.set(keys.jobKey(&jk_buf, fail_job.job_id), codec.encodeJob(&job_enc_buf, &job));

        self.verifyJobIndexes(b, &job, "fail");
        affected += 1;
    }

    return .{ .affected = affected };
}

/// Fire chain on_failure handler when a job goes dead.
/// Parses chain_config JSON, enqueues on_failure step if defined.
/// Public so maintenance (reclaim) can call it for lease-expired chain jobs.
pub fn fireChainOnFailure(self: *OpHandler, b: *kv.WriteBatch, job: *const types.Job, now_ns: u64) void {
    const cc = job.chain_config orelse return;
    if (cc.len == 0) return;

    const ChainStep = struct {
        queue: ?[]const u8 = null,
        payload: ?[]const u8 = null,
    };
    const ChainDef = struct {
        on_failure: ?ChainStep = null,
    };

    var parse_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    const parsed = std.json.parseFromSlice(ChainDef, fba.allocator(), cc, .{
        .ignore_unknown_fields = true,
    }) catch return;

    const on_failure = parsed.value.on_failure orelse return;
    const queue = on_failure.queue orelse return;

    var id_buf: [64]u8 = undefined;
    const chain_job_id = std.fmt.bufPrint(&id_buf, "chain_{s}_{d}", .{ job.id, chain_step_failure }) catch return;

    // Assert: chain failure job must not already exist.
    var check_jk_buf: keys.KeyBuf = undefined;
    assert.check(b.get(keys.jobKey(&check_jk_buf, chain_job_id)) == null,
        "fireChainOnFailure: chain failure job already exists: parent={s}", .{job.id});

    const chain_job = ops.EnqueueJob{
        .job_id = chain_job_id,
        .queue = queue,
        .payload = on_failure.payload,
        .state = .pending,
        .priority = job.priority,
        .max_retries = job.max_retries,
        .created_at_ns = now_ns,
        .chain_id = job.chain_id,
        .chain_step = chain_step_failure,
        .chain_config = cc,
        .parent_id = job.id,
    };

    const jobs = [_]ops.EnqueueJob{chain_job};
    const enqueue_op = ops.EnqueueOp{
        .jobs = &jobs,
        .now_ns = now_ns,
    };
    _ = self.applyEnqueue(b, &enqueue_op);
    self.recordSideEffect(&chain_job);
}
