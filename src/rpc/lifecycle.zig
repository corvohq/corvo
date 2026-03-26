//! Lifecycle parse/encode functions for job operations (enqueue, ack, fail, heartbeat, fetch).
//!
//! Moved from rpc.zig — these handle the domain-specific wire encoding for
//! job lifecycle messages. Core protocol types (BufWriter, BufReader, FrameHeader)
//! remain in the parent rpc module.

const std = @import("std");
const rpc = @import("../rpc.zig");
const assert = @import("../assert.zig");
const ops_mod = @import("../ops.zig");
const types = @import("../types.zig");

const BufReader = rpc.BufReader;
const BufWriter = rpc.BufWriter;
const ParseError = rpc.ParseError;
const MAX_BATCH_JOBS = rpc.MAX_BATCH_JOBS;
const JobDataFn = rpc.JobDataFn;

// ============================================================================
// Enqueue optional field flags
// ============================================================================

pub const FLAG_PAYLOAD: u16 = 0x0001;
pub const FLAG_UNIQUE_KEY: u16 = 0x0002;
pub const FLAG_TAGS: u16 = 0x0004;
pub const FLAG_BATCH_ID: u16 = 0x0008;
pub const FLAG_CHAIN_ID: u16 = 0x0010;
pub const FLAG_CHAIN_CONFIG: u16 = 0x0020;
pub const FLAG_GROUP: u16 = 0x0040;
pub const FLAG_PARENT_ID: u16 = 0x0080;

// ============================================================================
// Ack optional field flags
// ============================================================================

pub const ACK_FLAG_RESULT: u8 = 0x01;
pub const ACK_FLAG_CHECKPOINT: u8 = 0x02;
pub const ACK_FLAG_HOLD_REASON: u8 = 0x04;

// ============================================================================
// Heartbeat optional field flags
// ============================================================================

pub const HB_FLAG_PROGRESS: u8 = 0x01;
pub const HB_FLAG_CHECKPOINT: u8 = 0x02;

// ============================================================================
// Parse functions
// ============================================================================

pub fn parseEnqueue(reader: *BufReader, jobs_buf: []ops_mod.EnqueueJob, now_ns: u64) ParseError!struct { count: u16, op: ops_mod.EnqueueOp } {
    const count = try reader.readU16();
    if (count == 0 or count > MAX_BATCH_JOBS) return error.InvalidCount;
    if (count > jobs_buf.len) return error.InvalidCount;

    for (0..count) |i| {
        var job = ops_mod.EnqueueJob{};

        job.queue = try reader.readPrefixed();
        job.job_id = try reader.readPrefixed();
        job.priority = try reader.readU8();
        job.max_retries = try reader.readU16();

        const backoff_raw = try reader.readU8();
        job.backoff = std.meta.intToEnum(types.Backoff, backoff_raw) catch return error.InvalidEnum;

        job.base_delay_ms = try reader.readU32();
        job.max_delay_ms = try reader.readU32();
        job.unique_period_s = try reader.readU32();
        job.scheduled_at_ns = try reader.readU64();
        job.expire_after_ms = try reader.readU32();
        job.chain_step = try reader.readU16();

        const flags = try reader.readU16();

        if (flags & FLAG_PAYLOAD != 0) job.payload = try reader.readU16Prefixed();
        if (flags & FLAG_UNIQUE_KEY != 0) job.unique_key = try reader.readPrefixed();
        if (flags & FLAG_TAGS != 0) job.tags = try reader.readPrefixed();
        if (flags & FLAG_BATCH_ID != 0) job.batch_id = try reader.readPrefixed();
        if (flags & FLAG_CHAIN_ID != 0) job.chain_id = try reader.readPrefixed();
        if (flags & FLAG_CHAIN_CONFIG != 0) job.chain_config = try reader.readPrefixed();
        if (flags & FLAG_GROUP != 0) job.group = try reader.readPrefixed();
        if (flags & FLAG_PARENT_ID != 0) job.parent_id = try reader.readPrefixed();

        if (job.scheduled_at_ns > 0) job.state = .scheduled;
        job.created_at_ns = now_ns;
        jobs_buf[i] = job;
    }

    return .{
        .count = count,
        .op = .{
            .jobs = jobs_buf[0..count],
            .now_ns = now_ns,
        },
    };
}

pub fn parseAck(reader: *BufReader, acks_buf: []ops_mod.AckJob) ParseError!struct { count: u16, op: ops_mod.AckOp } {
    const count = try reader.readU16();
    if (count == 0 or count > MAX_BATCH_JOBS) return error.InvalidCount;
    if (count > acks_buf.len) return error.InvalidCount;

    for (0..count) |i| {
        var ack = ops_mod.AckJob{};

        ack.job_id = try reader.readPrefixed();
        ack.queue = try reader.readPrefixed();

        const status_raw = try reader.readU8();
        ack.ack_status = std.meta.intToEnum(types.AckStatus, status_raw) catch return error.InvalidEnum;

        const flags = try reader.readU8();

        if (flags & ACK_FLAG_RESULT != 0) ack.result = try reader.readPrefixed();
        if (flags & ACK_FLAG_CHECKPOINT != 0) ack.checkpoint = try reader.readPrefixed();
        if (flags & ACK_FLAG_HOLD_REASON != 0) ack.hold_reason = try reader.readPrefixed();

        acks_buf[i] = ack;
    }

    return .{
        .count = count,
        .op = .{
            .acks = acks_buf[0..count],
            .now_ns = 0,
        },
    };
}

pub fn parseFail(reader: *BufReader, fails_buf: []ops_mod.FailJob) ParseError!struct { count: u16, op: ops_mod.FailOp } {
    const count = try reader.readU16();
    if (count == 0 or count > MAX_BATCH_JOBS) return error.InvalidCount;
    if (count > fails_buf.len) return error.InvalidCount;

    for (0..count) |i| {
        var fail = ops_mod.FailJob{};

        fail.job_id = try reader.readPrefixed();
        fail.queue = try reader.readPrefixed();
        fail.error_msg = try reader.readPrefixed();

        const backtrace = try reader.readPrefixed();
        fail.backtrace = if (backtrace.len > 0) backtrace else null;

        fails_buf[i] = fail;
    }

    return .{
        .count = count,
        .op = .{
            .jobs = fails_buf[0..count],
            .now_ns = 0,
        },
    };
}

pub fn parseHeartbeat(
    reader: *BufReader,
    ids_buf: [][]const u8,
    job_ops_buf: []ops_mod.HeartbeatJobOp,
) ParseError!ops_mod.HeartbeatOp {
    const worker_id = try reader.readPrefixed();
    const count = try reader.readU16();
    if (count == 0 or count > MAX_BATCH_JOBS) return error.InvalidCount;
    if (count > ids_buf.len or count > job_ops_buf.len) return error.InvalidCount;

    for (0..count) |i| {
        ids_buf[i] = try reader.readPrefixed();
        const queue = try reader.readPrefixed();

        const flags = try reader.readU8();

        var progress: ?[]const u8 = null;
        var checkpoint: ?[]const u8 = null;

        if (flags & HB_FLAG_PROGRESS != 0) progress = try reader.readPrefixed();
        if (flags & HB_FLAG_CHECKPOINT != 0) checkpoint = try reader.readPrefixed();

        job_ops_buf[i] = .{
            .queue = queue,
            .progress = progress,
            .checkpoint = checkpoint,
        };
    }

    return .{
        .job_ids = ids_buf[0..count],
        .job_ops = job_ops_buf[0..count],
        .worker_id = worker_id,
        .now_ns = 0,
    };
}

pub const FetchSubscription = struct {
    queues: [16][]const u8 = undefined,
    queue_count: u8 = 0,
    worker_id: []const u8 = "",
    credits: u32 = 0,
    lease_ms: u32 = 0,
};

pub fn parseFetchSubscribe(reader: *BufReader) ParseError!FetchSubscription {
    var sub = FetchSubscription{};

    sub.credits = try reader.readU16();
    sub.lease_ms = try reader.readU32();
    sub.worker_id = try reader.readPrefixed();

    const queue_count = try reader.readU8();
    if (queue_count == 0 or queue_count > 16) return error.InvalidCount;
    sub.queue_count = queue_count;

    for (0..queue_count) |i| {
        sub.queues[i] = try reader.readPrefixed();
    }

    return sub;
}

// ============================================================================
// Encode functions
// ============================================================================

pub fn encodeEnqueueResp(writer: *BufWriter, result: *const ops_mod.OpResult, count: u16) void {
    writer.writeU16(count);
    writer.writeU8(if (result.err != null) @as(u8, 1) else 0);
}

pub fn encodeAckResp(writer: *BufWriter, result: *const ops_mod.OpResult, count: u16) void {
    _ = count;
    writer.writeU16(@intCast(result.affected));
    writer.writeU8(if (result.err != null) @as(u8, 1) else 0);
}

pub fn encodeFailResp(writer: *BufWriter, result: *const ops_mod.OpResult, count: u16) void {
    _ = count;
    writer.writeU16(@intCast(result.affected));
    writer.writeU8(if (result.err != null) @as(u8, 1) else 0);
}

pub fn encodeHeartbeatResp(writer: *BufWriter, result: *const ops_mod.OpResult, count: u16) void {
    _ = count;
    writer.writeU16(@intCast(result.affected));
    writer.writeU8(if (result.err != null) @as(u8, 1) else 0);
}

pub fn encodeFetchResp(writer: *BufWriter, result: *const ops_mod.OpResult, payload_fn: JobDataFn) void {
    const count: u16 = @intCast(result.affected);
    writer.writeU16(count);

    for (0..count) |i| {
        const fetched = &result.fetched[i];
        const job_id = fetched.id_buf[0..fetched.id_len];
        const queue = fetched.queue_buf[0..fetched.queue_len];

        writer.writePrefixed(job_id);
        writer.writePrefixed(queue);
        writer.writeU16(fetched.attempt);
        writer.writeU16(fetched.max_retries);

        // Checkpoint + tags: u8 length prefix (0 = empty).
        writer.writeU8(0);
        writer.writeU8(0);

        var payload_buf: [65536]u8 = undefined;
        const payload = payload_fn(job_id, &payload_buf);
        if (payload) |p| {
            assert.check(p.len <= 65535, "encodeFetchResp: payload too large ({d} > 65535)", .{p.len});
            writer.writeU16(@intCast(p.len));
            writer.writeBytes(p);
        } else {
            writer.writeU16(0);
        }
    }
}

pub fn encodeError(writer: *BufWriter, msg: []const u8) void {
    writer.writeBytes(msg);
}

// ============================================================================
// Tests
// ============================================================================

test "parseEnqueue roundtrip" {
    var buf: [512]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    w.writeU16(1);
    w.writePrefixed("test-queue");
    w.writePrefixed("job-001");
    w.writeU8(75);
    w.writeU16(3);
    w.writeU8(3); // exponential
    w.writeU32(1000);
    w.writeU32(60000);
    w.writeU32(0);
    w.writeU64(0);
    w.writeU32(0);
    w.writeU16(0);
    w.writeU16(FLAG_PAYLOAD);
    w.writeU16Prefixed("{\"task\":\"test\"}");

    var jobs_buf: [MAX_BATCH_JOBS]ops_mod.EnqueueJob = undefined;
    var r = BufReader{ .data = w.written() };
    const result = try parseEnqueue(&r, &jobs_buf, 1000);

    try std.testing.expectEqual(@as(u16, 1), result.count);
    try std.testing.expectEqualStrings("test-queue", result.op.jobs[0].queue);
    try std.testing.expectEqualStrings("job-001", result.op.jobs[0].job_id);
    try std.testing.expectEqual(@as(u8, 75), result.op.jobs[0].priority);
    try std.testing.expectEqual(types.Backoff.exponential, result.op.jobs[0].backoff);
    try std.testing.expectEqualStrings("{\"task\":\"test\"}", result.op.jobs[0].payload.?);
}

test "parseAck roundtrip" {
    var buf: [256]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    w.writeU16(1);
    w.writePrefixed("job-001");
    w.writePrefixed("test-queue");
    w.writeU8(0); // done
    w.writeU8(ACK_FLAG_RESULT);
    w.writePrefixed("ok");

    var acks_buf: [MAX_BATCH_JOBS]ops_mod.AckJob = undefined;
    var r = BufReader{ .data = w.written() };
    const result = try parseAck(&r, &acks_buf);

    try std.testing.expectEqual(@as(u16, 1), result.count);
    try std.testing.expectEqualStrings("job-001", result.op.acks[0].job_id);
    try std.testing.expectEqual(types.AckStatus.done, result.op.acks[0].ack_status);
    try std.testing.expectEqualStrings("ok", result.op.acks[0].result.?);
}

test "parseFail roundtrip" {
    var buf: [256]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    w.writeU16(1);
    w.writePrefixed("job-001");
    w.writePrefixed("test-queue");
    w.writePrefixed("connection timeout");
    w.writePrefixed("");

    var fails_buf: [MAX_BATCH_JOBS]ops_mod.FailJob = undefined;
    var r = BufReader{ .data = w.written() };
    const result = try parseFail(&r, &fails_buf);

    try std.testing.expectEqual(@as(u16, 1), result.count);
    try std.testing.expectEqualStrings("connection timeout", result.op.jobs[0].error_msg);
    try std.testing.expect(result.op.jobs[0].backtrace == null);
}

test "parseFetchSubscribe roundtrip" {
    var buf: [256]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    w.writeU16(10);
    w.writeU32(30000);
    w.writePrefixed("worker-1");
    w.writeU8(2);
    w.writePrefixed("default");
    w.writePrefixed("priority");

    var r = BufReader{ .data = w.written() };
    const result = try parseFetchSubscribe(&r);

    try std.testing.expectEqual(@as(u32, 10), result.credits);
    try std.testing.expectEqual(@as(u32, 30000), result.lease_ms);
    try std.testing.expectEqualStrings("worker-1", result.worker_id);
    try std.testing.expectEqual(@as(u8, 2), result.queue_count);
    try std.testing.expectEqualStrings("default", result.queues[0]);
}

test "encodeEnqueueResp ok" {
    var buf: [16]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    var result = ops_mod.OpResult{};
    encodeEnqueueResp(&w, &result, 5);

    var r = BufReader{ .data = w.written() };
    try std.testing.expectEqual(@as(u16, 5), try r.readU16());
    try std.testing.expectEqual(@as(u8, 0), try r.readU8());
}

test "parseEnqueue invalid count" {
    var buf: [4]u8 = undefined;
    var w = BufWriter{ .buf = &buf };
    w.writeU16(0);

    var jobs_buf: [MAX_BATCH_JOBS]ops_mod.EnqueueJob = undefined;
    var r = BufReader{ .data = w.written() };
    try std.testing.expectError(error.InvalidCount, parseEnqueue(&r, &jobs_buf, 0));
}
