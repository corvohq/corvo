//! Settings handler — modify KV-backed settings (API keys, webhooks, audit).

const std = @import("std");
const assert = @import("assert.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

pub fn applyModifySetting(self: *OpHandler, b: *kv.WriteBatch, op: *const ops.ModifySettingOp) ops.OpResult {
    _ = self;
    const prefix = settingPrefix(op.setting);

    // api_key_used is mirror-only metadata; skip KV write.
    if (op.setting == .api_key_used) {
        return .{};
    }

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

    return .{};
}

fn settingPrefix(s: ops.Setting) []const u8 {
    return switch (s) {
        .api_key, .api_key_used => keys.prefix_apikey,
        .webhook => keys.prefix_webhook,
        .audit_entry => keys.prefix_audit,
    };
}
