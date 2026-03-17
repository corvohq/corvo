//! TigerStyle assertions — panic with context on invariant violations.
//!
//! Use `check` for internal invariants (bugs), errors only at I/O boundaries.
//! In release builds assertions compile away unless using ReleaseSafe.

const std = @import("std");
const builtin = @import("builtin");

/// Assert an internal invariant. Panics with a formatted message on failure.
/// In ReleaseFast/ReleaseSmall, compiles to `unreachable` (UB if violated).
pub fn check(condition: bool, comptime fmt: []const u8, args: anytype) void {
    if (!condition) {
        fail(fmt, args);
    }
}

/// Unconditional assertion failure — always panics with formatted message.
pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    @branchHint(.cold);
    std.debug.panic("assertion failed: " ++ fmt, args);
}

/// Assert that a value is not null, returning the unwrapped value.
pub fn notNull(comptime T: type, val: ?T, comptime fmt: []const u8, args: anytype) T {
    return val orelse {
        fail(fmt, args);
    };
}

test "check passes on true" {
    check(true, "should not fire", .{});
}

test "notNull unwraps value" {
    const v: ?u32 = 42;
    const result = notNull(u32, v, "was null", .{});
    try std.testing.expectEqual(@as(u32, 42), result);
}
