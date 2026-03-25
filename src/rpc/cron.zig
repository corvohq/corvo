//! Cron parse/encode functions.

const std = @import("std");
const rpc = @import("../rpc.zig");
const assert = @import("../assert.zig");
const ops_mod = @import("../ops.zig");

const BufReader = rpc.BufReader;
const BufWriter = rpc.BufWriter;
const ParseError = rpc.ParseError;

// Create flags
pub const CRON_FLAG_PAYLOAD: u8 = 0x01;
pub const CRON_FLAG_UNIQUE_KEY: u8 = 0x02;

// Update flags (u16)
pub const CRON_UPD_NAME: u16 = 0x0001;
pub const CRON_UPD_QUEUE: u16 = 0x0002;
pub const CRON_UPD_SCHEDULE: u16 = 0x0004;
pub const CRON_UPD_TIMEZONE: u16 = 0x0008;
pub const CRON_UPD_PAYLOAD: u16 = 0x0010;
pub const CRON_UPD_UNIQUE_KEY: u16 = 0x0020;
pub const CRON_UPD_MAX_RETRIES: u16 = 0x0040;
pub const CRON_UPD_ENABLED: u16 = 0x0080;

// ============================================================================
// Parse
// ============================================================================

pub fn parseCronCreate(reader: *BufReader) ParseError!ops_mod.CreateCronOp {
    const name = try reader.readPrefixed();
    const queue = try reader.readPrefixed();
    const schedule = try reader.readPrefixed();
    const timezone = try reader.readPrefixed();
    const max_retries = try reader.readU16();
    const enabled_raw = try reader.readU8();
    const flags = try reader.readU8();

    var payload: ?[]const u8 = null;
    if (flags & CRON_FLAG_PAYLOAD != 0) {
        payload = try reader.readU16Prefixed();
    }

    var unique_key: ?[]const u8 = null;
    if (flags & CRON_FLAG_UNIQUE_KEY != 0) {
        unique_key = try reader.readPrefixed();
    }

    return .{
        .name = name,
        .queue = queue,
        .schedule = schedule,
        .timezone = timezone,
        .max_retries = max_retries,
        .enabled = enabled_raw != 0,
        .payload = payload,
        .unique_key = unique_key,
    };
}

pub fn parseCronUpdate(reader: *BufReader) ParseError!ops_mod.UpdateCronOp {
    const cron_id = try reader.readPrefixed();
    const flags = try reader.readU16();

    var op = ops_mod.UpdateCronOp{
        .cron_id = cron_id,
    };

    if (flags & CRON_UPD_NAME != 0) op.name = try reader.readPrefixed();
    if (flags & CRON_UPD_QUEUE != 0) op.queue = try reader.readPrefixed();
    if (flags & CRON_UPD_SCHEDULE != 0) op.schedule = try reader.readPrefixed();
    if (flags & CRON_UPD_TIMEZONE != 0) op.timezone = try reader.readPrefixed();
    if (flags & CRON_UPD_PAYLOAD != 0) op.payload = try reader.readU16Prefixed();
    if (flags & CRON_UPD_UNIQUE_KEY != 0) op.unique_key = try reader.readPrefixed();
    if (flags & CRON_UPD_MAX_RETRIES != 0) op.max_retries = try reader.readU16();
    if (flags & CRON_UPD_ENABLED != 0) {
        const enabled_raw = try reader.readU8();
        op.enabled = enabled_raw != 0;
    }

    return op;
}

pub fn parseCronDelete(reader: *BufReader) ParseError!ops_mod.DeleteCronOp {
    const cron_id = try reader.readPrefixed();
    return .{ .cron_id = cron_id };
}

pub fn parseCronTrigger(reader: *BufReader) ParseError!ops_mod.TriggerCronOp {
    const cron_id = try reader.readPrefixed();
    return .{ .cron_id = cron_id };
}

// ============================================================================
// Encode requests
// ============================================================================

pub fn encodeCronCreateReq(writer: *BufWriter, op: *const ops_mod.CreateCronOp) void {
    writer.writePrefixed(op.name);
    writer.writePrefixed(op.queue);
    writer.writePrefixed(op.schedule);
    writer.writePrefixed(op.timezone);
    writer.writeU16(op.max_retries);
    writer.writeU8(if (op.enabled) 1 else 0);

    var flags: u8 = 0;
    if (op.payload != null) flags |= CRON_FLAG_PAYLOAD;
    if (op.unique_key != null) flags |= CRON_FLAG_UNIQUE_KEY;
    writer.writeU8(flags);

    if (op.payload) |payload| {
        writer.writeU16Prefixed(payload);
    }
    if (op.unique_key) |uk| {
        writer.writePrefixed(uk);
    }
}

pub fn encodeCronUpdateReq(writer: *BufWriter, op: *const ops_mod.UpdateCronOp) void {
    writer.writePrefixed(op.cron_id);

    var flags: u16 = 0;
    if (op.name != null) flags |= CRON_UPD_NAME;
    if (op.queue != null) flags |= CRON_UPD_QUEUE;
    if (op.schedule != null) flags |= CRON_UPD_SCHEDULE;
    if (op.timezone != null) flags |= CRON_UPD_TIMEZONE;
    if (op.payload != null) flags |= CRON_UPD_PAYLOAD;
    if (op.unique_key != null) flags |= CRON_UPD_UNIQUE_KEY;
    if (op.max_retries != null) flags |= CRON_UPD_MAX_RETRIES;
    if (op.enabled != null) flags |= CRON_UPD_ENABLED;
    writer.writeU16(flags);

    if (op.name) |name| writer.writePrefixed(name);
    if (op.queue) |queue| writer.writePrefixed(queue);
    if (op.schedule) |schedule| writer.writePrefixed(schedule);
    if (op.timezone) |tz| writer.writePrefixed(tz);
    if (op.payload) |payload| writer.writeU16Prefixed(payload);
    if (op.unique_key) |uk| writer.writePrefixed(uk);
    if (op.max_retries) |mr| writer.writeU16(mr);
    if (op.enabled) |en| writer.writeU8(if (en) 1 else 0);
}

pub fn encodeCronDeleteReq(writer: *BufWriter, op: *const ops_mod.DeleteCronOp) void {
    writer.writePrefixed(op.cron_id);
}

pub fn encodeCronTriggerReq(writer: *BufWriter, op: *const ops_mod.TriggerCronOp) void {
    writer.writePrefixed(op.cron_id);
}

// ============================================================================
// Encode responses
// ============================================================================

pub fn encodeCronCreateResp(writer: *BufWriter, result: *const ops_mod.OpResult, cron_id: []const u8) void {
    writer.writePrefixed(cron_id);
    writer.writeU8(if (result.err != null) @as(u8, 1) else 0);
}

// ============================================================================
// Tests
// ============================================================================

test "parseCronCreate roundtrip — all fields" {
    var buf: [1024]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    const op_in = ops_mod.CreateCronOp{
        .cron_id = "cron-123",
        .name = "daily-report",
        .queue = "reports",
        .schedule = "0 9 * * *",
        .timezone = "America/New_York",
        .max_retries = 5,
        .enabled = true,
        .payload = "{\"type\":\"daily\"}",
        .unique_key = "report-daily",
        .next_run_ns = 999,
        .created_at_ns = 888,
        .now_ns = 777,
    };

    encodeCronCreateReq(&w, &op_in);

    var r = BufReader{ .data = w.written() };
    const op_out = try parseCronCreate(&r);

    try std.testing.expectEqualStrings("daily-report", op_out.name);
    try std.testing.expectEqualStrings("reports", op_out.queue);
    try std.testing.expectEqualStrings("0 9 * * *", op_out.schedule);
    try std.testing.expectEqual(@as(u16, 5), op_out.max_retries);
    try std.testing.expect(op_out.enabled);
    try std.testing.expectEqualStrings("{\"type\":\"daily\"}", op_out.payload.?);
    try std.testing.expectEqualStrings("report-daily", op_out.unique_key.?);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "parseCronUpdate roundtrip — partial update" {
    var buf: [512]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    const op_in = ops_mod.UpdateCronOp{
        .cron_id = "cron-456",
        .name = "updated-name",
        .schedule = "*/5 * * * *",
        .max_retries = 10,
        .enabled = false,
    };

    encodeCronUpdateReq(&w, &op_in);

    var r = BufReader{ .data = w.written() };
    const op_out = try parseCronUpdate(&r);

    try std.testing.expectEqualStrings("cron-456", op_out.cron_id);
    try std.testing.expectEqualStrings("updated-name", op_out.name.?);
    try std.testing.expect(op_out.queue == null);
    try std.testing.expectEqualStrings("*/5 * * * *", op_out.schedule.?);
    try std.testing.expectEqual(@as(u16, 10), op_out.max_retries.?);
    try std.testing.expectEqual(false, op_out.enabled.?);
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "parseCronDelete roundtrip" {
    var buf: [64]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    const op_in = ops_mod.DeleteCronOp{ .cron_id = "cron-del" };
    encodeCronDeleteReq(&w, &op_in);
    var r = BufReader{ .data = w.written() };
    const op_out = try parseCronDelete(&r);
    try std.testing.expectEqualStrings("cron-del", op_out.cron_id);
}

test "parseCronTrigger roundtrip" {
    var buf: [64]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    const op_in = ops_mod.TriggerCronOp{ .cron_id = "cron-trig", .job_id = "job-xxx", .now_ns = 555, .next_run_ns = 666 };
    encodeCronTriggerReq(&w, &op_in);
    var r = BufReader{ .data = w.written() };
    const op_out = try parseCronTrigger(&r);
    try std.testing.expectEqualStrings("cron-trig", op_out.cron_id);
}

test "encodeCronCreateResp ok" {
    var buf: [64]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    var result = ops_mod.OpResult{};
    encodeCronCreateResp(&w, &result, "cron-new");
    var r = BufReader{ .data = w.written() };
    try std.testing.expectEqualStrings("cron-new", try r.readPrefixed());
    try std.testing.expectEqual(@as(u8, 0), try r.readU8());
}
