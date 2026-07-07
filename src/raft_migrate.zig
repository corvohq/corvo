//! raft_migrate.zig — one-shot migration of an existing corvo Talon
//! database into Raft mode.
//!
//! What it does:
//!   1. Generates a fresh `instance_uuid` for this node.
//!   2. Initializes Raft Meta (term=0, voted_for=null, instance_uuid,
//!      cluster_id) under "r:meta".
//!   3. Bootstraps an initial cluster config — a synthetic conf_change
//!      entry at index 1, term 0, written via zig-raft's
//!      `bootstrap_initial_config` flag.
//!   4. Sets the FSM `last_applied` to 1 so existing Talon data
//!      (jobs/queues/etc. predating Raft) is treated as "already
//!      applied" and not re-replayed.
//!
//! Followers join with empty storage and catch up via InstallSnapshot
//! from the migrated leader. If you have multiple existing nodes with
//! divergent state, pick ONE as the bootstrap source — the others must
//! be wiped before joining.
//!
//! Usage (in a CLI subcommand):
//!     try raft_migrate.run(allocator, db, .{
//!         .cluster_id = 0xC0FFEE,
//!         .self = .{ .id = "node-1", .uuid = my_uuid },
//!         .all_voters = &peers, // including self
//!     });

const std = @import("std");
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const talon = @import("talon");
const raft = @import("raft");

const RaftStorage = @import("raft_storage.zig").Storage;
const OplogFsm = @import("raft_fsm.zig").OplogFsm;
const Config = raft.Config;
const PeerSpec = raft.PeerSpec;

pub const MigrateParams = struct {
    cluster_id: u64,
    /// All voters in the new cluster, including self. Each carries its
    /// instance_uuid; uuids should be persisted independently of
    /// migration so each node knows its own and its peers'.
    all_voters: []const PeerSpec,
    /// Index into `all_voters` for the local node.
    self_idx: usize,
    /// Optional Raft config; defaults are reasonable for production.
    raft_config: Config = .{
        .election_timeout_min = 300_000_000,
        .election_timeout_max = 600_000_000,
        .heartbeat_interval = 50_000_000,
    },
};

pub const MigrateError = error{
    AlreadyInitialized,
    InvalidParams,
    OutOfMemory,
    StorageError,
};

/// Migrate an existing Talon database into Raft mode. Idempotent in the
/// sense that calling it twice with the same params is rejected (returns
/// `AlreadyInitialized`) — migration is one-way.
pub fn run(allocator: std.mem.Allocator, db: *talon.DB, params: MigrateParams) MigrateError!void {
    if (params.all_voters.len == 0) return MigrateError.InvalidParams;
    if (params.self_idx >= params.all_voters.len) return MigrateError.InvalidParams;

    var storage = RaftStorage.init(allocator, db) catch return MigrateError.StorageError;
    defer storage.deinit();

    // If storage is already initialized (has Meta or log entries), refuse —
    // operator must wipe first to avoid corrupting an existing Raft cluster.
    const meta = storage.storage().loadMeta() catch return MigrateError.StorageError;
    const has_meta = meta.instance_uuid != 0 or meta.cluster_id != 0;
    const has_log = storage.storage().lastIndex() > 0;
    if (has_meta or has_log) return MigrateError.AlreadyInitialized;

    // Self peer info.
    const self_spec = params.all_voters[params.self_idx];

    // Build peer slice (all_voters minus self).
    var peer_buf: [raft.raft.max_peers]PeerSpec = undefined;
    var peer_count: usize = 0;
    for (params.all_voters, 0..) |v, i| {
        if (i == params.self_idx) continue;
        if (peer_count >= peer_buf.len) return MigrateError.InvalidParams;
        peer_buf[peer_count] = v;
        peer_count += 1;
    }

    // Bootstrap: write Meta with our identity, plus the synthetic
    // conf_change entry at index 1, term 0. zig-raft's Node.init does
    // both when bootstrap_initial_config = true on fresh storage.
    var raft_config = params.raft_config;
    raft_config.bootstrap_initial_config = true;

    var node = raft.Node.init(
        allocator,
        self_spec.id,
        self_spec.uuid,
        params.cluster_id,
        peer_buf[0..peer_count],
        raft_config,
        storage.storage(),
    ) catch return MigrateError.StorageError;
    defer node.deinit();

    // After bootstrap, the conf_change entry exists at index 1 in the
    // log. Treat it (and existing Talon data) as already-applied so
    // the FSM doesn't try to re-replay them.
    var fsm = OplogFsm.init(allocator, db) catch return MigrateError.StorageError;
    defer fsm.deinit();

    // Bump last_applied to 1 directly. We can't use fsm.apply (the
    // entry is conf_change; applying it would set last_applied=1, but
    // also bump the storage commit_index, which Raft owns). Easier:
    // manually write the applied counter.
    setLastAppliedTo(db, 1) catch return MigrateError.StorageError;
}

/// Direct write of the FSM's last_applied counter. Used only by
/// migration; runtime apply path goes through OplogFsm.apply().
fn setLastAppliedTo(db: *talon.DB, value: u64) !void {
    var batch = db.newBatch();
    defer db.closeBatch(batch);
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], value, .big);
    batch.set("r:applied", &buf);
    batch.commit();
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

fn synthUuid(id: []const u8) u128 {
    var h: u128 = 0xcbf29ce484222325cbf29ce484222325;
    for (id) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return if (h == 0) 1 else h;
}

test "migrate: fresh DB initialized with meta + bootstrap log entry" {
    const path = "/tmp/corvo-migrate-fresh";
    std.fs.cwd().deleteFile(path) catch {};
    std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
    const db = try talon.DB.open(testing.allocator, path, .{});
    defer {
        db.close();
        std.fs.cwd().deleteFile(path) catch {};
        std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
    }

    // Pre-populate with some "existing" FSM data (simulating pre-Raft state).
    {
        var b = db.newBatch();
        defer db.closeBatch(b);
        b.set("job:1", "preexisting");
        b.set("queue:Q", "{}");
        b.commit();
    }

    const voters = [_]PeerSpec{
        .{ .id = "n1", .uuid = synthUuid("n1") },
        .{ .id = "n2", .uuid = synthUuid("n2") },
        .{ .id = "n3", .uuid = synthUuid("n3") },
    };
    try run(testing.allocator, db, .{
        .cluster_id = 0xC0FFEE,
        .all_voters = &voters,
        .self_idx = 0,
        .raft_config = .{
            .election_timeout_min = 200,
            .election_timeout_max = 400,
            .heartbeat_interval = 50,
        },
    });

    // Verify Meta written.
    var storage = try RaftStorage.init(testing.allocator, db);
    defer storage.deinit();
    const meta = try storage.storage().loadMeta();
    try testing.expectEqual(synthUuid("n1"), meta.instance_uuid);
    try testing.expectEqual(@as(u64, 0xC0FFEE), meta.cluster_id);

    // Verify bootstrap conf_change at index 1.
    try testing.expectEqual(@as(u64, 1), storage.storage().firstIndex());
    try testing.expectEqual(@as(u64, 1), storage.storage().lastIndex());

    // Verify last_applied set.
    var fsm = try OplogFsm.init(testing.allocator, db);
    defer fsm.deinit();
    try testing.expectEqual(@as(u64, 1), fsm.lastApplied());

    // Existing FSM data is still there — migration did NOT touch it.
    var buf: [16]u8 = undefined;
    const got = (try db.getInto("job:1", &buf)).?;
    try testing.expectEqualStrings("preexisting", got);
}

test "migrate: refuses to run on already-migrated DB" {
    const path = "/tmp/corvo-migrate-double";
    std.fs.cwd().deleteFile(path) catch {};
    std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
    const db = try talon.DB.open(testing.allocator, path, .{});
    defer {
        db.close();
        std.fs.cwd().deleteFile(path) catch {};
        std.fs.cwd().deleteFile(path ++ ".vlog") catch {};
    }

    const voters = [_]PeerSpec{
        .{ .id = "n1", .uuid = synthUuid("n1") },
        .{ .id = "n2", .uuid = synthUuid("n2") },
    };
    const params = MigrateParams{
        .cluster_id = 0xC0FFEE,
        .all_voters = &voters,
        .self_idx = 0,
        .raft_config = .{
            .election_timeout_min = 200,
            .election_timeout_max = 400,
            .heartbeat_interval = 50,
        },
    };
    try run(testing.allocator, db, params);
    try testing.expectError(MigrateError.AlreadyInitialized, run(testing.allocator, db, params));
}
