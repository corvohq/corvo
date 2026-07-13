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
//! TigerStyle: bounded `max_pending`, `max_in_flight`, and `max_entry_bytes`
//! (the per-entry payload cap that keeps an assembled AppendEntries within the
//! codec frame cap — see the comptime livelock guard); static slot arrays;
//! assert on overflow rather than allocate.

const std = @import("std");
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const raft = @import("raft");
const codec = @import("raft_codec.zig");
const kv = @import("kv.zig");
const oplog = @import("oplog.zig");

const Mutation = kv.Mutation;
const Node = raft.Node;
const Message = raft.messages.Message;

/// Max pending handler proposals waiting for the next flush.
pub const max_pending: usize = 4096;
/// Max entries proposed but not yet committed at any one moment.
pub const max_in_flight: usize = 1024;

/// Entries packed per AppendEntries message. Corvo lowers zig-raft's default
/// (64) so the per-entry byte budget below is large enough to hold ANY single
/// client op's mutations — one frame's payload is capped at 256 KiB
/// (rpc.MAX_PAYLOAD_SIZE), and the pipeline splits its per-tick proposal at
/// frame boundaries, never inside one op. Every raft.Config corvo constructs
/// MUST set .max_entries_per_msg to this (raft_runtime.defaultConfig does;
/// Runtime.init rejects configs that don't).
pub const entries_per_msg: u32 = 4;

/// Hard cap on a single proposed entry's encoded payload (one flush = one raft
/// entry). Derived from the codec frame cap and entries_per_msg so that a
/// FULL AppendEntries — entries_per_msg entries, each this large — still
/// fits in codec.max_msg_bytes. See the comptime livelock guard below.
pub const max_entry_bytes: usize = codec.maxEntryDataBytes(entries_per_msg);

comptime {
    // Livelock guard (docs/hardening-roadmap.md Phase 3: "entry-size vs
    // codec-frame cap"). A leader packs up to Config.max_entries_per_msg
    // entries into one AppendEntries by COUNT with no byte budget
    // (zig-raft src/raft.zig buildAppendEntriesFor). If
    // entries_per_msg × (per-entry-size + overhead) + frame overhead ever
    // exceeds codec.max_msg_bytes, the leader can assemble a message it can
    // neither encode (raft_codec) nor transmit (raft_net send buffer), and
    // re-assembles the same oversize message on every retry — replication
    // stalls forever for that follower. Bounding every entry to
    // max_entry_bytes makes that message unassemblable; this assert fails the
    // build if any of these constants drift out of that relationship.
    const worst = entries_per_msg * (max_entry_bytes + codec.entry_wire_overhead) + codec.max_frame_overhead;
    std.debug.assert(max_entry_bytes > 0);
    std.debug.assert(worst <= codec.max_msg_bytes);
    // The per-entry budget must fit one full-size client op: payload hard cap
    // plus generous headroom for the op's index/counter mutations.
    std.debug.assert(max_entry_bytes >= 256 * 1024 + 64 * 1024);
}

pub const BatcherError = error{
    PendingFull,
    InFlightFull,
    EncodeFailed,
    ProposeFailed,
    /// A single proposal's encoded mutations exceed max_entry_bytes — it can
    /// never be flushed without producing an untransmittable entry. Rejected
    /// at enqueue (client input is a boundary) instead of livelocking later.
    ProposalTooLarge,
};

/// Contract: once `enqueue` accepts a completion, the batcher fires
/// `on_complete` exactly once — via `onCommitted` (success) or `failAll`
/// (failure). Errors never double-fire: `enqueue` rejects before storing,
/// and `flush` failures leave completions pending for a later flush or
/// failAll. Callers (raft_host token lifecycle) rely on exactly-once.
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
    /// The proposer already committed these mutations to talon before
    /// proposing (the pipeline's contract, docs/raft-wiring.md). On commit
    /// the FSM records the entry applied without re-writing data.
    locally_applied: bool,
};

pub const Batcher = struct {
    allocator: std.mem.Allocator,

    pending: [max_pending]PendingProposal = undefined,
    pending_count: usize = 0,
    pending_bytes: usize = 0,
    pending_locally_applied: bool = false,

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

    /// Add a proposal to the pending batch. Caller's `mutations` slice must
    /// remain valid until flush() consumes it (i.e. the next tick). Returns
    /// ProposalTooLarge if this one proposal exceeds max_entry_bytes, or
    /// PendingFull if there is no slot or adding it would push the current
    /// batch past the per-entry cap (the caller should flush and retry).
    pub fn enqueue(self: *Batcher, mutations: []const Mutation, completion: Completion, locally_applied: bool) BatcherError!void {
        const enc_size = encodedSize(mutations);
        // A single proposal whose encoded mutations exceed the per-entry cap
        // can never be flushed without producing an entry that overflows the
        // codec frame cap. Reject it at the boundary rather than let the leader
        // assemble an untransmittable AppendEntries it retries forever — see
        // the comptime livelock guard.
        if (enc_size > max_entry_bytes) return BatcherError.ProposalTooLarge;
        if (self.pending_count == max_pending) return BatcherError.PendingFull;
        // Adding to a non-empty batch would cross the per-entry cap: tell the
        // caller to flush first; this proposal starts the next batch.
        if (self.pending_count > 0 and self.pending_bytes + enc_size > max_entry_bytes) {
            return BatcherError.PendingFull;
        }
        // Coalesced proposals share one entry, so the locally_applied flag
        // must be uniform across the batch. In practice every production
        // proposal comes from the pipeline (always true); mixing only
        // happens in tests.
        if (self.pending_count > 0 and self.pending_locally_applied != locally_applied) {
            return BatcherError.PendingFull;
        }
        self.pending[self.pending_count] = .{ .mutations = mutations, .completion = completion };
        self.pending_count += 1;
        self.pending_bytes += enc_size;
        self.pending_locally_applied = locally_applied;
    }

    /// Should the caller call flush now (rather than wait for the next
    /// tick boundary)? True when the batch is at the per-entry byte cap.
    pub fn shouldFlush(self: *const Batcher) bool {
        return self.pending_bytes >= max_entry_bytes or self.pending_count >= max_pending;
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
        // enqueue keeps pending_bytes <= max_entry_bytes and single-encoding
        // only shrinks it (redundant per-proposal count prefixes collapse), so
        // the flushed entry can never overflow the per-entry cap. This assert
        // pins the livelock guarantee at the point the entry is produced.
        check(payload.len <= max_entry_bytes, "flushed entry {d} exceeds per-entry cap {d}", .{ payload.len, max_entry_bytes });
        const idx = try propose_fn(propose_ctx, payload);
        // Stash completions under that entry index.
        var slot = &self.in_flight[self.in_flight_count];
        slot.* = .{ .entry_index = idx, .completions = .{}, .locally_applied = self.pending_locally_applied };
        for (self.pending[0..self.pending_count]) |p| {
            slot.completions.append(self.allocator, p.completion) catch return BatcherError.EncodeFailed;
        }
        self.in_flight_count += 1;
        self.pending_count = 0;
        self.pending_bytes = 0;
    }

    /// True when `entry_index` is an in-flight self-proposal whose mutations
    /// the proposer already committed to talon (see InFlightEntry). Consulted
    /// by the runtime's apply loop BEFORE onCommitted removes the entry.
    pub fn isLocallyApplied(self: *const Batcher, entry_index: u64) bool {
        for (self.in_flight[0..self.in_flight_count]) |*e| {
            if (e.entry_index == entry_index) return e.locally_applied;
        }
        return false;
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

    /// On leader step-down, fail only proposals above the Raft commit index.
    /// An entry can reach quorum and advance commit_index, then a higher-term
    /// message later in the same inbound batch demotes the node before
    /// Runtime.applyReady applies it. Failing that committed completion makes
    /// the pipeline panic for a write the cluster DID accept. Keep committed
    /// entries until applyReady marks/applies them and onCommitted succeeds;
    /// fail every uncommitted in-flight and not-yet-flushed proposal.
    pub fn failUncommitted(self: *Batcher, commit_index: u64) void {
        var write: usize = 0;
        for (0..self.in_flight_count) |i| {
            const entry = &self.in_flight[i];
            if (entry.entry_index <= commit_index) {
                if (write != i) self.in_flight[write] = entry.*;
                write += 1;
            } else {
                for (entry.completions.items) |c| c.on_complete(c.ctx, false);
                entry.completions.deinit(self.allocator);
            }
        }
        self.in_flight_count = write;

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
    try b.enqueue(&muts, counter.completion(), false);
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
    try b.enqueue(&m1, c1.completion(), false);
    try b.enqueue(&m2, c2.completion(), false);
    try b.enqueue(&m3, c3.completion(), false);
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

test "batcher: coalescing capped at max_entry_bytes" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    // Size each value (derived from the cap) so two proposals coalesce under
    // max_entry_bytes but a third would cross it — forcing a flush boundary.
    const val_len = max_entry_bytes / 3;
    const big_value = try testing.allocator.alloc(u8, val_len);
    defer testing.allocator.free(big_value);
    @memset(big_value, 'A');
    const m1 = [_]Mutation{.{ .op = .set, .key = "k1", .value = big_value }};
    const m2 = [_]Mutation{.{ .op = .set, .key = "k2", .value = big_value }};
    const m3 = [_]Mutation{.{ .op = .set, .key = "k3", .value = big_value }};
    try b.enqueue(&m1, counter.completion(), false);
    try b.enqueue(&m2, counter.completion(), false);
    try testing.expectError(BatcherError.PendingFull, b.enqueue(&m3, counter.completion(), false));
}

test "batcher: single oversize proposal rejected (no livelock entry)" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    // One proposal whose encoded mutations exceed the per-entry cap can never
    // be flushed without producing an entry that overflows the codec frame
    // cap. It must be rejected at enqueue — before any completion is stored —
    // rather than assembled into an untransmittable AppendEntries later.
    const big_value = try testing.allocator.alloc(u8, max_entry_bytes);
    defer testing.allocator.free(big_value);
    @memset(big_value, 'Z');
    const m = [_]Mutation{.{ .op = .set, .key = "k", .value = big_value }};
    try testing.expectError(BatcherError.ProposalTooLarge, b.enqueue(&m, counter.completion(), false));
    try testing.expectEqual(@as(usize, 0), b.pendingCount());
    // Rejected before storing → the completion never fired (exactly-once).
    try testing.expectEqual(@as(usize, 0), counter.successes);
    try testing.expectEqual(@as(usize, 0), counter.failures);
}

test "batcher: flushed entry packs max_entries_per_msg times within frame cap" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();

    // Fill a batch as close to the per-entry cap as one proposal allows.
    const val_len = max_entry_bytes - 32; // leave room for key + framing
    const big_value = try testing.allocator.alloc(u8, val_len);
    defer testing.allocator.free(big_value);
    @memset(big_value, 'Q');
    const m = [_]Mutation{.{ .op = .set, .key = "k", .value = big_value }};
    try b.enqueue(&m, counter.completion(), false);
    try b.flush(@ptrCast(&proposer), TestProposer.propose);

    // The flushed payload must not exceed the per-entry cap...
    try testing.expect(proposer.last_payload.len <= max_entry_bytes);

    // ...and entries_per_msg entries of that payload must still encode
    // within the codec frame cap — the exact condition whose violation causes
    // the replication livelock this batcher guards against.
    const count = entries_per_msg;
    const ents = try testing.allocator.alloc(raft.Entry, count);
    defer testing.allocator.free(ents);
    for (ents, 0..) |*e, i| e.* = .{ .term = 1, .index = @intCast(i + 1), .data = proposer.last_payload };
    const id32 = "x" ** codec.max_id_len;
    const msg = raft.Message{ .type_ = .append_entries, .from = id32, .to = id32, .term = 1, .entries = ents };
    try testing.expect(codec.encodedSize(msg) <= codec.max_msg_bytes);
}

test "batcher: failAll fires failures and clears" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    const m = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
    try b.enqueue(&m, counter.completion(), false);
    try b.flush(@ptrCast(&proposer), TestProposer.propose);
    // Pending again before commit.
    try b.enqueue(&m, counter.completion(), false);
    b.failAll();
    try testing.expectEqual(@as(usize, 2), counter.failures);
    try testing.expectEqual(@as(usize, 0), b.pendingCount());
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}

test "batcher: step-down preserves committed completion and fails only suffix" {
    var batcher = Batcher.init(testing.allocator);
    defer batcher.deinit();
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    var committed = TestCounter{};
    var uncommitted = TestCounter{};
    var pending = TestCounter{};
    const mutation = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};

    try batcher.enqueue(&mutation, committed.completion(), true);
    try batcher.flush(@ptrCast(&proposer), TestProposer.propose);
    try batcher.enqueue(&mutation, uncommitted.completion(), true);
    try batcher.flush(@ptrCast(&proposer), TestProposer.propose);
    try batcher.enqueue(&mutation, pending.completion(), true);

    batcher.failUncommitted(1);
    try testing.expectEqual(@as(usize, 0), committed.successes);
    try testing.expectEqual(@as(usize, 0), committed.failures);
    try testing.expectEqual(@as(usize, 1), uncommitted.failures);
    try testing.expectEqual(@as(usize, 1), pending.failures);
    try testing.expectEqual(@as(usize, 1), batcher.inFlightCount());

    batcher.onCommitted(1);
    try testing.expectEqual(@as(usize, 1), committed.successes);
    try testing.expectEqual(@as(usize, 0), batcher.inFlightCount());
}

test "batcher: onCommitted only fires for committed entries" {
    var b = Batcher.init(testing.allocator);
    defer b.deinit();
    var c1 = TestCounter{};
    var c2 = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    const m = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};

    try b.enqueue(&m, c1.completion(), false);
    try b.flush(@ptrCast(&proposer), TestProposer.propose); // index 1
    try b.enqueue(&m, c2.completion(), false);
    try b.flush(@ptrCast(&proposer), TestProposer.propose); // index 2

    b.onCommitted(1);
    try testing.expectEqual(@as(usize, 1), c1.successes);
    try testing.expectEqual(@as(usize, 0), c2.successes);
    try testing.expectEqual(@as(usize, 1), b.inFlightCount());

    b.onCommitted(2);
    try testing.expectEqual(@as(usize, 1), c2.successes);
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}
