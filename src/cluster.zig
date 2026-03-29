//! Cluster — PBR cluster mode (election + replication + TCP transport).
//!
//! Manages a single node in a primary-backup replication cluster.
//! The leader replicates committed mutations to followers via TCP.
//! Followers apply replicated entries to their local KV stores.

const std = @import("std");
const assert = @import("assert.zig");
const kv = @import("kv.zig");
const oplog_mod = @import("oplog.zig");
const election_mod = @import("election.zig");
const repl_mod = @import("replicator.zig");
const follower_mod = @import("follower.zig");
const transport_mod = @import("transport.zig");
const tcp_mod = @import("tcp_transport.zig");
const pipeline_mod = @import("pipeline.zig");
const handler_mod = @import("handler.zig");
const metrics_mod = @import("metrics.zig");

// ============================================================================
// Config
// ============================================================================

pub const ClusterConfig = struct {
    node_id: []const u8,
    peer_ids: []const []const u8,
    peer_addrs: []const std.net.Address,
    bind_addr: std.net.Address,
    max_lag: u64 = 10000,
    tick_interval_ms: u32 = 50,
    /// Cluster config hash — exchanged during election. Nodes with
    /// different configs refuse to form a cluster.
    config_hash: u64 = 0,
};

// ============================================================================
// ClusterNode
// ============================================================================

pub const ClusterNode = struct {
    config: ClusterConfig,
    transport: tcp_mod.TcpTransport,
    election: election_mod.Election,
    replicator: ?*repl_mod.Replicator = null, // heap-allocated for stable pointers
    kv_applier: KVApplier,
    follower: ?*follower_mod.Follower = null, // heap-allocated for stable pointers
    shards: []kv.Store,
    handler: ?*handler_mod.OpHandler = null, // for rebuild after snapshot
    oplog: ?*oplog_mod.Log = null, // for sync-repl retry (set by main)
    allocator: std.mem.Allocator,

    // Tick loop
    tick_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Leader state
    is_leader_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    tick_counter: u64 = 0,
    /// Latest oplog sequence seen (updated on every replicate call).
    last_oplog_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Cluster event log for monitoring.
    events: metrics_mod.ClusterEventRing = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        shards: []kv.Store,
        config: ClusterConfig,
    ) ClusterNode {
        var transport = tcp_mod.TcpTransport.init(allocator, config.node_id);

        // Register peers
        for (config.peer_ids, 0..) |pid, i| {
            transport.addPeer(pid, config.peer_addrs[i]);
        }

        var election = election_mod.Election.init(
            allocator,
            config.node_id,
            config.peer_ids,
            .{
                .lease_duration = 5_000_000_000, // 5s
                .renew_interval = 1_000_000_000, // 1s
                .election_timeout = 3_000_000_000, // 3s
            },
        );
        election.config_hash = config.config_hash;

        return .{
            .config = config,
            .transport = transport,
            .election = election,
            .kv_applier = .{ .shards = shards, .allocator = allocator },
            .shards = shards,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClusterNode) void {
        self.stop();
        if (self.replicator) |r| {
            r.deinit();
            self.allocator.destroy(r);
            self.replicator = null;
        }
        if (self.follower) |f| {
            self.allocator.destroy(f);
            self.follower = null;
        }
        self.election.deinit();
        self.transport.deinit();
    }

    pub fn start(self: *ClusterNode) !void {
        // Initialize as follower
        const f = try self.allocator.create(follower_mod.Follower);
        f.* = follower_mod.Follower.init(
            self.config.node_id,
            0, // epoch 0
            0, // last_applied 0
            self.kv_applier.applier(),
        );
        self.follower = f;

        // Wire fast-path ack callback: TCP receive thread routes acks
        // directly to the replicator, bypassing the 50ms tick loop.
        g_cluster_for_ack = self;
        self.transport.ack_callback = &fastPathAckCallback;

        try self.transport.start(self.config.bind_addr);
        self.running.store(true, .monotonic);
        self.tick_thread = try std.Thread.spawn(.{}, tickLoop, .{self});
    }

    pub fn stop(self: *ClusterNode) void {
        self.running.store(false, .monotonic);
        self.transport.stop();
        if (self.tick_thread) |t| {
            t.join();
            self.tick_thread = null;
        }
    }

    /// Returns a ReplHook for pipeline to call after oplog append.
    pub fn replHook(self: *ClusterNode) pipeline_mod.ReplHook {
        return .{
            .ptr = @ptrCast(self),
            .replicate_fn = @ptrCast(&replicateImpl),
        };
    }

    fn replicateImpl(self: *ClusterNode, shard_id: u16, seq: u64, data: []const u8) void {
        self.last_oplog_seq.store(seq, .monotonic);
        if (!self.is_leader_flag.load(.monotonic)) return;

        const r = self.replicator orelse return;
        const entries = [_]repl_mod.Entry{
            .{ .seq = seq, .shard_id = shard_id, .data = data },
        };
        const msgs = r.replicate(&entries);
        defer self.allocator.free(msgs);

        for (msgs) |m| {
            const rmsg = transport_mod.ReplMsg{
                .type_ = m.type_,
                .epoch = m.epoch,
                .seq = m.seq,
                .shard_id = m.shard_id,
                .data = m.data,
            };
            _ = self.transport.send(m.to, .{ .repl = rmsg });
        }
    }

    pub fn isLeader(self: *ClusterNode) bool {
        return self.is_leader_flag.load(.monotonic);
    }

    /// Returns true if this node holds a valid leader lease.
    pub fn leaseValid(self: *ClusterNode) bool {
        const now: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        return self.election.leaseValid(now);
    }

    /// Wait for leader election to complete (blocking).
    pub fn waitForLeader(self: *ClusterNode, timeout_ms: u32) bool {
        const deadline = std.time.milliTimestamp() + @as(i64, timeout_ms);
        while (std.time.milliTimestamp() < deadline) {
            const s = self.election.currentState();
            if (s.state == .leader or s.leader_id.len > 0) return true;
            std.Thread.sleep(50_000_000); // 50ms
        }
        return false;
    }

    // ========================================================================
    // Tick loop
    // ========================================================================

    fn tickLoop(self: *ClusterNode) void {
        while (self.running.load(.monotonic)) {
            const had_msg = self.tick();
            if (had_msg) {
                // Messages pending — keep spinning with minimal sleep.
                std.Thread.sleep(10_000); // 10µs
            } else {
                // Idle — use configured tick interval.
                std.Thread.sleep(@as(u64, self.config.tick_interval_ms) * 1_000_000);
            }
        }
    }

    /// Returns true if any messages were processed (caller should keep spinning).
    fn tick(self: *ClusterNode) bool {
        const now: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        self.tick_counter += 1;

        // Drain incoming messages
        var had_election_msg = false;
        var had_any_msg = false;
        while (self.transport.recvOne()) |incoming| {
            had_any_msg = true;
            switch (incoming.msg) {
                .election => |emsg| {
                    self.handleElectionMsg(incoming.from, emsg, now);
                    had_election_msg = true;
                },
                .repl => |rmsg| {
                    self.handleReplMsg(incoming.from, rmsg);
                },
            }
        }

        // Advance election timer — include our oplog seq so proposals
        // carry log completeness info (Kafka ISR-style leader election).
        if (!had_election_msg) {
            self.election.last_log_seq = self.last_oplog_seq.load(.monotonic);
            const tick_msgs = self.election.tick(now);
            self.sendElectionMsgs(tick_msgs);
        }

        // Detect leadership changes
        const was_leader = self.is_leader_flag.load(.monotonic);
        const now_leader = self.election.isLeader();

        if (now_leader and !was_leader) {
            self.becomeLeader();
        } else if (!now_leader and was_leader) {
            self.stepDown();
        }

        // Periodic replication retry + snapshot re-send.
        if (now_leader and self.tick_counter % 20 == 0) {
            if (self.replicator) |r| {
                r.resetUnacked();

                // Re-send unacked entries from the oplog. Without this,
                // sync-repl hangs if the initial send fails or the ack is
                // lost — the pipeline defers and never calls replicateImpl
                // again, so resetUnacked alone is not enough.
                if (self.oplog) |oplog| {
                    const min_acked = r.minAcked();
                    const entries_raw = oplog.readAfter(min_acked, 64);
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
                            _ = self.transport.send(m.to, .{
                                .repl = .{
                                    .type_ = m.type_,
                                    .epoch = m.epoch,
                                    .seq = m.seq,
                                    .shard_id = m.shard_id,
                                    .data = m.data,
                                },
                            });
                        }
                    }
                }

                // Re-send snapshots to followers that still need them.
                // This handles dropped snapshot messages.
                const prog = r.progress();
                defer self.allocator.free(prog);
                for (prog) |fp| {
                    if (fp.need_snap) {
                        self.snapshotToPeer(fp.id);
                    }
                }
            }
        }

        return had_any_msg;
    }

    fn becomeLeader(self: *ClusterNode) void {
        const state = self.election.currentState();
        std.debug.print("cluster: {s} became leader (epoch={d})\n", .{
            self.config.node_id, state.epoch,
        });

        var ev = metrics_mod.ClusterEvent{
            .type_ = .leader_elected,
            .epoch = state.epoch,
            .timestamp_ns = @intCast(@as(i128, std.time.nanoTimestamp())),
        };
        const detail = std.fmt.bufPrint(&ev.detail_buf, "{s}", .{self.config.node_id}) catch "";
        ev.detail_len = @intCast(detail.len);
        self.events.push(ev);

        // Clean up old replicator
        if (self.replicator) |r| {
            r.deinit();
            self.allocator.destroy(r);
        }

        // Create new replicator on heap
        const r = self.allocator.create(repl_mod.Replicator) catch unreachable;
        r.* = repl_mod.Replicator.init(
            self.allocator,
            self.config.node_id,
            state.epoch,
            self.config.peer_ids,
            self.config.max_lag,
        );
        self.replicator = r;

        // Disable follower mode
        if (self.follower) |f| {
            self.allocator.destroy(f);
            self.follower = null;
        }
        self.is_leader_flag.store(true, .monotonic);

        // Note: snapshot to followers happens lazily via need_snap mechanism.
        // Don't do it synchronously here — file I/O in the tick thread
        // causes the leader to miss heartbeats and step down immediately.
    }

    fn stepDown(self: *ClusterNode) void {
        std.debug.print("cluster: {s} stepped down\n", .{self.config.node_id});

        var ev = metrics_mod.ClusterEvent{
            .type_ = .leader_stepped_down,
            .epoch = self.election.currentState().epoch,
            .timestamp_ns = @intCast(@as(i128, std.time.nanoTimestamp())),
        };
        const detail = std.fmt.bufPrint(&ev.detail_buf, "{s}", .{self.config.node_id}) catch "";
        ev.detail_len = @intCast(detail.len);
        self.events.push(ev);

        self.is_leader_flag.store(false, .monotonic);

        if (self.replicator) |r| {
            r.deinit();
            self.allocator.destroy(r);
            self.replicator = null;
        }

        // Re-enable follower mode
        const f = self.allocator.create(follower_mod.Follower) catch unreachable;
        const fstate = self.election.currentState();
        f.* = follower_mod.Follower.init(
            self.config.node_id,
            fstate.epoch,
            0,
            self.kv_applier.applier(),
        );
        self.follower = f;

        var fev = metrics_mod.ClusterEvent{
            .type_ = .follower_started,
            .epoch = fstate.epoch,
            .timestamp_ns = @intCast(@as(i128, std.time.nanoTimestamp())),
        };
        const fdetail = std.fmt.bufPrint(&fev.detail_buf, "{s}", .{self.config.node_id}) catch "";
        fev.detail_len = @intCast(fdetail.len);
        self.events.push(fev);
    }

    // ========================================================================
    // Message handlers
    // ========================================================================

    fn handleElectionMsg(self: *ClusterNode, from: []const u8, emsg: transport_mod.ElectionMsg, now: i64) void {
        const lmsg = election_mod.Message{
            .type_ = emsg.type_,
            .from = from,
            .to = self.config.node_id,
            .epoch = emsg.epoch,
            .granted = emsg.granted,
            .last_log_seq = emsg.last_log_seq,
            .config_hash = emsg.config_hash,
        };
        const replies = self.election.step(lmsg, now);
        self.sendElectionMsgs(replies);
    }

    fn handleReplMsg(self: *ClusterNode, from: []const u8, rmsg: transport_mod.ReplMsg) void {
        switch (rmsg.type_) {
            .replicate => {
                const f = self.follower orelse return;
                const msg = repl_mod.Message{
                    .type_ = .replicate,
                    .from = from,
                    .to = self.config.node_id,
                    .epoch = rmsg.epoch,
                    .seq = rmsg.seq,
                    .shard_id = rmsg.shard_id,
                    .data = rmsg.data,
                };
                const replies = f.step(msg);
                self.sendReplMsgs(replies);
            },
            .ack => {
                const r = self.replicator orelse return;
                const msg = repl_mod.Message{
                    .type_ = .ack,
                    .from = from,
                    .to = self.config.node_id,
                    .epoch = rmsg.epoch,
                    .seq = rmsg.seq,
                };
                r.step(msg);
                // Also notify pipeline's ack atomic for sync replication.
                if (g_ack_seq_ptr) |ptr| {
                    const prev = ptr.load(.monotonic);
                    if (rmsg.seq > prev) ptr.store(rmsg.seq, .release);
                }
            },
            .snapshot => {
                // Received a full KV snapshot from the leader.
                // Decode: [tree_len:4LE][tree_data][vlog_data]
                if (rmsg.data.len > 4) {
                    const tree_len = std.mem.readInt(u32, rmsg.data[0..4], .little);
                    if (4 + tree_len <= rmsg.data.len) {
                        // Write snapshot files to temp dir and restore.
                        var snap_dir_buf: [128]u8 = undefined;
                        const snap_dir = std.fmt.bufPrint(&snap_dir_buf, "/tmp/corvo-snap-restore-{s}", .{self.config.node_id}) catch return;
                        std.fs.cwd().makePath(snap_dir) catch return;

                        writeFile(snap_dir, "talon.db", rmsg.data[4 .. 4 + tree_len]) catch return;
                        writeFile(snap_dir, "talon.vlog", rmsg.data[4 + tree_len ..]) catch return;

                        self.shards[0].db.restore(snap_dir) catch |err| {
                            std.debug.print("cluster: snapshot restore failed: {}\n", .{err});
                            std.fs.cwd().deleteTree(snap_dir) catch {};
                            return;
                        };
                        std.fs.cwd().deleteTree(snap_dir) catch {};

                        // Reset follower state.
                        if (self.follower) |f| {
                            f.setLastApplied(rmsg.seq);
                        }
                        // Rebuild handler in-memory state from new KV.
                        if (self.handler) |h| {
                            h.clearState();
                            h.rebuildState(self.shards);
                        }
                        std.debug.print("cluster: {s} restored snapshot at seq={d}\n", .{ self.config.node_id, rmsg.seq });

                        var sev = metrics_mod.ClusterEvent{
                            .type_ = .snapshot_received,
                            .epoch = rmsg.epoch,
                            .timestamp_ns = @intCast(@as(i128, std.time.nanoTimestamp())),
                        };
                        const sdetail = std.fmt.bufPrint(&sev.detail_buf, "seq={d} from={s}", .{ rmsg.seq, from }) catch "";
                        sev.detail_len = @intCast(sdetail.len);
                        self.events.push(sev);
                    }
                }

                // Also forward to follower state machine for ack.
                if (self.follower) |f| {
                    const msg = repl_mod.Message{
                        .type_ = .ack,
                        .from = self.config.node_id,
                        .to = from,
                        .epoch = rmsg.epoch,
                        .seq = rmsg.seq,
                    };
                    // Send ack directly (snapshot already applied above).
                    self.sendReplMsgs(&[_]repl_mod.Message{msg});
                    _ = f; // follower state already updated via setLastApplied.
                }
            },
            .need_snap => {
                const r = self.replicator orelse return;
                const msg = repl_mod.Message{
                    .type_ = .need_snap,
                    .from = from,
                    .to = self.config.node_id,
                    .epoch = rmsg.epoch,
                    .seq = rmsg.seq,
                };
                r.step(msg);

                // Snapshot our KV to the requesting follower.
                self.snapshotToPeer(from);
            },
        }
    }

    /// Snapshot KV state to all peers. Called on leadership change.
    fn snapshotToAllPeers(self: *ClusterNode) void {
        for (self.config.peer_ids) |pid| {
            self.snapshotToPeer(pid);
        }
    }

    /// Snapshot KV state to a specific peer via Talon checkpoint + TCP transfer.
    fn snapshotToPeer(self: *ClusterNode, peer_id: []const u8) void {
        // Checkpoint our KV to a temp directory.
        var snap_dir_buf: [128]u8 = undefined;
        const snap_dir = std.fmt.bufPrint(&snap_dir_buf, "/tmp/corvo-snap-{s}", .{self.config.node_id}) catch return;

        // We operate on shard 0 (single-shard mode).
        self.shards[0].db.checkpoint(snap_dir) catch |err| {
            std.debug.print("cluster: snapshot checkpoint failed: {}\n", .{err});
            return;
        };

        // Read checkpoint files into memory for transport.
        const tree_data = readFileAlloc(self.allocator, snap_dir, "talon.db") orelse return;
        defer self.allocator.free(tree_data);
        const vlog_data = readFileAlloc(self.allocator, snap_dir, "talon.vlog") orelse return;
        defer self.allocator.free(vlog_data);

        // Clean up temp dir.
        std.fs.cwd().deleteTree(snap_dir) catch {};

        // Send snapshot via transport as a special replication message.
        // We encode both files as: [tree_len:4LE][tree_data][vlog_data]
        const total_len = 4 + tree_data.len + vlog_data.len;
        const snap_buf = self.allocator.alloc(u8, total_len) catch return;
        defer self.allocator.free(snap_buf);

        std.mem.writeInt(u32, snap_buf[0..4], @intCast(tree_data.len), .little);
        @memcpy(snap_buf[4 .. 4 + tree_data.len], tree_data);
        @memcpy(snap_buf[4 + tree_data.len ..], vlog_data);

        const epoch = self.election.currentState().epoch;
        const seq: u64 = 0; // Snapshot seq — followers reset to this.

        _ = self.transport.send(peer_id, .{
            .repl = .{
                .type_ = .snapshot,
                .epoch = epoch,
                .seq = seq,
                .data = snap_buf,
            },
        });

        var ssev = metrics_mod.ClusterEvent{
            .type_ = .snapshot_sent,
            .epoch = epoch,
            .timestamp_ns = @intCast(@as(i128, std.time.nanoTimestamp())),
        };
        const ssdetail = std.fmt.bufPrint(&ssev.detail_buf, "to={s} size={d}", .{ peer_id, total_len }) catch "";
        ssev.detail_len = @intCast(ssdetail.len);
        self.events.push(ssev);
    }

    fn sendElectionMsgs(self: *ClusterNode, msgs: []const election_mod.Message) void {
        for (msgs) |m| {
            const emsg = transport_mod.ElectionMsg{
                .type_ = m.type_,
                .epoch = m.epoch,
                .granted = m.granted,
                .last_log_seq = m.last_log_seq,
                .config_hash = m.config_hash,
            };
            _ = self.transport.send(m.to, .{ .election = emsg });
        }
    }

    fn sendReplMsgs(self: *ClusterNode, msgs: []const repl_mod.Message) void {
        for (msgs) |m| {
            const rmsg = transport_mod.ReplMsg{
                .type_ = m.type_,
                .epoch = m.epoch,
                .seq = m.seq,
                .shard_id = m.shard_id,
                .data = m.data,
            };
            _ = self.transport.send(m.to, .{ .repl = rmsg });
        }
    }
};

// ============================================================================
// Fast-path ack callback — routes TCP acks directly to the replicator
// ============================================================================

var g_cluster_for_ack: ?*ClusterNode = null;

fn fastPathAckCallback(from: []const u8, epoch: u64, seq: u64) void {
    const cn = g_cluster_for_ack orelse return;
    const r = cn.replicator orelse return;
    r.step(.{
        .type_ = .ack,
        .from = from,
        .to = cn.config.node_id,
        .epoch = epoch,
        .seq = seq,
    });
    // Notify pipeline's ack atomic — unblocks deferred responses in sync mode.
    if (g_ack_seq_ptr) |ptr| {
        const prev = ptr.load(.monotonic);
        if (seq > prev) ptr.store(seq, .release);
    }
}

/// Pointer to the pipeline's last_acked_seq atomic. Set by main.zig
/// when starting in cluster mode. TCP receive threads write directly.
pub var g_ack_seq_ptr: ?*std.atomic.Value(u64) = null;

// ============================================================================
// KVApplier — applies replicated mutations to local KV store
// ============================================================================

const KVApplier = struct {
    shards: []kv.Store,
    allocator: std.mem.Allocator,

    fn applier(self: *KVApplier) follower_mod.Applier {
        return .{
            .ptr = @ptrCast(self),
            .applyFn = @ptrCast(&applyBatchImpl),
        };
    }

    fn applyBatchImpl(self: *KVApplier, shard_id: u16, _: u64, data: []const u8) follower_mod.ApplyError!void {
        const mutations = oplog_mod.decodeMutations(self.allocator, data) catch return error.ApplyFailed;
        defer self.allocator.free(mutations);

        const shard_idx = @min(shard_id, @as(u16, @intCast(self.shards.len - 1)));
        var batch = self.shards[shard_idx].newBatch();
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
// File helpers for snapshot transfer
// ============================================================================

fn readFileAlloc(allocator: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return null;
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const stat = file.stat() catch return null;
    const data = allocator.alloc(u8, stat.size) catch return null;
    const n = file.readAll(data) catch {
        allocator.free(data);
        return null;
    };
    return data[0..n];
}

fn writeFile(dir: []const u8, name: []const u8, data: []const u8) !void {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return error.PathTooLong;
    const file = std.fs.cwd().createFile(path, .{}) catch return error.CreateFailed;
    defer file.close();
    file.writeAll(data) catch return error.WriteFailed;
}
