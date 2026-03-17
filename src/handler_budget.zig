//! Budget handler — set and delete budgets.
//! Ported from Go internal/ops/ops_budget.go.

const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

pub fn applySetBudget(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.SetBudgetOp) ops.OpResult {
    const budget = types.Budget{
        .scope = op.scope,
        .target = op.target,
        .daily_usd = op.daily_usd,
        .per_job_usd = op.per_job_usd,
        .on_exceed = op.on_exceed,
        .created_at_ns = op.created_at_ns,
    };

    var budget_enc_buf: [codec.max_budget_encoded_size]u8 = undefined;
    var bk_buf: keys.KeyBuf = undefined;
    b.set(keys.budgetKey(&bk_buf, op.scope, op.target), codec.encodeBudget(&budget_enc_buf, &budget));

    return .{ .affected = 1 };
}

pub fn applyDeleteBudget(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.DeleteBudgetOp) ops.OpResult {
    var bk_buf: keys.KeyBuf = undefined;
    b.delete(keys.budgetKey(&bk_buf, op.scope, op.target));
    return .{};
}
