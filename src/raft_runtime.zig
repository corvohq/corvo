//! raft_runtime.zig — composes Raft Storage + Transport + FSM + Batcher
//! + Node into a single-threaded runtime usable by main.zig.
//!
//! Tick loop responsibilities:
//!   1. Drain inbound transport: for each `Incoming`, call `node.step`.
//!     Forward outputs.
//!   2. Call `node.tick(now)` for time-based progress (heartbeats, elections).
//!     Forward outputs.
//!   3. If leader and pending proposals exist, `batcher.flush(node)`.
//!   4. Pull `node.ready()`. If a snapshot landed, hand it to FSM. Else
//!     apply committed entries via FSM.
//!   5. Fire batcher completions for the new commit_index.
//!
//! This module does NOT own the network. Callers (main.zig, tests, sim)
//! are responsible for moving bytes between sockets and `transport`. For
//! single-node tests, the InMemRouter from raft_transport.zig is enough;
//! for production, Phase 5b will add a single-threaded TCP transport
//! built on io.zig.

const std = @import("std");
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const talon = @import("talon");
const raft = @import("raft");
const kv = @import("kv.zig");
const oplog = @import("oplog.zig");

const RaftStorage = @import("raft_storage.zig").Storage;
const RaftTransport = @import("raft_transport.zig").Transport;
const OplogFsm = @import("raft_fsm.zig").OplogFsm;
const Batcher = @import("raft_batcher.zig").Batcher;
const BatcherError = @import("raft_batcher.zig").BatcherError;
const Completion = @import("raft_batcher.zig").Completion;

const Mutation = kv.Mutation;
const Node = raft.Node;
const Config = raft.Config;
const PeerSpec = raft.PeerSpec;
const Role = raft.Role;

pub const RuntimeError = error{
    NotLeader,
    NotInitialized,
    OutOfMemory,
} || BatcherError;

/// Inputs needed to bring a Raft node up.
pub const InitParams = struct {
    /// Stable identifier for this node within its cluster.
    node_id: []const u8,
    /// 128-bit instance UUID — must be persisted forever for *this* node.
    /// On fresh storage, generate once and write through the storage layer.
    instance_uuid: u128,
    /// Cluster identifier shared by all voters in this cluster.
    cluster_id: u64,
    /// Other voters in the cluster (do not include self).
    peers: []const PeerSpec,
    /// Raft config (timeouts, max_entries_per_msg, etc.).
    raft_config: Config,
    /// Bootstrap behavior — write initial conf_change at index 1 if storage
    /// is fresh. Set true only on cluster bootstrap; false on rejoin.
    bootstrap_initial_config: bool = false,
    /// Log-compaction trigger: once this many entries have been applied
    /// beyond the last snapshot, serialize the FSM into a snapshot and
    /// drop the covered log prefix. 0 disables compaction (tests that
    /// inspect the raw log).
    snapshot_threshold_entries: u64 = 10_000,
};

/// Reasonable defaults for production. Election timeout 300-600ms, heartbeat 50ms.
pub fn defaultConfig() Config {
    return .{
        .election_timeout_min = 300_000_000,
        .election_timeout_max = 600_000_000,
        .heartbeat_interval = 50_000_000,
        .bootstrap_initial_config = false,
        // Lowered from zig-raft's 64 so the batcher's per-entry byte budget
        // fits any single client op (raft_batcher livelock guard).
        .max_entries_per_msg = @import("raft_batcher.zig").entries_per_msg,
    };
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    db: *talon.DB,

    // Heap-pinned: the Node captures a pointer to the Storage adapter at
    // init, and Runtime is returned (moved) by value — an inline field
    // would leave the Node reading a dead stack copy while Runtime mutates
    // a diverged one.
    storage: *RaftStorage,
    transport: RaftTransport,
    fsm: OplogFsm,
    batcher: Batcher,
    node: Node,

    // Last role observed at the last tick — used to detect step-down so
    // we can fail in-flight batcher completions.
    last_role: Role = .follower,

    // Identity, retained for validating inbound messages at the trust boundary
    // (see pumpInbound). The Raft library's step() assumes callers only hand it
    // messages addressed to this node from a peer; hostile network input must be
    // filtered here first or its debug asserts abort the process.
    cluster_id: u64,
    instance_uuid: u128,

    // Compaction trigger — see maybeCompact. 0 disables.
    snapshot_threshold_entries: u64,

    pub fn init(allocator: std.mem.Allocator, db: *talon.DB, params: InitParams) !Runtime {
        var raft_config = params.raft_config;
        raft_config.bootstrap_initial_config = params.bootstrap_initial_config;
        // Livelock guard, runtime side: the batcher's per-entry byte cap
        // assumes at most entries_per_msg entries per AppendEntries; packing
        // more could assemble an untransmittable message. The Runtime owns
        // the batcher, so it owns this knob — overridden unconditionally
        // rather than trusting every Config constructor to remember it.
        raft_config.max_entries_per_msg = @import("raft_batcher.zig").entries_per_msg;

        const storage = try allocator.create(RaftStorage);
        errdefer allocator.destroy(storage);
        storage.* = try RaftStorage.init(allocator, db);
        errdefer storage.deinit();
        var transport = try RaftTransport.init(allocator);
        errdefer transport.deinit();
        var fsm = try OplogFsm.init(allocator, db);
        errdefer fsm.deinit();
        var batcher = Batcher.init(allocator);
        errdefer batcher.deinit();

        var node = try Node.init(
            allocator,
            params.node_id,
            params.instance_uuid,
            params.cluster_id,
            params.peers,
            raft_config,
            storage.storage(),
        );
        errdefer node.deinit();
        try node.recoverConfig();

        // A snapshot can be durable while the FSM still lags behind it — a
        // crash between InstallSnapshot persistence (inside node.step) and
        // the FSM swap (applyReady) loses the volatile apply-pending flag,
        // so ready() would never re-deliver it. The snapshot is committed
        // state by definition; finish the swap now.
        if (storage.snap_meta) |sm| {
            if (sm.last_included_index > fsm.lastApplied()) {
                const snap = storage.storage().loadSnapshot().?;
                try fsm.loadSnapshot(snap.data, sm.last_included_index);
            }
        }

        // Restart recovery: the raft library initializes commit_index and
        // last_applied to 0 and re-delivers committed entries via ready().
        // Once the log has been compacted, the prefix [1, snapshot_index]
        // no longer exists, so that re-delivery window would reach into
        // compacted history and ready() would fail on every tick. The FSM's
        // durable last_applied counts exactly the entries this node already
        // applied — and applyReady only ever applies committed entries — so
        // resuming both counters from it is safe and also skips the
        // redundant replay of the surviving log suffix.
        const applied = fsm.lastApplied();
        check(
            applied <= storage.storage().lastIndex(),
            "fsm applied {d} beyond log end {d}",
            .{ applied, storage.storage().lastIndex() },
        );
        if (applied > node.commit_index) node.commit_index = applied;
        if (applied > node.last_applied) node.last_applied = applied;

        return .{
            .allocator = allocator,
            .db = db,
            .storage = storage,
            .transport = transport,
            .fsm = fsm,
            .batcher = batcher,
            .node = node,
            .last_role = node.role,
            .cluster_id = params.cluster_id,
            .instance_uuid = params.instance_uuid,
            .snapshot_threshold_entries = params.snapshot_threshold_entries,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.batcher.failAll();
        self.batcher.deinit();
        self.node.deinit();
        self.fsm.deinit();
        self.transport.deinit();
        self.storage.deinit();
        self.allocator.destroy(self.storage);
    }

    /// Convenience: install a send hook on the transport.
    pub fn setSend(
        self: *Runtime,
        ctx: *anyopaque,
        send: @import("raft_transport.zig").SendFn,
    ) void {
        self.transport.setSend(ctx, send);
    }

    /// Enqueue a proposal for the next flush. Returns NotLeader if this
    /// node is not currently the leader. `locally_applied` = the caller has
    /// already committed these mutations to talon (the pipeline's contract);
    /// on commit the FSM records the entry applied without re-writing data.
    pub fn propose(self: *Runtime, mutations: []const Mutation, completion: Completion, locally_applied: bool) RuntimeError!void {
        if (!self.node.isLeader()) return RuntimeError.NotLeader;
        try self.batcher.enqueue(mutations, completion, locally_applied);
    }

    /// Drive one full tick. Caller passes the current monotonic timestamp
    /// (nanoseconds). Returns nothing — outbound messages already flowed
    /// through the registered send hook.
    pub fn tick(self: *Runtime, now: i64) !void {
        try self.handleStepDown();
        try self.pumpInbound(now);
        try self.tickNode(now);
        // Re-check step-down BEFORE applying commits. pumpInbound/tickNode can
        // demote us this tick (a higher-term AppendEntries truncates our
        // uncommitted entries and installs the new leader's). applyReady below
        // fires batcher completions by index; without failing our in-flight
        // proposals here first, a truncated-then-overwritten index would be
        // reported to the client as a durable commit of an entry that was in
        // fact discarded. handleStepDown at the top only catches the PRIOR
        // tick's demotion — too late for commits landing this tick.
        try self.handleStepDown();
        try self.flushIfLeader(now);
        try self.applyReady();
        try self.maybeCompact();
        // All entry-data slices returned by storage.getEntries during this
        // tick have been encoded onto the wire and applied to the FSM —
        // safe to reclaim arena memory.
        self.storage.releaseReads();
    }

    fn handleStepDown(self: *Runtime) !void {
        const role = self.node.role;
        if (self.last_role == .leader and role != .leader) {
            // We just stepped down — the entries we proposed but didn't
            // commit are no longer ours to complete.
            self.batcher.failAll();
        }
        self.last_role = role;
    }

    fn pumpInbound(self: *Runtime, now: i64) !void {
        const tr = self.transport.transport();
        const self_id = self.node.status().id;
        while (tr.recv()) |incoming| {
            if (!self.acceptInbound(incoming.msg, self_id)) continue;
            // A single message that step() can't process (e.g. LogTooShort on a
            // stale AppendEntries overlapping a compacted log) must not abort the
            // tick or crash the node — Raft tolerates message loss, so drop it
            // and move on. The sender retries on the next heartbeat.
            const out = self.node.step(incoming.msg, now) catch continue;
            for (out) |m| tr.send(m.to, m);
        }
    }

    /// Trust-boundary filter for network-delivered Raft messages. `node.step`
    /// asserts the message is addressed to this node from a distinct peer and
    /// (permissively) matches cluster/uuid; those asserts abort the process on
    /// hostile input, and the permissive zero-value escape hatch lets an
    /// attacker bypass the cluster/uuid guard by sending zeros. Enforce strictly
    /// here so only well-addressed, same-cluster messages reach the state machine.
    fn acceptInbound(self: *const Runtime, msg: raft.Message, self_id: []const u8) bool {
        if (msg.to.len == 0 or msg.from.len == 0) return false;
        if (!std.mem.eql(u8, msg.to, self_id)) return false; // not addressed to us
        if (std.mem.eql(u8, msg.from, self_id)) return false; // spoofed self-origin
        // Reject cross-cluster traffic. Our cluster_id is non-zero in production,
        // so a message carrying cluster_id 0 (the library's test-mode bypass) is
        // dropped rather than accepted.
        if (self.cluster_id != 0 and msg.cluster_id != self.cluster_id) return false;
        // If we carry a stable instance UUID, require the sender to have targeted
        // it (when it set to_uuid at all).
        if (self.instance_uuid != 0 and msg.to_uuid != 0 and msg.to_uuid != self.instance_uuid) return false;
        return true;
    }

    fn tickNode(self: *Runtime, now: i64) !void {
        const out = try self.node.tick(now);
        const tr = self.transport.transport();
        for (out) |m| tr.send(m.to, m);
    }

    fn flushIfLeader(self: *Runtime, now: i64) !void {
        _ = now;
        if (!self.node.isLeader()) return;
        if (self.batcher.pendingCount() == 0) return;
        try self.batcher.flush(@ptrCast(self), proposeBridge);
    }

    fn applyReady(self: *Runtime) !void {
        const r = try self.node.ready();
        if (r.snapshot) |snap| {
            try self.fsm.loadSnapshot(snap.data, snap.meta.last_included_index);
            self.node.advance(snap.meta.last_included_index);
            // After a snapshot replaces FSM state wholesale, fail any
            // in-flight batcher commits — they predate the snapshot view.
            self.batcher.failAll();
            return;
        }
        if (r.committed.len == 0) return;
        // Apply EVERY committed entry through the FSM, in order. The FSM
        // enforces gapless application (index == last_applied + 1) and no-ops
        // conf_change / empty entries internally while still advancing
        // last_applied. Skipping conf_change here (as before) left a hole in
        // the applied sequence, so the next data entry tripped the gap check
        // and panicked every node — fatal for any cluster that bootstraps an
        // initial config or performs a membership change.
        var max_committed: u64 = 0;
        for (r.committed) |entry| {
            // Leader fast-path (docs/raft-wiring.md): the pipeline commits
            // its mutations to talon BEFORE proposing, so re-applying a
            // self-proposed entry here would transiently roll back keys a
            // newer in-flight batch has since written locally — only record
            // it applied. Entries without an in-flight locally_applied
            // record (prior-term catch-up, direct runtime.propose callers,
            // post-step-down commits) take the full apply path, which is
            // idempotent over any earlier local commit.
            if (self.batcher.isLocallyApplied(entry.index)) {
                self.fsm.markApplied(entry) catch |err| {
                    std.debug.panic("fsm markApplied failed for committed entry {d}: {s}", .{ entry.index, @errorName(err) });
                };
            } else {
                self.fsm.apply(entry) catch |err| {
                    // FSM apply failure on a committed entry is unrecoverable.
                    std.debug.panic("fsm apply failed for committed entry {d}: {s}", .{ entry.index, @errorName(err) });
                };
            }
            if (entry.index > max_committed) max_committed = entry.index;
        }
        self.node.advance(max_committed);
        self.batcher.onCommitted(max_committed);
    }

    /// Snapshot trigger policy: once `snapshot_threshold_entries` entries
    /// have been applied beyond the last snapshot, serialize the FSM and
    /// hand the blob to the raft node — `node.compact` persists it via
    /// storage.saveSnapshot (chunked, see raft_storage.zig) and drops log
    /// entries <= the applied index via storage.compactLog. Every node
    /// compacts independently; a follower that falls behind a compacted
    /// leader catches up via InstallSnapshot.
    ///
    /// LIMITATION: OplogFsm.snapshot() is O(db-size) and runs inline on the
    /// raft thread — while it serializes, no messages are pumped, so a very
    /// large DB stalls heartbeats for the duration and can trigger a
    /// spurious election. Mitigation (incremental/off-thread snapshotting)
    /// is future work.
    fn maybeCompact(self: *Runtime) !void {
        if (self.snapshot_threshold_entries == 0) return;
        const applied = self.fsm.lastApplied();
        const base = if (self.storage.snap_meta) |sm| sm.last_included_index else 0;
        check(applied >= base, "fsm applied {d} behind snapshot {d}", .{ applied, base });
        if (applied - base < self.snapshot_threshold_entries) return;
        const blob = try self.fsm.snapshot();
        defer self.allocator.free(blob);
        try self.node.compact(applied, blob);
    }

    fn proposeBridge(ctx: *anyopaque, payload: []const u8) BatcherError!u64 {
        const self: *Runtime = @ptrCast(@alignCast(ctx));
        const now: i64 = @intCast(std.time.nanoTimestamp());
        const out = self.node.propose(payload, now) catch return BatcherError.ProposeFailed;
        // The new entry is now at lastIndex of the storage.
        const idx = self.storage.storage().lastIndex();
        // Send out the AppendEntries that propose() generated.
        const tr = self.transport.transport();
        for (out) |m| tr.send(m.to, m);
        return idx;
    }
};

// =====================================================================
// Tests — single-node end-to-end integration.
// =====================================================================

const testing = std.testing;
const InMemRouter = @import("raft_transport.zig").InMemRouter;

const TestCounter = struct {
    successes: usize = 0,
    failures: usize = 0,

    fn cb(ctx: *anyopaque, success: bool) void {
        const self: *TestCounter = @ptrCast(@alignCast(ctx));
        if (success) self.successes += 1 else self.failures += 1;
    }
    fn completion(self: *TestCounter) Completion {
        return .{ .ctx = @ptrCast(self), .on_complete = cb };
    }
};

fn synthUuid(id: []const u8) u128 {
    var h: u128 = 0xcbf29ce484222325cbf29ce484222325;
    for (id) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return if (h == 0) 1 else h;
}

const test_cluster_id: u64 = 0xC0FFEE;

/// Open a Talon DB at `path` and return it, after best-effort cleanup of
/// any stale data file from a previous test run.
fn openFreshDb(allocator: std.mem.Allocator, path: []const u8) !*talon.DB {
    std.fs.cwd().deleteFile(path) catch {};
    var vlog_buf: [256]u8 = undefined;
    const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{path}) catch unreachable;
    std.fs.cwd().deleteFile(vlog_path) catch {};
    return try talon.DB.open(allocator, path, .{});
}

fn deleteDbFiles(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    var vlog_buf: [256]u8 = undefined;
    const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{path}) catch unreachable;
    std.fs.cwd().deleteFile(vlog_path) catch {};
}

const ClusterPeers3 = struct {
    p1: [2]PeerSpec,
    p2: [2]PeerSpec,
    p3: [2]PeerSpec,
};

fn buildClusterPeers3() ClusterPeers3 {
    return .{
        .p1 = .{ .{ .id = "n2", .uuid = synthUuid("n2") }, .{ .id = "n3", .uuid = synthUuid("n3") } },
        .p2 = .{ .{ .id = "n1", .uuid = synthUuid("n1") }, .{ .id = "n3", .uuid = synthUuid("n3") } },
        .p3 = .{ .{ .id = "n1", .uuid = synthUuid("n1") }, .{ .id = "n2", .uuid = synthUuid("n2") } },
    };
}

test "runtime: 3-node propose → commit → apply → completion" {
    const path1 = "/tmp/corvo-runtime-3n-1";
    const path2 = "/tmp/corvo-runtime-3n-2";
    const path3 = "/tmp/corvo-runtime-3n-3";
    const db1 = try openFreshDb(testing.allocator, path1);
    const db2 = try openFreshDb(testing.allocator, path2);
    const db3 = try openFreshDb(testing.allocator, path3);
    defer {
        db1.close();
        db2.close();
        db3.close();
        deleteDbFiles(path1);
        deleteDbFiles(path2);
        deleteDbFiles(path3);
    }

    const peers = buildClusterPeers3();
    const cfg = Config{
        .election_timeout_min = 200,
        .election_timeout_max = 400,
        .heartbeat_interval = 50,
    };
    var rt1 = try Runtime.init(testing.allocator, db1, .{
        .node_id = "n1",
        .instance_uuid = synthUuid("n1"),
        .cluster_id = test_cluster_id,
        .peers = &peers.p1,
        .raft_config = cfg,
    });
    defer rt1.deinit();
    var rt2 = try Runtime.init(testing.allocator, db2, .{
        .node_id = "n2",
        .instance_uuid = synthUuid("n2"),
        .cluster_id = test_cluster_id,
        .peers = &peers.p2,
        .raft_config = cfg,
    });
    defer rt2.deinit();
    var rt3 = try Runtime.init(testing.allocator, db3, .{
        .node_id = "n3",
        .instance_uuid = synthUuid("n3"),
        .cluster_id = test_cluster_id,
        .peers = &peers.p3,
        .raft_config = cfg,
    });
    defer rt3.deinit();

    var router = InMemRouter.init();
    router.register("n1", &rt1.transport);
    router.register("n2", &rt2.transport);
    router.register("n3", &rt3.transport);

    var now: i64 = 0;
    // Drive enough ticks to elect a leader.
    var leader: ?*Runtime = null;
    var i: usize = 0;
    while (i < 80 and leader == null) : (i += 1) {
        now += 100;
        try rt1.tick(now);
        try rt2.tick(now);
        try rt3.tick(now);
        if (rt1.node.isLeader()) leader = &rt1;
        if (rt2.node.isLeader()) leader = &rt2;
        if (rt3.node.isLeader()) leader = &rt3;
    }
    try testing.expect(leader != null);

    var counter = TestCounter{};
    const muts = [_]Mutation{
        .{ .op = .set, .key = "job:1", .value = "alpha" },
        .{ .op = .set, .key = "job:2", .value = "beta" },
    };
    try leader.?.propose(&muts, counter.completion(), false);

    // Drive ticks until commit + apply land on the leader.
    var j: usize = 0;
    while (j < 80 and counter.successes == 0) : (j += 1) {
        now += 100;
        try rt1.tick(now);
        try rt2.tick(now);
        try rt3.tick(now);
    }
    try testing.expectEqual(@as(usize, 1), counter.successes);

    // Leader's FSM has the data.
    var buf: [16]u8 = undefined;
    const got = (try leader.?.db.getInto("job:1", &buf)).?;
    try testing.expectEqualStrings("alpha", got);
    try testing.expect(leader.?.fsm.lastApplied() >= 1);

    // Drive a few more ticks; followers should also eventually apply.
    var k: usize = 0;
    while (k < 80) : (k += 1) {
        now += 100;
        try rt1.tick(now);
        try rt2.tick(now);
        try rt3.tick(now);
        if (rt1.fsm.lastApplied() >= 1 and rt2.fsm.lastApplied() >= 1 and rt3.fsm.lastApplied() >= 1) break;
    }
    try testing.expect(rt1.fsm.lastApplied() >= 1);
    try testing.expect(rt2.fsm.lastApplied() >= 1);
    try testing.expect(rt3.fsm.lastApplied() >= 1);
}

test "runtime: rolling restart — old leader stops, new leader elected, commits survive" {
    const path1 = "/tmp/corvo-runtime-roll-1";
    const path2 = "/tmp/corvo-runtime-roll-2";
    const path3 = "/tmp/corvo-runtime-roll-3";
    const db1 = try openFreshDb(testing.allocator, path1);
    const db2 = try openFreshDb(testing.allocator, path2);
    const db3 = try openFreshDb(testing.allocator, path3);
    defer {
        db1.close();
        db2.close();
        db3.close();
        deleteDbFiles(path1);
        deleteDbFiles(path2);
        deleteDbFiles(path3);
    }

    const peers = buildClusterPeers3();
    const cfg = Config{
        .election_timeout_min = 200,
        .election_timeout_max = 400,
        .heartbeat_interval = 50,
    };
    var rt1 = try Runtime.init(testing.allocator, db1, .{
        .node_id = "n1",
        .instance_uuid = synthUuid("n1"),
        .cluster_id = test_cluster_id,
        .peers = &peers.p1,
        .raft_config = cfg,
    });
    defer rt1.deinit();
    var rt2 = try Runtime.init(testing.allocator, db2, .{
        .node_id = "n2",
        .instance_uuid = synthUuid("n2"),
        .cluster_id = test_cluster_id,
        .peers = &peers.p2,
        .raft_config = cfg,
    });
    defer rt2.deinit();
    var rt3 = try Runtime.init(testing.allocator, db3, .{
        .node_id = "n3",
        .instance_uuid = synthUuid("n3"),
        .cluster_id = test_cluster_id,
        .peers = &peers.p3,
        .raft_config = cfg,
    });
    defer rt3.deinit();

    var router = InMemRouter.init();
    router.register("n1", &rt1.transport);
    router.register("n2", &rt2.transport);
    router.register("n3", &rt3.transport);

    var now: i64 = 0;
    // Phase 1: elect first leader.
    var leader: ?*Runtime = null;
    var i: usize = 0;
    while (i < 80 and leader == null) : (i += 1) {
        now += 100;
        try rt1.tick(now);
        try rt2.tick(now);
        try rt3.tick(now);
        if (rt1.node.isLeader()) leader = &rt1;
        if (rt2.node.isLeader()) leader = &rt2;
        if (rt3.node.isLeader()) leader = &rt3;
    }
    try testing.expect(leader != null);
    const old_leader = leader.?;
    const old_leader_id: []const u8 = old_leader.node.id;

    // Phase 2: propose + commit one entry.
    var c1 = TestCounter{};
    const muts1 = [_]Mutation{.{ .op = .set, .key = "before:1", .value = "OK" }};
    try old_leader.propose(&muts1, c1.completion(), false);
    var j: usize = 0;
    while (j < 80 and c1.successes == 0) : (j += 1) {
        now += 100;
        try rt1.tick(now);
        try rt2.tick(now);
        try rt3.tick(now);
    }
    try testing.expectEqual(@as(usize, 1), c1.successes);

    // Phase 3: simulate leader stop. We do NOT tick the old leader for
    // a while — its messages stop flowing. The other two should detect
    // the missed heartbeats and elect a new leader.
    var new_leader: ?*Runtime = null;
    var k: usize = 0;
    while (k < 200 and new_leader == null) : (k += 1) {
        now += 100;
        // old_leader skipped — simulating crash / k8s pod terminating.
        if (old_leader != &rt1) try rt1.tick(now);
        if (old_leader != &rt2) try rt2.tick(now);
        if (old_leader != &rt3) try rt3.tick(now);
        const cand: ?*Runtime = blk: {
            if (old_leader != &rt1 and rt1.node.isLeader()) break :blk &rt1;
            if (old_leader != &rt2 and rt2.node.isLeader()) break :blk &rt2;
            if (old_leader != &rt3 and rt3.node.isLeader()) break :blk &rt3;
            break :blk null;
        };
        new_leader = cand;
    }
    try testing.expect(new_leader != null);
    try testing.expect(!std.mem.eql(u8, new_leader.?.node.id, old_leader_id));

    // Phase 4: propose to NEW leader; verify it commits.
    var c2 = TestCounter{};
    const muts2 = [_]Mutation{.{ .op = .set, .key = "after:1", .value = "OK" }};
    try new_leader.?.propose(&muts2, c2.completion(), false);
    var m: usize = 0;
    while (m < 200 and c2.successes == 0) : (m += 1) {
        now += 100;
        if (old_leader != &rt1) try rt1.tick(now);
        if (old_leader != &rt2) try rt2.tick(now);
        if (old_leader != &rt3) try rt3.tick(now);
    }
    try testing.expectEqual(@as(usize, 1), c2.successes);

    // Phase 5: verify both pre- and post-failover entries are visible
    // on the new leader's FSM.
    var buf: [16]u8 = undefined;
    try testing.expect((try new_leader.?.db.getInto("before:1", &buf)) != null);
    try testing.expect((try new_leader.?.db.getInto("after:1", &buf)) != null);
}

test "runtime: compaction — threshold crossing snapshots + truncates log, restart recovers" {
    const paths = [3][]const u8{ "/tmp/corvo-snap-rt-thresh-1", "/tmp/corvo-snap-rt-thresh-2", "/tmp/corvo-snap-rt-thresh-3" };
    var dbs: [3]*talon.DB = undefined;
    for (paths, 0..) |p, i| dbs[i] = try openFreshDb(testing.allocator, p);
    defer for (paths, 0..) |p, i| {
        dbs[i].close();
        deleteDbFiles(p);
    };

    const peers = buildClusterPeers3();
    const cfg = Config{
        .election_timeout_min = 200,
        .election_timeout_max = 400,
        .heartbeat_interval = 50,
    };
    const ids = [3][]const u8{ "n1", "n2", "n3" };
    const peer_slices = [3][]const PeerSpec{ &peers.p1, &peers.p2, &peers.p3 };
    var rts: [3]Runtime = undefined;
    for (0..3) |i| {
        rts[i] = try Runtime.init(testing.allocator, dbs[i], .{
            .node_id = ids[i],
            .instance_uuid = synthUuid(ids[i]),
            .cluster_id = test_cluster_id,
            .peers = peer_slices[i],
            .raft_config = cfg,
            .snapshot_threshold_entries = 4,
        });
    }

    var router = InMemRouter.init();
    for (0..3) |i| router.register(ids[i], &rts[i].transport);

    var now: i64 = 0;
    var leader_idx: ?usize = null;
    var i: usize = 0;
    while (i < 80 and leader_idx == null) : (i += 1) {
        now += 100;
        for (&rts) |*rt| try rt.tick(now);
        for (0..3) |k| {
            if (rts[k].node.isLeader()) leader_idx = k;
        }
    }
    try testing.expect(leader_idx != null);
    const li = leader_idx.?;

    // Propose 6 entries one at a time — each commits before the next, so
    // the applied index crosses the threshold (4) mid-run.
    var key_buf: [8]u8 = undefined;
    var n_committed: usize = 0;
    while (n_committed < 6) : (n_committed += 1) {
        var counter = TestCounter{};
        const key = std.fmt.bufPrint(&key_buf, "job:{d}", .{n_committed}) catch unreachable;
        const muts = [_]Mutation{.{ .op = .set, .key = key, .value = "V" }};
        try rts[li].propose(&muts, counter.completion(), false);
        var j: usize = 0;
        while (j < 80 and counter.successes == 0) : (j += 1) {
            now += 100;
            for (&rts) |*rt| try rt.tick(now);
        }
        try testing.expectEqual(@as(usize, 1), counter.successes);
    }

    // Threshold crossed: leader snapshotted and truncated the log prefix.
    const lsnap = rts[li].storage.snap_meta.?;
    try testing.expect(lsnap.last_included_index >= 4);
    const snap_idx = lsnap.last_included_index;
    try testing.expectEqual(snap_idx + 1, rts[li].storage.storage().firstIndex());
    try testing.expect(rts[li].fsm.lastApplied() >= snap_idx);

    // Restart the leader on the same db. The other runtimes are torn down
    // too; the restarted node is deliberately NOT registered with the
    // router, so its messages drop — recovery must not need the cluster.
    const leader_applied = rts[li].fsm.lastApplied();
    for (&rts) |*rt| rt.deinit();
    var restarted = try Runtime.init(testing.allocator, dbs[li], .{
        .node_id = ids[li],
        .instance_uuid = synthUuid(ids[li]),
        .cluster_id = test_cluster_id,
        .peers = peer_slices[li],
        .raft_config = cfg,
        .snapshot_threshold_entries = 4,
    });
    defer restarted.deinit();

    // Storage bounds and applied state are consistent with the snapshot.
    try testing.expectEqual(snap_idx + 1, restarted.storage.storage().firstIndex());
    try testing.expectEqual(leader_applied, restarted.fsm.lastApplied());
    try testing.expect(restarted.node.commit_index >= snap_idx);
    var buf: [4]u8 = undefined;
    for (0..6) |k| {
        const key = std.fmt.bufPrint(&key_buf, "job:{d}", .{k}) catch unreachable;
        try testing.expect((try dbs[li].getInto(key, &buf)) != null);
    }
    // Ticking with a compacted log prefix must not error (ready() must not
    // reach into compacted history).
    var t: usize = 0;
    while (t < 20) : (t += 1) {
        now += 100;
        try restarted.tick(now);
    }
    try testing.expectEqual(leader_applied, restarted.fsm.lastApplied());
}

test "runtime: compaction — lagging follower catches up via InstallSnapshot" {
    const paths = [3][]const u8{ "/tmp/corvo-snap-rt-lag-1", "/tmp/corvo-snap-rt-lag-2", "/tmp/corvo-snap-rt-lag-3" };
    var dbs: [3]*talon.DB = undefined;
    for (paths, 0..) |p, i| dbs[i] = try openFreshDb(testing.allocator, p);
    defer for (paths, 0..) |p, i| {
        dbs[i].close();
        deleteDbFiles(p);
    };

    const peers = buildClusterPeers3();
    const cfg = Config{
        .election_timeout_min = 200,
        .election_timeout_max = 400,
        .heartbeat_interval = 50,
    };
    const ids = [3][]const u8{ "n1", "n2", "n3" };
    const peer_slices = [3][]const PeerSpec{ &peers.p1, &peers.p2, &peers.p3 };
    var rts: [3]Runtime = undefined;
    for (0..3) |i| {
        rts[i] = try Runtime.init(testing.allocator, dbs[i], .{
            .node_id = ids[i],
            .instance_uuid = synthUuid(ids[i]),
            .cluster_id = test_cluster_id,
            .peers = peer_slices[i],
            .raft_config = cfg,
            .snapshot_threshold_entries = 6,
        });
    }
    defer for (&rts) |*rt| rt.deinit();

    // n3 is the designated lagger: not registered with the router and not
    // ticked, it is effectively offline while the other two make progress.
    const lag: usize = 2;
    var router = InMemRouter.init();
    router.register(ids[0], &rts[0].transport);
    router.register(ids[1], &rts[1].transport);

    var now: i64 = 0;
    var leader_idx: ?usize = null;
    var i: usize = 0;
    while (i < 80 and leader_idx == null) : (i += 1) {
        now += 100;
        try rts[0].tick(now);
        try rts[1].tick(now);
        for (0..2) |k| {
            if (rts[k].node.isLeader()) leader_idx = k;
        }
    }
    try testing.expect(leader_idx != null);
    const li = leader_idx.?;

    // Propose 7 entries with 48 KiB values — the FSM snapshot taken at the
    // threshold (6 applied entries, ~288 KiB of values) exceeds Talon's
    // 256 KiB single-value cap, so compaction exercises chunked storage and
    // catch-up exercises multi-chunk InstallSnapshot end to end.
    const value_len: usize = 48 * 1024;
    const value = try testing.allocator.alloc(u8, value_len);
    defer testing.allocator.free(value);
    var key_buf: [8]u8 = undefined;
    var n_committed: usize = 0;
    while (n_committed < 7) : (n_committed += 1) {
        var counter = TestCounter{};
        const key = std.fmt.bufPrint(&key_buf, "job:{d}", .{n_committed}) catch unreachable;
        @memset(value, @as(u8, @intCast(n_committed & 0xFF)));
        const muts = [_]Mutation{.{ .op = .set, .key = key, .value = value }};
        try rts[li].propose(&muts, counter.completion(), false);
        var j: usize = 0;
        while (j < 120 and counter.successes == 0) : (j += 1) {
            now += 100;
            try rts[0].tick(now);
            try rts[1].tick(now);
        }
        try testing.expectEqual(@as(usize, 1), counter.successes);
    }

    // Leader compacted past what the lagger would need via AppendEntries.
    const lsnap = rts[li].storage.snap_meta.?;
    try testing.expect(lsnap.last_included_index >= 6);
    try testing.expect(rts[li].storage.storage().firstIndex() > 1);
    const leader_blob = rts[li].storage.storage().loadSnapshot().?;
    try testing.expect(leader_blob.data.len > 256 * 1024);

    // Wake the lagger: register + tick all three until it catches up.
    router.register(ids[lag], &rts[lag].transport);
    const leader_applied = rts[li].fsm.lastApplied();
    var k: usize = 0;
    while (k < 600 and rts[lag].fsm.lastApplied() < leader_applied) : (k += 1) {
        now += 100;
        for (&rts) |*rt| try rt.tick(now);
    }
    try testing.expectEqual(leader_applied, rts[lag].fsm.lastApplied());

    // The lagger got there via InstallSnapshot: it holds a snapshot and its
    // log starts after the snapshot index (never held the compacted prefix).
    const fsnap = rts[lag].storage.snap_meta.?;
    try testing.expectEqual(lsnap.last_included_index, fsnap.last_included_index);
    try testing.expectEqual(fsnap.last_included_index + 1, rts[lag].storage.storage().firstIndex());

    // KV state matches the leader byte for byte.
    const got = try testing.allocator.alloc(u8, value_len);
    defer testing.allocator.free(got);
    for (0..7) |n| {
        const key = std.fmt.bufPrint(&key_buf, "job:{d}", .{n}) catch unreachable;
        @memset(value, @as(u8, @intCast(n & 0xFF)));
        const got_slice = (try rts[lag].db.getInto(key, got)).?;
        try testing.expectEqualSlices(u8, value, got_slice);
    }
}

test "runtime: init completes a snapshot the FSM missed (install/apply crash window)" {
    const path = "/tmp/corvo-snap-rt-heal";
    const db = try openFreshDb(testing.allocator, path);
    defer {
        db.close();
        deleteDbFiles(path);
    }
    // Simulate the crash window: InstallSnapshot persisted a snapshot (and
    // truncated the log), but the process died before applyReady swapped
    // the FSM.
    {
        var s_obj = try @import("raft_storage.zig").Storage.init(testing.allocator, db);
        defer s_obj.deinit();
        const blob = oplog.encodeMutations(testing.allocator, &.{
            .{ .op = .set, .key = "job:s", .value = "SNAP" },
        });
        defer testing.allocator.free(blob);
        try s_obj.storage().saveSnapshot(.{
            .last_included_index = 5,
            .last_included_term = 2,
            .config = "",
        }, blob);
    }
    const peers = [_]PeerSpec{.{ .id = "n2", .uuid = synthUuid("n2") }};
    var rt = try Runtime.init(testing.allocator, db, .{
        .node_id = "n1",
        .instance_uuid = synthUuid("n1"),
        .cluster_id = test_cluster_id,
        .peers = &peers,
        .raft_config = .{
            .election_timeout_min = 200,
            .election_timeout_max = 400,
            .heartbeat_interval = 50,
        },
        .snapshot_threshold_entries = 0,
    });
    defer rt.deinit();
    // Init finished the swap and resumed the applied/commit counters.
    try testing.expectEqual(@as(u64, 5), rt.fsm.lastApplied());
    try testing.expectEqual(@as(u64, 5), rt.node.commit_index);
    var buf: [8]u8 = undefined;
    const got = (try db.getInto("job:s", &buf)).?;
    try testing.expectEqualStrings("SNAP", got);
    // Ticking with the healed state must not error.
    var now: i64 = 0;
    var t: usize = 0;
    while (t < 20) : (t += 1) {
        now += 100;
        try rt.tick(now);
    }
}

test "runtime: propose returns NotLeader when not leader" {
    const path = "/tmp/corvo-runtime-notleader";
    const db = try openFreshDb(testing.allocator, path);
    defer {
        db.close();
        deleteDbFiles(path);
    }
    const peers = [_]PeerSpec{.{ .id = "n2", .uuid = synthUuid("n2") }};
    var rt = try Runtime.init(testing.allocator, db, .{
        .node_id = "n1",
        .instance_uuid = synthUuid("n1"),
        .cluster_id = test_cluster_id,
        .peers = &peers,
        .raft_config = .{
            .election_timeout_min = 200,
            .election_timeout_max = 400,
            .heartbeat_interval = 50,
        },
    });
    defer rt.deinit();
    var counter = TestCounter{};
    const muts = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
    try testing.expectError(RuntimeError.NotLeader, rt.propose(&muts, counter.completion(), false));
}
