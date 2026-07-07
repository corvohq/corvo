//! raft_batcher.zig — coalesce per-tick handler proposes into one Raft entry.
//!
//! Without this, every handler call costs a full Raft round (propose →
//! quorum ack → commit → apply). With this, many handler calls in a
//! single tick share one Raft entry, amortizing storage + replication.
//!
//! Flow:
//!   1. Handler calls `enqueue(mutations, completion)` — appends to pending.
//!   2. Tick loop calls `flush(node, now)` — emits one `Node.propose` with
//!      all pending mutations encoded as one payload, records entry-index →
//!      pending completions.
//!   3. After `Node.ready()`, tick loop calls `onCommitted(commit_index)` —
//!      fires completions for any in-flight entries with index ≤
//!      commit_index.
//!
//! TigerStyle: bounded `max_pending` and `max_in_flight`; static slot
//! arrays; assert on overflow rather than allocate.

const std = @import("std");
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const raft = @import("raft");
const kv = @import("kv.zig");
const oplog = @import("oplog.zig");

const Mutation = kv.Mutation;
const Node = raft.Node;
const Message = raft.messages.Message;

/// Max pending handler proposals waiting for the next flush.
pub const max_pending: usize = 4096;
/// Max entries proposed but not yet committed at any one moment.
pub const max_in_flight: usize = 1024;
/// Bytes-encoded cap per single proposed entry. When pending exceeds this,
/// flush is forced before the next enqueue.
pub const max_batch_bytes: usize = 64 * 1024;

pub const BatcherError = error{
    PendingFull,
    InFlightFull,
    EncodeFailed,
    ProposeFailed,
};

pub const Completion = struct {
    ctx: *anyopaque,
    on_complete: *const fn (*anyopaque, success: bool) void,
};

/// One pending proposal (not yet flushed).
const PendingProposal = struct {
    /// Mutations slice — caller-owned for the lifetime of this proposal
    /// (i.e. until flush or drop). The batcher does NOT copy here; on
    /// flush it concatenates all pending mutations into one encoded entry.
    mutations: []const Mutation,
    completion: Completion,
};

/// One in-flight entry (proposed; awaiting commit).
const InFlightEntry = struct {
    entry_index: u64,
    completions: std.ArrayList(Completion),
};

pub const Batcher = struct {
    allocator: std.mem.Allocator,

    pending: [max_pending]PendingProposal = undefined,
    pending_count: usize = 0,
    pending_bytes: usize = 0,

    in_flight: [max_in_flight]InFlightEntry = undefined,
    in_flight_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Batcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Batcher) void {
        for (0..self.in_flight_count) |i| {
            self.in_flight[i].completions.deinit(self.allocator);
        }
        self.in_flight_count = 0;
        self.pending_count = 0;
    }

    /// Add a proposal to the pending batch. Returns PendingFull if there
    /// is no slot. Caller's `mutations` slice must remain valid until
    /// flush() consumes it (i.e. the next tick).
    pub fn enqueue(self: *Batcher, mutations: []const Mutation, completion: Completion) BatcherError!void {
        if (self.pending_count == max_pending) return BatcherError.PendingFull;
        const enc_size = encodedSize(mutations);
        // If a single proposal already exceeds the per-entry cap, accept it
        // alone — it'll be the only one in its batch.
        if (self.pending_bytes + enc_size > max_batch_bytes and self.pending_count > 0) {
            return BatcherError.PendingFull;
        }
        self.pending[self.pending_count] = .{ .mutations = mutations, .completion = completion };
        self.pending_count += 1;
        self.pending_bytes += enc_size;
    }

    /// Should the caller call flush now (rather than wait for the next
    /// tick boundary)? True when the batch is at the byte cap.
    pub fn shouldFlush(self: *const Batcher) bool {
        return self.pending_bytes >= max_batch_bytes or self.pending_count >= max_pending;
    }

    pub fn pendingCount(self: *const Batcher) usize {
        return self.pending_count;
    }

    pub fn inFlightCount(self: *const Batcher) usize {
        return self.in_flight_count;
    }

    /// Flush all pending proposals as one Raft entry. No-op if nothing
    /// pending. The Node must be the current leader; `proposeFn` returns
    /// the new entry's index.
    ///
    /// `proposeFn` indirection lets tests run without a full Raft Node;
    /// production callers pass a wrapper around `node.propose`.
    pub fn flush(
        self: *Batcher,
        propose_ctx: *anyopaque,
        propose_fn: *const fn (ctx: *anyopaque, payload: []const u8) BatcherError!u64,
    ) BatcherError!void {
        if (self.pending_count == 0) return;
        if (self.in_flight_count == max_in_flight) return BatcherError.InFlightFull;
        // Encode all pending mutations into one blob.
        const payload = self.encodePending() catch return BatcherError.EncodeFailed;
        defer self.allocator.free(payload);
        const idx = try propose_fn(propose_ctx, payload);
        // Stash completions under that entry index.
        var slot = &self.in_flight[self.in_flight_count];
        slot.* = .{ .entry_index = idx, .completions = .{} };
        for (self.pending[0..self.pending_count]) |p| {
            slot.completions.append(self.allocator, p.completion) catch return BatcherError.EncodeFailed;
        }
        self.in_flight_count += 1;
        self.pending_count = 0;
        self.pending_bytes = 0;
    }

    /// Fire completions for any in-flight entry with index ≤ commit_index.
    pub fn onCommitted(self: *Batcher, commit_index: u64) void {
        var write: usize = 0;
        for (0..self.in_flight_count) |i| {
            const e = &self.in_flight[i];
            if (e.entry_index <= commit_index) {
                for (e.completions.items) |c| c.on_complete(c.ctx, true);
                e.completions.deinit(self.allocator);
            } else {
                if (write != i) self.in_flight[write] = e.*;
                write += 1;
            }
        }
        self.in_flight_count = write;
    }

    /// Fail all in-flight + pending completions (e.g. on leader stepdown).
    pub fn failAll(self: *Batcher) void {
        for (0..self.in_flight_count) |i| {
            const e = &self.in_flight[i];
            for (e.completions.items) |c| c.on_complete(c.ctx, false);
            e.completions.deinit(self.allocator);
        }
        self.in_flight_count = 0;
        for (0..self.pending_count) |i| {
            const c = self.pending[i].completion;
            c.on_complete(c.ctx, false);
        }
        self.pending_count = 0;
        self.pending_bytes = 0;
    }

    fn encodePending(self: *Batcher) ![]u8 {
        // Concatenate all pending mutations into one []Mutation, then
        // single-encode via oplog.encodeMutations.
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var all: std.ArrayList(Mutation) = .{};
        for (self.pending[0..self.pending_count]) |p| {
            for (p.mutations) |m| {
                try all.append(a, m);
            }
        }
        // encodeMutations allocates with self.allocator; caller frees.
        return oplog.encodeMutations(self.allocator, all.items);
    }
};

fn encodedSize(muts: []const Mutation) usize {
    var n: usize = 4; // count u32
    for (muts) |m| n += 1 + 2 + 4 + m.key.len + m.value.len;
    return n;
}

// =====================================================================
// Tests
// =====================================================================

const testing = std.testing;

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

const TestProposer = struct {
    next_index: u64 = 1,
    last_payload: []u8 = &.{},
    allocator: std.mem.Allocator,

    fn propose(ctx: *anyopaque, payload: []const u8) BatcherError!u64 {
        const self: *TestProposer = @ptrCast(@alignCast(ctx));
        if (self.last_payload.len > 0) self.allocator.free(self.last_payload);
        self.last_payload = self.allocator.dupe(u8, payload) catch return BatcherError.EncodeFailed;
        const idx = self.next_index;
        self.next_index += 1;
        return idx;
    }
    fn deinit(self: *TestProposer) void {
        if (self.last_payload.len > 0) self.allocator.free(self.last_payload);
    }
};

test "batcher: enqueue + flush + commit fires completion" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();

    const muts = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
    try b.enqueue(&muts, counter.completion());
    try testing.expectEqual(@as(usize, 1), b.pendingCount());
    try b.flush(@ptrCast(&proposer), TestProposer.propose);
    try testing.expectEqual(@as(usize, 0), b.pendingCount());
    try testing.expectEqual(@as(usize, 1), b.inFlightCount());
    try testing.expectEqual(@as(usize, 0), counter.successes);

    b.onCommitted(1);
    try testing.expectEqual(@as(usize, 1), counter.successes);
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}

test "batcher: multiple enqueues flush as one entry" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var c1 = TestCounter{};
    var c2 = TestCounter{};
    var c3 = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();

    const m1 = [_]Mutation{.{ .op = .set, .key = "a", .value = "1" }};
    const m2 = [_]Mutation{.{ .op = .set, .key = "b", .value = "2" }};
    const m3 = [_]Mutation{.{ .op = .set, .key = "c", .value = "3" }};
    try b.enqueue(&m1, c1.completion());
    try b.enqueue(&m2, c2.completion());
    try b.enqueue(&m3, c3.completion());
    try b.flush(@ptrCast(&proposer), TestProposer.propose);
    try testing.expectEqual(@as(u64, 2), proposer.next_index); // proposed once

    // Decode payload — should contain three set mutations in order.
    const decoded = try oplog.decodeMutations(testing.allocator, proposer.last_payload);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 3), decoded.len);
    try testing.expectEqualStrings("a", decoded[0].key);
    try testing.expectEqualStrings("c", decoded[2].key);

    b.onCommitted(1);
    try testing.expectEqual(@as(usize, 1), c1.successes);
    try testing.expectEqual(@as(usize, 1), c2.successes);
    try testing.expectEqual(@as(usize, 1), c3.successes);
}

test "batcher: flush no-op on empty pending" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    try b.flush(@ptrCast(&proposer), TestProposer.propose);
    try testing.expectEqual(@as(u64, 1), proposer.next_index); // unchanged
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}

test "batcher: pending capped at max_batch_bytes" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    // Each value is 30 KiB; per-mutation overhead ~9 bytes, plus 4-byte
    // count prefix per call. Two enqueues ≈ 61 KiB; a third would push
    // total past the 64 KiB per-entry cap.
    const big_value = try testing.allocator.alloc(u8, 30 * 1024);
    defer testing.allocator.free(big_value);
    @memset(big_value, 'A');
    const m1 = [_]Mutation{.{ .op = .set, .key = "k1", .value = big_value }};
    const m2 = [_]Mutation{.{ .op = .set, .key = "k2", .value = big_value }};
    const m3 = [_]Mutation{.{ .op = .set, .key = "k3", .value = big_value }};
    try b.enqueue(&m1, counter.completion());
    try b.enqueue(&m2, counter.completion());
    try testing.expectError(BatcherError.PendingFull, b.enqueue(&m3, counter.completion()));
}

test "batcher: failAll fires failures and clears" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    const m = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
    try b.enqueue(&m, counter.completion());
    try b.flush(@ptrCast(&proposer), TestProposer.propose);
    // Pending again before commit.
    try b.enqueue(&m, counter.completion());
    b.failAll();
    try testing.expectEqual(@as(usize, 2), counter.failures);
    try testing.expectEqual(@as(usize, 0), b.pendingCount());
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}

test "batcher: onCommitted only fires for committed entries" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var c1 = TestCounter{};
    var c2 = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    const m = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};

    try b.enqueue(&m, c1.completion());
    try b.flush(@ptrCast(&proposer), TestProposer.propose); // index 1
    try b.enqueue(&m, c2.completion());
    try b.flush(@ptrCast(&proposer), TestProposer.propose); // index 2

    b.onCommitted(1);
    try testing.expectEqual(@as(usize, 1), c1.successes);
    try testing.expectEqual(@as(usize, 0), c2.successes);
    try testing.expectEqual(@as(usize, 1), b.inFlightCount());

    b.onCommitted(2);
    try testing.expectEqual(@as(usize, 1), c2.successes);
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}
