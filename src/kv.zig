//! KV store interface wrapping talon-zig.
//!
//! Ported from Go internal/kv/kv.go + internal/kv/talon.go.
//! Provides Store, WriteBatch, and Iterator abstractions over the
//! underlying B+ tree engine.
//!
//! In corvo, all writes go through WriteBatch (one per Raft apply).
//! Reads come from either the Store directly (KVReader path) or
//! from a WriteBatch (during apply, sees uncommitted writes).

const std = @import("std");
const talon = @import("talon");
const assert_mod = @import("assert.zig");

// ============================================================================
// Mutation types (used by WriteBatch recording + oplog)
// ============================================================================

/// Mutation op types for replication recording.
pub const MutOp = enum(u8) {
    set = 0x01,
    delete = 0x02,
    delete_range = 0x03,
};

/// A single key-value mutation recorded for replication.
pub const Mutation = struct {
    op: MutOp,
    key: []const u8,
    value: []const u8 = "",
};

// ============================================================================
// Store — top-level KV backend
// ============================================================================

pub const Store = struct {
    db: *talon.DB,

    pub fn init(db: *talon.DB) Store {
        return .{ .db = db };
    }

    /// Direct read from committed state. Returns null if not found.
    /// Returned slice is allocated by the DB's allocator — caller must
    /// free with `freeValue()` when done.
    pub fn get(self: *Store, key: []const u8) ?[]const u8 {
        return self.db.get(key);
    }

    /// Free a value returned by `get()`.
    pub fn freeValue(self: *Store, val: []const u8) void {
        self.db.allocator.free(@constCast(val));
    }

    /// Create a new write batch for atomic apply.
    pub fn newBatch(self: *Store) WriteBatch {
        return .{ .batch = self.db.newBatch(), .db = self.db };
    }

    /// Close the store. Caller owns the talon.DB lifecycle.
    pub fn close(self: *Store) void {
        _ = self;
        // Caller owns the talon.DB — don't close it here.
    }
};

// ============================================================================
// WriteBatch — buffered read-write batch
// ============================================================================

pub const WriteBatch = struct {
    batch: *talon.Batch,
    db: *talon.DB,

    /// Optional mutation recording for oplog replication.
    /// When non-null, set/delete/deleteRange record mutations here.
    rec: ?*std.ArrayList(Mutation) = null,
    rec_alloc: std.mem.Allocator = undefined,

    /// Track get() allocations so they can be freed on close.
    get_allocs: std.ArrayList([]const u8) = .{},

    /// Enable mutation recording for this batch.
    pub fn enableRecording(self: *WriteBatch, alloc: std.mem.Allocator, list: *std.ArrayList(Mutation)) void {
        self.rec = list;
        self.rec_alloc = alloc;
    }

    /// Read from batch overlay first, then underlying store.
    /// Returned slice is valid until close().
    pub fn get(self: *WriteBatch, key: []const u8) ?[]const u8 {
        const val = self.batch.get(key) orelse return null;
        // Talon's batch.get() always allocates via db.allocator.dupe().
        // Track for bulk free on close().
        self.get_allocs.append(self.db.allocator, val) catch {};
        return val;
    }

    /// Zero-alloc read: copies value into caller-provided buffer.
    /// Returns slice of `out` on hit, null on miss. No heap allocation.
    pub fn getInto(self: *WriteBatch, key: []const u8, out: []u8) ?[]const u8 {
        return self.batch.getInto(key, out);
    }

    /// Buffer a key-value write.
    pub fn set(self: *WriteBatch, key: []const u8, value: []const u8) void {
        self.batch.set(key, value);
        if (self.rec) |list| {
            const kc = self.rec_alloc.dupe(u8, key) catch unreachable;
            const vc = self.rec_alloc.dupe(u8, value) catch unreachable;
            list.append(self.rec_alloc, .{ .op = .set, .key = kc, .value = vc }) catch unreachable;
        }
    }

    /// Buffer a key deletion.
    pub fn delete(self: *WriteBatch, key: []const u8) void {
        self.batch.delete(key);
        if (self.rec) |list| {
            const kc = self.rec_alloc.dupe(u8, key) catch unreachable;
            list.append(self.rec_alloc, .{ .op = .delete, .key = kc, .value = "" }) catch unreachable;
        }
    }

    /// Buffer a range deletion [start, end).
    pub fn deleteRange(self: *WriteBatch, start: []const u8, end: []const u8) void {
        self.batch.deleteRange(start, end);
        if (self.rec) |list| {
            const sc = self.rec_alloc.dupe(u8, start) catch unreachable;
            const ec = self.rec_alloc.dupe(u8, end) catch unreachable;
            list.append(self.rec_alloc, .{ .op = .delete_range, .key = sc, .value = ec }) catch unreachable;
        }
    }

    /// Create a forward-only iterator over [lower, upper).
    /// Pass null for unbounded on either side.
    pub fn newIter(self: *WriteBatch, lower: ?[]const u8, upper: ?[]const u8) Iterator {
        return .{ .iter = self.batch.newIterBounded(lower, upper) };
    }

    /// Encode the batch overlay directly into a buffer for replication.
    /// Zero-copy: reads key/value slices from Talon's arena (valid until commit).
    /// Returns (encoded_len, mutation_count). Does NOT write the count header —
    /// caller accumulates across sub-batches and writes one header.
    /// Entry format: {op:1}{key_len:2LE}{val_len:4LE}{key}{val}
    pub fn encodeOverlay(self: *WriteBatch, buf: []u8) struct { len: usize, count: u32 } {
        const writes = self.batch.writes.items;
        const delete_ranges = self.batch.delete_ranges.items;
        const total = writes.len + delete_ranges.len;
        if (total == 0) return .{ .len = 0, .count = 0 };

        var pos: usize = 0;

        for (writes) |m| {
            const op: u8 = if (m.value != null) 0x01 else 0x02;
            const key = m.key;
            const val = m.value orelse "";

            const entry_size = 1 + 2 + 4 + key.len + val.len;
            if (pos + entry_size > buf.len) return .{ .len = pos, .count = @intCast(total) };

            buf[pos] = op;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(key.len), .little);
            pos += 2;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(val.len), .little);
            pos += 4;
            @memcpy(buf[pos..][0..key.len], key);
            pos += key.len;
            if (val.len > 0) {
                @memcpy(buf[pos..][0..val.len], val);
                pos += val.len;
            }
        }

        for (delete_ranges) |r| {
            const entry_size = 1 + 2 + 4 + r.start.len + r.end.len;
            if (pos + entry_size > buf.len) return .{ .len = pos, .count = @intCast(total) };

            buf[pos] = 0x03;
            pos += 1;
            std.mem.writeInt(u16, buf[pos..][0..2], @intCast(r.start.len), .little);
            pos += 2;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(r.end.len), .little);
            pos += 4;
            @memcpy(buf[pos..][0..r.start.len], r.start);
            pos += r.start.len;
            @memcpy(buf[pos..][0..r.end.len], r.end);
            pos += r.end.len;
        }

        return .{ .len = pos, .count = @intCast(total) };
    }

    /// Sort the write overlay for O(log n) reads instead of O(n).
    /// Call between handler invocations in a sub-batch to avoid
    /// linear scan degradation as writes accumulate.
    pub fn sortOverlay(self: *WriteBatch) void {
        self.batch.ensureSorted();
    }

    /// Atomically commit all buffered writes.
    pub fn commit(self: *WriteBatch) void {
        self.batch.commit();
    }

    /// Release batch resources without committing.
    pub fn close(self: *WriteBatch) void {
        for (self.get_allocs.items) |val| {
            self.db.allocator.free(@constCast(val));
        }
        self.get_allocs.deinit(self.db.allocator);
        self.db.closeBatch(self.batch);
    }

    /// Return recorded mutations (only valid after enableRecording + writes).
    pub fn getMutations(self: *const WriteBatch) []const Mutation {
        if (self.rec) |list| return list.items;
        return &.{};
    }

    /// Free recorded mutation data.
    pub fn freeMutations(self: *WriteBatch) void {
        if (self.rec) |list| {
            for (list.items) |m| {
                if (m.key.len > 0) self.rec_alloc.free(@constCast(m.key));
                if (m.value.len > 0 and m.op != .delete) self.rec_alloc.free(@constCast(m.value));
            }
            list.clearRetainingCapacity();
        }
    }
};

// ============================================================================
// Iterator — forward-only scan
// ============================================================================

pub const Iterator = struct {
    iter: talon.Iterator,

    /// Position at the first key >= lower bound. Returns false if empty.
    pub fn first(self: *Iterator) bool {
        return self.iter.first();
    }

    /// Advance to the next key. Returns false if exhausted.
    pub fn next(self: *Iterator) bool {
        return self.iter.next();
    }

    /// Whether the iterator is positioned at a valid entry.
    pub fn valid(self: *const Iterator) bool {
        return self.iter.valid;
    }

    /// Current key. Only valid when valid() is true.
    pub fn key(self: *const Iterator) []const u8 {
        return self.iter.key();
    }

    /// Current value. Only valid when valid() is true.
    pub fn value(self: *const Iterator) []const u8 {
        return self.iter.value();
    }

    /// Release iterator resources.
    pub fn close(self: *Iterator) void {
        self.iter.close();
    }
};

// ============================================================================
// Tests (require talon-zig to be linked)
// ============================================================================

test "Store basic get/set" {
    const db = try talon.DB.open(std.testing.allocator, "/tmp/corvo-kv-test", .{});
    defer {
        db.close();
        std.fs.cwd().deleteTree("/tmp/corvo-kv-test") catch {};
    }

    var store = Store.init(db);
    defer store.close();

    // Write
    var batch = store.newBatch();
    batch.set("hello", "world");
    batch.commit();
    batch.close();

    // Read
    const val = store.get("hello");
    try std.testing.expect(val != null);
    defer store.freeValue(val.?);
    try std.testing.expectEqualStrings("world", val.?);

    // Missing key
    try std.testing.expect(store.get("missing") == null);
}

test "WriteBatch read-your-writes" {
    const db = try talon.DB.open(std.testing.allocator, "/tmp/corvo-kv-ryw-test", .{});
    defer {
        db.close();
        std.fs.cwd().deleteTree("/tmp/corvo-kv-ryw-test") catch {};
    }

    var store = Store.init(db);
    var batch = store.newBatch();
    defer batch.close();

    batch.set("key1", "val1");
    const v = batch.get("key1");
    try std.testing.expect(v != null);
    // get() results freed automatically by batch.close()
    try std.testing.expectEqualStrings("val1", v.?);
}

test "Iterator scan" {
    const db = try talon.DB.open(std.testing.allocator, "/tmp/corvo-kv-iter-test", .{});
    defer {
        db.close();
        std.fs.cwd().deleteTree("/tmp/corvo-kv-iter-test") catch {};
    }

    var store = Store.init(db);

    // Write some keys
    var batch = store.newBatch();
    batch.set("a|1", "v1");
    batch.set("a|2", "v2");
    batch.set("a|3", "v3");
    batch.set("b|1", "other");
    batch.commit();
    batch.close();

    // Scan a| prefix
    var batch2 = store.newBatch();
    defer batch2.close();
    var iter = batch2.newIter("a|", "a}");
    defer iter.close();

    var count: usize = 0;
    var found_first = iter.first();
    while (found_first or iter.valid()) {
        count += 1;
        found_first = false;
        if (!iter.next()) break;
    }
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "WriteBatch delete" {
    const db = try talon.DB.open(std.testing.allocator, "/tmp/corvo-kv-del-test", .{});
    defer {
        db.close();
        std.fs.cwd().deleteTree("/tmp/corvo-kv-del-test") catch {};
    }

    var store = Store.init(db);

    var batch = store.newBatch();
    batch.set("key", "val");
    batch.commit();
    batch.close();

    // Delete and verify
    var batch2 = store.newBatch();
    batch2.delete("key");
    try std.testing.expect(batch2.get("key") == null);
    batch2.commit();
    batch2.close();

    try std.testing.expect(store.get("key") == null);
}
