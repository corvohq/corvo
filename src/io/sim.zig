//! Deterministic IO backend for the simulator.
//!
//! Same interface as UringBackend / KqueueBackend, but with no kernel IO.
//! The simulator drives the pipeline by injecting fake completions:
//!
//!   1. sim calls connect()     → allocates a virtual connection
//!   2. sim calls injectRecv()  → writes data into recv_buf, stages recv completion
//!   3. pipeline calls drain()  → returns staged completions
//!   4. pipeline processes them  (decode → apply → commit → mirror → encode)
//!   5. pipeline calls queueSend() → marks send pending
//!   6. pipeline calls submit() → stages send_done completions
//!   7. sim reads response from send_buf
//!
//! This is the same pattern TigerBeetle uses for deterministic simulation.
//! All pipeline stages are pure — only drain() is non-deterministic in
//! production. SimBackend makes drain() deterministic.

const std = @import("std");
const assert = @import("../assert.zig");
const io = @import("../io.zig");
const Completion = io.Completion;
const ConnState = io.ConnState;
const Config = io.Config;
const Allocator = std.mem.Allocator;

pub const SimBackend = struct {
    conns: []ConnState,
    max_conns: u16,
    buf_mem: []u8,

    // Free list for connection slots (stack, O(1) alloc/free)
    free_list: []u16,
    free_count: u16,

    // Staged completions — sim pushes, drain() pops
    completions: [max_staged]Completion = undefined,
    completion_count: u32 = 0,

    // Pending sends — submit() converts these to send_done completions
    pending_sends: [max_staged]u16 = undefined,
    pending_send_count: u32 = 0,

    const max_staged = 256;

    // ========================================================================
    // Lifecycle (matches UringBackend interface)
    // ========================================================================

    pub fn init(allocator: Allocator, config: Config) !SimBackend {
        const max: u16 = config.max_conns;
        assert.check(max > 0, "SimBackend.init: max_conns must be > 0", .{});

        // Allocate connection state array
        const conns = try allocator.alloc(ConnState, max);
        errdefer allocator.free(conns);

        // Allocate all buffers in a single contiguous block
        const per_conn = config.recv_buf_size + config.send_buf_size;
        const total_buf = @as(usize, per_conn) * @as(usize, max);
        const buf_mem = try allocator.alloc(u8, total_buf);
        errdefer allocator.free(buf_mem);

        // Initialize each connection slot with its buffer slices
        for (conns, 0..) |*c, i| {
            const base = i * per_conn;
            c.* = ConnState{
                .recv_buf = buf_mem[base..][0..config.recv_buf_size],
                .send_buf = buf_mem[base + config.recv_buf_size ..][0..config.send_buf_size],
            };
        }

        // Build free list (all slots free initially)
        const free_list = try allocator.alloc(u16, max);
        errdefer allocator.free(free_list);
        for (free_list, 0..) |*slot, i| {
            slot.* = @intCast(max - 1 - i);
        }

        return SimBackend{
            .conns = conns,
            .max_conns = max,
            .buf_mem = buf_mem,
            .free_list = free_list,
            .free_count = max,
        };
    }

    pub fn deinit(self: *SimBackend, allocator: Allocator) void {
        allocator.free(self.free_list);
        allocator.free(self.buf_mem);
        allocator.free(self.conns);
    }

    // ========================================================================
    // IO interface (matches UringBackend)
    // ========================================================================

    /// Return staged completions. Non-blocking — returns 0 if nothing staged.
    pub fn drain(self: *SimBackend, out: []Completion) u32 {
        const n = @min(self.completion_count, @as(u32, @intCast(out.len)));
        if (n == 0) return 0;

        @memcpy(out[0..n], self.completions[0..n]);

        // Shift remaining completions down
        const remaining = self.completion_count - n;
        if (remaining > 0) {
            std.mem.copyForwards(
                Completion,
                self.completions[0..remaining],
                self.completions[n..self.completion_count],
            );
        }
        self.completion_count = remaining;
        return n;
    }

    /// Mark a send as pending. submit() will convert to send_done completion.
    pub fn queueSend(self: *SimBackend, conn_id: u16, len: u32) void {
        assert.check(conn_id < self.max_conns, "SimBackend.queueSend: conn_id out of range", .{});
        const c = &self.conns[conn_id];
        assert.check(c.phase != .free, "SimBackend.queueSend: conn is free", .{});
        assert.check(len > 0 and len <= c.send_buf.len, "SimBackend.queueSend: bad len", .{});

        c.send_pos = 0;
        c.send_len = len;
        c.phase = .send_pending;

        // Stage for submit()
        assert.check(self.pending_send_count < max_staged, "SimBackend: too many pending sends", .{});
        self.pending_sends[self.pending_send_count] = conn_id;
        self.pending_send_count += 1;
    }

    /// No-op for sim — recv is injected explicitly via injectRecv().
    pub fn queueRecv(self: *SimBackend, conn_id: u16) void {
        _ = self;
        _ = conn_id;
    }

    /// No-op for sim — connections are created explicitly via connect().
    pub fn queueAccept(self: *SimBackend) void {
        _ = self;
    }

    /// Close a connection and free its slot.
    pub fn queueClose(self: *SimBackend, conn_id: u16) void {
        assert.check(conn_id < self.max_conns, "SimBackend.queueClose: conn_id out of range", .{});
        self.closeConn(conn_id);
    }

    /// Process pending sends — convert to send_done completions.
    pub fn submit(self: *SimBackend) void {
        for (self.pending_sends[0..self.pending_send_count]) |conn_id| {
            const c = &self.conns[conn_id];
            if (c.phase == .free) continue;

            // Simulate instant send completion
            c.send_pos = c.send_len;
            c.phase = .ready;

            self.stageCompletion(.{ .conn_id = conn_id, .event = .send_done });
        }
        self.pending_send_count = 0;
    }

    /// Access connection state by id.
    pub fn conn(self: *SimBackend, id: u16) *ConnState {
        assert.check(id < self.max_conns, "SimBackend.conn: id out of range", .{});
        return &self.conns[id];
    }

    // ========================================================================
    // Sim control methods (not in UringBackend)
    // ========================================================================

    /// Create a virtual connection. Returns conn_id, or null if no slots.
    pub fn connect(self: *SimBackend) ?u16 {
        const id = self.allocConn() orelse return null;
        const c = &self.conns[id];
        c.fd = 0; // Fake fd — no real socket
        c.phase = .ready;
        return id;
    }

    /// Inject data into a connection's recv_buf and stage a recv completion.
    /// The pipeline will see this as incoming network data on the next drain().
    pub fn injectRecv(self: *SimBackend, conn_id: u16, data: []const u8) void {
        assert.check(conn_id < self.max_conns, "SimBackend.injectRecv: conn_id out of range", .{});
        const c = &self.conns[conn_id];
        assert.check(c.phase != .free, "SimBackend.injectRecv: conn is free", .{});

        const space = c.recv_buf.len - c.recv_pos;
        assert.check(data.len <= space, "SimBackend.injectRecv: data exceeds recv_buf space", .{});

        @memcpy(c.recv_buf[c.recv_pos..][0..data.len], data);
        c.recv_pos += @intCast(data.len);

        self.stageCompletion(.{ .conn_id = conn_id, .event = .recv });
    }

    /// Disconnect a virtual connection. Stages a closed completion.
    pub fn disconnect(self: *SimBackend, conn_id: u16) void {
        assert.check(conn_id < self.max_conns, "SimBackend.disconnect: conn_id out of range", .{});
        self.stageCompletion(.{ .conn_id = conn_id, .event = .closed });
        self.closeConn(conn_id);
    }

    /// Read the response data from a connection's send_buf after a pipeline cycle.
    /// Returns the response bytes, or null if no send data.
    pub fn readResponse(self: *SimBackend, conn_id: u16) ?[]const u8 {
        assert.check(conn_id < self.max_conns, "SimBackend.readResponse: conn_id out of range", .{});
        const c = &self.conns[conn_id];
        if (c.send_len == 0) return null;
        const data = c.send_buf[0..c.send_len];
        // Reset send state for next cycle
        c.send_pos = 0;
        c.send_len = 0;
        return data;
    }

    // ========================================================================
    // Internal helpers
    // ========================================================================

    fn stageCompletion(self: *SimBackend, completion: Completion) void {
        assert.check(self.completion_count < max_staged, "SimBackend: completion overflow", .{});
        self.completions[self.completion_count] = completion;
        self.completion_count += 1;
    }

    fn allocConn(self: *SimBackend) ?u16 {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        return self.free_list[self.free_count];
    }

    fn freeConn(self: *SimBackend, conn_id: u16) void {
        assert.check(self.free_count < self.max_conns, "SimBackend.freeConn: free_list overflow", .{});
        self.free_list[self.free_count] = conn_id;
        self.free_count += 1;
    }

    fn closeConn(self: *SimBackend, conn_id: u16) void {
        const c = &self.conns[conn_id];
        if (c.phase == .free) return;
        c.reset();
        self.freeConn(conn_id);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "SimBackend: init and connect" {
    const allocator = std.testing.allocator;
    var backend = try SimBackend.init(allocator, .{
        .listen_fd = -1,
        .max_conns = 8,
        .recv_buf_size = 1024,
        .send_buf_size = 1024,
    });
    defer backend.deinit(allocator);

    const id = backend.connect().?;
    const c = backend.conn(id);
    try std.testing.expect(c.phase == .ready);
    try std.testing.expectEqual(@as(usize, 1024), c.recv_buf.len);
    try std.testing.expectEqual(@as(usize, 1024), c.send_buf.len);
}

test "SimBackend: injectRecv and drain" {
    const allocator = std.testing.allocator;
    var backend = try SimBackend.init(allocator, .{
        .listen_fd = -1,
        .max_conns = 8,
        .recv_buf_size = 1024,
        .send_buf_size = 1024,
    });
    defer backend.deinit(allocator);

    const id = backend.connect().?;

    // Inject data
    backend.injectRecv(id, "hello");
    try std.testing.expectEqual(@as(u32, 5), backend.conn(id).recv_pos);

    // Drain should return the recv completion
    var completions: [8]Completion = undefined;
    const n = backend.drain(&completions);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(id, completions[0].conn_id);
    try std.testing.expect(completions[0].event == .recv);

    // Second drain returns nothing
    try std.testing.expectEqual(@as(u32, 0), backend.drain(&completions));
}

test "SimBackend: queueSend and submit" {
    const allocator = std.testing.allocator;
    var backend = try SimBackend.init(allocator, .{
        .listen_fd = -1,
        .max_conns = 8,
        .recv_buf_size = 1024,
        .send_buf_size = 1024,
    });
    defer backend.deinit(allocator);

    const id = backend.connect().?;
    const c = backend.conn(id);

    // Write response data into send_buf
    @memcpy(c.send_buf[0..5], "world");
    backend.queueSend(id, 5);

    // submit() should stage a send_done completion
    backend.submit();

    var completions: [8]Completion = undefined;
    const n = backend.drain(&completions);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(id, completions[0].conn_id);
    try std.testing.expect(completions[0].event == .send_done);
}

test "SimBackend: connect exhaustion" {
    const allocator = std.testing.allocator;
    var backend = try SimBackend.init(allocator, .{
        .listen_fd = -1,
        .max_conns = 2,
        .recv_buf_size = 64,
        .send_buf_size = 64,
    });
    defer backend.deinit(allocator);

    const id1 = backend.connect();
    const id2 = backend.connect();
    const id3 = backend.connect(); // should be null

    try std.testing.expect(id1 != null);
    try std.testing.expect(id2 != null);
    try std.testing.expect(id3 == null);

    // Disconnect frees a slot
    backend.disconnect(id1.?);
    const id4 = backend.connect();
    try std.testing.expect(id4 != null);
}

test "SimBackend: readResponse" {
    const allocator = std.testing.allocator;
    var backend = try SimBackend.init(allocator, .{
        .listen_fd = -1,
        .max_conns = 4,
        .recv_buf_size = 256,
        .send_buf_size = 256,
    });
    defer backend.deinit(allocator);

    const id = backend.connect().?;
    const c = backend.conn(id);

    // No response yet
    try std.testing.expect(backend.readResponse(id) == null);

    // Simulate pipeline writing response
    @memcpy(c.send_buf[0..3], "OK!");
    backend.queueSend(id, 3);
    backend.submit();

    // Read response
    const resp = backend.readResponse(id).?;
    try std.testing.expectEqualStrings("OK!", resp);

    // Response consumed
    try std.testing.expect(backend.readResponse(id) == null);
}
