//! Settings handler — modify KV-backed settings (API keys, webhooks, audit).

const std = @import("std");
const assert = @import("assert.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

pub fn applyModifySetting(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.ModifySettingOp) ops.OpResult {
    const prefix = settingPrefix(op.setting);

    // api_key_used is mirror-only metadata; skip KV write.
    if (op.setting == .api_key_used) {
        return .{};
    }

    // Audit clear: delete all entries in the audit| prefix range.
    if (op.setting == .audit_entry and op.id.len == 0 and op.data == null) {
        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        @memcpy(lower_buf[0..prefix.len], prefix);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..prefix.len]) orelse return .{};
        b.deleteRange(lower_buf[0..prefix.len], upper);
        return .{ .affected = 1 };
    }

    const key_len = prefix.len + op.id.len + if (op.scope.len > 0) op.scope.len + 1 else 0;
    if (op.id.len == 0 or key_len > keys.max_key_len or
        std.mem.indexOfScalar(u8, op.id, 0) != null or
        std.mem.indexOfScalar(u8, op.scope, 0) != null)
        return .{ .err = "invalid setting key" };

    var ek_buf: keys.KeyBuf = undefined;
    const key = if (op.scope.len > 0)
        keys.settingScopeKey(&ek_buf, prefix, op.scope, op.id)
    else
        keys.settingKey(&ek_buf, prefix, op.id);

    if (op.data) |data| {
        b.set(key, data);
    } else {
        b.delete(key);
    }

    // Update webhook cache on create/delete.
    if (op.setting == .webhook) {
        if (op.data) |data| {
            self.addWebhookToCache(data);
        } else {
            self.removeWebhookFromCache(op.id);
        }
    }

    return .{};
}

fn settingPrefix(s: ops.Setting) []const u8 {
    return switch (s) {
        .api_key, .api_key_used => keys.prefix_apikey,
        .webhook => keys.prefix_webhook,
        .audit_entry => keys.prefix_audit,
    };
}

/// Write an audit log entry into the same KV batch for management operations.
/// Decides which ops are auditable. Non-auditable ops are silently skipped.
pub fn writeAuditEntry(
    _: *OpHandler,
    b: *kv.WriteBatch,
    op_type: ops.OpType,
    data: *const ops.OpData,
    result: *const ops.OpResult,
    actor: []const u8,
    now_ns: u64,
) void {
    // Skip failed ops (nothing happened, nothing to audit).
    if (result.err != null) return;

    var target_buf: [256]u8 = undefined;
    var op_name_buf: [64]u8 = undefined;

    const entry: AuditFields = switch (op_type) {
        .bulk_action => auditBulkAction(&data.bulk_action, &target_buf),
        .queue_config => auditQueueConfig(&data.queue_config, &target_buf),
        .clear_queue => .{ .op_name = "clear_queue", .target = data.clear_queue.queue },
        .delete_queue => .{ .op_name = "delete_queue", .target = data.delete_queue.queue },
        .modify_setting => auditModifySetting(&data.modify_setting, &op_name_buf) orelse return,
        .global_config => .{ .op_name = "global_rate_limit", .target = "" },
        // Not auditable: enqueue, fetch, ack, fail, heartbeat, maintenance,
        // batch_create, batch_seal, cron_*, set_budget, delete_budget.
        .enqueue,
        .fetch,
        .ack,
        .fail,
        .heartbeat,
        .maintenance,
        .batch_create,
        .batch_seal,
        .cron_create,
        .cron_update,
        .cron_delete,
        .cron_trigger,
        .set_budget,
        .delete_budget,
        .multi,
        => return,
    };

    const affected = result.affected;

    // Key: audit|{ts_ns}
    var key_buf: keys.KeyBuf = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{s}{d}", .{ keys.prefix_audit, now_ns }) catch return;

    // JSON value.
    var val_buf: [512]u8 = undefined;
    const val = std.fmt.bufPrint(&val_buf, "{{\"op\":\"{s}\",\"target\":\"{s}\",\"count\":{d},\"actor\":\"{s}\",\"ts\":{d}}}", .{
        entry.op_name,
        entry.target,
        affected,
        actor,
        now_ns,
    }) catch return;

    b.set(key, val);
}

const AuditFields = struct {
    op_name: []const u8,
    target: []const u8,
};

fn auditBulkAction(op: *const ops.BulkActionOp, target_buf: *[256]u8) AuditFields {
    const target = if (op.queue.len > 0)
        std.fmt.bufPrint(target_buf, "queue:{s}", .{op.queue}) catch ""
    else if (op.job_ids.len == 1)
        std.fmt.bufPrint(target_buf, "job:{s}", .{op.job_ids[0]}) catch ""
    else
        std.fmt.bufPrint(target_buf, "jobs:{d}", .{op.job_ids.len}) catch "";

    return .{
        .op_name = op.action.toString(),
        .target = target,
    };
}

fn auditQueueConfig(op: *const ops.QueueOp, target_buf: *[256]u8) AuditFields {
    const target = std.fmt.bufPrint(target_buf, "queue:{s}", .{op.queue}) catch "";
    return .{
        .op_name = op.action.toString(),
        .target = target,
    };
}

fn auditModifySetting(op: *const ops.ModifySettingOp, op_name_buf: *[64]u8) ?AuditFields {
    const action = if (op.data != null) "create" else "delete";
    const setting_name = switch (op.setting) {
        .api_key => "api_key",
        .webhook => "webhook",
        // Don't audit audit entries or key-used metadata.
        .audit_entry, .api_key_used => return null,
    };

    return .{
        .op_name = std.fmt.bufPrint(op_name_buf, "{s}_{s}", .{ setting_name, action }) catch "",
        .target = op.id,
    };
}
