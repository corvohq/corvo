//! OpHandler — deterministic state machine for the Corvo apply loop.
//!
//! Ported from Go internal/ops/handler.go. All business logic for job
//! state transitions lives here. No I/O, no allocator surprises.
//! Operates exclusively on kv.WriteBatch for reads and writes.

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const pending_index_mod = @import("pending_index.zig");

const Allocator = std.mem.Allocator;

// ============================================================================
// OpHandler
// ============================================================================

pub const OpHandler = struct {
    /// Per-queue active job count. Avoids O(n) prefix scan on fetch.
    active_counts: std.StringHashMap(i32),
    /// Queue → tag key (which queues have fairness enabled).
    fairness_keys: std.StringHashMap([]const u8),
    /// Queue → tag → active count.
    fairness_active: std.StringHashMap(std.StringHashMap(i32)),
    /// Queue → tag → served count (for round-robin scoring).
    fairness_served: std.StringHashMap(std.StringHashMap(i32)),
    /// In-memory index of pending jobs per queue. Eliminates B+ tree
    /// iterator scans on fetch — O(log n) heap pop instead of O(n) scan.
    pending: pending_index_mod.PendingIndex,
    /// Cached queue configs. Avoids KV read on every fetch.
    /// Invalidated on queue_config, clear_queue, delete_queue ops.
    queue_configs: std.StringHashMap(types.Queue),
    /// Whether to verify index consistency after each mutation.
    verify_indexes: bool = false,
    /// Monotonic counter for lease tokens. Unique per fetch claim.
    lease_counter: u64 = 0,
    requeue_counter: u64 = 0,
    // Effect buffers — accumulated during apply, drained by pipeline after commit.
    side_effects: [max_side_effects]mirror_mod.MirrorOp.EnqueuePayload = undefined,
    side_effect_count: u8 = 0,
    fail_results: [max_fail_results]FailResult = undefined,
    fail_result_count: u16 = 0,
    bulk_results: [max_bulk_results]BulkResult = undefined,
    bulk_result_count: u16 = 0,

    // Promote/reclaim notification: queues that had jobs promoted to pending.
    promote_queue_bufs: [max_promote_queues][64]u8 = undefined,
    promote_queue_lens: [max_promote_queues]u8 = [_]u8{0} ** max_promote_queues,
    promote_queue_slices: [max_promote_queues][]const u8 = undefined,
    promote_queue_count: u8 = 0,
    /// Allocator for handler-owned state (maps, etc).
    allocator: Allocator,

    // Explicit resource limits (TigerStyle: all collections must have bounds).
    max_queues: u32 = 100,
    max_tags_per_queue: u32 = 1000,

    const mirror_mod = @import("mirror.zig");

    const max_side_effects = 32;
    const max_fail_results = 256;
    pub const max_bulk_results = 4096;
    const max_promote_queues = 32;

    pub const FailResult = struct {
        job_id: [128]u8 = undefined,
        job_id_len: u8 = 0,
        error_msg: [256]u8 = undefined,
        error_msg_len: u16 = 0,
        backtrace: [1024]u8 = undefined,
        backtrace_len: u16 = 0,
        new_state: types.JobState = .retrying,
        attempt: u16 = 0,
        retry_at_ns: u64 = 0,
        now_ns: u64 = 0,

        pub fn jobId(self: *const FailResult) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        pub fn errorMsg(self: *const FailResult) []const u8 {
            return self.error_msg[0..self.error_msg_len];
        }
        pub fn backtraceSlice(self: *const FailResult) []const u8 {
            return self.backtrace[0..self.backtrace_len];
        }
    };

    pub const BulkResult = struct {
        pub const ActionType = enum { update_state, delete, move };

        job_id: [128]u8 = undefined,
        job_id_len: u8 = 0,
        action: ActionType = .update_state,
        new_state: [16]u8 = undefined,
        new_state_len: u8 = 0,
        new_queue: [128]u8 = undefined,
        new_queue_len: u8 = 0,
        now_ns: u64 = 0,

        pub fn jobId(self: *const BulkResult) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        pub fn stateSlice(self: *const BulkResult) []const u8 {
            return self.new_state[0..self.new_state_len];
        }
        pub fn queueSlice(self: *const BulkResult) []const u8 {
            return self.new_queue[0..self.new_queue_len];
        }
    };

    pub fn init(allocator: Allocator) OpHandler {
        return .{
            .active_counts = std.StringHashMap(i32).init(allocator),
            .fairness_keys = std.StringHashMap([]const u8).init(allocator),
            .fairness_active = std.StringHashMap(std.StringHashMap(i32)).init(allocator),
            .fairness_served = std.StringHashMap(std.StringHashMap(i32)).init(allocator),
            .pending = pending_index_mod.PendingIndex.init(allocator),
            .queue_configs = std.StringHashMap(types.Queue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpHandler) void {
        // Free owned keys in active_counts.
        {
            var it = self.active_counts.iterator();
            while (it.next()) |entry| self.allocator.free(@constCast(entry.key_ptr.*));
        }
        self.active_counts.deinit();
        // Free owned keys in fairness maps.
        {
            var it = self.fairness_keys.iterator();
            while (it.next()) |entry| {
                self.allocator.free(@constCast(entry.key_ptr.*));
                self.allocator.free(@constCast(entry.value_ptr.*));
            }
        }
        self.fairness_keys.deinit();
        {
            var fa_iter = self.fairness_active.iterator();
            while (fa_iter.next()) |entry| {
                self.allocator.free(@constCast(entry.key_ptr.*));
                var inner_it = entry.value_ptr.iterator();
                while (inner_it.next()) |ie| self.allocator.free(@constCast(ie.key_ptr.*));
                entry.value_ptr.deinit();
            }
        }
        self.fairness_active.deinit();
        {
            var fs_iter = self.fairness_served.iterator();
            while (fs_iter.next()) |entry| {
                self.allocator.free(@constCast(entry.key_ptr.*));
                var inner_it = entry.value_ptr.iterator();
                while (inner_it.next()) |ie| self.allocator.free(@constCast(ie.key_ptr.*));
                entry.value_ptr.deinit();
            }
        }
        self.fairness_served.deinit();
        self.pending.deinit();
        {
            var it = self.queue_configs.iterator();
            while (it.next()) |entry| self.allocator.free(@constCast(entry.key_ptr.*));
        }
        self.queue_configs.deinit();
    }

    /// Clear all in-memory state. Call before rebuildState() after snapshot restore.
    pub fn clearState(self: *OpHandler) void {
        // Clear active counts (free owned keys).
        {
            var it = self.active_counts.iterator();
            while (it.next()) |entry| {
                self.allocator.free(@constCast(entry.key_ptr.*));
            }
            self.active_counts.clearRetainingCapacity();
        }

        // Clear queue configs (free owned keys).
        {
            var it = self.queue_configs.iterator();
            while (it.next()) |entry| {
                self.allocator.free(@constCast(entry.key_ptr.*));
            }
            self.queue_configs.clearRetainingCapacity();
        }

        // Clear pending index.
        self.pending.clear();

        // Clear fairness maps (nested hashmaps — free inner maps).
        {
            var it = self.fairness_active.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.fairness_active.clearRetainingCapacity();
        }
        {
            var it = self.fairness_served.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.deinit();
            }
            self.fairness_served.clearRetainingCapacity();
        }
    }

    /// Rebuild in-memory state from KV after restart.
    /// Single pass over all j| keys to populate:
    ///   - PendingIndex (pending jobs for fetch)
    ///   - active_counts (for concurrency limits)
    ///   - queue_configs (cached queue settings)
    pub fn rebuildState(self: *OpHandler, shards: []kv.Store) void {
        var pending_count: u32 = 0;
        var active_count: u32 = 0;
        var total_count: u32 = 0;

        for (shards) |*shard| {
            var batch = shard.newBatch();
            defer batch.close();

            // Scan all j| keys.
            var jp_buf: keys.KeyBuf = undefined;
            var jpe_buf: keys.KeyBuf = undefined;
            const jp = keys.prefix_job;
            @memcpy(jp_buf[0..jp.len], jp);
            const end = keys.prefixEnd(&jpe_buf, jp_buf[0..jp.len]) orelse continue;

            var iter = batch.newIter(jp_buf[0..jp.len], end);
            defer iter.close();

            if (!iter.first()) continue;

            while (true) {
                const val = iter.value();
                const job = codec.decodeJob(val);
                total_count += 1;

                switch (job.state) {
                    .pending => {
                        self.pending.push(job.queue, job.priority, job.created_at_ns, job.id);
                        pending_count += 1;
                    },
                    .active => {
                        self.incrActiveCount(job.queue);
                        if (job.group) |g| self.incrFairnessActive(job.queue, g);
                        active_count += 1;
                    },
                    else => {},
                }

                if (!iter.next()) break;
            }

            // Also rebuild queue configs from qc| keys.
            var qc_buf: keys.KeyBuf = undefined;
            var qce_buf: keys.KeyBuf = undefined;
            const qcp = keys.prefix_queue_config;
            @memcpy(qc_buf[0..qcp.len], qcp);
            const qc_end = keys.prefixEnd(&qce_buf, qc_buf[0..qcp.len]) orelse continue;

            var qc_iter = batch.newIter(qc_buf[0..qcp.len], qc_end);
            defer qc_iter.close();

            if (qc_iter.first()) {
                while (true) {
                    const qc_val = qc_iter.value();
                    const queue = codec.decodeQueue(qc_val);
                    if (queue.name.len > 0) {
                        _ = self.putQueueConfig(queue.name, queue);
                    }
                    if (!qc_iter.next()) break;
                }
            }
        }

        _ = .{ pending_count, active_count, total_count };
    }

    // ========================================================================
    // Effect buffer methods — pipeline drains these after commit
    // ========================================================================

    pub fn resetEffects(self: *OpHandler) void {
        self.side_effect_count = 0;
        self.fail_result_count = 0;
        self.bulk_result_count = 0;
        self.promote_queue_count = 0;
    }

    /// Record a queue that had jobs promoted to pending (dedup by name).
    pub fn recordPromoteQueue(self: *OpHandler, queue: []const u8) void {
        // Dedup: check if already recorded.
        for (0..self.promote_queue_count) |i| {
            const existing = self.promote_queue_bufs[i][0..self.promote_queue_lens[i]];
            if (std.mem.eql(u8, existing, queue)) return;
        }
        if (self.promote_queue_count >= max_promote_queues) return; // saturate
        const idx = self.promote_queue_count;
        const len: u8 = @intCast(@min(queue.len, 64));
        @memcpy(self.promote_queue_bufs[idx][0..len], queue[0..len]);
        self.promote_queue_lens[idx] = len;
        self.promote_queue_count += 1;
    }

    /// Get the promote queue notification slices (valid until next resetEffects).
    pub fn promoteQueueSlices(self: *OpHandler) []const []const u8 {
        for (0..self.promote_queue_count) |i| {
            self.promote_queue_slices[i] = self.promote_queue_bufs[i][0..self.promote_queue_lens[i]];
        }
        return self.promote_queue_slices[0..self.promote_queue_count];
    }

    pub fn recordSideEffect(self: *OpHandler, job: *const ops.EnqueueJob) void {
        assert.check(self.side_effect_count < max_side_effects, "recordSideEffect: overflow ({d})", .{self.side_effect_count});
        var p = mirror_mod.MirrorOp.EnqueuePayload{
            .state = job.state,
            .priority = job.priority,
            .max_retries = job.max_retries,
            .created_at_ns = job.created_at_ns,
        };
        inline for (.{
            .{ &p.job_id, &p.job_id_len, job.job_id },
            .{ &p.queue, &p.queue_len, job.queue },
        }) |t| {
            const dst, const dst_len, const src = t;
            const l: u8 = @intCast(@min(src.len, dst.len));
            @memcpy(dst[0..l], src[0..l]);
            dst_len.* = l;
        }
        if (job.payload) |pl| {
            const l: u16 = @intCast(@min(pl.len, p.payload_preview.len));
            @memcpy(p.payload_preview[0..l], pl[0..l]);
            p.payload_preview_len = l;
        }
        if (job.tags) |t| {
            const l: u8 = @intCast(@min(t.len, p.tags.len));
            @memcpy(p.tags[0..l], t[0..l]);
            p.tags_len = l;
        }
        if (job.parent_id) |pid| {
            const l: u8 = @intCast(@min(pid.len, p.parent_id.len));
            @memcpy(p.parent_id[0..l], pid[0..l]);
            p.parent_id_len = l;
        }
        if (job.chain_id) |cid| {
            const l: u8 = @intCast(@min(cid.len, p.chain_id.len));
            @memcpy(p.chain_id[0..l], cid[0..l]);
            p.chain_id_len = l;
        }
        p.chain_step = job.chain_step;
        self.side_effects[self.side_effect_count] = p;
        self.side_effect_count += 1;
    }

    pub fn recordFailResult(self: *OpHandler, job_id: []const u8, error_msg: []const u8, backtrace: ?[]const u8, new_state: types.JobState, attempt: u16, retry_at_ns: u64, now_ns: u64) void {
        assert.check(self.fail_result_count < max_fail_results, "recordFailResult: overflow ({d})", .{self.fail_result_count});
        var r = FailResult{
            .new_state = new_state,
            .attempt = attempt,
            .retry_at_ns = retry_at_ns,
            .now_ns = now_ns,
        };
        const il: u8 = @intCast(@min(job_id.len, r.job_id.len));
        @memcpy(r.job_id[0..il], job_id[0..il]);
        r.job_id_len = il;
        const el: u16 = @intCast(@min(error_msg.len, r.error_msg.len));
        @memcpy(r.error_msg[0..el], error_msg[0..el]);
        r.error_msg_len = el;
        if (backtrace) |bt| {
            const bl: u16 = @intCast(@min(bt.len, r.backtrace.len));
            @memcpy(r.backtrace[0..bl], bt[0..bl]);
            r.backtrace_len = bl;
        }
        self.fail_results[self.fail_result_count] = r;
        self.fail_result_count += 1;
    }

    pub fn recordBulkResult(self: *OpHandler, job_id: []const u8, action: BulkResult.ActionType, state: []const u8, queue: []const u8, now_ns: u64) void {
        assert.check(self.bulk_result_count < max_bulk_results, "recordBulkResult: overflow ({d})", .{self.bulk_result_count});
        var r = BulkResult{ .action = action, .now_ns = now_ns };
        const il: u8 = @intCast(@min(job_id.len, r.job_id.len));
        @memcpy(r.job_id[0..il], job_id[0..il]);
        r.job_id_len = il;
        const sl: u8 = @intCast(@min(state.len, r.new_state.len));
        @memcpy(r.new_state[0..sl], state[0..sl]);
        r.new_state_len = sl;
        const ql: u8 = @intCast(@min(queue.len, r.new_queue.len));
        @memcpy(r.new_queue[0..ql], queue[0..ql]);
        r.new_queue_len = ql;
        self.bulk_results[self.bulk_result_count] = r;
        self.bulk_result_count += 1;
    }

    /// Main apply dispatch — the core state machine.
    pub fn apply(self: *OpHandler, b: *kv.WriteBatch, op_type: ops.OpType, data: *const ops.OpData) ops.OpResult {
        return switch (op_type) {
            .enqueue => self.applyEnqueue(b, &data.enqueue),
            .fetch => self.applyFetch(b, &data.fetch),
            .ack => self.applyAck(b, &data.ack),
            .fail => self.applyFail(b, &data.fail),
            .heartbeat => self.applyHeartbeat(b, &data.heartbeat),
            .bulk_action => self.applyBulkAction(b, &data.bulk_action),
            .queue_config => self.applyQueueConfig(b, &data.queue_config),
            .clear_queue => self.applyClearQueue(b, &data.clear_queue),
            .delete_queue => self.applyDeleteQueue(b, &data.delete_queue),
            .maintenance => self.applyMaintenance(b, &data.maintenance),
            .batch_create => self.applyBatchCreate(b, &data.batch_create),
            .batch_seal => self.applySealBatch(b, &data.batch_seal),
            .modify_ent_setting => self.applyModifyEntSetting(b, &data.modify_ent_setting),
            .cron_create => self.applyCreateCron(b, &data.cron_create),
            .cron_update => self.applyUpdateCron(b, &data.cron_update),
            .cron_delete => self.applyDeleteCron(b, &data.cron_delete),
            .cron_trigger => self.applyTriggerCron(b, &data.cron_trigger),
            .set_budget => self.applySetBudget(b, &data.set_budget),
            .delete_budget => self.applyDeleteBudget(b, &data.delete_budget),
            .multi => .{ .err = "nested multi not supported" },
        };
    }

    // ========================================================================
    // Active count helpers
    // ========================================================================

    pub fn decrActiveCount(self: *OpHandler, queue: []const u8) void {
        if (self.active_counts.getPtr(queue)) |count| {
            count.* -= 1;
            assert.check(count.* >= 0, "active count negative for queue", .{});
        }
    }

    pub fn incrActiveCount(self: *OpHandler, queue: []const u8) void {
        const entry = self.active_counts.getOrPut(queue) catch unreachable;
        if (!entry.found_existing) {
            entry.key_ptr.* = self.allocator.dupe(u8, queue) catch unreachable;
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    pub fn getActiveCount(self: *OpHandler, queue: []const u8) i32 {
        return self.active_counts.get(queue) orelse 0;
    }

    // ========================================================================
    // Fairness helpers
    // ========================================================================

    pub fn incrFairnessActive(self: *OpHandler, queue: []const u8, group: []const u8) void {
        if (group.len == 0) return;
        const qmap = self.fairness_active.getOrPut(queue) catch unreachable;
        if (!qmap.found_existing) {
            qmap.key_ptr.* = self.allocator.dupe(u8, queue) catch unreachable;
            qmap.value_ptr.* = std.StringHashMap(i32).init(self.allocator);
        }
        // Check tag limit before inserting new tag.
        if (qmap.value_ptr.get(group) == null and qmap.value_ptr.count() >= self.max_tags_per_queue) {
            return; // saturate — new tag won't get fairness tracking
        }
        const entry = qmap.value_ptr.getOrPut(group) catch unreachable;
        if (!entry.found_existing) {
            entry.key_ptr.* = self.allocator.dupe(u8, group) catch unreachable;
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    pub fn decrFairnessActive(self: *OpHandler, queue: []const u8, group: []const u8) void {
        if (group.len == 0) return;
        if (self.fairness_active.getPtr(queue)) |qmap| {
            if (qmap.getPtr(group)) |count| {
                count.* -= 1;
            }
        }
    }

    pub fn incrFairnessServed(self: *OpHandler, queue: []const u8, group: []const u8) void {
        if (group.len == 0) return;
        const qmap = self.fairness_served.getOrPut(queue) catch unreachable;
        if (!qmap.found_existing) {
            qmap.key_ptr.* = self.allocator.dupe(u8, queue) catch unreachable;
            qmap.value_ptr.* = std.StringHashMap(i32).init(self.allocator);
        }
        // Check tag limit before inserting new tag.
        if (qmap.value_ptr.get(group) == null and qmap.value_ptr.count() >= self.max_tags_per_queue) {
            return; // saturate — new tag won't get fairness scoring
        }
        const entry = qmap.value_ptr.getOrPut(group) catch unreachable;
        if (!entry.found_existing) {
            entry.key_ptr.* = self.allocator.dupe(u8, group) catch unreachable;
            entry.value_ptr.* = 0;
        }
        entry.value_ptr.* += 1;
    }

    // ========================================================================
    // Queue config cache
    // ========================================================================

    /// Get queue config, checking in-memory cache first, then KV.
    /// Caches the result for subsequent calls.
    pub fn getQueueConfig(self: *OpHandler, b: *kv.WriteBatch, queue_name: []const u8) ?types.Queue {
        // Check cache first
        if (self.queue_configs.get(queue_name)) |cached| return cached;

        // Miss — read from KV
        var qc_buf: keys.KeyBuf = undefined;
        var qc_val_buf: [codec.max_queue_encoded_size]u8 = undefined;
        const qc_bytes = b.getInto(keys.queueConfigKey(&qc_buf, queue_name), &qc_val_buf);
        if (qc_bytes == null) return null;

        const queue = codec.decodeQueue(qc_bytes.?);
        _ = self.putQueueConfig(queue_name, queue);
        return queue;
    }

    /// Update cache after a queue config change.
    /// Returns false if a new queue would exceed max_queues.
    pub fn putQueueConfig(self: *OpHandler, queue_name: []const u8, queue: types.Queue) bool {
        // Check limit before inserting a new key.
        if (self.queue_configs.get(queue_name) == null and self.queue_configs.count() >= self.max_queues) {
            return false;
        }
        const entry = self.queue_configs.getOrPut(queue_name) catch return false;
        if (!entry.found_existing) {
            entry.key_ptr.* = self.allocator.dupe(u8, queue_name) catch return false;
        }
        entry.value_ptr.* = queue;
        return true;
    }

    /// Remove from cache (on queue delete).
    pub fn removeQueueConfig(self: *OpHandler, queue_name: []const u8) void {
        if (self.queue_configs.fetchRemove(queue_name)) |entry| {
            self.allocator.free(@constCast(entry.key));
        }
    }

    // ========================================================================
    // Key helpers (single-source key constructors from job fields)
    // ========================================================================

    pub fn jobActiveKey(buf: *keys.KeyBuf, job: *const types.Job) []const u8 {
        return keys.activeKey(buf, job.queue, job.id);
    }

    pub fn jobScheduledKey(buf: *keys.KeyBuf, job: *const types.Job) []const u8 {
        assert.check(job.scheduled_at_ns > 0, "jobScheduledKey: job has zero scheduled_at_ns", .{});
        return keys.scheduledKey(buf, job.queue, job.scheduled_at_ns, job.id);
    }

    pub fn jobRetryingKey(buf: *keys.KeyBuf, job: *const types.Job) []const u8 {
        assert.check(job.scheduled_at_ns > 0, "jobRetryingKey: job has zero scheduled_at_ns", .{});
        return keys.retryingKey(buf, job.queue, job.scheduled_at_ns, job.id);
    }

    pub fn jobUniqueKey(buf: *keys.KeyBuf, job: *const types.Job) ?[]const u8 {
        const uk = job.unique_key orelse return null;
        if (uk.len == 0) return null;
        return keys.uniqueKey(buf, job.queue, uk);
    }

    // ========================================================================
    // Verification
    // ========================================================================

    pub fn verifyJobIndexes(self: *OpHandler, b: *kv.WriteBatch, job: *const types.Job, op_name: []const u8) void {
        if (!self.verify_indexes) return;

        var ak_buf: keys.KeyBuf = undefined;
        var sk_buf: keys.KeyBuf = undefined;

        const has_active = b.get(jobActiveKey(&ak_buf, job)) != null;
        const has_scheduled = if (job.scheduled_at_ns > 0) b.get(jobScheduledKey(&sk_buf, job)) != null else false;
        const has_retrying = if (job.scheduled_at_ns > 0) b.get(jobRetryingKey(&sk_buf, job)) != null else false;

        switch (job.state) {
            .pending => {
                // Pending is tracked in-memory (PendingIndex), no KV key to verify.
                assert.check(!has_active, "{s}: pending job has active key", .{op_name});
                assert.check(!has_scheduled, "{s}: pending job has scheduled key", .{op_name});
                assert.check(!has_retrying, "{s}: pending job has retrying key", .{op_name});
            },
            .active => {
                assert.check(has_active, "{s}: active job missing active key", .{op_name});
            },
            .scheduled => {
                assert.check(has_scheduled, "{s}: scheduled job missing scheduled key", .{op_name});
            },
            .retrying => {
                assert.check(has_retrying, "{s}: retrying job missing retrying key", .{op_name});
            },
            .completed, .dead, .cancelled => {
                assert.check(!has_active, "{s}: terminal job has active key", .{op_name});
                assert.check(!has_scheduled, "{s}: terminal job has scheduled key", .{op_name});
                assert.check(!has_retrying, "{s}: terminal job has retrying key", .{op_name});
            },
            .held => {
                assert.check(!has_active, "{s}: held job has active key", .{op_name});
            },
        }
    }

    // ========================================================================
    // Handler implementations — each in its own file, imported below.
    // Forward declarations so the handler files can call each other.
    // ========================================================================

    // Enqueue
    pub const applyEnqueue = @import("handler_enqueue.zig").applyEnqueue;

    // Fetch
    pub const applyFetch = @import("handler_fetch.zig").applyFetch;

    // Ack
    pub const applyAck = @import("handler_ack.zig").applyAck;

    // Fail
    pub const applyFail = @import("handler_fail.zig").applyFail;

    // Heartbeat
    pub const applyHeartbeat = @import("handler_heartbeat.zig").applyHeartbeat;

    // Bulk Action
    pub const applyBulkAction = @import("handler_bulk.zig").applyBulkAction;

    // Queue Config
    pub const applyQueueConfig = @import("handler_queue.zig").applyQueueConfig;
    pub const applyClearQueue = @import("handler_queue.zig").applyClearQueue;
    pub const applyDeleteQueue = @import("handler_queue.zig").applyDeleteQueue;

    // Maintenance
    pub const applyMaintenance = @import("handler_maintenance.zig").applyMaintenance;

    // Batch
    pub const applyBatchCreate = @import("handler_batch.zig").applyBatchCreate;
    pub const applySealBatch = @import("handler_batch.zig").applySealBatch;

    // Cron
    pub const applyCreateCron = @import("handler_cron.zig").applyCreateCron;
    pub const applyUpdateCron = @import("handler_cron.zig").applyUpdateCron;
    pub const applyDeleteCron = @import("handler_cron.zig").applyDeleteCron;
    pub const applyTriggerCron = @import("handler_cron.zig").applyTriggerCron;

    // Budget
    pub const applySetBudget = @import("handler_budget.zig").applySetBudget;
    pub const applyDeleteBudget = @import("handler_budget.zig").applyDeleteBudget;

    // Enterprise
    pub const applyModifyEntSetting = @import("handler_ent.zig").applyModifyEntSetting;

    /// Handle batch job completion — decrement pending, fire callback if batch is done.
    pub fn handleBatchJobComplete(self: *OpHandler, b: *kv.WriteBatch, batch_id: []const u8, succeeded: bool, now_ns: u64) void {
        var bk_buf: keys.KeyBuf = undefined;
        const bkey = keys.batchKey(&bk_buf, batch_id);
        var batch_val_buf: [codec.max_batch_encoded_size]u8 = undefined;
        const batch_bytes = b.getInto(bkey, &batch_val_buf) orelse return;
        var batch = codec.decodeBatch(batch_bytes);

        assert.check(batch.pending > 0, "handleBatchJobComplete: pending underflow for batch {s}", .{batch_id});
        batch.pending -= 1;
        if (succeeded) {
            batch.succeeded += 1;
        } else {
            batch.failed += 1;
        }
        assert.check(batch.succeeded + batch.failed <= batch.total, "handleBatchJobComplete: completed ({d}+{d}) exceeds total ({d}) for batch {s}", .{ batch.succeeded, batch.failed, batch.total, batch_id });

        // Check if batch is complete (sealed + no pending jobs).
        if (batch.pending == 0 and !batch.open) {
            batch.completed_at_ns = now_ns;

            // Fire callback if configured.
            if (batch.callback_queue) |cq| {
                if (cq.len > 0) {
                    var id_buf: [64]u8 = undefined;
                    const cb_id = std.fmt.bufPrint(&id_buf, "batch_cb_{s}", .{batch_id}) catch "batch_cb_err";
                    const cb_job = ops.EnqueueJob{
                        .job_id = cb_id,
                        .queue = cq,
                        .payload = batch.callback_payload,
                        .state = .pending,
                        .priority = types.priority_normal,
                        .created_at_ns = now_ns,
                    };
                    const jobs = [_]ops.EnqueueJob{cb_job};
                    const enqueue_op = ops.EnqueueOp{
                        .jobs = &jobs,
                        .now_ns = now_ns,
                    };
                    _ = self.applyEnqueue(b, &enqueue_op);
                }
            }
        }

        var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
        b.set(bkey, codec.encodeBatch(&batch_enc_buf, &batch));
    }
};

// ============================================================================
// Backoff calculation (ported from Go store/backoff.go)
// ============================================================================

/// Calculate retry delay in nanoseconds.
pub fn calculateBackoffNs(strategy: types.Backoff, attempt: u16, base_delay_ms: u32, max_delay_ms: u32) u64 {
    const delay_ms: u64 = switch (strategy) {
        .none => 0,
        .fixed => base_delay_ms,
        .linear => @as(u64, base_delay_ms) * @as(u64, attempt),
        .exponential => blk: {
            const exp: u6 = if (attempt > 0) @intCast(@min(attempt - 1, 63)) else 0;
            break :blk @as(u64, base_delay_ms) * (@as(u64, 1) << exp);
        },
    };

    const clamped = if (max_delay_ms > 0 and delay_ms > max_delay_ms) max_delay_ms else delay_ms;
    return @as(u64, clamped) * 1_000_000; // ms → ns
}

// ============================================================================
// Utility
// ============================================================================

/// Extract job ID from pending key: p|{queue}\x00{priority:1}{createdNs:8BE}{jobID}
pub fn getJobIDFromPendingKey(queue: []const u8, key: []const u8) []const u8 {
    const prefix_len = keys.prefix_pending.len + queue.len + 1; // "p|" + queue + \x00
    const id_offset = prefix_len + 1 + 8; // priority(1) + createdNs(8)
    assert.check(key.len > id_offset, "invalid pending key length", .{});
    return key[id_offset..];
}

/// Extract job ID from active key: a|{queue}\x00{jobID}
pub fn getJobIDFromActiveKey(queue: []const u8, key: []const u8) []const u8 {
    const prefix_len = keys.prefix_active.len + queue.len + 1;
    assert.check(key.len > prefix_len, "invalid active key length", .{});
    return key[prefix_len..];
}

/// Extract job ID from time-sorted key (scheduled/retrying): prefix|{queue}\x00{ns:8BE}{jobID}
pub fn getJobIDFromTimeSortedKey(prefix_len: usize, key: []const u8) []const u8 {
    const id_offset = prefix_len + 8; // ns(8)
    assert.check(key.len > id_offset, "invalid time-sorted key length", .{});
    return key[id_offset..];
}

test "calculateBackoffNs" {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 0), calculateBackoffNs(.none, 1, 1000, 0));
    try testing.expectEqual(@as(u64, 1000 * 1_000_000), calculateBackoffNs(.fixed, 1, 1000, 0));
    try testing.expectEqual(@as(u64, 3000 * 1_000_000), calculateBackoffNs(.linear, 3, 1000, 0));
    try testing.expectEqual(@as(u64, 4000 * 1_000_000), calculateBackoffNs(.exponential, 3, 1000, 0));
    // Clamped
    try testing.expectEqual(@as(u64, 5000 * 1_000_000), calculateBackoffNs(.exponential, 10, 1000, 5000));
}
