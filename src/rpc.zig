//! RPC protocol module — pure encode/decode, zero IO, zero state, zero allocations.
//!
//! Wire format (per frame):
//!   [msg_type:u8][req_id:u32LE][payload_len:u32LE][payload...]
//!
//! All multi-byte integers are little-endian on the wire.
//! String fields use length-prefixed encoding:
//!   - u8-prefixed:  [len:u8][bytes...]   (max 255 bytes)
//!   - u16-prefixed: [len:u16LE][bytes...]  (max 65535 bytes)
//!
//! Optional fields use a flags bitmask to indicate presence.
//!
//! This module is standalone — no IO, no engine, no handler dependencies.
//! BufWriter uses assertions (internal writes). BufReader returns errors (external input).

const std = @import("std");
const net = std.net;
const assert = @import("assert.zig");
const ops_mod = @import("ops.zig");
const types = @import("types.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");

// ============================================================================
// Protocol Constants
// ============================================================================

pub const FRAME_HEADER_SIZE: usize = 9;
pub const MAX_PAYLOAD_SIZE: u32 = 256 * 1024; // 256 KiB
pub const MAX_BATCH_JOBS: u16 = 256;

// Request types (client -> server)
pub const MSG_ENQUEUE_BATCH: u8 = 0x01;
pub const MSG_FETCH_BATCH: u8 = 0x02;
pub const MSG_ACK_BATCH: u8 = 0x03;
pub const MSG_PING: u8 = 0x04;
pub const MSG_HEARTBEAT: u8 = 0x06;
pub const MSG_FAIL_BATCH: u8 = 0x07;

// Management request types
pub const MSG_MAINTENANCE: u8 = 0x10;
pub const MSG_QUEUE_CONFIG: u8 = 0x11;
pub const MSG_CLEAR_QUEUE: u8 = 0x12;
pub const MSG_DELETE_QUEUE: u8 = 0x13;

// Bulk request/response
pub const MSG_BULK_ACTION: u8 = 0x14;
pub const MSG_BULK_ACTION_RESP: u8 = 0x94;

// Batch request/response
pub const MSG_BATCH_CREATE: u8 = 0x15;
pub const MSG_BATCH_SEAL: u8 = 0x16;
pub const MSG_BATCH_CREATE_RESP: u8 = 0x95;
pub const MSG_BATCH_SEAL_RESP: u8 = 0x96;

// Cron request/response
pub const MSG_CRON_CREATE: u8 = 0x17;
pub const MSG_CRON_UPDATE: u8 = 0x18;
pub const MSG_CRON_DELETE: u8 = 0x19;
pub const MSG_CRON_TRIGGER: u8 = 0x1A;
pub const MSG_CRON_CREATE_RESP: u8 = 0x97;
pub const MSG_CRON_UPDATE_RESP: u8 = 0x98;
pub const MSG_CRON_DELETE_RESP: u8 = 0x99;
pub const MSG_CRON_TRIGGER_RESP: u8 = 0x9A;

// Budget + enterprise (HTTP-only, no RPC binary encoding yet)
pub const MSG_SET_BUDGET: u8 = 0x1B;
pub const MSG_DELETE_BUDGET: u8 = 0x1C;
pub const MSG_MODIFY_ENT_SETTING: u8 = 0x1D;
pub const MSG_GLOBAL_CONFIG: u8 = 0x1E;
pub const MSG_SET_BUDGET_RESP: u8 = 0x9B;
pub const MSG_DELETE_BUDGET_RESP: u8 = 0x9C;
pub const MSG_MODIFY_ENT_SETTING_RESP: u8 = 0x9D;
pub const MSG_GLOBAL_CONFIG_RESP: u8 = 0x9E;

// Response types (server -> client)
pub const MSG_ENQUEUE_BATCH_RESP: u8 = 0x81;
pub const MSG_FETCH_BATCH_RESP: u8 = 0x82;
pub const MSG_ACK_BATCH_RESP: u8 = 0x83;
pub const MSG_PONG: u8 = 0x84;
pub const MSG_HEARTBEAT_RESP: u8 = 0x86;
pub const MSG_FAIL_BATCH_RESP: u8 = 0x87;

// Management response types
pub const MSG_MAINTENANCE_RESP: u8 = 0x90;
pub const MSG_QUEUE_CONFIG_RESP: u8 = 0x91;
pub const MSG_CLEAR_QUEUE_RESP: u8 = 0x92;
pub const MSG_DELETE_QUEUE_RESP: u8 = 0x93;

pub const MSG_ERROR: u8 = 0xFF;

// Lifecycle sub-module (parse/encode for enqueue, ack, fail, heartbeat, fetch)
pub const lifecycle = @import("rpc/lifecycle.zig");

// Management sub-module (parse/encode for maintenance, queue config, clear/delete queue)
pub const management = @import("rpc/management.zig");

// Bulk, batch, cron sub-modules
pub const bulk = @import("rpc/bulk.zig");
pub const batch = @import("rpc/batch.zig");
pub const cron = @import("rpc/cron.zig");

// Re-export lifecycle parse/encode functions
pub const parseEnqueue = lifecycle.parseEnqueue;
pub const parseAck = lifecycle.parseAck;
pub const parseFail = lifecycle.parseFail;
pub const parseHeartbeat = lifecycle.parseHeartbeat;
pub const parseFetchSubscribe = lifecycle.parseFetchSubscribe;
pub const FetchSubscription = lifecycle.FetchSubscription;
pub const encodeEnqueueResp = lifecycle.encodeEnqueueResp;
pub const encodeAckResp = lifecycle.encodeAckResp;
pub const encodeFailResp = lifecycle.encodeFailResp;
pub const encodeHeartbeatResp = lifecycle.encodeHeartbeatResp;
pub const encodeFetchResp = lifecycle.encodeFetchResp;
pub const encodeError = lifecycle.encodeError;

// Re-export flag constants
pub const FLAG_PAYLOAD = lifecycle.FLAG_PAYLOAD;
pub const FLAG_UNIQUE_KEY = lifecycle.FLAG_UNIQUE_KEY;
pub const FLAG_TAGS = lifecycle.FLAG_TAGS;
pub const FLAG_BATCH_ID = lifecycle.FLAG_BATCH_ID;
pub const FLAG_CHAIN_ID = lifecycle.FLAG_CHAIN_ID;
pub const FLAG_CHAIN_CONFIG = lifecycle.FLAG_CHAIN_CONFIG;
pub const FLAG_GROUP = lifecycle.FLAG_GROUP;
pub const FLAG_PARENT_ID = lifecycle.FLAG_PARENT_ID;
pub const ACK_FLAG_RESULT = lifecycle.ACK_FLAG_RESULT;
pub const ACK_FLAG_CHECKPOINT = lifecycle.ACK_FLAG_CHECKPOINT;
pub const ACK_FLAG_HOLD_REASON = lifecycle.ACK_FLAG_HOLD_REASON;
pub const HB_FLAG_PROGRESS = lifecycle.HB_FLAG_PROGRESS;
pub const HB_FLAG_CHECKPOINT = lifecycle.HB_FLAG_CHECKPOINT;

// ============================================================================
// FrameHeader
// ============================================================================

pub const FrameHeader = struct {
    msg_type: u8,
    req_id: u32,
    payload_len: u32,
};

/// Read a frame header from a buffer. Returns null if fewer than 9 bytes available.
pub fn readFrameHeader(buf: []const u8) ?FrameHeader {
    if (buf.len < FRAME_HEADER_SIZE) return null;
    return .{
        .msg_type = buf[0],
        .req_id = std.mem.readInt(u32, buf[1..5], .little),
        .payload_len = std.mem.readInt(u32, buf[5..9], .little),
    };
}

/// Write a frame header into a buffer. Buffer must be at least 9 bytes.
pub fn writeFrameHeader(buf: []u8, msg_type: u8, req_id: u32, payload_len: u32) void {
    assert.check(buf.len >= FRAME_HEADER_SIZE, "writeFrameHeader: buffer too small ({d} < 9)", .{buf.len});
    buf[0] = msg_type;
    std.mem.writeInt(u32, buf[1..5], req_id, .little);
    std.mem.writeInt(u32, buf[5..9], payload_len, .little);
}

// ============================================================================
// BufWriter — zero-alloc write helper (assertions, not errors)
// ============================================================================

pub const BufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn writeU8(self: *BufWriter, v: u8) void {
        assert.check(self.pos + 1 <= self.buf.len, "BufWriter.writeU8: overflow (pos={d}, len={d})", .{ self.pos, self.buf.len });
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    pub fn writeU16(self: *BufWriter, v: u16) void {
        assert.check(self.pos + 2 <= self.buf.len, "BufWriter.writeU16: overflow (pos={d}, len={d})", .{ self.pos, self.buf.len });
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .little);
        self.pos += 2;
    }

    pub fn writeU32(self: *BufWriter, v: u32) void {
        assert.check(self.pos + 4 <= self.buf.len, "BufWriter.writeU32: overflow (pos={d}, len={d})", .{ self.pos, self.buf.len });
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }

    pub fn writeU64(self: *BufWriter, v: u64) void {
        assert.check(self.pos + 8 <= self.buf.len, "BufWriter.writeU64: overflow (pos={d}, len={d})", .{ self.pos, self.buf.len });
        std.mem.writeInt(u64, self.buf[self.pos..][0..8], v, .little);
        self.pos += 8;
    }

    pub fn writeBytes(self: *BufWriter, data: []const u8) void {
        assert.check(self.pos + data.len <= self.buf.len, "BufWriter.writeBytes: overflow (pos={d}, data={d}, len={d})", .{ self.pos, data.len, self.buf.len });
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    /// Write u8-length-prefixed bytes: [len:u8][data...]. Max 255 bytes.
    pub fn writePrefixed(self: *BufWriter, data: []const u8) void {
        assert.check(data.len <= 255, "BufWriter.writePrefixed: data too long ({d} > 255)", .{data.len});
        self.writeU8(@intCast(data.len));
        self.writeBytes(data);
    }

    /// Write u16-length-prefixed bytes: [len:u16LE][data...]. Max 65535 bytes.
    pub fn writeU16Prefixed(self: *BufWriter, data: []const u8) void {
        assert.check(data.len <= 65535, "BufWriter.writeU16Prefixed: data too long ({d} > 65535)", .{data.len});
        self.writeU16(@intCast(data.len));
        self.writeBytes(data);
    }

    /// Returns the portion of the buffer that has been written.
    pub fn written(self: *const BufWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

// ============================================================================
// BufReader — zero-alloc read helper (returns errors, untrusted input)
// ============================================================================

pub const ParseError = error{
    ShortRead,
    InvalidCount,
    InvalidEnum,
    InvalidFlags,
};

pub const BufReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn readU8(self: *BufReader) ParseError!u8 {
        if (self.pos + 1 > self.data.len) return error.ShortRead;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readU16(self: *BufReader) ParseError!u16 {
        if (self.pos + 2 > self.data.len) return error.ShortRead;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn readU32(self: *BufReader) ParseError!u32 {
        if (self.pos + 4 > self.data.len) return error.ShortRead;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn readU64(self: *BufReader) ParseError!u64 {
        if (self.pos + 8 > self.data.len) return error.ShortRead;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    /// Read u8-length-prefixed bytes: [len:u8][data...].
    /// Returns a slice into the original buffer (zero-copy).
    pub fn readPrefixed(self: *BufReader) ParseError![]const u8 {
        const len = try self.readU8();
        if (self.pos + len > self.data.len) return error.ShortRead;
        const data = self.data[self.pos..][0..len];
        self.pos += len;
        return data;
    }

    /// Read u16-length-prefixed bytes: [len:u16LE][data...].
    /// Returns a slice into the original buffer (zero-copy).
    pub fn readU16Prefixed(self: *BufReader) ParseError![]const u8 {
        const len = try self.readU16();
        if (self.pos + len > self.data.len) return error.ShortRead;
        const data = self.data[self.pos..][0..len];
        self.pos += len;
        return data;
    }

    pub fn skip(self: *BufReader, n: u16) ParseError!void {
        if (self.pos + n > self.data.len) return error.ShortRead;
        self.pos += n;
    }

    pub fn remaining(self: *const BufReader) usize {
        return self.data.len - self.pos;
    }
};

/// Callback type for looking up job data by ID.
pub const JobDataFn = *const fn (job_id: []const u8, buf: []u8) ?[]const u8;

// ============================================================================
// Response type mapping
// ============================================================================

/// Given a request message type, return the corresponding response type.
pub fn responseType(msg_type: u8) ?u8 {
    return switch (msg_type) {
        MSG_ENQUEUE_BATCH => MSG_ENQUEUE_BATCH_RESP,
        MSG_FETCH_BATCH => MSG_FETCH_BATCH_RESP,
        MSG_ACK_BATCH => MSG_ACK_BATCH_RESP,
        MSG_PING => MSG_PONG,
        MSG_HEARTBEAT => MSG_HEARTBEAT_RESP,
        MSG_FAIL_BATCH => MSG_FAIL_BATCH_RESP,
        MSG_MAINTENANCE => MSG_MAINTENANCE_RESP,
        MSG_QUEUE_CONFIG => MSG_QUEUE_CONFIG_RESP,
        MSG_CLEAR_QUEUE => MSG_CLEAR_QUEUE_RESP,
        MSG_DELETE_QUEUE => MSG_DELETE_QUEUE_RESP,
        MSG_BULK_ACTION => MSG_BULK_ACTION_RESP,
        MSG_BATCH_CREATE => MSG_BATCH_CREATE_RESP,
        MSG_BATCH_SEAL => MSG_BATCH_SEAL_RESP,
        MSG_CRON_CREATE => MSG_CRON_CREATE_RESP,
        MSG_CRON_UPDATE => MSG_CRON_UPDATE_RESP,
        MSG_CRON_DELETE => MSG_CRON_DELETE_RESP,
        MSG_CRON_TRIGGER => MSG_CRON_TRIGGER_RESP,
        MSG_SET_BUDGET => MSG_SET_BUDGET_RESP,
        MSG_DELETE_BUDGET => MSG_DELETE_BUDGET_RESP,
        MSG_MODIFY_ENT_SETTING => MSG_MODIFY_ENT_SETTING_RESP,
        MSG_GLOBAL_CONFIG => MSG_GLOBAL_CONFIG_RESP,
        else => null,
    };
}

// ============================================================================
// Stream-based helpers (used by bench_rpc.zig, sim/client.zig)
// ============================================================================

pub fn readExact(stream: net.Stream, buf: []u8) !void {
    var filled: usize = 0;
    while (filled < buf.len) {
        const n = stream.read(buf[filled..]) catch return error.ConnectionClosed;
        if (n == 0) return error.ConnectionClosed;
        filled += n;
    }
}

pub fn readHeader(stream: net.Stream) !FrameHeader {
    var buf: [FRAME_HEADER_SIZE]u8 = undefined;
    try readExact(stream, &buf);
    return .{
        .msg_type = buf[0],
        .req_id = std.mem.readInt(u32, buf[1..5], .little),
        .payload_len = std.mem.readInt(u32, buf[5..9], .little),
    };
}

pub fn writeHeader(stream: net.Stream, header: FrameHeader) !void {
    var buf: [FRAME_HEADER_SIZE]u8 = undefined;
    buf[0] = header.msg_type;
    std.mem.writeInt(u32, buf[1..5], header.req_id, .little);
    std.mem.writeInt(u32, buf[5..9], header.payload_len, .little);
    try stream.writeAll(&buf);
}

// ============================================================================
// Tests
// ============================================================================

test "frame header roundtrip" {
    var buf: [9]u8 = undefined;
    writeFrameHeader(&buf, MSG_ENQUEUE_BATCH, 42, 1024);
    const hdr = readFrameHeader(&buf).?;
    try std.testing.expectEqual(@as(u8, MSG_ENQUEUE_BATCH), hdr.msg_type);
    try std.testing.expectEqual(@as(u32, 42), hdr.req_id);
    try std.testing.expectEqual(@as(u32, 1024), hdr.payload_len);
}

test "frame header too short returns null" {
    var buf: [8]u8 = undefined;
    try std.testing.expect(readFrameHeader(&buf) == null);
}

test "BufWriter/BufReader roundtrip" {
    var buf: [256]u8 = undefined;
    var w = BufWriter{ .buf = &buf };

    w.writeU8(0xAA);
    w.writeU16(0x1234);
    w.writeU32(0xDEADBEEF);
    w.writeU64(0xCAFEBABE01020304);
    w.writePrefixed("hello");
    w.writeU16Prefixed("world of zig");

    var r = BufReader{ .data = w.written() };
    try std.testing.expectEqual(@as(u8, 0xAA), try r.readU8());
    try std.testing.expectEqual(@as(u16, 0x1234), try r.readU16());
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), try r.readU32());
    try std.testing.expectEqual(@as(u64, 0xCAFEBABE01020304), try r.readU64());
    try std.testing.expectEqualStrings("hello", try r.readPrefixed());
    try std.testing.expectEqualStrings("world of zig", try r.readU16Prefixed());
    try std.testing.expectEqual(@as(usize, 0), r.remaining());
}

test "BufReader short read" {
    var r = BufReader{ .data = &[_]u8{0x01} };
    try std.testing.expectError(error.ShortRead, r.readU16());
}

test "BufReader skip" {
    var r = BufReader{ .data = &[_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05 } };
    try r.skip(3);
    try std.testing.expectEqual(@as(u8, 0x04), try r.readU8());
    try std.testing.expectEqual(@as(usize, 1), r.remaining());
}

test "responseType mapping" {
    try std.testing.expectEqual(@as(?u8, MSG_ENQUEUE_BATCH_RESP), responseType(MSG_ENQUEUE_BATCH));
    try std.testing.expectEqual(@as(?u8, MSG_FETCH_BATCH_RESP), responseType(MSG_FETCH_BATCH));
    try std.testing.expectEqual(@as(?u8, MSG_ACK_BATCH_RESP), responseType(MSG_ACK_BATCH));
    try std.testing.expectEqual(@as(?u8, MSG_PONG), responseType(MSG_PING));
    try std.testing.expectEqual(@as(?u8, MSG_HEARTBEAT_RESP), responseType(MSG_HEARTBEAT));
    try std.testing.expectEqual(@as(?u8, MSG_FAIL_BATCH_RESP), responseType(MSG_FAIL_BATCH));
    try std.testing.expectEqual(@as(?u8, null), responseType(0xFE));
}
