//! Mutation codec — serializes a batch's recorded KV mutations.
//!
//! A committed kv.Batch records its mutations (set/delete/delete_range);
//! this module encodes that list into a compact byte buffer and decodes it
//! back. raft_fsm and raft_batcher use it to carry mutations through the
//! raft log and snapshot blobs.
//!
//! Encoding format:
//!   [count:4LE][{op:1}{key_len:2LE}{val_len:4LE}{key}{val}]...

const std = @import("std");
const kv = @import("kv.zig");

const Mutation = kv.Mutation;
const MutOp = kv.MutOp;

/// Encode mutations into a byte buffer.
/// Format: [count:4LE][{op:1}{key_len:2LE}{val_len:4LE}{key}{val}]...
pub fn encodeMutations(allocator: std.mem.Allocator, mutations: []const Mutation) []u8 {
    var size: usize = 4;
    for (mutations) |m| {
        size += 1 + 2 + 4 + m.key.len + m.value.len;
    }

    const buf = allocator.alloc(u8, size) catch unreachable;
    var pos: usize = 0;

    std.mem.writeInt(u32, buf[pos..][0..4], @intCast(mutations.len), .little);
    pos += 4;

    for (mutations) |m| {
        buf[pos] = @intFromEnum(m.op);
        pos += 1;

        std.mem.writeInt(u16, buf[pos..][0..2], @intCast(m.key.len), .little);
        pos += 2;

        std.mem.writeInt(u32, buf[pos..][0..4], @intCast(m.value.len), .little);
        pos += 4;

        @memcpy(buf[pos..][0..m.key.len], m.key);
        pos += m.key.len;

        if (m.value.len > 0) {
            @memcpy(buf[pos..][0..m.value.len], m.value);
            pos += m.value.len;
        }
    }

    return buf;
}

/// Decode mutations from an encoded buffer.
pub fn decodeMutations(allocator: std.mem.Allocator, data: []const u8) ![]Mutation {
    if (data.len < 4) return error.DataTooShort;

    const count = std.mem.readInt(u32, data[0..4], .little);
    const mutations = try allocator.alloc(Mutation, count);

    var off: usize = 4;
    for (0..count) |i| {
        if (off + 7 > data.len) {
            allocator.free(mutations);
            return error.TruncatedHeader;
        }

        const op_byte = data[off];
        off += 1;

        const key_len: usize = std.mem.readInt(u16, data[off..][0..2], .little);
        off += 2;

        const val_len: usize = std.mem.readInt(u32, data[off..][0..4], .little);
        off += 4;

        if (off + key_len + val_len > data.len) {
            allocator.free(mutations);
            return error.TruncatedData;
        }

        mutations[i] = .{
            .op = @enumFromInt(op_byte),
            .key = data[off .. off + key_len],
            .value = if (val_len > 0) data[off + key_len .. off + key_len + val_len] else "",
        };
        off += key_len + val_len;
    }

    return mutations;
}

// ============================================================================
// Tests
// ============================================================================

test "mutation encode/decode roundtrip" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const mutations = [_]Mutation{
        .{ .op = .set, .key = "k1", .value = "v1" },
        .{ .op = .delete, .key = "k2", .value = "" },
        .{ .op = .delete_range, .key = "start", .value = "end" },
    };

    const encoded = encodeMutations(allocator, &mutations);
    defer allocator.free(encoded);

    const decoded = try decodeMutations(allocator, encoded);
    defer allocator.free(decoded);

    try testing.expectEqual(@as(usize, 3), decoded.len);
    try testing.expectEqual(MutOp.set, decoded[0].op);
    try testing.expectEqualStrings("k1", decoded[0].key);
    try testing.expectEqualStrings("v1", decoded[0].value);
    try testing.expectEqual(MutOp.delete, decoded[1].op);
    try testing.expectEqualStrings("k2", decoded[1].key);
    try testing.expectEqual(MutOp.delete_range, decoded[2].op);
    try testing.expectEqualStrings("start", decoded[2].key);
    try testing.expectEqualStrings("end", decoded[2].value);
}
