//! Binary RPC server — high-throughput streaming protocol for Corvo.
//!
//! Wire format: persistent TCP connections with framed binary messages.
//! No HTTP overhead, no JSON parsing — raw binary encode/decode.
//!
//! Frame header (9 bytes):
//!   [msg_type:u8][req_id:u32LE][payload_len:u32LE]
//! Followed by `payload_len` bytes of payload.
//!
//! Supports pipelining: multiple in-flight requests per connection.

const std = @import("std");
const net = std.net;
const store_mod = @import("store.zig");
const ops_mod = @import("ops.zig");
const types = @import("types.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");

// ============================================================================
// Protocol constants
// ============================================================================

pub const FRAME_HEADER_SIZE = 9;
pub const MAX_PAYLOAD_SIZE = 4 * 1024 * 1024; // 4MB max frame

// Request types (client → server)
pub const MSG_ENQUEUE_BATCH: u8 = 0x01;
pub const MSG_FETCH_BATCH: u8 = 0x02;
pub const MSG_ACK_BATCH: u8 = 0x03;
pub const MSG_PING: u8 = 0x04;
pub const MSG_HEARTBEAT: u8 = 0x06;
pub const MSG_FAIL_BATCH: u8 = 0x07;

// Response types (server → client)
pub const MSG_ENQUEUE_BATCH_RESP: u8 = 0x81;
pub const MSG_FETCH_BATCH_RESP: u8 = 0x82;
pub const MSG_ACK_BATCH_RESP: u8 = 0x83;
pub const MSG_PONG: u8 = 0x84;
pub const MSG_HEARTBEAT_RESP: u8 = 0x86;
pub const MSG_FAIL_BATCH_RESP: u8 = 0x87;
pub const MSG_ERROR: u8 = 0xFF;

// ============================================================================
// Frame header
// ============================================================================

pub const FrameHeader = struct {
    msg_type: u8,
    req_id: u32,
    length: u32,
};

/// Read exactly `buf.len` bytes from stream. Returns error on short read.
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
        .length = std.mem.readInt(u32, buf[5..9], .little),
    };
}

pub fn writeHeader(stream: net.Stream, header: FrameHeader) !void {
    var buf: [FRAME_HEADER_SIZE]u8 = undefined;
    buf[0] = header.msg_type;
    std.mem.writeInt(u32, buf[1..5], header.req_id, .little);
    std.mem.writeInt(u32, buf[5..9], header.length, .little);
    try stream.writeAll(&buf);
}

pub fn writeFrame(stream: net.Stream, msg_type: u8, req_id: u32, payload: []const u8) !void {
    var buf: [FRAME_HEADER_SIZE]u8 = undefined;
    buf[0] = msg_type;
    std.mem.writeInt(u32, buf[1..5], req_id, .little);
    std.mem.writeInt(u32, buf[5..9], @intCast(payload.len), .little);
    // Single writev syscall — avoids 2 TCP sends with NODELAY.
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
// Binary encoding helpers
// ============================================================================

pub const BufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    pub fn writeU8(self: *BufWriter, v: u8) void {
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    pub fn writeU16(self: *BufWriter, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .little);
        self.pos += 2;
    }

    pub fn writeU32(self: *BufWriter, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }

    pub fn writeU64(self: *BufWriter, v: u64) void {
        std.mem.writeInt(u64, self.buf[self.pos..][0..8], v, .little);
        self.pos += 8;
    }

    pub fn writeBytes(self: *BufWriter, data: []const u8) void {
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    pub fn writeLenPrefixed(self: *BufWriter, data: []const u8) void {
        self.writeU8(@intCast(data.len));
        self.writeBytes(data);
    }

    pub fn slice(self: *const BufWriter) []const u8 {
        return self.buf[0..self.pos];
    }
};

pub const BufReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn readU8(self: *BufReader) !u8 {
        if (self.pos >= self.data.len) return error.ShortRead;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    pub fn readU16(self: *BufReader) !u16 {
        if (self.pos + 2 > self.data.len) return error.ShortRead;
        const v = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return v;
    }

    pub fn readU32(self: *BufReader) !u32 {
        if (self.pos + 4 > self.data.len) return error.ShortRead;
        const v = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    pub fn readU64(self: *BufReader) !u64 {
        if (self.pos + 8 > self.data.len) return error.ShortRead;
        const v = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    pub fn readLenPrefixed(self: *BufReader) ![]const u8 {
        const len = try self.readU8();
        if (self.pos + len > self.data.len) return error.ShortRead;
        const data = self.data[self.pos..][0..len];
        self.pos += len;
        return data;
    }

    /// Read a u16-length-prefixed byte slice (for payloads up to 64KB).
    pub fn readU16Prefixed(self: *BufReader) ![]const u8 {
        const len = try self.readU16();
        if (self.pos + len > self.data.len) return error.ShortRead;
        const data = self.data[self.pos..][0..len];
        self.pos += len;
        return data;
    }

    pub fn skip(self: *BufReader, n: u16) !void {
        if (self.pos + n > self.data.len) return error.ShortRead;
        self.pos += n;
    }
};

// ============================================================================
// RPC Server
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
                // Thread-per-connection — fine for small number of bench clients.
                _ = std.Thread.spawn(.{}, handleConnection, .{ self, conn.stream }) catch {
                    conn.stream.close();
                    continue;
                };
            } else return;
        }
    }

    const CONN_BUF_SIZE = 65536; // 64KB per connection — plenty for batch ops

    fn handleConnection(self: *RpcServer, stream: net.Stream) void {
        defer stream.close();

        // Disable Nagle for low-latency responses.
        const TCP_NODELAY = 1;
        std.posix.setsockopt(stream.handle, std.posix.IPPROTO.TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        // Per-connection read/write buffers.
        var payload_buf: [CONN_BUF_SIZE]u8 = undefined;
        var resp_buf: [CONN_BUF_SIZE]u8 = undefined;

        while (self.running.load(.monotonic)) {
            const header = readHeader(stream) catch return;

            if (header.length > CONN_BUF_SIZE) {
                writeFrame(stream, MSG_ERROR, header.req_id, "frame too large") catch return;
                return;
            }

            // Read payload.
            if (header.length > 0) {
                readExact(stream, payload_buf[0..header.length]) catch return;
            }

            const payload = payload_buf[0..header.length];

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
// Shared RPC handlers — used by both RpcServer and IoUringRpcServer
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
        const queue = try reader.readLenPrefixed();
        var job_id = try reader.readLenPrefixed();

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
        if (flags & 0x0002 != 0) jobs[i].unique_key = try reader.readLenPrefixed();
        if (flags & 0x0004 != 0) jobs[i].tags = try reader.readLenPrefixed();
        if (flags & 0x0008 != 0) jobs[i].batch_id = try reader.readLenPrefixed();
        if (flags & 0x0010 != 0) jobs[i].chain_id = try reader.readLenPrefixed();
        if (flags & 0x0020 != 0) jobs[i].chain_config = try reader.readLenPrefixed();
        if (flags & 0x0040 != 0) jobs[i].group = try reader.readLenPrefixed();
        if (flags & 0x0080 != 0) jobs[i].parent_id = try reader.readLenPrefixed();
    }

    const result = store.enqueueBatch(jobs);

    var writer = BufWriter{ .buf = resp_buf };
    writer.writeU16(@intCast(jobs.len));
    writer.writeU8(if (result.err != null) 1 else 0);
    return writer.slice();
}

pub fn processAckBatch(store: *store_mod.Store, payload: []const u8, resp_buf: []u8) ![]const u8 {
    var reader = BufReader{ .data = payload };

    _ = try reader.readU64(); // now_ns — store generates its own
    const count = try reader.readU16();

    var stack_acks: [128]ops_mod.AckJob = undefined;
    var id_bufs: [128][64]u8 = undefined;
    var queue_bufs: [128][64]u8 = undefined;
    const n = @min(count, 128);

    for (0..n) |i| {
        const job_id = try reader.readLenPrefixed();
        const queue = try reader.readLenPrefixed();
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

        if (flags & 0x01 != 0) stack_acks[i].result = try reader.readLenPrefixed();
        if (flags & 0x02 != 0) stack_acks[i].checkpoint = try reader.readLenPrefixed();
        if (flags & 0x04 != 0) stack_acks[i].hold_reason = try reader.readLenPrefixed();
    }

    const result = store.ackBatch(stack_acks[0..n]);

    var writer = BufWriter{ .buf = resp_buf };
    writer.writeU16(@intCast(result.affected));
    writer.writeU8(if (result.err != null) 1 else 0);
    return writer.slice();
}

pub fn processFailBatch(store: *store_mod.Store, payload: []const u8, resp_buf: []u8) ![]const u8 {
    var reader = BufReader{ .data = payload };

    _ = try reader.readU64(); // now_ns — store generates its own
    const count = try reader.readU16();

    var stack_fails: [128]ops_mod.FailJob = undefined;
    var id_bufs: [128][64]u8 = undefined;
    var queue_bufs: [128][64]u8 = undefined;
    var err_bufs: [128][256]u8 = undefined;
    const n = @min(count, 128);

    for (0..n) |i| {
        const job_id = try reader.readLenPrefixed();
        const queue = try reader.readLenPrefixed();
        const err_msg = try reader.readLenPrefixed();
        const backtrace = try reader.readLenPrefixed();
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
    return writer.slice();
}

pub fn processHeartbeat(store: *store_mod.Store, payload: []const u8, resp_buf: []u8) ![]const u8 {
    var reader = BufReader{ .data = payload };

    const worker_id = try reader.readLenPrefixed();
    const count = try reader.readU16();

    var id_bufs: [128][64]u8 = undefined;
    var id_slices: [128][]const u8 = undefined;
    var hb_ops: [128]ops_mod.HeartbeatJobOp = undefined;
    const n = @min(count, 128);

    for (0..n) |i| {
        const job_id = try reader.readLenPrefixed();
        const queue = try reader.readLenPrefixed();
        @memcpy(id_bufs[i][0..job_id.len], job_id);
        id_slices[i] = id_bufs[i][0..job_id.len];

        const flags = try reader.readU8();
        var op = ops_mod.HeartbeatJobOp{ .queue = queue };
        if (flags & 0x01 != 0) op.progress = try reader.readLenPrefixed();
        if (flags & 0x02 != 0) op.checkpoint = try reader.readLenPrefixed();
        hb_ops[i] = op;
    }

    const result = store.heartbeat(id_slices[0..n], hb_ops[0..n], worker_id);

    var writer = BufWriter{ .buf = resp_buf };
    writer.writeU16(@intCast(result.affected));
    writer.writeU8(if (result.err != null) 1 else 0);
    return writer.slice();
}

/// Fetch with full job data response (job header + payload from KV).
pub fn processFetchBatch(store: *store_mod.Store, allocator: std.mem.Allocator, payload: []const u8, resp_buf: []u8) ![]const u8 {
    var reader = BufReader{ .data = payload };

    const now_ns = try reader.readU64();
    const count = try reader.readU16();
    const lease_ms = try reader.readU32();
    const worker_id = try reader.readLenPrefixed();
    const queue_count = try reader.readU8();

    var queue_bufs: [16][64]u8 = undefined;
    var queue_slices: [16][]const u8 = undefined;
    const qn = @min(queue_count, 16);
    for (0..qn) |i| {
        const q = try reader.readLenPrefixed();
        @memcpy(queue_bufs[i][0..q.len], q);
        queue_slices[i] = queue_bufs[i][0..q.len];
    }

    const result = store.fetch(queue_slices[0..qn], worker_id, count, lease_ms, now_ns);

    var writer = BufWriter{ .buf = resp_buf };
    writer.writeU16(@intCast(result.affected));

    for (0..result.affected) |i| {
        const f = &result.fetched[i];
        const job_id = f.id_buf[0..f.id_len];
        writer.writeLenPrefixed(job_id);
        writer.writeLenPrefixed(f.queue_buf[0..f.queue_len]);

        var jk_buf: keys.KeyBuf = undefined;
        if (store.engine.get(keys.jobKey(&jk_buf, job_id))) |job_bytes| {
            defer allocator.free(job_bytes);
            const job = codec.decodeJob(job_bytes);
            writer.writeU16(@intCast(job.attempt));
            writer.writeU16(job.max_retries);
            if (job.checkpoint) |cp| {
                writer.writeLenPrefixed(cp);
            } else {
                writer.writeU8(0);
            }
            if (job.tags) |t| {
                writer.writeLenPrefixed(t);
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

    return writer.slice();
}

