//! Follower — follower-side replication entry application.
//!
//! Ported from Go internal/pbr/follower.go.
//! Pure deterministic state machine — no threads, no I/O. The caller
//! feeds messages via step() and sends returned responses to the leader.
//!
//! Invariants:
//!   - Entries are applied in strictly sequential order (no gaps, no reorder).
//!   - lastApplied only increases, never decreases.
//!   - Stale epoch messages are silently dropped.
//!   - A gap in sequence numbers triggers a snapshot request.

const std = @import("std");
const assert = @import("assert.zig");
const repl = @import("replicator.zig");

const Message = repl.Message;
const MessageType = repl.MessageType;

/// Applier applies replicated mutations to the local store.
/// data is the encoded mutations from oplog.encodeMutations.
pub const Applier = struct {
    ptr: *anyopaque,
    applyFn: *const fn (ptr: *anyopaque, shard_id: u16, seq: u64, data: []const u8) ApplyError!void,

    pub fn applyBatch(self: Applier, shard_id: u16, seq: u64, data: []const u8) ApplyError!void {
        return self.applyFn(self.ptr, shard_id, seq, data);
    }
};

pub const ApplyError = error{ApplyFailed};

/// Receives and applies replication entries from the leader.
///
/// Pure state machine — no threads, no I/O. Uses a fixed 1-element output
/// buffer — no heap allocation for returned messages.
pub const Follower = struct {
    mu: std.Thread.Mutex = .{},
    node_id: []const u8,
    epoch: u64,
    last_applied: u64,
    applier: Applier,

    // Fixed output buffer — step() returns at most 1 message.
    out_buf: [1]Message = undefined,

    /// Create a new replication follower.
    ///
    /// Preconditions:
    ///   - node_id must not be empty.
    ///
    /// Postcondition: lastApplied == the provided value, ready to receive.
    pub fn init(
        node_id: []const u8,
        epoch: u64,
        last_applied: u64,
        applier: Applier,
    ) Follower {
        assert.check(node_id.len > 0, "Follower.init: empty nodeID", .{});

        const f = Follower{
            .node_id = node_id,
            .epoch = epoch,
            .last_applied = last_applied,
            .applier = applier,
        };

        // Postcondition.
        assert.check(f.last_applied == last_applied, "Follower.init: lastApplied mismatch", .{});
        return f;
    }

    /// Process an incoming replication message and return responses.
    /// Returned slice points into internal buffer — valid until next step().
    ///
    /// Precondition: msg.to == self.node_id.
    pub fn step(self: *Follower, msg: Message) []const Message {
        self.mu.lock();
        defer self.mu.unlock();

        assert.check(std.mem.eql(u8, msg.to, self.node_id),
            "Follower.step: message to wrong node", .{});

        return switch (msg.type_) {
            .replicate => self.handleReplicate(msg),
            .snapshot => self.handleSnapshot(msg),
            .ack, .need_snap => {
                assert.check(false, "Follower.step: unexpected message type", .{});
                unreachable;
            },
        };
    }

    /// Handle a replicate message.
    ///
    /// Cases:
    ///   - Stale epoch: silently dropped (empty return).
    ///   - Higher epoch: accepted (new leader).
    ///   - Duplicate (seq <= lastApplied): ack with current lastApplied (idempotent).
    ///   - Gap (seq > lastApplied+1): request snapshot.
    ///   - Sequential (seq == lastApplied+1): apply and ack.
    fn handleReplicate(self: *Follower, msg: Message) []const Message {
        // Stale epoch — drop silently.
        if (msg.epoch < self.epoch) {
            return self.out_buf[0..0];
        }

        // Higher epoch — accept new leader.
        if (msg.epoch > self.epoch) {
            const prev_epoch = self.epoch;
            self.epoch = msg.epoch;
            // Postcondition: epoch only increases.
            assert.check(self.epoch > prev_epoch, "Follower: epoch did not increase", .{});
        }

        // Duplicate — already applied. Ack idempotently so leader stops retrying.
        if (msg.seq <= self.last_applied) {
            return self.emitOne(.{
                .type_ = .ack,
                .from = self.node_id,
                .to = msg.from,
                .epoch = self.epoch,
                .seq = self.last_applied,
            });
        }

        // Gap — missed entries. Request snapshot to catch up.
        if (msg.seq > self.last_applied + 1) {
            return self.emitOne(.{
                .type_ = .need_snap,
                .from = self.node_id,
                .to = msg.from,
                .epoch = self.epoch,
                .seq = self.last_applied,
            });
        }

        // Sequential — apply the entry.
        // Invariant: msg.seq == self.last_applied + 1.
        assert.check(msg.seq == self.last_applied + 1,
            "Follower: expected next seq", .{});

        // Apply errors are bugs: the leader committed valid mutations,
        // so the follower must be able to replay them.
        self.applier.applyBatch(msg.shard_id, msg.seq, msg.data) catch {
            assert.check(false, "Follower: apply failed", .{});
            unreachable;
        };

        const prev_applied = self.last_applied;
        self.last_applied = msg.seq;

        // Postcondition: lastApplied advanced by exactly 1.
        assert.check(self.last_applied == prev_applied + 1,
            "Follower: lastApplied not sequential", .{});

        return self.emitOne(.{
            .type_ = .ack,
            .from = self.node_id,
            .to = msg.from,
            .epoch = self.epoch,
            .seq = self.last_applied,
        });
    }

    /// Handle a snapshot message — replaces local state entirely.
    /// The snapshot data is applied via the Applier with seq=0, shard=0xFFFF
    /// as a sentinel indicating "full snapshot, not incremental."
    /// After applying, last_applied is set to the snapshot's seq.
    fn handleSnapshot(self: *Follower, msg: Message) []const Message {
        if (msg.epoch < self.epoch) return self.out_buf[0..0];
        if (msg.epoch > self.epoch) self.epoch = msg.epoch;

        // Apply snapshot via applier (special shard_id=0xFFFF signals full snapshot).
        self.applier.applyBatch(0xFFFF, msg.seq, msg.data) catch {
            // Snapshot apply failure is fatal.
            assert.check(false, "Follower: snapshot apply failed", .{});
            unreachable;
        };

        self.last_applied = msg.seq;

        return self.emitOne(.{
            .type_ = .ack,
            .from = self.node_id,
            .to = msg.from,
            .epoch = self.epoch,
            .seq = self.last_applied,
        });
    }

    // --- Query methods ---

    pub fn lastApplied(self: *Follower) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.last_applied;
    }

    pub fn getEpoch(self: *Follower) u64 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.epoch;
    }

    /// Update lastApplied after snapshot restore.
    ///
    /// Precondition: seq >= current lastApplied (no regression).
    /// Postcondition: lastApplied == seq.
    pub fn setLastApplied(self: *Follower, seq: u64) void {
        self.mu.lock();
        defer self.mu.unlock();
        assert.check(seq >= self.last_applied, "Follower.setLastApplied: regression", .{});
        self.last_applied = seq;
    }

    pub fn getNodeID(self: *const Follower) []const u8 {
        return self.node_id;
    }

    // --- Helpers ---

    fn emitOne(self: *Follower, msg: Message) []const Message {
        self.out_buf[0] = msg;
        return self.out_buf[0..1];
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing_alloc = std.testing.allocator;

/// Test applier that records calls.
const TestApplier = struct {
    applied: std.ArrayList(AppliedEntry),

    const AppliedEntry = struct {
        shard_id: u16,
        seq: u64,
    };

    fn init() TestApplier {
        return .{ .applied = .{} };
    }

    fn deinit(self: *TestApplier) void {
        self.applied.deinit(testing_alloc);
    }

    fn applier(self: *TestApplier) Applier {
        return .{
            .ptr = @ptrCast(self),
            .applyFn = @ptrCast(&applyBatchImpl),
        };
    }

    fn applyBatchImpl(self: *TestApplier, shard_id: u16, seq: u64, data: []const u8) ApplyError!void {
        _ = data;
        self.applied.append(testing_alloc, .{ .shard_id = shard_id, .seq = seq }) catch unreachable;
    }
};

test "follower sequential apply" {
    var ta = TestApplier.init();
    defer ta.deinit();

    var f = Follower.init("node-2", 1, 0, ta.applier());

    const msgs = f.step(.{
        .type_ = .replicate,
        .from = "node-1",
        .to = "node-2",
        .epoch = 1,
        .seq = 1,
        .shard_id = 0,
        .data = "data1",
    });

    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqual(MessageType.ack, msgs[0].type_);
    try std.testing.expectEqual(@as(u64, 1), msgs[0].seq);
    try std.testing.expectEqual(@as(u64, 1), f.lastApplied());
    try std.testing.expectEqual(@as(usize, 1), ta.applied.items.len);
}

test "follower duplicate is idempotent" {
    var ta = TestApplier.init();
    defer ta.deinit();

    var f = Follower.init("node-2", 1, 5, ta.applier());

    const msgs = f.step(.{
        .type_ = .replicate,
        .from = "node-1",
        .to = "node-2",
        .epoch = 1,
        .seq = 3, // already applied
        .shard_id = 0,
        .data = "old",
    });

    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqual(MessageType.ack, msgs[0].type_);
    try std.testing.expectEqual(@as(u64, 5), msgs[0].seq); // ack with lastApplied
    try std.testing.expectEqual(@as(usize, 0), ta.applied.items.len); // not applied
}

test "follower gap triggers need_snap" {
    var ta = TestApplier.init();
    defer ta.deinit();

    var f = Follower.init("node-2", 1, 5, ta.applier());

    const msgs = f.step(.{
        .type_ = .replicate,
        .from = "node-1",
        .to = "node-2",
        .epoch = 1,
        .seq = 8, // gap: expected 6
        .shard_id = 0,
        .data = "future",
    });

    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqual(MessageType.need_snap, msgs[0].type_);
    try std.testing.expectEqual(@as(u64, 5), msgs[0].seq);
}

test "follower stale epoch dropped" {
    var ta = TestApplier.init();
    defer ta.deinit();

    var f = Follower.init("node-2", 3, 0, ta.applier());

    const msgs = f.step(.{
        .type_ = .replicate,
        .from = "node-1",
        .to = "node-2",
        .epoch = 1, // stale
        .seq = 1,
        .shard_id = 0,
        .data = "stale",
    });

    try std.testing.expectEqual(@as(usize, 0), msgs.len);
    try std.testing.expectEqual(@as(usize, 0), ta.applied.items.len);
}

test "follower accepts higher epoch" {
    var ta = TestApplier.init();
    defer ta.deinit();

    var f = Follower.init("node-2", 1, 0, ta.applier());

    const msgs = f.step(.{
        .type_ = .replicate,
        .from = "node-1",
        .to = "node-2",
        .epoch = 5, // new leader
        .seq = 1,
        .shard_id = 0,
        .data = "data",
    });

    try std.testing.expectEqual(@as(u64, 5), f.getEpoch());
    try std.testing.expectEqual(@as(usize, 1), msgs.len);
    try std.testing.expectEqual(MessageType.ack, msgs[0].type_);
}
