//! Operation types for the Corvo apply pipeline.
//!
//! Ported from Go internal/store/ops.go, types_*.go, bulk.go, queues.go.
//! These structs represent the Raft log entry payloads — each op is
//! deterministically applied against a kv.Batch by the OpHandler.

const std = @import("std");
const types = @import("types.zig");
const JobState = types.JobState;
const AckStatus = types.AckStatus;
const Backoff = types.Backoff;

// ============================================================================
// OpType — discriminator for the apply switch
// ============================================================================

pub const OpType = enum(u8) {
    enqueue = 1,
    fetch = 2,
    ack = 3,
    fail = 4,
    heartbeat = 5,
    bulk_action = 6,
    queue_config = 7,
    clear_queue = 8,
    delete_queue = 9,
    maintenance = 10,
    batch_create = 11,
    batch_seal = 12,
    modify_setting = 13,
    multi = 14,
    cron_create = 15,
    cron_update = 16,
    cron_delete = 17,
    cron_trigger = 18,
    set_budget = 19,
    delete_budget = 20,
    global_config = 21,
};

// ============================================================================
// Enqueue
// ============================================================================

pub const EnqueueJob = struct {
    job_id: []const u8 = "",
    queue: []const u8 = "",
    state: JobState = .pending,
    payload: ?[]const u8 = null,
    checkpoint: ?[]const u8 = null,
    priority: u8 = types.priority_default,
    max_retries: u16 = 0,
    backoff: Backoff = .none,
    base_delay_ms: u32 = 0,
    max_delay_ms: u32 = 0,
    unique_key: ?[]const u8 = null,
    unique_period_s: u32 = 0,
    tags: ?[]const u8 = null,
    scheduled_at_ns: u64 = 0, // 0 = not scheduled
    expire_after_ms: u32 = 0,
    expire_at_ns: u64 = 0,
    created_at_ns: u64 = 0,
    batch_id: ?[]const u8 = null,
    parent_id: ?[]const u8 = null,
    chain_id: ?[]const u8 = null,
    chain_step: u16 = 0,
    chain_config: ?[]const u8 = null,
    group: ?[]const u8 = null,
};

pub const EnqueueOp = struct {
    jobs: []const EnqueueJob = &.{},
    now_ns: u64 = 0,
};

// ============================================================================
// Fetch
// ============================================================================

pub const FetchOp = struct {
    queues: []const []const u8 = &.{},
    worker_id: []const u8 = "",
    hostname: []const u8 = "",
    lease_duration_ms: u32 = 0,
    count: u32 = 1,
    now_ns: u64 = 0,
    random_seed: u64 = 0,
};

// ============================================================================
// Ack
// ============================================================================

pub const AckJob = struct {
    job_id: []const u8 = "",
    queue: []const u8 = "", // used for shard routing; handler reads job from KV by ID
    result: ?[]const u8 = null,
    checkpoint: ?[]const u8 = null,
    ack_status: AckStatus = .done,
    hold_reason: ?[]const u8 = null,
    lease_token: u64 = 0, // must match job's lease_token; 0 = don't check
};

pub const AckOp = struct {
    acks: []const AckJob = &.{},
    now_ns: u64 = 0,
};

// ============================================================================
// FetchAck — combined ack + fetch in a single pipeline batch
// ============================================================================

// ============================================================================
// Fail
// ============================================================================

pub const FailJob = struct {
    job_id: []const u8 = "",
    queue: []const u8 = "", // used for shard routing; handler reads job from KV by ID
    error_msg: []const u8 = "",
    backtrace: ?[]const u8 = null,
    lease_token: u64 = 0, // must match job's lease_token; 0 = don't check
};

pub const FailOp = struct {
    jobs: []const FailJob = &.{},
    now_ns: u64 = 0,
};

// ============================================================================
// Heartbeat
// ============================================================================

pub const HeartbeatJobOp = struct {
    queue: []const u8 = "",
    progress: ?[]const u8 = null,
    checkpoint: ?[]const u8 = null,
};

pub const HeartbeatOp = struct {
    // job_id -> HeartbeatJobOp — but Zig doesn't have built-in string maps in structs.
    // We use parallel slices instead.
    job_ids: []const []const u8 = &.{},
    job_ops: []const HeartbeatJobOp = &.{},
    worker_id: []const u8 = "",
    now_ns: u64 = 0,
};

// ============================================================================
// Bulk Action
// ============================================================================

pub const BulkAction = enum(u8) {
    delete = 2,
    cancel = 3,
    move = 4,
    requeue = 5,
    change_priority = 6,
    hold = 7,
    approve = 8,
    reject = 9,
    promote = 10,

    pub fn toString(self: BulkAction) []const u8 {
        return switch (self) {
            .delete => "delete",
            .cancel => "cancel",
            .move => "move",
            .requeue => "requeue",
            .change_priority => "change_priority",
            .hold => "hold",
            .approve => "approve",
            .reject => "reject",
            .promote => "promote",
        };
    }
};

pub const BulkActionOp = struct {
    job_ids: []const []const u8 = &.{},
    action: BulkAction = .requeue,
    queue: []const u8 = "",
    move_to_queue: ?[]const u8 = null,
    priority: u8 = 0,
    now_ns: u64 = 0,
};

// ============================================================================
// Queue Config
// ============================================================================

pub const QueueAction = enum(u8) {
    pause = 1,
    @"resume" = 2,
    concurrency = 3,
    throttle = 4,
    fairness = 5,
    clear = 6,
    delete = 7,

    pub fn toString(self: QueueAction) []const u8 {
        return switch (self) {
            .pause => "pause",
            .@"resume" => "resume",
            .concurrency => "concurrency",
            .throttle => "throttle",
            .fairness => "fairness",
            .clear => "clear",
            .delete => "delete",
        };
    }
};

pub const QueueOp = struct {
    queue: []const u8 = "",
    action: QueueAction = .pause,
    max_concurrency: u32 = 0,
    rate_limit: u32 = 0,
    rate_window_ms: u32 = 0,
    fairness: bool = false,
};

pub const ClearQueueOp = struct {
    queue: []const u8 = "",
    now_ns: u64 = 0,
};

pub const DeleteQueueOp = struct {
    queue: []const u8 = "",
    now_ns: u64 = 0,
};

// ============================================================================
// Maintenance
// ============================================================================

pub const MaintenanceAction = enum(u8) {
    promote = 1,
    reclaim = 2,
    expire = 3,
    purge = 4,
    unique = 5,
    rate_limit = 6,
    workers = 7,
    batches = 8,

    pub fn toString(self: MaintenanceAction) []const u8 {
        return switch (self) {
            .promote => "promote",
            .reclaim => "reclaim",
            .expire => "expire",
            .purge => "purge",
            .unique => "unique",
            .rate_limit => "rate_limit",
            .workers => "workers",
            .batches => "batches",
        };
    }
};

pub const MaintenanceOp = struct {
    action: MaintenanceAction = .promote,
    now_ns: u64 = 0,
    cutoff_ns: u64 = 0,
};

// ============================================================================
// Batch ops
// ============================================================================

pub const CreateBatchOp = struct {
    batch_id: []const u8 = "",
    callback_queue: []const u8 = "",
    callback_payload: ?[]const u8 = null,
    created_at_ns: u64 = 0,
};

pub const SealBatchOp = struct {
    batch_id: []const u8 = "",
    now_ns: u64 = 0,
};

// ============================================================================
// Cron ops
// ============================================================================

pub const CreateCronOp = struct {
    cron_id: []const u8 = "",
    name: []const u8 = "",
    queue: []const u8 = "",
    schedule: []const u8 = "",
    timezone: []const u8 = "",
    payload: ?[]const u8 = null,
    unique_key: ?[]const u8 = null,
    max_retries: u16 = 0,
    enabled: bool = true,
    next_run_ns: i64 = 0,
    created_at_ns: u64 = 0,
    now_ns: u64 = 0,
};

pub const UpdateCronOp = struct {
    cron_id: []const u8 = "",
    name: ?[]const u8 = null,
    queue: ?[]const u8 = null,
    schedule: ?[]const u8 = null,
    timezone: ?[]const u8 = null,
    payload: ?[]const u8 = null,
    unique_key: ?[]const u8 = null,
    max_retries: ?u16 = null,
    enabled: ?bool = null,
    next_run_ns: i64 = 0,
    now_ns: u64 = 0,
};

pub const DeleteCronOp = struct {
    cron_id: []const u8 = "",
};

pub const TriggerCronOp = struct {
    cron_id: []const u8 = "",
    job_id: []const u8 = "",
    now_ns: u64 = 0,
    next_run_ns: i64 = 0,
};

// ============================================================================
// Budget ops
// ============================================================================

pub const SetBudgetOp = struct {
    id: []const u8 = "",
    scope: []const u8 = "",
    target: []const u8 = "",
    daily_usd: f64 = 0,
    per_job_usd: f64 = 0,
    on_exceed: []const u8 = "",
    created_at_ns: u64 = 0,
};

pub const DeleteBudgetOp = struct {
    scope: []const u8 = "",
    target: []const u8 = "",
};

// ============================================================================
// Global config
// ============================================================================

pub const GlobalConfigOp = struct {
    rate_limit: u32 = 0,
    rate_window_ms: u32 = 0,
};

// ============================================================================
// Settings
// ============================================================================

pub const Setting = enum(u8) {
    api_key = 3,
    webhook = 4,
    audit_entry = 6,
    api_key_used = 9,
};

pub const ModifySettingOp = struct {
    setting: Setting = .api_key,
    id: []const u8 = "",
    scope: []const u8 = "",
    data: ?[]const u8 = null, // null = delete, otherwise = upsert
};

// ============================================================================
// Multi
// ============================================================================

pub const OpInput = struct {
    op_type: OpType,
    data: OpData,
};

pub const OpData = union(OpType) {
    enqueue: EnqueueOp,
    fetch: FetchOp,
    ack: AckOp,
    fail: FailOp,
    heartbeat: HeartbeatOp,
    bulk_action: BulkActionOp,
    queue_config: QueueOp,
    clear_queue: ClearQueueOp,
    delete_queue: DeleteQueueOp,
    maintenance: MaintenanceOp,
    batch_create: CreateBatchOp,
    batch_seal: SealBatchOp,
    modify_setting: ModifySettingOp,
    multi: void, // nested multi not supported
    cron_create: CreateCronOp,
    cron_update: UpdateCronOp,
    cron_delete: DeleteCronOp,
    cron_trigger: TriggerCronOp,
    set_budget: SetBudgetOp,
    delete_budget: DeleteBudgetOp,
    global_config: GlobalConfigOp,
};

// ============================================================================
// OpResult
// ============================================================================

pub const OpResult = struct {
    /// Fetched jobs (for fetch ops)
    jobs: ?[]types.Job = null,
    /// Error message (for failed ops)
    err: ?[]const u8 = null,
    /// Affected count (for bulk ops)
    affected: u32 = 0,
    /// Existing job ID for unique conflicts (set when err = "unique_existing")
    unique_job_id_buf: [64]u8 = undefined,
    unique_job_id_len: u8 = 0,
    /// Queues that need notification (for post-commit)
    notify_queues: ?[]const []const u8 = null,
    /// Callback jobs triggered by batch completion or chain advancement
    callback_jobs: ?[]types.Job = null,

    /// Inline fetch result: IDs of fetched jobs. Fixed-size, no allocation.
    /// Valid when affected > 0 on a fetch operation.
    fetched: [max_inline_fetch]FetchedJob = undefined,

    pub const max_inline_fetch = 128;

    pub const FetchedJob = struct {
        id_buf: [64]u8 = undefined,
        id_len: u8 = 0,
        queue_buf: [64]u8 = undefined,
        queue_len: u8 = 0,
        attempt: u16 = 0,
        max_retries: u16 = 0,
        lease_duration_ms: u32 = 0,
        lease_token: u64 = 0,
    };
};

// ============================================================================
// Tests
// ============================================================================

test "OpType exhaustive" {
    // Compile-time check that switch is exhaustive
    const op: OpType = .enqueue;
    _ = switch (op) {
        .enqueue, .fetch, .ack, .fail, .heartbeat, .bulk_action => true,
        .queue_config, .clear_queue, .delete_queue, .maintenance => true,
        .batch_create, .batch_seal, .modify_setting, .multi => true,
        .cron_create, .cron_update, .cron_delete, .cron_trigger => true,
        .set_budget, .delete_budget, .global_config => true,
    };
}

test "BulkAction values" {
    const testing = std.testing;
    try testing.expectEqualStrings("requeue", BulkAction.requeue.toString());
    try testing.expectEqualStrings("delete", BulkAction.delete.toString());
    try testing.expectEqualStrings("reject", BulkAction.reject.toString());
}
