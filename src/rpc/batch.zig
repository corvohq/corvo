//! Batch parse/encode functions.

const std = @import("std");
const rpc = @import("../rpc.zig");
const assert = @import("../assert.zig");
const ops_mod = @import("../ops.zig");

const BufReader = rpc.BufReader;
const BufWriter = rpc.BufWriter;
const ParseError = rpc.ParseError;

pub const BATCH_FLAG_PAYLOAD: u8 = 0x01;

pub fn parseBatchCreate(reader: *BufReader) ParseError!ops_mod.CreateBatchOp {
    const callback_queue = try reader.readPrefixed();
    const flags = try reader.readU8();

    var callback_payload: ?[]const u8 = null;
    if (flags & BATCH_FLAG_PAYLOAD != 0) {
        callback_payload = try reader.readU16Prefixed();
    }

    return .{
        .callback_queue = callback_queue,
        .callback_payload = callback_payload,
    };
}

pub fn parseBatchSeal(reader: *BufReader) ParseError!ops_mod.SealBatchOp {
    const batch_id = try reader.readPrefixed();
    return .{
        .batch_id = batch_id,
    };
}

pub fn encodeBatchCreateReq(writer: *BufWriter, op: *const ops_mod.CreateBatchOp) void {
    writer.writePrefixed(op.callback_queue);

    var flags: u8 = 0;
    if (op.callback_payload != null) flags |= BATCH_FLAG_PAYLOAD;
    writer.writeU8(flags);

    if (op.callback_payload) |payload| {
        writer.writeU16Prefixed(payload);
    }
}

pub fn encodeBatchSealReq(writer: *BufWriter, op: *const ops_mod.SealBatchOp) void {
    writer.writePrefixed(op.batch_id);
}

pub fn encodeBatchCreateResp(writer: *BufWriter, result: *const ops_mod.OpResult, batch_id: []const u8) void {
    writer.writePrefixed(batch_id);
    writer.writeU8(if (result.err != null) @as(u8, 1) else 0);
}

// ============================================================================
// Tests
// ============================================================================

test "parseBatchCreate roundtrip — with payload" {
    var buf: [512]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    const op_in = ops_mod.CreateBatchOp{
        .batch_id = "batch-123",
        .callback_queue = "callback-q",
        .callback_payload = "{\"notify\":true}",
        .created_at_ns = 999,
    };

    encodeBatchCreateReq(&w, &op_in);

    var r = BufReader{ .data = w.written() };
    const op_out = try parseBatchCreate(&r);

    try std.testing.expectEqualStrings("callback-q", op_out.callback_queue);
    try std.testing.expectEqualStrings("{\"notify\":true}", op_out.callback_payload.?);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "parseBatchSeal roundtrip" {
    var buf: [256]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    const op_in = ops_mod.SealBatchOp{
        .batch_id = "batch-456",
        .now_ns = 777,
    };

    encodeBatchSealReq(&w, &op_in);

    var r = BufReader{ .data = w.written() };
    const op_out = try parseBatchSeal(&r);

    try std.testing.expectEqualStrings("batch-456", op_out.batch_id);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "encodeBatchCreateResp ok" {
    var buf: [64]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    var result = ops_mod.OpResult{};
    encodeBatchCreateResp(&w, &result, "batch-789");

    var r = BufReader{ .data = w.written() };
    try std.testing.expectEqualStrings("batch-789", try r.readPrefixed());
    try std.testing.expectEqual(@as(u8, 0), try r.readU8());
}
