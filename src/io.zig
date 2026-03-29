//! IO backend — platform-abstracted network IO.
//!
//! Provides a unified interface over io_uring (Linux) and kqueue (macOS).
//! The IO backend owns the event loop, connection state, and all buffers.
//! It does NOT know about the RPC protocol, pipeline, or business logic.
//!
//! All buffers are pre-allocated at init — no allocations on the hot path.

const builtin = @import("builtin");
const std = @import("std");

/// A single IO completion event delivered to the caller.
pub const Completion = struct {
    conn_id: u16,
    event: Event,

    pub const Event = enum { recv, send_done, accept, closed };
};

/// Platform-specific IO backend, selected at comptime.
pub const Backend = switch (builtin.os.tag) {
    .linux => @import("io/uring.zig").UringBackend,
    .macos => @import("io/kqueue.zig").KqueueBackend,
    else => @compileError("unsupported OS: need io_uring (Linux) or kqueue (macOS)"),
};

/// Deterministic IO backend for simulation.
pub const SimBackend = @import("io/sim.zig").SimBackend;

/// Configuration for the IO backend.
pub const Config = struct {
    listen_fd: std.posix.fd_t,
    max_conns: u16 = 4096,
    recv_buf_size: u32 = 65536,
    send_buf_size: u32 = 65536,
};

/// Per-connection state. Pre-allocated flat array indexed by conn_id.
/// Idle connections have `phase == .free`. All buffers allocated at init.
pub const ConnState = struct {
    fd: std.posix.fd_t = -1,
    generation: u16 = 0,
    phase: Phase = .free,
    protocol: Protocol = .unknown,
    recv_buf: []u8,
    send_buf: []u8,
    recv_pos: u32 = 0,
    send_pos: u32 = 0,
    send_len: u32 = 0,

    // Fetch subscription state (for bidi push — pipeline reads these)
    queue_bufs: [16][64]u8 = undefined,
    queue_lens: [16]u8 = [_]u8{0} ** 16,
    queue_count: u8 = 0,
    worker_id_buf: [128]u8 = undefined,
    worker_id_len: u8 = 0,
    prefetch: u32 = 0,
    lease_ms: u32 = 30_000,
    waiting: bool = false,
    last_req_id: u32 = 0,

    pub const Phase = enum { free, recv_pending, ready, send_pending };
    pub const Protocol = enum { unknown, rpc, http };

    pub fn reset(self: *ConnState) void {
        self.fd = -1;
        self.generation +%= 1;
        self.phase = .free;
        self.protocol = .unknown;
        self.recv_pos = 0;
        self.send_pos = 0;
        self.send_len = 0;
        self.queue_count = 0;
        self.worker_id_len = 0;
        self.prefetch = 0;
        self.waiting = false;
        self.last_req_id = 0;
    }
};

test {
    const testing = std.testing;
    testing.refAllDecls(Backend);
}
