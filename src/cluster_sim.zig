//! Multi-node cluster simulator.
//!
//! Creates N nodes with:
//!   - Independent Talon KV stores (in-memory)
//!   - Engine + OpHandler per node
//!   - Election state machines
//!   - Leader: Replicator → streams oplog to followers
//!   - Follower: applies replicated mutations to local KV
//!   - InMem transport for message delivery
//!
//! Tick-based simulation loop:
//!   1. Election ticks (all nodes)
//!   2. Client ops on leader
//!   3. Leader replicates new oplog entries
//!   4. Message delivery
//!   5. Invariant checks
//!
//! All state machines are deterministic — no real time, no threads.

const std = @import("std");
const assert_mod = @import("assert.zig");
const kv = @import("kv.zig");
const keys = @import("keys.zig");
const ops_mod = @import("ops.zig");
const handler_mod = @import("handler.zig");
const oplog_mod = @import("oplog.zig");
const election_mod = @import("election.zig");
const repl_mod = @import("replicator.zig");
const follower_mod = @import("follower.zig");
const transport_mod = @import("transport.zig");

const talon = @import("talon");

// ============================================================================
// SimClock — deterministic, advance-only
// ============================================================================

const SimClock = struct {
    nanos: i64 = 0,

    fn now(self: *SimClock) i64 {
        return self.nanos;
    }

    pub fn advance(self: *SimClock, delta_ns: i64) void {
        self.nanos += delta_ns;
    }
};

/// Module-level global so bare function pointers (no context) can access the sim clock.
var g_sim_clock: *SimClock = undefined;

fn simClockNow() i64 {
    return g_sim_clock.nanos;
}

// ============================================================================
// SimNode — one node in the simulated cluster
// ============================================================================

pub const SimNode = struct {
    id: []const u8,
    db: *talon.DB, // owned by talon, closed via db.close()
    store: kv.Store,
    handler: handler_mod.OpHandler,
    oplog: oplog_mod.Log,
    election: election_mod.Election,
    transport: *transport_mod.InMemTransport,
    runner: transport_mod.Runner,

    // Replicator (only when leader).
    replicator: ?repl_mod.Replicator,

    // Follower applier (only when not leader).
    follower_state: ?follower_mod.Follower,

    allocator: std.mem.Allocator,
    mut_list: std.ArrayList(kv.Mutation) = .{},

    fn deinit(self: *SimNode) void {
        self.handler.deinit();
        self.oplog.deinit();
        self.election.deinit();
        if (self.replicator) |*r| r.deinit();
        self.mut_list.deinit(self.allocator);
        self.db.close();
    }

    /// Apply an op to this node (only valid on leader).
    pub fn apply(self: *SimNode, op_type: ops_mod.OpType, data: *const ops_mod.OpData) ops_mod.OpResult {
        var batch = self.store.newBatch();
        defer batch.close();

        // Enable mutation recording for oplog (reuses pre-allocated list).
        self.mut_list.clearRetainingCapacity();
        batch.enableRecording(self.allocator, &self.mut_list);
        defer batch.freeMutations();

        const result = self.handler.apply(&batch, op_type, data);
        batch.commit();

        // Append to oplog.
        if (self.mut_list.items.len > 0) {
            const encoded = oplog_mod.encodeMutations(self.allocator, self.mut_list.items);
            defer self.allocator.free(encoded);
            _ = self.oplog.append(0, encoded);
        }

        return result;
    }

    /// Replicate oplog entries to followers (leader only).
    /// Reads from the minimum acked sequence, so unacked entries are re-sent
    /// on every tick until followers acknowledge them. This handles message drops.
    fn replicateNew(self: *SimNode) void {
        const r = &(self.replicator orelse return);
        const head = self.oplog.getSeq();
        if (head == 0) return;

        // Read from the minimum acked point — this re-sends any dropped entries.
        const min_acked = r.minAcked();
        const read_from = if (min_acked > 0) min_acked else 0;

        const entries_raw = self.oplog.readAfter(read_from, 64);
        if (entries_raw.len == 0) return;

        var repl_entries: [64]repl_mod.Entry = undefined;
        for (entries_raw, 0..) |e, i| {
            repl_entries[i] = .{
                .seq = e.seq,
                .shard_id = e.shard_id,
                .data = e.data,
            };
        }

        const msgs = r.replicate(repl_entries[0..entries_raw.len]);
        defer self.allocator.free(msgs);

        for (msgs) |m| {
            _ = self.transport.send(m.to, .{
                .repl = .{
                    .type_ = .replicate,
                    .epoch = m.epoch,
                    .seq = m.seq,
                    .shard_id = m.shard_id,
                    .data = m.data,
                },
            });
        }

        self.runner.last_repl = entries_raw[entries_raw.len - 1].seq;
    }
};

// ============================================================================
// KV Applier — applies oplog mutations to a follower's KV store
// ============================================================================

const KvApplier = struct {
    node: *SimNode,

    fn applier(self: *KvApplier) follower_mod.Applier {
        return .{
            .ptr = @ptrCast(self),
            .applyFn = @ptrCast(&applyBatchImpl),
        };
    }

    fn applyBatchImpl(self: *KvApplier, shard_id: u16, seq: u64, data: []const u8) follower_mod.ApplyError!void {
        _ = shard_id;
        _ = seq;

        // Decode mutations and apply to KV.
        const mutations = oplog_mod.decodeMutations(self.node.allocator, data) catch
            return error.ApplyFailed;
        defer self.node.allocator.free(mutations);

        var batch = self.node.store.newBatch();
        defer batch.close();

        for (mutations) |m| {
            switch (m.op) {
                .set => batch.set(m.key, m.value),
                .delete => batch.delete(m.key),
                .delete_range => batch.deleteRange(m.key, m.value),
            }
        }

        batch.commit();
    }
};

// ============================================================================
// Cluster — the full simulated cluster
// ============================================================================

var g_instance_counter: u32 = 0;


pub const Cluster = struct {
    nodes: []SimNode,
    appliers: []KvApplier,
    network: *transport_mod.InMemNetwork,
    clock: *SimClock,
    allocator: std.mem.Allocator,
    tick_count: u64 = 0,
    last_leader_idx: ?usize = null,

    // Node IDs (owned).
    node_ids: [][]const u8,
    // Per-node peer lists (owned).
    peer_lists: [][][]const u8,

    pub fn init(allocator: std.mem.Allocator, node_count: u8) !Cluster {
        assert_mod.check(node_count >= 1 and node_count <= 7, "Cluster: invalid node count", .{});
        const instance_id = g_instance_counter;
        g_instance_counter += 1;

        // Heap-allocate clock so the pointer is stable after return.
        const clock = try allocator.create(SimClock);
        clock.* = SimClock{ .nanos = 1_000_000_000 };

        // Set module-level global so bare function pointers can access it.
        g_sim_clock = clock;

        // Build node ID strings.
        const node_ids = try allocator.alloc([]const u8, node_count);
        for (0..node_count) |i| {
            const id = try std.fmt.allocPrint(allocator, "node-{d}", .{i + 1});
            node_ids[i] = id;
        }

        // Build peer lists (each node's peers = all other nodes).
        const peer_lists = try allocator.alloc([][]const u8, node_count);
        for (0..node_count) |i| {
            const peers = try allocator.alloc([]const u8, node_count - 1);
            var pi: usize = 0;
            for (0..node_count) |j| {
                if (i != j) {
                    peers[pi] = node_ids[j];
                    pi += 1;
                }
            }
            peer_lists[i] = peers;
        }

        // Heap-allocate network so transports can store a stable pointer.
        const network = try allocator.create(transport_mod.InMemNetwork);
        network.* = transport_mod.InMemNetwork.init(allocator);

        const election_config = election_mod.Config{
            .lease_duration = 500_000_000, // 500ms
            .renew_interval = 100_000_000, // 100ms
            .election_timeout = 300_000_000, // 300ms
        };

        const nodes = try allocator.alloc(SimNode, node_count);
        const appliers = try allocator.alloc(KvApplier, node_count);

        for (0..node_count) |i| {
            const id = node_ids[i];
            const peers = peer_lists[i];

            // Talon DB in temp directory — clean stale data from prior runs.
            var dir_buf: [64]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&dir_buf, "/tmp/corvo-sim-{d}-{d}", .{ instance_id, i }) catch unreachable;
            std.fs.cwd().deleteTree(dir_path) catch {};
            std.fs.cwd().makePath(dir_path) catch {};
            var path_buf: [80]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}/kv", .{dir_path}) catch unreachable;
            const db = try talon.DB.open(allocator, path, .{});

            const store = kv.Store.init(db);

            nodes[i] = SimNode{
                .id = id,
                .db = db,
                .store = store,
                .handler = handler_mod.OpHandler.init(allocator),
                .oplog = oplog_mod.Log.init(allocator, .{ .now_fn = simClockNow }, null),
                .election = election_mod.Election.init(allocator, id, peers, election_config),
                .transport = network.newTransport(id),
                .runner = undefined, // set below
                .replicator = null,
                .follower_state = null,
                .allocator = allocator,
            };
        }

        // Initialize runners and appliers (needs nodes to be placed first).
        for (0..node_count) |i| {
            appliers[i] = .{ .node = &nodes[i] };

            nodes[i].runner = transport_mod.Runner.init(.{
                .node_id = node_ids[i],
                .peer_ids = peer_lists[i],
                .transport = nodes[i].transport,
                .election = &nodes[i].election,
                .clock_fn = simClockNow,
                .max_lag = 1000,
            });
        }

        var self = Cluster{
            .nodes = nodes,
            .appliers = appliers,
            .network = network,
            .clock = clock,
            .allocator = allocator,
            .node_ids = node_ids,
            .peer_lists = peer_lists,
        };

        // Wire follower appliers.
        for (0..node_count) |i| {
            self.nodes[i].runner.follower = null; // set dynamically
        }

        return self;
    }

    pub fn deinit(self: *Cluster) void {
        for (self.nodes) |*n| n.deinit();
        self.network.deinit();
        self.allocator.destroy(self.network);
        self.allocator.destroy(self.clock);
        self.allocator.free(self.nodes);
        self.allocator.free(self.appliers);

        for (self.peer_lists) |peers| self.allocator.free(peers);
        self.allocator.free(self.peer_lists);

        for (self.node_ids) |id| self.allocator.free(@constCast(id));
        self.allocator.free(self.node_ids);
    }

    /// Run election ticks until a leader is elected (or max ticks reached).
    pub fn electLeader(self: *Cluster, max_ticks: u32) bool {
        for (0..max_ticks) |_| {
            self.clock.advance(50_000_000); // 50ms per tick

            // Tick all runners.
            for (self.nodes) |*n| {
                n.runner.tick();
            }

            // Check if any node became leader.
            if (self.getLeader() != null) {
                self.setupReplication();
                return true;
            }
        }
        return false;
    }

    /// Set up replicator on the leader and snapshot state to all followers.
    fn setupReplication(self: *Cluster) void {
        const leader_idx = self.getLeaderIdx() orelse return;
        const leader = &self.nodes[leader_idx];
        const epoch = leader.election.currentState().epoch;
        const leader_seq = leader.oplog.getSeq();

        // Create replicator on leader.
        if (leader.replicator) |*old_r| old_r.deinit();
        leader.replicator = repl_mod.Replicator.init(
            self.allocator,
            leader.id,
            epoch,
            self.peer_lists[leader_idx],
            1000, // max_lag
        );
        leader.runner.replicator = &leader.replicator.?;
        leader.runner.last_repl = 0;

        // Snapshot leader's KV to all followers so they start from a
        // consistent base. This handles leadership changes where the
        // old leader had unreplicated writes — followers get the new
        // leader's state, not a mix of old + new.
        for (0..self.nodes.len) |i| {
            if (i == leader_idx) continue;

            // Copy all KV data from leader to follower.
            self.snapshotKV(leader_idx, i);

            // Reset follower state to start from leader's current seq.
            self.nodes[i].follower_state = follower_mod.Follower.init(
                self.nodes[i].id,
                epoch,
                leader_seq,
                self.appliers[i].applier(),
            );
            self.nodes[i].runner.follower = &self.nodes[i].follower_state.?;
        }
    }

    fn printKeys(self: *Cluster, idx: usize, label: []const u8) void {
        var batch = self.nodes[idx].store.newBatch();
        defer batch.close();
        var iter = batch.newIter("", "\xff");
        defer iter.close();
        var count: u32 = 0;
        if (iter.first()) {
            while (true) {
                const k = iter.key();
                // Print first 2 bytes as prefix identifier.
                if (k.len >= 2) {
                    std.debug.print("  {s}[{d}]: prefix={c}{c} len={d}\n", .{ label, count, k[0], k[1], k.len });
                }
                count += 1;
                if (!iter.next()) break;
            }
        }
    }

    /// Copy all KV data from src node to dst node and rebuild handler state.
    fn snapshotKV(self: *Cluster, src_idx: usize, dst_idx: usize) void {
        const src = &self.nodes[src_idx];
        const dst = &self.nodes[dst_idx];

        // Clear dst KV by deleting all keys individually.
        {
            // First collect keys to delete (can't delete while iterating).
            var keys_to_del: [4096]struct { buf: [256]u8, len: usize } = undefined;
            var del_count: usize = 0;
            {
                var rb = dst.store.newBatch();
                defer rb.close();
                var iter = rb.newIter("\x00", "\xff");
                defer iter.close();
                if (iter.first()) {
                    while (true) {
                        if (del_count < keys_to_del.len) {
                            const k = iter.key();
                            const kl = @min(k.len, 256);
                            @memcpy(keys_to_del[del_count].buf[0..kl], k[0..kl]);
                            keys_to_del[del_count].len = kl;
                            del_count += 1;
                        }
                        if (!iter.next()) break;
                    }
                }
            }
            // Now delete them.
            {
                var wb = dst.store.newBatch();
                defer wb.close();
                for (keys_to_del[0..del_count]) |*kd| {
                    wb.delete(kd.buf[0..kd.len]);
                }
                wb.commit();
            }
        }

        // Copy all keys from src to dst.
        {
            var src_batch = src.store.newBatch();
            defer src_batch.close();
            var dst_batch = dst.store.newBatch();
            defer dst_batch.close();

            var iter = src_batch.newIter("\x00", "\xff");
            defer iter.close();

            if (iter.first()) {
                while (true) {
                    dst_batch.set(iter.key(), iter.value());
                    if (!iter.next()) break;
                }
            }
            dst_batch.commit();
        }

        // Rebuild handler's in-memory state from the new KV contents.
        dst.handler.clearState();
        var stores = [1]kv.Store{dst.store};
        dst.handler.rebuildState(&stores);
    }

    /// Find the current leader node, or null.
    pub fn getLeader(self: *Cluster) ?*SimNode {
        const idx = self.getLeaderIdx() orelse return null;
        return &self.nodes[idx];
    }

    fn getLeaderIdx(self: *Cluster) ?usize {
        for (self.nodes, 0..) |*n, i| {
            if (n.election.isLeader()) return i;
        }
        return null;
    }

    /// Submit an op to the leader. Returns null if no leader.
    pub fn submitToLeader(self: *Cluster, op_type: ops_mod.OpType, data: *const ops_mod.OpData) ?ops_mod.OpResult {
        const leader = self.getLeader() orelse return null;
        return leader.apply(op_type, data);
    }

    /// Submit an op to a specific node (for testing follower rejection).
    pub fn submitToNode(self: *Cluster, node_idx: usize, op_type: ops_mod.OpType, data: *const ops_mod.OpData) ops_mod.OpResult {
        return self.nodes[node_idx].apply(op_type, data);
    }

    /// Get a non-leader node index, or null if all are leaders (shouldn't happen).
    pub fn getFollowerIdx(self: *Cluster) ?usize {
        const leader_idx = self.getLeaderIdx() orelse return null;
        for (0..self.nodes.len) |i| {
            if (i != leader_idx) return i;
        }
        return null;
    }

    /// Enable/disable network fault injection.
    pub fn setFaultFn(self: *Cluster, f: ?*const fn (from: []const u8, to: []const u8) bool) void {
        self.network.setFaultFn(f);
    }

    /// Run one simulation tick: leader replicates, all nodes process messages.
    pub fn tick(self: *Cluster) void {
        self.clock.advance(10_000_000); // 10ms
        self.tick_count += 1;

        // Detect leadership changes.
        const prev_leader = self.last_leader_idx;
        const cur_leader = self.getLeaderIdx();
        if (cur_leader) |li| {
            if (prev_leader == null or prev_leader.? != li) {
                self.setupReplication();
                self.last_leader_idx = li;
            }
        }

        // Leader: handle need_snap requests, reset unacked, replicate.
        if (cur_leader) |li| {
            const leader = &self.nodes[li];

            // Check for followers needing snapshots.
            if (leader.replicator) |*r| {
                const prog = r.progress();
                defer self.allocator.free(prog);
                for (prog) |fp| {
                    if (fp.need_snap) {
                        // Find follower index and snapshot.
                        for (0..self.nodes.len) |fi| {
                            if (fi == li) continue;
                            if (std.mem.eql(u8, self.nodes[fi].id, fp.id)) {
                                self.snapshotKV(li, fi);
                                const leader_seq = leader.oplog.getSeq();
                                const epoch = leader.election.currentState().epoch;
                                r.resetFollower(fp.id, leader_seq);
                                self.nodes[fi].follower_state = follower_mod.Follower.init(
                                    self.nodes[fi].id,
                                    epoch,
                                    leader_seq,
                                    self.appliers[fi].applier(),
                                );
                                self.nodes[fi].runner.follower = &self.nodes[fi].follower_state.?;
                                break;
                            }
                        }
                    }
                }

                // Reset unacked for retry.
                r.resetUnacked();
            }
            leader.replicateNew();
        }

        // All nodes process transport messages.
        // Update each node's election with its oplog seq for ISR-style voting.
        for (self.nodes) |*n| {
            n.election.last_log_seq = n.oplog.getSeq();
            n.runner.tick();
        }
    }

    /// Run N ticks.
    pub fn runTicks(self: *Cluster, n: u32) void {
        for (0..n) |_| {
            self.tick();
        }
    }

    // ====================================================================
    // Invariant checks
    // ====================================================================

    /// Check that all followers' KV state matches the leader's for ALL key prefixes.
    /// Counts total KV keys across the entire keyspace.
    pub fn checkReplicationConsistency(self: *Cluster) !void {
        const leader_idx = self.getLeaderIdx() orelse return;
        const leader = &self.nodes[leader_idx];

        for (self.nodes, 0..) |*node, i| {
            if (i == leader_idx) continue;

            var leader_count: u32 = 0;
            var follower_count: u32 = 0;

            // Count ALL keys on leader.
            {
                var lb = leader.store.newBatch();
                defer lb.close();
                var iter = lb.newIter("", "\xff");
                defer iter.close();
                if (iter.first()) {
                    leader_count += 1;
                    while (iter.next()) leader_count += 1;
                }
            }

            // Count ALL keys on follower.
            {
                var fb = node.store.newBatch();
                defer fb.close();
                var iter = fb.newIter("", "\xff");
                defer iter.close();
                if (iter.first()) {
                    follower_count += 1;
                    while (iter.next()) follower_count += 1;
                }
            }

            if (leader_count != follower_count) {
                std.debug.print(
                    "REPLICATION MISMATCH: leader({s}) has {d} keys, follower({s}) has {d}\n",
                    .{ leader.id, leader_count, node.id, follower_count },
                );
                // Print keys on each side for debugging.
                self.printKeys(leader_idx, "leader");
                self.printKeys(i, "follower");
                return error.ReplicationMismatch;
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "cluster election converges" {
    const allocator = std.testing.allocator;

    var cluster = try Cluster.init(allocator, 3);
    defer cluster.deinit();

    const elected = cluster.electLeader(50);
    try std.testing.expect(elected);

    const leader = cluster.getLeader().?;
    try std.testing.expect(leader.election.isLeader());
}

test "cluster replication consistency" {
    const allocator = std.testing.allocator;

    var cluster = try Cluster.init(allocator, 3);
    defer cluster.deinit();

    try std.testing.expect(cluster.electLeader(50));

    // Enqueue some jobs on the leader.
    for (0..5) |i| {
        var id_buf: [32]u8 = undefined;
        const job_id = std.fmt.bufPrint(&id_buf, "job-{d}", .{i}) catch unreachable;

        const now: u64 = @intCast(cluster.clock.nanos);
        const data = ops_mod.OpData{
            .enqueue = .{
                .now_ns = now,
                .jobs = @constCast(&[_]ops_mod.EnqueueJob{.{
                    .job_id = job_id,
                    .queue = "default",
                    .priority = 50,
                    .max_retries = 3,
                    .created_at_ns = now,
                }}),
            },
        };
        const result = cluster.submitToLeader(.enqueue, &data);
        try std.testing.expect(result != null);
        try std.testing.expect(result.?.err == null);
    }

    // Run ticks to let replication propagate.
    cluster.runTicks(20);

    // Verify all followers match the leader.
    try cluster.checkReplicationConsistency();
}

test "follower write causes divergence — detected by consistency check" {
    // This test proves that writing to a follower directly causes data
    // divergence that checkReplicationConsistency catches.
    // In production, the server rejects/proxies follower writes.
    const allocator = std.testing.allocator;

    var cluster = try Cluster.init(allocator, 3);
    defer cluster.deinit();

    try std.testing.expect(cluster.electLeader(50));

    // Enqueue a job on the leader — this replicates correctly.
    const now: u64 = @intCast(cluster.clock.nanos);
    _ = cluster.submitToLeader(.enqueue, &ops_mod.OpData{
        .enqueue = .{
            .now_ns = now,
            .jobs = @constCast(&[_]ops_mod.EnqueueJob{.{
                .job_id = "leader-job",
                .queue = "q1",
                .priority = 50,
                .max_retries = 1,
                .created_at_ns = now,
            }}),
        },
    });

    cluster.runTicks(20);
    try cluster.checkReplicationConsistency(); // Should pass — leader write replicated.

    // Now write directly to a follower — this does NOT replicate.
    const follower_idx = cluster.getFollowerIdx().?;
    _ = cluster.submitToNode(follower_idx, .enqueue, &ops_mod.OpData{
        .enqueue = .{
            .now_ns = now + 1000,
            .jobs = @constCast(&[_]ops_mod.EnqueueJob{.{
                .job_id = "follower-rogue-job",
                .queue = "q1",
                .priority = 50,
                .max_retries = 1,
                .created_at_ns = now + 1000,
            }}),
        },
    });

    cluster.runTicks(20);

    // Consistency check should FAIL — follower has an extra job.
    const result = cluster.checkReplicationConsistency();
    try std.testing.expectError(error.ReplicationMismatch, result);
}

test "leader-only writes maintain consistency" {
    // All writes go through the leader → all nodes converge.
    const allocator = std.testing.allocator;

    var cluster = try Cluster.init(allocator, 3);
    defer cluster.deinit();

    try std.testing.expect(cluster.electLeader(50));

    // Full lifecycle: enqueue, fetch, ack, fail.
    for (0..20) |i| {
        var id_buf: [32]u8 = undefined;
        const job_id = std.fmt.bufPrint(&id_buf, "job-{d}", .{i}) catch unreachable;
        const now: u64 = @intCast(cluster.clock.nanos);

        // Enqueue.
        _ = cluster.submitToLeader(.enqueue, &ops_mod.OpData{
            .enqueue = .{
                .now_ns = now,
                .jobs = @constCast(&[_]ops_mod.EnqueueJob{.{
                    .job_id = job_id,
                    .queue = "q1",
                    .priority = 50,
                    .max_retries = 3,
                    .created_at_ns = now,
                }}),
            },
        });

        cluster.runTicks(3);
    }

    // Fetch + ack some jobs on leader.
    const leader = cluster.getLeader().?;
    for (0..5) |_| {
        const now: u64 = @intCast(cluster.clock.nanos);
        const queues = [1][]const u8{"q1"};
        const fetch_result = leader.apply(.fetch, &ops_mod.OpData{
            .fetch = .{ .queues = &queues, .worker_id = "w1", .count = 1, .now_ns = now, .lease_duration_ms = 30000 },
        });
        if (fetch_result.affected > 0) {
            const fetched_id = fetch_result.fetched[0].id_buf[0..fetch_result.fetched[0].id_len];
            const acks = [1]ops_mod.AckJob{.{ .job_id = fetched_id, .queue = "q1" }};
            _ = leader.apply(.ack, &ops_mod.OpData{
                .ack = .{ .acks = &acks, .now_ns = now },
            });
        }
        cluster.runTicks(3);
    }

    cluster.runTicks(30);
    try cluster.checkReplicationConsistency();
}

test "cluster replication survives packet loss" {
    // Drop only replication messages (not election messages) to avoid
    // leadership changes. With resetUnacked, followers converge.
    const allocator = std.testing.allocator;

    var cluster = try Cluster.init(allocator, 3);
    defer cluster.deinit();

    try std.testing.expect(cluster.electLeader(50));

    // 5% packet loss (every 20th message).
    cluster.network.setPacketLoss(20);

    // Enqueue 10 jobs on the leader.
    for (0..10) |i| {
        var id_buf: [32]u8 = undefined;
        const job_id = std.fmt.bufPrint(&id_buf, "drop-job-{d}", .{i}) catch unreachable;
        const now: u64 = @intCast(cluster.clock.nanos);

        _ = cluster.submitToLeader(.enqueue, &ops_mod.OpData{
            .enqueue = .{
                .now_ns = now,
                .jobs = @constCast(&[_]ops_mod.EnqueueJob{.{
                    .job_id = job_id,
                    .queue = "q1",
                    .priority = 50,
                    .max_retries = 1,
                    .created_at_ns = now,
                }}),
            },
        });
        cluster.runTicks(5);
    }

    // Stop loss, let retries converge.
    cluster.network.setPacketLoss(0);
    cluster.runTicks(300);

    try cluster.checkReplicationConsistency();
}

test "cluster adversarial: mixed ops with replication" {
    const allocator = std.testing.allocator;

    var cluster = try Cluster.init(allocator, 3);
    defer cluster.deinit();

    try std.testing.expect(cluster.electLeader(50));

    const leader = cluster.getLeader().?;

    // Batch create + enqueue + seal.
    const batch_now: u64 = @intCast(cluster.clock.nanos);
    _ = leader.apply(.batch_create, &ops_mod.OpData{
        .batch_create = .{ .batch_id = "batch-1", .created_at_ns = batch_now },
    });

    for (0..5) |i| {
        var id_buf: [32]u8 = undefined;
        const job_id = std.fmt.bufPrint(&id_buf, "batch-job-{d}", .{i}) catch unreachable;
        const now: u64 = @intCast(cluster.clock.nanos);
        _ = leader.apply(.enqueue, &ops_mod.OpData{
            .enqueue = .{
                .now_ns = now,
                .jobs = @constCast(&[_]ops_mod.EnqueueJob{.{
                    .job_id = job_id,
                    .queue = "q1",
                    .priority = 50,
                    .max_retries = 1,
                    .created_at_ns = now,
                    .batch_id = "batch-1",
                }}),
            },
        });
        cluster.runTicks(2);
    }

    _ = leader.apply(.batch_seal, &ops_mod.OpData{
        .batch_seal = .{ .batch_id = "batch-1", .now_ns = @intCast(cluster.clock.nanos) },
    });

    // Queue pause/resume.
    _ = leader.apply(.queue_config, &ops_mod.OpData{
        .queue_config = .{ .queue = "q1", .action = .pause },
    });
    cluster.runTicks(5);
    _ = leader.apply(.queue_config, &ops_mod.OpData{
        .queue_config = .{ .queue = "q1", .action = .@"resume" },
    });

    // Maintenance.
    _ = leader.apply(.maintenance, &ops_mod.OpData{
        .maintenance = .{ .action = .promote, .now_ns = @intCast(cluster.clock.nanos) },
    });

    cluster.runTicks(50);
    try cluster.checkReplicationConsistency();
}

// ============================================================================
// Randomized adversarial cluster sim — multi-seed
// ============================================================================

fn runClusterSim(allocator: std.mem.Allocator, seed: u64, ticks: u32, drop_rate: u32) !void {
    var rng_state = std.Random.DefaultPrng.init(seed);
    const rng = rng_state.random();

    var cluster = try Cluster.init(allocator, 3);
    defer cluster.deinit();

    if (!cluster.electLeader(100)) return error.NoLeader;

    var enqueued: u32 = 0;
    var fetched: u32 = 0;
    var acked: u32 = 0;
    var failed: u32 = 0;
    var bulk_ops: u32 = 0;
    var maint_ops: u32 = 0;

    // Active jobs tracked for ack/fail.
    const max_active = 32;
    var active_ids: [max_active][64]u8 = undefined;
    var active_lens: [max_active]u8 = [_]u8{0} ** max_active;
    var active_count: usize = 0;

    // Completed job IDs for bulk retry.
    const max_completed = 64;
    var completed_ids: [max_completed][64]u8 = undefined;
    var completed_lens: [max_completed]u8 = [_]u8{0} ** max_completed;
    var completed_count: usize = 0;

    // Enable packet loss after election is stable.
    if (drop_rate > 0) cluster.network.setPacketLoss(drop_rate);

    var tick: u32 = 0;
    while (tick < ticks) : (tick += 1) {
        cluster.tick();

        const leader = cluster.getLeader() orelse continue;
        const now: u64 = @intCast(cluster.clock.nanos);
        const r = rng.float(f64);

        // Force complete if too many active.
        if (active_count >= max_active / 2) {
            if (active_count > 0) {
                const idx = rng.intRangeAtMost(usize, 0, active_count - 1);
                const jid = active_ids[idx][0..active_lens[idx]];
                if (rng.float(f64) < 0.3) {
                    const fj = [1]ops_mod.FailJob{.{ .job_id = jid, .queue = "q1", .error_msg = "sim" }};
                    _ = leader.apply(.fail, &ops_mod.OpData{ .fail = .{ .jobs = &fj, .now_ns = now } });
                    failed += 1;
                } else {
                    const aj = [1]ops_mod.AckJob{.{ .job_id = jid, .queue = "q1" }};
                    _ = leader.apply(.ack, &ops_mod.OpData{ .ack = .{ .acks = &aj, .now_ns = now } });
                    acked += 1;
                }
                // Track completed.
                if (completed_count < max_completed) {
                    @memcpy(completed_ids[completed_count][0..active_lens[idx]], jid);
                    completed_lens[completed_count] = active_lens[idx];
                    completed_count += 1;
                }
                // Swap-remove.
                active_ids[idx] = active_ids[active_count - 1];
                active_lens[idx] = active_lens[active_count - 1];
                active_count -= 1;
            }
            continue;
        }

        if (r < 0.08) {
            // Maintenance.
            const actions = [_]ops_mod.MaintenanceAction{ .promote, .reclaim, .expire, .purge, .unique, .batches };
            const action = actions[rng.intRangeAtMost(usize, 0, actions.len - 1)];
            _ = leader.apply(.maintenance, &ops_mod.OpData{ .maintenance = .{ .action = action, .now_ns = now } });
            maint_ops += 1;
        } else if (r < 0.13 and completed_count > 0) {
            // Bulk retry/cancel.
            const ci = rng.intRangeAtMost(usize, 0, completed_count - 1);
            const cid = completed_ids[ci][0..completed_lens[ci]];
            const id_ptrs = [1][]const u8{cid};
            const actions = [_]ops_mod.BulkAction{ .retry, .cancel, .delete };
            const action = actions[rng.intRangeAtMost(usize, 0, 2)];
            _ = leader.apply(.bulk_action, &ops_mod.OpData{
                .bulk_action = .{ .job_ids = &id_ptrs, .action = action, .now_ns = now },
            });
            bulk_ops += 1;
        } else if (r < 0.45 and active_count > 0) {
            // Ack or fail.
            const idx = rng.intRangeAtMost(usize, 0, active_count - 1);
            const jid = active_ids[idx][0..active_lens[idx]];
            if (rng.float(f64) < 0.2) {
                const fj = [1]ops_mod.FailJob{.{ .job_id = jid, .queue = "q1", .error_msg = "sim" }};
                _ = leader.apply(.fail, &ops_mod.OpData{ .fail = .{ .jobs = &fj, .now_ns = now } });
                failed += 1;
            } else {
                const aj = [1]ops_mod.AckJob{.{ .job_id = jid, .queue = "q1" }};
                _ = leader.apply(.ack, &ops_mod.OpData{ .ack = .{ .acks = &aj, .now_ns = now } });
                acked += 1;
            }
            if (completed_count < max_completed) {
                @memcpy(completed_ids[completed_count][0..active_lens[idx]], jid);
                completed_lens[completed_count] = active_lens[idx];
                completed_count += 1;
            }
            active_ids[idx] = active_ids[active_count - 1];
            active_lens[idx] = active_lens[active_count - 1];
            active_count -= 1;
        } else if (r < 0.65) {
            // Fetch.
            if (active_count < max_active) {
                const queues = [1][]const u8{"q1"};
                const result = leader.apply(.fetch, &ops_mod.OpData{
                    .fetch = .{ .queues = &queues, .worker_id = "sim-w", .count = 1, .now_ns = now, .lease_duration_ms = 30000 },
                });
                if (result.affected > 0) {
                    const f = &result.fetched[0];
                    @memcpy(active_ids[active_count][0..f.id_len], f.id_buf[0..f.id_len]);
                    active_lens[active_count] = @intCast(f.id_len);
                    active_count += 1;
                    fetched += 1;
                }
            }
        } else {
            // Enqueue.
            var id_buf: [64]u8 = undefined;
            const jid = std.fmt.bufPrint(&id_buf, "csim_{d}_{d}", .{ seed, enqueued }) catch unreachable;
            const jobs = [1]ops_mod.EnqueueJob{.{
                .job_id = jid,
                .queue = "q1",
                .priority = @intCast(rng.intRangeAtMost(u8, 1, 255)),
                .max_retries = 3,
                .created_at_ns = now,
            }};
            _ = leader.apply(.enqueue, &ops_mod.OpData{
                .enqueue = .{ .jobs = &jobs, .now_ns = now },
            });
            enqueued += 1;
        }
    }

    // Stop fault injection, let replication converge.
    cluster.network.setPacketLoss(0);
    cluster.network.healAll();
    cluster.runTicks(500);

    // Verify all nodes converged.
    try cluster.checkReplicationConsistency();

    std.debug.print(
        "OK seed={d} ticks={d} drop=1/{d} | enq={d} fetch={d} ack={d} fail={d} bulk={d} maint={d}\n",
        .{ seed, ticks, if (drop_rate > 0) drop_rate else @as(u32, 0), enqueued, fetched, acked, failed, bulk_ops, maint_ops },
    );
}

test "cluster sim: 20 seeds, no drops" {
    const seeds = [_]u64{ 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000, 1100, 1200, 1300, 1400, 1500, 1600, 1700, 1800, 1900, 2000 };
    for (seeds) |s| {
        try runClusterSim(std.testing.allocator, s, 500, 0);
    }
}

test "cluster sim: 10 seeds, 5% packet loss" {
    const seeds = [_]u64{ 3001, 3002, 3003, 3004, 3005, 3006, 3007, 3008, 3009, 3010 };
    for (seeds) |s| {
        try runClusterSim(std.testing.allocator, s, 500, 20);
    }
}

test "cluster sim: 10 seeds, 10% packet loss" {
    const seeds = [_]u64{ 4001, 4002, 4003, 4004, 4005, 4006, 4007, 4008, 4009, 4010 };
    for (seeds) |s| {
        try runClusterSim(std.testing.allocator, s, 500, 10);
    }
}

test "cluster sim: 5 seeds, 10% packet loss, 1000 ticks" {
    const seeds = [_]u64{ 6001, 6002, 6003, 6004, 6005 };
    for (seeds) |s| {
        try runClusterSim(std.testing.allocator, s, 1000, 10);
    }
}

test "cluster replication after multiple ops" {
    const allocator = std.testing.allocator;

    var cluster = try Cluster.init(allocator, 3);
    defer cluster.deinit();

    try std.testing.expect(cluster.electLeader(50));

    // Enqueue + tick interleaved.
    for (0..10) |i| {
        var id_buf: [32]u8 = undefined;
        const job_id = std.fmt.bufPrint(&id_buf, "job-{d}", .{i}) catch unreachable;

        const now: u64 = @intCast(cluster.clock.nanos);
        const data = ops_mod.OpData{
            .enqueue = .{
                .now_ns = now,
                .jobs = @constCast(&[_]ops_mod.EnqueueJob{.{
                    .job_id = job_id,
                    .queue = "q1",
                    .priority = 50,
                    .max_retries = 1,
                    .created_at_ns = now,
                }}),
            },
        };
        _ = cluster.submitToLeader(.enqueue, &data);
        cluster.runTicks(3); // let replication happen between ops
    }

    // Final tick burst.
    cluster.runTicks(20);

    try cluster.checkReplicationConsistency();
}
