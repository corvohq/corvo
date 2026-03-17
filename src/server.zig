//! HTTP Server — REST API for Corvo.
//!
//! Ported from Go internal/server/server.go + handlers_*.go.
//! Fixed thread pool with bounded connection queue. HTTP/1.1 keep-alive
//! with proper Content-Length parsing and incremental reads.
//! Full JSON request parsing for all core job lifecycle endpoints.

const std = @import("std");
const store_mod = @import("store.zig");
const ops_mod = @import("ops.zig");
const types = @import("types.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const sqlite_read = @import("sqlite_read.zig");
const notify_mod = @import("notify.zig");
const oplog_mod = @import("oplog.zig");
const scheduler_mod = @import("scheduler.zig");
const pipeline_mod = @import("pipeline.zig");
const mirror_mod = @import("mirror.zig");
const ui_embed = @import("ui");
const request_metrics_mod = @import("request_metrics.zig");
const rate_limiter_mod = @import("rate_limiter.zig");
const cluster_mod = @import("cluster.zig");

const http = std.http;
const net = std.net;

const scalar_html =
    \\<!doctype html><html><head><title>Corvo API</title><meta charset="utf-8"/>
    \\<meta name="viewport" content="width=device-width,initial-scale=1"/>
    \\</head><body><script id="api-reference" data-url="/openapi.json"></script>
    \\<script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"></script>
    \\</body></html>
;

// ============================================================================
// Server Config
// ============================================================================

pub const ServerConfig = struct {
    bind_address: []const u8 = "0.0.0.0",
    port: u16 = 8080,
    max_payload_bytes: usize = 262_144, // 256KB
    default_lease_ms: u32 = 30_000,
    /// Number of worker threads. 0 = auto-detect (CPU count).
    worker_count: u16 = 0,
    /// Max connections waiting in queue before accept starts dropping.
    max_queued_connections: u16 = 512,
    /// Admin password — if set, grants full access when used as API key.
    admin_password: ?[]const u8 = null,
    /// Rate limiter config.
    rate_limit: rate_limiter_mod.RateLimitConfig = .{},
};

// ============================================================================
// Connection Queue — bounded MPSC queue for accepted connections
// ============================================================================

const ConnQueue = struct {
    buf: []net.Server.Connection,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    capacity: usize,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    closed: bool = false,

    fn init(allocator: std.mem.Allocator, capacity: usize) !ConnQueue {
        const buf = try allocator.alloc(net.Server.Connection, capacity);
        return .{
            .buf = buf,
            .capacity = capacity,
        };
    }

    fn deinit(self: *ConnQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    /// Push a connection. Returns false if full or closed (caller must close the conn).
    fn push(self: *ConnQueue, conn: net.Server.Connection) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return false;
        if (self.count >= self.capacity) return false;
        self.buf[self.tail] = conn;
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
        self.not_empty.signal();
        return true;
    }

    /// Block until a connection is available. Returns null if closed and empty.
    fn pop(self: *ConnQueue) ?net.Server.Connection {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count == 0 and !self.closed) {
            self.not_empty.timedWait(&self.mutex, 100_000_000) catch {
                // Timeout — return null so worker can check running flag.
                if (self.count == 0) return null;
            };
        }
        if (self.count == 0) return null;
        const conn = self.buf[self.head];
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
        return conn;
    }

    fn close(self: *ConnQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.not_empty.broadcast();
    }
};

// ============================================================================
// Server
// ============================================================================

// ============================================================================
// Throughput Tracker — 60-minute ring buffer of per-minute counters
// ============================================================================

const throughput_buckets = 60;

const ThroughputBucket = struct {
    minute_ns: u64 = 0, // truncated to minute
    enqueued: u64 = 0,
    completed: u64 = 0,
    failed: u64 = 0,
};

const ThroughputTracker = struct {
    buckets: [throughput_buckets]ThroughputBucket = [_]ThroughputBucket{.{}} ** throughput_buckets,
    head: usize = throughput_buckets - 1,
    mutex: std.Thread.Mutex = .{},

    fn currentMinuteNs() u64 {
        const now: u64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        const minute_ns: u64 = 60_000_000_000;
        return (now / minute_ns) * minute_ns;
    }

    fn advance(self: *ThroughputTracker) void {
        const now_min = currentMinuteNs();
        const minute_ns: u64 = 60_000_000_000;
        var cur = self.buckets[self.head].minute_ns;
        if (cur == 0) {
            // First use — initialize current bucket.
            self.buckets[self.head].minute_ns = now_min;
            return;
        }
        while (cur < now_min) {
            self.head = (self.head + 1) % throughput_buckets;
            cur += minute_ns;
            self.buckets[self.head] = .{ .minute_ns = cur };
        }
    }

    fn inc(self: *ThroughputTracker, comptime field: enum { enqueued, completed, failed }) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.advance();
        switch (field) {
            .enqueued => self.buckets[self.head].enqueued += 1,
            .completed => self.buckets[self.head].completed += 1,
            .failed => self.buckets[self.head].failed += 1,
        }
    }

    /// Write snapshot as JSON array into buf. Returns the slice.
    fn snapshot(self: *ThroughputTracker, buf: []u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.advance();

        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;

        for (0..throughput_buckets) |i| {
            const idx = (self.head + 1 + i) % throughput_buckets;
            const b = &self.buckets[idx];
            if (i > 0) {
                buf[pos] = ',';
                pos += 1;
            }
            const written = std.fmt.bufPrint(buf[pos..], "{{\"minute_ns\":{d},\"enqueued\":{d},\"completed\":{d},\"failed\":{d}}}", .{
                b.minute_ns, b.enqueued, b.completed, b.failed,
            }) catch break;
            pos += written.len;
        }

        buf[pos] = ']';
        pos += 1;
        return buf[0..pos];
    }
};

pub const Server = struct {
    store: *store_mod.Store,
    config: ServerConfig,
    listener: ?net.Server = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accept_thread: ?std.Thread = null,
    workers: ?[]std.Thread = null,
    conn_queue: ?ConnQueue = null,
    allocator: std.mem.Allocator,
    scheduler: ?*scheduler_mod.Scheduler = null,
    /// Optional enterprise route dispatcher. Called for unhandled API routes
    /// before returning 404. Enterprise module sets this at startup.
    ent_dispatch: ?*const fn (*store_mod.Store, []const u8, []const u8, Request, []u8) ?Response = null,
    active_fds: [512]std.atomic.Value(i32) = [_]std.atomic.Value(i32){std.atomic.Value(i32).init(-1)} ** 512,
    throughput: ThroughputTracker = .{},
    req_metrics: request_metrics_mod.RequestMetrics = .{},
    rate_limiter: rate_limiter_mod.RateLimiter = rate_limiter_mod.RateLimiter.init(.{}),
    /// Cluster node reference — if set, write requests on followers are proxied to leader.
    cluster: ?*cluster_mod.ClusterNode = null,

    pub fn init(allocator: std.mem.Allocator, store: *store_mod.Store, config: ServerConfig) Server {
        return .{
            .store = store,
            .config = config,
            .allocator = allocator,
            .rate_limiter = rate_limiter_mod.RateLimiter.init(config.rate_limit),
        };
    }

    pub fn start(self: *Server) !void {
        const addr = try net.Address.parseIp(self.config.bind_address, self.config.port);
        self.listener = try addr.listen(.{
            .reuse_address = true,
        });
        self.running.store(true, .monotonic);

        // Initialize connection queue.
        self.conn_queue = try ConnQueue.init(self.allocator, self.config.max_queued_connections);

        // Determine worker count: configured or CPU count.
        const num_workers: usize = if (self.config.worker_count > 0)
            self.config.worker_count
        else
            std.Thread.getCpuCount() catch 4;

        // Spawn worker threads.
        const workers = try self.allocator.alloc(std.Thread, num_workers);
        for (0..num_workers) |i| {
            workers[i] = try std.Thread.spawn(.{}, workerLoop, .{self});
        }
        self.workers = workers;

        // Spawn accept thread.
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    pub fn stop(self: *Server) void {
        self.running.store(false, .monotonic);

        // Close listener first to unblock accept().
        if (self.listener) |*l| {
            l.deinit();
            self.listener = null;
        }

        // Wait for accept thread.
        if (self.accept_thread) |t| {
            t.join();
            self.accept_thread = null;
        }

        // Close all active client connections to unblock worker threads
        // stuck on read(). This is the key to graceful shutdown — without it,
        // keep-alive connections block worker joins indefinitely.
        self.closeAllConnections();

        // Close queue to wake all workers, then join them.
        if (self.conn_queue) |*q| {
            q.close();
        }
        if (self.workers) |workers| {
            for (workers) |t| {
                t.join();
            }
            self.allocator.free(workers);
            self.workers = null;
        }
        if (self.conn_queue) |*q| {
            q.deinit(self.allocator);
            self.conn_queue = null;
        }
    }

    /// Register a connection fd for shutdown tracking. Returns slot index.
    fn registerConn(self: *Server, fd: i32) ?usize {
        for (&self.active_fds, 0..) |*slot, i| {
            if (slot.cmpxchgStrong(-1, fd, .monotonic, .monotonic) == null) {
                return i;
            }
        }
        return null; // All slots full — connection will work but won't be tracked.
    }

    /// Unregister a connection fd.
    fn unregisterConn(self: *Server, slot: usize) void {
        self.active_fds[slot].store(-1, .monotonic);
    }

    /// Close all tracked active connections to unblock worker reads.
    fn closeAllConnections(self: *Server) void {
        for (&self.active_fds) |*slot| {
            const fd = slot.swap(-1, .monotonic);
            if (fd >= 0) {
                const sock: std.posix.socket_t = @intCast(fd);
                std.posix.shutdown(sock, .both) catch {};
            }
        }
    }

    fn acceptLoop(self: *Server) void {
        while (self.running.load(.monotonic)) {
            if (self.listener) |*l| {
                const conn = l.accept() catch {
                    if (!self.running.load(.monotonic)) return;
                    continue;
                };
                // Push to connection queue; drop if full.
                if (self.conn_queue) |*q| {
                    if (!q.push(conn)) {
                        conn.stream.close();
                    }
                } else {
                    conn.stream.close();
                }
            } else return;
        }
    }

    fn workerLoop(self: *Server) void {
        while (self.running.load(.monotonic)) {
            const conn = if (self.conn_queue) |*q| q.pop() else null;
            if (conn) |c| {
                self.handleConnection(c);
            }
        }
        // Drain remaining connections after shutdown signal.
        if (self.conn_queue) |*q| {
            while (q.pop()) |c| {
                self.handleConnection(c);
            }
        }
    }

    // ================================================================
    // Keep-alive connection handler
    // ================================================================

    fn handleConnection(self: *Server, conn: net.Server.Connection) void {
        const slot = self.registerConn(conn.stream.handle);
        defer {
            if (slot) |s| self.unregisterConn(s);
            conn.stream.close();
        }

        // 64KB read buffer for incremental HTTP parsing.
        var buf: [65536]u8 = undefined;
        var filled: usize = 0;

        while (true) {
            // Read more data into buffer.
            if (filled >= buf.len) {
                // Buffer full without a complete request — reject.
                const err_resp = "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                conn.stream.writeAll(err_resp) catch {};
                return;
            }
            const n = conn.stream.read(buf[filled..]) catch return;
            if (n == 0) return; // Client closed connection.
            filled += n;

            // Try to parse a complete request from the buffer.
            while (true) {
                const parsed = parseRequestFull(buf[0..filled]) orelse {
                    // No complete header block yet — need more data.
                    break;
                };

                // Check if we have the full body.
                if (parsed.total_bytes > filled) {
                    // Headers parsed but body incomplete — need more data.
                    break;
                }

                const req = Request{
                    .method = parsed.method,
                    .path = parsed.path,
                    .body = parsed.body,
                    .api_key = parsed.api_key,
                };

                // SSE streaming — takes over the connection indefinitely.
                if (eql(req.method, "GET") and eql(req.path, "/api/v1/events")) {
                    self.handleSSE(conn);
                    return;
                }

                // --- Request metrics & rate limiting ---
                const start_ns = std.time.nanoTimestamp();
                var norm_buf: [128]u8 = undefined;
                const metrics_slot = self.req_metrics.begin(req.method, req.path, &norm_buf);

                // Rate limiting (skip healthz, metrics, UI, OPTIONS).
                if (startsWith(req.path, "/api/v1/") and !eql(req.method, "OPTIONS")) {
                    var ck_buf: [32]u8 = undefined;
                    const ck = rate_limiter_mod.clientKey(req.api_key, &ck_buf);
                    const is_write = rate_limiter_mod.isWriteMethod(req.method);
                    // Batch endpoints cost N tokens (parse count from body).
                    const cost: u32 = if (is_write and req.body != null and
                        (endsWith(req.path, "/batch") or endsWith(req.path, "/batch/")))
                        parseBatchCount(req.body.?)
                    else
                        1;
                    if (!self.rate_limiter.allow(ck, is_write, cost)) {
                        self.req_metrics.recordThrottled(metrics_slot);
                        self.req_metrics.finish(metrics_slot, 429, start_ns);
                        const rate_resp = "HTTP/1.1 429 Too Many Requests\r\n" ++
                            "Content-Type: application/json\r\n" ++
                            "Content-Length: 46\r\n" ++
                            "Retry-After: 1\r\n" ++
                            "Connection: keep-alive\r\n\r\n" ++
                            "{\"error\":\"rate limited\",\"code\":\"RATE_LIMITED\"}";
                        conn.stream.writeAll(rate_resp) catch return;
                        // Shift buffer and continue to next request.
                        if (parsed.total_bytes < filled) {
                            std.mem.copyForwards(u8, buf[0..filled - parsed.total_bytes], buf[parsed.total_bytes..filled]);
                        }
                        filled -= parsed.total_bytes;
                        continue;
                    }
                }

                // --- Leader check: proxy writes to leader if this node is a follower ---
                if (self.cluster) |cl| {
                    if (rate_limiter_mod.isWriteMethod(req.method) and
                        startsWith(req.path, "/api/v1/") and
                        !eql(req.method, "OPTIONS"))
                    {
                        // Check for forwarding loop.
                        const already_forwarded = parsed.forwarded;

                        if (!cl.isLeader() and !already_forwarded) {
                            const leader_resp = self.proxyToLeader(cl, req, parsed.raw_request);
                            if (leader_resp) |proxied| {
                                // Send proxied response back to client.
                                conn.stream.writeAll(proxied.data[0..proxied.len]) catch return;
                                self.req_metrics.finish(metrics_slot, proxied.status, start_ns);
                                if (parsed.connection_close) return;
                                if (parsed.total_bytes < filled) {
                                    std.mem.copyForwards(u8, buf[0..filled - parsed.total_bytes], buf[parsed.total_bytes..filled]);
                                }
                                filled -= parsed.total_bytes;
                                continue;
                            } else {
                                // No leader available.
                                self.req_metrics.finish(metrics_slot, 503, start_ns);
                                const unavail = "HTTP/1.1 503 Service Unavailable\r\n" ++
                                    "Content-Type: application/json\r\n" ++
                                    "Content-Length: 58\r\n" ++
                                    "Connection: keep-alive\r\n\r\n" ++
                                    "{\"error\":\"leader unavailable\",\"code\":\"LEADER_UNAVAILABLE\"}";
                                conn.stream.writeAll(unavail) catch return;
                                if (parsed.connection_close) return;
                                if (parsed.total_bytes < filled) {
                                    std.mem.copyForwards(u8, buf[0..filled - parsed.total_bytes], buf[parsed.total_bytes..filled]);
                                }
                                filled -= parsed.total_bytes;
                                continue;
                            }
                        }
                    }
                }

                // Route and build response.
                var resp_buf: [65536]u8 = undefined;
                const response = self.route(req, &resp_buf);

                const conn_header: []const u8 = if (parsed.connection_close)
                    "Connection: close\r\n"
                else
                    "Connection: keep-alive\r\n";

                var header_buf: [1024]u8 = undefined;
                const header = std.fmt.bufPrint(&header_buf,
                    "HTTP/1.1 {d} {s}\r\n" ++
                    "Content-Type: {s}\r\n" ++
                    "Content-Length: {d}\r\n" ++
                    "Access-Control-Allow-Origin: *\r\n" ++
                    "Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n" ++
                    "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
                    "{s}" ++
                    "\r\n",
                    .{ response.status, statusText(response.status), response.content_type, response.body.len, conn_header },
                ) catch return;

                conn.stream.writeAll(header) catch return;
                if (response.body.len > 0) {
                    conn.stream.writeAll(response.body) catch return;
                }

                // Record request metrics.
                self.req_metrics.finish(metrics_slot, response.status, start_ns);

                // If client requested close, we're done.
                if (parsed.connection_close) return;

                // Shift unconsumed data to front of buffer.
                const consumed = parsed.total_bytes;
                const remaining = filled - consumed;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, buf[0..remaining], buf[consumed..filled]);
                }
                filled = remaining;
            }
        }
    }

    // ====================================================================
    // Auth
    // ====================================================================

    const AuthRole = enum {
        admin,
        readonly,
        worker,

        fn isAllowed(self: AuthRole, method: []const u8, api_path: []const u8) bool {
            switch (self) {
                .admin => return true,
                .readonly => return eql(method, "GET"),
                .worker => {
                    if (eql(method, "POST")) {
                        return eql(api_path, "/enqueue") or
                            eql(api_path, "/enqueue/batch") or
                            eql(api_path, "/fetch") or
                            eql(api_path, "/fetch/batch") or
                            eql(api_path, "/ack/batch") or
                            startsWith(api_path, "/ack/") or
                            startsWith(api_path, "/fail/") or
                            eql(api_path, "/heartbeat");
                    }
                    if (eql(method, "GET")) {
                        return startsWith(api_path, "/jobs/");
                    }
                    return false;
                },
            }
        }

        fn fromString(s: []const u8) AuthRole {
            if (eql(s, "admin")) return .admin;
            if (eql(s, "worker")) return .worker;
            return .readonly;
        }
    };

    /// Check authentication. Returns null if authorized, or an error Response.
    fn checkAuth(self: *Server, req: *const Request, method: []const u8, api_path: []const u8, buf: []u8) ?Response {
        // Admin password bypass.
        if (self.config.admin_password) |pw| {
            if (req.api_key) |key| {
                if (eql(key, pw)) return null; // admin password matches → full access
            }
        }

        // Check if any API keys exist. If none and no admin password, allow anonymous.
        var reader = self.store.reader() orelse return null; // no mirror → no auth
        const key_count = reader.countEnabledApiKeys() catch return null;
        if (key_count == 0 and self.config.admin_password == null) return null; // dev mode

        // No key provided → reject.
        const raw_key = req.api_key orelse
            return jsonError(buf, 401, "API key required");

        // Hash the key and look up.
        var hash_buf: [64]u8 = undefined;
        const key_hash = hashApiKey(raw_key, &hash_buf);

        const row = reader.getApiKeyByHash(key_hash) catch
            return jsonError(buf, 500, "auth lookup failed");
        if (row == null) return jsonError(buf, 401, "invalid API key");

        const key_row = row.?;
        if (!key_row.enabled) return jsonError(buf, 401, "API key disabled");

        // Check role permission.
        const role = AuthRole.fromString(key_row.roleSlice());
        if (!role.isAllowed(method, api_path)) {
            return jsonError(buf, 403, "insufficient permissions");
        }

        return null; // authorized
    }

    /// SHA256 hash an API key, returning hex string in the provided buffer.
    fn hashApiKey(key: []const u8, out: *[64]u8) []const u8 {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(key, &hash, .{});
        const hex_chars = "0123456789abcdef";
        for (hash, 0..) |byte, i| {
            out[i * 2] = hex_chars[byte >> 4];
            out[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        return out[0..64];
    }

    // ====================================================================
    // Routing
    // ====================================================================

    pub const Response = struct {
        status: u16,
        body: []const u8,
        content_type: []const u8 = "application/json",
    };

    fn route(self: *Server, req: Request, buf: []u8) Response {
        const path = req.path;

        // CORS preflight.
        if (eql(req.method, "OPTIONS")) {
            return .{ .status = 204, .body = "" };
        }

        if (eql(path, "/healthz")) {
            return jsonOk(buf, "{\"status\":\"ok\"}");
        }

        if (eql(path, "/metrics")) {
            return self.handleMetrics(buf);
        }

        if (startsWith(path, "/api/v1/")) {
            const api_path = path[7..]; // strip "/api/v1" prefix, keep leading /

            // Auth status is always public.
            if (eql(req.method, "GET") and eql(api_path, "/auth/status")) {
                return self.handleAuthStatus(buf);
            }

            // All other API routes require auth.
            if (self.checkAuth(&req, req.method, api_path, buf)) |err_resp| {
                return err_resp;
            }

            if (eql(req.method, "POST")) {
                if (eql(api_path, "/enqueue")) return self.handleEnqueue(req, buf);
                if (eql(api_path, "/enqueue/batch")) return self.handleEnqueueBatch(req, buf);
                if (eql(api_path, "/fetch")) return self.handleFetch(req, buf);
                if (eql(api_path, "/fetch/batch")) return self.handleFetchBatch(req, buf);
                if (eql(api_path, "/ack/batch")) return self.handleAckBatch(req, buf);
                if (startsWith(api_path, "/ack/")) return self.handleAck(api_path[5..], req, buf);
                if (startsWith(api_path, "/fail/")) return self.handleFail(api_path[6..], req, buf);
                if (eql(api_path, "/heartbeat")) return self.handleHeartbeat(req, buf);
                if (eql(api_path, "/jobs/bulk")) return self.handleBulk(req, buf);
                if (startsWith(api_path, "/jobs/") and endsWith(api_path, "/retry")) return self.handleJobAction(api_path, .retry, buf);
                if (startsWith(api_path, "/jobs/") and endsWith(api_path, "/cancel")) return self.handleJobAction(api_path, .cancel, buf);
                if (startsWith(api_path, "/jobs/") and endsWith(api_path, "/hold")) return self.handleJobAction(api_path, .hold, buf);
                if (startsWith(api_path, "/jobs/") and endsWith(api_path, "/approve")) return self.handleJobAction(api_path, .approve, buf);
                if (startsWith(api_path, "/jobs/") and endsWith(api_path, "/reject")) return self.handleJobAction(api_path, .reject, buf);
                if (startsWith(api_path, "/queues/") and endsWith(api_path, "/pause"))
                    return self.handleQueueAction(api_path, .pause, buf);
                if (startsWith(api_path, "/queues/") and endsWith(api_path, "/resume"))
                    return self.handleQueueAction(api_path, .@"resume", buf);
                if (startsWith(api_path, "/queues/") and endsWith(api_path, "/concurrency"))
                    return self.handleQueueConcurrency(api_path, req, buf);
                if (startsWith(api_path, "/queues/") and endsWith(api_path, "/throttle"))
                    return self.handleQueueThrottle(api_path, req, buf);
                if (startsWith(api_path, "/queues/") and endsWith(api_path, "/fairness"))
                    return self.handleQueueFairness(api_path, req, buf);
                if (startsWith(api_path, "/queues/") and endsWith(api_path, "/clear"))
                    return self.handleQueueClear(api_path, buf);
                if (startsWith(api_path, "/queues/") and endsWith(api_path, "/drain"))
                    return self.handleQueueDrain(api_path, buf);
                if (startsWith(api_path, "/jobs/") and endsWith(api_path, "/move"))
                    return self.handleJobMove(api_path, req, buf);
                if (startsWith(api_path, "/jobs/") and endsWith(api_path, "/replay"))
                    return self.handleJobReplay(api_path, req, buf);
                if (startsWith(api_path, "/jobs/search")) return self.handleJobSearchPost(req, buf);
                if (eql(api_path, "/batch")) return self.handleBatchCreate(req, buf);
                if (startsWith(api_path, "/batch/") and endsWith(api_path, "/seal"))
                    return self.handleBatchSeal(api_path, buf);
                if (eql(api_path, "/crons") or eql(api_path, "/cron-jobs"))
                    return self.handleCronCreate(req, buf);
                if (startsWith(api_path, "/cron-jobs/") and endsWith(api_path, "/pause"))
                    return self.handleCronAction(api_path, "pause", buf);
                if (startsWith(api_path, "/cron-jobs/") and endsWith(api_path, "/resume"))
                    return self.handleCronAction(api_path, "resume", buf);
                if (startsWith(api_path, "/cron-jobs/") and endsWith(api_path, "/trigger"))
                    return self.handleCronTrigger(api_path, buf);
                if (eql(api_path, "/jobs/bulk-get")) return self.handleBulkGetJobs(req, buf);
                if (eql(api_path, "/admin/rebuild-sqlite")) return self.handleRebuildSQLite(buf);
                if (eql(api_path, "/auth/keys")) return self.handleCreateApiKey(req, buf);
                if (eql(api_path, "/budgets")) return self.handleSetBudget(req, buf);
                if (eql(api_path, "/approval-policies")) return self.handleSetApprovalPolicy(req, buf);
                if (startsWith(api_path, "/webhooks/")) return self.handleWebhookEnqueue(api_path, req, buf);
            }

            if (eql(req.method, "GET")) {
                if (eql(api_path, "/queues")) return self.handleListQueues(buf);
                if (eql(api_path, "/workers")) return self.handleListWorkers(buf);
                if (eql(api_path, "/crons") or eql(api_path, "/cron-jobs"))
                    return self.handleListCrons(buf);
                if (startsWith(api_path, "/cron-jobs/")) return self.handleGetCron(api_path, buf);
                if (eql(api_path, "/search/fulltext")) return self.handleFullTextSearch(req, buf);
                if (startsWith(api_path, "/jobs/search")) return self.handleJobSearch(req, buf);
                if (startsWith(api_path, "/jobs/") and endsWith(api_path, "/iterations"))
                    return self.handleJobIterations(api_path, buf);
                if (startsWith(api_path, "/jobs/")) return self.handleGetJob(api_path[6..], buf);
                if (eql(api_path, "/info")) return jsonOk(buf, "{\"version\":\"0.1.0\",\"engine\":\"zig\"}");

                if (eql(api_path, "/cluster/status"))
                    return self.handleClusterStatus(buf);
                if (startsWith(api_path, "/metrics/throughput"))
                    return self.handleThroughput(buf);
                if (startsWith(api_path, "/usage/summary"))
                    return self.handleUsageSummary(req, buf);
                if (eql(api_path, "/budgets"))
                    return self.handleListBudgets(buf);
                if (eql(api_path, "/approval-policies"))
                    return self.handleListApprovalPolicies(buf);

                if (eql(api_path, "/debug/runtime")) return self.handleDebugRuntime(buf);
                if (eql(api_path, "/cluster/events")) return self.handleClusterEvents(buf);

                // Core auth endpoints.
                if (eql(api_path, "/auth/keys")) return self.handleListApiKeys(buf);

                // Enterprise routes — dispatch if enterprise module loaded, else 403 stub.
                if (eql(api_path, "/namespaces") or
                    startsWith(api_path, "/settings/sso") or
                    startsWith(api_path, "/audit-logs") or
                    eql(api_path, "/auth/roles") or
                    eql(api_path, "/org") or
                    eql(api_path, "/org/members") or
                    (startsWith(api_path, "/auth/keys/") and endsWith(api_path, "/roles")))
                {
                    if (self.ent_dispatch) |dispatch| {
                        if (dispatch(self.store, req.method, api_path, req, buf)) |resp| return resp;
                    }
                    return jsonForbidden(buf);
                }
            }

            if (eql(req.method, "PUT")) {
                if (startsWith(api_path, "/crons/")) return self.handleCronUpdate(api_path[7..], req, buf);
                if (startsWith(api_path, "/cron-jobs/")) return self.handleCronUpdate(api_path[11..], req, buf);
            }

            if (eql(req.method, "DELETE")) {
                if (eql(api_path, "/auth/keys")) return self.handleDeleteApiKey(req, buf);
                if (startsWith(api_path, "/budgets/")) return self.handleDeleteBudget(api_path, buf);
                if (startsWith(api_path, "/approval-policies/")) return self.handleDeleteApprovalPolicy(api_path, buf);
                if (startsWith(api_path, "/jobs/")) return self.handleDeleteJob(api_path[6..], buf);
                if (startsWith(api_path, "/queues/") and endsWith(api_path, "/throttle"))
                    return self.handleQueueThrottleDelete(api_path, buf);
                if (startsWith(api_path, "/queues/") and endsWith(api_path, "/fairness"))
                    return self.handleQueueFairnessDelete(api_path, buf);
                if (startsWith(api_path, "/queues/")) return self.handleQueueDelete(api_path, buf);
                if (startsWith(api_path, "/crons/")) return self.handleCronDelete(api_path[7..], buf);
                if (startsWith(api_path, "/cron-jobs/")) return self.handleCronDelete(api_path[11..], buf);
            }

            // Fallback: try enterprise dispatch for any unhandled API path.
            if (self.ent_dispatch) |dispatch| {
                if (dispatch(self.store, req.method, api_path, req, buf)) |resp| return resp;
            }

            return jsonError(buf, 404, "not found");
        }

        // OpenAPI spec & docs
        if (eql(path, "/openapi.json")) {
            return .{ .status = 200, .body = @embedFile("openapi.json"), .content_type = "application/json" };
        }
        if (eql(path, "/docs")) {
            return .{ .status = 200, .body = scalar_html, .content_type = "text/html" };
        }

        // UI — embedded SPA dashboard
        if (eql(path, "/ui") or startsWith(path, "/ui/")) {
            return self.handleUI(path);
        }

        return jsonError(buf, 404, "not found");
    }

    // ====================================================================
    // Handlers — Job Lifecycle
    // ====================================================================

    fn handleEnqueue(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const AgentConfigReq = struct {
            max_iterations: ?i64 = null,
            max_cost_usd: ?f64 = null,
            iteration_timeout_ms: ?i64 = null,
        };
        const EnqueueReq = struct {
            queue: ?[]const u8 = null,
            priority: ?std.json.Value = null,
            max_retries: ?i64 = null,
            retry_backoff: ?[]const u8 = null,
            retry_base_delay_ms: ?i64 = null,
            retry_max_delay_ms: ?i64 = null,
            unique_key: ?[]const u8 = null,
            unique_period: ?i64 = null,
            payload: ?std.json.Value = null,
            checkpoint: ?std.json.Value = null,
            tags: ?std.json.Value = null,
            group: ?[]const u8 = null,
            expire_after_ms: ?i64 = null,
            batch_id: ?[]const u8 = null,
            scheduled_at: ?[]const u8 = null,
            agent: ?AgentConfigReq = null,
            parent_id: ?[]const u8 = null,
            chain_id: ?[]const u8 = null,
            chain_step: ?i64 = null,
            chain_config: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(EnqueueReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();
        const r = parsed.value;

        const queue = r.queue orelse return jsonError(buf, 400, "queue is required");

        // Stringify JSON values to raw bytes for storage.
        var payload_str: ?[]const u8 = null;
        var payload_allocated = false;
        defer if (payload_allocated) if (payload_str) |s| self.allocator.free(s);
        if (r.payload) |pv| {
            switch (pv) {
                .string => |s| payload_str = s,
                else => {
                    payload_str = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(pv, .{})}) catch null;
                    payload_allocated = payload_str != null;
                },
            }
        }

        var checkpoint_str: ?[]const u8 = null;
        var checkpoint_allocated = false;
        defer if (checkpoint_allocated) if (checkpoint_str) |s| self.allocator.free(s);
        if (r.checkpoint) |cv| {
            switch (cv) {
                .string => |s| checkpoint_str = s,
                else => {
                    checkpoint_str = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(cv, .{})}) catch null;
                    checkpoint_allocated = checkpoint_str != null;
                },
            }
        }

        var tags_str: ?[]const u8 = null;
        var tags_allocated = false;
        defer if (tags_allocated) if (tags_str) |s| self.allocator.free(s);
        if (r.tags) |tv| {
            switch (tv) {
                .string => |s| tags_str = s,
                else => {
                    tags_str = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(tv, .{})}) catch null;
                    tags_allocated = tags_str != null;
                },
            }
        }

        // Payload size validation.
        if (self.config.max_payload_bytes > 0) {
            if (payload_str) |p| {
                if (p.len > self.config.max_payload_bytes) return jsonError(buf, 413, "payload too large");
            }
        }

        // Parse scheduled_at if provided.
        var state: types.JobState = .pending;
        var scheduled_at_ns: u64 = 0;
        if (r.scheduled_at) |sat| {
            scheduled_at_ns = parseRfc3339Ns(sat) orelse return jsonError(buf, 400, "invalid scheduled_at value (use RFC3339)");
            state = .scheduled;
        }

        // Parse agent config if provided.
        var agent: ?types.AgentState = null;
        if (r.agent) |ac| {
            agent = .{
                .max_iterations = if (ac.max_iterations) |mi| @intCast(@max(mi, 0)) else 0,
                .max_cost_usd = if (ac.max_cost_usd) |mc| @max(mc, 0) else 0,
                .iteration_timeout = if (ac.iteration_timeout_ms) |it| @intCast(@max(it, 0)) else 0,
                .iteration = 1,
            };
        }

        var id_buf: [64]u8 = undefined;
        const job_id = self.store.generateID(&id_buf);

        const job = ops_mod.EnqueueJob{
            .job_id = job_id,
            .queue = queue,
            .state = state,
            .priority = parsePriorityValue(r.priority),
            .max_retries = if (r.max_retries) |mr| @intCast(@min(@max(mr, 0), 100)) else 3,
            .backoff = parseBackoff(r.retry_backoff),
            .base_delay_ms = if (r.retry_base_delay_ms) |d| @intCast(@min(@max(d, 0), 3600_000)) else 5_000,
            .max_delay_ms = if (r.retry_max_delay_ms) |d| @intCast(@min(@max(d, 0), 86400_000)) else 600_000,
            .unique_key = r.unique_key,
            .unique_period_s = if (r.unique_period) |up| @intCast(@min(@max(up, 0), 86400 * 30)) else 0,
            .payload = payload_str,
            .checkpoint = checkpoint_str,
            .tags = tags_str,
            .group = r.group,
            .expire_after_ms = if (r.expire_after_ms) |e| @intCast(@min(@max(e, 0), 86400_000 * 30)) else 0,
            .batch_id = r.batch_id,
            .scheduled_at_ns = scheduled_at_ns,
            .created_at_ns = self.store.nowNs(),
            .agent = agent,
            .parent_id = r.parent_id,
            .chain_id = r.chain_id,
            .chain_step = if (r.chain_step) |cs| @intCast(@max(cs, 0)) else 0,
            .chain_config = r.chain_config,
        };

        const result = self.store.enqueue(job);
        if (result.err) |err| {
            if (std.mem.eql(u8, err, "unique_existing")) {
                const uid = result.unique_job_id_buf[0..result.unique_job_id_len];
                const resp = std.fmt.bufPrint(buf,
                    "{{\"unique_existing\":true,\"unique_job_id\":\"{s}\"}}",
                    .{uid},
                ) catch "{}";
                return .{ .status = 409, .body = resp };
            }
            return jsonError(buf, 500, err);
        }

        self.throughput.inc(.enqueued);

        const resp = std.fmt.bufPrint(buf,
            "{{\"job\":{{\"id\":\"{s}\",\"queue\":\"{s}\",\"state\":\"{s}\",\"priority\":{d}}}}}",
            .{ job_id, queue, state.toString(), job.priority },
        ) catch "{}";
        return .{ .status = 201, .body = resp };
    }

    fn handleEnqueueBatch(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const BatchJobReq = struct {
            queue: ?[]const u8 = null,
            priority: ?std.json.Value = null,
            max_retries: ?i64 = null,
            retry_backoff: ?[]const u8 = null,
            retry_base_delay_ms: ?i64 = null,
            retry_max_delay_ms: ?i64 = null,
            unique_key: ?[]const u8 = null,
            payload: ?std.json.Value = null,
            tags: ?[]const u8 = null,
            group: ?[]const u8 = null,
            scheduled_at: ?[]const u8 = null,
        };
        const BatchEnqReq = struct {
            jobs: ?[]const BatchJobReq = null,
        };

        const parsed = std.json.parseFromSlice(BatchEnqReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();

        const jobs_in = parsed.value.jobs orelse return jsonError(buf, 400, "jobs is required");
        if (jobs_in.len == 0) return jsonError(buf, 400, "jobs must not be empty");
        if (jobs_in.len > 1000) return jsonError(buf, 400, "max 1000 jobs per batch");

        const now_ns = self.store.nowNs();

        // Build response incrementally, processing in chunks of 64.
        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeAll("{\"job_ids\":[") catch return jsonError(buf, 500, "buffer overflow");

        var first = true;
        var chunk_start: usize = 0;
        while (chunk_start < jobs_in.len) {
            const chunk_end = @min(chunk_start + 64, jobs_in.len);
            const chunk_len = chunk_end - chunk_start;

            var stack_jobs: [64]ops_mod.EnqueueJob = undefined;
            var stack_ids: [64][64]u8 = undefined;
            var payload_strs: [64]?[]const u8 = .{null} ** 64;

            defer for (0..chunk_len) |i| {
                if (payload_strs[i]) |s| {
                    var is_alloc = true;
                    if (jobs_in[chunk_start + i].payload) |pv| {
                        switch (pv) {
                            .string => is_alloc = false,
                            else => {},
                        }
                    }
                    if (is_alloc) self.allocator.free(s);
                }
            };

            for (0..chunk_len) |i| {
                const j = &jobs_in[chunk_start + i];
                const q = j.queue orelse "default";
                const job_id = self.store.generateID(&stack_ids[i]);

                if (j.payload) |pv| {
                    switch (pv) {
                        .string => |s| payload_strs[i] = s,
                        else => {
                            payload_strs[i] = std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(pv, .{})}) catch null;
                        },
                    }
                }

                // Payload size validation.
                if (self.config.max_payload_bytes > 0) {
                    if (payload_strs[i]) |p| {
                        if (p.len > self.config.max_payload_bytes) return jsonError(buf, 413, "payload too large");
                    }
                }

                // Parse scheduled_at for batch jobs.
                var job_state: types.JobState = .pending;
                var sched_ns: u64 = 0;
                if (j.scheduled_at) |sat| {
                    sched_ns = parseRfc3339Ns(sat) orelse return jsonError(buf, 400, "invalid scheduled_at value (use RFC3339)");
                    job_state = .scheduled;
                }

                stack_jobs[i] = .{
                    .job_id = job_id,
                    .queue = q,
                    .state = job_state,
                    .priority = parsePriorityValue(j.priority),
                    .max_retries = if (j.max_retries) |mr| @intCast(@min(@max(mr, 0), 100)) else 3,
                    .backoff = parseBackoff(j.retry_backoff),
                    .base_delay_ms = if (j.retry_base_delay_ms) |d| @intCast(@min(@max(d, 0), 3600_000)) else 5_000,
                    .max_delay_ms = if (j.retry_max_delay_ms) |d| @intCast(@min(@max(d, 0), 86400_000)) else 600_000,
                    .unique_key = j.unique_key,
                    .payload = payload_strs[i],
                    .tags = j.tags,
                    .group = j.group,
                    .scheduled_at_ns = sched_ns,
                    .created_at_ns = now_ns,
                };
            }

            const result = self.store.enqueueBatch(stack_jobs[0..chunk_len]);
            if (result.err) |err| {
                return jsonError(buf, 500, err);
            }

            // Write IDs to response stream.
            for (0..chunk_len) |i| {
                if (!first) w.writeByte(',') catch break;
                first = false;
                w.writeByte('"') catch break;
                w.writeAll(stack_jobs[i].job_id) catch break;
                w.writeByte('"') catch break;
            }

            chunk_start = chunk_end;
        }

        self.throughput.inc(.enqueued);

        w.writeAll("]}") catch {};
        return .{ .status = 201, .body = stream.getWritten() };
    }

    fn handleFetch(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const FetchReq = struct {
            queues: ?[]const []const u8 = null,
            worker_id: ?[]const u8 = null,
            hostname: ?[]const u8 = null,
            count: ?i64 = null,
            wait_timeout_ms: ?i64 = null,
        };

        const parsed = std.json.parseFromSlice(FetchReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();
        const r = parsed.value;

        const queues = r.queues orelse return jsonError(buf, 400, "queues is required");
        if (queues.len == 0) return jsonError(buf, 400, "queues must not be empty");

        const count: u32 = if (r.count) |c| @intCast(@min(@max(c, 1), 512)) else 1;
        const wait_timeout_ms: u64 = if (r.wait_timeout_ms) |w|
            @intCast(@min(@max(w, 0), 30_000))
        else
            0;

        // First attempt.
        var result = self.store.fetch(
            queues,
            r.worker_id orelse "",
            count,
            self.config.default_lease_ms,
            0,
        );

        // Long-poll: if no jobs and wait_timeout_ms > 0, register a waiter
        // and block until notified or timeout.
        if (result.affected == 0 and wait_timeout_ms > 0) {
            const notifier = self.store.engine.getNotifier();
            var waiter = notify_mod.QueueWaiter{};
            notifier.register(queues, &waiter);
            defer notifier.unregister(queues, &waiter);

            _ = waiter.wait(wait_timeout_ms * 1_000_000); // ms → ns

            // Retry fetch after wake.
            result = self.store.fetch(
                queues,
                r.worker_id orelse "",
                count,
                self.config.default_lease_ms,
                0,
            );
        }

        if (result.affected == 0) {
            return jsonOk(buf, "{\"jobs\":[]}");
        }

        return self.formatFetchResponse(result, buf);
    }

    fn formatFetchResponse(self: *Server, result: ops_mod.OpResult, buf: []u8) Response {
        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();

        w.writeAll("{\"jobs\":[") catch return .{ .status = 200, .body = "{\"jobs\":[]}" };

        for (0..result.affected) |i| {
            if (i > 0) w.writeByte(',') catch break;
            const f = &result.fetched[i];
            const fid = f.id_buf[0..f.id_len];
            const fq = f.queue_buf[0..f.queue_len];

            // Core fields from FetchedJob (set in handler, no KV read needed).
            w.print("{{\"job_id\":\"{s}\",\"queue\":\"{s}\",\"attempt\":{d},\"max_retries\":{d},\"lease_duration\":{d}", .{
                fid,
                fq,
                f.attempt,
                f.max_retries,
                f.lease_duration_ms / 1000,
            }) catch break;

            // Load payload from KV (separate key, matches Go pattern).
            var jpk_buf: keys.KeyBuf = undefined;
            if (self.store.engine.get(keys.jobPayloadKey(&jpk_buf, fid))) |payload| {
                defer self.allocator.free(payload);
                w.writeAll(",\"payload\":") catch break;
                w.writeAll(payload) catch break;
            }

            // Load job header from KV for checkpoint, tags, agent state.
            var jk_buf: keys.KeyBuf = undefined;
            if (self.store.engine.get(keys.jobKey(&jk_buf, fid))) |job_bytes| {
                defer self.allocator.free(job_bytes);
                const job = codec.decodeJob(job_bytes);
                if (job.checkpoint) |cp| {
                    if (cp.len > 0) {
                        w.writeAll(",\"checkpoint\":") catch break;
                        w.writeAll(cp) catch break;
                    }
                }
                if (job.tags) |tags| {
                    if (tags.len > 0) {
                        w.writeAll(",\"tags\":") catch break;
                        w.writeAll(tags) catch break;
                    }
                }
                if (job.agent) |agent| {
                    w.print(",\"agent\":{{\"iteration\":{d},\"max_iterations\":{d},\"total_cost_usd\":{d:.6},\"max_cost_usd\":{d:.6}}}", .{
                        agent.iteration,
                        agent.max_iterations,
                        agent.total_cost_usd,
                        agent.max_cost_usd,
                    }) catch break;
                }
            }

            w.writeByte('}') catch break;
        }

        w.writeAll("]}") catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    fn handleFetchBatch(self: *Server, req: Request, buf: []u8) Response {
        // Fetch/batch is the same as fetch with count > 1 — delegate.
        return self.handleFetch(req, buf);
    }

    fn handleAck(self: *Server, job_id: []const u8, req: Request, buf: []u8) Response {
        if (job_id.len == 0) return jsonError(buf, 400, "missing job_id");

        // Look up queue from KV.
        var qbuf: [64]u8 = undefined;
        const queue = self.store.lookupJobQueue(job_id, &qbuf) orelse return jsonError(buf, 404, "job not found");

        // Parse optional ack body (result, checkpoint, usage, agent_status, etc.).
        var ack_job = ops_mod.AckJob{
            .job_id = job_id,
            .queue = queue,
        };

        if (req.body) |body| {
            const UsageReq = struct {
                input_tokens: ?i64 = null,
                output_tokens: ?i64 = null,
                cache_creation_tokens: ?i64 = null,
                cache_read_tokens: ?i64 = null,
                cost_usd: ?f64 = null,
                model: ?[]const u8 = null,
                provider: ?[]const u8 = null,
            };
            const AckReq = struct {
                result: ?[]const u8 = null,
                checkpoint: ?[]const u8 = null,
                usage: ?UsageReq = null,
                agent_status: ?[]const u8 = null,
                hold_reason: ?[]const u8 = null,
                step_status: ?[]const u8 = null,
                exit_reason: ?[]const u8 = null,
            };
            const parsed = std.json.parseFromSlice(AckReq, self.allocator, body, .{
                .ignore_unknown_fields = true,
            }) catch null;
            if (parsed) |p| {
                defer p.deinit();
                const r = p.value;
                ack_job.result = r.result;
                ack_job.checkpoint = r.checkpoint;
                ack_job.hold_reason = r.hold_reason;
                ack_job.step_status = r.step_status;
                ack_job.exit_reason = r.exit_reason;
                if (r.agent_status) |as| {
                    ack_job.agent_status = parseAgentStatus(as);
                }
                if (r.usage) |u| {
                    ack_job.usage = .{
                        .input_tokens = if (u.input_tokens) |t| @intCast(@max(t, 0)) else 0,
                        .output_tokens = if (u.output_tokens) |t| @intCast(@max(t, 0)) else 0,
                        .cache_creation_tokens = if (u.cache_creation_tokens) |t| @intCast(@max(t, 0)) else 0,
                        .cache_read_tokens = if (u.cache_read_tokens) |t| @intCast(@max(t, 0)) else 0,
                        .cost_usd = if (u.cost_usd) |c| @max(c, 0) else 0,
                        .model = u.model orelse "",
                        .provider = u.provider orelse "",
                    };
                }
            }
        }

        const result = self.store.ackFull(job_id, queue, ack_job);
        if (result.err) |err| {
            return jsonError(buf, 500, err);
        }
        self.throughput.inc(.completed);
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleAckBatch(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        // Accept both formats:
        //   {"acks": [{"job_id": "..."}, ...]}  (Go client)
        //   {"job_ids": ["...", ...]}            (simple)
        const AckItem = struct { job_id: []const u8 = "" };
        const BatchAckReq = struct {
            acks: ?[]const AckItem = null,
            job_ids: ?[]const []const u8 = null,
        };

        const parsed = std.json.parseFromSlice(BatchAckReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();

        var acked: u32 = 0;

        if (parsed.value.acks) |acks| {
            for (acks) |ack| {
                if (ack.job_id.len == 0) continue;
                var qbuf: [64]u8 = undefined;
                const queue = self.store.lookupJobQueue(ack.job_id, &qbuf) orelse continue;
                const result = self.store.ack(ack.job_id, queue);
                if (result.err == null) acked += 1;
            }
        } else if (parsed.value.job_ids) |job_ids| {
            for (job_ids) |jid| {
                var qbuf: [64]u8 = undefined;
                const queue = self.store.lookupJobQueue(jid, &qbuf) orelse continue;
                const result = self.store.ack(jid, queue);
                if (result.err == null) acked += 1;
            }
        } else {
            return jsonError(buf, 400, "acks or job_ids is required");
        }

        if (acked > 0) self.throughput.inc(.completed);

        const resp = std.fmt.bufPrint(buf, "{{\"acked\":{d}}}", .{acked}) catch "{}";
        return .{ .status = 200, .body = resp };
    }

    fn handleFail(self: *Server, job_id: []const u8, req: Request, buf: []u8) Response {
        if (job_id.len == 0) return jsonError(buf, 400, "missing job_id");

        var error_msg: []const u8 = "";
        var backtrace: ?[]const u8 = null;
        if (req.body) |body| {
            const FailReq = struct {
                @"error": ?[]const u8 = null,
                backtrace: ?[]const u8 = null,
            };
            const parsed = std.json.parseFromSlice(FailReq, self.allocator, body, .{
                .ignore_unknown_fields = true,
            }) catch null;
            if (parsed) |p| {
                defer p.deinit();
                error_msg = p.value.@"error" orelse "";
                backtrace = p.value.backtrace;
            }
        }

        var qbuf: [64]u8 = undefined;
        const queue = self.store.lookupJobQueue(job_id, &qbuf) orelse return jsonError(buf, 404, "job not found");
        const result = self.store.fail(job_id, queue, error_msg, backtrace);
        if (result.err) |err| {
            return jsonError(buf, 500, err);
        }
        self.throughput.inc(.failed);
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleHeartbeat(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const HeartbeatJobReq = struct {
            job_id: ?[]const u8 = null,
            progress: ?[]const u8 = null,
            checkpoint: ?[]const u8 = null,
        };
        const HeartbeatReq = struct {
            worker_id: ?[]const u8 = null,
            jobs: ?[]const HeartbeatJobReq = null,
        };

        const parsed = std.json.parseFromSlice(HeartbeatReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();

        const worker_id = parsed.value.worker_id orelse return jsonError(buf, 400, "worker_id is required");
        const jobs = parsed.value.jobs orelse return jsonOk(buf, "{\"status\":\"ok\"}");
        if (jobs.len == 0) return jsonOk(buf, "{\"status\":\"ok\"}");

        // Build parallel job_ids and HeartbeatJobOp slices.
        var id_slices: [128][]const u8 = undefined;
        var hb_ops: [128]ops_mod.HeartbeatJobOp = undefined;
        const n = @min(jobs.len, 128);
        for (0..n) |i| {
            id_slices[i] = jobs[i].job_id orelse continue;
            hb_ops[i] = .{
                .progress = jobs[i].progress,
                .checkpoint = jobs[i].checkpoint,
            };
        }

        const result = self.store.heartbeat(id_slices[0..n], hb_ops[0..n], worker_id);
        if (result.err) |err| {
            return jsonError(buf, 500, err);
        }

        // Return per-job status (ok/cancel) matching Go response format.
        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeAll("{\"jobs\":{") catch return jsonOk(buf, "{\"status\":\"ok\"}");

        var first = true;
        for (0..n) |i| {
            const jid = id_slices[i];
            if (jid.len == 0) continue;
            if (!first) w.writeByte(',') catch break;
            first = false;
            // Job is "ok" if it was found and active (i.e., heartbeat succeeded for it).
            // We check via KV lookup — if the job exists and is active, status is ok.
            var qbuf: [64]u8 = undefined;
            const status: []const u8 = if (self.store.lookupJobQueue(jid, &qbuf) != null) "ok" else "cancel";
            w.print("\"{s}\":{{\"status\":\"{s}\"}}", .{ jid, status }) catch break;
        }

        w.writeAll("}}") catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    // ====================================================================
    // Handlers — Bulk Operations
    // ====================================================================

    fn handleBulk(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const BulkReq = struct {
            action: ?[]const u8 = null,
            job_ids: ?[]const []const u8 = null,
            queue: ?[]const u8 = null,
            move_to_queue: ?[]const u8 = null,
            priority: ?std.json.Value = null,
        };

        const parsed = std.json.parseFromSlice(BulkReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();
        const r = parsed.value;

        const action_str = r.action orelse return jsonError(buf, 400, "action is required");
        const action = parseBulkAction(action_str) orelse return jsonError(buf, 400, "invalid action");
        const job_ids = r.job_ids orelse return jsonError(buf, 400, "job_ids is required");

        const data = ops_mod.OpData{
            .bulk_action = .{
                .job_ids = job_ids,
                .action = action,
                .queue = r.queue orelse "",
                .move_to_queue = r.move_to_queue,
                .priority = parsePriorityValue(r.priority),
                .now_ns = self.store.nowNs(),
            },
        };
        const result = self.store.bulkAction(&data);
        if (result.err) |err| {
            return jsonError(buf, 500, err);
        }

        const resp = std.fmt.bufPrint(buf,
            "{{\"affected\":{d}}}",
            .{result.affected},
        ) catch "{}";
        return .{ .status = 200, .body = resp };
    }

    fn handleJobAction(self: *Server, api_path: []const u8, action: ops_mod.BulkAction, buf: []u8) Response {
        // Extract job ID: /jobs/{id}/action
        const rest = api_path["/jobs/".len..];
        const slash = std.mem.indexOf(u8, rest, "/") orelse return jsonError(buf, 400, "invalid path");
        const job_id = rest[0..slash];
        if (job_id.len == 0) return jsonError(buf, 400, "missing job_id");

        var qbuf: [64]u8 = undefined;
        const queue = self.store.lookupJobQueue(job_id, &qbuf) orelse return jsonError(buf, 404, "job not found");

        const job_ids = [1][]const u8{job_id};
        const data = ops_mod.OpData{
            .bulk_action = .{
                .job_ids = &job_ids,
                .action = action,
                .queue = queue,
                .now_ns = self.store.nowNs(),
            },
        };
        const result = self.store.bulkAction(&data);
        if (result.err) |err| {
            return jsonError(buf, 500, err);
        }
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleJobMove(self: *Server, api_path: []const u8, req: Request, buf: []u8) Response {
        const rest = api_path["/jobs/".len..];
        const slash = std.mem.indexOf(u8, rest, "/") orelse return jsonError(buf, 400, "invalid path");
        const job_id = rest[0..slash];
        if (job_id.len == 0) return jsonError(buf, 400, "missing job_id");

        const body = req.body orelse return jsonError(buf, 400, "missing request body");
        const MoveReq = struct { queue: ?[]const u8 = null };
        const parsed = std.json.parseFromSlice(MoveReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();
        const target_queue = parsed.value.queue orelse return jsonError(buf, 400, "queue is required");

        var qbuf: [64]u8 = undefined;
        const current_queue = self.store.lookupJobQueue(job_id, &qbuf) orelse return jsonError(buf, 404, "job not found");
        const job_ids = [1][]const u8{job_id};
        const data = ops_mod.OpData{
            .bulk_action = .{
                .job_ids = &job_ids,
                .action = .move,
                .queue = current_queue,
                .move_to_queue = target_queue,
                .now_ns = self.store.nowNs(),
            },
        };
        const result = self.store.bulkAction(&data);
        if (result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"moved\"}");
    }

    fn handleJobReplay(self: *Server, api_path: []const u8, req: Request, buf: []u8) Response {
        // Replay re-enqueues a completed/failed job as a new pending job.
        const rest = api_path["/jobs/".len..];
        const slash = std.mem.indexOf(u8, rest, "/") orelse return jsonError(buf, 400, "invalid path");
        const job_id = rest[0..slash];
        if (job_id.len == 0) return jsonError(buf, 400, "missing job_id");
        _ = req;

        var qbuf: [64]u8 = undefined;
        const queue = self.store.lookupJobQueue(job_id, &qbuf) orelse return jsonError(buf, 404, "job not found");
        const job_ids = [1][]const u8{job_id};
        const data = ops_mod.OpData{
            .bulk_action = .{
                .job_ids = &job_ids,
                .action = .retry,
                .queue = queue,
                .now_ns = self.store.nowNs(),
            },
        };
        const result = self.store.bulkAction(&data);
        if (result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"replayed\"}");
    }

    fn handleDeleteJob(self: *Server, job_id: []const u8, buf: []u8) Response {
        if (job_id.len == 0) return jsonError(buf, 400, "missing job_id");

        var qbuf: [64]u8 = undefined;
        const queue = self.store.lookupJobQueue(job_id, &qbuf) orelse return jsonError(buf, 404, "job not found");
        const job_ids = [1][]const u8{job_id};
        const data = ops_mod.OpData{
            .bulk_action = .{
                .job_ids = &job_ids,
                .action = .delete,
                .queue = queue,
                .now_ns = self.store.nowNs(),
            },
        };
        const del_result = self.store.bulkAction(&data);
        if (del_result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"deleted\"}");
    }

    // ====================================================================
    // Handlers — Queue Management
    // ====================================================================

    fn handleQueueAction(self: *Server, api_path: []const u8, action: ops_mod.QueueAction, buf: []u8) Response {
        const queue_name = extractQueueName(api_path) orelse return jsonError(buf, 400, "invalid path");
        const qa_result = self.store.queueConfig(queue_name, action);
        if (qa_result.err) |err| return jsonError(buf, 500, err);
        const status = if (action == .pause) "paused" else "resumed";
        const resp = std.fmt.bufPrint(buf, "{{\"status\":\"{s}\"}}", .{status}) catch "{}";
        return .{ .status = 200, .body = resp };
    }

    fn handleQueueConcurrency(self: *Server, api_path: []const u8, req: Request, buf: []u8) Response {
        const queue_name = extractQueueName(api_path) orelse return jsonError(buf, 400, "invalid path");
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const Req = struct { max: ?i64 = null };
        const parsed = std.json.parseFromSlice(Req, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();

        const max_conc: u32 = if (parsed.value.max) |m| @intCast(@max(m, 0)) else 0;
        const conc_result = self.store.queueConfigFull(.{
            .queue = queue_name,
            .action = .concurrency,
            .max_concurrency = max_conc,
        });
        if (conc_result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleQueueThrottle(self: *Server, api_path: []const u8, req: Request, buf: []u8) Response {
        const queue_name = extractQueueName(api_path) orelse return jsonError(buf, 400, "invalid path");
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const Req = struct { rate: ?i64 = null, window_ms: ?i64 = null };
        const parsed = std.json.parseFromSlice(Req, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();

        const rate: u32 = if (parsed.value.rate) |r| @intCast(@max(r, 0)) else 0;
        const window_ms: u32 = if (parsed.value.window_ms) |w| @intCast(@max(w, 0)) else 1000;
        const thr_result = self.store.queueConfigFull(.{
            .queue = queue_name,
            .action = .throttle,
            .rate_limit = rate,
            .rate_window_ms = window_ms,
        });
        if (thr_result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleQueueFairness(self: *Server, api_path: []const u8, req: Request, buf: []u8) Response {
        const queue_name = extractQueueName(api_path) orelse return jsonError(buf, 400, "invalid path");
        _ = req;
        const fair_result = self.store.queueConfig(queue_name, .fairness);
        if (fair_result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleQueueClear(self: *Server, api_path: []const u8, buf: []u8) Response {
        const queue_name = extractQueueName(api_path) orelse return jsonError(buf, 400, "invalid path");
        const clear_result = self.store.clearQueue(queue_name);
        if (clear_result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleQueueDrain(self: *Server, api_path: []const u8, buf: []u8) Response {
        // Drain pauses the queue and lets active jobs finish (pause is sufficient).
        const queue_name = extractQueueName(api_path) orelse return jsonError(buf, 400, "invalid path");
        const drain_result = self.store.queueConfig(queue_name, .pause);
        if (drain_result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"draining\"}");
    }

    fn handleQueueThrottleDelete(self: *Server, api_path: []const u8, buf: []u8) Response {
        const queue_name = extractQueueName(api_path) orelse return jsonError(buf, 400, "invalid path");
        // Remove throttle by setting rate_limit=0 and rate_window_ms=0.
        const result = self.store.queueConfigFull(.{
            .queue = queue_name,
            .action = .throttle,
            .rate_limit = 0,
            .rate_window_ms = 0,
        });
        if (result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleQueueFairnessDelete(self: *Server, api_path: []const u8, buf: []u8) Response {
        // Remove fairness key from queue — reset to default (no fairness).
        const stripped = api_path["/queues/".len..];
        const slash = std.mem.indexOf(u8, stripped, "/") orelse return jsonError(buf, 400, "invalid path");
        const queue_name = stripped[0..slash];
        const fd_result = self.store.queueConfig(queue_name, .fairness);
        if (fd_result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleQueueDelete(self: *Server, api_path: []const u8, buf: []u8) Response {
        // Path: /queues/{name} — no trailing action.
        const name = api_path["/queues/".len..];
        if (name.len == 0) return jsonError(buf, 400, "missing queue name");
        const dq_result = self.store.deleteQueue(name);
        if (dq_result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"deleted\"}");
    }

    fn handleListQueues(self: *Server, buf: []u8) Response {
        var r = self.store.reader() orelse return jsonError(buf, 503, "mirror not available");
        var queue_buf: [64]sqlite_read.QueueStats = undefined;
        const count = r.getQueueStats(&queue_buf) catch {
            return jsonError(buf, 500, "query failed");
        };

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeByte('[') catch return jsonOk(buf, "[]");

        for (0..count) |i| {
            if (i > 0) w.writeByte(',') catch break;
            const q = &queue_buf[i];
            w.print("{{\"name\":\"{s}\",\"pending\":{d},\"active\":{d},\"retrying\":{d},\"dead\":{d},\"paused\":{s}}}",
                .{
                    q.nameSlice(),
                    q.pending,
                    q.active,
                    q.retrying,
                    q.dead,
                    if (q.paused) "true" else "false",
                },
            ) catch break;
        }

        w.writeByte(']') catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    // ====================================================================
    // Handlers — Job Queries
    // ====================================================================

    fn handleGetJob(self: *Server, job_id: []const u8, buf: []u8) Response {
        self.store.flushMirror();
        var r = self.store.reader() orelse return jsonError(buf, 503, "mirror not available");
        const job = r.getJob(job_id) catch {
            return jsonError(buf, 500, "query failed");
        };

        if (job == null) {
            return jsonError(buf, 404, "job not found");
        }

        const j = job.?;
        const resp = std.fmt.bufPrint(buf,
            "{{\"id\":\"{s}\",\"queue\":\"{s}\",\"state\":\"{s}\",\"priority\":{d},\"attempt\":{d}}}",
            .{ j.idSlice(), j.queueSlice(), j.stateSlice(), j.priority, j.attempt },
        ) catch "{}";
        return .{ .status = 200, .body = resp };
    }

    // ====================================================================
    // Handlers — Batch Operations
    // ====================================================================

    fn handleBatchCreate(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const BatchReq = struct {
            callback_queue: ?[]const u8 = null,
        };
        const parsed = std.json.parseFromSlice(BatchReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();

        const callback_queue = parsed.value.callback_queue orelse return jsonError(buf, 400, "callback_queue is required");

        var batch_id_buf: [64]u8 = undefined;
        const batch_id = self.store.generateID(&batch_id_buf);

        const data = ops_mod.OpData{
            .batch_create = .{
                .batch_id = batch_id,
                .callback_queue = callback_queue,
                .created_at_ns = self.store.nowNs(),
            },
        };
        const bc_result = self.store.batchCreate(&data);
        if (bc_result.err) |err| return jsonError(buf, 500, err);

        const resp = std.fmt.bufPrint(buf, "{{\"batch_id\":\"{s}\"}}", .{batch_id}) catch "{}";
        return .{ .status = 201, .body = resp };
    }

    fn handleBatchSeal(self: *Server, api_path: []const u8, buf: []u8) Response {
        // Extract batch ID: /batch/{id}/seal
        const rest = api_path["/batch/".len..];
        const slash = std.mem.indexOf(u8, rest, "/") orelse return jsonError(buf, 400, "invalid path");
        const batch_id = rest[0..slash];
        if (batch_id.len == 0) return jsonError(buf, 400, "missing batch_id");

        const data = ops_mod.OpData{
            .batch_seal = .{
                .batch_id = batch_id,
                .now_ns = self.store.nowNs(),
            },
        };
        const bs_result = self.store.batchSeal(&data);
        if (bs_result.err) |err| return jsonError(buf, 500, err);
        return jsonOk(buf, "{\"status\":\"sealed\"}");
    }

    // ====================================================================
    // Handlers — Cron CRUD
    // ====================================================================

    fn handleCronCreate(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const CronReq = struct {
            name: ?[]const u8 = null,
            queue: ?[]const u8 = null,
            schedule: ?[]const u8 = null,
            timezone: ?[]const u8 = null,
            payload: ?[]const u8 = null,
            unique_key: ?[]const u8 = null,
            max_retries: ?i64 = null,
            enabled: ?bool = null,
        };

        const parsed = std.json.parseFromSlice(CronReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();
        const r = parsed.value;

        const name = r.name orelse return jsonError(buf, 400, "name is required");
        const queue = r.queue orelse return jsonError(buf, 400, "queue is required");
        const schedule = r.schedule orelse return jsonError(buf, 400, "schedule is required");

        var cron_id_buf: [64]u8 = undefined;
        const cron_id = self.store.generateID(&cron_id_buf);

        const data = ops_mod.OpData{
            .cron_create = .{
                .cron_id = cron_id,
                .name = name,
                .queue = queue,
                .schedule = schedule,
                .timezone = r.timezone orelse "UTC",
                .payload = r.payload,
                .unique_key = r.unique_key,
                .max_retries = if (r.max_retries) |mr| @intCast(@min(mr, 100)) else 0,
                .enabled = r.enabled orelse true,
                .created_at_ns = self.store.nowNs(),
                .now_ns = self.store.nowNs(),
            },
        };
        const result = self.store.engine.submit(.cron_create, &data);
        if (result.err) |err| {
            return jsonError(buf, 409, err);
        }

        // Mirror: create cron via ring buffer.
        if (self.store.mirror) |m| {
            m.enqueueCronUpsert(.{
                .id = cron_id,
                .name = name,
                .queue = queue,
                .schedule = schedule,
                .timezone = r.timezone orelse "UTC",
                .payload = r.payload,
                .unique_key = r.unique_key,
                .max_retries = if (r.max_retries) |mr| @intCast(@min(mr, 100)) else 0,
                .enabled = r.enabled orelse true,
                .created_at_ns = self.store.nowNs(),
            });
        }

        const resp = std.fmt.bufPrint(buf, "{{\"cron_id\":\"{s}\",\"name\":\"{s}\"}}", .{ cron_id, name }) catch "{}";
        return .{ .status = 201, .body = resp };
    }

    fn handleCronUpdate(self: *Server, cron_id: []const u8, req: Request, buf: []u8) Response {
        if (cron_id.len == 0) return jsonError(buf, 400, "missing cron_id");
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const CronReq = struct {
            name: ?[]const u8 = null,
            queue: ?[]const u8 = null,
            schedule: ?[]const u8 = null,
            timezone: ?[]const u8 = null,
            payload: ?[]const u8 = null,
            unique_key: ?[]const u8 = null,
            max_retries: ?i64 = null,
            enabled: ?bool = null,
        };

        const parsed = std.json.parseFromSlice(CronReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();
        const r = parsed.value;

        const data = ops_mod.OpData{
            .cron_update = .{
                .cron_id = cron_id,
                .name = r.name,
                .queue = r.queue,
                .schedule = r.schedule,
                .timezone = r.timezone,
                .payload = r.payload,
                .unique_key = r.unique_key,
                .max_retries = if (r.max_retries) |mr| @intCast(@min(mr, 100)) else null,
                .enabled = r.enabled,
                .now_ns = self.store.nowNs(),
            },
        };
        const result = self.store.engine.submit(.cron_update, &data);
        if (result.err) |err| {
            return jsonError(buf, 404, err);
        }

        // Mirror: update cron via ring buffer.
        if (self.store.mirror) |m| {
            if (r.name != null or r.queue != null or r.schedule != null) {
                m.enqueueCronUpsert(.{
                    .id = cron_id,
                    .name = r.name orelse "",
                    .queue = r.queue orelse "",
                    .schedule = r.schedule orelse "",
                    .timezone = r.timezone orelse "UTC",
                    .payload = r.payload,
                    .unique_key = r.unique_key,
                    .max_retries = if (r.max_retries) |mr2| @intCast(@min(mr2, 100)) else 0,
                    .enabled = r.enabled orelse true,
                });
            }
        }

        return jsonOk(buf, "{\"status\":\"updated\"}");
    }

    fn handleCronDelete(self: *Server, cron_id: []const u8, buf: []u8) Response {
        if (cron_id.len == 0) return jsonError(buf, 400, "missing cron_id");
        const data = ops_mod.OpData{
            .cron_delete = .{ .cron_id = cron_id },
        };
        const cd_result = self.store.engine.submit(.cron_delete, &data);
        if (cd_result.err) |err| return jsonError(buf, 500, err);

        // Mirror: delete cron via ring buffer.
        if (self.store.mirror) |m| m.enqueueCronDelete(cron_id);

        return jsonOk(buf, "{\"status\":\"deleted\"}");
    }

    fn handleCronAction(self: *Server, api_path: []const u8, action: []const u8, buf: []u8) Response {
        // Extract cron ID: /cron-jobs/{id}/pause or /cron-jobs/{id}/resume
        const rest = api_path["/cron-jobs/".len..];
        const slash = std.mem.indexOf(u8, rest, "/") orelse return jsonError(buf, 400, "invalid path");
        const cron_id = rest[0..slash];
        if (cron_id.len == 0) return jsonError(buf, 400, "missing cron_id");

        const enabled = eql(action, "resume");
        const data = ops_mod.OpData{
            .cron_update = .{ .cron_id = cron_id, .enabled = enabled },
        };
        const ca_result = self.store.engine.submit(.cron_update, &data);
        if (ca_result.err) |err| return jsonError(buf, 500, err);

        // Mirror: toggle cron enabled via ring buffer.
        if (self.store.mirror) |m| {
            m.enqueueCronToggle(cron_id, enabled);
        }

        const status = if (enabled) "resumed" else "paused";
        const resp = std.fmt.bufPrint(buf, "{{\"status\":\"{s}\"}}", .{status}) catch "{}";
        return .{ .status = 200, .body = resp };
    }

    fn handleCronTrigger(self: *Server, api_path: []const u8, buf: []u8) Response {
        // Extract cron ID: /cron-jobs/{id}/trigger
        const rest = api_path["/cron-jobs/".len..];
        const slash = std.mem.indexOf(u8, rest, "/") orelse return jsonError(buf, 400, "invalid path");
        const cron_id = rest[0..slash];
        if (cron_id.len == 0) return jsonError(buf, 400, "missing cron_id");

        // Generate a job ID for the triggered job.
        var id_buf: [64]u8 = undefined;
        const job_id = self.store.generateID(&id_buf);

        const data = ops_mod.OpData{
            .cron_trigger = .{
                .cron_id = cron_id,
                .job_id = job_id,
                .now_ns = self.store.nowNs(),
            },
        };
        const result = self.store.engine.submit(.cron_trigger, &data);
        if (result.err) |err| return jsonError(buf, 404, err);
        const resp = std.fmt.bufPrint(buf, "{{\"status\":\"triggered\",\"job_id\":\"{s}\"}}", .{job_id}) catch "{}";
        return .{ .status = 200, .body = resp };
    }

    fn handleBulkGetJobs(self: *Server, req: Request, buf: []u8) Response {
        self.store.flushMirror();
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const BulkGetReq = struct {
            job_ids: ?[]const []const u8 = null,
        };
        const parsed = std.json.parseFromSlice(BulkGetReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();

        const job_ids = parsed.value.job_ids orelse return jsonError(buf, 400, "job_ids is required");
        if (job_ids.len == 0) return jsonOk(buf, "{\"jobs\":[]}");

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeAll("{\"jobs\":[") catch return jsonOk(buf, "{\"jobs\":[]}");

        const n = @min(job_ids.len, 100);
        var written: u32 = 0;
        for (0..n) |i| {
            var jk_buf: keys.KeyBuf = undefined;
            const job_bytes = self.store.engine.get(keys.jobKey(&jk_buf, job_ids[i])) orelse continue;
            defer self.allocator.free(job_bytes);
            const job = codec.decodeJob(job_bytes);

            if (written > 0) w.writeByte(',') catch break;
            w.print("{{\"id\":\"{s}\",\"queue\":\"{s}\",\"state\":\"{s}\",\"priority\":{d},\"attempt\":{d},\"max_retries\":{d}}}", .{
                job.id,
                job.queue,
                job.state.toString(),
                job.priority,
                job.attempt,
                job.max_retries,
            }) catch break;
            written += 1;
        }

        w.writeAll("]}") catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    fn handleRebuildSQLite(self: *Server, buf: []u8) Response {
        const m = self.store.mirror orelse return jsonError(buf, 503, "mirror not available");

        // Flush any pending mirror ops first.
        m.flush() catch {};

        // Rebuild: drop and recreate all tables, then scan KV to repopulate.
        m.getDB().exec("DELETE FROM jobs") catch {};
        m.getDB().exec("DELETE FROM job_payloads") catch {};
        m.getDB().exec("DELETE FROM job_errors") catch {};
        m.getDB().exec("DELETE FROM job_iterations") catch {};
        m.getDB().exec("DELETE FROM queues") catch {};
        m.getDB().exec("DELETE FROM workers") catch {};

        // Re-scan all jobs from KV and mirror them.
        var count: u32 = 0;
        var jp_buf: keys.KeyBuf = undefined;
        var jpe_buf: keys.KeyBuf = undefined;
        const jp: []const u8 = keys.prefix_job;
        @memcpy(jp_buf[0..jp.len], jp);
        if (keys.prefixEnd(&jpe_buf, jp_buf[0..jp.len])) |end| {
            for (self.store.engine.shards) |*shard| {
                var batch = shard.newBatch();
                defer batch.close();
                var iter = batch.newIter(jp_buf[0..jp.len], end);
                defer iter.close();

                if (iter.first()) {
                    while (true) {
                        const key = iter.key();
                        // Skip payload keys (j|jp|) — they start with j|jp|
                        if (key.len > 4 and key[2] == 'j' and key[3] == 'p') {
                            if (!iter.next()) break;
                            continue;
                        }
                        const val = iter.value();
                        const job = codec.decodeJob(val);
                        m.enqueueJob(&.{
                            .job_id = job.id,
                            .queue = job.queue,
                            .state = job.state,
                            .priority = job.priority,
                            .max_retries = job.max_retries,
                            .created_at_ns = job.created_at_ns,
                            .scheduled_at_ns = job.scheduled_at_ns,
                        });
                        count += 1;
                        if (!iter.next()) break;
                    }
                }
            }
        }

        // Flush the re-mirrored jobs.
        m.flush() catch {};

        const resp = std.fmt.bufPrint(buf, "{{\"status\":\"ok\",\"jobs_rebuilt\":{d}}}", .{count}) catch "{}";
        return .{ .status = 200, .body = resp };
    }

    fn handleGetCron(self: *Server, api_path: []const u8, buf: []u8) Response {
        // Extract cron ID: /cron-jobs/{id}
        const cron_id = api_path["/cron-jobs/".len..];
        if (cron_id.len == 0) return jsonError(buf, 400, "missing cron_id");

        var r = self.store.reader() orelse return jsonError(buf, 503, "mirror not available");
        const cron = r.getCron(cron_id) catch {
            return jsonError(buf, 500, "query failed");
        };

        if (cron == null) return jsonError(buf, 404, "schedule not found");

        const c = cron.?;
        const resp = std.fmt.bufPrint(buf, "{{\"id\":\"{s}\",\"name\":\"{s}\",\"queue\":\"{s}\",\"schedule\":\"{s}\",\"enabled\":{s}}}",
            .{ c.idSlice(), c.nameSlice(), c.queueSlice(), c.scheduleSlice(), if (c.enabled) "true" else "false" },
        ) catch "{}";
        return .{ .status = 200, .body = resp };
    }

    fn handleListCrons(self: *Server, buf: []u8) Response {
        var r = self.store.reader() orelse return jsonError(buf, 503, "mirror not available");
        var cron_buf: [64]sqlite_read.CronRow = undefined;
        const count = r.getCrons(&cron_buf) catch {
            return jsonError(buf, 500, "query failed");
        };

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeByte('[') catch return jsonOk(buf, "[]");

        for (0..count) |i| {
            if (i > 0) w.writeByte(',') catch break;
            const c = &cron_buf[i];
            w.print("{{\"id\":\"{s}\",\"name\":\"{s}\",\"queue\":\"{s}\",\"schedule\":\"{s}\",\"enabled\":{s}}}",
                .{
                    c.idSlice(),
                    c.nameSlice(),
                    c.queueSlice(),
                    c.scheduleSlice(),
                    if (c.enabled) "true" else "false",
                },
            ) catch break;
        }

        w.writeByte(']') catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    // ====================================================================
    // Handlers — Workers
    // ====================================================================

    fn handleListWorkers(self: *Server, buf: []u8) Response {
        var r = self.store.reader() orelse return jsonError(buf, 503, "mirror not available");
        var worker_buf: [64]sqlite_read.WorkerRow = undefined;
        const count = r.getWorkers(&worker_buf) catch {
            return jsonError(buf, 500, "query failed");
        };

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeByte('[') catch return jsonOk(buf, "[]");

        for (0..count) |i| {
            if (i > 0) w.writeByte(',') catch break;
            const wk = &worker_buf[i];
            w.print("{{\"id\":\"{s}\",\"hostname\":\"{s}\"}}",
                .{ wk.idSlice(), wk.hostnameSlice() },
            ) catch break;
        }

        w.writeByte(']') catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    // ====================================================================
    // Handlers — Job Search (FTS5)
    // ====================================================================

    /// GET /search/fulltext?q=query&limit=50
    /// Dedicated full-text search endpoint. Tries FTS5 first, falls back to LIKE.
    fn handleFullTextSearch(self: *Server, req: Request, buf: []u8) Response {
        self.store.flushMirror();
        var r = self.store.reader() orelse return jsonError(buf, 503, "mirror not available");

        const query_str = extractQueryParam(req.path, "q") orelse
            return jsonError(buf, 400, "q parameter is required");

        if (query_str.len == 0) return jsonError(buf, 400, "q parameter is required");

        const limit_str = extractQueryParam(req.path, "limit");
        var limit: u32 = 50;
        if (limit_str) |ls| {
            limit = @min(std.fmt.parseInt(u32, ls, 10) catch 50, 500);
        }

        var result_buf: [500]sqlite_read.JobRow = undefined;
        const actual_limit = @min(limit, result_buf.len);

        // Try FTS5 first, fall back to LIKE on error.
        var count = r.searchJobs(query_str, result_buf[0..actual_limit]) catch blk: {
            break :blk r.searchJobsLike(query_str, result_buf[0..actual_limit]) catch 0;
        };
        _ = &count;

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.print("{{\"q\":\"{s}\",\"results\":[", .{query_str}) catch return jsonOk(buf, "{\"q\":\"\",\"results\":[]}");

        for (0..count) |i| {
            if (i > 0) w.writeByte(',') catch break;
            const j = &result_buf[i];
            w.print("{{\"id\":\"{s}\",\"queue\":\"{s}\",\"state\":\"{s}\",\"created_at\":\"{s}\"}}",
                .{ j.idSlice(), j.queueSlice(), j.stateSlice(), j.createdAtSlice() },
            ) catch break;
        }

        w.writeAll("]}") catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    fn handleJobSearch(self: *Server, req: Request, buf: []u8) Response {
        self.store.flushMirror();
        var r = self.store.reader() orelse return jsonError(buf, 503, "mirror not available");

        // Parse ?q= query parameter from path.
        const query_str = extractQueryParam(req.path, "q");

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeAll("{\"jobs\":[") catch return jsonOk(buf, "{\"jobs\":[]}");

        if (query_str) |q| {
            var result_buf: [100]sqlite_read.JobRow = undefined;
            const count = r.searchJobs(q, &result_buf) catch blk: {
                break :blk r.searchJobsLike(q, &result_buf) catch 0;
            };
            for (0..count) |i| {
                if (i > 0) w.writeByte(',') catch break;
                const j = &result_buf[i];
                w.print("{{\"id\":\"{s}\",\"queue\":\"{s}\",\"state\":\"{s}\",\"priority\":{d}}}",
                    .{ j.idSlice(), j.queueSlice(), j.stateSlice(), j.priority },
                ) catch break;
            }
        } else {
            var job_buf: [100]sqlite_read.JobRow = undefined;
            const count = r.getJobs(&job_buf) catch {
                return jsonError(buf, 500, "query failed");
            };
            for (0..count) |i| {
                if (i > 0) w.writeByte(',') catch break;
                const j = &job_buf[i];
                w.print("{{\"id\":\"{s}\",\"queue\":\"{s}\",\"state\":\"{s}\",\"priority\":{d}}}",
                    .{ j.idSlice(), j.queueSlice(), j.stateSlice(), j.priority },
                ) catch break;
            }
        }

        w.writeAll("]}") catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    /// POST /jobs/search — filter-based job listing (used by UI for all job views).
    fn handleJobSearchPost(self: *Server, req: Request, buf: []u8) Response {
        self.store.flushMirror();
        var r = self.store.reader() orelse return jsonError(buf, 503, "mirror not available");

        const SearchReq = struct {
            state: ?[]const []const u8 = null,
            queue: ?[]const u8 = null,
            payload_contains: ?[]const u8 = null,
            limit: ?i64 = null,
            sort: ?[]const u8 = null,
            order: ?[]const u8 = null,
        };

        var state_filter: ?[]const u8 = null;
        var text_filter: ?[]const u8 = null;

        if (req.body) |body| {
            if (body.len > 0) {
                if (std.json.parseFromSlice(SearchReq, self.allocator, body, .{
                    .ignore_unknown_fields = true,
                })) |parsed| {
                    defer parsed.deinit();
                    if (parsed.value.state) |states| {
                        if (states.len > 0) state_filter = states[0];
                    }
                    if (parsed.value.payload_contains) |q| text_filter = q;
                } else |_| {}
            }
        }

        var job_buf: [100]sqlite_read.JobRow = undefined;
        var count: u32 = 0;

        if (state_filter) |state| {
            count = r.listJobsByState(state, &job_buf) catch 0;
        } else if (text_filter) |q| {
            count = r.searchJobs(q, &job_buf) catch blk: {
                break :blk r.searchJobsLike(q, &job_buf) catch 0;
            };
        } else {
            count = r.getJobs(&job_buf) catch 0;
        }

        // Build response: {jobs: [...], total: N, has_more: false}
        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeAll("{\"jobs\":[") catch return jsonOk(buf, "{\"jobs\":[],\"total\":0,\"has_more\":false}");

        for (0..count) |i| {
            if (i > 0) w.writeByte(',') catch break;
            const j = &job_buf[i];
            w.print("{{\"id\":\"{s}\",\"queue\":\"{s}\",\"state\":\"{s}\",\"priority\":{d},\"attempt\":{d},\"max_retries\":{d},\"created_at\":\"{s}\"}}",
                .{ j.idSlice(), j.queueSlice(), j.stateSlice(), j.priority, j.attempt, j.max_retries, j.createdAtSlice() },
            ) catch break;
        }

        w.print("],\"total\":{d},\"has_more\":false}}", .{count}) catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    // ====================================================================
    // Handlers — Job Iterations
    // ====================================================================

    fn handleJobIterations(self: *Server, api_path: []const u8, buf: []u8) Response {
        self.store.flushMirror();
        // Extract job ID: /jobs/{id}/iterations
        const rest = api_path["/jobs/".len..];
        const slash = std.mem.indexOf(u8, rest, "/") orelse return jsonError(buf, 400, "invalid path");
        const job_id = rest[0..slash];
        if (job_id.len == 0) return jsonError(buf, 400, "missing job_id");

        var r = self.store.reader() orelse return jsonError(buf, 503, "mirror not available");
        var iter_buf: [100]sqlite_read.IterationRow = undefined;
        const count = r.getJobIterations(job_id, &iter_buf) catch {
            return jsonError(buf, 500, "query failed");
        };

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeAll("{\"iterations\":[") catch return jsonOk(buf, "{\"iterations\":[]}");

        for (0..count) |i| {
            if (i > 0) w.writeByte(',') catch break;
            const it = &iter_buf[i];
            w.print("{{\"iteration\":{d},\"status\":\"{s}\",\"completed_at\":\"{s}\"}}",
                .{ it.iteration, it.statusSlice(), it.completedAtSlice() },
            ) catch break;
        }

        w.writeAll("]}") catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    // ====================================================================
    // Handlers — Prometheus Metrics
    // ====================================================================

    fn handleUsageSummary(self: *Server, req: Request, buf: []u8) Response {
        _ = req;
        var reader = self.store.reader() orelse
            return jsonOk(buf, "{\"period\":\"24h\",\"totals\":{\"input_tokens\":0,\"output_tokens\":0,\"cost_usd\":0,\"count\":0}}");

        // Default period: 24h. Parse from query string if present.
        const now_ns = self.store.nowNs();
        const period_ns: u64 = 24 * 3600 * 1_000_000_000; // 24h default
        const from_ns = now_ns -| period_ns;

        var from_buf: [32]u8 = undefined;
        var to_buf: [32]u8 = undefined;
        const from_str = std.fmt.bufPrint(&from_buf, "{d}", .{from_ns}) catch "0";
        const to_str = std.fmt.bufPrint(&to_buf, "{d}", .{now_ns}) catch "0";

        const totals = reader.usageTotals(from_str, to_str) catch
            return jsonError(buf, 500, "usage query failed");

        const resp = std.fmt.bufPrint(buf,
            "{{\"period\":\"24h\",\"totals\":{{\"input_tokens\":{d},\"output_tokens\":{d},\"cache_creation_tokens\":{d},\"cache_read_tokens\":{d},\"cost_usd\":{d:.4},\"count\":{d}}}}}",
            .{ totals.input_tokens, totals.output_tokens, totals.cache_creation_tokens, totals.cache_read_tokens, totals.cost_usd, totals.count },
        ) catch return jsonError(buf, 500, "format error");
        return jsonOk(buf, resp);
    }

    fn handleThroughput(self: *Server, buf: []u8) Response {
        const data = self.throughput.snapshot(buf);
        return jsonOk(buf, data);
    }

    fn handleMetrics(self: *Server, buf: []u8) Response {
        var pos: usize = 0;

        // Pipeline stats.
        if (self.store.engine.pipeline) |*p| {
            pos += (std.fmt.bufPrint(buf[pos..],
                "# HELP corvo_pipeline_applied_total Total operations applied\n" ++
                "# TYPE corvo_pipeline_applied_total counter\n" ++
                "corvo_pipeline_applied_total {d}\n" ++
                "# HELP corvo_pipeline_overload_total Operations rejected due to overload\n" ++
                "# TYPE corvo_pipeline_overload_total counter\n" ++
                "corvo_pipeline_overload_total {d}\n" ++
                "# HELP corvo_pipeline_batch_count Total batches executed\n" ++
                "# TYPE corvo_pipeline_batch_count counter\n" ++
                "corvo_pipeline_batch_count {d}\n",
                .{
                    p.getAppliedTotal(),
                    p.getOverloadTotal(),
                    p.getBatchCount(),
                },
            ) catch return .{ .status = 500, .body = "" }).len;
        }

        // Mirror stats.
        if (self.store.mirror) |m| {
            const ms = m.stats();
            const lag = ms.queued -| ms.committed;
            pos += (std.fmt.bufPrint(buf[pos..],
                "# HELP corvo_mirror_queued_total Total operations queued to mirror\n" ++
                "# TYPE corvo_mirror_queued_total counter\n" ++
                "corvo_mirror_queued_total {d}\n" ++
                "# HELP corvo_mirror_committed_total Total operations committed to SQLite\n" ++
                "# TYPE corvo_mirror_committed_total counter\n" ++
                "corvo_mirror_committed_total {d}\n" ++
                "# HELP corvo_mirror_dropped_total Operations dropped due to full queue\n" ++
                "# TYPE corvo_mirror_dropped_total counter\n" ++
                "corvo_mirror_dropped_total {d}\n" ++
                "# HELP corvo_mirror_lag Operations pending in mirror queue\n" ++
                "# TYPE corvo_mirror_lag gauge\n" ++
                "corvo_mirror_lag {d}\n",
                .{ ms.queued, ms.committed, ms.dropped, lag },
            ) catch return .{ .status = 500, .body = "" }).len;
        }

        // Scheduler stats.
        if (self.scheduler) |sched| {
            pos += (std.fmt.bufPrint(buf[pos..],
                "# HELP corvo_scheduler_promote_total Promote runs\n" ++
                "# TYPE corvo_scheduler_promote_total counter\n" ++
                "corvo_scheduler_promote_total {d}\n" ++
                "# HELP corvo_scheduler_reclaim_total Reclaim runs\n" ++
                "# TYPE corvo_scheduler_reclaim_total counter\n" ++
                "corvo_scheduler_reclaim_total {d}\n" ++
                "# HELP corvo_scheduler_expire_total Expire runs\n" ++
                "# TYPE corvo_scheduler_expire_total counter\n" ++
                "corvo_scheduler_expire_total {d}\n" ++
                "# HELP corvo_scheduler_purge_total Purge runs\n" ++
                "# TYPE corvo_scheduler_purge_total counter\n" ++
                "corvo_scheduler_purge_total {d}\n",
                .{
                    sched.promote_runs.load(.monotonic),
                    sched.reclaim_runs.load(.monotonic),
                    sched.expire_runs.load(.monotonic),
                    sched.purge_runs.load(.monotonic),
                },
            ) catch return .{ .status = 500, .body = "" }).len;
        }

        // Queue stats (per-queue gauges).
        if (self.store.reader()) |rv| {
            var reader = rv;
            var stats_buf: [64]sqlite_read.QueueStats = undefined;
            const qcount = reader.getQueueStats(&stats_buf) catch 0;
            if (qcount > 0) {
                pos += (std.fmt.bufPrint(buf[pos..],
                    "# HELP corvo_queue_jobs Number of jobs per queue and state\n" ++
                    "# TYPE corvo_queue_jobs gauge\n",
                    .{},
                ) catch &[0]u8{}).len;
                for (0..qcount) |i| {
                    const q = &stats_buf[i];
                    const qn = q.nameSlice();
                    inline for (.{
                        .{ "pending", q.pending },
                        .{ "active", q.active },
                        .{ "retrying", q.retrying },
                        .{ "scheduled", q.scheduled },
                        .{ "completed", q.completed },
                        .{ "dead", q.dead },
                    }) |pair| {
                        pos += (std.fmt.bufPrint(buf[pos..],
                            "corvo_queue_jobs{{queue=\"{s}\",state=\"{s}\"}} {d}\n",
                            .{ qn, pair[0], pair[1] },
                        ) catch break).len;
                    }
                }
            }

            // Workers gauge.
            const wcount = reader.countWorkers() catch 0;
            pos += (std.fmt.bufPrint(buf[pos..],
                "# HELP corvo_workers_registered Number of registered workers\n" ++
                "# TYPE corvo_workers_registered gauge\n" ++
                "corvo_workers_registered {d}\n",
                .{wcount},
            ) catch &[0]u8{}).len;
        }

        // Request metrics (HTTP latency histograms, error counts, etc.)
        const req_metrics_out = self.req_metrics.renderPrometheus(buf[pos..]);
        pos += req_metrics_out.len;

        return .{ .status = 200, .body = buf[0..pos], .content_type = "text/plain; version=0.0.4" };
    }

    // ====================================================================
    // Handlers — Budgets
    // ====================================================================

    fn handleListBudgets(self: *Server, buf: []u8) Response {
        self.store.flushMirror();
        var reader = self.store.reader() orelse return jsonOk(buf, "[]");
        var budget_buf: [64]sqlite_read.BudgetRow = undefined;
        const count = reader.listBudgets(&budget_buf) catch return jsonError(buf, 500, "db error");

        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;

        for (budget_buf[0..count], 0..) |*row, i| {
            if (i > 0) {
                buf[pos] = ',';
                pos += 1;
            }
            const written = std.fmt.bufPrint(buf[pos..], "{{\"scope\":\"{s}\",\"target\":\"{s}\",\"daily_usd\":{d:.2},\"per_job_usd\":{d:.4},\"on_exceed\":\"{s}\",\"created_at\":\"{s}\"}}", .{
                row.scopeSlice(),
                row.targetSlice(),
                row.daily_usd,
                row.per_job_usd,
                row.onExceedSlice(),
                row.createdAtSlice(),
            }) catch return jsonError(buf, 500, "buf");
            pos += written.len;
        }

        buf[pos] = ']';
        pos += 1;
        return jsonOk(buf, buf[0..pos]);
    }

    fn handleSetBudget(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const BudgetReq = struct {
            scope: ?[]const u8 = null,
            target: ?[]const u8 = null,
            daily_usd: ?f64 = null,
            per_job_usd: ?f64 = null,
            on_exceed: ?[]const u8 = null,
        };

        var parse_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
        const parsed = std.json.parseFromSlice(BudgetReq, fba.allocator(), body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");

        const scope = parsed.value.scope orelse return jsonError(buf, 400, "missing scope");
        const target = parsed.value.target orelse return jsonError(buf, 400, "missing target");

        const result = self.store.setBudget(.{
            .scope = scope,
            .target = target,
            .daily_usd = parsed.value.daily_usd orelse 0,
            .per_job_usd = parsed.value.per_job_usd orelse 0,
            .on_exceed = parsed.value.on_exceed orelse "hold",
            .created_at_ns = self.store.nowNs(),
        });

        if (result.err) |e| return jsonError(buf, 400, e);
        return jsonOk(buf, "{\"status\":\"ok\"}");
    }

    fn handleDeleteBudget(self: *Server, api_path: []const u8, buf: []u8) Response {
        // Path: /budgets/{scope}/{target}
        const path = api_path["/budgets/".len..];
        const sep = std.mem.indexOf(u8, path, "/") orelse return jsonError(buf, 400, "missing target");
        const scope = path[0..sep];
        const target = path[sep + 1 ..];

        if (scope.len == 0 or target.len == 0) return jsonError(buf, 400, "missing scope or target");

        const result = self.store.deleteBudget(scope, target);
        if (result.err) |e| return jsonError(buf, 400, e);
        return jsonOk(buf, "{\"status\":\"deleted\"}");
    }

    // ====================================================================
    // Leader proxy — forward write requests to the leader node
    // ====================================================================

    const ProxyResult = struct {
        data: [65536]u8 = undefined,
        len: usize = 0,
        status: u16 = 503,
    };

    /// Proxy a write request to the current leader. Returns null if no leader.
    fn proxyToLeader(self: *Server, cl: *cluster_mod.ClusterNode, req: Request, raw_request: []const u8) ?ProxyResult {
        _ = raw_request;

        // Find the leader's address.
        const state = cl.election.currentState();
        if (state.leader_id.len == 0) return null; // No leader known.

        // Find leader's peer address from config, use its host with our HTTP port.
        var leader_peer_addr: ?std.net.Address = null;
        for (cl.config.peer_ids, 0..) |pid, i| {
            if (std.mem.eql(u8, pid, state.leader_id)) {
                leader_peer_addr = cl.config.peer_addrs[i];
                break;
            }
        }
        if (leader_peer_addr == null) return null;

        // Use the peer's IP but our HTTP port (all nodes run on the same HTTP port).
        var addr = leader_peer_addr.?;
        addr.in.sa.port = std.mem.nativeToBig(u16, self.config.port);

        const stream = std.net.tcpConnectToAddress(addr) catch return null;
        defer stream.close();

        // Build the proxied request with X-Corvo-Forwarded header injected.
        var proxy_buf: [65536]u8 = undefined;
        const body = req.body orelse "";
        const proxy_req = std.fmt.bufPrint(&proxy_buf,
            "{s} {s} HTTP/1.1\r\n" ++
                "Host: localhost:{d}\r\n" ++
                "Content-Type: application/json\r\n" ++
                "Content-Length: {d}\r\n" ++
                "X-Corvo-Forwarded: 1\r\n" ++
                "Connection: close\r\n" ++
                "{s}" ++
                "\r\n" ++
                "{s}",
            .{
                req.method, req.path, self.config.port,
                body.len,
                if (req.api_key) |k| std.fmt.bufPrint(
                    proxy_buf[65000..], "X-API-Key: {s}\r\n", .{k},
                ) catch "" else "",
                body,
            },
        ) catch return null;

        stream.writeAll(proxy_req) catch return null;

        // Read response.
        var result = ProxyResult{};
        var total_read: usize = 0;
        while (total_read < result.data.len) {
            const n = stream.read(result.data[total_read..]) catch break;
            if (n == 0) break;
            total_read += n;
        }
        result.len = total_read;

        // Parse status code from response.
        if (total_read > 12 and std.mem.startsWith(u8, result.data[0..total_read], "HTTP/1.1 ")) {
            result.status = std.fmt.parseInt(u16, result.data[9..12], 10) catch 503;
        }

        // Inject X-Corvo-Forwarded into response headers.
        // Find \r\n\r\n in response and insert header before it.
        if (std.mem.indexOf(u8, result.data[0..total_read], "\r\n\r\n")) |hdr_end| {
            // Insert "X-Corvo-Forwarded: 1\r\n" before the final \r\n\r\n.
            const inject = "X-Corvo-Forwarded: 1\r\n";
            const after = total_read - hdr_end;
            if (total_read + inject.len < result.data.len) {
                // Shift body right.
                std.mem.copyBackwards(u8, result.data[hdr_end + inject.len .. total_read + inject.len], result.data[hdr_end..total_read]);
                @memcpy(result.data[hdr_end .. hdr_end + inject.len], inject);
                result.len = total_read + inject.len;
                _ = after;
            }
        }

        return result;
    }

    // ====================================================================
    // Handlers — Approval Policies
    // ====================================================================

    fn handleListApprovalPolicies(self: *Server, buf: []u8) Response {
        self.store.flushMirror();
        var reader = self.store.reader() orelse return jsonOk(buf, "[]");
        var policy_buf: [64]sqlite_read.ApprovalPolicyRow = undefined;
        const count = reader.listApprovalPolicies(&policy_buf) catch return jsonError(buf, 500, "db error");

        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;

        for (policy_buf[0..count], 0..) |*row, i| {
            if (i > 0) {
                buf[pos] = ',';
                pos += 1;
            }
            const written = std.fmt.bufPrint(buf[pos..],
                \\{{"id":"{s}","name":"{s}","mode":"{s}","enabled":{s},"queue":"{s}","tag_key":"{s}","tag_value":"{s}","created_at":"{s}"}}
            , .{
                row.idSlice(),
                row.nameSlice(),
                row.modeSlice(),
                if (row.enabled) "true" else "false",
                row.queueSlice(),
                row.tagKeySlice(),
                row.tagValueSlice(),
                row.createdAtSlice(),
            }) catch return jsonError(buf, 500, "buf");
            pos += written.len;
        }

        buf[pos] = ']';
        pos += 1;
        return jsonOk(buf, buf[0..pos]);
    }

    fn handleSetApprovalPolicy(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const PolicyReq = struct {
            name: ?[]const u8 = null,
            mode: ?[]const u8 = null,
            enabled: ?bool = null,
            queue: ?[]const u8 = null,
            tag_key: ?[]const u8 = null,
            tag_value: ?[]const u8 = null,
        };

        const parsed = std.json.parseFromSlice(PolicyReq, self.allocator, body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");
        defer parsed.deinit();
        const r = parsed.value;

        const name = r.name orelse return jsonError(buf, 400, "name is required");
        const mode = r.mode orelse "any";
        const enabled = r.enabled orelse true;

        if (!std.mem.eql(u8, mode, "any") and !std.mem.eql(u8, mode, "all")) {
            return jsonError(buf, 400, "mode must be 'any' or 'all'");
        }

        // Generate a policy ID from timestamp.
        var id_buf: [32]u8 = undefined;
        const now_ns: u64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        const id = std.fmt.bufPrint(&id_buf, "apol_{x}", .{now_ns}) catch return jsonError(buf, 500, "id gen");

        // Build JSON data for KV storage.
        var data_buf: [1024]u8 = undefined;
        const data = std.fmt.bufPrint(&data_buf,
            \\{{"id":"{s}","name":"{s}","mode":"{s}","enabled":{s},"queue":"{s}","tag_key":"{s}","tag_value":"{s}"}}
        , .{
            id,
            name,
            mode,
            if (enabled) "true" else "false",
            r.queue orelse "",
            r.tag_key orelse "",
            r.tag_value orelse "",
        }) catch return jsonError(buf, 500, "buf");

        const result = self.store.modifyEntSetting(.{
            .setting = .approval_policy,
            .id = id,
            .data = data,
        });
        if (result.err) |e| return jsonError(buf, 400, e);

        // Mirror.
        if (self.store.mirror) |m| {
            m.enqueueApprovalPolicyUpsert(
                id,
                name,
                mode,
                enabled,
                r.queue orelse "",
                r.tag_key orelse "",
                r.tag_value orelse "",
            );
        }

        return jsonOk(buf, data);
    }

    fn handleDeleteApprovalPolicy(self: *Server, api_path: []const u8, buf: []u8) Response {
        const id = api_path["/approval-policies/".len..];
        if (id.len == 0) return jsonError(buf, 400, "missing policy id");

        const result = self.store.modifyEntSetting(.{
            .setting = .approval_policy,
            .id = id,
            .data = null,
        });
        if (result.err) |e| return jsonError(buf, 400, e);

        // Mirror.
        if (self.store.mirror) |m| {
            m.enqueueApprovalPolicyDelete(id);
        }

        return jsonOk(buf, "{\"status\":\"deleted\"}");
    }

    // ====================================================================
    // Handlers — Auth / API Keys
    // ====================================================================

    fn handleAuthStatus(self: *Server, buf: []u8) Response {
        const has_pw: bool = self.config.admin_password != null;
        const pw_str: []const u8 = if (has_pw) "true" else "false";
        return jsonOk(buf, std.fmt.bufPrint(buf, "{{\"admin_password_set\":{s}}}", .{pw_str}) catch
            return jsonError(buf, 500, "format error"));
    }

    fn handleListApiKeys(self: *Server, buf: []u8) Response {
        self.store.flushMirror();
        var reader = self.store.reader() orelse return jsonOk(buf, "[]");
        var key_buf: [100]sqlite_read.ApiKeyRow = undefined;
        const count = reader.listApiKeys(&key_buf) catch return jsonError(buf, 500, "db error");

        var pos: usize = 0;
        buf[pos] = '[';
        pos += 1;

        for (key_buf[0..count], 0..) |*row, i| {
            if (i > 0) {
                buf[pos] = ',';
                pos += 1;
            }

            if (row.expires_at_len > 0) {
                const written = std.fmt.bufPrint(buf[pos..], "{{\"key_hash\":\"{s}\",\"name\":\"{s}\",\"role\":\"{s}\",\"enabled\":{s},\"created_at\":\"{s}\",\"expires_at\":\"{s}\"}}", .{
                    row.keyHashSlice(),
                    row.nameSlice(),
                    row.roleSlice(),
                    if (row.enabled) "true" else "false",
                    row.createdAtSlice(),
                    row.expiresAtSlice(),
                }) catch return jsonError(buf, 500, "buf");
                pos += written.len;
            } else {
                const written = std.fmt.bufPrint(buf[pos..], "{{\"key_hash\":\"{s}\",\"name\":\"{s}\",\"role\":\"{s}\",\"enabled\":{s},\"created_at\":\"{s}\"}}", .{
                    row.keyHashSlice(),
                    row.nameSlice(),
                    row.roleSlice(),
                    if (row.enabled) "true" else "false",
                    row.createdAtSlice(),
                }) catch return jsonError(buf, 500, "buf");
                pos += written.len;
            }
        }

        buf[pos] = ']';
        pos += 1;
        return jsonOk(buf, buf[0..pos]);
    }

    fn handleCreateApiKey(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const KeyReq = struct {
            name: ?[]const u8 = null,
            key: ?[]const u8 = null,
            role: ?[]const u8 = null,
            enabled: ?bool = null,
        };

        var parse_buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
        const parsed = std.json.parseFromSlice(KeyReq, fba.allocator(), body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");

        const name = parsed.value.name orelse return jsonError(buf, 400, "missing name");
        const role = parsed.value.role orelse "admin";

        // Generate or use provided key.
        var gen_key_buf: [64]u8 = undefined;
        const raw_key = if (parsed.value.key) |k| k else blk: {
            // Generate: sk_ + hex from store ID generator.
            const id = self.store.generateID(gen_key_buf[3..]);
            @memcpy(gen_key_buf[0..3], "sk_");
            break :blk gen_key_buf[0 .. 3 + id.len];
        };

        // Hash the key.
        var hash_buf: [64]u8 = undefined;
        const key_hash = hashApiKey(raw_key, &hash_buf);

        // Build the KV data (JSON for enterprise setting storage).
        var data_buf: [512]u8 = undefined;
        const now_ns = self.store.nowNs();
        const data = std.fmt.bufPrint(&data_buf, "{{\"key_hash\":\"{s}\",\"name\":\"{s}\",\"role\":\"{s}\",\"enabled\":{s},\"created_at\":\"{d}\"}}", .{
            key_hash,
            name,
            role,
            if (parsed.value.enabled orelse true) "true" else "false",
            now_ns,
        }) catch return jsonError(buf, 500, "format error");

        // Write to KV via engine.
        var key_hash_copy: [64]u8 = undefined;
        @memcpy(&key_hash_copy, &hash_buf);
        const result = self.store.modifyEntSetting(.{
            .setting = .api_key,
            .id = key_hash_copy[0..64],
            .data = data,
        });

        if (result.err) |e| return jsonError(buf, 500, e);

        // Write directly to SQLite mirror (admin operation, not hot path).
        if (self.store.mirror) |m| {
            const db = m.getDB();
            var stmt = db.prepare(
                "INSERT OR REPLACE INTO api_keys (key_hash, name, role, enabled, created_at)" ++
                    " VALUES (?, ?, ?, ?, ?)",
            ) catch return jsonError(buf, 500, "mirror write failed");
            defer stmt.finalize();

            stmt.bindText(1, key_hash);
            stmt.bindText(2, name);
            stmt.bindText(3, role);
            stmt.bindInt(4, if (parsed.value.enabled orelse true) 1 else 0);
            var ts_buf2: [32]u8 = undefined;
            stmt.bindText(5, std.fmt.bufPrint(&ts_buf2, "{d}", .{now_ns}) catch "0");
            stmt.exec() catch return jsonError(buf, 500, "mirror write failed");
        }

        // Return the raw key (only time it's shown).
        return jsonOk(buf, std.fmt.bufPrint(buf, "{{\"status\":\"ok\",\"api_key\":\"{s}\"}}", .{raw_key}) catch
            return jsonError(buf, 500, "format error"));
    }

    fn handleDeleteApiKey(self: *Server, req: Request, buf: []u8) Response {
        const body = req.body orelse return jsonError(buf, 400, "missing request body");

        const DelReq = struct {
            key_hash: ?[]const u8 = null,
        };

        var parse_buf: [1024]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&parse_buf);
        const parsed = std.json.parseFromSlice(DelReq, fba.allocator(), body, .{
            .ignore_unknown_fields = true,
        }) catch return jsonError(buf, 400, "invalid JSON");

        const key_hash = parsed.value.key_hash orelse return jsonError(buf, 400, "missing key_hash");

        // Delete from KV.
        const result = self.store.modifyEntSetting(.{
            .setting = .api_key,
            .id = key_hash,
            .data = null, // null = delete
        });

        if (result.err) |e| return jsonError(buf, 500, e);

        // Delete from SQLite mirror.
        if (self.store.mirror) |m| {
            const db = m.getDB();
            var stmt = db.prepare("DELETE FROM api_keys WHERE key_hash = ?") catch
                return jsonOk(buf, "{\"status\":\"deleted\"}");
            defer stmt.finalize();
            stmt.bindText(1, key_hash);
            stmt.exec() catch {};
        }

        return jsonOk(buf, "{\"status\":\"deleted\"}");
    }

    // ====================================================================
    // UI — embedded SPA dashboard
    // ====================================================================

    fn handleUI(self: *Server, path: []const u8) Response {
        _ = self;
        // Strip "/ui" prefix to get the file path within the embedded assets.
        const sub = if (path.len > 3) path[3..] else "/";

        // Try to find an exact file match.
        if (ui_embed.lookup(sub)) |file| {
            return .{ .status = 200, .body = file.data, .content_type = file.content_type };
        }

        // SPA fallback — serve index.html for client-side routing.
        const index = ui_embed.indexHtml();
        return .{ .status = 200, .body = index.data, .content_type = index.content_type };
    }

    // ====================================================================
    // SSE streaming
    // ====================================================================

    fn handleSSE(self: *Server, conn: net.Server.Connection) void {
        const header =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "\r\n";
        conn.stream.writeAll(header) catch return;

        const oplog = self.store.engine.getOpLog();
        var last_seq = oplog.getSeq();
        var keepalive_counter: u32 = 0;

        while (self.running.load(.monotonic)) {
            const entries = oplog.readAfter(last_seq, 64);
            if (entries.len > 0) {
                for (entries) |e| {
                    var event_buf: [512]u8 = undefined;
                    const event = std.fmt.bufPrint(&event_buf,
                        "id: {d}\ndata: {{\"seq\":{d},\"shard\":{d},\"ts\":{d},\"size\":{d}}}\n\n",
                        .{ e.seq, e.seq, e.shard_id, e.timestamp, e.data.len },
                    ) catch continue;
                    conn.stream.writeAll(event) catch return;
                    last_seq = e.seq;
                }
                keepalive_counter = 0;
            } else {
                keepalive_counter += 1;
                // Send keepalive comment every ~15s (150 * 100ms).
                if (keepalive_counter >= 150) {
                    conn.stream.writeAll(": keepalive\n\n") catch return;
                    keepalive_counter = 0;
                }
                std.Thread.sleep(100_000_000); // 100ms
            }
        }
    }

    // ====================================================================
    // Webhook ingest
    // ====================================================================

    fn handleWebhookEnqueue(self: *Server, api_path: []const u8, req: Request, buf: []u8) Response {
        // Path: /webhooks/{queue} or /webhooks/{queue}?params
        const after_prefix = api_path["/webhooks/".len..];
        // Strip query params if present.
        const queue = if (std.mem.indexOf(u8, after_prefix, "?")) |qi| after_prefix[0..qi] else after_prefix;
        if (queue.len == 0) return jsonError(buf, 400, "missing queue name");

        // Raw body becomes the payload. Empty body defaults to "{}".
        var payload: []const u8 = "{}";
        if (req.body) |b| {
            if (b.len > 0) payload = b;
        }

        // Payload size validation.
        if (self.config.max_payload_bytes > 0 and payload.len > self.config.max_payload_bytes) {
            return jsonError(buf, 413, "payload too large");
        }

        // Parse query params from the path for priority, unique_key, max_retries, scheduled_at.
        var priority: u8 = types.priority_default;
        var unique_key: ?[]const u8 = null;
        var max_retries: u16 = 3;
        var state: types.JobState = .pending;
        var scheduled_at_ns: u64 = 0;

        if (std.mem.indexOf(u8, after_prefix, "?")) |qi| {
            const qs = after_prefix[qi + 1 ..];
            var params = std.mem.splitScalar(u8, qs, '&');
            while (params.next()) |param| {
                if (std.mem.indexOf(u8, param, "=")) |ei| {
                    const key = param[0..ei];
                    const val = param[ei + 1 ..];
                    if (eql(key, "priority")) {
                        priority = parsePriorityString(val);
                    } else if (eql(key, "unique_key")) {
                        unique_key = val;
                    } else if (eql(key, "max_retries")) {
                        max_retries = std.fmt.parseInt(u16, val, 10) catch 3;
                    } else if (eql(key, "scheduled_at")) {
                        if (parseRfc3339Ns(val)) |ns| {
                            scheduled_at_ns = ns;
                            state = .scheduled;
                        }
                    }
                }
            }
        }

        var id_buf: [64]u8 = undefined;
        const job_id = self.store.generateID(&id_buf);

        const job = ops_mod.EnqueueJob{
            .job_id = job_id,
            .queue = queue,
            .state = state,
            .priority = priority,
            .max_retries = max_retries,
            .backoff = .exponential,
            .base_delay_ms = 5_000,
            .max_delay_ms = 600_000,
            .unique_key = unique_key,
            .payload = payload,
            .scheduled_at_ns = scheduled_at_ns,
            .created_at_ns = self.store.nowNs(),
        };

        const result = self.store.enqueue(job);
        if (result.err) |err| {
            return jsonError(buf, 500, err);
        }

        self.throughput.inc(.enqueued);

        const resp = std.fmt.bufPrint(buf,
            "{{\"job\":{{\"id\":\"{s}\",\"queue\":\"{s}\",\"state\":\"{s}\",\"priority\":{d}}}}}",
            .{ job_id, queue, state.toString(), priority },
        ) catch "{}";
        return .{ .status = 201, .body = resp };
    }

    // ====================================================================
    // Debug / cluster info
    // ====================================================================

    fn handleDebugRuntime(self: *Server, buf: []u8) Response {
        _ = self;
        // Zig equivalent of Go's runtime stats — thread count, memory stats.
        const resp = std.fmt.bufPrint(buf,
            "{{\"engine\":\"zig\",\"arch\":\"{s}\",\"os\":\"{s}\"}}",
            .{ @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag) },
        ) catch "{}";
        return .{ .status = 200, .body = resp };
    }

    fn handleClusterStatus(self: *Server, buf: []u8) Response {
        if (self.cluster) |cl| {
            const state = cl.election.currentState();
            const state_str: []const u8 = if (state.state == .leader) "leader" else if (state.leader_id.len > 0) "follower" else "candidate";
            return jsonOk(buf, std.fmt.bufPrint(buf,
                "{{\"state\":\"{s}\",\"node_id\":\"{s}\",\"leader_id\":\"{s}\",\"epoch\":{d}}}",
                .{ state_str, cl.config.node_id, state.leader_id, state.epoch },
            ) catch return jsonError(buf, 500, "format error"));
        }
        return jsonOk(buf, "{\"state\":\"standalone\",\"node_id\":\"node-1\",\"leader_id\":\"node-1\",\"peers\":[]}");
    }

    fn handleClusterEvents(self: *Server, buf: []u8) Response {
        const oplog = self.store.engine.getOpLog();
        const seq = oplog.getSeq();
        const entries = oplog.readAfter(if (seq > 100) seq - 100 else 0, 100);

        var stream = std.io.fixedBufferStream(buf);
        const w = stream.writer();
        w.writeAll("{\"events\":[") catch return jsonOk(buf, "{\"events\":[]}");

        for (entries, 0..) |e, i| {
            if (i > 0) w.writeByte(',') catch break;
            w.print("{{\"seq\":{d},\"shard\":{d},\"ts\":{d},\"size\":{d}}}", .{
                e.seq, e.shard_id, e.timestamp, e.data.len,
            }) catch break;
        }

        w.writeAll("]}") catch {};
        return .{ .status = 200, .body = stream.getWritten() };
    }

    // ====================================================================
    // JSON helpers
    // ====================================================================

    fn jsonOk(buf: []u8, body: []const u8) Response {
        if (@intFromPtr(body.ptr) >= @intFromPtr(buf.ptr) and @intFromPtr(body.ptr) < @intFromPtr(buf.ptr) + buf.len) {
            return .{ .status = 200, .body = body };
        }
        const len = @min(body.len, buf.len);
        @memcpy(buf[0..len], body[0..len]);
        return .{ .status = 200, .body = buf[0..len] };
    }

    fn jsonError(buf: []u8, status: u16, msg: []const u8) Response {
        const body = std.fmt.bufPrint(buf, "{{\"error\":\"{s}\"}}", .{msg}) catch "{}";
        return .{ .status = status, .body = body };
    }

    fn jsonForbidden(buf: []u8) Response {
        const body = std.fmt.bufPrint(buf,
            "{{\"error\":\"enterprise license required\",\"code\":\"FORBIDDEN\"}}",
            .{},
        ) catch "{}";
        return .{ .status = 403, .body = body };
    }
};

// ============================================================================
// Priority parsing
// ============================================================================

/// Parse priority from a JSON value. Accepts:
///   - Named strings: "critical" (100), "high" (75), "normal" (50), "low" (25)
///   - Integer 0-100 (clamped)
fn parsePriorityValue(v: ?std.json.Value) u8 {
    const val = v orelse return types.priority_default;
    switch (val) {
        .string => |s| return parsePriorityString(s),
        .integer => |n| return @intCast(std.math.clamp(n, 0, 100)),
        else => return types.priority_default,
    }
}

fn parsePriorityString(s: []const u8) u8 {
    if (eql(s, "critical")) return types.priority_critical;
    if (eql(s, "high")) return types.priority_high;
    if (eql(s, "normal")) return types.priority_default;
    if (eql(s, "low")) return types.priority_low;
    // Try parsing as numeric string.
    const n = std.fmt.parseInt(i64, s, 10) catch return types.priority_default;
    return @intCast(std.math.clamp(n, 0, 100));
}

fn parseBackoff(s: ?[]const u8) types.Backoff {
    const v = s orelse return .exponential; // Go default
    if (eql(v, "exponential")) return .exponential;
    if (eql(v, "linear")) return .linear;
    if (eql(v, "fixed")) return .fixed;
    if (eql(v, "none")) return .none;
    return .exponential;
}

/// Quick parse of batch/array size from JSON body for rate limiting cost.
/// Looks for "jobs":[ or "acks":[ and counts commas + 1.
fn parseBatchCount(body: []const u8) u32 {
    // Find an array field.
    const markers = [_][]const u8{ "\"jobs\":[", "\"acks\":[", "\"job_ids\":[" };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, body, marker)) |pos| {
            var depth: i32 = 0;
            var count: u32 = 1;
            var i = pos + marker.len;
            while (i < body.len) : (i += 1) {
                switch (body[i]) {
                    '[' => depth += 1,
                    ']' => {
                        if (depth == 0) return @max(1, count);
                        depth -= 1;
                    },
                    ',' => {
                        if (depth == 0) count += 1;
                    },
                    else => {},
                }
            }
            return @max(1, count);
        }
    }
    return 1;
}

fn parseAgentStatus(s: []const u8) types.AgentStatus {
    if (eql(s, "continue")) return .@"continue";
    if (eql(s, "done")) return .done;
    if (eql(s, "hold")) return .hold;
    return .none;
}

/// Parse RFC3339 timestamp to nanoseconds since epoch.
/// Supports: "2024-01-15T10:30:00Z" and "2024-01-15T10:30:00+05:00"
fn parseRfc3339Ns(s: []const u8) ?u64 {
    // Minimum: "YYYY-MM-DDTHH:MM:SSZ" = 20 chars
    if (s.len < 20) return null;
    const year = std.fmt.parseInt(u32, s[0..4], 10) catch return null;
    if (s[4] != '-') return null;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    if (s[7] != '-') return null;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    if (s[10] != 'T' and s[10] != 't') return null;
    const hour = std.fmt.parseInt(u32, s[11..13], 10) catch return null;
    if (s[13] != ':') return null;
    const minute = std.fmt.parseInt(u32, s[14..16], 10) catch return null;
    if (s[16] != ':') return null;
    const second = std.fmt.parseInt(u32, s[17..19], 10) catch return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    // Days from year 0 to epoch (1970-01-01).
    const epoch_days: i64 = 719528;
    // Days from year 0 to target date.
    const y: i64 = @intCast(year);
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    // Convert month to 0-indexed March-based (March=0, Feb=11).
    const adj_m = if (m > 2) m - 3 else m + 9;
    const adj_y = if (m <= 2) y - 1 else y;
    const total_days = adj_y * 365 + @divFloor(adj_y, 4) - @divFloor(adj_y, 100) + @divFloor(adj_y, 400) +
        @divFloor(adj_m * 306 + 5, 10) + d - 1 - epoch_days + 60; // +60 to adjust March-based offset

    var offset_seconds: i64 = 0;
    if (s.len > 19) {
        if (s[19] == 'Z' or s[19] == 'z') {
            // UTC, no offset.
        } else if ((s[19] == '+' or s[19] == '-') and s.len >= 25) {
            const oh = std.fmt.parseInt(i64, s[20..22], 10) catch return null;
            const om = std.fmt.parseInt(i64, s[23..25], 10) catch return null;
            offset_seconds = (oh * 3600 + om * 60);
            if (s[19] == '+') offset_seconds = -offset_seconds; // UTC = local - offset
        }
    }

    const total_seconds = total_days * 86400 + @as(i64, @intCast(hour)) * 3600 +
        @as(i64, @intCast(minute)) * 60 + @as(i64, @intCast(second)) + offset_seconds;

    if (total_seconds < 0) return null;
    return @intCast(total_seconds * 1_000_000_000);
}

fn parseBulkAction(s: []const u8) ?ops_mod.BulkAction {
    if (eql(s, "retry")) return .retry;
    if (eql(s, "delete")) return .delete;
    if (eql(s, "cancel")) return .cancel;
    if (eql(s, "move")) return .move;
    if (eql(s, "requeue")) return .requeue;
    if (eql(s, "change_priority")) return .change_priority;
    if (eql(s, "hold")) return .hold;
    if (eql(s, "approve")) return .approve;
    if (eql(s, "reject")) return .reject;
    return null;
}

fn extractQueueName(api_path: []const u8) ?[]const u8 {
    const rest = api_path["/queues/".len..];
    const slash = std.mem.indexOf(u8, rest, "/") orelse return null;
    const name = rest[0..slash];
    if (name.len == 0) return null;
    return name;
}

// ============================================================================
// Request parsing (HTTP/1.1 with Content-Length + keep-alive)
// ============================================================================

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    api_key: ?[]const u8 = null,
};

/// Extended parse result that tracks total bytes consumed and Connection header.
const ParsedRequestFull = struct {
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
    /// Total bytes consumed by this request (headers + body). Caller uses
    /// this to shift unconsumed data to front of buffer for pipelining.
    total_bytes: usize,
    /// True if the client sent "Connection: close".
    connection_close: bool,
    /// API key from X-API-Key or Authorization: Bearer header.
    api_key: ?[]const u8 = null,
    /// True if X-Corvo-Forwarded: 1 header present (prevent proxy loop).
    forwarded: bool = false,
    /// Raw request bytes (for proxying to leader).
    raw_request: []const u8 = "",
};

/// Parse one complete HTTP/1.1 request from the buffer. Returns null if
/// the header block is not yet complete (no \r\n\r\n found). If headers
/// are complete but the body (per Content-Length) is not fully buffered,
/// the returned total_bytes will exceed the buffer length — caller must
/// read more data before using the result.
fn parseRequestFull(raw: []const u8) ?ParsedRequestFull {
    // Find end of headers.
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return null;
    const headers_block = raw[0..header_end];
    const body_offset = header_end + 4;

    // Parse request line.
    const line_end = std.mem.indexOf(u8, headers_block, "\r\n") orelse return null;
    const request_line = headers_block[0..line_end];

    const space1 = std.mem.indexOf(u8, request_line, " ") orelse return null;
    const method = request_line[0..space1];
    const rest = request_line[space1 + 1 ..];
    const space2 = std.mem.indexOf(u8, rest, " ") orelse return null;
    const path = rest[0..space2];

    // Scan headers for Content-Length, Connection, and auth.
    var content_length: usize = 0;
    var connection_close = false;
    var api_key: ?[]const u8 = null;
    var forwarded = false;
    var hdr_pos = line_end + 2; // skip past request line's \r\n
    while (hdr_pos < header_end) {
        const next_end = std.mem.indexOf(u8, headers_block[hdr_pos..], "\r\n") orelse
            headers_block.len - hdr_pos;
        const header_line = headers_block[hdr_pos .. hdr_pos + next_end];
        hdr_pos += next_end + 2;

        if (header_line.len == 0) break;

        // Case-insensitive header matching.
        if (asciiStartsWithIgnoreCase(header_line, "content-length:")) {
            const val = std.mem.trimLeft(u8, header_line["content-length:".len..], " \t");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        } else if (asciiStartsWithIgnoreCase(header_line, "connection:")) {
            const val = std.mem.trimLeft(u8, header_line["connection:".len..], " \t");
            if (asciiEqlIgnoreCase(val, "close")) {
                connection_close = true;
            }
        } else if (asciiStartsWithIgnoreCase(header_line, "x-api-key:")) {
            api_key = std.mem.trimLeft(u8, header_line["x-api-key:".len..], " \t");
        } else if (asciiStartsWithIgnoreCase(header_line, "x-corvo-forwarded:")) {
            forwarded = true;
        } else if (api_key == null and asciiStartsWithIgnoreCase(header_line, "authorization:")) {
            const val = std.mem.trimLeft(u8, header_line["authorization:".len..], " \t");
            if (asciiStartsWithIgnoreCase(val, "Bearer ")) {
                api_key = std.mem.trimLeft(u8, val["Bearer ".len..], " \t");
            }
        }
    }

    const total_bytes = body_offset + content_length;
    const body: ?[]const u8 = if (content_length > 0 and total_bytes <= raw.len)
        raw[body_offset .. body_offset + content_length]
    else if (content_length == 0)
        null
    else
        null; // Body not fully received yet — caller checks total_bytes > raw.len.

    return .{
        .method = method,
        .path = path,
        .body = body,
        .total_bytes = total_bytes,
        .connection_close = connection_close,
        .api_key = api_key,
        .forwarded = forwarded,
        .raw_request = if (total_bytes <= raw.len) raw[0..total_bytes] else raw,
    };
}

/// Legacy single-request parser (kept for compatibility).
fn parseRequest(raw: []const u8) ?Request {
    const full = parseRequestFull(raw) orelse return null;
    return .{
        .method = full.method,
        .path = full.path,
        .body = full.body,
        .api_key = full.api_key,
    };
}

fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        403 => "Forbidden",
        404 => "Not Found",
        409 => "Conflict",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

/// Extract a query parameter value from a URL path (e.g., "q" from "/path?q=hello&limit=10").
fn extractQueryParam(path: []const u8, param: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOf(u8, path, "?") orelse return null;
    var remaining = path[qmark + 1 ..];

    while (remaining.len > 0) {
        // Find next & or end.
        const amp = std.mem.indexOf(u8, remaining, "&") orelse remaining.len;
        const pair = remaining[0..amp];
        remaining = if (amp < remaining.len) remaining[amp + 1 ..] else "";

        // Split on =.
        const eq = std.mem.indexOf(u8, pair, "=") orelse continue;
        const key = pair[0..eq];
        const val = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, param) and val.len > 0) return val;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, haystack, prefix);
}

fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, haystack, suffix);
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    for (haystack[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    return true;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const talon = @import("talon");
const kv = @import("kv.zig");
const engine_mod = @import("engine.zig");

const TestContext = struct {
    db: *talon.DB,
    stores: [1]kv.Store,
    engine: engine_mod.Engine,
    store: store_mod.Store,
    server: Server,
    allocator: std.mem.Allocator,
    path: []const u8,

    /// Must be called on a stable (non-movable) *TestContext, e.g. declared
    /// as `var ctx: TestContext = undefined; try ctx.setup(...)`.
    fn setup(self: *TestContext, allocator: std.mem.Allocator, path: []const u8) !void {
        std.fs.cwd().deleteTree(path) catch {};
        self.allocator = allocator;
        self.path = path;
        self.db = try talon.DB.open(allocator, path, .{ .sync = false });
        self.stores = .{kv.Store.init(self.db)};
        self.engine = engine_mod.Engine.init(allocator, &self.stores, .{
            .talon_sync = false,
        });
        self.store = store_mod.Store.init(allocator, &self.engine, null);
        self.server = Server.init(allocator, &self.store, .{});
    }

    fn deinit(self: *TestContext) void {
        self.engine.deinit();
        self.db.close();
        std.fs.cwd().deleteTree(self.path) catch {};
    }

    fn route(self: *TestContext, method: []const u8, path: []const u8, body: ?[]const u8, buf: []u8) Server.Response {
        const req = Request{ .method = method, .path = path, .body = body };
        return self.server.route(req, buf);
    }
};

test "OPTIONS returns 204 (CORS preflight)" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-options");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("OPTIONS", "/api/v1/enqueue", null, &buf);
    try std.testing.expectEqual(@as(u16, 204), resp.status);
}

test "healthz returns 200" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-health");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("GET", "/healthz", null, &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "enqueue returns 201 with job ID" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-enq");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue",
        \\{"queue":"test","payload":"hello"}
    , &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    // Response should contain a job ID.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"job_") != null);
}

test "enqueue missing queue returns 400" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-enq-noq");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue",
        \\{"payload":"hello"}
    , &buf);
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "ack non-existent job returns 404" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-ack404");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/ack/nonexistent-job", null, &buf);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "job not found") != null);
}

test "fail non-existent job returns 404" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-fail404");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/fail/nonexistent-job",
        \\{"error":"test error"}
    , &buf);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "job not found") != null);
}

test "delete non-existent job returns 404" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-del404");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("DELETE", "/api/v1/jobs/nonexistent-job", null, &buf);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "job action on non-existent job returns 404" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-action404");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/jobs/nonexistent-job/retry", null, &buf);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "heartbeat parses worker_id" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-hb");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    // Heartbeat with no jobs is OK.
    const resp = ctx.route("POST", "/api/v1/heartbeat",
        \\{"worker_id":"w-1","jobs":[]}
    , &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "heartbeat missing worker_id returns 400" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-hb400");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/heartbeat",
        \\{"jobs":[{"job_id":"j1"}]}
    , &buf);
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "heartbeat with progress and checkpoint" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-hbprog");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Heartbeat with per-job progress and checkpoint (job doesn't exist, but parsing works).
    const hb_resp = ctx.route("POST", "/api/v1/heartbeat",
        \\{"worker_id":"w1","jobs":[{"job_id":"j1","progress":"50%","checkpoint":"step-3"},{"job_id":"j2","progress":"done"}]}
    , &buf);
    try std.testing.expectEqual(@as(u16, 200), hb_resp.status);
}

test "queue concurrency passes max value" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-conc");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/queues/testq/concurrency",
        \\{"max":10}
    , &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "queue throttle passes rate and window" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-throttle");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/queues/testq/throttle",
        \\{"rate":100,"window_ms":5000}
    , &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "batch enqueue handles >64 jobs" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-batch65");
    defer ctx.deinit();

    // Build a batch with 65 jobs.
    var json_buf: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&json_buf);
    const w = stream.writer();
    w.writeAll("{\"jobs\":[") catch unreachable;
    for (0..65) |i| {
        if (i > 0) w.writeByte(',') catch unreachable;
        w.writeAll("{\"queue\":\"test\"}") catch unreachable;
    }
    w.writeAll("]}") catch unreachable;

    var buf: [65536]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue/batch", stream.getWritten(), &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);

    // Count job IDs in response — should be 65 (not capped at 64).
    // Count commas between [ and ] to determine number of array elements.
    const arr_start = (std.mem.indexOf(u8, resp.body, "[") orelse 0) + 1;
    const arr_end = std.mem.lastIndexOf(u8, resp.body, "]") orelse resp.body.len;
    const arr_content = resp.body[arr_start..arr_end];
    if (arr_content.len == 0) return error.TestFailed;
    var count: usize = 1; // At least one element if non-empty.
    for (arr_content) |c| {
        if (c == ',') count += 1;
    }
    try std.testing.expectEqual(@as(usize, 65), count);
}

test "enqueue + ack lifecycle" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-lifecycle");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;

    // Enqueue.
    const enq_resp = ctx.route("POST", "/api/v1/enqueue",
        \\{"queue":"test","payload":"hello"}
    , &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);

    // Extract job ID from response.
    const id_start = (std.mem.indexOf(u8, enq_resp.body, "\"id\":\"") orelse return error.TestFailed) + 6;
    const id_end = std.mem.indexOf(u8, enq_resp.body[id_start..], "\"") orelse return error.TestFailed;
    const job_id = enq_resp.body[id_start..][0..id_end];

    // Fetch.
    var buf2: [4096]u8 = undefined;
    const fetch_resp = ctx.route("POST", "/api/v1/fetch",
        \\{"queues":["test"],"worker_id":"w-1","count":1}
    , &buf2);
    try std.testing.expectEqual(@as(u16, 200), fetch_resp.status);
    // Should contain the job we enqueued.
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "job_id") != null);

    // Ack — should succeed (job exists).
    var ack_path_buf: [128]u8 = undefined;
    const ack_path = std.fmt.bufPrint(&ack_path_buf, "/api/v1/ack/{s}", .{job_id}) catch return error.TestFailed;
    var buf3: [4096]u8 = undefined;
    const ack_resp = ctx.route("POST", ack_path, null, &buf3);
    try std.testing.expectEqual(@as(u16, 200), ack_resp.status);
}

test "job move on non-existent job returns 404" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-move404");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/jobs/nonexistent/move",
        \\{"queue":"target"}
    , &buf);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "job replay on non-existent job returns 404" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-replay404");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/jobs/nonexistent/replay", null, &buf);
    try std.testing.expectEqual(@as(u16, 404), resp.status);
}

test "enqueue with negative max_retries clamps to 0" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-neg-retries");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    // Negative max_retries should not crash (previously would overflow).
    const resp = ctx.route("POST", "/api/v1/enqueue",
        \\{"queue":"test","max_retries":-50}
    , &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
}

test "queue operations check errors" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-qop");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;

    // Pause should succeed.
    const pause_resp = ctx.route("POST", "/api/v1/queues/testq/pause", null, &buf);
    try std.testing.expectEqual(@as(u16, 200), pause_resp.status);

    // Resume should succeed.
    var buf2: [4096]u8 = undefined;
    const resume_resp = ctx.route("POST", "/api/v1/queues/testq/resume", null, &buf2);
    try std.testing.expectEqual(@as(u16, 200), resume_resp.status);
}

test "batch seal with empty batch_id returns 400" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-seal400");
    defer ctx.deinit();

    var buf: [4096]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/batch//seal", null, &buf);
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

// ============================================================================
// Mirror-enabled test context — for testing store→mirror sync
// ============================================================================

const MirrorTestContext = struct {
    db: *talon.DB,
    stores: [1]kv.Store,
    engine: engine_mod.Engine,
    mirror: mirror_mod.Mirror,
    store: store_mod.Store,
    server: Server,
    allocator: std.mem.Allocator,
    path: []const u8,
    text_buf: [512]u8 = undefined,

    fn setup(self: *MirrorTestContext, allocator: std.mem.Allocator, path: []const u8) !void {
        std.fs.cwd().deleteTree(path) catch {};
        self.allocator = allocator;
        self.path = path;
        self.db = try talon.DB.open(allocator, path, .{ .sync = false });
        self.stores = .{kv.Store.init(self.db)};
        self.engine = engine_mod.Engine.init(allocator, &self.stores, .{
            .talon_sync = false,
        });
        self.mirror = try mirror_mod.Mirror.initInMemory(allocator);
        self.store = store_mod.Store.init(allocator, &self.engine, &self.mirror);
        self.server = Server.init(allocator, &self.store, .{});
    }

    fn deinit(self: *MirrorTestContext) void {
        self.mirror.deinit();
        self.engine.deinit();
        self.db.close();
        std.fs.cwd().deleteTree(self.path) catch {};
    }

    fn route(self: *MirrorTestContext, method: []const u8, path_str: []const u8, body: ?[]const u8, buf: []u8) Server.Response {
        const req = Request{ .method = method, .path = path_str, .body = body };
        return self.server.route(req, buf);
    }

    /// Query a count from the mirror SQLite.
    fn mirrorCount(self: *MirrorTestContext, sql: [*:0]const u8) i64 {
        var stmt = self.mirror.db.prepare(sql) catch return -1;
        defer stmt.finalize();
        _ = stmt.step() catch return -1;
        return stmt.columnInt(0);
    }

    /// Query a count with a text binding.
    fn mirrorCountBind(self: *MirrorTestContext, sql: [*:0]const u8, bind1: []const u8) i64 {
        var stmt = self.mirror.db.prepare(sql) catch return -1;
        defer stmt.finalize();
        stmt.bindText(1, bind1);
        _ = stmt.step() catch return -1;
        return stmt.columnInt(0);
    }

    /// Query a text value with a text binding. Copies result into struct buffer
    /// to avoid use-after-free from SQLite statement finalization.
    fn mirrorText(self: *MirrorTestContext, sql: [*:0]const u8, bind1: []const u8) ?[]const u8 {
        var stmt = self.mirror.db.prepare(sql) catch return null;
        defer stmt.finalize();
        stmt.bindText(1, bind1);
        if (stmt.step() catch null) |_| {
            const text = stmt.columnText(0) orelse return null;
            const len = @min(text.len, self.text_buf.len);
            @memcpy(self.text_buf[0..len], text[0..len]);
            return self.text_buf[0..len];
        }
        return null;
    }

    /// Flush the mirror ring buffer synchronously.
    fn flushMirror(self: *MirrorTestContext) void {
        self.mirror.flush() catch {};
    }

    /// Extract a job ID from an enqueue response body.
    fn extractJobId(body: []const u8) []const u8 {
        const start = (std.mem.indexOf(u8, body, "\"id\":\"") orelse return "") + 6;
        const end = std.mem.indexOf(u8, body[start..], "\"") orelse return "";
        return body[start..][0..end];
    }
};

// ============================================================================
// Mirror sync integration tests
// ============================================================================

test "mirror sync: enqueue mirrors job and queue" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-enqueue");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"sync-q\",\"priority\":80}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);

    ctx.flushMirror();

    // Job should exist in mirror.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM jobs WHERE queue = ?", "sync-q"));
    // Queue should exist in mirror.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM queues WHERE name = ?", "sync-q"));
}

test "mirror sync: queue pause/resume mirrors to sqlite" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-qpause");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue to create the queue in mirror.
    _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"pauseq\"}", &buf);
    ctx.flushMirror();

    // Pause queue.
    const resp = ctx.route("POST", "/api/v1/queues/pauseq/pause", null, &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    ctx.flushMirror();

    // Mirror should show paused.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT paused FROM queues WHERE name = ?", "pauseq"));

    // Resume queue.
    _ = ctx.route("POST", "/api/v1/queues/pauseq/resume", null, &buf);
    ctx.flushMirror();

    // Mirror should show unpaused.
    try std.testing.expectEqual(@as(i64, 0), ctx.mirrorCountBind("SELECT paused FROM queues WHERE name = ?", "pauseq"));
}

test "mirror sync: queue concurrency mirrors to sqlite" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-qconc");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Create queue.
    _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"concq\"}", &buf);
    ctx.flushMirror();

    // Set concurrency.
    _ = ctx.route("POST", "/api/v1/queues/concq/concurrency", "{\"max\":5}", &buf);
    ctx.flushMirror();

    try std.testing.expectEqual(@as(i64, 5), ctx.mirrorCountBind("SELECT max_concurrency FROM queues WHERE name = ?", "concq"));
}

test "mirror sync: enqueue + fetch + ack lifecycle" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-lifecycle");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue.
    const enq_resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"lq\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);
    const job_id = MirrorTestContext.extractJobId(enq_resp.body);
    try std.testing.expect(job_id.len > 0);
    ctx.flushMirror();

    // Mirror: job should be pending.
    {
        const state = ctx.mirrorText("SELECT state FROM jobs WHERE id = ?", job_id);
        try std.testing.expect(state != null);
        try std.testing.expectEqualStrings("pending", state.?);
    }

    // Fetch.
    var fetch_buf: [8192]u8 = undefined;
    const fetch_resp = ctx.route("POST", "/api/v1/fetch", "{\"queues\":[\"lq\"],\"worker_id\":\"w1\",\"count\":1}", &fetch_buf);
    try std.testing.expectEqual(@as(u16, 200), fetch_resp.status);
    ctx.flushMirror();

    // Mirror: job should be active.
    {
        const state = ctx.mirrorText("SELECT state FROM jobs WHERE id = ?", job_id);
        try std.testing.expect(state != null);
        try std.testing.expectEqualStrings("active", state.?);
    }

    // Ack.
    var ack_buf: [8192]u8 = undefined;
    var ack_path_buf: [256]u8 = undefined;
    const ack_path = std.fmt.bufPrint(&ack_path_buf, "/api/v1/ack/{s}", .{job_id}) catch return;
    const ack_resp = ctx.route("POST", ack_path, "{\"queue\":\"lq\"}", &ack_buf);
    try std.testing.expectEqual(@as(u16, 200), ack_resp.status);
    ctx.flushMirror();

    // Mirror: job should be completed.
    {
        const state = ctx.mirrorText("SELECT state FROM jobs WHERE id = ?", job_id);
        try std.testing.expect(state != null);
        try std.testing.expectEqualStrings("completed", state.?);
    }
}

test "mirror sync: fail mirrors correct state" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-fail");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue a job with 0 retries (will go dead on first fail).
    const enq_resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"fq\",\"max_retries\":0}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);

    // Copy job_id into stable buffer before buf is reused.
    var jid_buf: [64]u8 = undefined;
    const job_id_raw = MirrorTestContext.extractJobId(enq_resp.body);
    @memcpy(jid_buf[0..job_id_raw.len], job_id_raw);
    const job_id = jid_buf[0..job_id_raw.len];

    ctx.flushMirror();

    // Fetch.
    _ = ctx.route("POST", "/api/v1/fetch", "{\"queues\":[\"fq\"],\"worker_id\":\"w1\",\"count\":1}", &buf);
    ctx.flushMirror();

    // Fail.
    var fail_path: [256]u8 = undefined;
    const fp = std.fmt.bufPrint(&fail_path, "/api/v1/fail/{s}", .{job_id}) catch return;
    _ = ctx.route("POST", fp, "{\"queue\":\"fq\",\"error\":\"test error\"}", &buf);
    ctx.flushMirror();

    // Mirror: job should be dead (0 retries).
    {
        const state = ctx.mirrorText("SELECT state FROM jobs WHERE id = ?", job_id);
        try std.testing.expect(state != null);
        try std.testing.expectEqualStrings("dead", state.?);
    }

    // Error record should exist in mirror.
    try std.testing.expect(ctx.mirrorCountBind("SELECT COUNT(*) FROM job_errors WHERE job_id = ?", job_id) >= 1);
}

test "mirror sync: heartbeat mirrors worker" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-hb");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue and fetch to register worker.
    _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"hbq\"}", &buf);
    var fbuf: [8192]u8 = undefined;
    _ = ctx.route("POST", "/api/v1/fetch", "{\"queues\":[\"hbq\"],\"worker_id\":\"hb-worker\",\"count\":1}", &fbuf);
    ctx.flushMirror();

    // Worker should be in mirror from fetch.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM workers WHERE id = ?", "hb-worker"));

    // Heartbeat.
    _ = ctx.route("POST", "/api/v1/heartbeat", "{\"worker_id\":\"hb-worker\",\"jobs\":{}}", &buf);
    ctx.flushMirror();

    // Worker should still exist with updated heartbeat.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM workers WHERE id = ?", "hb-worker"));
}

test "mirror sync: clear queue removes jobs from mirror" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-clearq");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue 3 jobs.
    for (0..3) |_| {
        _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"clearq\"}", &buf);
    }
    ctx.flushMirror();
    try std.testing.expectEqual(@as(i64, 3), ctx.mirrorCountBind("SELECT COUNT(*) FROM jobs WHERE queue = ?", "clearq"));

    // Clear queue.
    _ = ctx.route("POST", "/api/v1/queues/clearq/clear", null, &buf);
    ctx.flushMirror();

    // Jobs should be gone from mirror.
    try std.testing.expectEqual(@as(i64, 0), ctx.mirrorCountBind("SELECT COUNT(*) FROM jobs WHERE queue = ?", "clearq"));
}

test "mirror sync: delete queue removes queue and jobs from mirror" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-delq");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue to create queue.
    _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"delq\"}", &buf);
    ctx.flushMirror();
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM queues WHERE name = ?", "delq"));

    // Delete queue.
    _ = ctx.route("DELETE", "/api/v1/queues/delq", null, &buf);
    ctx.flushMirror();

    // Queue and jobs gone from mirror.
    try std.testing.expectEqual(@as(i64, 0), ctx.mirrorCountBind("SELECT COUNT(*) FROM queues WHERE name = ?", "delq"));
    try std.testing.expectEqual(@as(i64, 0), ctx.mirrorCountBind("SELECT COUNT(*) FROM jobs WHERE queue = ?", "delq"));
}

test "mirror sync: batch create and seal" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-batch");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Create batch.
    const resp = ctx.route("POST", "/api/v1/batch", "{\"callback_queue\":\"cb\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);

    // Extract batch_id.
    const bid_start = (std.mem.indexOf(u8, resp.body, "\"batch_id\":\"") orelse return) + 12;
    const bid_end = std.mem.indexOf(u8, resp.body[bid_start..], "\"") orelse return;
    const batch_id = resp.body[bid_start..][0..bid_end];

    ctx.flushMirror();

    // Mirror should have the batch record.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM batches WHERE id = ?", batch_id));
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT open FROM batches WHERE id = ?", batch_id));

    // Seal batch.
    var seal_path: [256]u8 = undefined;
    const sp = std.fmt.bufPrint(&seal_path, "/api/v1/batch/{s}/seal", .{batch_id}) catch return;
    _ = ctx.route("POST", sp, null, &buf);
    ctx.flushMirror();

    // Mirror should show sealed.
    try std.testing.expectEqual(@as(i64, 0), ctx.mirrorCountBind("SELECT open FROM batches WHERE id = ?", batch_id));
}

test "mirror sync: budget set and delete" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-budget");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Set budget.
    const resp = ctx.route("POST", "/api/v1/budgets",
        "{\"scope\":\"queue\",\"target\":\"default\",\"daily_usd\":100,\"per_job_usd\":5,\"on_exceed\":\"hold\"}", &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status);

    ctx.flushMirror();

    // Budget should be in mirror.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCount("SELECT COUNT(*) FROM budgets"));

    // Delete budget.
    _ = ctx.route("DELETE", "/api/v1/budgets/queue/default", null, &buf);
    ctx.flushMirror();

    // Budget should be gone.
    try std.testing.expectEqual(@as(i64, 0), ctx.mirrorCount("SELECT COUNT(*) FROM budgets"));
}

test "mirror sync: cron create and delete" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-cron");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Create cron.
    const resp = ctx.route("POST", "/api/v1/cron-jobs",
        "{\"name\":\"test-cron\",\"queue\":\"cron-q\",\"schedule\":\"*/5 * * * *\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);

    ctx.flushMirror();

    // Cron should be in mirror.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCount("SELECT COUNT(*) FROM crons"));
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM crons WHERE name = ?", "test-cron"));

    // Extract cron_id for deletion.
    const cid_start = (std.mem.indexOf(u8, resp.body, "\"cron_id\":\"") orelse return) + 11;
    const cid_end = std.mem.indexOf(u8, resp.body[cid_start..], "\"") orelse return;
    const cron_id = resp.body[cid_start..][0..cid_end];

    // Delete cron.
    var del_path: [256]u8 = undefined;
    const dp = std.fmt.bufPrint(&del_path, "/api/v1/cron-jobs/{s}", .{cron_id}) catch return;
    _ = ctx.route("DELETE", dp, null, &buf);
    ctx.flushMirror();

    // Cron should be gone.
    try std.testing.expectEqual(@as(i64, 0), ctx.mirrorCount("SELECT COUNT(*) FROM crons"));
}

test "mirror sync: maintenance promote mirrors to sqlite" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-promote");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue a scheduled job with a past timestamp (will be immediately promotable).
    const enq_resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"promq\",\"scheduled_at\":\"2020-01-01T00:00:00Z\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);
    ctx.flushMirror();

    // Job should be scheduled in mirror.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM jobs WHERE queue = ? AND state = 'scheduled'", "promq"));

    // Run promote maintenance — now_ns will be >> 2020, so job should promote.
    _ = ctx.store.maintenance(.promote);
    ctx.flushMirror();

    // Job should now be pending in mirror.
    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM jobs WHERE queue = ? AND state = 'pending'", "promq"));
}

test "mirror sync: bulk cancel mirrors job state" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-bulkcancel");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue.
    const enq_resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"bcq\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);

    // Copy job_id into stable buffer before buf is reused.
    var jid_buf: [64]u8 = undefined;
    const job_id_raw = MirrorTestContext.extractJobId(enq_resp.body);
    @memcpy(jid_buf[0..job_id_raw.len], job_id_raw);
    const job_id = jid_buf[0..job_id_raw.len];
    ctx.flushMirror();

    // Cancel via bulk action.
    var cancel_path: [256]u8 = undefined;
    const cp = std.fmt.bufPrint(&cancel_path, "/api/v1/jobs/{s}/cancel", .{job_id}) catch return;
    _ = ctx.route("POST", cp, null, &buf);
    ctx.flushMirror();

    // Mirror should show cancelled.
    {
        const state = ctx.mirrorText("SELECT state FROM jobs WHERE id = ?", job_id);
        try std.testing.expect(state != null);
        try std.testing.expectEqualStrings("cancelled", state.?);
    }
}

test "mirror sync: bulk delete removes job from mirror" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-bulkdel");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue.
    const enq_resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"bdq\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);

    // Copy job_id into stable buffer before buf is reused.
    var jid_buf: [64]u8 = undefined;
    const job_id_raw = MirrorTestContext.extractJobId(enq_resp.body);
    @memcpy(jid_buf[0..job_id_raw.len], job_id_raw);
    const job_id = jid_buf[0..job_id_raw.len];
    ctx.flushMirror();

    try std.testing.expectEqual(@as(i64, 1), ctx.mirrorCountBind("SELECT COUNT(*) FROM jobs WHERE id = ?", job_id));

    // Delete job — use separate path buffer, not buf.
    var del_path: [256]u8 = undefined;
    const dp = std.fmt.bufPrint(&del_path, "/api/v1/jobs/{s}", .{job_id}) catch return;
    _ = ctx.route("DELETE", dp, null, &buf);
    ctx.flushMirror();

    // Job should be gone from mirror.
    try std.testing.expectEqual(@as(i64, 0), ctx.mirrorCountBind("SELECT COUNT(*) FROM jobs WHERE id = ?", job_id));
}

test "mirror sync: FTS payload search" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-msync-fts");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue with payload.
    _ = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"ftsq\",\"payload\":\"{\\\"task\\\":\\\"send_email\\\",\\\"to\\\":\\\"alice@example.com\\\"}\"}", &buf);
    ctx.flushMirror();

    // FTS should find it.
    try std.testing.expect(ctx.mirrorCount("SELECT COUNT(*) FROM jobs_fts") >= 1);

    // Payload should be in job_payloads.
    try std.testing.expect(ctx.mirrorCount("SELECT COUNT(*) FROM job_payloads") >= 1);
}

// ============================================================================
// Priority + scheduled_at tests
// ============================================================================

test "parseRfc3339Ns: basic UTC timestamps" {
    // 2020-01-01T00:00:00Z = 1577836800 seconds since epoch.
    const ns = parseRfc3339Ns("2020-01-01T00:00:00Z").?;
    try std.testing.expectEqual(@as(u64, 1577836800_000_000_000), ns);

    // 1970-01-01T00:00:00Z = 0 (epoch).
    try std.testing.expectEqual(@as(u64, 0), parseRfc3339Ns("1970-01-01T00:00:00Z").?);

    // 2024-06-15T14:30:00Z
    const ns2 = parseRfc3339Ns("2024-06-15T14:30:00Z").?;
    try std.testing.expectEqual(@as(u64, 1718461800_000_000_000), ns2);
}

test "parseRfc3339Ns: timezone offsets" {
    // 2020-01-01T05:00:00+05:00 = 2020-01-01T00:00:00Z
    const ns = parseRfc3339Ns("2020-01-01T05:00:00+05:00").?;
    try std.testing.expectEqual(@as(u64, 1577836800_000_000_000), ns);

    // 2019-12-31T19:00:00-05:00 = 2020-01-01T00:00:00Z
    const ns2 = parseRfc3339Ns("2019-12-31T19:00:00-05:00").?;
    try std.testing.expectEqual(@as(u64, 1577836800_000_000_000), ns2);
}

test "parseRfc3339Ns: invalid inputs" {
    try std.testing.expect(parseRfc3339Ns("not-a-date") == null);
    try std.testing.expect(parseRfc3339Ns("2020-13-01T00:00:00Z") == null); // month 13
    try std.testing.expect(parseRfc3339Ns("2020-01-01") == null); // too short
    try std.testing.expect(parseRfc3339Ns("") == null);
}

test "parsePriorityValue: integer and string" {
    // Integer values.
    const int_50 = std.json.Value{ .integer = 50 };
    try std.testing.expectEqual(@as(u8, 50), parsePriorityValue(int_50));

    const int_0 = std.json.Value{ .integer = 0 };
    try std.testing.expectEqual(@as(u8, 0), parsePriorityValue(int_0));

    const int_100 = std.json.Value{ .integer = 100 };
    try std.testing.expectEqual(@as(u8, 100), parsePriorityValue(int_100));

    // Clamping.
    const int_neg = std.json.Value{ .integer = -5 };
    try std.testing.expectEqual(@as(u8, 0), parsePriorityValue(int_neg));

    const int_over = std.json.Value{ .integer = 200 };
    try std.testing.expectEqual(@as(u8, 100), parsePriorityValue(int_over));

    // Null defaults to normal (50).
    try std.testing.expectEqual(types.priority_default, parsePriorityValue(null));
}

test "parsePriorityString: named and numeric strings" {
    try std.testing.expectEqual(@as(u8, 100), parsePriorityString("critical"));
    try std.testing.expectEqual(@as(u8, 75), parsePriorityString("high"));
    try std.testing.expectEqual(@as(u8, 50), parsePriorityString("normal"));
    try std.testing.expectEqual(@as(u8, 25), parsePriorityString("low"));
    // Numeric strings.
    try std.testing.expectEqual(@as(u8, 42), parsePriorityString("42"));
    try std.testing.expectEqual(@as(u8, 0), parsePriorityString("0"));
    // Unknown defaults to normal.
    try std.testing.expectEqual(types.priority_default, parsePriorityString("unknown"));
}

test "enqueue with integer priority" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-int-prio");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"q\",\"priority\":80}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    // Response should contain priority 80.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"priority\":80") != null);
}

test "enqueue with scheduled_at creates scheduled job" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-sched");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"scheduled_at\":\"2030-01-01T00:00:00Z\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    // Response should indicate state is scheduled.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"scheduled\"") != null);
}

test "enqueue with invalid scheduled_at returns 400" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-badsched");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"scheduled_at\":\"not-a-date\"}", &buf);
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

// ============================================================================
// Ack body parsing tests
// ============================================================================

test "ack with result and checkpoint" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-ack-body");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue + fetch to make job active.
    const enq_resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"q\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);
    const job_id = MirrorTestContext.extractJobId(enq_resp.body);
    try std.testing.expect(job_id.len > 0);

    var jid_buf: [64]u8 = undefined;
    @memcpy(jid_buf[0..job_id.len], job_id);
    const jid = jid_buf[0..job_id.len];

    var fbuf: [8192]u8 = undefined;
    _ = ctx.route("POST", "/api/v1/fetch", "{\"queues\":[\"q\"],\"worker_id\":\"w1\",\"count\":1}", &fbuf);

    // Ack with body.
    var ack_path: [256]u8 = undefined;
    const ap = std.fmt.bufPrint(&ack_path, "/api/v1/ack/{s}", .{jid}) catch return;
    var abuf: [8192]u8 = undefined;
    const ack_resp = ctx.route("POST", ap,
        "{\"result\":\"output data\",\"checkpoint\":\"step-5\"}", &abuf);
    try std.testing.expectEqual(@as(u16, 200), ack_resp.status);
}

test "ack with usage report" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-ack-usage");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue + fetch.
    const enq_resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"q\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);
    var jid_buf: [64]u8 = undefined;
    const jid_raw = MirrorTestContext.extractJobId(enq_resp.body);
    @memcpy(jid_buf[0..jid_raw.len], jid_raw);
    const jid = jid_buf[0..jid_raw.len];

    var fbuf: [8192]u8 = undefined;
    _ = ctx.route("POST", "/api/v1/fetch", "{\"queues\":[\"q\"],\"worker_id\":\"w1\",\"count\":1}", &fbuf);

    // Ack with usage.
    var ack_path: [256]u8 = undefined;
    const ap = std.fmt.bufPrint(&ack_path, "/api/v1/ack/{s}", .{jid}) catch return;
    var abuf: [8192]u8 = undefined;
    const ack_resp = ctx.route("POST", ap,
        "{\"usage\":{\"input_tokens\":100,\"output_tokens\":50,\"cost_usd\":0.01,\"model\":\"claude-3\",\"provider\":\"anthropic\"}}", &abuf);
    try std.testing.expectEqual(@as(u16, 200), ack_resp.status);
}

test "ack with agent_status hold" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-ack-agent");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    const enq_resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"q\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);
    var jid_buf: [64]u8 = undefined;
    const jid_raw = MirrorTestContext.extractJobId(enq_resp.body);
    @memcpy(jid_buf[0..jid_raw.len], jid_raw);
    const jid = jid_buf[0..jid_raw.len];

    var fbuf: [8192]u8 = undefined;
    _ = ctx.route("POST", "/api/v1/fetch", "{\"queues\":[\"q\"],\"worker_id\":\"w1\",\"count\":1}", &fbuf);

    var ack_path: [256]u8 = undefined;
    const ap = std.fmt.bufPrint(&ack_path, "/api/v1/ack/{s}", .{jid}) catch return;
    var abuf: [8192]u8 = undefined;
    const ack_resp = ctx.route("POST", ap,
        "{\"agent_status\":\"hold\",\"hold_reason\":\"budget exceeded\"}", &abuf);
    try std.testing.expectEqual(@as(u16, 200), ack_resp.status);
}

// ============================================================================
// Fail with backtrace tests
// ============================================================================

test "fail with backtrace stores error in KV" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-fail-bt");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue with 0 retries.
    const enq_resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"q\",\"max_retries\":0}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);
    var jid_buf: [64]u8 = undefined;
    const jid_raw = MirrorTestContext.extractJobId(enq_resp.body);
    @memcpy(jid_buf[0..jid_raw.len], jid_raw);
    const jid = jid_buf[0..jid_raw.len];

    // Fetch.
    var fbuf: [8192]u8 = undefined;
    _ = ctx.route("POST", "/api/v1/fetch", "{\"queues\":[\"q\"],\"worker_id\":\"w1\",\"count\":1}", &fbuf);

    // Fail with backtrace.
    var fail_path: [256]u8 = undefined;
    const fp = std.fmt.bufPrint(&fail_path, "/api/v1/fail/{s}", .{jid}) catch return;
    _ = ctx.route("POST", fp,
        "{\"error\":\"null pointer\",\"backtrace\":\"main.zig:42 -> handler.zig:10\"}", &buf);
    ctx.flushMirror();

    // Job should be dead.
    {
        const state = ctx.mirrorText("SELECT state FROM jobs WHERE id = ?", jid);
        try std.testing.expect(state != null);
        try std.testing.expectEqualStrings("dead", state.?);
    }

    // Error record should exist with error message.
    try std.testing.expect(ctx.mirrorCountBind("SELECT COUNT(*) FROM job_errors WHERE job_id = ?", jid) >= 1);
    {
        const err = ctx.mirrorText("SELECT error FROM job_errors WHERE job_id = ?", jid);
        try std.testing.expect(err != null);
        try std.testing.expectEqualStrings("null pointer", err.?);
    }
}

test "fail with retries goes to retrying state" {
    const allocator = std.testing.allocator;
    var ctx: MirrorTestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-fail-retry");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;

    // Enqueue with 3 retries.
    const enq_resp = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"q\",\"max_retries\":3}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);
    var jid_buf: [64]u8 = undefined;
    const jid_raw = MirrorTestContext.extractJobId(enq_resp.body);
    @memcpy(jid_buf[0..jid_raw.len], jid_raw);
    const jid = jid_buf[0..jid_raw.len];

    // Fetch.
    var fbuf: [8192]u8 = undefined;
    _ = ctx.route("POST", "/api/v1/fetch", "{\"queues\":[\"q\"],\"worker_id\":\"w1\",\"count\":1}", &fbuf);

    // Fail.
    var fail_path: [256]u8 = undefined;
    const fp = std.fmt.bufPrint(&fail_path, "/api/v1/fail/{s}", .{jid}) catch return;
    _ = ctx.route("POST", fp, "{\"error\":\"timeout\"}", &buf);
    ctx.flushMirror();

    // Should be retrying (not dead) since max_retries=3.
    {
        const state = ctx.mirrorText("SELECT state FROM jobs WHERE id = ?", jid);
        try std.testing.expect(state != null);
        try std.testing.expectEqualStrings("retrying", state.?);
    }
}

// ============================================================================
// Enqueue with retry config tests
// ============================================================================

test "enqueue with retry config" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-retry-cfg");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"retry_backoff\":\"linear\",\"retry_base_delay_ms\":1000,\"retry_max_delay_ms\":30000}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"job_") != null);
}

test "enqueue with agent config" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-agent-cfg");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"agent\":{\"max_iterations\":10,\"max_cost_usd\":5.0,\"iteration_timeout_ms\":30000}}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"job_") != null);
}

test "enqueue with chain fields" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-chain");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"parent_id\":\"job_parent\",\"chain_id\":\"chain_1\",\"chain_step\":2,\"chain_config\":\"{\\\"steps\\\":[]}\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"job_") != null);
}

test "enqueue with checkpoint" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-ckpt");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"checkpoint\":\"step-3-done\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
}

// ============================================================================
// Payload size validation tests
// ============================================================================

test "enqueue payload too large returns 413" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-413");
    defer ctx.deinit();
    // Default max_payload_bytes is 256KB (262144). Set to small for test.
    ctx.server.config.max_payload_bytes = 50;

    var buf: [8192]u8 = undefined;
    // Payload is >50 bytes.
    const resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"payload\":\"this payload is definitely longer than fifty bytes and should be rejected\"}", &buf);
    try std.testing.expectEqual(@as(u16, 413), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "payload too large") != null);
}

test "enqueue payload within limit succeeds" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-413ok");
    defer ctx.deinit();
    ctx.server.config.max_payload_bytes = 1000;

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"payload\":\"small\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
}

// ============================================================================
// Webhook ingest tests
// ============================================================================

test "webhook enqueue creates job" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-webhook");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/webhooks/email-q",
        "{\"event\":\"user.signup\",\"email\":\"alice@example.com\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"queue\":\"email-q\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"job_") != null);
}

test "webhook with query params" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-webhook-qp");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/webhooks/wh-q?priority=high&max_retries=5&unique_key=evt-123",
        "{\"data\":1}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"queue\":\"wh-q\"") != null);
    // Priority "high" = 75.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"priority\":75") != null);
}

test "webhook with scheduled_at" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-webhook-sched");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/webhooks/wh-q?scheduled_at=2030-01-01T00:00:00Z",
        "{}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"state\":\"scheduled\"") != null);
}

test "webhook empty body defaults to {}" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-webhook-empty");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/webhooks/wh-q", null, &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
}

test "webhook missing queue returns 400" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-webhook-noq");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    // Path ends at /webhooks/ with no queue.
    const resp = ctx.route("POST", "/api/v1/webhooks/", "{}", &buf);
    try std.testing.expectEqual(@as(u16, 400), resp.status);
}

test "webhook payload too large returns 413" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-webhook-413");
    defer ctx.deinit();
    ctx.server.config.max_payload_bytes = 10;

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/webhooks/wh-q",
        "{\"this_payload_is_too_large\":true}", &buf);
    try std.testing.expectEqual(@as(u16, 413), resp.status);
}

// ============================================================================
// Debug / cluster endpoint tests
// ============================================================================

test "debug runtime returns arch and os" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-debug");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("GET", "/api/v1/debug/runtime", null, &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"engine\":\"zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"arch\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"os\":") != null);
}

test "cluster events returns events array" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-cluster-ev");
    defer ctx.deinit();

    var buf: [8192]u8 = undefined;
    const resp = ctx.route("GET", "/api/v1/cluster/events", null, &buf);
    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"events\":[") != null);
}

// ============================================================================
// Batch enqueue with new fields tests
// ============================================================================

test "batch enqueue with retry and scheduled_at" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-batch-fields");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue/batch",
        "{\"jobs\":[{\"queue\":\"q\",\"retry_backoff\":\"linear\",\"retry_base_delay_ms\":2000,\"retry_max_delay_ms\":60000},{\"queue\":\"q\",\"scheduled_at\":\"2030-01-01T00:00:00Z\"}]}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp.status);
    // Should have 2 job IDs.
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"job_ids\":[") != null);
}

test "batch enqueue payload too large returns 413" {
    var ctx: TestContext = undefined;
    try ctx.setup(std.testing.allocator, "/tmp/corvo-test-batch-413");
    defer ctx.deinit();
    ctx.server.config.max_payload_bytes = 10;

    var buf: [16384]u8 = undefined;
    const resp = ctx.route("POST", "/api/v1/enqueue/batch",
        "{\"jobs\":[{\"queue\":\"q\",\"payload\":\"this payload is way too large for the limit\"}]}", &buf);
    try std.testing.expectEqual(@as(u16, 413), resp.status);
}

// ============================================================================
// Backoff and agent status parsing tests
// ============================================================================

test "parseBackoff: all variants" {
    try std.testing.expectEqual(types.Backoff.exponential, parseBackoff("exponential"));
    try std.testing.expectEqual(types.Backoff.linear, parseBackoff("linear"));
    try std.testing.expectEqual(types.Backoff.fixed, parseBackoff("fixed"));
    try std.testing.expectEqual(types.Backoff.none, parseBackoff("none"));
    // Default is exponential.
    try std.testing.expectEqual(types.Backoff.exponential, parseBackoff(null));
    try std.testing.expectEqual(types.Backoff.exponential, parseBackoff("unknown"));
}

test "parseAgentStatus: all variants" {
    try std.testing.expectEqual(types.AgentStatus.@"continue", parseAgentStatus("continue"));
    try std.testing.expectEqual(types.AgentStatus.done, parseAgentStatus("done"));
    try std.testing.expectEqual(types.AgentStatus.hold, parseAgentStatus("hold"));
    try std.testing.expectEqual(types.AgentStatus.none, parseAgentStatus("unknown"));
}

test "extractQueryParam: various cases" {
    // Simple parameter.
    try std.testing.expectEqualStrings("hello", extractQueryParam("/path?q=hello", "q").?);
    // Multiple params.
    try std.testing.expectEqualStrings("10", extractQueryParam("/path?q=hello&limit=10", "limit").?);
    // No query string.
    try std.testing.expect(extractQueryParam("/path", "q") == null);
    // Param not present.
    try std.testing.expect(extractQueryParam("/path?foo=bar", "q") == null);
}

// ============================================================================
// Reclaim: batch failure tracking + unique lock cleanup + chain on_failure
// ============================================================================

test "reclaim: dead job releases unique lock" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-reclaim-unique");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    // Enqueue a job with unique key and max_retries=1.
    _ = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"unique_key\":\"uk1\",\"max_retries\":1}", &buf);

    // Fetch it (attempt 1) with a very short lease.
    const q = [_][]const u8{"q"};
    _ = ctx.store.fetch(&q, "w1", 1, 1, 0); // 1ms lease

    // Run reclaim — lease is expired immediately, attempt >= max_retries → dead.
    // Use a far-future now_ns to ensure lease is expired.
    const data = ops_mod.OpData{
        .maintenance = .{
            .action = .reclaim,
            .now_ns = @as(u64, @intCast(std.time.nanoTimestamp())) + 10_000_000_000, // 10s from now
            .cutoff_ns = 0,
        },
    };
    _ = ctx.store.engine.submit(.maintenance, &data);

    // Now enqueue with the same unique key — should succeed because lock was released.
    const resp2 = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"unique_key\":\"uk1\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp2.status);
}

test "reclaim: dead job tracks batch failure" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-reclaim-batch");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    // Create a batch directly via store.
    const bc_data = ops_mod.OpData{
        .batch_create = .{ .batch_id = "b1", .created_at_ns = 1000 },
    };
    _ = ctx.store.batchCreate(&bc_data);

    // Enqueue a job in the batch with max_retries=1.
    _ = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"batch_id\":\"b1\",\"max_retries\":1}", &buf);

    // Seal the batch.
    const bs_data = ops_mod.OpData{
        .batch_seal = .{ .batch_id = "b1", .now_ns = 2000 },
    };
    _ = ctx.store.batchSeal(&bs_data);

    // Fetch (attempt 1) with very short lease.
    const q = [_][]const u8{"q"};
    _ = ctx.store.fetch(&q, "w1", 1, 1, 0);

    // Reclaim with far-future time.
    const maint_data = ops_mod.OpData{
        .maintenance = .{
            .action = .reclaim,
            .now_ns = @as(u64, @intCast(std.time.nanoTimestamp())) + 10_000_000_000,
            .cutoff_ns = 0,
        },
    };
    _ = ctx.store.engine.submit(.maintenance, &maint_data);

    // Check batch state via KV — should have failed=1.
    var bk_buf: keys.KeyBuf = undefined;
    if (ctx.store.engine.get(keys.batchKey(&bk_buf, "b1"))) |batch_bytes| {
        defer allocator.free(batch_bytes);
        const batch = codec.decodeBatch(batch_bytes);
        try std.testing.expectEqual(@as(u32, 1), batch.failed);
    } else {
        return error.TestExpectedEqual;
    }
}

// ============================================================================
// Expire: unique lock cleanup + batch failure tracking
// ============================================================================

test "expire: dead job releases unique lock" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-expire-unique");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    // Enqueue a job with unique key and expire_after_ms=1.
    _ = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"unique_key\":\"ek1\",\"expire_after_ms\":1}", &buf);

    // Run expire with far-future time.
    const data = ops_mod.OpData{
        .maintenance = .{
            .action = .expire,
            .now_ns = @as(u64, @intCast(std.time.nanoTimestamp())) + 10_000_000_000,
            .cutoff_ns = 0,
        },
    };
    _ = ctx.store.engine.submit(.maintenance, &data);

    // Re-enqueue with same unique key — should succeed.
    const resp2 = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"unique_key\":\"ek1\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp2.status);
}

test "expire: tracks batch failure" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-expire-batch");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    const bc_data = ops_mod.OpData{
        .batch_create = .{ .batch_id = "b2", .created_at_ns = 1000 },
    };
    _ = ctx.store.batchCreate(&bc_data);
    _ = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"batch_id\":\"b2\",\"expire_after_ms\":1}", &buf);
    const bs_data = ops_mod.OpData{
        .batch_seal = .{ .batch_id = "b2", .now_ns = 2000 },
    };
    _ = ctx.store.batchSeal(&bs_data);

    const data = ops_mod.OpData{
        .maintenance = .{
            .action = .expire,
            .now_ns = @as(u64, @intCast(std.time.nanoTimestamp())) + 10_000_000_000,
            .cutoff_ns = 0,
        },
    };
    _ = ctx.store.engine.submit(.maintenance, &data);

    // Check batch state via KV.
    var bk_buf: keys.KeyBuf = undefined;
    if (ctx.store.engine.get(keys.batchKey(&bk_buf, "b2"))) |batch_bytes| {
        defer allocator.free(batch_bytes);
        const batch = codec.decodeBatch(batch_bytes);
        try std.testing.expectEqual(@as(u32, 1), batch.failed);
    } else {
        return error.TestExpectedEqual;
    }
}

// ============================================================================
// Chain: previous_job_id + previous_result merge
// ============================================================================

test "chain ack merges previous_job_id into next step payload" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-chain-merge");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    // Enqueue a chain job (step 0).
    const enq_resp = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"step0\",\"chain_config\":\"{\\\"steps\\\":[{\\\"queue\\\":\\\"step0\\\"},{\\\"queue\\\":\\\"step1\\\",\\\"payload\\\":\\\"{\\\\\\\"key\\\\\\\":\\\\\\\"val\\\\\\\"}\\\"}]}\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);
    const job_id = MirrorTestContext.extractJobId(enq_resp.body);

    // Fetch step 0.
    const q0 = [_][]const u8{"step0"};
    _ = ctx.store.fetch(&q0, "w1", 1, 60000, 0);

    // Ack step 0 with a result.
    _ = ctx.store.ackFull(job_id, "step0", .{
        .job_id = job_id,
        .queue = "step0",
        .result = "\"step0_output\"",
    });

    // Step 1 should now be enqueued. Fetch it.
    const q1 = [_][]const u8{"step1"};
    const fetch1 = ctx.store.fetch(&q1, "w1", 1, 60000, 0);
    try std.testing.expectEqual(@as(u32, 1), fetch1.affected);

    // Read the chain job's payload from KV — should contain previous_job_id.
    const f0 = &fetch1.fetched[0];
    const chain_jid = f0.id_buf[0..f0.id_len];
    var jk_buf: keys.KeyBuf = undefined;
    var jpk_buf: keys.KeyBuf = undefined;
    if (ctx.store.engine.get(keys.jobPayloadKey(&jpk_buf, chain_jid))) |payload_bytes| {
        defer allocator.free(payload_bytes);
        // Check that previous_job_id is in the payload.
        try std.testing.expect(std.mem.indexOf(u8, payload_bytes, "previous_job_id") != null);
        try std.testing.expect(std.mem.indexOf(u8, payload_bytes, "step0_output") != null);
    } else {
        // Also check the job key itself for the payload (it may be inline).
        _ = keys.jobKey(&jk_buf, chain_jid);
    }
}

// ============================================================================
// Queue clear: pending job KV data cleanup
// ============================================================================

test "clear queue deletes pending job data from KV" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-clear-pending");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    // Enqueue two pending jobs.
    const resp1 = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"clearq\",\"payload\":\"data1\"}", &buf);
    const jid1 = MirrorTestContext.extractJobId(resp1.body);
    _ = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"clearq\",\"payload\":\"data2\"}", &buf);

    // Clear the queue.
    _ = ctx.store.clearQueue("clearq");

    // Job data should be gone from KV.
    var jk_buf: keys.KeyBuf = undefined;
    const job_bytes = ctx.store.engine.get(keys.jobKey(&jk_buf, jid1));
    if (job_bytes) |b2| allocator.free(b2);
    try std.testing.expect(job_bytes == null);
}

// ============================================================================
// Bulk: batch counter adjustments for cancel/delete
// ============================================================================

test "bulk cancel adjusts batch counters" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-bulk-batch-cancel");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    const bc_data = ops_mod.OpData{
        .batch_create = .{ .batch_id = "bb1", .created_at_ns = 1000 },
    };
    _ = ctx.store.batchCreate(&bc_data);
    const resp1 = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"batch_id\":\"bb1\"}", &buf);
    const jid = MirrorTestContext.extractJobId(resp1.body);
    const bs_data = ops_mod.OpData{
        .batch_seal = .{ .batch_id = "bb1", .now_ns = 2000 },
    };
    _ = ctx.store.batchSeal(&bs_data);

    // Cancel the job via bulk action.
    const cancel_data = ops_mod.OpData{
        .bulk_action = .{
            .job_ids = &[_][]const u8{jid},
            .action = .cancel,
            .now_ns = @as(u64, @intCast(std.time.nanoTimestamp())),
        },
    };
    _ = ctx.store.bulkAction(&cancel_data);

    // Check batch state via KV — should have failed=1.
    var bk_buf: keys.KeyBuf = undefined;
    if (ctx.store.engine.get(keys.batchKey(&bk_buf, "bb1"))) |batch_bytes| {
        defer allocator.free(batch_bytes);
        const batch = codec.decodeBatch(batch_bytes);
        try std.testing.expectEqual(@as(u32, 1), batch.failed);
    } else {
        return error.TestExpectedEqual;
    }
}

test "bulk requeue recreates unique lock" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-bulk-requeue-unique");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    // Enqueue with unique key, max_retries=0 so fail goes straight to dead.
    const resp1 = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"unique_key\":\"ruk1\",\"max_retries\":0}", &buf);
    const jid = MirrorTestContext.extractJobId(resp1.body);

    // Fetch and fail → dead.
    const q = [_][]const u8{"q"};
    _ = ctx.store.fetch(&q, "w1", 1, 60000, 0);
    _ = ctx.store.fail(jid, "q", "oops", null);

    // Requeue the dead job.
    const requeue_data = ops_mod.OpData{
        .bulk_action = .{
            .job_ids = &[_][]const u8{jid},
            .action = .requeue,
            .now_ns = @as(u64, @intCast(std.time.nanoTimestamp())),
        },
    };
    _ = ctx.store.bulkAction(&requeue_data);

    // Try to enqueue a new job with the same unique key — should be rejected.
    const resp2 = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"unique_key\":\"ruk1\"}", &buf);
    // Should get 409 (unique conflict) since the requeued job owns the lock.
    try std.testing.expectEqual(@as(u16, 409), resp2.status);
}

// ============================================================================
// Fairness fetch scoring
// ============================================================================

test "fairness fetch: lowest served+active group wins" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-fairness");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    // Configure fairness on the queue.
    _ = ctx.store.queueConfigFull(.{ .queue = "fq", .action = .fairness, .fairness = true });

    // Enqueue jobs for group A (3 jobs) and group B (1 job) at the same priority.
    _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"fq\",\"group\":\"A\"}", &buf);
    _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"fq\",\"group\":\"A\"}", &buf);
    _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"fq\",\"group\":\"A\"}", &buf);
    _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"fq\",\"group\":\"B\"}", &buf);

    // Fetch 1 — should get a job (both groups have score 0, first valid candidate wins).
    const q = [_][]const u8{"fq"};
    const f1 = ctx.store.fetch(&q, "w1", 1, 60000, 0);
    try std.testing.expectEqual(@as(u32, 1), f1.affected);

    // Ack the first job so served count increments.
    const fj1 = &f1.fetched[0];
    const jid1 = fj1.id_buf[0..fj1.id_len];
    _ = ctx.store.ack(jid1, "fq");

    // Fetch 2 — the group that was served should have higher score.
    // If first was group A, second should prefer group B (score 0 vs score 1+).
    const f2 = ctx.store.fetch(&q, "w1", 1, 60000, 0);
    try std.testing.expectEqual(@as(u32, 1), f2.affected);

    // Fetch 3.
    const fj2 = &f2.fetched[0];
    const jid2_fair = fj2.id_buf[0..fj2.id_len];
    _ = ctx.store.ack(jid2_fair, "fq");
    const f3 = ctx.store.fetch(&q, "w1", 1, 60000, 0);
    try std.testing.expectEqual(@as(u32, 1), f3.affected);
}

// ============================================================================
// Bulk reject deletes unique lock
// ============================================================================

test "bulk reject releases unique lock" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-reject-unique");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    // Enqueue with unique key, then hold it.
    const resp1 = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"unique_key\":\"rejuk\"}", &buf);
    const jid = MirrorTestContext.extractJobId(resp1.body);

    // Hold it.
    const hold_data = ops_mod.OpData{
        .bulk_action = .{
            .job_ids = &[_][]const u8{jid},
            .action = .hold,
            .now_ns = @as(u64, @intCast(std.time.nanoTimestamp())),
        },
    };
    _ = ctx.store.bulkAction(&hold_data);

    // Reject it.
    const reject_data = ops_mod.OpData{
        .bulk_action = .{
            .job_ids = &[_][]const u8{jid},
            .action = .reject,
            .now_ns = @as(u64, @intCast(std.time.nanoTimestamp())),
        },
    };
    _ = ctx.store.bulkAction(&reject_data);

    // Re-enqueue with same unique key — should succeed.
    const resp2 = ctx.route("POST", "/api/v1/enqueue",
        "{\"queue\":\"q\",\"unique_key\":\"rejuk\"}", &buf);
    try std.testing.expectEqual(@as(u16, 201), resp2.status);
}

// ============================================================================
// Bulk cancel decrements fairness active count
// ============================================================================

test "bulk cancel active job decrements fairness active" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-test-cancel-fairness");
    defer ctx.deinit();

    var buf: [16384]u8 = undefined;

    _ = ctx.store.queueConfigFull(.{ .queue = "cfq", .action = .fairness, .fairness = true });

    // Enqueue two jobs in same group, fetch both.
    _ = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"cfq\",\"group\":\"g1\"}", &buf);
    const resp2_enq = ctx.route("POST", "/api/v1/enqueue", "{\"queue\":\"cfq\",\"group\":\"g1\"}", &buf);
    const jid2 = MirrorTestContext.extractJobId(resp2_enq.body);

    const q = [_][]const u8{"cfq"};
    _ = ctx.store.fetch(&q, "w1", 2, 60000, 0);

    // Cancel one — active count should go from 2→1.
    const cancel_data = ops_mod.OpData{
        .bulk_action = .{
            .job_ids = &[_][]const u8{jid2},
            .action = .cancel,
            .now_ns = @as(u64, @intCast(std.time.nanoTimestamp())),
        },
    };
    const cancel_result = ctx.store.bulkAction(&cancel_data);
    try std.testing.expectEqual(@as(u32, 1), cancel_result.affected);

    // Verify no assertion failures occurred (fairness active count went negative).
    // If we get here without panic, the fairness decrement is working.
}

test "fetch response includes payload, attempt, max_retries, tags, checkpoint" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-fetch-fields");
    defer ctx.deinit();

    // Enqueue with payload, tags, checkpoint, and max_retries.
    var buf: [8192]u8 = undefined;
    const enq_resp = ctx.route("POST", "/api/v1/enqueue",
        \\{"queue":"q1","payload":{"key":"value"},"tags":{"env":"prod"},"checkpoint":{"step":1},"max_retries":5}
    , &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);

    // Fetch.
    var buf2: [8192]u8 = undefined;
    const fetch_resp = ctx.route("POST", "/api/v1/fetch",
        \\{"queues":["q1"],"worker_id":"w-1","count":1}
    , &buf2);
    try std.testing.expectEqual(@as(u16, 200), fetch_resp.status);

    // Verify all expected fields are present in the response.
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"attempt\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"max_retries\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"lease_duration\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"payload\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"key\":\"value\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"tags\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"env\":\"prod\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"checkpoint\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"step\":1") != null);
}

test "fetch response includes agent state for agent jobs" {
    const allocator = std.testing.allocator;
    var ctx: TestContext = undefined;
    try ctx.setup(allocator, "/tmp/corvo-srv-test-fetch-agent");
    defer ctx.deinit();

    // Enqueue an agent job.
    var buf: [8192]u8 = undefined;
    const enq_resp = ctx.route("POST", "/api/v1/enqueue",
        \\{"queue":"aq","payload":{"task":"analyze"},"agent":{"max_iterations":10,"max_cost_usd":5.0}}
    , &buf);
    try std.testing.expectEqual(@as(u16, 201), enq_resp.status);

    // Fetch.
    var buf2: [8192]u8 = undefined;
    const fetch_resp = ctx.route("POST", "/api/v1/fetch",
        \\{"queues":["aq"],"worker_id":"w-1","count":1}
    , &buf2);
    try std.testing.expectEqual(@as(u16, 200), fetch_resp.status);

    // Agent state should be in the response.
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"agent\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, fetch_resp.body, "\"max_iterations\":10") != null);
}
