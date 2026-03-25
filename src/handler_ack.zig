//! Ack handler — marks active jobs as completed (or re-enqueues for agents).
//! Ported from Go internal/ops/ops_ack_fail.go (ack portion).

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

// Chain step sentinel values (since chain_step is u16, we use high values for cleanup handlers).
const chain_step_exit: u16 = 0xFFFF;
const chain_step_failure: u16 = 0xFFFE;
const chain_step_max: u16 = 0xFFFD; // max valid step index

pub fn applyAck(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.AckOp) ops.OpResult {
    if (op.acks.len == 0) return .{ .err = "no jobs provided" };

    var affected: u32 = 0;

    for (op.acks) |*ack| {
        if (ack.job_id.len == 0) continue;

        var jk_buf: keys.KeyBuf = undefined;
        var job_val_buf: [codec.max_job_encoded_size]u8 = undefined;
        const job_bytes = b.getInto(keys.jobKey(&jk_buf, ack.job_id), &job_val_buf);
        if (job_bytes == null) continue; // job not found, skip

        var job = codec.decodeJob(job_bytes.?);
        if (job.state != .active) continue; // not active, skip

        // Lease token check: reject stale acks from workers whose lease was reclaimed.
        if (job.lease_token != 0 and ack.lease_token != job.lease_token) continue;

        // Hold logic
        var next_state: types.JobState = .completed;
        switch (ack.ack_status) {
            .hold => {
                next_state = .held;
                job.hold_reason = ack.hold_reason;
            },
            .done => {
                next_state = .completed;
            },
        }

        if (ack.checkpoint) |cp| {
            if (cp.len > 0) job.checkpoint = cp;
        }

        if (next_state == .completed) {
            job.completed_at_ns = op.now_ns;
            var dk_buf: keys.KeyBuf = undefined;
            b.set(keys.deadKey(&dk_buf, op.now_ns, job.id), "");

            if (job.expire_after_ms > 0 and job.expire_at_ns > 0) {
                var xk_buf: keys.KeyBuf = undefined;
                b.delete(keys.expireKey(&xk_buf, job.expire_at_ns, job.id));
                job.expire_at_ns = 0;
            }

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
                if (bid.len > 0) self.handleBatchJobComplete(b, bid, true, op.now_ns);
            }

            // Chain advancement — enqueue next step.
            // Only advance if chain_step is a valid index (not a cleanup sentinel).
            if (job.chain_config) |cc| {
                if (cc.len > 0 and job.chain_step <= chain_step_max) {
                    advanceChain(self, b, &job, ack, op.now_ns);
                }
            }
        }

        // Clear worker fields
        job.worker_id = null;
        job.hostname = null;
        job.lease_expires_at_ns = 0;

        if (ack.result) |r| {
            if (r.len > 0) job.result = r;
        }

        // Delete active key, decrement counts
        var ak_buf: keys.KeyBuf = undefined;
        b.delete(OpHandler.jobActiveKey(&ak_buf, &job));
        self.decrActiveCount(job.queue);
        if (job.group) |g| self.decrFairnessActive(job.queue, g);

        // Write updated job
        job.state = next_state;
        var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
        b.set(keys.jobKey(&jk_buf, ack.job_id), codec.encodeJob(&job_enc_buf, &job));

        self.verifyJobIndexes(b, &job, "ack");
        affected += 1;
    }

    return .{ .affected = affected };
}

/// Advance a chain after successful ack. Parses chain_config JSON to find
/// the next step and enqueues it. Off the hot path — only runs for chain jobs.
fn advanceChain(self: *OpHandler, b: *kv.WriteBatch, job: *const types.Job, ack: *const ops.AckJob, now_ns: u64) void {
    const cc = job.chain_config orelse return;
    if (cc.len == 0) return;

    // Parse chain config JSON: {"steps":[{"queue":"q","payload":...}],"on_exit":{"queue":"done"}}.
    // payload is Value because SDKs may send it as a string or a JSON object.
    const ChainStep = struct {
        queue: ?[]const u8 = null,
        payload: ?std.json.Value = null,
    };
    const ChainDef = struct {
        steps: ?[]const ChainStep = null,
        on_exit: ?ChainStep = null,
        on_failure: ?ChainStep = null,
    };

    // Use a stack allocator for JSON parsing (no heap allocation).
    var parse_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    const parsed = std.json.parseFromSlice(ChainDef, fba.allocator(), cc, .{
        .ignore_unknown_fields = true,
    }) catch return;

    const chain = parsed.value;
    const steps = chain.steps orelse return;

    const current_step = job.chain_step;
    const next_idx = current_step + 1;

    const is_exit = (next_idx >= steps.len);

    var next_queue: ?[]const u8 = null;
    var next_payload: ?std.json.Value = null;
    var next_chain_step: u16 = 0;

    if (is_exit) {
        // Exit → jump to on_exit handler.
        if (chain.on_exit) |on_exit| {
            next_queue = on_exit.queue;
            next_payload = on_exit.payload;
            next_chain_step = chain_step_exit;
        } else return;
    } else if (next_idx < steps.len) {
        // Normal progression.
        next_queue = steps[next_idx].queue;
        next_payload = steps[next_idx].payload;
        next_chain_step = @intCast(next_idx);
    } else {
        // Past the end → fire on_exit if exists.
        if (chain.on_exit) |on_exit| {
            next_queue = on_exit.queue;
            next_payload = on_exit.payload;
            next_chain_step = chain_step_exit;
        } else return;
    }

    const queue = next_queue orelse return;

    // Merge previous_job_id and previous_result into payload (matches Go).
    // Off the hot path — only runs for chain jobs.
    var merged_buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&merged_buf);
    const w = fbs.writer();
    w.writeAll("{\"previous_job_id\":\"") catch return;
    w.writeAll(job.id) catch return;
    w.writeByte('"') catch return;
    if (ack.result) |r| {
        if (r.len > 0) {
            w.writeAll(",\"previous_result\":") catch return;
            w.writeAll(r) catch return;
        }
    }
    if (next_payload) |pv| {
        switch (pv) {
            .string => |s| {
                if (s.len > 2 and s[0] == '{') {
                    w.writeByte(',') catch return;
                    w.writeAll(s[1..]) catch return;
                } else {
                    w.writeByte('}') catch return;
                }
            },
            .object => {
                var obj_iter = pv.object.iterator();
                while (obj_iter.next()) |entry| {
                    w.writeByte(',') catch return;
                    w.print("{f}:", .{std.json.fmt(entry.key_ptr.*, .{})}) catch return;
                    w.print("{f}", .{std.json.fmt(entry.value_ptr.*, .{})}) catch return;
                }
                w.writeByte('}') catch return;
            },
            else => w.writeByte('}') catch return,
        }
    } else {
        w.writeByte('}') catch return;
    }
    const merged_payload = fbs.getWritten();

    // Generate a job ID for the next chain step.
    var id_buf: [64]u8 = undefined;
    const chain_job_id = std.fmt.bufPrint(&id_buf, "chain_{s}_{d}", .{ job.id, next_chain_step }) catch return;

    // Assert: chain job must not already exist. If it does, something re-triggered
    // advanceChain for a parent that already spawned this step (e.g. bulk retry on parent
    // without cleaning up downstream chain state).
    var check_jk_buf: keys.KeyBuf = undefined;
    assert.check(b.get(keys.jobKey(&check_jk_buf, chain_job_id)) == null,
        "advanceChain: chain job already exists: step={d} parent={s}", .{ next_chain_step, job.id });

    const chain_job = ops.EnqueueJob{
        .job_id = chain_job_id,
        .queue = queue,
        .payload = merged_payload,
        .state = .pending,
        .priority = job.priority,
        .max_retries = job.max_retries,
        .created_at_ns = now_ns,
        .chain_id = job.chain_id,
        .chain_step = next_chain_step,
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

