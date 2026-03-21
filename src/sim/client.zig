//! SimClient — adversarial simulated worker for the VOPR simulator.
//!
//! Routes all operations through Server.route() (HTTP JSON path) to exercise
//! the full request lifecycle: JSON parsing, handler logic, KV ops, mirror
//! sync, chain progression, and response serialization.
//!
//! Maintenance is the only operation that bypasses HTTP (no public endpoint).

const std = @import("std");
const corvo = @import("corvo");
const assert = corvo.assert;
const types = corvo.types;
const ops = corvo.ops;
const keys = corvo.keys;
const codec = corvo.codec;
const engine_mod = corvo.engine;
const server_mod = corvo.server;
const kv = corvo.kv;
const clock_mod = @import("clock.zig");
const Config = @import("config.zig").Config;

const max_active_jobs = 64;
const max_completed_ids = 128;
const max_batches = 16;

pub const SimClient = struct {
    id: u32,
    prng: std.Random.DefaultPrng,
    rng: std.Random,
    engine: *engine_mod.Engine, // for maintenance only (no HTTP path)
    server: *server_mod.Server,
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
    chain_enqueued: u32 = 0,

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
        lease_token: u64 = 0,

        fn jobID(self: *const JobEntry) []const u8 {
            return self.id_buf[0..self.id_len];
        }
        fn queue(self: *const JobEntry) []const u8 {
            return self.queue_buf[0..self.queue_len];
        }
    };

    // Response buffer for server.route() calls.
    const resp_buf_size = 65536;

    pub fn init(
        id: u32,
        seed: u64,
        engine: *engine_mod.Engine,
        server: *server_mod.Server,
        config: Config,
        queues: []const []const u8,
    ) SimClient {
        var c = SimClient{
            .id = id,
            .prng = std.Random.DefaultPrng.init(seed),
            .rng = undefined,
            .engine = engine,
            .server = server,
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

    fn route(self: *SimClient, method: []const u8, path: []const u8, body: ?[]const u8, buf: []u8) server_mod.Server.Response {
        const req = server_mod.Request{ .method = method, .path = path, .body = body };
        return self.server.route(req, buf);
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

        // Maintenance — still via engine (no HTTP endpoint).
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
    // Enqueue — via POST /api/v1/enqueue
    // ====================================================================

    fn doEnqueue(self: *SimClient) void {
        const queue_idx = self.rng.intRangeAtMost(usize, 0, self.queues.len - 1);
        const q = self.queues[queue_idx];

        var body_buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&body_buf);
        const w = stream.writer();

        w.print("{{\"queue\":\"{s}\",\"payload\":{{\"sim\":true}}", .{q}) catch return;

        // Priority.
        if (self.chance(self.config.priority_rate)) {
            const p = self.rng.intRangeAtMost(u8, 1, 255);
            w.print(",\"priority\":{d}", .{p}) catch return;
        }

        // Unique key.
        if (self.chance(self.config.unique_rate)) {
            const uk_idx = self.rng.intRangeAtMost(u32, 0, 9);
            w.print(",\"unique_key\":\"ukey_{d}_{d}\",\"unique_period\":3600", .{ queue_idx, uk_idx }) catch return;
        }

        // Batch assignment.
        if (self.batch_count > 0 and self.chance(self.config.batch_enqueue_rate)) {
            const bi = self.rng.intRangeAtMost(usize, 0, self.batch_count - 1);
            w.print(",\"batch_id\":\"{s}\"", .{self.batches[bi].slice()}) catch return;
            self.batch_job_counts[bi] += 1;
        }

        // Chain config — 5% of enqueues.
        if (self.chance(0.05)) {
            // Simple 2-step chain with on_exit.
            const other_q = self.queues[self.rng.intRangeAtMost(usize, 0, self.queues.len - 1)];
            w.print(",\"chain\":{{\"steps\":[{{\"queue\":\"{s}\"}},{{\"queue\":\"{s}\"}}],\"on_exit\":{{\"queue\":\"{s}\"}}}}", .{ q, other_q, q }) catch return;
            self.chain_enqueued += 1;
        }

        // Scheduled job.
        if (self.chance(self.config.scheduled_job_rate)) {
            w.writeAll(",\"scheduled_at\":\"2099-01-01T00:00:00Z\"") catch return;
        }

        w.writeByte('}') catch return;
        const body = stream.getWritten();

        var resp_buf: [resp_buf_size]u8 = undefined;
        const resp = self.route("POST", "/api/v1/enqueue", body, &resp_buf);

        if (resp.status == 201) {
            self.enqueued += 1;
        } else if (resp.status == 409) {
            // unique_existing
            self.unique_conflicts += 1;
        }
    }

    // ====================================================================
    // Fetch — via POST /api/v1/fetch
    // ====================================================================

    fn doFetch(self: *SimClient) void {
        if (self.active_count >= max_active_jobs) return;

        const queue_idx = self.rng.intRangeAtMost(usize, 0, self.queues.len - 1);
        const q = self.queues[queue_idx];

        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            "{{\"queues\":[\"{s}\"],\"worker_id\":\"{s}\",\"count\":1}}",
            .{ q, self.workerID() },
        ) catch return;

        var resp_buf: [resp_buf_size]u8 = undefined;
        const resp = self.route("POST", "/api/v1/fetch", body, &resp_buf);

        if (resp.status != 200) return;

        // Parse job_id from response: {"job_id":"...","queue":"..."}
        const job_id = extractJsonString(resp.body, "job_id") orelse return;
        if (job_id.len == 0) return; // empty = no job available

        const resp_queue = extractJsonString(resp.body, "queue") orelse q;

        var entry = &self.active_jobs[self.active_count];
        const id_len = @min(job_id.len, entry.id_buf.len);
        @memcpy(entry.id_buf[0..id_len], job_id[0..id_len]);
        entry.id_len = id_len;
        const ql = @min(resp_queue.len, entry.queue_buf.len);
        @memcpy(entry.queue_buf[0..ql], resp_queue[0..ql]);
        entry.queue_len = ql;
        entry.will_fail = self.chance(self.config.fail_rate);
        entry.lease_token = extractJsonU64(resp.body, "lease_token");
        self.active_count += 1;
        self.fetched += 1;
    }

    // ====================================================================
    // Complete (ack or fail) — via POST /api/v1/ack/{id} or /fail/{id}
    // ====================================================================

    fn doComplete(self: *SimClient) void {
        if (self.active_count == 0) return;

        const idx = self.rng.intRangeAtMost(usize, 0, self.active_count - 1);
        const entry = self.active_jobs[idx];
        const job_id = entry.jobID();

        if (entry.will_fail) {
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/api/v1/fail/{s}", .{job_id}) catch return;
            var body_buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf,
                "{{\"error\":\"sim-failure\",\"lease_token\":{d}}}",
                .{entry.lease_token},
            ) catch return;
            var resp_buf: [resp_buf_size]u8 = undefined;
            _ = self.route("POST", path, body, &resp_buf);
            self.failed += 1;
        } else {
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/api/v1/ack/{s}", .{job_id}) catch return;
            var body_buf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&body_buf,
                "{{\"lease_token\":{d}}}",
                .{entry.lease_token},
            ) catch return;
            var resp_buf: [resp_buf_size]u8 = undefined;
            _ = self.route("POST", path, body, &resp_buf);
            self.acked += 1;
        }

        self.trackCompleted(job_id);
        // Swap-remove from active.
        self.active_jobs[idx] = self.active_jobs[self.active_count - 1];
        self.active_count -= 1;
    }

    // ====================================================================
    // Adversarial ack — double-ack, ack non-existent
    // ====================================================================

    fn doAdversarialAck(self: *SimClient) void {
        if (self.completed_count > 0 and self.chance(0.5)) {
            const ci = self.rng.intRangeAtMost(usize, 0, self.completed_count - 1);
            const job_id = self.completed_ids[ci].slice();
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/api/v1/ack/{s}", .{job_id}) catch return;
            var resp_buf: [resp_buf_size]u8 = undefined;
            _ = self.route("POST", path, "{}", &resp_buf);
            self.double_acks += 1;
        } else {
            var resp_buf: [resp_buf_size]u8 = undefined;
            _ = self.route("POST", "/api/v1/ack/nonexistent_job_xyz", "{}", &resp_buf);
            self.double_acks += 1;
        }
    }

    // ====================================================================
    // Heartbeat — via POST /api/v1/heartbeat
    // ====================================================================

    fn doHeartbeat(self: *SimClient) void {
        if (self.active_count == 0) return;

        const idx = self.rng.intRangeAtMost(usize, 0, self.active_count - 1);
        const entry = &self.active_jobs[idx];

        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            "{{\"worker_id\":\"{s}\",\"jobs\":{{\"{s}\":{{}}}}}}",
            .{ self.workerID(), entry.jobID() },
        ) catch return;

        var resp_buf: [resp_buf_size]u8 = undefined;
        _ = self.route("POST", "/api/v1/heartbeat", body, &resp_buf);
        self.heartbeats += 1;
    }

    // ====================================================================
    // Bulk actions — via POST /api/v1/jobs/bulk
    // ====================================================================

    fn doBulkAction(self: *SimClient) void {
        if (self.completed_count == 0) return;

        const count = @min(
            self.rng.intRangeAtMost(usize, 1, 5),
            self.completed_count,
        );

        const actions = [_][]const u8{ "requeue", "delete", "cancel" };
        const action = actions[self.rng.intRangeAtMost(usize, 0, actions.len - 1)];

        var body_buf: [2048]u8 = undefined;
        var stream = std.io.fixedBufferStream(&body_buf);
        const w = stream.writer();

        w.print("{{\"action\":\"{s}\",\"job_ids\":[", .{action}) catch return;
        for (0..count) |i| {
            if (i > 0) w.writeByte(',') catch return;
            const ci = self.rng.intRangeAtMost(usize, 0, self.completed_count - 1);
            w.print("\"{s}\"", .{self.completed_ids[ci].slice()}) catch return;
        }
        w.writeAll("]}") catch return;

        var resp_buf: [resp_buf_size]u8 = undefined;
        _ = self.route("POST", "/api/v1/jobs/bulk", stream.getWritten(), &resp_buf);
        self.bulk_ops += 1;

        if (std.mem.eql(u8, action, "delete")) {
            // Can't easily track which specific IDs were in the random selection,
            // so just leave completed_ids as-is (harmless stale entries).
        }
    }

    // ====================================================================
    // Batch operations — via POST /api/v1/batch and /batch/{id}/seal
    // ====================================================================

    fn doBatchOp(self: *SimClient) void {
        if (self.batch_count > 0 and self.chance(0.4)) {
            self.doBatchSeal(self.rng.intRangeAtMost(usize, 0, self.batch_count - 1));
        } else {
            self.doBatchCreate();
        }
    }

    fn doBatchCreate(self: *SimClient) void {
        if (self.batch_count >= max_batches) {
            self.doBatchSeal(0);
            return;
        }

        const q = self.queues[self.rng.intRangeAtMost(usize, 0, self.queues.len - 1)];
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf,
            "{{\"callback_queue\":\"{s}\"}}",
            .{q},
        ) catch return;

        var resp_buf: [resp_buf_size]u8 = undefined;
        const resp = self.route("POST", "/api/v1/batch", body, &resp_buf);
        if (resp.status != 201) return;

        // Parse batch_id from response.
        const batch_id = extractJsonString(resp.body, "batch_id") orelse return;
        if (batch_id.len == 0) return;

        const len = @min(batch_id.len, self.batches[self.batch_count].buf.len);
        @memcpy(self.batches[self.batch_count].buf[0..len], batch_id[0..len]);
        self.batches[self.batch_count].len = len;
        self.batch_job_counts[self.batch_count] = 0;
        self.batch_count += 1;
        self.batch_creates += 1;
    }

    fn doBatchSeal(self: *SimClient, idx: usize) void {
        if (self.batch_count == 0) return;
        const bi = @min(idx, self.batch_count - 1);

        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf,
            "/api/v1/batch/{s}/seal", .{self.batches[bi].slice()},
        ) catch return;

        var resp_buf: [resp_buf_size]u8 = undefined;
        _ = self.route("POST", path, null, &resp_buf);
        self.batch_seals += 1;

        self.batches[bi] = self.batches[self.batch_count - 1];
        self.batch_job_counts[bi] = self.batch_job_counts[self.batch_count - 1];
        self.batch_count -= 1;
    }

    // ====================================================================
    // Maintenance — via engine.apply() (no HTTP endpoint)
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
    // Queue operations — via POST /api/v1/queues/{name}/pause|resume|clear
    // ====================================================================

    fn doQueueOp(self: *SimClient) void {
        const queue_idx = self.rng.intRangeAtMost(usize, 0, self.queues.len - 1);
        const q = self.queues[queue_idx];

        // 10% chance of clear.
        if (self.chance(0.1)) {
            var path_buf: [128]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/api/v1/queues/{s}/clear", .{q}) catch return;
            var resp_buf: [resp_buf_size]u8 = undefined;
            _ = self.route("POST", path, null, &resp_buf);
            self.clear_queues += 1;
            self.queue_ops += 1;
            // Active jobs are NOT affected by queue clear — workers still hold them.
            return;
        }

        // Toggle pause state.
        const action_str: []const u8 = if (self.paused_queues[queue_idx]) "resume" else "pause";
        self.paused_queues[queue_idx] = !self.paused_queues[queue_idx];

        var path_buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/queues/{s}/{s}", .{ q, action_str }) catch return;
        var resp_buf: [resp_buf_size]u8 = undefined;
        _ = self.route("POST", path, null, &resp_buf);
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

    fn chance(self: *SimClient, prob: f64) bool {
        return self.rng.float(f64) < prob;
    }

    /// Extract a JSON u64 value by key from a flat JSON object.
    /// Simple parser — handles {"key":12345,...} patterns.
    fn extractJsonU64(body: []const u8, key: []const u8) u64 {
        var pattern_buf: [128]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":", .{key}) catch return 0;

        const start_idx = std.mem.indexOf(u8, body, pattern) orelse return 0;
        const val_start = start_idx + pattern.len;
        if (val_start >= body.len) return 0;

        // Parse decimal digits.
        var end = val_start;
        while (end < body.len and body[end] >= '0' and body[end] <= '9') : (end += 1) {}
        if (end == val_start) return 0;

        return std.fmt.parseUnsigned(u64, body[val_start..end], 10) catch 0;
    }

    /// Extract a JSON string value by key from a flat JSON object.
    /// Simple parser — handles {"key":"value",...} patterns.
    fn extractJsonString(body: []const u8, key: []const u8) ?[]const u8 {
        // Build search pattern: "key":"
        var pattern_buf: [128]u8 = undefined;
        const pattern = std.fmt.bufPrint(&pattern_buf, "\"{s}\":\"", .{key}) catch return null;

        const start_idx = std.mem.indexOf(u8, body, pattern) orelse return null;
        const val_start = start_idx + pattern.len;
        if (val_start >= body.len) return null;

        // Find closing quote.
        const val_end = std.mem.indexOf(u8, body[val_start..], "\"") orelse return null;
        return body[val_start .. val_start + val_end];
    }
};
