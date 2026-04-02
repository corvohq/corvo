//! Leader Election — lease-based leader election with epoch fencing.
//!
//! Ported from Go internal/leader/leader.go.
//! Pure deterministic state machine with no I/O. The caller drives it
//! via Step() for messages and Tick() for time. Simulator-friendly.
//!
//! Protocol:
//!   Follower: monitors leader lease. If lease expires → Candidate.
//!   Candidate: increments epoch, sends Propose to all peers, collects votes.
//!     If majority → Leader. If timeout → retry with new epoch.
//!   Leader: sends heartbeats every RenewInterval to extend follower leases.
//!     If can't maintain majority contact → steps down.
//!
//! Epoch fencing: every message carries an epoch. Nodes reject messages from
//! stale epochs. A node that sees a higher epoch immediately steps down.

const std = @import("std");
const assert = @import("assert.zig");

/// Maximum number of peers in a cluster.
pub const max_peers = 8;

/// Role of a node in the election protocol.
pub const State = enum(u8) {
    follower = 0,
    candidate = 1,
    leader = 2,
};

/// Election protocol message types.
pub const MessageType = enum(u8) {
    propose = 0x01, // Candidate → peers: "vote for me at epoch X"
    vote = 0x02, // Peer → candidate: "granted/denied for epoch X"
    heartbeat = 0x03, // Leader → peers: "I'm alive at epoch X"
    heartbeat_ack = 0x04, // Peer → leader: "ack epoch X"
};

/// An election protocol message between nodes.
pub const Message = struct {
    type_: MessageType,
    from: []const u8,
    to: []const u8,
    epoch: u64,
    granted: bool = false, // only meaningful for vote
    /// Oplog sequence — included in proposals so voters can reject
    /// candidates with stale data (Kafka ISR-style).
    last_log_seq: u64 = 0,
    /// Cluster config hash — included in proposals and heartbeats.
    /// Nodes with mismatched configs refuse to form a cluster.
    config_hash: u64 = 0,
};

/// Election timing configuration. All durations in nanoseconds.
///
/// Invariant: RenewInterval < LeaseDuration.
pub const Config = struct {
    /// How long a leader's lease is valid after a heartbeat.
    lease_duration: i64,
    /// How often the leader sends heartbeats to peers.
    renew_interval: i64,
    /// How long a candidate waits for votes before retrying.
    election_timeout: i64,
};

/// Deterministic state machine for leader election.
///
/// No I/O, no system clock reads. The caller drives everything via
/// Step() and Tick(). Thread-safe: all public methods acquire the mutex.
/// Uses fixed-size output buffer — no heap allocation for messages.
pub const Election = struct {
    mu: std.Thread.Mutex = .{},
    node_id: []const u8,
    peer_storage: [max_peers][]const u8 = undefined,
    peer_count: u8 = 0,
    config: Config,

    // Current state.
    state: State = .follower,
    epoch: u64 = 0,
    leader_id: []const u8 = "",
    lease_expiry: i64 = 0,

    // Candidate state: tracks votes received.
    votes_received: std.StringHashMap(bool),
    proposal_time: i64 = 0,

    // Leader state: tracks heartbeat acks.
    last_renew_time: i64 = 0,
    heartbeat_acks: std.StringHashMap(bool),

    // Vote tracking: prevents double-voting within the same epoch.
    voted_epoch: u64 = 0,
    voted_for: []const u8 = "",

    /// Current node's oplog sequence. Set by caller before tick().
    last_log_seq: u64 = 0,

    /// Cluster config hash. Set by caller after init(). Included in all
    /// outgoing messages. Proposals/heartbeats from nodes with a different
    /// config_hash are rejected (prevents misconfigured clusters).
    config_hash: u64 = 0,

    /// Earliest time this node will propose (randomized to prevent livelock).
    next_election_at: i64 = 0,
    /// Jitter seed derived from node_id for deterministic randomization.
    jitter_state: u64 = 0,

    // Fixed-size output buffer for messages returned by step/tick.
    out_buf: [max_peers]Message = undefined,

    allocator: std.mem.Allocator, // for HashMaps only

    /// Creates a new election state machine starting as Follower.
    ///
    /// Preconditions:
    ///   - nodeID must not be empty.
    ///   - peers.len <= max_peers.
    ///   - config durations must be positive.
    ///   - RenewInterval < LeaseDuration.
    ///   - No peer ID may equal nodeID.
    fn peers(self: *const Election) []const []const u8 {
        return self.peer_storage[0..self.peer_count];
    }

    pub fn init(
        allocator: std.mem.Allocator,
        node_id: []const u8,
        initial_peers: []const []const u8,
        config: Config,
    ) Election {
        assert.check(node_id.len > 0, "Election.init: empty nodeID", .{});
        assert.check(initial_peers.len <= max_peers, "Election.init: too many peers", .{});
        assert.check(config.lease_duration > 0, "Election.init: LeaseDuration must be > 0", .{});
        assert.check(config.renew_interval > 0, "Election.init: RenewInterval must be > 0", .{});
        assert.check(config.election_timeout > 0, "Election.init: ElectionTimeout must be > 0", .{});
        assert.check(config.renew_interval < config.lease_duration,
            "Election.init: RenewInterval must be < LeaseDuration", .{});

        var storage: [max_peers][]const u8 = undefined;
        for (initial_peers, 0..) |pid, i| {
            assert.check(pid.len > 0, "Election.init: empty peer ID", .{});
            assert.check(!std.mem.eql(u8, pid, node_id), "Election.init: peer has same ID as self", .{});
            storage[i] = pid;
        }

        // Hash node_id to create a deterministic jitter seed unique per node.
        var seed: u64 = 0x517cc1b727220a95; // FNV offset basis
        for (node_id) |c| {
            seed ^= c;
            seed *%= 0x00000100000001B3; // FNV prime
        }

        return .{
            .node_id = node_id,
            .peer_storage = storage,
            .peer_count = @intCast(initial_peers.len),
            .config = config,
            .votes_received = std.StringHashMap(bool).init(allocator),
            .heartbeat_acks = std.StringHashMap(bool).init(allocator),
            .allocator = allocator,
            .jitter_state = seed,
        };
    }

    /// Add a peer at runtime (e.g., via cluster join).
    /// Caller must ensure node_id lifetime outlives the Election.
    pub fn addPeer(self: *Election, peer_id: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        assert.check(peer_id.len > 0, "Election.addPeer: empty peer ID", .{});
        assert.check(!std.mem.eql(u8, peer_id, self.node_id), "Election.addPeer: peer has same ID as self", .{});
        assert.check(self.peer_count < max_peers, "Election.addPeer: too many peers", .{});

        // Check for duplicate.
        for (self.peer_storage[0..self.peer_count]) |existing| {
            if (std.mem.eql(u8, existing, peer_id)) return;
        }

        self.peer_storage[self.peer_count] = peer_id;
        self.peer_count += 1;
    }

    pub fn deinit(self: *Election) void {
        self.votes_received.deinit();
        self.heartbeat_acks.deinit();
    }

    /// Process an incoming message and return outgoing messages.
    /// Returned slice points into internal buffer — valid until next step/tick.
    pub fn step(self: *Election, msg: Message, now: i64) []const Message {
        self.mu.lock();
        defer self.mu.unlock();

        assert.check(std.mem.eql(u8, msg.to, self.node_id),
            "Election.step: message addressed to wrong node", .{});
        assert.check(!std.mem.eql(u8, msg.from, self.node_id),
            "Election.step: node received message from itself", .{});
        assert.check(now > 0, "Election.step: non-positive time", .{});

        return switch (msg.type_) {
            .propose => self.handlePropose(msg),
            .vote => self.handleVote(msg, now),
            .heartbeat => self.handleHeartbeat(msg, now),
            .heartbeat_ack => self.handleHeartbeatAck(msg),
        };
    }

    /// Advance time and return outgoing messages (proposals, heartbeats, etc.).
    /// Returned slice points into internal buffer — valid until next step/tick.
    pub fn tick(self: *Election, now: i64) []const Message {
        self.mu.lock();
        defer self.mu.unlock();

        assert.check(now > 0, "Election.tick: non-positive time", .{});

        return switch (self.state) {
            .follower => self.tickFollower(now),
            .candidate => self.tickCandidate(now),
            .leader => self.tickLeader(now),
        };
    }

    // --- Query methods ---

    pub fn nodeID(self: *const Election) []const u8 {
        return self.node_id; // immutable
    }

    pub fn currentState(self: *Election) struct { state: State, leader_id: []const u8, epoch: u64 } {
        self.mu.lock();
        defer self.mu.unlock();
        return .{ .state = self.state, .leader_id = self.leader_id, .epoch = self.epoch };
    }

    pub fn isLeader(self: *Election) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.state == .leader;
    }

    pub fn leaseValid(self: *Election, now: i64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        assert.check(now > 0, "Election.leaseValid: non-positive time", .{});
        return self.state == .leader and now < self.lease_expiry;
    }

    // --- Tick handlers ---

    fn tickFollower(self: *Election, now: i64) []const Message {
        if (self.leader_id.len == 0 or (self.lease_expiry > 0 and now >= self.lease_expiry)) {
            if (now < self.next_election_at) return self.out_buf[0..0];
            return self.becomeCandidate(now);
        }
        return self.out_buf[0..0];
    }

    fn tickCandidate(self: *Election, now: i64) []const Message {
        const timeout = self.config.election_timeout + self.jitter();
        if (now >= self.proposal_time + timeout) {
            return self.becomeCandidate(now);
        }
        return self.out_buf[0..0];
    }

    fn tickLeader(self: *Election, now: i64) []const Message {
        // Single-node cluster: always the leader.
        if (self.peer_count == 0) {
            self.lease_expiry = now + self.config.lease_duration;
            return self.out_buf[0..0];
        }

        // Lease expired — couldn't maintain majority contact. Step down.
        if (now >= self.lease_expiry) {
            self.state = .follower;
            self.leader_id = "";
            self.heartbeat_acks.clearRetainingCapacity();
            return self.out_buf[0..0];
        }

        // Time to send heartbeats.
        if (now >= self.last_renew_time + self.config.renew_interval) {
            return self.sendHeartbeats(now);
        }
        return self.out_buf[0..0];
    }

    // --- State transitions ---

    /// Pseudo-random jitter (0 to election_timeout/2) for preventing livelock.
    fn jitter(self: *Election) i64 {
        // xorshift64
        self.jitter_state ^= self.jitter_state << 13;
        self.jitter_state ^= self.jitter_state >> 7;
        self.jitter_state ^= self.jitter_state << 17;
        const half_timeout: u64 = @intCast(@divFloor(self.config.election_timeout, 2));
        if (half_timeout == 0) return 0;
        return @intCast(self.jitter_state % half_timeout);
    }

    fn becomeCandidate(self: *Election, now: i64) []const Message {
        const prev_epoch = self.epoch;
        self.epoch += 1;
        self.state = .candidate;
        self.next_election_at = now + self.jitter();
        self.leader_id = "";
        self.proposal_time = now;
        self.heartbeat_acks.clearRetainingCapacity();

        // Vote for self.
        self.votes_received.clearRetainingCapacity();
        self.votes_received.put(self.node_id, true) catch unreachable;
        self.voted_epoch = self.epoch;
        self.voted_for = self.node_id;

        assert.check(self.epoch == prev_epoch + 1, "becomeCandidate: epoch not monotonic", .{});

        // Single-node cluster: self-vote is majority.
        if (self.peer_count == 0) {
            return self.becomeLeader(now);
        }

        if (self.votes_received.count() >= self.majority()) {
            return self.becomeLeader(now);
        }

        // Send proposals to all peers with our log seq so they can reject stale candidates.
        for (self.peers(), 0..) |peer, i| {
            self.out_buf[i] = .{
                .type_ = .propose,
                .from = self.node_id,
                .to = peer,
                .epoch = self.epoch,
                .last_log_seq = self.last_log_seq,
                .config_hash = self.config_hash,
            };
        }
        return self.out_buf[0..self.peer_count];
    }

    fn becomeLeader(self: *Election, now: i64) []const Message {
        assert.check(self.state == .candidate, "becomeLeader: invalid transition", .{});

        self.state = .leader;
        self.leader_id = self.node_id;
        self.lease_expiry = now + self.config.lease_duration;
        self.last_renew_time = now;
        self.heartbeat_acks.clearRetainingCapacity();
        self.votes_received.clearRetainingCapacity();

        if (self.peer_count == 0) {
            return self.out_buf[0..0];
        }
        return self.sendHeartbeats(now);
    }

    fn becomeFollower(self: *Election, leader_id: []const u8, epoch: u64, now: i64) void {
        assert.check(epoch >= self.epoch, "becomeFollower: epoch regression", .{});
        assert.check(leader_id.len > 0, "becomeFollower: empty leaderID", .{});

        self.state = .follower;
        self.epoch = epoch;
        self.leader_id = leader_id;
        self.lease_expiry = now + self.config.lease_duration;
        self.votes_received.clearRetainingCapacity();
        self.heartbeat_acks.clearRetainingCapacity();
    }

    fn sendHeartbeats(self: *Election, now: i64) []const Message {
        assert.check(self.state == .leader, "sendHeartbeats: not leader", .{});

        self.last_renew_time = now;
        self.heartbeat_acks.clearRetainingCapacity();

        for (self.peers(), 0..) |peer, i| {
            self.out_buf[i] = .{
                .type_ = .heartbeat,
                .from = self.node_id,
                .to = peer,
                .epoch = self.epoch,
                .config_hash = self.config_hash,
            };
        }
        return self.out_buf[0..self.peer_count];
    }

    // --- Message handlers ---

    fn handlePropose(self: *Election, msg: Message) []const Message {
        // Config hash mismatch — reject without advancing epoch.
        // Nodes with different configs cannot form a cluster.
        if (self.config_hash != 0 and msg.config_hash != 0 and
            self.config_hash != msg.config_hash)
        {
            return self.emitOne(.{
                .type_ = .vote,
                .from = self.node_id,
                .to = msg.from,
                .epoch = msg.epoch,
                .granted = false,
                .config_hash = self.config_hash,
            });
        }

        // Stale epoch — reject.
        if (msg.epoch < self.epoch) {
            return self.emitOne(.{
                .type_ = .vote,
                .from = self.node_id,
                .to = msg.from,
                .epoch = msg.epoch,
                .granted = false,
                .config_hash = self.config_hash,
            });
        }

        // Higher epoch — step up, but only grant vote if candidate's log is
        // at least as up-to-date as ours (Kafka ISR-style).
        if (msg.epoch > self.epoch) {
            self.epoch = msg.epoch;
            self.state = .follower;
            self.leader_id = "";
            self.votes_received.clearRetainingCapacity();
            self.heartbeat_acks.clearRetainingCapacity();

            const log_ok = msg.last_log_seq >= self.last_log_seq;
            if (log_ok) {
                self.voted_epoch = msg.epoch;
                self.voted_for = msg.from;
            }

            return self.emitOne(.{
                .type_ = .vote,
                .from = self.node_id,
                .to = msg.from,
                .epoch = msg.epoch,
                .granted = log_ok,
                .config_hash = self.config_hash,
            });
        }

        // Same epoch — grant only if we haven't voted for someone else.
        if (self.voted_epoch == msg.epoch and self.voted_for.len > 0 and
            !std.mem.eql(u8, self.voted_for, msg.from))
        {
            return self.emitOne(.{
                .type_ = .vote,
                .from = self.node_id,
                .to = msg.from,
                .epoch = msg.epoch,
                .granted = false,
                .config_hash = self.config_hash,
            });
        }

        // Same epoch, haven't voted — grant only if candidate's log is caught up.
        const log_ok = msg.last_log_seq >= self.last_log_seq;
        if (!log_ok) {
            return self.emitOne(.{
                .type_ = .vote,
                .from = self.node_id,
                .to = msg.from,
                .epoch = msg.epoch,
                .granted = false,
                .config_hash = self.config_hash,
            });
        }

        self.voted_epoch = msg.epoch;
        self.voted_for = msg.from;

        if (self.state == .candidate) {
            self.state = .follower;
            self.leader_id = "";
            self.votes_received.clearRetainingCapacity();
        }

        return self.emitOne(.{
            .type_ = .vote,
            .from = self.node_id,
            .to = msg.from,
            .epoch = msg.epoch,
            .granted = true,
            .config_hash = self.config_hash,
        });
    }

    fn handleVote(self: *Election, msg: Message, now: i64) []const Message {
        if (self.state != .candidate or msg.epoch != self.epoch) {
            return self.out_buf[0..0];
        }

        if (!msg.granted) {
            return self.out_buf[0..0];
        }

        assert.check(self.votes_received.count() <= max_peers, "election: votes_received exceeds max_peers", .{});
        self.votes_received.put(msg.from, true) catch unreachable;

        if (self.votes_received.count() >= self.majority()) {
            return self.becomeLeader(now);
        }

        return self.out_buf[0..0];
    }

    fn handleHeartbeat(self: *Election, msg: Message, now: i64) []const Message {
        // Config hash mismatch — ignore heartbeat, don't extend lease.
        // Leader has different config; let its lease expire.
        if (self.config_hash != 0 and msg.config_hash != 0 and
            self.config_hash != msg.config_hash)
        {
            return self.out_buf[0..0];
        }

        // Stale heartbeat — ignore.
        if (msg.epoch < self.epoch) {
            return self.out_buf[0..0];
        }

        // Higher epoch — step down unconditionally.
        if (msg.epoch > self.epoch) {
            self.becomeFollower(msg.from, msg.epoch, now);
            return self.emitOne(.{
                .type_ = .heartbeat_ack,
                .from = self.node_id,
                .to = msg.from,
                .epoch = msg.epoch,
                .config_hash = self.config_hash,
            });
        }

        // Same epoch.
        switch (self.state) {
            .follower => {
                if (self.leader_id.len == 0) {
                    self.leader_id = msg.from;
                }
                assert.check(std.mem.eql(u8, self.leader_id, msg.from),
                    "handleHeartbeat: two leaders in same epoch", .{});
                self.lease_expiry = now + self.config.lease_duration;
            },
            .candidate => {
                self.becomeFollower(msg.from, msg.epoch, now);
            },
            .leader => {
                assert.check(false, "handleHeartbeat: two leaders in same epoch", .{});
            },
        }

        return self.emitOne(.{
            .type_ = .heartbeat_ack,
            .from = self.node_id,
            .to = msg.from,
            .epoch = msg.epoch,
            .config_hash = self.config_hash,
        });
    }

    fn handleHeartbeatAck(self: *Election, msg: Message) []const Message {
        if (self.state != .leader or msg.epoch != self.epoch) {
            return self.out_buf[0..0];
        }

        assert.check(self.heartbeat_acks.count() <= max_peers, "election: heartbeat_acks exceeds max_peers", .{});
        self.heartbeat_acks.put(msg.from, true) catch unreachable;

        const ack_count = self.heartbeat_acks.count() + 1; // +1 for self
        if (ack_count >= self.majority()) {
            self.lease_expiry = self.last_renew_time + self.config.lease_duration;
        }

        return self.out_buf[0..0];
    }

    // --- Helpers ---

    fn majority(self: *const Election) u32 {
        const total: u32 = @as(u32, self.peer_count) + 1;
        return total / 2 + 1;
    }

    /// Write a single message to out_buf[0] and return a 1-element slice.
    fn emitOne(self: *Election, msg: Message) []const Message {
        self.out_buf[0] = msg;
        return self.out_buf[0..1];
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn testConfig() Config {
    return .{
        .lease_duration = 500,
        .renew_interval = 100,
        .election_timeout = 300,
    };
}

test "single node becomes leader immediately" {
    const allocator = testing.allocator;
    var e = Election.init(allocator, "node-1", &.{}, testConfig());
    defer e.deinit();

    const msgs = e.tick(100);
    try testing.expectEqual(@as(usize, 0), msgs.len);
    try testing.expect(e.isLeader());

    const s = e.currentState();
    try testing.expectEqual(State.leader, s.state);
    try testing.expectEqualStrings("node-1", s.leader_id);
    try testing.expectEqual(@as(u64, 1), s.epoch);
}

test "three node election" {
    const allocator = testing.allocator;
    const peers_1 = [_][]const u8{ "node-2", "node-3" };
    const peers_2 = [_][]const u8{ "node-1", "node-3" };

    var e1 = Election.init(allocator, "node-1", &peers_1, testConfig());
    defer e1.deinit();
    var e2 = Election.init(allocator, "node-2", &peers_2, testConfig());
    defer e2.deinit();

    // node-1 starts election.
    const propose_msgs = e1.tick(100);
    try testing.expectEqual(@as(usize, 2), propose_msgs.len);
    try testing.expectEqual(State.candidate, e1.currentState().state);

    // Deliver proposal to node-2.
    var vote_msg_to_1: Message = undefined;
    for (propose_msgs) |m| {
        if (std.mem.eql(u8, m.to, "node-2")) {
            const replies = e2.step(m, 100);
            try testing.expectEqual(@as(usize, 1), replies.len);
            try testing.expect(replies[0].granted);
            vote_msg_to_1 = replies[0];
            break;
        }
    }

    // Deliver vote back to node-1. Should become leader.
    const hb_msgs = e1.step(vote_msg_to_1, 100);
    try testing.expect(e1.isLeader());
    try testing.expectEqual(@as(u64, 1), e1.currentState().epoch);
    try testing.expectEqual(@as(usize, 2), hb_msgs.len); // heartbeats to both peers
}

test "heartbeat extends follower lease" {
    const allocator = testing.allocator;
    const peers_1 = [_][]const u8{"node-2"};
    const peers_2 = [_][]const u8{"node-1"};

    var e1 = Election.init(allocator, "node-1", &peers_1, testConfig());
    defer e1.deinit();
    var e2 = Election.init(allocator, "node-2", &peers_2, testConfig());
    defer e2.deinit();

    // node-1 becomes leader.
    const propose_msgs = e1.tick(100);
    try testing.expectEqual(@as(usize, 1), propose_msgs.len);

    const vote_replies = e2.step(propose_msgs[0], 100);
    const leader_msgs = e1.step(vote_replies[0], 100);
    try testing.expect(e1.isLeader());

    try testing.expectEqual(@as(usize, 1), leader_msgs.len);
    try testing.expectEqual(MessageType.heartbeat, leader_msgs[0].type_);

    // Deliver heartbeat to follower.
    const ack_msgs = e2.step(leader_msgs[0], 200);
    try testing.expectEqual(@as(usize, 1), ack_msgs.len);
    try testing.expectEqual(MessageType.heartbeat_ack, ack_msgs[0].type_);

    const s2 = e2.currentState();
    try testing.expectEqual(State.follower, s2.state);
    try testing.expectEqualStrings("node-1", s2.leader_id);
}

test "epoch fencing rejects stale proposals" {
    const allocator = testing.allocator;
    const peers = [_][]const u8{"node-2"};

    var e = Election.init(allocator, "node-1", &peers, testConfig());
    defer e.deinit();

    // Advance to epoch 2.
    _ = e.tick(100);
    _ = e.tick(500); // election timeout → retry

    try testing.expectEqual(@as(u64, 2), e.currentState().epoch);

    // Receive a stale proposal from epoch 1.
    const replies = e.step(.{
        .type_ = .propose,
        .from = "node-2",
        .to = "node-1",
        .epoch = 1,
    }, 600);
    try testing.expectEqual(@as(usize, 1), replies.len);
    try testing.expect(!replies[0].granted);
}

test "config hash mismatch rejects proposal" {
    const allocator = testing.allocator;
    const peers = [_][]const u8{"node-2"};

    var e1 = Election.init(allocator, "node-1", &peers, testConfig());
    defer e1.deinit();
    e1.config_hash = 0xAAAA;

    // Receive a proposal from node-2 with a different config_hash.
    const replies = e1.step(.{
        .type_ = .propose,
        .from = "node-2",
        .to = "node-1",
        .epoch = 1,
        .config_hash = 0xBBBB,
    }, 100);
    try testing.expectEqual(@as(usize, 1), replies.len);
    try testing.expect(!replies[0].granted);

    // Node-1's epoch should NOT advance (config mismatch is pre-epoch check).
    try testing.expectEqual(@as(u64, 0), e1.currentState().epoch);
}

test "config hash mismatch ignores heartbeat" {
    const allocator = testing.allocator;
    const peers = [_][]const u8{"node-2"};

    var e = Election.init(allocator, "node-1", &peers, testConfig());
    defer e.deinit();
    e.config_hash = 0xAAAA;

    // Receive a heartbeat from a leader with different config hash.
    const replies = e.step(.{
        .type_ = .heartbeat,
        .from = "node-2",
        .to = "node-1",
        .epoch = 5,
        .config_hash = 0xCCCC,
    }, 100);
    // Should return no messages (ignored).
    try testing.expectEqual(@as(usize, 0), replies.len);
    // Node should still be follower with no leader.
    try testing.expectEqual(State.follower, e.currentState().state);
    try testing.expectEqualStrings("", e.currentState().leader_id);
}

test "matching config hash allows election" {
    const allocator = testing.allocator;
    const peers_1 = [_][]const u8{"node-2"};
    const peers_2 = [_][]const u8{"node-1"};

    var e1 = Election.init(allocator, "node-1", &peers_1, testConfig());
    defer e1.deinit();
    e1.config_hash = 0xDEAD;

    var e2 = Election.init(allocator, "node-2", &peers_2, testConfig());
    defer e2.deinit();
    e2.config_hash = 0xDEAD; // same hash

    // node-1 proposes.
    const proposals = e1.tick(100);
    try testing.expectEqual(@as(usize, 1), proposals.len);

    // node-2 grants vote (config hashes match).
    const votes = e2.step(proposals[0], 100);
    try testing.expectEqual(@as(usize, 1), votes.len);
    try testing.expect(votes[0].granted);

    // node-1 becomes leader.
    _ = e1.step(votes[0], 100);
    try testing.expect(e1.isLeader());
}
