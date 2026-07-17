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

/// Wire size of one job in the RPC fetch response. MUST match the layout
/// pipeline.encodeFetchResult writes per job, whose actual field sizes are:
///   1+id, 1+queue (both u8-length-prefixed), 2 attempt, 2 max_retries,
///   1 checkpoint-len, 1 tags-len, 4 payload-len (u32), payload bytes,
///   8 lease_token.
/// Fixed overhead = 1+1+2+2+1+1+4+8 = 20 bytes. (The old comment mis-stated
/// 2-byte id/queue prefixes and a 2-byte payload length; the u8 id/queue
/// prefixes offset the u32 payload length exactly, so the total is still 20 —
/// verified against encodeFetchResult, not the stale comment. This estimate is
/// therefore EXACT, so fulfillSubscriptions no longer needs a slack margin.)
pub fn fetchedJobWireSize(id_len: usize, queue_len: usize, payload_len: usize) usize {
    return 20 + id_len + queue_len + payload_len;
}

pub fn applyFetch(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.FetchOp) ops.OpResult {
    if (op.count == 0) return .{ .err = "invalid fetch count: 0" };
    if (op.now_ns == 0) return .{ .err = "invalid fetch timestamp" };
    if (op.worker_id.len > types.max_worker_id_len or
        std.mem.indexOfScalar(u8, op.worker_id, 0) != null)
        return .{ .err = "invalid worker_id" };
    if (op.hostname.len > types.max_hostname_len or
        std.mem.indexOfScalar(u8, op.hostname, 0) != null)
        return .{ .err = "invalid hostname" };
    var worker_queues_len: usize = 0;
    for (op.queues) |queue_name| {
        if (queue_name.len == 0 or queue_name.len > types.max_queue_name_len or
            std.mem.indexOfScalar(u8, queue_name, 0) != null)
            return .{ .err = "invalid fetch queue" };
        worker_queues_len += queue_name.len;
    }
    if (op.queues.len > 0) worker_queues_len += op.queues.len - 1;
    if (op.worker_id.len > 0) {
        const worker_encoded_size = 23 + op.worker_id.len + op.hostname.len + worker_queues_len;
        if (worker_encoded_size > codec.max_worker_encoded_size)
            return .{ .err = "worker metadata too large" };
    }

    const lease_duration_ms: u32 = if (op.lease_duration_ms == 0) 60_000 else op.lease_duration_ms;
    const lease_duration_ns = @as(u64, lease_duration_ms) * 1_000_000;
    if (op.now_ns > std.math.maxInt(u64) - lease_duration_ns)
        return .{ .err = "fetch lease timestamp overflow" };
    const lease_expires_ns = op.now_ns + lease_duration_ns;
    var max_fetch: u32 = @min(op.count, ops.OpResult.max_inline_fetch);

    var result: ops.OpResult = .{};
    // Running total of encoded response bytes, shared across queues so a
    // multi-queue fetch also respects the caller's send-buffer budget.
    var bytes_used: usize = 0;
    const has_global_rl = self.global_rate_limit > 0 and self.global_rate_window_ms > 0;

    // Global rate limit check — applies across all queues.
    if (has_global_rl) {
        const gl_window_ns = @as(u64, self.global_rate_window_ms) * 1_000_000;
        const gl_window_start = if (op.now_ns > gl_window_ns) op.now_ns - gl_window_ns else 0;
        var gl_lower_buf: keys.KeyBuf = undefined;
        var gl_upper_buf: keys.KeyBuf = undefined;
        var gl_prefix_buf: keys.KeyBuf = undefined;
        var gl_iter = b.newIter(
            keys.globalRateLimitWindowStart(&gl_lower_buf, gl_window_start),
            keys.prefixEnd(&gl_upper_buf, keys.globalRateLimitPrefix(&gl_prefix_buf)),
        );
        defer gl_iter.close();
        var gl_count: u32 = 0;
        // Stop counting once the limit is reached — the exact overage is
        // irrelevant, only whether we're at/over the cap (M13 scan cost).
        if (gl_iter.first()) {
            gl_count += 1;
            while (gl_count < self.global_rate_limit and gl_iter.next()) gl_count += 1;
        }
        if (gl_count >= self.global_rate_limit) return result;
        max_fetch = @min(max_fetch, self.global_rate_limit - gl_count);
    }

    for (op.queues) |queue_name| {
        if (result.affected >= max_fetch) break;
        var queue_max_fetch = max_fetch;

        // Load queue config (cached in-memory, avoids KV read on hot path)
        const queue = self.getQueueConfig(b, queue_name) orelse continue;
        if (queue.paused) continue;

        // Check concurrency limit
        if (queue.max_concurrency > 0) {
            const active_count = self.getActiveCount(queue_name);
            assert.check(active_count >= 0, "fetch: negative active count for queue {s}", .{queue_name});
            const active: u32 = @intCast(active_count);
            if (active >= queue.max_concurrency) continue;
            const remaining_concurrency = queue.max_concurrency - active;
            if (remaining_concurrency < queue_max_fetch - result.affected) {
                queue_max_fetch = result.affected + remaining_concurrency;
            }
        }

        // Check per-queue rate limit
        if (queue.rate_limit > 0 and queue.rate_window_ms > 0) {
            const window_ns = @as(u64, queue.rate_window_ms) * 1_000_000;
            const window_start = if (op.now_ns > window_ns) op.now_ns - window_ns else 0;
            var rl_lower_buf: keys.KeyBuf = undefined;
            var rl_upper_buf: keys.KeyBuf = undefined;
            var rl_prefix_buf: keys.KeyBuf = undefined;
            var rl_iter = b.newIter(
                keys.rateLimitWindowStart(&rl_lower_buf, queue.name, window_start),
                keys.prefixEnd(&rl_upper_buf, keys.rateLimitPrefix(&rl_prefix_buf, queue.name)),
            );
            defer rl_iter.close();
            var rate_count: u32 = 0;
            // Stop once the limit is reached (M13 scan cost).
            if (rl_iter.first()) {
                rate_count += 1;
                while (rate_count < queue.rate_limit and rl_iter.next()) rate_count += 1;
            }
            if (rate_count >= queue.rate_limit) continue;
            const remaining_rate = queue.rate_limit - rate_count;
            const remaining_fetch = queue_max_fetch - result.affected;
            if (remaining_rate < remaining_fetch) {
                queue_max_fetch = result.affected + remaining_rate;
            }
        }

        const has_rl = queue.rate_limit > 0 and queue.rate_window_ms > 0;

        // Fairness path: score candidates by served+active, pick lowest score.
        // Separate from the normal pop loop to avoid any overhead on non-fairness queues.
        if (queue.fairness) {
            var fairness_budget: u32 = @max((queue_max_fetch - result.affected) * 2, 64);
            fetchWithFairness(self, b, &result, queue_name, &fairness_budget, queue_max_fetch, lease_expires_ns, lease_duration_ms, op, has_rl, has_global_rl, queue.max_concurrency, &bytes_used);
            continue; // next queue
        }

        // Non-fairness path: pop in priority order (hot path, unchanged).
        const remaining = queue_max_fetch - result.affected;
        var pop_budget: u32 = @max(remaining * 2, 64); // Min budget for skipping stale entries.
        while (pop_budget > 0 and result.affected < queue_max_fetch) {
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
            // Bulk-move pushes the job into the destination queue's index but
            // leaves a stale entry in the source queue's index. Validate the
            // job still belongs to THIS queue, else claiming it here writes the
            // active key + concurrency counter under mismatched queues (corrupts
            // active counts, panics on ack). Drop the stale entry.
            if (!std.mem.eql(u8, job.queue, queue_name)) continue;

            // Read the payload once, here, for both the send-buffer budget check
            // and the response (the pipeline reuses this slice, avoiding a second
            // read). Stop before the encoded response would overflow the caller's
            // send buffer. The FIRST job (bytes_used == 0) is always admitted:
            // fulfillSubscriptions only calls us for a connection whose free send
            // buffer already fits one max-size job, so max_response_bytes bounds
            // one such job — asserted below. Jobs left unclaimed stay pending for
            // the next push — no loss.
            var pk_buf: keys.KeyBuf = undefined;
            const payload_slice: []const u8 = b.get(keys.jobPayloadKey(&pk_buf, job_id)) orelse "";
            if (op.max_response_bytes > 0) {
                const need = fetchedJobWireSize(job_id.len, queue_name.len, payload_slice.len);
                if (bytes_used == 0) {
                    assert.check(need <= op.max_response_bytes, "fetch: first job ({d}B) exceeds budget ({d}B) — caller must guarantee room for one max job", .{ need, op.max_response_bytes });
                } else if (bytes_used + need > op.max_response_bytes) {
                    self.pending.push(queue_name, job.priority, job.created_at_ns, job_id);
                    break;
                }
            }

            // Claim the job.
            _ = self.nextLeaseToken(b);
            job.state = .active;
            job.worker_id = op.worker_id;
            job.hostname = op.hostname;
            assert.check(job.attempt < std.math.maxInt(u16), "fetch: attempt counter exhausted for job {s}", .{job.id});
            job.attempt += 1;
            job.started_at_ns = op.now_ns;
            job.lease_expires_at_ns = lease_expires_ns;
            job.lease_token = self.lease_counter;

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
            assert.check(
                queue.max_concurrency == 0 or self.getActiveCount(queue_name) <= @as(i32, @intCast(queue.max_concurrency)),
                "fetch: active_count ({d}) exceeded max_concurrency ({d}) for queue after incrActiveCount",
                .{ self.getActiveCount(queue_name), queue.max_concurrency },
            );

            // Re-check concurrency after claiming — prevents overshooting when
            // prefetch > max_concurrency (the outer loop only checks once per queue).
            const conc_reached = queue.max_concurrency > 0 and
                self.getActiveCount(queue_name) >= @as(i32, @intCast(queue.max_concurrency));

            if (job.group) |g| {
                self.incrFairnessActive(queue_name, g);
                self.incrFairnessServed(queue_name, g);
            }

            // Write rate limit entries. Disambiguate with lease_counter (the
            // just-assigned lease token), which is monotonic and unique per
            // claim across the whole process. The old `random_seed +% affected`
            // collided when two fetch ops ran in one tick with equal seeds (e.g.
            // fulfillSubscriptions, where random_seed is 0), causing the window
            // to undercount claims and the rate limit to be bypassed (M13).
            if (has_rl) {
                var rlk_buf: keys.KeyBuf = undefined;
                b.set(keys.rateLimitKey(&rlk_buf, queue_name, op.now_ns, self.lease_counter), "");
            }
            if (has_global_rl) {
                var gl_rlk_buf: keys.KeyBuf = undefined;
                b.set(keys.globalRateLimitKey(&gl_rlk_buf, op.now_ns, self.lease_counter), "");
            }
            self.indexer.recordTransition(job_id, queue_name, .pending, .active, job.created_at_ns);
            self.updateQueueCounterMem(queue_name, .pending, .active);
            self.verifyJobIndexes(b, &job, "fetch");

            // Store fetch result inline (no allocation).
            assert.check(result.affected < ops.OpResult.max_inline_fetch, "fetch: result.affected ({d}) >= max_inline_fetch", .{result.affected});
            var f = &result.fetched[result.affected];
            assert.check(job_id.len <= f.id_buf.len, "fetch: validated job_id exceeds response buffer", .{});
            const il = job_id.len;
            @memcpy(f.id_buf[0..il], job_id);
            f.id_len = @intCast(il);
            assert.check(queue_name.len <= f.queue_buf.len, "fetch: validated queue exceeds response buffer", .{});
            const ql = queue_name.len;
            @memcpy(f.queue_buf[0..ql], queue_name);
            f.queue_len = @intCast(ql);
            f.attempt = job.attempt;
            f.max_retries = job.max_retries;
            f.lease_duration_ms = lease_duration_ms;
            f.lease_token = job.lease_token;
            bytes_used += fetchedJobWireSize(job_id.len, queue_name.len, payload_slice.len);
            result.affected += 1;
            if (conc_reached) break;
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

        // Format queue names as comma-separated list.
        var q_buf: [codec.max_worker_encoded_size]u8 = undefined;
        var q_len: usize = 0;
        for (op.queues, 0..) |qname, i| {
            if (i > 0) {
                assert.check(q_len < q_buf.len, "fetch: validated worker queue list overflow", .{});
                q_buf[q_len] = ',';
                q_len += 1;
            }
            assert.check(qname.len <= q_buf.len - q_len, "fetch: validated worker queue list overflow", .{});
            @memcpy(q_buf[q_len..][0..qname.len], qname);
            q_len += qname.len;
        }
        assert.check(q_len == worker_queues_len, "fetch: worker queue list length mismatch", .{});
        if (q_len > 0) w.queues = q_buf[0..q_len];
        assert.check(codec.workerEncodedSize(&w) <= codec.max_worker_encoded_size, "fetch: validated worker exceeds codec buffer", .{});

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
    has_global_rl: bool,
    max_concurrency: u32,
    bytes_used: *usize,
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
            // Stale entry from a bulk-move into another queue (see non-fairness path).
            if (!std.mem.eql(u8, job.queue, queue_name)) continue;

            assert.check(num_candidates < max_candidates, "fetch-fairness: num_candidates ({d}) >= max_candidates", .{num_candidates});
            candidates[num_candidates] = entry;
            if (job.group) |g| {
                assert.check(g.len <= candidate_group_bufs[num_candidates].len, "fetch-fairness: validated group exceeds candidate buffer", .{});
                const gl: u8 = @intCast(g.len);
                @memcpy(candidate_group_bufs[num_candidates][0..gl], g);
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

        // Send-buffer budget (see non-fairness path). Read payload once for both
        // the check and the response. If the selected job won't fit, re-push it
        // and stop — it stays pending for the next push.
        var pk_buf: keys.KeyBuf = undefined;
        const payload_slice: []const u8 = b.get(keys.jobPayloadKey(&pk_buf, sel_job_id)) orelse "";
        if (op.max_response_bytes > 0) {
            const need = fetchedJobWireSize(sel_job_id.len, queue_name.len, payload_slice.len);
            // First job is always admitted (see non-fairness path): the caller
            // guarantees room for one max-size job.
            if (bytes_used.* == 0) {
                assert.check(need <= op.max_response_bytes, "fetch-fairness: first job ({d}B) exceeds budget ({d}B) — caller must guarantee room for one max job", .{ need, op.max_response_bytes });
            } else if (bytes_used.* + need > op.max_response_bytes) {
                self.pending.push(queue_name, 255 - candidates[best_idx].inv_priority, candidates[best_idx].created_ns, sel_job_id);
                break;
            }
        }

        _ = self.nextLeaseToken(b);
        job.state = .active;
        job.worker_id = op.worker_id;
        job.hostname = op.hostname;
        assert.check(job.attempt < std.math.maxInt(u16), "fetch-fairness: attempt counter exhausted for job {s}", .{job.id});
        job.attempt += 1;
        job.started_at_ns = op.now_ns;
        job.lease_expires_at_ns = lease_expires_ns;
        job.lease_token = self.lease_counter;

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
        assert.check(
            max_concurrency == 0 or self.getActiveCount(queue_name) <= @as(i32, @intCast(max_concurrency)),
            "fetch-fairness: active_count ({d}) exceeded max_concurrency ({d}) for queue after incrActiveCount",
            .{ self.getActiveCount(queue_name), max_concurrency },
        );

        // Re-check concurrency after claiming — prevents overshooting when
        // prefetch > max_concurrency (the outer loop only checks once per queue).
        const conc_reached = max_concurrency > 0 and
            self.getActiveCount(queue_name) >= @as(i32, @intCast(max_concurrency));

        if (job.group) |g| {
            self.incrFairnessActive(queue_name, g);
            self.incrFairnessServed(queue_name, g);
        }

        // See non-fairness path: lease_counter is unique per claim, avoiding the
        // random_seed collision that let two same-tick fetches undercount the
        // rate-limit window (M13).
        if (has_rl) {
            var rlk_buf: keys.KeyBuf = undefined;
            b.set(keys.rateLimitKey(&rlk_buf, queue_name, op.now_ns, self.lease_counter), "");
        }
        if (has_global_rl) {
            var gl_rlk_buf: keys.KeyBuf = undefined;
            b.set(keys.globalRateLimitKey(&gl_rlk_buf, op.now_ns, self.lease_counter), "");
        }
        self.indexer.recordTransition(sel_job_id, queue_name, .pending, .active, job.created_at_ns);
        self.updateQueueCounterMem(queue_name, .pending, .active);
        self.verifyJobIndexes(b, &job, "fetch-fairness");

        assert.check(result.affected < ops.OpResult.max_inline_fetch, "fetch-fairness: result.affected ({d}) >= max_inline_fetch", .{result.affected});
        var f = &result.fetched[result.affected];
        assert.check(sel_job_id.len <= f.id_buf.len, "fetch-fairness: validated job_id exceeds response buffer", .{});
        const il = sel_job_id.len;
        @memcpy(f.id_buf[0..il], sel_job_id);
        f.id_len = @intCast(il);
        assert.check(queue_name.len <= f.queue_buf.len, "fetch-fairness: validated queue exceeds response buffer", .{});
        const ql = queue_name.len;
        @memcpy(f.queue_buf[0..ql], queue_name);
        f.queue_len = @intCast(ql);
        f.attempt = job.attempt;
        f.max_retries = job.max_retries;
        f.lease_duration_ms = lease_duration_ms;
        f.lease_token = job.lease_token;
        bytes_used.* += fetchedJobWireSize(sel_job_id.len, queue_name.len, payload_slice.len);
        result.affected += 1;
        if (conc_reached) break;
    }
}
