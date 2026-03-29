//! Server-side performance metrics for Corvo.
//!
//! Lightweight, fixed-bucket histograms and counters. No allocations,
//! no locks — single-threaded pipeline updates these inline.
//! Exposed via /metrics in Prometheus text format.

const std = @import("std");

// ============================================================================
// Latency histogram — fixed Prometheus-style buckets
// ============================================================================

pub const LatencyHistogram = struct {
    /// Cumulative bucket counts (each bucket includes all smaller buckets).
    buckets: [bucket_count]u64 = [_]u64{0} ** bucket_count,
    sum_ns: u64 = 0,
    count: u64 = 0,

    pub const bucket_count = 14;

    /// Bucket boundaries in nanoseconds.
    pub const boundaries_ns = [bucket_count]u64{
        10_000, //     10us
        50_000, //     50us
        100_000, //   100us
        500_000, //   500us
        1_000_000, //   1ms
        5_000_000, //   5ms
        10_000_000, //  10ms
        50_000_000, //  50ms
        100_000_000, // 100ms
        200_000_000, // 200ms
        500_000_000, // 500ms
        1_000_000_000, //  1s
        5_000_000_000, //  5s
        10_000_000_000, // 10s
    };

    /// Bucket boundaries as seconds strings for Prometheus output.
    pub const boundaries_str = [bucket_count][]const u8{
        "0.00001",
        "0.00005",
        "0.0001",
        "0.0005",
        "0.001",
        "0.005",
        "0.01",
        "0.05",
        "0.1",
        "0.2",
        "0.5",
        "1",
        "5",
        "10",
    };

    pub fn observe(self: *LatencyHistogram, ns: u64) void {
        for (&self.buckets, boundaries_ns) |*b, boundary| {
            if (ns <= boundary) b.* += 1;
        }
        self.sum_ns += ns;
        self.count += 1;
    }

    pub fn reset(self: *LatencyHistogram) void {
        self.buckets = [_]u64{0} ** bucket_count;
        self.sum_ns = 0;
        self.count = 0;
    }

    /// Compute approximate percentile from histogram buckets with linear interpolation.
    pub fn percentile(self: *const LatencyHistogram, p: f64) u64 {
        if (self.count == 0) return 0;
        const target: u64 = @intFromFloat(@as(f64, @floatFromInt(self.count)) * p);
        var prev_count: u64 = 0;
        var prev_boundary: u64 = 0;
        for (self.buckets, boundaries_ns) |bucket_count_val, boundary| {
            if (bucket_count_val >= target) {
                // Linear interpolation within this bucket.
                const range = bucket_count_val - prev_count;
                if (range == 0) return boundary;
                const offset = target - prev_count;
                const frac = @as(f64, @floatFromInt(offset)) / @as(f64, @floatFromInt(range));
                return prev_boundary + @as(u64, @intFromFloat(frac * @as(f64, @floatFromInt(boundary - prev_boundary))));
            }
            prev_count = bucket_count_val;
            prev_boundary = boundary;
        }
        return boundaries_ns[bucket_count - 1];
    }
};

// ============================================================================
// Per-queue metrics
// ============================================================================

pub const QueueMetrics = struct {
    enqueued: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
    delivery: LatencyHistogram = .{},
    e2e: LatencyHistogram = .{},
};

// ============================================================================
// Server metrics — system-wide + per-queue
// ============================================================================

pub const max_tracked_queues = 128;

pub const ServerMetrics = struct {
    // System-wide counters.
    enqueued_total: u64 = 0,
    completed_total: u64 = 0,
    failed_total: u64 = 0,

    // System-wide latency histograms.
    delivery: LatencyHistogram = .{},
    e2e: LatencyHistogram = .{},

    // Per-queue metrics (fixed-size array, no allocations).
    queue_names: [max_tracked_queues][64]u8 = undefined,
    queue_name_lens: [max_tracked_queues]u8 = [_]u8{0} ** max_tracked_queues,
    queue_metrics: [max_tracked_queues]QueueMetrics = [_]QueueMetrics{.{}} ** max_tracked_queues,
    queue_count: u16 = 0,

    /// Find or create a per-queue metrics slot. Returns null if at capacity.
    pub fn getQueue(self: *ServerMetrics, name: []const u8) ?*QueueMetrics {
        // Search existing.
        for (0..self.queue_count) |i| {
            if (self.queue_name_lens[i] == name.len and
                std.mem.eql(u8, self.queue_names[i][0..self.queue_name_lens[i]], name))
            {
                return &self.queue_metrics[i];
            }
        }
        // Create new.
        if (self.queue_count >= max_tracked_queues) return null;
        if (name.len > 64) return null;
        const idx = self.queue_count;
        @memcpy(self.queue_names[idx][0..name.len], name);
        self.queue_name_lens[idx] = @intCast(name.len);
        self.queue_metrics[idx] = .{};
        self.queue_count += 1;
        return &self.queue_metrics[idx];
    }

    pub fn queueName(self: *const ServerMetrics, idx: usize) []const u8 {
        return self.queue_names[idx][0..self.queue_name_lens[idx]];
    }

    // --- Recording helpers (called from handlers) ---

    pub fn recordEnqueue(self: *ServerMetrics, queue: []const u8, count: u32) void {
        self.enqueued_total += count;
        if (self.getQueue(queue)) |qm| qm.enqueued += count;
    }

    pub fn recordComplete(self: *ServerMetrics, queue: []const u8, created_at_ns: u64, started_at_ns: u64, completed_at_ns: u64) void {
        self.completed_total += 1;

        // Delivery latency: enqueue → fetch.
        if (started_at_ns > created_at_ns) {
            const delivery_ns = started_at_ns - created_at_ns;
            self.delivery.observe(delivery_ns);
            if (self.getQueue(queue)) |qm| qm.delivery.observe(delivery_ns);
        }

        // E2E latency: enqueue → ack.
        if (completed_at_ns > created_at_ns) {
            const e2e_ns = completed_at_ns - created_at_ns;
            self.e2e.observe(e2e_ns);
            if (self.getQueue(queue)) |qm| qm.e2e.observe(e2e_ns);
        }

        if (self.getQueue(queue)) |qm| qm.completed += 1;
    }

    pub fn recordFail(self: *ServerMetrics, queue: []const u8) void {
        self.failed_total += 1;
        if (self.getQueue(queue)) |qm| qm.failed += 1;
    }

    // --- Prometheus text format output ---

    pub fn writePrometheus(self: *const ServerMetrics, buf: []u8) usize {
        var pos: usize = 0;

        // Throughput counters.
        pos += (std.fmt.bufPrint(buf[pos..],
            \\# HELP corvo_enqueued_total Total jobs enqueued
            \\# TYPE corvo_enqueued_total counter
            \\corvo_enqueued_total {d}
            \\# HELP corvo_completed_total Total jobs completed
            \\# TYPE corvo_completed_total counter
            \\corvo_completed_total {d}
            \\# HELP corvo_failed_total Total jobs failed
            \\# TYPE corvo_failed_total counter
            \\corvo_failed_total {d}
            \\
        , .{ self.enqueued_total, self.completed_total, self.failed_total }) catch return pos).len;

        // System-wide delivery latency histogram.
        pos += writeHistogram(buf[pos..], "corvo_delivery_latency_seconds", "Time from enqueue to fetch", null, &self.delivery);

        // System-wide e2e latency histogram.
        pos += writeHistogram(buf[pos..], "corvo_e2e_latency_seconds", "Time from enqueue to ack", null, &self.e2e);

        // Per-queue counters.
        if (self.queue_count > 0) {
            pos += (std.fmt.bufPrint(buf[pos..],
                \\# HELP corvo_queue_enqueued_total Jobs enqueued per queue
                \\# TYPE corvo_queue_enqueued_total counter
                \\
            , .{}) catch return pos).len;
            for (0..self.queue_count) |i| {
                const qn = self.queueName(i);
                pos += (std.fmt.bufPrint(buf[pos..], "corvo_queue_enqueued_total{{queue=\"{s}\"}} {d}\n", .{ qn, self.queue_metrics[i].enqueued }) catch return pos).len;
            }

            pos += (std.fmt.bufPrint(buf[pos..],
                \\# HELP corvo_queue_completed_total Jobs completed per queue
                \\# TYPE corvo_queue_completed_total counter
                \\
            , .{}) catch return pos).len;
            for (0..self.queue_count) |i| {
                const qn = self.queueName(i);
                pos += (std.fmt.bufPrint(buf[pos..], "corvo_queue_completed_total{{queue=\"{s}\"}} {d}\n", .{ qn, self.queue_metrics[i].completed }) catch return pos).len;
            }

            pos += (std.fmt.bufPrint(buf[pos..],
                \\# HELP corvo_queue_failed_total Jobs failed per queue
                \\# TYPE corvo_queue_failed_total counter
                \\
            , .{}) catch return pos).len;
            for (0..self.queue_count) |i| {
                const qn = self.queueName(i);
                pos += (std.fmt.bufPrint(buf[pos..], "corvo_queue_failed_total{{queue=\"{s}\"}} {d}\n", .{ qn, self.queue_metrics[i].failed }) catch return pos).len;
            }

            // Per-queue delivery latency.
            for (0..self.queue_count) |i| {
                const qn = self.queueName(i);
                if (self.queue_metrics[i].delivery.count > 0) {
                    pos += writeHistogram(buf[pos..], "corvo_queue_delivery_latency_seconds", "", qn, &self.queue_metrics[i].delivery);
                }
            }

            // Per-queue e2e latency.
            for (0..self.queue_count) |i| {
                const qn = self.queueName(i);
                if (self.queue_metrics[i].e2e.count > 0) {
                    pos += writeHistogram(buf[pos..], "corvo_queue_e2e_latency_seconds", "", qn, &self.queue_metrics[i].e2e);
                }
            }
        }

        return pos;
    }
};

fn writeHistogram(buf: []u8, name: []const u8, help: []const u8, queue: ?[]const u8, hist: *const LatencyHistogram) usize {
    var pos: usize = 0;

    if (help.len > 0) {
        pos += (std.fmt.bufPrint(buf[pos..], "# HELP {s} {s}\n# TYPE {s} histogram\n", .{ name, help, name }) catch return pos).len;
    }

    const label_prefix: []const u8 = if (queue) |q| blk: {
        _ = q;
        break :blk "queue=\"";
    } else "";
    _ = label_prefix;

    for (0..LatencyHistogram.bucket_count) |i| {
        if (queue) |q| {
            pos += (std.fmt.bufPrint(buf[pos..], "{s}_bucket{{queue=\"{s}\",le=\"{s}\"}} {d}\n", .{ name, q, LatencyHistogram.boundaries_str[i], hist.buckets[i] }) catch return pos).len;
        } else {
            pos += (std.fmt.bufPrint(buf[pos..], "{s}_bucket{{le=\"{s}\"}} {d}\n", .{ name, LatencyHistogram.boundaries_str[i], hist.buckets[i] }) catch return pos).len;
        }
    }

    // +Inf bucket and sum/count.
    if (queue) |q| {
        pos += (std.fmt.bufPrint(buf[pos..], "{s}_bucket{{queue=\"{s}\",le=\"+Inf\"}} {d}\n{s}_sum{{queue=\"{s}\"}} {d}.{d:0>9}\n{s}_count{{queue=\"{s}\"}} {d}\n", .{
            name, q, hist.count,
            name, q, hist.sum_ns / 1_000_000_000, hist.sum_ns % 1_000_000_000,
            name, q, hist.count,
        }) catch return pos).len;
    } else {
        pos += (std.fmt.bufPrint(buf[pos..], "{s}_bucket{{le=\"+Inf\"}} {d}\n{s}_sum {d}.{d:0>9}\n{s}_count {d}\n", .{
            name, hist.count,
            name, hist.sum_ns / 1_000_000_000, hist.sum_ns % 1_000_000_000,
            name, hist.count,
        }) catch return pos).len;
    }

    return pos;
}
