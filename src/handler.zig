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
const indexer_mod = @import("indexer.zig");
pub const metrics_mod = @import("metrics.zig");

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
    /// Deferred read-index writer. Hot-path handlers record effects here;
    /// pipeline flushes them in a separate KV batch after the main commit.
    indexer: indexer_mod.Indexer = .{},
    /// Whether to verify index consistency after each mutation.
    verify_indexes: bool = false,
    /// Monotonic counter for lease tokens. Unique per fetch claim.
    lease_counter: u64 = 0,
    requeue_counter: u64 = 0,
    // Effect buffers — accumulated during apply, drained by pipeline after commit.
    side_effect_count: u8 = 0, // kept for pipeline.resetEffects compat
    /// Per-tick maintenance work units. Reclaim/expire/promote increment this
    /// and stop once it reaches max_bulk_results so a single tick cannot stall
    /// the pipeline thread with an unbounded scan. Saturating — never asserts.
    bulk_result_count: u16 = 0,
    cancel_signals: [max_cancel_signals]CancelSignal = undefined,
    cancel_signal_count: u16 = 0,

    // Webhook events — accumulated during apply, drained by pipeline after commit.
    webhook_events: [max_webhook_events]WebhookEvent = undefined,
    webhook_event_count: u16 = 0,

    // Webhook config cache — bounded, loaded from KV on warmup, updated on create/delete.
    webhook_cache: [max_webhooks]WebhookCached = undefined,
    webhook_cache_count: u8 = 0,

    // Promote/reclaim notification: queues that had jobs promoted to pending.
    promote_queue_bufs: [max_promote_queues][64]u8 = undefined,
    promote_queue_lens: [max_promote_queues]u8 = [_]u8{0} ** max_promote_queues,
    promote_queue_slices: [max_promote_queues][]const u8 = undefined,
    promote_queue_count: u16 = 0,
    /// Allocator for handler-owned state (maps, etc).
    allocator: Allocator,

    /// Terminal jobs created since last purge. Incremented when a d| key
    /// is written (ack/fail/reclaim/expire/bulk). Pipeline uses this to
    /// trigger purge early when count exceeds purge_threshold.
    dead_since_purge: u32 = 0,

    /// Performance metrics (latency histograms + throughput counters).
    metrics: metrics_mod.ServerMetrics = .{},

    /// Maximum rate window across all queues/global rate limits.
    /// Used by maintenance to compute correct cleanup cutoff.
    max_rate_window_ns: u64 = 0,

    /// Global rate limit (0 = unlimited). Set via POST /api/v1/throttle.
    global_rate_limit: u32 = 0,
    global_rate_window_ms: u32 = 0,

    // Explicit resource limits (TigerStyle: all collections must have bounds).
    max_queues: u32 = 100,
    max_jobs: u32 = 0, // 0 = unlimited
    max_tags_per_queue: u32 = 1000,
    persist_completed: bool = false,

    /// Total live jobs in KV. Incremented on enqueue, decremented on purge.
    total_jobs: u32 = 0,

    const max_side_effects = 32;
    pub const max_bulk_results = 4096;
    const max_cancel_signals = 256;
    const max_webhook_events = 256;
    pub const max_webhooks = 64;
    // One bounded RPC can create/requeue/callback into 256 distinct queues.
    // Preserve every destination so no subscribed queue is silently skipped.
    const max_promote_queues = @import("rpc.zig").MAX_BATCH_JOBS;

    pub const CancelSignal = struct {
        job_id: [64]u8 = undefined,
        job_id_len: u8 = 0,
        worker_id: [128]u8 = undefined,
        worker_id_len: u8 = 0,

        pub fn jobId(self: *const CancelSignal) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        pub fn workerId(self: *const CancelSignal) []const u8 {
            return self.worker_id[0..self.worker_id_len];
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

    pub const WebhookEvent = struct {
        pub const EventType = enum(u8) { completed = 1, failed = 2, dead = 3 };

        job_id: [128]u8 = undefined,
        job_id_len: u8 = 0,
        queue: [64]u8 = undefined,
        queue_len: u8 = 0,
        webhook_url: [512]u8 = undefined,
        webhook_url_len: u16 = 0,
        webhook_id: [64]u8 = undefined,
        webhook_id_len: u8 = 0,
        event: EventType = .completed,
        now_ns: u64 = 0,

        pub fn jobId(self: *const WebhookEvent) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        pub fn queueSlice(self: *const WebhookEvent) []const u8 {
            return self.queue[0..self.queue_len];
        }
        pub fn urlSlice(self: *const WebhookEvent) []const u8 {
            return self.webhook_url[0..self.webhook_url_len];
        }
        pub fn webhookIdSlice(self: *const WebhookEvent) []const u8 {
            return self.webhook_id[0..self.webhook_id_len];
        }
        pub fn eventName(self: *const WebhookEvent) []const u8 {
            return switch (self.event) {
                .completed => "job.completed",
                .failed => "job.failed",
                .dead => "job.dead",
            };
        }
    };

    pub const WebhookCached = struct {
        id: [64]u8 = undefined,
        id_len: u8 = 0,
        url: [512]u8 = undefined,
        url_len: u16 = 0,
        queue_filter: [64]u8 = undefined,
        queue_filter_len: u8 = 0,
        on_completed: bool = false,
        on_failed: bool = false,
        on_dead: bool = false,
        enabled: bool = true,

        pub fn idSlice(self: *const WebhookCached) []const u8 {
            return self.id[0..self.id_len];
        }
        pub fn urlSlice(self: *const WebhookCached) []const u8 {
            return self.url[0..self.url_len];
        }
        pub fn queueFilterSlice(self: *const WebhookCached) []const u8 {
            return self.queue_filter[0..self.queue_filter_len];
        }
        pub fn matchesQueue(self: *const WebhookCached, queue: []const u8) bool {
            const filter = self.queueFilterSlice();
            if (filter.len == 0 or std.mem.eql(u8, filter, "*")) return true;
            return std.mem.eql(u8, filter, queue);
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

        // Clear fairness maps (nested hashmaps — free outer keys + inner maps).
        {
            var it = self.fairness_active.iterator();
            while (it.next()) |entry| {
                self.allocator.free(@constCast(entry.key_ptr.*));
                var inner_it = entry.value_ptr.iterator();
                while (inner_it.next()) |ie| self.allocator.free(@constCast(ie.key_ptr.*));
                entry.value_ptr.deinit();
            }
            self.fairness_active.clearRetainingCapacity();
        }
        {
            var it = self.fairness_served.iterator();
            while (it.next()) |entry| {
                self.allocator.free(@constCast(entry.key_ptr.*));
                var inner_it = entry.value_ptr.iterator();
                while (inner_it.next()) |ie| self.allocator.free(@constCast(ie.key_ptr.*));
                entry.value_ptr.deinit();
            }
            self.fairness_served.clearRetainingCapacity();
        }

        // Reset global config.
        self.global_rate_limit = 0;
        self.global_rate_window_ms = 0;
        self.max_rate_window_ns = 0;
    }

    /// Rebuild in-memory state from KV after restart.
    /// Single pass over all j| keys to populate:
    ///   - PendingIndex (pending jobs for fetch)
    ///   - active_counts (for concurrency limits)
    ///   - queue_configs (cached queue settings)
    pub fn rebuildState(self: *OpHandler, shards: []kv.Store) void {
        self.lease_counter = 0;
        var pending_count: u32 = 0;
        var active_count: u32 = 0;
        var total_count: u32 = 0;

        for (shards) |*shard| {
            var batch = shard.newBatch();
            defer batch.close();

            // Lease tokens fence stale workers. Persisting and restoring the
            // sequence is essential across restart and leader promotion: if a
            // new leader restarted at token 1, an old worker's token 1 could
            // acknowledge the NEW worker's lease for the same job.
            if (batch.get(keys.key_lease_counter)) |counter_bytes| {
                if (counter_bytes.len == 8) {
                    self.lease_counter = @max(self.lease_counter, keys.getU64BE(counter_bytes));
                }
            }

            // Scan all j| keys.
            var jp_buf: keys.KeyBuf = undefined;
            var jpe_buf: keys.KeyBuf = undefined;
            const jp = keys.prefix_job;
            @memcpy(jp_buf[0..jp.len], jp);
            const end = keys.prefixEnd(&jpe_buf, jp_buf[0..jp.len]) orelse continue;

            var iter = batch.newIter(jp_buf[0..jp.len], end);
            defer iter.close();

            if (iter.first()) {
                while (true) {
                    const val = iter.value();
                    const job = codec.decodeJob(val);
                    // Backward-compatible recovery for databases created before
                    // g|lease existed. Reclaimed pending jobs retain their last
                    // token, so scanning headers preserves the fence on upgrade.
                    self.lease_counter = @max(self.lease_counter, job.lease_token);
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
                        .retrying, .completed, .dead, .cancelled, .scheduled, .held => {},
                    }

                    if (!iter.next()) break;
                }
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

            // Load global config from g|rl key.
            {
                var gc_buf: keys.KeyBuf = undefined;
                const gc_key = keys.globalConfigKey(&gc_buf);
                if (batch.get(gc_key)) |gc_val| {
                    if (gc_val.len >= 8) {
                        self.global_rate_limit = std.mem.readInt(u32, gc_val[0..4], .little);
                        self.global_rate_window_ms = std.mem.readInt(u32, gc_val[4..8], .little);
                    }
                }
            }
        }

        self.total_jobs = total_count;
        self.recomputeMaxRateWindow();
        std.debug.print("corvo: state ready — {d} jobs ({d} pending, {d} active)\n", .{ total_count, pending_count, active_count });
    }

    /// Allocate and durably record the next lease fencing token in the same
    /// batch as the job claim. The singleton mutation is replicated through
    /// Raft, so a promoted follower always starts above every issued token.
    pub fn nextLeaseToken(self: *OpHandler, b: *kv.WriteBatch) u64 {
        assert.check(self.lease_counter < std.math.maxInt(u64), "lease token space exhausted", .{});
        self.lease_counter += 1;
        var encoded: [8]u8 = undefined;
        std.mem.writeInt(u64, &encoded, self.lease_counter, .big);
        b.set(keys.key_lease_counter, &encoded);
        return self.lease_counter;
    }

    // ========================================================================
    // Effect buffer methods — pipeline drains these after commit
    // ========================================================================

    pub fn resetEffects(self: *OpHandler) void {
        self.side_effect_count = 0;
        self.bulk_result_count = 0;
        self.cancel_signal_count = 0;
        self.webhook_event_count = 0;
        self.promote_queue_count = 0;
        self.indexer.reset();
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

    /// No-op — mirror removed. Side effects were only consumed by mirror_events.
    pub fn recordSideEffect(_: *OpHandler, _: *const ops.EnqueueJob) void {}

    /// No-op — mirror removed. Fail results were only consumed by mirror_events.
    /// Kept as a call site so handler_fail stays readable; carries no state.
    pub fn recordFailResult(_: *OpHandler, _: []const u8, _: []const u8, _: ?[]const u8, _: types.JobState, _: u16, _: u64, _: u64) void {}

    /// Count one unit of maintenance/bulk work this tick. The stored result set
    /// was only consumed by the removed mirror; today this is purely the
    /// per-tick work cap read by reclaim/expire/promote. Saturating so a burst
    /// of client bulk ops in one tick can never overflow or panic.
    pub fn recordBulkResult(self: *OpHandler, _: []const u8, _: BulkResult.ActionType, _: []const u8, _: []const u8, _: u64) void {
        self.bulk_result_count +|= 1;
    }

    pub fn recordCancelSignal(self: *OpHandler, job_id: []const u8, worker_id: []const u8) void {
        if (self.cancel_signal_count >= max_cancel_signals) return;
        var sig = CancelSignal{};
        const il: u8 = @intCast(@min(job_id.len, sig.job_id.len));
        @memcpy(sig.job_id[0..il], job_id[0..il]);
        sig.job_id_len = il;
        const wl: u8 = @intCast(@min(worker_id.len, sig.worker_id.len));
        @memcpy(sig.worker_id[0..wl], worker_id[0..wl]);
        sig.worker_id_len = wl;
        self.cancel_signals[self.cancel_signal_count] = sig;
        self.cancel_signal_count += 1;
    }

    pub fn recordWebhookEvent(
        self: *OpHandler,
        job_id: []const u8,
        queue: []const u8,
        event: WebhookEvent.EventType,
        webhook_id: []const u8,
        webhook_url: []const u8,
        now_ns: u64,
    ) void {
        if (self.webhook_event_count >= max_webhook_events) return;
        var ev = WebhookEvent{};
        const jl: u8 = @intCast(@min(job_id.len, ev.job_id.len));
        @memcpy(ev.job_id[0..jl], job_id[0..jl]);
        ev.job_id_len = jl;
        const ql: u8 = @intCast(@min(queue.len, ev.queue.len));
        @memcpy(ev.queue[0..ql], queue[0..ql]);
        ev.queue_len = ql;
        const ul: u16 = @intCast(@min(webhook_url.len, ev.webhook_url.len));
        @memcpy(ev.webhook_url[0..ul], webhook_url[0..ul]);
        ev.webhook_url_len = ul;
        const wl: u8 = @intCast(@min(webhook_id.len, ev.webhook_id.len));
        @memcpy(ev.webhook_id[0..wl], webhook_id[0..wl]);
        ev.webhook_id_len = wl;
        ev.event = event;
        ev.now_ns = now_ns;
        self.webhook_events[self.webhook_event_count] = ev;
        self.webhook_event_count += 1;
    }

    /// Check webhook cache and record events for matching webhooks.
    /// Writes whd| delivery records to the batch (atomic with state transition)
    /// and records events in the effect buffer (for pipeline awareness).
    pub fn checkWebhooks(self: *OpHandler, job_id: []const u8, queue: []const u8, event: WebhookEvent.EventType, now_ns: u64) void {
        for (self.webhook_cache[0..self.webhook_cache_count]) |*wh| {
            if (!wh.enabled) continue;
            if (!wh.matchesQueue(queue)) continue;
            const matches = switch (event) {
                .completed => wh.on_completed,
                .failed => wh.on_failed,
                .dead => wh.on_dead,
            };
            if (!matches) continue;
            self.recordWebhookEvent(job_id, queue, event, wh.idSlice(), wh.urlSlice(), now_ns);
        }
    }

    /// Load webhook cache from KV. Called on warmup.
    pub fn loadWebhookCache(self: *OpHandler, b: *kv.WriteBatch) void {
        self.webhook_cache_count = 0;
        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        @memcpy(lower_buf[0..keys.prefix_webhook.len], keys.prefix_webhook);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..keys.prefix_webhook.len]) orelse return;

        var iter = b.newIter(lower_buf[0..keys.prefix_webhook.len], upper);
        defer iter.close();

        if (!iter.first()) return;
        while (true) {
            if (self.webhook_cache_count >= max_webhooks) break;
            self.webhook_cache[self.webhook_cache_count] = webhookValueToCached(iter.value());
            self.webhook_cache_count += 1;
            if (!iter.next()) break;
        }
    }

    /// Add or update a webhook in the cache.
    pub fn addWebhookToCache(self: *OpHandler, val: []const u8) void {
        const entry = webhookValueToCached(val);
        const new_id = entry.idSlice();
        // Update existing entry if same ID.
        for (self.webhook_cache[0..self.webhook_cache_count]) |*wh| {
            if (std.mem.eql(u8, wh.idSlice(), new_id)) {
                wh.* = entry;
                return;
            }
        }
        if (self.webhook_cache_count >= max_webhooks) return;
        self.webhook_cache[self.webhook_cache_count] = entry;
        self.webhook_cache_count += 1;
    }

    /// Remove a webhook from the cache by ID.
    pub fn removeWebhookFromCache(self: *OpHandler, webhook_id: []const u8) void {
        var i: u8 = 0;
        while (i < self.webhook_cache_count) {
            if (std.mem.eql(u8, self.webhook_cache[i].idSlice(), webhook_id)) {
                // Swap with last and shrink.
                self.webhook_cache_count -= 1;
                if (i < self.webhook_cache_count) {
                    self.webhook_cache[i] = self.webhook_cache[self.webhook_cache_count];
                }
                return;
            }
            i += 1;
        }
    }

    /// Public JSON string extractor for cross-module use (pipeline webhook dispatch).
    pub fn jsonStrPub(body: []const u8, key: []const u8) ?[]const u8 {
        return jsonStr(body, key);
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
            .modify_setting => self.applyModifySetting(b, &data.modify_setting),
            .cron_create => self.applyCreateCron(b, &data.cron_create),
            .cron_update => self.applyUpdateCron(b, &data.cron_update),
            .cron_delete => self.applyDeleteCron(b, &data.cron_delete),
            .cron_trigger => self.applyTriggerCron(b, &data.cron_trigger),
            .set_budget => self.applySetBudget(b, &data.set_budget),
            .delete_budget => self.applyDeleteBudget(b, &data.delete_budget),
            .global_config => self.applyGlobalConfig(b, &data.global_config),
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
            assert.check(self.active_counts.count() <= self.max_queues + 1, "incrActiveCount: queue count ({d}) exceeds max_queues ({d})", .{ self.active_counts.count(), self.max_queues });
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
            assert.check(self.fairness_active.count() <= self.max_queues + 1, "incrFairnessActive: queue count exceeds max_queues", .{});
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
                assert.check(count.* > 0, "decrFairnessActive: underflow for queue={s} group={s}", .{ queue, group });
                count.* -= 1;
            }
        }
    }

    pub fn incrFairnessServed(self: *OpHandler, queue: []const u8, group: []const u8) void {
        if (group.len == 0) return;
        const qmap = self.fairness_served.getOrPut(queue) catch unreachable;
        if (!qmap.found_existing) {
            assert.check(self.fairness_served.count() <= self.max_queues + 1, "incrFairnessServed: queue count exceeds max_queues", .{});
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
        // Return from cache — putQueueConfig fixes up the name slice to
        // point at the owned HashMap key. The local `queue` has name
        // pointing into qc_val_buf which dies when this function returns.
        return self.queue_configs.get(queue_name);
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
        // Fix up name to point at the owned HashMap key — the original
        // queue.name slice points into transient memory (frame payload,
        // stack decode buffer, KV iterator) that becomes dangling after
        // the calling function returns.
        entry.value_ptr.*.name = entry.key_ptr.*;
        return true;
    }

    /// Remove from cache (on queue delete).
    pub fn removeQueueConfig(self: *OpHandler, queue_name: []const u8) void {
        if (self.queue_configs.fetchRemove(queue_name)) |entry| {
            self.allocator.free(@constCast(entry.key));
        }
    }

    /// Recompute max_rate_window_ns from all rate limit sources.
    /// Called when any queue throttle or global config changes.
    pub fn recomputeMaxRateWindow(self: *OpHandler) void {
        var max_ms: u32 = self.global_rate_window_ms;
        var it = self.queue_configs.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.rate_window_ms > max_ms) max_ms = entry.value_ptr.rate_window_ms;
        }
        self.max_rate_window_ns = @as(u64, max_ms) * 1_000_000;
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
    // Read Index Maintenance
    // ========================================================================

    /// Write all read indexes for a newly created job.
    pub fn writeReadIndexes(b: *kv.WriteBatch, job: *const types.Job) void {
        var jt_buf: keys.KeyBuf = undefined;
        var jq_buf: keys.KeyBuf = undefined;
        var js_buf: keys.KeyBuf = undefined;
        var jqs_buf: keys.KeyBuf = undefined;
        const state_byte = @intFromEnum(job.state);

        b.set(keys.jobTimeKey(&jt_buf, job.created_at_ns, job.id), "");
        b.set(keys.jobQueueKey(&jq_buf, job.queue, job.created_at_ns, job.id), "");
        b.set(keys.jobStateKey(&js_buf, state_byte, job.created_at_ns, job.id), "");
        b.set(keys.jobQueueStateKey(&jqs_buf, job.queue, state_byte, job.created_at_ns, job.id), "");
    }

    /// Delete all read indexes for a purged job.
    pub fn deleteReadIndexes(b: *kv.WriteBatch, job: *const types.Job) void {
        var jt_buf: keys.KeyBuf = undefined;
        var jq_buf: keys.KeyBuf = undefined;
        var js_buf: keys.KeyBuf = undefined;
        var jqs_buf: keys.KeyBuf = undefined;
        const state_byte = @intFromEnum(job.state);

        b.delete(keys.jobTimeKey(&jt_buf, job.created_at_ns, job.id));
        b.delete(keys.jobQueueKey(&jq_buf, job.queue, job.created_at_ns, job.id));
        b.delete(keys.jobStateKey(&js_buf, state_byte, job.created_at_ns, job.id));
        b.delete(keys.jobQueueStateKey(&jqs_buf, job.queue, state_byte, job.created_at_ns, job.id));
    }

    /// Delete queue-specific read indexes for a job under a given queue.
    /// Used by bulk move to clean up old queue's indexes before writing new ones.
    pub fn deleteQueueReadIndexes(b: *kv.WriteBatch, queue: []const u8, job: *const types.Job) void {
        var jq_buf: keys.KeyBuf = undefined;
        var jqs_buf: keys.KeyBuf = undefined;
        const state_byte = @intFromEnum(job.state);
        b.delete(keys.jobQueueKey(&jq_buf, queue, job.created_at_ns, job.id));
        b.delete(keys.jobQueueStateKey(&jqs_buf, queue, state_byte, job.created_at_ns, job.id));
    }

    /// Write queue-specific read indexes for a job (using job.queue).
    /// Used by bulk move to write new queue's indexes after updating job.queue.
    pub fn writeQueueReadIndexes(b: *kv.WriteBatch, job: *const types.Job) void {
        var jq_buf: keys.KeyBuf = undefined;
        var jqs_buf: keys.KeyBuf = undefined;
        const state_byte = @intFromEnum(job.state);
        b.set(keys.jobQueueKey(&jq_buf, job.queue, job.created_at_ns, job.id), "");
        b.set(keys.jobQueueStateKey(&jqs_buf, job.queue, state_byte, job.created_at_ns, job.id), "");
    }

    /// Update read indexes when a job transitions state.
    /// Deletes old state entries, writes new state entries, updates queue counters.
    pub fn transitionReadIndexes(self: *OpHandler, b: *kv.WriteBatch, job: *const types.Job, old_state: types.JobState, new_state: types.JobState) void {
        const old_byte = @intFromEnum(old_state);
        const new_byte = @intFromEnum(new_state);

        // Delete old state-dependent indexes
        var old_js_buf: keys.KeyBuf = undefined;
        var old_jqs_buf: keys.KeyBuf = undefined;
        b.delete(keys.jobStateKey(&old_js_buf, old_byte, job.created_at_ns, job.id));
        b.delete(keys.jobQueueStateKey(&old_jqs_buf, job.queue, old_byte, job.created_at_ns, job.id));

        // Write new state-dependent indexes
        var new_js_buf: keys.KeyBuf = undefined;
        var new_jqs_buf: keys.KeyBuf = undefined;
        b.set(keys.jobStateKey(&new_js_buf, new_byte, job.created_at_ns, job.id), "");
        b.set(keys.jobQueueStateKey(&new_jqs_buf, job.queue, new_byte, job.created_at_ns, job.id), "");

        // Update queue counters
        self.updateQueueCounter(b, job.queue, old_state, new_state);
    }

    /// Write tag index entries for a job. Parses JSON object tags.
    /// Index key: tq|{tag_key}\x00{tag_value}\x00{queue}\x00{job_id}
    pub fn writeTagIndexes(b: *kv.WriteBatch, job: *const types.Job) void {
        const tag_str = job.tags orelse return;
        if (tag_str.len < 2) return;

        // Parse simple JSON object: {"key":"value","key2":"value2"}
        var pos: usize = 0;
        while (pos < tag_str.len) {
            // Find key
            const k_start = std.mem.indexOfScalarPos(u8, tag_str, pos, '"') orelse break;
            const k_end = std.mem.indexOfScalarPos(u8, tag_str, k_start + 1, '"') orelse break;
            const tag_key = tag_str[k_start + 1 .. k_end];

            // Find value — skip colon
            const colon = std.mem.indexOfScalarPos(u8, tag_str, k_end + 1, ':') orelse break;
            const v_start = std.mem.indexOfScalarPos(u8, tag_str, colon + 1, '"') orelse break;
            const v_end = std.mem.indexOfScalarPos(u8, tag_str, v_start + 1, '"') orelse break;
            const tag_value = tag_str[v_start + 1 .. v_end];

            var tq_buf: keys.KeyBuf = undefined;
            b.set(keys.tagQueueKey(&tq_buf, job.queue, tag_key, tag_value, job.id), "");

            pos = v_end + 1;
        }
    }

    /// Delete tag index entries for a job (mirror of writeTagIndexes).
    /// Uses job.queue for the queue segment — caller must ensure queue is correct
    /// (i.e. call BEFORE changing job.queue during moves).
    pub fn deleteTagIndexes(b: *kv.WriteBatch, job: *const types.Job) void {
        const tag_str = job.tags orelse return;
        if (tag_str.len < 2) return;

        var pos: usize = 0;
        while (pos < tag_str.len) {
            const k_start = std.mem.indexOfScalarPos(u8, tag_str, pos, '"') orelse break;
            const k_end = std.mem.indexOfScalarPos(u8, tag_str, k_start + 1, '"') orelse break;
            const tag_key = tag_str[k_start + 1 .. k_end];

            const colon = std.mem.indexOfScalarPos(u8, tag_str, k_end + 1, ':') orelse break;
            const v_start = std.mem.indexOfScalarPos(u8, tag_str, colon + 1, '"') orelse break;
            const v_end = std.mem.indexOfScalarPos(u8, tag_str, v_start + 1, '"') orelse break;
            const tag_value = tag_str[v_start + 1 .. v_end];

            var tq_buf: keys.KeyBuf = undefined;
            b.delete(keys.tagQueueKey(&tq_buf, job.queue, tag_key, tag_value, job.id));

            pos = v_end + 1;
        }
    }

    /// Increment counter for new_state, decrement for old_state on a queue.
    /// Updates KV from the batch overlay and in-memory cache independently.
    /// The KV path reads from the batch (which may lag behind the cache when
    /// indexer deltas are still deferred), so we must NOT putQueueConfig here —
    /// that would overwrite in-memory deltas from the same batch.
    fn updateQueueCounter(self: *OpHandler, b: *kv.WriteBatch, queue: []const u8, old_state: types.JobState, new_state: types.JobState) void {
        var qc_buf: keys.KeyBuf = undefined;
        var qc_val_buf: [codec.max_queue_encoded_size]u8 = undefined;
        const qc_key = keys.queueConfigKey(&qc_buf, queue);
        const qc_bytes = b.getInto(qc_key, &qc_val_buf) orelse return;
        var q = codec.decodeQueue(qc_bytes);
        q.decrState(old_state);
        q.incrState(new_state);
        var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
        b.set(qc_key, codec.encodeQueue(&qc_enc_buf, &q));
        self.updateQueueCounterMem(queue, old_state, new_state);
    }

    /// Increment a single state counter on a queue (for enqueue).
    pub fn incrQueueCounter(self: *OpHandler, b: *kv.WriteBatch, queue: []const u8, state: types.JobState) void {
        var qc_buf: keys.KeyBuf = undefined;
        var qc_val_buf: [codec.max_queue_encoded_size]u8 = undefined;
        const qc_key = keys.queueConfigKey(&qc_buf, queue);
        const qc_bytes = b.getInto(qc_key, &qc_val_buf) orelse return;
        var q = codec.decodeQueue(qc_bytes);
        q.incrState(state);
        var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
        b.set(qc_key, codec.encodeQueue(&qc_enc_buf, &q));
        self.incrQueueCounterMem(queue, state);
    }

    /// Decrement a single state counter on a queue (for purge).
    pub fn decrQueueCounter(self: *OpHandler, b: *kv.WriteBatch, queue: []const u8, state: types.JobState) void {
        var qc_buf: keys.KeyBuf = undefined;
        var qc_val_buf: [codec.max_queue_encoded_size]u8 = undefined;
        const qc_key = keys.queueConfigKey(&qc_buf, queue);
        const qc_bytes = b.getInto(qc_key, &qc_val_buf) orelse return;
        var q = codec.decodeQueue(qc_bytes);
        q.decrState(state);
        var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
        b.set(qc_key, codec.encodeQueue(&qc_enc_buf, &q));
        self.decrQueueCounterMem(queue, state);
    }

    /// In-memory-only counter increment. KV write deferred to indexer.
    pub fn incrQueueCounterMem(self: *OpHandler, queue: []const u8, state: types.JobState) void {
        if (self.queue_configs.getPtr(queue)) |q| {
            q.incrState(state);
        }
    }

    /// In-memory-only counter decrement. KV write deferred to indexer.
    pub fn decrQueueCounterMem(self: *OpHandler, queue: []const u8, state: types.JobState) void {
        if (self.queue_configs.getPtr(queue)) |q| {
            q.decrState(state);
        }
    }

    /// In-memory-only counter transition. KV write deferred to indexer.
    pub fn updateQueueCounterMem(self: *OpHandler, queue: []const u8, old_state: types.JobState, new_state: types.JobState) void {
        if (self.queue_configs.getPtr(queue)) |q| {
            q.decrState(old_state);
            q.incrState(new_state);
        }
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

    // Settings
    pub const applyModifySetting = @import("handler_settings.zig").applyModifySetting;
    pub const writeAuditEntry = @import("handler_settings.zig").writeAuditEntry;

    // Global config
    pub fn applyGlobalConfig(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.GlobalConfigOp) ops.OpResult {
        self.global_rate_limit = op.rate_limit;
        self.global_rate_window_ms = op.rate_window_ms;

        var key_buf: keys.KeyBuf = undefined;
        const key = keys.globalConfigKey(&key_buf);
        if (op.rate_limit > 0) {
            var val_buf: [8]u8 = undefined;
            std.mem.writeInt(u32, val_buf[0..4], op.rate_limit, .little);
            std.mem.writeInt(u32, val_buf[4..8], op.rate_window_ms, .little);
            b.set(key, &val_buf);
        } else {
            b.delete(key);
        }

        self.recomputeMaxRateWindow();
        return .{ .affected = 1 };
    }

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
            if (self.enqueueBatchCallback(b, &batch, now_ns)) batch.completed_at_ns = now_ns;
        }

        var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
        b.set(bkey, codec.encodeBatch(&batch_enc_buf, &batch));
    }

    /// Enqueue a completed batch's callback in the caller's atomic KV batch.
    /// False leaves completed_at_ns unset so an explicit seal retry can recover
    /// from resource pressure instead of recording success with no callback.
    pub fn enqueueBatchCallback(self: *OpHandler, b: *kv.WriteBatch, batch: *const types.Batch, now_ns: u64) bool {
        const queue = batch.callback_queue orelse return true;
        if (queue.len == 0) return true;

        var id_buf: [64]u8 = undefined;
        const callback_id = resolveBatchCallbackId(b, &id_buf, batch.id) orelse return false;
        const callback_job = ops.EnqueueJob{
            .job_id = callback_id,
            .queue = queue,
            .payload = batch.callback_payload,
            .state = .pending,
            .priority = types.priority_normal,
            .created_at_ns = now_ns,
        };
        const jobs = [_]ops.EnqueueJob{callback_job};
        const enqueue_op = ops.EnqueueOp{ .jobs = &jobs, .now_ns = now_ns };
        const result = self.applyEnqueue(b, &enqueue_op);
        if (result.err != null) return false;
        self.recordPromoteQueue(queue);
        return true;
    }
};

// ============================================================================
// Backoff calculation (ported from Go store/backoff.go)
// ============================================================================

/// Calculate retry delay in nanoseconds.
pub fn calculateBackoffNs(strategy: types.Backoff, attempt: u16, base_delay_ms: u32, max_delay_ms: u32) u64 {
    // Saturating arithmetic throughout: with max_retries up to 65535, a naive
    // exponential (base << exp) or the ms→ns multiply overflows u64 and panics
    // in ReleaseSafe. Large delays saturate to the ceiling instead.
    const delay_ms: u64 = switch (strategy) {
        .none => 0,
        .fixed => base_delay_ms,
        .linear => @as(u64, base_delay_ms) *| @as(u64, attempt),
        .exponential => blk: {
            const exp: u6 = if (attempt > 0) @intCast(@min(attempt - 1, 63)) else 0;
            break :blk @as(u64, base_delay_ms) *| (@as(u64, 1) << exp);
        },
    };

    // Clamp to max_delay_ms (when set), then to the largest value that still
    // fits u64 after the ms→ns multiply.
    const max_ms_before_ns: u64 = std.math.maxInt(u64) / 1_000_000;
    var clamped = delay_ms;
    if (max_delay_ms > 0 and clamped > max_delay_ms) clamped = max_delay_ms;
    if (clamped > max_ms_before_ns) clamped = max_ms_before_ns;
    return clamped * 1_000_000; // ms → ns
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

/// Resolve a deterministic ID for a generated chain child without trusting a
/// client-reservable namespace. The legacy readable ID is tried first for
/// compatibility; on collision (or a long parent ID), bounded hash-derived
/// alternatives are used. Replaying the same transition recognizes the
/// existing logical child and returns `.existing`, preserving idempotency.
pub const ChainChildId = union(enum) {
    available: []const u8,
    existing,
    exhausted,
};

pub fn resolveChainChildId(
    b: *kv.WriteBatch,
    out: *[64]u8,
    parent_id: []const u8,
    chain_id: ?[]const u8,
    chain_step: u16,
) ChainChildId {
    var attempt: u16 = 0;
    while (attempt < 256) : (attempt += 1) {
        const candidate = if (attempt == 0)
            std.fmt.bufPrint(out, "chain_{s}_{d}", .{ parent_id, chain_step }) catch continue
        else blk: {
            const hash = std.hash.Wyhash.hash(attempt, parent_id);
            break :blk std.fmt.bufPrint(out, "chain_{x:0>16}_{x:0>4}_{x:0>2}", .{ hash, chain_step, attempt }) catch
                return .exhausted;
        };

        var jk: keys.KeyBuf = undefined;
        const existing_bytes = b.get(keys.jobKey(&jk, candidate)) orelse
            return .{ .available = candidate };
        const existing = codec.decodeJob(existing_bytes);
        if (existing.chain_step == chain_step and
            optionalEql(existing.parent_id, parent_id) and
            optionalOptionalEql(existing.chain_id, chain_id))
        {
            return .existing;
        }
    }
    return .exhausted;
}

/// Generated callbacks and cron fires share the user-visible job ID namespace.
/// Probe bounded hash-derived alternatives so a user-created collision cannot
/// suppress an internal side effect, and long entity IDs still produce legal
/// 64-byte job IDs.
pub fn resolveBatchCallbackId(b: *kv.WriteBatch, out: *[64]u8, batch_id: []const u8) ?[]const u8 {
    var attempt: u16 = 0;
    while (attempt < 256) : (attempt += 1) {
        const candidate = if (attempt == 0)
            std.fmt.bufPrint(out, "batch_cb_{s}", .{batch_id}) catch continue
        else blk: {
            const hash = std.hash.Wyhash.hash(attempt, batch_id);
            break :blk std.fmt.bufPrint(out, "batch_cb_{x:0>16}_{x:0>2}", .{ hash, attempt }) catch return null;
        };
        var jk: keys.KeyBuf = undefined;
        if (b.get(keys.jobKey(&jk, candidate)) == null) return candidate;
    }
    return null;
}

pub fn resolveCronFireId(b: *kv.WriteBatch, out: *[64]u8, cron_id: []const u8, fire_slot: u64) ?[]const u8 {
    var attempt: u16 = 0;
    while (attempt < 256) : (attempt += 1) {
        const candidate = if (attempt == 0)
            std.fmt.bufPrint(out, "{s}-{d}", .{ cron_id, fire_slot }) catch continue
        else blk: {
            var seed_buf: [96]u8 = undefined;
            const seed = std.fmt.bufPrint(&seed_buf, "{s}-{d}", .{ cron_id, fire_slot }) catch return null;
            const hash = std.hash.Wyhash.hash(attempt, seed);
            break :blk std.fmt.bufPrint(out, "cron_{x:0>16}_{x:0>16}_{x:0>2}", .{ hash, fire_slot, attempt }) catch return null;
        };
        var jk: keys.KeyBuf = undefined;
        if (b.get(keys.jobKey(&jk, candidate)) == null) return candidate;
    }
    return null;
}

fn optionalEql(value: ?[]const u8, expected: []const u8) bool {
    const actual = value orelse return false;
    return std.mem.eql(u8, actual, expected);
}

fn optionalOptionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Parse webhook JSON value into a WebhookCached entry.
fn webhookValueToCached(val: []const u8) OpHandler.WebhookCached {
    var entry = OpHandler.WebhookCached{};

    // Parse fields using same JSON extractors as kv_read.
    if (jsonStr(val, "id")) |v| {
        const l: u8 = @intCast(@min(v.len, entry.id.len));
        @memcpy(entry.id[0..l], v[0..l]);
        entry.id_len = l;
    }
    if (jsonStr(val, "url")) |v| {
        const l: u16 = @intCast(@min(v.len, entry.url.len));
        @memcpy(entry.url[0..l], v[0..l]);
        entry.url_len = l;
    }
    if (jsonStr(val, "queue")) |v| {
        const l: u8 = @intCast(@min(v.len, entry.queue_filter.len));
        @memcpy(entry.queue_filter[0..l], v[0..l]);
        entry.queue_filter_len = l;
    }
    if (jsonStr(val, "events")) |events_str| {
        // Comma-separated: "job.completed,job.failed,job.dead"
        entry.on_completed = std.mem.indexOf(u8, events_str, "job.completed") != null;
        entry.on_failed = std.mem.indexOf(u8, events_str, "job.failed") != null;
        entry.on_dead = std.mem.indexOf(u8, events_str, "job.dead") != null;
    }
    if (jsonBool(val, "enabled")) |e| entry.enabled = e;
    return entry;
}

/// Minimal JSON string extractor (duplicated from kv_read for module independence).
fn jsonStr(body: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    const val_start = start + search_key.len;
    if (val_start >= body.len) return null;
    const end = std.mem.indexOfScalar(u8, body[val_start..], '"') orelse return null;
    return body[val_start..][0..end];
}

fn jsonBool(body: []const u8, key: []const u8) ?bool {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    var val_start = start + search_key.len;
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start + 4 <= body.len and std.mem.eql(u8, body[val_start..][0..4], "true")) return true;
    if (val_start + 5 <= body.len and std.mem.eql(u8, body[val_start..][0..5], "false")) return false;
    return null;
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

test "queue notifications preserve every destination in a maximum RPC batch" {
    var h = OpHandler.init(std.testing.allocator);
    defer h.deinit();

    var names: [OpHandler.max_promote_queues][16]u8 = undefined;
    for (0..OpHandler.max_promote_queues) |i| {
        const name = std.fmt.bufPrint(&names[i], "q-{d}", .{i}) catch unreachable;
        h.recordPromoteQueue(name);
    }
    try std.testing.expectEqual(@as(u16, OpHandler.max_promote_queues), h.promote_queue_count);
    try std.testing.expectEqual(@as(usize, OpHandler.max_promote_queues), h.promoteQueueSlices().len);
}
