//! Bulk action parse/encode functions.

const std = @import("std");
const rpc = @import("../rpc.zig");
const assert = @import("../assert.zig");
const ops_mod = @import("../ops.zig");

const BufReader = rpc.BufReader;
const BufWriter = rpc.BufWriter;
const ParseError = rpc.ParseError;

pub const BULK_FLAG_MOVE_TO: u8 = 0x01;
pub const BULK_FLAG_PRIORITY: u8 = 0x02;

pub fn parseBulkAction(reader: *BufReader, job_ids_buf: [][]const u8) ParseError!ops_mod.BulkActionOp {
    const action_raw = try reader.readU8();
    const action = std.meta.intToEnum(ops_mod.BulkAction, action_raw) catch return error.InvalidEnum;

    const queue = try reader.readPrefixed();

    const count = try reader.readU16();
    if (count == 0 or count > rpc.MAX_BATCH_JOBS) return error.InvalidCount;
    if (count > job_ids_buf.len) return error.InvalidCount;

    for (0..count) |i| {
        job_ids_buf[i] = try reader.readPrefixed();
    }

    const flags = try reader.readU8();

    var move_to_queue: ?[]const u8 = null;
    if (flags & BULK_FLAG_MOVE_TO != 0) {
        move_to_queue = try reader.readPrefixed();
    }

    var priority: u8 = 0;
    if (flags & BULK_FLAG_PRIORITY != 0) {
        priority = try reader.readU8();
    }

    const now_ns = try reader.readU64();

    return .{
        .action = action,
        .queue = queue,
        .job_ids = job_ids_buf[0..count],
        .move_to_queue = move_to_queue,
        .priority = priority,
        .now_ns = now_ns,
    };
}

pub fn encodeBulkActionReq(writer: *BufWriter, op: *const ops_mod.BulkActionOp) void {
    writer.writeU8(@intFromEnum(op.action));
    writer.writePrefixed(op.queue);

    assert.check(op.job_ids.len <= rpc.MAX_BATCH_JOBS, "encodeBulkActionReq: too many job_ids ({d} > {d})", .{ op.job_ids.len, rpc.MAX_BATCH_JOBS });
    writer.writeU16(@intCast(op.job_ids.len));

    for (op.job_ids) |job_id| {
        writer.writePrefixed(job_id);
    }

    var flags: u8 = 0;
    if (op.move_to_queue != null) flags |= BULK_FLAG_MOVE_TO;
    if (op.priority != 0) flags |= BULK_FLAG_PRIORITY;
    writer.writeU8(flags);

    if (op.move_to_queue) |mtq| {
        writer.writePrefixed(mtq);
    }
    if (op.priority != 0) {
        writer.writeU8(op.priority);
    }

    writer.writeU64(op.now_ns);
}

// ============================================================================
// Tests
// ============================================================================

test "parseBulkAction roundtrip — move with priority" {
    var buf: [512]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    const job_ids_in = [_][]const u8{ "job-001", "job-002", "job-003" };
    const op_in = ops_mod.BulkActionOp{
        .action = .move,
        .queue = "source-queue",
        .job_ids = &job_ids_in,
        .move_to_queue = "dest-queue",
        .priority = 42,
        .now_ns = 123456789,
    };

    encodeBulkActionReq(&w, &op_in);

    var ids_buf: [rpc.MAX_BATCH_JOBS][]const u8 = undefined;
    var r = BufReader{ .data = w.written() };
    const op_out = try parseBulkAction(&r, &ids_buf);

    try std.testing.expectEqual(ops_mod.BulkAction.move, op_out.action);
    try std.testing.expectEqualStrings("source-queue", op_out.queue);
    try std.testing.expectEqual(@as(usize, 3), op_out.job_ids.len);
    try std.testing.expectEqualStrings("dest-queue", op_out.move_to_queue.?);
    try std.testing.expectEqual(@as(u8, 42), op_out.priority);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "parseBulkAction invalid count zero" {
    var buf: [32]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    w.writeU8(@intFromEnum(ops_mod.BulkAction.requeue));
    w.writePrefixed("q");
    w.writeU16(0);

    var ids_buf: [rpc.MAX_BATCH_JOBS][]const u8 = undefined;
    var r = BufReader{ .data = w.written() };
    try std.testing.expectError(error.InvalidCount, parseBulkAction(&r, &ids_buf));
}
