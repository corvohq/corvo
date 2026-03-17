//! SimClient — adversarial simulated worker for the VOPR simulator.
//!
//! Exercises the full operation space including edge cases:
//! - Unique job lifecycle (enqueue → ack → re-enqueue same key)
//! - Bulk retry/requeue of dead jobs (d| cleanup, unique lock re-acquire)
//! - Batch create → enqueue into batch → ack/fail → seal (counter tracking)
//! - Fetch from paused queues (should get nothing)
//! - Double-ack, ack of non-existent jobs
//! - Clear queue with active jobs
//! - Maintenance interleaved with everything

const std = @import("std");
const corvo = @import("corvo");
const assert = corvo.assert;
const types = corvo.types;
const ops = corvo.ops;
const keys = corvo.keys;
const codec = corvo.codec;
const engine_mod = corvo.engine;
const kv = corvo.kv;
const clock_mod = @import("clock.zig");
const Config = @import("config.zig").Config;

const max_active_jobs = 64;
const max_completed_ids = 128;
const max_batches = 16;
const max_unique_keys = 20;

pub const SimClient = struct {
    id: u32,
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    engine: *engine_mod.Engine,
    config: Config,
    queues: []const []const u8,
    worker_id_buf: [32]u8 = undefined,
    worker_id_len: usize = 0,

    // Active jobs (fetched, not yet acked/failed).
    active_jobs: [max_active_jobs]JobEntry = undefined,
    active_count: usize = 0,

    // Recently completed/dead job IDs (for bulk retry/cancel/delete).
    completed_ids: [max_completed_ids]IdBuf = undefined,
    completed_count: usize = 0,

    // Open batches.
    batches: [max_batches]IdBuf = undefined,
    batch_job_counts: [max_batches]u32 = [_]u32{0} ** max_batches,
    batch_count: usize = 0,

    // Unique key pool — small pool so conflicts are frequent.
    unique_keys_used: u32 = 0,

    // Queue pause state tracking.
    paused_queues: [8]bool = [_]bool{false} ** 8,

    // Stats
    enqueued: u32 = 0,
    fetched: u32 = 0,
    acked: u32 = 0,
    failed: u32 = 0,
    bulk_ops: u32 = 0,
    batch_creates: u32 = 0,
    batch_seals: u32 = 0,
    maintenance_ops: u32 = 0,
    heartbeats: u32 = 0,
    queue_ops: u32 = 0,
    unique_conflicts: u32 = 0,
    double_acks: u32 = 0,
    clear_queues: u32 = 0,

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
        engine: *engine_mod.Engine,
        config: Config,
        queues: []const []const u8,
    ) SimClient {
        var c = SimClient{
            .id = id,
            .prng = std.Random.DefaultPrng.init(seed),
            .rng = undefined,
            .engine = engine,
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

    pub fn act(self: *SimClient) void {
        assert.check(self.active_count <= max_active_jobs,
            "SimClient.act: active_count overflow", .{});

        if (self.active_count >= max_active_jobs / 2) {
            self.doComplete();
            return;
        }

        const r = self.rng.float(f64);
        var threshold: f64 = 0;

        // Maintenance — always interleaved, not just at end.
        threshold += self.config.maintenance_rate;
        if (r < threshold) { self.doMaintenance(); return; }

        // Batch create/seal.
        threshold += self.config.batch_rate;
        if (r < threshold) { self.doBatchOp(); return; }

        // Bulk action (retry/requeue/cancel/delete on completed/dead jobs).
        threshold += self.config.bulk_rate;
        if (r < threshold and self.completed_count > 0) { self.doBulkAction(); return; }

        // Queue ops (pause/resume/clear).
        threshold += self.config.queue_op_rate;
        if (r < threshold) { self.doQueueOp(); return; }

        // Heartbeat.
        if (self.active_count > 0 and self.chance(self.config.heartbeat_rate)) {
            self.doHeartbeat();
            return;
        }

        // Adversarial: double-ack or ack non-existent.
        if (self.chance(0.02)) {
            self.doAdversarialAck();
            return;
        }

        // Core: complete, fetch, or enqueue.
        if (self.active_count == 0) {
            if (self.chance(0.6)) self.doEnqueue() else self.doFetch();
        } else {
            const r2 = self.rng.float(f64);
            if (r2 < 0.30) {
                self.doComplete();
            } else if (r2 < 0.50) {
                self.doFetch();
            } else {
                self.doEnqueue();
            }
        }
    }

    // ====================================================================
    // Enqueue — with unique keys, batch assignment, scheduling
    // ====================================================================

    fn doEnqueue(self: *SimClient) void {
        const queue_idx = self.rng.intRangeAtMost(usize, 0, self.queues.len - 1);
        const q = self.queues[queue_idx];
        const now_ns: u64 = @intCast(clock_mod.globalClockNow());

        var id_buf: [64]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "job_{d}_{d}_{d}", .{
            self.id, self.enqueued, self.rng.int(u32),
        }) catch unreachable;

        var enqueue_job = ops.EnqueueJob{
            .job_id = id,
            .queue = q,
            .priority = types.priority_default,
            .max_retries = 3,
            .created_at_ns = now_ns,
        };

        // Scheduled job.
        if (self.chance(self.config.scheduled_job_rate)) {
            enqueue_job.scheduled_at_ns = now_ns + 5_000_000_000;
            enqueue_job.state = .scheduled;
        }

        // Priority.
        if (self.chance(self.config.priority_rate)) {
            enqueue_job.priority = @intCast(self.rng.intRangeAtMost(u8, 1, 255));
        }

        // Unique key — small pool (10 keys per queue) so conflicts are frequent.
        var uk_buf: [32]u8 = undefined;
        if (self.chance(self.config.unique_rate)) {
            const uk_idx = self.rng.intRangeAtMost(u32, 0, 9);
            const uk = std.fmt.bufPrint(&uk_buf, "ukey_{d}_{d}", .{ queue_idx, uk_idx }) catch unreachable;
            enqueue_job.unique_key = uk;
            enqueue_job.unique_period_s = 3600;
        }

        // Batch assignment.
        if (self.batch_count > 0 and self.chance(self.config.batch_enqueue_rate)) {
            const bi = self.rng.intRangeAtMost(usize, 0, self.batch_count - 1);
            enqueue_job.batch_id = self.batches[bi].slice();
            self.batch_job_counts[bi] += 1;
        }

        const jobs_arr = [1]ops.EnqueueJob{enqueue_job};
        const data = ops.OpData{
            .enqueue = .{ .jobs = &jobs_arr, .now_ns = now_ns },
        };

        const result = self.engine.apply(.enqueue, &data);
        if (result.err == null) {
            self.enqueued += 1;
            if (result.unique_job_id_len > 0) {
                self.unique_conflicts += 1;
            }
        } else {
            // Unique conflict returns an error but it's expected.
            self.enqueued += 1;
            self.unique_conflicts += 1;
        }
    }

    // ====================================================================
    // Fetch
    // ====================================================================

    fn doFetch(self: *SimClient) void {
        if (self.active_count >= max_active_jobs) return;

        const queue_idx = self.rng.intRangeAtMost(usize, 0, self.queues.len - 1);
        const q = self.queues[queue_idx];
        const now_ns: u64 = @intCast(clock_mod.globalClockNow());

        const queues_slice = [1][]const u8{q};
        const data = ops.OpData{
            .fetch = .{
                .queues = &queues_slice,
                .worker_id = self.workerID(),
                .count = 1,
                .now_ns = now_ns,
                .lease_duration_ms = 30000,
            },
        };

        const result = self.engine.apply(.fetch, &data);

        for (0..result.affected) |i| {
            if (self.active_count >= max_active_jobs) break;
            if (i >= ops.OpResult.max_inline_fetch) break;

            const f = &result.fetched[i];
            var entry = &self.active_jobs[self.active_count];
            @memcpy(entry.id_buf[0..f.id_len], f.id_buf[0..f.id_len]);
            entry.id_len = f.id_len;
            @memcpy(entry.queue_buf[0..f.queue_len], f.queue_buf[0..f.queue_len]);
            entry.queue_len = f.queue_len;
            entry.will_fail = self.chance(self.config.fail_rate);
            self.active_count += 1;
            self.fetched += 1;
        }
    }

    // ====================================================================
    // Complete (ack or fail) — also track for bulk ops
    // ====================================================================

    fn doComplete(self: *SimClient) void {
        if (self.active_count == 0) return;

        const idx = self.rng.intRangeAtMost(usize, 0, self.active_count - 1);
        const entry = self.active_jobs[idx];
        const job_id = entry.jobID();
        const q = entry.queue();
        const now_ns: u64 = @intCast(clock_mod.globalClockNow());

        if (entry.will_fail) {
            const fail_jobs = [1]ops.FailJob{.{
                .job_id = job_id,
                .queue = q,
                .error_msg = "sim-failure",
            }};
            const data = ops.OpData{
                .fail = .{ .jobs = &fail_jobs, .now_ns = now_ns },
            };
            _ = self.engine.apply(.fail, &data);
            self.failed += 1;
        } else {
            const acks = [1]ops.AckJob{.{
                .job_id = job_id,
                .queue = q,
            }};
            const data = ops.OpData{
                .ack = .{ .acks = &acks, .now_ns = now_ns },
            };
            _ = self.engine.apply(.ack, &data);
            self.acked += 1;
        }

        self.trackCompleted(job_id);
        // Swap-remove from active.
        self.active_jobs[idx] = self.active_jobs[self.active_count - 1];
        self.active_count -= 1;
    }

    // ====================================================================
    // Adversarial ack — double-ack, ack non-existent, ack already-completed
    // ====================================================================

    fn doAdversarialAck(self: *SimClient) void {
        const now_ns: u64 = @intCast(clock_mod.globalClockNow());

        if (self.completed_count > 0 and self.chance(0.5)) {
            // Double-ack: ack an already-completed job (should be no-op or error).
            const ci = self.rng.intRangeAtMost(usize, 0, self.completed_count - 1);
            const job_id = self.completed_ids[ci].slice();
            const acks = [1]ops.AckJob{.{ .job_id = job_id, .queue = "any" }};
            const data = ops.OpData{
                .ack = .{ .acks = &acks, .now_ns = now_ns },
            };
            _ = self.engine.apply(.ack, &data);
            self.double_acks += 1;
        } else {
            // Ack non-existent job.
            const acks = [1]ops.AckJob{.{ .job_id = "nonexistent_job_xyz", .queue = "any" }};
            const data = ops.OpData{
                .ack = .{ .acks = &acks, .now_ns = now_ns },
            };
            _ = self.engine.apply(.ack, &data);
            self.double_acks += 1;
        }
    }

    // ====================================================================
    // Heartbeat
    // ====================================================================

    fn doHeartbeat(self: *SimClient) void {
        if (self.active_count == 0) return;

        const idx = self.rng.intRangeAtMost(usize, 0, self.active_count - 1);
        const entry = &self.active_jobs[idx];
        const now_ns: u64 = @intCast(clock_mod.globalClockNow());

        const job_ids = [1][]const u8{entry.jobID()};
        const job_ops = [1]ops.HeartbeatJobOp{.{}};
        const data = ops.OpData{
            .heartbeat = .{
                .job_ids = &job_ids,
                .job_ops = &job_ops,
                .worker_id = self.workerID(),
                .now_ns = now_ns,
            },
        };
        _ = self.engine.apply(.heartbeat, &data);
        self.heartbeats += 1;
    }

    // ====================================================================
    // Bulk actions — retry, requeue, cancel, delete
    // (These are where the Go refactor found most bugs)
    // ====================================================================

    fn doBulkAction(self: *SimClient) void {
        if (self.completed_count == 0) return;

        const count = @min(
            self.rng.intRangeAtMost(usize, 1, 5),
            self.completed_count,
        );

        var id_ptrs: [5][]const u8 = undefined;
        for (0..count) |i| {
            const ci = self.rng.intRangeAtMost(usize, 0, self.completed_count - 1);
            id_ptrs[i] = self.completed_ids[ci].slice();
        }

        const now_ns: u64 = @intCast(clock_mod.globalClockNow());

        // Include requeue — this is the action that exposed d| cleanup bugs.
        const actions = [_]ops.BulkAction{ .retry, .delete, .cancel, .requeue };
        const action = actions[self.rng.intRangeAtMost(usize, 0, actions.len - 1)];

        const data = ops.OpData{
            .bulk_action = .{
                .job_ids = id_ptrs[0..count],
                .action = action,
                .now_ns = now_ns,
            },
        };
        _ = self.engine.apply(.bulk_action, &data);
        self.bulk_ops += 1;

        if (action == .delete) {
            for (0..count) |i| {
                self.removeCompleted(id_ptrs[i]);
            }
        }
    }

    // ====================================================================
    // Batch operations — create, enqueue into, seal
    // ====================================================================

    fn doBatchOp(self: *SimClient) void {
        if (self.batch_count > 0 and self.chance(0.4)) {
            // Seal a random open batch.
            const bi = self.rng.intRangeAtMost(usize, 0, self.batch_count - 1);
            self.doBatchSeal(bi);
        } else {
            self.doBatchCreate();
        }
    }

    fn doBatchCreate(self: *SimClient) void {
        if (self.batch_count >= max_batches) {
            self.doBatchSeal(0);
            return;
        }

        const now_ns: u64 = @intCast(clock_mod.globalClockNow());
        var id_buf: [64]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "batch_{d}_{d}_{d}", .{
            self.id, self.batch_creates, self.rng.int(u16),
        }) catch unreachable;

        const data = ops.OpData{
            .batch_create = .{
                .batch_id = id,
                .created_at_ns = now_ns,
            },
        };
        const result = self.engine.apply(.batch_create, &data);
        if (result.err == null) {
            const len = @min(id.len, self.batches[self.batch_count].buf.len);
            @memcpy(self.batches[self.batch_count].buf[0..len], id[0..len]);
            self.batches[self.batch_count].len = len;
            self.batch_job_counts[self.batch_count] = 0;
            self.batch_count += 1;
            self.batch_creates += 1;
        }
    }

    fn doBatchSeal(self: *SimClient, idx: usize) void {
        if (self.batch_count == 0) return;
        const bi = @min(idx, self.batch_count - 1);

        const now_ns: u64 = @intCast(clock_mod.globalClockNow());
        const data = ops.OpData{
            .batch_seal = .{
                .batch_id = self.batches[bi].slice(),
                .now_ns = now_ns,
            },
        };
        _ = self.engine.apply(.batch_seal, &data);
        self.batch_seals += 1;

        self.batches[bi] = self.batches[self.batch_count - 1];
        self.batch_job_counts[bi] = self.batch_job_counts[self.batch_count - 1];
        self.batch_count -= 1;
    }

    // ====================================================================
    // Maintenance — all types, interleaved with operations
    // ====================================================================

    fn doMaintenance(self: *SimClient) void {
        const now_ns: u64 = @intCast(clock_mod.globalClockNow());

        const actions = [_]ops.MaintenanceAction{
            .promote, .reclaim, .expire, .purge, .unique, .batches,
        };
        const action = actions[self.rng.intRangeAtMost(usize, 0, actions.len - 1)];

        const data = ops.OpData{
            .maintenance = .{ .action = action, .now_ns = now_ns },
        };
        _ = self.engine.apply(.maintenance, &data);
        self.maintenance_ops += 1;
    }

    // ====================================================================
    // Queue operations — pause, resume, AND clear (adversarial)
    // ====================================================================

    fn doQueueOp(self: *SimClient) void {
        const queue_idx = self.rng.intRangeAtMost(usize, 0, self.queues.len - 1);
        const q = self.queues[queue_idx];

        // 10% chance of clear instead of pause/resume — this is adversarial.
        if (self.chance(0.1)) {
            const data = ops.OpData{
                .clear_queue = .{ .queue = q },
            };
            _ = self.engine.apply(.clear_queue, &data);
            self.clear_queues += 1;
            self.queue_ops += 1;

            // Remove active jobs from this queue (they were cleared).
            var i: usize = 0;
            while (i < self.active_count) {
                if (std.mem.eql(u8, self.active_jobs[i].queue(), q)) {
                    self.active_jobs[i] = self.active_jobs[self.active_count - 1];
                    self.active_count -= 1;
                } else {
                    i += 1;
                }
            }
            return;
        }

        // Toggle pause state.
        const action: ops.QueueAction = if (self.paused_queues[queue_idx]) .@"resume" else .pause;
        self.paused_queues[queue_idx] = !self.paused_queues[queue_idx];

        const data = ops.OpData{
            .queue_config = .{ .queue = q, .action = action },
        };
        _ = self.engine.apply(.queue_config, &data);
        self.queue_ops += 1;
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

    fn removeCompleted(self: *SimClient, job_id: []const u8) void {
        var i: usize = 0;
        while (i < self.completed_count) {
            if (std.mem.eql(u8, self.completed_ids[i].slice(), job_id)) {
                self.completed_ids[i] = self.completed_ids[self.completed_count - 1];
                self.completed_count -= 1;
            } else {
                i += 1;
            }
        }
    }

    fn chance(self: *SimClient, prob: f64) bool {
        return self.rng.float(f64) < prob;
    }
};
