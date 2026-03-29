//! Bulk action handler — retry, cancel, move, delete, requeue, hold, approve, reject.
//! Ported from Go internal/ops/ops_bulk.go.

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

/// Track batch counter adjustments during bulk actions.
/// Fixed-size to avoid allocation. Max 64 distinct batches per bulk op.
const max_batch_mods = 64;
const BatchMod = struct {
    batch_id_buf: [128]u8 = undefined,
    batch_id_len: u8 = 0,
    pending_delta: i32 = 0,
    failed_delta: i32 = 0,

    fn batchId(self: *const BatchMod) []const u8 {
        return self.batch_id_buf[0..self.batch_id_len];
    }
};

pub fn applyBulkAction(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.BulkActionOp) ops.OpResult {
    var affected: u32 = 0;

    // Track batch counter adjustments for delete/cancel.
    var batch_mods: [max_batch_mods]BatchMod = undefined;
    var batch_mod_count: u32 = 0;

    for (op.job_ids) |job_id| {
        var jk_buf: keys.KeyBuf = undefined;

        // For requeue: copy job data to stack buffer since applyEnqueue writes
        // to the same batch and may invalidate slices from b.get().
        var job_val_buf: [codec.max_job_encoded_size]u8 = undefined;
        const job_bytes = if (op.action == .requeue)
            b.getInto(keys.jobKey(&jk_buf, job_id), &job_val_buf)
        else
            b.get(keys.jobKey(&jk_buf, job_id));
        if (job_bytes == null) continue;

        var job = codec.decodeJob(job_bytes.?);
        const old_state = job.state;

        switch (op.action) {
            .requeue => {
                if (!job.state.isTerminal()) continue;

                // Load payload from jp| key into stack buffer.
                var payload_buf: [8192]u8 = undefined;
                var jpk_buf: keys.KeyBuf = undefined;
                const payload = b.getInto(keys.jobPayloadKey(&jpk_buf, job_id), &payload_buf);

                // Generate new job ID using a global counter to avoid collisions
                // when multiple bulk requeue operations share the same tick timestamp.
                self.requeue_counter += 1;
                var new_id_buf: [64]u8 = undefined;
                const new_id = std.fmt.bufPrint(&new_id_buf, "rq_{x}_{x}", .{ op.now_ns, self.requeue_counter }) catch "rq_err";

                // Build enqueue op from old job's config.
                const enq_job = ops.EnqueueJob{
                    .job_id = new_id,
                    .queue = job.queue,
                    .state = .pending,
                    .payload = payload,
                    .priority = job.priority,
                    .max_retries = job.max_retries,
                    .backoff = job.retry_backoff,
                    .base_delay_ms = job.retry_base_delay_ms,
                    .max_delay_ms = job.retry_max_delay_ms,
                    .unique_key = job.unique_key,
                    .unique_period_s = job.unique_period_s,
                    .tags = job.tags,
                    .expire_after_ms = job.expire_after_ms,
                    .created_at_ns = op.now_ns,
                    // Drop batch_id — old batch already counted this job.
                    .batch_id = null,
                    .parent_id = job_id, // lineage: new job's parent is the old job
                    .chain_id = if (job.chain_config != null) new_id else null,
                    .chain_step = job.chain_step,
                    .chain_config = job.chain_config,
                    .group = job.group,
                };

                const jobs_arr = [_]ops.EnqueueJob{enq_job};
                const enqueue_op = ops.EnqueueOp{
                    .jobs = &jobs_arr,
                    .now_ns = op.now_ns,
                };
                const enq_result = self.applyEnqueue(b, &enqueue_op);
                if (enq_result.err == null) {
                    self.recordSideEffect(&enq_job);
                }

                // Old job stays terminal — don't modify it.
                affected += 1;
                continue; // skip job write — old job is unchanged
            },

            .delete => {
                if (job.state == .active) continue;
                switch (job.state) {
                    .pending => {
                        if (job.expire_after_ms > 0 and job.expire_at_ns > 0) {
                            var xk_buf: keys.KeyBuf = undefined;
                            b.delete(keys.expireKey(&xk_buf, job.expire_at_ns, job.id));
                        }
                    },
                    .scheduled => {
                        var sk_buf: keys.KeyBuf = undefined;
                        b.delete(OpHandler.jobScheduledKey(&sk_buf, &job));
                    },
                    .retrying => {
                        var rk_buf: keys.KeyBuf = undefined;
                        b.delete(OpHandler.jobRetryingKey(&rk_buf, &job));
                    },
                    else => {},
                }
                // Adjust batch counters for non-terminal jobs.
                if (job.batch_id) |bid| {
                    if (bid.len > 0 and !job.state.isTerminal()) {
                        recordBatchMod(&batch_mods, &batch_mod_count, bid, -1, 1);
                    }
                }
                // Delete unique lock
                var uk_buf: keys.KeyBuf = undefined;
                if (OpHandler.jobUniqueKey(&uk_buf, &job)) |ukey| {
                    if (b.get(ukey)) |ub| {
                        const decoded = keys.decodeUniqueValue(ub);
                        if (std.mem.eql(u8, decoded.job_id, job.id)) b.delete(ukey);
                    }
                }
                OpHandler.deleteReadIndexes(b, &job);
                OpHandler.deleteTagIndexes(b, &job);
                self.decrQueueCounter(b, job.queue, job.state);

                b.delete(keys.jobKey(&jk_buf, job_id));
                var jpk_buf: keys.KeyBuf = undefined;
                b.delete(keys.jobPayloadKey(&jpk_buf, job_id));
                var jep_buf: keys.KeyBuf = undefined;
                var jee_buf: keys.KeyBuf = undefined;
                b.deleteRange(
                    keys.jobErrorPrefix(&jep_buf, job_id),
                    keys.prefixEnd(&jee_buf, keys.jobErrorPrefix(&jep_buf, job_id)) orelse "",
                );
                self.recordBulkResult(job_id, .delete, "", "", op.now_ns);
                affected += 1;
                continue; // skip job write — it's deleted
            },

            .cancel => {
                switch (job.state) {
                    .pending, .active, .scheduled, .retrying => {},
                    else => continue,
                }
                switch (job.state) {
                    .pending => {
                        if (job.expire_after_ms > 0 and job.expire_at_ns > 0) {
                            var xk_buf: keys.KeyBuf = undefined;
                            b.delete(keys.expireKey(&xk_buf, job.expire_at_ns, job.id));
                        }
                    },
                    .active => {
                        var ak_buf: keys.KeyBuf = undefined;
                        b.delete(OpHandler.jobActiveKey(&ak_buf, &job));
                        self.decrActiveCount(job.queue);
                        if (job.group) |g| self.decrFairnessActive(job.queue, g);
                    },
                    .scheduled => {
                        var sk_buf: keys.KeyBuf = undefined;
                        b.delete(OpHandler.jobScheduledKey(&sk_buf, &job));
                    },
                    .retrying => {
                        var rk_buf: keys.KeyBuf = undefined;
                        b.delete(OpHandler.jobRetryingKey(&rk_buf, &job));
                    },
                    else => unreachable,
                }
                // Adjust batch counters for non-terminal jobs.
                if (job.batch_id) |bid| {
                    if (bid.len > 0) {
                        recordBatchMod(&batch_mods, &batch_mod_count, bid, -1, 1);
                    }
                }
                // Delete unique lock
                var uk_buf: keys.KeyBuf = undefined;
                if (OpHandler.jobUniqueKey(&uk_buf, &job)) |ukey| {
                    if (b.get(ukey)) |ub| {
                        const decoded = keys.decodeUniqueValue(ub);
                        if (std.mem.eql(u8, decoded.job_id, job.id)) b.delete(ukey);
                    }
                }
                job.state = .cancelled;
                job.completed_at_ns = op.now_ns;
                job.worker_id = null;
                job.hostname = null;
                job.lease_expires_at_ns = 0;
                var dk_buf: keys.KeyBuf = undefined;
                b.set(keys.deadKey(&dk_buf, op.now_ns, job_id), "");
                self.dead_since_purge += 1;
                self.recordBulkResult(job_id, .update_state, "cancelled", "", op.now_ns);
            },

            .move => {
                const move_to = op.move_to_queue orelse continue;
                switch (job.state) {
                    .pending => {
                        // Stale entry in old queue's index is lazily cleaned on fetch.
                        self.pending.push(move_to, job.priority, job.created_at_ns, job_id);
                    },
                    .scheduled => {
                        var sk_buf: keys.KeyBuf = undefined;
                        b.delete(OpHandler.jobScheduledKey(&sk_buf, &job));
                        var nsk_buf: keys.KeyBuf = undefined;
                        b.set(keys.scheduledKey(&nsk_buf, move_to, job.scheduled_at_ns, job_id), "");
                    },
                    .retrying => {
                        var rk_buf: keys.KeyBuf = undefined;
                        b.delete(OpHandler.jobRetryingKey(&rk_buf, &job));
                        var nrk_buf: keys.KeyBuf = undefined;
                        b.set(keys.retryingKey(&nrk_buf, move_to, job.scheduled_at_ns, job_id), "");
                    },
                    else => continue,
                }
                // Transfer unique lock
                var uk_buf: keys.KeyBuf = undefined;
                if (OpHandler.jobUniqueKey(&uk_buf, &job)) |old_ukey| {
                    if (b.get(old_ukey)) |ub| {
                        const decoded = keys.decodeUniqueValue(ub);
                        if (std.mem.eql(u8, decoded.job_id, job.id)) {
                            b.delete(old_ukey);
                            var nuk_buf: keys.KeyBuf = undefined;
                            var nuv_buf: keys.KeyBuf = undefined;
                            b.set(
                                keys.uniqueKey(&nuk_buf, move_to, job.unique_key.?),
                                keys.encodeUniqueValue(&nuv_buf, job.id, decoded.expires_ns),
                            );
                        }
                    }
                }
                job.queue = move_to;
                self.recordBulkResult(job_id, .move, "pending", move_to, op.now_ns);
            },

            .change_priority => {
                if (job.state != .pending and job.state != .scheduled) continue;
                if (job.state == .pending) {
                    // Stale entry with old priority lazily cleaned on fetch.
                    self.pending.push(job.queue, op.priority, job.created_at_ns, job_id);
                }
                job.priority = op.priority;
            },

            .hold => {
                switch (job.state) {
                    .pending, .scheduled, .retrying => {},
                    else => continue,
                }
                switch (job.state) {
                    .pending => {
                        if (job.expire_after_ms > 0 and job.expire_at_ns > 0) {
                            var xk_buf: keys.KeyBuf = undefined;
                            b.delete(keys.expireKey(&xk_buf, job.expire_at_ns, job.id));
                            job.expire_at_ns = 0;
                        }
                    },
                    .scheduled => {
                        var sk_buf: keys.KeyBuf = undefined;
                        b.delete(OpHandler.jobScheduledKey(&sk_buf, &job));
                    },
                    .retrying => {
                        var rk_buf: keys.KeyBuf = undefined;
                        b.delete(OpHandler.jobRetryingKey(&rk_buf, &job));
                    },
                    else => unreachable,
                }
                job.state = .held;
                job.hold_reason = "bulk_hold";
                job.scheduled_at_ns = 0;
                self.recordBulkResult(job_id, .update_state, "held", "", op.now_ns);
            },

            .approve => {
                if (job.state != .held) continue;
                job.state = .pending;
                self.pending.push(job.queue, job.priority, job.created_at_ns, job_id);
                if (job.expire_after_ms > 0) {
                    job.expire_at_ns = op.now_ns + @as(u64, job.expire_after_ms) * 1_000_000;
                    var xk_buf: keys.KeyBuf = undefined;
                    b.set(keys.expireKey(&xk_buf, job.expire_at_ns, job_id), "");
                }
                self.recordBulkResult(job_id, .update_state, "pending", "", op.now_ns);
            },

            .reject => {
                if (job.state != .held) continue;
                // Delete unique lock
                var uk_buf: keys.KeyBuf = undefined;
                if (OpHandler.jobUniqueKey(&uk_buf, &job)) |ukey| {
                    if (b.get(ukey)) |ub| {
                        const decoded = keys.decodeUniqueValue(ub);
                        if (std.mem.eql(u8, decoded.job_id, job_id)) b.delete(ukey);
                    }
                }
                job.state = .dead;
                job.completed_at_ns = op.now_ns;
                job.failed_at_ns = op.now_ns;
                var dk_buf: keys.KeyBuf = undefined;
                b.set(keys.deadKey(&dk_buf, op.now_ns, job_id), "");
                self.dead_since_purge += 1;
                // Write job error KV entry for rejected jobs.
                {
                    var ek_buf: keys.KeyBuf = undefined;
                    var err_val_buf: [256]u8 = undefined;
                    const err_json = std.fmt.bufPrint(&err_val_buf, "{{\"job_id\":\"{s}\",\"attempt\":{d},\"error\":\"rejected\",\"created_at_ns\":{d}}}", .{
                        job_id, job.attempt, op.now_ns,
                    }) catch "";
                    if (err_json.len > 0) {
                        b.set(keys.jobErrorKey(&ek_buf, job_id, @intCast(job.attempt)), err_json);
                    }
                }
                self.recordBulkResult(job_id, .update_state, "dead", "", op.now_ns);
            },
        }

        // Update read indexes if state changed
        if (job.state != old_state) {
            self.transitionReadIndexes(b, &job, old_state, job.state);
        }

        // Write updated job (for non-delete actions)
        var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
        b.set(keys.jobKey(&jk_buf, job_id), codec.encodeJob(&job_enc_buf, &job));
        self.verifyJobIndexes(b, &job, "bulk");
        affected += 1;
    }

    // Apply accumulated batch counter adjustments and fire callbacks.
    applyBatchMods(self, b, &batch_mods, batch_mod_count, op.now_ns);

    return .{ .affected = affected };
}

/// Record a batch modification. Coalesces multiple changes to the same batch.
fn recordBatchMod(mods: []BatchMod, count: *u32, batch_id: []const u8, pending_delta: i32, failed_delta: i32) void {
    // Look for existing entry.
    for (mods[0..count.*]) |*m| {
        if (std.mem.eql(u8, m.batchId(), batch_id)) {
            m.pending_delta += pending_delta;
            m.failed_delta += failed_delta;
            return;
        }
    }
    // New entry.
    if (count.* >= max_batch_mods) return; // safety cap
    var m = &mods[count.*];
    m.* = .{};
    const len = @min(batch_id.len, m.batch_id_buf.len);
    @memcpy(m.batch_id_buf[0..len], batch_id[0..len]);
    m.batch_id_len = @intCast(len);
    m.pending_delta = pending_delta;
    m.failed_delta = failed_delta;
    count.* += 1;
}

/// Apply batch modifications: update counters, check completion, fire callbacks.
/// Does NOT delegate to handleBatchJobComplete — applies deltas directly
/// to avoid double-counting (handleBatchJobComplete would re-read and decrement again).
fn applyBatchMods(self: *OpHandler, b: *kv.WriteBatch, mods: []const BatchMod, count: u32, now_ns: u64) void {
    for (mods[0..count]) |*m| {
        var bk_buf: keys.KeyBuf = undefined;
        const bkey = keys.batchKey(&bk_buf, m.batchId());
        var batch_val_buf: [codec.max_batch_encoded_size]u8 = undefined;
        const batch_bytes = b.getInto(bkey, &batch_val_buf) orelse continue;
        var batch = codec.decodeBatch(batch_bytes);

        // Apply deltas.
        const new_pending = @as(i64, batch.pending) + @as(i64, m.pending_delta);
        assert.check(new_pending >= 0, "applyBatchMods: pending underflow for batch {s} (pending={d} delta={d})", .{ m.batchId(), batch.pending, m.pending_delta });
        batch.pending = @intCast(new_pending);
        const new_failed = @as(i64, batch.failed) + @as(i64, m.failed_delta);
        assert.check(new_failed >= 0, "applyBatchMods: failed underflow for batch {s}", .{m.batchId()});
        batch.failed = @intCast(new_failed);

        assert.check(batch.succeeded + batch.failed <= batch.total, "batch completed exceeds total", .{});

        // Check if batch is now complete.
        if (batch.pending == 0 and !batch.open and batch.total > 0) {
            batch.completed_at_ns = now_ns;
            // Fire callback directly.
            if (batch.callback_queue) |cq| {
                if (cq.len > 0) {
                    var id_buf: [64]u8 = undefined;
                    const cb_id = std.fmt.bufPrint(&id_buf, "batch_cb_{s}", .{m.batchId()}) catch "batch_cb_err";
                    const cb_job = ops.EnqueueJob{
                        .job_id = cb_id,
                        .queue = cq,
                        .payload = batch.callback_payload,
                        .state = .pending,
                        .priority = types.priority_normal,
                        .created_at_ns = now_ns,
                    };
                    const jobs_arr = [_]ops.EnqueueJob{cb_job};
                    const enqueue_op = ops.EnqueueOp{
                        .jobs = &jobs_arr,
                        .now_ns = now_ns,
                    };
                    const enq_result2 = self.applyEnqueue(b, &enqueue_op);
                    if (enq_result2.err == null) {
                        self.recordSideEffect(&cb_job);
                    }
                }
            }
        }

        var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
        b.set(bkey, codec.encodeBatch(&batch_enc_buf, &batch));
    }
}
