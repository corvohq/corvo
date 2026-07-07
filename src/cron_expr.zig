//! Cron expression parser + next-fire computation.
//!
//! Supports the standard 5-field cron syntax at minute resolution:
//!   minute(0-59) hour(0-23) day-of-month(1-31) month(1-12) day-of-week(0-6, Sun=0)
//! Each field accepts `*`, `*/step`, a number, `a-b` ranges, `a-b/step`, and
//! comma-separated lists of those. 7 in the day-of-week field is also accepted
//! as Sunday (some crons use 0-7).
//!
//! Computation is in UTC and fully deterministic: nextFire takes the "from"
//! timestamp as an argument (no wall-clock reads), so it is safe to run inside
//! the deterministic pipeline/handler and the simulator.
//!
//! day-of-month / day-of-week semantics follow Vixie cron: when BOTH fields are
//! restricted (not `*`), a day matches if EITHER matches; otherwise the single
//! restricted field must match.

const std = @import("std");

pub const CronError = error{InvalidExpression};

const ns_per_min: u64 = 60 * 1_000_000_000;

/// A parsed field as a bitmask over its value domain.
const Field = struct {
    bits: u64 = 0,

    fn has(self: Field, v: u6) bool {
        return (self.bits & (@as(u64, 1) << v)) != 0;
    }
};

pub const CronExpr = struct {
    minute: Field,
    hour: Field,
    dom: Field,
    month: Field,
    dow: Field,
    dom_restricted: bool,
    dow_restricted: bool,
};

/// Parse one field into a bitmask. `min`/`max` bound the valid values.
/// Returns whether the field was restricted (i.e. not a bare `*`).
fn parseField(spec: []const u8, min: u6, max: u6, out: *Field) CronError!bool {
    out.bits = 0;
    if (spec.len == 0) return CronError.InvalidExpression;

    var restricted = true;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |part_raw| {
        const part = part_raw;
        if (part.len == 0) return CronError.InvalidExpression;

        // Split optional /step.
        var range_spec: []const u8 = part;
        var step: u6 = 1;
        if (std.mem.indexOfScalar(u8, part, '/')) |si| {
            range_spec = part[0..si];
            const step_str = part[si + 1 ..];
            step = parseNum(step_str, 1, max) catch return CronError.InvalidExpression;
            if (step == 0) return CronError.InvalidExpression;
        }

        var lo: u6 = min;
        var hi: u6 = max;
        if (std.mem.eql(u8, range_spec, "*")) {
            // wildcard — full range; still "restricted" only if a step is present.
            if (step == 1) restricted = false;
        } else if (std.mem.indexOfScalar(u8, range_spec, '-')) |di| {
            lo = parseNum(range_spec[0..di], min, max) catch return CronError.InvalidExpression;
            hi = parseNum(range_spec[di + 1 ..], min, max) catch return CronError.InvalidExpression;
        } else {
            lo = parseNum(range_spec, min, max) catch return CronError.InvalidExpression;
            hi = lo;
        }
        if (lo > hi) return CronError.InvalidExpression;

        var v: u6 = lo;
        while (true) : (v += step) {
            out.bits |= (@as(u64, 1) << v);
            if (v > max - step or v + step > hi) break;
        }
        // Ensure hi is included when it lands on a step boundary.
        if (((hi - lo) % step) == 0) out.bits |= (@as(u64, 1) << hi);
    }
    if (out.bits == 0) return CronError.InvalidExpression;
    return restricted;
}

fn parseNum(s: []const u8, min: u6, max: u6) !u6 {
    const n = try std.fmt.parseInt(u32, s, 10);
    if (n < min or n > max) return error.OutOfRange;
    return @intCast(n);
}

/// Parse a 5-field cron expression.
pub fn parse(expr: []const u8) CronError!CronExpr {
    const trimmed = std.mem.trim(u8, expr, " \t");
    var fields: [5][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    while (it.next()) |f| {
        if (n >= 5) return CronError.InvalidExpression;
        fields[n] = f;
        n += 1;
    }
    if (n != 5) return CronError.InvalidExpression;

    var e: CronExpr = undefined;
    _ = try parseField(fields[0], 0, 59, &e.minute);
    _ = try parseField(fields[1], 0, 23, &e.hour);
    e.dom_restricted = try parseField(fields[2], 1, 31, &e.dom);
    _ = try parseField(fields[3], 1, 12, &e.month);
    e.dow_restricted = try parseField(fields[4], 0, 7, &e.dow);
    // Normalise Sunday: accept 7 as 0.
    if (e.dow.has(7)) e.dow.bits |= (@as(u64, 1) << 0);
    return e;
}

const Civil = struct { year: u32, month: u4, day: u5, hour: u5, minute: u6, dow: u3 };

fn civilFromNs(ns: u64) Civil {
    const secs = ns / 1_000_000_000;
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = es.getEpochDay();
    const day_secs = es.getDaySeconds();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    // 1970-01-01 was a Thursday. Sun=0 → Thursday=4.
    const dow: u3 = @intCast((day.day + 4) % 7);
    return .{
        .year = year_day.year,
        .month = month_day.month.numeric(),
        .day = @as(u5, month_day.day_index) + 1,
        .hour = @intCast(day_secs.getHoursIntoDay()),
        .minute = @intCast(day_secs.getMinutesIntoHour()),
        .dow = dow,
    };
}

fn dayMatches(e: *const CronExpr, c: Civil) bool {
    const dom_ok = e.dom.has(@intCast(c.day));
    const dow_ok = e.dow.has(c.dow);
    if (e.dom_restricted and e.dow_restricted) return dom_ok or dow_ok;
    if (e.dom_restricted) return dom_ok;
    if (e.dow_restricted) return dow_ok;
    return true;
}

/// Next fire time strictly after `from_ns`, aligned to the minute, in UTC ns.
/// Returns null if no match within a bounded search window (~4 years), which
/// only happens for an impossible schedule (e.g. Feb 30).
pub fn nextFire(e: *const CronExpr, from_ns: u64) ?u64 {
    // Start at the beginning of the next minute after `from`.
    var t = (from_ns / ns_per_min + 1) * ns_per_min;
    // Bound: 4 years of minutes. Covers leap-year Feb 29 schedules.
    const max_iters: u64 = 4 * 366 * 24 * 60;
    var i: u64 = 0;
    while (i < max_iters) : (i += 1) {
        const c = civilFromNs(t);
        if (e.month.has(@intCast(c.month)) and dayMatches(e, c) and
            e.hour.has(@intCast(c.hour)) and e.minute.has(c.minute))
        {
            return t;
        }
        t += ns_per_min;
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn nsFor(y: u16, mo: u4, d: u5, h: u5, mi: u6) u64 {
    // Build a UTC timestamp via std.time.epoch day math (test helper).
    var days: u64 = 0;
    var yr: u16 = 1970;
    while (yr < y) : (yr += 1) {
        days += if (std.time.epoch.isLeapYear(yr)) @as(u64, 366) else 365;
    }
    var m: u4 = 1;
    while (m < mo) : (m += 1) {
        days += std.time.epoch.getDaysInMonth(y, @enumFromInt(m));
    }
    days += @as(u64, d) - 1;
    const secs = days * 86400 + @as(u64, h) * 3600 + @as(u64, mi) * 60;
    return secs * 1_000_000_000;
}

test "cron parse and next-fire: every minute" {
    const e = try parse("* * * * *");
    const from = nsFor(2026, 3, 15, 10, 30);
    const next = nextFire(&e, from).?;
    try testing.expectEqual(nsFor(2026, 3, 15, 10, 31), next);
}

test "cron: hourly at minute 0" {
    const e = try parse("0 * * * *");
    const from = nsFor(2026, 3, 15, 10, 30);
    try testing.expectEqual(nsFor(2026, 3, 15, 11, 0), nextFire(&e, from).?);
}

test "cron: daily at 09:00" {
    const e = try parse("0 9 * * *");
    // Before 9am → same day 9:00.
    try testing.expectEqual(nsFor(2026, 3, 15, 9, 0), nextFire(&e, nsFor(2026, 3, 15, 8, 0)).?);
    // After 9am → next day 9:00.
    try testing.expectEqual(nsFor(2026, 3, 16, 9, 0), nextFire(&e, nsFor(2026, 3, 15, 10, 0)).?);
}

test "cron: step every 15 minutes" {
    const e = try parse("*/15 * * * *");
    try testing.expectEqual(nsFor(2026, 3, 15, 10, 15), nextFire(&e, nsFor(2026, 3, 15, 10, 3)).?);
    try testing.expectEqual(nsFor(2026, 3, 15, 11, 0), nextFire(&e, nsFor(2026, 3, 15, 10, 47)).?);
}

test "cron: list and range" {
    const e = try parse("30 8-10,18 * * *");
    try testing.expectEqual(nsFor(2026, 3, 15, 8, 30), nextFire(&e, nsFor(2026, 3, 15, 7, 0)).?);
    try testing.expectEqual(nsFor(2026, 3, 15, 18, 30), nextFire(&e, nsFor(2026, 3, 15, 11, 0)).?);
}

test "cron: invalid expressions rejected" {
    try testing.expectError(CronError.InvalidExpression, parse(""));
    try testing.expectError(CronError.InvalidExpression, parse("* * * *"));
    try testing.expectError(CronError.InvalidExpression, parse("60 * * * *"));
    try testing.expectError(CronError.InvalidExpression, parse("* 24 * * *"));
    try testing.expectError(CronError.InvalidExpression, parse("bad * * * *"));
}
