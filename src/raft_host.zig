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
//!     and `releaseToken`s when done — or earlier, to abandon it.
//!
//! Lifecycle
//!   - `init` allocates the host on the heap (Runtime + PeerNet take stable
//!     pointers into it via `pn.install(&runtime.transport)`).
//!   - `start` spawns the tick thread.
//!   - `stop` clears the running flag and joins; safe to call repeatedly.
//!   - `deinit` calls stop, drains the inbox, and tears down components.
//!   - Token ownership is refcounted with two owners: every token starts at
//!     refcount 2 (one reference for the pipeline, one for the host) and the
//!     last decrement frees. The pipeline drops its reference via
//!     `releaseToken` exactly once, at ANY time — pending or final; releasing
//!     a still-pending token IS the abandon operation. The host drops its
//!     reference on exactly one finish path per token: the batcher completion
//!     callback (`onCommitTokenCallback`, commit or fail), the
//!     terminal-rejection path in `proposeOne` (NotLeader / oversize
//!     proposal), or `drainInboxOnShutdown` for tokens never handed to the
//!     runtime. Back-pressure is NOT a finish path: a proposal the runtime
//!     can't take this tick stays queued in the inbox, token pending, and is
//!     retried in order on later ticks. `destroy` finishes every outstanding
//!     token (inbox drain, then runtime deinit's failAll), so a pipeline
//!     release after destroy is safe via `ProposeToken.release`.
//!
//! TigerStyle: bounded inbox (`max_inbox`), per-entry arena for mutation
//! deep-copy (freed as soon as the batcher copies the bytes into its own
//! pending buffer), exhaustive switches in callbacks, no allocations on the
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

/// Re-exported so composition roots (main.zig) can build peer lists without
/// importing the raft library directly.
pub const PeerSpec = raft.PeerSpec;

/// Stable uuid derived from a node id (FNV-1a-128). Static clusters use
/// this by default so operators don't hand-mint uuids; an explicit
/// `id:uuidhex@host:port` peer spec overrides it when instance-identity
/// detection matters (a wiped node reusing an id).
pub fn deriveUuid(id: []const u8) u128 {
    var h: u128 = 0xcbf29ce484222325cbf29ce484222325;
    for (id) |c| {
        h ^= c;
        h *%= 0x100000001b3;
    }
    return if (h == 0) 1 else h;
}

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
    /// Two owners share the token — the pipeline and the host — so `refs`
    /// starts at 2. Each side decrements exactly once; whoever hits zero
    /// frees. This makes pipeline release safe at any point in the token's
    /// lifecycle: a still-pending token released by the pipeline stays alive
    /// until the host's finish path drops the last reference.
    refs: std.atomic.Value(u32) = .init(2),
    allocator: Allocator,

    pub fn loadState(self: *const ProposeToken) TokenState {
        return @enumFromInt(self.state.load(.acquire));
    }

    /// Pipeline-side ownership drop. Call exactly once per token, at ANY
    /// time — pending or final. Releasing a pending token abandons it: the
    /// host's finish path still runs and the last owner frees. Also valid
    /// after the host is destroyed (`destroy` finishes every outstanding
    /// token first, so only the pipeline reference can remain).
    pub fn release(self: *ProposeToken) void {
        self.unref();
    }

    /// Drop one ownership reference; the owner that hits zero frees. The
    /// .acq_rel decrement pairs the two owners: the releasing side publishes
    /// all its prior writes (notably the host's final-state store), and the
    /// freeing side acquires them before `destroy`.
    fn unref(self: *ProposeToken) void {
        const prev = self.refs.fetchSub(1, .acq_rel);
        check(prev == 1 or prev == 2, "token refcount underflow", .{});
        if (prev == 1) self.allocator.destroy(self);
    }
};

/// Host-side finish: publish the final state, then drop the host's
/// reference. Exactly one host path calls this per token — the batcher
/// completion callback, `proposeOne`'s propose-error path, or
/// `drainInboxOnShutdown` — and these are mutually exclusive (see each
/// call site).
/// Ordering constraint: the state store (.release) MUST precede the
/// refcount decrement. The decrement is what makes the token freeable, so
/// storing first guarantees a pipeline reader that observes a final state
/// can never race the free, and the freeing owner sees the final state.
fn finishTokenHostSide(token: *ProposeToken, state: TokenState) void {
    check(state != .pending, "host-side finish must be final", .{});
    token.state.store(@intFromEnum(state), .release);
    token.unref();
}

// ============================================================================
// Inbox entry — owned by host from proposeAsync() until the raft thread's
// drainInbox() hands it to the runtime (or rejects it terminally). Each entry
// carries a per-entry arena that backs the deep-copied Mutations + their
// key/value bytes; the arena is freed the moment the batcher accepts the
// proposal (it copies the bytes into its own pending buffer) or the token is
// finished. On back-pressure the entry stays in the inbox, arena intact, and
// is retried in order on a later tick.
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

    // Inbox: pipeline → raft. Mutex-protected ring buffer. Doubles as the
    // ordered retry queue under back-pressure: drainInbox only pops an entry
    // once the runtime accepted it (or rejected it terminally), so proposals
    // reach the raft log in exactly the order the pipeline committed them.
    inbox: [max_inbox]?InboxEntry = .{null} ** max_inbox,
    inbox_head: usize = 0,
    inbox_tail: usize = 0,
    inbox_count: usize = 0,
    inbox_mu: std.Thread.Mutex = .{},

    // Atomics for pipeline thread to poll.
    last_committed_index: std.atomic.Value(u64) align(64) = .init(0),
    is_leader: std.atomic.Value(bool) align(64) = .init(false),

    // Drop counters — observable for tests + metrics.
    drops_inbox_full: std.atomic.Value(u64) = .init(0),
    drops_not_leader: std.atomic.Value(u64) = .init(0),
    // Recoverable tick errors (transient OOM in snapshot serialization,
    // node.tick storage hiccups that were not fail-stop). Counted AND logged
    // (rate-limited) so a persistently-failing node is visible to operators
    // without the process crashing on a single transient hiccup.
    tick_errors: std.atomic.Value(u64) = .init(0),

    tick_interval_ns: u64 = default_tick_interval_ns,

    /// Serializes talon access with the pipeline thread (talon's batch pool
    /// and root swap are single-threaded). Held for the DB-touching span of
    /// each tick. Null when no other thread shares the DB (tests).
    db_lock: ?*std.Thread.Mutex = null,

    pub const HostInitParams = struct {
        runtime: InitParams,
        peer_net: PeerNetConfig,
        tick_interval_ns: u64 = default_tick_interval_ns,
        db_lock: ?*std.Thread.Mutex = null,
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
            .db_lock = params.db_lock,
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
    /// thread once the entry commits or fails. Caller holds one of the
    /// token's two references and drops it via `releaseToken`.
    pub fn proposeAsync(self: *RaftHost, mutations: []const Mutation) !*ProposeToken {
        const token = try self.allocator.create(ProposeToken);
        // On error the token was never shared, so destroy directly rather
        // than dropping references one owner at a time.
        errdefer self.allocator.destroy(token);
        token.* = .{ .allocator = self.allocator };

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

    /// Drop the pipeline's reference to a token. Call exactly once per
    /// token, at ANY time — after the response fired, or earlier to abandon
    /// a still-pending proposal. Delegates to `ProposeToken.release` (which
    /// is also callable directly, e.g. after the host is destroyed).
    pub fn releaseToken(self: *RaftHost, token: *ProposeToken) void {
        _ = self;
        token.release();
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
        // Peer socket I/O (reconnects, HMAC handshakes, frame decode) never
        // touches the DB — run it OUTSIDE the db_lock so client traffic on
        // the pipeline thread doesn't stall behind peer-socket work.
        // Inbound frames land in the runtime's transport queues; the locked
        // runtime.tick below drains them on this same thread.
        self.peer_net.tick(now, &self.runtime.transport);
        {
            if (self.db_lock) |l| l.lock();
            defer if (self.db_lock) |l| l.unlock();
            // drainInbox runs under the DB lock: accepting a proposal can
            // flush the batcher into raft storage (a talon write) when a
            // batch crosses the per-entry cap. Lock nesting is
            // db_lock → inbox_mu on this thread only; the pipeline takes
            // inbox_mu solely inside proposeAsync, which never touches the
            // DB lock — no cycle, no deadlock.
            self.runtime.tick_now = now;
            self.drainInbox();
            self.runtime.tick(now) catch |err| {
                // A failed tick here is recoverable-by-retry: transient OOM
                // (e.g. snapshot serialization) or a node.tick storage
                // hiccup; nothing was lost — proposals stay queued and
                // committed entries re-surface via ready(). Genuinely fatal
                // failures never reach this catch: FSM-apply failures and
                // step()/propose() storage failures fail-stop via panic
                // inside the runtime. Count + log (rate-limited: first and
                // every 1024th) so a node erroring every tick is visible.
                const n = self.tick_errors.fetchAdd(1, .monotonic);
                if (n == 0 or n % 1024 == 0) {
                    std.debug.print("raft: tick error (total {d}): {s}\n", .{ n + 1, @errorName(err) });
                }
            };
        }
        self.publishObservables();
    }

    /// Feed queued proposals to the runtime, in order. An entry is popped
    /// only once the runtime accepted it (batcher copied the bytes) or
    /// rejected it terminally (token failed); on back-pressure the entry —
    /// arena intact — stays at the head of the inbox and the drain stops,
    /// preserving proposal order across ticks.
    fn drainInbox(self: *RaftHost) void {
        // Snapshot drain count under the lock, then work one entry at a
        // time, releasing the lock between so proposeAsync isn't blocked.
        self.inbox_mu.lock();
        const drain_count = self.inbox_count;
        self.inbox_mu.unlock();

        var i: usize = 0;
        while (i < drain_count) : (i += 1) {
            self.inbox_mu.lock();
            if (self.inbox_count == 0) {
                self.inbox_mu.unlock();
                break;
            }
            const head = self.inbox_head;
            self.inbox_mu.unlock();

            // Only this thread pops; the head slot is stable outside the
            // lock (producers touch only the tail).
            const entry = &self.inbox[head].?;
            switch (self.proposeOne(entry)) {
                .accepted, .rejected => {
                    entry.arena.deinit();
                    self.inbox[head] = null;
                    self.inbox_mu.lock();
                    self.inbox_head = (head + 1) % max_inbox;
                    self.inbox_count -= 1;
                    self.inbox_mu.unlock();
                },
                // Runtime can't take it this tick (raft log in-flight window
                // full, or transient OOM before capture). The token is still
                // pending and no bytes were captured — leave the entry
                // queued and retry next tick. Back-pressure propagates to
                // the pipeline as a pending token / a filling inbox, never
                // as a failed token for a write that was merely delayed.
                .backpressure => return,
            }
        }
    }

    const ProposeOutcome = enum { accepted, rejected, backpressure };

    fn proposeOne(self: *RaftHost, entry: *InboxEntry) ProposeOutcome {
        const completion = Completion{
            .ctx = @ptrCast(entry.token),
            .on_complete = onCommitTokenCallback,
        };
        // locally_applied: proposeAsync's contract is that the caller (the
        // pipeline) committed these mutations to talon before proposing —
        // the FSM records commit without re-applying (docs/raft-wiring.md).
        self.runtime.propose(entry.mutations, completion, true) catch |err| switch (err) {
            // Terminal rejections: the proposal can never be accepted, and
            // it failed BEFORE the batcher captured the completion, so no
            // callback will ever fire — this is the token's host-side finish.
            error.NotLeader => {
                _ = self.drops_not_leader.fetchAdd(1, .monotonic);
                finishTokenHostSide(entry.token, .failed);
                return .rejected;
            },
            error.ProposalTooLarge => {
                finishTokenHostSide(entry.token, .failed);
                return .rejected;
            },
            // Back-pressure: legal load, NOT a failure. Failing the token
            // here would make the pipeline treat an already-locally-committed
            // write as divergence and fail-stop ("wipe the data dir") for
            // hitting a rate limit. The caller keeps the entry queued.
            error.InFlightFull, error.OutOfMemory => return .backpressure,
            // Runtime.propose flushes + retries PendingFull internally;
            // NotInitialized/ProposeFailed have no path out of propose
            // (storage failures panic inside proposeBridge).
            error.PendingFull, error.ProposeFailed, error.NotInitialized => unreachable,
        };
        return .accepted;
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
        // These tokens were never handed to the runtime (the raft thread is
        // joined, so drainInbox can't run concurrently), so this is their
        // one and only host-side finish.
        self.inbox_mu.lock();
        defer self.inbox_mu.unlock();
        while (self.inbox_count > 0) {
            if (self.inbox[self.inbox_head]) |*entry| {
                finishTokenHostSide(entry.token, .failed);
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

// The batcher fires each accepted completion exactly once — completeCommitted
// on commit (success on an (index, term) match, failure when another leader's
// entry landed at our index), failDiscarded when a new leader truncates the
// entry out of our log, failPending on step-down (unflushed proposals only),
// failAll on snapshot install / runtime deinit — and proposeOne only
// registers it when runtime.propose succeeds (its terminal-rejection path
// finishes the token instead; back-pressure finishes nothing). So this
// callback is the token's one and only host-side finish.
fn onCommitTokenCallback(ctx: *anyopaque, success: bool) void {
    const token: *ProposeToken = @ptrCast(@alignCast(ctx));
    finishTokenHostSide(token, if (success) .committed else .failed);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

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

test "raft_host: token — host completes, then pipeline releases" {
    const token = try testing.allocator.create(ProposeToken);
    token.* = .{ .allocator = testing.allocator };
    onCommitTokenCallback(@ptrCast(token), true);
    try testing.expectEqual(TokenState.committed, token.loadState());
    // Pipeline drops the last reference — frees. testing.allocator verifies
    // the create/destroy balance (no leak, no double-free).
    token.release();
}

test "raft_host: token — pipeline abandons pending, host finish frees" {
    const token = try testing.allocator.create(ProposeToken);
    token.* = .{ .allocator = testing.allocator };
    // Abandon while pending: the token must not be touched again by the
    // pipeline side after this call.
    token.release();
    // Host-side finish drops the last reference and frees.
    onCommitTokenCallback(@ptrCast(token), false);
}

/// Single-node follower host — never started, so tests drive the raft-thread
/// internals (`drainInbox`) directly and deterministically (no election
/// ticks means `runtime.propose` always returns NotLeader).
fn createFollowerHost(allocator: Allocator, db: *talon.DB) !*RaftHost {
    const peers = [_]PeerSpec{};
    return RaftHost.create(allocator, db, .{
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
}

test "raft_host: abandon pending token, raft side finishes via propose error" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const path = "/tmp/corvo-host-abandon";
    const db = try openFreshDb(testing.allocator, path);
    defer {
        db.close();
        cleanupDbFiles(path);
    }
    const host = try createFollowerHost(testing.allocator, db);
    defer host.destroy();

    const muts = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
    const token = try host.proposeAsync(&muts);
    try testing.expectEqual(TokenState.pending, token.loadState());
    host.releaseToken(token);
    // Raft-thread side: the follower rejects the proposal (NotLeader), so
    // proposeOne's terminal-rejection path finishes the token and drops the
    // last reference. Any write into freed memory would trip
    // testing.allocator.
    host.drainInbox();
    try testing.expectEqual(@as(u64, 1), host.drops_not_leader.load(.monotonic));
}

test "raft_host: host finishes token first, pipeline releases after" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const path = "/tmp/corvo-host-finish-first";
    const db = try openFreshDb(testing.allocator, path);
    defer {
        db.close();
        cleanupDbFiles(path);
    }
    const host = try createFollowerHost(testing.allocator, db);
    defer host.destroy();

    const muts = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
    const token = try host.proposeAsync(&muts);
    host.drainInbox();
    try testing.expectEqual(TokenState.failed, token.loadState());
    host.releaseToken(token);
}

test "raft_host: destroy fails inbox tokens; release before and after destroy" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const path = "/tmp/corvo-host-shutdown-tokens";
    const db = try openFreshDb(testing.allocator, path);
    defer {
        db.close();
        cleanupDbFiles(path);
    }
    const host = try createFollowerHost(testing.allocator, db);

    const muts = [_]Mutation{.{ .op = .set, .key = "k", .value = "v" }};
    const token_a = try host.proposeAsync(&muts);
    const token_b = try host.proposeAsync(&muts);
    // token_a: abandoned while pending — destroy's inbox drain frees it.
    host.releaseToken(token_a);
    host.destroy();
    // token_b: the inbox drain finished it with .failed; it outlives the
    // host because the pipeline still holds its reference, dropped via the
    // token itself (the host is gone).
    try testing.expectEqual(TokenState.failed, token_b.loadState());
    token_b.release();
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
    // Pipeline release is safe at any point, pending or final: if the token
    // is still pending at host.destroy(), the host-side finish (inbox drain
    // or runtime deinit's failAll) drops the last reference and frees.
    defer leader.?.releaseToken(token);

    const commit_deadline = std.time.nanoTimestamp() + 4 * std.time.ns_per_s;
    while (token.loadState() == .pending and std.time.nanoTimestamp() < commit_deadline) {
        std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    try testing.expectEqual(TokenState.committed, token.loadState());

    // proposeAsync's contract: the caller applied locally BEFORE proposing,
    // so the leader's FSM skips the data re-apply — verify on a FOLLOWER,
    // which takes the full apply path.
    const follower = if (leader.? == h1) h2 else h1;
    var buf: [16]u8 = undefined;
    const apply_deadline = std.time.nanoTimestamp() + 4 * std.time.ns_per_s;
    var got: ?[]const u8 = null;
    while (got == null and std.time.nanoTimestamp() < apply_deadline) {
        got = try follower.runtime.db.getInto("host3n:k1", &buf);
        if (got == null) std.Thread.sleep(2 * std.time.ns_per_ms);
    }
    try testing.expectEqualStrings("v1", got.?);
}
