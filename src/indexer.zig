//! Deferred read-index writer.
//!
//! Hot-path handlers (enqueue, fetch, ack, fail) record index effects
//! instead of writing read indexes inline. Pipeline flushes effects
//! into a separate KV batch after the main batch commits.
//!
//! Read indexes (js|, jqs|, jt|, jq|, tq|) are ONLY used by the read
//! path (HTTP/API queries). The write path uses PendingIndex (in-memory)
//! and active keys (a|) directly. Deferring index writes removes them
//! from the hot-path batch, eliminating O(n) overlay growth per op.

const std = @import("std");
const types = @import("types.zig");
const keys = @import("keys.zig");
const kv = @import("kv.zig");
const codec = @import("codec.zig");
const assert = @import("assert.zig");
const rpc = @import("rpc.zig");
const handler = @import("handler.zig");

pub const Indexer = struct {
    effects: [max_effects]IndexEffect = undefined,
    effect_count: u32 = 0,

    // Queue counter deltas — accumulated per tick, flushed once per queue.
    // Keyed by queue name (inline buffer). Bounded to max_queues.
    counter_deltas: [max_counter_deltas]CounterDelta = undefined,
    counter_delta_count: u32 = 0,

    /// Buffer sizes are derived from the per-op ceilings below: each buffer
    /// holds one worst-case op (the nearFull() reservation) plus batching
    /// headroom, so an op arriving right at the flush threshold provably fits.
    ///   max_effects        = 8192 (per-op) + 8192 (headroom) = 16384
    ///   max_counter_deltas = 8192 (per-op) + 1024 (headroom) =  9216
    const max_effects: u32 = max_effects_per_op + 8192;
    const max_counter_deltas: u32 = max_counter_deltas_per_op + 1024;

    /// Worst-case record* calls a single job can drive on the CLIENT write
    /// path. The largest op is a batch ack/fail (rpc.MAX_BATCH_JOBS jobs); per
    /// job the record* calls are: (1) its own primary transition/delete
    /// (recordTransition/recordDeleteAll), (2) a chain-advance enqueue
    /// (handler_ack.advanceChain / handler_fail.fireChainOnFailure →
    /// applyEnqueue → recordCreate), and (3) a batch-completion callback
    /// enqueue (handler.handleBatchJobComplete → applyEnqueue → recordCreate).
    /// The callback job carries no batch_id and no active state, so it never
    /// recurses. Three is the ceiling.
    const records_per_job: u32 = 3;

    /// Worst-case record* calls per job processed by ONE maintenance apply.
    /// Maintenance writes its own read indexes inline (transitionReadIndexes /
    /// deleteReadIndexes go straight to the batch), so its indexer effects
    /// come only from the enqueues it triggers: reclaiming a job to dead can
    /// fire (1) a batch-completion callback enqueue (handleBatchJobComplete →
    /// enqueueBatchCallback → applyEnqueue → recordCreate) and (2) a chain
    /// on_failure enqueue (fireChainOnFailure → applyEnqueue → recordCreate).
    /// Expire fires only (1); promote/purge fire none; cron enqueues ≤64 per
    /// scan (handler_cron.max_fire_per_scan). Two is the ceiling.
    const records_per_maintenance_job: u32 = 2;

    /// Max effects a single op (one pipeline frame / maintenance action /
    /// fetch) can buffer before the pipeline's next nearFull() check — the
    /// pipeline flushes only BETWEEN ops/actions, never inside one. Every
    /// record* call emits exactly one effect. Candidates:
    ///   batch ack/fail:  records_per_job × MAX_BATCH_JOBS = 3 × 256   =  768
    ///   one maintenance apply (reclaim is the worst): up to
    ///   max_bulk_results jobs per apply (bulk_result_count cap) ×
    ///   records_per_maintenance_job                   = 2 × 4096      = 8192
    ///   fetch: ≤ ops.OpResult.max_inline_fetch (128) transitions      =  128
    /// The maintenance ceiling dominates.
    const max_effects_per_op: u32 = @max(
        rpc.MAX_BATCH_JOBS * records_per_job,
        handler.OpHandler.max_bulk_results * records_per_maintenance_job,
    );

    /// Max distinct-queue counter-delta slots a single op can consume. Each
    /// record* call touches exactly one queue and a new slot is used only for a
    /// queue not yet seen this tick, so the distinct queues one op introduces
    /// can never exceed its effect count — same worst case, independent of
    /// max_queues (the effect count, not the queue population, is the binding
    /// bound because both chain and callback enqueues route through record*).
    const max_counter_deltas_per_op: u32 = max_effects_per_op;

    comptime {
        // The pipeline flushes at nearFull() *between* ops, so one op's records
        // must fit in the free tail of each buffer or addEffect/addCounterDelta
        // would assert-overflow (M10). These caps are the headroom nearFull()
        // reserves; they must not exceed the buffers themselves.
        std.debug.assert(max_effects_per_op <= max_effects);
        std.debug.assert(max_counter_deltas_per_op <= max_counter_deltas);
    }

    pub const IndexEffect = struct {
        kind: Kind,
        job_id_buf: [64]u8 = undefined,
        job_id_len: u8 = 0,
        queue_buf: [64]u8 = undefined,
        queue_len: u8 = 0,
        created_at_ns: u64 = 0,
        old_state: types.JobState = .pending,
        new_state: types.JobState = .pending,

        const Kind = enum {
            /// New job: write jt|, jq|, js|, jqs|, tags.
            create,
            /// State change: delete old js|/jqs|, write new js|/jqs|.
            transition,
            /// Auto-delete: delete all read indexes (jt|, jq|, js|, jqs|, tags).
            delete_all,
        };

        fn jobId(self: *const IndexEffect) []const u8 {
            return self.job_id_buf[0..self.job_id_len];
        }
        fn queue(self: *const IndexEffect) []const u8 {
            return self.queue_buf[0..self.queue_len];
        }
    };

    const CounterDelta = struct {
        queue_buf: [64]u8 = undefined,
        queue_len: u8 = 0,
        // Per-state deltas: positive = increment, negative = decrement.
        deltas: [state_count]i32 = [_]i32{0} ** state_count,

        const state_count = @typeInfo(types.JobState).@"enum".fields.len;

        fn queueSlice(self: *const CounterDelta) []const u8 {
            return self.queue_buf[0..self.queue_len];
        }
    };

    pub fn reset(self: *Indexer) void {
        self.effect_count = 0;
        self.counter_delta_count = 0;
    }

    /// True once either buffer has fewer than one op's worth of free slots.
    /// The pipeline flushes on this signal *between* ops so the next op's
    /// records always fit — addEffect/addCounterDelta never drop, so js|/jqs|
    /// transitions and qc| counter deltas can never silently diverge (M10).
    pub fn nearFull(self: *const Indexer) bool {
        return self.effect_count + max_effects_per_op > max_effects or
            self.counter_delta_count + max_counter_deltas_per_op > max_counter_deltas;
    }

    // ====================================================================
    // Record methods — called by hot-path handlers
    // ====================================================================

    pub fn recordCreate(self: *Indexer, job_id: []const u8, queue: []const u8, state: types.JobState, created_at_ns: u64) void {
        const e = self.addEffect();
        e.kind = .create;
        self.copyId(e, job_id, queue);
        e.new_state = state;
        e.created_at_ns = created_at_ns;

        self.addCounterDelta(queue, state, 1);
    }

    pub fn recordTransition(self: *Indexer, job_id: []const u8, queue: []const u8, old_state: types.JobState, new_state: types.JobState, created_at_ns: u64) void {
        const e = self.addEffect();
        e.kind = .transition;
        self.copyId(e, job_id, queue);
        e.old_state = old_state;
        e.new_state = new_state;
        e.created_at_ns = created_at_ns;

        self.addCounterDelta(queue, old_state, -1);
        self.addCounterDelta(queue, new_state, 1);
    }

    pub fn recordDeleteAll(self: *Indexer, job_id: []const u8, queue: []const u8, old_state: types.JobState, created_at_ns: u64) void {
        const e = self.addEffect();
        e.kind = .delete_all;
        self.copyId(e, job_id, queue);
        e.old_state = old_state;
        e.created_at_ns = created_at_ns;

        self.addCounterDelta(queue, old_state, -1);
    }

    // ====================================================================
    // Flush — write all deferred indexes in a separate KV batch
    // ====================================================================

    /// Flush deferred indexes into an existing batch (same batch as the
    /// main pipeline commit). Called AFTER all handler.apply reads are done
    /// so index writes don't pollute the batch overlay during reads.
    /// The batch is committed by the caller (pipeline).
    pub fn flush(self: *Indexer, batch: *kv.WriteBatch) void {
        if (self.effect_count == 0 and self.counter_delta_count == 0) return;

        for (self.effects[0..self.effect_count]) |*e| {
            switch (e.kind) {
                .create => self.flushCreate(batch, e),
                .transition => self.flushTransition(batch, e),
                .delete_all => self.flushDeleteAll(batch, e),
            }
        }

        self.flushCounterDeltas(batch);
        self.effect_count = 0;
        self.counter_delta_count = 0;
    }


    fn flushCreate(_: *const Indexer, b: *kv.WriteBatch, e: *const IndexEffect) void {
        const job_id = e.jobId();
        const queue = e.queue();

        // Skip if job was deleted in the same batch (clear/delete queue).
        var jk_check: keys.KeyBuf = undefined;
        if (b.get(keys.jobKey(&jk_check, job_id)) == null) return;

        const state_byte = @intFromEnum(e.new_state);

        var jt_buf: keys.KeyBuf = undefined;
        var jq_buf: keys.KeyBuf = undefined;
        var js_buf: keys.KeyBuf = undefined;
        var jqs_buf: keys.KeyBuf = undefined;

        b.set(keys.jobTimeKey(&jt_buf, e.created_at_ns, job_id), "");
        b.set(keys.jobQueueKey(&jq_buf, queue, e.created_at_ns, job_id), "");
        b.set(keys.jobStateKey(&js_buf, state_byte, e.created_at_ns, job_id), "");
        b.set(keys.jobQueueStateKey(&jqs_buf, queue, state_byte, e.created_at_ns, job_id), "");

        // Write tag indexes — job header is in the same batch (not yet committed).
        writeTagIndexesFromBatch(b, job_id, queue);
    }

    fn flushTransition(_: *const Indexer, b: *kv.WriteBatch, e: *const IndexEffect) void {
        const job_id = e.jobId();
        const queue = e.queue();
        const old_byte = @intFromEnum(e.old_state);

        // Always delete old state indexes (cleanup even if job was deleted).
        var old_js_buf: keys.KeyBuf = undefined;
        var old_jqs_buf: keys.KeyBuf = undefined;
        b.delete(keys.jobStateKey(&old_js_buf, old_byte, e.created_at_ns, job_id));
        b.delete(keys.jobQueueStateKey(&old_jqs_buf, queue, old_byte, e.created_at_ns, job_id));

        // Skip writing new state indexes if job was deleted in the same batch.
        var jk_check: keys.KeyBuf = undefined;
        if (b.get(keys.jobKey(&jk_check, job_id)) == null) return;

        const new_byte = @intFromEnum(e.new_state);
        var new_js_buf: keys.KeyBuf = undefined;
        var new_jqs_buf: keys.KeyBuf = undefined;
        b.set(keys.jobStateKey(&new_js_buf, new_byte, e.created_at_ns, job_id), "");
        b.set(keys.jobQueueStateKey(&new_jqs_buf, queue, new_byte, e.created_at_ns, job_id), "");
    }

    fn flushDeleteAll(_: *const Indexer, b: *kv.WriteBatch, e: *const IndexEffect) void {
        const job_id = e.jobId();
        const queue = e.queue();
        const state_byte = @intFromEnum(e.old_state);

        var jt_buf: keys.KeyBuf = undefined;
        var jq_buf: keys.KeyBuf = undefined;
        var js_buf: keys.KeyBuf = undefined;
        var jqs_buf: keys.KeyBuf = undefined;

        b.delete(keys.jobTimeKey(&jt_buf, e.created_at_ns, job_id));
        b.delete(keys.jobQueueKey(&jq_buf, queue, e.created_at_ns, job_id));
        b.delete(keys.jobStateKey(&js_buf, state_byte, e.created_at_ns, job_id));
        b.delete(keys.jobQueueStateKey(&jqs_buf, queue, state_byte, e.created_at_ns, job_id));

        // Delete tag indexes — job was deleted in same batch, read from batch overlay.
        deleteTagIndexesFromBatch(b, job_id, queue);
    }

    fn flushCounterDeltas(self: *Indexer, b: *kv.WriteBatch) void {
        for (self.counter_deltas[0..self.counter_delta_count]) |*cd| {
            const queue = cd.queueSlice();
            var qc_buf: keys.KeyBuf = undefined;
            var qc_val_buf: [codec.max_queue_encoded_size]u8 = undefined;
            const qc_key = keys.queueConfigKey(&qc_buf, queue);
            const qc_bytes = b.getInto(qc_key, &qc_val_buf) orelse continue;
            var q = codec.decodeQueue(qc_bytes);

            for (cd.deltas, 0..) |delta, si| {
                if (delta == 0) continue;
                const state: types.JobState = @enumFromInt(si);
                if (delta > 0) {
                    var d: u32 = @intCast(delta);
                    while (d > 0) : (d -= 1) q.incrState(state);
                } else {
                    var d: u32 = @intCast(-delta);
                    while (d > 0) : (d -= 1) q.decrState(state);
                }
            }

            var qc_enc_buf: [codec.max_queue_encoded_size]u8 = undefined;
            b.set(qc_key, codec.encodeQueue(&qc_enc_buf, &q));
        }
    }

    // ====================================================================
    // Tag index helpers — read committed job from KV for tag data
    // ====================================================================

    /// Read job from batch overlay and write tag indexes.
    fn writeTagIndexesFromBatch(b: *kv.WriteBatch, job_id: []const u8, queue: []const u8) void {
        var jk_buf: keys.KeyBuf = undefined;
        var job_val_buf: [codec.max_job_encoded_size]u8 = undefined;
        const job_bytes = b.getInto(keys.jobKey(&jk_buf, job_id), &job_val_buf) orelse return;
        const job = codec.decodeJob(job_bytes);
        const tag_str = job.tags orelse return;
        if (tag_str.len < 2) return;
        writeTagEntries(b, queue, job_id, tag_str);
    }

    fn deleteTagIndexesFromBatch(b: *kv.WriteBatch, job_id: []const u8, queue: []const u8) void {
        var jk_buf: keys.KeyBuf = undefined;
        var job_val_buf: [codec.max_job_encoded_size]u8 = undefined;
        const job_bytes = b.getInto(keys.jobKey(&jk_buf, job_id), &job_val_buf) orelse return;
        const job = codec.decodeJob(job_bytes);
        const tag_str = job.tags orelse return;
        if (tag_str.len < 2) return;
        deleteTagEntries(b, queue, job_id, tag_str);
    }

    fn writeTagEntries(b: *kv.WriteBatch, queue: []const u8, job_id: []const u8, tag_str: []const u8) void {
        var pos: usize = 0;
        while (pos < tag_str.len) {
            const k_start = std.mem.indexOfScalarPos(u8, tag_str, pos, '"') orelse break;
            const k_end = std.mem.indexOfScalarPos(u8, tag_str, k_start + 1, '"') orelse break;
            const tag_key = tag_str[k_start + 1 .. k_end];
            const colon = std.mem.indexOfScalarPos(u8, tag_str, k_end + 1, ':') orelse break;
            const v_start = std.mem.indexOfScalarPos(u8, tag_str, colon + 1, '"') orelse break;
            const v_end = std.mem.indexOfScalarPos(u8, tag_str, v_start + 1, '"') orelse break;
            const tag_value = tag_str[v_start + 1 .. v_end];

            var tq_buf: keys.KeyBuf = undefined;
            b.set(keys.tagQueueKey(&tq_buf, queue, tag_key, tag_value, job_id), "");
            pos = v_end + 1;
        }
    }

    fn deleteTagEntries(b: *kv.WriteBatch, queue: []const u8, job_id: []const u8, tag_str: []const u8) void {
        var pos: usize = 0;
        while (pos < tag_str.len) {
            const k_start = std.mem.indexOfScalarPos(u8, tag_str, pos, '"') orelse break;
            const k_end = std.mem.indexOfScalarPos(u8, tag_str, k_start + 1, '"') orelse break;
            const tag_key = tag_str[k_start + 1 .. k_end];
            const colon = std.mem.indexOfScalarPos(u8, tag_str, k_end + 1, ':') orelse break;
            const v_start = std.mem.indexOfScalarPos(u8, tag_str, colon + 1, '"') orelse break;
            const v_end = std.mem.indexOfScalarPos(u8, tag_str, v_start + 1, '"') orelse break;
            const tag_value = tag_str[v_start + 1 .. v_end];

            var tq_buf: keys.KeyBuf = undefined;
            b.delete(keys.tagQueueKey(&tq_buf, queue, tag_key, tag_value, job_id));
            pos = v_end + 1;
        }
    }

    // ====================================================================
    // Internal helpers
    // ====================================================================

    fn addEffect(self: *Indexer) *IndexEffect {
        // Never silently drops: the pipeline flushes between ops when nearFull()
        // so there is always room for the current op's effects (M10). Reaching
        // this assert means a caller accumulated a full op's worth of effects
        // without giving the pipeline a flush point.
        assert.check(self.effect_count < max_effects, "indexer: effect buffer overflow ({d}) — pipeline must flush at nearFull()", .{self.effect_count});
        const e = &self.effects[self.effect_count];
        self.effect_count += 1;
        return e;
    }

    fn copyId(_: *const Indexer, e: *IndexEffect, job_id: []const u8, queue: []const u8) void {
        const id_len: u8 = @intCast(@min(job_id.len, 64));
        @memcpy(e.job_id_buf[0..id_len], job_id[0..id_len]);
        e.job_id_len = id_len;
        const q_len: u8 = @intCast(@min(queue.len, 64));
        @memcpy(e.queue_buf[0..q_len], queue[0..q_len]);
        e.queue_len = q_len;
    }

    fn addCounterDelta(self: *Indexer, queue: []const u8, state: types.JobState, delta: i32) void {
        // Find existing delta for this queue.
        for (self.counter_deltas[0..self.counter_delta_count]) |*cd| {
            if (cd.queue_len == queue.len and
                std.mem.eql(u8, cd.queueSlice(), queue))
            {
                cd.deltas[@intFromEnum(state)] += delta;
                return;
            }
        }
        // New queue — add entry. Never silently drops (see addEffect): the
        // pipeline flushes between ops when nearFull() so there is always room.
        assert.check(self.counter_delta_count < max_counter_deltas, "indexer: counter-delta buffer overflow ({d}) — pipeline must flush at nearFull()", .{self.counter_delta_count});
        var cd = &self.counter_deltas[self.counter_delta_count];
        cd.* = .{};
        const q_len: u8 = @intCast(@min(queue.len, 64));
        @memcpy(cd.queue_buf[0..q_len], queue[0..q_len]);
        cd.queue_len = q_len;
        cd.deltas[@intFromEnum(state)] = delta;
        self.counter_delta_count += 1;
    }

    /// Discard this tick's accumulated counter deltas for `queue` in the given
    /// states. clear-queue calls this after zeroing the qc| counters so the
    /// pre-clear enqueue deltas (for jobs the clear just deleted) don't get
    /// re-applied on top of the zeroed counter when flushed (M11). Post-clear
    /// ops re-accumulate their own deltas normally.
    pub fn resetQueueStateDeltas(self: *Indexer, queue: []const u8, states: []const types.JobState) void {
        for (self.counter_deltas[0..self.counter_delta_count]) |*cd| {
            if (cd.queue_len == queue.len and std.mem.eql(u8, cd.queueSlice(), queue)) {
                for (states) |s| cd.deltas[@intFromEnum(s)] = 0;
                return;
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "nearFull reserves exactly one op's headroom, not the whole buffer (M10)" {
    const testing = std.testing;
    const idx = try testing.allocator.create(Indexer);
    defer testing.allocator.destroy(idx);
    idx.* = .{};
    idx.reset();

    try testing.expect(!idx.nearFull());

    // Dozens of ops' worth of buffered effects and deltas must NOT trip
    // nearFull — batching only pays off if a tick accumulates far more than one
    // op before flushing. The prior bug reserved the entire counter buffer as
    // headroom, so a single buffered delta (every write op emits at least one)
    // tripped nearFull and flushed after essentially every op. These concrete
    // moderate loads (four batch-ack ops' worth of effects — the common hot-path
    // op, not the rare maintenance ceiling that sizes max_effects_per_op) must
    // stay below the threshold regardless of the named caps, so they fail
    // against that buggy nearFull.
    const batch_op_effects = 4 * Indexer.records_per_job * rpc.MAX_BATCH_JOBS; // 3072 ≪ effect cap
    idx.effect_count = batch_op_effects;
    idx.counter_delta_count = 50; // dozens of single-queue ops
    try testing.expect(!idx.nearFull());

    // Effect buffer: false with exactly one op's headroom free, true once fewer
    // than one op's worth of slots remain — so the next op always fits.
    idx.counter_delta_count = 0;
    idx.effect_count = Indexer.max_effects - Indexer.max_effects_per_op;
    try testing.expect(!idx.nearFull());
    idx.effect_count = Indexer.max_effects - Indexer.max_effects_per_op + 1;
    try testing.expect(idx.nearFull());

    // Counter-delta buffer: same one-op headroom. The honest cap puts the
    // threshold a full op below the buffer (1024 free slots), not at 1 delta.
    idx.effect_count = 0;
    idx.counter_delta_count = Indexer.max_counter_deltas - Indexer.max_counter_deltas_per_op;
    try testing.expect(!idx.nearFull());
    idx.counter_delta_count = Indexer.max_counter_deltas - Indexer.max_counter_deltas_per_op + 1;
    try testing.expect(idx.nearFull());
}

test "resetQueueStateDeltas clears only the given states (M11)" {
    const testing = std.testing;
    const idx = try testing.allocator.create(Indexer);
    defer testing.allocator.destroy(idx);
    idx.* = .{};
    idx.reset();

    // Simulate a tick that enqueued pending jobs and moved one to active.
    idx.addCounterDelta("q", .pending, 3);
    idx.addCounterDelta("q", .active, 1);
    idx.addCounterDelta("other", .pending, 5);

    // clear-queue on "q" discards the pending/scheduled/retrying deltas but must
    // leave active (in-flight jobs survive the clear) and "other" untouched.
    idx.resetQueueStateDeltas("q", &.{ .pending, .scheduled, .retrying });

    const q = &idx.counter_deltas[0];
    try testing.expectEqualStrings("q", q.queueSlice());
    try testing.expectEqual(@as(i32, 0), q.deltas[@intFromEnum(types.JobState.pending)]);
    try testing.expectEqual(@as(i32, 1), q.deltas[@intFromEnum(types.JobState.active)]);

    const other = &idx.counter_deltas[1];
    try testing.expectEqualStrings("other", other.queueSlice());
    try testing.expectEqual(@as(i32, 5), other.deltas[@intFromEnum(types.JobState.pending)]);
}
