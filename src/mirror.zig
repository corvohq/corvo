//! SQLite Mirror — async materialized view writer.
//!
//! Ported from Go internal/sqlite/mirror.go.
//! Receives operations from the engine post-commit pipeline and
//! batches them into SQLite transactions.
//!
//! The mirror is NOT the source of truth — KV is. SQLite is a
//! read-optimized materialized view for the API/dashboard.
//!
//! Flow:
//!   engine.apply() → mirror.enqueue(op) → [batch queue] → flush to SQLite

const std = @import("std");
const assert_mod = @import("assert.zig");
const sqlite = @import("sqlite.zig");
const schema = @import("schema.zig");
const types = @import("types.zig");
const ops_mod = @import("ops.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const keys = @import("keys.zig");

// ============================================================================
// Config
// ============================================================================

const mirror_queue_capacity = 131_072;
const max_batch_size = 4_096;
const flush_interval_ms = 50;

// ============================================================================
// MirrorOp — queued operation
// ============================================================================

pub const MirrorOp = struct {
    op_type: ops_mod.OpType,
    /// Inline snapshot of the data needed for mirror writes.
    /// We copy the essential fields at enqueue time since the
    /// original OpData pointers may be invalidated after apply returns.
    payload: Payload,

    pub const Payload = union(enum) {
        enqueue: EnqueuePayload,
        fetch: FetchPayload,
        ack: AckPayload,
        fail: FailPayload,
        heartbeat: HeartbeatPayload,
        maintenance: MaintenancePayload,
        queue_config: QueueConfigPayload,
        cron: CronFullPayload,
        bulk_action_job: BulkActionJobPayload,
        batch_op: BatchOpPayload,
        budget_op: BudgetOpPayload,
        queue_op: QueueOpPayload,
        heartbeat_job: HeartbeatJobPayload,
        approval_policy: ApprovalPolicyPayload,
        noop: void,
    };

    pub const EnqueuePayload = struct {
        job_id: [128]u8 = undefined,
        job_id_len: u8 = 0,
        queue: [128]u8 = undefined,
        queue_len: u8 = 0,
        state: types.JobState = .pending,
        priority: u8 = types.priority_default,
        max_retries: u16 = 0,
        created_at_ns: u64 = 0,
        scheduled_at_ns: u64 = 0,
        payload_preview: [4096]u8 = undefined,
        payload_preview_len: u16 = 0,
        tags: [256]u8 = undefined,
        tags_len: u8 = 0,
        batch_id: [128]u8 = undefined,
        batch_id_len: u8 = 0,
        unique_key: [128]u8 = undefined,
        unique_key_len: u8 = 0,
        unique_period_s: u32 = 0,
        backoff: types.Backoff = .none,
        base_delay_ms: u32 = 0,
        max_delay_ms: u32 = 0,
        parent_id: [128]u8 = undefined,
        parent_id_len: u8 = 0,
        chain_id: [128]u8 = undefined,
        chain_id_len: u8 = 0,
        chain_step: u16 = 0,
        group_key: [128]u8 = undefined,
        group_key_len: u8 = 0,
        expire_at_ns: u64 = 0,

        fn jobId(self: *const EnqueuePayload) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        fn queueName(self: *const EnqueuePayload) []const u8 {
            return self.queue[0..self.queue_len];
        }
        fn payloadPreview(self: *const EnqueuePayload) []const u8 {
            return self.payload_preview[0..self.payload_preview_len];
        }
        fn tagsSlice(self: *const EnqueuePayload) []const u8 {
            return self.tags[0..self.tags_len];
        }
        fn batchIdSlice(self: *const EnqueuePayload) []const u8 {
            return self.batch_id[0..self.batch_id_len];
        }
        fn uniqueKeySlice(self: *const EnqueuePayload) []const u8 {
            return self.unique_key[0..self.unique_key_len];
        }
        fn parentIdSlice(self: *const EnqueuePayload) []const u8 {
            return self.parent_id[0..self.parent_id_len];
        }
        fn chainIdSlice(self: *const EnqueuePayload) []const u8 {
            return self.chain_id[0..self.chain_id_len];
        }
        fn groupKeySlice(self: *const EnqueuePayload) []const u8 {
            return self.group_key[0..self.group_key_len];
        }
    };

    pub const FetchPayload = struct {
        job_id: [128]u8 = undefined,
        job_id_len: u8 = 0,
        queue: [128]u8 = undefined,
        queue_len: u8 = 0,
        worker_id: [128]u8 = undefined,
        worker_id_len: u8 = 0,
        now_ns: u64 = 0,
        lease_duration_ms: u32 = 0,

        fn jobId(self: *const FetchPayload) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        fn workerIdSlice(self: *const FetchPayload) []const u8 {
            return self.worker_id[0..self.worker_id_len];
        }
    };

    pub const AckPayload = struct {
        job_id: [128]u8 = undefined,
        job_id_len: u8 = 0,
        queue: [128]u8 = undefined,
        queue_len: u8 = 0,
        now_ns: u64 = 0,
        result: [4096]u8 = undefined,
        result_len: u16 = 0,
        hold_reason: [256]u8 = undefined,
        hold_reason_len: u8 = 0,

        fn jobId(self: *const AckPayload) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        fn resultSlice(self: *const AckPayload) []const u8 {
            return self.result[0..self.result_len];
        }
        fn holdReasonSlice(self: *const AckPayload) []const u8 {
            return self.hold_reason[0..self.hold_reason_len];
        }
    };

    pub const FailPayload = struct {
        job_id: [128]u8 = undefined,
        job_id_len: u8 = 0,
        queue: [128]u8 = undefined,
        queue_len: u8 = 0,
        error_msg: [256]u8 = undefined,
        error_msg_len: u16 = 0,
        backtrace: [1024]u8 = undefined,
        backtrace_len: u16 = 0,
        new_state: types.JobState = .retrying,
        attempt: u16 = 0,
        now_ns: u64 = 0,
        retry_at_ns: u64 = 0,

        fn jobId(self: *const FailPayload) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        fn errorMsg(self: *const FailPayload) []const u8 {
            return self.error_msg[0..self.error_msg_len];
        }
        fn backtraceSlice(self: *const FailPayload) []const u8 {
            return self.backtrace[0..self.backtrace_len];
        }
    };

    pub const HeartbeatPayload = struct {
        worker_id: [128]u8 = undefined,
        worker_id_len: u8 = 0,
        now_ns: u64 = 0,

        fn workerIdSlice(self: *const HeartbeatPayload) []const u8 {
            return self.worker_id[0..self.worker_id_len];
        }
    };

    pub const MaintenancePayload = struct {
        action: ops_mod.MaintenanceAction = .promote,
        now_ns: u64 = 0,
    };

    pub const QueueConfigPayload = struct {
        queue: [128]u8 = undefined,
        queue_len: u8 = 0,
        action: ops_mod.QueueAction = .pause,
        max_concurrency: u32 = 0,
        rate_limit: u32 = 0,
        rate_window_ms: u32 = 0,

        fn queueName(self: *const QueueConfigPayload) []const u8 {
            return self.queue[0..self.queue_len];
        }
    };

    pub const CronFullPayload = struct {
        cron_id: [128]u8 = undefined,
        cron_id_len: u8 = 0,
        action: enum { create, update, delete, toggle_enabled } = .create,
        name: [128]u8 = undefined,
        name_len: u8 = 0,
        queue: [128]u8 = undefined,
        queue_len: u8 = 0,
        schedule: [64]u8 = undefined,
        schedule_len: u8 = 0,
        timezone: [64]u8 = undefined,
        timezone_len: u8 = 0,
        payload: [4096]u8 = undefined,
        payload_len: u16 = 0,
        unique_key: [128]u8 = undefined,
        unique_key_len: u8 = 0,
        max_retries: u16 = 0,
        enabled: bool = true,
        created_at_ns: u64 = 0,

        fn cronId(self: *const CronFullPayload) []const u8 {
            return self.cron_id[0..self.cron_id_len];
        }
    };

    pub const BulkActionJobPayload = struct {
        job_id: [128]u8 = undefined,
        job_id_len: u8 = 0,
        action: enum { update_state, delete, move } = .update_state,
        new_state: [16]u8 = undefined,
        new_state_len: u8 = 0,
        new_queue: [128]u8 = undefined,
        new_queue_len: u8 = 0,
        now_ns: u64 = 0,

        fn jobId(self: *const BulkActionJobPayload) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        fn stateSlice(self: *const BulkActionJobPayload) []const u8 {
            return self.new_state[0..self.new_state_len];
        }
        fn queueSlice(self: *const BulkActionJobPayload) []const u8 {
            return self.new_queue[0..self.new_queue_len];
        }
    };

    pub const BatchOpPayload = struct {
        batch_id: [128]u8 = undefined,
        batch_id_len: u8 = 0,
        action: enum { create, seal } = .create,
        created_at_ns: u64 = 0,

        fn batchId(self: *const BatchOpPayload) []const u8 {
            return self.batch_id[0..self.batch_id_len];
        }
    };

    pub const BudgetOpPayload = struct {
        action: enum { upsert, delete } = .upsert,
        id: [128]u8 = undefined,
        id_len: u8 = 0,
        scope: [64]u8 = undefined,
        scope_len: u8 = 0,
        target: [64]u8 = undefined,
        target_len: u8 = 0,
        daily_usd: f64 = 0,
        per_job_usd: f64 = 0,
        on_exceed: [16]u8 = undefined,
        on_exceed_len: u8 = 0,

        fn idSlice(self: *const BudgetOpPayload) []const u8 {
            return self.id[0..self.id_len];
        }
        fn scopeSlice(self: *const BudgetOpPayload) []const u8 {
            return self.scope[0..self.scope_len];
        }
        fn targetSlice(self: *const BudgetOpPayload) []const u8 {
            return self.target[0..self.target_len];
        }
        fn onExceedSlice(self: *const BudgetOpPayload) []const u8 {
            return self.on_exceed[0..self.on_exceed_len];
        }
    };

    pub const QueueOpPayload = struct {
        queue: [128]u8 = undefined,
        queue_len: u8 = 0,
        action: enum { clear, delete } = .clear,

        fn queueName(self: *const QueueOpPayload) []const u8 {
            return self.queue[0..self.queue_len];
        }
    };

    pub const HeartbeatJobPayload = struct {
        job_id: [128]u8 = undefined,
        job_id_len: u8 = 0,
        progress: [4096]u8 = undefined,
        progress_len: u16 = 0,
        checkpoint: [4096]u8 = undefined,
        checkpoint_len: u16 = 0,
        lease_expires_ns: u64 = 0,

        fn jobId(self: *const HeartbeatJobPayload) []const u8 {
            return self.job_id[0..self.job_id_len];
        }
        fn progressSlice(self: *const HeartbeatJobPayload) ?[]const u8 {
            if (self.progress_len == 0) return null;
            return self.progress[0..self.progress_len];
        }
        fn checkpointSlice(self: *const HeartbeatJobPayload) ?[]const u8 {
            if (self.checkpoint_len == 0) return null;
            return self.checkpoint[0..self.checkpoint_len];
        }
    };

    pub const ApprovalPolicyPayload = struct {
        action: enum { upsert, delete },
        id: [64]u8 = undefined,
        id_len: u8 = 0,
        name: [128]u8 = undefined,
        name_len: u8 = 0,
        mode: [8]u8 = undefined,
        mode_len: u8 = 0,
        enabled: bool = true,
        queue: [64]u8 = undefined,
        queue_len: u8 = 0,
        tag_key: [64]u8 = undefined,
        tag_key_len: u8 = 0,
        tag_value: [128]u8 = undefined,
        tag_value_len: u8 = 0,

        fn idSlice(self: *const ApprovalPolicyPayload) []const u8 {
            return self.id[0..self.id_len];
        }
        fn nameSlice(self: *const ApprovalPolicyPayload) []const u8 {
            return self.name[0..self.name_len];
        }
        fn modeSlice(self: *const ApprovalPolicyPayload) []const u8 {
            return self.mode[0..self.mode_len];
        }
        fn queueSlice(self: *const ApprovalPolicyPayload) []const u8 {
            return self.queue[0..self.queue_len];
        }
        fn tagKeySlice(self: *const ApprovalPolicyPayload) []const u8 {
            return self.tag_key[0..self.tag_key_len];
        }
        fn tagValueSlice(self: *const ApprovalPolicyPayload) []const u8 {
            return self.tag_value[0..self.tag_value_len];
        }
    };
};

// ============================================================================
// Mirror
// ============================================================================

pub const Mirror = struct {
    db: sqlite.DB,
    allocator: std.mem.Allocator,
    running: bool = false,
    thread: ?std.Thread = null,

    // Stats
    queued: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    committed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Ring buffer for ops — heap-allocated, lock-free SPSC.
    // Producer: engine thread (enqueue). Consumer: mirror thread (flush).
    ring: []MirrorOp,
    write_pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    read_pos: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Prepared statements (lazily initialized on first flush).
    stmts: ?MirrorStmts = null,

    // KV stores for rebuild-on-overflow. Set by main after init.
    // Null in tests/simulator where overflow rebuild isn't needed.
    kv_stores: ?[]kv.Store = null,

    // Overflow rebuild: set when ring drops ops, cleared after full KV→SQLite rebuild.
    needs_rebuild: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    rebuilds: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator, db_path: [*:0]const u8) !Mirror {
        var db = try sqlite.DB.open(db_path, .{});
        try schema.createSchema(&db);
        const ring = try allocator.alloc(MirrorOp, mirror_queue_capacity);
        return .{
            .db = db,
            .allocator = allocator,
            .ring = ring,
        };
    }

    pub fn initInMemory(allocator: std.mem.Allocator) !Mirror {
        var db = try sqlite.DB.open(":memory:", .{});
        try schema.createSchema(&db);
        const ring = try allocator.alloc(MirrorOp, mirror_queue_capacity);
        return .{
            .db = db,
            .allocator = allocator,
            .ring = ring,
        };
    }

    pub fn deinit(self: *Mirror) void {
        self.stop();
        if (self.stmts) |*s| s.deinit();
        self.db.close();
        self.allocator.free(self.ring);
    }

    /// Start the background flush thread.
    pub fn start(self: *Mirror) !void {
        if (self.running) return;
        self.running = true;
        self.thread = try std.Thread.spawn(.{}, flushLoop, .{self});
    }

    /// Stop the background flush thread and drain remaining ops.
    pub fn stop(self: *Mirror) void {
        if (!self.running) return;
        self.running = false;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        // Final drain.
        self.flush() catch {};
    }

    /// Enqueue an operation for async mirror write. Non-blocking.
    /// Drops the op if the queue is full and sets needs_rebuild.
    pub fn enqueue(self: *Mirror, op: MirrorOp) void {
        const wp = self.write_pos.load(.monotonic);
        const rp = self.read_pos.load(.acquire);

        // Ring full — drop op and flag for rebuild on next flushAll().
        if (wp -% rp >= mirror_queue_capacity) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            self.needs_rebuild.store(true, .release);
            return;
        }

        self.ring[wp % mirror_queue_capacity] = op;
        self.write_pos.store(wp +% 1, .release);
        _ = self.queued.fetchAdd(1, .monotonic);
    }

    /// Enqueue a simple enqueue op from apply result.
    pub fn enqueueJob(self: *Mirror, job: *const ops_mod.EnqueueJob) void {
        var payload = MirrorOp.EnqueuePayload{
            .state = job.state,
            .priority = job.priority,
            .max_retries = job.max_retries,
            .created_at_ns = job.created_at_ns,
            .scheduled_at_ns = job.scheduled_at_ns,
            .unique_period_s = job.unique_period_s,
            .backoff = job.backoff,
            .base_delay_ms = job.base_delay_ms,
            .max_delay_ms = job.max_delay_ms,
            .chain_step = job.chain_step,
            .expire_at_ns = job.expire_at_ns,
        };
        // Copy fixed-size ID fields.
        inline for (.{
            .{ job.job_id, &payload.job_id, &payload.job_id_len },
            .{ job.queue, &payload.queue, &payload.queue_len },
        }) |f| {
            const len = @min(f[0].len, f[1].len);
            @memcpy(f[1][0..len], f[0][0..len]);
            f[2].* = @intCast(len);
        }
        // Copy optional text fields.
        inline for (.{
            .{ job.payload, &payload.payload_preview, &payload.payload_preview_len },
            .{ job.tags, &payload.tags, &payload.tags_len },
            .{ job.batch_id, &payload.batch_id, &payload.batch_id_len },
            .{ job.unique_key, &payload.unique_key, &payload.unique_key_len },
            .{ job.parent_id, &payload.parent_id, &payload.parent_id_len },
            .{ job.chain_id, &payload.chain_id, &payload.chain_id_len },
            .{ job.group, &payload.group_key, &payload.group_key_len },
        }) |f| {
            if (f[0]) |v| {
                const len = @min(v.len, f[1].len);
                @memcpy(f[1][0..len], v[0..len]);
                f[2].* = @intCast(len);
            }
        }

        self.enqueue(.{ .op_type = .enqueue, .payload = .{ .enqueue = payload } });
    }

    /// Enqueue a bulk action job state update or delete via ring buffer.
    pub fn enqueueBulkActionJob(self: *Mirror, job_id: []const u8, action: @TypeOf(@as(MirrorOp.BulkActionJobPayload, .{}).action), state: []const u8, now_ns: u64) void {
        var p = MirrorOp.BulkActionJobPayload{
            .action = action,
            .now_ns = now_ns,
        };
        const il = @min(job_id.len, p.job_id.len);
        @memcpy(p.job_id[0..il], job_id[0..il]);
        p.job_id_len = @intCast(il);
        if (action == .update_state) {
            const sl = @min(state.len, p.new_state.len);
            @memcpy(p.new_state[0..sl], state[0..sl]);
            p.new_state_len = @intCast(sl);
        }
        self.enqueue(.{ .op_type = .bulk_action, .payload = .{ .bulk_action_job = p } });
    }

    pub fn enqueueBulkActionMove(self: *Mirror, job_id: []const u8, queue: []const u8) void {
        var p = MirrorOp.BulkActionJobPayload{
            .action = .move,
        };
        const il = @min(job_id.len, p.job_id.len);
        @memcpy(p.job_id[0..il], job_id[0..il]);
        p.job_id_len = @intCast(il);
        const ql = @min(queue.len, p.new_queue.len);
        @memcpy(p.new_queue[0..ql], queue[0..ql]);
        p.new_queue_len = @intCast(ql);
        self.enqueue(.{ .op_type = .bulk_action, .payload = .{ .bulk_action_job = p } });
    }

    /// Enqueue a maintenance op via ring buffer.
    pub fn enqueueMaintenance(self: *Mirror, action: ops_mod.MaintenanceAction, now_ns: u64) void {
        self.enqueue(.{ .op_type = .maintenance, .payload = .{ .maintenance = .{
            .action = action,
            .now_ns = now_ns,
        } } });
    }

    /// Enqueue a queue clear via ring buffer.
    pub fn enqueueQueueClear(self: *Mirror, queue: []const u8) void {
        var p = MirrorOp.QueueOpPayload{ .action = .clear };
        const ql = @min(queue.len, p.queue.len);
        @memcpy(p.queue[0..ql], queue[0..ql]);
        p.queue_len = @intCast(ql);
        self.enqueue(.{ .op_type = .clear_queue, .payload = .{ .queue_op = p } });
    }

    /// Enqueue a queue delete via ring buffer.
    pub fn enqueueQueueDelete(self: *Mirror, queue: []const u8) void {
        var p = MirrorOp.QueueOpPayload{ .action = .delete };
        const ql = @min(queue.len, p.queue.len);
        @memcpy(p.queue[0..ql], queue[0..ql]);
        p.queue_len = @intCast(ql);
        self.enqueue(.{ .op_type = .delete_queue, .payload = .{ .queue_op = p } });
    }

    /// Enqueue a batch create via ring buffer.
    pub fn enqueueBatchCreate(self: *Mirror, batch_id: []const u8, now_ns: u64) void {
        var p = MirrorOp.BatchOpPayload{ .action = .create, .created_at_ns = now_ns };
        const bl = @min(batch_id.len, p.batch_id.len);
        @memcpy(p.batch_id[0..bl], batch_id[0..bl]);
        p.batch_id_len = @intCast(bl);
        self.enqueue(.{ .op_type = .batch_create, .payload = .{ .batch_op = p } });
    }

    /// Enqueue a batch seal via ring buffer.
    pub fn enqueueBatchSeal(self: *Mirror, batch_id: []const u8) void {
        var p = MirrorOp.BatchOpPayload{ .action = .seal };
        const bl = @min(batch_id.len, p.batch_id.len);
        @memcpy(p.batch_id[0..bl], batch_id[0..bl]);
        p.batch_id_len = @intCast(bl);
        self.enqueue(.{ .op_type = .batch_seal, .payload = .{ .batch_op = p } });
    }

    /// Enqueue a budget upsert via ring buffer.
    pub fn enqueueBudgetUpsert(self: *Mirror, id: []const u8, scope: []const u8, target: []const u8, daily_usd: f64, per_job_usd: f64, on_exceed: []const u8) void {
        var p = MirrorOp.BudgetOpPayload{ .action = .upsert, .daily_usd = daily_usd, .per_job_usd = per_job_usd };
        inline for (.{
            .{ id, &p.id, &p.id_len },
            .{ scope, &p.scope, &p.scope_len },
            .{ target, &p.target, &p.target_len },
            .{ on_exceed, &p.on_exceed, &p.on_exceed_len },
        }) |f| {
            const len = @min(f[0].len, f[1].len);
            @memcpy(f[1][0..len], f[0][0..len]);
            f[2].* = @intCast(len);
        }
        self.enqueue(.{ .op_type = .set_budget, .payload = .{ .budget_op = p } });
    }

    /// Enqueue a budget delete via ring buffer.
    pub fn enqueueBudgetDelete(self: *Mirror, scope: []const u8, target: []const u8) void {
        var p = MirrorOp.BudgetOpPayload{ .action = .delete };
        const sl = @min(scope.len, p.scope.len);
        @memcpy(p.scope[0..sl], scope[0..sl]);
        p.scope_len = @intCast(sl);
        const tl = @min(target.len, p.target.len);
        @memcpy(p.target[0..tl], target[0..tl]);
        p.target_len = @intCast(tl);
        self.enqueue(.{ .op_type = .delete_budget, .payload = .{ .budget_op = p } });
    }

    /// Enqueue an approval policy upsert via ring buffer.
    pub fn enqueueApprovalPolicyUpsert(self: *Mirror, id: []const u8, name: []const u8, mode: []const u8, enabled: bool, queue: []const u8, tag_key: []const u8, tag_value: []const u8) void {
        var p = MirrorOp.ApprovalPolicyPayload{ .action = .upsert, .enabled = enabled };
        inline for (.{
            .{ id, &p.id, &p.id_len },
            .{ name, &p.name, &p.name_len },
            .{ mode, &p.mode, &p.mode_len },
            .{ queue, &p.queue, &p.queue_len },
            .{ tag_key, &p.tag_key, &p.tag_key_len },
            .{ tag_value, &p.tag_value, &p.tag_value_len },
        }) |f| {
            const len = @min(f[0].len, f[1].len);
            @memcpy(f[1][0..len], f[0][0..len]);
            f[2].* = @intCast(len);
        }
        self.enqueue(.{ .op_type = .modify_ent_setting, .payload = .{ .approval_policy = p } });
    }

    /// Enqueue an approval policy delete via ring buffer.
    pub fn enqueueApprovalPolicyDelete(self: *Mirror, id: []const u8) void {
        var p = MirrorOp.ApprovalPolicyPayload{ .action = .delete };
        const len = @min(id.len, p.id.len);
        @memcpy(p.id[0..len], id[0..len]);
        p.id_len = @intCast(len);
        self.enqueue(.{ .op_type = .modify_ent_setting, .payload = .{ .approval_policy = p } });
    }

    /// Enqueue a cron upsert via ring buffer.
    pub fn enqueueCronUpsert(self: *Mirror, opts: CronUpsertOpts) void {
        var p = MirrorOp.CronFullPayload{
            .action = .create,
            .max_retries = opts.max_retries,
            .enabled = opts.enabled,
            .created_at_ns = opts.created_at_ns,
        };
        inline for (.{
            .{ opts.id, &p.cron_id, &p.cron_id_len },
            .{ opts.name, &p.name, &p.name_len },
            .{ opts.queue, &p.queue, &p.queue_len },
            .{ opts.schedule, &p.schedule, &p.schedule_len },
            .{ opts.timezone, &p.timezone, &p.timezone_len },
        }) |f| {
            const len = @min(f[0].len, f[1].len);
            @memcpy(f[1][0..len], f[0][0..len]);
            f[2].* = @intCast(len);
        }
        if (opts.payload) |v| {
            const len: u16 = @intCast(@min(v.len, p.payload.len));
            @memcpy(p.payload[0..len], v[0..len]);
            p.payload_len = len;
        }
        if (opts.unique_key) |v| {
            const len = @min(v.len, p.unique_key.len);
            @memcpy(p.unique_key[0..len], v[0..len]);
            p.unique_key_len = @intCast(len);
        }
        self.enqueue(.{ .op_type = .cron_create, .payload = .{ .cron = p } });
    }

    /// Enqueue a cron delete via ring buffer.
    pub fn enqueueCronDelete(self: *Mirror, cron_id: []const u8) void {
        var p = MirrorOp.CronFullPayload{ .action = .delete };
        const cl = @min(cron_id.len, p.cron_id.len);
        @memcpy(p.cron_id[0..cl], cron_id[0..cl]);
        p.cron_id_len = @intCast(cl);
        self.enqueue(.{ .op_type = .cron_delete, .payload = .{ .cron = p } });
    }

    /// Enqueue a cron enabled toggle via ring buffer.
    pub fn enqueueCronToggle(self: *Mirror, cron_id: []const u8, enabled: bool) void {
        var p = MirrorOp.CronFullPayload{ .action = .toggle_enabled, .enabled = enabled };
        const cl = @min(cron_id.len, p.cron_id.len);
        @memcpy(p.cron_id[0..cl], cron_id[0..cl]);
        p.cron_id_len = @intCast(cl);
        self.enqueue(.{ .op_type = .cron_update, .payload = .{ .cron = p } });
    }

    /// Enqueue a per-job heartbeat update via ring buffer.
    pub fn enqueueHeartbeatJob(self: *Mirror, job_id: []const u8, progress: ?[]const u8, checkpoint: ?[]const u8, lease_expires_ns: u64) void {
        var p = MirrorOp.HeartbeatJobPayload{ .lease_expires_ns = lease_expires_ns };
        const il = @min(job_id.len, p.job_id.len);
        @memcpy(p.job_id[0..il], job_id[0..il]);
        p.job_id_len = @intCast(il);
        if (progress) |v| {
            const len: u16 = @intCast(@min(v.len, p.progress.len));
            @memcpy(p.progress[0..len], v[0..len]);
            p.progress_len = len;
        }
        if (checkpoint) |v| {
            const len: u16 = @intCast(@min(v.len, p.checkpoint.len));
            @memcpy(p.checkpoint[0..len], v[0..len]);
            p.checkpoint_len = len;
        }
        self.enqueue(.{ .op_type = .heartbeat, .payload = .{ .heartbeat_job = p } });
    }

    // ========================================================================
    // Flush loop (runs on background thread)
    // ========================================================================

    fn flushLoop(self: *Mirror) void {
        while (self.running) {
            std.Thread.sleep(flush_interval_ms * std.time.ns_per_ms);
            self.flush() catch {};
        }
    }

    /// Flush pending ops to SQLite in a single transaction.
    /// Drain the entire ring buffer synchronously. Called before reads
    /// that need strong consistency (e.g. GetJob after Enqueue).
    /// If overflow was detected (needs_rebuild), does a full KV→SQLite
    /// rebuild instead of draining the ring.
    pub fn flushAll(self: *Mirror) void {
        if (self.needs_rebuild.load(.acquire)) {
            self.rebuildFromKV();
            return;
        }
        while (true) {
            const wp = self.write_pos.load(.acquire);
            const rp = self.read_pos.load(.monotonic);
            if (wp == rp) return;
            self.flush() catch return;
        }
    }

    pub fn flush(self: *Mirror) !void {
        if (self.needs_rebuild.load(.acquire)) return; // Rebuild pending — skip partial flushes.

        const wp = self.write_pos.load(.acquire);
        const rp = self.read_pos.load(.monotonic);
        if (wp == rp) return; // Nothing to flush.

        const count = @min(wp -% rp, max_batch_size);

        // Ensure prepared statements.
        if (self.stmts == null) {
            self.stmts = try MirrorStmts.init(&self.db);
        }
        const stmts = &self.stmts.?;

        try self.db.begin();
        errdefer self.db.rollback();

        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const idx = (rp +% i) % mirror_queue_capacity;
            const op = &self.ring[idx];
            self.applyOp(stmts, op) catch {
                _ = self.dropped.fetchAdd(1, .monotonic);
                continue;
            };
        }

        try self.db.commit();
        self.read_pos.store(rp +% count, .release);
        _ = self.committed.fetchAdd(count, .monotonic);
    }

    // ========================================================================
    // Rebuild from KV (overflow recovery)
    // ========================================================================

    /// Full KV→SQLite rebuild. Called when ring buffer overflow is detected.
    /// Drops all SQLite tables, scans KV stores, and re-inserts everything.
    /// Runs on the pipeline thread (same thread as flushAll).
    fn rebuildFromKV(self: *Mirror) void {
        const stores = self.kv_stores orelse {
            // No KV stores (simulator/tests) — clear flag, best-effort drain.
            self.needs_rebuild.store(false, .release);
            return;
        };

        std.debug.print("mirror: rebuilding from KV (dropped={d})...\n", .{self.dropped.load(.monotonic)});

        // Invalidate cached prepared statements — tables will be dropped.
        if (self.stmts) |*s| {
            s.deinit();
            self.stmts = null;
        }

        // Reset ring buffer — discard pending ops (incomplete due to drops).
        const wp = self.write_pos.load(.acquire);
        self.read_pos.store(wp, .release);

        // Drop and recreate all tables for a clean slate.
        self.db.execMulti(
            "DROP TABLE IF EXISTS jobs_fts;" ++
                "DROP TABLE IF EXISTS job_payloads;" ++
                "DROP TABLE IF EXISTS job_errors;" ++
                "DROP TABLE IF EXISTS jobs;" ++
                "DROP TABLE IF EXISTS queues;" ++
                "DROP TABLE IF EXISTS workers;" ++
                "DROP TABLE IF EXISTS batches;" ++
                "DROP TABLE IF EXISTS crons;" ++
                "DROP TABLE IF EXISTS budgets;" ++
                "DROP TABLE IF EXISTS approval_policies;" ++
                "DROP TABLE IF EXISTS api_keys;",
        ) catch return;
        schema.createSchema(&self.db) catch return;

        // Scan each KV store and rebuild all entity types.
        for (stores) |*store| {
            self.rebuildJobs(store);
            self.rebuildPayloads(store);
            self.rebuildQueues(store);
            self.rebuildWorkers(store);
            self.rebuildCrons(store);
            self.rebuildBatches(store);
            self.rebuildBudgets(store);
        }

        // Clear flag and bump counter.
        self.needs_rebuild.store(false, .release);
        _ = self.rebuilds.fetchAdd(1, .monotonic);
        std.debug.print("mirror: rebuild complete\n", .{});
    }

    /// Scan j| prefix — rebuild jobs table + auto-create queues.
    fn rebuildJobs(self: *Mirror, store: *kv.Store) void {
        var batch = store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        @memcpy(lower_buf[0..keys.prefix_job.len], keys.prefix_job);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..keys.prefix_job.len]) orelse return;

        var iter = batch.newIter(lower_buf[0..keys.prefix_job.len], upper);
        defer iter.close();

        if (!iter.first()) return;

        var insert_job = self.db.prepare(
            "INSERT OR REPLACE INTO jobs (id, queue, state, priority, attempt, max_retries," ++
                " retry_backoff, retry_base_delay_ms, retry_max_delay_ms," ++
                " unique_key, unique_period_s, batch_id, worker_id, hostname," ++
                " tags, progress, checkpoint, result," ++
                " parent_id, chain_id, chain_step, chain_config, group_key, hold_reason," ++
                " lease_expires_at, scheduled_at, expire_at," ++
                " created_at, started_at, completed_at, failed_at)" ++
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        ) catch return;
        defer insert_job.finalize();

        var insert_queue = self.db.prepare(
            "INSERT OR IGNORE INTO queues (name, created_at) VALUES (?, ?)",
        ) catch return;
        defer insert_queue.finalize();

        var count: u32 = 0;
        self.db.begin() catch return;

        while (true) {
            const val = iter.value();
            const job = codec.decodeJob(val);

            // Bind all 31 params.
            var ts: [7][32]u8 = undefined;
            insert_job.bindText(1, job.id);
            insert_job.bindText(2, job.queue);
            insert_job.bindText(3, job.state.toString());
            insert_job.bindInt(4, @intCast(job.priority));
            insert_job.bindInt(5, @intCast(job.attempt));
            insert_job.bindInt(6, @intCast(job.max_retries));
            insert_job.bindText(7, job.retry_backoff.toString());
            insert_job.bindInt(8, @intCast(job.retry_base_delay_ms));
            insert_job.bindInt(9, @intCast(job.retry_max_delay_ms));
            bindOptText(&insert_job, 10, job.unique_key);
            insert_job.bindInt(11, @intCast(job.unique_period_s));
            bindOptText(&insert_job, 12, job.batch_id);
            bindOptText(&insert_job, 13, job.worker_id);
            bindOptText(&insert_job, 14, job.hostname);
            bindOptText(&insert_job, 15, job.tags);
            bindOptText(&insert_job, 16, job.progress);
            bindOptText(&insert_job, 17, job.checkpoint);
            bindOptText(&insert_job, 18, job.result);
            bindOptText(&insert_job, 19, job.parent_id);
            bindOptText(&insert_job, 20, job.chain_id);
            insert_job.bindInt(21, @intCast(job.chain_step));
            bindOptText(&insert_job, 22, job.chain_config);
            bindOptText(&insert_job, 23, job.group);
            bindOptText(&insert_job, 24, job.hold_reason);
            bindTimestamp(&insert_job, 25, job.lease_expires_at_ns, &ts[0]);
            bindTimestamp(&insert_job, 26, job.scheduled_at_ns, &ts[1]);
            bindTimestamp(&insert_job, 27, job.expire_at_ns, &ts[2]);
            bindTimestamp(&insert_job, 28, job.created_at_ns, &ts[3]);
            bindTimestamp(&insert_job, 29, job.started_at_ns, &ts[4]);
            bindTimestamp(&insert_job, 30, job.completed_at_ns, &ts[5]);
            bindTimestamp(&insert_job, 31, job.failed_at_ns, &ts[6]);

            insert_job.exec() catch {
                insert_job.reset();
                if (!iter.next()) break;
                continue;
            };
            insert_job.reset();

            // Auto-create queue.
            insert_queue.bindText(1, job.queue);
            var qts: [32]u8 = undefined;
            insert_queue.bindText(2, formatNs(&qts, job.created_at_ns));
            insert_queue.exec() catch {};
            insert_queue.reset();

            count += 1;
            if (count % max_batch_size == 0) {
                self.db.commit() catch return;
                self.db.begin() catch return;
            }
            if (!iter.next()) break;
        }

        self.db.commit() catch {};
        if (count > 0) std.debug.print("mirror: rebuilt {d} jobs\n", .{count});
    }

    /// Scan jp| prefix — rebuild job_payloads + FTS index.
    fn rebuildPayloads(self: *Mirror, store: *kv.Store) void {
        var batch = store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const pfx = keys.prefix_job_payload;
        @memcpy(lower_buf[0..pfx.len], pfx);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..pfx.len]) orelse return;

        var iter = batch.newIter(lower_buf[0..pfx.len], upper);
        defer iter.close();

        if (!iter.first()) return;

        var insert_payload = self.db.prepare(
            "INSERT OR REPLACE INTO job_payloads (job_id, payload) VALUES (?, ?)",
        ) catch return;
        defer insert_payload.finalize();

        var insert_fts = self.db.prepare(
            "INSERT INTO jobs_fts (job_id, payload) VALUES (?, ?)",
        ) catch return;
        defer insert_fts.finalize();

        var count: u32 = 0;
        self.db.begin() catch return;

        while (true) {
            const k = iter.key();
            const val = iter.value();

            // Extract job_id from key: jp|{job_id}
            const job_id = k[pfx.len..];

            insert_payload.bindText(1, job_id);
            insert_payload.bindText(2, val);
            insert_payload.exec() catch {};
            insert_payload.reset();

            // Payload preview for FTS (truncate to 4096 for search index).
            const preview_len = @min(val.len, 4096);
            insert_fts.bindText(1, job_id);
            insert_fts.bindText(2, val[0..preview_len]);
            insert_fts.exec() catch {};
            insert_fts.reset();

            count += 1;
            if (count % max_batch_size == 0) {
                self.db.commit() catch return;
                self.db.begin() catch return;
            }
            if (!iter.next()) break;
        }

        self.db.commit() catch {};
        if (count > 0) std.debug.print("mirror: rebuilt {d} payloads\n", .{count});
    }

    /// Scan qc| prefix — rebuild queues table with config.
    fn rebuildQueues(self: *Mirror, store: *kv.Store) void {
        var batch = store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const pfx = keys.prefix_queue_config;
        @memcpy(lower_buf[0..pfx.len], pfx);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..pfx.len]) orelse return;

        var iter = batch.newIter(lower_buf[0..pfx.len], upper);
        defer iter.close();

        if (!iter.first()) return;

        var stmt = self.db.prepare(
            "INSERT OR REPLACE INTO queues (name, paused, max_concurrency, rate_limit, rate_window_ms, created_at)" ++
                " VALUES (?, ?, ?, ?, ?, ?)",
        ) catch return;
        defer stmt.finalize();

        self.db.begin() catch return;
        var count: u32 = 0;

        while (true) {
            const val = iter.value();
            const queue = codec.decodeQueue(val);
            var ts: [32]u8 = undefined;

            stmt.bindText(1, queue.name);
            stmt.bindInt(2, if (queue.paused) 1 else 0);
            if (queue.max_concurrency > 0) stmt.bindInt(3, @intCast(queue.max_concurrency)) else stmt.bindNull(3);
            if (queue.rate_limit > 0) stmt.bindInt(4, @intCast(queue.rate_limit)) else stmt.bindNull(4);
            if (queue.rate_window_ms > 0) stmt.bindInt(5, @intCast(queue.rate_window_ms)) else stmt.bindNull(5);
            if (queue.created_at_ns > 0) stmt.bindText(6, formatNs(&ts, queue.created_at_ns)) else stmt.bindNull(6);

            stmt.exec() catch {};
            stmt.reset();
            count += 1;
            if (!iter.next()) break;
        }

        self.db.commit() catch {};
        if (count > 0) std.debug.print("mirror: rebuilt {d} queues\n", .{count});
    }

    /// Scan w| prefix — rebuild workers table.
    fn rebuildWorkers(self: *Mirror, store: *kv.Store) void {
        var batch = store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const pfx = keys.prefix_worker;
        @memcpy(lower_buf[0..pfx.len], pfx);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..pfx.len]) orelse return;

        var iter = batch.newIter(lower_buf[0..pfx.len], upper);
        defer iter.close();

        if (!iter.first()) return;

        var stmt = self.db.prepare(
            "INSERT OR REPLACE INTO workers (id, hostname, queues, last_heartbeat, started_at)" ++
                " VALUES (?, ?, ?, ?, ?)",
        ) catch return;
        defer stmt.finalize();

        self.db.begin() catch return;
        var count: u32 = 0;

        while (true) {
            const val = iter.value();
            const worker = codec.decodeWorker(val);
            var ts1: [32]u8 = undefined;
            var ts2: [32]u8 = undefined;

            stmt.bindText(1, worker.id);
            bindOptText(&stmt, 2, worker.hostname);
            bindOptText(&stmt, 3, worker.queues);
            bindTimestamp(&stmt, 4, worker.last_heartbeat_ns, &ts1);
            bindTimestamp(&stmt, 5, worker.started_at_ns, &ts2);

            stmt.exec() catch {};
            stmt.reset();
            count += 1;
            if (!iter.next()) break;
        }

        self.db.commit() catch {};
        if (count > 0) std.debug.print("mirror: rebuilt {d} workers\n", .{count});
    }

    /// Scan sc| prefix — rebuild crons table.
    fn rebuildCrons(self: *Mirror, store: *kv.Store) void {
        var batch = store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const pfx = keys.prefix_cron;
        @memcpy(lower_buf[0..pfx.len], pfx);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..pfx.len]) orelse return;

        var iter = batch.newIter(lower_buf[0..pfx.len], upper);
        defer iter.close();

        if (!iter.first()) return;

        var stmt = self.db.prepare(
            "INSERT OR REPLACE INTO crons (id, name, queue, schedule, timezone, payload," ++
                " unique_key, max_retries, enabled, next_run_at, last_run_at, created_at)" ++
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ) catch return;
        defer stmt.finalize();

        self.db.begin() catch return;
        var count: u32 = 0;

        while (true) {
            const val = iter.value();
            const cron = codec.decodeCron(val);
            var ts1: [32]u8 = undefined;
            var ts2: [32]u8 = undefined;
            var ts3: [32]u8 = undefined;

            stmt.bindText(1, cron.id);
            stmt.bindText(2, cron.name);
            stmt.bindText(3, cron.queue);
            stmt.bindText(4, cron.schedule);
            stmt.bindText(5, cron.timezone);
            bindOptText(&stmt, 6, cron.payload);
            bindOptText(&stmt, 7, cron.unique_key);
            stmt.bindInt(8, @intCast(cron.max_retries));
            stmt.bindInt(9, if (cron.enabled) 1 else 0);
            if (cron.next_run_ns > 0) stmt.bindText(10, formatI64(&ts1, cron.next_run_ns)) else stmt.bindNull(10);
            if (cron.last_run_ns > 0) stmt.bindText(11, formatI64(&ts2, cron.last_run_ns)) else stmt.bindNull(11);
            if (cron.created_at_ns > 0) stmt.bindText(12, formatNs(&ts3, cron.created_at_ns)) else stmt.bindNull(12);

            stmt.exec() catch {};
            stmt.reset();
            count += 1;
            if (!iter.next()) break;
        }

        self.db.commit() catch {};
        if (count > 0) std.debug.print("mirror: rebuilt {d} crons\n", .{count});
    }

    /// Scan b| prefix — rebuild batches table.
    fn rebuildBatches(self: *Mirror, store: *kv.Store) void {
        var batch_kv = store.newBatch();
        defer batch_kv.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const pfx = keys.prefix_batch;
        @memcpy(lower_buf[0..pfx.len], pfx);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..pfx.len]) orelse return;

        var iter = batch_kv.newIter(lower_buf[0..pfx.len], upper);
        defer iter.close();

        if (!iter.first()) return;

        var stmt = self.db.prepare(
            "INSERT OR REPLACE INTO batches (id, open, total, pending, succeeded, failed," ++
                " callback_queue, callback_payload, created_at)" ++
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ) catch return;
        defer stmt.finalize();

        self.db.begin() catch return;
        var count: u32 = 0;

        while (true) {
            const val = iter.value();
            const b = codec.decodeBatch(val);
            var ts: [32]u8 = undefined;

            stmt.bindText(1, b.id);
            stmt.bindInt(2, if (b.open) 1 else 0);
            stmt.bindInt(3, @intCast(b.total));
            stmt.bindInt(4, @intCast(b.pending));
            stmt.bindInt(5, @intCast(b.succeeded));
            stmt.bindInt(6, @intCast(b.failed));
            bindOptText(&stmt, 7, b.callback_queue);
            bindOptText(&stmt, 8, b.callback_payload);
            if (b.created_at_ns > 0) stmt.bindText(9, formatNs(&ts, b.created_at_ns)) else stmt.bindNull(9);

            stmt.exec() catch {};
            stmt.reset();
            count += 1;
            if (!iter.next()) break;
        }

        self.db.commit() catch {};
        if (count > 0) std.debug.print("mirror: rebuilt {d} batches\n", .{count});
    }

    /// Scan bg| prefix — rebuild budgets table.
    fn rebuildBudgets(self: *Mirror, store: *kv.Store) void {
        var batch = store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const pfx = keys.prefix_budget;
        @memcpy(lower_buf[0..pfx.len], pfx);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..pfx.len]) orelse return;

        var iter = batch.newIter(lower_buf[0..pfx.len], upper);
        defer iter.close();

        if (!iter.first()) return;

        var stmt = self.db.prepare(
            "INSERT OR REPLACE INTO budgets (id, scope, target, daily_usd, per_job_usd, on_exceed, created_at)" ++
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
        ) catch return;
        defer stmt.finalize();

        self.db.begin() catch return;
        var count: u32 = 0;

        while (true) {
            const k = iter.key();
            const val = iter.value();
            const bg = codec.decodeBudget(val);
            var ts: [32]u8 = undefined;

            // Budget id = KV key (bg|{scope}\x00{target}).
            stmt.bindText(1, k);
            stmt.bindText(2, bg.scope);
            stmt.bindText(3, bg.target);
            stmt.bindDouble(4, bg.daily_usd);
            stmt.bindDouble(5, bg.per_job_usd);
            stmt.bindText(6, bg.on_exceed);
            if (bg.created_at_ns > 0) stmt.bindText(7, formatNs(&ts, bg.created_at_ns)) else stmt.bindNull(7);

            stmt.exec() catch {};
            stmt.reset();
            count += 1;
            if (!iter.next()) break;
        }

        self.db.commit() catch {};
        if (count > 0) std.debug.print("mirror: rebuilt {d} budgets\n", .{count});
    }

    fn applyOp(self: *Mirror, stmts: *MirrorStmts, op: *const MirrorOp) !void {
        switch (op.payload) {
            .enqueue => |*p| {
                var s = &stmts.insert_job;
                s.bindText(1, p.jobId());
                s.bindText(2, p.queueName());
                s.bindText(3, p.state.toString());
                s.bindInt(4, @intCast(p.priority));
                s.bindInt(5, @intCast(p.max_retries));
                s.bindText(6, formatNs(&stmts.ts_buf, p.created_at_ns));
                if (p.scheduled_at_ns > 0) {
                    s.bindText(7, formatNs(&stmts.ts_buf2, p.scheduled_at_ns));
                } else {
                    s.bindNull(7);
                }
                // 8: tags
                if (p.tags_len > 0) s.bindText(8, p.tagsSlice()) else s.bindNull(8);
                // 9: batch_id
                if (p.batch_id_len > 0) s.bindText(9, p.batchIdSlice()) else s.bindNull(9);
                // 10: unique_key
                if (p.unique_key_len > 0) s.bindText(10, p.uniqueKeySlice()) else s.bindNull(10);
                // 11: unique_period_s
                if (p.unique_period_s > 0) s.bindInt(11, @intCast(p.unique_period_s)) else s.bindNull(11);
                // 12: retry_backoff
                s.bindText(12, p.backoff.toString());
                // 13: retry_base_delay_ms
                s.bindInt(13, @intCast(p.base_delay_ms));
                // 14: retry_max_delay_ms
                s.bindInt(14, @intCast(p.max_delay_ms));
                // 15: parent_id
                if (p.parent_id_len > 0) s.bindText(15, p.parentIdSlice()) else s.bindNull(15);
                // 16: chain_id
                if (p.chain_id_len > 0) s.bindText(16, p.chainIdSlice()) else s.bindNull(16);
                // 17: chain_step
                s.bindInt(17, @intCast(p.chain_step));
                // 18: group_key
                if (p.group_key_len > 0) s.bindText(18, p.groupKeySlice()) else s.bindNull(18);
                // 19: expire_at
                if (p.expire_at_ns > 0) {
                    var ts3: [32]u8 = undefined;
                    s.bindText(19, formatNs(&ts3, p.expire_at_ns));
                } else {
                    s.bindNull(19);
                }
                try s.exec();
                s.reset();

                // Ensure queue exists.
                stmts.insert_queue.bindText(1, p.queueName());
                stmts.insert_queue.bindText(2, formatNs(&stmts.ts_buf, p.created_at_ns));
                try stmts.insert_queue.exec();
                stmts.insert_queue.reset();

                // Insert payload into job_payloads.
                if (p.payload_preview_len > 0) {
                    stmts.insert_payload.bindText(1, p.jobId());
                    stmts.insert_payload.bindText(2, p.payloadPreview());
                    try stmts.insert_payload.exec();
                    stmts.insert_payload.reset();
                }

                // Insert into FTS index (payload only).
                if (p.payload_preview_len > 0) {
                    stmts.insert_fts.bindText(1, p.jobId());
                    stmts.insert_fts.bindText(2, p.payloadPreview());
                    try stmts.insert_fts.exec();
                    stmts.insert_fts.reset();
                }
            },
            .fetch => |*p| {
                var s = &stmts.fetch_job;
                s.bindText(1, p.workerIdSlice());
                const lease_ns = p.now_ns + @as(u64, p.lease_duration_ms) * 1_000_000;
                s.bindText(2, formatNs(&stmts.ts_buf, lease_ns));
                s.bindText(3, formatNs(&stmts.ts_buf2, p.now_ns));
                s.bindText(4, p.jobId());
                try s.exec();
                s.reset();

                // Upsert worker registration.
                if (p.worker_id_len > 0) {
                    var w = &stmts.upsert_worker;
                    w.bindText(1, p.workerIdSlice());
                    w.bindText(2, formatNs(&stmts.ts_buf, p.now_ns));
                    w.bindText(3, formatNs(&stmts.ts_buf2, p.now_ns));
                    try w.exec();
                    w.reset();
                }
            },
            .ack => |*p| {
                var s = &stmts.ack_job;
                // 1: completed_at
                s.bindText(1, formatNs(&stmts.ts_buf, p.now_ns));
                // 2: result
                if (p.result_len > 0) s.bindText(2, p.resultSlice()) else s.bindNull(2);
                // 3: hold_reason
                if (p.hold_reason_len > 0) s.bindText(3, p.holdReasonSlice()) else s.bindNull(3);
                // 4: id (WHERE clause)
                s.bindText(4, p.jobId());
                try s.exec();
                s.reset();
            },
            .fail => |*p| {
                // Insert error.
                var e = &stmts.insert_error;
                e.bindText(1, p.jobId());
                e.bindInt(2, @intCast(p.attempt));
                e.bindText(3, p.errorMsg());
                if (p.backtrace_len > 0) e.bindText(4, p.backtraceSlice()) else e.bindNull(4);
                e.bindText(5, formatNs(&stmts.ts_buf, p.now_ns));
                try e.exec();
                e.reset();

                // Update job state.
                var s = &stmts.fail_job;
                s.bindText(1, p.new_state.toString());
                s.bindText(2, formatNs(&stmts.ts_buf, p.now_ns));
                if (p.retry_at_ns > 0) {
                    s.bindText(3, formatNs(&stmts.ts_buf2, p.retry_at_ns));
                } else {
                    s.bindNull(3);
                }
                s.bindText(4, p.jobId());
                try s.exec();
                s.reset();
            },
            .heartbeat => |*p| {
                var s = &stmts.heartbeat_worker;
                s.bindText(1, formatNs(&stmts.ts_buf, p.now_ns));
                s.bindText(2, p.workerIdSlice());
                try s.exec();
                s.reset();
            },
            .queue_config => |*p| {
                switch (p.action) {
                    .pause => {
                        var s = &stmts.update_queue_paused;
                        s.bindInt(1, 1);
                        s.bindText(2, p.queueName());
                        try s.exec();
                        s.reset();
                    },
                    .@"resume" => {
                        var s = &stmts.update_queue_paused;
                        s.bindInt(1, 0);
                        s.bindText(2, p.queueName());
                        try s.exec();
                        s.reset();
                    },
                    .concurrency => {
                        var s = &stmts.update_queue_concurrency;
                        s.bindInt(1, @intCast(p.max_concurrency));
                        s.bindText(2, p.queueName());
                        try s.exec();
                        s.reset();
                    },
                    .throttle => {
                        var s = &stmts.update_queue_throttle;
                        s.bindInt(1, @intCast(p.rate_limit));
                        s.bindInt(2, @intCast(p.rate_window_ms));
                        s.bindText(3, p.queueName());
                        try s.exec();
                        s.reset();
                    },
                    else => {},
                }
            },
            .maintenance => |*p| {
                switch (p.action) {
                    .promote => self.promoteScheduled(p.now_ns),
                    .reclaim => self.reclaimLeases(p.now_ns),
                    .expire => self.expireJobs(p.now_ns),
                    .purge => self.purgeTerminalJobs(p.now_ns),
                    else => {},
                }
            },
            .cron => |*p| {
                switch (p.action) {
                    .create, .update => {
                        const payload_slice: ?[]const u8 = if (p.payload_len > 0) p.payload[0..p.payload_len] else null;
                        const uk_slice: ?[]const u8 = if (p.unique_key_len > 0) p.unique_key[0..p.unique_key_len] else null;
                        self.upsertCron(.{
                            .id = p.cronId(),
                            .name = p.name[0..p.name_len],
                            .queue = p.queue[0..p.queue_len],
                            .schedule = p.schedule[0..p.schedule_len],
                            .timezone = if (p.timezone_len > 0) p.timezone[0..p.timezone_len] else "UTC",
                            .payload = payload_slice,
                            .unique_key = uk_slice,
                            .max_retries = p.max_retries,
                            .enabled = p.enabled,
                            .created_at_ns = p.created_at_ns,
                        });
                    },
                    .delete => self.deleteCron(p.cronId()),
                    .toggle_enabled => self.toggleCronEnabled(p.cronId(), p.enabled),
                }
            },
            .bulk_action_job => |*p| {
                switch (p.action) {
                    .delete => self.deleteJob(p.jobId()),
                    .update_state => self.updateJobState(p.jobId(), p.stateSlice(), p.now_ns),
                    .move => self.updateJobQueue(p.jobId(), p.queueSlice()),
                }
            },
            .batch_op => |*p| {
                switch (p.action) {
                    .create => self.createBatch(p.batchId(), p.created_at_ns),
                    .seal => self.sealBatch(p.batchId()),
                }
            },
            .budget_op => |*p| {
                switch (p.action) {
                    .upsert => self.upsertBudget(p.idSlice(), p.scopeSlice(), p.targetSlice(), p.daily_usd, p.per_job_usd, p.onExceedSlice()),
                    .delete => self.deleteBudgetRecord(p.scopeSlice(), p.targetSlice()),
                }
            },
            .queue_op => |*p| {
                switch (p.action) {
                    .clear => self.clearQueueJobs(p.queueName()),
                    .delete => self.deleteQueueRecord(p.queueName()),
                }
            },
            .heartbeat_job => |*p| {
                self.heartbeatJob(p.jobId(), p.progressSlice(), p.checkpointSlice(), p.lease_expires_ns);
            },
            .approval_policy => |*p| {
                switch (p.action) {
                    .upsert => self.upsertApprovalPolicy(p),
                    .delete => self.deleteApprovalPolicy(p.idSlice()),
                }
            },
            .noop => {},
        }
    }

    // ========================================================================
    // Stats
    // ========================================================================

    pub fn stats(self: *const Mirror) MirrorStats {
        return .{
            .queued = self.queued.load(.monotonic),
            .committed = self.committed.load(.monotonic),
            .dropped = self.dropped.load(.monotonic),
            .rebuilds = self.rebuilds.load(.monotonic),
        };
    }

    /// Get the underlying SQLite DB for read queries.
    pub fn getDB(self: *Mirror) *sqlite.DB {
        return &self.db;
    }

    /// Purge terminal jobs from SQLite mirror older than cutoff_ns.
    /// Runs directly on the DB (not through the ring buffer) since purge
    /// is a bulk operation that doesn't need per-job queueing.
    /// CASCADE handles job_payloads and job_errors. We manually delete
    /// jobs_fts (contentless FTS5).
    pub fn purgeTerminalJobs(self: *Mirror, cutoff_ns: u64) void {
        // Delete FTS entries for jobs being purged (contentless FTS5, no CASCADE).
        var del_fts = self.db.prepare(
            "DELETE FROM jobs_fts WHERE job_id IN " ++
                "(SELECT id FROM jobs WHERE state IN ('completed','dead','cancelled') " ++
                "AND completed_at IS NOT NULL AND CAST(completed_at AS INTEGER) < ?)",
        ) catch return;
        defer del_fts.finalize();
        del_fts.bindInt64(1, @intCast(cutoff_ns));
        del_fts.exec() catch {};
        del_fts.reset();

        // Delete jobs (CASCADE deletes job_payloads and job_errors).
        var del_jobs = self.db.prepare(
            "DELETE FROM jobs WHERE state IN ('completed','dead','cancelled') " ++
                "AND completed_at IS NOT NULL AND CAST(completed_at AS INTEGER) < ?",
        ) catch return;
        defer del_jobs.finalize();
        del_jobs.bindInt64(1, @intCast(cutoff_ns));
        del_jobs.exec() catch {};
        del_jobs.reset();
    }

    // ========================================================================
    // Direct SQL methods for cold-path mirror sync
    // ========================================================================
    // These run directly on the DB (not through the ring buffer) for
    // infrequent admin/maintenance operations. Same pattern as purgeTerminalJobs.

    /// Promote scheduled jobs whose scheduled_at has passed.
    pub fn promoteScheduled(self: *Mirror, now_ns: u64) void {
        // Promote scheduled → pending.
        {
            var stmt = self.db.prepare(
                "UPDATE jobs SET state = 'pending', scheduled_at = NULL" ++
                    " WHERE state = 'scheduled' AND scheduled_at IS NOT NULL AND CAST(scheduled_at AS INTEGER) <= ?",
            ) catch return;
            defer stmt.finalize();
            stmt.bindInt64(1, @intCast(now_ns));
            stmt.exec() catch {};
        }
        // Promote retrying → pending (KV handler promotes both in applyPromote).
        {
            var stmt = self.db.prepare(
                "UPDATE jobs SET state = 'pending', scheduled_at = NULL" ++
                    " WHERE state = 'retrying' AND scheduled_at IS NOT NULL AND CAST(scheduled_at AS INTEGER) <= ?",
            ) catch return;
            defer stmt.finalize();
            stmt.bindInt64(1, @intCast(now_ns));
            stmt.exec() catch {};
        }
    }

    /// Reclaim jobs with expired leases — return to pending or move to dead.
    pub fn reclaimLeases(self: *Mirror, now_ns: u64) void {
        var stmt = self.db.prepare(
            "UPDATE jobs SET state = 'pending', worker_id = NULL, hostname = NULL, lease_expires_at = NULL" ++
                " WHERE state = 'active' AND lease_expires_at IS NOT NULL AND CAST(lease_expires_at AS INTEGER) <= ?",
        ) catch return;
        defer stmt.finalize();
        stmt.bindInt64(1, @intCast(now_ns));
        stmt.exec() catch {};
    }

    /// Expire jobs whose expire_at has passed.
    pub fn expireJobs(self: *Mirror, now_ns: u64) void {
        var stmt = self.db.prepare(
            "UPDATE jobs SET state = 'dead', failed_at = ?" ++
                " WHERE state = 'pending' AND expire_at IS NOT NULL AND CAST(expire_at AS INTEGER) <= ?",
        ) catch return;
        defer stmt.finalize();
        var ts_buf: [32]u8 = undefined;
        stmt.bindText(1, std.fmt.bufPrint(&ts_buf, "{d}", .{now_ns}) catch return);
        stmt.bindInt64(2, @intCast(now_ns));
        stmt.exec() catch {};
    }

    /// Clear all jobs from a queue in the mirror.
    pub fn clearQueueJobs(self: *Mirror, queue_name: []const u8) void {
        // Only clear pending/scheduled/retrying jobs — active/held/terminal stay.
        var del_fts = self.db.prepare(
            "DELETE FROM jobs_fts WHERE job_id IN " ++
                "(SELECT id FROM jobs WHERE queue = ? AND state IN ('pending', 'scheduled', 'retrying'))",
        ) catch return;
        defer del_fts.finalize();
        del_fts.bindText(1, queue_name);
        del_fts.exec() catch {};

        // Delete jobs (CASCADE handles payloads + errors).
        var del_jobs = self.db.prepare(
            "DELETE FROM jobs WHERE queue = ? AND state IN ('pending', 'scheduled', 'retrying')",
        ) catch return;
        defer del_jobs.finalize();
        del_jobs.bindText(1, queue_name);
        del_jobs.exec() catch {};
    }

    /// Delete a queue record and all its jobs from the mirror.
    pub fn deleteQueueRecord(self: *Mirror, queue_name: []const u8) void {
        // Delete ALL jobs for this queue (not just clearable ones).
        var del_fts = self.db.prepare(
            "DELETE FROM jobs_fts WHERE job_id IN (SELECT id FROM jobs WHERE queue = ?)",
        ) catch return;
        defer del_fts.finalize();
        del_fts.bindText(1, queue_name);
        del_fts.exec() catch {};

        var del_jobs = self.db.prepare("DELETE FROM jobs WHERE queue = ?") catch return;
        defer del_jobs.finalize();
        del_jobs.bindText(1, queue_name);
        del_jobs.exec() catch {};

        var stmt = self.db.prepare("DELETE FROM queues WHERE name = ?") catch return;
        defer stmt.finalize();
        stmt.bindText(1, queue_name);
        stmt.exec() catch {};
    }

    /// Create a batch record in the mirror.
    pub fn createBatch(self: *Mirror, batch_id: []const u8, now_ns: u64) void {
        var ts_buf: [32]u8 = undefined;
        const now_str = std.fmt.bufPrint(&ts_buf, "{d}", .{now_ns}) catch return;
        var stmt = self.db.prepare(
            "INSERT OR IGNORE INTO batches (id, open, total, pending, succeeded, failed, created_at)" ++
                " VALUES (?, 1, 0, 0, 0, 0, ?)",
        ) catch return;
        defer stmt.finalize();
        stmt.bindText(1, batch_id);
        stmt.bindText(2, now_str);
        stmt.exec() catch {};
    }

    /// Seal a batch in the mirror.
    pub fn sealBatch(self: *Mirror, batch_id: []const u8) void {
        var stmt = self.db.prepare("UPDATE batches SET open = 0 WHERE id = ?") catch return;
        defer stmt.finalize();
        stmt.bindText(1, batch_id);
        stmt.exec() catch {};
    }

    /// Upsert a budget in the mirror.
    pub fn upsertBudget(self: *Mirror, id: []const u8, scope: []const u8, target: []const u8, daily_usd: f64, per_job_usd: f64, on_exceed: []const u8) void {
        var stmt = self.db.prepare(
            "INSERT OR REPLACE INTO budgets (id, scope, target, daily_usd, per_job_usd, on_exceed)" ++
                " VALUES (?, ?, ?, ?, ?, ?)",
        ) catch return;
        defer stmt.finalize();
        stmt.bindText(1, id);
        stmt.bindText(2, scope);
        stmt.bindText(3, target);
        stmt.bindDouble(4, daily_usd);
        stmt.bindDouble(5, per_job_usd);
        stmt.bindText(6, on_exceed);
        stmt.exec() catch {};
    }

    /// Delete a budget from the mirror.
    pub fn deleteBudgetRecord(self: *Mirror, scope: []const u8, target: []const u8) void {
        var stmt = self.db.prepare("DELETE FROM budgets WHERE scope = ? AND target = ?") catch return;
        defer stmt.finalize();
        stmt.bindText(1, scope);
        stmt.bindText(2, target);
        stmt.exec() catch {};
    }

    fn upsertApprovalPolicy(self: *Mirror, p: *const MirrorOp.ApprovalPolicyPayload) void {
        var stmt = self.db.prepare(
            "INSERT OR REPLACE INTO approval_policies (id, name, mode, enabled, queue, tag_key, tag_value)" ++
                " VALUES (?, ?, ?, ?, ?, ?, ?)",
        ) catch return;
        defer stmt.finalize();
        stmt.bindText(1, p.idSlice());
        stmt.bindText(2, p.nameSlice());
        stmt.bindText(3, p.modeSlice());
        stmt.bindInt(4, if (p.enabled) 1 else 0);
        stmt.bindText(5, if (p.queue_len > 0) p.queueSlice() else "");
        stmt.bindText(6, if (p.tag_key_len > 0) p.tagKeySlice() else "");
        stmt.bindText(7, if (p.tag_value_len > 0) p.tagValueSlice() else "");
        stmt.exec() catch {};
    }

    fn deleteApprovalPolicy(self: *Mirror, id: []const u8) void {
        var stmt = self.db.prepare("DELETE FROM approval_policies WHERE id = ?") catch return;
        defer stmt.finalize();
        stmt.bindText(1, id);
        stmt.exec() catch {};
    }

    /// Create or update a cron schedule in the mirror.
    pub fn upsertCron(self: *Mirror, opts: CronUpsertOpts) void {
        var stmt = self.db.prepare(
            "INSERT OR REPLACE INTO crons (id, name, queue, schedule, timezone, payload, unique_key, max_retries, enabled, created_at)" ++
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        ) catch return;
        defer stmt.finalize();
        stmt.bindText(1, opts.id);
        stmt.bindText(2, opts.name);
        stmt.bindText(3, opts.queue);
        stmt.bindText(4, opts.schedule);
        stmt.bindText(5, opts.timezone);
        if (opts.payload) |p| stmt.bindText(6, p) else stmt.bindNull(6);
        if (opts.unique_key) |uk| stmt.bindText(7, uk) else stmt.bindNull(7);
        stmt.bindInt(8, @intCast(opts.max_retries));
        stmt.bindInt(9, if (opts.enabled) 1 else 0);
        if (opts.created_at_ns > 0) {
            var ts_buf: [32]u8 = undefined;
            stmt.bindText(10, formatNs(&ts_buf, opts.created_at_ns));
        } else {
            stmt.bindNull(10);
        }
        stmt.exec() catch {};
    }

    pub const CronUpsertOpts = struct {
        id: []const u8,
        name: []const u8,
        queue: []const u8,
        schedule: []const u8,
        timezone: []const u8 = "UTC",
        payload: ?[]const u8 = null,
        unique_key: ?[]const u8 = null,
        max_retries: u16 = 0,
        enabled: bool = true,
        created_at_ns: u64 = 0,
    };

    /// Toggle cron enabled state in the mirror.
    fn toggleCronEnabled(self: *Mirror, cron_id: []const u8, enabled: bool) void {
        var stmt = self.db.prepare("UPDATE crons SET enabled = ? WHERE id = ?") catch return;
        defer stmt.finalize();
        stmt.bindInt(1, if (enabled) 1 else 0);
        stmt.bindText(2, cron_id);
        stmt.exec() catch {};
    }

    /// Delete a cron schedule from the mirror.
    pub fn deleteCron(self: *Mirror, cron_id: []const u8) void {
        var stmt = self.db.prepare("DELETE FROM crons WHERE id = ?") catch return;
        defer stmt.finalize();
        stmt.bindText(1, cron_id);
        stmt.exec() catch {};
    }

    /// Update a single job's state in the mirror (used for bulk action sync).
    pub fn updateJobState(self: *Mirror, job_id: []const u8, state: []const u8, now_ns: u64) void {
        var ts_buf: [32]u8 = undefined;
        const now_str = std.fmt.bufPrint(&ts_buf, "{d}", .{now_ns}) catch return;
        // Use a general update that covers the common bulk action transitions.
        if (std.mem.eql(u8, state, "completed") or std.mem.eql(u8, state, "dead") or std.mem.eql(u8, state, "cancelled")) {
            var stmt = self.db.prepare(
                "UPDATE jobs SET state = ?, completed_at = ?, worker_id = NULL, lease_expires_at = NULL WHERE id = ?",
            ) catch return;
            defer stmt.finalize();
            stmt.bindText(1, state);
            stmt.bindText(2, now_str);
            stmt.bindText(3, job_id);
            stmt.exec() catch {};
        } else if (std.mem.eql(u8, state, "pending")) {
            var stmt = self.db.prepare(
                "UPDATE jobs SET state = 'pending', worker_id = NULL, lease_expires_at = NULL, completed_at = NULL WHERE id = ?",
            ) catch return;
            defer stmt.finalize();
            stmt.bindText(1, job_id);
            stmt.exec() catch {};
        } else {
            var stmt = self.db.prepare("UPDATE jobs SET state = ? WHERE id = ?") catch return;
            defer stmt.finalize();
            stmt.bindText(1, state);
            stmt.bindText(2, job_id);
            stmt.exec() catch {};
        }
    }

    pub fn updateJobQueue(self: *Mirror, job_id: []const u8, queue: []const u8) void {
        var stmt = self.db.prepare("UPDATE jobs SET queue = ? WHERE id = ?") catch return;
        defer stmt.finalize();
        stmt.bindText(1, queue);
        stmt.bindText(2, job_id);
        stmt.exec() catch {};
    }

    /// Update a job's progress, checkpoint, and lease in the mirror (heartbeat).
    pub fn heartbeatJob(self: *Mirror, job_id: []const u8, progress: ?[]const u8, checkpoint: ?[]const u8, lease_expires_ns: u64) void {
        var ts_buf: [32]u8 = undefined;
        const lease_str = std.fmt.bufPrint(&ts_buf, "{d}", .{lease_expires_ns}) catch return;

        if (progress != null and checkpoint != null) {
            var stmt = self.db.prepare(
                "UPDATE jobs SET progress = ?, checkpoint = ?, lease_expires_at = ? WHERE id = ? AND state = 'active'",
            ) catch return;
            defer stmt.finalize();
            stmt.bindText(1, progress.?);
            stmt.bindText(2, checkpoint.?);
            stmt.bindText(3, lease_str);
            stmt.bindText(4, job_id);
            stmt.exec() catch {};
        } else if (progress != null) {
            var stmt = self.db.prepare(
                "UPDATE jobs SET progress = ?, lease_expires_at = ? WHERE id = ? AND state = 'active'",
            ) catch return;
            defer stmt.finalize();
            stmt.bindText(1, progress.?);
            stmt.bindText(2, lease_str);
            stmt.bindText(3, job_id);
            stmt.exec() catch {};
        } else if (checkpoint != null) {
            var stmt = self.db.prepare(
                "UPDATE jobs SET checkpoint = ?, lease_expires_at = ? WHERE id = ? AND state = 'active'",
            ) catch return;
            defer stmt.finalize();
            stmt.bindText(1, checkpoint.?);
            stmt.bindText(2, lease_str);
            stmt.bindText(3, job_id);
            stmt.exec() catch {};
        } else {
            var stmt = self.db.prepare(
                "UPDATE jobs SET lease_expires_at = ? WHERE id = ? AND state = 'active'",
            ) catch return;
            defer stmt.finalize();
            stmt.bindText(1, lease_str);
            stmt.bindText(2, job_id);
            stmt.exec() catch {};
        }
    }

    /// Delete a single job from the mirror (including FTS).
    pub fn deleteJob(self: *Mirror, job_id: []const u8) void {
        // FTS (contentless, no CASCADE).
        var del_fts = self.db.prepare("DELETE FROM jobs_fts WHERE job_id = ?") catch return;
        defer del_fts.finalize();
        del_fts.bindText(1, job_id);
        del_fts.exec() catch {};

        // Job (CASCADE handles payloads + errors).
        var del_job = self.db.prepare("DELETE FROM jobs WHERE id = ?") catch return;
        defer del_job.finalize();
        del_job.bindText(1, job_id);
        del_job.exec() catch {};
    }
};

pub const MirrorStats = struct {
    queued: u64 = 0,
    committed: u64 = 0,
    dropped: u64 = 0,
    rebuilds: u64 = 0,
};

// ============================================================================
// Prepared statements
// ============================================================================

const MirrorStmts = struct {
    insert_job: sqlite.Stmt,
    insert_queue: sqlite.Stmt,
    fetch_job: sqlite.Stmt,
    ack_job: sqlite.Stmt,
    fail_job: sqlite.Stmt,
    insert_error: sqlite.Stmt,
    heartbeat_worker: sqlite.Stmt,
    upsert_worker: sqlite.Stmt,
    update_queue_paused: sqlite.Stmt,
    update_queue_concurrency: sqlite.Stmt,
    update_queue_throttle: sqlite.Stmt,
    insert_fts: sqlite.Stmt,
    insert_payload: sqlite.Stmt,

    // Shared timestamp formatting buffers.
    ts_buf: [32]u8 = undefined,
    ts_buf2: [32]u8 = undefined,

    fn init(db: *sqlite.DB) !MirrorStmts {
        return .{
            .insert_job = try db.prepare(
                "INSERT OR REPLACE INTO jobs (id, queue, state, priority, max_retries, created_at, scheduled_at," ++
                    " tags, batch_id, unique_key, unique_period_s," ++
                    " retry_backoff, retry_base_delay_ms, retry_max_delay_ms," ++
                    " parent_id, chain_id, chain_step, group_key, expire_at)" ++
                    " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ),
            .insert_queue = try db.prepare(
                "INSERT OR IGNORE INTO queues (name, created_at) VALUES (?, ?)",
            ),
            .fetch_job = try db.prepare(
                "UPDATE jobs SET state = 'active', worker_id = ?, lease_expires_at = ?," ++
                    " started_at = ?, attempt = attempt + 1 WHERE id = ?",
            ),
            .ack_job = try db.prepare(
                "UPDATE jobs SET state = 'completed', completed_at = ?," ++
                    " result = ?, hold_reason = ?," ++
                    " worker_id = NULL, lease_expires_at = NULL WHERE id = ? AND state = 'active'",
            ),
            .fail_job = try db.prepare(
                "UPDATE jobs SET state = ?, failed_at = ?, scheduled_at = ? WHERE id = ?",
            ),
            .insert_error = try db.prepare(
                "INSERT INTO job_errors (job_id, attempt, error, backtrace, created_at) VALUES (?, ?, ?, ?, ?)",
            ),
            .heartbeat_worker = try db.prepare(
                "UPDATE workers SET last_heartbeat = ? WHERE id = ?",
            ),
            .upsert_worker = try db.prepare(
                "INSERT INTO workers (id, last_heartbeat, started_at) VALUES (?, ?, ?)" ++
                    " ON CONFLICT(id) DO UPDATE SET last_heartbeat = excluded.last_heartbeat",
            ),
            .update_queue_paused = try db.prepare(
                "UPDATE queues SET paused = ? WHERE name = ?",
            ),
            .update_queue_concurrency = try db.prepare(
                "UPDATE queues SET max_concurrency = ? WHERE name = ?",
            ),
            .update_queue_throttle = try db.prepare(
                "UPDATE queues SET rate_limit = ?, rate_window_ms = ? WHERE name = ?",
            ),
            .insert_fts = try db.prepare(
                "INSERT INTO jobs_fts (job_id, payload) VALUES (?, ?)",
            ),
            .insert_payload = try db.prepare(
                "INSERT OR REPLACE INTO job_payloads (job_id, payload) VALUES (?, ?)",
            ),
        };
    }

    fn deinit(self: *MirrorStmts) void {
        self.insert_job.finalize();
        self.insert_queue.finalize();
        self.fetch_job.finalize();
        self.ack_job.finalize();
        self.fail_job.finalize();
        self.insert_error.finalize();
        self.heartbeat_worker.finalize();
        self.upsert_worker.finalize();
        self.update_queue_paused.finalize();
        self.update_queue_concurrency.finalize();
        self.update_queue_throttle.finalize();
        self.insert_fts.finalize();
        self.insert_payload.finalize();
    }
};

// ============================================================================
// Timestamp formatting
// ============================================================================

/// Format nanoseconds as a simple numeric string for SQLite storage.
/// We use integer nanoseconds rather than RFC3339 for simplicity in Zig.
fn formatNs(buf: *[32]u8, ns: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{ns}) catch "0";
}

/// Format signed i64 nanoseconds (used for cron next_run_ns/last_run_ns).
fn formatI64(buf: *[32]u8, ns: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{ns}) catch "0";
}

/// Bind an optional text field — NULL if null, text if non-null.
fn bindOptText(stmt: *sqlite.Stmt, idx: c_int, val: ?[]const u8) void {
    if (val) |v| {
        if (v.len > 0) stmt.bindText(idx, v) else stmt.bindNull(idx);
    } else {
        stmt.bindNull(idx);
    }
}

/// Bind a u64 timestamp — NULL if zero, formatted nanosecond string otherwise.
fn bindTimestamp(stmt: *sqlite.Stmt, idx: c_int, ns: u64, buf: *[32]u8) void {
    if (ns > 0) {
        stmt.bindText(idx, formatNs(buf, ns));
    } else {
        stmt.bindNull(idx);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "mirror enqueue and flush" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Enqueue a job.
    mirror.enqueueJob(&.{
        .job_id = "test-job-1",
        .queue = "default",
        .priority = 2,
        .max_retries = 3,
        .created_at_ns = 1_000_000_000,
    });

    // Flush synchronously.
    try mirror.flush();

    // Verify in SQLite.
    var stmt = try mirror.db.prepare("SELECT id, queue, state FROM jobs WHERE id = 'test-job-1'");
    defer stmt.finalize();
    const has_row = try stmt.step();
    try std.testing.expect(has_row);
    try std.testing.expectEqualStrings("test-job-1", stmt.columnText(0).?);
    try std.testing.expectEqualStrings("default", stmt.columnText(1).?);
    try std.testing.expectEqualStrings("pending", stmt.columnText(2).?);

    const s = mirror.stats();
    try std.testing.expectEqual(@as(u64, 1), s.queued);
    try std.testing.expectEqual(@as(u64, 1), s.committed);
}

test "mirror lifecycle" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Enqueue
    mirror.enqueueJob(&.{
        .job_id = "lc-1",
        .queue = "q1",
        .priority = 2,
        .max_retries = 3,
        .created_at_ns = 1_000_000_000,
    });
    try mirror.flush();

    // Fetch
    var fetch_payload = MirrorOp.FetchPayload{
        .now_ns = 2_000_000_000,
        .lease_duration_ms = 30000,
    };
    const fid = "lc-1";
    @memcpy(fetch_payload.job_id[0..fid.len], fid);
    fetch_payload.job_id_len = fid.len;
    const wid = "worker-1";
    @memcpy(fetch_payload.worker_id[0..wid.len], wid);
    fetch_payload.worker_id_len = wid.len;

    mirror.enqueue(.{ .op_type = .fetch, .payload = .{ .fetch = fetch_payload } });
    try mirror.flush();

    // Verify active.
    {
        var stmt = try mirror.db.prepare("SELECT state, worker_id FROM jobs WHERE id = 'lc-1'");
        defer stmt.finalize();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("active", stmt.columnText(0).?);
        try std.testing.expectEqualStrings("worker-1", stmt.columnText(1).?);
    }

    // Ack
    var ack_payload = MirrorOp.AckPayload{
        .now_ns = 3_000_000_000,
    };
    @memcpy(ack_payload.job_id[0..fid.len], fid);
    ack_payload.job_id_len = fid.len;

    mirror.enqueue(.{ .op_type = .ack, .payload = .{ .ack = ack_payload } });
    try mirror.flush();

    // Verify completed.
    {
        var stmt = try mirror.db.prepare("SELECT state FROM jobs WHERE id = 'lc-1'");
        defer stmt.finalize();
        _ = try stmt.step();
        try std.testing.expectEqualStrings("completed", stmt.columnText(0).?);
    }
}

test "mirror purge terminal jobs" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Enqueue two jobs.
    mirror.enqueueJob(&.{
        .job_id = "old-1",
        .queue = "q1",
        .priority = 2,
        .created_at_ns = 1_000_000_000,
    });
    mirror.enqueueJob(&.{
        .job_id = "new-1",
        .queue = "q1",
        .priority = 2,
        .created_at_ns = 5_000_000_000,
    });
    try mirror.flush();

    // Fetch both.
    for ([_][]const u8{ "old-1", "new-1" }) |jid| {
        var fp = MirrorOp.FetchPayload{
            .now_ns = 2_000_000_000,
            .lease_duration_ms = 30000,
        };
        @memcpy(fp.job_id[0..jid.len], jid);
        fp.job_id_len = @intCast(jid.len);
        const wid = "w1";
        @memcpy(fp.worker_id[0..wid.len], wid);
        fp.worker_id_len = wid.len;
        mirror.enqueue(.{ .op_type = .fetch, .payload = .{ .fetch = fp } });
    }
    try mirror.flush();

    // Ack old-1 at t=3s, new-1 at t=8s.
    for ([_]struct { id: []const u8, ns: u64 }{
        .{ .id = "old-1", .ns = 3_000_000_000 },
        .{ .id = "new-1", .ns = 8_000_000_000 },
    }) |a| {
        var ap = MirrorOp.AckPayload{ .now_ns = a.ns };
        @memcpy(ap.job_id[0..a.id.len], a.id);
        ap.job_id_len = @intCast(a.id.len);
        mirror.enqueue(.{ .op_type = .ack, .payload = .{ .ack = ap } });
    }
    try mirror.flush();

    // Both jobs completed.
    {
        var stmt = try mirror.db.prepare("SELECT COUNT(*) FROM jobs WHERE state = 'completed'");
        defer stmt.finalize();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 2), stmt.columnInt(0));
    }

    // Purge with cutoff at t=5s — should delete old-1 (completed_at=3s) but keep new-1 (completed_at=8s).
    mirror.purgeTerminalJobs(5_000_000_000);

    // old-1 gone.
    {
        var stmt = try mirror.db.prepare("SELECT COUNT(*) FROM jobs WHERE id = 'old-1'");
        defer stmt.finalize();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
    }

    // new-1 still there.
    {
        var stmt = try mirror.db.prepare("SELECT COUNT(*) FROM jobs WHERE id = 'new-1'");
        defer stmt.finalize();
        _ = try stmt.step();
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    }
}

// ============================================================================
// Tests — Direct SQL mirror sync methods
// ============================================================================

/// Helper: insert a job directly into the mirror SQLite for test setup.
fn testInsertJob(mirror: *Mirror, id: []const u8, queue: []const u8, state: []const u8) void {
    var stmt = mirror.db.prepare(
        "INSERT OR REPLACE INTO jobs (id, queue, state, created_at) VALUES (?, ?, ?, '1000000000')",
    ) catch return;
    defer stmt.finalize();
    stmt.bindText(1, id);
    stmt.bindText(2, queue);
    stmt.bindText(3, state);
    stmt.exec() catch {};
}

/// Helper: query a single column text value from SQLite.
fn testQueryText(mirror: *Mirror, sql: [*:0]const u8, bind1: []const u8) ?[]const u8 {
    var stmt = mirror.db.prepare(sql) catch return null;
    defer stmt.finalize();
    stmt.bindText(1, bind1);
    if (stmt.step() catch null) |has_row| {
        if (has_row) return stmt.columnText(0);
    }
    return null;
}

/// Helper: query a single count from SQLite.
fn testQueryCount(mirror: *Mirror, sql: [*:0]const u8) i64 {
    var stmt = mirror.db.prepare(sql) catch return -1;
    defer stmt.finalize();
    _ = stmt.step() catch return -1;
    return stmt.columnInt(0);
}

/// Helper: query a count with a text binding.
fn testQueryCountBind(mirror: *Mirror, sql: [*:0]const u8, bind1: []const u8) i64 {
    var stmt = mirror.db.prepare(sql) catch return -1;
    defer stmt.finalize();
    stmt.bindText(1, bind1);
    _ = stmt.step() catch return -1;
    return stmt.columnInt(0);
}

test "mirror promote scheduled jobs" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Insert a scheduled job with scheduled_at in the past.
    {
        var stmt = try mirror.db.prepare(
            "INSERT INTO jobs (id, queue, state, scheduled_at, created_at) VALUES ('sj-1', 'q1', 'scheduled', '1000000000', '500000000')",
        );
        defer stmt.finalize();
        try stmt.exec();
    }
    // Insert a scheduled job with scheduled_at in the future.
    {
        var stmt = try mirror.db.prepare(
            "INSERT INTO jobs (id, queue, state, scheduled_at, created_at) VALUES ('sj-2', 'q1', 'scheduled', '9000000000', '500000000')",
        );
        defer stmt.finalize();
        try stmt.exec();
    }

    // Promote with cutoff at t=5s — sj-1 should promote, sj-2 should stay.
    mirror.promoteScheduled(5_000_000_000);

    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ? AND state = 'pending'", "sj-1"));
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ? AND state = 'scheduled'", "sj-2"));
}

test "mirror reclaim expired leases" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Insert an active job with expired lease.
    {
        var stmt = try mirror.db.prepare(
            "INSERT INTO jobs (id, queue, state, worker_id, hostname, lease_expires_at, created_at)" ++
                " VALUES ('aj-1', 'q1', 'active', 'w1', 'host1', '1000000000', '500000000')",
        );
        defer stmt.finalize();
        try stmt.exec();
    }
    // Insert an active job with future lease.
    {
        var stmt = try mirror.db.prepare(
            "INSERT INTO jobs (id, queue, state, worker_id, hostname, lease_expires_at, created_at)" ++
                " VALUES ('aj-2', 'q1', 'active', 'w2', 'host2', '9000000000', '500000000')",
        );
        defer stmt.finalize();
        try stmt.exec();
    }

    // Reclaim with cutoff at t=5s.
    mirror.reclaimLeases(5_000_000_000);

    // aj-1 should be reclaimed to pending with cleared worker/hostname/lease.
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ? AND state = 'pending'", "aj-1"));
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror,
        "SELECT COUNT(*) FROM jobs WHERE id = ? AND worker_id IS NULL AND hostname IS NULL AND lease_expires_at IS NULL", "aj-1"));
    // aj-2 should remain active.
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ? AND state = 'active'", "aj-2"));
}

test "mirror expire jobs" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Insert an active job with expired expire_at.
    {
        var stmt = try mirror.db.prepare(
            "INSERT INTO jobs (id, queue, state, expire_at, created_at) VALUES ('ej-1', 'q1', 'pending', '2000000000', '500000000')",
        );
        defer stmt.finalize();
        try stmt.exec();
    }
    // Insert an active job with future expire_at.
    {
        var stmt = try mirror.db.prepare(
            "INSERT INTO jobs (id, queue, state, expire_at, created_at) VALUES ('ej-2', 'q1', 'pending', '9000000000', '500000000')",
        );
        defer stmt.finalize();
        try stmt.exec();
    }

    mirror.expireJobs(5_000_000_000);

    // ej-1 should be dead with failed_at set.
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ? AND state = 'dead'", "ej-1"));
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ? AND failed_at IS NOT NULL", "ej-1"));
    // ej-2 should remain pending (expire_at in the future).
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ? AND state = 'pending'", "ej-2"));
}

test "mirror clear queue jobs" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Insert jobs in two different queues + payloads + FTS.
    for ([_]struct { id: []const u8, q: []const u8 }{
        .{ .id = "cq-1", .q = "target" },
        .{ .id = "cq-2", .q = "target" },
        .{ .id = "cq-3", .q = "other" },
    }) |j| {
        testInsertJob(&mirror, j.id, j.q, "pending");
        // Insert payload.
        var ps = mirror.db.prepare("INSERT INTO job_payloads (job_id, payload) VALUES (?, 'test payload')") catch continue;
        defer ps.finalize();
        ps.bindText(1, j.id);
        ps.exec() catch {};
    }

    // Clear "target" queue.
    mirror.clearQueueJobs("target");

    // target queue jobs should be gone.
    try std.testing.expectEqual(@as(i64, 0), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE queue = ?", "target"));
    try std.testing.expectEqual(@as(i64, 0), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM job_payloads WHERE job_id = ?", "cq-1"));
    // other queue job should remain.
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE queue = ?", "other"));
}

test "mirror delete queue record" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Insert queue record + jobs.
    {
        var stmt = try mirror.db.prepare("INSERT INTO queues (name) VALUES ('delq')");
        defer stmt.finalize();
        try stmt.exec();
    }
    testInsertJob(&mirror, "dq-1", "delq", "pending");
    testInsertJob(&mirror, "dq-2", "delq", "pending");

    mirror.deleteQueueRecord("delq");

    // Queue and its jobs should be gone.
    try std.testing.expectEqual(@as(i64, 0), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM queues WHERE name = ?", "delq"));
    try std.testing.expectEqual(@as(i64, 0), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE queue = ?", "delq"));
}

test "mirror batch create and seal" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    mirror.createBatch("batch-1", 1_000_000_000);

    // Verify batch exists and is open.
    {
        var stmt = try mirror.db.prepare("SELECT open FROM batches WHERE id = 'batch-1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(0));
    }

    mirror.sealBatch("batch-1");

    // Verify batch is sealed.
    {
        var stmt = try mirror.db.prepare("SELECT open FROM batches WHERE id = 'batch-1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
    }
}

test "mirror budget upsert and delete" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    mirror.upsertBudget("b1", "queue", "default", 100.0, 5.0, "hold");

    // Verify budget exists.
    {
        var stmt = try mirror.db.prepare("SELECT scope, target, daily_usd, per_job_usd, on_exceed FROM budgets WHERE id = 'b1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("queue", stmt.columnText(0).?);
        try std.testing.expectEqualStrings("default", stmt.columnText(1).?);
        try std.testing.expectEqual(@as(f64, 100.0), stmt.columnDouble(2));
        try std.testing.expectEqual(@as(f64, 5.0), stmt.columnDouble(3));
        try std.testing.expectEqualStrings("hold", stmt.columnText(4).?);
    }

    // Update budget.
    mirror.upsertBudget("b1", "queue", "default", 200.0, 10.0, "reject");
    {
        var stmt = try mirror.db.prepare("SELECT daily_usd, on_exceed FROM budgets WHERE id = 'b1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqual(@as(f64, 200.0), stmt.columnDouble(0));
        try std.testing.expectEqualStrings("reject", stmt.columnText(1).?);
    }

    // Delete budget.
    mirror.deleteBudgetRecord("queue", "default");
    try std.testing.expectEqual(@as(i64, 0), testQueryCount(&mirror, "SELECT COUNT(*) FROM budgets"));
}

test "mirror cron upsert and delete" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    mirror.upsertCron(.{ .id = "cron-1", .name = "daily-report", .queue = "reports", .schedule = "0 0 * * *" });

    // Verify cron exists.
    {
        var stmt = try mirror.db.prepare("SELECT name, queue, schedule, enabled, timezone FROM crons WHERE id = 'cron-1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("daily-report", stmt.columnText(0).?);
        try std.testing.expectEqualStrings("reports", stmt.columnText(1).?);
        try std.testing.expectEqualStrings("0 0 * * *", stmt.columnText(2).?);
        try std.testing.expectEqual(@as(i64, 1), stmt.columnInt(3));
        try std.testing.expectEqualStrings("UTC", stmt.columnText(4).?);
    }

    // Update cron (disable).
    mirror.upsertCron(.{ .id = "cron-1", .name = "daily-report", .queue = "reports", .schedule = "0 0 * * *", .enabled = false });
    {
        var stmt = try mirror.db.prepare("SELECT enabled FROM crons WHERE id = 'cron-1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqual(@as(i64, 0), stmt.columnInt(0));
    }

    // Delete cron.
    mirror.deleteCron("cron-1");
    try std.testing.expectEqual(@as(i64, 0), testQueryCount(&mirror, "SELECT COUNT(*) FROM crons"));
}

test "mirror heartbeat job progress and checkpoint" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Insert an active job.
    {
        var stmt = try mirror.db.prepare(
            "INSERT INTO jobs (id, queue, state, created_at) VALUES ('hb-1', 'q1', 'active', '1000000000')",
        );
        defer stmt.finalize();
        try stmt.exec();
    }

    // Heartbeat with progress only.
    mirror.heartbeatJob("hb-1", "50%", null, 5_000_000_000);
    {
        var stmt = try mirror.db.prepare("SELECT progress, checkpoint, lease_expires_at FROM jobs WHERE id = 'hb-1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("50%", stmt.columnText(0).?);
        try std.testing.expect(stmt.columnText(1) == null); // checkpoint unchanged
        try std.testing.expectEqualStrings("5000000000", stmt.columnText(2).?);
    }

    // Heartbeat with checkpoint only.
    mirror.heartbeatJob("hb-1", null, "{\"step\":3}", 6_000_000_000);
    {
        var stmt = try mirror.db.prepare("SELECT progress, checkpoint, lease_expires_at FROM jobs WHERE id = 'hb-1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("50%", stmt.columnText(0).?); // preserved
        try std.testing.expectEqualStrings("{\"step\":3}", stmt.columnText(1).?);
        try std.testing.expectEqualStrings("6000000000", stmt.columnText(2).?);
    }

    // Heartbeat with both progress and checkpoint.
    mirror.heartbeatJob("hb-1", "75%", "{\"step\":5}", 7_000_000_000);
    {
        var stmt = try mirror.db.prepare("SELECT progress, checkpoint, lease_expires_at FROM jobs WHERE id = 'hb-1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("75%", stmt.columnText(0).?);
        try std.testing.expectEqualStrings("{\"step\":5}", stmt.columnText(1).?);
        try std.testing.expectEqualStrings("7000000000", stmt.columnText(2).?);
    }

    // Heartbeat with lease only (no progress, no checkpoint).
    mirror.heartbeatJob("hb-1", null, null, 8_000_000_000);
    {
        var stmt = try mirror.db.prepare("SELECT progress, checkpoint, lease_expires_at FROM jobs WHERE id = 'hb-1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("75%", stmt.columnText(0).?); // preserved
        try std.testing.expectEqualStrings("{\"step\":5}", stmt.columnText(1).?); // preserved
        try std.testing.expectEqualStrings("8000000000", stmt.columnText(2).?);
    }

    // Heartbeat should NOT update a non-active job.
    testInsertJob(&mirror, "hb-pend", "q1", "pending");
    mirror.heartbeatJob("hb-pend", "100%", null, 9_000_000_000);
    {
        var stmt = try mirror.db.prepare("SELECT progress FROM jobs WHERE id = 'hb-pend'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expect(stmt.columnText(0) == null); // NOT updated (not active)
    }
}

test "mirror update job state" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Insert active job.
    {
        var stmt = try mirror.db.prepare(
            "INSERT INTO jobs (id, queue, state, worker_id, lease_expires_at, created_at)" ++
                " VALUES ('us-1', 'q1', 'active', 'w1', '9000000000', '1000000000')",
        );
        defer stmt.finalize();
        try stmt.exec();
    }

    // Cancel → completed state, clears worker/lease.
    mirror.updateJobState("us-1", "cancelled", 5_000_000_000);
    {
        var stmt = try mirror.db.prepare("SELECT state, worker_id, lease_expires_at, completed_at FROM jobs WHERE id = 'us-1'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("cancelled", stmt.columnText(0).?);
        try std.testing.expect(stmt.columnText(1) == null); // worker cleared
        try std.testing.expect(stmt.columnText(2) == null); // lease cleared
        try std.testing.expectEqualStrings("5000000000", stmt.columnText(3).?);
    }

    // Re-enqueue → pending state, clears completed_at.
    testInsertJob(&mirror, "us-2", "q1", "dead");
    mirror.updateJobState("us-2", "pending", 6_000_000_000);
    {
        var stmt = try mirror.db.prepare("SELECT state, completed_at FROM jobs WHERE id = 'us-2'");
        defer stmt.finalize();
        try std.testing.expect(try stmt.step());
        try std.testing.expectEqualStrings("pending", stmt.columnText(0).?);
        try std.testing.expect(stmt.columnText(1) == null); // completed_at cleared
    }
}

test "mirror delete job removes all related data" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Insert job + payload + FTS + error.
    testInsertJob(&mirror, "del-1", "q1", "completed");
    {
        var stmt = try mirror.db.prepare("INSERT INTO job_payloads (job_id, payload) VALUES ('del-1', 'hello world')");
        defer stmt.finalize();
        try stmt.exec();
    }
    {
        var stmt = try mirror.db.prepare("INSERT INTO jobs_fts (job_id, payload) VALUES ('del-1', 'hello world')");
        defer stmt.finalize();
        try stmt.exec();
    }
    {
        var stmt = try mirror.db.prepare("INSERT INTO job_errors (job_id, attempt, error, created_at) VALUES ('del-1', 1, 'oops', '1000')");
        defer stmt.finalize();
        try stmt.exec();
    }

    // Verify everything exists.
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ?", "del-1"));
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM job_payloads WHERE job_id = ?", "del-1"));
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM job_errors WHERE job_id = ?", "del-1"));

    // Delete the job.
    mirror.deleteJob("del-1");

    // Everything should be gone.
    try std.testing.expectEqual(@as(i64, 0), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ?", "del-1"));
    try std.testing.expectEqual(@as(i64, 0), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM job_payloads WHERE job_id = ?", "del-1"));
    try std.testing.expectEqual(@as(i64, 0), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM job_errors WHERE job_id = ?", "del-1"));
}

test "mirror fail with retry vs dead state" {
    var mirror = try Mirror.initInMemory(std.testing.allocator);
    defer mirror.deinit();

    // Insert two active jobs.
    for ([_][]const u8{ "fail-retry", "fail-dead" }) |jid| {
        var stmt = try mirror.db.prepare(
            "INSERT INTO jobs (id, queue, state, created_at) VALUES (?, 'q1', 'active', '1000000000')",
        );
        defer stmt.finalize();
        stmt.bindText(1, jid);
        try stmt.exec();
    }

    // Fail to retrying.
    {
        var stmts = try MirrorStmts.init(&mirror.db);
        defer stmts.deinit();

        // Error record.
        var e = &stmts.insert_error;
        e.bindText(1, "fail-retry");
        e.bindInt(2, 1);
        e.bindText(3, "timeout");
        e.bindNull(4); // backtrace
        e.bindText(5, "2000000000");
        try e.exec();
        e.reset();

        // Update state to retrying with scheduled_at.
        var s = &stmts.fail_job;
        s.bindText(1, "retrying");
        s.bindText(2, "2000000000");
        s.bindText(3, "5000000000"); // retry_at
        s.bindText(4, "fail-retry");
        try s.exec();
        s.reset();

        // Error record for dead job.
        e.bindText(1, "fail-dead");
        e.bindInt(2, 3);
        e.bindText(3, "max retries exceeded");
        e.bindNull(4); // backtrace
        e.bindText(5, "2000000000");
        try e.exec();
        e.reset();

        // Update state to dead (no retry_at).
        s.bindText(1, "dead");
        s.bindText(2, "2000000000");
        s.bindNull(3);
        s.bindText(4, "fail-dead");
        try s.exec();
        s.reset();
    }

    // Verify states.
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ? AND state = 'retrying'", "fail-retry"));
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror,
        "SELECT COUNT(*) FROM jobs WHERE id = ? AND scheduled_at = '5000000000'", "fail-retry"));
    try std.testing.expectEqual(@as(i64, 1), testQueryCountBind(&mirror, "SELECT COUNT(*) FROM jobs WHERE id = ? AND state = 'dead'", "fail-dead"));
    // Both should have error records.
    try std.testing.expectEqual(@as(i64, 2), testQueryCount(&mirror, "SELECT COUNT(*) FROM job_errors"));
}

