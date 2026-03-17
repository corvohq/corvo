//! VOPR Simulator module root.
//!
//! Re-exports all simulator components for testing.

pub const clock = @import("clock.zig");
pub const config = @import("config.zig");
pub const invariants = @import("invariants.zig");
pub const client = @import("client.zig");
pub const sim = @import("sim.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
