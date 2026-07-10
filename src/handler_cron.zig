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
const cron_expr = @import("cron_expr.zig");
const OpHandler = handler.OpHandler;

/// Compute the first fire time for a cron schedule at/after `now_ns`.
/// Returns 0 if the expression is invalid or has no upcoming fire.
pub fn computeInitialNextRun(schedule: []const u8, now_ns: u64) u64 {
    const e = cron_expr.parse(schedule) catch return 0;
    return cron_expr.nextFire(&e, now_ns) orelse 0;
}

/// Scan cron definitions and fire any whose next_run_ns is due. Fires each due
/// cron at most once per scan (no backfill of missed slots), enqueues its job,
/// and advances next_run_ns via the cron expression. Two-phase (collect due ids,
/// then fire) so enqueue writes don't invalidate the scan iterator.
pub fn applyCronScan(self: *OpHandler, b: *kv.WriteBatch, now_ns: u64) ops.OpResult {
    const max_fire_per_scan = 64;
    var due_ids: [max_fire_per_scan][64]u8 = undefined;
    var due_lens: [max_fire_per_scan]u8 = undefined;
    var due_count: usize = 0;

    // Phase 1: collect due cron ids.
    {
        var sp_buf: keys.KeyBuf = undefined;
        var spe_buf: keys.KeyBuf = undefined;
        const sp: []const u8 = keys.prefix_cron;
        @memcpy(sp_buf[0..sp.len], sp);
        if (keys.prefixEnd(&spe_buf, sp_buf[0..sp.len])) |end| {
            var iter = b.newIter(sp_buf[0..sp.len], end);
            defer iter.close();
            if (iter.first()) {
                while (due_count < max_fire_per_scan) {
                    const cron = codec.decodeCron(iter.value());
                    if (cron.enabled and cron.next_run_ns > 0 and
                        @as(u64, @intCast(cron.next_run_ns)) <= now_ns)
                    {
                        const l: u8 = @intCast(@min(cron.id.len, 64));
                        @memcpy(due_ids[due_count][0..l], cron.id[0..l]);
                        due_lens[due_count] = l;
                        due_count += 1;
                    }
                    if (!iter.next()) break;
                }
            }
        }
    }

    // Phase 2: fire each due cron.
    var affected: u32 = 0;
    for (0..due_count) |i| {
        const cron_id = due_ids[i][0..due_lens[i]];
        var ck_buf: keys.KeyBuf = undefined;
        const cron_bytes = b.get(keys.cronKey(&ck_buf, cron_id)) orelse continue;
        var cron = codec.decodeCron(cron_bytes);

        const fire_slot: u64 = @intCast(cron.next_run_ns);

        // Advance to the next fire. A bad expression disables the cron so it is
        // not rescanned forever.
        const parsed = cron_expr.parse(cron.schedule) catch {
            cron.enabled = false;
            var db_buf: [codec.max_cron_encoded_size]u8 = undefined;
            b.set(keys.cronKey(&ck_buf, cron_id), codec.encodeCron(&db_buf, &cron));
            continue;
        };
        cron.next_run_ns = @intCast(cron_expr.nextFire(&parsed, now_ns) orelse 0);
        cron.last_run_ns = @intCast(now_ns);
        var enc_buf: [codec.max_cron_encoded_size]u8 = undefined;
        b.set(keys.cronKey(&ck_buf, cron_id), codec.encodeCron(&enc_buf, &cron));

        // Deterministic per-slot job id: a re-fire of the same slot (e.g. after a
        // crash before the advance was persisted) collides and is idempotently
        // rejected by the enqueue handler, so a cron never double-enqueues a slot.
        var jid_buf: [96]u8 = undefined;
        const job_id = std.fmt.bufPrint(&jid_buf, "{s}-{d}", .{ cron_id, fire_slot }) catch continue;

        var enq_job = ops.EnqueueJob{
            .job_id = job_id,
            .queue = cron.queue,
            .payload = cron.payload,
            .max_retries = cron.max_retries,
            .state = .pending,
            .priority = types.priority_normal,
            .created_at_ns = now_ns,
        };
        if (cron.unique_key) |uk| enq_job.unique_key = uk;
        const jobs = [_]ops.EnqueueJob{enq_job};
        const enqueue_op = ops.EnqueueOp{ .jobs = &jobs, .now_ns = now_ns };
        _ = self.applyEnqueue(b, &enqueue_op); // dup id (re-fire) → no-op
        self.recordPromoteQueue(cron.queue);
        affected += 1;
    }

    return .{
        .affected = affected,
        .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
    };
}

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

    // Use the client-provided next fire if given, else compute it from the cron
    // expression so a cron created via any client fires without the caller
    // pre-computing the schedule.
    if (op.next_run_ns > 0) {
        cron.next_run_ns = op.next_run_ns;
    } else if (cron.enabled and cron.schedule.len > 0) {
        cron.next_run_ns = @intCast(computeInitialNextRun(cron.schedule, @intCast(op.created_at_ns)));
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

    self.recordSideEffect(&enq_job);
    return self.applyEnqueue(b, &enqueue_op);
}
