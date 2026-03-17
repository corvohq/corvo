//! Fetch handler — claims pending jobs for workers.
//! Ported from Go internal/ops/ops_fetch.go.
//!
//! Uses the in-memory PendingIndex for O(log n) job lookup instead of
//! O(n) B+ tree iterator scan. Stale entries (from cancel/delete) are
//! lazily validated: pop, check state, skip if not pending.

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;
const pending_index_mod = @import("pending_index.zig");

pub fn applyFetch(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.FetchOp) ops.OpResult {
    if (op.count == 0) return .{ .err = "invalid fetch count: 0" };

    const lease_duration_ms: u32 = if (op.lease_duration_ms == 0) 60_000 else op.lease_duration_ms;
    const lease_expires_ns = op.now_ns + @as(u64, lease_duration_ms) * 1_000_000;
    const max_fetch: u32 = @min(op.count, ops.OpResult.max_inline_fetch);

    var result: ops.OpResult = .{};

    for (op.queues) |queue_name| {
        if (result.affected >= max_fetch) break;

        // Load queue config (cached in-memory, avoids KV read on hot path)
        const queue = self.getQueueConfig(b, queue_name) orelse continue;
        if (queue.paused) continue;

        // Check concurrency limit
        if (queue.max_concurrency > 0) {
            if (self.getActiveCount(queue.name) >= @as(i32, @intCast(queue.max_concurrency))) continue;
        }

        // Check rate limit
        if (queue.rate_limit > 0 and queue.rate_window_ms > 0) {
            const window_ns = @as(u64, queue.rate_window_ms) * 1_000_000;
            const window_start = if (op.now_ns > window_ns) op.now_ns - window_ns else 0;
            var rl_lower_buf: keys.KeyBuf = undefined;
            var rl_upper_buf: keys.KeyBuf = undefined;
            var rl_iter = b.newIter(
                keys.rateLimitWindowStart(&rl_lower_buf, queue.name, window_start),
                keys.prefixEnd(&rl_upper_buf, keys.rateLimitPrefix(&rl_lower_buf, queue.name)),
            );
            defer rl_iter.close();
            var rate_count: u32 = 0;
            if (rl_iter.first()) {
                rate_count += 1;
                while (rl_iter.next()) rate_count += 1;
            }
            if (rate_count >= queue.rate_limit) continue;
        }

        const has_rl = queue.rate_limit > 0;

        // Fairness path: score candidates by served+active, pick lowest score.
        // Separate from the normal pop loop to avoid any overhead on non-fairness queues.
        if (queue.fairness) {
            var fairness_budget: u32 = (@min(op.count, ops.OpResult.max_inline_fetch) - result.affected) * 2;
            fetchWithFairness(self, b, &result, queue_name, &fairness_budget, max_fetch, lease_expires_ns, lease_duration_ms, op, has_rl);
            continue; // next queue
        }

        // Non-fairness path: pop in priority order (hot path, unchanged).
        const remaining = max_fetch - result.affected;
        var pop_budget: u32 = remaining * 2; // Extra budget for stale entries.
        while (pop_budget > 0 and result.affected < max_fetch) {
            const entry = self.pending.pop(queue_name) orelse break;
            pop_budget -= 1;

            const job_id = entry.jobId();

            // Load job — single KV read. Serves as both validation and data source.
            var jk_buf: keys.KeyBuf = undefined;
            var job_val_buf: [codec.max_job_encoded_size]u8 = undefined;
            const job_bytes = b.getInto(keys.jobKey(&jk_buf, job_id), &job_val_buf);
            if (job_bytes == null) continue; // Deleted — stale entry.

            var job = codec.decodeJob(job_bytes.?);
            if (job.state != .pending) continue; // No longer pending — stale.

            // Claim the job.
            job.state = .active;
            job.worker_id = op.worker_id;
            job.hostname = op.hostname;
            job.attempt += 1;
            job.started_at_ns = op.now_ns;
            job.lease_expires_at_ns = lease_expires_ns;

            // No p| key delete needed — PendingIndex is the source of truth.
            // p| keys are not written (enqueue uses in-memory index only).

            if (job.expire_after_ms > 0 and job.expire_at_ns > 0) {
                var xk_buf: keys.KeyBuf = undefined;
                b.delete(keys.expireKey(&xk_buf, job.expire_at_ns, job_id));
                job.expire_at_ns = 0;
            }

            var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
            b.set(keys.jobKey(&jk_buf, job_id), codec.encodeJob(&job_enc_buf, &job));

            var ak_buf: keys.KeyBuf = undefined;
            var lease_val: [8]u8 = undefined;
            std.mem.writeInt(u64, &lease_val, lease_expires_ns, .big);
            b.set(OpHandler.jobActiveKey(&ak_buf, &job), &lease_val);

            self.incrActiveCount(queue_name);
            if (job.group) |g| {
                self.incrFairnessActive(queue_name, g);
                self.incrFairnessServed(queue_name, g);
            }

            // Write rate limit entry.
            if (has_rl) {
                var rlk_buf: keys.KeyBuf = undefined;
                b.set(keys.rateLimitKey(&rlk_buf, queue_name, op.now_ns, op.random_seed +% @as(u32, @intCast(result.affected))), "");
            }

            self.verifyJobIndexes(b, &job, "fetch");

            // Store fetch result inline (no allocation).
            var f = &result.fetched[result.affected];
            const il = @min(job_id.len, f.id_buf.len);
            @memcpy(f.id_buf[0..il], job_id[0..il]);
            f.id_len = @intCast(il);
            const ql = @min(queue_name.len, f.queue_buf.len);
            @memcpy(f.queue_buf[0..ql], queue_name[0..ql]);
            f.queue_len = @intCast(ql);
            f.attempt = job.attempt;
            f.max_retries = job.max_retries;
            f.lease_duration_ms = lease_duration_ms;
            result.affected += 1;
        }
    }

    // Register worker if we fetched anything
    if (result.affected > 0 and op.worker_id.len > 0) {
        var w = types.Worker{
            .id = op.worker_id,
            .last_heartbeat_ns = op.now_ns,
            .started_at_ns = op.now_ns,
        };
        if (op.hostname.len > 0) w.hostname = op.hostname;

        var wk_buf: keys.KeyBuf = undefined;
        var w_enc_buf: [codec.max_worker_encoded_size]u8 = undefined;
        b.set(keys.workerKey(&wk_buf, op.worker_id), codec.encodeWorker(&w_enc_buf, &w));
    }

    return result;
}

/// Fairness fetch: pop candidates, score by `served + active` per group,
/// select the candidate with the lowest score. Re-push the rest.
/// Only called when `queue.fairness == true`. Keeps the non-fairness hot path untouched.
fn fetchWithFairness(
    self: *OpHandler,
    b: *kv.WriteBatch,
    result: *ops.OpResult,
    queue_name: []const u8,
    pop_budget: *u32,
    max_fetch: u32,
    lease_expires_ns: u64,
    lease_duration_ms: u32,
    op: *const ops.FetchOp,
    has_rl: bool,
) void {
    const max_candidates: u32 = 16;

    while (pop_budget.* > 0 and result.affected < max_fetch) {
        // Collect validated candidates with their group info.
        var candidates: [16]pending_index_mod.PendingEntry = undefined;
        var candidate_group_bufs: [16][64]u8 = undefined;
        var candidate_group_lens: [16]u8 = undefined;
        var num_candidates: u32 = 0;

        var pops: u32 = 0;
        while (pops < max_candidates and pop_budget.* > 0) {
            const entry = self.pending.pop(queue_name) orelse break;
            pop_budget.* -= 1;
            pops += 1;

            // Validate — single KV read per candidate.
            var jk_buf: keys.KeyBuf = undefined;
            var job_val_buf: [codec.max_job_encoded_size]u8 = undefined;
            const job_bytes = b.getInto(keys.jobKey(&jk_buf, entry.jobId()), &job_val_buf);
            if (job_bytes == null) continue;
            const job = codec.decodeJob(job_bytes.?);
            if (job.state != .pending) continue;

            candidates[num_candidates] = entry;
            if (job.group) |g| {
                const gl: u8 = @intCast(@min(g.len, 64));
                @memcpy(candidate_group_bufs[num_candidates][0..gl], g[0..gl]);
                candidate_group_lens[num_candidates] = gl;
            } else {
                candidate_group_lens[num_candidates] = 0;
            }
            num_candidates += 1;
        }

        if (num_candidates == 0) break;

        // Score: lowest served + active wins.
        var best_idx: u32 = 0;
        var best_score: i64 = std.math.maxInt(i64);
        for (0..num_candidates) |i| {
            const group = candidate_group_bufs[i][0..candidate_group_lens[i]];
            var score: i64 = 0;
            if (group.len > 0) {
                if (self.fairness_served.get(queue_name)) |qmap| {
                    score += qmap.get(group) orelse 0;
                }
                if (self.fairness_active.get(queue_name)) |qmap| {
                    score += qmap.get(group) orelse 0;
                }
            }
            if (score < best_score) {
                best_score = score;
                best_idx = @intCast(i);
            }
        }

        // Re-push non-selected candidates.
        for (0..num_candidates) |i| {
            if (i != best_idx) {
                const c = &candidates[i];
                self.pending.push(queue_name, 255 - c.inv_priority, c.created_ns, c.jobId());
            }
        }

        // Claim the selected candidate. Re-read from KV (one extra overlay read).
        const sel_job_id = candidates[best_idx].jobId();
        var jk_buf: keys.KeyBuf = undefined;
        var job_val_buf: [codec.max_job_encoded_size]u8 = undefined;
        const job_bytes = b.getInto(keys.jobKey(&jk_buf, sel_job_id), &job_val_buf);
        assert.check(job_bytes != null, "fairness: validated job disappeared", .{});
        var job = codec.decodeJob(job_bytes.?);

        job.state = .active;
        job.worker_id = op.worker_id;
        job.hostname = op.hostname;
        job.attempt += 1;
        job.started_at_ns = op.now_ns;
        job.lease_expires_at_ns = lease_expires_ns;

        if (job.expire_after_ms > 0 and job.expire_at_ns > 0) {
            var xk_buf: keys.KeyBuf = undefined;
            b.delete(keys.expireKey(&xk_buf, job.expire_at_ns, sel_job_id));
            job.expire_at_ns = 0;
        }

        var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
        b.set(keys.jobKey(&jk_buf, sel_job_id), codec.encodeJob(&job_enc_buf, &job));

        var ak_buf: keys.KeyBuf = undefined;
        var lease_val: [8]u8 = undefined;
        std.mem.writeInt(u64, &lease_val, lease_expires_ns, .big);
        b.set(OpHandler.jobActiveKey(&ak_buf, &job), &lease_val);

        self.incrActiveCount(queue_name);
        if (job.group) |g| {
            self.incrFairnessActive(queue_name, g);
            self.incrFairnessServed(queue_name, g);
        }

        if (has_rl) {
            var rlk_buf: keys.KeyBuf = undefined;
            b.set(keys.rateLimitKey(&rlk_buf, queue_name, op.now_ns, op.random_seed +% @as(u32, @intCast(result.affected))), "");
        }

        self.verifyJobIndexes(b, &job, "fetch-fairness");

        var f = &result.fetched[result.affected];
        const il = @min(sel_job_id.len, f.id_buf.len);
        @memcpy(f.id_buf[0..il], sel_job_id[0..il]);
        f.id_len = @intCast(il);
        const ql = @min(queue_name.len, f.queue_buf.len);
        @memcpy(f.queue_buf[0..ql], queue_name[0..ql]);
        f.queue_len = @intCast(ql);
        f.attempt = job.attempt;
        f.max_retries = job.max_retries;
        f.lease_duration_ms = lease_duration_ms;
        result.affected += 1;
    }
}
