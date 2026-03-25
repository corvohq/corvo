//! kqueue backend for macOS.
//!
//! Owns the kqueue fd, all connection state (pre-allocated flat array),
//! and all per-connection buffers. Provides accept/recv/send/close lifecycle.
//!
//! Does NOT know about the RPC protocol, pipeline, or business logic.
//! All buffers pre-allocated at init — zero allocations on the hot path.
//!
//! This module compiles on Linux (comptime gated) but is only exercised on macOS.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const assert = @import("../assert.zig");
const io = @import("../io.zig");
const Completion = io.Completion;
const ConnState = io.ConnState;
const Config = io.Config;
const Allocator = std.mem.Allocator;

// ============================================================================
// Platform-specific types (comptime gated for cross-compilation)
// ============================================================================

const is_macos = builtin.os.tag == .macos;

const Kevent = if (is_macos) posix.Kevent else extern struct {
    ident: usize = 0,
    filter: i16 = 0,
    flags: u16 = 0,
    fflags: u32 = 0,
    data: isize = 0,
    udata: usize = 0,
};

const EVFILT_READ: i16 = if (is_macos) std.c.EVFILT.READ else -1;
const EVFILT_WRITE: i16 = if (is_macos) std.c.EVFILT.WRITE else -5;
const EV_ADD: u16 = if (is_macos) std.c.EV.ADD else 0x0001;
const EV_DELETE: u16 = if (is_macos) std.c.EV.DELETE else 0x0002;
const EV_ENABLE: u16 = if (is_macos) std.c.EV.ENABLE else 0x0004;
const EV_ONESHOT: u16 = if (is_macos) std.c.EV.ONESHOT else 0x0010;
const EV_EOF: u16 = if (is_macos) std.c.EV.EOF else 0x8000;
const EV_ERROR: u16 = if (is_macos) std.c.EV.ERROR else 0x4000;

// ============================================================================
// KqueueBackend
// ============================================================================

pub const KqueueBackend = struct {
    kq_fd: posix.fd_t,
    conns: []ConnState,
    max_conns: u16,
    listen_fd: posix.fd_t,
    buf_mem: []u8,

    // Free list for connection slots (stack, O(1) alloc/free)
    free_list: []u16,
    free_count: u16,

    // Pending kevent changes to flush
    changes: [256]Kevent = undefined,
    change_count: u16 = 0,

    // Event output buffer for kevent()
    event_buf: [256]Kevent = undefined,

    pub fn init(allocator: Allocator, config: Config) !KqueueBackend {
        if (comptime !is_macos) {
            @compileError("KqueueBackend.init: only supported on macOS");
        }

        const max: u16 = config.max_conns;
        assert.check(max > 0, "KqueueBackend.init: max_conns must be > 0", .{});

        const kq_fd = try posix.kqueue();
        errdefer posix.close(kq_fd);

        const conns = try allocator.alloc(ConnState, max);
        errdefer allocator.free(conns);

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

        const free_list = try allocator.alloc(u16, max);
        errdefer allocator.free(free_list);
        for (free_list, 0..) |*slot, i| {
            slot.* = @intCast(max - 1 - i);
        }

        return KqueueBackend{
            .kq_fd = kq_fd,
            .conns = conns,
            .max_conns = max,
            .listen_fd = config.listen_fd,
            .buf_mem = buf_mem,
            .free_list = free_list,
            .free_count = max,
        };
    }

    pub fn deinit(self: *KqueueBackend, allocator: Allocator) void {
        for (self.conns) |*c| {
            if (c.phase != .free and c.fd >= 0) {
                posix.close(c.fd);
                c.fd = -1;
            }
        }
        posix.close(self.kq_fd);
        allocator.free(self.free_list);
        allocator.free(self.buf_mem);
        allocator.free(self.conns);
    }

    pub fn drain(self: *KqueueBackend, out: []Completion) u32 {
        if (comptime !is_macos) unreachable;

        assert.check(out.len > 0, "drain: output buffer must be non-empty", .{});

        const n_events = kevent(
            self.kq_fd,
            self.changes[0..self.change_count],
            &self.event_buf,
            null,
        );
        self.change_count = 0;

        if (n_events < 0) return 0;

        var out_count: u32 = 0;
        for (self.event_buf[0..@intCast(n_events)]) |ev| {
            if (out_count >= out.len) break;

            const fd: posix.fd_t = @intCast(ev.ident);

            if (fd == self.listen_fd) {
                const result = posix.accept(self.listen_fd, null, null, 0);
                if (result) |new_fd| {
                    const slot = self.allocConn();
                    if (slot) |id| {
                        const c = &self.conns[id];
                        c.fd = new_fd;
                        c.phase = .recv_pending;

                        setNonBlocking(new_fd);
                        setTcpNodelay(new_fd);
                        self.addReadEvent(id);

                        out[out_count] = .{ .conn_id = id, .event = .accept };
                        out_count += 1;
                    } else {
                        posix.close(new_fd);
                    }
                } else |_| {}
                continue;
            }

            if (ev.udata >= self.max_conns) continue;
            const conn_id: u16 = @intCast(ev.udata);
            const c = &self.conns[conn_id];
            if (c.phase == .free) continue;

            if (ev.filter == EVFILT_READ) {
                if (ev.flags & EV_EOF != 0 and ev.data == 0) {
                    out[out_count] = .{ .conn_id = conn_id, .event = .closed };
                    out_count += 1;
                    self.closeConn(conn_id);
                    continue;
                }

                const space = c.recv_buf.len - c.recv_pos;
                if (space == 0) continue;

                const n = posix.read(c.fd, c.recv_buf[c.recv_pos..]) catch {
                    out[out_count] = .{ .conn_id = conn_id, .event = .closed };
                    out_count += 1;
                    self.closeConn(conn_id);
                    continue;
                };

                if (n == 0) {
                    out[out_count] = .{ .conn_id = conn_id, .event = .closed };
                    out_count += 1;
                    self.closeConn(conn_id);
                } else {
                    c.recv_pos += @intCast(n);
                    c.phase = .ready;
                    out[out_count] = .{ .conn_id = conn_id, .event = .recv };
                    out_count += 1;
                }
            } else if (ev.filter == EVFILT_WRITE) {
                if (c.send_len == 0) continue;

                const to_send = c.send_buf[c.send_pos..c.send_len];
                const n = posix.write(c.fd, to_send) catch {
                    out[out_count] = .{ .conn_id = conn_id, .event = .closed };
                    out_count += 1;
                    self.closeConn(conn_id);
                    continue;
                };

                c.send_pos += @intCast(n);
                if (c.send_pos >= c.send_len) {
                    c.send_pos = 0;
                    c.send_len = 0;
                    c.phase = .ready;
                    out[out_count] = .{ .conn_id = conn_id, .event = .send_done };
                    out_count += 1;
                }
            }
        }
        return out_count;
    }

    pub fn queueSend(self: *KqueueBackend, conn_id: u16, len: u32) void {
        assert.check(conn_id < self.max_conns, "queueSend: conn_id {d} >= max {d}", .{ conn_id, self.max_conns });
        const c = &self.conns[conn_id];
        assert.check(c.phase != .free, "queueSend: conn {d} is free", .{conn_id});

        c.send_pos = 0;
        c.send_len = len;
        c.phase = .send_pending;
        self.addWriteEvent(conn_id);
    }

    pub fn queueRecv(self: *KqueueBackend, conn_id: u16) void {
        assert.check(conn_id < self.max_conns, "queueRecv: conn_id {d} >= max {d}", .{ conn_id, self.max_conns });
        const c = &self.conns[conn_id];
        assert.check(c.phase != .free, "queueRecv: conn {d} is free", .{conn_id});

        c.phase = .recv_pending;
        self.addReadEvent(conn_id);
    }

    pub fn queueAccept(self: *KqueueBackend) void {
        self.addChange(.{
            .ident = @intCast(self.listen_fd),
            .filter = EVFILT_READ,
            .flags = EV_ADD | EV_ENABLE,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        });
    }

    pub fn queueClose(self: *KqueueBackend, conn_id: u16) void {
        assert.check(conn_id < self.max_conns, "queueClose: conn_id {d} >= max {d}", .{ conn_id, self.max_conns });
        self.closeConn(conn_id);
    }

    pub fn submit(self: *KqueueBackend) void {
        if (comptime !is_macos) return;

        if (self.change_count == 0) return;
        _ = kevent(self.kq_fd, self.changes[0..self.change_count], &[_]Kevent{}, null);
        self.change_count = 0;
    }

    pub fn conn(self: *KqueueBackend, id: u16) *ConnState {
        assert.check(id < self.max_conns, "conn: id {d} >= max {d}", .{ id, self.max_conns });
        return &self.conns[id];
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    fn addReadEvent(self: *KqueueBackend, conn_id: u16) void {
        const c = &self.conns[conn_id];
        self.addChange(.{
            .ident = @intCast(c.fd),
            .filter = EVFILT_READ,
            .flags = EV_ADD | EV_ENABLE | EV_ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = @intCast(conn_id),
        });
    }

    fn addWriteEvent(self: *KqueueBackend, conn_id: u16) void {
        const c = &self.conns[conn_id];
        self.addChange(.{
            .ident = @intCast(c.fd),
            .filter = EVFILT_WRITE,
            .flags = EV_ADD | EV_ENABLE | EV_ONESHOT,
            .fflags = 0,
            .data = 0,
            .udata = @intCast(conn_id),
        });
    }

    fn addChange(self: *KqueueBackend, ev: Kevent) void {
        if (self.change_count >= self.changes.len) {
            self.submit();
        }
        self.changes[self.change_count] = ev;
        self.change_count += 1;
    }

    fn allocConn(self: *KqueueBackend) ?u16 {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        return self.free_list[self.free_count];
    }

    fn freeConn(self: *KqueueBackend, conn_id: u16) void {
        assert.check(self.free_count < self.max_conns, "freeConn: free_list overflow", .{});
        self.free_list[self.free_count] = conn_id;
        self.free_count += 1;
    }

    fn closeConn(self: *KqueueBackend, conn_id: u16) void {
        const c = &self.conns[conn_id];
        if (c.phase == .free) return;

        const fd = c.fd;
        c.reset();
        self.freeConn(conn_id);

        if (fd >= 0) {
            self.addChange(.{
                .ident = @intCast(fd),
                .filter = EVFILT_READ,
                .flags = EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            });
            self.addChange(.{
                .ident = @intCast(fd),
                .filter = EVFILT_WRITE,
                .flags = EV_DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            });
            posix.close(fd);
        }
    }

    fn setNonBlocking(fd: posix.fd_t) void {
        if (comptime !is_macos) return;
        const flags = posix.fcntl(fd, .GETFL) catch return;
        _ = posix.fcntl(fd, .SETFL, .{ .bits = @as(u32, @bitCast(flags)) | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })) }) catch {};
    }

    fn setTcpNodelay(fd: posix.fd_t) void {
        if (comptime !is_macos) return;
        const TCP_NODELAY = 1;
        posix.setsockopt(
            fd,
            posix.IPPROTO.TCP,
            TCP_NODELAY,
            &std.mem.toBytes(@as(c_int, 1)),
        ) catch {};
    }

    fn kevent(kq: posix.fd_t, changelist: []const Kevent, eventlist: []Kevent, timeout: ?*const posix.timespec) isize {
        if (comptime !is_macos) return 0;
        return @intCast(posix.system.kevent(
            kq,
            changelist.ptr,
            @intCast(changelist.len),
            eventlist.ptr,
            @intCast(eventlist.len),
            timeout,
        ));
    }
};

test "KqueueBackend compiles" {
    const T = KqueueBackend;
    _ = T.init;
    _ = T.deinit;
    _ = T.drain;
    _ = T.queueSend;
    _ = T.queueRecv;
    _ = T.queueAccept;
    _ = T.queueClose;
    _ = T.submit;
    _ = T.conn;
}
