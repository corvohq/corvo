//! io_uring-based RPC Server — high-throughput async I/O for Linux.
//!
//! Architecture:
//!   Event loop thread: io_uring for accept + recv (CQE processing)
//!   Worker pool (8 threads): decode → pipeline.submit (blocking) → encode → blocking send
//!   Hybrid I/O: io_uring for recv (async), blocking write() for send (avoids ring_mu contention)
//!   Synchronization: ring_mu protects SQE submission; copy_cqes is lock-free (CQ only)
//!
//! At 64 connections: ~50% faster enqueue, ~80% faster lifecycle vs thread-per-connection.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const IoUring = linux.IoUring;
const net = std.net;
const store_mod = @import("store.zig");
const ops_mod = @import("ops.zig");
const rpc = @import("rpc.zig");

const BufWriter = rpc.BufWriter;
const BufReader = rpc.BufReader;

// ============================================================================
// Config
// ============================================================================

const RING_ENTRIES: u16 = 4096;
const MAX_CONNS: usize = 65535;
const CONN_BUF_SIZE: usize = 65536;
const WORK_QUEUE_CAP: usize = 4096;
const MAX_WORKERS: usize = 16;
const DEFAULT_WORKERS: u8 = 8;
const HDR: usize = rpc.FRAME_HEADER_SIZE; // 9

// ============================================================================
// user_data encoding: [op:8][conn_id:16]
// ============================================================================

const OP_ACCEPT: u64 = 1 << 16;
const OP_RECV: u64 = 2 << 16;
const OP_MASK: u64 = 0xFFFF_0000;

fn ud(op: u64, conn_id: u16) u64 {
    return op | @as(u64, conn_id);
}
fn udOp(data: u64) u64 {
    return data & OP_MASK;
}
fn udConn(data: u64) u16 {
    return @intCast(data & 0xFFFF);
}

// ============================================================================
// Connection state
// ============================================================================

const ConnPhase = enum { free, idle, recv, processing };

const ConnState = struct {
    fd: posix.fd_t = -1,
    phase: ConnPhase = .free,

    // Heap-allocated per-request buffers (allocated on first recv, freed after send).
    // Idle connections hold just an fd — no buffer memory.
    read_buf: ?[]u8 = null,
    resp_buf: ?[]u8 = null,

    read_pos: u32 = 0,
    header_parsed: bool = false,

    // Parsed frame header
    msg_type: u8 = 0,
    req_id: u32 = 0,
    payload_len: u32 = 0,

    resp_len: u32 = 0,

    /// Release buffers back to allocator and transition to idle.
    fn releaseBuffers(self: *ConnState, alloc: std.mem.Allocator) void {
        if (self.read_buf) |rb| alloc.free(rb);
        if (self.resp_buf) |wb| alloc.free(wb);
        self.read_buf = null;
        self.resp_buf = null;
        self.read_pos = 0;
        self.header_parsed = false;
        self.payload_len = 0;
        self.resp_len = 0;
        self.phase = .idle;
    }
};

// ============================================================================
// Work queue (SPMC: event loop pushes, workers pop)
// ============================================================================

const WorkItem = struct { conn_id: u16 };

const WorkQueue = struct {
    buf: [WORK_QUEUE_CAP]WorkItem = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    mu: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    closed: bool = false,

    fn push(self: *WorkQueue, item: WorkItem) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.count >= WORK_QUEUE_CAP or self.closed) return;
        self.buf[self.tail] = item;
        self.tail = (self.tail + 1) % WORK_QUEUE_CAP;
        self.count += 1;
        self.not_empty.signal();
    }

    fn pop(self: *WorkQueue) ?WorkItem {
        self.mu.lock();
        defer self.mu.unlock();
        while (self.count == 0 and !self.closed) {
            self.not_empty.timedWait(&self.mu, 100_000_000) catch continue;
        }
        if (self.count == 0) return null;
        const item = self.buf[self.head];
        self.head = (self.head + 1) % WORK_QUEUE_CAP;
        self.count -= 1;
        return item;
    }

    fn close(self: *WorkQueue) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.closed = true;
        self.not_empty.broadcast();
    }
};

// ============================================================================
// IoUringRpcServer
// ============================================================================

pub const IoUringRpcServer = struct {
    store: *store_mod.Store,
    allocator: std.mem.Allocator,
    config: rpc.RpcConfig,

    ring: IoUring = undefined,
    ring_mu: std.Thread.Mutex = .{},

    listener: ?net.Server = null,
    listen_fd: posix.fd_t = -1,

    conns: []ConnState = &.{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    event_thread: ?std.Thread = null,

    workers: [MAX_WORKERS]?std.Thread = [_]?std.Thread{null} ** MAX_WORKERS,
    worker_count: u8 = DEFAULT_WORKERS,
    work_queue: WorkQueue = .{},

    pub fn create(
        alloc: std.mem.Allocator,
        store: *store_mod.Store,
        config: rpc.RpcConfig,
    ) !*IoUringRpcServer {
        const self = try alloc.create(IoUringRpcServer);
        self.* = .{
            .store = store,
            .allocator = alloc,
            .config = config,
        };
        // Heap-allocate connection slot metadata (~40 bytes each; buffers allocated on accept).
        const conns = try alloc.alloc(ConnState, MAX_CONNS);
        for (conns) |*conn| {
            conn.* = .{};
        }
        self.conns = conns;
        return self;
    }

    pub fn start(self: *IoUringRpcServer) !void {
        self.ring = try IoUring.init(RING_ENTRIES, 0);
        errdefer self.ring.deinit();

        // Create listening socket via std.net (handles SO_REUSEADDR, bind, listen).
        const addr = try net.Address.parseIp(self.config.bind_address, self.config.port);
        self.listener = try addr.listen(.{ .reuse_address = true });
        self.listen_fd = self.listener.?.stream.handle;

        self.running.store(true, .monotonic);

        // Start worker threads.
        for (0..self.worker_count) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, workerLoop, .{self});
        }

        // Start event loop.
        self.event_thread = try std.Thread.spawn(.{}, eventLoop, .{self});
    }

    pub fn stop(self: *IoUringRpcServer) void {
        self.running.store(false, .monotonic);
        self.work_queue.close();

        // Wake event loop with a NOP CQE.
        {
            self.ring_mu.lock();
            defer self.ring_mu.unlock();
            _ = self.ring.nop(0) catch {};
            _ = self.ring.submit() catch {};
        }

        // Join event loop.
        if (self.event_thread) |t| {
            t.join();
            self.event_thread = null;
        }

        // Close listener.
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
        self.listen_fd = -1;

        // Join workers.
        for (&self.workers) |*w| {
            if (w.*) |t| {
                t.join();
                w.* = null;
            }
        }

        // Close active connections and free buffers.
        for (self.conns) |*conn| {
            if (conn.fd >= 0) {
                posix.close(conn.fd);
                conn.fd = -1;
            }
            if (conn.read_buf) |rb| self.allocator.free(rb);
            if (conn.resp_buf) |wb| self.allocator.free(wb);
            conn.read_buf = null;
            conn.resp_buf = null;
            conn.phase = .free;
        }

        self.ring.deinit();
    }

    // ========================================================================
    // Event loop
    // ========================================================================

    fn eventLoop(self: *IoUringRpcServer) void {
        // Submit initial accept SQE.
        {
            self.ring_mu.lock();
            defer self.ring_mu.unlock();
            _ = self.ring.accept(ud(OP_ACCEPT, 0), self.listen_fd, null, null, 0) catch return;
            _ = self.ring.submit() catch return;
        }

        var cqes: [64]linux.io_uring_cqe = undefined;

        while (self.running.load(.monotonic)) {
            // copy_cqes only touches CQ — no ring_mu needed.
            const n = self.ring.copy_cqes(&cqes, 1) catch |err| {
                if (err == error.SignalInterrupt) continue;
                break;
            };

            var need_submit = false;
            for (cqes[0..n]) |cqe| {
                if (cqe.user_data == 0) continue; // NOP (shutdown)
                if (self.handleCqe(cqe)) need_submit = true;
            }

            if (need_submit) {
                self.ring_mu.lock();
                defer self.ring_mu.unlock();
                _ = self.ring.submit() catch {};
            }
        }
    }

    fn handleCqe(self: *IoUringRpcServer, cqe: linux.io_uring_cqe) bool {
        return switch (udOp(cqe.user_data)) {
            OP_ACCEPT => self.onAccept(cqe.res),
            OP_RECV => self.onRecv(udConn(cqe.user_data), cqe.res),
            else => false,
        };
    }

    // ========================================================================
    // Accept
    // ========================================================================

    fn onAccept(self: *IoUringRpcServer, res: i32) bool {
        // Always re-submit accept for the next connection.
        {
            self.ring_mu.lock();
            defer self.ring_mu.unlock();
            _ = self.ring.accept(ud(OP_ACCEPT, 0), self.listen_fd, null, null, 0) catch {};
        }

        if (res < 0) return true;

        const new_fd: posix.fd_t = @intCast(res);

        // TCP_NODELAY.
        posix.setsockopt(new_fd, posix.IPPROTO.TCP, 1, &std.mem.toBytes(@as(c_int, 1))) catch {};

        const conn_id = self.allocConn(new_fd) orelse {
            posix.close(new_fd);
            return true;
        };

        self.queueRecv(conn_id);
        return true;
    }

    fn allocConn(self: *IoUringRpcServer, fd: posix.fd_t) ?u16 {
        for (0..self.conns.len) |i| {
            if (self.conns[i].phase == .free) {
                self.conns[i] = .{
                    .fd = fd,
                    .phase = .idle,
                };
                return @intCast(i);
            }
        }
        return null;
    }

    // ========================================================================
    // Recv
    // ========================================================================

    fn queueRecv(self: *IoUringRpcServer, conn_id: u16) void {
        self.ring_mu.lock();
        defer self.ring_mu.unlock();
        self.queueRecvLocked(conn_id);
    }

    /// Queue a recv SQE. Caller must hold ring_mu.
    /// Lazily allocates read/resp buffers on first recv for this request cycle.
    fn queueRecvLocked(self: *IoUringRpcServer, conn_id: u16) void {
        const conn = &self.conns[conn_id];
        // Lazy buffer allocation — idle connections hold no buffers.
        if (conn.read_buf == null) {
            conn.read_buf = self.allocator.alloc(u8, CONN_BUF_SIZE) catch {
                self.closeConnLocked(conn_id);
                return;
            };
            conn.resp_buf = self.allocator.alloc(u8, CONN_BUF_SIZE) catch {
                self.allocator.free(conn.read_buf.?);
                conn.read_buf = null;
                self.closeConnLocked(conn_id);
                return;
            };
        }
        conn.phase = .recv;
        _ = self.ring.recv(
            ud(OP_RECV, conn_id),
            conn.fd,
            .{ .buffer = conn.read_buf.?[conn.read_pos..] },
            0,
        ) catch {};
    }

    fn onRecv(self: *IoUringRpcServer, conn_id: u16, res: i32) bool {
        if (res <= 0) {
            self.closeConn(conn_id);
            return false;
        }

        const conn = &self.conns[conn_id];
        conn.read_pos += @as(u32, @intCast(res));

        // Need at least the frame header (9 bytes).
        if (conn.read_pos < HDR) {
            self.queueRecv(conn_id);
            return true;
        }

        // Parse header once.
        if (!conn.header_parsed) {
            const rb = conn.read_buf.?;
            conn.msg_type = rb[0];
            conn.req_id = std.mem.readInt(u32, rb[1..5], .little);
            conn.payload_len = std.mem.readInt(u32, rb[5..9], .little);
            conn.header_parsed = true;

            if (conn.payload_len > CONN_BUF_SIZE - HDR) {
                self.closeConn(conn_id);
                return false;
            }
        }

        // Need header + full payload.
        const needed: u32 = @intCast(HDR + conn.payload_len);
        if (conn.read_pos < needed) {
            self.queueRecv(conn_id);
            return true;
        }

        // Complete frame — dispatch to worker.
        conn.phase = .processing;
        self.work_queue.push(.{ .conn_id = conn_id });
        return false;
    }

    // ========================================================================
    // Send (blocking from worker threads — avoids ring_mu contention)
    // ========================================================================

    /// Blocking send from worker thread. Small responses with TCP_NODELAY
    /// complete in a single writev call. Falls back to loop for partial sends.
    fn blockingSend(conn: *ConnState) bool {
        var sent: usize = 0;
        const total = conn.resp_len;
        while (sent < total) {
            const n = std.posix.write(conn.fd, conn.resp_buf.?[sent..total]) catch return false;
            if (n == 0) return false;
            sent += n;
        }
        return true;
    }

    // ========================================================================
    // Connection management
    // ========================================================================

    fn closeConnInner(self: *IoUringRpcServer, conn_id: u16) void {
        const conn = &self.conns[conn_id];
        if (conn.fd >= 0) {
            posix.close(conn.fd);
            conn.fd = -1;
        }
        // Free per-connection buffers.
        if (conn.read_buf) |rb| self.allocator.free(rb);
        if (conn.resp_buf) |wb| self.allocator.free(wb);
        conn.read_buf = null;
        conn.resp_buf = null;
        conn.phase = .free;
    }

    fn closeConn(self: *IoUringRpcServer, conn_id: u16) void {
        self.closeConnInner(conn_id);
    }

    /// Close a connection when ring_mu is already held.
    fn closeConnLocked(self: *IoUringRpcServer, conn_id: u16) void {
        self.closeConnInner(conn_id);
    }

    // ========================================================================
    // Worker pool
    // ========================================================================

    fn workerLoop(self: *IoUringRpcServer) void {
        while (true) {
            const item = self.work_queue.pop() orelse break;
            self.processRequest(item.conn_id);
        }
    }

    fn processRequest(self: *IoUringRpcServer, conn_id: u16) void {
        const conn = &self.conns[conn_id];
        const rb = conn.read_buf.?;
        const wb = conn.resp_buf.?;
        const pl_start: usize = HDR;
        const pl_end: usize = HDR + conn.payload_len;
        const payload = rb[pl_start..pl_end];

        var resp_type: u8 = rpc.MSG_ERROR;
        var resp_payload_len: u32 = 0;

        switch (conn.msg_type) {
            rpc.MSG_ENQUEUE_BATCH => {
                const resp = self.doEnqueue(payload, wb[HDR..]) catch {
                    self.setError(conn, "enqueue failed");
                    self.sendFromWorker(conn_id);
                    return;
                };
                resp_type = rpc.MSG_ENQUEUE_BATCH_RESP;
                resp_payload_len = @intCast(resp.len);
            },
            rpc.MSG_FETCH_BATCH => {
                const resp = self.doFetch(payload, wb[HDR..]) catch {
                    self.setError(conn, "fetch failed");
                    self.sendFromWorker(conn_id);
                    return;
                };
                resp_type = rpc.MSG_FETCH_BATCH_RESP;
                resp_payload_len = @intCast(resp.len);
            },
            rpc.MSG_ACK_BATCH => {
                const resp = self.doAck(payload, wb[HDR..]) catch {
                    self.setError(conn, "ack failed");
                    self.sendFromWorker(conn_id);
                    return;
                };
                resp_type = rpc.MSG_ACK_BATCH_RESP;
                resp_payload_len = @intCast(resp.len);
            },
            rpc.MSG_FETCH_ACK_BATCH => {
                const resp = self.doFetchAck(payload, wb[HDR..]) catch {
                    self.setError(conn, "fetch_ack failed");
                    self.sendFromWorker(conn_id);
                    return;
                };
                resp_type = rpc.MSG_FETCH_ACK_BATCH_RESP;
                resp_payload_len = @intCast(resp.len);
            },
            rpc.MSG_PING => {
                resp_type = rpc.MSG_PONG;
            },
            else => {
                self.setError(conn, "unknown msg type");
                self.sendFromWorker(conn_id);
                return;
            },
        }

        // Write frame header.
        wb[0] = resp_type;
        std.mem.writeInt(u32, wb[1..5], conn.req_id, .little);
        std.mem.writeInt(u32, wb[5..9], resp_payload_len, .little);
        conn.resp_len = @intCast(HDR + resp_payload_len);

        self.sendFromWorker(conn_id);
    }

    fn setError(self: *IoUringRpcServer, conn: *ConnState, msg: []const u8) void {
        _ = self;
        const wb = conn.resp_buf.?;
        wb[0] = rpc.MSG_ERROR;
        std.mem.writeInt(u32, wb[1..5], conn.req_id, .little);
        std.mem.writeInt(u32, wb[5..9], @intCast(msg.len), .little);
        @memcpy(wb[HDR .. HDR + msg.len], msg);
        conn.resp_len = @intCast(HDR + msg.len);
    }

    /// Send response from worker thread using blocking write, then re-arm recv via io_uring.
    fn sendFromWorker(self: *IoUringRpcServer, conn_id: u16) void {
        const conn = &self.conns[conn_id];
        if (!blockingSend(conn)) {
            self.closeConn(conn_id);
            return;
        }
        // Release buffers — idle connections hold no memory.
        // queueRecvLocked will re-allocate when next request arrives.
        conn.releaseBuffers(self.allocator);
        {
            self.ring_mu.lock();
            defer self.ring_mu.unlock();
            self.queueRecvLocked(conn_id);
            _ = self.ring.submit() catch {};
        }
    }

    // ========================================================================
    // Request handlers (same logic as rpc.zig, buffer-to-buffer)
    // ========================================================================

    fn doEnqueue(self: *IoUringRpcServer, payload: []const u8, resp_buf: []u8) ![]const u8 {
        var reader = BufReader{ .data = payload };

        const count = try reader.readU16();
        const now_ns = try reader.readU64();

        var stack_jobs: [128]ops_mod.EnqueueJob = undefined;
        var id_bufs: [128][64]u8 = undefined;
        var queue_bufs: [128][64]u8 = undefined;
        const n = @min(count, 128);

        for (0..n) |i| {
            const queue = try reader.readLenPrefixed();
            const job_id = try reader.readLenPrefixed();
            const priority = try reader.readU8();
            const max_retries = try reader.readU16();

            @memcpy(id_bufs[i][0..job_id.len], job_id);
            @memcpy(queue_bufs[i][0..queue.len], queue);

            stack_jobs[i] = .{
                .job_id = id_bufs[i][0..job_id.len],
                .queue = queue_bufs[i][0..queue.len],
                .priority = priority,
                .max_retries = max_retries,
                .created_at_ns = now_ns,
            };
        }

        const result = self.store.enqueueBatch(stack_jobs[0..n]);

        var writer = BufWriter{ .buf = resp_buf };
        writer.writeU16(@intCast(n));
        writer.writeU8(if (result.err != null) 1 else 0);
        return writer.slice();
    }

    fn doFetch(self: *IoUringRpcServer, payload: []const u8, resp_buf: []u8) ![]const u8 {
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

        const result = self.store.fetch(queue_slices[0..qn], worker_id, count, lease_ms, now_ns);

        var writer = BufWriter{ .buf = resp_buf };
        writer.writeU16(@intCast(result.affected));
        for (0..result.affected) |i| {
            const f = &result.fetched[i];
            writer.writeLenPrefixed(f.id_buf[0..f.id_len]);
            writer.writeLenPrefixed(f.queue_buf[0..f.queue_len]);
        }
        return writer.slice();
    }

    fn doAck(self: *IoUringRpcServer, payload: []const u8, resp_buf: []u8) ![]const u8 {
        var reader = BufReader{ .data = payload };

        const now_ns = try reader.readU64();
        const count = try reader.readU16();

        var stack_acks: [128]ops_mod.AckJob = undefined;
        var id_bufs: [128][64]u8 = undefined;
        var queue_bufs: [128][64]u8 = undefined;
        const n = @min(count, 128);

        for (0..n) |i| {
            const job_id = try reader.readLenPrefixed();
            const queue = try reader.readLenPrefixed();
            @memcpy(id_bufs[i][0..job_id.len], job_id);
            @memcpy(queue_bufs[i][0..queue.len], queue);
            stack_acks[i] = .{
                .job_id = id_bufs[i][0..job_id.len],
                .queue = queue_bufs[i][0..queue.len],
            };
        }

        const data = ops_mod.OpData{
            .ack = .{
                .acks = stack_acks[0..n],
                .now_ns = now_ns,
            },
        };
        const result = self.store.engine.submit(.ack, &data);

        var writer = BufWriter{ .buf = resp_buf };
        writer.writeU16(@intCast(result.affected));
        writer.writeU8(if (result.err != null) 1 else 0);
        return writer.slice();
    }

    fn doFetchAck(self: *IoUringRpcServer, payload: []const u8, resp_buf: []u8) ![]const u8 {
        var reader = BufReader{ .data = payload };

        const now_ns = try reader.readU64();
        const fetch_count = try reader.readU16();
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

        // Ack phase
        const ack_count = try reader.readU16();
        var stack_acks: [128]ops_mod.AckJob = undefined;
        var ack_id_bufs: [128][64]u8 = undefined;
        var ack_queue_bufs: [128][64]u8 = undefined;
        const ack_n = @min(ack_count, 128);

        for (0..ack_n) |i| {
            const job_id = try reader.readLenPrefixed();
            const queue = try reader.readLenPrefixed();
            @memcpy(ack_id_bufs[i][0..job_id.len], job_id);
            @memcpy(ack_queue_bufs[i][0..queue.len], queue);
            stack_acks[i] = .{
                .job_id = ack_id_bufs[i][0..job_id.len],
                .queue = ack_queue_bufs[i][0..queue.len],
            };
        }

        if (ack_n > 0) {
            const ack_data = ops_mod.OpData{
                .ack = .{
                    .acks = stack_acks[0..ack_n],
                    .now_ns = now_ns,
                },
            };
            _ = self.store.engine.submit(.ack, &ack_data);
        }

        // Fetch phase
        const fetch_result = self.store.fetch(queue_slices[0..qn], worker_id, fetch_count, lease_ms, now_ns);

        var writer = BufWriter{ .buf = resp_buf };
        writer.writeU16(@intCast(fetch_result.affected));
        for (0..fetch_result.affected) |i| {
            const f = &fetch_result.fetched[i];
            writer.writeLenPrefixed(f.id_buf[0..f.id_len]);
            writer.writeLenPrefixed(f.queue_buf[0..f.queue_len]);
        }
        return writer.slice();
    }
};
