//! Transport — network layer for primary-backup replication.
//!
//! Carries both election and replication messages. Two implementations:
//!   - InMemNetwork/InMemTransport: for simulation and testing (no I/O)
//!   - TcpTransport: for production (tcp_transport.zig)
//!
//! Fault injection models real network conditions:
//!   - Network partitions: all messages between partitioned nodes are dropped
//!   - Packet loss: random per-message drops at a configurable rate
//!   - Node isolation: all messages to/from a node are dropped

const std = @import("std");
const assert = @import("assert.zig");
const election_mod = @import("election.zig");
const repl_mod = @import("replicator.zig");
const follower_mod = @import("follower.zig");

// ============================================================================
// Message types
// ============================================================================

/// Transport-level message. Carries either an election or replication message.
pub const Msg = union(enum) {
    election: ElectionMsg,
    repl: ReplMsg,
};

/// Election message for transport.
pub const ElectionMsg = struct {
    type_: election_mod.MessageType,
    epoch: u64,
    granted: bool = false,
    last_log_seq: u64 = 0,
};

/// Replication message for transport.
pub const ReplMsg = struct {
    type_: repl_mod.MessageType,
    epoch: u64,
    seq: u64 = 0,
    shard_id: u16 = 0,
    data: []const u8 = "",
};

// ============================================================================
// InMemNetwork — simulated network for testing
// ============================================================================

/// Max messages buffered per transport inbox.
const inbox_capacity = 256;

/// Max nodes in the network.
const max_nodes = 8;

/// A received message with sender information.
pub const IncomingMsg = struct {
    from: []const u8,
    msg: Msg,
};

/// Simulates a network of in-memory transports.
/// Supports partition model + packet loss for realistic fault injection.
pub const InMemNetwork = struct {
    mu: std.Thread.Mutex = .{},
    nodes: std.StringHashMap(*InMemTransport),
    allocator: std.mem.Allocator,

    // --- Fault injection state ---

    /// Legacy fault function (for backward compat with existing tests).
    fault_fn: ?*const fn (from: []const u8, to: []const u8) bool = null,

    /// Partition matrix: partitions[i][j] = true means i cannot send to j.
    /// Index by node registration order.
    partitions: [max_nodes][max_nodes]bool = [_][max_nodes]bool{[_]bool{false} ** max_nodes} ** max_nodes,
    node_order: [max_nodes][]const u8 = [_][]const u8{""} ** max_nodes,
    node_count: u8 = 0,

    /// Packet loss rate: 0 = no loss, N = drop 1 in N messages.
    packet_loss_rate: u32 = 0,
    packet_loss_counter: u32 = 0,

    /// Isolated nodes: all messages to/from are dropped.
    isolated: [max_nodes]bool = [_]bool{false} ** max_nodes,

    pub fn init(allocator: std.mem.Allocator) InMemNetwork {
        return .{
            .nodes = std.StringHashMap(*InMemTransport).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InMemNetwork) void {
        var iter = self.nodes.iterator();
        while (iter.next()) |kv| {
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.nodes.deinit();
    }

    /// Set legacy fault injection function.
    pub fn setFaultFn(self: *InMemNetwork, f: ?*const fn (from: []const u8, to: []const u8) bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.fault_fn = f;
    }

    /// Set packet loss rate. 0 = no loss, N = drop 1 in every N messages.
    pub fn setPacketLoss(self: *InMemNetwork, rate: u32) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.packet_loss_rate = rate;
        self.packet_loss_counter = 0;
    }

    /// Create a network partition between two nodes (bidirectional).
    pub fn partition(self: *InMemNetwork, node_a: []const u8, node_b: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const a = self.nodeIndex(node_a) orelse return;
        const b = self.nodeIndex(node_b) orelse return;
        self.partitions[a][b] = true;
        self.partitions[b][a] = true;
    }

    /// Heal a partition between two nodes.
    pub fn heal(self: *InMemNetwork, node_a: []const u8, node_b: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const a = self.nodeIndex(node_a) orelse return;
        const b = self.nodeIndex(node_b) orelse return;
        self.partitions[a][b] = false;
        self.partitions[b][a] = false;
    }

    /// Heal all partitions.
    pub fn healAll(self: *InMemNetwork) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.partitions = [_][max_nodes]bool{[_]bool{false} ** max_nodes} ** max_nodes;
        self.isolated = [_]bool{false} ** max_nodes;
    }

    /// Isolate a node from all others.
    pub fn isolate(self: *InMemNetwork, node_id: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const idx = self.nodeIndex(node_id) orelse return;
        self.isolated[idx] = true;
    }

    /// Rejoin an isolated node.
    pub fn rejoin(self: *InMemNetwork, node_id: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        const idx = self.nodeIndex(node_id) orelse return;
        self.isolated[idx] = false;
    }

    /// Create a transport for the given node.
    pub fn newTransport(self: *InMemNetwork, node_id: []const u8) *InMemTransport {
        assert.check(node_id.len > 0, "InMemNetwork: empty nodeID", .{});

        self.mu.lock();
        defer self.mu.unlock();

        assert.check(self.nodes.get(node_id) == null, "InMemNetwork: duplicate nodeID", .{});

        // Track node order for partition indexing.
        if (self.node_count < max_nodes) {
            self.node_order[self.node_count] = node_id;
            self.node_count += 1;
        }

        const t = self.allocator.create(InMemTransport) catch unreachable;
        t.* = InMemTransport.initInner(node_id, self);
        self.nodes.put(node_id, t) catch unreachable;
        return t;
    }

    fn checkFault(self: *InMemNetwork, from: []const u8, to: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();

        // Legacy fault function.
        if (self.fault_fn) |func| {
            // Release lock before calling user function to avoid deadlock.
            self.mu.unlock();
            const drop = func(from, to);
            self.mu.lock();
            if (drop) return true;
        }

        // Node isolation.
        if (self.nodeIndex(from)) |fi| {
            if (self.isolated[fi]) return true;
        }
        if (self.nodeIndex(to)) |ti| {
            if (self.isolated[ti]) return true;
        }

        // Partition check.
        if (self.nodeIndex(from)) |fi| {
            if (self.nodeIndex(to)) |ti| {
                if (self.partitions[fi][ti]) return true;
            }
        }

        // Packet loss.
        if (self.packet_loss_rate > 0) {
            self.packet_loss_counter += 1;
            if (self.packet_loss_counter % self.packet_loss_rate == 0) return true;
        }

        return false;
    }

    fn nodeIndex(self: *const InMemNetwork, node_id: []const u8) ?usize {
        for (0..self.node_count) |i| {
            if (std.mem.eql(u8, self.node_order[i], node_id)) return i;
        }
        return null;
    }

    fn getTransport(self: *InMemNetwork, node_id: []const u8) ?*InMemTransport {
        self.mu.lock();
        defer self.mu.unlock();
        return self.nodes.get(node_id);
    }
};

/// In-memory transport for a single node.
pub const InMemTransport = struct {
    node_id: []const u8,
    network: *InMemNetwork,
    mu: std.Thread.Mutex = .{},
    closed: bool = false,

    inbox: [inbox_capacity]IncomingMsg = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,

    fn initInner(node_id: []const u8, network: *InMemNetwork) InMemTransport {
        return .{
            .node_id = node_id,
            .network = network,
        };
    }

    /// Send a message to a peer.
    pub fn send(self: *InMemTransport, to: []const u8, msg: Msg) bool {
        if (self.closed) return false;

        if (self.network.checkFault(self.node_id, to)) return false;

        const peer = self.network.getTransport(to) orelse return false;

        peer.mu.lock();
        defer peer.mu.unlock();
        if (peer.closed) return false;

        if (peer.count >= inbox_capacity) return false;

        peer.inbox[peer.tail] = .{ .from = self.node_id, .msg = msg };
        peer.tail = (peer.tail + 1) % inbox_capacity;
        peer.count += 1;
        return true;
    }

    /// Read and remove one pending message.
    pub fn recvOne(self: *InMemTransport) ?IncomingMsg {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.count == 0) return null;

        const msg = self.inbox[self.head];
        self.head = (self.head + 1) % inbox_capacity;
        self.count -= 1;
        return msg;
    }

    pub fn pending(self: *InMemTransport) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.count;
    }

    pub fn close(self: *InMemTransport) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.closed = true;
    }
};

// ============================================================================
// Runner — drives election + replication state machines from transport
// ============================================================================

pub const RunnerConfig = struct {
    node_id: []const u8,
    peer_ids: []const []const u8,
    transport: *InMemTransport,
    election: *election_mod.Election,
    clock_fn: *const fn () i64,
    max_lag: u64 = 1000,
};

pub const Runner = struct {
    config: RunnerConfig,
    replicator: ?*repl_mod.Replicator = null,
    follower: ?*follower_mod.Follower = null,
    last_repl: u64 = 0,

    pub fn init(config: RunnerConfig) Runner {
        return .{ .config = config };
    }

    pub fn tick(self: *Runner) void {
        const now = self.config.clock_fn();

        var had_election_msg = false;
        while (self.config.transport.recvOne()) |incoming| {
            switch (incoming.msg) {
                .election => |emsg| {
                    self.dispatchElection(incoming.from, emsg, now);
                    had_election_msg = true;
                },
                .repl => |rmsg| {
                    self.dispatchRepl(incoming.from, rmsg);
                },
            }
        }

        if (!had_election_msg) {
            const tick_msgs = self.config.election.tick(now);
            self.sendElectionMsgs(tick_msgs);
        }
    }

    fn dispatchElection(self: *Runner, from: []const u8, emsg: ElectionMsg, now: i64) void {
        const lmsg = election_mod.Message{
            .type_ = emsg.type_,
            .from = from,
            .to = self.config.node_id,
            .epoch = emsg.epoch,
            .granted = emsg.granted,
            .last_log_seq = emsg.last_log_seq,
        };

        const replies = self.config.election.step(lmsg, now);
        self.sendElectionMsgs(replies);
    }

    fn dispatchRepl(self: *Runner, from: []const u8, rmsg: ReplMsg) void {
        switch (rmsg.type_) {
            .replicate => {
                if (self.follower) |f| {
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
                }
            },
            .ack => {
                if (self.replicator) |r| {
                    const msg = repl_mod.Message{
                        .type_ = .ack,
                        .from = from,
                        .to = self.config.node_id,
                        .epoch = rmsg.epoch,
                        .seq = rmsg.seq,
                    };
                    r.step(msg);
                }
            },
            .need_snap => {
                if (self.replicator) |r| {
                    const msg = repl_mod.Message{
                        .type_ = .need_snap,
                        .from = from,
                        .to = self.config.node_id,
                        .epoch = rmsg.epoch,
                        .seq = rmsg.seq,
                    };
                    r.step(msg);
                }
            },
            .snapshot => {
                if (self.follower) |f| {
                    const msg = repl_mod.Message{
                        .type_ = .snapshot,
                        .from = from,
                        .to = self.config.node_id,
                        .epoch = rmsg.epoch,
                        .seq = rmsg.seq,
                        .data = rmsg.data,
                    };
                    const replies = f.step(msg);
                    self.sendReplMsgs(replies);
                }
            },
        }
    }

    fn sendReplMsgs(self: *Runner, msgs: []const repl_mod.Message) void {
        for (msgs) |m| {
            const rmsg = ReplMsg{
                .type_ = m.type_,
                .epoch = m.epoch,
                .seq = m.seq,
                .shard_id = m.shard_id,
                .data = m.data,
            };
            _ = self.config.transport.send(m.to, .{ .repl = rmsg });
        }
    }

    fn sendElectionMsgs(self: *Runner, msgs: []const election_mod.Message) void {
        for (msgs) |m| {
            const emsg = ElectionMsg{
                .type_ = m.type_,
                .epoch = m.epoch,
                .granted = m.granted,
                .last_log_seq = m.last_log_seq,
            };
            _ = self.config.transport.send(m.to, .{ .election = emsg });
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "inmem network basic send/recv" {
    const t = std.testing;
    const alloc = t.allocator;

    var network = InMemNetwork.init(alloc);
    defer network.deinit();

    const t1 = network.newTransport("node-1");
    const t2 = network.newTransport("node-2");
    _ = t2;

    const sent = t1.send("node-2", .{ .election = .{ .type_ = .propose, .epoch = 1 } });
    try t.expect(sent);

    const recv = network.getTransport("node-2").?.recvOne();
    try t.expect(recv != null);
    try t.expectEqualStrings("node-1", recv.?.from);
}

test "inmem network partition blocks messages" {
    const t = std.testing;
    const alloc = t.allocator;

    var network = InMemNetwork.init(alloc);
    defer network.deinit();

    const t1 = network.newTransport("node-1");
    _ = network.newTransport("node-2");

    // Partition node-1 from node-2.
    network.partition("node-1", "node-2");

    const sent = t1.send("node-2", .{ .election = .{ .type_ = .propose, .epoch = 1 } });
    try t.expect(!sent); // dropped by partition

    // Heal and retry.
    network.heal("node-1", "node-2");
    const sent2 = t1.send("node-2", .{ .election = .{ .type_ = .propose, .epoch = 2 } });
    try t.expect(sent2);
}

test "inmem network node isolation" {
    const t = std.testing;
    const alloc = t.allocator;

    var network = InMemNetwork.init(alloc);
    defer network.deinit();

    const t1 = network.newTransport("node-1");
    _ = network.newTransport("node-2");
    _ = network.newTransport("node-3");

    // Isolate node-2 — neither node-1 nor node-3 can reach it.
    network.isolate("node-2");

    try t.expect(!t1.send("node-2", .{ .election = .{ .type_ = .propose, .epoch = 1 } }));

    // But node-1 can still reach node-3.
    try t.expect(t1.send("node-3", .{ .election = .{ .type_ = .propose, .epoch = 1 } }));

    // Rejoin.
    network.rejoin("node-2");
    try t.expect(t1.send("node-2", .{ .election = .{ .type_ = .propose, .epoch = 2 } }));
}

test "inmem network packet loss" {
    const t = std.testing;
    const alloc = t.allocator;

    var network = InMemNetwork.init(alloc);
    defer network.deinit();

    const t1 = network.newTransport("node-1");
    _ = network.newTransport("node-2");

    // Drop every 3rd message.
    network.setPacketLoss(3);

    var sent_count: u32 = 0;
    for (0..9) |_| {
        if (t1.send("node-2", .{ .election = .{ .type_ = .heartbeat, .epoch = 1 } }))
            sent_count += 1;
    }
    // 9 messages, 1 in 3 dropped = 6 delivered.
    try t.expectEqual(@as(u32, 6), sent_count);
}

test "inmem network fault injection drops messages" {
    const t = std.testing;
    const alloc = t.allocator;

    var network = InMemNetwork.init(alloc);
    defer network.deinit();

    const t1 = network.newTransport("node-1");
    _ = network.newTransport("node-2");

    const drop_all = struct {
        fn drop(_: []const u8, _: []const u8) bool {
            return true;
        }
    };
    network.setFaultFn(&drop_all.drop);

    const sent = t1.send("node-2", .{ .election = .{ .type_ = .propose, .epoch = 1 } });
    try t.expect(!sent); // dropped
}
