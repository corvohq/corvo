//! Maintenance handler — promote, reclaim, expire, purge, unique, rate_limit, workers, batches.
//! Ported from Go internal/ops/ops_maintenance.go.

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;
const handler_fail = @import("handler_fail.zig");
const handler_cron = @import("handler_cron.zig");

// Chain step sentinel values (matching handler_ack.zig / handler_fail.zig).
const chain_step_max: u16 = 0xFFFD;

pub fn applyMaintenance(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.MaintenanceOp) ops.OpResult {
    return switch (op.action) {
        .promote => applyPromote(self, b, op.now_ns),
        .reclaim => applyReclaim(self, b, op.now_ns),
        .expire => applyExpire(self, b, op.now_ns),
        .purge => applyPurge(self, b, op.cutoff_ns),
        .unique => applyCleanUnique(b, op.now_ns),
        .rate_limit => applyCleanRateLimit(b, op.cutoff_ns),
        .workers => applyCleanWorkers(b, op.cutoff_ns),
        .batches => applyCleanBatches(b, op.cutoff_ns),
        .cron => handler_cron.applyCronScan(self, b, op.now_ns),
    };
}

// ============================================================================
// Promote: scheduled/retrying → pending
// ============================================================================

fn applyPromote(self: *OpHandler, b: *kv.WriteBatch, now_ns: u64) ops.OpResult {
    var affected: u32 = 0;

    // Promote scheduled jobs
    {
        var sp_buf: keys.KeyBuf = undefined;
        var spe_buf: keys.KeyBuf = undefined;
        const sp: []const u8 = keys.prefix_scheduled;
        @memcpy(sp_buf[0..sp.len], sp);
        if (keys.prefixEnd(&spe_buf, sp_buf[0..sp.len])) |end| {
            var iter = b.newIter(sp_buf[0..sp.len], end);
            defer iter.close();

            if (iter.first()) {
                while (true) {
                    // Cap per-tick promote to avoid an unbounded scan stalling
                    // the pipeline thread (and to bound work like reclaim/expire).
                    if (self.bulk_result_count >= OpHandler.max_bulk_results - 1) break;
                    const key = iter.key();
                    const scheduled_ns = extractTimestampFromScheduledKey(key);
                    if (scheduled_ns > now_ns) {
                        if (!iter.next()) break;
                        continue;
                    }

                    const job_id = extractJobIDFromScheduledKey(key);
                    var jk_buf: keys.KeyBuf = undefined;
                    const job_bytes = b.get(keys.jobKey(&jk_buf, job_id));
                    assert.check(job_bytes != null, "promote: scheduled key but no job", .{});
                    var job = codec.decodeJob(job_bytes.?);

                    job.state = .pending;
                    job.scheduled_at_ns = 0;
                    b.delete(key);

                    self.pending.push(job.queue, job.priority, job.created_at_ns, job_id);
                    self.recordPromoteQueue(job.queue);

                    if (job.expire_after_ms > 0) {
                        job.expire_at_ns = now_ns + @as(u64, job.expire_after_ms) * 1_000_000;
                        var xk_buf: keys.KeyBuf = undefined;
                        b.set(keys.expireKey(&xk_buf, job.expire_at_ns, job_id), "");
                    }

                    var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
                    b.set(keys.jobKey(&jk_buf, job_id), codec.encodeJob(&job_enc_buf, &job));
                    self.transitionReadIndexes(b, &job, .scheduled, .pending);
                    self.verifyJobIndexes(b, &job, "promote-scheduled");
                    self.recordBulkResult(job_id, .update_state, "pending", "", now_ns);
                    affected += 1;

                    if (!iter.next()) break;
                }
            }
        }
    }

    // Promote retrying jobs
    {
        var rp_buf: keys.KeyBuf = undefined;
        var rpe_buf: keys.KeyBuf = undefined;
        const rp: []const u8 = keys.prefix_retrying;
        @memcpy(rp_buf[0..rp.len], rp);
        if (keys.prefixEnd(&rpe_buf, rp_buf[0..rp.len])) |end| {
            var iter = b.newIter(rp_buf[0..rp.len], end);
            defer iter.close();

            if (iter.first()) {
                while (true) {
                    // Cap per-tick promote to avoid an unbounded scan stalling
                    // the pipeline thread (and to bound work like reclaim/expire).
                    if (self.bulk_result_count >= OpHandler.max_bulk_results - 1) break;
                    const key = iter.key();
                    const retry_ns = extractTimestampFromScheduledKey(key);
                    if (retry_ns > now_ns) {
                        if (!iter.next()) break;
                        continue;
                    }

                    const job_id = extractJobIDFromScheduledKey(key);
                    var jk_buf: keys.KeyBuf = undefined;
                    const job_bytes = b.get(keys.jobKey(&jk_buf, job_id));
                    assert.check(job_bytes != null, "promote: retrying key but no job", .{});
                    var job = codec.decodeJob(job_bytes.?);

                    job.state = .pending;
                    job.scheduled_at_ns = 0;
                    b.delete(key);

                    self.pending.push(job.queue, job.priority, job.created_at_ns, job_id);
                    self.recordPromoteQueue(job.queue);

                    if (job.expire_after_ms > 0) {
                        job.expire_at_ns = now_ns + @as(u64, job.expire_after_ms) * 1_000_000;
                        var xk_buf: keys.KeyBuf = undefined;
                        b.set(keys.expireKey(&xk_buf, job.expire_at_ns, job_id), "");
                    }

                    var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
                    b.set(keys.jobKey(&jk_buf, job_id), codec.encodeJob(&job_enc_buf, &job));
                    self.transitionReadIndexes(b, &job, .retrying, .pending);
                    self.verifyJobIndexes(b, &job, "promote-retrying");
                    self.recordBulkResult(job_id, .update_state, "pending", "", now_ns);
                    affected += 1;

                    if (!iter.next()) break;
                }
            }
        }
    }

    return .{
        .affected = affected,
        .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
    };
}

// ============================================================================
// Reclaim: active jobs with expired leases → pending or dead
// ============================================================================

fn applyReclaim(self: *OpHandler, b: *kv.WriteBatch, now_ns: u64) ops.OpResult {
    var affected: u32 = 0;

    var ap_buf: keys.KeyBuf = undefined;
    var ape_buf: keys.KeyBuf = undefined;
    const ap: []const u8 = keys.prefix_active;
    @memcpy(ap_buf[0..ap.len], ap);
    if (keys.prefixEnd(&ape_buf, ap_buf[0..ap.len])) |end| {
        var iter = b.newIter(ap_buf[0..ap.len], end);
        defer iter.close();

        if (iter.first()) {
            while (true) {
                // Cap per-tick reclaim to avoid bulk_results overflow.
                if (self.bulk_result_count >= OpHandler.max_bulk_results - 1) break;

                const val = iter.value();
                const key = iter.key();
                assert.check(val.len == 8, "invalid active key value length", .{});

                const lease_expires_ns = keys.getU64BE(val);
                if (lease_expires_ns >= now_ns) {
                    if (!iter.next()) break;
                    continue;
                }

                // Parse job ID from active key: a|{queue}\x00{job_id}
                const key_offset = keys.prefix_active.len;
                const sep_pos = std.mem.indexOfScalarPos(u8, key, key_offset, 0x00) orelse {
                    if (!iter.next()) break;
                    continue;
                };
                const job_id = key[sep_pos + 1 ..];

                var jk_buf: keys.KeyBuf = undefined;
                const job_bytes = b.get(keys.jobKey(&jk_buf, job_id));
                assert.check(job_bytes != null, "reclaim: active key but no job", .{});
                var job = codec.decodeJob(job_bytes.?);

                self.decrActiveCount(job.queue);
                if (job.group) |g| self.decrFairnessActive(job.queue, g);

                b.delete(key); // active key

                job.worker_id = null;
                job.hostname = null;
                job.lease_expires_at_ns = 0;

                // Write error KV entry for lease expiry.
                {
                    var ek_buf: keys.KeyBuf = undefined;
                    var err_val_buf: [256]u8 = undefined;
                    const err_json = std.fmt.bufPrint(&err_val_buf, "{{\"job_id\":\"{s}\",\"attempt\":{d},\"error\":\"lease expired\",\"created_at_ns\":{d}}}", .{
                        job_id,
                        job.attempt,
                        now_ns,
                    }) catch "";
                    if (err_json.len > 0) {
                        b.set(keys.jobErrorKey(&ek_buf, job_id, @intCast(job.attempt)), err_json);
                    }
                }

                if (job.max_retries > 0 and job.attempt >= job.max_retries) {
                    // Dead — retries exhausted
                    job.state = .dead;
                    job.completed_at_ns = now_ns;
                    job.failed_at_ns = now_ns;

                    // Release unique lock if we own it
                    var uk_buf: keys.KeyBuf = undefined;
                    if (OpHandler.jobUniqueKey(&uk_buf, &job)) |ukey| {
                        var uk_val_buf: [256]u8 = undefined;
                        if (b.getInto(ukey, &uk_val_buf)) |ub| {
                            const decoded = keys.decodeUniqueValue(ub);
                            if (std.mem.eql(u8, decoded.job_id, job.id)) {
                                b.delete(ukey);
                            }
                        }
                    }

                    var dk_buf: keys.KeyBuf = undefined;
                    b.set(keys.deadKey(&dk_buf, now_ns, job_id), "");
                    self.dead_since_purge += 1;

                    // Batch failure tracking.
                    if (job.batch_id) |bid| {
                        if (bid.len > 0) self.handleBatchJobComplete(b, bid, false, now_ns);
                    }

                    // Chain on_failure handler
                    if (job.chain_config) |cc| {
                        if (cc.len > 0 and job.chain_step <= chain_step_max) {
                            handler_fail.fireChainOnFailure(self, b, &job, now_ns);
                        }
                    }

                    var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
                    b.set(keys.jobKey(&jk_buf, job_id), codec.encodeJob(&job_enc_buf, &job));
                    self.transitionReadIndexes(b, &job, .active, .dead);
                    self.verifyJobIndexes(b, &job, "reclaim-dead");
                    self.recordBulkResult(job_id, .update_state, "dead", "", now_ns);
                } else {
                    // Back to pending
                    job.state = .pending;
                    self.pending.push(job.queue, job.priority, job.created_at_ns, job_id);
                    self.recordPromoteQueue(job.queue);
                    if (job.expire_after_ms > 0) {
                        job.expire_at_ns = now_ns + @as(u64, job.expire_after_ms) * 1_000_000;
                        var xk_buf: keys.KeyBuf = undefined;
                        b.set(keys.expireKey(&xk_buf, job.expire_at_ns, job_id), "");
                    }

                    var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
                    b.set(keys.jobKey(&jk_buf, job_id), codec.encodeJob(&job_enc_buf, &job));
                    self.transitionReadIndexes(b, &job, .active, .pending);
                    self.verifyJobIndexes(b, &job, "reclaim-pending");
                    self.recordBulkResult(job_id, .update_state, "pending", "", now_ns);
                }

                affected += 1;
                if (!iter.next()) break;
            }
        }
    }

    return .{
        .affected = affected,
        .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
    };
}

// ============================================================================
// Expire: pending jobs past their expire_at → dead
// ============================================================================

fn applyExpire(self: *OpHandler, b: *kv.WriteBatch, now_ns: u64) ops.OpResult {
    var affected: u32 = 0;

    var xp_buf: keys.KeyBuf = undefined;
    var xpe_buf: keys.KeyBuf = undefined;
    const xp: []const u8 = keys.prefix_expire;
    @memcpy(xp_buf[0..xp.len], xp);
    if (keys.prefixEnd(&xpe_buf, xp_buf[0..xp.len])) |end| {
        var iter = b.newIter(xp_buf[0..xp.len], end);
        defer iter.close();

        if (iter.first()) {
            while (true) {
                // Cap per-tick expire to avoid bulk_results overflow.
                if (self.bulk_result_count >= OpHandler.max_bulk_results - 1) break;

                const key = iter.key();
                const prefix_len = keys.prefix_expire.len;
                const expires_at = keys.getU64BE(key[prefix_len .. prefix_len + 8]);
                if (expires_at >= now_ns) {
                    if (!iter.next()) break;
                    continue;
                }

                const job_id = key[prefix_len + 8 ..];
                var jk_buf: keys.KeyBuf = undefined;
                const job_bytes = b.get(keys.jobKey(&jk_buf, job_id));
                assert.check(job_bytes != null, "expire: expire key but no job", .{});
                var job = codec.decodeJob(job_bytes.?);
                assert.check(job.state == .pending, "expire: expected pending job", .{});

                b.delete(key); // expire key

                // Write error KV entry for job expiry.
                {
                    var ek_buf: keys.KeyBuf = undefined;
                    var err_val_buf: [256]u8 = undefined;
                    const err_json = std.fmt.bufPrint(&err_val_buf, "{{\"job_id\":\"{s}\",\"attempt\":{d},\"error\":\"job expired\",\"created_at_ns\":{d}}}", .{
                        job_id,
                        job.attempt,
                        now_ns,
                    }) catch "";
                    if (err_json.len > 0) {
                        b.set(keys.jobErrorKey(&ek_buf, job_id, @intCast(job.attempt)), err_json);
                    }
                }

                job.state = .dead;
                job.completed_at_ns = now_ns;
                job.failed_at_ns = now_ns;

                // Release unique lock if we own it
                var uk_buf: keys.KeyBuf = undefined;
                if (OpHandler.jobUniqueKey(&uk_buf, &job)) |ukey| {
                    var uk_val_buf: [256]u8 = undefined;
                    if (b.getInto(ukey, &uk_val_buf)) |ub| {
                        const decoded = keys.decodeUniqueValue(ub);
                        if (std.mem.eql(u8, decoded.job_id, job.id)) {
                            b.delete(ukey);
                        }
                    }
                }

                // Batch failure tracking.
                if (job.batch_id) |bid| {
                    if (bid.len > 0) self.handleBatchJobComplete(b, bid, false, now_ns);
                }

                var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
                b.set(keys.jobKey(&jk_buf, job_id), codec.encodeJob(&job_enc_buf, &job));
                self.transitionReadIndexes(b, &job, .pending, .dead);
                self.verifyJobIndexes(b, &job, "expire");
                var dk_buf: keys.KeyBuf = undefined;
                b.set(keys.deadKey(&dk_buf, now_ns, job_id), "");
                self.dead_since_purge += 1;
                self.recordBulkResult(job_id, .update_state, "dead", "", now_ns);

                affected += 1;
                if (!iter.next()) break;
            }
        }
    }

    return .{ .affected = affected };
}

// ============================================================================
// Purge: delete terminal jobs older than cutoff
// ============================================================================

fn applyPurge(self: *OpHandler, b: *kv.WriteBatch, cutoff_ns: u64) ops.OpResult {
    var affected: u32 = 0;

    var dp_buf: keys.KeyBuf = undefined;
    var dpe_buf: keys.KeyBuf = undefined;
    const dp: []const u8 = keys.prefix_dead;
    @memcpy(dp_buf[0..dp.len], dp);
    if (keys.prefixEnd(&dpe_buf, dp_buf[0..dp.len])) |end| {
        var iter = b.newIter(dp_buf[0..dp.len], end);
        defer iter.close();

        if (iter.first()) {
            while (true) {
                // Cap per-tick purge. A large backlog (e.g. millions of terminal
                // jobs crossing the retention cutoff at once) would otherwise
                // delete everything in a single batch, stalling the pipeline
                // thread for seconds and freezing all connections. The remainder
                // is drained on subsequent ticks / count-triggered runs.
                if (affected >= OpHandler.max_bulk_results) break;
                const key = iter.key();
                const prefix_len = keys.prefix_dead.len;
                const completed_at = keys.getU64BE(key[prefix_len .. prefix_len + 8]);
                if (completed_at >= cutoff_ns) break; // d| keys are time-sorted

                const job_id = key[prefix_len + 8 ..];

                // Skip purging non-terminal jobs (stale d| keys from re-enqueue).
                var jk_buf: keys.KeyBuf = undefined;
                const job_bytes = b.get(keys.jobKey(&jk_buf, job_id));
                if (job_bytes != null) {
                    const job = codec.decodeJob(job_bytes.?);
                    if (!job.state.isTerminal()) {
                        // Stale d| key — delete index but leave job data.
                        b.delete(key);
                        if (!iter.next()) break;
                        continue;
                    }
                }

                // Delete read indexes + tag indexes + decrement counter
                if (job_bytes != null) {
                    const job = codec.decodeJob(job_bytes.?);
                    OpHandler.deleteReadIndexes(b, &job);
                    OpHandler.deleteTagIndexes(b, &job);
                    self.decrQueueCounter(b, job.queue, job.state);
                }

                b.delete(keys.jobKey(&jk_buf, job_id));
                var jpk_buf: keys.KeyBuf = undefined;
                b.delete(keys.jobPayloadKey(&jpk_buf, job_id));

                // Delete errors
                var jep_buf: keys.KeyBuf = undefined;
                var jee_buf: keys.KeyBuf = undefined;
                const err_prefix = keys.jobErrorPrefix(&jep_buf, job_id);
                if (keys.prefixEnd(&jee_buf, err_prefix)) |err_end| {
                    b.deleteRange(err_prefix, err_end);
                }

                b.delete(key); // d| key
                affected += 1;

                if (!iter.next()) break;
            }
        }
    }

    self.total_jobs -|= affected;
    return .{ .affected = affected };
}

// ============================================================================
// Unique cleanup: delete expired unique locks
// ============================================================================

fn applyCleanUnique(b: *kv.WriteBatch, now_ns: u64) ops.OpResult {
    var up_buf: keys.KeyBuf = undefined;
    var upe_buf: keys.KeyBuf = undefined;
    const up: []const u8 = keys.prefix_unique;
    @memcpy(up_buf[0..up.len], up);
    if (keys.prefixEnd(&upe_buf, up_buf[0..up.len])) |end| {
        var iter = b.newIter(up_buf[0..up.len], end);
        defer iter.close();

        if (iter.first()) {
            while (true) {
                const val = iter.value();
                const decoded = keys.decodeUniqueValue(val);
                if (decoded.expires_ns == 0 or decoded.expires_ns >= now_ns) {
                    if (!iter.next()) break;
                    continue;
                }
                b.delete(iter.key());
                if (!iter.next()) break;
            }
        }
    }

    return .{};
}

// ============================================================================
// Rate limit cleanup: delete old rate limit entries
// ============================================================================

fn applyCleanRateLimit(b: *kv.WriteBatch, cutoff_ns: u64) ops.OpResult {
    var lp_buf: keys.KeyBuf = undefined;
    var lpe_buf: keys.KeyBuf = undefined;
    const lp: []const u8 = keys.prefix_rate_limit;
    @memcpy(lp_buf[0..lp.len], lp);
    if (keys.prefixEnd(&lpe_buf, lp_buf[0..lp.len])) |end| {
        var iter = b.newIter(lp_buf[0..lp.len], end);
        defer iter.close();

        if (iter.first()) {
            while (true) {
                const key = iter.key();
                // l|{queue}\x00{fetched_ns:8BE}{random:8BE}
                const key_offset = keys.prefix_rate_limit.len;
                const sep_pos = std.mem.indexOfScalarPos(u8, key, key_offset, 0x00) orelse {
                    if (!iter.next()) break;
                    continue;
                };
                const fetched_ns = keys.getU64BE(key[sep_pos + 1 .. sep_pos + 9]);
                if (fetched_ns >= cutoff_ns) {
                    if (!iter.next()) break;
                    continue;
                }
                b.delete(key);
                if (!iter.next()) break;
            }
        }
    }

    // Clean global rate limit entries (gl| prefix).
    cleanRateLimitPrefix(b, keys.prefix_global_rate_limit, cutoff_ns);

    return .{};
}

/// Generic rate limit prefix cleaner for gl| keys.
/// gl| keys: prefix{fetched_ns:8BE}{random:8BE} — timestamp immediately after prefix.
fn cleanRateLimitPrefix(b: *kv.WriteBatch, prefix: []const u8, cutoff_ns: u64) void {
    var p_buf: keys.KeyBuf = undefined;
    var pe_buf: keys.KeyBuf = undefined;
    @memcpy(p_buf[0..prefix.len], prefix);
    const end = keys.prefixEnd(&pe_buf, p_buf[0..prefix.len]) orelse return;

    var iter = b.newIter(p_buf[0..prefix.len], end);
    defer iter.close();

    if (!iter.first()) return;
    while (true) {
        const key = iter.key();
        // Find timestamp position: after \x00 separator if present, else directly after prefix.
        const ts_pos = if (std.mem.indexOfScalarPos(u8, key, prefix.len, 0x00)) |sep|
            sep + 1
        else
            prefix.len;

        if (ts_pos + 8 <= key.len) {
            const fetched_ns = keys.getU64BE(key[ts_pos .. ts_pos + 8]);
            if (fetched_ns >= cutoff_ns) {
                if (!iter.next()) break;
                continue;
            }
        }
        b.delete(key);
        if (!iter.next()) break;
    }
}

// ============================================================================
// Workers cleanup: delete stale workers
// ============================================================================

fn applyCleanWorkers(b: *kv.WriteBatch, cutoff_ns: u64) ops.OpResult {
    var affected: u32 = 0;

    var wp_buf: keys.KeyBuf = undefined;
    var wpe_buf: keys.KeyBuf = undefined;
    const wp: []const u8 = keys.prefix_worker;
    @memcpy(wp_buf[0..wp.len], wp);
    if (keys.prefixEnd(&wpe_buf, wp_buf[0..wp.len])) |end| {
        var iter = b.newIter(wp_buf[0..wp.len], end);
        defer iter.close();

        if (iter.first()) {
            while (true) {
                const val = iter.value();
                const worker = codec.decodeWorker(val);
                if (worker.last_heartbeat_ns <= cutoff_ns) {
                    b.delete(iter.key());
                    affected += 1;
                }
                if (!iter.next()) break;
            }
        }
    }

    return .{ .affected = affected };
}

// ============================================================================
// Batches cleanup: delete completed batches older than cutoff
// ============================================================================

fn applyCleanBatches(b: *kv.WriteBatch, cutoff_ns: u64) ops.OpResult {
    var affected: u32 = 0;

    var bp_buf: keys.KeyBuf = undefined;
    var bpe_buf: keys.KeyBuf = undefined;
    const bp: []const u8 = keys.prefix_batch;
    @memcpy(bp_buf[0..bp.len], bp);
    if (keys.prefixEnd(&bpe_buf, bp_buf[0..bp.len])) |end| {
        var iter = b.newIter(bp_buf[0..bp.len], end);
        defer iter.close();

        if (iter.first()) {
            while (true) {
                const val = iter.value();
                const batch = codec.decodeBatch(val);
                if (batch.completed_at_ns > 0 and batch.completed_at_ns <= cutoff_ns) {
                    b.delete(iter.key());
                    affected += 1;
                }
                if (!iter.next()) break;
            }
        }
    }

    return .{ .affected = affected };
}

// ============================================================================
// Helpers
// ============================================================================

/// Extract timestamp from scheduled/retrying key: prefix|{queue}\x00{ns:8BE}{job_id}
fn extractTimestampFromScheduledKey(key: []const u8) u64 {
    // Find the separator after the queue name
    var i: usize = 2; // skip past "s|" or "r|"
    while (i < key.len) : (i += 1) {
        if (key[i] == 0x00) break;
    }
    if (i + 9 > key.len) return std.math.maxInt(u64);
    return keys.getU64BE(key[i + 1 .. i + 9]);
}

/// Extract job ID from scheduled/retrying key
fn extractJobIDFromScheduledKey(key: []const u8) []const u8 {
    var i: usize = 2;
    while (i < key.len) : (i += 1) {
        if (key[i] == 0x00) break;
    }
    if (i + 9 > key.len) return "";
    return key[i + 9 ..];
}
