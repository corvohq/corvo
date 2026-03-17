//! Scheduler — periodic maintenance operations.
//!
//! Ported from Go internal/scheduler/scheduler.go.
//! Runs promote, reclaim, expire, purge on configurable intervals.

const std = @import("std");
const store_mod = @import("store.zig");
const ops_mod = @import("ops.zig");

// ============================================================================
// Config
// ============================================================================

pub const Config = struct {
    /// Base tick interval.
    interval_ms: u64 = 1_000,
    /// Promote scheduled/retrying jobs to pending.
    promote_interval_ms: u64 = 1_000,
    /// Reclaim expired leases.
    reclaim_interval_ms: u64 = 1_000,
    /// Clean expired unique locks.
    unique_interval_ms: u64 = 30_000,
    /// Clean old rate limit entries.
    rate_limit_interval_ms: u64 = 30_000,
    /// Expire jobs past deadline.
    expire_interval_ms: u64 = 10_000,
    /// Purge terminal jobs.
    purge_interval_ms: u64 = 3_600_000, // 1 hour
};

// ============================================================================
// Scheduler
// ============================================================================

pub const Scheduler = struct {
    store: *store_mod.Store,
    config: Config,
    running: bool = false,
    thread: ?std.Thread = null,

    // Last run timestamps (milliseconds).
    last_promote: u64 = 0,
    last_reclaim: u64 = 0,
    last_unique: u64 = 0,
    last_rate_limit: u64 = 0,
    last_expire: u64 = 0,
    last_purge: u64 = 0,

    // Stats
    promote_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reclaim_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    expire_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    purge_runs: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(store: *store_mod.Store, config: Config) Scheduler {
        return .{
            .store = store,
            .config = config,
        };
    }

    /// Start the scheduler background thread.
    pub fn start(self: *Scheduler) !void {
        if (self.running) return;
        self.running = true;
        self.thread = try std.Thread.spawn(.{}, tickLoop, .{self});
    }

    /// Stop the scheduler.
    pub fn stop(self: *Scheduler) void {
        if (!self.running) return;
        self.running = false;
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn tickLoop(self: *Scheduler) void {
        while (self.running) {
            std.Thread.sleep(self.config.interval_ms * std.time.ns_per_ms);
            self.tick();
        }
    }

    fn tick(self: *Scheduler) void {
        const now_ms = nowMs();

        if (now_ms - self.last_promote >= self.config.promote_interval_ms) {
            _ = self.store.maintenance(.promote);
            self.last_promote = now_ms;
            _ = self.promote_runs.fetchAdd(1, .monotonic);
        }

        if (now_ms - self.last_reclaim >= self.config.reclaim_interval_ms) {
            _ = self.store.maintenance(.reclaim);
            self.last_reclaim = now_ms;
            _ = self.reclaim_runs.fetchAdd(1, .monotonic);
        }

        if (now_ms - self.last_unique >= self.config.unique_interval_ms) {
            _ = self.store.maintenance(.unique);
            self.last_unique = now_ms;
        }

        if (now_ms - self.last_rate_limit >= self.config.rate_limit_interval_ms) {
            _ = self.store.maintenance(.rate_limit);
            self.last_rate_limit = now_ms;
        }

        if (now_ms - self.last_expire >= self.config.expire_interval_ms) {
            _ = self.store.maintenance(.expire);
            self.last_expire = now_ms;
            _ = self.expire_runs.fetchAdd(1, .monotonic);
        }

        if (now_ms - self.last_purge >= self.config.purge_interval_ms) {
            _ = self.store.maintenance(.purge);
            self.last_purge = now_ms;
            _ = self.purge_runs.fetchAdd(1, .monotonic);
        }
    }

    fn nowMs() u64 {
        return @intCast(@as(u128, @bitCast(std.time.nanoTimestamp())) / 1_000_000);
    }
};
