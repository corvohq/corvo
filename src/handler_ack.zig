//! Ack handler — marks active jobs as completed (or re-enqueues for agents).
//! Ported from Go internal/ops/ops_ack_fail.go (ack portion).

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;
const metrics_mod = handler.metrics_mod;

// Chain step sentinel values (since chain_step is u16, we use high values for cleanup handlers).
const chain_step_exit: u16 = 0xFFFF;
const chain_step_failure: u16 = 0xFFFE;
const chain_step_max: u16 = 0xFFFD; // max valid step index

pub fn applyAck(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.AckOp) ops.OpResult {
    if (op.acks.len == 0) return .{ .err = "no jobs provided" };
    if (op.now_ns == 0) return .{ .err = "invalid ack timestamp" };

    // Validate the complete batch before applying any completion side effects.
    // HTTP result/checkpoint bodies are not naturally limited by the u8 RPC
    // prefixes and previously could panic the fixed job encoder after earlier
    // acknowledgements in the same request had already mutated state.
    for (op.acks) |*ack| {
        if (ack.job_id.len == 0 or ack.job_id.len > types.max_job_id_len or
            std.mem.indexOfScalar(u8, ack.job_id, 0) != null)
            return .{ .err = "invalid ack job_id" };
        if (ack.queue.len > types.max_queue_name_len or
            std.mem.indexOfScalar(u8, ack.queue, 0) != null)
            return .{ .err = "invalid ack queue" };
        if (ack.result) |value| {
            if (value.len > types.max_metadata_field_len)
                return .{ .err = "ack result too large" };
        }
        if (ack.checkpoint) |value| {
            if (value.len > types.max_metadata_field_len)
                return .{ .err = "ack checkpoint too large" };
        }
        if (ack.hold_reason) |value| {
            if (value.len > types.max_metadata_field_len)
                return .{ .err = "ack hold reason too large" };
        }
    }

    var affected: u32 = 0;

    for (op.acks) |*ack| {
        if (ack.job_id.len == 0) continue;

        var jk_buf: keys.KeyBuf = undefined;
        var job_val_buf: [codec.max_job_encoded_size]u8 = undefined;
        const job_bytes = b.getInto(keys.jobKey(&jk_buf, ack.job_id), &job_val_buf);
        if (job_bytes == null) continue; // job not found, skip

        var job = codec.decodeJob(job_bytes.?);
        if (job.state != .active) continue; // not active, skip

        // Lease token check: reject stale acks from workers whose lease was reclaimed.
        // ack.lease_token=0 means "don't check" (client doesn't have the token).
        if (ack.lease_token != 0 and ack.lease_token != job.lease_token) continue;

        // Hold logic
        var next_state: types.JobState = .completed;
        switch (ack.ack_status) {
            .hold => {
                next_state = .held;
                job.hold_reason = ack.hold_reason;
            },
            .done => {
                next_state = .completed;
            },
        }

        if (ack.checkpoint) |cp| {
            if (cp.len > 0) job.checkpoint = cp;
        }

        if (next_state == .completed) {
            job.completed_at_ns = op.now_ns;
            self.metrics.recordComplete(job.queue, job.created_at_ns, job.started_at_ns, op.now_ns);

            // Dead key for purge to find and clean up deferred indexes.
            var dk_buf: keys.KeyBuf = undefined;
            b.set(keys.deadKey(&dk_buf, op.now_ns, job.id), "");
            self.dead_since_purge += 1;

            // Record webhook events for matching webhooks.
            self.checkWebhooks(job.id, job.queue, .completed, op.now_ns);

            if (job.expire_after_ms > 0 and job.expire_at_ns > 0) {
                var xk_buf: keys.KeyBuf = undefined;
                b.delete(keys.expireKey(&xk_buf, job.expire_at_ns, job.id));
                job.expire_at_ns = 0;
            }

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

            // Batch completion tracking.
            if (job.batch_id) |bid| {
                if (bid.len > 0) self.handleBatchJobComplete(b, bid, true, op.now_ns);
            }

            // Chain advancement — enqueue next step.
            // Only advance if chain_step is a valid index (not a cleanup sentinel).
            if (job.chain_config) |cc| {
                if (cc.len > 0 and job.chain_step <= chain_step_max) {
                    advanceChain(self, b, &job, ack, op.now_ns);
                }
            }
        }

        // Clear worker fields
        job.worker_id = null;
        job.hostname = null;
        job.lease_expires_at_ns = 0;

        if (ack.result) |r| {
            if (r.len > 0) job.result = r;
        }

        // Delete active key, decrement counts
        var ak_buf: keys.KeyBuf = undefined;
        b.delete(OpHandler.jobActiveKey(&ak_buf, &job));
        self.decrActiveCount(job.queue);
        if (job.group) |g| self.decrFairnessActive(job.queue, g);

        job.state = next_state;

        if (next_state == .completed and !self.persist_completed) {
            // Auto-delete: remove job + payload from hot-path batch.
            // Read indexes are deferred to the indexer. Tags must be removed
            // while the job value is still available; error keys are retained
            // with the d| marker until purge.
            OpHandler.deleteTagIndexes(b, &job);
            b.delete(keys.jobKey(&jk_buf, ack.job_id));
            var jpk_buf: keys.KeyBuf = undefined;
            b.delete(keys.jobPayloadKey(&jpk_buf, ack.job_id));
            self.indexer.recordDeleteAll(job.id, job.queue, .active, job.created_at_ns);
            self.decrQueueCounterMem(job.queue, .active);
            assert.check(self.total_jobs > 0, "ack auto-delete: total_jobs underflow", .{});
            self.total_jobs -= 1;
        } else {
            // Write updated job
            var job_enc_buf: [codec.max_job_encoded_size]u8 = undefined;
            b.set(keys.jobKey(&jk_buf, ack.job_id), codec.encodeJob(&job_enc_buf, &job));

            // Defer read index transition to indexer.
            self.indexer.recordTransition(job.id, job.queue, .active, next_state, job.created_at_ns);
            self.updateQueueCounterMem(job.queue, .active, next_state);

            self.verifyJobIndexes(b, &job, "ack");
        }
        affected += 1;
    }

    return .{
        .affected = affected,
        .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
    };
}

/// Advance a chain after successful ack. Parses chain_config JSON to find
/// the next step and enqueues it. Off the hot path — only runs for chain jobs.
fn advanceChain(self: *OpHandler, b: *kv.WriteBatch, job: *const types.Job, ack: *const ops.AckJob, now_ns: u64) void {
    const cc = job.chain_config orelse return;
    if (cc.len == 0) return;

    // Parse chain config JSON: {"steps":[{"queue":"q","payload":...}],"on_exit":{"queue":"done"}}.
    // payload is Value because SDKs may send it as a string or a JSON object.
    const ChainStep = struct {
        queue: ?[]const u8 = null,
        payload: ?std.json.Value = null,
    };
    const ChainDef = struct {
        steps: ?[]const ChainStep = null,
        on_exit: ?ChainStep = null,
        on_failure: ?ChainStep = null,
    };

    // Use a stack allocator for JSON parsing (no heap allocation).
    // Parse failure (malformed chain_config) deliberately skips chain
    // advancement — an invalid config never had a runnable next step.
    var parse_buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    const parsed = std.json.parseFromSlice(ChainDef, fba.allocator(), cc, .{
        .ignore_unknown_fields = true,
    }) catch return;

    const chain = parsed.value;
    const steps = chain.steps orelse return;

    const current_step = job.chain_step;
    const next_idx = current_step + 1;

    const is_exit = (next_idx >= steps.len);

    var next_queue: ?[]const u8 = null;
    var next_payload: ?std.json.Value = null;
    var next_chain_step: u16 = 0;

    if (is_exit) {
        // Exit → jump to on_exit handler.
        if (chain.on_exit) |on_exit| {
            next_queue = on_exit.queue;
            next_payload = on_exit.payload;
            next_chain_step = chain_step_exit;
        } else return;
    } else if (next_idx < steps.len) {
        // Normal progression.
        next_queue = steps[next_idx].queue;
        next_payload = steps[next_idx].payload;
        next_chain_step = @intCast(next_idx);
    } else {
        // Past the end → fire on_exit if exists.
        if (chain.on_exit) |on_exit| {
            next_queue = on_exit.queue;
            next_payload = on_exit.payload;
            next_chain_step = chain_step_exit;
        } else return;
    }

    const queue = next_queue orelse return;

    // Merge previous_job_id and previous_result into payload (matches Go).
    // Off the hot path — only runs for chain jobs.
    //
    // merged_buf is sized to the provable worst case, so a write can never
    // fail and a chain continuation is never silently dropped:
    //   {"previous_job_id":                                     19 bytes
    //   json.fmt(job.id): 2 quotes + 64*6 (\uXXXX worst case)  386 bytes
    //   ,"previous_result": + result (<= max_metadata_field_len,
    //   validated in applyAck)                                  19 + 512
    //   payload arm: bounded by the chain_config source text — the parsed
    //   string is at most its source length, and std.json re-serialization
    //   never emits more bytes than a token's source form (short escapes stay
    //   short, \uXXXX came from \uXXXX). cc passed validateEnqueue, so
    //   cc.len < max_enqueue_job_encoded_size (4096).
    //   closing }                                                1 byte
    //   total <= 19 + 386 + 19 + 512 + 4096 + 1 = 5033 < 8192.
    var merged_buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&merged_buf);
    const w = fbs.writer();
    w.print("{{\"previous_job_id\":{f}", .{std.json.fmt(job.id, .{})}) catch
        assert.fail("chain merge exceeds sized buffer", .{});
    if (ack.result) |r| {
        if (r.len > 0) {
            w.writeAll(",\"previous_result\":") catch
                assert.fail("chain merge exceeds sized buffer", .{});
            w.writeAll(r) catch
                assert.fail("chain merge exceeds sized buffer", .{});
        }
    }
    if (next_payload) |pv| {
        switch (pv) {
            .string => |s| {
                if (s.len > 2 and s[0] == '{') {
                    w.writeByte(',') catch
                        assert.fail("chain merge exceeds sized buffer", .{});
                    w.writeAll(s[1..]) catch
                        assert.fail("chain merge exceeds sized buffer", .{});
                } else {
                    w.writeByte('}') catch
                        assert.fail("chain merge exceeds sized buffer", .{});
                }
            },
            .object => {
                var obj_iter = pv.object.iterator();
                while (obj_iter.next()) |entry| {
                    w.writeByte(',') catch
                        assert.fail("chain merge exceeds sized buffer", .{});
                    w.print("{f}:", .{std.json.fmt(entry.key_ptr.*, .{})}) catch
                        assert.fail("chain merge exceeds sized buffer", .{});
                    w.print("{f}", .{std.json.fmt(entry.value_ptr.*, .{})}) catch
                        assert.fail("chain merge exceeds sized buffer", .{});
                }
                w.writeByte('}') catch
                    assert.fail("chain merge exceeds sized buffer", .{});
            },
            else => w.writeByte('}') catch
                assert.fail("chain merge exceeds sized buffer", .{}),
        }
    } else {
        w.writeByte('}') catch
            assert.fail("chain merge exceeds sized buffer", .{});
    }
    const merged_payload = fbs.getWritten();

    // Generate a deterministic child ID. Client IDs share the same keyspace,
    // so collisions are boundary conditions, not assertion failures.
    var id_buf: [64]u8 = undefined;
    const chain_job_id = switch (handler.resolveChainChildId(b, &id_buf, job.id, job.chain_id, next_chain_step)) {
        .available => |id| id,
        .existing, .exhausted => return,
    };

    const chain_job = ops.EnqueueJob{
        .job_id = chain_job_id,
        .queue = queue,
        .payload = merged_payload,
        .state = .pending,
        .priority = job.priority,
        .max_retries = job.max_retries,
        .created_at_ns = now_ns,
        .chain_id = job.chain_id,
        .chain_step = next_chain_step,
        .chain_config = cc,
        .parent_id = job.id,
    };

    const jobs = [_]ops.EnqueueJob{chain_job};
    const enqueue_op = ops.EnqueueOp{
        .jobs = &jobs,
        .now_ns = now_ns,
    };
    const enq_result = self.applyEnqueue(b, &enqueue_op);
    if (enq_result.err == null) {
        self.recordSideEffect(&chain_job);
        self.recordPromoteQueue(chain_job.queue);
    }
}
