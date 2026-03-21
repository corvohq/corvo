//! Corvo RPC Benchmark Client
//!
//! Standalone executable that benchmarks the Zig server via binary RPC.
//! Runs enqueue and lifecycle (fetch+ack) phases with configurable
//! concurrency and batch sizes.
//!
//! Usage:
//!   bench-rpc [options]
//!     --server <host:port>   RPC server (default: 127.0.0.1:9878)
//!     --jobs <n>             Total jobs (default: 100000)
//!     --concurrency <n>      Worker threads (default: 8)
//!     --batch <n>            Jobs per batch frame (default: 64)
//!     --queue <name>         Queue name (default: bench.q)

const std = @import("std");
const net = std.net;

// Import RPC protocol from corvo library.
const corvo = @import("corvo");
const rpc = corvo.rpc;

// ============================================================================
// Config
// ============================================================================

const BenchConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9878,
    total_jobs: u32 = 100_000,
    concurrency: u16 = 8,
    batch_size: u16 = 64,
    queue: []const u8 = "bench.q",
};

// ============================================================================
// RPC Client (one per thread)
// ============================================================================

const CLIENT_BUF_SIZE = 65536; // 64KB — plenty for batch-64

const RpcClient = struct {
    stream: net.Stream,
    req_id: u32 = 0,
    // Per-connection buffers.
    send_buf: [CLIENT_BUF_SIZE]u8 = undefined,
    recv_buf: [CLIENT_BUF_SIZE]u8 = undefined,

    fn connect(host: []const u8, port: u16) !RpcClient {
        const addr = try net.Address.parseIp(host, port);
        const stream = try net.tcpConnectToAddress(addr);
        // Disable Nagle for low latency.
        const raw_fd = stream.handle;
        const TCP_NODELAY = 1;
        std.posix.setsockopt(raw_fd, std.posix.IPPROTO.TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        return .{ .stream = stream };
    }

    fn close(self: *RpcClient) void {
        self.stream.close();
    }

    /// Send an enqueue batch. Returns number enqueued.
    fn enqueueBatch(
        self: *RpcClient,
        queue: []const u8,
        id_prefix: []const u8,
        start_idx: u32,
        count: u16,
    ) !u16 {
        self.req_id +%= 1;

        // Encode payload.
        var w = rpc.BufWriter{ .buf = &self.send_buf };
        w.writeU16(count);
        const now_ns: u64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        w.writeU64(now_ns);

        for (0..count) |i| {
            // Queue
            w.writeLenPrefixed(queue);
            // Job ID: "{prefix}-{idx}"
            var id_buf: [64]u8 = undefined;
            const id = std.fmt.bufPrint(&id_buf, "{s}-{d}", .{ id_prefix, start_idx + @as(u32, @intCast(i)) }) catch "err";
            w.writeLenPrefixed(id);
            // Priority
            w.writeU8(50);
            // Max retries
            w.writeU16(3);
            // Backoff
            w.writeU8(0);
            // Base delay ms
            w.writeU32(0);
            // Max delay ms
            w.writeU32(0);
            // Unique period s
            w.writeU32(0);
            // Scheduled at ns
            w.writeU64(0);
            // Expire after ms
            w.writeU32(0);
            // Chain step
            w.writeU16(0);
            // Flags (no optional fields)
            w.writeU16(0);
        }

        try rpc.writeFrame(self.stream, rpc.MSG_ENQUEUE_BATCH, self.req_id, w.slice());

        // Read response.
        const header = try rpc.readHeader(self.stream);
        if (header.msg_type == rpc.MSG_ERROR) {
            // Read and discard error payload.
            if (header.length > 0) {
                try rpc.readExact(self.stream, self.recv_buf[0..header.length]);
            }
            return 0;
        }
        if (header.length > 0) {
            try rpc.readExact(self.stream, self.recv_buf[0..header.length]);
        }

        // Decode: [count:u16][err_code:u8]
        var r = rpc.BufReader{ .data = self.recv_buf[0..header.length] };
        const enqueued = r.readU16() catch 0;
        return enqueued;
    }

    /// Fetch a batch of jobs. Returns the fetched job IDs and queues.
    fn fetchBatch(
        self: *RpcClient,
        queue: []const u8,
        count: u16,
        fetched_ids: []FetchedId,
    ) !u16 {
        self.req_id +%= 1;

        var w = rpc.BufWriter{ .buf = &self.send_buf };
        const now_ns: u64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        w.writeU64(now_ns);
        w.writeU16(count);
        w.writeU32(30_000); // lease_ms
        w.writeLenPrefixed("bench-worker"); // worker_id
        w.writeU8(1); // queue_count
        w.writeLenPrefixed(queue);

        try rpc.writeFrame(self.stream, rpc.MSG_FETCH_BATCH, self.req_id, w.slice());

        const header = try rpc.readHeader(self.stream);
        if (header.msg_type == rpc.MSG_ERROR) {
            if (header.length > 0) {
                try rpc.readExact(self.stream, self.recv_buf[0..header.length]);
            }
            return 0;
        }
        if (header.length > 0) {
            try rpc.readExact(self.stream, self.recv_buf[0..header.length]);
        }

        var r = rpc.BufReader{ .data = self.recv_buf[0..header.length] };
        const fetched_count = r.readU16() catch 0;
        const n = @min(fetched_count, @as(u16, @intCast(fetched_ids.len)));

        for (0..n) |i| {
            const id = r.readLenPrefixed() catch break;
            const q = r.readLenPrefixed() catch break;
            @memcpy(fetched_ids[i].id_buf[0..id.len], id);
            fetched_ids[i].id_len = @intCast(id.len);
            @memcpy(fetched_ids[i].queue_buf[0..q.len], q);
            fetched_ids[i].queue_len = @intCast(q.len);
            // Skip per-job metadata: attempt, max_retries, checkpoint, tags, payload.
            _ = r.readU16() catch break; // attempt
            _ = r.readU16() catch break; // max_retries
            _ = r.readLenPrefixed() catch break; // checkpoint
            _ = r.readLenPrefixed() catch break; // tags
            const pl = r.readU16() catch break; // payload length
            r.skip(pl) catch break; // payload data
        }

        return n;
    }

    /// Ack a batch of jobs. Returns number acked.
    fn ackBatch(self: *RpcClient, acks: []const FetchedId) !u16 {
        self.req_id +%= 1;

        var w = rpc.BufWriter{ .buf = &self.send_buf };
        const now_ns: u64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        w.writeU64(now_ns);
        w.writeU16(@intCast(acks.len));

        for (acks) |a| {
            w.writeLenPrefixed(a.id_buf[0..a.id_len]);
            w.writeLenPrefixed(a.queue_buf[0..a.queue_len]);
            w.writeU8(0); // ack_status: done
            w.writeU8(0); // flags: no optional fields
        }

        try rpc.writeFrame(self.stream, rpc.MSG_ACK_BATCH, self.req_id, w.slice());

        const header = try rpc.readHeader(self.stream);
        if (header.msg_type == rpc.MSG_ERROR) {
            if (header.length > 0) {
                try rpc.readExact(self.stream, self.recv_buf[0..header.length]);
            }
            return 0;
        }
        if (header.length > 0) {
            try rpc.readExact(self.stream, self.recv_buf[0..header.length]);
        }

        var r = rpc.BufReader{ .data = self.recv_buf[0..header.length] };
        const acked = r.readU16() catch 0;
        return acked;
    }
    /// Combined fetch+ack in one round-trip. Acks previous jobs, fetches new ones.
    fn fetchAckBatch(
        self: *RpcClient,
        queue: []const u8,
        count: u16,
        acks: []const FetchedId,
        fetched_ids: []FetchedId,
    ) !u16 {
        self.req_id +%= 1;

        var w = rpc.BufWriter{ .buf = &self.send_buf };
        const now_ns: u64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        w.writeU64(now_ns);
        w.writeU16(count);
        w.writeU32(30_000); // lease_ms
        w.writeLenPrefixed("bench-worker"); // worker_id
        w.writeU8(1); // queue_count
        w.writeLenPrefixed(queue);

        // Ack jobs from previous round
        w.writeU16(@intCast(acks.len));
        for (acks) |a| {
            w.writeLenPrefixed(a.id_buf[0..a.id_len]);
            w.writeLenPrefixed(a.queue_buf[0..a.queue_len]);
            w.writeU8(0); // ack_status: done
            w.writeU8(0); // flags: no optional fields
        }

        try rpc.writeFrame(self.stream, rpc.MSG_FETCH_ACK_BATCH, self.req_id, w.slice());

        const header = try rpc.readHeader(self.stream);
        if (header.msg_type == rpc.MSG_ERROR) {
            if (header.length > 0) {
                try rpc.readExact(self.stream, self.recv_buf[0..header.length]);
            }
            return 0;
        }
        if (header.length > 0) {
            try rpc.readExact(self.stream, self.recv_buf[0..header.length]);
        }

        var r = rpc.BufReader{ .data = self.recv_buf[0..header.length] };
        const fetched_count = r.readU16() catch 0;
        const n = @min(fetched_count, @as(u16, @intCast(fetched_ids.len)));

        for (0..n) |i| {
            const id = r.readLenPrefixed() catch break;
            const q = r.readLenPrefixed() catch break;
            @memcpy(fetched_ids[i].id_buf[0..id.len], id);
            fetched_ids[i].id_len = @intCast(id.len);
            @memcpy(fetched_ids[i].queue_buf[0..q.len], q);
            fetched_ids[i].queue_len = @intCast(q.len);
            // Skip per-job metadata.
            _ = r.readU16() catch break; // attempt
            _ = r.readU16() catch break; // max_retries
            _ = r.readLenPrefixed() catch break; // checkpoint
            _ = r.readLenPrefixed() catch break; // tags
            const pl = r.readU16() catch break;
            r.skip(pl) catch break; // payload data
        }

        return n;
    }
};

const FetchedId = struct {
    id_buf: [64]u8 = undefined,
    id_len: u8 = 0,
    queue_buf: [64]u8 = undefined,
    queue_len: u8 = 0,
};

// ============================================================================
// Bench workers
// ============================================================================

const WorkerResult = struct {
    ops: u64 = 0,
    errors: u64 = 0,
    elapsed_ns: u64 = 0,
};

fn enqueueWorker(config: BenchConfig, worker_id: u16, jobs_per_worker: u32) WorkerResult {
    var client = RpcClient.connect(config.host, config.port) catch return .{ .errors = 1 };
    defer client.close();

    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "w{d}", .{worker_id}) catch "w";

    var total_enqueued: u64 = 0;
    var total_errors: u64 = 0;
    var idx: u32 = 0;
    var timer = std.time.Timer.start() catch return .{ .errors = 1 };

    while (idx < jobs_per_worker) {
        const remaining = jobs_per_worker - idx;
        const batch: u16 = @intCast(@min(config.batch_size, remaining));

        const enqueued = client.enqueueBatch(config.queue, prefix, idx, batch) catch {
            total_errors += 1;
            break;
        };
        total_enqueued += enqueued;
        idx += batch;
    }

    return .{
        .ops = total_enqueued,
        .errors = total_errors,
        .elapsed_ns = timer.read(),
    };
}

fn lifecycleWorker(config: BenchConfig, _: u16, jobs_per_worker: u32) WorkerResult {
    var client = RpcClient.connect(config.host, config.port) catch return .{ .errors = 1 };
    defer client.close();

    var total_ops: u64 = 0;
    var total_errors: u64 = 0;
    var remaining: u32 = jobs_per_worker;
    var timer = std.time.Timer.start() catch return .{ .errors = 1 };

    var fetched_buf: [512]FetchedId = undefined;

    while (remaining > 0) {
        const batch: u16 = @intCast(@min(config.batch_size, remaining));

        // Fetch
        const fetched = client.fetchBatch(config.queue, batch, &fetched_buf) catch {
            total_errors += 1;
            break;
        };

        if (fetched == 0) {
            // No jobs available — yield briefly and retry.
            std.Thread.sleep(100_000); // 100µs
            continue;
        }

        // Ack all fetched
        const acked = client.ackBatch(fetched_buf[0..fetched]) catch {
            total_errors += 1;
            break;
        };

        total_ops += acked;
        remaining -|= @intCast(acked);
    }

    return .{
        .ops = total_ops,
        .errors = total_errors,
        .elapsed_ns = timer.read(),
    };
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var config = BenchConfig{};

    // Parse args.
    var args = std.process.args();
    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--server")) {
            if (args.next()) |v| {
                // Parse host:port
                if (std.mem.indexOfScalar(u8, v, ':')) |colon| {
                    config.host = v[0..colon];
                    config.port = std.fmt.parseInt(u16, v[colon + 1 ..], 10) catch 9878;
                } else {
                    config.host = v;
                }
            }
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            if (args.next()) |v| config.total_jobs = std.fmt.parseInt(u32, v, 10) catch 100_000;
        } else if (std.mem.eql(u8, arg, "--concurrency")) {
            if (args.next()) |v| config.concurrency = std.fmt.parseInt(u16, v, 10) catch 8;
        } else if (std.mem.eql(u8, arg, "--batch")) {
            if (args.next()) |v| config.batch_size = std.fmt.parseInt(u16, v, 10) catch 64;
        } else if (std.mem.eql(u8, arg, "--queue")) {
            if (args.next()) |v| config.queue = v;
        }
    }

    const print = std.debug.print;
    print(
        \\
        \\Corvo RPC Benchmark
        \\  server:      {s}:{d}
        \\  jobs:        {d}
        \\  concurrency: {d}
        \\  batch:       {d}
        \\  queue:       {s}
        \\
        \\
    , .{ config.host, config.port, config.total_jobs, config.concurrency, config.batch_size, config.queue });

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    // ---- Enqueue Phase ----
    print("=== Enqueue Phase ===\n", .{});
    {
        const jobs_per_worker = config.total_jobs / config.concurrency;
        const threads = try alloc.alloc(std.Thread, config.concurrency);
        defer alloc.free(threads);
        const results = try alloc.alloc(WorkerResult, config.concurrency);
        defer alloc.free(results);

        var wall_start = std.time.Timer.start() catch unreachable;

        for (0..config.concurrency) |i| {
            threads[i] = try std.Thread.spawn(.{}, enqueueWorkerThread, .{
                config, @as(u16, @intCast(i)), jobs_per_worker, &results[i],
            });
        }
        for (0..config.concurrency) |i| {
            threads[i].join();
        }

        const wall_ns = wall_start.read();
        var total_ops: u64 = 0;
        var total_errors: u64 = 0;
        for (0..config.concurrency) |i| {
            total_ops += results[i].ops;
            total_errors += results[i].errors;
        }

        const wall_ms = wall_ns / 1_000_000;
        const ops_per_sec = if (wall_ns > 0) total_ops * 1_000_000_000 / wall_ns else 0;
        print("  enqueued: {d} ops in {d}ms = {d} ops/sec", .{ total_ops, wall_ms, ops_per_sec });
        if (total_errors > 0) print(" ({d} errors)", .{total_errors});
        print("\n\n", .{});
    }

    // ---- Lifecycle Phase (fetch + ack) ----
    print("=== Lifecycle Phase (fetch + ack) ===\n", .{});
    {
        const jobs_per_worker = config.total_jobs / config.concurrency;
        const threads = try alloc.alloc(std.Thread, config.concurrency);
        defer alloc.free(threads);
        const results = try alloc.alloc(WorkerResult, config.concurrency);
        defer alloc.free(results);

        var wall_start = std.time.Timer.start() catch unreachable;

        for (0..config.concurrency) |i| {
            threads[i] = try std.Thread.spawn(.{}, lifecycleWorkerThread, .{
                config, @as(u16, @intCast(i)), jobs_per_worker, &results[i],
            });
        }
        for (0..config.concurrency) |i| {
            threads[i].join();
        }

        const wall_ns = wall_start.read();
        var total_ops: u64 = 0;
        var total_errors: u64 = 0;
        for (0..config.concurrency) |i| {
            total_ops += results[i].ops;
            total_errors += results[i].errors;
        }

        const wall_ms = wall_ns / 1_000_000;
        const ops_per_sec = if (wall_ns > 0) total_ops * 1_000_000_000 / wall_ns else 0;
        print("  lifecycle: {d} ops in {d}ms = {d} ops/sec", .{ total_ops, wall_ms, ops_per_sec });
        if (total_errors > 0) print(" ({d} errors)", .{total_errors});
        print("\n\n", .{});
    }
}

fn enqueueWorkerThread(config: BenchConfig, worker_id: u16, jobs_per_worker: u32, result: *WorkerResult) void {
    result.* = enqueueWorker(config, worker_id, jobs_per_worker);
}

fn lifecycleWorkerThread(config: BenchConfig, worker_id: u16, jobs_per_worker: u32, result: *WorkerResult) void {
    result.* = lifecycleWorker(config, worker_id, jobs_per_worker);
}
