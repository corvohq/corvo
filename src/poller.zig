//! Poller — cross-platform I/O event notification.
//!
//! Provides a unified interface over epoll (Linux) and kqueue (macOS).
//! Designed for multiplexing thousands of idle TCP connections with
//! minimal overhead — no allocations on the hot path.
//!
//! Usage:
//!   var poller = try Poller.init();
//!   defer poller.deinit();
//!   try poller.addFd(fd, user_data);
//!   var raw_buf: [N]RawEvent = undefined;
//!   var out_buf: [N]Event = undefined;
//!   const events = poller.wait(&out_buf, &raw_buf, timeout_ms);

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Platform-specific raw event type — callers must declare a buffer of this
/// type and pass it to wait(). The buffer is never inspected by the caller;
/// it just provides stack space for the kernel to write into.
pub const RawEvent = switch (builtin.os.tag) {
    .linux => std.os.linux.epoll_event,
    .macos => posix.Kevent,
    else => @compileError("poller: unsupported OS (epoll/kqueue only)"),
};

/// Decoded event returned by wait(). Platform-agnostic.
pub const Event = struct {
    /// User-supplied token passed to addFd(). Opaque to the poller.
    data: usize,
    readable: bool,
    writable: bool,
    /// Error or hangup on the fd.
    err: bool,
};

/// Platform-selected Poller implementation.
pub const Poller = switch (builtin.os.tag) {
    .linux => EpollPoller,
    .macos => KqueuePoller,
    else => @compileError("poller: unsupported OS (epoll/kqueue only)"),
};

// ============================================================================
// EpollPoller — Linux
// ============================================================================

const EpollPoller = struct {
    epfd: i32,

    const linux = std.os.linux;

    pub fn init() !EpollPoller {
        const epfd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        return .{ .epfd = epfd };
    }

    pub fn deinit(self: *EpollPoller) void {
        posix.close(self.epfd);
    }

    /// Register fd for edge-triggered read notification with user data token.
    pub fn addFd(self: *EpollPoller, fd: i32, data: usize) !void {
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = .{ .u64 = data },
        };
        try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_ADD, fd, &ev);
    }

    /// Modify an existing fd registration to watch readable and/or writable.
    pub fn modFd(self: *EpollPoller, fd: i32, data: usize, readable: bool, writable: bool) !void {
        var flags: u32 = linux.EPOLL.ET;
        if (readable) flags |= linux.EPOLL.IN;
        if (writable) flags |= linux.EPOLL.OUT;
        var ev = linux.epoll_event{
            .events = flags,
            .data = .{ .u64 = data },
        };
        try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_MOD, fd, &ev);
    }

    /// Deregister fd from the poller.
    pub fn removeFd(self: *EpollPoller, fd: i32) !void {
        try posix.epoll_ctl(self.epfd, linux.EPOLL.CTL_DEL, fd, null);
    }

    /// Block up to timeout_ms milliseconds waiting for events.
    /// Writes raw kernel events into raw_events, then decodes into out_events.
    /// Returns the slice of decoded events (always a sub-slice of out_events).
    pub fn wait(
        self: *EpollPoller,
        out_events: []Event,
        raw_events: []linux.epoll_event,
        timeout_ms: i32,
    ) []Event {
        const max = @min(out_events.len, raw_events.len);
        const n = posix.epoll_wait(self.epfd, raw_events[0..max], timeout_ms);
        for (raw_events[0..n], 0..n) |*re, i| {
            const ev = re.events;
            out_events[i] = .{
                .data = @intCast(re.data.u64),
                .readable = (ev & linux.EPOLL.IN) != 0,
                .writable = (ev & linux.EPOLL.OUT) != 0,
                .err = (ev & (linux.EPOLL.ERR | linux.EPOLL.HUP)) != 0,
            };
        }
        return out_events[0..n];
    }
};

// ============================================================================
// KqueuePoller — macOS
// ============================================================================

const KqueuePoller = struct {
    kqfd: i32,

    const EV = std.c.EV;
    const EVFILT = std.c.EVFILT;

    pub fn init() !KqueuePoller {
        const kqfd = try posix.kqueue();
        return .{ .kqfd = kqfd };
    }

    pub fn deinit(self: *KqueuePoller) void {
        posix.close(self.kqfd);
    }

    /// Register fd for edge-triggered read notification with user data token.
    pub fn addFd(self: *KqueuePoller, fd: i32, data: usize) !void {
        const changes = [_]posix.Kevent{.{
            .ident = @intCast(fd),
            .filter = EVFILT.READ,
            .flags = EV.ADD | EV.CLEAR,
            .fflags = 0,
            .data = 0,
            .udata = data,
        }};
        _ = posix.kevent(self.kqfd, &changes, &.{}, null) catch |err| switch (err) {
            error.EventNotFound => return error.FileDescriptorNotFound,
            else => return err,
        };
    }

    /// Modify an existing fd registration to watch readable and/or writable.
    /// kqueue requires each filter to be registered separately, so we
    /// add/delete READ and WRITE filters individually.
    pub fn modFd(self: *KqueuePoller, fd: i32, data: usize, readable: bool, writable: bool) !void {
        const read_flags: u16 = if (readable) EV.ADD | EV.CLEAR else EV.DELETE;
        const write_flags: u16 = if (writable) EV.ADD | EV.CLEAR else EV.DELETE;
        const changes = [_]posix.Kevent{
            .{
                .ident = @intCast(fd),
                .filter = EVFILT.READ,
                .flags = read_flags,
                .fflags = 0,
                .data = 0,
                .udata = data,
            },
            .{
                .ident = @intCast(fd),
                .filter = EVFILT.WRITE,
                .flags = write_flags,
                .fflags = 0,
                .data = 0,
                .udata = data,
            },
        };
        // EventNotFound on DELETE is benign (filter was never added).
        _ = posix.kevent(self.kqfd, &changes, &.{}, null) catch |err| switch (err) {
            error.EventNotFound => {},
            else => return err,
        };
    }

    /// Deregister fd from the poller. Removes BOTH READ and WRITE filters to
    /// prevent stale write-interest from leaking after the fd is closed.
    pub fn removeFd(self: *KqueuePoller, fd: i32) !void {
        const changes = [_]posix.Kevent{
            .{
                .ident = @intCast(fd),
                .filter = EVFILT.READ,
                .flags = EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
            .{
                .ident = @intCast(fd),
                .filter = EVFILT.WRITE,
                .flags = EV.DELETE,
                .fflags = 0,
                .data = 0,
                .udata = 0,
            },
        };
        // EventNotFound is benign — WRITE filter may not have been registered.
        _ = posix.kevent(self.kqfd, &changes, &.{}, null) catch |err| switch (err) {
            error.EventNotFound => {},
            else => return err,
        };
    }

    /// Block up to timeout_ms milliseconds waiting for events.
    /// Writes raw kernel events into raw_events, then decodes into out_events.
    /// Returns the slice of decoded events (always a sub-slice of out_events).
    pub fn wait(
        self: *KqueuePoller,
        out_events: []Event,
        raw_events: []posix.Kevent,
        timeout_ms: i32,
    ) []Event {
        const max = @min(out_events.len, raw_events.len);
        const ts = posix.timespec{
            .sec = @divTrunc(timeout_ms, 1000),
            .nsec = @rem(timeout_ms, 1000) * std.time.ns_per_ms,
        };
        const timeout_ptr: ?*const posix.timespec = if (timeout_ms < 0) null else &ts;
        const n = posix.kevent(self.kqfd, &.{}, raw_events[0..max], timeout_ptr) catch return &.{};
        for (raw_events[0..n], 0..n) |*re, i| {
            out_events[i] = .{
                .data = re.udata,
                .readable = re.filter == EVFILT.READ,
                .writable = re.filter == EVFILT.WRITE,
                .err = (re.flags & EV.ERROR) != 0 or (re.flags & EV.EOF) != 0,
            };
        }
        return out_events[0..n];
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Poller: add fd, trigger readable" {
    const pipe = try posix.pipe();
    defer posix.close(pipe[0]);
    defer posix.close(pipe[1]);

    var poller = try Poller.init();
    defer poller.deinit();

    try poller.addFd(pipe[0], 42);

    _ = try posix.write(pipe[1], "x");

    var raw_buf: [16]RawEvent = undefined;
    var out_buf: [16]Event = undefined;
    const events = poller.wait(&out_buf, &raw_buf, 100);

    try std.testing.expect(events.len >= 1);
    try std.testing.expectEqual(@as(usize, 42), events[0].data);
    try std.testing.expect(events[0].readable);
}
