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
    if (op.batch_id.len == 0 or op.batch_id.len > types.max_entity_id_len or
        std.mem.indexOfScalar(u8, op.batch_id, 0) != null)
        return .{ .err = "invalid batch_id" };
    if (op.callback_queue.len > types.max_queue_name_len or
        std.mem.indexOfScalar(u8, op.callback_queue, 0) != null)
        return .{ .err = "invalid callback queue" };
    if (op.created_at_ns == 0) return .{ .err = "invalid batch timestamp" };

    // Reject a duplicate batch id (client-provided data → error, not a silent
    // overwrite). Overwriting reset the counters of an in-flight batch, which
    // later underflowed and tripped an assert-panic in adjustBatchForDeletedJob
    // / applyBatchMods when its jobs completed. TigerStyle: boundary data is an
    // error, not an assert.
    var dup_bk_buf: keys.KeyBuf = undefined;
    if (b.get(keys.batchKey(&dup_bk_buf, op.batch_id)) != null) {
        return .{ .err = "batch already exists" };
    }

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
    if (codec.batchEncodedSize(&batch) > codec.max_batch_encoded_size)
        return .{ .err = "batch metadata too large" };

    var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
    var bk_buf: keys.KeyBuf = undefined;
    b.set(keys.batchKey(&bk_buf, op.batch_id), codec.encodeBatch(&batch_enc_buf, &batch));

    return .{ .affected = 1 };
}

pub fn applySealBatch(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.SealBatchOp) ops.OpResult {
    if (op.batch_id.len == 0 or op.batch_id.len > types.max_entity_id_len or
        std.mem.indexOfScalar(u8, op.batch_id, 0) != null)
        return .{ .err = "invalid batch_id" };
    if (op.now_ns == 0) return .{ .err = "invalid batch timestamp" };
    var bk_buf: keys.KeyBuf = undefined;
    const bkey = keys.batchKey(&bk_buf, op.batch_id);
    const batch_bytes = b.get(bkey);
    if (batch_bytes == null) {
        return .{ .err = "batch not found" };
    }

    var batch = codec.decodeBatch(batch_bytes.?);
    if (!batch.open) {
        // A callback enqueue may previously have failed under resource
        // pressure after the batch's last job completed. Keep completed_at=0
        // and let an idempotent seal retry finish the callback atomically.
        if (batch.pending == 0 and batch.total > 0 and batch.completed_at_ns == 0) {
            if (!self.enqueueBatchCallback(b, &batch, op.now_ns))
                return .{ .err = "batch callback unavailable" };
            batch.completed_at_ns = op.now_ns;
            var retry_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
            b.set(bkey, codec.encodeBatch(&retry_enc_buf, &batch));
            return .{
                .affected = 1,
                .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
            };
        }
        return .{ .err = "batch already sealed" };
    }

    assert.check(batch.completed_at_ns == 0, "batch is open but has completed_at set", .{});
    batch.open = false;

    // Check if batch is already complete (all jobs finished before seal)
    if (batch.pending == 0 and batch.total > 0) {
        if (!self.enqueueBatchCallback(b, &batch, op.now_ns))
            return .{ .err = "batch callback unavailable" };
        batch.completed_at_ns = op.now_ns;
    }

    var batch_enc_buf: [codec.max_batch_encoded_size]u8 = undefined;
    b.set(bkey, codec.encodeBatch(&batch_enc_buf, &batch));

    return .{
        .affected = 1,
        .notify_queues = if (self.promote_queue_count > 0) self.promoteQueueSlices() else null,
    };
}
