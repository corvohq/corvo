//! raft_fsm.zig — Raft-committed-entry → Talon apply path.
//!
//! Replaces replicator.zig's apply role. Each Raft entry's `data` carries
//! a list of corvo Mutations (encoded via oplog.encodeMutations). On
//! apply, decode and write under one Talon batch. Idempotent by entry
//! index — if `entry.index <= last_applied`, skip.
//!
//! Snapshot semantics:
//!   serialize: dump every Talon key NOT under "r:" (raft state) as a
//!     `set` mutation. This becomes the snapshot blob.
//!   load: clear all non-"r:" keys, then apply the encoded mutations.
//!
//! TigerStyle: bounded-loop apply, asserts on idempotency invariant
//! (last_applied monotonic, entry.index sequential).

const std = @import("std");
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const talon = @import("talon");
const raft = @import("raft");
const kv = @import("kv.zig");
const oplog = @import("oplog.zig");

const Entry = raft.messages.Entry;
const Mutation = kv.Mutation;
const MutOp = kv.MutOp;

/// Talon key holding the FSM's last_applied index.
const key_applied = "r:applied";
/// Cap on entries applied per `applyMany` call. Keeps the per-tick budget
/// bounded — large backlogs apply over multiple ticks.
pub const max_apply_per_tick: usize = 256;
/// Raft state prefix (mirrors raft_storage.zig). Snapshot serialization
/// excludes any keys under this prefix so FSM and Raft state stay separate.
const raft_prefix: []const u8 = "r:";
/// Smallest key strictly greater than every "r:..." key (':' = 0x3A;
/// ';' = 0x3B). Used as exclusive upper bound when scanning post-prefix
/// keys.
const raft_prefix_upper: []const u8 = "r;";

pub const FsmError = error{
    DecodeFailed,
    ApplyFailed,
    IndexRegression,
    OutOfMemory,
};

pub const OplogFsm = struct {
    db: *talon.DB,
    allocator: std.mem.Allocator,
    last_applied: u64,

    pub fn init(allocator: std.mem.Allocator, db: *talon.DB) !OplogFsm {
        var self: OplogFsm = .{
            .db = db,
            .allocator = allocator,
            .last_applied = 0,
        };
        try self.loadAppliedCache();
        return self;
    }

    pub fn deinit(self: *OplogFsm) void {
        _ = self;
    }

    fn loadAppliedCache(self: *OplogFsm) !void {
        var buf: [8]u8 = undefined;
        const got = (self.db.getInto(key_applied, &buf) catch return FsmError.DecodeFailed) orelse return;
        if (got.len != 8) return FsmError.DecodeFailed;
        self.last_applied = std.mem.readInt(u64, buf[0..8], .big);
    }

    /// Apply one committed entry. Idempotent: re-applying an already
    /// applied entry is a no-op. Conf-change entries are handled
    /// internally by the Raft FSM (we skip them here).
    pub fn apply(self: *OplogFsm, entry: Entry) FsmError!void {
        check(entry.index > 0, "entry.index must be 1-based, got 0", .{});
        if (entry.index <= self.last_applied) return; // already applied
        // Strict monotonic: gap means caller skipped an entry, which is a bug.
        check(entry.index == self.last_applied + 1, "entry.index gap: last_applied={d}, index={d}", .{ self.last_applied, entry.index });
        // Conf changes are applied by the Raft FSM internally; skip here.
        if (entry.type_ == .conf_change) {
            try self.bumpApplied(entry.index);
            return;
        }
        if (entry.data.len == 0) {
            try self.bumpApplied(entry.index);
            return;
        }
        const muts = oplog.decodeMutations(self.allocator, entry.data) catch return FsmError.DecodeFailed;
        defer self.allocator.free(muts);
        try self.applyMutations(muts, entry.index);
    }

    /// Apply many committed entries in one Talon batch. Bounded by
    /// `max_apply_per_tick` — caller is expected to call repeatedly when
    /// the queue is deep.
    pub fn applyMany(self: *OplogFsm, entries: []const Entry) FsmError!usize {
        if (entries.len == 0) return 0;
        const n = @min(entries.len, max_apply_per_tick);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.apply(entries[i]);
        }
        return n;
    }

    fn applyMutations(self: *OplogFsm, muts: []Mutation, entry_index: u64) FsmError!void {
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        for (muts) |m| {
            switch (m.op) {
                .set => batch.set(m.key, m.value),
                .delete => batch.delete(m.key),
                .delete_range => batch.deleteRange(m.key, m.value),
            }
        }
        // Bump last_applied in the same batch — atomic with the writes.
        var applied_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, applied_buf[0..8], entry_index, .big);
        batch.set(key_applied, &applied_buf);
        batch.commit();
        self.last_applied = entry_index;
    }

    fn bumpApplied(self: *OplogFsm, entry_index: u64) FsmError!void {
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        var applied_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, applied_buf[0..8], entry_index, .big);
        batch.set(key_applied, &applied_buf);
        batch.commit();
        self.last_applied = entry_index;
    }

    pub fn lastApplied(self: *const OplogFsm) u64 {
        return self.last_applied;
    }

    // -------------------------------------------------------------------
    // Snapshot.
    // -------------------------------------------------------------------

    /// Serialize all FSM-owned Talon state (everything NOT under "r:")
    /// into a snapshot blob using oplog's mutation encoding. Caller owns
    /// the returned slice. Uses an internal arena for transient key/value
    /// copies — freed before return.
    pub fn snapshot(self: *OplogFsm) FsmError![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var muts: std.ArrayList(Mutation) = .{};
        try self.collectRange(a, &muts, null, raft_prefix);
        try self.collectRange(a, &muts, raft_prefix_upper, null);
        // encodeMutations allocates fresh memory in self.allocator for the
        // returned slice — caller owns it. Arena cleanup frees the temp copies.
        const buf = oplog.encodeMutations(self.allocator, muts.items);
        return buf;
    }

    fn collectRange(self: *OplogFsm, a: std.mem.Allocator, out: *std.ArrayList(Mutation), lower: ?[]const u8, upper: ?[]const u8) FsmError!void {
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        var iter = batch.newIterBounded(lower, upper);
        defer iter.close();
        if (!iter.first()) return;
        while (true) {
            const k = iter.key();
            const v = iter.value();
            const k_copy = a.alloc(u8, k.len) catch return FsmError.OutOfMemory;
            @memcpy(k_copy, k);
            const v_copy = a.alloc(u8, v.len) catch return FsmError.OutOfMemory;
            @memcpy(v_copy, v);
            out.append(a, .{ .op = .set, .key = k_copy, .value = v_copy }) catch return FsmError.OutOfMemory;
            if (!iter.next()) break;
        }
    }

    /// Load snapshot bytes — clears all FSM-owned keys, then writes the
    /// encoded mutations. Resets `last_applied` to `applied_at_snapshot`.
    pub fn loadSnapshot(self: *OplogFsm, bytes: []const u8, applied_at_snapshot: u64) FsmError!void {
        const muts = oplog.decodeMutations(self.allocator, bytes) catch return FsmError.DecodeFailed;
        defer self.allocator.free(muts);
        var batch = self.db.newBatch();
        defer self.db.closeBatch(batch);
        // Wipe every key NOT under the raft prefix.
        const empty: []const u8 = "";
        const max_key: []const u8 = "\xff\xff\xff\xff";
        batch.deleteRange(empty, raft_prefix);
        batch.deleteRange(raft_prefix_upper, max_key);
        // Write the snapshot mutations.
        for (muts) |m| {
            switch (m.op) {
                .set => batch.set(m.key, m.value),
                .delete => batch.delete(m.key),
                .delete_range => batch.deleteRange(m.key, m.value),
            }
        }
        // Bump applied to the snapshot's index.
        var applied_buf: [8]u8 = undefined;
        std.mem.writeInt(u64, applied_buf[0..8], applied_at_snapshot, .big);
        batch.set(key_applied, &applied_buf);
        batch.commit();
        self.last_applied = applied_at_snapshot;
    }
};

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

const TestEnv = struct {
    db: *talon.DB,
    fsm: OplogFsm,
    path: []const u8,

    fn init(allocator: std.mem.Allocator, path: []const u8) !TestEnv {
        std.fs.cwd().deleteFile(path) catch {};
        var vlog_buf: [256]u8 = undefined;
        const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{path}) catch unreachable;
        std.fs.cwd().deleteFile(vlog_path) catch {};
        const db = try talon.DB.open(allocator, path, .{});
        const fsm = try OplogFsm.init(allocator, db);
        return .{ .db = db, .fsm = fsm, .path = path };
    }

    fn deinit(self: *TestEnv) void {
        self.fsm.deinit();
        self.db.close();
        std.fs.cwd().deleteFile(self.path) catch {};
        var vlog_buf: [256]u8 = undefined;
        const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{self.path}) catch unreachable;
        std.fs.cwd().deleteFile(vlog_path) catch {};
    }
};

fn buildEntry(allocator: std.mem.Allocator, idx: u64, muts: []const Mutation) !Entry {
    const data = oplog.encodeMutations(allocator, muts);
    return .{ .term = 1, .index = idx, .data = data };
}

fn freeEntry(allocator: std.mem.Allocator, e: Entry) void {
    allocator.free(@constCast(e.data));
}

test "fsm: apply set + delete idempotently" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-fsm-apply");
    defer env.deinit();

    const e1 = try buildEntry(testing.allocator, 1, &.{
        .{ .op = .set, .key = "job:1", .value = "alpha" },
        .{ .op = .set, .key = "job:2", .value = "beta" },
    });
    defer freeEntry(testing.allocator, e1);
    try env.fsm.apply(e1);
    try testing.expectEqual(@as(u64, 1), env.fsm.lastApplied());

    var buf: [16]u8 = undefined;
    const got1 = (try env.db.getInto("job:1", &buf)).?;
    try testing.expectEqualStrings("alpha", got1);

    // Re-applying the same entry is a no-op.
    try env.fsm.apply(e1);
    try testing.expectEqual(@as(u64, 1), env.fsm.lastApplied());

    const e2 = try buildEntry(testing.allocator, 2, &.{
        .{ .op = .delete, .key = "job:1" },
    });
    defer freeEntry(testing.allocator, e2);
    try env.fsm.apply(e2);
    try testing.expectEqual(@as(u64, 2), env.fsm.lastApplied());
    try testing.expect((try env.db.getInto("job:1", &buf)) == null);
}

test "fsm: applyMany respects budget" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-fsm-many");
    defer env.deinit();
    var entries: [3]Entry = undefined;
    inline for (0..3) |i| {
        const muts = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
        entries[i] = try buildEntry(testing.allocator, @as(u64, i + 1), &muts);
    }
    defer for (entries) |e| freeEntry(testing.allocator, e);
    const n = try env.fsm.applyMany(&entries);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u64, 3), env.fsm.lastApplied());
}

test "fsm: persistence across reopen" {
    const path = "/tmp/corvo-fsm-reopen";
    std.fs.cwd().deleteFile(path) catch {};
    std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
    {
        const db = try talon.DB.open(testing.allocator, path, .{});
        defer db.close();
        var fsm = try OplogFsm.init(testing.allocator, db);
        defer fsm.deinit();
        const e = try buildEntry(testing.allocator, 1, &.{
            .{ .op = .set, .key = "queue:default", .value = "{}" },
        });
        defer freeEntry(testing.allocator, e);
        try fsm.apply(e);
    }
    {
        const db = try talon.DB.open(testing.allocator, path, .{});
        defer {
            db.close();
            std.fs.cwd().deleteFile(path) catch {};
            std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
        }
        var fsm = try OplogFsm.init(testing.allocator, db);
        defer fsm.deinit();
        try testing.expectEqual(@as(u64, 1), fsm.lastApplied());
        var buf: [16]u8 = undefined;
        const got = (try db.getInto("queue:default", &buf)).?;
        try testing.expectEqualStrings("{}", got);
    }
}

test "fsm: snapshot round-trip preserves FSM state" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-fsm-snap");
    defer env.deinit();
    // Seed via apply.
    const e = try buildEntry(testing.allocator, 1, &.{
        .{ .op = .set, .key = "job:1", .value = "alpha" },
        .{ .op = .set, .key = "job:2", .value = "beta" },
        .{ .op = .set, .key = "queue:Q", .value = "{}" },
    });
    defer freeEntry(testing.allocator, e);
    try env.fsm.apply(e);

    // Take snapshot.
    const snap = try env.fsm.snapshot();
    defer testing.allocator.free(snap);

    // Mutate state after snapshot to prove load reverts.
    const e2 = try buildEntry(testing.allocator, 2, &.{
        .{ .op = .set, .key = "job:1", .value = "MODIFIED" },
        .{ .op = .delete, .key = "job:2" },
    });
    defer freeEntry(testing.allocator, e2);
    try env.fsm.apply(e2);
    try testing.expectEqual(@as(u64, 2), env.fsm.lastApplied());

    // Load snapshot — state reverts to point of snapshot.
    try env.fsm.loadSnapshot(snap, 1);
    try testing.expectEqual(@as(u64, 1), env.fsm.lastApplied());
    var buf: [32]u8 = undefined;
    const got1 = (try env.db.getInto("job:1", &buf)).?;
    try testing.expectEqualStrings("alpha", got1);
    const got2 = (try env.db.getInto("job:2", &buf)).?;
    try testing.expectEqualStrings("beta", got2);
}

test "fsm: snapshot excludes raft state" {
    var env = try TestEnv.init(testing.allocator, "/tmp/corvo-fsm-snap-excl");
    defer env.deinit();
    // Manually plant a raft-namespaced key + an FSM key.
    {
        var batch = env.db.newBatch();
        defer env.db.closeBatch(batch);
        batch.set("r:meta", "raft-bookkeeping");
        batch.set("job:1", "fsm-data");
        batch.commit();
    }
    const snap = try env.fsm.snapshot();
    defer testing.allocator.free(snap);
    // Decoded snap should contain "job:1" but not "r:meta".
    const decoded = try oplog.decodeMutations(testing.allocator, snap);
    defer testing.allocator.free(decoded);
    var saw_job: bool = false;
    var saw_raft: bool = false;
    for (decoded) |m| {
        if (std.mem.eql(u8, m.key, "job:1")) saw_job = true;
        if (std.mem.eql(u8, m.key, "r:meta")) saw_raft = true;
    }
    try testing.expect(saw_job);
    try testing.expect(!saw_raft);
}
