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
///
/// Skips by field granularity so the search stays cheap even for a valid-but-
/// never-matching expression: an excluded month jumps to 00:00 on the 1st of
/// the next month, an excluded day jumps to 00:00 the next day, and only a
/// matching day is walked minute-by-minute. The iteration count is therefore
/// bounded by ~(48 month jumps + 4*366 day jumps + 24*60 minute steps), never
/// the ~2.1M minutes a naive scan of the whole window would take.
pub fn nextFire(e: *const CronExpr, from_ns: u64) ?u64 {
    const ns_per_day: u64 = 24 * 60 * ns_per_min;
    // Start at the beginning of the next minute after `from`.
    var t = (from_ns / ns_per_min + 1) * ns_per_min;
    // Same ~4-year horizon (4 * 366 days) as the old minute-by-minute scan, so
    // the matched timestamp (and the null result for impossible schedules) is
    // identical: every jump below only ever skips minutes the old scan would
    // have rejected, so no earlier match can be stepped over.
    const max_window_min: u64 = 4 * 366 * 24 * 60;
    const deadline = t + max_window_min * ns_per_min;

    while (t < deadline) {
        const c = civilFromNs(t);
        if (!e.month.has(@intCast(c.month))) {
            // No minute in this month can match — jump to 00:00 on the 1st of
            // the next month.
            const days_in_month: u64 = std.time.epoch.getDaysInMonth(@intCast(c.year), @enumFromInt(c.month));
            const day_start = t - (t % ns_per_day);
            t = day_start + (days_in_month - @as(u64, c.day) + 1) * ns_per_day;
            continue;
        }
        if (!dayMatches(e, c)) {
            // dom/dow depend only on the date, so no minute today can match —
            // jump to 00:00 tomorrow.
            const day_start = t - (t % ns_per_day);
            t = day_start + ns_per_day;
            continue;
        }
        if (e.hour.has(@intCast(c.hour)) and e.minute.has(c.minute)) {
            return t;
        }
        // Month and day match but this hour/minute doesn't. Both fields always
        // have at least one value set, so a match is reached within this day.
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

test "cron: impossible schedules return null quickly" {
    // Feb 30 and April 31 never exist; the skip-by-granularity search must
    // reject them via ~day-count jumps, not a 2.1M-minute scan.
    const feb30 = try parse("0 0 30 2 *");
    try testing.expectEqual(@as(?u64, null), nextFire(&feb30, nsFor(2026, 3, 15, 10, 30)));
    const apr31 = try parse("0 0 31 4 *");
    try testing.expectEqual(@as(?u64, null), nextFire(&apr31, nsFor(2026, 1, 1, 0, 0)));
}

test "cron: leap-year Feb 29 found across year boundary" {
    const e = try parse("0 0 29 2 *");
    // From mid-2026 the next Feb 29 is in 2028 (2027 is not a leap year).
    try testing.expectEqual(nsFor(2028, 2, 29, 0, 0), nextFire(&e, nsFor(2026, 3, 15, 10, 30)).?);
    // From just before Feb 29 2028 it fires that same day.
    try testing.expectEqual(nsFor(2028, 2, 29, 0, 0), nextFire(&e, nsFor(2028, 2, 28, 23, 59)).?);
}

test "cron: */5 matches hand-computed values" {
    const e = try parse("*/5 * * * *");
    // Strictly after 10:30 → 10:35 (10:30 itself matches but is excluded).
    try testing.expectEqual(nsFor(2026, 3, 15, 10, 35), nextFire(&e, nsFor(2026, 3, 15, 10, 30)).?);
    // 10:31 → 10:35; 10:57 → 11:00 (hour rollover).
    try testing.expectEqual(nsFor(2026, 3, 15, 10, 35), nextFire(&e, nsFor(2026, 3, 15, 10, 31)).?);
    try testing.expectEqual(nsFor(2026, 3, 15, 11, 0), nextFire(&e, nsFor(2026, 3, 15, 10, 57)).?);
}

test "cron: yearly Jan 1 matches hand-computed values" {
    const e = try parse("0 0 1 1 *");
    // Mid-year → next New Year's midnight, exercising the month-skip path.
    try testing.expectEqual(nsFor(2027, 1, 1, 0, 0), nextFire(&e, nsFor(2026, 3, 15, 10, 30)).?);
    // Exactly at the fire instant → strictly-after gives next year.
    try testing.expectEqual(nsFor(2028, 1, 1, 0, 0), nextFire(&e, nsFor(2027, 1, 1, 0, 0)).?);
    // One minute before → fires this New Year.
    try testing.expectEqual(nsFor(2027, 1, 1, 0, 0), nextFire(&e, nsFor(2026, 12, 31, 23, 59)).?);
}

test "cron: dom/dow OR rule unchanged" {
    // 2026-03-15 is a Sunday (dow=0). "at 12:00 on the 20th OR on Monday".
    const both = try parse("0 12 20 * 1");
    // From Sunday 2026-03-15: Monday 2026-03-16 12:00 comes before the 20th.
    try testing.expectEqual(nsFor(2026, 3, 16, 12, 0), nextFire(&both, nsFor(2026, 3, 15, 10, 0)).?);
    // From Tuesday 2026-03-17: the 20th (Friday) comes before next Monday.
    try testing.expectEqual(nsFor(2026, 3, 20, 12, 0), nextFire(&both, nsFor(2026, 3, 17, 10, 0)).?);

    // Only dom restricted: dow wildcard must not OR-in every day.
    const dom_only = try parse("0 12 20 * *");
    try testing.expectEqual(nsFor(2026, 3, 20, 12, 0), nextFire(&dom_only, nsFor(2026, 3, 15, 10, 0)).?);

    // Only dow restricted: fires on Mondays regardless of dom.
    const dow_only = try parse("0 12 * * 1");
    try testing.expectEqual(nsFor(2026, 3, 16, 12, 0), nextFire(&dow_only, nsFor(2026, 3, 15, 10, 0)).?);
}
