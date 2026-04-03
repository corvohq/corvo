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

pub const Indexer = struct {
    effects: [max_effects]IndexEffect = undefined,
    effect_count: u32 = 0,

    // Queue counter deltas — accumulated per tick, flushed once per queue.
    // Keyed by queue name (inline buffer). Bounded to max_queues.
    counter_deltas: [max_counter_deltas]CounterDelta = undefined,
    counter_delta_count: u32 = 0,

    const max_effects: u32 = 8192;
    const max_counter_deltas: u32 = 128;

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

    // ====================================================================
    // Record methods — called by hot-path handlers
    // ====================================================================

    pub fn recordCreate(self: *Indexer, job_id: []const u8, queue: []const u8, state: types.JobState, created_at_ns: u64) void {
        const e = self.addEffect() orelse return;
        e.kind = .create;
        self.copyId(e, job_id, queue);
        e.new_state = state;
        e.created_at_ns = created_at_ns;

        self.addCounterDelta(queue, state, 1);
    }

    pub fn recordTransition(self: *Indexer, job_id: []const u8, queue: []const u8, old_state: types.JobState, new_state: types.JobState, created_at_ns: u64) void {
        const e = self.addEffect() orelse return;
        e.kind = .transition;
        self.copyId(e, job_id, queue);
        e.old_state = old_state;
        e.new_state = new_state;
        e.created_at_ns = created_at_ns;

        self.addCounterDelta(queue, old_state, -1);
        self.addCounterDelta(queue, new_state, 1);
    }

    pub fn recordDeleteAll(self: *Indexer, job_id: []const u8, queue: []const u8, old_state: types.JobState, created_at_ns: u64) void {
        const e = self.addEffect() orelse return;
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
        const new_byte = @intFromEnum(e.new_state);

        var old_js_buf: keys.KeyBuf = undefined;
        var old_jqs_buf: keys.KeyBuf = undefined;
        b.delete(keys.jobStateKey(&old_js_buf, old_byte, e.created_at_ns, job_id));
        b.delete(keys.jobQueueStateKey(&old_jqs_buf, queue, old_byte, e.created_at_ns, job_id));

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

    fn addEffect(self: *Indexer) ?*IndexEffect {
        if (self.effect_count >= max_effects) return null;
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
        // New queue — add entry.
        if (self.counter_delta_count >= max_counter_deltas) return;
        var cd = &self.counter_deltas[self.counter_delta_count];
        cd.* = .{};
        const q_len: u8 = @intCast(@min(queue.len, 64));
        @memcpy(cd.queue_buf[0..q_len], queue[0..q_len]);
        cd.queue_len = q_len;
        cd.deltas[@intFromEnum(state)] = delta;
        self.counter_delta_count += 1;
    }
};
