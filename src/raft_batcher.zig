//! raft_batcher.zig — coalesce per-tick handler proposes into one Raft entry.
//!
//! Without this, every handler call costs a full Raft round (propose →
//! quorum ack → commit → apply). With this, many handler calls in a
//! single tick share one Raft entry, amortizing storage + replication.
//!
//! Flow:
//!   1. Handler calls `enqueue(mutations, completion)` — the mutations are
//!      encoded immediately into the batcher-owned pending buffer (the
//!      caller's slices may be freed on return).
//!   2. Tick loop calls `flush(node, now)` — emits one `Node.propose` with
//!      all pending mutations as one payload, and records the new entry's
//!      (index, term) against the pending completions.
//!   3. After `Node.ready()`, the tick loop calls `completeCommitted(index,
//!      term)` for each committed entry — success only on an exact
//!      (index, term) match; an index match with a different term means a
//!      new leader overwrote our uncommitted entry, so the completion FAILS
//!      (the pipeline's divergence fail-stop handles it).
//!
//! TigerStyle: bounded `max_pending`, `max_in_flight`, and `max_entry_bytes`
//! (the per-entry payload cap that keeps an assembled AppendEntries within the
//! codec frame cap — see the comptime livelock guard); static slot arrays and
//! a pending buffer pre-allocated once at init; back-pressure errors (not
//! asserts) on overflow, because an operator can legally hit these limits.

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
    OutOfMemory,
    ProposeFailed,
    /// A single proposal's encoded mutations exceed max_entry_bytes — it can
    /// never be flushed without producing an untransmittable entry. Rejected
    /// at enqueue (client input is a boundary) instead of livelocking later.
    ProposalTooLarge,
};

/// Contract: once `enqueue` accepts a completion, the batcher fires
/// `on_complete` exactly once — via `completeCommitted` (success on an
/// (index, term) match, failure on a term mismatch) or `failAll` /
/// `failPending` / `failDiscarded` (failure). Errors never double-fire:
/// `enqueue` rejects before storing, and `flush` failures leave completions
/// pending for a later flush or failAll. Callers (raft_host token
/// lifecycle) rely on exactly-once.
pub const Completion = struct {
    ctx: *anyopaque,
    on_complete: *const fn (*anyopaque, success: bool) void,
};

/// What `flush`'s propose_fn reports back: the appended entry's log position
/// AND the term it was proposed under. Both are recorded per in-flight entry
/// so commit-time completion can detect a different leader's entry landing
/// at the same index (see completeCommitted).
pub const ProposedEntry = struct {
    index: u64,
    term: u64,
};

/// One in-flight entry (proposed; awaiting commit).
const InFlightEntry = struct {
    entry_index: u64,
    /// Leader term the entry was proposed under. A committed entry at
    /// `entry_index` with a DIFFERENT term is a new leader's entry that
    /// overwrote ours after truncation — completing it as success would
    /// falsely ack a discarded write, and treating it as locally applied
    /// would skip applying the new leader's data (permanent KV divergence).
    entry_term: u64,
    completions: std.ArrayList(Completion),
    /// The proposer already committed these mutations to talon before
    /// proposing (the pipeline's contract, docs/raft-wiring.md). On commit
    /// the FSM records the entry applied without re-writing data — but only
    /// when the committed entry's (index, term) matches this record.
    locally_applied: bool,
};

pub const Batcher = struct {
    allocator: std.mem.Allocator,

    /// Batcher-owned encoded pending batch. Layout mirrors one
    /// oplog.encodeMutations blob: [count:4LE] at offset 0 (finalized at
    /// flush), mutation bodies from offset 4. `enqueue` copies mutation
    /// bytes in here immediately, so callers may free their slices on
    /// return — nothing in the batcher dangles into caller memory.
    /// Pre-allocated once at init (len == max_entry_bytes); the payload can
    /// never exceed that (see enqueue's budget check + the flush assert).
    pending_buf: []u8,
    /// Completion per accepted-but-unflushed proposal.
    pending: [max_pending]Completion = undefined,
    pending_count: usize = 0,
    /// Bytes of mutation bodies written after the 4-byte count header.
    pending_body_bytes: usize = 0,
    /// Total mutations across all pending proposals (the count header).
    pending_mut_count: u32 = 0,
    pending_locally_applied: bool = false,

    in_flight: [max_in_flight]InFlightEntry = undefined,
    in_flight_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !Batcher {
        // Pre-allocate the pending buffer up front so enqueue never
        // allocates (pre-initialized memory: nothing can fail after a
        // proposal is partially captured).
        const buf = try allocator.alloc(u8, max_entry_bytes);
        return .{ .allocator = allocator, .pending_buf = buf };
    }

    pub fn deinit(self: *Batcher) void {
        for (0..self.in_flight_count) |i| {
            self.in_flight[i].completions.deinit(self.allocator);
        }
        self.in_flight_count = 0;
        self.pending_count = 0;
        self.allocator.free(self.pending_buf);
    }

    /// Add a proposal to the pending batch. The mutations' bytes are copied
    /// into the batcher-owned pending buffer before return — the caller may
    /// free or reuse its slices immediately. Returns ProposalTooLarge if
    /// this one proposal exceeds max_entry_bytes, or PendingFull if there is
    /// no slot or adding it would push the current batch past the per-entry
    /// cap (the caller should flush and retry).
    pub fn enqueue(self: *Batcher, mutations: []const Mutation, completion: Completion, locally_applied: bool) BatcherError!void {
        const enc_size = encodedSize(mutations);
        // A single proposal whose encoded mutations exceed the per-entry cap
        // can never be flushed without producing an entry that overflows the
        // codec frame cap. Reject it at the boundary rather than let the leader
        // assemble an untransmittable AppendEntries it retries forever — see
        // the comptime livelock guard.
        if (enc_size > max_entry_bytes) return BatcherError.ProposalTooLarge;
        if (self.pending_count == max_pending) return BatcherError.PendingFull;
        const body_size = enc_size - 4; // enc_size includes the 4-byte count header
        // Adding to a non-empty batch would cross the per-entry cap: tell the
        // caller to flush first; this proposal starts the next batch.
        if (self.pending_count > 0 and 4 + self.pending_body_bytes + body_size > max_entry_bytes) {
            return BatcherError.PendingFull;
        }
        // Coalesced proposals share one entry, so the locally_applied flag
        // must be uniform across the batch. PendingFull tells the caller to
        // flush first; this proposal then starts the next batch.
        if (self.pending_count > 0 and self.pending_locally_applied != locally_applied) {
            return BatcherError.PendingFull;
        }
        // All checks passed — copy the mutation bodies into the pending
        // buffer. Nothing below can fail (no allocation, bounds proven).
        var pos = 4 + self.pending_body_bytes;
        for (mutations) |m| {
            self.pending_buf[pos] = @intFromEnum(m.op);
            pos += 1;
            std.mem.writeInt(u16, self.pending_buf[pos..][0..2], @intCast(m.key.len), .little);
            pos += 2;
            std.mem.writeInt(u32, self.pending_buf[pos..][0..4], @intCast(m.value.len), .little);
            pos += 4;
            @memcpy(self.pending_buf[pos..][0..m.key.len], m.key);
            pos += m.key.len;
            @memcpy(self.pending_buf[pos..][0..m.value.len], m.value);
            pos += m.value.len;
        }
        check(pos == 4 + self.pending_body_bytes + body_size, "enqueue encoded {d} bytes, sized {d}", .{ pos - 4 - self.pending_body_bytes, body_size });
        self.pending[self.pending_count] = completion;
        self.pending_count += 1;
        self.pending_body_bytes += body_size;
        self.pending_mut_count += @intCast(mutations.len);
        self.pending_locally_applied = locally_applied;
    }

    pub fn pendingCount(self: *const Batcher) usize {
        return self.pending_count;
    }

    pub fn inFlightCount(self: *const Batcher) usize {
        return self.in_flight_count;
    }

    /// Flush all pending proposals as one Raft entry. No-op if nothing
    /// pending. The Node must be the current leader; `propose_fn` returns
    /// the new entry's (index, term).
    ///
    /// Failure ordering contract: every fallible step (in-flight slot,
    /// completion-list reservation) runs BEFORE propose_fn. Once the entry
    /// is in the log nothing can fail, so a logged entry always has its
    /// in-flight record — re-proposing a logged entry (a duplicate whose
    /// first copy would then be FULL-applied on the leader, transiently
    /// rolling back newer in-flight batches) is impossible.
    ///
    /// On error the pending batch is retained — the bytes live in the
    /// batcher-owned pending buffer, so retrying on a later tick is safe.
    ///
    /// `propose_fn` indirection lets tests run without a full Raft Node;
    /// production callers pass a wrapper around `node.propose`.
    pub fn flush(
        self: *Batcher,
        propose_ctx: *anyopaque,
        propose_fn: *const fn (ctx: *anyopaque, payload: []const u8, now: i64) BatcherError!ProposedEntry,
        now: i64,
    ) BatcherError!void {
        if (self.pending_count == 0) return;
        if (self.in_flight_count == max_in_flight) return BatcherError.InFlightFull;
        // Reserve the completion list BEFORE proposing (pre-initialized
        // memory): an allocation failure here loses nothing — the batch is
        // retained; after propose_fn only infallible appendAssumeCapacity
        // runs.
        var completions = std.ArrayList(Completion).initCapacity(self.allocator, self.pending_count) catch return BatcherError.OutOfMemory;
        errdefer completions.deinit(self.allocator);
        // Finalize the count header; the payload is the pending buffer.
        std.mem.writeInt(u32, self.pending_buf[0..4], self.pending_mut_count, .little);
        const payload = self.pending_buf[0 .. 4 + self.pending_body_bytes];
        // enqueue keeps the running payload <= max_entry_bytes, so the
        // flushed entry can never overflow the per-entry cap. This assert
        // pins the livelock guarantee at the point the entry is produced.
        check(payload.len <= max_entry_bytes, "flushed entry {d} exceeds per-entry cap {d}", .{ payload.len, max_entry_bytes });
        // propose_fn (raft_runtime.proposeBridge) copies the payload into
        // raft storage, so reusing pending_buf for the next batch is safe.
        const proposed = try propose_fn(propose_ctx, payload, now);
        for (self.pending[0..self.pending_count]) |c| completions.appendAssumeCapacity(c);
        self.in_flight[self.in_flight_count] = .{
            .entry_index = proposed.index,
            .entry_term = proposed.term,
            .completions = completions,
            .locally_applied = self.pending_locally_applied,
        };
        self.in_flight_count += 1;
        self.pending_count = 0;
        self.pending_body_bytes = 0;
        self.pending_mut_count = 0;
    }

    /// True when the committed entry (entry_index, entry_term) is an
    /// in-flight self-proposal whose mutations the proposer already
    /// committed to talon (see InFlightEntry). The term must match: a
    /// same-index entry from another leader carries DIFFERENT data that
    /// must take the full apply path. Consulted by the runtime's apply
    /// loop BEFORE completeCommitted removes the entry.
    pub fn isLocallyApplied(self: *const Batcher, entry_index: u64, entry_term: u64) bool {
        for (self.in_flight[0..self.in_flight_count]) |*e| {
            if (e.entry_index == entry_index) {
                return e.entry_term == entry_term and e.locally_applied;
            }
        }
        return false;
    }

    /// Fire the completion for one committed entry. Success only on an
    /// exact (index, term) match; an index match with a different term
    /// means our proposal was truncated by a new leader and a different
    /// entry committed at that index — the completion FAILS (the pipeline
    /// treats a failed token after local commit as divergence and
    /// fail-stops). No-op when the index has no in-flight record (follower
    /// catch-up entries, entries whose completions already failed).
    pub fn completeCommitted(self: *Batcher, entry_index: u64, entry_term: u64) void {
        for (0..self.in_flight_count) |i| {
            const e = &self.in_flight[i];
            if (e.entry_index != entry_index) continue;
            const success = e.entry_term == entry_term;
            for (e.completions.items) |c| c.on_complete(c.ctx, success);
            e.completions.deinit(self.allocator);
            // Remove slot i, preserving order.
            var j = i;
            while (j + 1 < self.in_flight_count) : (j += 1) {
                self.in_flight[j] = self.in_flight[j + 1];
            }
            self.in_flight_count -= 1;
            return;
        }
    }

    /// True when any in-flight entry has index <= `index`. The runtime
    /// asserts this is false after applying a committed range through
    /// `index` — a leftover would be a completion that can never fire.
    pub fn hasInFlightAtOrBelow(self: *const Batcher, index: u64) bool {
        for (self.in_flight[0..self.in_flight_count]) |*e| {
            if (e.entry_index <= index) return true;
        }
        return false;
    }

    /// Fail all in-flight + pending completions (e.g. on snapshot install
    /// or runtime shutdown).
    pub fn failAll(self: *Batcher) void {
        for (0..self.in_flight_count) |i| {
            const e = &self.in_flight[i];
            for (e.completions.items) |c| c.on_complete(c.ctx, false);
            e.completions.deinit(self.allocator);
        }
        self.in_flight_count = 0;
        for (0..self.pending_count) |i| {
            const c = self.pending[i];
            c.on_complete(c.ctx, false);
        }
        self.pending_count = 0;
        self.pending_body_bytes = 0;
        self.pending_mut_count = 0;
    }

    /// On leader step-down, fail ONLY the not-yet-flushed pending proposals:
    /// they never reached any log, the follower gate blocks re-flushing
    /// them, and their mutations are already in local KV — genuinely
    /// divergent, so their tokens must fail (fail-stop downstream).
    ///
    /// In-flight entries are deliberately KEPT: each is in OUR log and was
    /// possibly delivered to followers, so its fate is decided by the log,
    /// not by our role. It either commits later — possibly under a NEW
    /// leader that inherited it, still carrying our (index, term), which
    /// completeCommitted resolves as success — or is truncated/overwritten,
    /// which failDiscarded / completeCommitted's term check resolves as
    /// failure. Failing it at step-down would be term-blind the other way:
    /// a false divergence fail-stop for a write the cluster DID accept.
    pub fn failPending(self: *Batcher) void {
        for (0..self.pending_count) |i| {
            const c = self.pending[i];
            c.on_complete(c.ctx, false);
        }
        self.pending_count = 0;
        self.pending_body_bytes = 0;
        self.pending_mut_count = 0;
    }

    /// Fail and remove every in-flight entry `discarded_fn` reports as no
    /// longer held by the log at its (index, term) — i.e. truncated by a
    /// new leader, with or without a replacement entry at that index. The
    /// runtime calls this after inbound processing on non-leaders so a
    /// discarded write fails promptly even if the cluster never commits
    /// anything at that index again.
    pub fn failDiscarded(
        self: *Batcher,
        ctx: *anyopaque,
        discarded_fn: *const fn (ctx: *anyopaque, entry_index: u64, entry_term: u64) bool,
    ) void {
        var write: usize = 0;
        for (0..self.in_flight_count) |i| {
            const entry = &self.in_flight[i];
            if (discarded_fn(ctx, entry.entry_index, entry.entry_term)) {
                for (entry.completions.items) |c| c.on_complete(c.ctx, false);
                entry.completions.deinit(self.allocator);
            } else {
                if (write != i) self.in_flight[write] = entry.*;
                write += 1;
            }
        }
        self.in_flight_count = write;
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
    term: u64 = 1,
    last_payload: []u8 = &.{},
    allocator: std.mem.Allocator,

    fn propose(ctx: *anyopaque, payload: []const u8, now: i64) BatcherError!ProposedEntry {
        _ = now;
        const self: *TestProposer = @ptrCast(@alignCast(ctx));
        if (self.last_payload.len > 0) self.allocator.free(self.last_payload);
        self.last_payload = self.allocator.dupe(u8, payload) catch return BatcherError.OutOfMemory;
        const idx = self.next_index;
        self.next_index += 1;
        return .{ .index = idx, .term = self.term };
    }
    fn deinit(self: *TestProposer) void {
        if (self.last_payload.len > 0) self.allocator.free(self.last_payload);
    }
};

test "batcher: enqueue + flush + commit fires completion" {
    var b = try Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();

    const muts = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
    try b.enqueue(&muts, counter.completion(), false);
    try testing.expectEqual(@as(usize, 1), b.pendingCount());
    try b.flush(@ptrCast(&proposer), TestProposer.propose, 0);
    try testing.expectEqual(@as(usize, 0), b.pendingCount());
    try testing.expectEqual(@as(usize, 1), b.inFlightCount());
    try testing.expectEqual(@as(usize, 0), counter.successes);

    b.completeCommitted(1, 1);
    try testing.expectEqual(@as(usize, 1), counter.successes);
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}

test "batcher: multiple enqueues flush as one entry" {
    var b = try Batcher.init(testing.allocator);
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
    try b.flush(@ptrCast(&proposer), TestProposer.propose, 0);
    try testing.expectEqual(@as(u64, 2), proposer.next_index); // proposed once

    // Decode payload — should contain three set mutations in order.
    const decoded = try oplog.decodeMutations(testing.allocator, proposer.last_payload);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 3), decoded.len);
    try testing.expectEqualStrings("a", decoded[0].key);
    try testing.expectEqualStrings("c", decoded[2].key);

    b.completeCommitted(1, 1);
    try testing.expectEqual(@as(usize, 1), c1.successes);
    try testing.expectEqual(@as(usize, 1), c2.successes);
    try testing.expectEqual(@as(usize, 1), c3.successes);
}

test "batcher: enqueue copies mutation bytes (caller slices may die)" {
    var b = try Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();

    var key_buf: [4]u8 = undefined;
    var val_buf: [4]u8 = undefined;
    @memcpy(key_buf[0..3], "abc");
    @memcpy(val_buf[0..3], "xyz");
    const muts = [_]Mutation{.{ .op = .set, .key = key_buf[0..3], .value = val_buf[0..3] }};
    try b.enqueue(&muts, counter.completion(), false);
    // Stomp the caller buffers BEFORE flush — a batcher that retained the
    // caller's slices (the old use-after-free) would propose the stomped
    // bytes into the replicated log.
    @memset(&key_buf, 0xAA);
    @memset(&val_buf, 0xBB);
    try b.flush(@ptrCast(&proposer), TestProposer.propose, 0);
    const decoded = try oplog.decodeMutations(testing.allocator, proposer.last_payload);
    defer testing.allocator.free(decoded);
    try testing.expectEqual(@as(usize, 1), decoded.len);
    try testing.expectEqualStrings("abc", decoded[0].key);
    try testing.expectEqualStrings("xyz", decoded[0].value);
    b.completeCommitted(1, 1);
}

test "batcher: flush no-op on empty pending" {
    var b = try Batcher.init(testing.allocator);
    defer b.deinit();
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    try b.flush(@ptrCast(&proposer), TestProposer.propose, 0);
    try testing.expectEqual(@as(u64, 1), proposer.next_index); // unchanged
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}

test "batcher: coalescing capped at max_entry_bytes" {
    var b = try Batcher.init(testing.allocator);
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
    var b = try Batcher.init(testing.allocator);
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
    var b = try Batcher.init(testing.allocator);
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
    try b.flush(@ptrCast(&proposer), TestProposer.propose, 0);

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
    var b = try Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    const m = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
    try b.enqueue(&m, counter.completion(), false);
    try b.flush(@ptrCast(&proposer), TestProposer.propose, 0);
    // Pending again before commit.
    try b.enqueue(&m, counter.completion(), false);
    b.failAll();
    try testing.expectEqual(@as(usize, 2), counter.failures);
    try testing.expectEqual(@as(usize, 0), b.pendingCount());
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}

test "batcher: step-down fails only pending; in-flight resolves by log fate" {
    var batcher = try Batcher.init(testing.allocator);
    defer batcher.deinit();
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    var survives = TestCounter{};
    var truncated = TestCounter{};
    var pending = TestCounter{};
    const mutation = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};

    try batcher.enqueue(&mutation, survives.completion(), true);
    try batcher.flush(@ptrCast(&proposer), TestProposer.propose, 0); // index 1
    try batcher.enqueue(&mutation, truncated.completion(), true);
    try batcher.flush(@ptrCast(&proposer), TestProposer.propose, 0); // index 2
    try batcher.enqueue(&mutation, pending.completion(), true);

    // Step-down: only the unflushed proposal fails — both logged entries
    // are kept, their fate is the log's to decide.
    batcher.failPending();
    try testing.expectEqual(@as(usize, 1), pending.failures);
    try testing.expectEqual(@as(usize, 0), survives.successes + survives.failures);
    try testing.expectEqual(@as(usize, 0), truncated.successes + truncated.failures);
    try testing.expectEqual(@as(usize, 2), batcher.inFlightCount());

    // The new leader inherited entry 1 (same term at index 1) but truncated
    // entry 2. Reconciliation fails the truncated one...
    const Pred = struct {
        fn discarded(ctx: *anyopaque, entry_index: u64, entry_term: u64) bool {
            _ = ctx;
            _ = entry_term;
            return entry_index == 2;
        }
    };
    var dummy: u8 = 0;
    batcher.failDiscarded(@ptrCast(&dummy), Pred.discarded);
    try testing.expectEqual(@as(usize, 1), truncated.failures);
    try testing.expectEqual(@as(usize, 1), batcher.inFlightCount());

    // ...and the surviving entry completes as success when it commits under
    // its original (index, term) — even though we are no longer the leader.
    batcher.completeCommitted(1, 1);
    try testing.expectEqual(@as(usize, 1), survives.successes);
    try testing.expectEqual(@as(usize, 0), batcher.inFlightCount());
}

test "batcher: completion only fires for committed entries" {
    var b = try Batcher.init(testing.allocator);
    defer b.deinit();
    var c1 = TestCounter{};
    var c2 = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    const m = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};

    try b.enqueue(&m, c1.completion(), false);
    try b.flush(@ptrCast(&proposer), TestProposer.propose, 0); // index 1
    try b.enqueue(&m, c2.completion(), false);
    try b.flush(@ptrCast(&proposer), TestProposer.propose, 0); // index 2

    b.completeCommitted(1, 1);
    try testing.expectEqual(@as(usize, 1), c1.successes);
    try testing.expectEqual(@as(usize, 0), c2.successes);
    try testing.expectEqual(@as(usize, 1), b.inFlightCount());

    b.completeCommitted(2, 1);
    try testing.expectEqual(@as(usize, 1), c2.successes);
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}

test "batcher: term mismatch at commit fails the completion (truncated entry)" {
    var b = try Batcher.init(testing.allocator);
    defer b.deinit();
    var counter = TestCounter{};
    var proposer = TestProposer{ .allocator = testing.allocator };
    defer proposer.deinit();
    const m = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};

    // Proposed under term 1, locally applied (the pipeline's contract).
    try b.enqueue(&m, counter.completion(), true);
    try b.flush(@ptrCast(&proposer), TestProposer.propose, 0); // index 1, term 1
    try testing.expect(b.isLocallyApplied(1, 1));

    // A new leader (term 2) truncated our entry and committed its OWN
    // entry at index 1. That entry is NOT locally applied here — it must
    // take the full apply path — and our completion must FAIL, not report
    // a discarded write as durable.
    try testing.expect(!b.isLocallyApplied(1, 2));
    b.completeCommitted(1, 2);
    try testing.expectEqual(@as(usize, 0), counter.successes);
    try testing.expectEqual(@as(usize, 1), counter.failures);
    try testing.expectEqual(@as(usize, 0), b.inFlightCount());
}
