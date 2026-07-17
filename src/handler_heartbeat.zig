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
    if (op.job_ids.len != op.job_ops.len) return .{ .err = "invalid heartbeat jobs" };
    if (op.now_ns == 0 or op.now_ns > std.math.maxInt(u64) - 60 * 1_000_000_000)
        return .{ .err = "invalid heartbeat timestamp" };
    if (op.worker_id.len > types.max_worker_id_len or
        std.mem.indexOfScalar(u8, op.worker_id, 0) != null)
        return .{ .err = "invalid worker_id" };
    for (op.job_ids, op.job_ops) |job_id, update_op| {
        if (job_id.len == 0 or job_id.len > types.max_job_id_len or
            std.mem.indexOfScalar(u8, job_id, 0) != null)
            return .{ .err = "invalid heartbeat job_id" };
        if (update_op.progress) |p| {
            if (p.len > types.max_metadata_field_len)
                return .{ .err = "heartbeat progress too large" };
        }
        if (update_op.checkpoint) |cp| {
            if (cp.len > types.max_metadata_field_len)
                return .{ .err = "heartbeat checkpoint too large" };
        }
    }

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

        // Ownership guard: only the worker currently holding the lease may
        // extend it or update progress/checkpoint. Without this, a worker
        // whose lease expired and was reclaimed → refetched by another worker
        // keeps refreshing the new holder's lease and overwriting its
        // checkpoint with stale data (so a later retry resumes from the wrong
        // point). Ack/fail enforce this via lease_token; the heartbeat wire
        // format has no token, so match on worker_id, which catches the
        // cross-worker case (the corruption risk).
        if (op.worker_id.len > 0 and !std.mem.eql(u8, job.worker_id orelse "", op.worker_id)) continue;

        assert.check(job.lease_expires_at_ns > 0, "heartbeat: active job has no lease", .{});

        job.lease_expires_at_ns = lease_expires_ns;

        if (update_op.progress) |p| {
            if (p.len > 0) job.progress = p;
        }
        if (update_op.checkpoint) |cp| {
            if (cp.len > 0) job.checkpoint = cp;
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
            assert.check(codec.workerEncodedSize(&w) <= codec.max_worker_encoded_size, "heartbeat: stored worker exceeds codec buffer", .{});
            var w_enc_buf: [codec.max_worker_encoded_size]u8 = undefined;
            b.set(keys.workerKey(&wk_buf, op.worker_id), codec.encodeWorker(&w_enc_buf, &w));
        }
    }

    return .{ .affected = affected };
}
