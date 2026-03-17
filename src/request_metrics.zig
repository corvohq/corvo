//! Per-route HTTP request metrics with Prometheus exposition format.
//!
//! Tracks per method+route:
//!   - Total requests (counter)
//!   - Error requests (counter, status >= 400)
//!   - Duration histogram (12 buckets)
//!   - Rate-limited requests (counter)
//! Plus global in-flight gauge.

const std = @import("std");

// ============================================================================
// Histogram buckets (seconds)
// ============================================================================

pub const bucket_count = 12;
pub const buckets = [bucket_count]f64{
    0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
};

// ============================================================================
// Per-route counter
// ============================================================================

pub const RouteCounter = struct {
    total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    throttled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    sum_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    histogram: [bucket_count]std.atomic.Value(u64) = init: {
        var h: [bucket_count]std.atomic.Value(u64) = undefined;
        for (&h) |*v| v.* = std.atomic.Value(u64).init(0);
        break :init h;
    },
};

// ============================================================================
// Route key — fixed-size for lock-free storage
// ============================================================================

pub const RouteKey = struct {
    method: [8]u8 = [_]u8{0} ** 8,
    method_len: u8 = 0,
    route: [128]u8 = [_]u8{0} ** 128,
    route_len: u8 = 0,

    pub fn methodSlice(self: *const RouteKey) []const u8 {
        return self.method[0..self.method_len];
    }

    pub fn routeSlice(self: *const RouteKey) []const u8 {
        return self.route[0..self.route_len];
    }

    pub fn eql(self: *const RouteKey, other: *const RouteKey) bool {
        return self.method_len == other.method_len and
            self.route_len == other.route_len and
            std.mem.eql(u8, self.method[0..self.method_len], other.method[0..other.method_len]) and
            std.mem.eql(u8, self.route[0..self.route_len], other.route[0..other.route_len]);
    }
};

// ============================================================================
// RequestMetrics — fixed-capacity slot array (no allocator needed)
// ============================================================================

const max_routes = 128;

pub const RequestMetrics = struct {
    keys: [max_routes]RouteKey = [_]RouteKey{.{}} ** max_routes,
    counters: [max_routes]RouteCounter = [_]RouteCounter{.{}} ** max_routes,
    used: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    in_flight: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    mutex: std.Thread.Mutex = .{},

    /// Find or create a slot for the given method+route. Returns slot index.
    fn getSlot(self: *RequestMetrics, method: []const u8, route: []const u8) ?u32 {
        const key = makeKey(method, route);

        // Fast path: scan existing slots lock-free.
        const n = self.used.load(.acquire);
        for (0..n) |i| {
            if (self.keys[i].eql(&key)) return @intCast(i);
        }

        // Slow path: create new slot under lock.
        self.mutex.lock();
        defer self.mutex.unlock();

        // Re-check after acquiring lock.
        const n2 = self.used.load(.monotonic);
        for (0..n2) |i| {
            if (self.keys[i].eql(&key)) return @intCast(i);
        }

        if (n2 >= max_routes) return null;
        self.keys[n2] = key;
        self.counters[n2] = .{};
        self.used.store(@intCast(n2 + 1), .release);
        return @intCast(n2);
    }

    /// Record beginning of a request. Returns slot index for finish().
    /// `norm_buf` is a caller-owned buffer for path normalization (thread-safe).
    pub fn begin(self: *RequestMetrics, method: []const u8, path: []const u8, norm_buf: *[128]u8) ?u32 {
        _ = self.in_flight.fetchAdd(1, .monotonic);
        const route = normalizePath(path, norm_buf);
        return self.getSlot(method, route);
    }

    /// Record completion of a request.
    pub fn finish(self: *RequestMetrics, slot: ?u32, status: u16, start_ns: i128) void {
        _ = self.in_flight.fetchSub(1, .monotonic);

        const s = slot orelse return;
        if (s >= max_routes) return;

        const c = &self.counters[s];
        _ = c.total.fetchAdd(1, .monotonic);

        if (status >= 400) {
            _ = c.errors.fetchAdd(1, .monotonic);
        }

        const now_ns: i128 = std.time.nanoTimestamp();
        const elapsed_ns: u64 = @intCast(@max(0, now_ns - start_ns));
        _ = c.sum_ns.fetchAdd(elapsed_ns, .monotonic);
        _ = c.count.fetchAdd(1, .monotonic);

        // Histogram: cumulative buckets.
        const elapsed_s: f64 = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;
        for (0..bucket_count) |i| {
            if (elapsed_s <= buckets[i]) {
                _ = c.histogram[i].fetchAdd(1, .monotonic);
            }
        }
    }

    /// Record a rate-limited request.
    pub fn recordThrottled(self: *RequestMetrics, slot: ?u32) void {
        const s = slot orelse return;
        if (s >= max_routes) return;
        _ = self.counters[s].throttled.fetchAdd(1, .monotonic);
    }

    /// Render all metrics in Prometheus exposition format.
    pub fn renderPrometheus(self: *RequestMetrics, buf: []u8) []const u8 {
        var pos: usize = 0;
        const n = self.used.load(.acquire);
        if (n == 0) return buf[0..0];

        // --- In-flight gauge ---
        pos += (std.fmt.bufPrint(buf[pos..],
            "# HELP corvo_http_requests_in_flight Current in-flight HTTP requests\n" ++
                "# TYPE corvo_http_requests_in_flight gauge\n" ++
                "corvo_http_requests_in_flight {d}\n",
            .{self.in_flight.load(.monotonic)},
        ) catch return buf[0..pos]).len;

        // --- Per-route metrics ---
        pos += (std.fmt.bufPrint(buf[pos..],
            "# HELP corvo_http_requests_total Total HTTP requests\n" ++
                "# TYPE corvo_http_requests_total counter\n",
            .{},
        ) catch return buf[0..pos]).len;

        for (0..n) |i| {
            const k = &self.keys[i];
            const c = &self.counters[i];
            const total = c.total.load(.monotonic);
            if (total == 0) continue;
            pos += (std.fmt.bufPrint(buf[pos..],
                "corvo_http_requests_total{{method=\"{s}\",route=\"{s}\"}} {d}\n",
                .{ k.methodSlice(), k.routeSlice(), total },
            ) catch break).len;
        }

        // --- Errors ---
        pos += (std.fmt.bufPrint(buf[pos..],
            "# HELP corvo_http_request_errors_total HTTP requests with status >= 400\n" ++
                "# TYPE corvo_http_request_errors_total counter\n",
            .{},
        ) catch return buf[0..pos]).len;

        for (0..n) |i| {
            const k = &self.keys[i];
            const c = &self.counters[i];
            const errs = c.errors.load(.monotonic);
            if (errs == 0) continue;
            pos += (std.fmt.bufPrint(buf[pos..],
                "corvo_http_request_errors_total{{method=\"{s}\",route=\"{s}\"}} {d}\n",
                .{ k.methodSlice(), k.routeSlice(), errs },
            ) catch break).len;
        }

        // --- Duration histogram ---
        pos += (std.fmt.bufPrint(buf[pos..],
            "# HELP corvo_http_request_duration_seconds HTTP request duration\n" ++
                "# TYPE corvo_http_request_duration_seconds histogram\n",
            .{},
        ) catch return buf[0..pos]).len;

        for (0..n) |i| {
            const k = &self.keys[i];
            const c = &self.counters[i];
            const cnt = c.count.load(.monotonic);
            if (cnt == 0) continue;

            // Cumulative bucket values.
            var cumulative: u64 = 0;
            for (0..bucket_count) |bi| {
                cumulative += c.histogram[bi].load(.monotonic);
                pos += (std.fmt.bufPrint(buf[pos..],
                    "corvo_http_request_duration_seconds_bucket{{method=\"{s}\",route=\"{s}\",le=\"{d:.3}\"}} {d}\n",
                    .{ k.methodSlice(), k.routeSlice(), buckets[bi], cumulative },
                ) catch break).len;
            }
            pos += (std.fmt.bufPrint(buf[pos..],
                "corvo_http_request_duration_seconds_bucket{{method=\"{s}\",route=\"{s}\",le=\"+Inf\"}} {d}\n" ++
                    "corvo_http_request_duration_seconds_sum{{method=\"{s}\",route=\"{s}\"}} {d:.6}\n" ++
                    "corvo_http_request_duration_seconds_count{{method=\"{s}\",route=\"{s}\"}} {d}\n",
                .{
                    k.methodSlice(), k.routeSlice(), cnt,
                    k.methodSlice(), k.routeSlice(), @as(f64, @floatFromInt(c.sum_ns.load(.monotonic))) / 1_000_000_000.0,
                    k.methodSlice(), k.routeSlice(), cnt,
                },
            ) catch break).len;
        }

        // --- Throttled ---
        var has_throttled = false;
        for (0..n) |i| {
            if (self.counters[i].throttled.load(.monotonic) > 0) {
                has_throttled = true;
                break;
            }
        }
        if (has_throttled) {
            pos += (std.fmt.bufPrint(buf[pos..],
                "# HELP corvo_rate_limit_throttled_total Requests rejected by rate limiter\n" ++
                    "# TYPE corvo_rate_limit_throttled_total counter\n",
                .{},
            ) catch return buf[0..pos]).len;

            for (0..n) |i| {
                const k = &self.keys[i];
                const c = &self.counters[i];
                const t = c.throttled.load(.monotonic);
                if (t == 0) continue;
                pos += (std.fmt.bufPrint(buf[pos..],
                    "corvo_rate_limit_throttled_total{{method=\"{s}\",route=\"{s}\"}} {d}\n",
                    .{ k.methodSlice(), k.routeSlice(), t },
                ) catch break).len;
            }
        }

        return buf[0..pos];
    }
};

// ============================================================================
// Helpers
// ============================================================================

fn makeKey(method: []const u8, route: []const u8) RouteKey {
    var key = RouteKey{};
    const ml = @min(method.len, key.method.len);
    @memcpy(key.method[0..ml], method[0..ml]);
    key.method_len = @intCast(ml);
    const rl = @min(route.len, key.route.len);
    @memcpy(key.route[0..rl], route[0..rl]);
    key.route_len = @intCast(rl);
    return key;
}

/// Normalize a URL path: replace dynamic ID segments with `:id`.
/// Corvo paths: /api/v1/{resource}/{id}[/{action}]
/// IDs look like: job_*, batch_*, apol_*, hex >=16 chars, UUIDs, etc.
fn normalizePath(path: []const u8, buf: *[128]u8) []const u8 {
    if (!std.mem.startsWith(u8, path, "/api/v1/")) return path;

    const api = path["/api/v1".len..];

    var pos: usize = 0;
    const prefix = "/api/v1";
    @memcpy(buf[0..prefix.len], prefix);
    pos = prefix.len;

    var rest = api;
    while (rest.len > 0) {
        // Skip leading /
        if (rest[0] == '/') {
            if (pos < buf.len) {
                buf[pos] = '/';
                pos += 1;
            }
            rest = rest[1..];
            continue;
        }
        // Find end of segment.
        var end: usize = 0;
        while (end < rest.len and rest[end] != '/') end += 1;
        const seg = rest[0..end];
        rest = rest[end..];

        if (looksLikeId(seg)) {
            if (pos + 3 <= buf.len) {
                @memcpy(buf[pos..][0..3], ":id");
                pos += 3;
            }
        } else {
            const len = @min(seg.len, buf.len - pos);
            @memcpy(buf[pos..][0..len], seg[0..len]);
            pos += len;
        }
    }

    return buf[0..pos];
}

fn looksLikeId(seg: []const u8) bool {
    if (seg.len == 0) return false;
    // Known prefixes: job_, batch_, apol_, bulk_, budget_
    const id_prefixes = [_][]const u8{ "job_", "batch_", "apol_", "bulk_", "budget_" };
    for (id_prefixes) |pfx| {
        if (std.mem.startsWith(u8, seg, pfx)) return true;
    }
    // UUID-like: contains hyphens and is 32+ chars (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
    if (seg.len >= 32 and std.mem.indexOfScalar(u8, seg, '-') != null) return true;
    // Hex string >= 16 chars
    if (seg.len >= 16 and isHexLike(seg)) return true;
    return false;
}

fn isHexLike(s: []const u8) bool {
    var hex_count: usize = 0;
    for (s) |c| {
        if ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F') or c == '-' or c == '_') {
            if (c != '-' and c != '_') hex_count += 1;
        } else {
            return false;
        }
    }
    return hex_count >= 12;
}

// ============================================================================
// Tests
// ============================================================================

test "begin and finish record metrics" {
    var m = RequestMetrics{};
    var nb: [128]u8 = undefined;

    const slot = m.begin("POST", "/api/v1/enqueue", &nb);
    try std.testing.expect(slot != null);
    try std.testing.expectEqual(@as(i64, 1), m.in_flight.load(.monotonic));

    m.finish(slot, 200, std.time.nanoTimestamp() - 1_000_000);
    try std.testing.expectEqual(@as(i64, 0), m.in_flight.load(.monotonic));

    const s = slot.?;
    try std.testing.expectEqual(@as(u64, 1), m.counters[s].total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 0), m.counters[s].errors.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.counters[s].count.load(.monotonic));
}

test "error status increments error counter" {
    var m = RequestMetrics{};
    var nb: [128]u8 = undefined;

    const slot = m.begin("GET", "/api/v1/jobs/test", &nb);
    m.finish(slot, 404, std.time.nanoTimestamp());

    const s = slot.?;
    try std.testing.expectEqual(@as(u64, 1), m.counters[s].total.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), m.counters[s].errors.load(.monotonic));
}

test "throttled counter" {
    var m = RequestMetrics{};
    var nb: [128]u8 = undefined;

    const slot = m.begin("POST", "/api/v1/enqueue", &nb);
    m.recordThrottled(slot);
    m.finish(slot, 429, std.time.nanoTimestamp());

    const s = slot.?;
    try std.testing.expectEqual(@as(u64, 1), m.counters[s].throttled.load(.monotonic));
}

test "same route reuses slot" {
    var m = RequestMetrics{};
    var nb: [128]u8 = undefined;

    const s1 = m.begin("POST", "/api/v1/enqueue", &nb);
    m.finish(s1, 200, std.time.nanoTimestamp());
    const s2 = m.begin("POST", "/api/v1/enqueue", &nb);
    m.finish(s2, 200, std.time.nanoTimestamp());

    try std.testing.expectEqual(s1, s2);
    try std.testing.expectEqual(@as(u64, 2), m.counters[s1.?].total.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), m.used.load(.monotonic));
}

test "different routes get different slots" {
    var m = RequestMetrics{};
    var nb: [128]u8 = undefined;

    const s1 = m.begin("POST", "/api/v1/enqueue", &nb);
    m.finish(s1, 200, std.time.nanoTimestamp());
    const s2 = m.begin("POST", "/api/v1/fetch", &nb);
    m.finish(s2, 200, std.time.nanoTimestamp());

    try std.testing.expect(s1.? != s2.?);
    try std.testing.expectEqual(@as(u32, 2), m.used.load(.monotonic));
}

test "route normalization - IDs collapsed" {
    var m = RequestMetrics{};
    var nb: [128]u8 = undefined;

    // Two different job IDs should map to the same slot.
    const s1 = m.begin("GET", "/api/v1/jobs/job_abc123", &nb);
    m.finish(s1, 200, std.time.nanoTimestamp());
    const s2 = m.begin("GET", "/api/v1/jobs/job_def456", &nb);
    m.finish(s2, 200, std.time.nanoTimestamp());

    try std.testing.expectEqual(s1, s2);
    try std.testing.expectEqual(@as(u32, 1), m.used.load(.monotonic));
    try std.testing.expectEqualStrings("/api/v1/jobs/:id", m.keys[s1.?].routeSlice());
}

test "route normalization - action after ID" {
    var nb: [128]u8 = undefined;
    const route = normalizePath("/api/v1/jobs/job_abc123/retry", &nb);
    try std.testing.expectEqualStrings("/api/v1/jobs/:id/retry", route);
}

test "route normalization - non-ID paths unchanged" {
    var nb: [128]u8 = undefined;
    const route = normalizePath("/api/v1/enqueue", &nb);
    try std.testing.expectEqualStrings("/api/v1/enqueue", route);
}

test "route normalization - batch ID" {
    var nb: [128]u8 = undefined;
    const route = normalizePath("/api/v1/batch/batch_xyz789/seal", &nb);
    try std.testing.expectEqualStrings("/api/v1/batch/:id/seal", route);
}

test "route normalization - non-api paths unchanged" {
    var nb: [128]u8 = undefined;
    const route = normalizePath("/healthz", &nb);
    try std.testing.expectEqualStrings("/healthz", route);
}

test "renderPrometheus produces output" {
    var m = RequestMetrics{};
    var nb: [128]u8 = undefined;

    const slot = m.begin("POST", "/api/v1/enqueue", &nb);
    m.finish(slot, 200, std.time.nanoTimestamp() - 5_000_000);

    var buf: [16384]u8 = undefined;
    const output = m.renderPrometheus(&buf);
    try std.testing.expect(output.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, output, "corvo_http_requests_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "corvo_http_requests_in_flight") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "corvo_http_request_duration_seconds_bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "/api/v1/enqueue") != null);
}

test "null slot is safe" {
    var m = RequestMetrics{};
    m.finish(null, 200, std.time.nanoTimestamp());
    m.recordThrottled(null);
}
