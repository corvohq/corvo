//! raft_net.zig — single-threaded TCP peer transport for Raft.
//!
//! Owns its own io_uring (Linux) / kqueue (macOS) instance, ticked from
//! the same OS thread as the main pipeline. Bridges io completions to
//! `raft_transport.Transport` via length-prefixed frames over TCP.
//!
//! Why a private event loop and not shared with the client transport:
//!   - Peer messages can be up to `raft_codec.max_msg_bytes` (2 MiB,
//!     bounded by `install_snapshot` chunks). Sharing the client conn
//!     buffer pool would either bloat 20 k client conns or require
//!     intrusive per-conn buffer-size plumbing in `io.zig`.
//!   - Production already binds peer traffic on `cluster_port` (server
//!     port + 1000), separate from client traffic.
//!   - Failure isolation: a misbehaving peer can't exhaust client conn
//!     slots or recv-buf headroom.
//!
//! Topology: each node initiates one outbound TCP connection per peer
//! and accepts one inbound from each. Sends ride the outbound, receives
//! ride the inbound. Asymmetric simplifies framing (each direction is a
//! single byte stream of length-prefixed frames).
//!
//! Wire frame: `[u32_be: payload_len][payload bytes...]`
//! payload is the raft_codec-encoded Message; from-id is decoded out of
//! the payload header for transport.pushInboundBytes routing.
//!
//! TigerStyle: static peer / conn-info tables, bounded outbox per peer,
//! short functions, exhaustive switches, drops are explicit (Raft retries).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.net;
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const io_mod = @import("io.zig");
const codec = @import("raft_codec.zig");
const raft_transport_mod = @import("raft_transport.zig");

const RaftTransport = raft_transport_mod.Transport;

// ============================================================================
// Configuration
// ============================================================================

/// Raft cluster size cap (matches typical 3/5/7 voter deployments).
pub const max_peers: u8 = 7;

/// Outbound + inbound conns per peer + headroom for reconnect transients.
pub const max_conns: u16 = 32;

/// Bounded per-peer outbox. Drops on overflow — Raft retransmits.
pub const max_outbox_per_peer: u8 = 16;

/// How long to wait between reconnect attempts to a disconnected peer.
pub const reconnect_interval_ns: u64 = 100_000_000; // 100 ms

/// Default per-conn buffer size. Sized for one full encoded raft Message
/// (snapshot install_snapshot chunk hits the 2 MiB cap) plus headroom.
pub const default_buf_size: u32 = @as(u32, @intCast(codec.max_msg_bytes)) + 4 + 256;

/// Length prefix on every framed payload.
pub const frame_len_prefix: usize = 4;

pub const Config = struct {
    self_id: []const u8,
    bind_addr: net.Address,
    recv_buf_size: u32 = default_buf_size,
    send_buf_size: u32 = default_buf_size,
};

pub const NetError = error{
    PeerTableFull,
    AlreadyRegistered,
    BindFailed,
    ListenFailed,
    SocketFailed,
    OutOfMemory,
};

// ============================================================================
// Per-peer + per-conn state
// ============================================================================

const OutPhase = enum { disconnected, connecting, connected };
const ConnRole = enum { unused, outbound, inbound };

const PeerEntry = struct {
    id_buf: [codec.max_id_len]u8 = undefined,
    id_len: u8 = 0,
    addr: net.Address = undefined,

    out_conn_id: ?u16 = null,
    out_phase: OutPhase = .disconnected,
    last_attempt_ns: i64 = 0,

    /// Ring of frame-prefixed byte buffers awaiting transmission.
    /// Each entry is heap-allocated by `enqueueSend`; freed on dispatch
    /// (or on disconnect, where the queue is drained).
    outbox: [max_outbox_per_peer]?[]u8 = .{null} ** max_outbox_per_peer,
    outbox_head: u8 = 0,
    outbox_tail: u8 = 0,
    outbox_count: u8 = 0,

    /// True while a queueSend is in flight on the outbound conn.
    /// Cleared on send_done or on disconnect.
    sending: bool = false,

    fn id(self: *const PeerEntry) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

const ConnInfo = struct {
    role: ConnRole = .unused,
    /// For outbound conns, the peer index. Inbound conns are unattributed
    /// at the conn level — each frame's `from` field routes per-message.
    peer_idx: ?u8 = null,
};

// ============================================================================
// PeerNet
// ============================================================================

pub const PeerNet = struct {
    allocator: std.mem.Allocator,
    io: io_mod.Backend,
    listen_fd: posix.fd_t,
    bound_addr: net.Address,

    self_id_buf: [codec.max_id_len]u8 = undefined,
    self_id_len: u8 = 0,

    peers: [max_peers]PeerEntry = [_]PeerEntry{.{}} ** max_peers,
    peer_count: u8 = 0,

    conn_info: [max_conns]ConnInfo = [_]ConnInfo{.{}} ** max_conns,

    drops_unknown_peer: u64 = 0,
    drops_outbox_full: u64 = 0,
    drops_bad_frame: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !PeerNet {
        check(cfg.self_id.len > 0 and cfg.self_id.len <= codec.max_id_len, "self_id len {d}", .{cfg.self_id.len});
        check(cfg.recv_buf_size >= frame_len_prefix + 64, "recv_buf_size too small: {d}", .{cfg.recv_buf_size});

        const listen_fd = try createListenFd(cfg.bind_addr);
        errdefer posix.close(listen_fd);
        const bound = try getBoundAddr(listen_fd);

        var backend = try io_mod.Backend.init(allocator, .{
            .listen_fd = listen_fd,
            .max_conns = max_conns,
            .recv_buf_size = cfg.recv_buf_size,
            .send_buf_size = cfg.send_buf_size,
        });
        errdefer backend.deinit(allocator);

        var pn = PeerNet{
            .allocator = allocator,
            .io = backend,
            .listen_fd = listen_fd,
            .bound_addr = bound,
        };
        @memcpy(pn.self_id_buf[0..cfg.self_id.len], cfg.self_id);
        pn.self_id_len = @intCast(cfg.self_id.len);

        pn.io.queueAccept();
        pn.io.submit();
        return pn;
    }

    pub fn deinit(self: *PeerNet) void {
        for (&self.peers) |*p| {
            self.drainOutbox(p);
        }
        self.io.deinit(self.allocator);
        posix.close(self.listen_fd);
    }

    pub fn boundAddress(self: *const PeerNet) net.Address {
        return self.bound_addr;
    }

    pub fn selfId(self: *const PeerNet) []const u8 {
        return self.self_id_buf[0..self.self_id_len];
    }

    pub fn registerPeer(self: *PeerNet, id: []const u8, addr: net.Address) NetError!void {
        check(id.len > 0 and id.len <= codec.max_id_len, "peer id len {d}", .{id.len});
        if (self.peer_count >= max_peers) return NetError.PeerTableFull;
        for (self.peers[0..self.peer_count]) |*p| {
            if (std.mem.eql(u8, p.id(), id)) return NetError.AlreadyRegistered;
        }
        var p = &self.peers[self.peer_count];
        @memcpy(p.id_buf[0..id.len], id);
        p.id_len = @intCast(id.len);
        p.addr = addr;
        p.out_phase = .disconnected;
        self.peer_count += 1;
    }

    /// Wire the transport's send hook so raft sends route through this net.
    pub fn install(self: *PeerNet, transport: *RaftTransport) void {
        transport.setSend(@ptrCast(self), sendBridge);
    }

    fn sendBridge(ctx: *anyopaque, to: []const u8, bytes: []const u8) bool {
        const self: *PeerNet = @ptrCast(@alignCast(ctx));
        return self.enqueueSend(to, bytes);
    }

    fn enqueueSend(self: *PeerNet, to: []const u8, bytes: []const u8) bool {
        const p = self.findPeerMut(to) orelse {
            self.drops_unknown_peer += 1;
            return false;
        };
        if (p.outbox_count >= max_outbox_per_peer) {
            self.drops_outbox_full += 1;
            return false;
        }
        if (bytes.len > codec.max_msg_bytes) {
            self.drops_bad_frame += 1;
            return false;
        }
        const buf = self.allocator.alloc(u8, frame_len_prefix + bytes.len) catch {
            self.drops_outbox_full += 1;
            return false;
        };
        std.mem.writeInt(u32, buf[0..4], @intCast(bytes.len), .big);
        @memcpy(buf[4..], bytes);
        p.outbox[p.outbox_tail] = buf;
        p.outbox_tail = (p.outbox_tail + 1) % max_outbox_per_peer;
        p.outbox_count += 1;
        return true;
    }

    fn findPeerMut(self: *PeerNet, id: []const u8) ?*PeerEntry {
        for (self.peers[0..self.peer_count]) |*p| {
            if (std.mem.eql(u8, p.id(), id)) return p;
        }
        return null;
    }

    /// Run one tick: reconnect, dispatch, and drain io completions.
    /// `transport` receives every successfully-decoded inbound frame.
    pub fn tick(self: *PeerNet, now: i64, transport: *RaftTransport) void {
        self.maybeReconnect(now);
        self.flushPeerOutboxes();
        self.io.submit();
        self.drainAll(transport);
    }

    fn drainAll(self: *PeerNet, transport: *RaftTransport) void {
        var batch: [128]io_mod.Completion = undefined;
        var iters: u8 = 0;
        while (iters < 8) : (iters += 1) {
            const n = self.io.drainNonBlocking(&batch);
            if (n == 0) break;
            for (batch[0..n]) |c| self.handleCompletion(c, transport);
        }
    }

    fn maybeReconnect(self: *PeerNet, now: i64) void {
        for (self.peers[0..self.peer_count], 0..) |*p, idx| {
            if (p.out_phase != .disconnected) continue;
            const since = now - p.last_attempt_ns;
            if (since >= 0 and @as(u64, @intCast(since)) < reconnect_interval_ns) continue;
            p.last_attempt_ns = now;
            self.startConnect(@intCast(idx));
        }
    }

    fn startConnect(self: *PeerNet, peer_idx: u8) void {
        const p = &self.peers[peer_idx];
        const fd = posix.socket(
            p.addr.any.family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
            posix.IPPROTO.TCP,
        ) catch return;
        const conn_id = self.io.initOutboundConn(fd) orelse {
            posix.close(fd);
            return;
        };
        check(conn_id < max_conns, "conn_id {d} >= max_conns {d}", .{ conn_id, max_conns });
        self.conn_info[conn_id] = .{ .role = .outbound, .peer_idx = peer_idx };
        p.out_conn_id = conn_id;
        p.out_phase = .connecting;
        self.io.queueConnect(conn_id, &p.addr);
    }

    fn flushPeerOutboxes(self: *PeerNet) void {
        for (self.peers[0..self.peer_count]) |*p| {
            if (p.out_phase != .connected) continue;
            if (p.sending) continue;
            self.tryDispatch(p);
        }
    }

    fn tryDispatch(self: *PeerNet, p: *PeerEntry) void {
        if (p.outbox_count == 0) return;
        const conn_id = p.out_conn_id orelse return;
        const buf = p.outbox[p.outbox_head] orelse return;
        p.outbox[p.outbox_head] = null;
        p.outbox_head = (p.outbox_head + 1) % max_outbox_per_peer;
        p.outbox_count -= 1;

        const c = self.io.conn(conn_id);
        check(buf.len <= c.send_buf.len, "send buf overflow: {d} > {d}", .{ buf.len, c.send_buf.len });
        @memcpy(c.send_buf[0..buf.len], buf);
        const len: u32 = @intCast(buf.len);
        self.allocator.free(buf);
        p.sending = true;
        self.io.queueSend(conn_id, len);
    }

    fn drainOutbox(self: *PeerNet, p: *PeerEntry) void {
        while (p.outbox_count > 0) {
            if (p.outbox[p.outbox_head]) |buf| self.allocator.free(buf);
            p.outbox[p.outbox_head] = null;
            p.outbox_head = (p.outbox_head + 1) % max_outbox_per_peer;
            p.outbox_count -= 1;
        }
        p.outbox_head = 0;
        p.outbox_tail = 0;
        p.sending = false;
    }

    // ------------------------------------------------------------------------
    // Completion handling
    // ------------------------------------------------------------------------

    fn handleCompletion(self: *PeerNet, c: io_mod.Completion, transport: *RaftTransport) void {
        switch (c.event) {
            .accept => self.onAccept(c.conn_id),
            .connected => self.onConnected(c.conn_id),
            .recv => self.onRecv(c.conn_id, transport),
            .send_done => self.onSendDone(c.conn_id),
            .closed => self.onClosed(c.conn_id),
        }
    }

    fn onAccept(self: *PeerNet, conn_id: u16) void {
        check(conn_id < max_conns, "conn_id {d} >= max_conns {d}", .{ conn_id, max_conns });
        self.conn_info[conn_id] = .{ .role = .inbound, .peer_idx = null };
        // io backend already queued the recv on accept.
    }

    fn onConnected(self: *PeerNet, conn_id: u16) void {
        check(conn_id < max_conns, "conn_id {d} >= max_conns {d}", .{ conn_id, max_conns });
        const info = self.conn_info[conn_id];
        if (info.role != .outbound) return;
        const peer_idx = info.peer_idx orelse return;
        const p = &self.peers[peer_idx];
        p.out_phase = .connected;
        // Outbound is send-only: no queueRecv. Peer's reciprocal outbound is our inbound.
        self.tryDispatch(p);
    }

    fn onRecv(self: *PeerNet, conn_id: u16, transport: *RaftTransport) void {
        check(conn_id < max_conns, "conn_id {d} >= max_conns {d}", .{ conn_id, max_conns });
        const info = self.conn_info[conn_id];
        if (info.role != .inbound) {
            // We don't expect data on outbound conns; requeue and ignore.
            self.io.queueRecv(conn_id);
            return;
        }
        const c = self.io.conn(conn_id);
        const consumed = self.parseInboundFrames(c, transport, conn_id);
        if (consumed == 0 and c.recv_pos == c.recv_buf.len) {
            // No progress and the buffer is full — frame must be malformed.
            self.drops_bad_frame += 1;
            self.io.queueClose(conn_id);
            return;
        }
        if (consumed > 0) compactRecvBuf(c, consumed);
        self.io.queueRecv(conn_id);
    }

    /// Parse as many complete frames as fit in `c.recv_buf[0..c.recv_pos]`.
    /// Returns the number of bytes consumed from the front of the buffer.
    /// On a malformed length prefix, closes the connection and returns 0.
    fn parseInboundFrames(
        self: *PeerNet,
        c: *io_mod.ConnState,
        transport: *RaftTransport,
        conn_id: u16,
    ) u32 {
        var consumed: u32 = 0;
        while (true) {
            const remaining = c.recv_pos - consumed;
            if (remaining < frame_len_prefix) break;
            const len = std.mem.readInt(u32, c.recv_buf[consumed..][0..4], .big);
            if (len == 0 or len > codec.max_msg_bytes) {
                self.drops_bad_frame += 1;
                self.io.queueClose(conn_id);
                return 0;
            }
            const total: u32 = @as(u32, @intCast(frame_len_prefix)) + len;
            if (remaining < total) break;
            const payload = c.recv_buf[consumed + @as(u32, @intCast(frame_len_prefix)) ..][0..len];
            if (decodeFromOnly(payload)) |from| {
                _ = transport.pushInboundBytes(from, payload);
            } else |_| {
                self.drops_bad_frame += 1;
            }
            consumed += total;
        }
        return consumed;
    }

    fn onSendDone(self: *PeerNet, conn_id: u16) void {
        check(conn_id < max_conns, "conn_id {d} >= max_conns {d}", .{ conn_id, max_conns });
        const info = self.conn_info[conn_id];
        if (info.role != .outbound) return;
        const peer_idx = info.peer_idx orelse return;
        const p = &self.peers[peer_idx];
        p.sending = false;
        self.tryDispatch(p);
    }

    fn onClosed(self: *PeerNet, conn_id: u16) void {
        check(conn_id < max_conns, "conn_id {d} >= max_conns {d}", .{ conn_id, max_conns });
        const info = self.conn_info[conn_id];
        if (info.role == .outbound) {
            if (info.peer_idx) |idx| {
                const p = &self.peers[idx];
                p.out_phase = .disconnected;
                p.out_conn_id = null;
                self.drainOutbox(p);
            }
        }
        self.conn_info[conn_id] = .{};
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn createListenFd(addr: net.Address) NetError!posix.fd_t {
    const fd = posix.socket(
        addr.any.family,
        posix.SOCK.STREAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.TCP,
    ) catch return NetError.SocketFailed;
    errdefer posix.close(fd);
    posix.setsockopt(
        fd,
        posix.SOL.SOCKET,
        posix.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    ) catch {};
    posix.bind(fd, &addr.any, addr.getOsSockLen()) catch return NetError.BindFailed;
    posix.listen(fd, 16) catch return NetError.ListenFailed;
    return fd;
}

fn getBoundAddr(fd: posix.fd_t) NetError!net.Address {
    var storage: posix.sockaddr.storage = undefined;
    var len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
    const sa: *posix.sockaddr = @ptrCast(&storage);
    posix.getsockname(fd, sa, &len) catch return NetError.BindFailed;
    return net.Address.initPosix(@alignCast(sa));
}

fn compactRecvBuf(c: *io_mod.ConnState, consumed: u32) void {
    const tail = c.recv_pos - consumed;
    if (tail > 0) {
        std.mem.copyForwards(u8, c.recv_buf[0..tail], c.recv_buf[consumed .. consumed + tail]);
    }
    c.recv_pos = tail;
}

/// Cheap header-only parse: extract the `from` id from a raft_codec payload.
/// Mirrors raft_transport.zig's InMemRouter.decodeFromOnly.
/// Layout skip: version(1)+type(1)+term(8)+from_uuid(16)+to_uuid(16)+cluster_id(8) = 50 bytes.
fn decodeFromOnly(bytes: []const u8) ![]const u8 {
    const skip: usize = 1 + 1 + 8 + 16 + 16 + 8;
    if (bytes.len < skip + 1) return error.Short;
    const from_len = bytes[skip];
    if (from_len == 0 or from_len > codec.max_id_len) return error.Bad;
    if (bytes.len < skip + 1 + from_len) return error.Short;
    return bytes[skip + 1 .. skip + 1 + from_len];
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const raft = @import("raft");
const Message = raft.messages.Message;

fn loopback(port: u16) net.Address {
    return net.Address.parseIp("127.0.0.1", port) catch unreachable;
}

const test_buf_size: u32 = 64 * 1024; // 64 KiB — plenty for non-snapshot test traffic.

test "raft_net: init and bind to ephemeral port" {
    var pn = try PeerNet.init(testing.allocator, .{
        .self_id = "n1",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
    });
    defer pn.deinit();
    const bound = pn.boundAddress();
    try testing.expect(bound.getPort() != 0);
    try testing.expectEqualStrings("n1", pn.selfId());
}

test "raft_net: registerPeer enforces table limits" {
    var pn = try PeerNet.init(testing.allocator, .{
        .self_id = "self",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
    });
    defer pn.deinit();
    const a = loopback(1);
    try pn.registerPeer("p1", a);
    try testing.expectError(NetError.AlreadyRegistered, pn.registerPeer("p1", a));
    var i: u8 = 1;
    while (i < max_peers) : (i += 1) {
        var idbuf: [4]u8 = undefined;
        const id = std.fmt.bufPrint(&idbuf, "p{d}", .{i + 1}) catch unreachable;
        try pn.registerPeer(id, a);
    }
    try testing.expectError(NetError.PeerTableFull, pn.registerPeer("overflow", a));
}

test "raft_net: send to unknown peer drops, increments counter" {
    var pn = try PeerNet.init(testing.allocator, .{
        .self_id = "n1",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
    });
    defer pn.deinit();
    const ok = pn.enqueueSend("ghost", "payload");
    try testing.expect(!ok);
    try testing.expectEqual(@as(u64, 1), pn.drops_unknown_peer);
}

test "raft_net: decodeFromOnly extracts id" {
    const msg = Message{
        .type_ = .append_entries,
        .from = "leader-x",
        .to = "follower",
        .term = 5,
        .from_uuid = 0xDEAD_BEEF_CAFE_F00D_DEAD_BEEF_CAFE_F00D,
        .to_uuid = 0,
        .cluster_id = 0xC0FFEE,
    };
    var buf: [256]u8 = undefined;
    const n = try codec.encode(msg, &buf);
    const from = try decodeFromOnly(buf[0..n]);
    try testing.expectEqualStrings("leader-x", from);
}

// --- Loopback peer-to-peer round-trip --------------------------------------

test "raft_net: two-peer loopback delivers a frame" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pn1 = try PeerNet.init(testing.allocator, .{
        .self_id = "n1",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
    });
    defer pn1.deinit();
    var pn2 = try PeerNet.init(testing.allocator, .{
        .self_id = "n2",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
    });
    defer pn2.deinit();

    try pn1.registerPeer("n2", pn2.boundAddress());
    try pn2.registerPeer("n1", pn1.boundAddress());

    var t1 = try raft_transport_mod.Transport.init(testing.allocator);
    defer t1.deinit();
    var t2 = try raft_transport_mod.Transport.init(testing.allocator);
    defer t2.deinit();
    pn1.install(&t1);
    pn2.install(&t2);

    // Encode a small heartbeat from n1 → n2 and ask raft_transport to emit it.
    const msg = Message{
        .type_ = .append_entries,
        .from = "n1",
        .to = "n2",
        .term = 1,
        .leader_commit = 7,
    };
    // Use the transport's send vtable so PeerNet's bridge gets exercised.
    t1.transport().send("n2", msg);

    // Drive both ticks until n2's transport surfaces the inbound message,
    // or 2 s elapsed.
    const start = std.time.nanoTimestamp();
    var got: ?raft.transport.Incoming = null;
    while (std.time.nanoTimestamp() - start < 2 * std.time.ns_per_s) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        pn1.tick(now, &t1);
        pn2.tick(now, &t2);
        if (t2.transport().recv()) |inc| {
            got = inc;
            break;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(got != null);
    try testing.expectEqualStrings("n1", got.?.from);
    try testing.expectEqualStrings("n2", got.?.msg.to);
    try testing.expectEqual(@as(u64, 7), got.?.msg.leader_commit);
}

// --- 3-node end-to-end over real TCP ---------------------------------------
//
// Mirrors the InMemRouter-driven test in raft_runtime.zig:
// "runtime: 3-node propose → commit → apply → completion", but each node
// has its own Talon DB and PeerNets are wired over loopback TCP. Verifies
// that the Runtime + raft_transport + PeerNet stack can elect a leader,
// commit a proposal, and apply it on every node's FSM.

const talon = @import("talon");
const raft_runtime_mod = @import("raft_runtime.zig");
const Runtime = raft_runtime_mod.Runtime;
const PeerSpec = raft.PeerSpec;
const Mutation = @import("kv.zig").Mutation;
const Completion = @import("raft_batcher.zig").Completion;

const TickCounter = struct {
    successes: usize = 0,
    failures: usize = 0,
    fn cb(ctx: *anyopaque, success: bool) void {
        const self: *TickCounter = @ptrCast(@alignCast(ctx));
        if (success) self.successes += 1 else self.failures += 1;
    }
    fn completion(self: *TickCounter) Completion {
        return .{ .ctx = @ptrCast(self), .on_complete = cb };
    }
};

fn synthUuid(id: []const u8) u128 {
    var h: u128 = 0xcbf29ce484222325cbf29ce484222325;
    for (id) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return if (h == 0) 1 else h;
}

const test_cluster_id: u64 = 0xC0FFEE_BEEF;

fn openFreshDb(allocator: std.mem.Allocator, path: []const u8) !*talon.DB {
    std.fs.cwd().deleteFile(path) catch {};
    var vlog_buf: [256]u8 = undefined;
    const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{path}) catch unreachable;
    std.fs.cwd().deleteFile(vlog_path) catch {};
    return try talon.DB.open(allocator, path, .{});
}

fn cleanupDbFiles(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    var vlog_buf: [256]u8 = undefined;
    const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{path}) catch unreachable;
    std.fs.cwd().deleteFile(vlog_path) catch {};
}

test "raft_net: 3-node TCP cluster — election + propose + commit + apply" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Election timeouts are 200–400 ms here; the test budget is 8 s wall-clock,
    // which is comfortable for loopback TCP on any reasonable CI host.

    const path1 = "/tmp/corvo-rnet-3n-1";
    const path2 = "/tmp/corvo-rnet-3n-2";
    const path3 = "/tmp/corvo-rnet-3n-3";
    const db1 = try openFreshDb(testing.allocator, path1);
    const db2 = try openFreshDb(testing.allocator, path2);
    const db3 = try openFreshDb(testing.allocator, path3);
    defer {
        db1.close();
        db2.close();
        db3.close();
        cleanupDbFiles(path1);
        cleanupDbFiles(path2);
        cleanupDbFiles(path3);
    }

    var pn1 = try PeerNet.init(testing.allocator, .{
        .self_id = "n1",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
    });
    defer pn1.deinit();
    var pn2 = try PeerNet.init(testing.allocator, .{
        .self_id = "n2",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
    });
    defer pn2.deinit();
    var pn3 = try PeerNet.init(testing.allocator, .{
        .self_id = "n3",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
    });
    defer pn3.deinit();

    try pn1.registerPeer("n2", pn2.boundAddress());
    try pn1.registerPeer("n3", pn3.boundAddress());
    try pn2.registerPeer("n1", pn1.boundAddress());
    try pn2.registerPeer("n3", pn3.boundAddress());
    try pn3.registerPeer("n1", pn1.boundAddress());
    try pn3.registerPeer("n2", pn2.boundAddress());

    const peers1 = [_]PeerSpec{
        .{ .id = "n2", .uuid = synthUuid("n2") },
        .{ .id = "n3", .uuid = synthUuid("n3") },
    };
    const peers2 = [_]PeerSpec{
        .{ .id = "n1", .uuid = synthUuid("n1") },
        .{ .id = "n3", .uuid = synthUuid("n3") },
    };
    const peers3 = [_]PeerSpec{
        .{ .id = "n1", .uuid = synthUuid("n1") },
        .{ .id = "n2", .uuid = synthUuid("n2") },
    };

    // Real-time election timeouts (ns). Heartbeat 50 ms, election 200–400 ms.
    const cfg = raft.Config{
        .election_timeout_min = 200_000_000,
        .election_timeout_max = 400_000_000,
        .heartbeat_interval = 50_000_000,
    };
    var rt1 = try Runtime.init(testing.allocator, db1, .{
        .node_id = "n1",
        .instance_uuid = synthUuid("n1"),
        .cluster_id = test_cluster_id,
        .peers = &peers1,
        .raft_config = cfg,
    });
    defer rt1.deinit();
    var rt2 = try Runtime.init(testing.allocator, db2, .{
        .node_id = "n2",
        .instance_uuid = synthUuid("n2"),
        .cluster_id = test_cluster_id,
        .peers = &peers2,
        .raft_config = cfg,
    });
    defer rt2.deinit();
    var rt3 = try Runtime.init(testing.allocator, db3, .{
        .node_id = "n3",
        .instance_uuid = synthUuid("n3"),
        .cluster_id = test_cluster_id,
        .peers = &peers3,
        .raft_config = cfg,
    });
    defer rt3.deinit();

    // Wire send hooks: each Runtime's transport now routes through its PeerNet.
    pn1.install(&rt1.transport);
    pn2.install(&rt2.transport);
    pn3.install(&rt3.transport);

    // ----- Phase 1: drive ticks until a leader emerges (≤ 4 s) -----
    const elect_deadline_ns = std.time.nanoTimestamp() + 4 * std.time.ns_per_s;
    var leader: ?*Runtime = null;
    while (leader == null and std.time.nanoTimestamp() < elect_deadline_ns) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        pn1.tick(now, &rt1.transport);
        pn2.tick(now, &rt2.transport);
        pn3.tick(now, &rt3.transport);
        try rt1.tick(now);
        try rt2.tick(now);
        try rt3.tick(now);
        if (rt1.node.isLeader()) leader = &rt1;
        if (rt2.node.isLeader()) leader = &rt2;
        if (rt3.node.isLeader()) leader = &rt3;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(leader != null);

    // ----- Phase 2: propose a mutation, wait for commit + apply on leader -----
    var counter = TickCounter{};
    const muts = [_]Mutation{
        .{ .op = .set, .key = "rnet:1", .value = "alpha" },
        .{ .op = .set, .key = "rnet:2", .value = "beta" },
    };
    try leader.?.propose(&muts, counter.completion());

    const commit_deadline_ns = std.time.nanoTimestamp() + 4 * std.time.ns_per_s;
    while (counter.successes == 0 and std.time.nanoTimestamp() < commit_deadline_ns) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        pn1.tick(now, &rt1.transport);
        pn2.tick(now, &rt2.transport);
        pn3.tick(now, &rt3.transport);
        try rt1.tick(now);
        try rt2.tick(now);
        try rt3.tick(now);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 1), counter.successes);

    var buf: [16]u8 = undefined;
    const got = (try leader.?.db.getInto("rnet:1", &buf)).?;
    try testing.expectEqualStrings("alpha", got);

    // ----- Phase 3: drive a bit longer; followers should also apply -----
    const apply_deadline_ns = std.time.nanoTimestamp() + 4 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < apply_deadline_ns) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        pn1.tick(now, &rt1.transport);
        pn2.tick(now, &rt2.transport);
        pn3.tick(now, &rt3.transport);
        try rt1.tick(now);
        try rt2.tick(now);
        try rt3.tick(now);
        if (rt1.fsm.lastApplied() >= 1 and
            rt2.fsm.lastApplied() >= 1 and
            rt3.fsm.lastApplied() >= 1) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expect(rt1.fsm.lastApplied() >= 1);
    try testing.expect(rt2.fsm.lastApplied() >= 1);
    try testing.expect(rt3.fsm.lastApplied() >= 1);
}
