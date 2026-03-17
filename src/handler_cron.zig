//! Cron handler — CRUD + trigger for cron schedules.
//! Ported from Go internal/ops/ops_cron.go.

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

pub fn applyCreateCron(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.CreateCronOp) ops.OpResult {
    // Check name uniqueness
    var cn_buf: keys.KeyBuf = undefined;
    if (b.get(keys.cronNameKey(&cn_buf, op.name)) != null) {
        return .{ .err = "cron name conflict" };
    }

    var cron = types.Cron{
        .id = op.cron_id,
        .name = op.name,
        .queue = op.queue,
        .schedule = op.schedule,
        .timezone = op.timezone,
        .payload = op.payload,
        .max_retries = op.max_retries,
        .enabled = op.enabled,
        .created_at_ns = op.created_at_ns,
    };

    if (op.next_run_ns > 0) {
        cron.next_run_ns = op.next_run_ns;
    }
    if (op.unique_key) |uk| {
        if (uk.len > 0) cron.unique_key = uk;
    }

    var cron_enc_buf: [codec.max_cron_encoded_size]u8 = undefined;
    var ck_buf: keys.KeyBuf = undefined;
    b.set(keys.cronKey(&ck_buf, op.cron_id), codec.encodeCron(&cron_enc_buf, &cron));
    b.set(keys.cronNameKey(&cn_buf, op.name), op.cron_id);

    return .{ .affected = 1 };
}

pub fn applyUpdateCron(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.UpdateCronOp) ops.OpResult {
    var ck_buf: keys.KeyBuf = undefined;
    const cron_bytes = b.get(keys.cronKey(&ck_buf, op.cron_id));
    if (cron_bytes == null) {
        return .{ .err = "cron not found" };
    }

    var cron = codec.decodeCron(cron_bytes.?);

    // Update name (with uniqueness check)
    if (op.name) |name| {
        if (name.len > 0) {
            var cn_buf: keys.KeyBuf = undefined;
            const existing = b.get(keys.cronNameKey(&cn_buf, name));
            if (existing != null and !std.mem.eql(u8, existing.?, op.cron_id)) {
                return .{ .err = "cron name conflict" };
            }
            // Delete old name key, set new
            var old_cn_buf: keys.KeyBuf = undefined;
            b.delete(keys.cronNameKey(&old_cn_buf, cron.name));
            cron.name = name;
            b.set(keys.cronNameKey(&cn_buf, name), op.cron_id);
        }
    }
    if (op.queue) |q| {
        if (q.len > 0) cron.queue = q;
    }
    if (op.schedule) |s| {
        if (s.len > 0) cron.schedule = s;
    }
    if (op.timezone) |tz| {
        if (tz.len > 0) cron.timezone = tz;
    }
    if (op.payload) |p| {
        cron.payload = p;
    }
    if (op.unique_key) |uk| {
        cron.unique_key = uk;
    }
    if (op.max_retries) |mr| {
        cron.max_retries = mr;
    }
    if (op.enabled) |e| {
        cron.enabled = e;
    }
    if (op.next_run_ns > 0) {
        cron.next_run_ns = op.next_run_ns;
    }

    var cron_enc_buf: [codec.max_cron_encoded_size]u8 = undefined;
    b.set(keys.cronKey(&ck_buf, op.cron_id), codec.encodeCron(&cron_enc_buf, &cron));

    return .{ .affected = 1 };
}

pub fn applyDeleteCron(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.DeleteCronOp) ops.OpResult {
    var ck_buf: keys.KeyBuf = undefined;
    const cron_bytes = b.get(keys.cronKey(&ck_buf, op.cron_id));
    if (cron_bytes == null) {
        return .{}; // idempotent: deleting nonexistent cron is a no-op
    }

    const cron = codec.decodeCron(cron_bytes.?);
    b.delete(keys.cronKey(&ck_buf, op.cron_id));
    var cn_buf: keys.KeyBuf = undefined;
    b.delete(keys.cronNameKey(&cn_buf, cron.name));

    return .{};
}

pub fn applyTriggerCron(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.TriggerCronOp) ops.OpResult {
    var ck_buf: keys.KeyBuf = undefined;
    const cron_bytes = b.get(keys.cronKey(&ck_buf, op.cron_id));
    if (cron_bytes == null) {
        return .{ .err = "cron not found" };
    }

    var cron = codec.decodeCron(cron_bytes.?);
    cron.last_run_ns = @intCast(op.now_ns);

    if (op.next_run_ns > 0) {
        cron.next_run_ns = op.next_run_ns;
    }

    // Write updated cron
    var cron_enc_buf: [codec.max_cron_encoded_size]u8 = undefined;
    b.set(keys.cronKey(&ck_buf, op.cron_id), codec.encodeCron(&cron_enc_buf, &cron));

    // Create the job via enqueue
    var enq_job = ops.EnqueueJob{
        .job_id = op.job_id,
        .queue = cron.queue,
        .payload = cron.payload,
        .max_retries = cron.max_retries,
        .state = .pending,
        .priority = types.priority_normal,
        .created_at_ns = op.now_ns,
    };
    if (cron.unique_key) |uk| {
        enq_job.unique_key = uk;
    }

    const jobs = [_]ops.EnqueueJob{enq_job};
    const enqueue_op = ops.EnqueueOp{
        .jobs = &jobs,
        .now_ns = op.now_ns,
    };

    return self.applyEnqueue(b, &enqueue_op);
}
