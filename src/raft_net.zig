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
//! Every connection runs an HMAC-SHA256 challenge-response handshake
//! before any frame flows in either direction (see "Cluster handshake
//! auth" below). The handshake always exchanges and enforces the
//! shared-config hash; a configured cluster secret additionally
//! authenticates the peers.
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
    /// Shared cluster secret keying the handshake HMAC. Every peer connection
    /// runs the challenge-response handshake before any frame is accepted or
    /// sent; when the secret is non-empty the tags also prove the peer knows
    /// it, so an unauthenticated party on the network can't inject raft
    /// messages or receive log data. Empty = handshake still runs (it carries
    /// the config-hash check) but provides no authentication — tests,
    /// fully-trusted networks.
    cluster_secret: []const u8 = "",
    /// config.zig clusterHash() — the shared cluster params every voter must
    /// agree on. Exchanged inside the handshake on every connection,
    /// secret or not; a peer whose hash differs is refused (it would diverge
    /// on replicated maintenance).
    config_hash: u64 = 0,
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
// Cluster handshake auth (HMAC-SHA256 challenge-response)
// ============================================================================
//
// Mirrors the PBR transport's handshake, adapted to the async state machine
// and made mutual — raft frames carry log data, so the connector must also
// verify the acceptor before shipping anything. The exchange also carries each
// side's config hash (config.zig clusterHash() over the shared cluster params)
// so a misconfigured node is turned away before it can replicate or vote:
//
//   acceptor  → connector : nonce_a (32 B challenge)
//   connector → acceptor  : nonce_c (32 B) ++ cfg_c (8 B) ++ HMAC(secret, nonce_a ++ cfg_c) (32 B)
//   acceptor  → connector : cfg_a (8 B) ++ HMAC(secret, nonce_c ++ cfg_a) (32 B ack)
//
// Each side verifies the tag over (its own nonce ++ the peer's config hash)
// with a constant-time compare — proving the peer knows the secret AND binding
// the config hash to the HMAC'd material so a man-in-the-middle can't rewrite
// it to force a match. It then checks the peer's config hash equals its own; a
// mismatch means the two nodes would diverge on replicated maintenance (e.g. a
// shorter purge retention that, on failover, deletes terminal jobs through the
// raft log), so the connection is refused (`config_hash_rejects`) and stays
// refused on every 100 ms reconnect. The handshake runs on EVERY connection,
// secret or not: the misconfiguration it catches is an operator typo, which
// needs no attacker. With an empty secret the HMAC (empty key) provides no
// authentication, but it still transports and binds the config hash — all the
// benign-misconfig case needs. Production clusters set --cluster-secret, which
// upgrades the same tags to peer authentication.
//
// Handshake bytes come from an unauthenticated peer (trust boundary): any
// mismatch or protocol violation closes the connection and bumps
// `auth_rejects` (or `config_hash_rejects`) — never an assert.

/// Cap on the shared secret copied into PeerNet at init.
pub const max_secret_len: usize = 128;

const hs_nonce_len: u32 = 32;
const hs_cfg_len: u32 = 8; // config hash: u64 big-endian
const hs_tag_len: u32 = 32; // HMAC-SHA256 output length
/// connector → acceptor: nonce_c ++ cfg_c ++ tag.
const hs_response_len: u32 = hs_nonce_len + hs_cfg_len + hs_tag_len;
/// acceptor → connector: cfg_a ++ tag.
const hs_ack_len: u32 = hs_cfg_len + hs_tag_len;

/// HMAC-SHA256 over (nonce ++ config_hash_be). Binding the config hash to the
/// tag is what stops a man-in-the-middle from rewriting it to force a match:
/// the tag only verifies if the hash the peer committed to is unchanged.
fn computeAuthTag(secret: []const u8, nonce: []const u8, config_hash: u64) [hs_tag_len]u8 {
    check(nonce.len == hs_nonce_len, "auth nonce len {d}", .{nonce.len});
    var material: [hs_nonce_len + hs_cfg_len]u8 = undefined;
    @memcpy(material[0..hs_nonce_len], nonce[0..hs_nonce_len]);
    std.mem.writeInt(u64, material[hs_nonce_len..][0..hs_cfg_len], config_hash, .big);
    var tag: [hs_tag_len]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&tag, &material, secret);
    return tag;
}

fn verifyAuthTag(secret: []const u8, nonce: []const u8, config_hash: u64, tag: []const u8) bool {
    if (tag.len != hs_tag_len) return false;
    const expected = computeAuthTag(secret, nonce, config_hash);
    var diff: u8 = 0;
    for (expected, tag[0..hs_tag_len]) |x, y| diff |= x ^ y; // constant-time
    return diff == 0;
}

/// Serialize the acceptor's ack (cfg_a ++ tag) into `send_buf`. Shared by the
/// immediate and parked (send_done) ack paths so the wire layout is defined once.
fn writeAck(send_buf: []u8, config_hash: u64, tag: [hs_tag_len]u8) void {
    std.mem.writeInt(u64, send_buf[0..hs_cfg_len], config_hash, .big);
    @memcpy(send_buf[hs_cfg_len..hs_ack_len], &tag);
}

// ============================================================================
// Per-peer + per-conn state
// ============================================================================

const OutPhase = enum { disconnected, connecting, authenticating, connected };
const ConnRole = enum { unused, outbound, inbound };

/// Per-connection handshake progress. Sends are strictly sequenced through
/// send_done completions — the io backend allows one in-flight send per conn.
const AuthState = enum {
    /// Handshake complete — frames may flow.
    authenticated,
    /// Outbound: connected, waiting for the acceptor's 32-byte challenge.
    awaiting_challenge,
    /// Outbound: nonce+cfg+tag response queued/sent, waiting for the 40-byte ack.
    awaiting_ack,
    /// Inbound: challenge queued/sent, waiting for the 72-byte nonce+cfg+tag response.
    awaiting_response,
    /// Inbound: response verified while the challenge send was still in
    /// flight; the ack tag is parked in `hs_buf` until send_done.
    ack_pending,
};

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
    /// Handshake progress. Every connection handshakes (empty secret
    /// included); the default never grants access.
    auth: AuthState = .awaiting_challenge,
    /// Own challenge nonce while awaiting the peer's tag. On the acceptor it
    /// is reused to park the outgoing ack tag in the `.ack_pending` state
    /// (nonce and tag are both 32 bytes).
    hs_buf: [hs_nonce_len]u8 = undefined,
    /// Inbound only: the challenge send has drained, so `send_buf` is free
    /// for the ack tag.
    challenge_sent: bool = false,
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

    /// Shared cluster secret copied at init. Keys the handshake HMAC; zero
    /// length = no authentication (the handshake still runs and enforces the
    /// config hash).
    secret_buf: [max_secret_len]u8 = undefined,
    secret_len: u8 = 0,

    /// This node's shared-config hash (config.zig clusterHash()). Sent in the
    /// handshake and compared against each peer's; a mismatch refuses the peer.
    config_hash: u64 = 0,

    drops_unknown_peer: u64 = 0,
    drops_outbox_full: u64 = 0,
    drops_bad_frame: u64 = 0,
    /// Connections torn down for failing (or violating) the auth handshake.
    auth_rejects: u64 = 0,
    /// Connections torn down because the peer's config hash differs from ours
    /// (shared cluster params diverge). Grows on every reconnect while the
    /// misconfiguration persists.
    config_hash_rejects: u64 = 0,
    /// One-shot guard so the config-mismatch log fires once, not on every
    /// 100 ms reconnect attempt (the handshake is not a hot path, but a stuck
    /// misconfiguration would otherwise flood the log forever).
    config_mismatch_logged: bool = false,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !PeerNet {
        check(cfg.self_id.len > 0 and cfg.self_id.len <= codec.max_id_len, "self_id len {d}", .{cfg.self_id.len});
        check(cfg.recv_buf_size >= frame_len_prefix + 64, "recv_buf_size too small: {d}", .{cfg.recv_buf_size});
        check(cfg.cluster_secret.len <= max_secret_len, "cluster_secret len {d}", .{cfg.cluster_secret.len});

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
        @memcpy(pn.secret_buf[0..cfg.cluster_secret.len], cfg.cluster_secret);
        pn.secret_len = @intCast(cfg.cluster_secret.len);
        pn.config_hash = cfg.config_hash;

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

    fn secret(self: *const PeerNet) []const u8 {
        return self.secret_buf[0..self.secret_len];
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
        // Challenge the connector: send our nonce and keep a copy for
        // verifying the response tag. The recv (for the 72-byte response)
        // was already queued by the io backend on accept. Runs even with an
        // empty secret — the handshake carries the config-hash check.
        var info = ConnInfo{ .role = .inbound, .peer_idx = null, .auth = .awaiting_response };
        std.crypto.random.bytes(&info.hs_buf);
        self.conn_info[conn_id] = info;
        const c = self.io.conn(conn_id);
        @memcpy(c.send_buf[0..hs_nonce_len], &info.hs_buf);
        self.io.queueSend(conn_id, hs_nonce_len);
    }

    fn onConnected(self: *PeerNet, conn_id: u16) void {
        check(conn_id < max_conns, "conn_id {d} >= max_conns {d}", .{ conn_id, max_conns });
        const info = &self.conn_info[conn_id];
        if (info.role != .outbound) return;
        const peer_idx = info.peer_idx orelse return;
        const p = &self.peers[peer_idx];
        // Handshake first: no frame leaves until the acceptor's config hash
        // (and, with a secret, its identity) is verified.
        info.auth = .awaiting_challenge;
        p.out_phase = .authenticating;
        self.io.queueRecv(conn_id);
    }

    fn onRecv(self: *PeerNet, conn_id: u16, transport: *RaftTransport) void {
        check(conn_id < max_conns, "conn_id {d} >= max_conns {d}", .{ conn_id, max_conns });
        const info = self.conn_info[conn_id];
        switch (info.auth) {
            .authenticated => {},
            .awaiting_challenge, .awaiting_ack, .awaiting_response, .ack_pending => {
                self.onHandshakeRecv(conn_id);
                return;
            },
        }
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

    // ------------------------------------------------------------------------
    // Handshake completion handling (see "Cluster handshake auth" above)
    // ------------------------------------------------------------------------

    /// Trust boundary: bytes here come from an unauthenticated peer. Anything
    /// unexpected — oversized reads, bad tags, data before the ack — closes
    /// the connection via `rejectConn`; asserts are never used on this input.
    fn onHandshakeRecv(self: *PeerNet, conn_id: u16) void {
        const info = &self.conn_info[conn_id];
        const c = self.io.conn(conn_id);
        switch (info.auth) {
            .authenticated => unreachable, // dispatched to frame parsing in onRecv
            .awaiting_challenge => self.onChallengeRecv(conn_id, info, c),
            .awaiting_ack => self.onAckRecv(conn_id, info, c),
            .awaiting_response => self.onResponseRecv(conn_id, info, c),
            // We haven't acked yet, so no honest connector sends here.
            .ack_pending => self.rejectConn(conn_id),
        }
    }

    /// Outbound: the acceptor's 32-byte challenge. Reply with our own nonce
    /// plus the tag over theirs. The ack recv is queued from send_done, so at
    /// most one io op per direction is ever in flight during the handshake.
    fn onChallengeRecv(self: *PeerNet, conn_id: u16, info: *ConnInfo, c: *io_mod.ConnState) void {
        if (c.recv_pos > hs_nonce_len) {
            self.rejectConn(conn_id);
            return;
        }
        if (c.recv_pos < hs_nonce_len) {
            self.io.queueRecv(conn_id);
            return;
        }
        // Reply nonce_c ++ cfg_c ++ tag, where the tag binds our config hash to
        // proof-of-secret over the acceptor's nonce.
        const tag = computeAuthTag(self.secret(), c.recv_buf[0..hs_nonce_len], self.config_hash);
        std.crypto.random.bytes(&info.hs_buf);
        @memcpy(c.send_buf[0..hs_nonce_len], &info.hs_buf);
        std.mem.writeInt(u64, c.send_buf[hs_nonce_len..][0..hs_cfg_len], self.config_hash, .big);
        @memcpy(c.send_buf[hs_nonce_len + hs_cfg_len ..][0..hs_tag_len], &tag);
        c.recv_pos = 0;
        info.auth = .awaiting_ack;
        self.io.queueSend(conn_id, hs_response_len);
    }

    /// Outbound: the acceptor's 40-byte ack (cfg_a ++ tag over our nonce).
    /// Verify + config match → the connection is up and the outbox may flow.
    fn onAckRecv(self: *PeerNet, conn_id: u16, info: *ConnInfo, c: *io_mod.ConnState) void {
        if (c.recv_pos > hs_ack_len) {
            self.rejectConn(conn_id);
            return;
        }
        if (c.recv_pos < hs_ack_len) {
            self.io.queueRecv(conn_id);
            return;
        }
        // Verify first (proof-of-secret + authenticity of the peer's config
        // hash over our nonce), then require the config hash to match ours.
        const peer_hash = std.mem.readInt(u64, c.recv_buf[0..hs_cfg_len], .big);
        if (!verifyAuthTag(self.secret(), &info.hs_buf, peer_hash, c.recv_buf[hs_cfg_len..hs_ack_len])) {
            self.rejectConn(conn_id);
            return;
        }
        if (peer_hash != self.config_hash) {
            self.rejectConfigMismatch(conn_id, peer_hash);
            return;
        }
        c.recv_pos = 0;
        info.auth = .authenticated;
        const peer_idx = info.peer_idx orelse return;
        const p = &self.peers[peer_idx];
        p.out_phase = .connected;
        // Outbound is send-only from here: no further queueRecv. Peer's
        // reciprocal outbound is our inbound.
        self.tryDispatch(p);
    }

    /// Inbound: the connector's 72-byte nonce+cfg+tag response. Verify their
    /// tag over our challenge, then ack with a tag over their nonce — parked
    /// in `hs_buf` if the challenge send is still in flight (one send at a time).
    fn onResponseRecv(self: *PeerNet, conn_id: u16, info: *ConnInfo, c: *io_mod.ConnState) void {
        if (c.recv_pos > hs_response_len) {
            self.rejectConn(conn_id);
            return;
        }
        if (c.recv_pos < hs_response_len) {
            self.io.queueRecv(conn_id);
            return;
        }
        // Verify the connector's tag over (our nonce ++ its config hash), then
        // require its config hash to match ours before we ack.
        const peer_hash = std.mem.readInt(u64, c.recv_buf[hs_nonce_len..][0..hs_cfg_len], .big);
        if (!verifyAuthTag(self.secret(), &info.hs_buf, peer_hash, c.recv_buf[hs_nonce_len + hs_cfg_len ..][0..hs_tag_len])) {
            self.rejectConn(conn_id);
            return;
        }
        if (peer_hash != self.config_hash) {
            self.rejectConfigMismatch(conn_id, peer_hash);
            return;
        }
        // ack tag proves our secret + binds our config hash over the connector's nonce.
        const ack = computeAuthTag(self.secret(), c.recv_buf[0..hs_nonce_len], self.config_hash);
        c.recv_pos = 0;
        if (info.challenge_sent) {
            writeAck(c.send_buf, self.config_hash, ack);
            info.auth = .authenticated;
            self.io.queueSend(conn_id, hs_ack_len);
        } else {
            info.hs_buf = ack;
            info.auth = .ack_pending;
        }
        self.io.queueRecv(conn_id);
    }

    /// Tear down a connection that failed (or violated) the auth handshake.
    /// `queueClose` frees the slot without emitting a `.closed` completion,
    /// so peer bookkeeping is reset inline (mirrors onClosed).
    fn rejectConn(self: *PeerNet, conn_id: u16) void {
        self.auth_rejects += 1;
        self.teardownConn(conn_id);
    }

    /// Tear down a peer whose config hash differs from ours. The secret checked
    /// out (the tag verified), but the shared cluster params diverge — letting
    /// the node replicate or win an election risks unrecoverable data loss
    /// (e.g. a shorter purge retention purging terminal jobs through the log).
    /// Logged once (the 100 ms reconnect loop would otherwise flood the log);
    /// the reject counter keeps climbing so the mismatch stays observable.
    fn rejectConfigMismatch(self: *PeerNet, conn_id: u16, peer_hash: u64) void {
        self.config_hash_rejects += 1;
        if (!self.config_mismatch_logged) {
            self.config_mismatch_logged = true;
            std.debug.print(
                "raft_net: config hash mismatch — shared cluster params differ " ++
                    "(local=0x{x:0>16}, peer=0x{x:0>16}); refusing peer connection\n",
                .{ self.config_hash, peer_hash },
            );
        }
        self.teardownConn(conn_id);
    }

    /// Shared teardown for a rejected connection (auth failure or config
    /// mismatch): reset outbound peer bookkeeping and close the slot.
    fn teardownConn(self: *PeerNet, conn_id: u16) void {
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
        self.io.queueClose(conn_id);
    }

    fn onSendDone(self: *PeerNet, conn_id: u16) void {
        check(conn_id < max_conns, "conn_id {d} >= max_conns {d}", .{ conn_id, max_conns });
        const info = &self.conn_info[conn_id];
        switch (info.role) {
            .unused => {},
            .inbound => switch (info.auth) {
                // Challenge drained; send_buf is free for the ack tag.
                .awaiting_response => info.challenge_sent = true,
                .ack_pending => {
                    // Response was verified while the challenge was still in
                    // flight; ship the parked ack (cfg_a ++ tag) now.
                    const c = self.io.conn(conn_id);
                    writeAck(c.send_buf, self.config_hash, info.hs_buf);
                    info.auth = .authenticated;
                    info.challenge_sent = true;
                    self.io.queueSend(conn_id, hs_ack_len);
                },
                .authenticated => {}, // ack tag drained; nothing else is sent inbound
                .awaiting_challenge, .awaiting_ack => unreachable, // outbound-only states
            },
            .outbound => switch (info.auth) {
                // Response drained; now await the acceptor's ack tag.
                .awaiting_ack => self.io.queueRecv(conn_id),
                .authenticated => {
                    const peer_idx = info.peer_idx orelse return;
                    const p = &self.peers[peer_idx];
                    p.sending = false;
                    self.tryDispatch(p);
                },
                .awaiting_challenge, .awaiting_response, .ack_pending => unreachable, // no send queued in these states
            },
        }
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

// --- Auth handshake ----------------------------------------------------------

test "raft_net: auth tag compute + constant-time verify" {
    var nonce: [hs_nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce);
    const cfg: u64 = 0xABCD_1234_5678_9ABC;
    const good = computeAuthTag("s3cr3t", &nonce, cfg);
    try testing.expect(verifyAuthTag("s3cr3t", &nonce, cfg, &good));

    // Wrong secret produces a different tag.
    const bad = computeAuthTag("wrong", &nonce, cfg);
    try testing.expect(!verifyAuthTag("s3cr3t", &nonce, cfg, &bad));

    // A different config hash produces a different tag: the hash is bound into
    // the HMAC'd material, so a man-in-the-middle can't rewrite it on the wire
    // to force a match without also invalidating the tag.
    try testing.expect(!verifyAuthTag("s3cr3t", &nonce, cfg +% 1, &good));

    // Wrong nonce fails, and so does a truncated tag.
    var nonce2: [hs_nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce2);
    try testing.expect(!verifyAuthTag("s3cr3t", &nonce2, cfg, &good));
    try testing.expect(!verifyAuthTag("s3cr3t", &nonce, cfg, good[0..16]));
}

const AuthLoopbackOutcome = struct {
    delivered: bool,
    rejects_a: u64,
    rejects_b: u64,
    config_rejects_a: u64,
    config_rejects_b: u64,
};

/// Two PeerNets with independent secrets + config hashes; n1 sends one
/// heartbeat to n2. Drives both ticks for up to `budget_ns` (early exit on
/// delivery) and reports delivery plus each side's auth + config reject counts.
fn runAuthedLoopback(
    secret_a: []const u8,
    secret_b: []const u8,
    hash_a: u64,
    hash_b: u64,
    budget_ns: i128,
) !AuthLoopbackOutcome {
    var pn1 = try PeerNet.init(testing.allocator, .{
        .self_id = "n1",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
        .cluster_secret = secret_a,
        .config_hash = hash_a,
    });
    defer pn1.deinit();
    var pn2 = try PeerNet.init(testing.allocator, .{
        .self_id = "n2",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
        .cluster_secret = secret_b,
        .config_hash = hash_b,
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

    const msg = Message{
        .type_ = .append_entries,
        .from = "n1",
        .to = "n2",
        .term = 1,
        .leader_commit = 7,
    };
    t1.transport().send("n2", msg);

    var delivered = false;
    const start = std.time.nanoTimestamp();
    while (std.time.nanoTimestamp() - start < budget_ns) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        pn1.tick(now, &t1);
        pn2.tick(now, &t2);
        if (t2.transport().recv()) |inc| {
            try testing.expectEqualStrings("n1", inc.from);
            try testing.expectEqual(@as(u64, 7), inc.msg.leader_commit);
            delivered = true;
            break;
        }
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    return .{
        .delivered = delivered,
        .rejects_a = pn1.auth_rejects,
        .rejects_b = pn2.auth_rejects,
        .config_rejects_a = pn1.config_hash_rejects,
        .config_rejects_b = pn2.config_hash_rejects,
    };
}

test "raft_net: handshake success with shared secret and matching config" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const cfg: u64 = 0xC0FFEE_1234_5678;
    const out = try runAuthedLoopback("hunter2-cluster-secret", "hunter2-cluster-secret", cfg, cfg, 5 * std.time.ns_per_s);
    try testing.expect(out.delivered);
    try testing.expectEqual(@as(u64, 0), out.rejects_a);
    try testing.expectEqual(@as(u64, 0), out.rejects_b);
    try testing.expectEqual(@as(u64, 0), out.config_rejects_a);
    try testing.expectEqual(@as(u64, 0), out.config_rejects_b);
}

test "raft_net: wrong secret is rejected" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // 1.5 s budget: connect + handshake round-trips take milliseconds on
    // loopback; the loop runs the full budget since nothing is delivered.
    const out = try runAuthedLoopback("secret-alpha", "secret-bravo", 0, 0, 1_500 * std.time.ns_per_ms);
    try testing.expect(!out.delivered);
    // Each side accepted the other's outbound conn, challenged it, and the
    // response tag failed to verify (reconnects retry, so counts only grow).
    try testing.expect(out.rejects_a >= 1);
    try testing.expect(out.rejects_b >= 1);
    // The tag failed before any config comparison, so nothing is charged to
    // the config-mismatch counter.
    try testing.expectEqual(@as(u64, 0), out.config_rejects_a);
    try testing.expectEqual(@as(u64, 0), out.config_rejects_b);
}

test "raft_net: matching config hashes connect" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Same secret, same config hash (a non-default value) — the added config
    // exchange must not disturb the happy path.
    const cfg: u64 = 0xDEAD_BEEF_F00D_BABE;
    const out = try runAuthedLoopback("shared-secret", "shared-secret", cfg, cfg, 5 * std.time.ns_per_s);
    try testing.expect(out.delivered);
    try testing.expectEqual(@as(u64, 0), out.config_rejects_a);
    try testing.expectEqual(@as(u64, 0), out.config_rejects_b);
}

test "raft_net: mismatched config hashes are refused both directions" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Same secret (so the HMAC verifies) but divergent shared-config hashes.
    // Each node is the acceptor for the other's outbound conn, so BOTH detect
    // the mismatch and refuse — no frame is ever delivered. 1.5 s budget: the
    // handshake resolves in milliseconds and nothing is delivered, so the loop
    // runs the full budget accumulating rejects across reconnects.
    const out = try runAuthedLoopback("shared-secret", "shared-secret", 0x1111_1111, 0x2222_2222, 1_500 * std.time.ns_per_ms);
    try testing.expect(!out.delivered);
    // Refused on both sides (both directions), and it's a config reject, not an
    // auth reject: the secret was correct.
    try testing.expect(out.config_rejects_a >= 1);
    try testing.expect(out.config_rejects_b >= 1);
    try testing.expectEqual(@as(u64, 0), out.rejects_a);
    try testing.expectEqual(@as(u64, 0), out.rejects_b);
}

test "raft_net: empty secret still handshakes and enforces config hash" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // The handshake runs unconditionally: an operator typo needs no attacker,
    // so the config-hash check must not depend on --cluster-secret. With an
    // empty secret the HMAC provides no authentication, but it still
    // transports + binds the config hash.
    {
        // Mismatched hashes are refused even without a secret.
        const out = try runAuthedLoopback("", "", 0x1111_1111, 0x2222_2222, 1_500 * std.time.ns_per_ms);
        try testing.expect(!out.delivered);
        try testing.expect(out.config_rejects_a >= 1);
        try testing.expect(out.config_rejects_b >= 1);
        try testing.expectEqual(@as(u64, 0), out.rejects_a);
        try testing.expectEqual(@as(u64, 0), out.rejects_b);
    }
    {
        // Matching hashes connect without a secret (single-node dev / tests).
        const out = try runAuthedLoopback("", "", 0x3333_3333, 0x3333_3333, 5 * std.time.ns_per_s);
        try testing.expect(out.delivered);
        try testing.expectEqual(@as(u64, 0), out.rejects_a);
        try testing.expectEqual(@as(u64, 0), out.rejects_b);
        try testing.expectEqual(@as(u64, 0), out.config_rejects_a);
        try testing.expectEqual(@as(u64, 0), out.config_rejects_b);
    }
}

test "raft_net: frames before auth are rejected" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var pn = try PeerNet.init(testing.allocator, .{
        .self_id = "n1",
        .bind_addr = loopback(0),
        .recv_buf_size = test_buf_size,
        .send_buf_size = test_buf_size,
        .cluster_secret = "hunter2-cluster-secret",
    });
    defer pn.deinit();
    var t = try raft_transport_mod.Transport.init(testing.allocator);
    defer t.deinit();
    pn.install(&t);

    // Raw TCP client that skips the handshake and fires framed messages.
    const stream = try net.tcpConnectToAddress(pn.boundAddress());
    defer stream.close();
    const msg = Message{ .type_ = .append_entries, .from = "nx", .to = "n1", .term = 1 };
    var payload: [256]u8 = undefined;
    const n = try codec.encode(msg, &payload);
    var framed: [4 + 256]u8 = undefined;
    std.mem.writeInt(u32, framed[0..4], @intCast(n), .big);
    @memcpy(framed[4..][0..n], payload[0..n]);
    // Two frames back-to-back guarantees the bytes exceed the 72-byte
    // handshake response the acceptor is waiting for → reject + close.
    try stream.writeAll(framed[0 .. 4 + n]);
    try stream.writeAll(framed[0 .. 4 + n]);

    const start = std.time.nanoTimestamp();
    while (pn.auth_rejects == 0 and std.time.nanoTimestamp() - start < 5 * std.time.ns_per_s) {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        pn.tick(now, &t);
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }
    try testing.expectEqual(@as(u64, 1), pn.auth_rejects);
    // Nothing reached the raft transport.
    try testing.expect(t.transport().recv() == null);
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
    try leader.?.propose(&muts, counter.completion(), false);

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
