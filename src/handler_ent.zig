//! Enterprise settings handler — modify KV-backed enterprise settings.
//! Ported from Go internal/ops/ops_ent.go.

const assert = @import("assert.zig");
const ops = @import("ops.zig");
const keys = @import("keys.zig");
const kv = @import("kv.zig");
const handler = @import("handler.zig");
const OpHandler = handler.OpHandler;

pub fn applyModifyEntSetting(_: *OpHandler, b: *kv.WriteBatch, op: *const ops.ModifyEntSettingOp) ops.OpResult {
    const prefix = entSettingPrefix(op.setting);

    // api_key_used is mirror-only metadata; skip KV write.
    if (op.setting == .api_key_used) {
        return .{};
    }

    var ek_buf: keys.KeyBuf = undefined;
    const key = if (op.scope.len > 0)
        keys.entSettingScopeKey(&ek_buf, prefix, op.scope, op.id)
    else
        keys.entSettingKey(&ek_buf, prefix, op.id);

    if (op.data) |data| {
        b.set(key, data);
    } else {
        b.delete(key);
    }

    return .{};
}

fn entSettingPrefix(s: ops.EntSetting) []const u8 {
    return switch (s) {
        .ns => keys.prefix_ent_ns,
        .role => keys.prefix_ent_role,
        .api_key => keys.prefix_ent_apikey,
        .webhook => keys.prefix_ent_webhook,
        .sso => keys.prefix_ent_sso,
        .audit_entry => keys.prefix_ent_audit,
        .approval_policy => keys.prefix_ent_approval_policy,
        .ns_rate_limit => keys.prefix_ent_ns_rate_limit,
        .api_key_used => keys.prefix_ent_apikey, // not used, handled above
    };
}
