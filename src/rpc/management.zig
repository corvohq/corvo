//! Management parse/encode functions for maintenance, queue config, clear/delete queue.

const std = @import("std");
const rpc = @import("../rpc.zig");
const assert = @import("../assert.zig");
const ops_mod = @import("../ops.zig");

const BufReader = rpc.BufReader;
const BufWriter = rpc.BufWriter;
const ParseError = rpc.ParseError;

// ============================================================================
// Parse functions
// ============================================================================

pub fn parseMaintenance(reader: *BufReader) ParseError!ops_mod.MaintenanceOp {
    const action_raw = try reader.readU8();
    const action = std.meta.intToEnum(ops_mod.MaintenanceAction, action_raw) catch return error.InvalidEnum;
    const now_ns = try reader.readU64();
    const cutoff_ns = try reader.readU64();

    return .{
        .action = action,
        .now_ns = now_ns,
        .cutoff_ns = cutoff_ns,
    };
}

pub fn parseQueueConfig(reader: *BufReader) ParseError!ops_mod.QueueOp {
    const queue = try reader.readPrefixed();
    const action_raw = try reader.readU8();
    const action = std.meta.intToEnum(ops_mod.QueueAction, action_raw) catch return error.InvalidEnum;
    const max_concurrency = try reader.readU32();
    const rate_limit = try reader.readU32();
    const rate_window_ms = try reader.readU32();
    const fairness_raw = try reader.readU8();

    return .{
        .queue = queue,
        .action = action,
        .max_concurrency = max_concurrency,
        .rate_limit = rate_limit,
        .rate_window_ms = rate_window_ms,
        .fairness = fairness_raw == 1,
    };
}

pub fn parseClearQueue(reader: *BufReader) ParseError!ops_mod.ClearQueueOp {
    const queue = try reader.readPrefixed();
    return .{
        .queue = queue,
        .now_ns = 0,
    };
}

pub fn parseDeleteQueue(reader: *BufReader) ParseError!ops_mod.DeleteQueueOp {
    const queue = try reader.readPrefixed();
    return .{
        .queue = queue,
        .now_ns = 0,
    };
}

// ============================================================================
// Encode requests
// ============================================================================

pub fn encodeMaintenanceReq(writer: *BufWriter, op: *const ops_mod.MaintenanceOp) void {
    writer.writeU8(@intFromEnum(op.action));
    writer.writeU64(op.now_ns);
    writer.writeU64(op.cutoff_ns);
}

pub fn encodeQueueConfigReq(writer: *BufWriter, op: *const ops_mod.QueueOp) void {
    writer.writePrefixed(op.queue);
    writer.writeU8(@intFromEnum(op.action));
    writer.writeU32(op.max_concurrency);
    writer.writeU32(op.rate_limit);
    writer.writeU32(op.rate_window_ms);
    writer.writeU8(if (op.fairness) @as(u8, 1) else 0);
}

pub fn encodeClearQueueReq(writer: *BufWriter, op: *const ops_mod.ClearQueueOp) void {
    writer.writePrefixed(op.queue);
}

pub fn encodeDeleteQueueReq(writer: *BufWriter, op: *const ops_mod.DeleteQueueOp) void {
    writer.writePrefixed(op.queue);
}

// ============================================================================
// Encode responses
// ============================================================================

pub fn encodeGenericResp(writer: *BufWriter, result: *const ops_mod.OpResult) void {
    writer.writeU16(@intCast(result.affected));
    writer.writeU8(if (result.err != null) @as(u8, 1) else 0);
}

// ============================================================================
// Tests
// ============================================================================

test "maintenance roundtrip" {
    var buf: [64]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    const op = ops_mod.MaintenanceOp{ .action = .promote, .now_ns = 1000, .cutoff_ns = 500 };
    encodeMaintenanceReq(&w, &op);
    var r = BufReader{ .data = w.written() };
    const parsed = try parseMaintenance(&r);
    try std.testing.expectEqual(ops_mod.MaintenanceAction.promote, parsed.action);
    try std.testing.expectEqual(@as(u64, 1000), parsed.now_ns);
    try std.testing.expectEqual(@as(u64, 500), parsed.cutoff_ns);
}

test "queue config roundtrip" {
    var buf: [128]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    const op = ops_mod.QueueOp{
        .queue = "my-queue",
        .action = .throttle,
        .max_concurrency = 10,
        .rate_limit = 100,
        .rate_window_ms = 60000,
        .fairness = true,
    };
    encodeQueueConfigReq(&w, &op);
    var r = BufReader{ .data = w.written() };
    const parsed = try parseQueueConfig(&r);
    try std.testing.expectEqualStrings("my-queue", parsed.queue);
    try std.testing.expectEqual(ops_mod.QueueAction.throttle, parsed.action);
    try std.testing.expectEqual(@as(u32, 10), parsed.max_concurrency);
    try std.testing.expect(parsed.fairness);
}

test "clear queue roundtrip" {
    var buf: [64]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    const op = ops_mod.ClearQueueOp{ .queue = "cleanup-queue", .now_ns = 999 };
    encodeClearQueueReq(&w, &op);
    var r = BufReader{ .data = w.written() };
    const parsed = try parseClearQueue(&r);
    try std.testing.expectEqualStrings("cleanup-queue", parsed.queue);
}

test "delete queue roundtrip" {
    var buf: [64]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    const op = ops_mod.DeleteQueueOp{ .queue = "old-queue", .now_ns = 888 };
    encodeDeleteQueueReq(&w, &op);
    var r = BufReader{ .data = w.written() };
    const parsed = try parseDeleteQueue(&r);
    try std.testing.expectEqualStrings("old-queue", parsed.queue);
}

test "encodeGenericResp ok" {
    var buf: [16]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    const result = ops_mod.OpResult{ .affected = 42 };
    encodeGenericResp(&w, &result);
    var r = BufReader{ .data = w.written() };
    try std.testing.expectEqual(@as(u16, 42), try r.readU16());
    try std.testing.expectEqual(@as(u8, 0), try r.readU8());
}

test "maintenance invalid action" {
    var buf: [64]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    w.writeU8(0xFF);
    w.writeU64(0);
    w.writeU64(0);
    var r = BufReader{ .data = w.written() };
    try std.testing.expectError(error.InvalidEnum, parseMaintenance(&r));
}
