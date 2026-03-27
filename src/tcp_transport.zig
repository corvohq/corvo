//! TCP Transport — real network layer for primary-backup replication.
//!
//! Implements the same send/recvOne interface as InMemTransport but
//! over TCP connections. Used in production cluster mode.

const std = @import("std");
const net = std.net;
const assert = @import("assert.zig");
const transport = @import("transport.zig");
const election_mod = @import("election.zig");
const repl_mod = @import("replicator.zig");
const Msg = transport.Msg;
const IncomingMsg = transport.IncomingMsg;
const ElectionMsg = transport.ElectionMsg;
const ReplMsg = transport.ReplMsg;

// ============================================================================
// TCP_CORK optimization for small message batching
// ============================================================================

// TCP_CORK (Linux-specific, IPPROTO_TCP level option 3) defers sending until
// uncorked or the MSS is filled. When multiple small messages are sent in
// quick succession (election rounds, ack bursts), this coalesces them into
// fewer TCP segments. TCP_CORK takes precedence over TCP_NODELAY while set.
const TCP_CORK = 3;

/// Threshold below which we apply TCP_CORK. Election messages are 31 bytes
/// (4-byte frame header + 27-byte payload), acks are 28 bytes. Anything
/// under 128 bytes is a "small" control message worth coalescing.
const CORK_THRESHOLD: usize = 128;

fn setCork(stream: net.Stream, enabled: bool) void {
    if (comptime @import("builtin").os.tag != .linux) return;
    const val: c_int = if (enabled) 1 else 0;
    std.posix.setsockopt(stream.handle, std.posix.IPPROTO.TCP, TCP_CORK, &std.mem.toBytes(val)) catch {};
}

// ============================================================================
// Wire format for transport messages
// ============================================================================

// Frame: [total_len:4LE][msg_type:1][payload...]
// msg_type: 0x01 = election, 0x02 = replication
const FRAME_HEADER = 5;
const MSG_ELECTION: u8 = 0x01;
const MSG_REPL: u8 = 0x02;

// ============================================================================
// TcpTransport
// ============================================================================

pub const TcpTransport = struct {
    node_id: []const u8,
    allocator: std.mem.Allocator,

    // Listening for incoming connections
    listener: ?net.Server = null,
    listen_thread: ?std.Thread = null,

    // Outgoing connections to peers (node_id → stream)
    peers: std.StringHashMap(PeerConn),
    peers_mu: std.Thread.Mutex = .{},

    // Inbox ring buffer (same pattern as InMemTransport)
    inbox: [256]IncomingMsg = undefined,
    inbox_from_bufs: [256][32]u8 = undefined, // owned copies of from strings
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    inbox_mu: std.Thread.Mutex = .{},

    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closed: bool = false,

    /// Fast-path callback for replication acks — called directly from TCP
    /// receive thread, bypassing the inbox. This eliminates the tick-loop
    /// latency (up to 50ms) that kills sync replication throughput.
    ack_callback: ?*const fn (from: []const u8, epoch: u64, seq: u64) void = null,

    // Replication data buffers for inbox (owned copies)
    repl_data_bufs: [256][]u8 = [_][]u8{""} ** 256,

    const PeerConn = struct {
        stream: ?net.Stream = null,
        addr: net.Address,
    };

    pub fn init(allocator: std.mem.Allocator, node_id: []const u8) TcpTransport {
        return .{
            .node_id = node_id,
            .allocator = allocator,
            .peers = std.StringHashMap(PeerConn).init(allocator),
        };
    }

    pub fn deinit(self: *TcpTransport) void {
        self.stop();
        // Free repl data buffers
        for (&self.repl_data_bufs) |*buf| {
            if (buf.len > 0) {
                self.allocator.free(buf.*);
                buf.* = "";
            }
        }
        self.peers.deinit();
    }

    /// Add a peer node with its address.
    pub fn addPeer(self: *TcpTransport, node_id: []const u8, addr: net.Address) void {
        self.peers_mu.lock();
        defer self.peers_mu.unlock();
        self.peers.put(node_id, .{ .addr = addr }) catch {};
    }

    /// Start listening for incoming connections.
    pub fn start(self: *TcpTransport, bind_addr: net.Address) !void {
        self.listener = try bind_addr.listen(.{ .reuse_address = true });
        self.running.store(true, .monotonic);
        self.listen_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *TcpTransport) void {
        self.running.store(false, .monotonic);
        self.closed = true;
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }
        if (self.listen_thread) |t| {
            t.join();
            self.listen_thread = null;
        }
        // Close peer connections
        self.peers_mu.lock();
        defer self.peers_mu.unlock();
        var iter = self.peers.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.stream) |s| s.close();
            entry.value_ptr.stream = null;
        }
    }

    /// Send a message to a peer.
    pub fn send(self: *TcpTransport, to: []const u8, msg: Msg) bool {
        if (self.closed) return false;

        // Check if we have a connection (quick lock).
        self.peers_mu.lock();
        const peer = self.peers.getPtr(to);
        if (peer == null) {
            self.peers_mu.unlock();
            return false;
        }
        const need_connect = peer.?.stream == null;
        const addr = peer.?.addr;
        if (!need_connect) {
            const stream = peer.?.stream.?;
            self.peers_mu.unlock();
            return self.sendOnStream(stream, to, msg);
        }
        self.peers_mu.unlock();

        // Connect outside the lock so other sends aren't blocked.
        if (need_connect) {
            const new_stream = net.tcpConnectToAddress(addr) catch return false;

            // Set TCP_NODELAY — critical for small election messages.
            // Without this, Nagle's algorithm delays 19-byte messages by up to 200ms.
            const fd = new_stream.handle;
            const TCP_NODELAY = 1;
            std.posix.setsockopt(fd, std.posix.IPPROTO.TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

            // Handshake: send our node_id.
            var id_len_buf: [2]u8 = undefined;
            std.mem.writeInt(u16, &id_len_buf, @intCast(self.node_id.len), .little);
            new_stream.writeAll(&id_len_buf) catch {
                new_stream.close();
                return false;
            };
            new_stream.writeAll(self.node_id) catch {
                new_stream.close();
                return false;
            };

            // Store connection.
            self.peers_mu.lock();
            if (self.peers.getPtr(to)) |p| {
                if (p.stream) |old| old.close(); // close stale if race
                p.stream = new_stream;
            }
            self.peers_mu.unlock();

            return self.sendOnStream(new_stream, to, msg);
        }
        return false;
    }

    fn sendOnStream(self: *TcpTransport, stream: net.Stream, to: []const u8, msg: Msg) bool {

        const frame_size: usize = 4 + switch (msg) {
            .election => @as(usize, 27),
            .repl => |r| @as(usize, 24) + r.data.len,
        };

        var stack_buf: [256]u8 = undefined;
        const need_heap = frame_size > stack_buf.len;
        const buf: []u8 = if (!need_heap)
            &stack_buf
        else
            self.allocator.alloc(u8, frame_size) catch return false;
        defer if (need_heap) self.allocator.free(buf);

        const frame = encodeMsg(buf, msg);

        // TCP_CORK for small messages: cork before write, uncork after.
        // This lets the kernel coalesce multiple small sends (election
        // heartbeats, ack bursts) into a single TCP segment. The uncork
        // triggers an immediate flush, so latency is bounded to the time
        // between cork and uncork (just the writeAll call). TCP_CORK
        // overrides TCP_NODELAY while set, which is the desired behavior —
        // we want batching for small rapid-fire messages.
        const use_cork = frame.len <= CORK_THRESHOLD;
        if (use_cork) setCork(stream, true);
        defer if (use_cork) setCork(stream, false);

        stream.writeAll(frame) catch {
            self.peers_mu.lock();
            if (self.peers.getPtr(to)) |p| {
                p.stream = null;
            }
            self.peers_mu.unlock();
            return false;
        };
        return true;
    }

    /// Read one pending message. Returns null if empty.
    /// Repl data is owned by the caller until the slot is reused (lazy free in pushInbox).
    pub fn recvOne(self: *TcpTransport) ?IncomingMsg {
        self.inbox_mu.lock();
        defer self.inbox_mu.unlock();

        if (self.count == 0) return null;

        const msg = self.inbox[self.head];
        // Don't free repl data here — caller may still be using msg.repl.data.
        // Data will be freed lazily when this slot is reused in pushInbox.
        self.head = (self.head + 1) % 256;
        self.count -= 1;
        return msg;
    }

    pub fn pending(self: *TcpTransport) usize {
        self.inbox_mu.lock();
        defer self.inbox_mu.unlock();
        return self.count;
    }

    // ========================================================================
    // Internal
    // ========================================================================

    fn acceptLoop(self: *TcpTransport) void {
        while (self.running.load(.monotonic)) {
            if (self.listener) |*l| {
                const conn = l.accept() catch {
                    if (!self.running.load(.monotonic)) return;
                    continue;
                };
                // TCP_NODELAY on accepted connections too.
                const TCP_NODELAY = 1;
                std.posix.setsockopt(conn.stream.handle, std.posix.IPPROTO.TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
                _ = std.Thread.spawn(.{}, handlePeerConn, .{ self, conn.stream }) catch {
                    conn.stream.close();
                    continue;
                };
            } else return;
        }
    }

    fn handlePeerConn(self: *TcpTransport, stream: net.Stream) void {
        defer stream.close();

        // First message identifies the peer (node_id as length-prefixed string)
        var id_len_buf: [2]u8 = undefined;
        readExact(stream, &id_len_buf) catch return;
        const id_len = std.mem.readInt(u16, &id_len_buf, .little);
        if (id_len > 64) return;
        var id_buf: [64]u8 = undefined;
        readExact(stream, id_buf[0..id_len]) catch return;
        const from_id = id_buf[0..id_len];

        var stack_frame_buf: [256]u8 = undefined;

        while (self.running.load(.monotonic)) {
            // Read frame header: [total_len:4LE]
            var len_buf: [4]u8 = undefined;
            readExact(stream, &len_buf) catch return;
            const total_len = std.mem.readInt(u32, &len_buf, .little);
            if (total_len < 1 or total_len > 4 * 1024 * 1024) return; // max 4MB

            const need_heap_recv = total_len > stack_frame_buf.len;
            const frame_buf: []u8 = if (!need_heap_recv)
                &stack_frame_buf
            else
                self.allocator.alloc(u8, total_len) catch return;

            readExact(stream, frame_buf[0..total_len]) catch {
                if (need_heap_recv) self.allocator.free(frame_buf);
                return;
            };

            const decoded = decodeMsg(frame_buf[0..total_len], self.allocator) orelse {
                if (need_heap_recv) self.allocator.free(frame_buf);
                continue;
            };
            if (need_heap_recv) self.allocator.free(frame_buf);

            // Fast-path: route acks directly to replicator, bypassing inbox.
            // This eliminates 10-50ms tick-loop latency for sync replication.
            switch (decoded.msg) {
                .repl => |r| {
                    if (r.type_ == .ack) {
                        if (self.ack_callback) |cb| {
                            cb(from_id, r.epoch, r.seq);
                            if (decoded.data) |d| self.allocator.free(d);
                            continue; // Don't push to inbox — already handled.
                        }
                    }
                },
                else => {},
            }

            self.pushInbox(from_id, decoded.msg, decoded.data);
        }
    }

    fn pushInbox(self: *TcpTransport, from: []const u8, msg: Msg, repl_data: ?[]u8) void {
        self.inbox_mu.lock();
        defer self.inbox_mu.unlock();

        if (self.count >= 256) {
            // Inbox full — drop. Free repl_data if owned.
            if (repl_data) |d| self.allocator.free(d);
            return;
        }

        // Lazy-free: free old repl data from this slot (from a previous consumed entry).
        if (self.repl_data_bufs[self.tail].len > 0) {
            self.allocator.free(self.repl_data_bufs[self.tail]);
            self.repl_data_bufs[self.tail] = "";
        }

        // Copy from_id into owned buffer
        const fl = @min(from.len, self.inbox_from_bufs[self.tail].len);
        @memcpy(self.inbox_from_bufs[self.tail][0..fl], from[0..fl]);

        self.inbox[self.tail] = .{
            .from = self.inbox_from_bufs[self.tail][0..fl],
            .msg = msg,
        };
        // Store owned repl data
        if (repl_data) |d| {
            self.repl_data_bufs[self.tail] = d;
            // Update the msg's data pointer to the owned copy
            switch (self.inbox[self.tail].msg) {
                .repl => |*r| r.data = d,
                else => {},
            }
        } else {
            self.repl_data_bufs[self.tail] = "";
        }
        self.tail = (self.tail + 1) % 256;
        self.count += 1;
    }

    fn readExact(stream: net.Stream, buf: []u8) !void {
        var filled: usize = 0;
        while (filled < buf.len) {
            const n = stream.read(buf[filled..]) catch return error.ConnectionClosed;
            if (n == 0) return error.ConnectionClosed;
            filled += n;
        }
    }

    const DecodedMsg = struct {
        msg: Msg,
        data: ?[]u8, // owned allocation for repl data
    };

    fn encodeMsg(buf: []u8, msg: Msg) []const u8 {
        var pos: usize = 4; // skip total_len field
        switch (msg) {
            .election => |e| {
                buf[pos] = MSG_ELECTION;
                pos += 1;
                buf[pos] = @intFromEnum(e.type_);
                pos += 1;
                std.mem.writeInt(u64, buf[pos..][0..8], e.epoch, .little);
                pos += 8;
                buf[pos] = if (e.granted) 1 else 0;
                pos += 1;
                std.mem.writeInt(u64, buf[pos..][0..8], e.last_log_seq, .little);
                pos += 8;
                std.mem.writeInt(u64, buf[pos..][0..8], e.config_hash, .little);
                pos += 8;
            },
            .repl => |r| {
                buf[pos] = MSG_REPL;
                pos += 1;
                buf[pos] = @intFromEnum(r.type_);
                pos += 1;
                std.mem.writeInt(u64, buf[pos..][0..8], r.epoch, .little);
                pos += 8;
                std.mem.writeInt(u64, buf[pos..][0..8], r.seq, .little);
                pos += 8;
                std.mem.writeInt(u16, buf[pos..][0..2], r.shard_id, .little);
                pos += 2;
                std.mem.writeInt(u32, buf[pos..][0..4], @intCast(r.data.len), .little);
                pos += 4;
                if (r.data.len > 0) {
                    @memcpy(buf[pos..][0..r.data.len], r.data);
                    pos += r.data.len;
                }
            },
        }
        // Write total_len
        std.mem.writeInt(u32, buf[0..4], @intCast(pos - 4), .little);
        return buf[0..pos];
    }

    fn decodeMsg(data: []const u8, allocator: std.mem.Allocator) ?DecodedMsg {
        if (data.len < 1) return null;

        const msg_type = data[0];
        var pos: usize = 1;

        switch (msg_type) {
            MSG_ELECTION => {
                if (data.len < 27) return null;
                const raw_type = data[pos];
                if (raw_type < 1 or raw_type > 4) return null; // propose=1, vote=2, heartbeat=3, heartbeat_ack=4
                const type_: election_mod.MessageType = @enumFromInt(raw_type);
                pos += 1;
                const epoch = std.mem.readInt(u64, data[pos..][0..8], .little);
                pos += 8;
                const granted = data[pos] != 0;
                pos += 1;
                const last_log_seq = std.mem.readInt(u64, data[pos..][0..8], .little);
                pos += 8;
                const config_hash = std.mem.readInt(u64, data[pos..][0..8], .little);
                return .{
                    .msg = .{ .election = .{
                        .type_ = type_,
                        .epoch = epoch,
                        .granted = granted,
                        .last_log_seq = last_log_seq,
                        .config_hash = config_hash,
                    } },
                    .data = null,
                };
            },
            MSG_REPL => {
                if (data.len < 24) return null;
                const raw_rtype = data[pos];
                if (raw_rtype < 1 or raw_rtype > 4) return null; // replicate=1, ack=2, need_snap=3, snapshot=4
                const type_: repl_mod.MessageType = @enumFromInt(raw_rtype);
                pos += 1;
                const epoch = std.mem.readInt(u64, data[pos..][0..8], .little);
                pos += 8;
                const seq = std.mem.readInt(u64, data[pos..][0..8], .little);
                pos += 8;
                const shard_id = std.mem.readInt(u16, data[pos..][0..2], .little);
                pos += 2;
                const data_len = std.mem.readInt(u32, data[pos..][0..4], .little);
                pos += 4;
                var owned_data: []u8 = "";
                if (data_len > 0 and pos + data_len <= data.len) {
                    owned_data = allocator.alloc(u8, data_len) catch return null;
                    @memcpy(owned_data, data[pos..][0..data_len]);
                }
                return .{
                    .msg = .{ .repl = .{
                        .type_ = type_,
                        .epoch = epoch,
                        .seq = seq,
                        .shard_id = shard_id,
                        .data = owned_data,
                    } },
                    .data = if (owned_data.len > 0) owned_data else null,
                };
            },
            else => return null,
        }
    }
};
