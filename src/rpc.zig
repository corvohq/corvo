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
const store_mod = @import("store.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");

// ============================================================================
// Protocol Constants
// ============================================================================

pub const FRAME_HEADER_SIZE: usize = 9;
pub const MAX_PAYLOAD_SIZE: u32 = 4 * 1024 * 1024; // 4 MiB
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
pub const MSG_SET_BUDGET_RESP: u8 = 0x9B;
pub const MSG_DELETE_BUDGET_RESP: u8 = 0x9C;
pub const MSG_MODIFY_ENT_SETTING_RESP: u8 = 0x9D;

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
        else => null,
    };
}

// ============================================================================
// Legacy stream-based helpers (used by rpc_uring.zig, bench_rpc.zig)
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

pub fn writeFrame(stream: net.Stream, msg_type: u8, req_id: u32, payload: []const u8) !void {
    var buf: [FRAME_HEADER_SIZE]u8 = undefined;
    buf[0] = msg_type;
    std.mem.writeInt(u32, buf[1..5], req_id, .little);
    std.mem.writeInt(u32, buf[5..9], @intCast(payload.len), .little);
    if (payload.len > 0) {
        const iov = [_]std.posix.iovec_const{
            .{ .base = &buf, .len = FRAME_HEADER_SIZE },
            .{ .base = payload.ptr, .len = payload.len },
        };
        _ = stream.writev(&iov) catch return error.ConnectionClosed;
    } else {
        try stream.writeAll(&buf);
    }
}

// ============================================================================
// Legacy RPC server (used by rpc_uring.zig)
// ============================================================================

pub const RpcConfig = struct {
    port: u16 = 9878,
    bind_address: []const u8 = "0.0.0.0",
};

pub const RpcServer = struct {
    store: *store_mod.Store,
    config: RpcConfig,
    listener: ?net.Server = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accept_thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, store: *store_mod.Store, config: RpcConfig) RpcServer {
        return .{
            .store = store,
            .config = config,
            .allocator = allocator,
        };
    }

    pub fn start(self: *RpcServer) !void {
        const addr = try net.Address.parseIp(self.config.bind_address, self.config.port);
        self.listener = try addr.listen(.{ .reuse_address = true });
        self.running.store(true, .monotonic);
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *RpcServer) void {
        self.running.store(false, .monotonic);
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }
    }

    fn acceptLoop(self: *RpcServer) void {
        while (self.running.load(.monotonic)) {
            if (self.listener) |*l| {
                const conn = l.accept() catch {
                    if (!self.running.load(.monotonic)) return;
                    continue;
                };
                _ = std.Thread.spawn(.{}, handleConnection, .{ self, conn.stream }) catch {
                    conn.stream.close();
                    continue;
                };
            } else return;
        }
    }

    const CONN_BUF_SIZE = 65536;

    fn handleConnection(self: *RpcServer, stream: net.Stream) void {
        defer stream.close();

        const TCP_NODELAY = 1;
        std.posix.setsockopt(stream.handle, std.posix.IPPROTO.TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        var payload_buf: [CONN_BUF_SIZE]u8 = undefined;
        var resp_buf: [CONN_BUF_SIZE]u8 = undefined;

        while (self.running.load(.monotonic)) {
            const header = readHeader(stream) catch return;

            if (header.payload_len > CONN_BUF_SIZE) {
                writeFrame(stream, MSG_ERROR, header.req_id, "frame too large") catch return;
                return;
            }

            if (header.payload_len > 0) {
                readExact(stream, payload_buf[0..header.payload_len]) catch return;
            }

            const payload = payload_buf[0..header.payload_len];

            switch (header.msg_type) {
                MSG_ENQUEUE_BATCH => {
                    const resp = self.handleEnqueueBatch(payload, &resp_buf) catch {
                        writeFrame(stream, MSG_ERROR, header.req_id, "enqueue failed") catch return;
                        continue;
                    };
                    writeFrame(stream, MSG_ENQUEUE_BATCH_RESP, header.req_id, resp) catch return;
                },
                MSG_FETCH_BATCH => {
                    const resp = self.handleFetchBatch(payload, &resp_buf) catch {
                        writeFrame(stream, MSG_ERROR, header.req_id, "fetch failed") catch return;
                        continue;
                    };
                    writeFrame(stream, MSG_FETCH_BATCH_RESP, header.req_id, resp) catch return;
                },
                MSG_ACK_BATCH => {
                    const resp = self.handleAckBatch(payload, &resp_buf) catch {
                        writeFrame(stream, MSG_ERROR, header.req_id, "ack failed") catch return;
                        continue;
                    };
                    writeFrame(stream, MSG_ACK_BATCH_RESP, header.req_id, resp) catch return;
                },
                MSG_HEARTBEAT => {
                    const resp = self.handleHeartbeat(payload, &resp_buf) catch {
                        writeFrame(stream, MSG_ERROR, header.req_id, "heartbeat failed") catch return;
                        continue;
                    };
                    writeFrame(stream, MSG_HEARTBEAT_RESP, header.req_id, resp) catch return;
                },
                MSG_FAIL_BATCH => {
                    const resp = self.handleFailBatch(payload, &resp_buf) catch {
                        writeFrame(stream, MSG_ERROR, header.req_id, "fail failed") catch return;
                        continue;
                    };
                    writeFrame(stream, MSG_FAIL_BATCH_RESP, header.req_id, resp) catch return;
                },
                MSG_PING => {
                    writeFrame(stream, MSG_PONG, header.req_id, "") catch return;
                },
                else => {
                    writeFrame(stream, MSG_ERROR, header.req_id, "unknown msg type") catch return;
                },
            }
        }
    }

    fn handleEnqueueBatch(self: *RpcServer, payload: []const u8, resp_buf: *[CONN_BUF_SIZE]u8) ![]const u8 {
        return processEnqueueBatch(self.store, payload, resp_buf);
    }
    fn handleFetchBatch(self: *RpcServer, payload: []const u8, resp_buf: *[CONN_BUF_SIZE]u8) ![]const u8 {
        return processFetchBatch(self.store, self.allocator, payload, resp_buf);
    }
    fn handleAckBatch(self: *RpcServer, payload: []const u8, resp_buf: *[CONN_BUF_SIZE]u8) ![]const u8 {
        return processAckBatch(self.store, payload, resp_buf);
    }
    fn handleHeartbeat(self: *RpcServer, payload: []const u8, resp_buf: *[CONN_BUF_SIZE]u8) ![]const u8 {
        return processHeartbeat(self.store, payload, resp_buf);
    }
    fn handleFailBatch(self: *RpcServer, payload_data: []const u8, resp_buf: *[CONN_BUF_SIZE]u8) ![]const u8 {
        return processFailBatch(self.store, payload_data, resp_buf);
    }
};

// ============================================================================
// Legacy RPC handlers (used by rpc_uring.zig)
// ============================================================================

pub fn processEnqueueBatch(store: *store_mod.Store, payload: []const u8, resp_buf: []u8) ![]const u8 {
    var reader = BufReader{ .data = payload };

    const count = try reader.readU16();
    const now_ns = try reader.readU64();

    var stack_jobs: [128]ops_mod.EnqueueJob = undefined;
    const n = @min(count, 128);
    const jobs = stack_jobs[0..n];

    var id_bufs: [128][64]u8 = undefined;
    var queue_bufs: [128][64]u8 = undefined;
    var gen_id_bufs: [128][64]u8 = undefined;

    for (0..n) |i| {
        const queue = try reader.readPrefixed();
        var job_id = try reader.readPrefixed();

        if (job_id.len == 0) {
            const generated = store.generateID(&gen_id_bufs[i]);
            job_id = generated;
        }
        const priority = try reader.readU8();
        const max_retries = try reader.readU16();
        const backoff_raw = try reader.readU8();
        const base_delay_ms = try reader.readU32();
        const max_delay_ms = try reader.readU32();
        const unique_period_s = try reader.readU32();
        const scheduled_at_ns = try reader.readU64();
        const expire_after_ms = try reader.readU32();
        const chain_step = try reader.readU16();
        const flags = try reader.readU16();

        @memcpy(id_bufs[i][0..job_id.len], job_id);
        @memcpy(queue_bufs[i][0..queue.len], queue);

        const backoff: types.Backoff = std.meta.intToEnum(types.Backoff, backoff_raw) catch .none;

        jobs[i] = .{
            .job_id = id_bufs[i][0..job_id.len],
            .queue = queue_bufs[i][0..queue.len],
            .priority = priority,
            .max_retries = max_retries,
            .backoff = backoff,
            .base_delay_ms = base_delay_ms,
            .max_delay_ms = max_delay_ms,
            .unique_period_s = unique_period_s,
            .scheduled_at_ns = scheduled_at_ns,
            .expire_after_ms = expire_after_ms,
            .chain_step = chain_step,
            .created_at_ns = now_ns,
        };

        if (flags & 0x0001 != 0) jobs[i].payload = try reader.readU16Prefixed();
        if (flags & 0x0002 != 0) jobs[i].unique_key = try reader.readPrefixed();
        if (flags & 0x0004 != 0) jobs[i].tags = try reader.readPrefixed();
        if (flags & 0x0008 != 0) jobs[i].batch_id = try reader.readPrefixed();
        if (flags & 0x0010 != 0) jobs[i].chain_id = try reader.readPrefixed();
        if (flags & 0x0020 != 0) jobs[i].chain_config = try reader.readPrefixed();
        if (flags & 0x0040 != 0) jobs[i].group = try reader.readPrefixed();
        if (flags & 0x0080 != 0) jobs[i].parent_id = try reader.readPrefixed();
    }

    const result = store.enqueueBatch(jobs);

    var writer = BufWriter{ .buf = resp_buf };
    writer.writeU16(@intCast(jobs.len));
    writer.writeU8(if (result.err != null) 1 else 0);
    return writer.written();
}

pub fn processAckBatch(store: *store_mod.Store, payload: []const u8, resp_buf: []u8) ![]const u8 {
    var reader = BufReader{ .data = payload };

    _ = try reader.readU64(); // now_ns
    const count = try reader.readU16();

    var stack_acks: [128]ops_mod.AckJob = undefined;
    var id_bufs: [128][64]u8 = undefined;
    var queue_bufs: [128][64]u8 = undefined;
    const n = @min(count, 128);

    for (0..n) |i| {
        const job_id = try reader.readPrefixed();
        const queue = try reader.readPrefixed();
        const ack_status_raw = try reader.readU8();
        const flags = try reader.readU8();

        @memcpy(id_bufs[i][0..job_id.len], job_id);
        @memcpy(queue_bufs[i][0..queue.len], queue);

        const ack_status: types.AckStatus = std.meta.intToEnum(types.AckStatus, ack_status_raw) catch .done;

        stack_acks[i] = .{
            .job_id = id_bufs[i][0..job_id.len],
            .queue = queue_bufs[i][0..queue.len],
            .ack_status = ack_status,
        };

        if (flags & 0x01 != 0) stack_acks[i].result = try reader.readPrefixed();
        if (flags & 0x02 != 0) stack_acks[i].checkpoint = try reader.readPrefixed();
        if (flags & 0x04 != 0) stack_acks[i].hold_reason = try reader.readPrefixed();
    }

    const result = store.ackBatch(stack_acks[0..n]);

    var writer = BufWriter{ .buf = resp_buf };
    writer.writeU16(@intCast(result.affected));
    writer.writeU8(if (result.err != null) 1 else 0);
    return writer.written();
}

pub fn processFailBatch(store: *store_mod.Store, payload: []const u8, resp_buf: []u8) ![]const u8 {
    var reader = BufReader{ .data = payload };

    _ = try reader.readU64(); // now_ns
    const count = try reader.readU16();

    var stack_fails: [128]ops_mod.FailJob = undefined;
    var id_bufs: [128][64]u8 = undefined;
    var queue_bufs: [128][64]u8 = undefined;
    var err_bufs: [128][256]u8 = undefined;
    const n = @min(count, 128);

    for (0..n) |i| {
        const job_id = try reader.readPrefixed();
        const queue = try reader.readPrefixed();
        const err_msg = try reader.readPrefixed();
        const backtrace = try reader.readPrefixed();
        @memcpy(id_bufs[i][0..job_id.len], job_id);
        @memcpy(queue_bufs[i][0..queue.len], queue);
        @memcpy(err_bufs[i][0..err_msg.len], err_msg);
        stack_fails[i] = .{
            .job_id = id_bufs[i][0..job_id.len],
            .queue = queue_bufs[i][0..queue.len],
            .error_msg = err_bufs[i][0..err_msg.len],
            .backtrace = if (backtrace.len > 0) backtrace else null,
        };
    }

    const result = store.failBatch(stack_fails[0..n]);

    var writer = BufWriter{ .buf = resp_buf };
    writer.writeU16(@intCast(result.affected));
    writer.writeU8(if (result.err != null) 1 else 0);
    return writer.written();
}

pub fn processHeartbeat(store: *store_mod.Store, payload: []const u8, resp_buf: []u8) ![]const u8 {
    var reader = BufReader{ .data = payload };

    const worker_id = try reader.readPrefixed();
    const count = try reader.readU16();

    var id_bufs: [128][64]u8 = undefined;
    var id_slices: [128][]const u8 = undefined;
    var hb_ops: [128]ops_mod.HeartbeatJobOp = undefined;
    const n = @min(count, 128);

    for (0..n) |i| {
        const job_id = try reader.readPrefixed();
        const queue = try reader.readPrefixed();
        @memcpy(id_bufs[i][0..job_id.len], job_id);
        id_slices[i] = id_bufs[i][0..job_id.len];

        const flags = try reader.readU8();
        var op = ops_mod.HeartbeatJobOp{ .queue = queue };
        if (flags & 0x01 != 0) op.progress = try reader.readPrefixed();
        if (flags & 0x02 != 0) op.checkpoint = try reader.readPrefixed();
        hb_ops[i] = op;
    }

    const result = store.heartbeat(id_slices[0..n], hb_ops[0..n], worker_id);

    var writer = BufWriter{ .buf = resp_buf };
    writer.writeU16(@intCast(result.affected));
    writer.writeU8(if (result.err != null) 1 else 0);
    return writer.written();
}

pub fn processFetchBatch(store: *store_mod.Store, allocator: std.mem.Allocator, payload: []const u8, resp_buf: []u8) ![]const u8 {
    var reader = BufReader{ .data = payload };

    const now_ns = try reader.readU64();
    const count = try reader.readU16();
    const lease_ms = try reader.readU32();
    const worker_id = try reader.readPrefixed();
    const queue_count = try reader.readU8();

    var queue_bufs: [16][64]u8 = undefined;
    var queue_slices: [16][]const u8 = undefined;
    const qn = @min(queue_count, 16);
    for (0..qn) |i| {
        const q = try reader.readPrefixed();
        @memcpy(queue_bufs[i][0..q.len], q);
        queue_slices[i] = queue_bufs[i][0..q.len];
    }

    const result = store.fetch(queue_slices[0..qn], worker_id, count, lease_ms, now_ns);

    var writer = BufWriter{ .buf = resp_buf };
    writer.writeU16(@intCast(result.affected));

    for (0..result.affected) |i| {
        const f = &result.fetched[i];
        const job_id = f.id_buf[0..f.id_len];
        writer.writePrefixed(job_id);
        writer.writePrefixed(f.queue_buf[0..f.queue_len]);

        var jk_buf: keys.KeyBuf = undefined;
        if (store.engine.get(keys.jobKey(&jk_buf, job_id))) |job_bytes| {
            defer allocator.free(job_bytes);
            const job = codec.decodeJob(job_bytes);
            writer.writeU16(@intCast(job.attempt));
            writer.writeU16(job.max_retries);
            if (job.checkpoint) |cp| {
                writer.writePrefixed(cp);
            } else {
                writer.writeU8(0);
            }
            if (job.tags) |t| {
                writer.writePrefixed(t);
            } else {
                writer.writeU8(0);
            }
        } else {
            writer.writeU16(0);
            writer.writeU16(0);
            writer.writeU8(0);
            writer.writeU8(0);
        }

        var jpk_buf: keys.KeyBuf = undefined;
        if (store.engine.get(keys.jobPayloadKey(&jpk_buf, job_id))) |payload_bytes| {
            defer allocator.free(payload_bytes);
            const pl = @min(payload_bytes.len, @as(usize, 32768));
            writer.writeU16(@intCast(pl));
            writer.writeBytes(payload_bytes[0..pl]);
        } else {
            writer.writeU16(0);
        }
    }

    return writer.written();
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
