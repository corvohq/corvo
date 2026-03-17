//! Test root for SQLite mirror modules.
//! Separate from main test root to avoid talon memory interaction.

const std = @import("std");

test {
    std.testing.refAllDecls(@import("sqlite.zig"));
    std.testing.refAllDecls(@import("schema.zig"));
    std.testing.refAllDecls(@import("mirror.zig"));
    std.testing.refAllDecls(@import("sqlite_read.zig"));
}
