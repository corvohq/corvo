//! raft_transport.zig — zig-raft Transport vtable adapter.
//!
//! This adapter is wire-agnostic: it owns an inbound ring buffer and a
//! send-callback hook. A network layer (Phase 5) wraps real sockets, calls
//! `pushInboundBytes` with received bytes, and registers a send callback
//! that pushes encoded bytes onto sockets. For unit tests, `InMemRouter`
//! glues N adapters together by codec round-tripping in process.
//!
//! TigerStyle: static inbound ring (`max_inbound`), per-slot heap-owned
//! byte buffer freed on slot reuse. Send is best-effort; full ring drops
//! on push (Raft tolerates).

const std = @import("std");
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const raft = @import("raft");
const codec = @import("raft_codec.zig");

const Message = raft.messages.Message;
const Incoming = raft.transport.Incoming;

/// Inbound ring slot count. Sized for several rounds of Raft chatter
/// per peer per tick (~3-5 peers × heartbeat + appends + responses).
pub const max_inbound: usize = 256;

pub const SendError = error{
    PeerUnknown,
    EncodeFailed,
    SendDropped,
};

/// Outbound send callback. Returns false if the underlying transport
/// dropped the message (full buffer, peer disconnected, encode failure).
/// Raft tolerates drops, so callers don't need to retry — the FSM will
/// re-send on next tick.
pub const SendFn = *const fn (ctx: *anyopaque, to: []const u8, bytes: []const u8) bool;

pub const Transport = struct {
    allocator: std.mem.Allocator,

    // Send hook — set by network layer (or test).
    send_ctx: ?*anyopaque = null,
    send_fn: ?SendFn = null,
    send_buf: []u8,

    // Inbound ring. Each slot owns a Decoded value; the from-string and
    // entry data live inside its arena. `pinned` holds the previously-
    // returned slot's index so its slices stay valid until the next recv().
    slots: [max_inbound]Slot = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    pinned: ?usize = null,
    drops: u64 = 0,

    const Slot = struct {
        decoded: ?codec.Decoded = null,
        from_buf: [codec.max_id_len]u8 = undefined,
        from_len: usize = 0,
    };

    pub fn init(allocator: std.mem.Allocator) !Transport {
        const buf = try allocator.alloc(u8, codec.max_msg_bytes);
        var t = Transport{ .allocator = allocator, .send_buf = buf };
        for (&t.slots) |*s| s.* = .{};
        return t;
    }

    pub fn deinit(self: *Transport) void {
        for (&self.slots) |*s| {
            if (s.decoded) |*d| d.deinit();
            s.decoded = null;
        }
        self.pinned = null;
        self.allocator.free(self.send_buf);
    }

    pub fn setSend(self: *Transport, ctx: *anyopaque, send: SendFn) void {
        self.send_ctx = ctx;
        self.send_fn = send;
    }

    pub fn transport(self: *Transport) raft.Transport {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    /// Push incoming wire bytes for decoding. Drops on full ring (Raft
    /// retransmits on next tick). Returns true if accepted, false if dropped.
    pub fn pushInboundBytes(self: *Transport, from: []const u8, bytes: []const u8) bool {
        if (from.len > codec.max_id_len) {
            self.drops += 1;
            return false;
        }
        if (self.count == max_inbound) {
            self.drops += 1;
            return false;
        }
        const d = codec.decode(bytes, self.allocator) catch {
            self.drops += 1;
            return false;
        };
        const slot = &self.slots[self.tail];
        // Free anything stale in this slot (paranoia: should be null when count<max).
        if (slot.decoded) |*old| old.deinit();
        slot.decoded = d;
        @memcpy(slot.from_buf[0..from.len], from);
        slot.from_len = from.len;
        self.tail = (self.tail + 1) % max_inbound;
        self.count += 1;
        return true;
    }

    /// VTable bridge — returns next inbound. The slices in the returned
    /// `Incoming` remain valid until the *next* call to recv().
    fn recvImpl(ptr: *anyopaque) ?Incoming {
        const self: *Transport = @ptrCast(@alignCast(ptr));
        // Free the slot pinned by the previous recv(): the caller has had
        // its tick to step the message and won't reference its slices again.
        if (self.pinned) |idx| {
            const s = &self.slots[idx];
            if (s.decoded) |*d| d.deinit();
            s.decoded = null;
            s.from_len = 0;
            self.pinned = null;
        }
        if (self.count == 0) return null;
        const idx = self.head;
        const slot = &self.slots[idx];
        const d = &slot.decoded.?;
        const inc = Incoming{
            .from = slot.from_buf[0..slot.from_len],
            .msg = d.msg,
        };
        // Logical pop, but keep the byte-buffer alive via `pinned`.
        self.pinned = idx;
        self.head = (self.head + 1) % max_inbound;
        self.count -= 1;
        return inc;
    }

    fn sendImpl(ptr: *anyopaque, to: []const u8, msg: Message) void {
        const self: *Transport = @ptrCast(@alignCast(ptr));
        const send = self.send_fn orelse return; // no transport wired yet — drop
        const ctx = self.send_ctx.?;
        const n = codec.encode(msg, self.send_buf) catch {
            self.drops += 1;
            return;
        };
        const ok = send(ctx, to, self.send_buf[0..n]);
        if (!ok) self.drops += 1;
    }

    const vtable = raft.Transport.VTable{
        .send = sendImpl,
        .recv = recvImpl,
    };
};

// =====================================================================
// InMemRouter — wire N Transport adapters together for unit tests.
// =====================================================================

pub const max_router_nodes: usize = 8;

pub const InMemRouter = struct {
    nodes: [max_router_nodes]Entry = undefined,
    count: usize = 0,

    const Entry = struct {
        id: []const u8,
        transport: *Transport,
    };

    pub fn init() InMemRouter {
        return .{};
    }

    pub fn register(self: *InMemRouter, id: []const u8, t: *Transport) void {
        check(self.count < max_router_nodes, "router full: {d}", .{self.count});
        self.nodes[self.count] = .{ .id = id, .transport = t };
        t.setSend(@ptrCast(self), routerSend);
        self.count += 1;
    }

    fn routerSend(ctx: *anyopaque, to: []const u8, bytes: []const u8) bool {
        const self: *InMemRouter = @ptrCast(@alignCast(ctx));
        for (self.nodes[0..self.count]) |e| {
            if (std.mem.eql(u8, e.id, to)) {
                // Find sender id by reverse lookup — we encode it into bytes,
                // but the InMem router lookup uses 'to'; we know the from
                // from the message body. Decode just the from for routing.
                // Cheaper: do nothing here — pushInboundBytes decodes anyway,
                // and we pass an empty from. But we need real `from` for the
                // adapter's slot key. Solve by re-decoding from-id only.
                const from = decodeFromOnly(bytes) catch return false;
                return e.transport.pushInboundBytes(from, bytes);
            }
        }
        return false;
    }
};

/// Cheap header-only parse to extract just the `from` string for routing.
/// Skips: version(1) + type(1) + term(8) + from_uuid(16) + to_uuid(16) + cluster_id(8) = 50 bytes
fn decodeFromOnly(bytes: []const u8) ![]const u8 {
    const skip: usize = 1 + 1 + 8 + 16 + 16 + 8;
    if (bytes.len < skip + 1) return error.Short;
    const from_len = bytes[skip];
    if (bytes.len < skip + 1 + from_len) return error.Short;
    return bytes[skip + 1 .. skip + 1 + from_len];
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;
const MemStorage = raft.storage.MemStorage;
const PeerSpec = raft.PeerSpec;
const Role = raft.Role;
const Config = raft.Config;

fn synthUuid(id: []const u8) u128 {
    var h: u128 = 0xcbf29ce484222325cbf29ce484222325;
    for (id) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return if (h == 0) 1 else h;
}

const test_cluster_id: u64 = 0xC0FFEE;

fn testConfig() Config {
    return .{
        .election_timeout_min = 200,
        .election_timeout_max = 400,
        .heartbeat_interval = 50,
    };
}

test "transport: pushInboundBytes round-trips a message" {
    var t = try Transport.init(testing.allocator);
    defer t.deinit();
    const msg = Message{
        .type_ = .append_entries,
        .from = "n1",
        .to = "n2",
        .term = 3,
        .leader_commit = 7,
    };
    var buf: [256]u8 = undefined;
    const n = try codec.encode(msg, &buf);
    try testing.expect(t.pushInboundBytes("n1", buf[0..n]));
    const got = t.transport().recv().?;
    try testing.expectEqualStrings("n1", got.from);
    try testing.expectEqualStrings("n2", got.msg.to);
    try testing.expectEqual(@as(u64, 3), got.msg.term);
    try testing.expectEqual(@as(u64, 7), got.msg.leader_commit);
    // Empty after consume.
    try testing.expect(t.transport().recv() == null);
}

test "transport: drops on full ring" {
    var t = try Transport.init(testing.allocator);
    defer t.deinit();
    const msg = Message{ .type_ = .append_entries, .from = "x", .to = "y", .term = 1 };
    var buf: [256]u8 = undefined;
    const n = try codec.encode(msg, &buf);
    var i: usize = 0;
    while (i < max_inbound) : (i += 1) {
        try testing.expect(t.pushInboundBytes("x", buf[0..n]));
    }
    // Next push should drop.
    try testing.expect(!t.pushInboundBytes("x", buf[0..n]));
    try testing.expectEqual(@as(u64, 1), t.drops);
}

test "transport: 3-node InMem election converges" {
    var router = InMemRouter.init();
    var t1 = try Transport.init(testing.allocator);
    defer t1.deinit();
    var t2 = try Transport.init(testing.allocator);
    defer t2.deinit();
    var t3 = try Transport.init(testing.allocator);
    defer t3.deinit();
    router.register("n1", &t1);
    router.register("n2", &t2);
    router.register("n3", &t3);

    var s1 = MemStorage.init(testing.allocator);
    defer s1.deinit();
    var s2 = MemStorage.init(testing.allocator);
    defer s2.deinit();
    var s3 = MemStorage.init(testing.allocator);
    defer s3.deinit();

    const peers_for = struct {
        fn get(comptime ids: []const []const u8) [ids.len]PeerSpec {
            var out: [ids.len]PeerSpec = undefined;
            inline for (ids, 0..) |id, i| out[i] = .{ .id = id, .uuid = synthUuid(id) };
            return out;
        }
    };
    const p1 = peers_for.get(&.{ "n2", "n3" });
    const p2 = peers_for.get(&.{ "n1", "n3" });
    const p3 = peers_for.get(&.{ "n1", "n2" });

    var n1 = try raft.Node.init(testing.allocator, "n1", synthUuid("n1"), test_cluster_id, &p1, testConfig(), s1.storage());
    defer n1.deinit();
    var n2 = try raft.Node.init(testing.allocator, "n2", synthUuid("n2"), test_cluster_id, &p2, testConfig(), s2.storage());
    defer n2.deinit();
    var n3 = try raft.Node.init(testing.allocator, "n3", synthUuid("n3"), test_cluster_id, &p3, testConfig(), s3.storage());
    defer n3.deinit();

    // Drive 50 ticks at 100ms each; election timeout is [200,400]ms, so
    // someone will become leader well within 50 ticks.
    var now: i64 = 0;
    var leader_id: ?[]const u8 = null;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        now += 100;
        try driveOnce(&n1, "n1", &t1, now);
        try driveOnce(&n2, "n2", &t2, now);
        try driveOnce(&n3, "n3", &t3, now);
        if (n1.isLeader()) leader_id = "n1";
        if (n2.isLeader()) leader_id = "n2";
        if (n3.isLeader()) leader_id = "n3";
        if (leader_id != null) break;
    }
    try testing.expect(leader_id != null);
}

fn driveOnce(n: *raft.Node, id: []const u8, t: *Transport, now: i64) !void {
    _ = id;
    const tr = t.transport();
    while (tr.recv()) |incoming| {
        const out = try n.step(incoming.msg, now);
        for (out) |m| tr.send(m.to, m);
    }
    const tick_out = try n.tick(now);
    for (tick_out) |m| tr.send(m.to, m);
}
