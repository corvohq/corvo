//! Budget handler — set and delete budgets.
//! Ported from Go internal/ops/ops_budget.go.

const std = @import("std");
const types = @import("types.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

pub fn applySetBudget(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.SetBudgetOp) ops.OpResult {
    if (!validBudgetKey(op.scope, op.target)) return .{ .err = "invalid budget key" };
    if (op.created_at_ns == 0) return .{ .err = "invalid budget timestamp" };
    if (!std.math.isFinite(op.daily_usd) or !std.math.isFinite(op.per_job_usd) or
        op.daily_usd < 0 or op.per_job_usd < 0)
        return .{ .err = "invalid budget amount" };
    const budget = types.Budget{
        .scope = op.scope,
        .target = op.target,
        .daily_usd = op.daily_usd,
        .per_job_usd = op.per_job_usd,
        .on_exceed = op.on_exceed,
        .created_at_ns = op.created_at_ns,
    };
    if (codec.budgetEncodedSize(&budget) > codec.max_budget_encoded_size)
        return .{ .err = "budget metadata too large" };

    var budget_enc_buf: [codec.max_budget_encoded_size]u8 = undefined;
    var bk_buf: keys.KeyBuf = undefined;
    b.set(keys.budgetKey(&bk_buf, op.scope, op.target), codec.encodeBudget(&budget_enc_buf, &budget));

    return .{ .affected = 1 };
}

pub fn applyDeleteBudget(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.DeleteBudgetOp) ops.OpResult {
    if (!validBudgetKey(op.scope, op.target)) return .{ .err = "invalid budget key" };
    var bk_buf: keys.KeyBuf = undefined;
    b.delete(keys.budgetKey(&bk_buf, op.scope, op.target));
    return .{};
}

fn validBudgetKey(scope: []const u8, target: []const u8) bool {
    if (scope.len == 0 or scope.len > 255 or target.len > 255) return false;
    if (std.mem.indexOfScalar(u8, scope, 0) != null or
        std.mem.indexOfScalar(u8, target, 0) != null)
        return false;
    return keys.prefix_budget.len + scope.len + 1 + target.len <= keys.max_key_len;
}
