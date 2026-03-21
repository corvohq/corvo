//! io_uring-based RPC Server — high-throughput async I/O for Linux.
//!
//! Architecture:
//!   Event loop thread: io_uring for accept + recv (CQE processing)
//!   Worker pool (8 threads): decode -> pipeline.submit (blocking) -> encode -> blocking send
//!   Hybrid I/O: io_uring for recv (async), blocking write() for send (avoids ring_mu contention)
//!   Synchronization: ring_mu protects SQE submission; copy_cqes is lock-free (CQ only)
//!
//! Buffer strategy:
//!   Recv: io_uring provided buffer ring (BufferGroup). Kernel picks from a pre-registered
//!   pool of buffers, avoiding per-recv address validation/page-table walks. Data is copied
//!   into connection-owned buffers (from BufferPool) on CQE completion, then the provided
//!   buffer is returned to the kernel immediately.
//!   Read/Resp buffers: BufferPool (lock-free MPMC stack) of pre-allocated 64KB buffers.
//!   Connections borrow/return buffers instead of malloc/free per request.
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
const pipeline = @import("pipeline.zig");

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

/// Number of buffers in the io_uring provided buffer ring for recv.
/// Must be a power of two. 512 buffers * 64KB = 32MB kernel-registered recv pool.
/// Only actively-receiving connections consume a buffer; it is returned on CQE completion.
const RECV_POOL_COUNT: u16 = 512;

/// Buffer group ID for the recv provided buffer ring.
const RECV_BUF_GROUP_ID: u16 = 0;

/// Number of pre-allocated buffers in the read/response buffer pool.
/// Sized for 2x MAX_WORKERS (read + resp per concurrent request) plus headroom.
const BUF_POOL_SIZE: usize = 256;

// ============================================================================
// user_data encoding: [op:8][conn_id:16]
// ============================================================================

const OP_ACCEPT: u64 = 1 << 16;
const OP_RECV: u64 = 2 << 16;
const OP_RECV_CONT: u64 = 3 << 16; // continuation recv (partial frame, no provided buffer)
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
// BufferPool — MPMC stack of pre-allocated 64KB buffers
// ============================================================================

const BufferPool = struct {
    /// Stack of available buffer pointers. Index `top-1` is the next to pop.
    stack: []?[*]u8,
    top: usize,
    mu: std.Thread.Mutex,
    allocator: std.mem.Allocator,
    buf_size: usize,
    capacity: usize,

    fn init(allocator: std.mem.Allocator, count: usize, buf_size: usize) !BufferPool {
        const stack = try allocator.alloc(?[*]u8, count);
        for (0..count) |i| {
            const buf = try allocator.alloc(u8, buf_size);
            stack[i] = buf.ptr;
        }
        return .{
            .stack = stack,
            .top = count,
            .mu = .{},
            .allocator = allocator,
            .buf_size = buf_size,
            .capacity = count,
        };
    }

    fn deinit(self: *BufferPool) void {
        // Free all buffers still in the pool.
        for (0..self.top) |i| {
            if (self.stack[i]) |ptr| {
                self.allocator.free(ptr[0..self.buf_size]);
            }
        }
        self.allocator.free(self.stack);
    }

    /// Borrow a buffer from the pool. Returns null if pool is exhausted.
    fn acquire(self: *BufferPool) ?[]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.top == 0) return null;
        self.top -= 1;
        const ptr = self.stack[self.top].?;
        self.stack[self.top] = null;
        return ptr[0..self.buf_size];
    }

    /// Return a buffer to the pool.
    fn release(self: *BufferPool, buf: []u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.top >= self.capacity) {
            // Pool is full (should not happen in correct usage). Free the buffer.
            self.allocator.free(buf);
            return;
        }
        self.stack[self.top] = buf.ptr;
        self.top += 1;
    }
};

// ============================================================================
// Connection state
// ============================================================================

const ConnPhase = enum { free, idle, recv, processing };

const ConnState = struct {
    fd: posix.fd_t = -1,
    phase: ConnPhase = .free,

    // Buffers borrowed from BufferPool (returned after send, or on close).
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

    /// Release buffers back to pool and transition to idle.
    fn releaseBuffers(self: *ConnState, pool: *BufferPool) void {
        if (self.read_buf) |rb| pool.release(rb);
        if (self.resp_buf) |wb| pool.release(wb);
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

    /// io_uring provided buffer ring for recv operations.
    recv_buf_group: ?IoUring.BufferGroup = null,
    /// Pre-allocated buffer pool for connection read/response buffers.
    buf_pool: ?BufferPool = null,

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

        // Initialize io_uring provided buffer ring for recv.
        // Kernel picks from this pool for each recv SQE, avoiding per-recv
        // address validation and page-table walks.
        self.recv_buf_group = try IoUring.BufferGroup.init(
            &self.ring,
            self.allocator,
            RECV_BUF_GROUP_ID,
            CONN_BUF_SIZE,
            RECV_POOL_COUNT,
        );

        // Initialize pre-allocated buffer pool for read/response buffers.
        self.buf_pool = try BufferPool.init(self.allocator, BUF_POOL_SIZE, CONN_BUF_SIZE);

        // Create listening socket via std.net (handles SO_REUSEADDR, bind, listen).
        const addr = try net.Address.parseIp(self.config.bind_address, self.config.port);
        self.listener = try addr.listen(.{ .reuse_address = true });
        self.listen_fd = self.listener.?.stream.handle;

        self.running.store(true, .monotonic);

        // Start worker threads (pinned to cores 2+i, leaving 0-1 for pipeline).
        for (0..self.worker_count) |i| {
            self.workers[i] = try std.Thread.spawn(.{}, workerLoop, .{ self, @as(u8, @intCast(i)) });
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

        // Close active connections and return buffers to pool.
        for (self.conns) |*conn| {
            if (conn.fd >= 0) {
                posix.close(conn.fd);
                conn.fd = -1;
            }
            if (self.buf_pool) |*pool| {
                if (conn.read_buf) |rb| pool.release(rb);
                if (conn.resp_buf) |wb| pool.release(wb);
            }
            conn.read_buf = null;
            conn.resp_buf = null;
            conn.phase = .free;
        }

        // Tear down provided buffer ring (unregisters from kernel, frees backing memory).
        if (self.recv_buf_group) |*bg| {
            bg.deinit(self.allocator);
            self.recv_buf_group = null;
        }

        // Tear down buffer pool (frees all pre-allocated buffers).
        if (self.buf_pool) |*pool| {
            pool.deinit();
            self.buf_pool = null;
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
            OP_RECV => self.onRecvProvided(udConn(cqe.user_data), cqe),
            OP_RECV_CONT => self.onRecvContinuation(udConn(cqe.user_data), cqe.res),
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

        self.queueRecvProvided(conn_id);
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
    // Recv — provided buffer ring (initial recv for each request)
    // ========================================================================

    /// Queue a recv using the provided buffer ring. Kernel selects a buffer.
    /// Used for the initial recv of each request cycle.
    fn queueRecvProvided(self: *IoUringRpcServer, conn_id: u16) void {
        self.ring_mu.lock();
        defer self.ring_mu.unlock();
        self.queueRecvProvidedLocked(conn_id);
    }

    /// Queue a recv using the provided buffer ring. Caller must hold ring_mu.
    fn queueRecvProvidedLocked(self: *IoUringRpcServer, conn_id: u16) void {
        const conn = &self.conns[conn_id];
        conn.phase = .recv;

        // Use BufferGroup.recv which sets IOSQE_BUFFER_SELECT.
        // The kernel picks a buffer from the pre-registered pool.
        _ = self.recv_buf_group.?.recv(ud(OP_RECV, conn_id), conn.fd, 0) catch {
            self.closeConnLocked(conn_id);
            return;
        };
    }

    /// Handle CQE for a provided-buffer recv. Copies data from the kernel-selected
    /// buffer into a connection-owned buffer (from the pool), then returns the
    /// provided buffer to the kernel immediately.
    fn onRecvProvided(self: *IoUringRpcServer, conn_id: u16, cqe: linux.io_uring_cqe) bool {
        if (cqe.res <= 0) {
            // Connection closed or error. Return provided buffer if kernel selected one.
            // put() calls buffer_id() which checks IORING_CQE_F_BUFFER flag —
            // returns error.NoBufferSelected (caught here) when no buffer was used (e.g. ENOBUFS).
            self.recv_buf_group.?.put(cqe) catch {};
            self.closeConn(conn_id);
            return false;
        }

        const conn = &self.conns[conn_id];
        const bytes_read: u32 = @intCast(cqe.res);

        // Get the provided buffer the kernel wrote into.
        const recv_data = self.recv_buf_group.?.get(cqe) catch {
            // No buffer selected (should not happen if res > 0).
            self.closeConn(conn_id);
            return false;
        };

        // Acquire a read buffer and response buffer from the pool.
        const pool = &self.buf_pool.?;
        const read_buf = pool.acquire() orelse {
            // Pool exhausted — return provided buffer and close connection.
            self.recv_buf_group.?.put(cqe) catch {};
            self.closeConn(conn_id);
            return false;
        };
        const resp_buf = pool.acquire() orelse {
            pool.release(read_buf);
            self.recv_buf_group.?.put(cqe) catch {};
            self.closeConn(conn_id);
            return false;
        };

        // Copy recv data into connection's read buffer.
        @memcpy(read_buf[0..bytes_read], recv_data[0..bytes_read]);

        // Return the provided buffer to the kernel immediately.
        self.recv_buf_group.?.put(cqe) catch {};

        // Assign pool buffers to connection.
        conn.read_buf = read_buf;
        conn.resp_buf = resp_buf;
        conn.read_pos = bytes_read;

        // Process the received data (same logic as before).
        return self.processRecvData(conn_id);
    }

    // ========================================================================
    // Recv — continuation (partial frame, using connection's own buffer)
    // ========================================================================

    /// Queue a continuation recv directly into the connection's own read buffer.
    /// Used when a partial frame needs more data. No provided buffer involved.
    fn queueRecvContinuation(self: *IoUringRpcServer, conn_id: u16) void {
        self.ring_mu.lock();
        defer self.ring_mu.unlock();
        self.queueRecvContinuationLocked(conn_id);
    }

    /// Queue a continuation recv. Caller must hold ring_mu.
    fn queueRecvContinuationLocked(self: *IoUringRpcServer, conn_id: u16) void {
        const conn = &self.conns[conn_id];
        conn.phase = .recv;
        _ = self.ring.recv(
            ud(OP_RECV_CONT, conn_id),
            conn.fd,
            .{ .buffer = conn.read_buf.?[conn.read_pos..] },
            0,
        ) catch {
            self.closeConnLocked(conn_id);
            return;
        };
    }

    /// Handle CQE for a continuation recv (direct buffer, no provided buffer involved).
    fn onRecvContinuation(self: *IoUringRpcServer, conn_id: u16, res: i32) bool {
        if (res <= 0) {
            self.closeConn(conn_id);
            return false;
        }

        const conn = &self.conns[conn_id];
        conn.read_pos += @as(u32, @intCast(res));

        return self.processRecvData(conn_id);
    }

    // ========================================================================
    // Shared recv data processing
    // ========================================================================

    /// Process accumulated recv data. Returns true if new SQEs were queued.
    fn processRecvData(self: *IoUringRpcServer, conn_id: u16) bool {
        const conn = &self.conns[conn_id];

        // Need at least the frame header (9 bytes).
        if (conn.read_pos < HDR) {
            self.queueRecvContinuation(conn_id);
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
            self.queueRecvContinuation(conn_id);
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
        // Return per-connection buffers to pool.
        if (self.buf_pool) |*pool| {
            if (conn.read_buf) |rb| pool.release(rb);
            if (conn.resp_buf) |wb| pool.release(wb);
        }
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

    fn workerLoop(self: *IoUringRpcServer, worker_idx: u8) void {
        pipeline.pinCurrentThread(@as(usize, worker_idx) + 2); // Cores 2+ for workers.

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
            rpc.MSG_FAIL_BATCH => {
                const resp = self.doFail(payload, wb[HDR..]) catch {
                    self.setError(conn, "fail failed");
                    self.sendFromWorker(conn_id);
                    return;
                };
                resp_type = rpc.MSG_FAIL_BATCH_RESP;
                resp_payload_len = @intCast(resp.len);
            },
            rpc.MSG_HEARTBEAT => {
                const resp = self.doHeartbeat(payload, wb[HDR..]) catch {
                    self.setError(conn, "heartbeat failed");
                    self.sendFromWorker(conn_id);
                    return;
                };
                resp_type = rpc.MSG_HEARTBEAT_RESP;
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
        // Release buffers back to pool — idle connections hold no memory.
        // queueRecvProvidedLocked will use the provided buffer ring for the next recv.
        conn.releaseBuffers(&self.buf_pool.?);
        {
            self.ring_mu.lock();
            defer self.ring_mu.unlock();
            self.queueRecvProvidedLocked(conn_id);
            _ = self.ring.submit() catch {};
        }
    }

    // ========================================================================
    // Request handlers — delegate to shared functions in rpc.zig
    // ========================================================================

    fn doEnqueue(self: *IoUringRpcServer, payload: []const u8, resp_buf: []u8) ![]const u8 {
        return rpc.processEnqueueBatch(self.store, payload, resp_buf);
    }

    fn doFetch(self: *IoUringRpcServer, payload: []const u8, resp_buf: []u8) ![]const u8 {
        return rpc.processFetchBatch(self.store, self.allocator, payload, resp_buf);
    }

    fn doAck(self: *IoUringRpcServer, payload: []const u8, resp_buf: []u8) ![]const u8 {
        return rpc.processAckBatch(self.store, payload, resp_buf);
    }

    fn doFail(self: *IoUringRpcServer, payload: []const u8, resp_buf: []u8) ![]const u8 {
        return rpc.processFailBatch(self.store, payload, resp_buf);
    }

    fn doHeartbeat(self: *IoUringRpcServer, payload: []const u8, resp_buf: []u8) ![]const u8 {
        return rpc.processHeartbeat(self.store, payload, resp_buf);
    }

};
