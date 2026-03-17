//! Store — stateless coordinator for the Corvo API layer.
//!
//! Ported from Go internal/store/store.go.
//! Wraps the Engine (write path), Mirror (async SQLite), and
//! SQLite Reader (query reads). All API handlers go through Store.

const std = @import("std");
const assert_mod = @import("assert.zig");
const types = @import("types.zig");
const ops_mod = @import("ops.zig");
const engine_mod = @import("engine.zig");
const mirror_mod = @import("mirror.zig");
const sqlite_read = @import("sqlite_read.zig");
const sqlite = @import("sqlite.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");

// Thread-local buffer for approval policy reason strings.
const threadlocal_reason = struct {
    threadlocal var buf: [256]u8 = undefined;

    fn build(policy_name: []const u8) []const u8 {
        return std.fmt.bufPrint(&buf, "approval policy matched: {s}", .{policy_name}) catch "approval policy matched";
    }
};

// ============================================================================
// Store
// ============================================================================

pub const Store = struct {
    engine: *engine_mod.Engine,
    mirror: ?*mirror_mod.Mirror,
    allocator: std.mem.Allocator,

    // ID generation
    id_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        engine: *engine_mod.Engine,
        mirror: ?*mirror_mod.Mirror,
    ) Store {
        return .{
            .engine = engine,
            .mirror = mirror,
            .allocator = allocator,
        };
    }

    // ====================================================================
    // Write operations — go through Engine
    // ====================================================================

    /// Enqueue a single job. Returns the job ID.
    pub fn enqueue(self: *Store, job: ops_mod.EnqueueJob) ops_mod.OpResult {
        const jobs_arr = [1]ops_mod.EnqueueJob{job};
        const data = ops_mod.OpData{
            .enqueue = .{
                .jobs = &jobs_arr,
                .now_ns = self.nowNs(),
            },
        };
        const result = self.engine.submit(.enqueue, &data);

        // Mirror
        if (self.mirror) |m| m.enqueueJob(&job);

        return result;
    }

    /// Enqueue multiple jobs.
    pub fn enqueueBatch(self: *Store, jobs: []const ops_mod.EnqueueJob) ops_mod.OpResult {
        const now = self.nowNs();
        const data = ops_mod.OpData{
            .enqueue = .{
                .jobs = jobs,
                .now_ns = now,
            },
        };
        const result = self.engine.submit(.enqueue, &data);

        if (self.mirror) |m| {
            for (jobs) |*j| m.enqueueJob(j);
        }

        return result;
    }

    /// Fetch jobs from queues.
    pub fn fetch(
        self: *Store,
        queues: []const []const u8,
        worker_id: []const u8,
        count: u32,
        lease_duration_ms: u32,
        override_now_ns: u64,
    ) ops_mod.OpResult {
        const now = if (override_now_ns > 0) override_now_ns else self.nowNs();
        const data = ops_mod.OpData{
            .fetch = .{
                .queues = queues,
                .worker_id = worker_id,
                .count = count,
                .now_ns = now,
                .lease_duration_ms = lease_duration_ms,
            },
        };
        const result = self.engine.submit(.fetch, &data);

        // Mirror fetched jobs.
        if (self.mirror) |m| {
            for (0..result.affected) |i| {
                const f = &result.fetched[i];
                var payload = mirror_mod.MirrorOp.FetchPayload{
                    .now_ns = now,
                    .lease_duration_ms = lease_duration_ms,
                };
                @memcpy(payload.job_id[0..f.id_len], f.id_buf[0..f.id_len]);
                payload.job_id_len = f.id_len;
                const wl = @min(worker_id.len, payload.worker_id.len);
                @memcpy(payload.worker_id[0..wl], worker_id[0..wl]);
                payload.worker_id_len = @intCast(wl);
                m.enqueue(.{ .op_type = .fetch, .payload = .{ .fetch = payload } });
            }
        }

        return result;
    }

    /// Acknowledge job completion.
    pub fn ack(self: *Store, job_id: []const u8, queue: []const u8) ops_mod.OpResult {
        return self.ackFull(job_id, queue, .{
            .job_id = job_id,
            .queue = queue,
        });
    }

    /// Acknowledge job with full ack options (agent status, checkpoint, etc.).
    pub fn ackFull(self: *Store, job_id: []const u8, queue: []const u8, ack_job: ops_mod.AckJob) ops_mod.OpResult {
        _ = queue;
        const now = self.nowNs();

        // Approval policy auto-hold: when agent_status is "continue",
        // evaluate policies and override to "hold" if a policy matches.
        var final_ack = ack_job;
        if (ack_job.agent_status == .@"continue") {
            if (self.evaluateApprovalPolicies(job_id, ack_job.queue)) |reason| {
                final_ack.agent_status = .hold;
                final_ack.hold_reason = reason;
            }
        }

        const acks = [1]ops_mod.AckJob{final_ack};
        const data = ops_mod.OpData{
            .ack = .{
                .acks = &acks,
                .now_ns = now,
            },
        };
        const result = self.engine.submit(.ack, &data);

        if (self.mirror) |m| {
            // Mirror ack — build payload with result/hold_reason.
            var payload = mirror_mod.MirrorOp.AckPayload{
                .now_ns = now,
            };
            const il = @min(job_id.len, payload.job_id.len);
            @memcpy(payload.job_id[0..il], job_id[0..il]);
            payload.job_id_len = @intCast(il);
            if (ack_job.result) |r| {
                const rl: u16 = @intCast(@min(r.len, payload.result.len));
                @memcpy(payload.result[0..rl], r[0..rl]);
                payload.result_len = rl;
            }
            if (ack_job.hold_reason) |hr| {
                const hl = @min(hr.len, payload.hold_reason.len);
                @memcpy(payload.hold_reason[0..hl], hr[0..hl]);
                payload.hold_reason_len = @intCast(hl);
            }

            // Read back job from KV to populate agent fields and emit iteration.
            if (result.err == null) {
                var jk_buf: keys.KeyBuf = undefined;
                if (self.engine.get(keys.jobKey(&jk_buf, job_id))) |job_bytes| {
                    defer self.allocator.free(job_bytes);
                    const job = codec.decodeJob(job_bytes);
                    if (job.agent) |agent| {
                        // Populate agent fields on the ack payload.
                        payload.agent_iteration = agent.iteration;
                        payload.agent_total_cost_usd = agent.total_cost_usd;

                        // Emit iteration mirror op.
                        var iter_payload = mirror_mod.MirrorOp.IterationPayload{
                            .iteration = agent.iteration,
                            .cost_usd = if (ack_job.usage) |u| u.cost_usd else 0,
                            .completed_at_ns = now,
                        };
                        const jl = @min(job_id.len, iter_payload.job_id.len);
                        @memcpy(iter_payload.job_id[0..jl], job_id[0..jl]);
                        iter_payload.job_id_len = @intCast(jl);
                        iter_payload.status = switch (job.state) {
                            .completed => .completed,
                            .held => .held,
                            .pending => .@"continue",
                            else => .completed,
                        };
                        if (ack_job.checkpoint) |cp| {
                            const cl = @min(cp.len, iter_payload.checkpoint.len);
                            @memcpy(iter_payload.checkpoint[0..cl], cp[0..cl]);
                            iter_payload.checkpoint_len = @intCast(cl);
                        }
                        if (ack_job.result) |r| {
                            const rl = @min(r.len, iter_payload.result.len);
                            @memcpy(iter_payload.result[0..rl], r[0..rl]);
                            iter_payload.result_len = @intCast(rl);
                        }
                        m.enqueue(.{ .op_type = .ack, .payload = .{ .iteration = iter_payload } });
                    }
                }
            }

            m.enqueue(.{ .op_type = .ack, .payload = .{ .ack = payload } });
        }

        return result;
    }

    /// Fail a job.
    pub fn fail(self: *Store, job_id: []const u8, queue: []const u8, error_msg: []const u8, backtrace: ?[]const u8) ops_mod.OpResult {
        const now = self.nowNs();
        const fail_jobs = [1]ops_mod.FailJob{.{
            .job_id = job_id,
            .queue = queue,
            .error_msg = error_msg,
            .backtrace = backtrace,
        }};
        const data = ops_mod.OpData{
            .fail = .{
                .jobs = &fail_jobs,
                .now_ns = now,
            },
        };
        const result = self.engine.submit(.fail, &data);

        // Mirror fail — read actual new state from KV (could be retrying or dead).
        if (self.mirror) |m| {
            var payload = mirror_mod.MirrorOp.FailPayload{
                .now_ns = now,
            };
            const il = @min(job_id.len, payload.job_id.len);
            @memcpy(payload.job_id[0..il], job_id[0..il]);
            payload.job_id_len = @intCast(il);
            const el = @min(error_msg.len, payload.error_msg.len);
            @memcpy(payload.error_msg[0..el], error_msg[0..el]);
            payload.error_msg_len = @intCast(el);
            if (backtrace) |bt| {
                const bl: u16 = @intCast(@min(bt.len, payload.backtrace.len));
                @memcpy(payload.backtrace[0..bl], bt[0..bl]);
                payload.backtrace_len = bl;
            }

            // Read back from KV to determine actual state (retrying vs dead).
            if (result.err == null) {
                var jk_buf: keys.KeyBuf = undefined;
                if (self.engine.get(keys.jobKey(&jk_buf, job_id))) |job_bytes| {
                    defer self.allocator.free(job_bytes);
                    const job = codec.decodeJob(job_bytes);
                    payload.new_state = job.state;
                    payload.attempt = job.attempt;
                    if (job.state == .retrying and job.scheduled_at_ns > 0) {
                        payload.retry_at_ns = job.scheduled_at_ns;
                    }
                }
            }

            m.enqueue(.{ .op_type = .fail, .payload = .{ .fail = payload } });
        }

        return result;
    }

    /// Worker heartbeat.
    pub fn heartbeat(
        self: *Store,
        job_ids: []const []const u8,
        job_ops: []const ops_mod.HeartbeatJobOp,
        worker_id: []const u8,
    ) ops_mod.OpResult {
        const now = self.nowNs();
        const data = ops_mod.OpData{
            .heartbeat = .{
                .job_ids = job_ids,
                .job_ops = job_ops,
                .worker_id = worker_id,
                .now_ns = now,
            },
        };
        const result = self.engine.submit(.heartbeat, &data);

        // Mirror worker heartbeat + per-job progress/checkpoint/lease updates.
        if (self.mirror) |m| {
            var payload = mirror_mod.MirrorOp.HeartbeatPayload{
                .now_ns = now,
            };
            const wl = @min(worker_id.len, payload.worker_id.len);
            @memcpy(payload.worker_id[0..wl], worker_id[0..wl]);
            payload.worker_id_len = @intCast(wl);
            m.enqueue(.{ .op_type = .heartbeat, .payload = .{ .heartbeat = payload } });

            // Per-job heartbeat updates (progress, checkpoint, lease) via ring buffer.
            const lease_ns = now + 30 * std.time.ns_per_s; // default lease
            const n = @min(job_ids.len, job_ops.len);
            for (0..n) |i| {
                m.enqueueHeartbeatJob(job_ids[i], job_ops[i].progress, job_ops[i].checkpoint, lease_ns);
            }
        }

        return result;
    }

    /// Run maintenance action.
    pub fn maintenance(self: *Store, action: ops_mod.MaintenanceAction) ops_mod.OpResult {
        const now = self.nowNs();
        const data = ops_mod.OpData{
            .maintenance = .{
                .action = action,
                .now_ns = now,
                .cutoff_ns = now,
            },
        };
        const result = self.engine.submit(.maintenance, &data);

        // Mirror maintenance via ring buffer.
        if (self.mirror) |m| {
            m.enqueueMaintenance(action, now);
        }

        return result;
    }

    /// Queue config action.
    pub fn queueConfig(self: *Store, queue: []const u8, action: ops_mod.QueueAction) ops_mod.OpResult {
        const data = ops_mod.OpData{
            .queue_config = .{
                .queue = queue,
                .action = action,
            },
        };
        const result = self.engine.submit(.queue_config, &data);

        // Mirror queue config change.
        if (self.mirror) |m| {
            var payload = mirror_mod.MirrorOp.QueueConfigPayload{
                .action = action,
            };
            const ql = @min(queue.len, payload.queue.len);
            @memcpy(payload.queue[0..ql], queue[0..ql]);
            payload.queue_len = @intCast(ql);
            m.enqueue(.{ .op_type = .queue_config, .payload = .{ .queue_config = payload } });
        }

        return result;
    }

    /// Queue config with full parameters (concurrency, throttle, etc.).
    pub fn queueConfigFull(self: *Store, op: ops_mod.QueueOp) ops_mod.OpResult {
        const data = ops_mod.OpData{
            .queue_config = op,
        };
        const result = self.engine.submit(.queue_config, &data);

        // Mirror queue config change.
        if (self.mirror) |m| {
            var payload = mirror_mod.MirrorOp.QueueConfigPayload{
                .action = op.action,
                .max_concurrency = op.max_concurrency,
                .rate_limit = op.rate_limit,
                .rate_window_ms = op.rate_window_ms,
            };
            const ql = @min(op.queue.len, payload.queue.len);
            @memcpy(payload.queue[0..ql], op.queue[0..ql]);
            payload.queue_len = @intCast(ql);
            m.enqueue(.{ .op_type = .queue_config, .payload = .{ .queue_config = payload } });
        }

        return result;
    }

    /// Bulk action (retry, delete, cancel, move, requeue, etc.).
    pub fn bulkAction(self: *Store, data: *const ops_mod.OpData) ops_mod.OpResult {
        const result = self.engine.submit(.bulk_action, data);

        // Mirror: sync affected jobs' state via ring buffer.
        if (result.err == null and result.affected > 0) {
            if (self.mirror) |m| {
                const bulk = data.bulk_action;
                for (bulk.job_ids) |job_id| {
                    if (bulk.action == .delete) {
                        m.enqueueBulkActionJob(job_id, .delete, "", bulk.now_ns);
                    } else {
                        // Read the job's new state from KV and update the mirror.
                        var jk_buf: keys.KeyBuf = undefined;
                        if (self.engine.get(keys.jobKey(&jk_buf, job_id))) |job_bytes| {
                            defer self.allocator.free(job_bytes);
                            const job = codec.decodeJob(job_bytes);
                            m.enqueueBulkActionJob(job_id, .update_state, job.state.toString(), bulk.now_ns);
                        } else {
                            // Job deleted from KV — remove from mirror too.
                            m.enqueueBulkActionJob(job_id, .delete, "", bulk.now_ns);
                        }
                    }
                }
            }
        }

        return result;
    }

    /// Clear all jobs from a queue.
    pub fn clearQueue(self: *Store, queue: []const u8) ops_mod.OpResult {
        const data = ops_mod.OpData{
            .clear_queue = .{ .queue = queue, .now_ns = self.nowNs() },
        };
        const result = self.engine.submit(.clear_queue, &data);

        // Mirror: clear all jobs for this queue via ring buffer.
        if (result.err == null) {
            if (self.mirror) |m| m.enqueueQueueClear(queue);
        }

        return result;
    }

    /// Delete a queue entirely.
    pub fn deleteQueue(self: *Store, queue: []const u8) ops_mod.OpResult {
        const data = ops_mod.OpData{
            .delete_queue = .{ .queue = queue, .now_ns = self.nowNs() },
        };
        const result = self.engine.submit(.delete_queue, &data);

        // Mirror: delete queue record and all its jobs via ring buffer.
        if (result.err == null) {
            if (self.mirror) |m| m.enqueueQueueDelete(queue);
        }

        return result;
    }

    /// Create a new batch.
    pub fn batchCreate(self: *Store, data: *const ops_mod.OpData) ops_mod.OpResult {
        const result = self.engine.submit(.batch_create, data);

        // Mirror: create batch record via ring buffer.
        if (result.err == null) {
            if (self.mirror) |m| {
                const bid = data.batch_create.batch_id;
                if (bid.len > 0) m.enqueueBatchCreate(bid, self.nowNs());
            }
        }

        return result;
    }

    /// Seal a batch.
    pub fn batchSeal(self: *Store, data: *const ops_mod.OpData) ops_mod.OpResult {
        const result = self.engine.submit(.batch_seal, data);

        // Mirror: seal batch via ring buffer.
        if (result.err == null) {
            if (self.mirror) |m| {
                const bid = data.batch_seal.batch_id;
                if (bid.len > 0) m.enqueueBatchSeal(bid);
            }
        }

        return result;
    }

    /// Modify an enterprise setting (API keys, etc.).
    pub fn modifyEntSetting(self: *Store, op: ops_mod.ModifyEntSettingOp) ops_mod.OpResult {
        const data = ops_mod.OpData{
            .modify_ent_setting = op,
        };
        return self.engine.submit(.modify_ent_setting, &data);
    }

    /// Set a budget.
    pub fn setBudget(self: *Store, op: ops_mod.SetBudgetOp) ops_mod.OpResult {
        const data = ops_mod.OpData{
            .set_budget = op,
        };
        const result = self.engine.submit(.set_budget, &data);

        // Mirror: upsert budget via ring buffer.
        if (result.err == null) {
            if (self.mirror) |m| {
                m.enqueueBudgetUpsert(op.id, op.scope, op.target, op.daily_usd, op.per_job_usd, op.on_exceed);
            }
        }

        return result;
    }

    /// Delete a budget.
    pub fn deleteBudget(self: *Store, scope: []const u8, target: []const u8) ops_mod.OpResult {
        const data = ops_mod.OpData{
            .delete_budget = .{ .scope = scope, .target = target },
        };
        const result = self.engine.submit(.delete_budget, &data);

        // Mirror: delete budget via ring buffer.
        if (result.err == null) {
            if (self.mirror) |m| m.enqueueBudgetDelete(scope, target);
        }

        return result;
    }

    // ====================================================================
    // Read operations — go through SQLite mirror
    // ====================================================================

    /// Flush all pending mirror writes synchronously. Call before reads
    /// that need strong consistency (GetJob, SearchJobs, etc.).
    pub fn flushMirror(self: *Store) void {
        if (self.mirror) |m| m.flushAll();
    }

    /// Get a SQLite reader for query operations. Returns null if no mirror.
    pub fn reader(self: *Store) ?sqlite_read.Reader {
        if (self.mirror) |m| {
            return sqlite_read.Reader.init(m.getDB());
        }
        return null;
    }

    // ====================================================================
    // Helpers
    // ====================================================================

    pub fn nowNs(self: *Store) u64 {
        _ = self;
        return @intCast(@as(i128, std.time.nanoTimestamp()));
    }

    /// Generate a unique job ID.
    pub fn generateID(self: *Store, buf: []u8) []const u8 {
        const seq = self.id_counter.fetchAdd(1, .monotonic);
        const ts_ms: u64 = @intCast(@divTrunc(@as(i128, std.time.nanoTimestamp()), 1_000_000));
        return std.fmt.bufPrint(buf, "job_{x}_{x}", .{ ts_ms, seq }) catch "job_err";
    }

    /// Look up a job's queue from KV. Returns null if not found.
    /// Copies the queue name into the provided buffer to avoid lifetime issues.
    /// Evaluate approval policies against a job. Returns a hold reason if any policy matches.
    fn evaluateApprovalPolicies(self: *Store, job_id: []const u8, queue: []const u8) ?[]const u8 {
        // Read policies from SQLite mirror.
        var rdr = self.reader() orelse return null;
        var policies: [64]sqlite_read.ApprovalPolicyRow = undefined;
        const count = rdr.listApprovalPolicies(&policies) catch return null;
        if (count == 0) return null;

        // Get job tags from KV for tag matching.
        var tags_json: []const u8 = "{}";
        var tags_buf: [4096]u8 = undefined;
        var jk_buf: keys.KeyBuf = undefined;
        if (self.engine.get(keys.jobKey(&jk_buf, job_id))) |job_bytes| {
            defer self.allocator.free(job_bytes);
            const job = codec.decodeJob(job_bytes);
            if (job.tags) |tags| {
                if (tags.len > 0) {
                    const tl = @min(tags.len, tags_buf.len);
                    @memcpy(tags_buf[0..tl], tags[0..tl]);
                    tags_json = tags_buf[0..tl];
                }
            }
        }

        // Check each policy (newest first — order from SQL query).
        for (policies[0..count]) |*p| {
            if (p.matches(queue, tags_json)) {
                // Use threadlocal buffer for the reason string (safe for concurrent acks).
                const reason = threadlocal_reason.build(p.nameSlice());
                return reason;
            }
        }

        return null;
    }

    pub fn lookupJobQueue(self: *Store, job_id: []const u8, queue_buf: *[64]u8) ?[]const u8 {
        var jk_buf: keys.KeyBuf = undefined;
        const val = self.engine.get(keys.jobKey(&jk_buf, job_id)) orelse return null;
        defer self.allocator.free(val);
        const job = codec.decodeJob(val);
        const qlen = @min(job.queue.len, queue_buf.len);
        @memcpy(queue_buf[0..qlen], job.queue[0..qlen]);
        return queue_buf[0..qlen];
    }
};
