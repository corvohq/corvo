//! OpLog — append-only replication log with file persistence.
//!
//! Ported from Go internal/oplog/oplog.go + encode.go.
//! The leader appends entries after committing to Talon, and
//! followers consume entries to replay into their own Talon instances.
//!
//! Frame format (on disk):
//!   [total_len:4LE][seq:8LE][shard:2LE][timestamp:8LE][data...]
//!
//! total_len covers everything after the 4-byte length prefix.
//! On startup, the file is scanned to rebuild the in-memory index.
//!
//! Mutation encoding format:
//!   [count:4LE][{op:1}{key_len:2LE}{val_len:4LE}{key}{val}]...

const std = @import("std");
const assert = @import("assert.zig");
const kv = @import("kv.zig");

const Mutation = kv.Mutation;
const MutOp = kv.MutOp;

/// Pre-allocate 256 MB to avoid filesystem metadata updates on each append.
const prealloc_size: u64 = 256 * 1024 * 1024;

/// Entry header sizes.
const entry_header_size: usize = 18; // seq(8) + shard(2) + timestamp(8)
const frame_len_size: usize = 4;
const frame_header_size: usize = frame_len_size + entry_header_size; // 22

/// A single operation log entry.
pub const Entry = struct {
    seq: u64,
    shard_id: u16,
    timestamp: i64,
    data: []const u8,
};

/// Clock provides the current time in nanoseconds.
pub const Clock = struct {
    now_fn: *const fn () i64,

    pub fn now(self: Clock) i64 {
        return self.now_fn();
    }
};

/// Index entry: maps sequence number to file offset.
const IndexEntry = struct {
    seq: u64,
    offset: u64,
};

/// File-backed append-only operation log.
///
/// Entries are appended to a file and cached in memory.
/// On startup, the file is scanned to rebuild state.
/// If no path is given (null), operates in memory-only mode (for tests).
pub const Log = struct {
    mu: std.Thread.Mutex = .{},
    seq: u64 = 0,
    clock: Clock,
    allocator: std.mem.Allocator,

    // In-memory entry cache for fast reads.
    entries: std.ArrayList(Entry),

    // File backing (null = memory-only).
    file: ?std.fs.File = null,
    file_size: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, clock: Clock, path: ?[*:0]const u8) Log {
        var self = Log{
            .clock = clock,
            .entries = .{},
            .allocator = allocator,
        };

        if (path) |p| {
            self.file = std.fs.cwd().openFileZ(p, .{ .mode = .read_write }) catch
                std.fs.cwd().createFileZ(p, .{ .truncate = false }) catch null;

            if (self.file) |f| {
                // Recover existing entries.
                self.recover(f);
                // Pre-allocate disk space to reduce metadata updates on append.
                preallocate(f);
            }
        }

        return self;
    }

    pub fn deinit(self: *Log) void {
        for (self.entries.items) |e| {
            self.allocator.free(@constCast(e.data));
        }
        self.entries.deinit(self.allocator);
        if (self.file) |f| f.close();
    }

    /// Append writes an entry to the log and returns the assigned sequence number.
    pub fn append(self: *Log, shard_id: u16, data: []const u8) u64 {
        assert.check(data.len > 0, "oplog.append: empty data", .{});

        self.mu.lock();
        defer self.mu.unlock();

        self.seq += 1;
        const seq = self.seq;
        const ts = self.clock.now();

        // Write to file first (durability).
        if (self.file) |f| {
            self.writeFrame(f, seq, shard_id, ts, data);
        }

        // Own a copy of the data for in-memory cache.
        const data_copy = self.allocator.dupe(u8, data) catch unreachable;

        self.entries.append(self.allocator, .{
            .seq = seq,
            .shard_id = shard_id,
            .timestamp = ts,
            .data = data_copy,
        }) catch unreachable;

        return seq;
    }

    /// Whether this log has file backing (vs memory-only).
    pub fn hasFile(self: *const Log) bool {
        return self.file != null;
    }

    /// Returns the current sequence number.
    pub fn getSeq(self: *Log) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.seq;
    }

    /// Read entries after the given sequence number (exclusive).
    pub fn readAfter(self: *Log, after_seq: u64, max_entries: u32) []const Entry {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.entries.items.len == 0) return &.{};

        // Binary search for first entry with seq > after_seq.
        const items = self.entries.items;
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid].seq <= after_seq) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        if (lo >= items.len) return &.{};

        const available = items.len - lo;
        const count = @min(available, max_entries);
        return items[lo .. lo + count];
    }

    /// Truncate entries with seq <= min_seq.
    /// Frees the data, removes from in-memory cache, and compacts the file.
    pub fn truncate(self: *Log, min_seq: u64) void {
        self.mu.lock();
        defer self.mu.unlock();

        var remove_count: usize = 0;
        for (self.entries.items) |e| {
            if (e.seq <= min_seq) {
                self.allocator.free(@constCast(e.data));
                remove_count += 1;
            } else {
                break; // entries are in order
            }
        }

        if (remove_count > 0) {
            const remaining = self.entries.items.len - remove_count;
            if (remaining > 0) {
                std.mem.copyForwards(
                    Entry,
                    self.entries.items[0..remaining],
                    self.entries.items[remove_count..],
                );
            }
            self.entries.shrinkRetainingCapacity(remaining);

            // Compact the file to match in-memory state.
            self.compactLocked();
        }
    }

    /// Rewrite the file with only the remaining in-memory entries.
    /// Must be called with mu held.
    fn compactLocked(self: *Log) void {
        const f = self.file orelse return;

        // Seek to beginning and rewrite all remaining entries.
        f.seekTo(0) catch return;
        self.file_size = 0;

        for (self.entries.items) |e| {
            self.writeFrame(f, e.seq, e.shard_id, e.timestamp, e.data);
        }

        // Truncate file to new size (remove leftover bytes from old entries).
        const posix_fd = f.handle;
        std.posix.ftruncate(posix_fd, self.file_size) catch {};

        // Re-allocate space after compaction.
        preallocate(f);
    }

    /// Returns the total number of entries in the log.
    pub fn len(self: *Log) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.entries.items.len;
    }

    // ========================================================================
    // File I/O
    // ========================================================================

    /// Pre-allocate disk blocks via fallocate(2) to avoid filesystem metadata
    /// updates on each append write. This is a best-effort optimization; failures
    /// are silently ignored (non-Linux, unsupported filesystem, etc.).
    fn preallocate(file: std.fs.File) void {
        if (comptime @import("builtin").os.tag != .linux) return;
        const fd: usize = @intCast(file.handle);
        // fallocate(fd, mode=0, offset=0, len)
        _ = std.os.linux.syscall4(.fallocate, fd, 0, 0, prealloc_size);
    }

    /// Write a single frame to the file.
    fn writeFrame(self: *Log, file: std.fs.File, seq: u64, shard_id: u16, ts: i64, data: []const u8) void {
        const payload_len: u32 = @intCast(entry_header_size + data.len);

        var header: [frame_header_size]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], payload_len, .little);
        std.mem.writeInt(u64, header[4..12], seq, .little);
        std.mem.writeInt(u16, header[12..14], shard_id, .little);
        std.mem.writeInt(i64, header[14..22], ts, .little);

        // Write header + data as two iovecs.
        const iov = [_]std.posix.iovec_const{
            .{ .base = &header, .len = frame_header_size },
            .{ .base = data.ptr, .len = data.len },
        };
        _ = file.writev(&iov) catch return;
        self.file_size += frame_header_size + data.len;
    }

    /// Recover entries from an existing file.
    fn recover(self: *Log, file: std.fs.File) void {
        const stat = file.stat() catch return;
        if (stat.size == 0) return;

        // Hint to the kernel that we'll read this file sequentially.
        // Enables aggressive read-ahead during recovery scan.
        if (comptime @import("builtin").os.tag == .linux) {
            const POSIX_FADV_SEQUENTIAL: usize = 2;
            _ = std.os.linux.syscall4(.fadvise64, @intCast(file.handle), 0, 0, POSIX_FADV_SEQUENTIAL);
        }

        file.seekTo(0) catch return;

        var offset: u64 = 0;
        while (offset < stat.size) {
            // Read frame header.
            var header: [frame_header_size]u8 = undefined;
            const header_read = file.readAll(&header) catch break;
            if (header_read < frame_header_size) break; // truncated

            const payload_len = std.mem.readInt(u32, header[0..4], .little);
            if (payload_len < entry_header_size) break; // corrupt
            const data_len = payload_len - entry_header_size;

            const seq = std.mem.readInt(u64, header[4..12], .little);
            const shard_id = std.mem.readInt(u16, header[12..14], .little);
            const ts = std.mem.readInt(i64, header[14..22], .little);

            // Read data.
            if (data_len > 0) {
                const data_buf = self.allocator.alloc(u8, data_len) catch break;
                const data_read = file.readAll(data_buf) catch {
                    self.allocator.free(data_buf);
                    break;
                };
                if (data_read < data_len) {
                    self.allocator.free(data_buf);
                    break; // truncated
                }

                self.entries.append(self.allocator, .{
                    .seq = seq,
                    .shard_id = shard_id,
                    .timestamp = ts,
                    .data = data_buf,
                }) catch {
                    self.allocator.free(data_buf);
                    break;
                };
            } else {
                // No data — shouldn't happen but handle gracefully.
                break;
            }

            if (seq > self.seq) self.seq = seq;
            offset += frame_header_size + data_len;
        }

        // Seek to end for future appends.
        file.seekTo(offset) catch {};
        self.file_size = offset;
    }
};

// ============================================================================
// Mutation encoding (matches Go oplog/encode.go)
// ============================================================================

/// Encode mutations into a byte buffer for the oplog.
/// Format: [count:4LE][{op:1}{key_len:2LE}{val_len:4LE}{key}{val}]...
pub fn encodeMutations(allocator: std.mem.Allocator, mutations: []const Mutation) []u8 {
    // Calculate total size
    var size: usize = 4; // count
    for (mutations) |m| {
        size += 1 + 2 + 4 + m.key.len + m.value.len;
    }

    const buf = allocator.alloc(u8, size) catch unreachable;
    var pos: usize = 0;

    // count
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

/// Decode mutations from an oplog entry.
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

fn testClock() i64 {
    return 1_000_000_000;
}

test "oplog append and read (memory-only)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var log = Log.init(allocator, .{ .now_fn = testClock }, null);
    defer log.deinit();

    const seq1 = log.append(0, "hello");
    try testing.expectEqual(@as(u64, 1), seq1);

    const seq2 = log.append(0, "world");
    try testing.expectEqual(@as(u64, 2), seq2);

    try testing.expectEqual(@as(u64, 2), log.getSeq());

    const entries = log.readAfter(0, 100);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("hello", entries[0].data);
    try testing.expectEqualStrings("world", entries[1].data);

    const entries2 = log.readAfter(1, 100);
    try testing.expectEqual(@as(usize, 1), entries2.len);
    try testing.expectEqualStrings("world", entries2[0].data);
}

test "oplog file persistence and recovery" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const path = "/tmp/corvo-test-oplog.bin";

    // Clean up from any previous run.
    std.fs.cwd().deleteFileZ(path) catch {};
    defer std.fs.cwd().deleteFileZ(path) catch {};

    // Write entries.
    {
        var log = Log.init(allocator, .{ .now_fn = testClock }, path);
        defer log.deinit();

        _ = log.append(0, "entry-1");
        _ = log.append(1, "entry-2");
        _ = log.append(0, "entry-3");

        try testing.expectEqual(@as(u64, 3), log.getSeq());
        try testing.expectEqual(@as(usize, 3), log.len());
    }

    // Recover from file.
    {
        var log = Log.init(allocator, .{ .now_fn = testClock }, path);
        defer log.deinit();

        try testing.expectEqual(@as(u64, 3), log.getSeq());
        try testing.expectEqual(@as(usize, 3), log.len());

        const entries = log.readAfter(0, 100);
        try testing.expectEqual(@as(usize, 3), entries.len);
        try testing.expectEqualStrings("entry-1", entries[0].data);
        try testing.expectEqual(@as(u16, 0), entries[0].shard_id);
        try testing.expectEqualStrings("entry-2", entries[1].data);
        try testing.expectEqual(@as(u16, 1), entries[1].shard_id);
        try testing.expectEqualStrings("entry-3", entries[2].data);

        // Append more entries after recovery.
        const seq4 = log.append(0, "entry-4");
        try testing.expectEqual(@as(u64, 4), seq4);
    }

    // Verify the new entry persisted too.
    {
        var log = Log.init(allocator, .{ .now_fn = testClock }, path);
        defer log.deinit();

        try testing.expectEqual(@as(u64, 4), log.getSeq());
        try testing.expectEqual(@as(usize, 4), log.len());
    }
}

test "oplog truncate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var log = Log.init(allocator, .{ .now_fn = testClock }, null);
    defer log.deinit();

    _ = log.append(0, "a");
    _ = log.append(0, "b");
    _ = log.append(0, "c");
    _ = log.append(0, "d");

    log.truncate(2); // remove seq 1 and 2

    try testing.expectEqual(@as(usize, 2), log.len());
    const entries = log.readAfter(0, 100);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u64, 3), entries[0].seq);
    try testing.expectEqual(@as(u64, 4), entries[1].seq);
}

test "oplog readAfter binary search" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var log = Log.init(allocator, .{ .now_fn = testClock }, null);
    defer log.deinit();

    for (0..100) |_| {
        _ = log.append(0, "x");
    }

    const entries = log.readAfter(95, 100);
    try testing.expectEqual(@as(usize, 5), entries.len);
    try testing.expectEqual(@as(u64, 96), entries[0].seq);
    try testing.expectEqual(@as(u64, 100), entries[4].seq);

    // Read 0 after last.
    const empty = log.readAfter(100, 100);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

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
