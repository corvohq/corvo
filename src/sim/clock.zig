//! SimClock — deterministic simulated clock.
//!
//! Advances only when told to via advance(). No real-time reads.
//! All times are nanoseconds since epoch (same as Go UnixNano).

const corvo = @import("corvo");
const assert = corvo.assert;

/// Deterministic clock for simulation. Advances only via advance().
/// Thread-safe is not needed — simulator is single-threaded.
pub const SimClock = struct {
    nanos: i64,

    /// Create a clock starting at the given time in nanoseconds.
    pub fn init(start_ns: i64) SimClock {
        assert.check(start_ns >= 0, "SimClock.init: negative start time", .{});
        return .{ .nanos = start_ns };
    }

    /// Returns the current simulated time in nanoseconds.
    pub fn now(self: *const SimClock) i64 {
        return self.nanos;
    }

    /// Advance the clock by delta nanoseconds.
    ///
    /// Precondition: delta must be non-negative (time never goes backward).
    pub fn advance(self: *SimClock, delta_ns: i64) void {
        assert.check(delta_ns >= 0, "SimClock.advance: negative delta", .{});
        self.nanos += delta_ns;
    }
};

/// Global SimClock pointer for clock_fn callback.
/// Set by the simulator before each run. Only one simulation runs at a time.
var global_clock: ?*const SimClock = null;

pub fn setGlobalClock(clock: *const SimClock) void {
    global_clock = clock;
}

pub fn globalClockNow() i64 {
    return if (global_clock) |c| c.now() else 0;
}
