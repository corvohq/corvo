//! raft_codec.zig — wire encoding for zig-raft Message values.
//!
//! Pure functions. encode() writes into a caller-owned buffer; decode()
//! materializes a Message whose variable-length slices (from, to, entries
//! data, snapshot bytes) live in the supplied allocator. Caller frees via
//! `freeDecoded` when done.
//!
//! Wire format (all integers big-endian):
//!   u8  version (= wire_version)
//!   u8  type
//!   u64 term
//!   u128 from_uuid
//!   u128 to_uuid
//!   u64 cluster_id
//!   u8  from_len; bytes
//!   u8  to_len;   bytes
//!   u64 last_log_index
//!   u64 last_log_term
//!   u8  granted, u8 success
//!   u64 prev_log_index, u64 prev_log_term, u64 leader_commit
//!   u32 entries_count;
//!     for each entry: u8 type, u64 term, u64 index, u32 data_len, bytes
//!   u64 hint_index, u64 match_index, u64 read_seq
//!   u64 snapshot_index, u64 snapshot_term, u64 snapshot_offset
//!   u8  snapshot_done
//!   u32 snapshot_data_len; bytes
//!   u32 snapshot_config_len; bytes
//!
//! Worst-case size is bounded by `max_msg_bytes`; encode() returns an
//! error if the message would exceed it.

const std = @import("std");
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const raft = @import("raft");

const Message = raft.messages.Message;
const MessageType = raft.messages.MessageType;
const Entry = raft.messages.Entry;
const EntryType = raft.messages.EntryType;

pub const wire_version: u8 = 1;
/// Hard cap on encoded message size. Anything bigger is a protocol error.
pub const max_msg_bytes: usize = 2 * 1024 * 1024;
/// Hard cap on a single ID (from / to). Matches existing tcp_transport.zig.
pub const max_id_len: usize = 32;

/// Per-entry wire overhead of an encoded entry: type(1) + term(8) + index(8) +
/// data_len(4). See writeEntries / encodedSize.
pub const entry_wire_overhead: usize = 1 + 8 + 8 + 4;

/// Worst-case fixed (non-entry) bytes of an encoded message: every field in
/// encodedSize() except the per-entry loop, with both ids at max_id_len and no
/// snapshot payload (an AppendEntries carries none). This is the frame budget
/// consumed before any entry data.
pub const max_frame_overhead: usize =
    (1 + 1 + 8 + 16 + 16 + 8) // version, type, term, from_uuid, to_uuid, cluster_id
+ (1 + max_id_len) + (1 + max_id_len) // from, to
+ (8 + 8) // last_log_index, last_log_term
+ (1 + 1) // granted, success
+ (8 + 8 + 8) // prev_log_index, prev_log_term, leader_commit
+ 4 // entries_count
+ (8 + 8 + 8) // hint_index, match_index, read_seq
+ (8 + 8 + 8 + 1) // snapshot_index, snapshot_term, snapshot_offset, snapshot_done
+ (4 + 4); // snapshot_data_len, snapshot_config_len (payloads empty)

/// Largest single entry `data` payload such that `count` entries of this size
/// still encode within max_msg_bytes. zig-raft packs up to
/// Config.max_entries_per_msg entries into one AppendEntries by COUNT with no
/// byte budget (zig-raft src/raft.zig `buildAppendEntriesFor`). If a single
/// entry exceeds this, a full message can exceed the frame cap and become
/// impossible to encode or transmit — the leader then re-assembles the same
/// oversize message every retry: a per-follower replication livelock. Entry
/// producers (raft_batcher) MUST bound each entry's payload to this.
pub fn maxEntryDataBytes(count: usize) usize {
    check(count > 0, "maxEntryDataBytes: count must be > 0", .{});
    return (max_msg_bytes - max_frame_overhead) / count - entry_wire_overhead;
}

pub const CodecError = error{
    BufferTooSmall,
    MessageTooLarge,
    InvalidWireVersion,
    InvalidMessage,
    OutOfMemory,
};

// =====================================================================
// Encode
// =====================================================================

pub fn encodedSize(msg: Message) usize {
    var n: usize = 1 + 1 + 8 + 16 + 16 + 8; // version, type, term, uuids, cluster_id
    n += 1 + msg.from.len;
    n += 1 + msg.to.len;
    n += 8 + 8; // last_log_index, last_log_term
    n += 1 + 1; // granted, success
    n += 8 + 8 + 8; // prev_log_index, prev_log_term, leader_commit
    n += 4; // entries_count
    for (msg.entries) |e| {
        n += 1 + 8 + 8 + 4 + e.data.len;
    }
    n += 8 + 8 + 8; // hint_index, match_index, read_seq
    n += 8 + 8 + 8 + 1; // snapshot_index, snapshot_term, snapshot_offset, snapshot_done
    n += 4 + msg.snapshot_data.len;
    n += 4 + msg.snapshot_config.len;
    return n;
}

pub fn encode(msg: Message, out: []u8) CodecError!usize {
    if (msg.from.len > max_id_len or msg.to.len > max_id_len) return CodecError.InvalidMessage;
    const total = encodedSize(msg);
    if (total > max_msg_bytes) return CodecError.MessageTooLarge;
    if (out.len < total) return CodecError.BufferTooSmall;
    var w = Writer{ .buf = out, .pos = 0 };
    w.putU8(wire_version);
    w.putU8(@intFromEnum(msg.type_));
    w.putU64(msg.term);
    w.putU128(msg.from_uuid);
    w.putU128(msg.to_uuid);
    w.putU64(msg.cluster_id);
    w.putIdStr(msg.from);
    w.putIdStr(msg.to);
    w.putU64(msg.last_log_index);
    w.putU64(msg.last_log_term);
    w.putBool(msg.granted);
    w.putBool(msg.success);
    w.putU64(msg.prev_log_index);
    w.putU64(msg.prev_log_term);
    w.putU64(msg.leader_commit);
    try writeEntries(&w, msg.entries);
    w.putU64(msg.hint_index);
    w.putU64(msg.match_index);
    w.putU64(msg.read_seq);
    w.putU64(msg.snapshot_index);
    w.putU64(msg.snapshot_term);
    w.putU64(msg.snapshot_offset);
    w.putBool(msg.snapshot_done);
    try w.putLenBytes32(msg.snapshot_data);
    try w.putLenBytes32(msg.snapshot_config);
    check(w.pos == total, "encoded size mismatch: wrote {d}, expected {d}", .{ w.pos, total });
    return w.pos;
}

fn writeEntries(w: *Writer, entries: []const Entry) CodecError!void {
    if (entries.len > std.math.maxInt(u32)) return CodecError.InvalidMessage;
    w.putU32(@intCast(entries.len));
    for (entries) |e| {
        w.putU8(@intFromEnum(e.type_));
        w.putU64(e.term);
        w.putU64(e.index);
        try w.putLenBytes32(e.data);
    }
}

const Writer = struct {
    buf: []u8,
    pos: usize,

    fn putU8(self: *Writer, v: u8) void {
        self.buf[self.pos] = v;
        self.pos += 1;
    }
    fn putU32(self: *Writer, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .big);
        self.pos += 4;
    }
    fn putU64(self: *Writer, v: u64) void {
        std.mem.writeInt(u64, self.buf[self.pos..][0..8], v, .big);
        self.pos += 8;
    }
    fn putU128(self: *Writer, v: u128) void {
        std.mem.writeInt(u128, self.buf[self.pos..][0..16], v, .big);
        self.pos += 16;
    }
    fn putBool(self: *Writer, b: bool) void {
        self.putU8(if (b) 1 else 0);
    }
    fn putIdStr(self: *Writer, s: []const u8) void {
        check(s.len <= max_id_len, "id too long: {d}", .{s.len});
        self.putU8(@intCast(s.len));
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }
    fn putLenBytes32(self: *Writer, s: []const u8) CodecError!void {
        if (s.len > std.math.maxInt(u32)) return CodecError.InvalidMessage;
        self.putU32(@intCast(s.len));
        @memcpy(self.buf[self.pos..][0..s.len], s);
        self.pos += s.len;
    }
};

// =====================================================================
// Decode
// =====================================================================

/// Decoded Message + ownership handle for free.
pub const Decoded = struct {
    msg: Message,
    /// Backing buffer for from / to / entries data / snapshot bytes.
    /// One arena per decoded message — cheap to free at once.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Decoded) void {
        self.arena.deinit();
    }
};

pub fn decode(bytes: []const u8, allocator: std.mem.Allocator) CodecError!Decoded {
    if (bytes.len > max_msg_bytes) return CodecError.MessageTooLarge;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var r = Reader{ .buf = bytes, .pos = 0 };
    const ver = try r.getU8();
    if (ver != wire_version) return CodecError.InvalidWireVersion;
    const t_byte = try r.getU8();
    if (t_byte == 0 or t_byte > @intFromEnum(MessageType.pre_vote_resp)) return CodecError.InvalidMessage;
    const type_: MessageType = @enumFromInt(t_byte);
    const term = try r.getU64();
    const from_uuid = try r.getU128();
    const to_uuid = try r.getU128();
    const cluster_id = try r.getU64();
    const from = try r.getIdStr(a);
    const to = try r.getIdStr(a);
    const last_log_index = try r.getU64();
    const last_log_term = try r.getU64();
    const granted = try r.getBool();
    const success = try r.getBool();
    const prev_log_index = try r.getU64();
    const prev_log_term = try r.getU64();
    const leader_commit = try r.getU64();
    const entries = try readEntries(&r, a);
    const hint_index = try r.getU64();
    const match_index = try r.getU64();
    const read_seq = try r.getU64();
    const snapshot_index = try r.getU64();
    const snapshot_term = try r.getU64();
    const snapshot_offset = try r.getU64();
    const snapshot_done = try r.getBool();
    const snapshot_data = try r.getLenBytes32(a);
    const snapshot_config = try r.getLenBytes32(a);

    if (r.pos != bytes.len) return CodecError.InvalidMessage;
    return .{
        .msg = .{
            .type_ = type_,
            .term = term,
            .from = from,
            .to = to,
            .from_uuid = from_uuid,
            .to_uuid = to_uuid,
            .cluster_id = cluster_id,
            .last_log_index = last_log_index,
            .last_log_term = last_log_term,
            .granted = granted,
            .success = success,
            .prev_log_index = prev_log_index,
            .prev_log_term = prev_log_term,
            .leader_commit = leader_commit,
            .entries = entries,
            .hint_index = hint_index,
            .match_index = match_index,
            .read_seq = read_seq,
            .snapshot_index = snapshot_index,
            .snapshot_term = snapshot_term,
            .snapshot_offset = snapshot_offset,
            .snapshot_done = snapshot_done,
            .snapshot_data = snapshot_data,
            .snapshot_config = snapshot_config,
        },
        .arena = arena,
    };
}

fn readEntries(r: *Reader, a: std.mem.Allocator) CodecError![]const Entry {
    const count = try r.getU32();
    if (count == 0) return &.{};
    // Reject a claimed count the remaining buffer can't possibly hold before
    // allocating. Each entry is at least type(1) + term(8) + index(8) +
    // data-length(4) = 21 bytes on the wire, so a hostile frame declaring
    // count = 0xFFFFFFFF can't turn into a multi-gigabyte allocation.
    const min_entry_bytes: usize = 1 + 8 + 8 + 4;
    const remaining = r.buf.len - r.pos;
    if (count > remaining / min_entry_bytes) return CodecError.InvalidMessage;
    const ents = a.alloc(Entry, count) catch return CodecError.OutOfMemory;
    for (ents) |*e| {
        const t_byte = try r.getU8();
        if (t_byte > @intFromEnum(EntryType.conf_change)) return CodecError.InvalidMessage;
        e.* = .{
            .type_ = @enumFromInt(t_byte),
            .term = try r.getU64(),
            .index = try r.getU64(),
            .data = try r.getLenBytes32(a),
        };
    }
    return ents;
}

const Reader = struct {
    buf: []const u8,
    pos: usize,

    fn need(self: *Reader, n: usize) CodecError!void {
        if (self.pos + n > self.buf.len) return CodecError.InvalidMessage;
    }
    fn getU8(self: *Reader) CodecError!u8 {
        try self.need(1);
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }
    fn getU32(self: *Reader) CodecError!u32 {
        try self.need(4);
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }
    fn getU64(self: *Reader) CodecError!u64 {
        try self.need(8);
        const v = std.mem.readInt(u64, self.buf[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }
    fn getU128(self: *Reader) CodecError!u128 {
        try self.need(16);
        const v = std.mem.readInt(u128, self.buf[self.pos..][0..16], .big);
        self.pos += 16;
        return v;
    }
    fn getBool(self: *Reader) CodecError!bool {
        const b = try self.getU8();
        return b != 0;
    }
    fn getIdStr(self: *Reader, a: std.mem.Allocator) CodecError![]const u8 {
        const len = try self.getU8();
        if (len > max_id_len) return CodecError.InvalidMessage;
        try self.need(len);
        const dest = a.alloc(u8, len) catch return CodecError.OutOfMemory;
        @memcpy(dest, self.buf[self.pos..][0..len]);
        self.pos += len;
        return dest;
    }
    fn getLenBytes32(self: *Reader, a: std.mem.Allocator) CodecError![]const u8 {
        const len = try self.getU32();
        if (len > max_msg_bytes) return CodecError.InvalidMessage;
        try self.need(len);
        if (len == 0) return &.{};
        const dest = a.alloc(u8, len) catch return CodecError.OutOfMemory;
        @memcpy(dest, self.buf[self.pos..][0..len]);
        self.pos += len;
        return dest;
    }
};

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn expectEqualMessages(expected: Message, got: Message) !void {
    try testing.expectEqual(expected.type_, got.type_);
    try testing.expectEqual(expected.term, got.term);
    try testing.expectEqualStrings(expected.from, got.from);
    try testing.expectEqualStrings(expected.to, got.to);
    try testing.expectEqual(expected.from_uuid, got.from_uuid);
    try testing.expectEqual(expected.to_uuid, got.to_uuid);
    try testing.expectEqual(expected.cluster_id, got.cluster_id);
    try testing.expectEqual(expected.last_log_index, got.last_log_index);
    try testing.expectEqual(expected.last_log_term, got.last_log_term);
    try testing.expectEqual(expected.granted, got.granted);
    try testing.expectEqual(expected.success, got.success);
    try testing.expectEqual(expected.prev_log_index, got.prev_log_index);
    try testing.expectEqual(expected.prev_log_term, got.prev_log_term);
    try testing.expectEqual(expected.leader_commit, got.leader_commit);
    try testing.expectEqual(expected.entries.len, got.entries.len);
    for (expected.entries, got.entries) |e_exp, e_got| {
        try testing.expectEqual(e_exp.type_, e_got.type_);
        try testing.expectEqual(e_exp.term, e_got.term);
        try testing.expectEqual(e_exp.index, e_got.index);
        try testing.expectEqualStrings(e_exp.data, e_got.data);
    }
    try testing.expectEqual(expected.hint_index, got.hint_index);
    try testing.expectEqual(expected.match_index, got.match_index);
    try testing.expectEqual(expected.read_seq, got.read_seq);
    try testing.expectEqual(expected.snapshot_index, got.snapshot_index);
    try testing.expectEqual(expected.snapshot_term, got.snapshot_term);
    try testing.expectEqual(expected.snapshot_offset, got.snapshot_offset);
    try testing.expectEqual(expected.snapshot_done, got.snapshot_done);
    try testing.expectEqualStrings(expected.snapshot_data, got.snapshot_data);
    try testing.expectEqualStrings(expected.snapshot_config, got.snapshot_config);
}

test "codec: heartbeat round-trip" {
    const msg = Message{
        .type_ = .append_entries,
        .from = "n1",
        .to = "n2",
        .term = 5,
        .from_uuid = 0xABCDEF01_23456789_DEADBEEF_CAFEBABE,
        .to_uuid = 0x11111111_22222222_33333333_44444444,
        .cluster_id = 0xC0FFEE,
        .prev_log_index = 10,
        .prev_log_term = 4,
        .leader_commit = 8,
        .entries = &.{},
    };
    var buf: [1024]u8 = undefined;
    const n = try encode(msg, &buf);
    try testing.expectEqual(encodedSize(msg), n);
    var d = try decode(buf[0..n], testing.allocator);
    defer d.deinit();
    try expectEqualMessages(msg, d.msg);
}

test "codec: append with entries" {
    const ents = [_]Entry{
        .{ .term = 3, .index = 11, .data = "hello" },
        .{ .term = 3, .index = 12, .type_ = .conf_change, .data = "conf-bytes" },
    };
    const msg = Message{
        .type_ = .append_entries,
        .from = "leader",
        .to = "follower",
        .term = 3,
        .prev_log_index = 10,
        .prev_log_term = 3,
        .leader_commit = 10,
        .entries = &ents,
    };
    var buf: [1024]u8 = undefined;
    const n = try encode(msg, &buf);
    var d = try decode(buf[0..n], testing.allocator);
    defer d.deinit();
    try expectEqualMessages(msg, d.msg);
}

test "codec: install_snapshot chunk" {
    const data = "fsm-state-bytes";
    const cfg = "n1,n2,n3";
    const msg = Message{
        .type_ = .install_snapshot,
        .from = "leader",
        .to = "lagger",
        .term = 9,
        .snapshot_index = 100,
        .snapshot_term = 9,
        .snapshot_offset = 0,
        .snapshot_done = true,
        .snapshot_data = data,
        .snapshot_config = cfg,
    };
    var buf: [1024]u8 = undefined;
    const n = try encode(msg, &buf);
    var d = try decode(buf[0..n], testing.allocator);
    defer d.deinit();
    try expectEqualMessages(msg, d.msg);
}

test "codec: vote response" {
    const msg = Message{
        .type_ = .request_vote_resp,
        .from = "n2",
        .to = "n1",
        .term = 7,
        .granted = true,
    };
    var buf: [256]u8 = undefined;
    const n = try encode(msg, &buf);
    var d = try decode(buf[0..n], testing.allocator);
    defer d.deinit();
    try expectEqualMessages(msg, d.msg);
}

test "codec: rejects buffer too small" {
    const msg = Message{ .type_ = .append_entries, .from = "n1", .to = "n2", .term = 1 };
    var buf: [4]u8 = undefined;
    try testing.expectError(CodecError.BufferTooSmall, encode(msg, &buf));
}

test "codec: rejects bad version" {
    var buf: [256]u8 = undefined;
    buf[0] = 0xFF; // bogus version byte
    try testing.expectError(CodecError.InvalidWireVersion, decode(buf[0..256], testing.allocator));
}

test "codec: rejects truncated payload" {
    const msg = Message{ .type_ = .append_entries, .from = "n1", .to = "n2", .term = 1 };
    var buf: [512]u8 = undefined;
    const n = try encode(msg, &buf);
    try testing.expectError(CodecError.InvalidMessage, decode(buf[0 .. n - 1], testing.allocator));
}

test "codec: rejects oversized id" {
    const long_id = "x" ** 33;
    const msg = Message{ .type_ = .append_entries, .from = long_id, .to = "n2", .term = 1 };
    var buf: [256]u8 = undefined;
    try testing.expectError(CodecError.InvalidMessage, encode(msg, &buf));
}

test "codec: worst-case max-entries message assembles within frame cap" {
    // A leader packs up to raft.max_entries_per_msg entries per AppendEntries
    // by count (zig-raft applies no byte budget). Prove the worst case — that
    // many entries, each at maxEntryDataBytes, with max-length ids — encodes
    // within max_msg_bytes and round-trips. If this ever regresses, a leader
    // could assemble an untransmittable message and livelock replication.
    const a = testing.allocator;
    const count = raft.raft.max_entries_per_msg;
    const data_len = maxEntryDataBytes(count);

    // One shared data blob; every entry points at it (decode copies per entry).
    const blob = try a.alloc(u8, data_len);
    defer a.free(blob);
    @memset(blob, 0xAB);

    const ents = try a.alloc(Entry, count);
    defer a.free(ents);
    for (ents, 0..) |*e, i| e.* = .{ .term = 9, .index = @intCast(i + 1), .data = blob };

    const id32 = "x" ** max_id_len; // worst-case 32-byte ids
    const msg = Message{
        .type_ = .append_entries,
        .from = id32,
        .to = id32,
        .term = 9,
        .prev_log_index = 100,
        .prev_log_term = 8,
        .leader_commit = 100,
        .entries = ents,
    };

    const total = encodedSize(msg);
    try testing.expect(total <= max_msg_bytes);

    const buf = try a.alloc(u8, max_msg_bytes);
    defer a.free(buf);
    const n = try encode(msg, buf);
    try testing.expectEqual(total, n);

    var d = try decode(buf[0..n], a);
    defer d.deinit();
    try testing.expectEqual(count, d.msg.entries.len);
    try testing.expectEqual(@as(usize, data_len), d.msg.entries[0].data.len);
    try testing.expectEqual(@as(u8, 0xAB), d.msg.entries[count - 1].data[0]);
}

test "codec: one byte over per-entry budget overflows the frame" {
    // maxEntryDataBytes is the exact ceiling: growing every entry by a single
    // byte pushes a full-count message past max_msg_bytes. encode() rejects it
    // (MessageTooLarge) before writing, so the buffer size is irrelevant.
    const a = testing.allocator;
    const count = raft.raft.max_entries_per_msg;
    const data_len = maxEntryDataBytes(count) + 1;

    const blob = try a.alloc(u8, data_len);
    defer a.free(blob);
    @memset(blob, 0xCD);

    const ents = try a.alloc(Entry, count);
    defer a.free(ents);
    for (ents, 0..) |*e, i| e.* = .{ .term = 9, .index = @intCast(i + 1), .data = blob };

    const id32 = "x" ** max_id_len;
    const msg = Message{ .type_ = .append_entries, .from = id32, .to = id32, .term = 9, .entries = ents };
    try testing.expect(encodedSize(msg) > max_msg_bytes);

    var buf: [64]u8 = undefined;
    try testing.expectError(CodecError.MessageTooLarge, encode(msg, &buf));
}
