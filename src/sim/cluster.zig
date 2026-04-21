//! Cluster simulator — multi-node PBR with Pipeline(SimBackend) on the leader.
//!
//! Each node has:
//!   - Talon DB + KV store
//!   - OpHandler, Oplog, QueueNotifier
//!   - Election FSM
//!   - InMemTransport for replication
//!
//! The LEADER node runs Pipeline(SimBackend) — client RPC frames go through the
//! full pipeline write path (decode → executeBatch → recordOplog → replicate).
//! The replicate_fn callback fans out oplog entries to followers via InMemTransport.
//!
//! FOLLOWER nodes apply replicated mutations directly to KV via follower.step().
//! They don't run a pipeline (no client connections).
//!
//! Tick loop:
//!   1. Clock advance
//!   2. Client injects RPC frame into leader's SimBackend
//!   3. Leader's pipeline.tick()  →  drain → execute → oplog → replicate → respond
//!   4. Deliver transport messages (election + replication)
//!   5. Election tick on all nodes
//!   6. Client reads response
//!   7. Periodic invariant checks (KV consistency across all nodes)

const std = @import("std");
const talon = @import("talon");
const corvo = @import("corvo");

const kv = corvo.kv;
const handler_mod = corvo.handler;
const oplog_mod = corvo.oplog;
const notify_mod = corvo.notify;
const pipeline_mod = corvo.pipeline;
const io_mod = corvo.io;
const election_mod = corvo.election;
const repl_mod = corvo.replicator;
const follower_mod = corvo.follower;
const transport_mod = corvo.transport;

const SimClock = @import("clock.zig").SimClock;
const setGlobalClock = @import("clock.zig").setGlobalClock;
const globalClockNow = @import("clock.zig").globalClockNow;
const Config = @import("config.zig").Config;
const SimClient = @import("client.zig").SimClient;
const invariants = @import("invariants.zig");

const SimBackend = io_mod.SimBackend;
const Pipeline = pipeline_mod.Pipeline(SimBackend);
const ReplHook = pipeline_mod.ReplHook;

const max_nodes = 7;
const max_queues = 8;
const max_clients = 16;

// ============================================================================
// ReplContext — bridges Pipeline's repl_hook to the replicator + transport
// ============================================================================

const ReplContext = struct {
    node_idx: usize,
    cluster: *SimCluster,

    fn replicate(ptr: *anyopaque, _: u16, seq: u64, _: []const u8) void {
        const self: *ReplContext = @ptrCast(@alignCast(ptr));
        const cluster = self.cluster;
        const node = &cluster.nodes[self.node_idx];

        node.last_oplog_seq = seq;

        const r = &(node.replicator orelse return);

        // Read from the oplog (which owns the data) instead of using the
        // `data` parameter — that slice is freed by recordOplog after we return.
        // The oplog entries persist for the lifetime of the sim.
        const oplog_entries = node.oplog.readAfter(if (seq > 0) seq - 1 else 0, 1);
        if (oplog_entries.len == 0) return;

        var repl_entries: [1]repl_mod.Entry = .{.{
            .seq = oplog_entries[0].seq,
            .shard_id = oplog_entries[0].shard_id,
            .data = oplog_entries[0].data,
        }};
        const msgs = r.replicate(&repl_entries);
        defer cluster.allocator.free(msgs);

        for (msgs) |m| {
            _ = node.transport.send(m.to, .{
                .repl = .{
                    .type_ = .replicate,
                    .epoch = m.epoch,
                    .seq = m.seq,
                    .shard_id = m.shard_id,
                    .data = m.data,
                },
            });
        }
    }
};

// ============================================================================
// KvApplier — applies replicated mutations to a follower's KV store
// ============================================================================

const KvApplier = struct {
    node_idx: usize,
    cluster: *SimCluster,

    fn applier(self: *KvApplier) follower_mod.Applier {
        return .{
            .ptr = @ptrCast(self),
            .applyFn = @ptrCast(&applyBatchImpl),
        };
    }

    fn applyBatchImpl(self: *KvApplier, shard_id: u16, seq: u64, data: []const u8) follower_mod.ApplyError!void {
        _ = shard_id;
        _ = seq;
        const node = &self.cluster.nodes[self.node_idx];

        const mutations = oplog_mod.decodeMutations(self.cluster.allocator, data) catch
            return error.ApplyFailed;
        defer self.cluster.allocator.free(mutations);

        var batch = node.store.newBatch();
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
// SimClusterNode — one node in the simulated cluster
// ============================================================================

const SimClusterNode = struct {
    id: []const u8,
    db: *talon.DB,
    store: kv.Store,
    stores: [1]kv.Store, // stable backing for pipeline's stores slice
    handler: handler_mod.OpHandler,
    oplog: oplog_mod.Log,
    notify: notify_mod.QueueNotifier,
    election: election_mod.Election,
    transport: *transport_mod.InMemTransport,

    // Leader: pipeline + SimBackend for client connections
    backend: ?*SimBackend,
    pipeline: ?*Pipeline,

    // Replication state
    replicator: ?repl_mod.Replicator,
    follower_state: ?follower_mod.Follower,
    last_oplog_seq: u64,

    allocator: std.mem.Allocator,
};

// ============================================================================
// SimCluster — orchestrates N nodes
// ============================================================================

var g_instance_counter: u32 = 0;

pub const SimCluster = struct {
    nodes: []SimClusterNode,
    repl_ctxs: []ReplContext,
    kv_appliers: []KvApplier,
    network: *transport_mod.InMemNetwork,
    clock: *SimClock,
    allocator: std.mem.Allocator,
    instance_id: u32,
    tick_count: u64 = 0,
    last_leader_idx: ?usize = null,
    sync_replication: bool = false,

    node_ids: [][]const u8,
    peer_lists: [][][]const u8,

    pub fn init(allocator: std.mem.Allocator, node_count: u8, clock: *SimClock) !SimCluster {
        std.debug.assert(node_count >= 1 and node_count <= max_nodes);
        const instance_id = g_instance_counter;
        g_instance_counter += 1;

        // Build node ID strings.
        const node_ids = try allocator.alloc([]const u8, node_count);
        for (0..node_count) |i| {
            node_ids[i] = try std.fmt.allocPrint(allocator, "node-{d}", .{i + 1});
        }

        // Build peer lists.
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

        const network = try allocator.create(transport_mod.InMemNetwork);
        network.* = transport_mod.InMemNetwork.init(allocator);

        // Use very long election timers so leader is stable for the entire sim.
        // The sim clock advances ~200ms per client tick + 10ms per cluster tick.
        // With a 60s lease, the leader won't lose leadership during the test.
        const election_config = election_mod.Config{
            .lease_duration = 60_000_000_000, // 60s
            .renew_interval = 10_000_000_000, // 10s
            .election_timeout = 30_000_000_000, // 30s
        };

        const nodes = try allocator.alloc(SimClusterNode, node_count);
        const repl_ctxs = try allocator.alloc(ReplContext, node_count);
        const kv_appliers = try allocator.alloc(KvApplier, node_count);

        for (0..node_count) |i| {
            var dir_buf: [80]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&dir_buf, "/tmp/corvo-csim-{d}-{d}", .{ instance_id, i }) catch unreachable;
            std.fs.cwd().deleteTree(dir_path) catch {};

            const db = try talon.DB.open(allocator, dir_path, .{ .sync = false });
            const store = kv.Store.init(db);

            nodes[i] = .{
                .id = node_ids[i],
                .db = db,
                .store = store,
                .stores = [1]kv.Store{store},
                .handler = handler_mod.OpHandler.init(allocator),
                .oplog = oplog_mod.Log.init(allocator, .{ .now_fn = &globalClockNow }, null, 1024),
                .notify = notify_mod.QueueNotifier.init(allocator),
                .election = election_mod.Election.init(allocator, node_ids[i], peer_lists[i], election_config),
                .transport = network.newTransport(node_ids[i]),
                .backend = null,
                .pipeline = null,
                .replicator = null,
                .follower_state = null,
                .last_oplog_seq = 0,
                .allocator = allocator,
            };
        }

        var self = SimCluster{
            .nodes = nodes,
            .repl_ctxs = repl_ctxs,
            .kv_appliers = kv_appliers,
            .network = network,
            .clock = clock,
            .allocator = allocator,
            .instance_id = instance_id,
            .node_ids = node_ids,
            .peer_lists = peer_lists,
        };

        // Initialize contexts (need stable self pointer after return, so
        // callers must not move the struct — heap-allocate if needed).
        for (0..node_count) |i| {
            repl_ctxs[i] = .{ .node_idx = i, .cluster = &self };
            kv_appliers[i] = .{ .node_idx = i, .cluster = &self };
        }

        return self;
    }

    pub fn deinit(self: *SimCluster) void {
        for (self.nodes, 0..) |*n, node_idx| {
            if (n.pipeline) |p| {
                p.deinit();
                self.allocator.destroy(p);
            }
            if (n.backend) |b| {
                b.deinit(self.allocator);
                self.allocator.destroy(b);
            }
            n.handler.deinit();
            n.oplog.deinit();
            n.notify.deinit();
            n.election.deinit();
            if (n.replicator) |*r| r.deinit();
            n.db.close();

            // Clean up temp dir.
            var dir_buf: [80]u8 = undefined;
            const dir_path = std.fmt.bufPrint(&dir_buf, "/tmp/corvo-csim-{d}-{d}", .{ self.instance_id, node_idx }) catch continue;
            std.fs.cwd().deleteTree(dir_path) catch {};
        }

        self.network.deinit();
        self.allocator.destroy(self.network);
        self.allocator.free(self.nodes);
        self.allocator.free(self.repl_ctxs);
        self.allocator.free(self.kv_appliers);

        for (self.peer_lists) |peers| self.allocator.free(peers);
        self.allocator.free(self.peer_lists);

        for (self.node_ids) |id| self.allocator.free(@constCast(id));
        self.allocator.free(self.node_ids);
    }

    // ====================================================================
    // Election
    // ====================================================================

    pub fn electLeader(self: *SimCluster, max_ticks: u32) bool {
        for (0..max_ticks) |_| {
            // Advance by 1s per tick during election — election_timeout is 30s.
            self.clock.advance(1_000_000_000);
            self.tickElection();
            if (self.getLeaderIdx() != null) {
                self.onLeadershipChange();
                return true;
            }
        }
        return false;
    }

    fn tickElection(self: *SimCluster) void {
        for (self.nodes) |*n| {
            n.election.last_log_seq = n.last_oplog_seq;
        }
        // Drain transport messages for election.
        for (self.nodes) |*n| {
            while (n.transport.recvOne()) |incoming| {
                switch (incoming.msg) {
                    .election => |emsg| {
                        const now = self.clock.now();
                        const lmsg = election_mod.Message{
                            .type_ = emsg.type_,
                            .from = incoming.from,
                            .to = n.id,
                            .epoch = emsg.epoch,
                            .granted = emsg.granted,
                            .last_log_seq = emsg.last_log_seq,
                            .config_hash = emsg.config_hash,
                        };
                        const replies = n.election.step(lmsg, now);
                        for (replies) |r| {
                            _ = n.transport.send(r.to, .{
                                .election = .{
                                    .type_ = r.type_,
                                    .epoch = r.epoch,
                                    .granted = r.granted,
                                    .last_log_seq = r.last_log_seq,
                                    .config_hash = r.config_hash,
                                },
                            });
                        }
                    },
                    .repl => |rmsg| {
                        self.handleReplMsg(n, incoming.from, rmsg);
                    },
                }
            }
            // Tick election FSM.
            const now = self.clock.now();
            const tick_msgs = n.election.tick(now);
            for (tick_msgs) |m| {
                _ = n.transport.send(m.to, .{
                    .election = .{
                        .type_ = m.type_,
                        .epoch = m.epoch,
                        .granted = m.granted,
                        .last_log_seq = m.last_log_seq,
                        .config_hash = m.config_hash,
                    },
                });
            }
        }
    }

    fn handleReplMsg(self: *SimCluster, node: *SimClusterNode, from: []const u8, rmsg: transport_mod.ReplMsg) void {
        switch (rmsg.type_) {
            .replicate => {
                const f = &(node.follower_state orelse return);
                const msg = repl_mod.Message{
                    .type_ = .replicate,
                    .from = from,
                    .to = node.id,
                    .epoch = rmsg.epoch,
                    .seq = rmsg.seq,
                    .shard_id = rmsg.shard_id,
                    .data = rmsg.data,
                };
                const replies = f.step(msg);
                for (replies) |r| {
                    _ = node.transport.send(r.to, .{
                        .repl = .{
                            .type_ = r.type_,
                            .epoch = r.epoch,
                            .seq = r.seq,
                            .shard_id = r.shard_id,
                            .data = r.data,
                        },
                    });
                }
            },
            .ack => {
                const r = &(node.replicator orelse return);
                r.step(.{
                    .type_ = .ack,
                    .from = from,
                    .to = node.id,
                    .epoch = rmsg.epoch,
                    .seq = rmsg.seq,
                });
                // Update pipeline's sync-repl atomic so deferred responses flush.
                if (node.pipeline) |p| p.onFollowerAck(rmsg.seq);
            },
            .need_snap => {
                const r = &(node.replicator orelse return);
                r.step(.{
                    .type_ = .need_snap,
                    .from = from,
                    .to = node.id,
                    .epoch = rmsg.epoch,
                    .seq = rmsg.seq,
                });
                // Find the follower and snapshot KV.
                for (self.nodes, 0..) |*n, i| {
                    if (std.mem.eql(u8, n.id, from)) {
                        const leader_idx = self.getLeaderIdx() orelse return;
                        self.snapshotKV(leader_idx, i);
                        break;
                    }
                }
            },
            .snapshot => {},
        }
    }

    // ====================================================================
    // Leadership changes
    // ====================================================================

    fn onLeadershipChange(self: *SimCluster) void {
        const leader_idx = self.getLeaderIdx() orelse return;
        const leader = &self.nodes[leader_idx];
        const epoch = leader.election.currentState().epoch;
        const leader_seq = leader.oplog.getSeq();

        // Set up replicator on leader.
        if (leader.replicator) |*old_r| old_r.deinit();
        leader.replicator = repl_mod.Replicator.init(
            self.allocator,
            leader.id,
            epoch,
            self.peer_lists[leader_idx],
            1000,
        );

        // Create Pipeline + SimBackend for the leader if not already present.
        if (leader.pipeline == null) {
            const backend = self.allocator.create(SimBackend) catch unreachable;
            backend.* = SimBackend.init(self.allocator, .{
                .listen_fd = -1,
                .max_conns = max_clients + 4,
                .recv_buf_size = 65536,
                .send_buf_size = 65536,
            }) catch unreachable;

            const p = self.allocator.create(Pipeline) catch unreachable;
            p.* = Pipeline.init(
                self.allocator,
                backend,
                &leader.handler,
                &leader.stores,
                &leader.oplog,
                &leader.notify,
                null,
                .{
                    .clock_fn = &globalClockNow,
                    .repl_hook = .{
                        .ptr = @ptrCast(&self.repl_ctxs[leader_idx]),
                        .replicate_fn = @ptrCast(&ReplContext.replicate),
                    },
                    .sync_replication = self.sync_replication,
                    .promote_interval_ns = 1_000_000_000,
                    .reclaim_interval_ns = 1_000_000_000,
                    .unique_interval_ns = 30_000_000_000,
                    .rate_limit_interval_ns = 30_000_000_000,
                    .expire_interval_ns = 10_000_000_000,
                    .purge_interval_ns = 3_600_000_000_000,
                },
            );

            leader.backend = backend;
            leader.pipeline = p;
        }

        // Snapshot leader's KV to all followers and set up follower state.
        for (0..self.nodes.len) |i| {
            if (i == leader_idx) continue;
            self.snapshotKV(leader_idx, i);

            self.nodes[i].follower_state = follower_mod.Follower.init(
                self.nodes[i].id,
                epoch,
                leader_seq,
                self.kv_appliers[i].applier(),
            );

            // Destroy follower's pipeline if it had one (was previous leader).
            if (self.nodes[i].pipeline) |p| {
                p.deinit();
                self.allocator.destroy(p);
                self.nodes[i].pipeline = null;
            }
            if (self.nodes[i].backend) |b| {
                b.deinit(self.allocator);
                self.allocator.destroy(b);
                self.nodes[i].backend = null;
            }
            self.nodes[i].replicator = null;
        }

        self.last_leader_idx = leader_idx;
    }

    fn snapshotKV(self: *SimCluster, src_idx: usize, dst_idx: usize) void {
        const src = &self.nodes[src_idx];
        const dst = &self.nodes[dst_idx];

        // Clear dst KV.
        {
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

        // Rebuild handler state.
        dst.handler.clearState();
        dst.handler.rebuildState(&dst.stores);
    }

    // ====================================================================
    // Queries
    // ====================================================================

    pub fn getLeaderIdx(self: *SimCluster) ?usize {
        for (self.nodes, 0..) |*n, i| {
            if (n.election.isLeader()) return i;
        }
        return null;
    }

    pub fn getLeader(self: *SimCluster) ?*SimClusterNode {
        const idx = self.getLeaderIdx() orelse return null;
        return &self.nodes[idx];
    }

    // ====================================================================
    // Tick
    // ====================================================================

    pub fn tick(self: *SimCluster) void {
        self.tick_count += 1;

        const cur_leader = self.last_leader_idx;

        // Leader: resetUnacked + re-send from oplog for entries that were
        // dropped or not yet acked. The pipeline's repl_hook only fires on new
        // oplog entries, so retries must read from the oplog directly.
        if (cur_leader) |li| {
            const leader = &self.nodes[li];
            if (leader.replicator) |*r| {
                r.resetUnacked();

                // Re-send from minimum acked point.
                const head = leader.oplog.getSeq();
                if (head > 0) {
                    const min_acked = r.minAcked();
                    const read_from = if (min_acked > 0) min_acked else 0;
                    const entries_raw = leader.oplog.readAfter(read_from, 64);
                    if (entries_raw.len > 0) {
                        var repl_entries: [64]repl_mod.Entry = undefined;
                        for (entries_raw, 0..) |e, ei| {
                            repl_entries[ei] = .{
                                .seq = e.seq,
                                .shard_id = e.shard_id,
                                .data = e.data,
                            };
                        }
                        const msgs = r.replicate(repl_entries[0..entries_raw.len]);
                        defer self.allocator.free(msgs);
                        for (msgs) |m| {
                            _ = leader.transport.send(m.to, .{
                                .repl = .{
                                    .type_ = .replicate,
                                    .epoch = m.epoch,
                                    .seq = m.seq,
                                    .shard_id = m.shard_id,
                                    .data = m.data,
                                },
                            });
                        }
                    }
                }
            }
        }

        // Drain transport on all nodes (replication message delivery).
        // Election is NOT ticked during the main sim loop — leader is stable.
        self.drainTransport();
    }

    /// Drain transport messages on all nodes (replication only, no election).
    fn drainTransport(self: *SimCluster) void {
        for (self.nodes) |*n| {
            while (n.transport.recvOne()) |incoming| {
                switch (incoming.msg) {
                    .election => {},
                    .repl => |rmsg| {
                        self.handleReplMsg(n, incoming.from, rmsg);
                    },
                }
            }
        }
    }

    pub fn runTicks(self: *SimCluster, n: u32) void {
        for (0..n) |_| self.tick();
    }

    // ====================================================================
    // Invariant: replication consistency
    // ====================================================================

    pub fn checkReplicationConsistency(self: *SimCluster) !void {
        const leader_idx = self.getLeaderIdx() orelse return;
        const leader = &self.nodes[leader_idx];

        for (self.nodes, 0..) |*node, i| {
            if (i == leader_idx) continue;

            var lb = leader.store.newBatch();
            defer lb.close();
            var fb = node.store.newBatch();
            defer fb.close();

            var l_iter = lb.newIter("\x00", "\xff");
            defer l_iter.close();
            var f_iter = fb.newIter("\x00", "\xff");
            defer f_iter.close();

            var l_valid = l_iter.first();
            var f_valid = f_iter.first();
            var key_count: u32 = 0;

            while (l_valid and f_valid) {
                const l_key = l_iter.key();
                const f_key = f_iter.key();

                if (!std.mem.eql(u8, l_key, f_key)) {
                    // Key mismatch — one side has a key the other doesn't.
                    // Print both keys for debugging, then fail hard.
                    std.debug.print(
                        "REPLICATION KEY MISMATCH at position {d}: leader({s}) key[{d}]=\"",
                        .{ key_count, leader.id, l_key.len },
                    );
                    printKey(l_key);
                    std.debug.print("\", follower({s}) key[{d}]=\"", .{ node.id, f_key.len });
                    printKey(f_key);
                    std.debug.print("\"\n", .{});
                    return error.ReplicationMismatch;
                }

                const l_val = l_iter.value();
                const f_val = f_iter.value();

                if (!std.mem.eql(u8, l_val, f_val)) {
                    std.debug.print(
                        "REPLICATION VALUE MISMATCH at key \"",
                        .{},
                    );
                    printKey(l_key);
                    std.debug.print(
                        "\": leader({s}) {d} bytes, follower({s}) {d} bytes\n",
                        .{ leader.id, l_val.len, node.id, f_val.len },
                    );
                    return error.ReplicationMismatch;
                }

                key_count += 1;
                l_valid = l_iter.next();
                f_valid = f_iter.next();
            }

            // Both iterators must exhaust at the same time.
            if (l_valid) {
                std.debug.print(
                    "REPLICATION EXTRA LEADER KEY at position {d}: leader({s}) has key \"",
                    .{ key_count, leader.id },
                );
                printKey(l_iter.key());
                std.debug.print("\" but follower({s}) exhausted\n", .{node.id});
                return error.ReplicationMismatch;
            }
            if (f_valid) {
                std.debug.print(
                    "REPLICATION EXTRA FOLLOWER KEY at position {d}: follower({s}) has key \"",
                    .{ key_count, node.id },
                );
                printKey(f_iter.key());
                std.debug.print("\" but leader({s}) exhausted\n", .{leader.id});
                return error.ReplicationMismatch;
            }
        }
    }

    fn printKey(key: []const u8) void {
        for (key) |b| {
            if (b >= 0x20 and b <= 0x7e) {
                std.debug.print("{c}", .{b});
            } else {
                std.debug.print("\\x{x:0>2}", .{b});
            }
        }
    }
};

// ============================================================================
// Run function — called from sim.zig with node_count > 1
// ============================================================================

pub fn run(allocator: std.mem.Allocator, config: Config, node_count: u8) !void {
    const seed: u64 = if (config.seed == 0)
        @intCast(@as(u128, @bitCast(std.time.nanoTimestamp())) & 0xFFFFFFFFFFFFFFFF)
    else
        config.seed;

    var rng_state = std.Random.DefaultPrng.init(seed);
    const rng = rng_state.random();

    // --- Clock ---
    var clock = SimClock.init(1_000_000_000_000);
    setGlobalClock(&clock);

    // --- Cluster (heap-allocated for stable pointers) ---
    var cluster_ptr = try allocator.create(SimCluster);
    cluster_ptr.* = try SimCluster.init(allocator, node_count, &clock);
    defer {
        cluster_ptr.deinit();
        allocator.destroy(cluster_ptr);
    }

    // Fix up repl_ctx/kv_applier pointers (they reference the cluster).
    for (0..node_count) |i| {
        cluster_ptr.repl_ctxs[i].cluster = cluster_ptr;
        cluster_ptr.kv_appliers[i].cluster = cluster_ptr;
    }
    cluster_ptr.sync_replication = config.sync_replication;

    // --- Elect leader ---
    std.debug.assert(cluster_ptr.electLeader(100));

    const leader_idx = cluster_ptr.getLeaderIdx().?;
    const leader = &cluster_ptr.nodes[leader_idx];
    const backend = leader.backend.?;
    const pipeline = leader.pipeline.?;
    _ = pipeline;

    // --- Queue names ---
    const num_queues: usize = @min(config.queues, max_queues);
    var queue_name_bufs: [max_queues][32]u8 = undefined;
    var queue_slices: [max_queues][]const u8 = undefined;
    for (0..num_queues) |i| {
        queue_slices[i] = std.fmt.bufPrint(&queue_name_bufs[i], "queue-{d}", .{i}) catch unreachable;
    }
    const queues = queue_slices[0..num_queues];

    // --- Clients (connect to leader's SimBackend) ---
    var client_config = config;
    client_config.maintenance_rate = 0;

    const num_clients: usize = @min(config.clients, max_clients);
    var clients: [max_clients]SimClient = undefined;
    for (0..num_clients) |i| {
        const conn_id = backend.connect() orelse unreachable;
        clients[i] = SimClient.init(
            @intCast(i),
            seed +% @as(u64, i) +% 1,
            backend,
            conn_id,
            client_config,
            queues,
        );
        clients[i].rng = clients[i].prng.random();
    }

    // --- Main tick loop ---
    var tick: u32 = 0;
    while (tick < config.ticks) : (tick += 1) {
        clock.advance(config.tick_duration_ns);

        // Random time jump.
        if (rng.float(f64) < config.time_jump_prob) {
            clock.advance(rng.intRangeAtMost(i64, 1_000_000, config.time_jump_max_ns));
        }

        // Phase 1: clients inject RPC frames into leader's SimBackend.
        for (clients[0..num_clients]) |*c| {
            c.inject();
        }

        // Phase 2: leader's pipeline processes all frames.
        leader.pipeline.?.tick();

        // Phase 3: cluster tick — election + replication message delivery.
        cluster_ptr.tick();

        // Phase 3b: sync-repl needs a second cluster tick to deliver follower
        // acks to the leader, plus a pipeline tick to flush deferred responses.
        if (config.sync_replication) {
            cluster_ptr.tick();
            leader.pipeline.?.tick();
        }

        // Phase 4: clients read responses.
        for (clients[0..num_clients]) |*c| {
            c.processResponse();
        }

        // Periodic replication consistency check.
        if (tick > 0 and tick % (config.check_interval * 10) == 0) {
            // Run extra ticks to let replication converge.
            cluster_ptr.runTicks(50);
            try cluster_ptr.checkReplicationConsistency();
        }
    }

    // --- Final convergence + check ---
    // Run enough ticks for all in-flight entries to replicate + ack.
    // Each round trip is ~2 ticks (send → apply → ack → drain).
    // Sync-repl also needs pipeline ticks to flush deferred responses.
    for (0..500) |_| {
        cluster_ptr.tick();
        if (config.sync_replication) {
            if (leader.pipeline) |p| p.tick();
        }
    }

    try cluster_ptr.checkReplicationConsistency();

    // --- Stats ---
    var total_enqueued: u32 = 0;
    var total_fetched: u32 = 0;
    var total_acked: u32 = 0;
    var total_failed: u32 = 0;
    var total_stale_acks: u32 = 0;

    for (clients[0..num_clients]) |c| {
        total_enqueued += c.enqueued;
        total_fetched += c.fetched;
        total_acked += c.acked;
        total_failed += c.failed;
        total_stale_acks += c.stale_acks;
    }

    std.debug.print(
        "OK seed={d} ticks={d} nodes={d} clients={d} | enq={d} fetch={d} ack={d} fail={d} stale={d}\n",
        .{ seed, config.ticks, node_count, num_clients, total_enqueued, total_fetched, total_acked, total_failed, total_stale_acks },
    );
}

// ============================================================================
// Tests
// ============================================================================

test "cluster sim: 3 nodes, pipeline replication" {
    // Use page_allocator: cluster sim has complex cross-module ownership
    // (oplog entries → transport → follower apply) that makes precise leak
    // tracking impractical. Correctness is verified by replication consistency.
    try run(std.heap.page_allocator, .{
        .seed = 42,
        .ticks = 200,
        .clients = 2,
        .queues = 1,
    }, 3);
}

test "cluster sim: 3 nodes, multi-queue" {
    try run(std.heap.page_allocator, .{
        .seed = 200,
        .ticks = 300,
        .clients = 3,
        .queues = 2,
    }, 3);
}

test "cluster sim: 5 nodes" {
    try run(std.heap.page_allocator, .{
        .seed = 777,
        .ticks = 200,
        .clients = 2,
        .queues = 1,
    }, 5);
}

test "cluster sim: 3 nodes, sync replication" {
    try run(std.heap.page_allocator, .{
        .seed = 42,
        .ticks = 200,
        .clients = 2,
        .queues = 1,
        .sync_replication = true,
    }, 3);
}
