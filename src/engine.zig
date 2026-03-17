//! Engine — the core apply pipeline for Corvo.
//!
//! Ported from Go internal/engine/engine.go + node.go.
//! Coordinates Talon shards, oplog, OpHandler, and QueueNotifier.
//!
//! The Engine is the direct write path — no Raft consensus overhead.
//! Single-threaded apply loop with batched execution.
//!
//! Write path:
//!   Apply(opType, data) → route to shard → batch → OpHandler.Apply
//!   → commit → oplog.Append → notify
//!
//! Read path (bypasses engine):
//!   Get(key) → Talon shard direct read

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops_mod = @import("ops.zig");
const kv = @import("kv.zig");
const handler_mod = @import("handler.zig");
const oplog_mod = @import("oplog.zig");
const notify_mod = @import("notify.zig");
const shard_mod = @import("shard.zig");
const pipeline_mod = @import("pipeline.zig");

const OpHandler = handler_mod.OpHandler;
const QueueNotifier = notify_mod.QueueNotifier;
const Log = oplog_mod.Log;

// ============================================================================
// Config
// ============================================================================

pub const Config = struct {
    node_id: []const u8 = "node-1",
    shard_count: u16 = 1,
    /// Max ops per batch.
    apply_batch_max: u32 = 1024,
    /// Max pending apply requests before backpressure.
    apply_max_pending: u32 = 16384,
    /// Max requests per sub-batch execution (matches batch_max for single commit).
    apply_sub_batch_max: u32 = 1024,
    /// true = wait for follower ack. false = replicate in background.
    sync_replication: bool = false,
    /// Talon fsync disabled (replication is the durability mechanism).
    talon_sync: bool = false,
    /// Clock function for timestamps. Null = use default.
    clock_fn: ?*const fn () i64 = null,
    /// Path for oplog file. Null = memory-only (tests).
    oplog_path: ?[*:0]const u8 = null,
};

// ============================================================================
// Engine
// ============================================================================

/// Lease check callback — returns true if this node holds a valid leader lease.
pub const LeaseCheck = struct {
    ptr: *anyopaque,
    checkFn: *const fn (ptr: *anyopaque) bool,

    pub fn isLeaseValid(self: LeaseCheck) bool {
        return self.checkFn(self.ptr);
    }
};

pub const Engine = struct {
    config: Config,
    shards: []kv.Store,
    handler: OpHandler,
    notify: QueueNotifier,
    oplog: Log,
    pipeline: ?pipeline_mod.Pipeline = null,
    mut_list: std.ArrayList(kv.Mutation) = .{},
    allocator: std.mem.Allocator,
    /// Optional lease check — if set, writes are rejected when lease is invalid.
    lease_check: ?LeaseCheck = null,

    pub fn init(allocator: std.mem.Allocator, shards: []kv.Store, config: Config) Engine {
        assert.check(shards.len > 0, "Engine.init: no shards", .{});

        const clock_fn = config.clock_fn orelse defaultClockFn;

        return .{
            .config = config,
            .shards = shards,
            .handler = OpHandler.init(allocator),
            .notify = QueueNotifier.init(allocator),
            .oplog = Log.init(allocator, .{ .now_fn = clock_fn }, config.oplog_path),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Engine) void {
        if (self.pipeline) |*p| p.deinit();
        self.handler.deinit();
        self.notify.deinit();
        self.oplog.deinit();
        self.mut_list.deinit(self.allocator);
    }

    /// Start the async apply pipeline. After this, use submit() for
    /// thread-safe concurrent access.
    pub fn startPipeline(self: *Engine) !void {
        try self.startPipelineWithHook(null);
    }

    /// Start the async apply pipeline with an optional replication hook.
    pub fn startPipelineWithHook(self: *Engine, repl_hook: ?pipeline_mod.ReplHook) !void {
        // Rebuild in-memory state (pending index, active counts, queue configs).
        self.handler.rebuildState(self.shards);

        self.pipeline = try pipeline_mod.Pipeline.init(
            self.allocator,
            &self.handler,
            self.shards,
            &self.oplog,
            &self.notify,
            .{
                .batch_max = self.config.apply_batch_max,
                .sub_batch_max = self.config.apply_sub_batch_max,
                .max_pending = self.config.apply_max_pending,
                .repl_hook = repl_hook,
                .sync_replication = self.config.sync_replication,
            },
        );
        try self.pipeline.?.start();
    }

    /// Stop the async apply pipeline.
    pub fn stopPipeline(self: *Engine) void {
        if (self.pipeline) |*p| {
            p.stop();
            self.pipeline = null;
        }
    }

    /// Submit an operation via the async pipeline. Thread-safe.
    /// Blocks until the result is ready. Requires startPipeline().
    pub fn submit(self: *Engine, op_type: ops_mod.OpType, data: *const ops_mod.OpData) ops_mod.OpResult {
        if (self.pipeline) |*p| {
            return p.submit(op_type, data);
        }
        // Fallback to synchronous apply if pipeline not started.
        return self.apply(op_type, data);
    }

    /// Apply a single operation. Routes to the correct shard, applies via
    /// OpHandler, commits, and appends to oplog.
    pub fn apply(self: *Engine, op_type: ops_mod.OpType, data: *const ops_mod.OpData) ops_mod.OpResult {
        // Reject writes if lease is invalid (leadership lost or transitioning).
        if (self.lease_check) |lc| {
            // Reads (fetch, maintenance reads) are allowed without lease.
            // Writes require a valid lease to prevent split-brain.
            const is_read_only = (op_type == .fetch or op_type == .maintenance);
            if (!is_read_only and !lc.isLeaseValid()) {
                return .{ .err = "not leader" };
            }
        }

        if (self.config.shard_count <= 1) {
            return self.applyToShard(0, op_type, data);
        }

        const route = shard_mod.classifyRoute(self.config.shard_count, op_type, data);
        return switch (route.mode) {
            .single_shard => self.applyToShard(route.shard_idx, op_type, data),
            .global => self.applyToShard(0, op_type, data),
            .broadcast => self.broadcastAll(op_type, data),
            .multi_shard => {
                // For now, apply to the first shard. Full split-apply
                // will be implemented when multi-shard is needed.
                return self.applyToShard(route.shard_idx, op_type, data);
            },
        };
    }

    /// Apply multiple operations in a single batch commit (single-shard fast path).
    /// This is the batched apply path matching Go's executeSubBatchSingleShard.
    /// Returns the result of the last operation.
    pub fn applyBatch(self: *Engine, batch_ops: []const ops_mod.OpInput) ops_mod.OpResult {
        if (batch_ops.len == 0) return .{};

        var kv_batch = self.shards[0].newBatch();
        defer kv_batch.close();

        var last_result: ops_mod.OpResult = .{};
        for (batch_ops, 0..) |op, i| {
            last_result = self.handler.apply(&kv_batch, op.op_type, &op.data);
            if (i % 64 == 63) kv_batch.sortOverlay();
        }

        kv_batch.commit();
        return last_result;
    }

    /// Apply multiple operations in a single batch commit, collecting all results.
    /// results slice must be at least batch_ops.len. Returns number of results written.
    pub fn applyBatchCollect(
        self: *Engine,
        batch_ops: []const ops_mod.OpInput,
        results: []ops_mod.OpResult,
    ) u32 {
        if (batch_ops.len == 0) return 0;

        var kv_batch = self.shards[0].newBatch();
        defer kv_batch.close();

        var count: u32 = 0;
        for (batch_ops, 0..) |op, idx| {
            results[idx] = self.handler.apply(&kv_batch, op.op_type, &op.data);
            count += 1;
            if (idx % 64 == 63) kv_batch.sortOverlay();
        }

        kv_batch.commit();
        return count;
    }

    /// Apply an op to a specific shard.
    fn applyToShard(self: *Engine, shard_idx: u16, op_type: ops_mod.OpType, data: *const ops_mod.OpData) ops_mod.OpResult {
        assert.check(shard_idx < self.shards.len, "applyToShard: shard_idx out of range", .{});

        var batch = self.shards[shard_idx].newBatch();
        defer batch.close();

        // Enable mutation recording for oplog (reuses pre-allocated list).
        self.mut_list.clearRetainingCapacity();
        batch.enableRecording(self.allocator, &self.mut_list);
        defer batch.freeMutations();

        const result = self.handler.apply(&batch, op_type, data);
        batch.commit();

        // Post-commit: append mutations to oplog.
        if (self.mut_list.items.len > 0) {
            const encoded = oplog_mod.encodeMutations(self.allocator, self.mut_list.items);
            defer self.allocator.free(encoded);
            _ = self.oplog.append(shard_idx, encoded);
        }

        // Notify waiters
        notify_mod.notifyFromOp(&self.notify, op_type, data);

        return result;
    }

    /// Apply an op to every shard (broadcast).
    fn broadcastAll(self: *Engine, op_type: ops_mod.OpType, data: *const ops_mod.OpData) ops_mod.OpResult {
        var last_result: ops_mod.OpResult = .{};
        for (0..self.shards.len) |i| {
            last_result = self.applyToShard(@intCast(i), op_type, data);
            if (last_result.err != null) return last_result;
        }
        return last_result;
    }

    // ========================================================================
    // KVReader interface
    // ========================================================================

    /// Read a key from KV (source of truth).
    pub fn get(self: *Engine, key: []const u8) ?[]const u8 {
        if (self.shards.len == 1) {
            return self.shards[0].get(key);
        }
        for (self.shards) |*s| {
            if (s.get(key)) |val| return val;
        }
        return null;
    }

    /// Scan over key-value pairs in [lower, upper) across all shards.
    pub fn scan(self: *Engine, lower: []const u8, upper: []const u8, callback: *const fn (key: []const u8, value: []const u8) bool) void {
        for (self.shards) |*s| {
            var batch = s.newBatch();
            defer batch.close();
            var iter = batch.newIter(lower, upper);
            defer iter.close();

            if (iter.first()) {
                while (true) {
                    if (!callback(iter.key(), iter.value())) return;
                    if (!iter.next()) break;
                }
            }
        }
    }

    // ========================================================================
    // Accessors
    // ========================================================================

    pub fn shardCount(self: *const Engine) u16 {
        return @intCast(self.shards.len);
    }

    pub fn getOpLog(self: *Engine) *Log {
        return &self.oplog;
    }

    pub fn getNotifier(self: *Engine) *QueueNotifier {
        return &self.notify;
    }

    pub fn getHandler(self: *Engine) *OpHandler {
        return &self.handler;
    }
};

fn defaultClockFn() i64 {
    return @intCast(@as(i128, std.time.nanoTimestamp()));
}
