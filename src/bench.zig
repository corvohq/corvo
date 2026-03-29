//! Corvo Saturation Benchmark
//!
//! Drives load against a Corvo server and reports performance metrics.
//! Client-side: enqueue + lifecycle throughput (ops/sec).
//! Server-side: delivery latency, e2e latency (scraped from /metrics).
//!
//! Modes:
//!   throughput — sequential enqueue then lifecycle phases (default)
//!   scale      — ramp connections, find saturation point
//!
//! Usage:
//!   bench [options]
//!     --mode <throughput|scale>           Benchmark mode (default: throughput)
//!     --protocol <rpc|http>              Protocol (default: rpc)
//!     --server <host:port>               Server address (default: 127.0.0.1:9878)
//!     --jobs <n>                         Total jobs (default: 100000)
//!     --concurrency <n>                  Worker threads (default: 8)
//!     --batch <n>                        Jobs per batch (default: 64)
//!     --queue <name>                     Queue name (default: bench.q)
//!     --json <path>                      Write JSON results to file
//!     --steps <n>                        Scale mode: number of steps (default: 8)
//!     --max-conns <n>                    Scale mode: max connections (default: 256)
//!     --burst <n>                        Scale mode: jobs per step (default: 5000)

const std = @import("std");
const net = std.net;
const corvo = @import("corvo");
const rpc = corvo.rpc;

// ============================================================================
// Config
// ============================================================================

const Protocol = enum { rpc, http };
const Mode = enum { combined, throughput, scale };

const BenchConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 9878,
    protocol: Protocol = .rpc,
    mode: Mode = .combined,
    total_jobs: u32 = 100_000,
    producers: u16 = 4,
    consumers: u16 = 4,
    batch_size: u16 = 64,
    queue: []const u8 = "bench.q",
    json_path: ?[]const u8 = null,
    // Scale mode.
    steps: u16 = 8,
    max_conns: u16 = 256,
    burst: u32 = 5_000,

    /// For throughput/scale modes that use a single concurrency value.
    concurrency: u16 = 8,
};

// ============================================================================
// FetchedId
// ============================================================================

const FetchedId = struct {
    id_buf: [64]u8 = undefined,
    id_len: u8 = 0,
    queue_buf: [64]u8 = undefined,
    queue_len: u8 = 0,
};

// ============================================================================
// RPC Client
// ============================================================================

const CLIENT_BUF_SIZE = 65536;

/// Write a complete RPC frame (header + payload) to a blocking TCP stream.
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

    fn connect(host: []const u8, port: u16) !RpcClient {
        const addr = try net.Address.parseIp(host, port);
        const stream = try net.tcpConnectToAddress(addr);
        const TCP_NODELAY = 1;
        std.posix.setsockopt(stream.handle, std.posix.IPPROTO.TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        return .{ .stream = stream };
    }

    fn close(self: *RpcClient) void {
        self.stream.close();
    }

    fn enqueueBatch(self: *RpcClient, queue_name: []const u8, id_prefix: []const u8, start_idx: u32, count: u16) !u16 {
        self.req_id +%= 1;
        var w = rpc.BufWriter{ .buf = &self.send_buf };
        w.writeU16(count);
        for (0..count) |i| {
            w.writePrefixed(queue_name);
            var id_buf: [64]u8 = undefined;
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
            w.writeU16(0); // flags
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

    fn fetchBatch(self: *RpcClient, queue_name: []const u8, count: u16, fetched_ids: []FetchedId) !u16 {
        self.req_id +%= 1;
        var w = rpc.BufWriter{ .buf = &self.send_buf };
        w.writeU16(count);
        w.writeU32(30_000);
        w.writePrefixed("bench-worker");
        w.writeU8(1);
        w.writePrefixed(queue_name);
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
            _ = r.readU16() catch break;
            _ = r.readU16() catch break;
            const ckpt_len = r.readU8() catch break;
            r.skip(ckpt_len) catch break;
            const tags_len = r.readU8() catch break;
            r.skip(tags_len) catch break;
            const pl = r.readU16() catch break;
            r.skip(pl) catch break;
        }
        return n;
    }

    fn ackBatch(self: *RpcClient, acks: []const FetchedId) !u16 {
        self.req_id +%= 1;
        var w = rpc.BufWriter{ .buf = &self.send_buf };
        w.writeU16(@intCast(acks.len));
        for (acks) |a| {
            w.writePrefixed(a.id_buf[0..a.id_len]);
            w.writePrefixed(a.queue_buf[0..a.queue_len]);
            w.writeU8(0);
            w.writeU8(0);
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
// HTTP Client
// ============================================================================

const HttpClient = struct {
    stream: net.Stream,
    send_buf: [CLIENT_BUF_SIZE]u8 = undefined,
    recv_buf: [CLIENT_BUF_SIZE]u8 = undefined,
    host_header: [128]u8 = undefined,
    host_header_len: u8 = 0,

    fn connect(host: []const u8, port: u16) !HttpClient {
        const addr = try net.Address.parseIp(host, port);
        const stream = try net.tcpConnectToAddress(addr);
        const TCP_NODELAY = 1;
        std.posix.setsockopt(stream.handle, std.posix.IPPROTO.TCP, TCP_NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        var client = HttpClient{ .stream = stream };
        const hdr = std.fmt.bufPrint(&client.host_header, "{s}:{d}", .{ host, port }) catch "localhost:9878";
        client.host_header_len = @intCast(hdr.len);
        return client;
    }

    fn close(self: *HttpClient) void {
        self.stream.close();
    }

    fn hostHeader(self: *const HttpClient) []const u8 {
        return self.host_header[0..self.host_header_len];
    }

    fn doPost(self: *HttpClient, path: []const u8, body: []const u8) !HttpResponse {
        var len: usize = 0;
        len += (std.fmt.bufPrint(self.send_buf[len..], "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: keep-alive\r\n\r\n", .{ path, self.hostHeader(), body.len }) catch return error.BufferOverflow).len;
        if (len + body.len > self.send_buf.len) return error.BufferOverflow;
        @memcpy(self.send_buf[len..][0..body.len], body);
        len += body.len;
        var sent: usize = 0;
        while (sent < len) {
            sent += try self.stream.write(self.send_buf[sent..len]);
        }
        return self.readResponse();
    }

    fn readResponse(self: *HttpClient) !HttpResponse {
        var total: usize = 0;
        while (total < self.recv_buf.len) {
            const n = try self.stream.read(self.recv_buf[total..]);
            if (n == 0) return error.ConnectionClosed;
            total += n;
            if (std.mem.indexOf(u8, self.recv_buf[0..total], "\r\n\r\n")) |_| break;
        }
        const status = std.fmt.parseInt(u16, self.recv_buf[9..12], 10) catch 0;
        const header_end = (std.mem.indexOf(u8, self.recv_buf[0..total], "\r\n\r\n") orelse return error.MalformedResponse) + 4;
        const content_length = extractContentLength(self.recv_buf[0..header_end]);
        const body_end = header_end + content_length;
        while (total < body_end and total < self.recv_buf.len) {
            const n = try self.stream.read(self.recv_buf[total..]);
            if (n == 0) return error.ConnectionClosed;
            total += n;
        }
        return .{ .status = status, .body = self.recv_buf[header_end..@min(body_end, total)] };
    }

    fn enqueueBatch(self: *HttpClient, queue_name: []const u8, _: []const u8, _: u32, count: u16) !u16 {
        var body_buf: [32768]u8 = undefined;
        var pos: usize = 0;
        if (count == 1) {
            pos += (std.fmt.bufPrint(body_buf[pos..], "{{\"queue\":\"{s}\",\"payload\":\"{{}}\"}}", .{queue_name}) catch return error.BufferOverflow).len;
        } else {
            pos += (std.fmt.bufPrint(body_buf[pos..], "{{\"jobs\":[", .{}) catch return error.BufferOverflow).len;
            for (0..count) |i| {
                if (i > 0) {
                    body_buf[pos] = ',';
                    pos += 1;
                }
                pos += (std.fmt.bufPrint(body_buf[pos..], "{{\"queue\":\"{s}\",\"payload\":\"{{}}\"}}", .{queue_name}) catch return error.BufferOverflow).len;
            }
            pos += (std.fmt.bufPrint(body_buf[pos..], "]}}", .{}) catch return error.BufferOverflow).len;
        }
        const resp = try self.doPost("/api/v1/enqueue", body_buf[0..pos]);
        if (resp.status == 201) return count;
        return 0;
    }

    fn fetchBatch(self: *HttpClient, queue_name: []const u8, _: u16, fetched_ids: []FetchedId) !u16 {
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"queues\":[\"{s}\"],\"worker_id\":\"bench-http\",\"count\":1}}", .{queue_name}) catch return error.BufferOverflow;
        const resp = try self.doPost("/api/v1/fetch", body);
        if (resp.status != 200) return 0;
        const job_id = extractJsonString(resp.body, "job_id") orelse return 0;
        if (job_id.len == 0) return 0;
        const q = extractJsonString(resp.body, "queue") orelse queue_name;
        @memcpy(fetched_ids[0].id_buf[0..job_id.len], job_id);
        fetched_ids[0].id_len = @intCast(job_id.len);
        @memcpy(fetched_ids[0].queue_buf[0..q.len], q);
        fetched_ids[0].queue_len = @intCast(q.len);
        return 1;
    }

    fn ackBatch(self: *HttpClient, acks: []const FetchedId) !u16 {
        var body_buf: [16384]u8 = undefined;
        var pos: usize = 0;
        pos += (std.fmt.bufPrint(body_buf[pos..], "{{\"job_ids\":[", .{}) catch return error.BufferOverflow).len;
        for (acks, 0..) |a, i| {
            if (i > 0) {
                body_buf[pos] = ',';
                pos += 1;
            }
            pos += (std.fmt.bufPrint(body_buf[pos..], "\"{s}\"", .{a.id_buf[0..a.id_len]}) catch return error.BufferOverflow).len;
        }
        pos += (std.fmt.bufPrint(body_buf[pos..], "]}}", .{}) catch return error.BufferOverflow).len;
        const resp = try self.doPost("/api/v1/ack", body_buf[0..pos]);
        if (resp.status == 200) return @intCast(acks.len);
        return 0;
    }
};

const HttpResponse = struct {
    status: u16,
    body: []const u8,
};

fn extractContentLength(headers: []const u8) usize {
    const needle = "Content-Length: ";
    const start = std.mem.indexOf(u8, headers, needle) orelse {
        const lower = "content-length: ";
        const s2 = std.mem.indexOf(u8, headers, lower) orelse return 0;
        const val_start = s2 + lower.len;
        const val_end = std.mem.indexOfScalar(u8, headers[val_start..], '\r') orelse return 0;
        return std.fmt.parseInt(usize, headers[val_start..][0..val_end], 10) catch 0;
    };
    const val_start = start + needle.len;
    const val_end = std.mem.indexOfScalar(u8, headers[val_start..], '\r') orelse return 0;
    return std.fmt.parseInt(usize, headers[val_start..][0..val_end], 10) catch 0;
}

fn extractJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = (std.mem.indexOf(u8, body, needle) orelse return null) + needle.len;
    const end = std.mem.indexOfScalar(u8, body[start..], '"') orelse return null;
    return body[start..][0..end];
}

// ============================================================================
// Worker results
// ============================================================================

const WorkerResult = struct {
    ops: u64 = 0,
    errors: u64 = 0,
    elapsed_ns: u64 = 0,
};

// ============================================================================
// Enqueue worker
// ============================================================================

fn enqueueWorker(comptime ClientType: type, config: BenchConfig, worker_id: u16, jobs_per_worker: u32) WorkerResult {
    var client = ClientType.connect(config.host, config.port) catch return .{ .errors = 1 };
    defer client.close();

    var prefix_buf: [32]u8 = undefined;
    const ts: u32 = @truncate(@as(u64, @intCast(std.time.milliTimestamp())));
    const prefix = std.fmt.bufPrint(&prefix_buf, "{d}w{d}", .{ ts, worker_id }) catch "w";

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

    return .{ .ops = total_enqueued, .errors = total_errors, .elapsed_ns = timer.read() };
}

// ============================================================================
// Lifecycle worker (fetch + ack)
// ============================================================================

fn lifecycleWorker(comptime ClientType: type, config: BenchConfig, _: u16, jobs_per_worker: u32) WorkerResult {
    if (ClientType == RpcClient) {
        return rpcLifecycleWorker(config, jobs_per_worker);
    } else {
        return httpLifecycleWorker(config, jobs_per_worker);
    }
}

var g_lifecycle_done: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
var g_lifecycle_target: u32 = 0;

fn rpcLifecycleWorker(config: BenchConfig, _: u32) WorkerResult {
    var client = RpcClient.connect(config.host, config.port) catch return .{ .errors = 1 };
    defer client.close();

    const timeval = std.posix.timeval{ .sec = 1, .usec = 0 };
    std.posix.setsockopt(client.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch {};

    var total_ops: u64 = 0;
    var total_errors: u64 = 0;
    var timer = std.time.Timer.start() catch return .{ .errors = 1 };
    var fetched_buf: [512]FetchedId = undefined;
    var empty_streak: u32 = 0;

    // Subscribe once — server pushes up to prefetch jobs, replenishes on ack.
    const prefetch: u16 = @intCast(@min(config.batch_size, 512));
    rpcSendSubscribe(&client, config.queue, prefetch) catch return .{ .errors = 1 };

    // Message loop: server can push FETCH_BATCH_RESP at any time (persistent
    // subscription), interleaved with ACK_BATCH_RESP. Read whatever arrives,
    // dispatch by type.
    while (g_lifecycle_done.load(.monotonic) < g_lifecycle_target) {
        const header = rpc.readHeader(client.stream) catch {
            if (g_lifecycle_done.load(.monotonic) >= g_lifecycle_target) break;
            empty_streak += 1;
            if (empty_streak > 5) break;
            continue;
        };

        if (header.payload_len > 0) {
            rpc.readExact(client.stream, client.recv_buf[0..header.payload_len]) catch break;
        }

        switch (header.msg_type) {
            rpc.MSG_FETCH_BATCH_RESP => {
                const fetched = parseFetchPayload(client.recv_buf[0..header.payload_len], &fetched_buf);
                if (fetched == 0) {
                    empty_streak += 1;
                    if (empty_streak > 5) break;
                    continue;
                }
                empty_streak = 0;

                // Send ack (fire-and-forget — response handled by this loop).
                rpcSendAck(&client, fetched_buf[0..fetched]) catch {
                    total_errors += 1;
                    break;
                };
                total_ops += fetched;
                _ = g_lifecycle_done.fetchAdd(@intCast(fetched), .monotonic);
            },
            rpc.MSG_ACK_BATCH_RESP => {},
            rpc.MSG_ERROR => {
                total_errors += 1;
            },
            else => {},
        }
    }

    return .{ .ops = total_ops, .errors = total_errors, .elapsed_ns = timer.read() };
}

/// Send ack batch — fire-and-forget, response handled by message loop.
fn rpcSendAck(client: *RpcClient, acks: []const FetchedId) !void {
    client.req_id +%= 1;
    var w = rpc.BufWriter{ .buf = &client.send_buf };
    w.writeU16(@intCast(acks.len));
    for (acks) |a| {
        w.writePrefixed(a.id_buf[0..a.id_len]);
        w.writePrefixed(a.queue_buf[0..a.queue_len]);
        w.writeU8(0);
        w.writeU8(0);
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
        _ = r.readU16() catch break;
        _ = r.readU16() catch break;
        const ckpt_len = r.readU8() catch break;
        r.skip(ckpt_len) catch break;
        const tags_len = r.readU8() catch break;
        r.skip(tags_len) catch break;
        const pl = r.readU16() catch break;
        r.skip(pl) catch break;
    }
    return n;
}

/// Send fetch subscribe frame — fire-and-forget, no response read.
fn rpcSendSubscribe(client: *RpcClient, queue_name: []const u8, prefetch: u16) !void {
    client.req_id +%= 1;
    var w = rpc.BufWriter{ .buf = &client.send_buf };
    w.writeU16(prefetch);
    w.writeU32(30_000);
    w.writePrefixed("bench-worker");
    w.writeU8(1);
    w.writePrefixed(queue_name);
    try writeFrame(client.stream, rpc.MSG_FETCH_BATCH, client.req_id, w.written());
}


fn httpLifecycleWorker(config: BenchConfig, jobs_per_worker: u32) WorkerResult {
    var client = HttpClient.connect(config.host, config.port) catch return .{ .errors = 1 };
    defer client.close();

    var total_ops: u64 = 0;
    var total_errors: u64 = 0;
    var remaining: u32 = jobs_per_worker;
    var timer = std.time.Timer.start() catch return .{ .errors = 1 };
    var fetched_buf: [512]FetchedId = undefined;

    while (remaining > 0) {
        const fetched = client.fetchBatch(config.queue, 1, &fetched_buf) catch {
            total_errors += 1;
            break;
        };
        if (fetched == 0) {
            std.Thread.sleep(100_000);
            continue;
        }
        const acked = client.ackBatch(fetched_buf[0..fetched]) catch {
            total_errors += 1;
            break;
        };
        total_ops += acked;
        remaining -|= @intCast(acked);
    }

    return .{ .ops = total_ops, .errors = total_errors, .elapsed_ns = timer.read() };
}

// ============================================================================
// Combined mode — producers + consumers simultaneously
// ============================================================================

const CombinedResult = struct {
    enqueue_ops: u64 = 0,
    enqueue_errors: u64 = 0,
    lifecycle_ops: u64 = 0,
    lifecycle_errors: u64 = 0,
    wall_ns: u64 = 0,
};

fn runCombined(comptime ClientType: type, config: BenchConfig, alloc: std.mem.Allocator) !CombinedResult {
    const jobs_per_producer = config.total_jobs / config.producers;

    // Set shared lifecycle target.
    g_lifecycle_done.store(0, .monotonic);
    g_lifecycle_target = config.total_jobs;

    const total_threads = @as(usize, config.producers) + config.consumers;
    const threads = try alloc.alloc(std.Thread, total_threads);
    defer alloc.free(threads);
    const producer_results = try alloc.alloc(WorkerResult, config.producers);
    defer alloc.free(producer_results);
    const consumer_results = try alloc.alloc(WorkerResult, config.consumers);
    defer alloc.free(consumer_results);

    var wall = std.time.Timer.start() catch unreachable;

    // Spawn consumers FIRST — they subscribe and wait for jobs.
    for (0..config.consumers) |i| {
        threads[config.producers + i] = try std.Thread.spawn(.{}, struct {
            fn run(cfg: BenchConfig, result: *WorkerResult) void {
                result.* = rpcLifecycleWorker(cfg, 0);
            }
        }.run, .{ config, &consumer_results[i] });
    }

    // Brief pause to let consumers connect and subscribe.
    std.Thread.sleep(5_000_000); // 5ms

    // Spawn producers — their enqueues trigger fulfillSubscriptions on the server.
    for (0..config.producers) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(cfg: BenchConfig, wid: u16, jpw: u32, result: *WorkerResult) void {
                result.* = enqueueWorker(ClientType, cfg, wid, jpw);
            }
        }.run, .{ config, @as(u16, @intCast(i)), jobs_per_producer, &producer_results[i] });
    }

    for (threads) |t| t.join();
    const wall_ns = wall.read();

    var enq_ops: u64 = 0;
    var enq_errors: u64 = 0;
    for (producer_results) |r| {
        enq_ops += r.ops;
        enq_errors += r.errors;
    }
    var lc_ops: u64 = 0;
    var lc_errors: u64 = 0;
    for (consumer_results) |r| {
        lc_ops += r.ops;
        lc_errors += r.errors;
    }

    return .{
        .enqueue_ops = enq_ops,
        .enqueue_errors = enq_errors,
        .lifecycle_ops = lc_ops,
        .lifecycle_errors = lc_errors,
        .wall_ns = wall_ns,
    };
}

fn printCombinedResult(config: BenchConfig, result: CombinedResult, latency: ServerLatency) void {
    const print = std.debug.print;

    print("\nCorvo Bench — {s} combined, {d}k jobs, {d}+{d} threads, batch {d}\n\n", .{
        @tagName(config.protocol), config.total_jobs / 1000, config.producers, config.consumers, config.batch_size,
    });

    const enq_ops = if (result.wall_ns > 0) result.enqueue_ops * 1_000_000_000 / result.wall_ns else 0;
    const lc_ops = if (result.wall_ns > 0) result.lifecycle_ops * 1_000_000_000 / result.wall_ns else 0;

    var wb: [16]u8 = undefined;
    print("  {s:<12} {d:>9} ops/sec\n", .{ "enqueue", enq_ops });
    print("  {s:<12} {d:>9} ops/sec\n", .{ "lifecycle", lc_ops });
    print("  {s:<12} {s}\n", .{ "wall", fmtDuration(result.wall_ns, &wb) });

    var dp50: [16]u8 = undefined;
    var dp99: [16]u8 = undefined;
    var dp999: [16]u8 = undefined;
    var ep50: [16]u8 = undefined;
    var ep99: [16]u8 = undefined;
    var ep999: [16]u8 = undefined;
    print("\n  {s:<12} p50 {s:<8}  p99 {s:<8}  p999 {s}   (server)\n", .{
        "delivery", fmtDuration(latency.delivery_p50, &dp50), fmtDuration(latency.delivery_p99, &dp99), fmtDuration(latency.delivery_p999, &dp999),
    });
    print("  {s:<12} p50 {s:<8}  p99 {s:<8}  p999 {s}   (server)\n", .{
        "e2e", fmtDuration(latency.e2e_p50, &ep50), fmtDuration(latency.e2e_p99, &ep99), fmtDuration(latency.e2e_p999, &ep999),
    });

    const total_errors = result.enqueue_errors + result.lifecycle_errors;
    print("\n  total: {d} jobs   errors: {d}\n\n", .{ result.enqueue_ops, total_errors });
}

// ============================================================================
// Run throughput benchmark (sequential phases)
// ============================================================================

const PhaseResult = struct {
    ops: u64 = 0,
    errors: u64 = 0,
    wall_ns: u64 = 0,
};

fn runPhase(comptime ClientType: type, comptime workerFn: anytype, config: BenchConfig, alloc: std.mem.Allocator) !PhaseResult {
    const jobs_per_worker = config.total_jobs / config.concurrency;
    const threads = try alloc.alloc(std.Thread, config.concurrency);
    defer alloc.free(threads);
    const results = try alloc.alloc(WorkerResult, config.concurrency);
    defer alloc.free(results);

    var wall = std.time.Timer.start() catch unreachable;

    for (0..config.concurrency) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(cfg: BenchConfig, wid: u16, jpw: u32, result: *WorkerResult) void {
                result.* = workerFn(ClientType, cfg, wid, jpw);
            }
        }.run, .{ config, @as(u16, @intCast(i)), jobs_per_worker, &results[i] });
    }
    for (threads) |t| t.join();

    const wall_ns = wall.read();
    var total_ops: u64 = 0;
    var total_errors: u64 = 0;
    for (results) |r| {
        total_ops += r.ops;
        total_errors += r.errors;
    }

    return .{ .ops = total_ops, .errors = total_errors, .wall_ns = wall_ns };
}

// ============================================================================
// Scrape /metrics from server
// ============================================================================

const ServerLatency = struct {
    delivery_p50: u64 = 0,
    delivery_p99: u64 = 0,
    delivery_p999: u64 = 0,
    e2e_p50: u64 = 0,
    e2e_p99: u64 = 0,
    e2e_p999: u64 = 0,
};

fn scrapeMetrics(host: []const u8, port: u16) ServerLatency {
    // Connect via HTTP and GET /metrics.
    var client = HttpClient.connect(host, port) catch return .{};
    defer client.close();

    // Set recv timeout to avoid blocking forever.
    const timeval = std.posix.timeval{ .sec = 3, .usec = 0 };
    std.posix.setsockopt(client.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&timeval)) catch {};

    var len: usize = 0;
    len += (std.fmt.bufPrint(client.send_buf[len..], "GET /metrics HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{client.hostHeader()}) catch return .{}).len;
    var sent: usize = 0;
    while (sent < len) {
        sent += client.stream.write(client.send_buf[sent..len]) catch return .{};
    }

    // Read response using Content-Length.
    const resp = client.readResponse() catch return .{};
    const body = resp.body;

    // Parse the histogram percentiles from Prometheus text format.
    // We use the bucket boundaries to approximate p50/p99/p999.
    return .{
        .delivery_p50 = parsePercentile(body, "corvo_delivery_latency_seconds", 0.50),
        .delivery_p99 = parsePercentile(body, "corvo_delivery_latency_seconds", 0.99),
        .delivery_p999 = parsePercentile(body, "corvo_delivery_latency_seconds", 0.999),
        .e2e_p50 = parsePercentile(body, "corvo_e2e_latency_seconds", 0.50),
        .e2e_p99 = parsePercentile(body, "corvo_e2e_latency_seconds", 0.99),
        .e2e_p999 = parsePercentile(body, "corvo_e2e_latency_seconds", 0.999),
    };
}

/// Parse an approximate percentile from Prometheus histogram buckets
/// with linear interpolation. Returns nanoseconds.
fn parsePercentile(body: []const u8, metric_name: []const u8, p: f64) u64 {
    var count_needle_buf: [128]u8 = undefined;
    const count_needle = std.fmt.bufPrint(&count_needle_buf, "{s}_count ", .{metric_name}) catch return 0;
    const count_pos = std.mem.indexOf(u8, body, count_needle) orelse return 0;
    const count_start = count_pos + count_needle.len;
    const count_end = std.mem.indexOfScalar(u8, body[count_start..], '\n') orelse return 0;
    const total_count = std.fmt.parseInt(u64, body[count_start..][0..count_end], 10) catch return 0;
    if (total_count == 0) return 0;

    const target: u64 = @intFromFloat(@as(f64, @floatFromInt(total_count)) * p);

    // Must match metrics.zig boundaries.
    const boundary_ns = [_]u64{
        10_000, 50_000, 100_000, 500_000, 1_000_000,
        5_000_000, 10_000_000, 50_000_000, 100_000_000,
        200_000_000, 500_000_000, 1_000_000_000, 5_000_000_000, 10_000_000_000,
    };
    const boundary_str = [_][]const u8{
        "0.00001", "0.00005", "0.0001", "0.0005", "0.001",
        "0.005", "0.01", "0.05", "0.1", "0.2", "0.5", "1", "5", "10",
    };

    // Read all bucket counts.
    var counts: [boundary_ns.len]u64 = undefined;
    for (boundary_str, 0..) |le_str, i| {
        var needle_buf: [192]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "{s}_bucket{{le=\"{s}\"}} ", .{ metric_name, le_str }) catch {
            counts[i] = 0;
            continue;
        };
        const pos = std.mem.indexOf(u8, body, needle) orelse {
            counts[i] = 0;
            continue;
        };
        const val_start = pos + needle.len;
        const val_end = std.mem.indexOfScalar(u8, body[val_start..], '\n') orelse {
            counts[i] = 0;
            continue;
        };
        counts[i] = std.fmt.parseInt(u64, body[val_start..][0..val_end], 10) catch 0;
    }

    // Interpolate.
    var prev_count: u64 = 0;
    var prev_ns: u64 = 0;
    for (counts, boundary_ns) |bucket_count, ns| {
        if (bucket_count >= target) {
            const range = bucket_count - prev_count;
            if (range == 0) return ns;
            const offset = target - prev_count;
            const frac = @as(f64, @floatFromInt(offset)) / @as(f64, @floatFromInt(range));
            return prev_ns + @as(u64, @intFromFloat(frac * @as(f64, @floatFromInt(ns - prev_ns))));
        }
        prev_count = bucket_count;
        prev_ns = ns;
    }

    return boundary_ns[boundary_ns.len - 1];
}

// ============================================================================
// Output formatting
// ============================================================================

fn fmtDuration(ns: u64, buf: []u8) []const u8 {
    if (ns == 0) return "N/A";
    if (ns < 1_000) return std.fmt.bufPrint(buf, "{d}ns", .{ns}) catch "?";
    if (ns < 1_000_000) return std.fmt.bufPrint(buf, "{d}us", .{ns / 1_000}) catch "?";
    if (ns < 1_000_000_000) {
        const ms = ns / 1_000_000;
        const frac = (ns % 1_000_000) / 100_000;
        if (frac > 0) return std.fmt.bufPrint(buf, "{d}.{d}ms", .{ ms, frac }) catch "?";
        return std.fmt.bufPrint(buf, "{d}ms", .{ms}) catch "?";
    }
    const s = ns / 1_000_000_000;
    const frac = (ns % 1_000_000_000) / 100_000_000;
    if (frac > 0) return std.fmt.bufPrint(buf, "{d}.{d}s", .{ s, frac }) catch "?";
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
}

fn printThroughputResult(config: BenchConfig, enq: PhaseResult, lc: PhaseResult, latency: ServerLatency) void {
    const print = std.debug.print;

    print("\nCorvo Bench — {s} throughput, {d}k jobs, {d} threads, batch {d}\n\n", .{
        @tagName(config.protocol), config.total_jobs / 1000, config.concurrency, config.batch_size,
    });

    const enq_ops = if (enq.wall_ns > 0) enq.ops * 1_000_000_000 / enq.wall_ns else 0;
    const lc_ops = if (lc.wall_ns > 0) lc.ops * 1_000_000_000 / lc.wall_ns else 0;

    var ew: [16]u8 = undefined;
    var lw: [16]u8 = undefined;
    print("  {s:<12} {d:>9} ops/sec    wall {s}\n", .{ "enqueue", enq_ops, fmtDuration(enq.wall_ns, &ew) });
    print("  {s:<12} {d:>9} ops/sec    wall {s}\n", .{ "lifecycle", lc_ops, fmtDuration(lc.wall_ns, &lw) });

    var dp50: [16]u8 = undefined;
    var dp99: [16]u8 = undefined;
    var dp999: [16]u8 = undefined;
    var ep50: [16]u8 = undefined;
    var ep99: [16]u8 = undefined;
    var ep999: [16]u8 = undefined;
    print("\n  {s:<12} p50 {s:<8}  p99 {s:<8}  p999 {s}   (server)\n", .{
        "delivery", fmtDuration(latency.delivery_p50, &dp50), fmtDuration(latency.delivery_p99, &dp99), fmtDuration(latency.delivery_p999, &dp999),
    });
    print("  {s:<12} p50 {s:<8}  p99 {s:<8}  p999 {s}   (server)\n", .{
        "e2e", fmtDuration(latency.e2e_p50, &ep50), fmtDuration(latency.e2e_p99, &ep99), fmtDuration(latency.e2e_p999, &ep999),
    });

    const total_errors = enq.errors + lc.errors;
    print("\n  total: {d} jobs   errors: {d}\n\n", .{ enq.ops, total_errors });
}

// ============================================================================
// Scale mode
// ============================================================================

fn runScale(comptime ClientType: type, config: BenchConfig, alloc: std.mem.Allocator) !void {
    const print = std.debug.print;

    print("\nCorvo Bench — {s} scale, burst {d}, {d} steps\n\n", .{
        @tagName(config.protocol), config.burst, config.steps,
    });
    print("  {s:>6}  {s:>10}  {s:>10}  {s:>9}  {s:>9}  {s:>9}  {s}\n", .{
        "CONNS", "ENQ ops/s", "LC ops/s", "DEL p50", "DEL p99", "E2E p99", "NOTES",
    });

    var first_del_p99: u64 = 0;

    for (0..config.steps) |step| {
        const conns: u16 = @intCast(@max(2, config.max_conns * (@as(u32, @intCast(step)) + 1) / config.steps));

        // Use unique queue per step.
        var queue_buf: [64]u8 = undefined;
        const step_queue = std.fmt.bufPrint(&queue_buf, "{s}.s{d}", .{ config.queue, step }) catch config.queue;

        var step_config = config;
        step_config.total_jobs = config.burst;
        step_config.concurrency = conns;
        step_config.queue = step_queue;

        // Enqueue phase.
        const enq = try runPhase(ClientType, enqueueWorker, step_config, alloc);

        // Lifecycle phase.
        g_lifecycle_done.store(0, .monotonic);
        g_lifecycle_target = config.burst;
        const lc = try runPhase(ClientType, lifecycleWorker, step_config, alloc);

        // Scrape server metrics.
        const latency = scrapeMetrics(config.host, config.port);

        if (step == 0) first_del_p99 = latency.delivery_p99;
        const saturated = first_del_p99 > 0 and latency.delivery_p99 > first_del_p99 * 2;

        const enq_ops = if (enq.wall_ns > 0) enq.ops * 1_000_000_000 / enq.wall_ns else 0;
        const lc_ops = if (lc.wall_ns > 0) lc.ops * 1_000_000_000 / lc.wall_ns else 0;

        var dp50: [16]u8 = undefined;
        var dp99: [16]u8 = undefined;
        var ep99: [16]u8 = undefined;

        print("  {d:>6}  {d:>10}  {d:>10}  {s:>9}  {s:>9}  {s:>9}  {s}\n", .{
            conns, enq_ops, lc_ops,
            fmtDuration(latency.delivery_p50, &dp50),
            fmtDuration(latency.delivery_p99, &dp99),
            fmtDuration(latency.e2e_p99, &ep99),
            if (saturated) "<- saturated" else "",
        });
    }
    print("\n", .{});
}

// ============================================================================
// JSON output
// ============================================================================

fn writeJson(config: BenchConfig, enq: PhaseResult, lc: PhaseResult, latency: ServerLatency) void {
    const path = config.json_path orelse return;
    const file = std.fs.cwd().createFile(path, .{}) catch |err| {
        std.debug.print("warning: could not write JSON to {s}: {}\n", .{ path, err });
        return;
    };
    defer file.close();

    const enq_ops = if (enq.wall_ns > 0) enq.ops * 1_000_000_000 / enq.wall_ns else 0;
    const lc_ops = if (lc.wall_ns > 0) lc.ops * 1_000_000_000 / lc.wall_ns else 0;

    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    pos += (std.fmt.bufPrint(buf[pos..], "{{\n  \"config\": {{\n    \"protocol\": \"{s}\",\n    \"total_jobs\": {d},\n    \"concurrency\": {d},\n    \"batch_size\": {d},\n    \"queue\": \"{s}\"\n  }},\n", .{
        @tagName(config.protocol), config.total_jobs, config.concurrency, config.batch_size, config.queue,
    }) catch return).len;

    pos += (std.fmt.bufPrint(buf[pos..], "  \"enqueue\": {{ \"ops\": {d}, \"ops_per_sec\": {d}, \"wall_ns\": {d}, \"errors\": {d} }},\n", .{
        enq.ops, enq_ops, enq.wall_ns, enq.errors,
    }) catch return).len;

    pos += (std.fmt.bufPrint(buf[pos..], "  \"lifecycle\": {{ \"ops\": {d}, \"ops_per_sec\": {d}, \"wall_ns\": {d}, \"errors\": {d} }},\n", .{
        lc.ops, lc_ops, lc.wall_ns, lc.errors,
    }) catch return).len;

    pos += (std.fmt.bufPrint(buf[pos..], "  \"delivery\": {{ \"p50_ns\": {d}, \"p99_ns\": {d}, \"p999_ns\": {d} }},\n", .{
        latency.delivery_p50, latency.delivery_p99, latency.delivery_p999,
    }) catch return).len;

    pos += (std.fmt.bufPrint(buf[pos..], "  \"e2e\": {{ \"p50_ns\": {d}, \"p99_ns\": {d}, \"p999_ns\": {d} }}\n}}\n", .{
        latency.e2e_p50, latency.e2e_p99, latency.e2e_p999,
    }) catch return).len;

    file.writeAll(buf[0..pos]) catch {};
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var config = BenchConfig{};

    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--server")) {
            if (args.next()) |v| {
                if (std.mem.indexOfScalar(u8, v, ':')) |colon| {
                    config.host = v[0..colon];
                    config.port = std.fmt.parseInt(u16, v[colon + 1 ..], 10) catch 9878;
                } else {
                    config.host = v;
                }
            }
        } else if (std.mem.eql(u8, arg, "--mode")) {
            if (args.next()) |v| {
                if (std.mem.eql(u8, v, "combined")) config.mode = .combined
                else if (std.mem.eql(u8, v, "throughput")) config.mode = .throughput
                else if (std.mem.eql(u8, v, "scale")) config.mode = .scale;
            }
        } else if (std.mem.eql(u8, arg, "--protocol")) {
            if (args.next()) |v| {
                if (std.mem.eql(u8, v, "rpc")) config.protocol = .rpc
                else if (std.mem.eql(u8, v, "http")) config.protocol = .http;
            }
        } else if (std.mem.eql(u8, arg, "--jobs")) {
            if (args.next()) |v| config.total_jobs = std.fmt.parseInt(u32, v, 10) catch 100_000;
        } else if (std.mem.eql(u8, arg, "--concurrency")) {
            if (args.next()) |v| config.concurrency = std.fmt.parseInt(u16, v, 10) catch 8;
        } else if (std.mem.eql(u8, arg, "--producers")) {
            if (args.next()) |v| config.producers = std.fmt.parseInt(u16, v, 10) catch 4;
        } else if (std.mem.eql(u8, arg, "--consumers")) {
            if (args.next()) |v| config.consumers = std.fmt.parseInt(u16, v, 10) catch 4;
        } else if (std.mem.eql(u8, arg, "--batch")) {
            if (args.next()) |v| config.batch_size = std.fmt.parseInt(u16, v, 10) catch 64;
        } else if (std.mem.eql(u8, arg, "--queue")) {
            if (args.next()) |v| config.queue = v;
        } else if (std.mem.eql(u8, arg, "--json")) {
            if (args.next()) |v| config.json_path = v;
        } else if (std.mem.eql(u8, arg, "--steps")) {
            if (args.next()) |v| config.steps = std.fmt.parseInt(u16, v, 10) catch 8;
        } else if (std.mem.eql(u8, arg, "--max-conns")) {
            if (args.next()) |v| config.max_conns = std.fmt.parseInt(u16, v, 10) catch 256;
        } else if (std.mem.eql(u8, arg, "--burst")) {
            if (args.next()) |v| config.burst = std.fmt.parseInt(u32, v, 10) catch 5_000;
        }
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    switch (config.mode) {
        .combined => {
            const result = switch (config.protocol) {
                .rpc => try runCombined(RpcClient, config, alloc),
                .http => try runCombined(HttpClient, config, alloc),
            };
            const latency = scrapeMetrics(config.host, config.port);
            printCombinedResult(config, result, latency);
        },
        .scale => switch (config.protocol) {
            .rpc => try runScale(RpcClient, config, alloc),
            .http => try runScale(HttpClient, config, alloc),
        },
        .throughput => {
            const enq = switch (config.protocol) {
                .rpc => try runPhase(RpcClient, enqueueWorker, config, alloc),
                .http => try runPhase(HttpClient, enqueueWorker, config, alloc),
            };
            g_lifecycle_done.store(0, .monotonic);
            g_lifecycle_target = config.total_jobs;

            const lc = switch (config.protocol) {
                .rpc => try runPhase(RpcClient, lifecycleWorker, config, alloc),
                .http => try runPhase(HttpClient, lifecycleWorker, config, alloc),
            };
            const latency = scrapeMetrics(config.host, config.port);
            printThroughputResult(config, enq, lc, latency);
            writeJson(config, enq, lc, latency);
        },
    }
}
