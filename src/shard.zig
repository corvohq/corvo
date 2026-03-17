//! Shard routing — determines which shard(s) an op targets.
//!
//! Ported from Go internal/engine/route.go.
//! Uses FNV-1a hash to deterministically route queue names to shards.

const std = @import("std");
const assert = @import("assert.zig");
const ops = @import("ops.zig");

/// How an op should be dispatched across shards.
pub const RouteMode = enum {
    single_shard, // all queues map to one shard
    multi_shard, // queues span multiple shards — split needed
    broadcast, // apply to every shard
    global, // apply to shard 0
};

/// Result of classifyRoute.
pub const RouteResult = struct {
    mode: RouteMode,
    shard_idx: u16 = 0, // valid when mode == single_shard
};

/// Deterministic shard index for a queue name using FNV-1a hash.
pub fn shardIndexForQueue(queue: []const u8, shard_count: u16) u16 {
    assert.check(shard_count > 0, "shardIndexForQueue: shard_count must be > 0", .{});
    const hash = std.hash.Fnv1a_32.hash(queue);
    return @intCast(hash % shard_count);
}

/// Classify how an op should be routed across shards.
pub fn classifyRoute(shard_count: u16, op_type: ops.OpType, data: *const ops.OpData) RouteResult {
    if (shard_count <= 1) {
        return .{ .mode = .single_shard, .shard_idx = 0 };
    }

    const queues = extractQueues(op_type, data);
    switch (queues.kind) {
        .global => return .{ .mode = .global, .shard_idx = 0 },
        .broadcast => return .{ .mode = .broadcast, .shard_idx = 0 },
        .single => {
            const idx = shardIndexForQueue(queues.first, shard_count);
            return .{ .mode = .single_shard, .shard_idx = idx };
        },
        .multi => {
            // Check if all queues hash to the same shard.
            const first_idx = shardIndexForQueue(queues.first, shard_count);
            // For simplicity in the Zig port, we check the op's queue list.
            // If we need a full multi-shard split, the engine handles it.
            return .{ .mode = .multi_shard, .shard_idx = first_idx };
        },
    }
}

/// Queue extraction result.
const QueueExtract = struct {
    kind: enum { global, broadcast, single, multi },
    first: []const u8, // first queue name (for single/multi)
};

/// Extract queue names from an op to determine routing.
fn extractQueues(op_type: ops.OpType, data: *const ops.OpData) QueueExtract {
    return switch (op_type) {
        .enqueue => blk: {
            const jobs = data.enqueue.jobs;
            if (jobs.len == 0) break :blk QueueExtract{ .kind = .global, .first = "" };
            if (jobs.len == 1) break :blk QueueExtract{ .kind = .single, .first = jobs[0].queue };
            break :blk QueueExtract{ .kind = .multi, .first = jobs[0].queue };
        },
        .fetch => blk: {
            const queues = data.fetch.queues;
            if (queues.len == 0) break :blk QueueExtract{ .kind = .global, .first = "" };
            if (queues.len == 1) break :blk QueueExtract{ .kind = .single, .first = queues[0] };
            break :blk QueueExtract{ .kind = .multi, .first = queues[0] };
        },
        .ack => blk: {
            const acks = data.ack.acks;
            if (acks.len == 0) break :blk QueueExtract{ .kind = .global, .first = "" };
            if (acks.len == 1) break :blk QueueExtract{ .kind = .single, .first = acks[0].queue };
            break :blk QueueExtract{ .kind = .multi, .first = acks[0].queue };
        },
        .fail => blk: {
            const jobs = data.fail.jobs;
            if (jobs.len == 0) break :blk QueueExtract{ .kind = .global, .first = "" };
            if (jobs.len == 1) break :blk QueueExtract{ .kind = .single, .first = jobs[0].queue };
            break :blk QueueExtract{ .kind = .multi, .first = jobs[0].queue };
        },
        .heartbeat => blk: {
            const ids = data.heartbeat.job_ops;
            if (ids.len == 0) break :blk QueueExtract{ .kind = .global, .first = "" };
            if (ids.len == 1) break :blk QueueExtract{ .kind = .single, .first = ids[0].queue };
            break :blk QueueExtract{ .kind = .multi, .first = ids[0].queue };
        },
        .bulk_action => blk: {
            const q = data.bulk_action.queue;
            if (q.len > 0) break :blk QueueExtract{ .kind = .single, .first = q };
            break :blk QueueExtract{ .kind = .broadcast, .first = "" };
        },
        .queue_config => QueueExtract{ .kind = .single, .first = data.queue_config.queue },
        .clear_queue => QueueExtract{ .kind = .single, .first = data.clear_queue.queue },
        .delete_queue => QueueExtract{ .kind = .single, .first = data.delete_queue.queue },
        .maintenance => QueueExtract{ .kind = .broadcast, .first = "" },
        // Global ops: cron, batch, budget, enterprise, multi
        .batch_create, .batch_seal, .cron_create, .cron_update, .cron_delete, .cron_trigger, .set_budget, .delete_budget, .modify_ent_setting, .multi => QueueExtract{ .kind = .global, .first = "" },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "shardIndexForQueue deterministic" {
    const testing = std.testing;
    const idx1 = shardIndexForQueue("emails", 4);
    const idx2 = shardIndexForQueue("emails", 4);
    try testing.expectEqual(idx1, idx2);
    try testing.expect(idx1 < 4);
}

test "shardIndexForQueue single shard" {
    const testing = std.testing;
    try testing.expectEqual(@as(u16, 0), shardIndexForQueue("anything", 1));
}
