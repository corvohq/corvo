//! Heartbeat handler — extends leases and updates progress/checkpoint.
//! Ported from Go internal/ops/ops_ack_fail.go (heartbeat portion).

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

pub fn applyHeartbeat(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.HeartbeatOp) ops.OpResult {
    const lease_expires_ns = op.now_ns + 60 * 1_000_000_000;
    var affected: u32 = 0;

    var i: usize = 0;
    while (i < op.job_ids.len) : (i += 1) {
        const job_id = op.job_ids[i];
        const update_op = op.job_ops[i];

        var jk_buf: keys.KeyBuf = undefined;
        const job_bytes = b.get(keys.jobKey(&jk_buf, job_id));
        if (job_bytes == null) continue;

        var job = codec.decodeJob(job_bytes.?);
        if (job.state != .active) continue;

        assert.check(job.lease_expires_at_ns > 0, "heartbeat: active job has no lease", .{});

        job.lease_expires_at_ns = lease_expires_ns;

        if (update_op.progress) |p| {
            if (p.len > 0) job.progress = p;
        }
        if (update_op.checkpoint) |cp| {
            if (cp.len > 0) job.checkpoint = cp;
        }

        // Write heartbeat usage KV entry if usage data present.
        if (update_op.usage) |usage| {
            if (usage.cost_usd > 0 or usage.input_tokens > 0 or usage.output_tokens > 0) {
                var uk_buf: keys.KeyBuf = undefined;
                var usage_val_buf: [256]u8 = undefined;
                const usage_json = std.fmt.bufPrint(&usage_val_buf, "{{\"input_tokens\":{d},\"output_tokens\":{d},\"cost_usd\":{d:.6},\"created_at_ns\":{d}}}", .{
                    usage.input_tokens,
                    usage.output_tokens,
                    usage.cost_usd,
                    op.now_ns,
                }) catch "";
                if (usage_json.len > 0) {
                    b.set(keys.jobUsageHeartbeatKey(&uk_buf, job_id, @intCast(job.attempt), op.now_ns), usage_json);
                }
            }
        }

        var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
        b.set(keys.jobKey(&jk_buf, job_id), codec.encodeJob(&job_enc_buf, &job));

        var ak_buf: keys.KeyBuf = undefined;
        var lease_val: [8]u8 = undefined;
        std.mem.writeInt(u64, &lease_val, lease_expires_ns, .big);
        b.set(OpHandler.jobActiveKey(&ak_buf, &job), &lease_val);

        self.verifyJobIndexes(b, &job, "heartbeat");
        affected += 1;
    }

    // Update worker last heartbeat
    if (op.worker_id.len > 0) {
        var wk_buf: keys.KeyBuf = undefined;
        const worker_bytes = b.get(keys.workerKey(&wk_buf, op.worker_id));
        if (worker_bytes != null) {
            var w = codec.decodeWorker(worker_bytes.?);
            w.last_heartbeat_ns = op.now_ns;
            var w_enc_buf: [codec.max_worker_encoded_size]u8 = undefined;
            b.set(keys.workerKey(&wk_buf, op.worker_id), codec.encodeWorker(&w_enc_buf, &w));
        }
    }

    return .{ .affected = affected };
}
