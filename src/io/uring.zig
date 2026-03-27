//! io_uring backend for Linux.
//!
//! Owns the io_uring instance, all connection state (pre-allocated flat array),
//! and all per-connection buffers. Provides accept/recv/send/close lifecycle.
//!
//! Does NOT know about the RPC protocol, pipeline, or business logic.
//! All buffers pre-allocated at init — zero allocations on the hot path.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const assert = @import("../assert.zig");
const io = @import("../io.zig");
const Completion = io.Completion;
const ConnState = io.ConnState;
const Config = io.Config;
const Allocator = std.mem.Allocator;

// ============================================================================
// user_data encoding: [op:8][conn_id:16] packed into u64
// ============================================================================

const OP_ACCEPT: u8 = 1;
const OP_RECV: u8 = 2;
const OP_SEND: u8 = 3;
const OP_CLOSE: u8 = 4;

fn encodeUserData(op: u8, conn_id: u16) u64 {
    return (@as(u64, op) << 16) | @as(u64, conn_id);
}

fn decodeOp(user_data: u64) u8 {
    return @intCast((user_data >> 16) & 0xFF);
}

fn decodeConnId(user_data: u64) u16 {
    return @intCast(user_data & 0xFFFF);
}

// ============================================================================
// UringBackend
// ============================================================================

pub const UringBackend = struct {
    ring: linux.IoUring,
    conns: []ConnState,
    max_conns: u16,
    listen_fd: posix.fd_t,
    buf_mem: []u8,

    // Free list for connection slots (stack, O(1) alloc/free)
    free_list: []u16,
    free_count: u16,

    // CQE batch buffer — avoids per-drain allocation
    cqe_buf: [256]linux.io_uring_cqe = undefined,

    /// Initialize the io_uring backend. Allocates all connection state and buffers.
    pub fn init(allocator: Allocator, config: Config) !UringBackend {
        const max: u16 = config.max_conns;
        assert.check(max > 0, "UringBackend.init: max_conns must be > 0", .{});

        var ring = try linux.IoUring.init(4096, 0);
        errdefer ring.deinit();

        const conns = try allocator.alloc(ConnState, max);
        errdefer allocator.free(conns);

        // Single contiguous block for all per-connection buffers
        const per_conn = config.recv_buf_size + config.send_buf_size;
        const total_buf = @as(usize, per_conn) * @as(usize, max);
        const buf_mem = try allocator.alloc(u8, total_buf);
        errdefer allocator.free(buf_mem);

        for (conns, 0..) |*c, i| {
            const base = i * per_conn;
            c.* = ConnState{
                .recv_buf = buf_mem[base..][0..config.recv_buf_size],
                .send_buf = buf_mem[base + config.recv_buf_size ..][0..config.send_buf_size],
            };
        }

        // Build free list (all slots free initially, stack order)
        const free_list = try allocator.alloc(u16, max);
        errdefer allocator.free(free_list);
        for (free_list, 0..) |*slot, i| {
            slot.* = @intCast(max - 1 - i);
        }

        return UringBackend{
            .ring = ring,
            .conns = conns,
            .max_conns = max,
            .listen_fd = config.listen_fd,
            .buf_mem = buf_mem,
            .free_list = free_list,
            .free_count = max,
        };
    }

    /// Tear down the backend. Closes all active connections and frees memory.
    pub fn deinit(self: *UringBackend, allocator: Allocator) void {
        for (self.conns) |*c| {
            if (c.phase != .free and c.fd >= 0) {
                posix.close(c.fd);
                c.fd = -1;
            }
        }
        self.ring.deinit();
        allocator.free(self.free_list);
        allocator.free(self.buf_mem);
        allocator.free(self.conns);
    }

    /// Block until at least one completion, then drain all available into out buffer.
    /// Returns number of completions. Blocks when idle (no busy-spin).
    /// Drain completions: submit any pending SQEs and wait for at least 1 CQE.
    /// Combines submit + wait into a single io_uring_enter syscall when possible.
    pub fn drain(self: *UringBackend, out: []Completion) u32 {
        assert.check(out.len > 0, "drain: output buffer must be non-empty", .{});

        // Peek for already-ready CQEs (no syscall).
        var cqe_count = self.ring.copy_cqes(&self.cqe_buf, 0) catch 0;
        if (cqe_count == 0) {
            // Submit pending SQEs and wait for at least 1 CQE — single syscall.
            _ = self.ring.submit_and_wait(1) catch |err| {
                switch (err) {
                    error.SignalInterrupt => return 0,
                    else => assert.fail("drain: submit_and_wait failed: {}", .{err}),
                }
            };
            cqe_count = self.ring.copy_cqes(&self.cqe_buf, 0) catch 0;
        }

        return self.processCqes(out, cqe_count);
    }

    /// Coalescing drain: like drain(), but after the first batch of CQEs,
    /// keeps collecting non-blocking until the output buffer is full or the
    /// clock exceeds deadline_ns. Used for sync replication batch accumulation.
    pub fn drainCoalescing(self: *UringBackend, out: []Completion, clock_fn: *const fn () i64, deadline_ns: u64) u32 {
        // First: blocking drain to get at least one CQE.
        var total = self.drain(out);
        if (total >= out.len) return total;

        // Then: keep peeking for more CQEs until deadline or buffer full.
        while (total < out.len) {
            const now: u64 = @intCast(clock_fn());
            if (now >= deadline_ns) break;

            _ = self.ring.submit() catch 0;
            const cqe_count = self.ring.copy_cqes(&self.cqe_buf, 0) catch 0;
            if (cqe_count == 0) continue;

            total += self.processCqes(out[total..], cqe_count);
        }
        return total;
    }

    /// Non-blocking drain: submit pending SQEs and return any ready CQEs.
    /// Returns 0 immediately if nothing is ready. Used during sync replication
    /// ack-wait so the pipeline tick loop doesn't block on io_uring while
    /// waiting for an atomic update from the cluster thread.
    pub fn drainNonBlocking(self: *UringBackend, out: []Completion) u32 {
        assert.check(out.len > 0, "drainNonBlocking: output buffer must be non-empty", .{});

        // Submit any pending SQEs without waiting.
        _ = self.ring.submit() catch 0;

        // Peek for ready CQEs (no syscall wait).
        const cqe_count = self.ring.copy_cqes(&self.cqe_buf, 0) catch 0;

        return self.processCqes(out, cqe_count);
    }

    /// Process CQEs from the cqe_buf into the output completion buffer.
    fn processCqes(self: *UringBackend, out: []Completion, cqe_count: u32) u32 {
        var out_count: u32 = 0;
        for (self.cqe_buf[0..cqe_count]) |cqe| {
            if (out_count >= out.len) break;

            const op = decodeOp(cqe.user_data);
            const conn_id = decodeConnId(cqe.user_data);

            switch (op) {
                OP_ACCEPT => {
                    if (cqe.res < 0) {
                        self.queueAccept();
                        continue;
                    }
                    const new_fd = cqe.res;
                    const slot = self.allocConn();
                    if (slot) |id| {
                        const c = &self.conns[id];
                        c.fd = new_fd;
                        c.phase = .recv_pending;

                        self.setTcpNodelay(new_fd);
                        self.queueRecvInternal(id);
                        self.queueAccept();

                        out[out_count] = .{ .conn_id = id, .event = .accept };
                        out_count += 1;
                    } else {
                        posix.close(@intCast(new_fd));
                        self.queueAccept();
                    }
                },
                OP_RECV => {
                    if (conn_id >= self.max_conns) continue;
                    const c = &self.conns[conn_id];
                    if (c.phase == .free) continue;

                    if (cqe.res <= 0) {
                        out[out_count] = .{ .conn_id = conn_id, .event = .closed };
                        out_count += 1;
                        self.closeConn(conn_id);
                    } else {
                        const n: u32 = @intCast(cqe.res);
                        c.recv_pos += n;
                        c.phase = .ready;
                        out[out_count] = .{ .conn_id = conn_id, .event = .recv };
                        out_count += 1;
                    }
                },
                OP_SEND => {
                    if (conn_id >= self.max_conns) continue;
                    const c = &self.conns[conn_id];
                    if (c.phase == .free) continue;

                    if (cqe.res < 0) {
                        out[out_count] = .{ .conn_id = conn_id, .event = .closed };
                        out_count += 1;
                        self.closeConn(conn_id);
                    } else {
                        const n: u32 = @intCast(cqe.res);
                        c.send_pos += n;
                        if (c.send_pos < c.send_len) {
                            self.queueSendInternal(conn_id);
                        } else {
                            c.send_pos = 0;
                            c.send_len = 0;
                            c.phase = .ready;
                            out[out_count] = .{ .conn_id = conn_id, .event = .send_done };
                            out_count += 1;
                        }
                    }
                },
                OP_CLOSE => {},
                else => {
                    assert.fail("drain: unknown op {d} in CQE user_data", .{op});
                },
            }
        }
        return out_count;
    }

    /// Queue a send. Data must already be in conn's send_buf[0..len].
    pub fn queueSend(self: *UringBackend, conn_id: u16, len: u32) void {
        assert.check(conn_id < self.max_conns, "queueSend: conn_id {d} >= max {d}", .{ conn_id, self.max_conns });
        const c = &self.conns[conn_id];
        assert.check(c.phase != .free, "queueSend: conn {d} is free", .{conn_id});
        assert.check(len > 0, "queueSend: zero-length send on conn {d}", .{conn_id});
        assert.check(len <= c.send_buf.len, "queueSend: len {d} > buf size {d}", .{ len, c.send_buf.len });

        c.send_pos = 0;
        c.send_len = len;
        c.phase = .send_pending;
        self.queueSendInternal(conn_id);
    }

    /// Queue a recv into conn's recv_buf.
    pub fn queueRecv(self: *UringBackend, conn_id: u16) void {
        assert.check(conn_id < self.max_conns, "queueRecv: conn_id {d} >= max {d}", .{ conn_id, self.max_conns });
        const c = &self.conns[conn_id];
        assert.check(c.phase != .free, "queueRecv: conn {d} is free", .{conn_id});

        c.phase = .recv_pending;
        self.queueRecvInternal(conn_id);
    }

    /// Queue accept on listen socket.
    pub fn queueAccept(self: *UringBackend) void {
        _ = self.ring.accept(
            encodeUserData(OP_ACCEPT, 0),
            self.listen_fd,
            null,
            null,
            0,
        ) catch return;
    }

    /// Close a connection and free its slot.
    pub fn queueClose(self: *UringBackend, conn_id: u16) void {
        assert.check(conn_id < self.max_conns, "queueClose: conn_id {d} >= max {d}", .{ conn_id, self.max_conns });
        self.closeConn(conn_id);
    }

    /// Flush all queued operations to kernel.
    pub fn submit(self: *UringBackend) void {
        _ = self.ring.submit() catch |err| {
            switch (err) {
                error.SignalInterrupt => {},
                error.SystemResources => {},
                else => assert.fail("submit: io_uring submit failed: {}", .{err}),
            }
        };
    }

    /// Access connection state by id.
    pub fn conn(self: *UringBackend, id: u16) *ConnState {
        assert.check(id < self.max_conns, "conn: id {d} >= max {d}", .{ id, self.max_conns });
        return &self.conns[id];
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    fn queueRecvInternal(self: *UringBackend, conn_id: u16) void {
        const c = &self.conns[conn_id];
        assert.check(c.fd >= 0, "queueRecvInternal: conn {d} has invalid fd", .{conn_id});
        assert.check(c.recv_pos < c.recv_buf.len, "queueRecvInternal: recv_buf full on conn {d}", .{conn_id});

        _ = self.ring.recv(
            encodeUserData(OP_RECV, conn_id),
            c.fd,
            .{ .buffer = c.recv_buf[c.recv_pos..] },
            0,
        ) catch {
            self.closeConn(conn_id);
            return;
        };
    }

    fn queueSendInternal(self: *UringBackend, conn_id: u16) void {
        const c = &self.conns[conn_id];
        assert.check(c.fd >= 0, "queueSendInternal: conn {d} has invalid fd", .{conn_id});
        assert.check(c.send_pos < c.send_len, "queueSendInternal: nothing to send on conn {d}", .{conn_id});

        _ = self.ring.send(
            encodeUserData(OP_SEND, conn_id),
            c.fd,
            c.send_buf[c.send_pos..c.send_len],
            0,
        ) catch {
            self.closeConn(conn_id);
            return;
        };
    }

    fn allocConn(self: *UringBackend) ?u16 {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        return self.free_list[self.free_count];
    }

    fn freeConn(self: *UringBackend, conn_id: u16) void {
        assert.check(self.free_count < self.max_conns, "freeConn: free_list overflow", .{});
        self.free_list[self.free_count] = conn_id;
        self.free_count += 1;
    }

    fn closeConn(self: *UringBackend, conn_id: u16) void {
        const c = &self.conns[conn_id];
        if (c.phase == .free) return;

        const fd = c.fd;
        c.reset();
        self.freeConn(conn_id);

        if (fd >= 0) {
            _ = self.ring.close(encodeUserData(OP_CLOSE, conn_id), fd) catch {
                posix.close(fd);
            };
        }
    }

    fn setTcpNodelay(self: *UringBackend, fd: i32) void {
        _ = self;
        const TCP_NODELAY = 1;
        posix.setsockopt(
            fd,
            posix.IPPROTO.TCP,
            TCP_NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch {};
    }
};

// ============================================================================
// Tests
// ============================================================================

test "user_data encoding round-trips" {
    const testing = std.testing;

    const ud1 = encodeUserData(OP_ACCEPT, 0);
    try testing.expectEqual(OP_ACCEPT, decodeOp(ud1));
    try testing.expectEqual(@as(u16, 0), decodeConnId(ud1));

    const ud2 = encodeUserData(OP_RECV, 42);
    try testing.expectEqual(OP_RECV, decodeOp(ud2));
    try testing.expectEqual(@as(u16, 42), decodeConnId(ud2));

    const ud3 = encodeUserData(OP_SEND, 4095);
    try testing.expectEqual(OP_SEND, decodeOp(ud3));
    try testing.expectEqual(@as(u16, 4095), decodeConnId(ud3));

    const ud4 = encodeUserData(OP_CLOSE, 0xFFFF);
    try testing.expectEqual(OP_CLOSE, decodeOp(ud4));
    try testing.expectEqual(@as(u16, 0xFFFF), decodeConnId(ud4));
}

test "ConnState reset clears subscription fields" {
    const testing = std.testing;
    var buf: [128]u8 = undefined;
    var sbuf: [128]u8 = undefined;
    var c = ConnState{
        .recv_buf = &buf,
        .send_buf = &sbuf,
        .fd = 5,
        .generation = 3,
        .phase = .ready,
        .recv_pos = 100,
        .send_pos = 50,
        .send_len = 200,
        .queue_count = 4,
        .worker_id_len = 10,
        .credits = 99,
        .waiting = true,
        .last_req_id = 42,
    };
    c.reset();
    try testing.expectEqual(@as(std.posix.fd_t, -1), c.fd);
    try testing.expectEqual(@as(u16, 4), c.generation);
    try testing.expectEqual(ConnState.Phase.free, c.phase);
    try testing.expectEqual(@as(u32, 0), c.recv_pos);
    try testing.expectEqual(@as(u32, 0), c.send_pos);
    try testing.expectEqual(@as(u32, 0), c.send_len);
    try testing.expectEqual(@as(u8, 0), c.queue_count);
    try testing.expectEqual(@as(u8, 0), c.worker_id_len);
    try testing.expectEqual(@as(u32, 0), c.credits);
    try testing.expectEqual(false, c.waiting);
    try testing.expectEqual(@as(u32, 0), c.last_req_id);
    try testing.expectEqual(@as(usize, 128), c.recv_buf.len);
    try testing.expectEqual(@as(usize, 128), c.send_buf.len);
}
