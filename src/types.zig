//! Core domain types for Corvo job queue.
//!
//! Ported from Go internal/store/models.go. These are the in-memory
//! representations used throughout the system. Serialization to/from
//! KV storage is handled by codec.zig.

const std = @import("std");

/// Identifiers are copied into fixed-size hot-path buffers (PendingEntry,
/// FetchedJob, simulator state, and several response encoders). Keep the
/// accepted boundary in one place so a job can never be durable in KV but
/// absent from the in-memory pending index merely because its ID was too long.
pub const max_job_id_len: usize = 64;
pub const max_queue_name_len: usize = 64;
pub const max_entity_id_len: usize = 64;
pub const max_worker_id_len: usize = 128;
pub const max_hostname_len: usize = 255;
pub const max_metadata_field_len: usize = 512;

// ============================================================================
// Job State
// ============================================================================

pub const JobState = enum(u8) {
    pending = 0,
    active = 1,
    retrying = 2,
    completed = 3,
    dead = 4,
    cancelled = 5,
    scheduled = 6,
    held = 7,

    pub fn isTerminal(self: JobState) bool {
        return switch (self) {
            .completed, .dead, .cancelled => true,
            .pending, .active, .retrying, .scheduled, .held => false,
        };
    }

    pub fn toString(self: JobState) []const u8 {
        return switch (self) {
            .pending => "pending",
            .active => "active",
            .retrying => "retrying",
            .completed => "completed",
            .dead => "dead",
            .cancelled => "cancelled",
            .scheduled => "scheduled",
            .held => "held",
        };
    }
};

// ============================================================================
// Priority
// ============================================================================

pub const priority_critical: u8 = 100;
pub const priority_high: u8 = 75;
pub const priority_normal: u8 = 50;
pub const priority_low: u8 = 25;
pub const priority_default: u8 = priority_normal;

// ============================================================================
// Backoff
// ============================================================================

pub const Backoff = enum(u8) {
    none = 0,
    fixed = 1,
    linear = 2,
    exponential = 3,

    pub fn toString(self: Backoff) []const u8 {
        return switch (self) {
            .none => "none",
            .fixed => "fixed",
            .linear => "linear",
            .exponential => "exponential",
        };
    }
};

// ============================================================================
// Ack Status
// ============================================================================

pub const AckStatus = enum(u8) {
    done = 0,
    hold = 1,

    pub fn toString(self: AckStatus) []const u8 {
        return switch (self) {
            .done => "done",
            .hold => "hold",
        };
    }
};

// ============================================================================
// Job
// ============================================================================

/// Core job type — the unit of work in Corvo.
/// Payload is stored separately (at jp|{id}) and not part of the header.
pub const Job = struct {
    id: []const u8 = "",
    queue: []const u8 = "",
    state: JobState = .pending,
    priority: u8 = priority_default,
    attempt: u16 = 0,
    max_retries: u16 = 0,
    retry_backoff: Backoff = .none,
    retry_base_delay_ms: u32 = 0,
    retry_max_delay_ms: u32 = 0,

    // Payload stored separately — only in-memory during enqueue/ack
    payload: ?[]const u8 = null,
    checkpoint: ?[]const u8 = null,
    result: ?[]const u8 = null,
    progress: ?[]const u8 = null,
    tags: ?[]const u8 = null,

    // Unique constraint
    unique_key: ?[]const u8 = null,
    unique_period_s: u32 = 0,

    // Batch
    batch_id: ?[]const u8 = null,

    // Worker
    worker_id: ?[]const u8 = null,
    hostname: ?[]const u8 = null,

    // Timestamps (nanoseconds since epoch)
    created_at_ns: u64 = 0,
    started_at_ns: u64 = 0,
    completed_at_ns: u64 = 0,
    failed_at_ns: u64 = 0,
    scheduled_at_ns: u64 = 0,
    lease_expires_at_ns: u64 = 0,

    // Expiry
    expire_after_ms: u32 = 0,
    expire_at_ns: u64 = 0,

    // Chain / parent
    parent_id: ?[]const u8 = null,
    chain_id: ?[]const u8 = null,
    chain_step: u16 = 0,
    chain_config: ?[]const u8 = null,

    // Group (for fairness)
    group: ?[]const u8 = null,

    // Hold
    hold_reason: ?[]const u8 = null,

    // Lease token — set on fetch, verified on ack/fail.
    // Prevents stale workers (whose lease expired and was reclaimed)
    // from completing jobs they no longer own.
    lease_token: u64 = 0,
};

// ============================================================================
// Queue
// ============================================================================

pub const Queue = struct {
    name: []const u8 = "",
    paused: bool = false,
    max_concurrency: u32 = 0, // 0 = unlimited
    rate_limit: u32 = 0, // 0 = unlimited
    rate_window_ms: u32 = 0, // 0 = default (1000ms)
    fairness: bool = false,
    created_at_ns: u64 = 0,

    // Per-state job counters (maintained by handlers on state transitions).
    pending_count: u32 = 0,
    active_count: u32 = 0,
    retrying_count: u32 = 0,
    completed_count: u32 = 0,
    dead_count: u32 = 0,
    cancelled_count: u32 = 0,
    scheduled_count: u32 = 0,
    held_count: u32 = 0,

    pub fn incrState(self: *Queue, state: JobState) void {
        self.counterPtr(state).* +|= 1;
    }

    pub fn decrState(self: *Queue, state: JobState) void {
        self.counterPtr(state).* -|= 1;
    }

    fn counterPtr(self: *Queue, state: JobState) *u32 {
        return switch (state) {
            .pending => &self.pending_count,
            .active => &self.active_count,
            .retrying => &self.retrying_count,
            .completed => &self.completed_count,
            .dead => &self.dead_count,
            .scheduled => &self.scheduled_count,
            .held => &self.held_count,
            .cancelled => &self.cancelled_count,
        };
    }

    pub fn totalJobs(self: *const Queue) u32 {
        return self.pending_count +| self.active_count +| self.retrying_count +|
            self.completed_count +| self.dead_count +| self.cancelled_count +| self.scheduled_count +| self.held_count;
    }
};

// ============================================================================
// Worker
// ============================================================================

pub const Worker = struct {
    id: []const u8 = "",
    hostname: ?[]const u8 = null,
    queues: ?[]const u8 = null, // JSON array of queue names
    last_heartbeat_ns: u64 = 0,
    started_at_ns: u64 = 0,
};

// ============================================================================
// Cron
// ============================================================================

pub const Cron = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    queue: []const u8 = "",
    schedule: []const u8 = "", // cron expression
    timezone: []const u8 = "",
    payload: ?[]const u8 = null,
    unique_key: ?[]const u8 = null,
    max_retries: u16 = 0,
    enabled: bool = true,
    next_run_ns: i64 = 0,
    last_run_ns: i64 = 0,
    created_at_ns: u64 = 0,
};

// ============================================================================
// Batch
// ============================================================================

pub const Batch = struct {
    id: []const u8 = "",
    open: bool = true,
    total: u32 = 0,
    pending: u32 = 0,
    succeeded: u32 = 0,
    failed: u32 = 0,
    callback_queue: ?[]const u8 = null,
    callback_payload: ?[]const u8 = null,
    created_at_ns: u64 = 0,
    completed_at_ns: u64 = 0,
};

// ============================================================================
// Budget
// ============================================================================

pub const Budget = struct {
    scope: []const u8 = "",
    target: []const u8 = "",
    daily_usd: f64 = 0,
    per_job_usd: f64 = 0,
    on_exceed: []const u8 = "", // "pause" | "reject" | "alert"
    created_at_ns: u64 = 0,
};

// ============================================================================
// Job Error
// ============================================================================

pub const JobError = struct {
    attempt: u16 = 0,
    error_msg: []const u8 = "",
    backtrace: ?[]const u8 = null,
};

// ============================================================================
// Tests
// ============================================================================

test "JobState.isTerminal" {
    const testing = std.testing;
    try testing.expect(JobState.completed.isTerminal());
    try testing.expect(JobState.dead.isTerminal());
    try testing.expect(JobState.cancelled.isTerminal());
    try testing.expect(!JobState.pending.isTerminal());
    try testing.expect(!JobState.active.isTerminal());
    try testing.expect(!JobState.retrying.isTerminal());
    try testing.expect(!JobState.scheduled.isTerminal());
    try testing.expect(!JobState.held.isTerminal());
}
