//! SimClient — adversarial simulated worker for the VOPR simulator.
//!
//! Routes all operations through Pipeline v2 via RPC binary protocol over
//! SimBackend. Two-phase tick model:
//!   inject()          — pick action, build RPC frame, inject into SimBackend
//!   processResponse() — read response from SimBackend, update client state
//!
//! Exercises the full write path: RPC decode → handler.apply → KV commit →
//! RPC encode. Maintenance goes through MSG_MAINTENANCE (not engine.apply).

const std = @import("std");
const corvo = @import("corvo");
const assert = corvo.assert;
const types = corvo.types;
const ops = corvo.ops;
const rpc = corvo.rpc;
const io_mod = corvo.io;
const BufWriter = rpc.BufWriter;
const BufReader = rpc.BufReader;
const SimBackend = io_mod.SimBackend;
const Config = @import("config.zig").Config;
const clock_mod = @import("clock.zig");

const max_active_jobs = 64;
const max_completed_ids = 128;
const max_stale_jobs = 8;

pub const SimClient = struct {
    id: u32,
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    backend: *SimBackend,
    config: Config,
    queues: []const []const u8,
    conn_id: u16,
    req_counter: u32 = 0,

    // Pending action state (set during inject, read during processResponse)
    pending_msg_type: u8 = 0,

    // Worker ID
    worker_id_buf: [32]u8 = undefined,
    worker_id_len: usize = 0,

    // Job ID generation
    job_seq: u32 = 0,

    // Active jobs (fetched, not yet acked/failed).
    active_jobs: [max_active_jobs]JobEntry = undefined,
    active_count: usize = 0,

    // Recently completed/dead job IDs (for bulk retry/cancel/delete).
    completed_ids: [max_completed_ids]IdBuf = undefined,
    completed_count: usize = 0,

    // Stale jobs: jobs we "forgot" to ack, letting leases expire.
    // Used to later send stale acks that should be rejected.
    stale_jobs: [max_stale_jobs]JobEntry = undefined,
    stale_count: usize = 0,

    // Queue pause state tracking.
    paused_queues: [8]bool = [_]bool{false} ** 8,

    // Stats
    enqueued: u32 = 0,
    fetched: u32 = 0,
    acked: u32 = 0,
    failed: u32 = 0,
    bulk_ops: u32 = 0,
    maintenance_ops: u32 = 0,
    heartbeats: u32 = 0,
    queue_ops: u32 = 0,
    unique_conflicts: u32 = 0,
    double_acks: u32 = 0,
    stale_acks: u32 = 0,
    clear_queues: u32 = 0,

    // Fetch subscription: true when we sent a fetch that got no immediate response.
    // The pipeline will push MSG_FETCH_BATCH_RESP when jobs become available.
    fetch_subscribed: bool = false,

    // Scratch buffer for building RPC frames.
    // Layout: [frame_header:9][payload...]
    frame_buf: [8192]u8 = undefined,

    const IdBuf = struct {
        buf: [64]u8 = undefined,
        len: usize = 0,
        fn slice(self: *const IdBuf) []const u8 {
            return self.buf[0..self.len];
        }
    };

    const JobEntry = struct {
        id_buf: [64]u8 = undefined,
        id_len: usize = 0,
        queue_buf: [64]u8 = undefined,
        queue_len: usize = 0,
        will_fail: bool = false,

        fn jobID(self: *const JobEntry) []const u8 {
            return self.id_buf[0..self.id_len];
        }
        fn queue(self: *const JobEntry) []const u8 {
            return self.queue_buf[0..self.queue_len];
        }
    };

    pub fn init(
        id: u32,
        seed: u64,
        backend: *SimBackend,
        conn_id: u16,
        config: Config,
        queues: []const []const u8,
    ) SimClient {
        var c = SimClient{
            .id = id,
            .prng = std.Random.DefaultPrng.init(seed),
            .rng = undefined,
            .backend = backend,
            .conn_id = conn_id,
            .config = config,
            .queues = queues,
        };
        c.rng = c.prng.random();
        const w = std.fmt.bufPrint(&c.worker_id_buf, "sim-worker-{d}", .{id}) catch unreachable;
        c.worker_id_len = w.len;
        return c;
    }

    fn workerID(self: *const SimClient) []const u8 {
        return self.worker_id_buf[0..self.worker_id_len];
    }

    // ====================================================================
    // Phase 1: inject — pick action, build RPC frame, inject into backend
    // ====================================================================

    pub fn inject(self: *SimClient) void {
        self.pending_msg_type = 0;

        assert.check(
            self.active_count <= max_active_jobs,
            "SimClient.inject: active_count overflow",
            .{},
        );

        if (self.active_count >= max_active_jobs / 2) {
            self.doComplete();
            return;
        }

        const r = self.rng.float(f64);
        var threshold: f64 = 0;

        // Maintenance
        threshold += self.config.maintenance_rate;
        if (r < threshold) {
            self.doMaintenance();
            return;
        }

        // Bulk action (on completed/dead jobs)
        threshold += self.config.bulk_rate;
        if (r < threshold and self.completed_count > 0) {
            self.doBulkAction();
            return;
        }

        // Queue ops (pause/resume/clear)
        threshold += self.config.queue_op_rate;
        if (r < threshold) {
            self.doQueueOp();
            return;
        }

        // Heartbeat
        if (self.active_count > 0 and self.chance(self.config.heartbeat_rate)) {
            self.doHeartbeat();
            return;
        }

        // Adversarial: double-ack or ack non-existent
        if (self.chance(0.02)) {
            self.doAdversarialAck();
            return;
        }

        // Stale ack: send an ack for a job we previously "forgot" about.
        if (self.stale_count > 0 and self.chance(0.02)) {
            self.doStaleAck();
            return;
        }

        // Core: complete, fetch, or enqueue
        if (self.active_count == 0) {
            if (self.fetch_subscribed or self.chance(0.6)) self.doEnqueue() else self.doFetch();
        } else {
            const r2 = self.rng.float(f64);
            if (r2 < 0.30) {
                self.doComplete();
            } else if (r2 < 0.50) {
                if (!self.fetch_subscribed) self.doFetch() else self.doEnqueue();
            } else {
                self.doEnqueue();
            }
        }
    }

    // ====================================================================
    // Phase 2: processResponse — read response, update state
    // ====================================================================

    pub fn processResponse(self: *SimClient) void {
        const resp_data = self.backend.readResponse(self.conn_id) orelse {
            // No response. If we sent a fetch, we're now subscribed (pipeline holds it).
            if (self.pending_msg_type == rpc.MSG_FETCH_BATCH) {
                self.fetch_subscribed = true;
            }
            self.pending_msg_type = 0;
            return;
        };

        // Parse ALL frames in the response. There may be multiple:
        // - The direct response to pending_msg_type
        // - A pushed MSG_FETCH_BATCH_RESP from a fulfilled subscription
        var pos: usize = 0;
        while (pos + rpc.FRAME_HEADER_SIZE <= resp_data.len) {
            const hdr = rpc.readFrameHeader(resp_data[pos..]) orelse break;
            const frame_end = pos + rpc.FRAME_HEADER_SIZE + hdr.payload_len;
            if (frame_end > resp_data.len) break;

            const payload = resp_data[pos + rpc.FRAME_HEADER_SIZE .. frame_end];

            switch (hdr.msg_type) {
                rpc.MSG_ENQUEUE_BATCH_RESP => self.parseEnqueuePayload(payload),
                rpc.MSG_FETCH_BATCH_RESP => {
                    self.parseFetchPayload(payload);
                    self.fetch_subscribed = false;
                },
                else => {},
            }

            pos = frame_end;
        }

        self.pending_msg_type = 0;
    }

    // ====================================================================
    // Enqueue — MSG_ENQUEUE_BATCH
    // ====================================================================

    fn doEnqueue(self: *SimClient) void {
        const queue_idx = self.rng.intRangeAtMost(usize, 0, self.queues.len - 1);
        const q = self.queues[queue_idx];

        self.job_seq += 1;
        var id_buf: [32]u8 = undefined;
        const job_id = std.fmt.bufPrint(&id_buf, "c{d}-{d}", .{ self.id, self.job_seq }) catch unreachable;

        var w = self.payloadWriter();
        w.writeU16(1); // count
        w.writePrefixed(q);
        w.writePrefixed(job_id);

        // Priority
        const priority: u8 = if (self.chance(self.config.priority_rate))
            self.rng.intRangeAtMost(u8, 1, 255)
        else
            128;
        w.writeU8(priority);
        w.writeU16(3); // max_retries
        w.writeU8(0); // backoff = none
        w.writeU32(0); // base_delay_ms
        w.writeU32(0); // max_delay_ms

        // Unique key
        var flags: u16 = rpc.FLAG_PAYLOAD;
        var unique_period_s: u32 = 0;
        var unique_key_buf: [32]u8 = undefined;
        var unique_key_len: usize = 0;

        if (self.chance(self.config.unique_rate)) {
            const uk_idx = self.rng.intRangeAtMost(u32, 0, 9);
            const uk = std.fmt.bufPrint(&unique_key_buf, "ukey_{d}_{d}", .{ queue_idx, uk_idx }) catch unreachable;
            unique_key_len = uk.len;
            unique_period_s = 3600;
            flags |= rpc.FLAG_UNIQUE_KEY;
        }

        w.writeU32(unique_period_s);

        // Scheduled job
        const scheduled_at_ns: u64 = if (self.chance(self.config.scheduled_job_rate))
            4070908800000000000 // ~2099-01-01
        else
            0;
        w.writeU64(scheduled_at_ns);

        w.writeU32(0); // expire_after_ms
        w.writeU16(0); // chain_step
        w.writeU16(flags);

        // Optional fields in flag order
        w.writeU16Prefixed("{\"sim\":true}"); // payload
        if (flags & rpc.FLAG_UNIQUE_KEY != 0) {
            w.writePrefixed(unique_key_buf[0..unique_key_len]);
        }

        self.sendFrame(rpc.MSG_ENQUEUE_BATCH, w.pos);
    }

    fn parseEnqueuePayload(self: *SimClient, payload: []const u8) void {
        if (payload.len == 0) return;
        var r = BufReader{ .data = payload };
        _ = r.readU16() catch return; // count
        const err_byte = r.readU8() catch return;

        if (err_byte == 0) {
            self.enqueued += 1;
        }
    }

    // ====================================================================
    // Fetch — MSG_FETCH_BATCH
    // ====================================================================

    fn doFetch(self: *SimClient) void {
        if (self.active_count >= max_active_jobs) return;

        const queue_idx = self.rng.intRangeAtMost(usize, 0, self.queues.len - 1);
        const q = self.queues[queue_idx];

        var w = self.payloadWriter();
        w.writeU16(1); // credits
        w.writeU32(30000); // lease_ms
        w.writePrefixed(self.workerID());
        w.writeU8(1); // queue_count
        w.writePrefixed(q);

        self.sendFrame(rpc.MSG_FETCH_BATCH, w.pos);
    }

    fn parseFetchPayload(self: *SimClient, payload: []const u8) void {
        if (payload.len == 0) return;
        var r = BufReader{ .data = payload };
        const count = r.readU16() catch return;
        if (count == 0) return;

        // Parse first fetched job
        const job_id = r.readPrefixed() catch return;
        const job_queue = r.readPrefixed() catch return;
        _ = r.readU16() catch return; // attempt
        _ = r.readU16() catch return; // max_retries
        _ = r.readPrefixed() catch return; // checkpoint (empty)
        _ = r.readPrefixed() catch return; // tags (empty)
        const plen = r.readU16() catch return;
        r.skip(plen) catch return; // payload bytes

        if (job_id.len == 0) return;
        if (self.active_count >= max_active_jobs) return;

        var entry = &self.active_jobs[self.active_count];
        const id_len = @min(job_id.len, entry.id_buf.len);
        @memcpy(entry.id_buf[0..id_len], job_id[0..id_len]);
        entry.id_len = id_len;
        const ql = @min(job_queue.len, entry.queue_buf.len);
        @memcpy(entry.queue_buf[0..ql], job_queue[0..ql]);
        entry.queue_len = ql;
        entry.will_fail = self.chance(self.config.fail_rate);
        self.active_count += 1;
        self.fetched += 1;
    }

    // ====================================================================
    // Complete (ack or fail) — MSG_ACK_BATCH or MSG_FAIL_BATCH
    // ====================================================================

    fn doComplete(self: *SimClient) void {
        if (self.active_count == 0) return;

        const idx = self.rng.intRangeAtMost(usize, 0, self.active_count - 1);
        const entry = self.active_jobs[idx];
        const job_id = entry.jobID();
        const job_queue = entry.queue();

        // Small chance: "forget" this job instead of acking it.
        // The lease will expire, maintenance will reclaim it, another client
        // may re-fetch it, and our later stale ack will be rejected.
        if (self.stale_count < max_stale_jobs and self.chance(self.config.stale_rate)) {
            self.stale_jobs[self.stale_count] = self.active_jobs[idx];
            self.stale_count += 1;
            // Swap-remove from active (without sending any RPC)
            self.active_jobs[idx] = self.active_jobs[self.active_count - 1];
            self.active_count -= 1;
            return;
        }

        if (entry.will_fail) {
            var w = self.payloadWriter();
            w.writeU16(1);
            w.writePrefixed(job_id);
            w.writePrefixed(job_queue);
            w.writePrefixed("sim-failure");
            w.writePrefixed(""); // backtrace
            self.sendFrame(rpc.MSG_FAIL_BATCH, w.pos);
            self.failed += 1;
        } else {
            var w = self.payloadWriter();
            w.writeU16(1);
            w.writePrefixed(job_id);
            w.writePrefixed(job_queue);
            w.writeU8(0); // ack_status = done
            w.writeU8(0); // flags (no optional fields)
            self.sendFrame(rpc.MSG_ACK_BATCH, w.pos);
            self.acked += 1;
        }

        self.trackCompleted(job_id);
        // Swap-remove from active
        self.active_jobs[idx] = self.active_jobs[self.active_count - 1];
        self.active_count -= 1;
    }

    // ====================================================================
    // Adversarial ack — double-ack, ack non-existent
    // ====================================================================

    fn doAdversarialAck(self: *SimClient) void {
        const q = self.queues[self.rng.intRangeAtMost(usize, 0, self.queues.len - 1)];

        var w = self.payloadWriter();
        w.writeU16(1);

        if (self.completed_count > 0 and self.chance(0.5)) {
            const ci = self.rng.intRangeAtMost(usize, 0, self.completed_count - 1);
            w.writePrefixed(self.completed_ids[ci].slice());
        } else {
            w.writePrefixed("nonexistent_job_xyz");
        }
        w.writePrefixed(q);
        w.writeU8(0); // ack_status = done
        w.writeU8(0); // flags

        self.sendFrame(rpc.MSG_ACK_BATCH, w.pos);
        self.double_acks += 1;
    }

    // ====================================================================
    // Stale ack — ack a job whose lease has (likely) expired
    // ====================================================================

    fn doStaleAck(self: *SimClient) void {
        if (self.stale_count == 0) return;

        const idx = self.rng.intRangeAtMost(usize, 0, self.stale_count - 1);
        const entry = self.stale_jobs[idx];

        var w = self.payloadWriter();
        w.writeU16(1);
        w.writePrefixed(entry.jobID());
        w.writePrefixed(entry.queue());
        w.writeU8(0); // ack_status = done
        w.writeU8(0); // flags

        self.sendFrame(rpc.MSG_ACK_BATCH, w.pos);
        self.stale_acks += 1;

        // Swap-remove from stale_jobs
        self.stale_jobs[idx] = self.stale_jobs[self.stale_count - 1];
        self.stale_count -= 1;
    }

    // ====================================================================
    // Heartbeat — MSG_HEARTBEAT
    // ====================================================================

    fn doHeartbeat(self: *SimClient) void {
        if (self.active_count == 0) return;

        const idx = self.rng.intRangeAtMost(usize, 0, self.active_count - 1);
        const entry = &self.active_jobs[idx];

        var w = self.payloadWriter();
        w.writePrefixed(self.workerID());
        w.writeU16(1); // count
        w.writePrefixed(entry.jobID());
        w.writePrefixed(entry.queue());
        w.writeU8(0); // flags (no progress/checkpoint)

        self.sendFrame(rpc.MSG_HEARTBEAT, w.pos);
        self.heartbeats += 1;
    }

    // ====================================================================
    // Bulk actions — MSG_BULK_ACTION
    // ====================================================================

    fn doBulkAction(self: *SimClient) void {
        if (self.completed_count == 0) return;

        const count = @min(
            self.rng.intRangeAtMost(usize, 1, 5),
            self.completed_count,
        );

        const actions = [_]ops.BulkAction{ .requeue, .delete, .cancel };
        const action = actions[self.rng.intRangeAtMost(usize, 0, actions.len - 1)];

        const now_ns: u64 = @intCast(clock_mod.globalClockNow());

        var w = self.payloadWriter();
        w.writeU8(@intFromEnum(action));
        w.writePrefixed(""); // queue (handler looks up per job)
        w.writeU16(@intCast(count));

        for (0..count) |_| {
            const ci = self.rng.intRangeAtMost(usize, 0, self.completed_count - 1);
            w.writePrefixed(self.completed_ids[ci].slice());
        }

        w.writeU8(0); // flags (no move_to, no priority)
        w.writeU64(now_ns);

        self.sendFrame(rpc.MSG_BULK_ACTION, w.pos);
        self.bulk_ops += 1;
    }

    // ====================================================================
    // Maintenance — MSG_MAINTENANCE
    // ====================================================================

    fn doMaintenance(self: *SimClient) void {
        const now_ns: u64 = @intCast(clock_mod.globalClockNow());

        const actions = [_]ops.MaintenanceAction{
            .promote, .reclaim, .expire, .purge, .unique, .batches,
        };
        const action = actions[self.rng.intRangeAtMost(usize, 0, actions.len - 1)];

        var w = self.payloadWriter();
        w.writeU8(@intFromEnum(action));
        w.writeU64(now_ns);
        w.writeU64(0); // cutoff_ns

        self.sendFrame(rpc.MSG_MAINTENANCE, w.pos);
        self.maintenance_ops += 1;
    }

    // ====================================================================
    // Queue operations — MSG_QUEUE_CONFIG / MSG_CLEAR_QUEUE
    // ====================================================================

    fn doQueueOp(self: *SimClient) void {
        const queue_idx = self.rng.intRangeAtMost(usize, 0, self.queues.len - 1);
        const q = self.queues[queue_idx];

        // 10% chance of clear
        if (self.chance(0.1)) {
            var w = self.payloadWriter();
            w.writePrefixed(q);
            self.sendFrame(rpc.MSG_CLEAR_QUEUE, w.pos);
            self.clear_queues += 1;
            self.queue_ops += 1;
            return;
        }

        // Toggle pause state
        const action: ops.QueueAction = if (self.paused_queues[queue_idx]) .@"resume" else .pause;
        self.paused_queues[queue_idx] = !self.paused_queues[queue_idx];

        var w = self.payloadWriter();
        w.writePrefixed(q);
        w.writeU8(@intFromEnum(action));
        w.writeU32(0); // max_concurrency
        w.writeU32(0); // rate_limit
        w.writeU32(0); // rate_window_ms
        w.writeU8(0); // fairness

        self.sendFrame(rpc.MSG_QUEUE_CONFIG, w.pos);
        self.queue_ops += 1;
    }

    // ====================================================================
    // Frame helpers
    // ====================================================================

    fn payloadWriter(self: *SimClient) BufWriter {
        return BufWriter{ .buf = self.frame_buf[rpc.FRAME_HEADER_SIZE..] };
    }

    fn sendFrame(self: *SimClient, msg_type: u8, payload_len: usize) void {
        self.req_counter += 1;
        rpc.writeFrameHeader(
            self.frame_buf[0..rpc.FRAME_HEADER_SIZE],
            msg_type,
            self.req_counter,
            @intCast(payload_len),
        );
        const total = rpc.FRAME_HEADER_SIZE + payload_len;
        self.backend.injectRecv(self.conn_id, self.frame_buf[0..total]);
        self.pending_msg_type = msg_type;
    }

    // ====================================================================
    // Helpers
    // ====================================================================

    fn trackCompleted(self: *SimClient, job_id: []const u8) void {
        if (self.completed_count >= max_completed_ids) {
            self.completed_count = max_completed_ids / 2;
        }
        const len = @min(job_id.len, self.completed_ids[self.completed_count].buf.len);
        @memcpy(self.completed_ids[self.completed_count].buf[0..len], job_id[0..len]);
        self.completed_ids[self.completed_count].len = len;
        self.completed_count += 1;
    }

    fn chance(self: *SimClient, prob: f64) bool {
        return self.rng.float(f64) < prob;
    }
};
