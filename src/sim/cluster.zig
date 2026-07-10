//! Multi-node cluster simulator — deterministic end-to-end raft replication.
//!
//! When raft replaced primary-backup replication (commit 74efe39) the old
//! src/sim/cluster.zig (PBR mechanics) was deleted. This is its raft-stack
//! successor. It drives the FULL production write path across N simulated
//! nodes and asserts leader/follower KV convergence after replicated traffic:
//!
//!   client RPC frame → leader Pipeline.executeBatch (local commit + record)
//!     → proposeRecordedFrames → RaftIface.propose → raft batcher/Node.propose
//!     → AppendEntries over an in-memory transport → follower Node.step + FSM
//!     apply → follower KV.
//!
//! Design (see docs/raft-wiring.md):
//!   - Deterministic + single-threaded. Production runs the pipeline on one
//!     thread and raft on another (serialized by a DB mutex). The sim replaces
//!     that with EXPLICIT interleaved stepping from the test loop: each "round"
//!     ticks every node's Pipeline, then every node's raft Runtime, in a fixed
//!     order. No real threads, sockets, or wall clock.
//!   - Message delivery uses `SimNet`, an in-memory router between the nodes'
//!     `raft_transport.Transport` adapters. This is the same wiring the
//!     raft_runtime / raft_transport tests use via `InMemRouter`, extended with
//!     a per-node `up` flag so a node can be partitioned (scenario d). Send is
//!     synchronous into the peer's inbound ring; recv happens during the peer's
//!     next Runtime.tick (raft tolerates the resulting message latency exactly
//!     as it does over a real network).
//!   - Each node wires the way main.zig wires production: its own talon DB +
//!     KV store + OpHandler + QueueNotifier + raft Runtime (Storage+Transport+
//!     FSM+Batcher+Node) + Pipeline. The leader path uses a `RaftIface`
//!     (SimRaftBridge) that proposes into the Runtime's batcher; followers
//!     apply committed entries through the Runtime's FSM. The bridge is the
//!     deterministic, single-threaded stand-in for raft_host.zig's threaded
//!     RaftHost (same ProposeToken refcount contract, no inbox/thread).
//!
//! The core assertion (`assertConsistent`) walks each node's KV store and
//! asserts the leader and every follower are byte-identical over the
//! USER-visible keyspace. Raft's own bookkeeping ("r:" prefix — r:meta,
//! r:log:*, r:snap:*, r:applied; see raft_storage.zig / raft_fsm.zig) is
//! EXCLUDED: it legitimately differs per node (distinct match indexes, apply
//! timing, log suffixes) and is not user state. Note "r:" (0x72 0x3a) is
//! distinct from the user retry-index prefix "r|" (0x72 0x7c), so the exclusion
//! never drops a job index.
//!
//! Maintenance (promote/reclaim/expire/purge/...) is left DISABLED (all
//! intervals 0, the Config default) so quiescence is purely traffic-driven and
//! fully deterministic; maintenance-mutation application is covered by the
//! single-node sim + raft_runtime tests. All client-op mutations (enqueue /
//! fetch-claim / ack / fail / bulk / cron / batch / queue-config) DO replicate
//! and are checked.

const std = @import("std");
const talon = @import("talon");
const corvo = @import("corvo");
const raft = @import("raft");

const kv = corvo.kv;
const Mutation = kv.Mutation;
const handler_mod = corvo.handler;
const notify_mod = corvo.notify;
const pipeline_mod = corvo.pipeline;
const io_mod = corvo.io;
const rpc = corvo.rpc;
const raft_runtime = corvo.raft_runtime;
const raft_host = corvo.raft_host;

const SimBackend = io_mod.SimBackend;
const Pipeline = pipeline_mod.Pipeline(SimBackend);
const RaftIface = pipeline_mod.RaftIface;
const ProposeToken = pipeline_mod.ProposeToken;
const TokenState = pipeline_mod.TokenState;
const Runtime = raft_runtime.Runtime;
const RaftTransport = corvo.raft_transport.Transport;
const Completion = corvo.raft_batcher.Completion;
const OpHandler = handler_mod.OpHandler;
const QueueNotifier = notify_mod.QueueNotifier;
const PeerSpec = raft_host.PeerSpec;

const SimClock = @import("clock.zig").SimClock;
const setGlobalClock = @import("clock.zig").setGlobalClock;
const globalClockNow = @import("clock.zig").globalClockNow;
const Config = @import("config.zig").Config;
const SimClient = @import("client.zig").SimClient;

// ============================================================================
// Bounds
// ============================================================================

const max_nodes = 7;
const max_clients = 16;
const cluster_id: u64 = 0xC0FFEE_5107;

/// Simulated-time advance per raft round. Chosen with the raft timeouts below
/// so a full AppendEntries → response round trip (~1-2 rounds) lands well
/// inside election_timeout_min, keeping CheckQuorum satisfied and the leader
/// stable, while an initial election still resolves in ~6-12 rounds.
const round_ns: i64 = 50_000_000; // 50ms

fn raftConfig() raft.Config {
    return .{
        .election_timeout_min = 300_000_000, // 300ms
        .election_timeout_max = 600_000_000, // 600ms
        .heartbeat_interval = 100_000_000, // 100ms (< election_timeout_min)
    };
}

// ============================================================================
// ProposeToken completion — the host-side finish (mirrors raft_host's
// onCommitTokenCallback but for the single-threaded sim bridge). Publishes the
// final state, then drops the host's reference of the 2-owner token.
// ============================================================================

fn tokenComplete(ctx: *anyopaque, success: bool) void {
    const token: *ProposeToken = @ptrCast(@alignCast(ctx));
    token.state.store(
        @intFromEnum(if (success) TokenState.committed else TokenState.failed),
        .release,
    );
    token.release(); // host-side unref (the pipeline drops the other reference)
}

// ============================================================================
// SimRaftBridge — a deterministic RaftIface over a raft Runtime.
//
// Production's RaftHost hands proposals to a dedicated raft thread through a
// mutex-guarded inbox. The sim is single-threaded, so the bridge proposes
// straight into the Runtime's batcher and the test loop ticks the Runtime
// explicitly. It keeps the exact ProposeToken refcount contract: every token
// starts at refs=2, the completion (host) drops one, the pipeline drops one.
//
// Mutations captured by batcher.enqueue must stay alive until batcher.flush
// consumes them (during the NEXT Runtime.tick). We deep-copy each proposal's
// mutations into a per-proposal arena and free the arenas after a Runtime.tick
// once the batcher's pending queue is empty (flush copied them into the entry
// payload, or a step-down failAll cleared pending without touching them).
// ============================================================================

const SimRaftBridge = struct {
    runtime: *Runtime = undefined,
    allocator: std.mem.Allocator = undefined,
    arenas: std.ArrayList(*std.heap.ArenaAllocator) = .{},

    fn iface(self: *SimRaftBridge) RaftIface {
        return .{
            .ptr = @ptrCast(self),
            .propose_fn = proposeFn,
            .is_leader_fn = isLeaderFn,
        };
    }

    fn isLeaderFn(ptr: *anyopaque) bool {
        const self: *SimRaftBridge = @ptrCast(@alignCast(ptr));
        return self.runtime.node.isLeader();
    }

    fn proposeFn(ptr: *anyopaque, muts: []const Mutation) ?*ProposeToken {
        const self: *SimRaftBridge = @ptrCast(@alignCast(ptr));

        const token = self.allocator.create(ProposeToken) catch @panic("sim OOM: token");
        token.* = .{ .allocator = self.allocator }; // refs=2, state=pending

        const ar = self.allocator.create(std.heap.ArenaAllocator) catch @panic("sim OOM: arena");
        ar.* = std.heap.ArenaAllocator.init(self.allocator);
        const a = ar.allocator();

        const copy = a.alloc(Mutation, muts.len) catch @panic("sim OOM: muts");
        for (muts, copy) |src, *dst| {
            const k = a.alloc(u8, src.key.len) catch @panic("sim OOM: key");
            @memcpy(k, src.key);
            const v = a.alloc(u8, src.value.len) catch @panic("sim OOM: val");
            @memcpy(v, src.value);
            dst.* = .{ .op = src.op, .key = k, .value = v };
        }

        const completion = Completion{ .ctx = @ptrCast(token), .on_complete = tokenComplete };
        // locally_applied = true: the pipeline committed these mutations to
        // talon before proposing (docs/raft-wiring.md), so the leader's FSM
        // records the entry applied without re-writing data.
        if (self.runtime.propose(copy, completion, true)) |_| {
            self.arenas.append(self.allocator, ar) catch @panic("sim OOM: arenas");
        } else |_| {
            // NotLeader or batcher rejection — both fail BEFORE the batcher
            // captured the completion, so no callback will fire: finish the
            // token host-side here and drop the (uncaptured) arena now.
            token.state.store(@intFromEnum(TokenState.failed), .release);
            token.release();
            ar.deinit();
            self.allocator.destroy(ar);
        }
        return token;
    }

    /// Free proposal arenas once the batcher no longer references their
    /// mutations. Called after every Runtime.tick.
    fn afterRaftTick(self: *SimRaftBridge) void {
        if (self.runtime.batcher.pendingCount() != 0) return;
        for (self.arenas.items) |ar| {
            ar.deinit();
            self.allocator.destroy(ar);
        }
        self.arenas.clearRetainingCapacity();
    }

    fn deinit(self: *SimRaftBridge) void {
        for (self.arenas.items) |ar| {
            ar.deinit();
            self.allocator.destroy(ar);
        }
        self.arenas.deinit(self.allocator);
    }
};

// ============================================================================
// SimNet — in-memory raft transport router with partition support.
//
// Same role as raft_transport.InMemRouter (glue N Transport adapters together
// by codec round-trip in process), but each node carries an `up` flag so a
// scenario can partition it. The sender's node index is captured per hook, so
// routing needs no wire decode.
// ============================================================================

const SendHook = struct { net: *SimNet, from_idx: usize };

const SimNet = struct {
    const Peer = struct {
        id: []const u8,
        transport: *RaftTransport,
        up: bool = true,
    };

    peers: [max_nodes]Peer = undefined,
    hooks: [max_nodes]SendHook = undefined,
    count: usize = 0,

    fn register(self: *SimNet, idx: usize, id: []const u8, transport: *RaftTransport) void {
        std.debug.assert(idx == self.count);
        std.debug.assert(self.count < max_nodes);
        self.peers[self.count] = .{ .id = id, .transport = transport, .up = true };
        self.hooks[self.count] = .{ .net = self, .from_idx = self.count };
        transport.setSend(@ptrCast(&self.hooks[self.count]), sendFn);
        self.count += 1;
    }

    fn setUp(self: *SimNet, idx: usize, up: bool) void {
        self.peers[idx].up = up;
    }

    fn sendFn(ctx: *anyopaque, to: []const u8, bytes: []const u8) bool {
        const hook: *SendHook = @ptrCast(@alignCast(ctx));
        const self = hook.net;
        if (!self.peers[hook.from_idx].up) return false; // partitioned sender
        for (self.peers[0..self.count]) |*p| {
            if (std.mem.eql(u8, p.id, to)) {
                if (!p.up) return false; // partitioned receiver
                return p.transport.pushInboundBytes(self.peers[hook.from_idx].id, bytes);
            }
        }
        return false;
    }
};

// ============================================================================
// Node — one simulated cluster member, wired like main.zig's production node.
// ============================================================================

const Node = struct {
    id: []const u8,
    db: *talon.DB,
    stores: [1]kv.Store,
    handler: OpHandler,
    notify: QueueNotifier,
    runtime: Runtime,
    bridge: SimRaftBridge,
    backend: SimBackend,
    pipeline: *Pipeline,
    /// When false the node is "crashed" — its Pipeline and Runtime are not
    /// ticked. (Partition, i.e. alive-but-unreachable, is modeled via SimNet.)
    ticking: bool = true,
};

// ============================================================================
// Cluster
// ============================================================================

var g_instance_counter: u32 = 0;

const Cluster = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    net: *SimNet,
    clock: *SimClock,
    now_ns: i64,
    instance_id: u32,
    node_ids: [][]const u8,

    fn init(allocator: std.mem.Allocator, node_count: u8, clock: *SimClock) !Cluster {
        std.debug.assert(node_count >= 1 and node_count <= max_nodes);
        const instance_id = g_instance_counter;
        g_instance_counter += 1;

        const node_ids = try allocator.alloc([]const u8, node_count);
        for (0..node_count) |i| {
            node_ids[i] = try std.fmt.allocPrint(allocator, "n{d}", .{i + 1});
        }

        const net = try allocator.create(SimNet);
        net.* = .{};

        const nodes = try allocator.alloc(Node, node_count);

        const cfg = raftConfig();
        for (0..node_count) |i| {
            var path_buf: [96]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/tmp/corvo-clustersim-{d}-{d}", .{ instance_id, i }) catch unreachable;
            deleteDbFiles(path);
            const db = try talon.DB.open(allocator, path, .{});

            // Peers = all other node ids, uuids derived like main.zig's default.
            var peers_buf: [max_nodes - 1]PeerSpec = undefined;
            var pn: usize = 0;
            for (0..node_count) |j| {
                if (i == j) continue;
                peers_buf[pn] = .{ .id = node_ids[j], .uuid = raft_host.deriveUuid(node_ids[j]) };
                pn += 1;
            }

            const runtime = try Runtime.init(allocator, db, .{
                .node_id = node_ids[i],
                .instance_uuid = raft_host.deriveUuid(node_ids[i]),
                .cluster_id = cluster_id,
                .peers = peers_buf[0..pn],
                .raft_config = cfg,
                .bootstrap_initial_config = false,
                .snapshot_threshold_entries = 0, // no compaction — keep the log intact
            });

            const backend = try SimBackend.init(allocator, .{
                .listen_fd = -1,
                .max_conns = max_clients + 8,
                .recv_buf_size = 65536,
                // Must exceed the pipeline's max_payload_size (64KiB): the fetch
                // fulfillment budget guard (pipeline.fulfillSubscriptions) only
                // pushes to a subscriber whose free send buffer can already hold
                // one MAX-size job. A 64KiB buffer == max payload never clears
                // that bar, so subscriptions would never fulfill.
                .send_buf_size = 256 * 1024,
            });

            const store = kv.Store.init(db);
            nodes[i] = .{
                .id = node_ids[i],
                .db = db,
                .stores = [1]kv.Store{store},
                .handler = OpHandler.init(allocator),
                .notify = QueueNotifier.init(allocator),
                .runtime = runtime,
                .bridge = .{},
                .backend = backend,
                .pipeline = undefined,
            };
        }

        // Second pass: nodes are now at stable heap addresses. Wire the bridge,
        // build the Pipeline (config.raft points at the bridge), and register
        // the transport with the router.
        for (0..node_count) |i| {
            nodes[i].bridge = .{ .runtime = &nodes[i].runtime, .allocator = allocator };
            const p = try allocator.create(Pipeline);
            p.* = Pipeline.init(
                allocator,
                &nodes[i].backend,
                &nodes[i].handler,
                nodes[i].stores[0..],
                &nodes[i].notify,
                null,
                .{
                    .clock_fn = &globalClockNow,
                    .raft = nodes[i].bridge.iface(),
                    // All maintenance intervals default to 0 = disabled.
                },
            );
            nodes[i].pipeline = p;
            net.register(i, nodes[i].id, &nodes[i].runtime.transport);
        }

        return .{
            .allocator = allocator,
            .nodes = nodes,
            .net = net,
            .clock = clock,
            .now_ns = clock.now(),
            .instance_id = instance_id,
            .node_ids = node_ids,
        };
    }

    fn deinit(self: *Cluster) void {
        for (self.nodes, 0..) |*n, i| {
            n.pipeline.destroyHeap(); // releases pipeline-held token refs
            n.runtime.deinit(); // failAll fires remaining completions (host refs)
            n.bridge.deinit();
            n.handler.deinit();
            n.notify.deinit();
            n.backend.deinit(self.allocator);
            n.db.close();
            var path_buf: [96]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/tmp/corvo-clustersim-{d}-{d}", .{ self.instance_id, i }) catch continue;
            deleteDbFiles(path);
        }
        self.allocator.free(self.nodes);
        self.allocator.destroy(self.net);
        for (self.node_ids) |id| self.allocator.free(@constCast(id));
        self.allocator.free(self.node_ids);
    }

    // ------------------------------------------------------------------------
    // Stepping
    // ------------------------------------------------------------------------

    /// One round: advance simulated time, tick every ticking node's Pipeline,
    /// then every ticking node's raft Runtime. Message delivery is synchronous
    /// on send (into the peer's inbound ring) and consumed on the next tick.
    fn pumpRound(self: *Cluster) void {
        self.now_ns += round_ns;
        self.clock.advance(round_ns);

        for (self.nodes) |*n| {
            if (n.ticking) n.pipeline.tick();
        }
        for (self.nodes) |*n| {
            if (!n.ticking) continue;
            n.runtime.tick(self.now_ns) catch |e| {
                std.debug.panic("runtime.tick failed on {s}: {s}", .{ n.id, @errorName(e) });
            };
            n.bridge.afterRaftTick();
        }
    }

    fn pumpRounds(self: *Cluster, n: u32) void {
        for (0..n) |_| self.pumpRound();
    }

    fn leaderIdx(self: *Cluster) ?usize {
        for (self.nodes, 0..) |*n, i| {
            if (n.ticking and n.runtime.node.isLeader()) return i;
        }
        return null;
    }

    /// Pump until a raft leader exists AND its Pipeline has driven the
    /// follower→acquiring→leading barrier to completion (so it may serve
    /// writes). Returns the leader index.
    fn electLeaderLeading(self: *Cluster, max_rounds: u32) !usize {
        var r: u32 = 0;
        while (r < max_rounds) : (r += 1) {
            self.pumpRound();
            if (self.leaderIdx()) |li| {
                if (self.nodes[li].pipeline.raft_state == .leading) return li;
            }
        }
        return error.NoLeaderElected;
    }

    /// True when replicated traffic has settled: a leader is leading with no
    /// in-flight proposals, and every ticking node has applied the same number
    /// of raft entries (so their KV is identical).
    fn converged(self: *Cluster) bool {
        const li = self.leaderIdx() orelse return false;
        const leader = &self.nodes[li];
        if (leader.pipeline.raft_state != .leading) return false;
        if (leader.pipeline.prepare_count != 0) return false;
        if (leader.pipeline.maint_token_count != 0) return false;
        if (leader.runtime.batcher.pendingCount() != 0) return false;
        if (leader.runtime.batcher.inFlightCount() != 0) return false;
        const applied = leader.runtime.fsm.lastApplied();
        for (self.nodes) |*n| {
            if (!n.ticking) continue;
            if (n.runtime.fsm.lastApplied() != applied) return false;
        }
        return true;
    }

    /// Pump rounds until `converged`. Returns true on success.
    fn quiesce(self: *Cluster, max_rounds: u32) bool {
        var r: u32 = 0;
        while (r < max_rounds) : (r += 1) {
            if (self.converged()) return true;
            self.pumpRound();
        }
        return self.converged();
    }

    // ------------------------------------------------------------------------
    // Consistency assertion — the core check.
    // ------------------------------------------------------------------------

    /// Assert every ticking follower's user-visible KV is byte-identical to the
    /// leader's. Raft bookkeeping ("r:" prefix) is excluded. Returns the number
    /// of j| job records on the leader.
    fn assertConsistent(self: *Cluster, leader_idx: usize) !usize {
        const leader = &self.nodes[leader_idx];
        for (self.nodes, 0..) |*node, i| {
            if (i == leader_idx or !node.ticking) continue;
            try compareUserKv(leader, node);
        }
        return countPrefix(leader, "j|");
    }

    fn setPartition(self: *Cluster, idx: usize, up: bool) void {
        self.net.setUp(idx, up);
    }

    /// Deterministically exercise the full completed-job lifecycle through the
    /// leader on a dedicated queue and assert AUTO-DELETE REPLICATES: enqueue →
    /// fetch (an already-pending job fulfills synchronously) → ack (done, which
    /// auto-deletes the completed job) → the record is gone on the leader AND
    /// every follower. Each step quiesces so the deferred, committed responses
    /// flush and the mutation replicates.
    fn assertLifecycleReplicates(self: *Cluster, leader_idx: usize) !void {
        const leader = &self.nodes[leader_idx];
        const wconn = leader.backend.connect() orelse unreachable; // worker/subscriber
        const pconn = leader.backend.connect() orelse unreachable; // producer
        var buf: [512]u8 = undefined;

        // 1. Worker subscribes to the (empty) dedicated queue. Fetch is
        // subscribe-only: nothing to fulfill yet. Pump so the frame is drained.
        const sn = buildFetchFrame(&buf, 201, "life-worker", "lifeq");
        leader.backend.injectRecv(wconn, buf[0..sn]);
        self.pumpRounds(4);
        if (leader.pipeline.waiting_conn_count == 0) return error.SubscribeFailed;

        // 2. Producer enqueues life-1 → notifies lifeq → fulfillSubscriptions
        // claims it for the waiting worker. The claim + push replicate/commit.
        const en = buildEnqueueFrame(&buf, 202, "lifeq", "life-1");
        leader.backend.injectRecv(pconn, buf[0..en]);
        self.pumpRounds(rounds_per_step);
        if (!self.quiesce(400)) return error.DidNotConverge;
        if (!hasKey(leader, "j|life-1")) return error.EnqueueLost;
        _ = try self.assertConsistent(leader_idx); // present on every follower

        // 3. The pushed job landed on the worker connection; recover its lease.
        const resp = leader.backend.readResponse(wconn) orelse return error.FetchNotFulfilled;
        const job = parseFirstFetchedJob(resp) orelse return error.FetchClaimedNothing;
        if (!std.mem.eql(u8, job.id(), "life-1")) return error.WrongJobFetched;

        // 4. Ack done → auto-delete the completed job; replicate the deletion.
        const an = buildAckFrame(&buf, 203, job.id(), "lifeq", job.lease_token);
        leader.backend.injectRecv(wconn, buf[0..an]);
        self.pumpRounds(rounds_per_step);
        if (!self.quiesce(400)) return error.DidNotConverge;
        _ = leader.backend.readResponse(wconn); // discard ack resp

        // 5. Auto-delete replicated: the job record is gone everywhere.
        if (hasKey(leader, "j|life-1")) return error.AutoDeleteDidNotRun;
        for (self.nodes, 0..) |*n, i| {
            if (i == leader_idx or !n.ticking) continue;
            if (hasKey(n, "j|life-1")) return error.AutoDeleteNotReplicated;
        }
        _ = try self.assertConsistent(leader_idx); // still fully consistent
    }
};

// ============================================================================
// KV comparison helpers
// ============================================================================

/// Raft's own keys live under "r:" (r:meta/r:log:/r:snap:/r:applied). "r|" is
/// the user retry index and must NOT be excluded, so match the ':' explicitly.
fn isRaftKey(key: []const u8) bool {
    return key.len >= 2 and key[0] == 'r' and key[1] == ':';
}

fn skipRaftKeys(iter: *kv.Iterator, valid: bool) bool {
    var v = valid;
    while (v and isRaftKey(iter.key())) v = iter.next();
    return v;
}

fn compareUserKv(leader: *Node, follower: *Node) !void {
    var lb = leader.stores[0].newBatch();
    defer lb.close();
    var fb = follower.stores[0].newBatch();
    defer fb.close();

    var li = lb.newIter("\x00", "\xff");
    defer li.close();
    var fi = fb.newIter("\x00", "\xff");
    defer fi.close();

    var lv = skipRaftKeys(&li, li.first());
    var fv = skipRaftKeys(&fi, fi.first());
    var n: u32 = 0;

    while (lv and fv) {
        const lk = li.key();
        const fk = fi.key();
        if (!std.mem.eql(u8, lk, fk)) {
            std.debug.print("KV KEY MISMATCH @#{d}: leader({s})=", .{ n, leader.id });
            printKey(lk);
            std.debug.print(" follower({s})=", .{follower.id});
            printKey(fk);
            std.debug.print("\n", .{});
            return error.KvMismatch;
        }
        if (!std.mem.eql(u8, li.value(), fi.value())) {
            std.debug.print("KV VALUE MISMATCH key=", .{});
            printKey(lk);
            std.debug.print(" leader({s}) {d}B vs follower({s}) {d}B\n", .{ leader.id, li.value().len, follower.id, fi.value().len });
            return error.KvMismatch;
        }
        n += 1;
        lv = skipRaftKeys(&li, li.next());
        fv = skipRaftKeys(&fi, fi.next());
    }
    if (lv) {
        std.debug.print("KV EXTRA LEADER KEY @#{d} ({s}): ", .{ n, leader.id });
        printKey(li.key());
        std.debug.print(" — follower({s}) exhausted\n", .{follower.id});
        return error.KvMismatch;
    }
    if (fv) {
        std.debug.print("KV EXTRA FOLLOWER KEY @#{d} ({s}): ", .{ n, follower.id });
        printKey(fi.key());
        std.debug.print(" — leader({s}) exhausted\n", .{leader.id});
        return error.KvMismatch;
    }
}

/// FNV-1a over the user keyspace (excluding r:) — used to assert a node's KV
/// is unchanged across an operation.
fn userKvHash(node: *Node) u64 {
    var h: u64 = 0xcbf29ce484222325;
    var b = node.stores[0].newBatch();
    defer b.close();
    var it = b.newIter("\x00", "\xff");
    defer it.close();
    var v = it.first();
    while (v) : (v = it.next()) {
        const k = it.key();
        if (isRaftKey(k)) continue;
        for (k) |c| {
            h ^= c;
            h *%= 0x100000001b3;
        }
        h ^= 0xff; // key/value separator
        h *%= 0x100000001b3;
        for (it.value()) |c| {
            h ^= c;
            h *%= 0x100000001b3;
        }
        h ^= 0xfe; // record separator
        h *%= 0x100000001b3;
    }
    return h;
}

fn countPrefix(node: *Node, prefix: []const u8) usize {
    var count: usize = 0;
    var b = node.stores[0].newBatch();
    defer b.close();
    var it = b.newIter("\x00", "\xff");
    defer it.close();
    var v = it.first();
    while (v) : (v = it.next()) {
        const k = it.key();
        if (k.len >= prefix.len and std.mem.eql(u8, k[0..prefix.len], prefix)) count += 1;
    }
    return count;
}

fn hasKey(node: *Node, key: []const u8) bool {
    var b = node.stores[0].newBatch();
    defer b.close();
    var it = b.newIter("\x00", "\xff");
    defer it.close();
    var v = it.first();
    while (v) : (v = it.next()) {
        if (std.mem.eql(u8, it.key(), key)) return true;
    }
    return false;
}

fn printKey(key: []const u8) void {
    for (key) |c| {
        if (c >= 0x20 and c <= 0x7e) std.debug.print("{c}", .{c}) else std.debug.print("\\x{x:0>2}", .{c});
    }
}

// ============================================================================
// Raw frame builders (for precise control in scenarios d and e)
// ============================================================================

/// Build a minimal single-job MSG_ENQUEUE_BATCH frame into `buf` (mirrors the
/// field order in SimClient.doEnqueue with only the required fields). Returns
/// the total frame length.
fn buildEnqueueFrame(buf: []u8, req_id: u32, queue: []const u8, job_id: []const u8) usize {
    var w = rpc.BufWriter{ .buf = buf[rpc.FRAME_HEADER_SIZE..] };
    w.writeU16(1); // count
    w.writePrefixed(queue);
    w.writePrefixed(job_id);
    w.writeU8(128); // priority
    w.writeU16(3); // max_retries
    w.writeU8(0); // backoff strategy = none
    w.writeU32(0); // base_delay_ms
    w.writeU32(0); // max_delay_ms
    w.writeU32(0); // unique_period_s
    w.writeU64(0); // scheduled_at_ns
    w.writeU32(0); // expire_after_ms
    w.writeU16(0); // chain_step
    w.writeU16(rpc.FLAG_PAYLOAD); // flags
    w.writeU16Prefixed("{}"); // payload
    rpc.writeFrameHeader(buf[0..rpc.FRAME_HEADER_SIZE], rpc.MSG_ENQUEUE_BATCH, req_id, @intCast(w.pos));
    return rpc.FRAME_HEADER_SIZE + w.pos;
}

/// Build a MSG_FETCH_BATCH (subscribe) frame — mirrors SimClient.doFetch.
fn buildFetchFrame(buf: []u8, req_id: u32, worker: []const u8, queue: []const u8) usize {
    var w = rpc.BufWriter{ .buf = buf[rpc.FRAME_HEADER_SIZE..] };
    w.writeU16(1); // credits
    w.writeU32(30000); // lease_ms
    w.writePrefixed(worker);
    w.writeU8(1); // queue_count
    w.writePrefixed(queue);
    rpc.writeFrameHeader(buf[0..rpc.FRAME_HEADER_SIZE], rpc.MSG_FETCH_BATCH, req_id, @intCast(w.pos));
    return rpc.FRAME_HEADER_SIZE + w.pos;
}

/// Build a single-job MSG_ACK_BATCH frame (ack_status = done) into `buf`.
fn buildAckFrame(buf: []u8, req_id: u32, job_id: []const u8, queue: []const u8, lease_token: u64) usize {
    var w = rpc.BufWriter{ .buf = buf[rpc.FRAME_HEADER_SIZE..] };
    w.writeU16(1); // count
    w.writePrefixed(job_id);
    w.writePrefixed(queue);
    w.writeU8(0); // ack_status = done
    w.writeU8(rpc.ACK_FLAG_LEASE_TOKEN); // flags
    w.writeU64(lease_token);
    rpc.writeFrameHeader(buf[0..rpc.FRAME_HEADER_SIZE], rpc.MSG_ACK_BATCH, req_id, @intCast(w.pos));
    return rpc.FRAME_HEADER_SIZE + w.pos;
}

const FetchedJob = struct {
    id_buf: [64]u8 = undefined,
    id_len: usize = 0,
    lease_token: u64 = 0,
    fn id(self: *const FetchedJob) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

/// Scan `resp` for the first MSG_FETCH_BATCH_RESP frame and parse its first
/// job (id + lease token). Mirrors SimClient.parseFetchPayload's wire layout.
fn parseFirstFetchedJob(resp: []const u8) ?FetchedJob {
    var pos: usize = 0;
    while (pos + rpc.FRAME_HEADER_SIZE <= resp.len) {
        const hdr = rpc.readFrameHeader(resp[pos..]) orelse break;
        const body_start = pos + rpc.FRAME_HEADER_SIZE;
        const body_end = body_start + hdr.payload_len;
        if (body_end > resp.len) break;
        if (hdr.msg_type == rpc.MSG_FETCH_BATCH_RESP) {
            var r = rpc.BufReader{ .data = resp[body_start..body_end] };
            const count = r.readU16() catch return null;
            if (count == 0) return null;
            const job_id = r.readPrefixed() catch return null;
            _ = r.readPrefixed() catch return null; // queue
            _ = r.readU16() catch return null; // attempt
            _ = r.readU16() catch return null; // max_retries
            _ = r.readPrefixed() catch return null; // checkpoint
            _ = r.readPrefixed() catch return null; // tags
            const plen = r.readU32() catch return null;
            r.skip(plen) catch return null;
            const lease_token = r.readU64() catch return null;
            var out = FetchedJob{ .lease_token = lease_token };
            const n = @min(job_id.len, out.id_buf.len);
            @memcpy(out.id_buf[0..n], job_id[0..n]);
            out.id_len = n;
            return out;
        }
        pos = body_end;
    }
    return null;
}

/// Return the msg_type of the first RPC frame in `resp`, or null if empty.
fn firstFrameType(resp: []const u8) ?u8 {
    if (resp.len < rpc.FRAME_HEADER_SIZE) return null;
    const hdr = rpc.readFrameHeader(resp) orelse return null;
    return hdr.msg_type;
}

/// True if any frame in `resp` has the given msg_type.
fn respHasType(resp: []const u8, msg_type: u8) bool {
    var pos: usize = 0;
    while (pos + rpc.FRAME_HEADER_SIZE <= resp.len) {
        const hdr = rpc.readFrameHeader(resp[pos..]) orelse break;
        if (hdr.msg_type == msg_type) return true;
        pos += rpc.FRAME_HEADER_SIZE + hdr.payload_len;
    }
    return false;
}

fn deleteDbFiles(path: []const u8) void {
    std.fs.cwd().deleteFile(path) catch {};
    var vlog_buf: [256]u8 = undefined;
    const vlog = std.fmt.bufPrint(&vlog_buf, "{s}.vlog", .{path}) catch return;
    std.fs.cwd().deleteFile(vlog) catch {};
}

// ============================================================================
// Scenario runners
// ============================================================================

const Stats = struct {
    enqueued: u32 = 0,
    fetched: u32 = 0,
    acked: u32 = 0,
    failed: u32 = 0,
    applied: u64 = 0,
    leader_jobs: usize = 0,
};

const rounds_per_step: u32 = 8;

/// Drive `steps` super-steps of adversarial client traffic through the leader,
/// quiesce, and assert full KV convergence. Used by scenarios a/b/c.
fn runReplication(
    allocator: std.mem.Allocator,
    node_count: u8,
    seed: u64,
    num_clients: u32,
    num_queues: u32,
    steps: u32,
    check_lifecycle: bool,
) !Stats {
    var clock = SimClock.init(1_000_000_000_000);
    setGlobalClock(&clock);

    var cluster = try Cluster.init(allocator, node_count, &clock);
    defer cluster.deinit();

    const leader_idx = try cluster.electLeaderLeading(400);

    // Queue names.
    var q_bufs: [8][24]u8 = undefined;
    var q_slices: [8][]const u8 = undefined;
    const qn = @min(num_queues, 8);
    for (0..qn) |i| q_slices[i] = std.fmt.bufPrint(&q_bufs[i], "q{d}", .{i}) catch unreachable;
    const queues = q_slices[0..qn];

    // Clients connect to the leader's backend.
    var client_cfg = Config{};
    client_cfg.maintenance_rate = 0; // pipeline owns maintenance
    client_cfg.time_jump_prob = 0; // keep raft timing deterministic/stable

    const nc = @min(num_clients, max_clients);
    var clients: [max_clients]SimClient = undefined;
    for (0..nc) |i| {
        const conn = cluster.nodes[leader_idx].backend.connect() orelse unreachable;
        clients[i] = SimClient.init(@intCast(i), seed +% i +% 1, &cluster.nodes[leader_idx].backend, conn, client_cfg, queues);
        clients[i].rng = clients[i].prng.random();
    }

    // Main loop: inject → pump → read responses.
    var step: u32 = 0;
    while (step < steps) : (step += 1) {
        for (clients[0..nc]) |*c| c.inject();
        cluster.pumpRounds(rounds_per_step);
        for (clients[0..nc]) |*c| c.processResponse();
    }

    // Final convergence + consistency check.
    if (!cluster.quiesce(600)) return error.DidNotConverge;
    // Leadership must have stayed stable for the traffic to be meaningful.
    if (cluster.leaderIdx().? != leader_idx) return error.LeadershipChurned;
    const leader_jobs = try cluster.assertConsistent(leader_idx);

    // Explicit completed-job lifecycle: enqueue → fetch → ack → auto-delete,
    // asserting the deletion replicates to every follower.
    if (check_lifecycle) try cluster.assertLifecycleReplicates(leader_idx);

    var s = Stats{ .applied = cluster.nodes[leader_idx].runtime.fsm.lastApplied(), .leader_jobs = leader_jobs };
    for (clients[0..nc]) |c| {
        s.enqueued += c.enqueued;
        s.fetched += c.fetched;
        s.acked += c.acked;
        s.failed += c.failed;
    }
    return s;
}

// ============================================================================
// Tests
// ============================================================================
//
// NOTE ON THE ALLOCATOR: these use page_allocator, matching the (deleted) PBR
// cluster sim's documented decision. The multi-node write path has intentionally
// complex, refcounted cross-component ownership (ProposeTokens shared between
// each Pipeline and its Runtime batcher, per-proposal arenas handed to the
// batcher, N talon DBs). Correctness here is proven by KV convergence, not by
// the testing allocator's leak counter; deinit still tears every component down
// in order (pipeline release → runtime failAll → arenas).

const sim_allocator = std.heap.page_allocator;

test "cluster raft: 3 nodes — enqueue replication converges" {
    // Scenario (a): 3 nodes, elect a leader, drive client traffic through the
    // leader's pipeline, quiesce, assert all 3 KV states match and jobs are
    // present on the followers.
    const s = try runReplication(sim_allocator, 3, 42, 2, 1, 60, false);
    try std.testing.expect(s.applied > 0);
    try std.testing.expect(s.leader_jobs > 0); // jobs present/pending on followers (checked equal)
    std.debug.print(
        "OK 3n enqueue-repl: enq={d} fetch={d} ack={d} fail={d} applied={d} jobs={d}\n",
        .{ s.enqueued, s.fetched, s.acked, s.failed, s.applied, s.leader_jobs },
    );
}

test "cluster raft: 3 nodes — multi-queue fetch/ack lifecycle replication" {
    // Scenario (b): multi-queue enqueue + subscribe + fulfill + ack/fail
    // through the leader. Auto-delete of completed jobs replicates via the
    // ack path; convergence proves the whole lifecycle stays consistent.
    const s = try runReplication(sim_allocator, 3, 20260707, 3, 3, 80, true);
    try std.testing.expect(s.applied > 0);
    try std.testing.expect(s.enqueued > 0);
    std.debug.print(
        "OK 3n lifecycle: enq={d} fetch={d} ack={d} fail={d} applied={d} jobs={d}\n",
        .{ s.enqueued, s.fetched, s.acked, s.failed, s.applied, s.leader_jobs },
    );
}

test "cluster raft: 5 nodes — enqueue replication converges" {
    // Scenario (c): same as (a) with 5 voters.
    const s = try runReplication(sim_allocator, 5, 777, 2, 1, 60, false);
    try std.testing.expect(s.applied > 0);
    try std.testing.expect(s.leader_jobs > 0);
    std.debug.print(
        "OK 5n enqueue-repl: enq={d} fetch={d} ack={d} fail={d} applied={d} jobs={d}\n",
        .{ s.enqueued, s.fetched, s.acked, s.failed, s.applied, s.leader_jobs },
    );
}

test "cluster raft: failover — deposed leader evicts subscriber, new leader serves" {
    // Scenario (d): partition the leader mid-life (kept ticking, so it steps
    // down live via CheckQuorum — exercising canWriteLocally +
    // evictWaitingSubscribers, not a silent crash). A new leader wins with the
    // surviving quorum, serves writes after its barrier commits, and every node
    // (including the reconnected old leader) converges with no divergence panic.
    const allocator = sim_allocator;
    var clock = SimClock.init(1_000_000_000_000);
    setGlobalClock(&clock);

    var cluster = try Cluster.init(allocator, 3, &clock);
    defer cluster.deinit();

    const old_leader = try cluster.electLeaderLeading(400);

    // --- Baseline traffic through the first leader. ---
    var q_buf: [8]u8 = undefined;
    const q0 = std.fmt.bufPrint(&q_buf, "q0", .{}) catch unreachable;
    var queues = [_][]const u8{q0};
    var cfg = Config{};
    cfg.maintenance_rate = 0;
    cfg.time_jump_prob = 0;

    const base_conn = cluster.nodes[old_leader].backend.connect() orelse unreachable;
    var client = SimClient.init(0, 99, &cluster.nodes[old_leader].backend, base_conn, cfg, queues[0..]);
    client.rng = client.prng.random();
    var step: u32 = 0;
    while (step < 30) : (step += 1) {
        client.inject();
        cluster.pumpRounds(rounds_per_step);
        client.processResponse();
    }
    try std.testing.expect(cluster.quiesce(600));
    _ = try cluster.assertConsistent(old_leader);

    // --- Register a waiting subscriber on the (still) leader for an EMPTY
    // queue, so it stays subscribed (nothing to fulfill). ---
    const sub_conn = cluster.nodes[old_leader].backend.connect() orelse unreachable;
    var frame_buf: [256]u8 = undefined;
    const fn_len = buildFetchFrame(&frame_buf, 1, "watcher", "dq-empty");
    cluster.nodes[old_leader].backend.injectRecv(sub_conn, frame_buf[0..fn_len]);
    cluster.nodes[old_leader].pipeline.tick();
    try std.testing.expect(cluster.nodes[old_leader].pipeline.waiting_conn_count >= 1);

    // --- Partition the old leader (kept ticking → steps down via CheckQuorum). ---
    cluster.setPartition(old_leader, false);

    var new_leader: ?usize = null;
    var r: u32 = 0;
    while (r < 200) : (r += 1) {
        cluster.pumpRound();
        const dep = &cluster.nodes[old_leader];
        const deposed = !dep.runtime.node.isLeader() and dep.pipeline.raft_state == .follower;
        if (deposed) {
            if (cluster.leaderIdx()) |li| {
                if (li != old_leader and cluster.nodes[li].pipeline.raft_state == .leading) {
                    new_leader = li;
                    break;
                }
            }
        }
    }
    try std.testing.expect(new_leader != null);
    const nl = new_leader.?;
    try std.testing.expect(nl != old_leader);

    // Deposed node stepped down and refuses local writes.
    try std.testing.expect(!cluster.nodes[old_leader].runtime.node.isLeader());
    try std.testing.expect(cluster.nodes[old_leader].pipeline.raft_state == .follower);

    // The waiting subscriber was evicted with MSG_NOT_LEADER on step-down.
    const evict_resp = cluster.nodes[old_leader].backend.readResponse(sub_conn);
    try std.testing.expect(evict_resp != null);
    try std.testing.expect(respHasType(evict_resp.?, rpc.MSG_NOT_LEADER));

    // --- Reconnect old leader; new leader serves fresh writes; all converge. ---
    cluster.setPartition(old_leader, true);
    const nlc = cluster.nodes[nl].backend.connect() orelse unreachable;
    var client2 = SimClient.init(1, 4242, &cluster.nodes[nl].backend, nlc, cfg, queues[0..]);
    client2.rng = client2.prng.random();
    step = 0;
    while (step < 25) : (step += 1) {
        client2.inject();
        cluster.pumpRounds(rounds_per_step);
        client2.processResponse();
    }

    try std.testing.expect(cluster.quiesce(800));
    try std.testing.expect(cluster.leaderIdx().? == nl);
    const jobs = try cluster.assertConsistent(nl); // all 3 nodes converge
    try std.testing.expect(client2.enqueued > 0); // new leader actually served writes
    std.debug.print(
        "OK failover: old={s} new={s} post-enq={d} applied={d} jobs={d}\n",
        .{ cluster.nodes[old_leader].id, cluster.nodes[nl].id, client2.enqueued, cluster.nodes[nl].runtime.fsm.lastApplied(), jobs },
    );
}

test "cluster raft: non-leader rejects write with MSG_NOT_LEADER, no mutation" {
    // Scenario (e): a follower answers a client enqueue with MSG_NOT_LEADER and
    // mutates nothing. Exercises the pipeline leadership gate + the
    // notifyForFrame err-skip (a rejected frame records no notify / no
    // fulfillment). We tick ONLY the follower's Pipeline (not its Runtime) so
    // replication can't change its KV — isolating the rejected write.
    const allocator = sim_allocator;
    var clock = SimClock.init(1_000_000_000_000);
    setGlobalClock(&clock);

    var cluster = try Cluster.init(allocator, 3, &clock);
    defer cluster.deinit();

    const leader_idx = try cluster.electLeaderLeading(400);

    // Some baseline traffic so followers hold real replicated job state.
    var q_buf: [8]u8 = undefined;
    const q0 = std.fmt.bufPrint(&q_buf, "q0", .{}) catch unreachable;
    var queues = [_][]const u8{q0};
    var cfg = Config{};
    cfg.maintenance_rate = 0;
    cfg.time_jump_prob = 0;
    const conn = cluster.nodes[leader_idx].backend.connect() orelse unreachable;
    var client = SimClient.init(0, 7, &cluster.nodes[leader_idx].backend, conn, cfg, queues[0..]);
    client.rng = client.prng.random();
    var step: u32 = 0;
    while (step < 30) : (step += 1) {
        client.inject();
        cluster.pumpRounds(rounds_per_step);
        client.processResponse();
    }
    try std.testing.expect(cluster.quiesce(600));
    _ = try cluster.assertConsistent(leader_idx);

    // Pick a follower.
    var follower_idx: usize = undefined;
    for (0..cluster.nodes.len) |i| {
        if (i != leader_idx) {
            follower_idx = i;
            break;
        }
    }
    const follower = &cluster.nodes[follower_idx];

    // Snapshot the follower's user KV, then inject an enqueue and tick ONLY its
    // pipeline (no runtime → no replication apply this step).
    const before = userKvHash(follower);
    const before_jobs = countPrefix(follower, "j|");

    const fconn = follower.backend.connect() orelse unreachable;
    var frame_buf: [256]u8 = undefined;
    const flen = buildEnqueueFrame(&frame_buf, 1, "q0", "reject-me-xyz");
    follower.backend.injectRecv(fconn, frame_buf[0..flen]);
    follower.pipeline.tick();

    // Response is MSG_NOT_LEADER and nothing else (no fulfillment push).
    const resp = follower.backend.readResponse(fconn);
    try std.testing.expect(resp != null);
    try std.testing.expectEqual(@as(?u8, rpc.MSG_NOT_LEADER), firstFrameType(resp.?));
    try std.testing.expect(!respHasType(resp.?, rpc.MSG_FETCH_BATCH_RESP));

    // KV unchanged; the rejected job never landed.
    try std.testing.expectEqual(before, userKvHash(follower));
    try std.testing.expectEqual(before_jobs, countPrefix(follower, "j|"));
    try std.testing.expect(!hasKey(follower, "j|reject-me-xyz"));
    std.debug.print("OK reject: follower {s} answered MSG_NOT_LEADER, KV intact\n", .{follower.id});
}

test "cluster raft: deterministic — same seed reproduces identical stats" {
    // Determinism check: two independent runs with the same seed must produce
    // byte-identical outcomes.
    const a = try runReplication(sim_allocator, 3, 12345, 2, 2, 40, false);
    const b = try runReplication(sim_allocator, 3, 12345, 2, 2, 40, false);
    try std.testing.expectEqual(a.enqueued, b.enqueued);
    try std.testing.expectEqual(a.fetched, b.fetched);
    try std.testing.expectEqual(a.acked, b.acked);
    try std.testing.expectEqual(a.failed, b.failed);
    try std.testing.expectEqual(a.applied, b.applied);
    try std.testing.expectEqual(a.leader_jobs, b.leader_jobs);
    std.debug.print("OK deterministic: enq={d} applied={d} jobs={d}\n", .{ a.enqueued, a.applied, a.leader_jobs });
}
