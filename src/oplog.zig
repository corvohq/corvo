//! OpLog — append-only replication log with file persistence.
//!
//! Ported from Go internal/oplog/oplog.go + encode.go.
//! The leader appends entries after committing to Talon, and
//! followers consume entries to replay into their own Talon instances.
//!
//! In-memory entries are stored in a bounded ring buffer. When full,
//! the oldest entry is evicted. This guarantees bounded memory usage
//! regardless of throughput. Cluster followers that fall behind the ring
//! must be re-synced via snapshot.
//!
//! Frame format (on disk):
//!   [total_len:4LE][seq:8LE][shard:2LE][timestamp:8LE][data...]
//!
//! total_len covers everything after the 4-byte length prefix.
//! On startup, the file is scanned to rebuild the in-memory ring.
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

/// File-backed append-only operation log with bounded in-memory ring buffer.
///
/// Entries are appended to a file and cached in a fixed-capacity ring.
/// When the ring is full, the oldest entry is evicted (data freed).
/// On startup, the file is scanned to rebuild state (keeping only the
/// last max_entries entries in memory).
/// If no path is given (null), operates in memory-only mode (for tests/sim).
pub const Log = struct {
    mu: std.Thread.Mutex = .{},
    seq: u64 = 0,
    clock: Clock,
    allocator: std.mem.Allocator,

    // Bounded ring buffer for in-memory entries.
    entries: []Entry,
    max_entries: u32,
    head: u32 = 0, // index of oldest entry in ring
    count: u32 = 0, // number of valid entries

    // File backing (null = memory-only).
    file: ?std.fs.File = null,
    file_size: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, clock: Clock, path: ?[*:0]const u8, max_entries: u32) Log {
        assert.check(max_entries > 0, "oplog: max_entries must be > 0", .{});

        const entries = allocator.alloc(Entry, max_entries) catch unreachable;

        var self = Log{
            .clock = clock,
            .entries = entries,
            .max_entries = max_entries,
            .allocator = allocator,
        };

        if (path) |p| {
            self.file = std.fs.cwd().openFileZ(p, .{ .mode = .read_write }) catch
                std.fs.cwd().createFileZ(p, .{ .truncate = false }) catch null;

            if (self.file) |f| {
                // Recover existing entries (capped to max_entries).
                self.recover(f);
                // Pre-allocate disk space to reduce metadata updates on append.
                preallocate(f);
            }
        }

        return self;
    }

    pub fn deinit(self: *Log) void {
        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + i) % self.max_entries;
            self.allocator.free(@constCast(self.entries[idx].data));
        }
        self.allocator.free(self.entries);
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

        // Evict oldest if ring is full.
        if (self.count == self.max_entries) {
            const oldest = &self.entries[self.head];
            self.allocator.free(@constCast(oldest.data));
            self.head = (self.head + 1) % self.max_entries;
            self.count -= 1;
        }

        // Own a copy of the data for in-memory cache.
        const data_copy = self.allocator.dupe(u8, data) catch unreachable;

        const tail = (self.head + self.count) % self.max_entries;
        self.entries[tail] = .{
            .seq = seq,
            .shard_id = shard_id,
            .timestamp = ts,
            .data = data_copy,
        };
        self.count += 1;

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
    /// Returns a contiguous slice from the ring buffer. If the result
    /// would wrap around the ring, only entries up to the end of the
    /// backing array are returned — call again with the last seq to
    /// get the rest. All production callers already loop this way.
    pub fn readAfter(self: *Log, after_seq: u64, max_read: u32) []const Entry {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.count == 0) return &.{};

        // Linear scan for first entry with seq > after_seq.
        // Ring is bounded (max_entries), so this is O(max_entries) worst case.
        var start_offset: u32 = 0;
        while (start_offset < self.count) {
            const idx = (self.head + start_offset) % self.max_entries;
            if (self.entries[idx].seq > after_seq) break;
            start_offset += 1;
        }
        if (start_offset == self.count) return &.{};

        const available = self.count - start_offset;
        const want = @min(available, max_read);

        // Return contiguous slice — clamp at ring wrap boundary.
        const start_idx = (self.head + start_offset) % self.max_entries;
        const until_wrap = self.max_entries - start_idx;
        const can_return = @min(want, until_wrap);

        return self.entries[start_idx..][0..can_return];
    }

    /// Truncate entries with seq <= min_seq.
    /// Frees the data, advances the ring head, and compacts the file.
    pub fn truncate(self: *Log, min_seq: u64) void {
        self.mu.lock();
        defer self.mu.unlock();

        var removed: u32 = 0;
        while (removed < self.count) {
            const idx = (self.head + removed) % self.max_entries;
            if (self.entries[idx].seq > min_seq) break;
            self.allocator.free(@constCast(self.entries[idx].data));
            removed += 1;
        }

        if (removed > 0) {
            self.head = (self.head + removed) % self.max_entries;
            self.count -= removed;
            self.compactLocked();
        }
    }

    /// Rewrite the file with only the remaining ring entries.
    /// Must be called with mu held.
    fn compactLocked(self: *Log) void {
        const f = self.file orelse return;

        f.seekTo(0) catch return;
        self.file_size = 0;

        var i: u32 = 0;
        while (i < self.count) : (i += 1) {
            const idx = (self.head + i) % self.max_entries;
            const e = &self.entries[idx];
            self.writeFrame(f, e.seq, e.shard_id, e.timestamp, e.data);
        }

        // Truncate file to new size.
        const posix_fd = f.handle;
        std.posix.ftruncate(posix_fd, self.file_size) catch {};

        preallocate(f);
    }

    /// Returns the total number of entries in the log.
    pub fn len(self: *Log) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.count;
    }

    // ========================================================================
    // File I/O
    // ========================================================================

    /// Pre-allocate disk blocks via fallocate(2) to avoid filesystem metadata
    /// updates on each append write. Best-effort; failures silently ignored.
    fn preallocate(file: std.fs.File) void {
        if (comptime @import("builtin").os.tag != .linux) return;
        const fd: usize = @intCast(file.handle);
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

        const iov = [_]std.posix.iovec_const{
            .{ .base = &header, .len = frame_header_size },
            .{ .base = data.ptr, .len = data.len },
        };
        _ = file.writev(&iov) catch return;
        self.file_size += frame_header_size + data.len;
    }

    /// Recover entries from an existing file into the ring buffer.
    /// If the file has more entries than max_entries, only the most recent
    /// max_entries are kept in memory (older entries are freed).
    fn recover(self: *Log, file: std.fs.File) void {
        const stat = file.stat() catch return;
        if (stat.size == 0) return;

        if (comptime @import("builtin").os.tag == .linux) {
            const POSIX_FADV_SEQUENTIAL: usize = 2;
            _ = std.os.linux.syscall4(.fadvise64, @intCast(file.handle), 0, 0, POSIX_FADV_SEQUENTIAL);
        }

        file.seekTo(0) catch return;

        var offset: u64 = 0;
        while (offset < stat.size) {
            var header: [frame_header_size]u8 = undefined;
            const header_read = file.readAll(&header) catch break;
            if (header_read < frame_header_size) break;

            const payload_len = std.mem.readInt(u32, header[0..4], .little);
            if (payload_len < entry_header_size) break;
            const data_len = payload_len - entry_header_size;

            const seq = std.mem.readInt(u64, header[4..12], .little);
            const shard_id = std.mem.readInt(u16, header[12..14], .little);
            const ts = std.mem.readInt(i64, header[14..22], .little);

            if (data_len == 0) break;

            const data_buf = self.allocator.alloc(u8, data_len) catch break;
            const data_read = file.readAll(data_buf) catch {
                self.allocator.free(data_buf);
                break;
            };
            if (data_read < data_len) {
                self.allocator.free(data_buf);
                break;
            }

            // Ring insert: evict oldest if full.
            if (self.count == self.max_entries) {
                const oldest_idx = self.head;
                self.allocator.free(@constCast(self.entries[oldest_idx].data));
                self.head = (self.head + 1) % self.max_entries;
                self.count -= 1;
            }

            const tail = (self.head + self.count) % self.max_entries;
            self.entries[tail] = .{
                .seq = seq,
                .shard_id = shard_id,
                .timestamp = ts,
                .data = data_buf,
            };
            self.count += 1;

            if (seq > self.seq) self.seq = seq;
            offset += frame_header_size + data_len;
        }

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

    var log = Log.init(allocator, .{ .now_fn = testClock }, null, 1024);
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

    std.fs.cwd().deleteFileZ(path) catch {};
    defer std.fs.cwd().deleteFileZ(path) catch {};

    // Write entries.
    {
        var log = Log.init(allocator, .{ .now_fn = testClock }, path, 1024);
        defer log.deinit();

        _ = log.append(0, "entry-1");
        _ = log.append(1, "entry-2");
        _ = log.append(0, "entry-3");

        try testing.expectEqual(@as(u64, 3), log.getSeq());
        try testing.expectEqual(@as(usize, 3), log.len());
    }

    // Recover from file.
    {
        var log = Log.init(allocator, .{ .now_fn = testClock }, path, 1024);
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

        const seq4 = log.append(0, "entry-4");
        try testing.expectEqual(@as(u64, 4), seq4);
    }

    // Verify the new entry persisted too.
    {
        var log = Log.init(allocator, .{ .now_fn = testClock }, path, 1024);
        defer log.deinit();

        try testing.expectEqual(@as(u64, 4), log.getSeq());
        try testing.expectEqual(@as(usize, 4), log.len());
    }
}

test "oplog truncate" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var log = Log.init(allocator, .{ .now_fn = testClock }, null, 1024);
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

test "oplog readAfter with ring wrap" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Small ring to force wrapping.
    var log = Log.init(allocator, .{ .now_fn = testClock }, null, 4);
    defer log.deinit();

    // Append 6 entries into ring of size 4 — entries 1,2 evicted.
    for (0..6) |_| {
        _ = log.append(0, "x");
    }

    try testing.expectEqual(@as(usize, 4), log.len());
    try testing.expectEqual(@as(u64, 6), log.getSeq());

    // Ring contains seq 3,4,5,6. readAfter(0) should get them all
    // (may take two calls if wrapping).
    var all_seqs: [4]u64 = undefined;
    var total: usize = 0;
    var after: u64 = 0;
    while (total < 4) {
        const entries = log.readAfter(after, 100);
        if (entries.len == 0) break;
        for (entries) |e| {
            all_seqs[total] = e.seq;
            total += 1;
            after = e.seq;
        }
    }

    try testing.expectEqual(@as(usize, 4), total);
    try testing.expectEqual(@as(u64, 3), all_seqs[0]);
    try testing.expectEqual(@as(u64, 4), all_seqs[1]);
    try testing.expectEqual(@as(u64, 5), all_seqs[2]);
    try testing.expectEqual(@as(u64, 6), all_seqs[3]);
}

test "oplog ring eviction" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var log = Log.init(allocator, .{ .now_fn = testClock }, null, 3);
    defer log.deinit();

    _ = log.append(0, "a"); // seq 1
    _ = log.append(0, "b"); // seq 2
    _ = log.append(0, "c"); // seq 3 — ring full
    _ = log.append(0, "d"); // seq 4 — evicts seq 1

    try testing.expectEqual(@as(usize, 3), log.len());

    // seq 1 is gone — readAfter(0) starts at seq 2
    const entries = log.readAfter(0, 100);
    try testing.expect(entries.len > 0);
    try testing.expectEqual(@as(u64, 2), entries[0].seq);
}

test "oplog binary search (linear scan)" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var log = Log.init(allocator, .{ .now_fn = testClock }, null, 1024);
    defer log.deinit();

    for (0..100) |_| {
        _ = log.append(0, "x");
    }

    // Read after seq 95 — should get 5 entries.
    var total: usize = 0;
    var after: u64 = 95;
    while (true) {
        const entries = log.readAfter(after, 100);
        if (entries.len == 0) break;
        if (total == 0) {
            try testing.expectEqual(@as(u64, 96), entries[0].seq);
        }
        total += entries.len;
        after = entries[entries.len - 1].seq;
    }
    try testing.expectEqual(@as(usize, 5), total);

    // Read 0 after last.
    const empty = log.readAfter(100, 100);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "oplog recovery caps at max_entries" {
    const testing = std.testing;
    const allocator = testing.allocator;
    const path = "/tmp/corvo-test-oplog-cap.bin";

    std.fs.cwd().deleteFileZ(path) catch {};
    defer std.fs.cwd().deleteFileZ(path) catch {};

    // Write 10 entries to file.
    {
        var log = Log.init(allocator, .{ .now_fn = testClock }, path, 1024);
        defer log.deinit();

        for (0..10) |_| {
            _ = log.append(0, "data");
        }
        try testing.expectEqual(@as(usize, 10), log.len());
    }

    // Recover with max_entries=4 — only last 4 entries kept in memory.
    {
        var log = Log.init(allocator, .{ .now_fn = testClock }, path, 4);
        defer log.deinit();

        try testing.expectEqual(@as(u64, 10), log.getSeq());
        try testing.expectEqual(@as(usize, 4), log.len());

        const entries = log.readAfter(0, 100);
        try testing.expect(entries.len > 0);
        try testing.expectEqual(@as(u64, 7), entries[0].seq);
    }
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
