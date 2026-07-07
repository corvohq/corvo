//! raft_gate.zig — server-side helper for "this node isn't the leader"
//! responses. Workers receive `MSG_NOT_LEADER` carrying the current
//! leader id + address; SDKs reconnect there and replay tokened acks.
//!
//! Wire payload of MSG_NOT_LEADER:
//!   [u8 leader_id_len][leader_id bytes]
//!   [u8 leader_addr_len][leader_addr bytes]
//! Either field may be empty (len=0) when the leader is unknown
//! (e.g. mid-election). SDK should retry on the same connection or
//! its known peer set in that case.
//!
//! Phase 6 status: protocol constant + encoder land here. Handler
//! integration (calling notLeader() before each write) and SDK
//! decode/replay logic (Go, TS, Python, Rust, Haskell, Zig) are
//! follow-up work — they all read MSG_NOT_LEADER off the wire and
//! redial to the indicated leader.

const std = @import("std");
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const rpc = @import("rpc.zig");

/// Maximum total payload size for MSG_NOT_LEADER (id + addr + their
/// length prefixes). Comfortable cap given max_id_len and a sensible
/// max addr length.
pub const max_payload_bytes: usize = 2 + 32 + 256;

pub const NotLeaderHint = struct {
    /// Current leader's node id, or empty if unknown.
    leader_id: []const u8 = "",
    /// Current leader's reachable client address (e.g. "10.0.0.4:9878"),
    /// or empty if not advertised.
    leader_addr: []const u8 = "",
};

/// Encode a MSG_NOT_LEADER frame (header + payload) into `out`. Returns
/// total bytes written. `out` must be at least frame-header (9 bytes) +
/// payload size. Caller controls req_id (typically the originating
/// request's req_id so the SDK correlates).
pub fn encodeNotLeader(out: []u8, req_id: u32, hint: NotLeaderHint) !usize {
    if (hint.leader_id.len > 32) return error.LeaderIdTooLong;
    if (hint.leader_addr.len > 255) return error.LeaderAddrTooLong;
    const payload_len = 1 + hint.leader_id.len + 1 + hint.leader_addr.len;
    const total = rpc.FRAME_HEADER_SIZE + payload_len;
    if (out.len < total) return error.BufferTooSmall;
    rpc.writeFrameHeader(out[0..rpc.FRAME_HEADER_SIZE], rpc.MSG_NOT_LEADER, req_id, @intCast(payload_len));
    var pos: usize = rpc.FRAME_HEADER_SIZE;
    out[pos] = @intCast(hint.leader_id.len);
    pos += 1;
    @memcpy(out[pos..][0..hint.leader_id.len], hint.leader_id);
    pos += hint.leader_id.len;
    out[pos] = @intCast(hint.leader_addr.len);
    pos += 1;
    @memcpy(out[pos..][0..hint.leader_addr.len], hint.leader_addr);
    pos += hint.leader_addr.len;
    check(pos == total, "encodeNotLeader size mismatch: {d} vs {d}", .{ pos, total });
    return total;
}

/// Decode a MSG_NOT_LEADER payload (everything after the frame header).
/// Returns slices into the input buffer; copy if retention needed.
pub fn decodeNotLeader(payload: []const u8) !NotLeaderHint {
    if (payload.len < 1) return error.Truncated;
    const id_len: usize = payload[0];
    if (payload.len < 1 + id_len + 1) return error.Truncated;
    const leader_id = payload[1 .. 1 + id_len];
    const addr_len_off = 1 + id_len;
    const addr_len: usize = payload[addr_len_off];
    if (payload.len < addr_len_off + 1 + addr_len) return error.Truncated;
    const leader_addr = payload[addr_len_off + 1 .. addr_len_off + 1 + addr_len];
    return .{ .leader_id = leader_id, .leader_addr = leader_addr };
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

test "raft_gate: encode + decode round-trip" {
    var buf: [256]u8 = undefined;
    const n = try encodeNotLeader(&buf, 42, .{ .leader_id = "node-2", .leader_addr = "10.0.0.4:9878" });
    // Header check.
    const hdr = rpc.readFrameHeader(buf[0..n]).?;
    try testing.expectEqual(rpc.MSG_NOT_LEADER, hdr.msg_type);
    try testing.expectEqual(@as(u32, 42), hdr.req_id);
    try testing.expectEqual(@as(u32, 1 + 6 + 1 + 13), hdr.payload_len);

    // Decode payload.
    const hint = try decodeNotLeader(buf[rpc.FRAME_HEADER_SIZE..n]);
    try testing.expectEqualStrings("node-2", hint.leader_id);
    try testing.expectEqualStrings("10.0.0.4:9878", hint.leader_addr);
}

test "raft_gate: empty hint encodes to header + 2 zero-length prefixes" {
    var buf: [16]u8 = undefined;
    const n = try encodeNotLeader(&buf, 7, .{});
    try testing.expectEqual(@as(usize, rpc.FRAME_HEADER_SIZE + 2), n);
    const hint = try decodeNotLeader(buf[rpc.FRAME_HEADER_SIZE..n]);
    try testing.expectEqualStrings("", hint.leader_id);
    try testing.expectEqualStrings("", hint.leader_addr);
}

test "raft_gate: rejects oversized leader_id" {
    const long_id = "x" ** 33;
    var buf: [128]u8 = undefined;
    try testing.expectError(error.LeaderIdTooLong, encodeNotLeader(&buf, 1, .{ .leader_id = long_id }));
}

test "raft_gate: rejects truncated payload" {
    // [id_len=5, "abc"] — claims 5 bytes but only 3 follow.
    const payload = [_]u8{ 5, 'a', 'b', 'c' };
    try testing.expectError(error.Truncated, decodeNotLeader(&payload));
}
