//! Mirror event generation — single-writer, called from pipeline thread.
//!
//! Generates MirrorOp events from (op_type, data, result) for all ops.
//! Fail and bulk_action are no-ops here — handled by mirrorEffects
//! which drains handler's accumulated effect buffers.

const std = @import("std");
const ops = @import("ops.zig");
const types = @import("types.zig");
const mirror_mod = @import("mirror.zig");
const handler_mod = @import("handler.zig");

const Mirror = mirror_mod.Mirror;
const MirrorOp = mirror_mod.MirrorOp;
const OpHandler = handler_mod.OpHandler;

/// Generate mirror events for a single request. Called from pipeline after commit.
/// Handles all op types that can be derived from request data + result alone.
/// Fail and bulk_action are handled by mirrorEffects (need handler output).
pub fn mirrorFromOp(m: *Mirror, op_type: ops.OpType, data: *const ops.OpData, result: *const ops.OpResult) void {
    if (result.err != null) return;

    switch (op_type) {
        .enqueue => {
            for (data.enqueue.jobs) |*j| {
                m.enqueueJob(j);
            }
        },
        .fetch => {
            const now = data.fetch.now_ns;
            const lease_ms = data.fetch.lease_duration_ms;
            const worker_id = data.fetch.worker_id;
            for (0..result.affected) |i| {
                const f = &result.fetched[i];
                var p = MirrorOp.FetchPayload{
                    .now_ns = now,
                    .lease_duration_ms = lease_ms,
                };
                @memcpy(p.job_id[0..f.id_len], f.id_buf[0..f.id_len]);
                p.job_id_len = f.id_len;
                const wl: u8 = @intCast(@min(worker_id.len, p.worker_id.len));
                @memcpy(p.worker_id[0..wl], worker_id[0..wl]);
                p.worker_id_len = wl;
                m.enqueue(.{ .op_type = .fetch, .payload = .{ .fetch = p } });
            }
        },
        .ack => {
            const now = data.ack.now_ns;
            for (data.ack.acks) |*a| {
                var p = MirrorOp.AckPayload{ .now_ns = now };
                const il: u8 = @intCast(@min(a.job_id.len, p.job_id.len));
                @memcpy(p.job_id[0..il], a.job_id[0..il]);
                p.job_id_len = il;
                if (a.result) |r| {
                    const rl: u16 = @intCast(@min(r.len, p.result.len));
                    @memcpy(p.result[0..rl], r[0..rl]);
                    p.result_len = rl;
                }
                if (a.hold_reason) |hr| {
                    const hl: u8 = @intCast(@min(hr.len, p.hold_reason.len));
                    @memcpy(p.hold_reason[0..hl], hr[0..hl]);
                    p.hold_reason_len = hl;
                }
                m.enqueue(.{ .op_type = .ack, .payload = .{ .ack = p } });
            }
        },
        .fail => {}, // Handled by mirrorEffects (needs handler FailResult).
        .bulk_action => {}, // Handled by mirrorEffects (needs handler BulkResult).
        .heartbeat => {
            const hb = &data.heartbeat;
            var p = MirrorOp.HeartbeatPayload{ .now_ns = hb.now_ns };
            const wl: u8 = @intCast(@min(hb.worker_id.len, p.worker_id.len));
            @memcpy(p.worker_id[0..wl], hb.worker_id[0..wl]);
            p.worker_id_len = wl;
            m.enqueue(.{ .op_type = .heartbeat, .payload = .{ .heartbeat = p } });

            // Per-job heartbeat updates.
            const lease_ns = hb.now_ns + 30 * std.time.ns_per_s;
            const n = @min(hb.job_ids.len, hb.job_ops.len);
            for (0..n) |i| {
                m.enqueueHeartbeatJob(hb.job_ids[i], hb.job_ops[i].progress, hb.job_ops[i].checkpoint, lease_ns);
            }
        },
        .maintenance => {}, // All maintenance flows through mirrorEffects via per-job BulkResults.
        .queue_config => {
            const qc = &data.queue_config;
            var p = MirrorOp.QueueConfigPayload{
                .action = qc.action,
                .max_concurrency = qc.max_concurrency,
                .rate_limit = qc.rate_limit,
                .rate_window_ms = qc.rate_window_ms,
            };
            const ql: u8 = @intCast(@min(qc.queue.len, p.queue.len));
            @memcpy(p.queue[0..ql], qc.queue[0..ql]);
            p.queue_len = ql;
            m.enqueue(.{ .op_type = .queue_config, .payload = .{ .queue_config = p } });
        },
        .clear_queue => {
            m.enqueueQueueClear(data.clear_queue.queue);
        },
        .delete_queue => {
            m.enqueueQueueDelete(data.delete_queue.queue);
        },
        .batch_create => {
            const bid = data.batch_create.batch_id;
            if (bid.len > 0) m.enqueueBatchCreate(bid, data.batch_create.created_at_ns);
        },
        .batch_seal => {
            const bid = data.batch_seal.batch_id;
            if (bid.len > 0) m.enqueueBatchSeal(bid);
        },
        .set_budget => {
            const b = &data.set_budget;
            m.enqueueBudgetUpsert(b.id, b.scope, b.target, b.daily_usd, b.per_job_usd, b.on_exceed);
        },
        .delete_budget => {
            m.enqueueBudgetDelete(data.delete_budget.scope, data.delete_budget.target);
        },
        .cron_create => {
            const c = &data.cron_create;
            m.enqueueCronUpsert(.{
                .id = c.cron_id,
                .name = c.name,
                .queue = c.queue,
                .schedule = c.schedule,
                .timezone = c.timezone,
                .payload = c.payload,
                .unique_key = c.unique_key,
                .max_retries = c.max_retries,
                .enabled = c.enabled,
                .created_at_ns = c.now_ns,
            });
        },
        .cron_update => {
            const c = &data.cron_update;
            if (c.enabled != null and c.name == null and c.queue == null and c.schedule == null) {
                m.enqueueCronToggle(c.cron_id, c.enabled.?);
            } else {
                m.enqueueCronUpsert(.{
                    .id = c.cron_id,
                    .name = c.name orelse "",
                    .queue = c.queue orelse "",
                    .schedule = c.schedule orelse "",
                    .timezone = c.timezone orelse "",
                    .payload = c.payload,
                    .unique_key = c.unique_key,
                    .max_retries = if (c.max_retries) |mr| mr else 0,
                    .enabled = c.enabled orelse true,
                    .created_at_ns = c.now_ns,
                });
            }
        },
        .cron_delete => {
            m.enqueueCronDelete(data.cron_delete.cron_id);
        },
        .cron_trigger => {}, // Triggered job mirrored via handler side_effects.
        .modify_ent_setting => {},
        .multi => {},
    }
}

/// Drain handler's accumulated effects into mirror events.
/// Called once per batch, after mirrorFromOp for each request.
pub fn mirrorEffects(m: *Mirror, h: *const OpHandler) void {
    // Side-effect enqueues (chain-on-failure, batch callbacks, cron triggers).
    for (h.side_effects[0..h.side_effect_count]) |*se| {
        m.enqueue(.{ .op_type = .enqueue, .payload = .{ .enqueue = se.* } });
    }

    // Fail results.
    for (h.fail_results[0..h.fail_result_count]) |*fr| {
        var p = MirrorOp.FailPayload{
            .new_state = fr.new_state,
            .attempt = fr.attempt,
            .retry_at_ns = fr.retry_at_ns,
            .now_ns = fr.now_ns,
        };
        @memcpy(p.job_id[0..fr.job_id_len], fr.job_id[0..fr.job_id_len]);
        p.job_id_len = fr.job_id_len;
        @memcpy(p.error_msg[0..fr.error_msg_len], fr.error_msg[0..fr.error_msg_len]);
        p.error_msg_len = fr.error_msg_len;
        if (fr.backtrace_len > 0) {
            @memcpy(p.backtrace[0..fr.backtrace_len], fr.backtrace[0..fr.backtrace_len]);
            p.backtrace_len = fr.backtrace_len;
        }
        m.enqueue(.{ .op_type = .fail, .payload = .{ .fail = p } });
    }

    // Bulk action results.
    for (h.bulk_results[0..h.bulk_result_count]) |*br| {
        const action: @TypeOf(@as(MirrorOp.BulkActionJobPayload, .{}).action) = switch (br.action) {
            .update_state => .update_state,
            .delete => .delete,
            .move => .move,
        };
        m.enqueueBulkActionJob(
            br.jobId(),
            action,
            br.stateSlice(),
            br.now_ns,
        );
        if (br.action == .move) {
            m.enqueueBulkActionMove(br.jobId(), br.queueSlice());
            m.enqueueBulkActionJob(br.jobId(), .update_state, "pending", br.now_ns);
        }
    }
}
