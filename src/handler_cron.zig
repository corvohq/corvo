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

        // Compute the next fire. Do not persist the advance until the enqueue
        // succeeds: resource pressure must leave this slot due for a retry,
        // rather than silently dropping a scheduled run.
        const parsed = cron_expr.parse(cron.schedule) catch {
            cron.enabled = false;
            var db_buf: [codec.max_cron_encoded_size]u8 = undefined;
            b.set(keys.cronKey(&ck_buf, cron_id), codec.encodeCron(&db_buf, &cron));
            continue;
        };
        const next_run_ns: i64 = @intCast(cron_expr.nextFire(&parsed, now_ns) orelse 0);

        // Prefer a readable deterministic per-slot ID, but probe hash-derived
        // alternatives when a user has occupied it or the cron ID is too long.
        // The enqueue and schedule advance commit in the same atomic batch.
        var jid_buf: [64]u8 = undefined;
        const job_id = handler.resolveCronFireId(b, &jid_buf, cron_id, fire_slot) orelse continue;

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
        const result = self.applyEnqueue(b, &enqueue_op);
        if (result.err != null) continue;

        cron.next_run_ns = next_run_ns;
        cron.last_run_ns = @intCast(now_ns);
        var enc_buf: [codec.max_cron_encoded_size]u8 = undefined;
        b.set(keys.cronKey(&ck_buf, cron_id), codec.encodeCron(&enc_buf, &cron));
        self.recordPromoteQueue(cron.queue);
        affected += 1;
    }

    return .{
        .affected = affected,
        .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
    };
}

pub fn applyCreateCron(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.CreateCronOp) ops.OpResult {
    if (op.cron_id.len == 0 or op.cron_id.len > types.max_entity_id_len or
        std.mem.indexOfScalar(u8, op.cron_id, 0) != null)
        return .{ .err = "invalid cron_id" };
    if (op.name.len == 0 or op.name.len > 255 or
        std.mem.indexOfScalar(u8, op.name, 0) != null)
        return .{ .err = "invalid cron name" };
    if (op.queue.len == 0 or op.queue.len > types.max_queue_name_len or
        std.mem.indexOfScalar(u8, op.queue, 0) != null)
        return .{ .err = "invalid cron queue" };
    if (op.schedule.len == 0) return .{ .err = "invalid cron schedule" };
    _ = cron_expr.parse(op.schedule) catch return .{ .err = "invalid cron schedule" };
    if (op.created_at_ns == 0) return .{ .err = "invalid cron timestamp" };
    if (op.unique_key) |uk| {
        if (uk.len > 255 or std.mem.indexOfScalar(u8, uk, 0) != null)
            return .{ .err = "invalid cron unique_key" };
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
    if (codec.cronEncodedSize(&cron) > codec.max_cron_encoded_size)
        return .{ .err = "cron metadata too large" };

    // IDs and names are independent unique indexes. Checking only cn| allowed
    // an ID collision to overwrite sc| while leaving the old cn| orphaned.
    var existing_ck_buf: keys.KeyBuf = undefined;
    if (b.get(keys.cronKey(&existing_ck_buf, op.cron_id)) != null)
        return .{ .err = "cron already exists" };

    var cn_buf: keys.KeyBuf = undefined;
    if (b.get(keys.cronNameKey(&cn_buf, op.name)) != null)
        return .{ .err = "cron name conflict" };

    var cron_enc_buf: [codec.max_cron_encoded_size]u8 = undefined;
    var ck_buf: keys.KeyBuf = undefined;
    b.set(keys.cronKey(&ck_buf, op.cron_id), codec.encodeCron(&cron_enc_buf, &cron));
    b.set(keys.cronNameKey(&cn_buf, op.name), op.cron_id);

    return .{ .affected = 1 };
}

pub fn applyUpdateCron(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.UpdateCronOp) ops.OpResult {
    if (op.cron_id.len == 0 or op.cron_id.len > types.max_entity_id_len or
        std.mem.indexOfScalar(u8, op.cron_id, 0) != null)
        return .{ .err = "invalid cron_id" };
    var ck_buf: keys.KeyBuf = undefined;
    const cron_bytes = b.get(keys.cronKey(&ck_buf, op.cron_id));
    if (cron_bytes == null) {
        return .{ .err = "cron not found" };
    }

    const old_cron = codec.decodeCron(cron_bytes.?);
    var cron = old_cron;
    var reschedule = false;

    // Build and validate the entire replacement before changing either the
    // cron record or its name index. Previously a name update was written
    // first, so a later invalid schedule returned an error with a partial rename.
    if (op.name) |name| {
        if (name.len > 0) {
            if (name.len > 255 or std.mem.indexOfScalar(u8, name, 0) != null)
                return .{ .err = "invalid cron name" };
            cron.name = name;
        }
    }
    if (op.queue) |q| {
        if (q.len > 0) {
            if (q.len > types.max_queue_name_len or std.mem.indexOfScalar(u8, q, 0) != null)
                return .{ .err = "invalid cron queue" };
            cron.queue = q;
        }
    }
    if (op.schedule) |s| {
        if (s.len > 0) {
            _ = cron_expr.parse(s) catch return .{ .err = "invalid cron schedule" };
            cron.schedule = s;
            reschedule = true;
        }
    }
    if (op.timezone) |tz| {
        if (tz.len > 0) cron.timezone = tz;
    }
    if (op.payload) |p| {
        cron.payload = p;
    }
    if (op.unique_key) |uk| {
        if (uk.len > 255 or std.mem.indexOfScalar(u8, uk, 0) != null)
            return .{ .err = "invalid cron unique_key" };
        cron.unique_key = uk;
    }
    if (op.max_retries) |mr| {
        cron.max_retries = mr;
    }
    if (op.enabled) |e| {
        if (e and !cron.enabled) reschedule = true;
        cron.enabled = e;
    }
    if (op.next_run_ns > 0) {
        cron.next_run_ns = op.next_run_ns;
    } else if (reschedule and cron.enabled) {
        if (op.now_ns == 0) return .{ .err = "invalid cron timestamp" };
        cron.next_run_ns = @intCast(computeInitialNextRun(cron.schedule, op.now_ns));
    } else if (!cron.enabled) {
        cron.next_run_ns = 0;
    }
    if (codec.cronEncodedSize(&cron) > codec.max_cron_encoded_size)
        return .{ .err = "cron metadata too large" };

    if (!std.mem.eql(u8, old_cron.name, cron.name)) {
        var cn_buf: keys.KeyBuf = undefined;
        const existing = b.get(keys.cronNameKey(&cn_buf, cron.name));
        if (existing != null and !std.mem.eql(u8, existing.?, op.cron_id))
            return .{ .err = "cron name conflict" };

        var old_cn_buf: keys.KeyBuf = undefined;
        b.delete(keys.cronNameKey(&old_cn_buf, old_cron.name));
        b.set(keys.cronNameKey(&cn_buf, cron.name), op.cron_id);
    }

    var cron_enc_buf: [codec.max_cron_encoded_size]u8 = undefined;
    b.set(keys.cronKey(&ck_buf, op.cron_id), codec.encodeCron(&cron_enc_buf, &cron));

    return .{ .affected = 1 };
}

pub fn applyDeleteCron(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.DeleteCronOp) ops.OpResult {
    if (op.cron_id.len == 0 or op.cron_id.len > types.max_entity_id_len or
        std.mem.indexOfScalar(u8, op.cron_id, 0) != null)
        return .{ .err = "invalid cron_id" };
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
    if (op.cron_id.len == 0 or op.cron_id.len > types.max_entity_id_len or
        std.mem.indexOfScalar(u8, op.cron_id, 0) != null)
        return .{ .err = "invalid cron_id" };
    if (op.job_id.len == 0 or op.job_id.len > types.max_job_id_len or
        std.mem.indexOfScalar(u8, op.job_id, 0) != null)
        return .{ .err = "invalid cron job_id" };
    if (op.now_ns == 0) return .{ .err = "invalid cron timestamp" };
    var ck_buf: keys.KeyBuf = undefined;
    const cron_bytes = b.get(keys.cronKey(&ck_buf, op.cron_id));
    if (cron_bytes == null) {
        return .{ .err = "cron not found" };
    }

    var cron = codec.decodeCron(cron_bytes.?);

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

    var result = self.applyEnqueue(b, &enqueue_op);
    if (result.err != null) return result;

    cron.last_run_ns = @intCast(op.now_ns);
    if (op.next_run_ns > 0) cron.next_run_ns = op.next_run_ns;
    var cron_enc_buf: [codec.max_cron_encoded_size]u8 = undefined;
    b.set(keys.cronKey(&ck_buf, op.cron_id), codec.encodeCron(&cron_enc_buf, &cron));

    self.recordSideEffect(&enq_job);
    self.recordPromoteQueue(enq_job.queue);
    result.notify_queues = self.promoteQueueSlices();
    return result;
}
