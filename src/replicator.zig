//! Replicator — leader-side replication fan-out.
//!
//! Ported from Go internal/pbr/replica.go.
//! Pure deterministic state machine — no threads, no I/O. The caller
//! provides entries via replicate() and feeds back acks via step().
//!
//! Protocol:
//!   Leader → Follower: MsgReplicate [epoch, seq, shard, data]
//!   Follower → Leader: MsgAck [epoch, seq]
//!   Follower → Leader: MsgNeedSnap [epoch, lastApplied] (gap detected)

const std = @import("std");
const assert = @import("assert.zig");

/// Replication protocol message types.
pub const MessageType = enum(u8) {
    replicate = 0x01,
    ack = 0x02,
    need_snap = 0x03,
    snapshot = 0x04,
};

/// A replication protocol message between leader and follower.
pub const Message = struct {
    type_: MessageType,
    from: []const u8,
    to: []const u8,
    epoch: u64,
    seq: u64,
    shard_id: u16 = 0,
    data: []const u8 = "",
};

/// An oplog entry for replication.
pub const Entry = struct {
    seq: u64,
    shard_id: u16,
    data: []const u8,
};

/// Per-follower replication state.
const PeerState = struct {
    id: []const u8,
    last_acked: u64 = 0,
    last_sent: u64 = 0,
    need_snap: bool = false,
};

/// Follower replication progress (public query result).
pub const FollowerProgress = struct {
    id: []const u8,
    last_acked: u64,
    last_sent: u64,
    need_snap: bool,
};

/// Pending ack waiter.
const AckWaiter = struct {
    seq: u64,
    event: *std.Thread.ResetEvent,
};

/// Manages streaming oplog entries to followers.
///
/// Pure state machine — no threads, no I/O. Usage:
///   1. Call replicate(entries) when new entries are committed.
///   2. Send the returned messages to followers via transport.
///   3. Call step(msg) when receiving acks from followers.
///   4. Call checkLag(headSeq) to detect followers needing snapshots.
///   5. Call minAcked() for safe oplog truncation point.
pub const Replicator = struct {
    mu: std.Thread.Mutex = .{},
    node_id: []const u8,
    epoch: u64,
    followers: std.StringHashMap(PeerState),
    max_lag: u64,
    waiters: std.ArrayList(AckWaiter),
    allocator: std.mem.Allocator,

    /// Create a new replicator for a leader at the given epoch.
    ///
    /// Preconditions:
    ///   - node_id must not be empty.
    ///   - epoch must be > 0.
    ///   - max_lag must be > 0.
    ///   - No peer ID may be empty or equal to node_id.
    pub fn init(
        allocator: std.mem.Allocator,
        node_id: []const u8,
        epoch: u64,
        peer_ids: []const []const u8,
        max_lag: u64,
    ) Replicator {
        assert.check(node_id.len > 0, "Replicator.init: empty nodeID", .{});
        assert.check(epoch > 0, "Replicator.init: epoch must be > 0", .{});
        assert.check(max_lag > 0, "Replicator.init: maxLag must be > 0", .{});

        var followers = std.StringHashMap(PeerState).init(allocator);
        for (peer_ids) |pid| {
            assert.check(pid.len > 0, "Replicator.init: empty peer ID", .{});
            assert.check(!std.mem.eql(u8, pid, node_id), "Replicator.init: peer same as self", .{});
            followers.put(pid, .{ .id = pid }) catch unreachable;
        }

        return .{
            .node_id = node_id,
            .epoch = epoch,
            .followers = followers,
            .max_lag = max_lag,
            .waiters = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Replicator) void {
        self.followers.deinit();
        self.waiters.deinit(self.allocator);
    }

    /// Generate replication messages for new oplog entries.
    /// Returns one message per (follower, entry) pair for unsent entries.
    /// Skips followers that need a snapshot. Caller owns returned slice.
    ///
    /// NOTE: heap-allocated because output size = followers * entries,
    /// which can exceed fixed buffer limits on the hot path.
    ///
    /// Precondition: entries must be non-empty and in strictly ascending seq order.
    /// Postcondition: each follower's lastSent >= max entry seq (unless needSnap).
    pub fn replicate(self: *Replicator, entries: []const Entry) []Message {
        self.mu.lock();
        defer self.mu.unlock();

        assert.check(entries.len > 0, "Replicator.replicate: empty entries", .{});

        // Verify strictly ascending order.
        for (1..entries.len) |i| {
            assert.check(entries[i].seq > entries[i - 1].seq,
                "Replicator.replicate: entries not in order", .{});
        }

        var msgs: std.ArrayList(Message) = .{};

        var fiter = self.followers.iterator();
        while (fiter.next()) |kv| {
            const f = kv.value_ptr;
            if (f.need_snap) continue;

            for (entries) |e| {
                if (e.seq <= f.last_sent) continue;
                msgs.append(self.allocator, .{
                    .type_ = .replicate,
                    .from = self.node_id,
                    .to = f.id,
                    .epoch = self.epoch,
                    .seq = e.seq,
                    .shard_id = e.shard_id,
                    .data = e.data,
                }) catch unreachable;
                f.last_sent = e.seq;
            }
        }
        return msgs.toOwnedSlice(self.allocator) catch unreachable;
    }

    /// Process an incoming message from a follower.
    ///
    /// Precondition: msg.to == self.node_id.
    /// Invariant: lastAcked only increases (monotonic).
    pub fn step(self: *Replicator, msg: Message) void {
        self.mu.lock();
        defer self.mu.unlock();

        assert.check(std.mem.eql(u8, msg.to, self.node_id),
            "Replicator.step: message to wrong node", .{});

        const f = self.followers.getPtr(msg.from) orelse return;

        switch (msg.type_) {
            .ack => {
                if (msg.epoch != self.epoch) return;
                // Invariant: ack must be monotonically increasing.
                if (msg.seq > f.last_acked) {
                    f.last_acked = msg.seq;
                    self.notifyWaiters(msg.seq);
                }
                // If follower caught up after needing snapshot, clear the flag.
                if (f.need_snap and f.last_acked >= f.last_sent) {
                    f.need_snap = false;
                }
            },
            .need_snap => {
                f.need_snap = true;
            },
            .replicate, .snapshot => {
                // Leader shouldn't receive replicate/snapshot messages.
            },
        }
    }

    /// Reset last_sent to last_acked for all followers, so the next replicate()
    /// call will re-send unacknowledged entries. Call periodically to handle
    /// dropped messages.
    pub fn resetUnacked(self: *Replicator) void {
        self.mu.lock();
        defer self.mu.unlock();

        var iter = self.followers.iterator();
        while (iter.next()) |kv| {
            const f = kv.value_ptr;
            if (!f.need_snap and f.last_sent > f.last_acked) {
                f.last_sent = f.last_acked;
            }
        }
    }

    /// Return replication progress of all followers.
    pub fn progress(self: *Replicator) []FollowerProgress {
        self.mu.lock();
        defer self.mu.unlock();

        const result = self.allocator.alloc(FollowerProgress, self.followers.count()) catch unreachable;
        var idx: usize = 0;
        var iter = self.followers.iterator();
        while (iter.next()) |kv| {
            const f = kv.value_ptr;
            result[idx] = .{
                .id = f.id,
                .last_acked = f.last_acked,
                .last_sent = f.last_sent,
                .need_snap = f.need_snap,
            };
            idx += 1;
        }
        return result;
    }

    /// Mark followers as needing snapshots if too far behind.
    pub fn checkLag(self: *Replicator, head_seq: u64) void {
        self.mu.lock();
        defer self.mu.unlock();

        var iter = self.followers.iterator();
        while (iter.next()) |kv| {
            const f = kv.value_ptr;
            if (!f.need_snap and head_seq > f.last_acked and head_seq - f.last_acked > self.max_lag) {
                f.need_snap = true;
            }
        }
    }

    /// Reset a follower after snapshot restore.
    pub fn resetFollower(self: *Replicator, peer_id: []const u8, restore_seq: u64) void {
        self.mu.lock();
        defer self.mu.unlock();

        const f = self.followers.getPtr(peer_id) orelse {
            assert.check(false, "Replicator.resetFollower: unknown peer", .{});
            unreachable;
        };
        f.last_acked = restore_seq;
        f.last_sent = restore_seq;
        f.need_snap = false;
    }

    /// Minimum acked sequence across all followers (safe truncation point).
    pub fn minAcked(self: *Replicator) u64 {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.followers.count() == 0) return 0;
        var min: u64 = std.math.maxInt(u64);
        var iter = self.followers.iterator();
        while (iter.next()) |kv| {
            if (kv.value_ptr.last_acked < min) {
                min = kv.value_ptr.last_acked;
            }
        }
        return min;
    }

    /// Check if any follower has acked the given sequence.
    pub fn anyAcked(self: *Replicator, seq: u64) bool {
        self.mu.lock();
        defer self.mu.unlock();

        var iter = self.followers.iterator();
        while (iter.next()) |kv| {
            if (kv.value_ptr.last_acked >= seq) return true;
        }
        return false;
    }

    /// Register a waiter that is signaled when any follower acks >= seq.
    /// If already satisfied, the event is set immediately.
    pub fn waitForAck(self: *Replicator, seq: u64, event: *std.Thread.ResetEvent) void {
        self.mu.lock();
        defer self.mu.unlock();

        // Check if already satisfied.
        var iter = self.followers.iterator();
        while (iter.next()) |kv| {
            if (kv.value_ptr.last_acked >= seq) {
                event.set();
                return;
            }
        }

        self.waiters.append(self.allocator, .{ .seq = seq, .event = event }) catch unreachable;
    }

    /// Signal waiters whose seq is <= ackedSeq. Must hold mu.
    fn notifyWaiters(self: *Replicator, acked_seq: u64) void {
        var n: usize = 0;
        for (self.waiters.items) |w| {
            if (acked_seq >= w.seq) {
                w.event.set();
            } else {
                self.waiters.items[n] = w;
                n += 1;
            }
        }
        self.waiters.shrinkRetainingCapacity(n);
    }

    pub fn getEpoch(self: *const Replicator) u64 {
        return self.epoch;
    }

    pub fn getNodeID(self: *const Replicator) []const u8 {
        return self.node_id;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing_alloc = std.testing.allocator;

test "replicator basic replicate and ack" {
    const t = std.testing;
    const peers = [_][]const u8{ "node-2", "node-3" };

    var r = Replicator.init(testing_alloc, "node-1", 1, &peers, 1000);
    defer r.deinit();

    // Replicate a single entry.
    const entries = [_]Entry{
        .{ .seq = 1, .shard_id = 0, .data = "data1" },
    };
    const msgs = r.replicate(&entries);
    defer testing_alloc.free(msgs);

    // Should have 2 messages (one per follower).
    try t.expectEqual(@as(usize, 2), msgs.len);

    // Ack from node-2.
    r.step(.{ .type_ = .ack, .from = "node-2", .to = "node-1", .epoch = 1, .seq = 1 });

    try t.expectEqual(@as(u64, 0), r.minAcked()); // node-3 hasn't acked
    try t.expect(r.anyAcked(1));

    // Ack from node-3.
    r.step(.{ .type_ = .ack, .from = "node-3", .to = "node-1", .epoch = 1, .seq = 1 });
    try t.expectEqual(@as(u64, 1), r.minAcked());
}

test "replicator skips need_snap followers" {
    const t = std.testing;
    const peers = [_][]const u8{"node-2"};

    var r = Replicator.init(testing_alloc, "node-1", 1, &peers, 5);
    defer r.deinit();

    // Mark follower as needing snapshot.
    r.checkLag(10); // 10 - 0 > 5, so node-2 needs snap

    const entries = [_]Entry{
        .{ .seq = 11, .shard_id = 0, .data = "data" },
    };
    const msgs = r.replicate(&entries);
    defer testing_alloc.free(msgs);

    try t.expectEqual(@as(usize, 0), msgs.len); // skipped
}

test "replicator reset follower clears need_snap" {
    const t = std.testing;
    const peers = [_][]const u8{"node-2"};

    var r = Replicator.init(testing_alloc, "node-1", 1, &peers, 5);
    defer r.deinit();

    r.checkLag(10);
    r.resetFollower("node-2", 8);

    const entries = [_]Entry{
        .{ .seq = 9, .shard_id = 0, .data = "data" },
    };
    const msgs = r.replicate(&entries);
    defer testing_alloc.free(msgs);

    try t.expectEqual(@as(usize, 1), msgs.len); // resumed
}

test "replicator stale epoch ack ignored" {
    const t = std.testing;
    const peers = [_][]const u8{"node-2"};

    var r = Replicator.init(testing_alloc, "node-1", 2, &peers, 1000);
    defer r.deinit();

    // Stale epoch ack.
    r.step(.{ .type_ = .ack, .from = "node-2", .to = "node-1", .epoch = 1, .seq = 5 });
    try t.expectEqual(@as(u64, 0), r.minAcked()); // not updated
}
