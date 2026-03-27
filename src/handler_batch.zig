//! Batch handler — create and seal batches.
//! Ported from Go internal/ops/ops_batch.go.

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

pub fn applyBatchCreate(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.CreateBatchOp) ops.OpResult {
    var batch = types.Batch{
        .id = op.batch_id,
        .open = true,
        .total = 0,
        .succeeded = 0,
        .failed = 0,
        .created_at_ns = op.created_at_ns,
    };

    if (op.callback_queue.len > 0) {
        batch.callback_queue = op.callback_queue;
    }
    if (op.callback_payload) |cp| {
        batch.callback_payload = cp;
    }

    var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
    var bk_buf: keys.KeyBuf = undefined;
    b.set(keys.batchKey(&bk_buf, op.batch_id), codec.encodeBatch(&batch_enc_buf, &batch));

    return .{ .affected = 1 };
}

pub fn applySealBatch(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.SealBatchOp) ops.OpResult {
    var bk_buf: keys.KeyBuf = undefined;
    const bkey = keys.batchKey(&bk_buf, op.batch_id);
    const batch_bytes = b.get(bkey);
    if (batch_bytes == null) {
        return .{ .err = "batch not found" };
    }

    var batch = codec.decodeBatch(batch_bytes.?);
    if (!batch.open) {
        return .{ .err = "batch already sealed" };
    }

    assert.check(batch.completed_at_ns == 0, "batch is open but has completed_at set", .{});
    batch.open = false;

    // Check if batch is already complete (all jobs finished before seal)
    if (batch.pending == 0 and batch.total > 0) {
        batch.completed_at_ns = op.now_ns;
        // Fire callback if defined
        if (batch.callback_queue) |cq| {
            if (cq.len > 0) {
                var cb_id_buf: [64]u8 = undefined;
                const cb_id = std.fmt.bufPrint(&cb_id_buf, "batch_cb_{s}", .{op.batch_id}) catch "batch_cb_err";
                const callback_job = ops.EnqueueJob{
                    .job_id = cb_id,
                    .queue = cq,
                    .payload = batch.callback_payload,
                    .state = .pending,
                    .created_at_ns = op.now_ns,
                };
                assert.check(callback_job.batch_id == null, "callback job cannot have batch id", .{});
                const jobs = [_]ops.EnqueueJob{callback_job};
                const enqueue_op = ops.EnqueueOp{
                    .jobs = &jobs,
                    .now_ns = op.now_ns,
                };
                const enq_result = self.applyEnqueue(b, &enqueue_op);
                if (enq_result.err == null) {
                    self.recordSideEffect(&callback_job);
                }
            }
        }
    }

    var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
    b.set(bkey, codec.encodeBatch(&batch_enc_buf, &batch));

    return .{ .affected = 1 };
}
