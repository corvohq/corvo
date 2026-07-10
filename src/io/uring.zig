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
// user_data encoding: [generation:16][op:8][conn_id:16] packed into u64
//
// The generation guards against a stale CQE landing on a reused slot. When a
// connection closes, ConnState.reset() bumps its generation and the LIFO free
// list can hand the slot to a brand-new connection on the very next accept.
// Recv/send/connect SQEs submitted for the old connection may still be in
// flight; their CQEs carry the generation captured at submission time. On
// completion we drop any CQE whose generation no longer matches the slot's
// current generation — otherwise a late recv/send for the old connection would
// be applied to the new one (cross-connection frame injection / wrong close).
// ============================================================================

const OP_ACCEPT: u8 = 1;
const OP_RECV: u8 = 2;
const OP_SEND: u8 = 3;
const OP_CLOSE: u8 = 4;
const OP_CONNECT: u8 = 5;

fn encodeUserData(op: u8, conn_id: u16, generation: u16) u64 {
    return (@as(u64, generation) << 24) | (@as(u64, op) << 16) | @as(u64, conn_id);
}

fn decodeOp(user_data: u64) u8 {
    return @intCast((user_data >> 16) & 0xFF);
}

fn decodeConnId(user_data: u64) u16 {
    return @intCast(user_data & 0xFFFF);
}

fn decodeGen(user_data: u64) u16 {
    return @intCast((user_data >> 24) & 0xFFFF);
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
            const gen = decodeGen(cqe.user_data);

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
                    // Drop a stale recv CQE for a slot that has since been
                    // reused by a different connection (see encodeUserData).
                    if (c.generation != gen) continue;

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
                    // Drop a stale send CQE for a since-reused slot.
                    if (c.generation != gen) continue;

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
                OP_CONNECT => {
                    if (conn_id >= self.max_conns) continue;
                    const c = &self.conns[conn_id];
                    if (c.phase == .free) continue;
                    // Drop a stale connect CQE for a since-reused slot.
                    if (c.generation != gen) continue;

                    if (cqe.res < 0) {
                        out[out_count] = .{ .conn_id = conn_id, .event = .closed };
                        out_count += 1;
                        self.closeConn(conn_id);
                    } else {
                        c.phase = .ready;
                        out[out_count] = .{ .conn_id = conn_id, .event = .connected };
                        out_count += 1;
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

        // A send is already in flight. Callers append new bytes at the old
        // send_len (a region the in-flight SQE is not transmitting) and grow
        // send_len to `len`. Restarting from offset 0 would retransmit bytes
        // the peer already received → duplicate frames on the wire and SDK
        // framing desync (M4). Instead just extend send_len; when the in-flight
        // send completes, queueSendInternal resumes from send_pos and ships the
        // appended tail (it re-reads the now-larger send_len).
        if (c.phase == .send_pending) {
            assert.check(len >= c.send_len, "queueSend: in-flight send on conn {d} shrank ({d} < {d})", .{ conn_id, len, c.send_len });
            c.send_len = len;
            return;
        }

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
        // Accept targets no connection slot yet — generation is irrelevant and
        // never checked for OP_ACCEPT.
        _ = self.ring.accept(
            encodeUserData(OP_ACCEPT, 0, 0),
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

    /// Allocate an outbound connection slot for a pre-created socket fd.
    /// Returns the conn_id, or null if no free slots.
    pub fn initOutboundConn(self: *UringBackend, fd: posix.fd_t) ?u16 {
        const slot = self.allocConn() orelse return null;
        const c = &self.conns[slot];
        c.fd = fd;
        c.phase = .connect_pending;
        c.protocol = .webhook;
        c.recv_pos = 0;
        c.send_pos = 0;
        c.send_len = 0;
        self.setTcpNodelay(fd);
        return slot;
    }

    /// Queue a connect on an outbound connection. The address must remain
    /// valid until the CQE arrives (stack-allocated is fine — io_uring copies it).
    pub fn queueConnect(self: *UringBackend, conn_id: u16, addr: *const std.net.Address) void {
        assert.check(conn_id < self.max_conns, "queueConnect: conn_id {d} >= max {d}", .{ conn_id, self.max_conns });
        const c = &self.conns[conn_id];
        assert.check(c.phase == .connect_pending, "queueConnect: conn {d} not in connect_pending phase", .{conn_id});
        assert.check(c.fd >= 0, "queueConnect: conn {d} has invalid fd", .{conn_id});

        _ = self.ring.connect(
            encodeUserData(OP_CONNECT, conn_id, c.generation),
            c.fd,
            &addr.any,
            addr.getOsSockLen(),
        ) catch {
            self.closeConn(conn_id);
            return;
        };
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
            encodeUserData(OP_RECV, conn_id, c.generation),
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
            encodeUserData(OP_SEND, conn_id, c.generation),
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
            // OP_CLOSE completions are ignored (no state applied), so the
            // generation is unused here.
            _ = self.ring.close(encodeUserData(OP_CLOSE, conn_id, 0), fd) catch {
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

test "user_data encoding round-trips (op, conn_id, generation)" {
    const testing = std.testing;

    const ud1 = encodeUserData(OP_ACCEPT, 0, 0);
    try testing.expectEqual(OP_ACCEPT, decodeOp(ud1));
    try testing.expectEqual(@as(u16, 0), decodeConnId(ud1));
    try testing.expectEqual(@as(u16, 0), decodeGen(ud1));

    const ud2 = encodeUserData(OP_RECV, 42, 7);
    try testing.expectEqual(OP_RECV, decodeOp(ud2));
    try testing.expectEqual(@as(u16, 42), decodeConnId(ud2));
    try testing.expectEqual(@as(u16, 7), decodeGen(ud2));

    const ud3 = encodeUserData(OP_SEND, 4095, 65535);
    try testing.expectEqual(OP_SEND, decodeOp(ud3));
    try testing.expectEqual(@as(u16, 4095), decodeConnId(ud3));
    try testing.expectEqual(@as(u16, 65535), decodeGen(ud3));

    const ud4 = encodeUserData(OP_CLOSE, 0xFFFF, 0);
    try testing.expectEqual(OP_CLOSE, decodeOp(ud4));
    try testing.expectEqual(@as(u16, 0xFFFF), decodeConnId(ud4));

    // conn_id, op, and generation occupy disjoint bit ranges — no cross-talk.
    const ud5 = encodeUserData(OP_RECV, 0xABCD, 0x1234);
    try testing.expectEqual(OP_RECV, decodeOp(ud5));
    try testing.expectEqual(@as(u16, 0xABCD), decodeConnId(ud5));
    try testing.expectEqual(@as(u16, 0x1234), decodeGen(ud5));
}

test "processCqes drops stale CQE with mismatched generation (M3)" {
    const testing = std.testing;
    // Loopback listener fd just so init() has a valid listen_fd.
    const listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(listen_fd);

    var backend = UringBackend.init(testing.allocator, .{
        .listen_fd = listen_fd,
        .max_conns = 4,
        .recv_buf_size = 256,
        .send_buf_size = 256,
    }) catch return; // skip if io_uring unavailable in the sandbox
    defer backend.deinit(testing.allocator);

    // Simulate an active connection on slot 1 at generation 5.
    const c = &backend.conns[1];
    c.fd = 100;
    c.phase = .ready;
    c.generation = 5;
    c.recv_pos = 0;

    var out: [4]Completion = undefined;

    // Stale recv CQE carrying the OLD generation (4) must be dropped.
    backend.cqe_buf[0] = .{ .user_data = encodeUserData(OP_RECV, 1, 4), .res = 10, .flags = 0 };
    try testing.expectEqual(@as(u32, 0), backend.processCqes(&out, 1));
    try testing.expectEqual(@as(u32, 0), c.recv_pos); // not advanced by stale data

    // Matching generation (5) is delivered normally.
    backend.cqe_buf[0] = .{ .user_data = encodeUserData(OP_RECV, 1, 5), .res = 10, .flags = 0 };
    try testing.expectEqual(@as(u32, 1), backend.processCqes(&out, 1));
    try testing.expectEqual(@as(u32, 10), c.recv_pos);
    try testing.expectEqual(Completion.Event.recv, out[0].event);

    c.fd = -1; // avoid deinit closing a bogus fd
    c.phase = .free;
}

test "queueSend does not restart an in-flight send (M4)" {
    const testing = std.testing;
    const listen_fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    defer posix.close(listen_fd);

    var backend = UringBackend.init(testing.allocator, .{
        .listen_fd = listen_fd,
        .max_conns = 4,
        .recv_buf_size = 256,
        .send_buf_size = 256,
    }) catch return; // skip if io_uring unavailable
    defer backend.deinit(testing.allocator);

    const c = &backend.conns[2];
    c.fd = 100;
    c.phase = .send_pending; // a send is already in flight
    c.send_pos = 30; // 30 bytes already acked by the peer
    c.send_len = 100;

    // A second queueSend (more data appended, send_len grown to 150) must NOT
    // rewind send_pos to 0 — that would retransmit the first 30 bytes.
    backend.queueSend(2, 150);
    try testing.expectEqual(@as(u32, 30), c.send_pos); // unchanged
    try testing.expectEqual(@as(u32, 150), c.send_len); // extended
    try testing.expectEqual(ConnState.Phase.send_pending, c.phase);

    c.fd = -1;
    c.phase = .free;
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
        .prefetch = 99,
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
    try testing.expectEqual(@as(u32, 0), c.prefetch);
    try testing.expectEqual(false, c.waiting);
    try testing.expectEqual(@as(u32, 0), c.last_req_id);
    try testing.expectEqual(@as(usize, 128), c.recv_buf.len);
    try testing.expectEqual(@as(usize, 128), c.send_buf.len);
}
