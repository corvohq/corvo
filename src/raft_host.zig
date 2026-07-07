//! raft_host.zig — thread-owning wrapper around `Runtime` + `PeerNet`.
//!
//! Why a dedicated thread:
//!   The pipeline thread (the client-traffic hot path) cannot tick raft: its
//!   `io.drain()` blocks until a client CQE arrives. Under idle traffic, raft
//!   heartbeats would not fire and elections would storm. The legacy
//!   `cluster.zig` already uses this pattern — `tick_thread` ticks election +
//!   replicator on a dedicated thread, and the pipeline syncs via an atomic
//!   `last_acked_seq`. RaftHost mirrors that for raft.
//!
//! Threading model
//!   - One dedicated raft thread runs `tickLoop`. It owns Runtime + PeerNet
//!     exclusively. No other thread calls into either.
//!   - Pipeline thread enqueues proposals via `proposeAsync` (mutex-guarded
//!     ring) and polls `lastCommittedIndex` / `isLeader` (atomic).
//!   - Each proposal returns a `*ProposeToken` whose `state` atomic is set
//!     by the raft-thread-side completion callback. Pipeline polls the token
//!     and `releaseToken`s when done.
//!
//! Lifecycle
//!   - `init` allocates the host on the heap (Runtime + PeerNet take stable
//!     pointers into it via `pn.install(&runtime.transport)`).
//!   - `start` spawns the tick thread.
//!   - `stop` clears the running flag and joins; safe to call repeatedly.
//!   - `deinit` calls stop, drains the inbox, and tears down components.
//!
//! TigerStyle: bounded inbox (`max_inbox`), per-entry arena for mutation
//! deep-copy, exhaustive switches in callbacks, no allocations on the
//! tick hot path beyond the inbox arenas (which are caller-budget).

const std = @import("std");
const builtin = @import("builtin");
const net = std.net;
const Allocator = std.mem.Allocator;
const assert_mod = @import("assert.zig");
const check = assert_mod.check;
const talon = @import("talon");
const raft = @import("raft");

const Runtime = @import("raft_runtime.zig").Runtime;
const InitParams = @import("raft_runtime.zig").InitParams;
const PeerNet = @import("raft_net.zig").PeerNet;
const PeerNetConfig = @import("raft_net.zig").Config;
const Mutation = @import("kv.zig").Mutation;
const Completion = @import("raft_batcher.zig").Completion;

// ============================================================================
// Configuration
// ============================================================================

/// Bounded proposal inbox between pipeline thread and raft thread.
/// Pipeline-side back-pressure if the raft thread can't keep up.
pub const max_inbox: usize = 4096;

/// How long the raft thread sleeps between ticks. Must be well below the
/// heartbeat interval so heartbeats fire on schedule. Heartbeat default
/// is 50 ms, so 5 ms gives 10× headroom.
pub const default_tick_interval_ns: u64 = 5_000_000;

pub const HostError = error{
    InboxFull,
    AlreadyStarted,
    NotStarted,
    OutOfMemory,
};

// ============================================================================
// ProposeToken — the pipeline-facing handle for an in-flight proposal.
// ============================================================================

pub const TokenState = enum(u8) { pending = 0, committed = 1, failed = 2 };

pub const ProposeToken = struct {
    state: std.atomic.Value(u8) align(64) = .init(@intFromEnum(TokenState.pending)),

    pub fn loadState(self: *const ProposeToken) TokenState {
        return @enumFromInt(self.state.load(.acquire));
    }
};

// ============================================================================
// Inbox entry — owned by host between proposeAsync() and the raft thread's
// drainInbox(). Each entry carries a per-entry arena that backs the deep-
// copied Mutations + their key/value bytes.
// ============================================================================

const InboxEntry = struct {
    arena: std.heap.ArenaAllocator,
    mutations: []Mutation,
    token: *ProposeToken,
};

// ============================================================================
// RaftHost
// ============================================================================

pub const RaftHost = struct {
    allocator: Allocator,

    runtime: Runtime,
    peer_net: PeerNet,

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = .init(false),
    started: bool = false,

    // Inbox: pipeline → raft. Mutex-protected ring buffer.
    inbox: [max_inbox]?InboxEntry = .{null} ** max_inbox,
    inbox_head: usize = 0,
    inbox_tail: usize = 0,
    inbox_count: usize = 0,
    inbox_mu: std.Thread.Mutex = .{},

    // Active set: entries pulled from the inbox this tick. Their arenas
    // back the mutation slices that batcher.enqueue captures, and must
    // outlive batcher.flush — which runs during runtime.tick later in
    // the same doOneTick. Cleared at end-of-tick.
    active: [max_inbox]?InboxEntry = .{null} ** max_inbox,
    active_count: usize = 0,

    // Atomics for pipeline thread to poll.
    last_committed_index: std.atomic.Value(u64) align(64) = .init(0),
    is_leader: std.atomic.Value(bool) align(64) = .init(false),

    // Drop counters — observable for tests + metrics.
    drops_inbox_full: std.atomic.Value(u64) = .init(0),
    drops_not_leader: std.atomic.Value(u64) = .init(0),
    // Recoverable tick errors (backpressure, transient encode/OOM). Counted so
    // operators can alert on a persistently-failing node without the process
    // crashing on a single transient hiccup.
    tick_errors: std.atomic.Value(u64) = .init(0),

    tick_interval_ns: u64 = default_tick_interval_ns,

    pub const HostInitParams = struct {
        runtime: InitParams,
        peer_net: PeerNetConfig,
        tick_interval_ns: u64 = default_tick_interval_ns,
    };

    /// Heap-allocate a RaftHost. Returns a pointer because Runtime + PeerNet
    /// hold stable interior pointers (`pn.install(&runtime.transport)`).
    pub fn create(allocator: Allocator, db: *talon.DB, params: HostInitParams) !*RaftHost {
        const self = try allocator.create(RaftHost);
        errdefer allocator.destroy(self);

        var rt = try Runtime.init(allocator, db, params.runtime);
        errdefer rt.deinit();
        var pn = try PeerNet.init(allocator, params.peer_net);
        errdefer pn.deinit();

        self.* = .{
            .allocator = allocator,
            .runtime = rt,
            .peer_net = pn,
            .tick_interval_ns = params.tick_interval_ns,
        };
        // Wire the transport's send hook to PeerNet.
        self.peer_net.install(&self.runtime.transport);
        // Seed leader-state atomic from initial role (typically follower).
        self.is_leader.store(self.runtime.node.isLeader(), .release);
        return self;
    }

    pub fn destroy(self: *RaftHost) void {
        self.stop();
        self.drainInboxOnShutdown();
        self.peer_net.deinit();
        self.runtime.deinit();
        const a = self.allocator;
        a.destroy(self);
    }

    /// Register a peer with the underlying PeerNet. Must be called before
    /// `start` (registering peers from a different thread is not supported).
    pub fn registerPeer(self: *RaftHost, id: []const u8, addr: net.Address) !void {
        check(!self.started, "registerPeer after start", .{});
        try self.peer_net.registerPeer(id, addr);
    }

    /// The TCP address PeerNet is bound to. Useful for tests + cluster
    /// discovery (callers learn each other's bound port after init).
    pub fn boundAddress(self: *const RaftHost) net.Address {
        return self.peer_net.boundAddress();
    }

    pub fn start(self: *RaftHost) !void {
        if (self.started) return HostError.AlreadyStarted;
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, tickLoop, .{self});
        self.started = true;
    }

    pub fn stop(self: *RaftHost) void {
        if (!self.started) return;
        self.running.store(false, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.started = false;
    }

    // ------------------------------------------------------------------------
    // Pipeline-thread API
    // ------------------------------------------------------------------------

    /// Enqueue a proposal for the raft thread. Mutations + their byte data
    /// are deep-copied into a per-entry arena, so the caller can free or
    /// reuse the input slices immediately on return.
    /// On success, returns a token whose state will be flipped by the raft
    /// thread once the entry commits or fails. Caller owns the token until
    /// `releaseToken`.
    pub fn proposeAsync(self: *RaftHost, mutations: []const Mutation) !*ProposeToken {
        const token = try self.allocator.create(ProposeToken);
        errdefer self.allocator.destroy(token);
        token.* = .{};

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const muts_copy = try a.alloc(Mutation, mutations.len);
        for (mutations, muts_copy) |src, *dst| {
            const k = try a.alloc(u8, src.key.len);
            @memcpy(k, src.key);
            const v = try a.alloc(u8, src.value.len);
            @memcpy(v, src.value);
            dst.* = .{ .op = src.op, .key = k, .value = v };
        }

        self.inbox_mu.lock();
        defer self.inbox_mu.unlock();
        if (self.inbox_count >= max_inbox) {
            _ = self.drops_inbox_full.fetchAdd(1, .monotonic);
            return HostError.InboxFull;
        }
        self.inbox[self.inbox_tail] = .{
            .arena = arena,
            .mutations = muts_copy,
            .token = token,
        };
        self.inbox_tail = (self.inbox_tail + 1) % max_inbox;
        self.inbox_count += 1;
        return token;
    }

    /// Free a token after the pipeline has fired its response.
    pub fn releaseToken(self: *RaftHost, token: *ProposeToken) void {
        self.allocator.destroy(token);
    }

    /// Pipeline-side observer of commit progress. Atomic load, safe from
    /// any thread.
    pub fn lastCommittedIndex(self: *const RaftHost) u64 {
        return self.last_committed_index.load(.acquire);
    }

    /// Pipeline-side observer of leader role. Atomic load.
    pub fn isLeader(self: *const RaftHost) bool {
        return self.is_leader.load(.acquire);
    }

    // ------------------------------------------------------------------------
    // Raft thread internals
    // ------------------------------------------------------------------------

    fn tickLoop(self: *RaftHost) void {
        while (self.running.load(.acquire)) {
            self.doOneTick();
            std.Thread.sleep(self.tick_interval_ns);
        }
    }

    fn doOneTick(self: *RaftHost) void {
        const now: i64 = @intCast(std.time.nanoTimestamp());
        self.drainInbox();
        self.peer_net.tick(now, &self.runtime.transport);
        self.runtime.tick(now) catch {
            // A single tick failing is recoverable: dropped messages, proposal
            // back-pressure (InFlightFull), or a transient encode/OOM. The node
            // retries next tick, so record it and continue rather than aborting
            // the whole process (which co-locates client traffic). Genuinely
            // fatal FSM-apply failures still fail-stop via panic inside
            // applyReady. Storage corruption surfaces the same way there.
            _ = self.tick_errors.fetchAdd(1, .monotonic);
        };
        self.publishObservables();
        self.deinitActive();
    }

    /// Move all currently-queued inbox entries into `active`, calling
    /// `proposeOne` on each. The arenas stay alive in `active` until
    /// `deinitActive` runs at end-of-tick, so the batcher's flush (which
    /// runs inside runtime.tick later this tick) can safely walk the
    /// captured mutation slices.
    fn drainInbox(self: *RaftHost) void {
        // Snapshot drain count under the lock, then drain entries one at a
        // time, releasing the lock between so proposeAsync isn't blocked.
        self.inbox_mu.lock();
        const drain_count = self.inbox_count;
        self.inbox_mu.unlock();

        var i: usize = 0;
        while (i < drain_count) : (i += 1) {
            self.inbox_mu.lock();
            const entry_opt = self.inbox[self.inbox_head];
            if (entry_opt == null) {
                self.inbox_mu.unlock();
                break;
            }
            self.inbox[self.inbox_head] = null;
            self.inbox_head = (self.inbox_head + 1) % max_inbox;
            self.inbox_count -= 1;
            self.inbox_mu.unlock();

            check(self.active_count < max_inbox, "active overflow", .{});
            self.active[self.active_count] = entry_opt.?;
            const slot = &self.active[self.active_count].?;
            self.active_count += 1;
            self.proposeOne(slot);
        }
    }

    fn deinitActive(self: *RaftHost) void {
        for (0..self.active_count) |i| {
            if (self.active[i]) |*e| e.arena.deinit();
            self.active[i] = null;
        }
        self.active_count = 0;
    }

    fn proposeOne(self: *RaftHost, entry: *InboxEntry) void {
        const completion = Completion{
            .ctx = @ptrCast(entry.token),
            .on_complete = onCommitTokenCallback,
        };
        self.runtime.propose(entry.mutations, completion) catch |err| {
            // Either NotLeader or batcher overflow. Either way, the entry
            // never enters the log; flip the token to failed.
            const state = if (err == error.NotLeader) blk: {
                _ = self.drops_not_leader.fetchAdd(1, .monotonic);
                break :blk @intFromEnum(TokenState.failed);
            } else @intFromEnum(TokenState.failed);
            entry.token.state.store(state, .release);
        };
    }

    fn publishObservables(self: *RaftHost) void {
        // last_applied is monotonic and tracks committed-and-applied entries
        // on this node. Use it (not commit_index) so pipeline only sees state
        // that's actually visible in Talon.
        const applied = self.runtime.fsm.lastApplied();
        const prev = self.last_committed_index.load(.acquire);
        if (applied > prev) self.last_committed_index.store(applied, .release);
        self.is_leader.store(self.runtime.node.isLeader(), .release);
    }

    fn drainInboxOnShutdown(self: *RaftHost) void {
        // Fail any tokens still in the inbox so pipeline pollers don't block.
        self.inbox_mu.lock();
        defer self.inbox_mu.unlock();
        while (self.inbox_count > 0) {
            if (self.inbox[self.inbox_head]) |*entry| {
                entry.token.state.store(@intFromEnum(TokenState.failed), .release);
                entry.arena.deinit();
                self.inbox[self.inbox_head] = null;
            }
            self.inbox_head = (self.inbox_head + 1) % max_inbox;
            self.inbox_count -= 1;
        }
    }
};

// ============================================================================
// Completion callback — invoked by raft_batcher on the raft thread.
// ============================================================================

fn onCommitTokenCallback(ctx: *anyopaque, success: bool) void {
    const token: *ProposeToken = @ptrCast(@alignCast(ctx));
    const state: u8 = if (success)
        @intFromEnum(TokenState.committed)
    else
        @intFromEnum(TokenState.failed);
    token.state.store(state, .release);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const PeerSpec = raft.PeerSpec;

fn loopback(port: u16) net.Address {
    return net.Address.parseIp("127.0.0.1", port) catch unreachable;
}

fn synthUuid(id: []const u8) u128 {
    var h: u128 = 0xcbf29ce484222325cbf29ce484222325;
    for (id) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return if (h == 0) 1 else h;
}

const test_cluster_id: u64 = 0xC0FFEE_F00D;
const test_buf_size: u32 = 64 * 1024;

fn openFreshDb(allocator: Allocator, path: []const u8) !*talon.DB {
    std.fs.cwd().deleteFile(path) catch {};
    var vlog_buf: [256]u8 = undefined;
    const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{path}) catch unreachable;
    std.fs.cwd().deleteFile(vlog_path) catch {};
    return try talon.DB.open(allocator, path, .{});
}

fn cleanupDbFiles(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    var vlog_buf: [256]u8 = undefined;
    const vlog_path = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{path}) catch unreachable;
    std.fs.cwd().deleteFile(vlog_path) catch {};
}

test "raft_host: proposeAsync deep-copies mutation bytes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const path = "/tmp/corvo-host-deepcopy";
    const db = try openFreshDb(testing.allocator, path);
    defer {
        db.close();
        cleanupDbFiles(path);
    }

    const peers = [_]PeerSpec{};
    var host = try RaftHost.create(testing.allocator, db, .{
        .runtime = .{
            .node_id = "n1",
            .instance_uuid = synthUuid("n1"),
            .cluster_id = test_cluster_id,
            .peers = &peers,
            .raft_config = .{
                .election_timeout_min = 200_000_000,
                .election_timeout_max = 400_000_000,
                .heartbeat_interval = 50_000_000,
            },
        },
        .peer_net = .{
            .self_id = "n1",
            .bind_addr = loopback(0),
            .recv_buf_size = test_buf_size,
            .send_buf_size = test_buf_size,
        },
    });
    defer host.destroy();

    // Ephemeral key/value buffers — overwritten before the raft thread
    // would normally see them. Deep-copy means the proposal still carries
    // the original bytes.
    var key_buf: [16]u8 = undefined;
    var val_buf: [16]u8 = undefined;
    @memcpy(key_buf[0..3], "abc");
    @memcpy(val_buf[0..3], "xyz");
    const muts = [_]Mutation{.{ .op = .set, .key = key_buf[0..3], .value = val_buf[0..3] }};
    const token = try host.proposeAsync(&muts);
    defer host.releaseToken(token);

    // Stomp the caller-side buffers immediately.
    @memset(&key_buf, 0xAA);
    @memset(&val_buf, 0xBB);

    // Inspect the queued copy directly (no thread running yet).
    host.inbox_mu.lock();
    defer host.inbox_mu.unlock();
    try testing.expectEqual(@as(usize, 1), host.inbox_count);
    const queued = host.inbox[host.inbox_head].?;
    try testing.expectEqualStrings("abc", queued.mutations[0].key);
    try testing.expectEqualStrings("xyz", queued.mutations[0].value);
}

test "raft_host: 3-node TCP cluster — election + propose + commit + apply" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const path1 = "/tmp/corvo-host-3n-1";
    const path2 = "/tmp/corvo-host-3n-2";
    const path3 = "/tmp/corvo-host-3n-3";
    const db1 = try openFreshDb(testing.allocator, path1);
    const db2 = try openFreshDb(testing.allocator, path2);
    const db3 = try openFreshDb(testing.allocator, path3);
    defer {
        db1.close();
        db2.close();
        db3.close();
        cleanupDbFiles(path1);
        cleanupDbFiles(path2);
        cleanupDbFiles(path3);
    }

    const peers1 = [_]PeerSpec{
        .{ .id = "n2", .uuid = synthUuid("n2") },
        .{ .id = "n3", .uuid = synthUuid("n3") },
    };
    const peers2 = [_]PeerSpec{
        .{ .id = "n1", .uuid = synthUuid("n1") },
        .{ .id = "n3", .uuid = synthUuid("n3") },
    };
    const peers3 = [_]PeerSpec{
        .{ .id = "n1", .uuid = synthUuid("n1") },
        .{ .id = "n2", .uuid = synthUuid("n2") },
    };
    const cfg = raft.Config{
        .election_timeout_min = 200_000_000,
        .election_timeout_max = 400_000_000,
        .heartbeat_interval = 50_000_000,
    };

    const h1 = try RaftHost.create(testing.allocator, db1, .{
        .runtime = .{ .node_id = "n1", .instance_uuid = synthUuid("n1"), .cluster_id = test_cluster_id, .peers = &peers1, .raft_config = cfg },
        .peer_net = .{ .self_id = "n1", .bind_addr = loopback(0), .recv_buf_size = test_buf_size, .send_buf_size = test_buf_size },
    });
    defer h1.destroy();
    const h2 = try RaftHost.create(testing.allocator, db2, .{
        .runtime = .{ .node_id = "n2", .instance_uuid = synthUuid("n2"), .cluster_id = test_cluster_id, .peers = &peers2, .raft_config = cfg },
        .peer_net = .{ .self_id = "n2", .bind_addr = loopback(0), .recv_buf_size = test_buf_size, .send_buf_size = test_buf_size },
    });
    defer h2.destroy();
    const h3 = try RaftHost.create(testing.allocator, db3, .{
        .runtime = .{ .node_id = "n3", .instance_uuid = synthUuid("n3"), .cluster_id = test_cluster_id, .peers = &peers3, .raft_config = cfg },
        .peer_net = .{ .self_id = "n3", .bind_addr = loopback(0), .recv_buf_size = test_buf_size, .send_buf_size = test_buf_size },
    });
    defer h3.destroy();

    try h1.registerPeer("n2", h2.boundAddress());
    try h1.registerPeer("n3", h3.boundAddress());
    try h2.registerPeer("n1", h1.boundAddress());
    try h2.registerPeer("n3", h3.boundAddress());
    try h3.registerPeer("n1", h1.boundAddress());
    try h3.registerPeer("n2", h2.boundAddress());

    try h1.start();
    try h2.start();
    try h3.start();

    // Wait for a leader from the pipeline thread's perspective.
    const elect_deadline = std.time.nanoTimestamp() + 4 * std.time.ns_per_s;
    var leader: ?*RaftHost = null;
    while (leader == null and std.time.nanoTimestamp() < elect_deadline) {
        if (h1.isLeader()) leader = h1;
        if (h2.isLeader()) leader = h2;
        if (h3.isLeader()) leader = h3;
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    try testing.expect(leader != null);

    // Propose from "pipeline thread" (this thread) to leader's host.
    const muts = [_]Mutation{
        .{ .op = .set, .key = "host3n:k1", .value = "v1" },
        .{ .op = .set, .key = "host3n:k2", .value = "v2" },
    };
    const token = try leader.?.proposeAsync(&muts);
    // Release only if final, so a still-pending token isn't freed before
    // host.destroy()'s failAll can fire on it.
    defer if (token.loadState() != .pending) leader.?.releaseToken(token);

    const commit_deadline = std.time.nanoTimestamp() + 4 * std.time.ns_per_s;
    while (token.loadState() == .pending and std.time.nanoTimestamp() < commit_deadline) {
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    try testing.expectEqual(TokenState.committed, token.loadState());

    var buf: [16]u8 = undefined;
    const got = leader.?.runtime.db.getInto("host3n:k1", &buf).?;
    try testing.expectEqualStrings("v1", got);
}
