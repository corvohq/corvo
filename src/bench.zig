//! Corvo Self-Contained Benchmark
//!
//! Starts a Corvo server as a child process, runs benchmark phases over
//! binary RPC, prints results, and cleans up.
//!
//! Phases:
//!   1. Enqueue throughput     — batch-enqueue jobs, measure ops/sec
//!   2. Lifecycle throughput   — fetch+ack jobs, measure ops/sec
//!   3. Combined throughput    — enqueue + lifecycle simultaneously
//!   4. Latency percentiles    — measure enqueue-to-fetch latency
//!   5. Connection scaling     — ramp workers, measure throughput + latency
//!
//! After single-node results, starts a 3-node cluster and repeats all phases.
//!
//! Usage:
//!   zig build bench          (builds + runs with ReleaseFast)

const std = @import("std");
const net = std.net;
const corvo = @import("corvo");
const rpc = corvo.rpc;

// ============================================================================
// Constants
// ============================================================================

const TOTAL_JOBS: u32 = 100_000;
const BATCH_SIZE: u16 = 64;
const THREAD_COUNT: u16 = 8;
const WARMUP_OPS: u32 = 5_000;
const PHASE_TIMEOUT_NS: u64 = 5_000_000_000; // 5 seconds
const COMBINED_DURATION_NS: u64 = 10_000_000_000; // 10 seconds
const LATENCY_SAMPLE_COUNT: u32 = 10_000;
const SCALING_STEP_DURATION_NS: u64 = 3_000_000_000; // 3 seconds per step
const SCALING_STEPS = [_]u16{ 8, 32, 128, 512 };

// ============================================================================
// FetchedId — stores job_id + queue from fetch response
// ============================================================================

const FetchedId = struct {
    id_buf: [128]u8 = undefined,
    id_len: u8 = 0,
    queue_buf: [128]u8 = undefined,
    queue_len: u8 = 0,
    lease_token: u64 = 0,
};

// ============================================================================
// RPC Client (one per thread)
// ============================================================================

const CLIENT_BUF_SIZE = 131072; // 128KB — room for batch-64 with headroom

fn writeFrame(stream: net.Stream, msg_type: u8, req_id: u32, payload: []const u8) !void {
    var buf: [rpc.FRAME_HEADER_SIZE]u8 = undefined;
    buf[0] = msg_type;
    std.mem.writeInt(u32, buf[1..5], req_id, .little);
    std.mem.writeInt(u32, buf[5..9], @intCast(payload.len), .little);
    if (payload.len > 0) {
        var iov = [_]std.posix.iovec_const{
            .{ .base = &buf, .len = rpc.FRAME_HEADER_SIZE },
            .{ .base = payload.ptr, .len = payload.len },
        };
        stream.writevAll(&iov) catch return error.ConnectionClosed;
    } else {
        stream.writeAll(&buf) catch return error.ConnectionClosed;
    }
}

const RpcClient = struct {
    stream: net.Stream,
    req_id: u32 = 0,
    send_buf: [CLIENT_BUF_SIZE]u8 = undefined,
    recv_buf: [CLIENT_BUF_SIZE]u8 = undefined,

    fn connect(port: u16) !RpcClient {
        const addr = try net.Address.parseIp("127.0.0.1", port);
        const stream = try net.tcpConnectToAddress(addr);
        const TCP_NODELAY = 1;
        std.posix.setsockopt(stream.handle, std.posix.IPPROTO.TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        // 10 second recv timeout to prevent indefinite blocking.
        const timeval = std.posix.timeval{ .sec = 10, .usec = 0 };
        std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch {};
        return .{ .stream = stream };
    }

    fn close(self: *RpcClient) void {
        self.stream.close();
    }

    /// Enqueue a batch of jobs. Returns count enqueued.
    fn enqueueBatch(self: *RpcClient, queue: []const u8, id_prefix: []const u8, start_idx: u32, count: u16) !u16 {
        self.req_id +%= 1;
        var w = rpc.BufWriter{ .buf = &self.send_buf };
        w.writeU16(count);
        for (0..count) |i| {
            w.writePrefixed(queue);
            var id_buf: [128]u8 = undefined;
            const job_id = std.fmt.bufPrint(&id_buf, "{s}-{d}", .{ id_prefix, start_idx + @as(u32, @intCast(i)) }) catch "err";
            w.writePrefixed(job_id);
            w.writeU8(50); // priority
            w.writeU16(3); // max_retries
            w.writeU8(0); // backoff
            w.writeU32(0); // base_delay_ms
            w.writeU32(0); // max_delay_ms
            w.writeU32(0); // unique_period_s
            w.writeU64(0); // scheduled_at_ns
            w.writeU32(0); // expire_after_ms
            w.writeU16(0); // chain_step
            w.writeU16(0); // flags (no optional fields)
        }
        try writeFrame(self.stream, rpc.MSG_ENQUEUE_BATCH, self.req_id, w.written());

        const header = try rpc.readHeader(self.stream);
        if (header.msg_type == rpc.MSG_ERROR) {
            if (header.payload_len > 0) try rpc.readExact(self.stream, self.recv_buf[0..header.payload_len]);
            return 0;
        }
        if (header.payload_len > 0) try rpc.readExact(self.stream, self.recv_buf[0..header.payload_len]);
        var r = rpc.BufReader{ .data = self.recv_buf[0..header.payload_len] };
        return r.readU16() catch 0;
    }

    /// Enqueue a single job with a specific ID (for latency measurement).
    fn enqueueSingle(self: *RpcClient, queue: []const u8, job_id: []const u8) !u16 {
        self.req_id +%= 1;
        var w = rpc.BufWriter{ .buf = &self.send_buf };
        w.writeU16(1); // count = 1
        w.writePrefixed(queue);
        w.writePrefixed(job_id);
        w.writeU8(50); // priority
        w.writeU16(3); // max_retries
        w.writeU8(0); // backoff
        w.writeU32(0); // base_delay_ms
        w.writeU32(0); // max_delay_ms
        w.writeU32(0); // unique_period_s
        w.writeU64(0); // scheduled_at_ns
        w.writeU32(0); // expire_after_ms
        w.writeU16(0); // chain_step
        w.writeU16(0); // flags
        try writeFrame(self.stream, rpc.MSG_ENQUEUE_BATCH, self.req_id, w.written());

        const header = try rpc.readHeader(self.stream);
        if (header.payload_len > 0) try rpc.readExact(self.stream, self.recv_buf[0..header.payload_len]);
        if (header.msg_type == rpc.MSG_ERROR) return 0;
        var r = rpc.BufReader{ .data = self.recv_buf[0..header.payload_len] };
        return r.readU16() catch 0;
    }

    /// Fetch a batch of jobs. Returns count fetched.
    fn fetchBatch(self: *RpcClient, queue: []const u8, count: u16, fetched_ids: []FetchedId) !u16 {
        self.req_id +%= 1;
        var w = rpc.BufWriter{ .buf = &self.send_buf };
        w.writeU16(count);
        w.writeU32(30_000); // lease_ms
        w.writePrefixed("bench-worker");
        w.writeU8(1); // queue_count
        w.writePrefixed(queue);
        try writeFrame(self.stream, rpc.MSG_FETCH_BATCH, self.req_id, w.written());

        const header = try rpc.readHeader(self.stream);
        if (header.msg_type == rpc.MSG_ERROR) {
            if (header.payload_len > 0) try rpc.readExact(self.stream, self.recv_buf[0..header.payload_len]);
            return 0;
        }
        if (header.payload_len > 0) try rpc.readExact(self.stream, self.recv_buf[0..header.payload_len]);

        var r = rpc.BufReader{ .data = self.recv_buf[0..header.payload_len] };
        const fetched_count = r.readU16() catch 0;
        const n = @min(fetched_count, @as(u16, @intCast(fetched_ids.len)));
        for (0..n) |i| {
            const fid = r.readPrefixed() catch break;
            const q = r.readPrefixed() catch break;
            @memcpy(fetched_ids[i].id_buf[0..fid.len], fid);
            fetched_ids[i].id_len = @intCast(fid.len);
            @memcpy(fetched_ids[i].queue_buf[0..q.len], q);
            fetched_ids[i].queue_len = @intCast(q.len);
            _ = r.readU16() catch break; // attempt
            _ = r.readU16() catch break; // max_retries
            const ckpt_len = r.readU8() catch break;
            r.skip(ckpt_len) catch break;
            const tags_len = r.readU8() catch break;
            r.skip(tags_len) catch break;
            const pl = r.readU32() catch break; // payload length (u32)
            r.skip(pl) catch break;
            fetched_ids[i].lease_token = r.readU64() catch break; // lease_token
        }
        return n;
    }

    /// Ack a batch of jobs. Returns count acked.
    fn ackBatch(self: *RpcClient, acks: []const FetchedId) !u16 {
        self.req_id +%= 1;
        var w = rpc.BufWriter{ .buf = &self.send_buf };
        w.writeU16(@intCast(acks.len));
        for (acks) |a| {
            w.writePrefixed(a.id_buf[0..a.id_len]);
            w.writePrefixed(a.queue_buf[0..a.queue_len]);
            w.writeU8(0); // ack_status: done
            w.writeU8(0); // flags: no optional fields
        }
        try writeFrame(self.stream, rpc.MSG_ACK_BATCH, self.req_id, w.written());

        const header = try rpc.readHeader(self.stream);
        if (header.msg_type == rpc.MSG_ERROR) {
            if (header.payload_len > 0) try rpc.readExact(self.stream, self.recv_buf[0..header.payload_len]);
            return 0;
        }
        if (header.payload_len > 0) try rpc.readExact(self.stream, self.recv_buf[0..header.payload_len]);
        var r = rpc.BufReader{ .data = self.recv_buf[0..header.payload_len] };
        return r.readU16() catch 0;
    }
};

// ============================================================================
// Worker results
// ============================================================================

const WorkerResult = struct {
    ops: u64 = 0,
    errors: u64 = 0,
    elapsed_ns: u64 = 0,
};

// ============================================================================
// Shared state for combined mode + lifecycle
// ============================================================================

var g_stop = std.atomic.Value(bool).init(false);
var g_lifecycle_done = std.atomic.Value(u64).init(0);
var g_enqueue_done = std.atomic.Value(u64).init(0);

// ============================================================================
// Phase 1: Enqueue throughput
// ============================================================================

fn enqueueWorkerFn(port: u16, worker_id: u16, total_per_worker: u32, queue: []const u8, result: *WorkerResult) void {
    var client = RpcClient.connect(port) catch {
        result.* = .{ .errors = 1 };
        return;
    };
    defer client.close();

    var prefix_buf: [32]u8 = undefined;
    const ts: u32 = @truncate(@as(u64, @intCast(std.time.milliTimestamp())));
    const prefix = std.fmt.bufPrint(&prefix_buf, "{d}w{d}", .{ ts, worker_id }) catch "w";

    var total_enqueued: u64 = 0;
    var total_errors: u64 = 0;
    var idx: u32 = 0;
    var timer = std.time.Timer.start() catch {
        result.* = .{ .errors = 1 };
        return;
    };

    while (idx < total_per_worker) {
        // Check timeout.
        if (timer.read() > PHASE_TIMEOUT_NS) break;
        if (g_stop.load(.monotonic)) break;

        const remaining = total_per_worker - idx;
        const batch: u16 = @intCast(@min(BATCH_SIZE, remaining));
        const enqueued = client.enqueueBatch(queue, prefix, idx, batch) catch {
            total_errors += 1;
            break;
        };
        total_enqueued += enqueued;
        idx += batch;
    }

    result.* = .{ .ops = total_enqueued, .errors = total_errors, .elapsed_ns = timer.read() };
}

fn runEnqueuePhase(alloc: std.mem.Allocator, port: u16, total_jobs: u32, thread_count: u16, queue: []const u8) !PhaseResult {
    const jobs_per_worker = total_jobs / thread_count;
    const threads = try alloc.alloc(std.Thread, thread_count);
    defer alloc.free(threads);
    const results = try alloc.alloc(WorkerResult, thread_count);
    defer alloc.free(results);

    g_stop.store(false, .monotonic);
    var wall = std.time.Timer.start() catch unreachable;

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, enqueueWorkerFn, .{
            port, @as(u16, @intCast(i)), jobs_per_worker, queue, &results[i],
        });
    }
    for (0..thread_count) |i| threads[i].join();

    const wall_ns = wall.read();
    var total_ops: u64 = 0;
    var total_errors: u64 = 0;
    for (results) |r| {
        total_ops += r.ops;
        total_errors += r.errors;
    }

    const timed_out = wall_ns > PHASE_TIMEOUT_NS;
    return .{ .ops = total_ops, .errors = total_errors, .wall_ns = wall_ns, .timed_out = timed_out, .target = total_jobs };
}

// ============================================================================
// Phase 2: Lifecycle throughput (fetch + ack)
// ============================================================================

fn lifecycleWorkerFn(port: u16, target_per_worker: u32, queue: []const u8, result: *WorkerResult) void {
    var client = RpcClient.connect(port) catch {
        result.* = .{ .errors = 1 };
        return;
    };
    defer client.close();

    // 100ms recv timeout for quick re-subscribe on idle.
    const timeval = std.posix.timeval{ .sec = 0, .usec = 100_000 };
    std.posix.setsockopt(client.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch {};

    var total_ops: u64 = 0;
    var total_errors: u64 = 0;
    var timer = std.time.Timer.start() catch {
        result.* = .{ .errors = 1 };
        return;
    };

    var fetched_buf: [512]FetchedId = undefined;

    // Subscribe — server pushes FETCH_BATCH_RESP when jobs are available.
    // Acks automatically replenish prefetch (server-side), so we only
    // re-subscribe on timeout (no jobs available).
    sendSubscribe(&client, queue, BATCH_SIZE) catch {
        result.* = .{ .errors = 1 };
        return;
    };

    while (total_ops < target_per_worker) {
        if (timer.read() > PHASE_TIMEOUT_NS) break;
        if (g_stop.load(.monotonic)) break;

        const header = rpc.readHeader(client.stream) catch {
            // Timeout — re-subscribe.
            sendSubscribe(&client, queue, BATCH_SIZE) catch break;
            continue;
        };

        if (header.payload_len > 0) {
            rpc.readExact(client.stream, client.recv_buf[0..header.payload_len]) catch break;
        }

        if (header.msg_type == rpc.MSG_FETCH_BATCH_RESP) {
            const fetched = parseFetchPayload(client.recv_buf[0..header.payload_len], &fetched_buf);
            if (fetched > 0) {
                // Ack — server auto-replenishes prefetch and pushes more.
                sendAck(&client, fetched_buf[0..fetched]) catch break;
                total_ops += fetched;
            }
        } else if (header.msg_type == rpc.MSG_ERROR) {
            total_errors += 1;
        }
        // ACK_BATCH_RESP: ignore (fire-and-forget ack)
    }

    result.* = .{ .ops = total_ops, .errors = total_errors, .elapsed_ns = timer.read() };
}

fn runLifecyclePhase(alloc: std.mem.Allocator, port: u16, total_jobs: u32, thread_count: u16, queue: []const u8) !PhaseResult {
    const jobs_per_worker = total_jobs / thread_count;
    const threads = try alloc.alloc(std.Thread, thread_count);
    defer alloc.free(threads);
    const results = try alloc.alloc(WorkerResult, thread_count);
    defer alloc.free(results);

    g_stop.store(false, .monotonic);
    var wall = std.time.Timer.start() catch unreachable;

    for (0..thread_count) |i| {
        threads[i] = try std.Thread.spawn(.{}, lifecycleWorkerFn, .{
            port, jobs_per_worker, queue, &results[i],
        });
    }
    for (0..thread_count) |i| threads[i].join();

    const wall_ns = wall.read();
    var total_ops: u64 = 0;
    var total_errors: u64 = 0;
    for (results) |r| {
        total_ops += r.ops;
        total_errors += r.errors;
    }

    const timed_out = wall_ns > PHASE_TIMEOUT_NS;
    return .{ .ops = total_ops, .errors = total_errors, .wall_ns = wall_ns, .timed_out = timed_out, .target = total_jobs };
}

// ============================================================================
// Phase 3: Combined throughput
// ============================================================================

fn combinedEnqueueWorkerFn(port: u16, worker_id: u16, queue: []const u8, result: *WorkerResult) void {
    var client = RpcClient.connect(port) catch {
        result.* = .{ .errors = 1 };
        return;
    };
    defer client.close();

    var prefix_buf: [32]u8 = undefined;
    const ts: u32 = @truncate(@as(u64, @intCast(std.time.milliTimestamp())));
    const prefix = std.fmt.bufPrint(&prefix_buf, "c{d}w{d}", .{ ts, worker_id }) catch "w";

    var total_enqueued: u64 = 0;
    var total_errors: u64 = 0;
    var idx: u32 = 0;
    var timer = std.time.Timer.start() catch {
        result.* = .{ .errors = 1 };
        return;
    };

    while (timer.read() < COMBINED_DURATION_NS) {
        if (g_stop.load(.monotonic)) break;
        const enqueued = client.enqueueBatch(queue, prefix, idx, BATCH_SIZE) catch {
            total_errors += 1;
            break;
        };
        total_enqueued += enqueued;
        _ = g_enqueue_done.fetchAdd(enqueued, .monotonic);
        idx += BATCH_SIZE;
    }

    result.* = .{ .ops = total_enqueued, .errors = total_errors, .elapsed_ns = timer.read() };
}

fn combinedLifecycleWorkerFn(port: u16, queue: []const u8, result: *WorkerResult) void {
    var client = RpcClient.connect(port) catch {
        result.* = .{ .errors = 1 };
        return;
    };
    defer client.close();

    // 100ms recv timeout.
    const timeval = std.posix.timeval{ .sec = 0, .usec = 100_000 };
    std.posix.setsockopt(client.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch {};

    var total_ops: u64 = 0;
    var total_errors: u64 = 0;
    var timer = std.time.Timer.start() catch {
        result.* = .{ .errors = 1 };
        return;
    };
    var fetched_buf: [512]FetchedId = undefined;

    // Subscribe — acks auto-replenish prefetch on server side.
    sendSubscribe(&client, queue, BATCH_SIZE) catch {
        result.* = .{ .errors = 1 };
        return;
    };

    while (timer.read() < COMBINED_DURATION_NS) {
        if (g_stop.load(.monotonic)) break;

        const header = rpc.readHeader(client.stream) catch {
            // Timeout — re-subscribe.
            sendSubscribe(&client, queue, BATCH_SIZE) catch break;
            continue;
        };

        if (header.payload_len > 0) {
            rpc.readExact(client.stream, client.recv_buf[0..header.payload_len]) catch break;
        }

        if (header.msg_type == rpc.MSG_FETCH_BATCH_RESP) {
            const fetched = parseFetchPayload(client.recv_buf[0..header.payload_len], &fetched_buf);
            if (fetched > 0) {
                sendAck(&client, fetched_buf[0..fetched]) catch break;
                total_ops += fetched;
                _ = g_lifecycle_done.fetchAdd(fetched, .monotonic);
            }
        } else if (header.msg_type == rpc.MSG_ERROR) {
            total_errors += 1;
        }
    }

    result.* = .{ .ops = total_ops, .errors = total_errors, .elapsed_ns = timer.read() };
}

/// Send a fetch subscribe frame (fire-and-forget).
fn sendSubscribe(client: *RpcClient, queue: []const u8, prefetch: u16) !void {
    client.req_id +%= 1;
    var w = rpc.BufWriter{ .buf = &client.send_buf };
    w.writeU16(prefetch);
    w.writeU32(30_000); // lease_ms
    w.writePrefixed("bench-worker");
    w.writeU8(1); // queue_count
    w.writePrefixed(queue);
    try writeFrame(client.stream, rpc.MSG_FETCH_BATCH, client.req_id, w.written());
}

/// Send ack batch (fire-and-forget).
fn sendAck(client: *RpcClient, acks: []const FetchedId) !void {
    client.req_id +%= 1;
    var w = rpc.BufWriter{ .buf = &client.send_buf };
    w.writeU16(@intCast(acks.len));
    for (acks) |a| {
        w.writePrefixed(a.id_buf[0..a.id_len]);
        w.writePrefixed(a.queue_buf[0..a.queue_len]);
        w.writeU8(0); // ack_status: done
        w.writeU8(0); // flags
    }
    try writeFrame(client.stream, rpc.MSG_ACK_BATCH, client.req_id, w.written());
}

/// Parse FETCH_BATCH_RESP payload into fetched IDs.
fn parseFetchPayload(payload: []const u8, fetched_ids: []FetchedId) u16 {
    var r = rpc.BufReader{ .data = payload };
    const fetched_count = r.readU16() catch return 0;
    const n = @min(fetched_count, @as(u16, @intCast(fetched_ids.len)));
    for (0..n) |i| {
        const fid = r.readPrefixed() catch break;
        const q = r.readPrefixed() catch break;
        @memcpy(fetched_ids[i].id_buf[0..fid.len], fid);
        fetched_ids[i].id_len = @intCast(fid.len);
        @memcpy(fetched_ids[i].queue_buf[0..q.len], q);
        fetched_ids[i].queue_len = @intCast(q.len);
        _ = r.readU16() catch break; // attempt
        _ = r.readU16() catch break; // max_retries
        const ckpt_len = r.readU8() catch break;
        r.skip(ckpt_len) catch break;
        const tags_len = r.readU8() catch break;
        r.skip(tags_len) catch break;
        const pl = r.readU32() catch break; // payload length (u32)
        r.skip(pl) catch break;
        _ = r.readU64() catch break; // lease_token
    }
    return n;
}

const CombinedResult = struct {
    enqueue_ops: u64 = 0,
    lifecycle_ops: u64 = 0,
    enqueue_errors: u64 = 0,
    lifecycle_errors: u64 = 0,
    wall_ns: u64 = 0,
};

fn runCombinedPhase(alloc: std.mem.Allocator, port: u16, queue: []const u8) !CombinedResult {
    const enq_threads: u16 = 4;
    const lc_threads: u16 = 4;
    const total_threads = enq_threads + lc_threads;

    const threads = try alloc.alloc(std.Thread, total_threads);
    defer alloc.free(threads);
    const enq_results = try alloc.alloc(WorkerResult, enq_threads);
    defer alloc.free(enq_results);
    const lc_results = try alloc.alloc(WorkerResult, lc_threads);
    defer alloc.free(lc_results);

    g_stop.store(false, .monotonic);
    g_enqueue_done.store(0, .monotonic);
    g_lifecycle_done.store(0, .monotonic);

    var wall = std.time.Timer.start() catch unreachable;

    // Spawn lifecycle workers first so they are ready.
    for (0..lc_threads) |i| {
        threads[enq_threads + i] = try std.Thread.spawn(.{}, combinedLifecycleWorkerFn, .{
            port, queue, &lc_results[i],
        });
    }

    // Brief pause for consumers to connect.
    std.Thread.sleep(2_000_000); // 2ms

    // Spawn enqueue workers.
    for (0..enq_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, combinedEnqueueWorkerFn, .{
            port, @as(u16, @intCast(i)), queue, &enq_results[i],
        });
    }

    for (threads) |t| t.join();
    const wall_ns = wall.read();

    var enq_ops: u64 = 0;
    var enq_errors: u64 = 0;
    for (enq_results) |r| {
        enq_ops += r.ops;
        enq_errors += r.errors;
    }
    var lc_ops: u64 = 0;
    var lc_errors: u64 = 0;
    for (lc_results) |r| {
        lc_ops += r.ops;
        lc_errors += r.errors;
    }

    return .{
        .enqueue_ops = enq_ops,
        .lifecycle_ops = lc_ops,
        .enqueue_errors = enq_errors,
        .lifecycle_errors = lc_errors,
        .wall_ns = wall_ns,
    };
}

// ============================================================================
// Phase 4: Latency percentiles
// ============================================================================

fn runLatencyPhase(port: u16, queue: []const u8) !LatencyResult {
    // Single connection — enqueue one job, then immediately fetch on same conn.
    // This ensures both operations are in the same or adjacent server ticks.
    var client = RpcClient.connect(port) catch return .{};
    defer client.close();

    var latencies: [LATENCY_SAMPLE_COUNT]u64 = undefined;
    var sample_count: u32 = 0;

    var timer = std.time.Timer.start() catch return .{};
    var fetched_buf: [8]FetchedId = undefined;

    // Warmup: enqueue+fetch a few jobs to prime the pipeline.
    for (0..50) |wi| {
        var warmup_id_buf: [128]u8 = undefined;
        const warmup_id = std.fmt.bufPrint(&warmup_id_buf, "wl-{d}", .{wi}) catch continue;
        _ = client.enqueueSingle(queue, warmup_id) catch continue;
        const f = client.fetchBatch(queue, 1, &fetched_buf) catch continue;
        if (f > 0) {
            _ = client.ackBatch(fetched_buf[0..f]) catch {};
        }
    }

    // Measure: enqueue one job at a time, immediately fetch, measure delta.
    var consecutive_errors: u32 = 0;
    var seq: u32 = 0;
    while (sample_count < LATENCY_SAMPLE_COUNT) {
        if (timer.read() > PHASE_TIMEOUT_NS) break;
        if (consecutive_errors > 50) break;

        const enqueue_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
        var id_buf: [128]u8 = undefined;
        seq += 1;
        const job_id = std.fmt.bufPrint(&id_buf, "l-{d}-{d}", .{ enqueue_ns, seq }) catch continue;

        const enqueued = client.enqueueSingle(queue, job_id) catch {
            consecutive_errors += 1;
            continue;
        };
        if (enqueued == 0) {
            consecutive_errors += 1;
            continue;
        }

        // Fetch — retry a few times since cluster replication may delay commit.
        var fetched: u16 = 0;
        for (0..20) |_| {
            fetched = client.fetchBatch(queue, 1, &fetched_buf) catch break;
            if (fetched > 0) break;
            std.Thread.sleep(100_000); // 100us
        }
        if (fetched > 0) {
            const fetch_ns = @as(u64, @intCast(std.time.nanoTimestamp()));
            latencies[sample_count] = fetch_ns - enqueue_ns;
            sample_count += 1;
            consecutive_errors = 0;
            _ = client.ackBatch(fetched_buf[0..fetched]) catch {};
        } else {
            consecutive_errors += 1;
        }
    }

    if (sample_count == 0) return .{};

    // Sort and compute percentiles.
    std.mem.sort(u64, latencies[0..sample_count], {}, std.sort.asc(u64));

    return .{
        .p50 = latencies[sample_count * 50 / 100],
        .p95 = latencies[sample_count * 95 / 100],
        .p99 = latencies[sample_count * 99 / 100],
        .p999 = latencies[@min(sample_count - 1, sample_count * 999 / 1000)],
        .samples = sample_count,
        .timed_out = timer.read() > PHASE_TIMEOUT_NS,
    };
}

const LatencyResult = struct {
    p50: u64 = 0,
    p95: u64 = 0,
    p99: u64 = 0,
    p999: u64 = 0,
    samples: u32 = 0,
    timed_out: bool = false,
};

// ============================================================================
// Phase 5: Connection scaling
// ============================================================================

const ScalingStepResult = struct {
    p50: u64 = 0,
    p99: u64 = 0,
    ops_sec: u64 = 0,
    workers: u16 = 0,
    ok: bool = false,
};

var g_scaling_stop = std.atomic.Value(bool).init(false);

const ScalingWorkerResult = struct {
    ops: u64 = 0,
    latencies: [8192]u64 = undefined,
    latency_count: u32 = 0,
};

fn scalingWorkerFn(port: u16, worker_id: u16, result: *ScalingWorkerResult) void {
    _ = worker_id;
    var client = RpcClient.connect(port) catch {
        return;
    };
    defer client.close();

    var timer = std.time.Timer.start() catch return;
    var ops: u64 = 0;
    var latency_count: u32 = 0;
    var fetched_buf: [8]FetchedId = undefined;
    var id_buf: [128]u8 = undefined;

    while (!g_scaling_stop.load(.monotonic)) {
        if (timer.read() > SCALING_STEP_DURATION_NS) break;

        const start_ns = timer.read();

        // Enqueue 1 job.
        const job_id = std.fmt.bufPrint(&id_buf, "s-{d}-{d}", .{ @as(u64, @intCast(std.time.nanoTimestamp())), ops }) catch continue;
        const enqueued = client.enqueueSingle("bench.scale", job_id) catch break;
        if (enqueued == 0) continue;

        // Fetch 1 job — retry for cluster replication delay.
        var fetched: u16 = 0;
        for (0..20) |_| {
            fetched = client.fetchBatch("bench.scale", 1, &fetched_buf) catch break;
            if (fetched > 0) break;
            std.Thread.sleep(100_000); // 100us
        }
        if (fetched == 0) continue;

        // Ack 1 job.
        _ = client.ackBatch(fetched_buf[0..fetched]) catch break;

        ops += 1;
        const elapsed = timer.read() - start_ns;
        if (latency_count < result.latencies.len) {
            result.latencies[latency_count] = elapsed;
            latency_count += 1;
        }
    }

    result.ops = ops;
    result.latency_count = latency_count;
}

fn runScalingStep(alloc: std.mem.Allocator, port: u16, worker_count: u16) !ScalingStepResult {
    const threads = try alloc.alloc(std.Thread, worker_count);
    defer alloc.free(threads);
    const results = try alloc.alloc(ScalingWorkerResult, worker_count);
    defer alloc.free(results);

    for (results) |*r| {
        r.* = .{};
    }

    g_scaling_stop.store(false, .monotonic);
    var wall = std.time.Timer.start() catch unreachable;

    for (0..worker_count) |i| {
        threads[i] = std.Thread.spawn(.{}, scalingWorkerFn, .{
            port, @as(u16, @intCast(i)), &results[i],
        }) catch {
            // If we can't spawn all threads, stop and measure what we have.
            g_scaling_stop.store(true, .monotonic);
            for (0..i) |j| threads[j].join();
            return .{ .workers = worker_count };
        };
    }

    for (0..worker_count) |i| threads[i].join();
    const wall_ns = wall.read();

    // Aggregate ops.
    var total_ops: u64 = 0;
    var total_latency_count: u32 = 0;
    for (results) |r| {
        total_ops += r.ops;
        total_latency_count += r.latency_count;
    }

    if (total_latency_count == 0) {
        return .{ .workers = worker_count };
    }

    // Collect all latency samples into one sorted array.
    const all_latencies = try alloc.alloc(u64, total_latency_count);
    defer alloc.free(all_latencies);
    var idx: u32 = 0;
    for (results) |r| {
        for (0..r.latency_count) |li| {
            all_latencies[idx] = r.latencies[li];
            idx += 1;
        }
    }
    std.mem.sort(u64, all_latencies, {}, std.sort.asc(u64));

    const ops_sec = if (wall_ns > 0) total_ops * 1_000_000_000 / wall_ns else 0;

    return .{
        .p50 = all_latencies[total_latency_count * 50 / 100],
        .p99 = all_latencies[@min(total_latency_count - 1, total_latency_count * 99 / 100)],
        .ops_sec = ops_sec,
        .workers = worker_count,
        .ok = true,
    };
}

fn runScalingPhase(alloc: std.mem.Allocator, port: u16) ![SCALING_STEPS.len]ScalingStepResult {
    var results: [SCALING_STEPS.len]ScalingStepResult = undefined;
    for (SCALING_STEPS, 0..) |worker_count, i| {
        results[i] = try runScalingStep(alloc, port, worker_count);
    }
    return results;
}

// ============================================================================
// Phase result
// ============================================================================

const PhaseResult = struct {
    ops: u64 = 0,
    errors: u64 = 0,
    wall_ns: u64 = 0,
    timed_out: bool = false,
    target: u32 = 0,
};

// ============================================================================
// Server management — start/stop child process
// ============================================================================

const ServerHandle = struct {
    child: std.process.Child,
    port: u16,
    data_dir: [128]u8,
    data_dir_len: usize,

    fn stop(self: *ServerHandle) void {
        const pid = self.child.id;
        std.posix.kill(pid, std.posix.SIG.KILL) catch {};
        _ = self.child.wait() catch {};
    }

    fn cleanup(self: *ServerHandle) void {
        self.stop();
        // Remove temp dir.
        const dir_path = self.data_dir[0..self.data_dir_len];
        std.fs.cwd().deleteTree(dir_path) catch {};
    }
};

fn startServer(alloc: std.mem.Allocator) !ServerHandle {
    // Pick a random port in 20000-30000.
    const seed = @as(u64, @intCast(std.time.nanoTimestamp()));
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const port = 20000 + random.intRangeAtMost(u16, 0, 10000);

    // Create temp dir.
    var data_dir: [128]u8 = undefined;
    const data_dir_slice = std.fmt.bufPrint(&data_dir, "/tmp/corvo-bench-{d}", .{port}) catch unreachable;
    const data_dir_len = data_dir_slice.len;

    // Ensure temp dir exists (delete if leftover from previous run).
    std.fs.cwd().deleteTree(data_dir_slice) catch {};
    std.fs.cwd().makePath(data_dir_slice) catch {};

    // Format port as string.
    var port_buf: [8]u8 = undefined;
    const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch unreachable;

    // Use the ReleaseFast server binary built by the bench target.
    const server_path = "zig-out/bin/corvo-bench-server";

    var child = std.process.Child.init(
        &.{ server_path, "--port", port_str, "--data-dir", data_dir_slice },
        alloc,
    );
    child.stderr_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    // Wait for server to be ready by reading stderr for "listening on".
    const stderr = child.stderr orelse return error.NoStderr;
    var read_buf: [4096]u8 = undefined;
    var filled: usize = 0;
    const deadline = std.time.nanoTimestamp() + 10_000_000_000; // 10s
    while (std.time.nanoTimestamp() < deadline) {
        const n = stderr.read(read_buf[filled..]) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(10_000_000); // 10ms
                continue;
            }
            return err;
        };
        if (n == 0) {
            std.Thread.sleep(10_000_000);
            continue;
        }
        filled += n;
        if (std.mem.indexOf(u8, read_buf[0..filled], "listening on") != null) {
            break;
        }
        if (filled >= read_buf.len) {
            // Buffer full, server probably started but we missed the line.
            break;
        }
    }

    // Verify the server is actually reachable.
    var attempts: u32 = 0;
    while (attempts < 50) : (attempts += 1) {
        if (net.tcpConnectToAddress(net.Address.parseIp("127.0.0.1", port) catch unreachable)) |stream| {
            stream.close();
            return .{
                .child = child,
                .port = port,
                .data_dir = data_dir,
                .data_dir_len = data_dir_len,
            };
        } else |_| {}
        std.Thread.sleep(100_000_000); // 100ms
    }

    return error.ServerDidNotStart;
}

// ============================================================================
// Cluster management — 3-node cluster
// ============================================================================

const ClusterHandle = struct {
    servers: [3]ServerHandle,
    leader_port: u16,
    count: u8,

    fn cleanup(self: *ClusterHandle) void {
        for (0..self.count) |i| {
            self.servers[i].cleanup();
        }
    }
};

fn startCluster(alloc: std.mem.Allocator) !ClusterHandle {
    const print = std.debug.print;

    // Pick 3 random ports spaced 2000 apart so that each node's raft transport
    // port (auto-calculated as port + 1000) doesn't collide with any other node's main port.
    const seed = @as(u64, @intCast(std.time.nanoTimestamp()));
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const base_port = 20000 + random.intRangeAtMost(u16, 0, 3000);
    const ports = [3]u16{ base_port, base_port + 2000, base_port + 4000 };
    const node_ids = [3][]const u8{ "bench-n1", "bench-n2", "bench-n3" };

    var handle = ClusterHandle{
        .servers = undefined,
        .leader_port = 0,
        .count = 0,
    };

    // Build peers strings for each node (other two nodes' client ports; the
    // raft transport dials each peer's client port + 1000).
    var peers_bufs: [3][256]u8 = undefined;
    var peers_slices: [3][]const u8 = undefined;
    for (0..3) |i| {
        var idx: usize = 0;
        var first = true;
        for (0..3) |j| {
            if (j == i) continue;
            if (!first) {
                peers_bufs[i][idx] = ',';
                idx += 1;
            }
            const written = std.fmt.bufPrint(peers_bufs[i][idx..], "{s}@127.0.0.1:{d}", .{ node_ids[j], ports[j] }) catch break;
            idx += written.len;
            first = false;
        }
        peers_slices[i] = peers_bufs[i][0..idx];
    }

    const server_path = "zig-out/bin/corvo-bench-server";

    for (0..3) |i| {
        // Create temp dir.
        var data_dir: [128]u8 = undefined;
        const data_dir_slice = std.fmt.bufPrint(&data_dir, "/tmp/corvo-bench-cluster-{d}", .{ports[i]}) catch unreachable;
        const data_dir_len = data_dir_slice.len;

        std.fs.cwd().deleteTree(data_dir_slice) catch {};
        std.fs.cwd().makePath(data_dir_slice) catch {};

        var port_buf: [8]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{ports[i]}) catch unreachable;

        var child = std.process.Child.init(
            &.{ server_path, "--port", port_str, "--data-dir", data_dir_slice, "--node-id", node_ids[i], "--peers", peers_slices[i], "--cluster-id", "1", "--no-mirror" },
            alloc,
        );
        child.stderr_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        try child.spawn();

        handle.servers[i] = .{
            .child = child,
            .port = ports[i],
            .data_dir = data_dir,
            .data_dir_len = data_dir_len,
        };
        handle.count += 1;
    }

    // Wait for all 3 nodes to be listening on their main ports.
    print("  Waiting for cluster nodes...", .{});
    const deadline = std.time.nanoTimestamp() + 15_000_000_000; // 15s
    for (0..3) |i| {
        while (std.time.nanoTimestamp() < deadline) {
            if (net.tcpConnectToAddress(net.Address.parseIp("127.0.0.1", ports[i]) catch unreachable)) |stream| {
                stream.close();
                break;
            } else |_| {}
            std.Thread.sleep(100_000_000); // 100ms
        }
    }

    // Wait for leader election. Raft election settles in ~1s (300-600ms
    // timeouts), so wait a bit then probe each node via RPC to find the leader
    // (the leader accepts writes; followers answer not-leader).
    print(" waiting for leader election...", .{});
    std.Thread.sleep(5_000_000_000); // 5s for election to complete

    var leader_found = false;
    const election_deadline = std.time.nanoTimestamp() + 25_000_000_000; // 25s more

    while (std.time.nanoTimestamp() < election_deadline) {
        for (0..3) |i| {
            var client = RpcClient.connect(ports[i]) catch continue;
            // Try a simple enqueue — the leader will accept, followers reject/error.
            const enqueued = client.enqueueSingle("bench.probe", "probe-job") catch {
                client.close();
                continue;
            };
            client.close();
            if (enqueued > 0) {
                handle.leader_port = ports[i];
                leader_found = true;
                break;
            }
        }
        if (leader_found) break;
        std.Thread.sleep(1_000_000_000); // 1s
    }

    if (!leader_found) {
        print(" FAILED\n", .{});
        return error.LeaderElectionTimeout;
    }

    print(" ready (leader port {d})\n", .{handle.leader_port});
    return handle;
}

// ============================================================================
// Warmup
// ============================================================================

fn runWarmup(port: u16, queue: []const u8) void {
    var client = RpcClient.connect(port) catch return;
    defer client.close();

    var prefix_buf: [32]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "warmup-{d}", .{std.time.milliTimestamp()}) catch "warmup";

    var idx: u32 = 0;
    var fetched_buf: [512]FetchedId = undefined;

    // Enqueue warmup jobs.
    while (idx < WARMUP_OPS) {
        const batch: u16 = @intCast(@min(BATCH_SIZE, WARMUP_OPS - idx));
        _ = client.enqueueBatch(queue, prefix, idx, batch) catch break;
        idx += batch;
    }

    // Fetch+ack them all (best effort, 3s timeout).
    var acked: u32 = 0;
    var timer = std.time.Timer.start() catch return;
    while (acked < idx and timer.read() < 3_000_000_000) {
        const want: u16 = @intCast(@min(BATCH_SIZE, idx - acked));
        const fetched = client.fetchBatch(queue, want, &fetched_buf) catch break;
        if (fetched == 0) {
            std.Thread.sleep(1_000_000); // 1ms
            continue;
        }
        _ = client.ackBatch(fetched_buf[0..fetched]) catch break;
        acked += fetched;
    }
}

// ============================================================================
// Output formatting
// ============================================================================

fn formatNumber(value: u64, buf: []u8) []const u8 {
    // Format with comma separators: 85412 -> "85,412"
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch return "?";

    if (num_str.len <= 3) {
        @memcpy(buf[0..num_str.len], num_str);
        return buf[0..num_str.len];
    }

    var out_pos: usize = 0;
    const first_group = num_str.len % 3;
    if (first_group > 0) {
        @memcpy(buf[out_pos..][0..first_group], num_str[0..first_group]);
        out_pos += first_group;
        buf[out_pos] = ',';
        out_pos += 1;
    }
    var i: usize = first_group;
    while (i < num_str.len) {
        @memcpy(buf[out_pos..][0..3], num_str[i..][0..3]);
        out_pos += 3;
        i += 3;
        if (i < num_str.len) {
            buf[out_pos] = ',';
            out_pos += 1;
        }
    }
    return buf[0..out_pos];
}

fn formatDurationMs(ns: u64, buf: []u8) []const u8 {
    if (ns == 0) return "N/A";
    if (ns < 1_000) return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "?";
    if (ns < 1_000_000) {
        const us = ns / 1000;
        const frac = (ns % 1000) / 100;
        if (frac > 0) return std.fmt.bufPrint(buf, "{d}.{d}us", .{ us, frac }) catch "?";
        return std.fmt.bufPrint(buf, "{d}us", .{us}) catch "?";
    }
    if (ns < 1_000_000_000) {
        const ms = ns / 1_000_000;
        const frac = (ns % 1_000_000) / 10_000; // two decimal places
        if (frac > 0) return std.fmt.bufPrint(buf, "{d}.{d:0>2}ms", .{ ms, frac }) catch "?";
        return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "?";
    }
    const s = ns / 1_000_000_000;
    const frac = (ns % 1_000_000_000) / 10_000_000;
    if (frac > 0) return std.fmt.bufPrint(buf, "{d}.{d:0>2}s", .{ s, frac }) catch "?";
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
}

fn printPhaseResult(label: []const u8, detail: []const u8, result: PhaseResult) void {
    const print = std.debug.print;
    var nb: [32]u8 = undefined;
    const ops_sec = if (result.wall_ns > 0) result.ops * 1_000_000_000 / result.wall_ns else 0;
    if (result.timed_out and result.ops < result.target) {
        print("  {s:<24}{s:>9} ops/sec  TIMEOUT ({d}s -- {d} of {d})  {s}\n", .{
            label,
            formatNumber(ops_sec, &nb),
            PHASE_TIMEOUT_NS / 1_000_000_000,
            result.ops,
            result.target,
            detail,
        });
    } else {
        print("  {s:<24}{s:>9} ops/sec  {s}\n", .{
            label, formatNumber(ops_sec, &nb), detail,
        });
    }
    if (result.errors > 0) {
        print("    ({d} errors)\n", .{result.errors});
    }
}

// ============================================================================
// Run all benchmark phases against a given port
// ============================================================================

fn runAllPhases(alloc: std.mem.Allocator, port: u16) !void {
    const print = std.debug.print;

    // Phase 1: Enqueue throughput.
    {
        const result = try runEnqueuePhase(alloc, port, TOTAL_JOBS, THREAD_COUNT, "bench.enq");
        var detail_buf: [128]u8 = undefined;
        var nb: [32]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "({s} jobs, batch={d}, {d} threads)", .{
            formatNumber(TOTAL_JOBS, &nb), BATCH_SIZE, THREAD_COUNT,
        }) catch "";
        printPhaseResult("Enqueue throughput:", detail, result);
    }

    // Phase 2: Lifecycle throughput (fetch + ack on the jobs from phase 1).
    {
        const result = try runLifecyclePhase(alloc, port, TOTAL_JOBS, THREAD_COUNT, "bench.enq");
        var detail_buf: [128]u8 = undefined;
        const detail = std.fmt.bufPrint(&detail_buf, "(fetch+ack, batch={d}, {d} threads)", .{
            BATCH_SIZE, THREAD_COUNT,
        }) catch "";
        printPhaseResult("Lifecycle throughput:", detail, result);
    }

    // Phase 3: Combined throughput.
    {
        const result = try runCombinedPhase(alloc, port, "bench.combined");
        const wall_ns = result.wall_ns;
        const enq_ops_sec = if (wall_ns > 0) result.enqueue_ops * 1_000_000_000 / wall_ns else 0;
        const lc_ops_sec = if (wall_ns > 0) result.lifecycle_ops * 1_000_000_000 / wall_ns else 0;
        var nb1: [32]u8 = undefined;
        var nb2: [32]u8 = undefined;
        print("  {s:<24}{s:>9} enq/sec + {s} lc/sec  (4+4 threads, {d}s sustained)\n", .{
            "Combined throughput:", formatNumber(enq_ops_sec, &nb1), formatNumber(lc_ops_sec, &nb2),
            COMBINED_DURATION_NS / 1_000_000_000,
        });
        if (result.enqueue_errors + result.lifecycle_errors > 0) {
            print("    ({d} enqueue errors, {d} lifecycle errors)\n", .{
                result.enqueue_errors, result.lifecycle_errors,
            });
        }
    }

    // Phase 4: Latency percentiles.
    {
        const result = try runLatencyPhase(port, "bench.latency");
        print("\n  Latency (enqueue-to-fetch):\n", .{});
        if (result.samples == 0) {
            print("    no samples collected\n", .{});
        } else {
            var b50: [32]u8 = undefined;
            var b95: [32]u8 = undefined;
            var b99: [32]u8 = undefined;
            var b999: [32]u8 = undefined;
            print("    p50:  {s}\n", .{formatDurationMs(result.p50, &b50)});
            print("    p95:  {s}\n", .{formatDurationMs(result.p95, &b95)});
            print("    p99:  {s}\n", .{formatDurationMs(result.p99, &b99)});
            print("    p999: {s}\n", .{formatDurationMs(result.p999, &b999)});
            if (result.timed_out) {
                print("    (timed out after {d} samples)\n", .{result.samples});
            } else {
                print("    ({d} samples)\n", .{result.samples});
            }
        }
    }

    // Phase 5: Connection scaling.
    {
        print("\n  Connection scaling (enqueue+fetch+ack per worker):\n", .{});
        const scaling_results = try runScalingPhase(alloc, port);
        for (scaling_results) |step| {
            if (!step.ok) {
                var wb: [8]u8 = undefined;
                const wstr = std.fmt.bufPrint(&wb, "{d}", .{step.workers}) catch "?";
                print("    {s} workers:{s}(no data)\n", .{ wstr, padding(14 - @min(wstr.len, 13)) });
                continue;
            }
            var b50: [32]u8 = undefined;
            var b99: [32]u8 = undefined;
            var nb: [32]u8 = undefined;
            var wb: [8]u8 = undefined;
            const wstr = std.fmt.bufPrint(&wb, "{d}", .{step.workers}) catch "?";
            // Pad worker count for alignment: "8 workers:     " vs "512 workers:   "
            const label_len = wstr.len + " workers:".len;
            const pad_len = if (label_len < 14) 14 - label_len else 1;
            print("    {s} workers:{s}p50={s:<8} p99={s:<8} {s} ops/sec\n", .{
                wstr,
                padding(pad_len),
                formatDurationMs(step.p50, &b50),
                formatDurationMs(step.p99, &b99),
                formatNumber(step.ops_sec, &nb),
            });
        }
    }
}

fn padding(n: usize) []const u8 {
    const spaces = "                    "; // 20 spaces
    return spaces[0..@min(n, spaces.len)];
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    const print = std.debug.print;

    print("\nCorvo Benchmark\n", .{});

    // ---- Single Node ----
    {
        print("\nStarting single-node server...\n", .{});
        var server = startServer(alloc) catch |err| {
            print("Failed to start server: {s}\n", .{@errorName(err)});
            return;
        };
        defer server.cleanup();

        print("Server running on port {d}\n", .{server.port});

        // Warmup.
        runWarmup(server.port, "bench.warmup");

        print("\n=== Single Node ===\n\n", .{});
        try runAllPhases(alloc, server.port);
    }

    // ---- 3-Node Cluster ----
    print("\n\nStarting 3-node cluster...\n", .{});
    var cluster = startCluster(alloc) catch |err| {
        if (err == error.LeaderElectionTimeout) {
            print("Cluster leader election timed out, skipping cluster benchmarks.\n", .{});
        } else {
            print("Failed to start cluster: {s}, skipping cluster benchmarks.\n", .{@errorName(err)});
        }
        print("\n", .{});
        return;
    };
    defer cluster.cleanup();

    // Warmup on cluster leader.
    runWarmup(cluster.leader_port, "bench.cluster-warmup");

    print("\n=== 3-Node Cluster ===\n\n", .{});
    try runAllPhases(alloc, cluster.leader_port);

    print("\n", .{});
}
