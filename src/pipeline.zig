//! Pipeline — single-threaded tick loop, generic over IoBackend.
//!
//! THE write path. One thread, one event loop, zero synchronization.
//!
//! Tick loop:
//!   io.drain()         → completions
//!   extractFrames()    → FrameDesc[]
//!   executeBatch()     → results[]   (single kv.Batch commit)
//!   encodeResponses()  → send_bufs
//!   io.submit()

const std = @import("std");
const posix = std.posix;
const io_mod = @import("io.zig");
const rpc = @import("rpc.zig");
const http = @import("http.zig");
const http_read = @import("http_read.zig");
const kv_read = @import("kv_read.zig");
const ops_mod = @import("ops.zig");
const kv = @import("kv.zig");
const handler_mod = @import("handler.zig");
const handler_fetch = @import("handler_fetch.zig");
const notify_mod = @import("notify.zig");
const assert = @import("assert.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const types = @import("types.zig");
const webhook_mod = @import("webhook.zig");

const OpHandler = handler_mod.OpHandler;
const QueueNotifier = notify_mod.QueueNotifier;
const ConnState = io_mod.ConnState;
const Protocol = ConnState.Protocol;
const Completion = io_mod.Completion;
const BufReader = rpc.BufReader;
const BufWriter = rpc.BufWriter;

// ========================================================================
// RaftIface — consensus vtable (module-level, backend-agnostic)
// ========================================================================

const raft_host_mod = @import("raft_host.zig");
const raft_gate = @import("raft_gate.zig");

pub const ProposeToken = raft_host_mod.ProposeToken;
pub const TokenState = raft_host_mod.TokenState;

/// Cluster mode replicates each batch's recorded mutations through raft.
/// The pipeline proposes after its local commit and defers the batch's
/// client responses until the returned token commits (see docs/raft-wiring.md).
/// Vtable (not a concrete *RaftHost) so tests can drive token state directly.
pub const RaftIface = struct {
    ptr: *anyopaque,
    /// Deep-copies mutations; returns null on inbox back-pressure.
    propose_fn: *const fn (ptr: *anyopaque, muts: []const kv.Mutation) ?*ProposeToken,
    is_leader_fn: *const fn (ptr: *anyopaque) bool,

    pub fn propose(self: RaftIface, muts: []const kv.Mutation) ?*ProposeToken {
        return self.propose_fn(self.ptr, muts);
    }
    pub fn isLeader(self: RaftIface) bool {
        return self.is_leader_fn(self.ptr);
    }
};

/// Sentinel err for write frames rejected at a non-leader. encodeResponses
/// turns it into MSG_NOT_LEADER (RPC) or 503 (HTTP) instead of a generic error.
pub const err_not_leader: []const u8 = "not_leader";

/// Sentinel err for an enqueue frame whose recorded mutations would exceed one
/// raft entry's payload cap (cluster mode only). Rejected at the boundary —
/// before handler.apply — so a legal-but-amplifying batch (job records inline
/// tags; each tag repeats queue+id in a tq| index key) can never drive the
/// per-frame proposal-cap assert in proposeRecordedFrames. Client input is a
/// boundary → error, never an assert. http.encodeWriteResponse maps it to 413.
pub const err_too_large: []const u8 = "batch too large for replication";

pub fn Pipeline(comptime IoBackend: type) type {
    return struct {
        const Self = @This();

        io: *IoBackend,
        handler: *OpHandler,
        stores: []kv.Store,
        notify: *QueueNotifier,
        reader: ?*kv_read.Reader,
        config: Config,
        allocator: std.mem.Allocator,
        mut_list: std.ArrayList(kv.Mutation) = .{},

        // HTTP decode scratch (reused per tick)
        http_scratch: http.DecodeScratch = .{},
        http_id_counter: u64 = 0,
        http_id_bufs: [max_frames][64]u8 = undefined,

        // Frame tracking for current tick
        frames: [max_frames]FrameDesc = undefined,
        frame_count: u32 = 0,

        // Results from execute stage
        results: [max_frames]ops_mod.OpResult = undefined,

        // Mutation-list end offset per frame (raft mode): executeBatch
        // records where each frame's mutations end so the proposal can be
        // split at frame boundaries — one client op never spans two raft
        // entries (its mutations must apply atomically on followers).
        frame_mut_ends: [max_frames]u32 = undefined,

        // Recv compaction tracking: (conn_id, consumed_bytes) pairs
        recv_compactions: [max_completions]RecvCompaction = undefined,
        recv_compaction_count: u32 = 0,

        // Completion buffer for io.drain()
        completions: [max_completions]Completion = undefined,

        // Pre-allocated scratch buffers for RPC decode (reused per frame)
        jobs_buf: [max_batch_jobs]ops_mod.EnqueueJob = undefined,
        acks_buf: [max_batch_jobs]ops_mod.AckJob = undefined,
        fails_buf: [max_batch_jobs]ops_mod.FailJob = undefined,
        hb_ids_buf: [max_batch_jobs][]const u8 = undefined,
        hb_ops_buf: [max_batch_jobs]ops_mod.HeartbeatJobOp = undefined,
        bulk_ids_buf: [max_batch_jobs][]const u8 = undefined,

        // Send tracking: connections with data to flush (populated by encode + fulfill)
        send_conns: [max_frames + max_waiting_conns]u16 = undefined,
        send_conn_count: u32 = 0,

        // Fetch subscription tracking
        waiting_conns: [max_waiting_conns]u16 = [_]u16{0} ** max_waiting_conns,
        waiting_conn_count: u32 = 0,

        // Notified queues this tick (collected during notifyForFrame)
        notified_queue_bufs: [max_notified_queues][64]u8 = undefined,
        notified_queue_lens: [max_notified_queues]u8 = [_]u8{0} ** max_notified_queues,
        notified_queue_count: u32 = 0,

        // Maintenance scheduling
        last_promote_ns: u64 = 0,
        last_reclaim_ns: u64 = 0,
        last_unique_ns: u64 = 0,
        last_rate_limit_ns: u64 = 0,
        last_expire_ns: u64 = 0,
        last_purge_ns: u64 = 0,
        last_workers_ns: u64 = 0,
        last_cron_ns: u64 = 0,
        last_webhook_ns: u64 = 0,

        // Raft replication — pipelined prepares.
        // Up to max_prepare_slots batches can be in-flight. Each slot holds
        // deferred sends + recv requeues until every proposal token the slot
        // carries commits. Tokens are written by the raft thread (atomic
        // state), polled here — single shared state per proposal.
        prepare_slots: [max_prepare_slots]PrepareSlot = [_]PrepareSlot{.{}} ** max_prepare_slots,
        prepare_head: u32 = 0,
        prepare_tail: u32 = 0,
        prepare_count: u32 = 0,
        // Recv connections that arrived while all prepare slots were full.
        // CQEs consumed but data is in recv_buf. Processed when a slot frees up.
        deferred_recv_conns: [max_completions]u16 = undefined,
        deferred_recv_conn_count: u32 = 0,

        // Leadership state machine (raft mode only; see docs/raft-wiring.md).
        // follower: write frames answered MSG_NOT_LEADER/503, no maintenance.
        // acquiring: barrier proposal in flight; on commit the local FSM has
        //   applied every prior term's entry, so the in-memory handler state
        //   is rebuilt from KV before accepting writes.
        // leading: normal write path.
        raft_state: RaftState = .follower,
        barrier_token: ?*ProposeToken = null,
        // Proposal tokens produced this tick (frame batch + maintenance
        // batches); attached to the batch's prepare slot at the end of tick.
        tick_tokens: [max_tick_tokens]*ProposeToken = undefined,
        tick_token_count: u32 = 0,
        // Maintenance-only proposals from frameless ticks: nothing to defer,
        // but every token must still be polled for divergence + released.
        // Bounded: maintenance is interval-gated, commit latency is ms-scale.
        maint_tokens: [max_maint_tokens]*ProposeToken = undefined,
        maint_token_count: u32 = 0,

        // Stats
        ticks_total: u64 = 0,
        applied_total: u64 = 0,
        subscriptions_fulfilled: u64 = 0,
        maintenance_runs: u64 = 0,

        // Per-phase timing accumulators (nanoseconds). Reset every 100 ticks.
        // Set enable_phase_timing to true to profile tick phases.
        // When false, Timer becomes a no-op struct — zero cost at comptime.
        phase_drain_ns: u64 = 0,
        phase_extract_ns: u64 = 0,
        phase_execute_ns: u64 = 0,
        phase_encode_ns: u64 = 0,
        phase_fulfill_ns: u64 = 0,
        phase_flush_ns: u64 = 0,
        phase_compact_ns: u64 = 0,
        phase_requeue_ns: u64 = 0,
        phase_submit_ns: u64 = 0,
        phase_cancel_ns: u64 = 0,
        phase_webhook_ns: u64 = 0,
        phase_maint_ns: u64 = 0,
        phase_ticks: u64 = 0,
        phase_frames: u64 = 0,
        phase_fulfills: u64 = 0,

        // Sub-phase accumulators for executeBatch breakdown.
        exec_apply_ns: u64 = 0,
        exec_commit_ns: u64 = 0,
        exec_notify_ns: u64 = 0,
        exec_oplog_ns: u64 = 0,
        exec_ticks: u64 = 0,

        // Phase timing — flip to true to profile tick phases.
        const enable_phase_timing = false;

        const Timer = if (enable_phase_timing) struct {
            t: i64,
            pub fn start(clock: *const fn () i64) @This() {
                return .{ .t = clock() };
            }
            pub fn elapsed(self: @This(), clock: *const fn () i64) u64 {
                return @intCast(@max(0, clock() - self.t));
            }
        } else struct {
            pub fn start(_: anytype) @This() { return .{}; }
            pub fn elapsed(_: @This(), _: anytype) u64 { return 0; }
        };

        fn addPhase(val: *u64, ns: u64) void {
            if (enable_phase_timing) val.* +|= ns;
        }

        const max_batch_jobs = rpc.MAX_BATCH_JOBS;
        const max_frames: u32 = 256;
        const max_completions: u32 = 256;
        /// recv conns for a tick = fresh completions ∪ deferred-recv conns, which
        /// can be disjoint, so the collection must hold both sets (each bounded by
        /// max_completions) to avoid a stack buffer overflow when merging them.
        const max_recv_conns: u32 = 2 * max_completions;
        /// Sized for the connection target (20k+). waiting_conns and the
        /// PrepareSlot send buffers hold at most one entry per connection, so
        /// this bounds them for the 20k-connection goal; the 4096 default made
        /// the 4097th subscriber panic (M6). The Pipeline is heap-allocated in
        /// production (initHeap) and inside the heap TestContext, so the larger
        /// inline arrays are stack-safe. storeSubscription also rejects
        /// gracefully rather than asserting if this is ever exceeded.
        const max_waiting_conns: u32 = 20480;
        const max_notified_queues: u32 = 64;
        const max_prepare_slots: u32 = 4;
        /// Upper bound on parked non-frame (maintenance + fulfill-claim)
        /// proposal tokens in flight at once. Both come from proposeRecorded's
        /// byte-split batches; this is the same cap parkTickTokens enforces on
        /// the maint_tokens ring.
        const max_maint_tokens: u32 = 192;
        /// Worst-case proposal tokens accumulated in `tick_tokens` within one
        /// tick, before they are copied into a PrepareSlot. In a frame-carrying
        /// tick three sources feed the same array, in order:
        ///   1. runMaintenance      → proposeRecorded (byte-split maint batch)
        ///   2. executeBatch        → proposeRecordedFrames
        ///   3. fulfillSubscriptions → proposeRecorded (byte-split fetch claims)
        /// proposeRecordedFrames splits at FRAME granularity, so (2) alone can
        /// emit one token per frame — up to max_frames. The old estimate (~125)
        /// assumed perfect byte packing, which frame splitting does not give,
        /// and undersized this so the 161st proposeSlice panicked under legal
        /// heavy load. (1)+(3) are byte-split and together bounded by
        /// max_maint_tokens (the same in-flight cap parkTickTokens enforces).
        /// Sum bounds the array; PrepareSlot.tokens is sized identically. Each
        /// element is a *ProposeToken (one pointer), so the larger array costs
        /// only (max_tick_tokens × 8) bytes per Pipeline plus per PrepareSlot.
        const max_tick_tokens: u32 = max_frames + max_maint_tokens;
        /// Per-proposal byte budget — one raft entry's payload cap. The
        /// batcher rejects anything larger (ProposalTooLarge → failed token
        /// → false divergence panic), so the pipeline splits BELOW this.
        const max_proposal_bytes: usize = @import("raft_batcher.zig").max_entry_bytes;

        const RaftState = enum { follower, acquiring, leading };

        /// Pipelined prepare slot for raft replication. Holds deferred
        /// sends and recv requeues until every carried token commits.
        const PrepareSlot = struct {
            send_conns: [max_frames + max_waiting_conns]u16 = undefined,
            send_conn_count: u32 = 0,
            recv_conns: [max_recv_conns]u16 = undefined,
            recv_conn_count: u32 = 0,
            tokens: [max_tick_tokens]*ProposeToken = undefined,
            token_count: u32 = 0,
        };


        // ====================================================================
        // Config
        // ====================================================================

        pub const Config = struct {
            clock_fn: *const fn () i64,
            batch_max: u32 = 256,
            max_payload_size: u32 = 64 * 1024,
            promote_interval_ns: u64 = 0,
            reclaim_interval_ns: u64 = 0,
            unique_interval_ns: u64 = 0,
            rate_limit_interval_ns: u64 = 0,
            expire_interval_ns: u64 = 0,
            purge_interval_ns: u64 = 0,
            purge_retention_ns: u64 = 14 * 24 * 3_600_000_000_000,
            /// Terminal-job count that triggers an early purge pass, independent
            /// of purge_interval_ns. 0 = only the interval triggers purge.
            purge_threshold: u32 = 0,
            workers_interval_ns: u64 = 0,
            /// How often to scan cron schedules for due fires. Cron resolution is
            /// one minute, so a 10s check fires within seconds of each boundary.
            cron_interval_ns: u64 = 0,
            webhook_interval_ns: u64 = 0,
            worker_timeout_ns: u64 = 60_000_000_000,
            /// Raft consensus hook. Non-null = cluster mode: every batch with
            /// mutations is proposed after its local commit and responses are
            /// deferred until the token commits. Replication is always
            /// synchronous — a raft commit IS quorum replication.
            raft: ?RaftIface = null,
            /// Serializes talon access between this thread and the raft
            /// thread (talon's batch pool and root swap are single-threaded).
            /// Held for the post-drain span of each tick — never across the
            /// blocking io.drain. Null in single-node mode (no raft thread).
            db_lock: ?*std.Thread.Mutex = null,
            /// Adaptive batch coalescing window for raft replication
            /// (nanoseconds). When a drain yields fewer than max_frames, the
            /// pipeline continues collecting frames via non-blocking drains
            /// until the batch is full or this window elapses. Zero disables
            /// coalescing. Only applies in raft mode.
            coalesce_window_ns: u64 = 0, // set by main.zig for production
            admin_password: []const u8 = "",
        };

        // ====================================================================
        // Internal types
        // ====================================================================

        const FrameDesc = struct {
            conn_id: u16,
            req_id: u32,
            msg_type: u8,
            payload: []const u8,
            count: u16 = 0,
            protocol: Protocol = .rpc,
            path_param: []const u8 = "",
            sub_action: []const u8 = "",
            http_path: []const u8 = "", // full path including query string (for webhook query params)
            actor: [128]u8 = undefined,
            actor_len: u8 = 0,

            fn actorSlice(self: *const FrameDesc) []const u8 {
                return self.actor[0..self.actor_len];
            }
        };

        const RecvCompaction = struct {
            conn_id: u16,
            consumed: u32,
        };

        // ====================================================================
        // Lifecycle
        // ====================================================================

        pub fn init(
            allocator: std.mem.Allocator,
            io_backend: *IoBackend,
            handler: *OpHandler,
            stores: []kv.Store,
            notify: *QueueNotifier,
            reader: ?*kv_read.Reader,
            config: Config,
        ) Self {
            return .{
                .io = io_backend,
                .handler = handler,
                .stores = stores,
                .notify = notify,
                .reader = reader,
                .config = config,
                .allocator = allocator,
                // Single-node has no leadership to acquire — writes flow
                // immediately. Raft mode starts as follower until the host
                // reports leadership and the barrier commits.
                .raft_state = if (config.raft == null) .leading else .follower,
            };
        }

        /// Heap-allocate the pipeline. The struct is ~5MB due to inline
        /// scratch buffers — too large for the default 8MB thread stack.
        pub fn initHeap(
            allocator: std.mem.Allocator,
            io_backend: *IoBackend,
            handler: *OpHandler,
            stores: []kv.Store,
            notify: *QueueNotifier,
            reader: ?*kv_read.Reader,
            config: Config,
        ) *Self {
            const self = allocator.create(Self) catch unreachable;
            self.* = init(allocator, io_backend, handler, stores, notify, reader, config);
            return self;
        }

        pub fn deinit(self: *Self) void {
            // Drop our reference on any in-flight proposal tokens (abandon is
            // safe: the raft host's finish path frees the last reference).
            var si = self.prepare_head;
            var remaining = self.prepare_count;
            while (remaining > 0) : (remaining -= 1) {
                const slot = &self.prepare_slots[si];
                for (slot.tokens[0..slot.token_count]) |token| token.release();
                slot.token_count = 0;
                si = (si + 1) % max_prepare_slots;
            }
            for (self.maint_tokens[0..self.maint_token_count]) |token| token.release();
            self.maint_token_count = 0;
            for (self.tick_tokens[0..self.tick_token_count]) |token| token.release();
            self.tick_token_count = 0;
            if (self.barrier_token) |token| token.release();
            self.barrier_token = null;

            for (self.mut_list.items) |m| {
                if (m.key.len > 0) self.allocator.free(@constCast(m.key));
                if (m.value.len > 0 and m.op != .delete) self.allocator.free(@constCast(m.value));
            }
            self.mut_list.deinit(self.allocator);
        }

        /// Seed maintenance timestamps and clean stale workers before accepting
        /// connections. Purge runs on its normal interval — it can be slow with
        /// large backlogs and doesn't affect correctness.
        pub fn warmup(self: *Self) void {
            const now_ns = self.nowNs();

            // Seed all timestamps so normal intervals start from now.
            self.last_promote_ns = now_ns;
            self.last_reclaim_ns = now_ns;
            self.last_unique_ns = now_ns;
            self.last_rate_limit_ns = now_ns;
            self.last_expire_ns = now_ns;
            self.last_purge_ns = now_ns;
            self.last_workers_ns = now_ns;
            self.last_cron_ns = now_ns;
            self.last_webhook_ns = now_ns;

            // Clean stale workers so the UI doesn't show ghosts.
            self.handler.resetEffects();
            var batch = self.stores[0].newBatch();
            defer batch.close();

            // Load webhook cache from KV.
            self.handler.loadWebhookCache(&batch);
            std.debug.print("corvo: warmup — loaded {d} webhooks\n", .{self.handler.webhook_cache_count});

            const t0 = self.config.clock_fn();
            const cutoff = now_ns -| self.config.worker_timeout_ns;
            const op = ops_mod.OpData{ .maintenance = .{ .action = .workers, .now_ns = now_ns, .cutoff_ns = cutoff } };
            const result = self.handler.apply(&batch, .maintenance, &op);
            const elapsed_us: u64 = @intCast(@max(0, self.config.clock_fn() - t0));
            std.debug.print("corvo: warmup — cleaned {d} stale workers ({d}us)\n", .{ result.affected, elapsed_us });

            batch.commit();
        }

        pub fn destroyHeap(self: *Self) void {
            const alloc = self.allocator;
            self.deinit();
            alloc.destroy(self);
        }

        // ====================================================================
        // Tick — the entire event loop body
        // ====================================================================

        pub fn tick(self: *Self) void {
            // ---- Phase 0: Leadership + frameless maintenance tokens ----
            self.tickRaftLeadership();
            self.pollMaintTokens();

            // ---- Phase 1: Flush committed prepare slots (FIFO order) ----
            // Pipelined prepares: up to max_prepare_slots batches in-flight.
            // Each slot holds deferred sends + recv requeues until every
            // proposal token it carries commits. A failed token after a local
            // commit is divergence → fail-stop (docs/raft-wiring.md).
            while (self.prepare_count > 0) {
                const slot = &self.prepare_slots[self.prepare_head];
                if (!self.slotCommitted(slot)) break;
                self.flushPrepareSlot(slot);
                for (slot.tokens[0..slot.token_count]) |token| token.release();
                slot.token_count = 0;
                self.prepare_head = (self.prepare_head + 1) % max_prepare_slots;
                self.prepare_count -= 1;
            }

            // ---- Phase 2: All slots full — back-pressure ----
            if (self.prepare_count >= max_prepare_slots) {
                // Cannot execute a new batch until a slot frees up.
                // Drain IO non-blocking: handle close/send_done, save recv data.
                const n_full = self.io.drainNonBlocking(&self.completions);
                for (self.completions[0..n_full]) |completion| {
                    switch (completion.event) {
                        .recv => self.deferRecvConn(completion.conn_id),
                        .accept => {},
                        .closed => {}, // deferred to second pass
                        .connected => self.handleWebhookConnected(completion.conn_id),
                        .send_done => {
                            const sc = self.io.conn(completion.conn_id);
                            if (sc.protocol == .webhook) {
                                self.io.queueRecv(completion.conn_id);
                            } else if (sc.recv_pos > 0) {
                                self.deferRecvConn(completion.conn_id);
                            } else {
                                self.io.queueRecv(completion.conn_id);
                            }
                        },
                    }
                }
                // Closed events last — send_done and closed for the same conn_id
                // can arrive in one CQE batch. Closing first would free the conn
                // before send_done sees it.
                for (self.completions[0..n_full]) |completion| {
                    if (completion.event == .closed) self.onConnClosed(completion.conn_id);
                }
                self.io.submit();
                self.ticks_total += 1;
                return;
            }

            // ---- Phase 3: Normal batch processing ----

            const clock = self.config.clock_fn;
            const t_drain = Timer.start(clock);

            // 1. Drain IO completions.
            const has_pending = self.prepare_count > 0;
            const coalesce = !has_pending and self.config.raft != null and
                self.config.coalesce_window_ns > 0;
            const n = if (has_pending)
                self.io.drainNonBlocking(&self.completions)
            else if (coalesce)
                self.io.drainCoalescing(
                    &self.completions,
                    clock,
                    @as(u64, @intCast(clock())) + self.config.coalesce_window_ns,
                )
            else
                self.io.drain(&self.completions);

            addPhase(&self.phase_drain_ns, t_drain.elapsed(clock));

            // Everything below may touch talon (decode reads, batch commits,
            // read endpoints); serialize against the raft thread's tick. The
            // proposal inbox mutex nests inside this lock on our side only —
            // the raft thread never holds both at once, so no deadlock.
            if (self.config.db_lock) |l| l.lock();
            defer if (self.config.db_lock) |l| l.unlock();

            // Reset per-tick state.
            self.frame_count = 0;
            self.recv_compaction_count = 0;
            self.notified_queue_count = 0;

            // 2. Process completions — collect unique recv conn_ids. Sized for
            // the union of fresh completions and deferred-recv conns (see below).
            var recv_conns: [max_recv_conns]u16 = undefined;
            var recv_conn_count: u32 = 0;

            for (self.completions[0..n]) |completion| {
                switch (completion.event) {
                    .recv => {
                        var dup = false;
                        for (recv_conns[0..recv_conn_count]) |existing| {
                            if (existing == completion.conn_id) {
                                dup = true;
                                break;
                            }
                        }
                        if (!dup) {
                            recv_conns[recv_conn_count] = completion.conn_id;
                            recv_conn_count += 1;
                        }
                    },
                    .accept => {},
                    .closed => {}, // deferred to second pass
                    .connected => self.handleWebhookConnected(completion.conn_id),
                    .send_done => {
                        const c = self.io.conn(completion.conn_id);
                        // Re-arm subscription delivery: this connection's send
                        // buffer just drained (send_len reset to 0 by the IO
                        // backend), so a job skipped for lack of room or a
                        // re-pushed job can be retried now. notified_queue_count
                        // was reset above this loop, so recording here feeds THIS
                        // tick's fulfillSubscriptions — nothing else re-triggers a
                        // stranded push until unrelated queue activity (Bug C).
                        if (c.waiting) self.recordConnNotified(c);
                        if (c.protocol == .webhook) {
                            self.io.queueRecv(completion.conn_id);
                        } else if (c.recv_pos > 0) {
                            var dup = false;
                            for (recv_conns[0..recv_conn_count]) |existing| {
                                if (existing == completion.conn_id) { dup = true; break; }
                            }
                            if (!dup) {
                                recv_conns[recv_conn_count] = completion.conn_id;
                                recv_conn_count += 1;
                            }
                        } else {
                            self.io.queueRecv(completion.conn_id);
                        }
                    },
                }
            }
            // Closed events last — same reason as drain loop above.
            for (self.completions[0..n]) |completion| {
                if (completion.event == .closed) self.onConnClosed(completion.conn_id);
            }

            // Include connections that received data while all prepare slots were full.
            for (self.deferred_recv_conns[0..self.deferred_recv_conn_count]) |dc| {
                var dup = false;
                for (recv_conns[0..recv_conn_count]) |existing| {
                    if (existing == dc) {
                        dup = true;
                        break;
                    }
                }
                if (!dup) {
                    assert.check(recv_conn_count < max_recv_conns, "pipeline: recv_conns overflow ({d})", .{recv_conn_count});
                    recv_conns[recv_conn_count] = dc;
                    recv_conn_count += 1;
                }
            }
            self.deferred_recv_conn_count = 0;

            const t_extract = Timer.start(clock);
            for (recv_conns[0..recv_conn_count]) |conn_id| {
                self.extractFrames(conn_id);
            }
            addPhase(&self.phase_extract_ns, t_extract.elapsed(clock));

            // Run scheduled maintenance in its own batch, committed before
            // client ops. Followers don't run maintenance — the leader's
            // maintenance mutations arrive through the raft log.
            self.tick_token_count = 0;
            if (self.raft_state == .leading) {
                const t_maint = Timer.start(clock);
                self.runMaintenance();
                addPhase(&self.phase_maint_ns, t_maint.elapsed(clock));
            }

            if (self.frame_count == 0) {
                if (self.notified_queue_count > 0) {
                    const tf = Timer.start(clock);
                    self.fulfillSubscriptions();
                    addPhase(&self.phase_fulfill_ns, tf.elapsed(clock));
                    const tfl = Timer.start(clock);
                    self.flushSends();
                    addPhase(&self.phase_flush_ns, tfl.elapsed(clock));
                }
                // Maintenance/fulfill-only proposals: fetch pushes are
                // at-least-once (a claim lost on failover expires via lease
                // reclaim), so nothing is deferred; park the tokens for
                // divergence polling + release.
                self.parkTickTokens();
                const tc = Timer.start(clock);
                self.compactRecvBufs();
                addPhase(&self.phase_compact_ns, tc.elapsed(clock));
                const tr = Timer.start(clock);
                self.requeueRecvs(recv_conns[0..recv_conn_count]);
                addPhase(&self.phase_requeue_ns, tr.elapsed(clock));
                const ts = Timer.start(clock);
                self.io.submit();
                addPhase(&self.phase_submit_ns, ts.elapsed(clock));
                if (enable_phase_timing) {
                    self.phase_frames += self.frame_count;
                    self.phase_ticks += 1;
                }
                self.ticks_total += 1;
                self.maybePrintPhaseStats();
                return;
            }

            // 3. Execute: decode + apply in single kv.Batch.
            const t_exec = Timer.start(clock);
            self.executeBatch();
            addPhase(&self.phase_execute_ns, t_exec.elapsed(clock));

            // 4. Raft replication: this tick produced proposals (frame batch
            // and/or maintenance). Defer the batch's client responses until
            // every token commits — a raft commit IS quorum replication.
            if (self.tick_token_count > 0) {
                self.encodeResponses();
                self.pushCancelSignals();
                self.writeWebhookDispatchRecords();
                self.fulfillSubscriptions();
                self.compactRecvBufs();

                assert.check(
                    self.prepare_count < max_prepare_slots,
                    "pipeline: prepare slot overflow",
                    .{},
                );
                const slot = &self.prepare_slots[self.prepare_tail];
                @memcpy(slot.tokens[0..self.tick_token_count], self.tick_tokens[0..self.tick_token_count]);
                slot.token_count = self.tick_token_count;
                self.tick_token_count = 0;
                @memcpy(slot.send_conns[0..self.send_conn_count], self.send_conns[0..self.send_conn_count]);
                slot.send_conn_count = self.send_conn_count;
                @memcpy(slot.recv_conns[0..recv_conn_count], recv_conns[0..recv_conn_count]);
                slot.recv_conn_count = recv_conn_count;
                self.prepare_tail = (self.prepare_tail + 1) % max_prepare_slots;
                self.prepare_count += 1;
            } else {
                self.encodeResponses();
                self.pushCancelSignals();
                self.writeWebhookDispatchRecords();
                self.fulfillSubscriptions();
                self.flushSends();
                self.compactRecvBufs();
                self.requeueRecvs(recv_conns[0..recv_conn_count]);
                // fulfillSubscriptions may have proposed claim mutations after
                // the branch condition was evaluated: fetch pushes flush
                // immediately (at-least-once), but the tokens still need
                // divergence polling + release.
                self.parkTickTokens();
            }

            self.io.submit();
            if (enable_phase_timing) {
                self.phase_frames += self.frame_count;
                self.phase_ticks += 1;
            }
            self.ticks_total += 1;
            self.maybePrintPhaseStats();
        }

        // ====================================================================
        // Raft — leadership state machine + proposal token plumbing
        // ====================================================================

        /// Drive follower → acquiring → leading transitions. Runs at the top
        /// of every tick; no-op outside raft mode.
        fn tickRaftLeadership(self: *Self) void {
            const raft = self.config.raft orelse return;
            switch (self.raft_state) {
                .follower => if (raft.isLeader()) {
                    // Barrier: an empty proposal in our term. When it commits,
                    // every prior term's entry has been applied to the local
                    // FSM, so the KV is complete and the in-memory handler
                    // state can be rebuilt from it.
                    const none: [0]kv.Mutation = .{};
                    if (raft.propose(&none)) |token| {
                        self.barrier_token = token;
                        self.raft_state = .acquiring;
                    } // Inbox back-pressure: retry next tick.
                },
                .acquiring => {
                    const token = self.barrier_token.?;
                    switch (token.loadState()) {
                        .pending => {},
                        .committed => {
                            token.release();
                            self.barrier_token = null;
                            // Runs before the tick's main lock span — take
                            // the DB lock for the rebuild reads.
                            if (self.config.db_lock) |l| l.lock();
                            defer if (self.config.db_lock) |l| l.unlock();
                            // Clear before rebuild: while we were a follower the
                            // FSM applied the new leader's log straight to KV
                            // without touching our in-memory PendingIndex/queue
                            // caches, so they are stale. Rebuilding onto stale
                            // state would duplicate pending entries (a re-acquire
                            // loop leaks the index). clearState + rebuildState
                            // gives a slate that exactly matches KV, closing the
                            // hole where a deposed node's stale pending index
                            // could later feed a fulfillment.
                            self.handler.clearState();
                            self.handler.rebuildState(self.stores);
                            self.warmupOnAcquire();
                            self.raft_state = .leading;
                        },
                        .failed => {
                            // Lost leadership before the barrier committed.
                            // No local commits happened — clean fallback.
                            token.release();
                            self.barrier_token = null;
                            self.raft_state = .follower;
                        },
                    }
                },
                .leading => if (!raft.isLeader() and self.prepare_count == 0 and
                    self.maint_token_count == 0)
                {
                    // In-flight tokens either commit (slots flush) or fail
                    // (divergence fail-stop); step down only once drained.
                    // A fetch claim is a local write, forbidden on a follower,
                    // so subscribed workers must be told to redial the leader
                    // rather than wait forever on a node that can no longer
                    // serve them.
                    self.evictWaitingSubscribers();
                    self.raft_state = .follower;
                },
            }
        }

        /// Leadership-acquisition warmup: seed maintenance timestamps and
        /// reload the webhook cache. Stale-worker cleanup is NOT run here —
        /// it mutates, and the first interval-scheduled workers pass handles
        /// it through the normal propose path.
        fn warmupOnAcquire(self: *Self) void {
            const now_ns = self.nowNs();
            self.last_promote_ns = now_ns;
            self.last_reclaim_ns = now_ns;
            self.last_unique_ns = now_ns;
            self.last_rate_limit_ns = now_ns;
            self.last_expire_ns = now_ns;
            self.last_purge_ns = now_ns;
            self.last_workers_ns = now_ns;
            self.last_cron_ns = now_ns;
            self.last_webhook_ns = now_ns;
            var batch = self.stores[0].newBatch();
            defer batch.close();
            self.handler.loadWebhookCache(&batch);
        }

        /// True when the node may commit writes to its LOCAL KV: single-node
        /// (no raft) always may; in raft mode only a confirmed leader may. Uses
        /// the SAME source of truth the write path (decodeAndApply) gates on —
        /// raft_state == .leading AND a live isLeader() — so a follower, an
        /// acquiring node (barrier not yet committed), or a deposed leader
        /// mid-stepdown can never claim jobs and propose a doomed write.
        fn canWriteLocally(self: *Self) bool {
            const raft = self.config.raft orelse return true;
            return self.raft_state == .leading and raft.isLeader();
        }

        /// On step-down, tell every subscribed worker to redial the leader. A
        /// fetch subscription is a standing claim (a local write on fulfillment),
        /// which a follower may not serve. We emit MSG_NOT_LEADER on each waiting
        /// connection and clear its subscription state, preserving the invariant
        /// "a connection marked waiting is in waiting_conns" (none is left
        /// waiting after the list is cleared). Reuses the same not-leader frame
        /// the per-frame write rejection path emits.
        fn evictWaitingSubscribers(self: *Self) void {
            for (self.waiting_conns[0..self.waiting_conn_count]) |conn_id| {
                const c = self.io.conn(conn_id);
                if (c.phase == .free) continue;
                c.waiting = false;
                c.prefetch = 0;
                const n = raft_gate.encodeNotLeader(c.send_buf[c.send_len..], c.last_req_id, .{}) catch continue;
                c.send_len += @intCast(n);
                self.io.queueSend(conn_id, c.send_len);
            }
            self.waiting_conn_count = 0;
        }

        /// Encoded size a mutation contributes to a proposal payload
        /// (oplog.encodeMutations layout: op u8 + keylen u16 + vallen u32).
        fn mutationBytes(m: kv.Mutation) usize {
            return 1 + 2 + 4 + m.key.len + m.value.len;
        }

        /// Propose one chunk of the recorded mutations and stash its token
        /// for the tick's prepare slot.
        fn proposeSlice(self: *Self, muts: []const kv.Mutation) void {
            if (muts.len == 0) return;
            const raft = self.config.raft.?;
            // Inbox depth (4096) dwarfs the bounded in-flight window
            // (max_prepare_slots × max_tick_tokens + max_maint_tokens), so
            // back-pressure here is an invariant violation, not a condition.
            const token = raft.propose(muts) orelse {
                assert.check(false, "pipeline: raft inbox full with bounded in-flight window", .{});
                unreachable;
            };
            assert.check(self.tick_token_count < max_tick_tokens, "pipeline: tick token overflow", .{});
            self.tick_tokens[self.tick_token_count] = token;
            self.tick_token_count += 1;
        }

        /// Propose a maintenance/fulfill batch's recorded mutations, split
        /// into ≤max_proposal_bytes chunks at MUTATION granularity — these
        /// batches are re-runnable scans (promote/reclaim/expire/purge) or
        /// lease claims recovered by reclaim, so entry-level atomicity is
        /// not required the way it is for client ops.
        fn proposeRecorded(self: *Self) void {
            if (self.config.raft == null) return;
            const muts = self.mut_list.items;
            var start: usize = 0;
            var bytes: usize = 4; // encodeMutations count header
            var i: usize = 0;
            while (i < muts.len) : (i += 1) {
                const sz = mutationBytes(muts[i]);
                assert.check(4 + sz <= max_proposal_bytes, "pipeline: single mutation exceeds proposal cap", .{});
                if (bytes + sz > max_proposal_bytes) {
                    self.proposeSlice(muts[start..i]);
                    start = i;
                    bytes = 4;
                }
                bytes += sz;
            }
            self.proposeSlice(muts[start..]);
        }

        /// Propose the frame batch's recorded mutations, split into
        /// ≤max_proposal_bytes chunks at FRAME boundaries: one client op's
        /// mutations must land in one raft entry so followers apply them
        /// atomically (a mid-op split would leave e.g. a job record without
        /// its indexes after a failover).
        ///
        /// The per-frame cap assert below is a BACKSTOP only: enqueueRecordedBound
        /// already rejects an oversize enqueue frame at decode (Bug B), and
        /// maintenance uses proposeRecorded (mutation-granularity split), so no
        /// client input reaches this assert.
        fn proposeRecordedFrames(self: *Self) void {
            if (self.config.raft == null) return;
            const muts = self.mut_list.items;
            if (muts.len == 0) return;
            var start: usize = 0; // chunk start (mutation index)
            var bytes: usize = 4; // encodeMutations count header
            var prev_end: usize = 0;
            for (self.frame_mut_ends[0..self.frame_count]) |end| {
                var seg_bytes: usize = 0;
                for (muts[prev_end..end]) |m| seg_bytes += mutationBytes(m);
                assert.check(
                    4 + seg_bytes <= max_proposal_bytes,
                    "pipeline: one frame's mutations ({d}B) exceed the proposal cap {d}",
                    .{ seg_bytes, max_proposal_bytes },
                );
                if (bytes + seg_bytes > max_proposal_bytes) {
                    self.proposeSlice(muts[start..prev_end]);
                    start = prev_end;
                    bytes = 4;
                }
                bytes += seg_bytes;
                prev_end = end;
            }
            assert.check(prev_end == muts.len, "pipeline: frame bounds don't cover mut_list ({d} vs {d})", .{ prev_end, muts.len });
            self.proposeSlice(muts[start..]);
        }

        /// Provable UPPER BOUND on the recorded-mutation bytes ONE enqueue frame
        /// contributes to its raft proposal segment. proposeRecordedFrames cannot
        /// split a frame across raft entries, so a frame whose recorded mutations
        /// exceed one entry's cap (max_proposal_bytes) fires the per-frame assert
        /// AFTER the local commit — a panic on legal client input. A 256 KiB
        /// enqueue amplifies far past its wire size: the job record inlines its
        /// tags AND every tag repeats queue+id in a tq| index key. decodeAndApply*
        /// rejects a frame at the boundary (before handler.apply) when this bound
        /// exceeds the cap, so the assert becomes a pure backstop.
        ///
        /// Every mutation the enqueue path records (handler_enqueue.applyEnqueue +
        /// indexer.flushCreate + flushCounterDeltas) is over-estimated as oplog
        /// framing (1 op + 2 keylen + 4 vallen = 7, see mutationBytes) + key bytes
        /// + value bytes, from the job's ACTUAL field sizes:
        ///   j|{id}   record : encodeJob = 91 fixed + 15 var-field 2-byte prefixes
        ///                     + inlined field CONTENT (id, queue, unique, batch,
        ///                     parent, chain, chain_config, group, tags, checkpoint)
        ///   jp|{id}  payload: value = payload bytes                    (if present)
        ///   jt|/jq|/js|/jqs|: empty-value read indexes (flushCreate)
        ///   tq| per tag     : the tag string parses into ≥5-byte pairs, so the
        ///                     pair count ≤ tags/5; all key/value CONTENT across
        ///                     pairs is a subset of the tag string (≤ tags total);
        ///                     each key's fixed part + framing is q + id + 13 bytes
        ///   qc|{queue}      : new-queue default write AND per-tick counter
        ///                     re-encode, each value = encodeQueue = 54 fixed + 2 +
        ///                     name; charged twice per job (worst case: every job a
        ///                     fresh queue)
        ///   qn|{queue}      : empty new-queue marker
        ///   x|/s|/u|/b|     : optional expire / scheduled / unique-lock / batch
        ///                     counter mutations, charged only when the field is set
        ///                     (b|'s re-encode is the batch record's ACTUAL current
        ///                     size, read from the batch — its counters change but
        ///                     its length does not).
        /// Plus the 4-byte encodeMutations count header, matching
        /// proposeRecordedFrames' per-chunk accounting.
        fn enqueueRecordedBound(batch: *kv.WriteBatch, op: *const ops_mod.EnqueueOp) usize {
            const fr: usize = 7; // oplog framing per mutation (see mutationBytes)
            var total: usize = 4; // encodeMutations count header
            for (op.jobs) |*j| {
                const q = j.queue.len;
                const id = j.job_id.len;
                const tags_len = if (j.tags) |t| t.len else 0;

                // j|{id} job record — value inlines every variable field present.
                var job_val: usize = 91 + 15 * 2 + id + q + tags_len;
                if (j.unique_key) |u| job_val += u.len;
                if (j.batch_id) |b| job_val += b.len;
                if (j.parent_id) |p| job_val += p.len;
                if (j.chain_id) |c| job_val += c.len;
                if (j.chain_config) |c| job_val += c.len;
                if (j.group) |g| job_val += g.len;
                if (j.checkpoint) |c| job_val += c.len;
                total += fr + (2 + id) + job_val;

                // Deferred read indexes (empty values).
                total += fr + (3 + 8 + id); // jt|{inv:8}{id}
                total += fr + (3 + q + 1 + 8 + id); // jq|{queue}\0{inv:8}{id}
                total += fr + (3 + 1 + 8 + id); // js|{state:1}{inv:8}{id}
                total += fr + (4 + q + 1 + 1 + 8 + id); // jqs|{queue}\0{state:1}{inv:8}{id}

                // Queue config (default write + counter re-encode) and marker.
                total += 2 * (fr + (3 + q) + (54 + 2 + q));
                total += fr + (3 + q);

                // Tag index keys: pair count ≤ tags/5, content ≤ tags total.
                total += tags_len + (tags_len / 5) * (q + id + 13);

                // Optional per-feature mutations.
                if (j.payload) |p| {
                    if (p.len > 0) total += fr + (3 + id) + p.len; // jp|{id}
                }
                if (j.expire_after_ms > 0) total += fr + (2 + 8 + id); // x|{expire:8}{id}
                if (j.scheduled_at_ns > 0) total += fr + (2 + q + 1 + 8 + id); // s|{queue}\0{sched:8}{id}
                if (j.unique_key) |u| {
                    if (u.len > 0) total += fr + (2 + q + 1 + u.len) + (id + 1 + 8); // u| lock (value = id|expires)
                }
                if (j.batch_id) |b| {
                    if (b.len > 0) {
                        // Re-encode of the existing batch record (same length).
                        var bk: keys.KeyBuf = undefined;
                        const bv = batch.get(keys.batchKey(&bk, b));
                        const bsz = if (bv) |v| v.len else codec.max_batch_encoded_size;
                        total += fr + (2 + b.len) + bsz; // b|{batch_id}
                    }
                }
            }
            return total;
        }

        /// True when every token the slot carries has committed. A failed
        /// token means our locally-committed batch was rejected by the
        /// cluster (leadership lost mid-flight): the local KV now contains
        /// writes the cluster never accepted, and there is no entry-wise
        /// rollback for mutation replication — fail-stop.
        fn slotCommitted(self: *Self, slot: *const PrepareSlot) bool {
            _ = self;
            var all_committed = true;
            for (slot.tokens[0..slot.token_count]) |token| {
                switch (token.loadState()) {
                    .committed => {},
                    .pending => all_committed = false,
                    .failed => std.debug.panic(
                        "corvo: raft proposal failed after local commit — " ++
                            "state diverged from cluster; wipe the data dir and rejoin",
                        .{},
                    ),
                }
            }
            return all_committed;
        }

        /// Move this tick's tokens to the maintenance ring (frameless tick:
        /// nothing client-visible to defer, but divergence polling + release
        /// must still happen).
        fn parkTickTokens(self: *Self) void {
            for (self.tick_tokens[0..self.tick_token_count]) |token| {
                assert.check(self.maint_token_count < max_maint_tokens, "pipeline: maint token overflow", .{});
                self.maint_tokens[self.maint_token_count] = token;
                self.maint_token_count += 1;
            }
            self.tick_token_count = 0;
        }

        /// Poll parked maintenance tokens: release committed, fail-stop on
        /// failed, keep pending (compacting in place).
        fn pollMaintTokens(self: *Self) void {
            var kept: u32 = 0;
            for (self.maint_tokens[0..self.maint_token_count]) |token| {
                switch (token.loadState()) {
                    .committed => token.release(),
                    .pending => {
                        self.maint_tokens[kept] = token;
                        kept += 1;
                    },
                    .failed => std.debug.panic(
                        "corvo: raft proposal failed after local commit — " ++
                            "state diverged from cluster; wipe the data dir and rejoin",
                        .{},
                    ),
                }
            }
            self.maint_token_count = kept;
        }

        // ====================================================================
        // Frame extraction — parse RPC frames from recv_bufs
        // ====================================================================

        fn extractFrames(self: *Self, conn_id: u16) void {
            const c = self.io.conn(conn_id);
            if (c.phase == .free) return;
            if (c.recv_pos == 0) return;

            // Detect protocol on first data.
            if (c.protocol == .unknown) {
                c.protocol = if (http.isHttpByte(c.recv_buf[0])) .http else .rpc;
            }

            switch (c.protocol) {
                .rpc => self.extractRpcFrames(conn_id, c),
                .http => self.extractHttpFrames(conn_id, c),
                .webhook => self.handleWebhookResponse(conn_id, c),
                .unknown => unreachable,
            }
        }

        fn extractRpcFrames(self: *Self, conn_id: u16, c: *ConnState) void {
            var pos: u32 = 0;
            const data_end = c.recv_pos;

            while (pos + @as(u32, rpc.FRAME_HEADER_SIZE) <= data_end) {
                const hdr = rpc.readFrameHeader(c.recv_buf[pos..data_end]) orelse break;

                if (hdr.payload_len > self.config.max_payload_size) {
                    self.io.queueClose(conn_id);
                    return;
                }

                const payload_start = pos + @as(u32, rpc.FRAME_HEADER_SIZE);
                const frame_end = payload_start + hdr.payload_len;
                if (frame_end > data_end) break; // partial frame, wait for more data

                if (self.frame_count >= max_frames) break; // back-pressure

                // RPC auth gate: when an admin password is configured, a
                // connection must complete a MSG_AUTH handshake before any other
                // frame is accepted. Otherwise a client speaking the binary
                // protocol could bypass the HTTP-layer auth entirely and mutate
                // state (delete jobs, drop queues). Unauthenticated non-AUTH
                // frames close the connection.
                if (self.config.admin_password.len > 0 and !c.rpc_authenticated and
                    hdr.msg_type != rpc.MSG_AUTH)
                {
                    self.io.queueClose(conn_id);
                    return;
                }

                self.frames[self.frame_count] = .{
                    .conn_id = conn_id,
                    .req_id = hdr.req_id,
                    .msg_type = hdr.msg_type,
                    .payload = c.recv_buf[payload_start..frame_end],
                };
                self.frame_count += 1;
                pos = @intCast(frame_end);

                // Stop after batching a MSG_AUTH from an unauthenticated conn:
                // the client waits for MSG_AUTH_RESP before sending more, so any
                // trailing bytes this pass would be processed with stale (still
                // unauthenticated) state.
                if (self.config.admin_password.len > 0 and !c.rpc_authenticated and
                    hdr.msg_type == rpc.MSG_AUTH) break;
            }

            self.recordRecvCompaction(conn_id, pos);
        }

        fn extractHttpFrames(self: *Self, conn_id: u16, c: *ConnState) void {
            const data = c.recv_buf[0..c.recv_pos];
            const req = http.parseRequest(data) orelse return; // incomplete, wait

            const route = http.classifyRoute(req.method, req.path);

            // CORS preflight — return immediately, no auth, no batch.
            if (req.method == .OPTIONS) {
                const resp_len = http.writeCorsPreflightResponse(c.send_buf);
                if (resp_len > 0) {
                    c.send_len = resp_len;
                    self.io.queueSend(conn_id, resp_len);
                }
                self.recordRecvCompaction(conn_id, req.total_len);
                return;
            }

            // Auth check.
            const clean_path = if (std.mem.indexOfScalar(u8, req.path, '?')) |qi| req.path[0..qi] else req.path;
            const is_ui_route = std.mem.eql(u8, clean_path, "/ui") or std.mem.startsWith(u8, clean_path, "/ui/");
            const is_ui_static = is_ui_route and
                (std.mem.endsWith(u8, clean_path, ".js") or
                std.mem.endsWith(u8, clean_path, ".css") or
                std.mem.endsWith(u8, clean_path, ".svg"));
            const admin_pw_set = self.config.admin_password.len > 0;

            const skip_auth = std.mem.eql(u8, clean_path, "/healthz") or
                std.mem.eql(u8, clean_path, "/api/v1/auth/status") or
                std.mem.eql(u8, clean_path, "/api/v1/auth/login") or
                std.mem.eql(u8, clean_path, "/metrics") or
                is_ui_static or
                (is_ui_route and !admin_pw_set) or
                (is_ui_route and std.mem.eql(u8, clean_path, "/ui/login")) or
                (is_ui_route and std.mem.eql(u8, clean_path, "/ui/logout"));
            // Auth: identity check for reads/UI/404. Writes use authorizeWrite (identity + role).
            if (!skip_auth and route != .write) {
                const auth_result = http.checkAuth(
                    req.api_key,
                    req.session_cookie,
                    self.config.admin_password,
                    self.reader,
                );
                if (auth_result != .ok) {
                    const resp_len = if (is_ui_route)
                        http.writeRedirect(c.send_buf, "/ui/login")
                    else
                        http.writeAuthError(c.send_buf, auth_result);
                    if (resp_len > 0) {
                        c.send_len = resp_len;
                        self.io.queueSend(conn_id, resp_len);
                    }
                    self.recordRecvCompaction(conn_id, req.total_len);
                    return;
                }
                // admin_read routes (backup/restore/cluster-join) additionally
                // require the admin role — a scoped worker/producer key that is a
                // valid identity must not dump or replace the whole database.
                if (route == .admin_read and auth_result.ok.role != .admin) {
                    const resp_len = http.writeAuthError(c.send_buf, .forbidden);
                    if (resp_len > 0) {
                        c.send_len = resp_len;
                        self.io.queueSend(conn_id, resp_len);
                    }
                    self.recordRecvCompaction(conn_id, req.total_len);
                    return;
                }
            }

            switch (route) {
                .read, .admin_read => {
                    // Handle inline — write response directly, bypass batch.
                    const clean = if (std.mem.indexOfScalar(u8, req.path, '?')) |qi| req.path[0..qi] else req.path;

                    // /metrics is special: needs handler metrics + reader.
                    if (std.mem.eql(u8, clean, "/metrics")) {
                        const resp_len = http_read.metrics(c.send_buf, self.reader, &self.handler.metrics);
                        if (resp_len > 0) {
                            c.send_len = resp_len;
                            self.io.queueSend(conn_id, resp_len);
                        }
                        self.recordRecvCompaction(conn_id, req.total_len);
                        return;
                    }

                    const api = if (std.mem.startsWith(u8, clean, "/api/v1/")) clean["/api/v1".len..] else clean;
                    const param = extractPathParam(api);
                    const resp_len = http_read.dispatch(
                        req.method,
                        req.path,
                        param,
                        req.body,
                        c.send_buf,
                        self.reader,
                        &self.handler.metrics,
                        &self.stores[0],
                        @intCast(@max(0, self.config.clock_fn())),
                    );
                    if (resp_len > 0) {
                        c.send_len = resp_len;
                        self.io.queueSend(conn_id, resp_len);
                    }
                    self.recordRecvCompaction(conn_id, req.total_len);
                },
                .write => |w| {
                    if (self.frame_count >= max_frames) return; // back-pressure

                    // Identity + role authorization for write operations.
                    var auth_actor: [128]u8 = undefined;
                    var auth_actor_len: u8 = 0;
                    if (!skip_auth) {
                        const write_auth = http.authorizeWrite(
                            req.api_key,
                            req.session_cookie,
                            self.config.admin_password,
                            self.reader,
                            w.msg_type,
                            w.sub_action,
                        );
                        switch (write_auth) {
                            .ok => |info| {
                                @memcpy(auth_actor[0..info.actor_len], info.actorSlice());
                                auth_actor_len = info.actor_len;
                            },
                            .unauthorized, .forbidden => {
                                const resp_len = http.writeAuthError(c.send_buf, write_auth);
                                c.send_len = resp_len;
                                self.io.queueSend(conn_id, resp_len);
                                self.recordRecvCompaction(conn_id, req.total_len);
                                return;
                            },
                        }
                    }

                    // Payload size validation — return 413 instead of asserting.
                    if (req.body.len > self.config.max_payload_size) {
                        const resp_len = http.writeResponse(c.send_buf, 413, "{\"error\":\"payload too large\"}");
                        c.send_len = resp_len;
                        self.io.queueSend(conn_id, resp_len);
                        self.recordRecvCompaction(conn_id, req.total_len);
                        return;
                    }

                    var frame = FrameDesc{
                        .conn_id = conn_id,
                        .req_id = 0,
                        .msg_type = w.msg_type,
                        .payload = req.body,
                        .protocol = .http,
                        .path_param = w.param,
                        .sub_action = w.sub_action,
                        .http_path = req.path,
                        .actor_len = auth_actor_len,
                    };
                    @memcpy(frame.actor[0..auth_actor_len], auth_actor[0..auth_actor_len]);
                    self.frames[self.frame_count] = frame;
                    self.frame_count += 1;
                    self.recordRecvCompaction(conn_id, req.total_len);
                },
                .not_found => {
                    const resp_len = http.writeResponse(c.send_buf, 404, "{\"error\":\"not found\"}");
                    c.send_len = resp_len;
                    self.io.queueSend(conn_id, resp_len);
                    self.recordRecvCompaction(conn_id, req.total_len);
                },
                .method_not_allowed => {
                    const resp_len = http.writeResponse(c.send_buf, 405, "{\"error\":\"method not allowed\"}");
                    c.send_len = resp_len;
                    self.io.queueSend(conn_id, resp_len);
                    self.recordRecvCompaction(conn_id, req.total_len);
                },
            }
        }

        fn extractPathParam(api_path: []const u8) []const u8 {
            // Extract trailing segment: /jobs/{id} → {id}, /ack/{id} → {id}
            if (std.mem.lastIndexOfScalar(u8, api_path, '/')) |last_slash| {
                const param = api_path[last_slash + 1 ..];
                if (param.len > 0) return param;
            }
            return "";
        }

        // ====================================================================
        // Maintenance — timer-driven ops, separate batch from client frames
        // ====================================================================

        fn runMaintenance(self: *Self) void {
            const now_ns = self.nowNs();

            const intervals = [8]struct { ns: u64, last: *u64, action: ops_mod.MaintenanceAction }{
                .{ .ns = self.config.promote_interval_ns, .last = &self.last_promote_ns, .action = .promote },
                .{ .ns = self.config.reclaim_interval_ns, .last = &self.last_reclaim_ns, .action = .reclaim },
                .{ .ns = self.config.unique_interval_ns, .last = &self.last_unique_ns, .action = .unique },
                .{ .ns = self.config.rate_limit_interval_ns, .last = &self.last_rate_limit_ns, .action = .rate_limit },
                .{ .ns = self.config.expire_interval_ns, .last = &self.last_expire_ns, .action = .expire },
                .{ .ns = self.config.purge_interval_ns, .last = &self.last_purge_ns, .action = .purge },
                .{ .ns = self.config.workers_interval_ns, .last = &self.last_workers_ns, .action = .workers },
                .{ .ns = self.config.cron_interval_ns, .last = &self.last_cron_ns, .action = .cron },
            };

            // Purge also fires early once enough terminal jobs have accumulated,
            // independent of the (hourly) interval, so terminal garbage doesn't
            // build up for the full retention window under heavy churn.
            const purge_count_due = self.config.purge_threshold > 0 and
                self.handler.dead_since_purge >= self.config.purge_threshold;

            var any_due = false;
            for (intervals) |iv| {
                if (iv.ns > 0 and now_ns - iv.last.* >= iv.ns) {
                    any_due = true;
                    break;
                }
                if (iv.action == .purge and purge_count_due) {
                    any_due = true;
                    break;
                }
            }
            if (!any_due) return;

            self.handler.resetEffects();
            var batch = self.stores[0].newBatch();
            defer batch.close();

            const record_mutations = self.config.raft != null;
            if (record_mutations) {
                self.mut_list.clearRetainingCapacity();
                batch.enableRecording(self.allocator, &self.mut_list);
            }
            defer if (record_mutations) batch.freeMutations();

            for (intervals) |iv| {
                const interval_due = iv.ns > 0 and now_ns - iv.last.* >= iv.ns;
                const count_due = iv.action == .purge and purge_count_due;
                if (!interval_due and !count_due) continue;

                const cutoff = if (iv.action == .rate_limit and self.handler.max_rate_window_ns > 0)
                    now_ns -| self.handler.max_rate_window_ns
                else if (iv.action == .workers)
                    now_ns -| self.config.worker_timeout_ns
                else if (iv.action == .purge)
                    now_ns -| self.config.purge_retention_ns
                else
                    now_ns;
                const t0 = self.config.clock_fn();
                const op_data = ops_mod.OpData{ .maintenance = .{ .action = iv.action, .now_ns = now_ns, .cutoff_ns = cutoff } };
                const result = self.handler.apply(&batch, .maintenance, &op_data);
                const elapsed_us: u64 = @intCast(@max(0, self.config.clock_fn() - t0));
                if (result.affected > 0)
                    std.debug.print("corvo: maintenance {s} — {d} affected, {d}us\n", .{
                        iv.action.toString(), result.affected, elapsed_us,
                    });
                self.emitMirrorOp(.maintenance, &op_data, &result);

                if (result.notify_queues) |queues| {
                    self.notify.notifyQueues(queues);
                    for (queues) |q| self.recordNotifiedQueue(q);
                }

                // Drain the indexer between maintenance ops so a burst (e.g.
                // cron firing many jobs) can never overflow the effect buffer
                // (M10). The final flush below handles the remainder.
                if (self.handler.indexer.nearFull()) self.handler.indexer.flush(&batch);

                iv.last.* = now_ns;
                // Reset the terminal-job accumulator only once the backlog is
                // drained. Per-tick purge is capped; if this pass hit the cap
                // there is more past-retention garbage to remove, so keep the
                // counter high and let the count-trigger re-fire next tick until
                // caught up. When it drains fewer than the cap, re-arm the trigger.
                if (iv.action == .purge and result.affected < OpHandler.max_bulk_results)
                    self.handler.dead_since_purge = 0;
                self.maintenance_runs += 1;
                self.applied_total += 1;
            }

            // Flush deferred indexes (e.g. cron enqueues) into the maintenance
            // batch. Without this, effects recorded during maintenance were
            // dropped by the next resetEffects, leaving cron jobs missing their
            // read indexes and qc| counter (KV/read drift).
            self.handler.indexer.flush(&batch);

            batch.commit();
            self.proposeRecorded();

            // Webhook dispatch — separate from the main maintenance batch.
            // Scans whd| for pending deliveries and initiates outbound HTTP.
            if (self.config.webhook_interval_ns > 0 and
                now_ns - self.last_webhook_ns >= self.config.webhook_interval_ns)
            {
                self.dispatchWebhooks(now_ns);
                self.last_webhook_ns = now_ns;
            }
        }

        /// Scan whd| prefix for pending webhook deliveries and initiate outbound HTTP.
        /// Bounded: max 8 deliveries per tick to avoid starving the event loop.
        fn dispatchWebhooks(self: *Self, now_ns: u64) void {
            var wb = self.stores[0].newBatch();
            defer wb.close();

            var lower_buf: keys.KeyBuf = undefined;
            var upper_buf: keys.KeyBuf = undefined;
            @memcpy(lower_buf[0..keys.prefix_webhook_dispatch.len], keys.prefix_webhook_dispatch);
            const upper = keys.prefixEnd(&upper_buf, lower_buf[0..keys.prefix_webhook_dispatch.len]) orelse return;

            var iter = wb.newIter(lower_buf[0..keys.prefix_webhook_dispatch.len], upper);
            defer iter.close();

            if (!iter.first()) return;

            const max_per_tick: u32 = 8;
            var dispatched: u32 = 0;
            var keys_to_delete: [8]keys.KeyBuf = undefined;
            var delete_lens: [8]usize = undefined;
            var delete_count: u32 = 0;

            while (dispatched < max_per_tick) {
                const key_slice = iter.key();
                const val = iter.value();

                // Parse scheduled_ns from key: whd|{scheduled_ns:8BE}{job_id}
                if (key_slice.len <= keys.prefix_webhook_dispatch.len + 8) {
                    if (!iter.next()) break;
                    continue;
                }
                const ns_bytes = key_slice[keys.prefix_webhook_dispatch.len..][0..8];
                const scheduled_ns = std.mem.readInt(u64, ns_bytes, .big);
                if (scheduled_ns > now_ns) break; // All remaining are in the future.

                // Parse webhook delivery JSON.
                const url_str = handler_mod.OpHandler.jsonStrPub(val, "url") orelse {
                    if (!iter.next()) break;
                    continue;
                };
                const job_id = handler_mod.OpHandler.jsonStrPub(val, "job_id") orelse "";
                const queue = handler_mod.OpHandler.jsonStrPub(val, "queue") orelse "";
                const event = handler_mod.OpHandler.jsonStrPub(val, "event") orelse "";

                // Parse URL and resolve address.
                const parsed = webhook_mod.parseUrl(url_str) orelse {
                    // Invalid URL — delete the record.
                    if (delete_count < 8) {
                        @memcpy(keys_to_delete[delete_count][0..key_slice.len], key_slice);
                        delete_lens[delete_count] = key_slice.len;
                        delete_count += 1;
                    }
                    if (!iter.next()) break;
                    continue;
                };

                const addr = webhook_mod.resolveHost(parsed.host, parsed.port) orelse {
                    if (!iter.next()) break;
                    continue;
                };

                // Create non-blocking socket.
                const fd = posix.socket(
                    posix.AF.INET,
                    posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
                    0,
                ) catch {
                    if (!iter.next()) break;
                    continue;
                };

                // Allocate outbound connection slot.
                const conn_id = self.io.initOutboundConn(fd) orelse {
                    posix.close(fd);
                    break; // No free slots — stop dispatching.
                };

                // Build HTTP POST request into send_buf.
                const c = self.io.conn(conn_id);
                var payload_buf: [1024]u8 = undefined;
                const payload = webhook_mod.buildEventPayload(&payload_buf, event, job_id, queue, now_ns) orelse "";
                const req = webhook_mod.buildHttpPost(c.send_buf, parsed.host, parsed.path, payload) orelse {
                    self.io.queueClose(conn_id);
                    if (!iter.next()) break;
                    continue;
                };
                c.send_len = @intCast(req.len);

                // Queue the connect SQE.
                self.io.queueConnect(conn_id, &addr);

                // Delete the delivery record (fire-and-forget for now).
                if (delete_count < 8) {
                    @memcpy(keys_to_delete[delete_count][0..key_slice.len], key_slice);
                    delete_lens[delete_count] = key_slice.len;
                    delete_count += 1;
                }

                dispatched += 1;
                if (!iter.next()) break;
            }

            // Delete processed delivery records.
            if (delete_count > 0) {
                iter.close();
                for (0..delete_count) |i| {
                    wb.delete(keys_to_delete[i][0..delete_lens[i]]);
                }
                wb.commit();
            }
        }

        fn recordRecvCompaction(self: *Self, conn_id: u16, consumed: u32) void {
            if (consumed == 0) return;
            assert.check(
                self.recv_compaction_count < max_completions,
                "pipeline: recv_compaction overflow",
                .{},
            );
            self.recv_compactions[self.recv_compaction_count] = .{
                .conn_id = conn_id,
                .consumed = consumed,
            };
            self.recv_compaction_count += 1;
        }

        // ====================================================================
        // Execute — decode + apply in a single kv.Batch
        // ====================================================================

        fn executeBatch(self: *Self) void {
            const clock = self.config.clock_fn;
            self.handler.resetEffects();
            var kv_batch = self.stores[0].newBatch();
            defer kv_batch.close();

            const record_mutations = self.config.raft != null;
            if (record_mutations) {
                self.mut_list.clearRetainingCapacity();
                kv_batch.enableRecording(self.allocator, &self.mut_list);
            }
            defer if (record_mutations) kv_batch.freeMutations();

            const t_apply = Timer.start(clock);
            for (self.frames[0..self.frame_count], 0..) |*frame, i| {
                self.results[i] = self.decodeAndApply(&kv_batch, frame, @intCast(i));
                if (record_mutations) {
                    // Raft: flush THIS frame's deferred index effects now so its
                    // recorded-mutation segment is self-contained. Two reasons:
                    // (1) a follower must apply one client op's mutations — the
                    // job record AND its read/tag indexes — in a single raft
                    // entry (docs/raft-wiring.md atomicity). The old end-of-loop
                    // flush attributed every frame's indexes to the LAST frame's
                    // segment, so an earlier frame's entry carried a job record
                    // without its indexes. (2) It makes each frame_mut_ends[i]
                    // cover exactly frame i, so enqueueRecordedBound provably
                    // bounds every frame's whole segment (Bug B). Flushing into
                    // the same committed batch is result-identical to one
                    // end-of-loop flush, and write-path handlers never read the
                    // read indexes, so an earlier frame's flushed indexes can't
                    // perturb a later frame's apply.
                    self.handler.indexer.flush(&kv_batch);
                    self.frame_mut_ends[i] = @intCast(self.mut_list.items.len);
                } else if (self.handler.indexer.nearFull()) {
                    // Non-raft: bounded-pass mid-loop flush so a burst of effects
                    // can never overflow and be silently dropped (M10).
                    self.handler.indexer.flush(&kv_batch);
                }
            }
            addPhase(&self.exec_apply_ns, t_apply.elapsed(clock));

            // Non-raft: flush the remaining deferred indexes once, after all
            // reads. (Raft flushed per-frame above — nothing left to attribute.)
            if (!record_mutations) self.handler.indexer.flush(&kv_batch);

            const t_commit = Timer.start(clock);
            kv_batch.commit();
            addPhase(&self.exec_commit_ns, t_commit.elapsed(clock));
            self.applied_total += self.frame_count;

            {
                const t_propose = Timer.start(clock);
                self.proposeRecordedFrames();
                addPhase(&self.exec_oplog_ns, t_propose.elapsed(clock));
            }

            const t_notify = Timer.start(clock);
            for (self.frames[0..self.frame_count], 0..) |frame, i| {
                self.notifyForFrame(&frame, &self.results[i]);
            }
            addPhase(&self.exec_notify_ns, t_notify.elapsed(clock));

            if (enable_phase_timing) {
                self.exec_ticks += 1;
                if (self.exec_ticks >= 100) {
                    const t = self.exec_ticks;
                    std.debug.print(
                        \\  EXEC BREAKDOWN ({d} ticks, {d} frames): apply={d}us commit={d}us notify={d}us oplog={d}us
                        \\
                    , .{
                        t, self.applied_total,
                        self.exec_apply_ns / (t * 1000), self.exec_commit_ns / (t * 1000),
                        self.exec_notify_ns / (t * 1000), self.exec_oplog_ns / (t * 1000),
                    });
                    self.exec_apply_ns = 0;
                    self.exec_commit_ns = 0;
                    self.exec_notify_ns = 0;
                    self.exec_oplog_ns = 0;
                    self.exec_ticks = 0;
                }
            }
        }

        /// Validate an RPC MSG_AUTH handshake and record the granted role on the
        /// connection. Payload is a single length-prefixed credential (admin
        /// password or API key). Reuses the same identity check as the HTTP layer.
        fn applyRpcAuth(self: *Self, frame: *FrameDesc) void {
            const c = self.io.conn(frame.conn_id);
            var reader = BufReader{ .data = frame.payload };
            const key = reader.readPrefixed() catch return; // stays unauthenticated
            const auth = http.checkAuth(key, null, self.config.admin_password, self.reader);
            switch (auth) {
                .ok => |info| {
                    c.rpc_authenticated = true;
                    c.rpc_role = @intFromEnum(info.role);
                },
                .unauthorized, .forbidden => {}, // leave unauthenticated; resp reports failure
            }
        }

        fn decodeAndApply(self: *Self, batch: *kv.WriteBatch, frame: *FrameDesc, frame_idx: u32) ops_mod.OpResult {
            // HTTP writes use JSON decode; RPC uses binary decode.
            if (frame.protocol == .http)
                return self.decodeAndApplyHttp(batch, frame, frame_idx);

            // RPC auth handshake — validate the key and record the granted role
            // on the connection. The response (MSG_AUTH_RESP) is emitted from
            // conn state in encodeResponses.
            if (frame.msg_type == rpc.MSG_AUTH) {
                self.applyRpcAuth(frame);
                return .{};
            }

            // Leadership gate: every RPC op besides PING/AUTH mutates (fetch
            // claims leases), so a non-leader answers MSG_NOT_LEADER and the
            // SDK redials. isLeader() is re-checked live so the window where
            // a deposed leader still executes writes is one atomic load wide.
            if (self.config.raft) |raft| {
                if (frame.msg_type != rpc.MSG_PING and
                    (self.raft_state != .leading or !raft.isLeader()))
                {
                    return .{ .err = err_not_leader };
                }
            }

            // Role enforcement. The extractRpcFrames gate already dropped
            // unauthenticated non-AUTH frames when auth is required; here we
            // additionally enforce that the authenticated role may perform the op
            // (e.g. a worker key can't delete queues).
            if (self.config.admin_password.len > 0) {
                const c = self.io.conn(frame.conn_id);
                const role: http.AuthRole = @enumFromInt(c.rpc_role);
                if (!http.rpcRoleAllows(role, frame.msg_type)) return .{ .err = "forbidden" };
            }

            switch (frame.msg_type) {
                rpc.MSG_PING => return .{},

                rpc.MSG_ENQUEUE_BATCH => {
                    var reader = BufReader{ .data = frame.payload };
                    const now_ns = self.nowNs();
                    const parsed = rpc.parseEnqueue(&reader, &self.jobs_buf, now_ns) catch
                        return .{ .err = "parse error" };
                    frame.count = parsed.count;
                    // Bug B: reject at the boundary if this frame's recorded
                    // mutations could exceed one raft entry's cap (cluster mode
                    // only — single node has no entry cap and never rejects).
                    if (self.config.raft != null and
                        enqueueRecordedBound(batch, &parsed.op) > max_proposal_bytes)
                        return .{ .err = err_too_large };
                    const op_data = ops_mod.OpData{ .enqueue = parsed.op };
                    const result = self.handler.apply(batch, .enqueue, &op_data);
                    self.emitMirrorOp(.enqueue, &op_data, &result);
                    return result;
                },

                rpc.MSG_ACK_BATCH => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.parseAck(&reader, &self.acks_buf) catch
                        return .{ .err = "parse error" };
                    frame.count = parsed.count;
                    var op = parsed.op;
                    op.now_ns = self.nowNs();
                    const op_data = ops_mod.OpData{ .ack = op };
                    const result = self.handler.apply(batch, .ack, &op_data);
                    self.emitMirrorOp(.ack, &op_data, &result);
                    return result;
                },

                rpc.MSG_FAIL_BATCH => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.parseFail(&reader, &self.fails_buf) catch
                        return .{ .err = "parse error" };
                    frame.count = parsed.count;
                    var op = parsed.op;
                    op.now_ns = self.nowNs();
                    const op_data = ops_mod.OpData{ .fail = op };
                    const result = self.handler.apply(batch, .fail, &op_data);
                    self.emitMirrorOp(.fail, &op_data, &result);
                    return result;
                },

                rpc.MSG_HEARTBEAT => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.parseHeartbeat(
                        &reader,
                        &self.hb_ids_buf,
                        &self.hb_ops_buf,
                    ) catch return .{ .err = "parse error" };
                    var op = parsed;
                    op.now_ns = self.nowNs();
                    const op_data = ops_mod.OpData{ .heartbeat = op };
                    const result = self.handler.apply(batch, .heartbeat, &op_data);
                    self.emitMirrorOp(.heartbeat, &op_data, &result);
                    return result;
                },

                rpc.MSG_FETCH_BATCH => {
                    // Subscribe-only: RPC fetch never polls KV directly.
                    // Validate frame, then return empty — encodeResponses stores
                    // the subscription, fulfillSubscriptions serves pending jobs.
                    var reader = BufReader{ .data = frame.payload };
                    _ = rpc.parseFetchSubscribe(&reader) catch
                        return .{ .err = "parse error" };
                    return .{};
                },

                rpc.MSG_MAINTENANCE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.management.parseMaintenance(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .maintenance = parsed };
                    const result = self.handler.apply(batch, .maintenance, &op_data);
                    self.emitMirrorOp(.maintenance, &op_data, &result);
                    return result;
                },

                rpc.MSG_QUEUE_CONFIG => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.management.parseQueueConfig(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .queue_config = parsed };
                    const result = self.handler.apply(batch, .queue_config, &op_data);
                    self.emitMirrorOp(.queue_config, &op_data, &result);
                    return result;
                },

                rpc.MSG_CLEAR_QUEUE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.management.parseClearQueue(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .clear_queue = parsed };
                    const result = self.handler.apply(batch, .clear_queue, &op_data);
                    self.emitMirrorOp(.clear_queue, &op_data, &result);
                    return result;
                },

                rpc.MSG_DELETE_QUEUE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.management.parseDeleteQueue(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .delete_queue = parsed };
                    const result = self.handler.apply(batch, .delete_queue, &op_data);
                    self.emitMirrorOp(.delete_queue, &op_data, &result);
                    return result;
                },

                rpc.MSG_BULK_ACTION => {
                    var reader = BufReader{ .data = frame.payload };
                    var parsed = rpc.bulk.parseBulkAction(&reader, &self.bulk_ids_buf) catch
                        return .{ .err = "parse error" };
                    // Override client now_ns with server clock (deterministic core).
                    parsed.now_ns = self.nowNs();
                    const op_data = ops_mod.OpData{ .bulk_action = parsed };
                    const result = self.handler.apply(batch, .bulk_action, &op_data);
                    self.emitMirrorOp(.bulk_action, &op_data, &result);
                    return result;
                },

                rpc.MSG_BATCH_CREATE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.batch.parseBatchCreate(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .batch_create = parsed };
                    const result = self.handler.apply(batch, .batch_create, &op_data);
                    self.emitMirrorOp(.batch_create, &op_data, &result);
                    return result;
                },

                rpc.MSG_BATCH_SEAL => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.batch.parseBatchSeal(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .batch_seal = parsed };
                    const result = self.handler.apply(batch, .batch_seal, &op_data);
                    self.emitMirrorOp(.batch_seal, &op_data, &result);
                    return result;
                },

                rpc.MSG_CRON_CREATE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.cron.parseCronCreate(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .cron_create = parsed };
                    const result = self.handler.apply(batch, .cron_create, &op_data);
                    self.emitMirrorOp(.cron_create, &op_data, &result);
                    return result;
                },

                rpc.MSG_CRON_UPDATE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.cron.parseCronUpdate(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .cron_update = parsed };
                    const result = self.handler.apply(batch, .cron_update, &op_data);
                    self.emitMirrorOp(.cron_update, &op_data, &result);
                    return result;
                },

                rpc.MSG_CRON_DELETE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.cron.parseCronDelete(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .cron_delete = parsed };
                    const result = self.handler.apply(batch, .cron_delete, &op_data);
                    self.emitMirrorOp(.cron_delete, &op_data, &result);
                    return result;
                },

                rpc.MSG_CRON_TRIGGER => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.cron.parseCronTrigger(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .cron_trigger = parsed };
                    const result = self.handler.apply(batch, .cron_trigger, &op_data);
                    self.emitMirrorOp(.cron_trigger, &op_data, &result);
                    return result;
                },

                else => return .{ .err = "unknown message type" },
            }
        }

        fn decodeAndApplyHttp(self: *Self, batch: *kv.WriteBatch, frame: *FrameDesc, frame_idx: u32) ops_mod.OpResult {
            const now_ns = self.nowNs();

            // Leadership gate: HTTP frames reaching the pipeline are writes
            // (reads are served by http_read). Non-leader → 503 not_leader.
            if (self.config.raft) |raft| {
                if (self.raft_state != .leading or !raft.isLeader()) {
                    return .{ .err = err_not_leader };
                }
            }

            // Generate server-side IDs for operations that need them.
            switch (frame.msg_type) {
                rpc.MSG_ENQUEUE_BATCH => {
                    self.http_id_counter += 1;
                    const id = http.generateId(&self.http_id_bufs[frame_idx], now_ns, self.http_id_counter);
                    self.http_scratch.jobs[0].job_id = id;
                    frame.path_param = id;
                },
                rpc.MSG_BATCH_CREATE, rpc.MSG_CRON_CREATE, rpc.MSG_SET_BUDGET, rpc.MSG_MODIFY_SETTING => {
                    self.http_id_counter += 1;
                    const id = http.generateId(&self.http_scratch.id_buf2, now_ns, self.http_id_counter);
                    self.http_scratch.id2_len = @intCast(id.len);
                    frame.path_param = id;
                },
                rpc.MSG_CRON_TRIGGER => {
                    // Trigger needs a generated job_id, stored in id_buf2
                    self.http_id_counter += 1;
                    const id = http.generateId(&self.http_scratch.id_buf2, now_ns, self.http_id_counter);
                    self.http_scratch.id2_len = @intCast(id.len);
                },
                else => {},
            }

            var decoded = http.decodeWrite(
                frame.msg_type,
                frame.payload,
                frame.path_param,
                frame.sub_action,
                now_ns,
                &self.http_scratch,
                frame.http_path,
            );

            // API key create: copy raw key to per-frame buffer for response encoding.
            if (frame.msg_type == rpc.MSG_MODIFY_SETTING and
                std.mem.eql(u8, frame.sub_action, "api_key") and decoded.count > 0)
            {
                @memcpy(self.http_id_bufs[frame_idx][0..64], self.http_scratch.api_key_raw[0..64]);
                frame.path_param = self.http_id_bufs[frame_idx][0..64];
            }

            // Webhook create: copy webhook ID to per-frame buffer for response encoding.
            if (frame.msg_type == rpc.MSG_MODIFY_SETTING and
                std.mem.eql(u8, frame.sub_action, "webhook_create") and decoded.count > 0)
            {
                @memcpy(self.http_id_bufs[frame_idx][0..32], self.http_scratch.id_buf2[0..32]);
                frame.path_param = self.http_id_bufs[frame_idx][0..32];
            }

            // Batch enqueue: generate remaining IDs (first was pre-generated above).
            if (frame.msg_type == rpc.MSG_ENQUEUE_BATCH and decoded.count > 1) {
                for (1..decoded.count) |j| {
                    self.http_id_counter += 1;
                    const jid = http.generateId(&self.http_id_bufs[j], now_ns, self.http_id_counter);
                    self.http_scratch.jobs[j].job_id = jid;
                }
                // Re-point the slice in op_data to include updated IDs.
                decoded.op_data.enqueue.jobs = self.http_scratch.jobs[0..decoded.count];
            }

            frame.count = decoded.count;

            const op_type: ops_mod.OpType = switch (frame.msg_type) {
                rpc.MSG_ENQUEUE_BATCH => .enqueue,
                rpc.MSG_FETCH_BATCH => .fetch,
                rpc.MSG_ACK_BATCH => .ack,
                rpc.MSG_FAIL_BATCH => .fail,
                rpc.MSG_HEARTBEAT => .heartbeat,
                rpc.MSG_BULK_ACTION => .bulk_action,
                rpc.MSG_QUEUE_CONFIG => .queue_config,
                rpc.MSG_CLEAR_QUEUE => .clear_queue,
                rpc.MSG_DELETE_QUEUE => .delete_queue,
                rpc.MSG_BATCH_CREATE => .batch_create,
                rpc.MSG_BATCH_SEAL => .batch_seal,
                rpc.MSG_CRON_CREATE => .cron_create,
                rpc.MSG_CRON_UPDATE => .cron_update,
                rpc.MSG_CRON_DELETE => .cron_delete,
                rpc.MSG_CRON_TRIGGER => .cron_trigger,
                rpc.MSG_SET_BUDGET => .set_budget,
                rpc.MSG_DELETE_BUDGET => .delete_budget,
                rpc.MSG_MODIFY_SETTING => .modify_setting,
                rpc.MSG_GLOBAL_CONFIG => .global_config,
                else => return .{ .err = "unsupported http write" },
            };

            // Bug B: same per-frame proposal-cap boundary check as the RPC path.
            // An HTTP enqueue amplifies identically (tags inline + tq| indexes);
            // reject before apply in cluster mode so the cap assert stays a
            // backstop. http.encodeWriteResponse maps err_too_large to 413.
            if (op_type == .enqueue and self.config.raft != null and
                enqueueRecordedBound(batch, &decoded.op_data.enqueue) > max_proposal_bytes)
                return .{ .err = err_too_large };

            var result = self.handler.apply(batch, op_type, &decoded.op_data);
            self.emitMirrorOp(op_type, &decoded.op_data, &result);

            // Wake fetch waiters. The RPC path does this in notifyForFrame by
            // re-parsing the binary payload, but an HTTP frame's payload is JSON
            // and would fail that parse — leaving RPC-subscribed workers asleep
            // when jobs arrive via the HTTP API. Capture the affected queues here
            // where the decoded op is in hand. Names are copied into pipeline
            // buffers and consumed post-commit by fulfillSubscriptions.
            if (result.err == null) self.recordHttpNotify(op_type, &decoded.op_data, &result);

            // Audit: write entry in same batch for management ops.
            if (frame.actor_len > 0) {
                self.handler.writeAuditEntry(batch, op_type, &decoded.op_data, &result, frame.actorSlice(), now_ns);
            }

            // Batch enqueue: copy job_ids into result.fetched for response encoding.
            if (frame.msg_type == rpc.MSG_ENQUEUE_BATCH and decoded.count > 1) {
                for (0..decoded.count) |j| {
                    const jid = self.http_scratch.jobs[j].job_id;
                    @memcpy(result.fetched[j].id_buf[0..jid.len], jid);
                    result.fetched[j].id_len = @intCast(jid.len);
                }
                result.affected = decoded.count;
            }

            return result;
        }


        // ====================================================================
        // Encode — write responses into send_bufs
        // ====================================================================

        /// Encode responses into send_bufs. Does NOT queue sends — call flushSends after.
        fn encodeResponses(self: *Self) void {
            self.send_conn_count = 0;

            for (self.frames[0..self.frame_count], 0..) |frame, i| {
                const c = self.io.conn(frame.conn_id);
                if (c.phase == .free) continue;

                // RPC fetch: always subscribe. fulfillSubscriptions serves jobs.
                // HTTP fetch returns empty immediately (request-response protocol).
                if (frame.msg_type == rpc.MSG_FETCH_BATCH and frame.protocol == .rpc and
                    self.results[i].err == null)
                {
                    if (!self.storeSubscription(frame.conn_id, &frame)) {
                        // waiting_conns at capacity: reject with an explicit
                        // error so the worker backs off and reconnects, rather
                        // than hanging forever on a subscription that was never
                        // registered (M6 — the old bare return silently dropped
                        // it after the conn was already marked waiting).
                        self.encodeErrorFrame(frame.conn_id, frame.req_id, "subscription rejected: server at connection capacity");
                    }
                    continue;
                }

                if (frame.protocol == .http) {
                    const resp_len = http.encodeWriteResponse(
                        c.send_buf,
                        frame.msg_type,
                        &self.results[i],
                        frame.path_param,
                        frame.sub_action,
                        &self.stores[0],
                        frame.payload,
                    );
                    if (resp_len > 0) {
                        self.trackSendConn(frame.conn_id);
                        c.send_len = resp_len;
                    }
                    continue;
                }

                // RPC auth handshake response: [status:1 (0=ok,1=fail)][role:1].
                // applyRpcAuth already set the connection state during apply.
                if (frame.msg_type == rpc.MSG_AUTH) {
                    self.trackSendConn(frame.conn_id);
                    const write_start = c.send_len;
                    var aw = BufWriter{ .buf = c.send_buf[write_start..] };
                    aw.pos = rpc.FRAME_HEADER_SIZE;
                    aw.writeU8(if (c.rpc_authenticated) 0 else 1);
                    aw.writeU8(c.rpc_role);
                    const alen: u32 = @intCast(aw.pos - rpc.FRAME_HEADER_SIZE);
                    rpc.writeFrameHeader(
                        c.send_buf[write_start..][0..rpc.FRAME_HEADER_SIZE],
                        rpc.MSG_AUTH_RESP,
                        frame.req_id,
                        alen,
                    );
                    c.send_len += @intCast(aw.pos);
                    continue;
                }

                // Raft follower rejection: a dedicated frame type carrying a
                // leader hint (empty until leader identity is plumbed) so
                // SDKs can distinguish redial-and-replay from an op error.
                if (self.results[i].err) |e| {
                    if (e.ptr == err_not_leader.ptr) {
                        self.trackSendConn(frame.conn_id);
                        const c2 = self.io.conn(frame.conn_id);
                        const n_written = raft_gate.encodeNotLeader(
                            c2.send_buf[c2.send_len..],
                            frame.req_id,
                            .{},
                        ) catch continue; // send_buf full: drop, client times out + redials
                        c2.send_len += @intCast(n_written);
                        continue;
                    }
                }

                const resp_type = switch (frame.msg_type) {
                    rpc.MSG_PING => rpc.MSG_PONG,
                    else => rpc.responseType(frame.msg_type) orelse continue,
                };

                self.trackSendConn(frame.conn_id);

                // Append response after any previous responses for this conn
                const write_start = c.send_len;
                var writer = BufWriter{ .buf = c.send_buf[write_start..] };
                writer.pos = rpc.FRAME_HEADER_SIZE; // reserve header space

                self.encodeResult(&writer, frame.msg_type, &self.results[i], frame.count);

                const payload_len: u32 = @intCast(writer.pos - rpc.FRAME_HEADER_SIZE);
                rpc.writeFrameHeader(
                    c.send_buf[write_start..][0..rpc.FRAME_HEADER_SIZE],
                    resp_type,
                    frame.req_id,
                    payload_len,
                );

                c.send_len += @intCast(writer.pos);
            }
        }

        /// Encode a standalone MSG_ERROR frame into a connection's send buffer
        /// and mark it for flushing. Used to reject an operation (e.g. a fetch
        /// subscribe when waiting_conns is full) so the client sees an explicit
        /// error instead of silence. The message is a short static string and
        /// the send buffer is sized for a full payload, so it always fits.
        fn encodeErrorFrame(self: *Self, conn_id: u16, req_id: u32, msg: []const u8) void {
            const c = self.io.conn(conn_id);
            if (c.phase == .free) return;
            const write_start = c.send_len;
            var w = BufWriter{ .buf = c.send_buf[write_start..] };
            w.pos = rpc.FRAME_HEADER_SIZE; // reserve header space
            rpc.encodeError(&w, msg);
            const payload_len: u32 = @intCast(w.pos - rpc.FRAME_HEADER_SIZE);
            rpc.writeFrameHeader(
                c.send_buf[write_start..][0..rpc.FRAME_HEADER_SIZE],
                rpc.MSG_ERROR,
                req_id,
                payload_len,
            );
            c.send_len += @intCast(w.pos);
            self.trackSendConn(conn_id);
        }

        /// Record a connection that needs a send flushed (dedup).
        fn trackSendConn(self: *Self, conn_id: u16) void {
            for (self.send_conns[0..self.send_conn_count]) |existing| {
                if (existing == conn_id) return;
            }
            assert.check(
                self.send_conn_count < self.send_conns.len,
                "pipeline: send_conns overflow",
                .{},
            );
            self.send_conns[self.send_conn_count] = conn_id;
            self.send_conn_count += 1;
        }

        /// Queue one send per connection that has accumulated response data.
        fn flushSends(self: *Self) void {
            for (self.send_conns[0..self.send_conn_count]) |conn_id| {
                const c = self.io.conn(conn_id);
                if (c.send_len > 0) {
                    self.io.queueSend(conn_id, c.send_len);
                }
            }
        }

        fn encodeResult(self: *Self, writer: *BufWriter, msg_type: u8, result: *const ops_mod.OpResult, count: u16) void {
            switch (msg_type) {
                rpc.MSG_PING => {},
                rpc.MSG_ENQUEUE_BATCH => rpc.encodeEnqueueResp(writer, result, count),
                rpc.MSG_ACK_BATCH => rpc.encodeAckResp(writer, result, count),
                rpc.MSG_FAIL_BATCH => rpc.encodeFailResp(writer, result, count),
                rpc.MSG_HEARTBEAT => rpc.encodeHeartbeatResp(writer, result, count),
                rpc.MSG_FETCH_BATCH => self.encodeFetchResult(writer, result),
                rpc.MSG_MAINTENANCE,
                rpc.MSG_QUEUE_CONFIG,
                rpc.MSG_CLEAR_QUEUE,
                rpc.MSG_DELETE_QUEUE,
                rpc.MSG_BULK_ACTION,
                => rpc.management.encodeGenericResp(writer, result),
                rpc.MSG_BATCH_CREATE => {
                    // batch_create response needs the generated batch_id
                    // For now, use generic response
                    rpc.management.encodeGenericResp(writer, result);
                },
                rpc.MSG_BATCH_SEAL,
                rpc.MSG_CRON_CREATE,
                rpc.MSG_CRON_UPDATE,
                rpc.MSG_CRON_DELETE,
                rpc.MSG_CRON_TRIGGER,
                rpc.MSG_SET_BUDGET,
                rpc.MSG_DELETE_BUDGET,
                rpc.MSG_MODIFY_SETTING,
                rpc.MSG_GLOBAL_CONFIG,
                => rpc.management.encodeGenericResp(writer, result),
                else => {
                    if (result.err) |msg| {
                        rpc.lifecycle.encodeError(writer, msg);
                    }
                },
            }
        }

        fn encodeFetchResult(self: *Self, writer: *BufWriter, result: *const ops_mod.OpResult) void {
            const count: u16 = @intCast(result.affected);
            writer.writeU16(count);

            for (0..count) |i| {
                const fetched = &result.fetched[i];
                const job_id = fetched.id_buf[0..fetched.id_len];
                const queue = fetched.queue_buf[0..fetched.queue_len];

                writer.writePrefixed(job_id);
                writer.writePrefixed(queue);
                writer.writeU16(fetched.attempt);
                writer.writeU16(fetched.max_retries);

                // Checkpoint + tags (not stored in FetchedJob — write empty)
                // u8 length prefix (0 = empty), matching SDK wire format.
                writer.writeU8(0);
                writer.writeU8(0);

                // Payload: read via get() (returns a right-sized slice) rather
                // than getInto() into a fixed scratch buffer, which overflowed
                // on payloads larger than the scratch size. The fetch claim
                // already bounded the total response to the send buffer, so the
                // cumulative writes fit.
                var jpk_buf: keys.KeyBuf = undefined;
                const payload_key = keys.jobPayloadKey(&jpk_buf, job_id);
                var store = &self.stores[0];
                var batch = store.newBatch();
                defer batch.close();
                // Payload length is a u32: rpc.MAX_PAYLOAD_SIZE is 256 KiB and
                // the default max_payload_size is 64 KiB, both of which exceed
                // u16's 65535 cap — a u16 field @intCast-panicked on a legal
                // 64 KiB payload and truncated anything larger.
                if (batch.get(payload_key)) |payload_bytes| {
                    writer.writeU32(@intCast(payload_bytes.len));
                    writer.writeBytes(payload_bytes);
                } else {
                    writer.writeU32(0);
                }

                writer.writeU64(fetched.lease_token);
            }
        }



        // ====================================================================
        // Fetch subscriptions — store and fulfill
        // ====================================================================

        /// Store a fetch subscription in ConnState and register the connection
        /// in waiting_conns. Subscribe-only: RPC fetch always subscribes —
        /// fulfillSubscriptions serves pending jobs. Re-parses the subscription
        /// from the frame payload (still valid before compaction).
        ///
        /// Returns false only when waiting_conns is at capacity and this
        /// connection is not already tracked; the caller must then reject the
        /// subscribe with an error. The capacity gate runs BEFORE any ConnState
        /// mutation, so a rejected connection is never left with c.waiting=true
        /// (which previously hung the worker forever — it believed it was
        /// subscribed while never appearing in waiting_conns, M6).
        fn storeSubscription(self: *Self, conn_id: u16, frame: *const FrameDesc) bool {
            const c = self.io.conn(conn_id);
            if (c.phase == .free) return true; // conn closed; nothing to register or report

            // The caller only reaches here for RPC frames; HTTP is
            // request-response and never subscribes.
            assert.check(frame.protocol == .rpc, "pipeline: storeSubscription on non-RPC frame", .{});

            // Re-parse subscription from frame payload. Already validated at
            // decode time (results[i].err == null), so a boundary re-parse
            // failure just skips registration without an error.
            var reader = BufReader{ .data = frame.payload };
            const sub = rpc.parseFetchSubscribe(&reader) catch return true;

            // Locate any existing waiting_conns entry: a re-subscribe updates
            // ConnState in place without consuming another slot.
            var tracked_idx: ?u32 = null;
            for (self.waiting_conns[0..self.waiting_conn_count], 0..) |wc, idx| {
                if (wc == conn_id) {
                    tracked_idx = @intCast(idx);
                    break;
                }
            }
            // Capacity gate — BEFORE touching ConnState. Sized for the
            // connection target, so this is only reachable past it. Reject
            // (caller sends an error) rather than silently dropping: the worker
            // must learn it is not subscribed. No state has been mutated yet, so
            // the connection stays clean and non-waiting.
            if (tracked_idx == null and self.waiting_conn_count >= max_waiting_conns) return false;

            // Copy queue names into ConnState fixed buffers.
            c.queue_count = sub.queue_count;
            for (0..sub.queue_count) |qi| {
                const qname = sub.queues[qi];
                const qlen: u8 = @intCast(@min(qname.len, c.queue_bufs[qi].len));
                @memcpy(c.queue_bufs[qi][0..qlen], qname[0..qlen]);
                c.queue_lens[qi] = qlen;
            }

            // Copy worker_id.
            const wlen: u8 = @intCast(@min(sub.worker_id.len, c.worker_id_buf.len));
            @memcpy(c.worker_id_buf[0..wlen], sub.worker_id[0..wlen]);
            c.worker_id_len = wlen;

            c.prefetch = sub.prefetch;
            c.prefetch_window = sub.prefetch;
            c.lease_ms = sub.lease_ms;
            c.last_req_id = frame.req_id;
            c.waiting = true;

            // Record subscribed queues as notified so fulfillSubscriptions
            // checks for pending jobs on the same tick (subscribe-only fetch).
            for (0..sub.queue_count) |qi| {
                self.recordNotifiedQueue(sub.queues[qi]);
            }

            if (tracked_idx == null) {
                tracked_idx = self.waiting_conn_count;
                self.waiting_conns[self.waiting_conn_count] = conn_id;
                self.waiting_conn_count += 1;
            }
            // Invariant: a connection marked waiting is always in waiting_conns.
            assert.check(
                self.waiting_conns[tracked_idx.?] == conn_id,
                "pipeline: waiting conn not tracked in waiting_conns",
                .{},
            );
            return true;
        }

        /// Save a recv conn_id for processing when a prepare slot frees up.
        /// Called when all prepare slots are full and recv CQEs arrive but
        /// frames cannot be processed yet (no free slot for a new batch).
        fn deferRecvConn(self: *Self, conn_id: u16) void {
            for (self.deferred_recv_conns[0..self.deferred_recv_conn_count]) |existing| {
                if (existing == conn_id) return;
            }
            assert.check(
                self.deferred_recv_conn_count < max_completions,
                "pipeline: deferred_recv_conns overflow",
                .{},
            );
            self.deferred_recv_conns[self.deferred_recv_conn_count] = conn_id;
            self.deferred_recv_conn_count += 1;
        }

        /// Clean up subscription state when a connection closes.
        /// ConnState may already be reset by the IO backend, so we can't check c.waiting.
        /// Unconditionally try to remove from waiting list.
        fn onConnClosed(self: *Self, conn_id: u16) void {
            self.removeWaitingConn(conn_id);
        }

        /// Remove a connection from the waiting list (e.g., on disconnect or fulfillment).
        fn removeWaitingConn(self: *Self, conn_id: u16) void {
            var i: u32 = 0;
            while (i < self.waiting_conn_count) {
                if (self.waiting_conns[i] == conn_id) {
                    // Swap-remove.
                    self.waiting_conn_count -= 1;
                    self.waiting_conns[i] = self.waiting_conns[self.waiting_conn_count];
                    return;
                }
                i += 1;
            }
        }

        /// After commit+encode, scan waiting connections and push jobs if notified queues match.
        fn fulfillSubscriptions(self: *Self) void {
            // A fetch claim writes to the LOCAL KV (lease + active key) and is
            // then proposed. Only fulfill when the node may write locally:
            // single-node, or a confirmed raft leader. On a follower / acquiring
            // / mid-stepdown node the local write would commit then fail the
            // proposal → false divergence panic (Bug A). Waiting workers on a
            // deposed node are drained via evictWaitingSubscribers on step-down.
            if (!self.canWriteLocally()) return;
            if (self.notified_queue_count == 0) return;
            if (self.waiting_conn_count == 0) return;

            var kv_batch = self.stores[0].newBatch();
            defer kv_batch.close();
            var did_fulfill = false;

            // Enable mutation recording for raft replication.
            const record_mutations = self.config.raft != null;
            if (record_mutations) {
                self.mut_list.clearRetainingCapacity();
                kv_batch.enableRecording(self.allocator, &self.mut_list);
            }
            defer if (record_mutations) kv_batch.freeMutations();

            // Partition: served connections move behind a shrinking boundary.
            // After the loop, served connections are at [end..waiting_conn_count],
            // un-served at [0..end]. Next tick, un-served get priority.
            var i: u32 = 0;
            var end: u32 = self.waiting_conn_count;

            while (i < end) {
                const conn_id = self.waiting_conns[i];
                const c = self.io.conn(conn_id);
                if (c.phase == .free or !c.waiting or c.prefetch == 0 or
                    !self.hasQueueOverlap(c))
                {
                    i += 1;
                    continue;
                }

                // Budget guarantee: only fulfill a connection whose free send
                // buffer already holds at least one max-size job (max payload +
                // per-job wire + frame overhead). A partially-drained buffer that
                // can't fit one max job is SKIPPED here — not fulfilled with a
                // starvation-prone shrunken budget. Skipping is safe for liveness
                // only because .send_done re-notifies this connection's queues
                // once its buffer drains (notified_queue_count resets each tick,
                // so a bare skip would strand the job).
                const send_room: u32 = @intCast(c.send_buf.len - c.send_len);
                const frame_overhead: u32 = @intCast(rpc.FRAME_HEADER_SIZE + 2);
                // One max-size job: FetchedJob id/queue buffers are 64 bytes each
                // and a payload can reach the configured cap. fetchedJobWireSize
                // is exact, so this is the true worst-case single-job wire size.
                const one_max_job: u32 = frame_overhead +
                    @as(u32, @intCast(handler_fetch.fetchedJobWireSize(64, 64, self.config.max_payload_size)));
                if (send_room < one_max_job) {
                    i += 1;
                    continue;
                }

                var queue_slices: [16][]const u8 = undefined;
                for (0..c.queue_count) |qi| {
                    queue_slices[qi] = c.queue_bufs[qi][0..c.queue_lens[qi]];
                }

                // fetchedJobWireSize is exact (no slack needed): the claim stops
                // before the encoded response would exceed this budget, leaving
                // any remaining jobs pending for the next push. Since send_room ≥
                // one_max_job, the budget covers at least one max job, so the
                // first-job admission in applyFetch can never overflow.
                const budget: u32 = send_room - frame_overhead;

                const op_data = ops_mod.OpData{ .fetch = .{
                    .queues = queue_slices[0..c.queue_count],
                    .worker_id = c.worker_id_buf[0..c.worker_id_len],
                    .lease_duration_ms = c.lease_ms,
                    .count = c.prefetch,
                    .now_ns = self.nowNs(),
                    .max_response_bytes = budget,
                } };

                const result = self.handler.apply(&kv_batch, .fetch, &op_data);

                if (result.affected == 0) {
                    i += 1;
                    continue;
                }

                did_fulfill = true;
                self.emitMirrorOp(.fetch, &op_data, &result);

                const write_start = c.send_len;
                var writer = BufWriter{ .buf = c.send_buf[write_start..] };
                writer.pos = rpc.FRAME_HEADER_SIZE;

                self.encodeFetchResult(&writer, &result);

                const payload_len: u32 = @intCast(writer.pos - rpc.FRAME_HEADER_SIZE);
                rpc.writeFrameHeader(
                    c.send_buf[write_start..][0..rpc.FRAME_HEADER_SIZE],
                    rpc.MSG_FETCH_BATCH_RESP,
                    c.last_req_id,
                    payload_len,
                );

                c.send_len += @intCast(writer.pos);
                // Invariant: the encoded push fit the connection's send buffer.
                // Guaranteed by the one_max_job room check + the exact budget
                // handed to applyFetch; assert it since the cost is one compare.
                assert.check(c.send_len <= c.send_buf.len, "fulfill: encoded fetch push overflowed send_buf ({d} > {d})", .{ c.send_len, c.send_buf.len });
                self.trackSendConn(conn_id);

                c.prefetch -= result.affected;
                self.subscriptions_fulfilled += 1;

                // Bounded-pass index flush (see executeBatch): drain the indexer
                // between fetches so a later fetch's transitions can never
                // overflow the effect buffer and be silently dropped (M10).
                if (self.handler.indexer.nearFull()) self.handler.indexer.flush(&kv_batch);

                // Swap served connection behind the boundary.
                end -= 1;
                self.waiting_conns[i] = self.waiting_conns[end];
                self.waiting_conns[end] = conn_id;
                // Don't increment i — check the swapped-in connection.
            }

            if (did_fulfill) {
                // Flush deferred indexes (fetch transitions) into same batch.
                self.handler.indexer.flush(&kv_batch);
                kv_batch.commit();
                self.proposeRecorded();
            }
        }

        /// Check if any of the connection's subscribed queues were notified this tick.
        fn hasQueueOverlap(self: *const Self, c: *const ConnState) bool {
            for (0..c.queue_count) |qi| {
                const sub_queue = c.queue_bufs[qi][0..c.queue_lens[qi]];
                for (0..self.notified_queue_count) |ni| {
                    const notified = self.notified_queue_bufs[ni][0..self.notified_queue_lens[ni]];
                    if (std.mem.eql(u8, sub_queue, notified)) return true;
                }
            }
            return false;
        }

        /// Record all of a subscribed connection's queues as notified this tick,
        /// so fulfillSubscriptions re-checks it. Used to re-arm delivery when a
        /// connection's send buffer drains (see the .send_done handler).
        fn recordConnNotified(self: *Self, c: *const ConnState) void {
            for (0..c.queue_count) |qi| {
                self.recordNotifiedQueue(c.queue_bufs[qi][0..c.queue_lens[qi]]);
            }
        }

        /// Record a queue name as notified this tick (deduped).
        fn recordNotifiedQueue(self: *Self, queue: []const u8) void {
            // Deduplicate.
            for (0..self.notified_queue_count) |i| {
                const existing = self.notified_queue_bufs[i][0..self.notified_queue_lens[i]];
                if (std.mem.eql(u8, existing, queue)) return;
            }
            if (self.notified_queue_count >= max_notified_queues) return; // saturate, don't crash
            const idx = self.notified_queue_count;
            const qlen: u8 = @intCast(@min(queue.len, 64));
            @memcpy(self.notified_queue_bufs[idx][0..qlen], queue[0..qlen]);
            self.notified_queue_lens[idx] = qlen;
            self.notified_queue_count += 1;
        }

        // ====================================================================
        // Cancel signals — push to workers whose active jobs were cancelled
        // ====================================================================

        fn pushCancelSignals(self: *Self) void {
            if (self.handler.cancel_signal_count == 0) return;

            for (self.handler.cancel_signals[0..self.handler.cancel_signal_count]) |*sig| {
                const worker_id = sig.workerId();

                // Find the subscribed connection with this worker_id.
                for (self.waiting_conns[0..self.waiting_conn_count]) |conn_id| {
                    const c = self.io.conn(conn_id);
                    if (c.phase == .free) continue;
                    if (c.worker_id_len != worker_id.len) continue;
                    if (!std.mem.eql(u8, c.worker_id_buf[0..c.worker_id_len], worker_id)) continue;

                    // Push MSG_CANCEL_SIGNAL frame into this connection's send_buf.
                    const write_start = c.send_len;
                    const space = c.send_buf.len - write_start;
                    const needed = rpc.FRAME_HEADER_SIZE + 2 + 1 + sig.job_id_len;
                    assert.check(space >= needed, "pushCancelSignals: send_buf overflow for conn {d}", .{conn_id});

                    var writer = BufWriter{ .buf = c.send_buf[write_start..] };
                    writer.pos = rpc.FRAME_HEADER_SIZE;
                    writer.writeU16(1); // count
                    writer.writePrefixed(sig.jobId());

                    const payload_len: u32 = @intCast(writer.pos - rpc.FRAME_HEADER_SIZE);
                    rpc.writeFrameHeader(
                        c.send_buf[write_start..][0..rpc.FRAME_HEADER_SIZE],
                        rpc.MSG_CANCEL_SIGNAL,
                        0, // no req_id for server push
                        payload_len,
                    );

                    c.send_len += @intCast(writer.pos);
                    self.trackSendConn(conn_id);
                    break;
                }
            }
        }

        /// Handle webhook HTTP response. Parses status code, closes conn.
        /// Deletes the whd| delivery record on success (2xx), reschedules on failure.
        fn handleWebhookResponse(self: *Self, conn_id: u16, c: *ConnState) void {
            const data = c.recv_buf[0..c.recv_pos];

            // Parse HTTP status from "HTTP/1.1 200 OK\r\n..."
            const success = if (data.len >= 12 and std.mem.startsWith(u8, data, "HTTP/"))
                data[9] == '2' // 2xx status
            else
                false;

            if (success) {
                std.debug.print("corvo: webhook delivered (conn {d})\n", .{conn_id});
            } else {
                std.debug.print("corvo: webhook delivery failed (conn {d})\n", .{conn_id});
            }

            self.io.queueClose(conn_id);
        }

        /// Handle a webhook outbound connection completing.
        /// Triggers the HTTP POST send (data already in send_buf).
        fn handleWebhookConnected(self: *Self, conn_id: u16) void {
            const c = self.io.conn(conn_id);
            assert.check(c.phase != .free, "handleWebhookConnected: conn {d} is free", .{conn_id});
            if (c.send_len == 0) {
                self.io.queueClose(conn_id);
                return;
            }
            self.io.queueSend(conn_id, c.send_len);
        }

        /// Write webhook dispatch records to KV for pending delivery.
        /// Called after executeBatch commit. Uses a separate batch so dispatch
        /// records are durable but don't block the main apply path.
        fn writeWebhookDispatchRecords(self: *Self) void {
            if (self.handler.webhook_event_count == 0) return;

            var batch = self.stores[0].newBatch();
            defer batch.close();

            for (self.handler.webhook_events[0..self.handler.webhook_event_count]) |*ev| {
                // Build delivery record JSON.
                var val_buf: [1024]u8 = undefined;
                const val = std.fmt.bufPrint(&val_buf,
                    "{{\"webhook_id\":\"{s}\",\"url\":\"{s}\",\"job_id\":\"{s}\",\"queue\":\"{s}\",\"event\":\"{s}\",\"attempt\":0,\"max_attempts\":5,\"created_at_ns\":{d}}}",
                    .{ ev.webhookIdSlice(), ev.urlSlice(), ev.jobId(), ev.queueSlice(), ev.eventName(), ev.now_ns },
                ) catch continue;

                // Key: whd|{now_ns:8BE}{job_id} — due immediately for first attempt.
                var key_buf: keys.KeyBuf = undefined;
                const key = keys.webhookDispatchKey(&key_buf, ev.now_ns, ev.jobId());
                batch.set(key, val);
            }

            batch.commit();
        }

        // ====================================================================
        // Notify — wake queue waiters post-commit
        // ====================================================================

        /// Record fetch-wake notifications for an HTTP write op at decode time.
        /// Mirrors the RPC notifyForFrame queue notifies (enqueue/ack/fail), but
        /// reads the already-decoded op instead of re-parsing a binary payload.
        /// Queue names are copied by recordNotifiedQueue; the QueueNotifier wake
        /// is deferred to a later tick by the single-threaded event loop, so
        /// recording here (pre-commit) is safe.
        fn recordHttpNotify(self: *Self, op_type: ops_mod.OpType, data: *const ops_mod.OpData, result: *const ops_mod.OpResult) void {
            switch (op_type) {
                .enqueue => for (data.enqueue.jobs) |job| {
                    if (job.queue.len == 0) continue;
                    self.notify.notify(job.queue);
                    self.recordNotifiedQueue(job.queue);
                },
                .ack => for (data.ack.acks) |ack| {
                    if (ack.queue.len == 0) continue;
                    self.notify.notify(ack.queue);
                    self.recordNotifiedQueue(ack.queue);
                },
                .fail => for (data.fail.jobs) |job| {
                    if (job.queue.len == 0) continue;
                    self.notify.notify(job.queue);
                    self.recordNotifiedQueue(job.queue);
                },
                // Bulk/other ops (e.g. requeue → pending) report affected queues
                // via notify_queues; honor them the same way the RPC else-branch
                // in notifyForFrame does.
                else => if (result.notify_queues) |queues| {
                    self.notify.notifyQueues(queues);
                    for (queues) |q| self.recordNotifiedQueue(q);
                },
            }
        }

        fn notifyForFrame(self: *Self, frame: *const FrameDesc, result: *const ops_mod.OpResult) void {
            // A rejected op changed no state, so it wakes no waiters. Critically,
            // a frame rejected with err_not_leader (deposed/follower node) must
            // NOT record its queues as notified: doing so let a follower with
            // stale waiting_conns run fulfillSubscriptions, claim jobs into the
            // LOCAL KV, and then fail the proposal — a false divergence panic
            // (Bug A). This mirrors the HTTP path's `if err == null` notify gate.
            if (result.err != null) return;
            // HTTP frames carry JSON payloads that the binary re-parse below can't
            // read; their wakes are recorded at decode time via recordHttpNotify.
            if (frame.protocol == .http) return;
            switch (frame.msg_type) {
                rpc.MSG_ENQUEUE_BATCH => {
                    // Enqueue can wake fetch waiters on affected queues.
                    // Re-parse to get queue names — payload slices still valid
                    // (compaction hasn't happened yet).
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.parseEnqueue(&reader, &self.jobs_buf, 0) catch return;
                    for (parsed.op.jobs) |job| {
                        self.notify.notify(job.queue);
                        self.recordNotifiedQueue(job.queue);
                    }
                },
                rpc.MSG_ACK_BATCH,
                rpc.MSG_FAIL_BATCH,
                => {
                    // Ack/fail can free capacity → wake waiters.
                    // Re-parse to get queue names.
                    if (frame.msg_type == rpc.MSG_ACK_BATCH) {
                        var reader = BufReader{ .data = frame.payload };
                        const parsed = rpc.parseAck(&reader, &self.acks_buf) catch return;
                        for (parsed.op.acks) |ack| {
                            self.notify.notify(ack.queue);
                            self.recordNotifiedQueue(ack.queue);
                        }
                    } else {
                        var reader = BufReader{ .data = frame.payload };
                        const parsed = rpc.parseFail(&reader, &self.fails_buf) catch return;
                        for (parsed.op.jobs) |job| {
                            self.notify.notify(job.queue);
                            self.recordNotifiedQueue(job.queue);
                        }
                    }
                    // Replenish the subscription window. A pushed job consumes one
                    // slot; reporting it done (ack OR fail) frees that slot. Use the
                    // count of jobs the worker reported (frame.count), NOT
                    // result.affected — a skipped ack (job already cancelled/terminal/
                    // auto-deleted) and every fail still occupied a window slot, so
                    // counting only accepted transitions leaks the window down to 0
                    // and the worker silently starves. Cap at the original window so
                    // spurious completions can't inflate it.
                    const c = self.io.conn(frame.conn_id);
                    if (c.waiting) {
                        c.prefetch = @min(c.prefetch_window, c.prefetch + frame.count);
                    }
                },
                rpc.MSG_MAINTENANCE => {
                    // Promote/reclaim can make jobs available.
                    if (result.affected > 0) {
                        var reader = BufReader{ .data = frame.payload };
                        const parsed = rpc.management.parseMaintenance(&reader) catch return;
                        switch (parsed.action) {
                            // cron fires jobs → wake workers, same as promote/reclaim.
                            .promote, .reclaim, .cron => {
                                if (result.notify_queues) |queues| {
                                    self.notify.notifyQueues(queues);
                                    for (queues) |q| {
                                        self.recordNotifiedQueue(q);
                                    }
                                }
                            },
                            .expire, .purge, .unique, .rate_limit, .workers, .batches => {},
                        }
                    }
                },
                else => {
                    // For any other op (bulk, queue config, cron, etc.):
                    // if the handler populated notify_queues, honor them.
                    if (result.notify_queues) |queues| {
                        self.notify.notifyQueues(queues);
                        for (queues) |q| {
                            self.recordNotifiedQueue(q);
                        }
                    }
                },
            }
        }

        // ====================================================================
        // Recv buffer compaction
        // ====================================================================

        fn compactRecvBufs(self: *Self) void {
            for (self.recv_compactions[0..self.recv_compaction_count]) |rc| {
                const c = self.io.conn(rc.conn_id);
                if (c.phase == .free) continue;
                compactRecvBuf(c, rc.consumed);
            }
        }

        fn compactRecvBuf(c: *ConnState, consumed: u32) void {
            if (consumed == 0) return;
            const remaining = c.recv_pos - consumed;
            if (remaining > 0) {
                std.mem.copyForwards(u8, c.recv_buf[0..remaining], c.recv_buf[consumed..c.recv_pos]);
            }
            c.recv_pos = @intCast(remaining);
        }

        // ====================================================================
        // Recv re-queue — connections with partial frames need more data
        // ====================================================================

        /// After frame extraction, connections that received data but produced
        /// no complete response (partial frame) need recv re-queued. Connections
        /// with a pending send will get recv re-queued via the send_done path.
        fn requeueRecvs(self: *Self, recv_conns: []const u16) void {
            for (recv_conns) |conn_id| {
                const c = self.io.conn(conn_id);
                if (c.phase == .ready and c.recv_pos < c.recv_buf.len) {
                    self.io.queueRecv(conn_id);
                }
            }
        }

        // ====================================================================
        // Pipelined prepare — flush an acked slot
        // ====================================================================

        /// Flush sends and requeue recvs for an acked prepare slot.
        /// Called at the top of tick() when a follower ack arrives.
        fn flushPrepareSlot(self: *Self, slot: *const PrepareSlot) void {
            for (slot.send_conns[0..slot.send_conn_count]) |conn_id| {
                const c = self.io.conn(conn_id);
                if (c.phase == .free) continue;
                if (c.send_len > 0) {
                    self.io.queueSend(conn_id, c.send_len);
                }
            }
            for (slot.recv_conns[0..slot.recv_conn_count]) |conn_id| {
                const c = self.io.conn(conn_id);
                if (c.phase == .ready and c.recv_pos < c.recv_buf.len) {
                    self.io.queueRecv(conn_id);
                }
            }
        }

        // ====================================================================
        // Helpers
        // ====================================================================

        /// No-op — mirror removed. Kept to avoid touching every callsite.
        fn emitMirrorOp(_: *Self, _: ops_mod.OpType, _: *const ops_mod.OpData, _: *const ops_mod.OpResult) void {}

        fn maybePrintPhaseStats(self: *Self) void {
            if (!enable_phase_timing) return;
            if (self.phase_ticks < 100) return;
            const t = self.phase_ticks;
            std.debug.print(
                \\TICK PHASES ({d} ticks, {d} frames, {d} fulfills):
                \\  drain:    {d}us  extract:  {d}us  maint:   {d}us
                \\  execute:  {d}us  encode:   {d}us  cancel:  {d}us
                \\  webhook:  {d}us  fulfill:  {d}us  flush:   {d}us
                \\  compact:  {d}us  requeue:  {d}us  submit:  {d}us
                \\
            , .{
                t, self.phase_frames, self.phase_fulfills,
                self.phase_drain_ns / (t * 1000), self.phase_extract_ns / (t * 1000), self.phase_maint_ns / (t * 1000),
                self.phase_execute_ns / (t * 1000), self.phase_encode_ns / (t * 1000), self.phase_cancel_ns / (t * 1000),
                self.phase_webhook_ns / (t * 1000), self.phase_fulfill_ns / (t * 1000), self.phase_flush_ns / (t * 1000),
                self.phase_compact_ns / (t * 1000), self.phase_requeue_ns / (t * 1000), self.phase_submit_ns / (t * 1000),
            });
            self.phase_drain_ns = 0;
            self.phase_extract_ns = 0;
            self.phase_execute_ns = 0;
            self.phase_encode_ns = 0;
            self.phase_fulfill_ns = 0;
            self.phase_flush_ns = 0;
            self.phase_compact_ns = 0;
            self.phase_requeue_ns = 0;
            self.phase_submit_ns = 0;
            self.phase_cancel_ns = 0;
            self.phase_webhook_ns = 0;
            self.phase_maint_ns = 0;
            self.phase_ticks = 0;
            self.phase_frames = 0;
            self.phase_fulfills = 0;
        }

        fn nowNs(self: *const Self) u64 {
            const ts = self.config.clock_fn();
            assert.check(ts > 0, "pipeline: clock_fn returned non-positive value: {d}", .{ts});
            return @intCast(ts);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const SimBackend = @import("io/sim.zig").SimBackend;
const talon = @import("talon");

const TestPipeline = Pipeline(SimBackend);

var test_clock_ns: i64 = 1_000_000_000_000; // 1000s

fn testClockFn() i64 {
    return @atomicLoad(i64, &test_clock_ns, .monotonic);
}

fn advanceTestClock(delta_ns: i64) void {
    _ = @atomicRmw(i64, &test_clock_ns, .Add, delta_ns, .monotonic);
}

/// Fake raft host for pipeline tests: hands out real ProposeTokens and lets
/// the test play the raft thread's role (flip state + drop the host ref).
const TestRaft = struct {
    is_leader: bool = true,
    spawned: [64]*ProposeToken = undefined,
    spawned_count: u32 = 0,
    /// Mutation count observed across all proposals (proves recording ran).
    proposed_mutations: u32 = 0,

    fn proposeFn(ptr: *anyopaque, muts: []const kv.Mutation) ?*ProposeToken {
        const self: *TestRaft = @ptrCast(@alignCast(ptr));
        const token = testing.allocator.create(ProposeToken) catch return null;
        token.* = .{ .allocator = testing.allocator };
        self.spawned[self.spawned_count] = token;
        self.spawned_count += 1;
        self.proposed_mutations += @intCast(muts.len);
        return token;
    }

    fn isLeaderFn(ptr: *anyopaque) bool {
        const self: *TestRaft = @ptrCast(@alignCast(ptr));
        return self.is_leader;
    }

    fn iface(self: *TestRaft) RaftIface {
        return .{
            .ptr = @ptrCast(self),
            .propose_fn = &proposeFn,
            .is_leader_fn = &isLeaderFn,
        };
    }

    /// Host-side finish for every unfinished token: store the final state,
    /// then drop the host reference (release doubles as unref).
    fn finishAll(self: *TestRaft, state: TokenState) void {
        for (self.spawned[0..self.spawned_count]) |token| {
            token.state.store(@intFromEnum(state), .release);
            token.release();
        }
        self.spawned_count = 0;
    }
};

const TestContext = struct {
    db: *talon.DB,
    stores: [1]kv.Store,
    handler: OpHandler,
    notify: QueueNotifier,
    backend: SimBackend,
    pipeline: TestPipeline,
    raft: TestRaft,
    db_path: [*:0]const u8,

    /// Heap-allocate and initialize a TestContext. Pipeline + SimBackend are ~7MB,
    /// too large for the test runner's thread stack.
    fn create(db_path: [*:0]const u8) !*TestContext {
        const allocator = testing.allocator;
        const self = try allocator.create(TestContext);
        self.initInPlace(allocator, db_path);
        return self;
    }

    fn initInPlace(self: *TestContext, allocator: std.mem.Allocator, db_path: [*:0]const u8) void {
        @atomicStore(i64, &test_clock_ns, 1_000_000_000_000, .monotonic);

        const path_slice = std.mem.span(db_path);
        std.fs.cwd().deleteTree(path_slice) catch {};
        const db = talon.DB.open(allocator, path_slice, .{ .sync = false }) catch unreachable;

        self.db = db;
        self.stores = [1]kv.Store{kv.Store.init(db)};
        self.handler = OpHandler.init(allocator);
        self.handler.rebuildState(&self.stores);
        self.notify = QueueNotifier.init(allocator);
        // Mirror main.zig's buffer sizing (max_payload_size + frame header +
        // 1024) so the send buffer can hold one max-size job plus framing — the
        // invariant fulfillSubscriptions' one_max_job room check relies on. The
        // TestPipeline uses the default max_payload_size (64 KiB).
        const test_buf_size: u32 = 64 * 1024 + @as(u32, rpc.FRAME_HEADER_SIZE) + 1024;
        self.backend = SimBackend.init(allocator, .{
            .listen_fd = -1,
            .max_conns = 16,
            .recv_buf_size = test_buf_size,
            .send_buf_size = test_buf_size,
        }) catch unreachable;
        self.raft = .{};
        self.db_path = db_path;

        self.pipeline = TestPipeline.init(
            allocator,
            &self.backend,
            &self.handler,
            &self.stores,
            &self.notify,
            null,
            .{ .clock_fn = &testClockFn },
        );
    }

    /// Switch the pipeline into raft mode with this context's TestRaft as
    /// the (already-elected) leader. Skips the acquisition barrier — tests
    /// that exercise acquisition drive raft_state themselves.
    fn enableRaftAsLeader(self: *TestContext) void {
        self.pipeline.config.raft = self.raft.iface();
        self.pipeline.raft_state = .leading;
    }

    fn destroy(self: *TestContext) void {
        const allocator = testing.allocator;
        self.pipeline.deinit();
        self.backend.deinit(allocator);
        self.handler.deinit();
        self.notify.deinit();
        self.db.close();
        const path_slice = std.mem.span(self.db_path);
        std.fs.cwd().deleteTree(path_slice) catch {};
        allocator.destroy(self);
    }

    /// Inject a raw RPC frame into a connection's recv_buf (single recv event).
    fn injectFrame(self: *TestContext, conn_id: u16, msg_type: u8, req_id: u32, payload: []const u8) void {
        // Build complete frame in a staging buffer, then inject as one recv.
        var frame_buf: [65536]u8 = undefined;
        rpc.writeFrameHeader(frame_buf[0..rpc.FRAME_HEADER_SIZE], msg_type, req_id, @intCast(payload.len));
        if (payload.len > 0) {
            @memcpy(frame_buf[rpc.FRAME_HEADER_SIZE..][0..payload.len], payload);
        }
        const total = rpc.FRAME_HEADER_SIZE + payload.len;
        self.backend.injectRecv(conn_id, frame_buf[0..total]);
    }

    /// Read and parse the response frame header from a connection.
    fn readResponseHeader(self: *TestContext, conn_id: u16) ?rpc.FrameHeader {
        const resp = self.backend.readResponse(conn_id) orelse return null;
        return rpc.readFrameHeader(resp);
    }

    /// Read full response: header + payload.
    fn readResponse(self: *TestContext, conn_id: u16) ?struct { header: rpc.FrameHeader, payload: []const u8 } {
        const c = self.backend.conn(conn_id);
        if (c.send_len == 0) return null;
        const data = c.send_buf[0..c.send_len];
        const header = rpc.readFrameHeader(data) orelse return null;
        const payload_start = rpc.FRAME_HEADER_SIZE;
        const payload_end = payload_start + header.payload_len;
        if (payload_end > data.len) return null;
        return .{
            .header = header,
            .payload = data[payload_start..payload_end],
        };
    }

    /// Inject a raw HTTP request into a connection's recv_buf.
    fn injectHttp(self: *TestContext, conn_id: u16, request: []const u8) void {
        self.backend.injectRecv(conn_id, request);
    }

    /// Read the raw HTTP response from a connection's send_buf.
    fn readHttpResponse(self: *TestContext, conn_id: u16) ?[]const u8 {
        const c = self.backend.conn(conn_id);
        if (c.send_len == 0) return null;
        return c.send_buf[0..c.send_len];
    }

    /// Extract the HTTP response body (everything after \r\n\r\n).
    fn httpResponseBody(resp: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i + 3 < resp.len) : (i += 1) {
            if (resp[i] == '\r' and resp[i + 1] == '\n' and resp[i + 2] == '\r' and resp[i + 3] == '\n')
                return resp[i + 4 ..];
        }
        return null;
    }

    /// Check HTTP response starts with expected status line.
    fn httpResponseStatus(resp: []const u8) ?u16 {
        // "HTTP/1.1 200 OK\r\n"
        if (!std.mem.startsWith(u8, resp, "HTTP/1.1 ")) return null;
        return std.fmt.parseInt(u16, resp[9..12], 10) catch null;
    }
};

test "ping/pong round-trip" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-ping");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;
    ctx.injectFrame(conn_id, rpc.MSG_PING, 42, "");

    ctx.pipeline.tick();

    const resp = ctx.readResponse(conn_id).?;
    try testing.expectEqual(rpc.MSG_PONG, resp.header.msg_type);
    try testing.expectEqual(@as(u32, 42), resp.header.req_id);
    try testing.expectEqual(@as(u32, 0), resp.header.payload_len);
}

test "enqueue round-trip" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-enqueue");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Build enqueue payload using BufWriter
    var payload_buf: [512]u8 = undefined;
    var w = BufWriter{ .buf = &payload_buf };
    w.writeU16(1); // count
    w.writePrefixed("test-queue"); // queue
    w.writePrefixed("job-001"); // job_id
    w.writeU8(128); // priority
    w.writeU16(3); // max_retries
    w.writeU8(0); // backoff = none
    w.writeU32(0); // base_delay_ms
    w.writeU32(0); // max_delay_ms
    w.writeU32(0); // unique_period_s
    w.writeU64(0); // scheduled_at_ns
    w.writeU32(0); // expire_after_ms
    w.writeU16(0); // chain_step
    w.writeU16(0); // flags (no optional fields)

    ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 1, w.written());
    ctx.pipeline.tick();

    // Verify response
    const resp = ctx.readResponse(conn_id).?;
    try testing.expectEqual(rpc.MSG_ENQUEUE_BATCH_RESP, resp.header.msg_type);
    try testing.expectEqual(@as(u32, 1), resp.header.req_id);

    // Parse response payload: [count:u16][error:u8]
    var r = BufReader{ .data = resp.payload };
    try testing.expectEqual(@as(u16, 1), try r.readU16()); // count
    try testing.expectEqual(@as(u8, 0), try r.readU8()); // no error

    // Verify job exists in KV
    var key_buf: keys.KeyBuf = undefined;
    const job_key = keys.jobKey(&key_buf, "job-001");
    var verify_batch = ctx.stores[0].newBatch();
    defer verify_batch.close();
    var out_buf: [4096]u8 = undefined;
    try testing.expect(verify_batch.getInto(job_key, &out_buf) != null);
}

test "multiple frames in one tick" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-multi");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Inject two pings
    ctx.injectFrame(conn_id, rpc.MSG_PING, 1, "");
    ctx.injectFrame(conn_id, rpc.MSG_PING, 2, "");

    ctx.pipeline.tick();

    // Both should produce responses — but only one send_buf per connection.
    // The first response is in the send_buf. The second frame should
    // also have been processed (applied_total == 2).
    try testing.expectEqual(@as(u64, 2), ctx.pipeline.applied_total);
}

test "enqueue then fetch round-trip" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-fetch");
    defer ctx.destroy();

    const conn_enqueue = ctx.backend.connect().?;

    // Enqueue a job with payload
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("fetch-queue");
    ew.writePrefixed("fetch-job-1");
    ew.writeU8(128);
    ew.writeU16(0);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(rpc.FLAG_PAYLOAD);
    ew.writeU16Prefixed("hello payload");

    ctx.injectFrame(conn_enqueue, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
    ctx.pipeline.tick();

    // Consume the send_done so we can reuse the connection
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fetch on a different connection
    const conn_fetch = ctx.backend.connect().?;

    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1); // credits
    fw.writeU32(30000); // lease_ms
    fw.writePrefixed("worker-1"); // worker_id
    fw.writeU8(1); // queue_count
    fw.writePrefixed("fetch-queue");

    ctx.injectFrame(conn_fetch, rpc.MSG_FETCH_BATCH, 2, fw.written());
    ctx.pipeline.tick();

    // Verify fetch response
    const resp = ctx.readResponse(conn_fetch).?;
    try testing.expectEqual(rpc.MSG_FETCH_BATCH_RESP, resp.header.msg_type);

    var r = BufReader{ .data = resp.payload };
    const fetched_count = try r.readU16();
    try testing.expectEqual(@as(u16, 1), fetched_count);

    const job_id = try r.readPrefixed();
    try testing.expectEqualStrings("fetch-job-1", job_id);
}

test "fetch-result payload length is u32 (round-trips 64 KiB and 256 KiB)" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-fetch-u32-payload");
    defer ctx.destroy();

    const allocator = testing.allocator;

    // 65536 is what a u16 length silently zeroed (65536 & 0xFFFF == 0) and
    // 256 KiB is what @intCast to u16 panicked on — both must now round-trip.
    const sizes = [_]usize{ 65536, 256 * 1024 };
    inline for (sizes) |plen| {
        const job_id = "u32-payload-job";
        const queue = "u32-payload-queue";

        // Store the payload under the job's payload key so encodeFetchResult
        // reads it back through the KV exactly like the real push path.
        const payload = try allocator.alloc(u8, plen);
        defer allocator.free(payload);
        for (payload, 0..) |*byte, idx| byte.* = @truncate(idx);
        {
            var jpk_buf: keys.KeyBuf = undefined;
            var b = ctx.stores[0].newBatch();
            b.set(keys.jobPayloadKey(&jpk_buf, job_id), payload);
            b.commit();
            b.close();
        }

        // One-job fetch result feeding the encoder.
        var result: ops_mod.OpResult = .{};
        result.affected = 1;
        const fetched = &result.fetched[0];
        @memcpy(fetched.id_buf[0..job_id.len], job_id);
        fetched.id_len = @intCast(job_id.len);
        @memcpy(fetched.queue_buf[0..queue.len], queue);
        fetched.queue_len = @intCast(queue.len);
        fetched.attempt = 2;
        fetched.max_retries = 5;
        fetched.lease_token = 0x00AB_CD12_3456_789A;

        // Encode on the heap (256 KiB overflows the test thread stack).
        const enc_buf = try allocator.alloc(u8, plen + 128);
        defer allocator.free(enc_buf);
        var w = BufWriter{ .buf = enc_buf };
        ctx.pipeline.encodeFetchResult(&w, &result);

        // Decode exactly as the bench/sim/SDK decoders do and verify.
        var r = BufReader{ .data = w.written() };
        try testing.expectEqual(@as(u16, 1), try r.readU16()); // count
        try testing.expectEqualStrings(job_id, try r.readPrefixed());
        try testing.expectEqualStrings(queue, try r.readPrefixed());
        try testing.expectEqual(@as(u16, 2), try r.readU16()); // attempt
        try testing.expectEqual(@as(u16, 5), try r.readU16()); // max_retries
        try testing.expectEqual(@as(u8, 0), try r.readU8()); // checkpoint len
        try testing.expectEqual(@as(u8, 0), try r.readU8()); // tags len
        const got_len = try r.readU32(); // payload length (now u32)
        try testing.expectEqual(@as(u32, @intCast(plen)), got_len);
        const got_payload = r.data[r.pos..][0..got_len];
        try r.skip(got_len);
        try testing.expect(std.mem.eql(u8, payload, got_payload));
        try testing.expectEqual(@as(u64, 0x00AB_CD12_3456_789A), try r.readU64());
    }
}

test "partial frame waits for more data" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-partial");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    var header_buf: [rpc.FRAME_HEADER_SIZE]u8 = undefined;
    rpc.writeFrameHeader(&header_buf, rpc.MSG_PING, 99, 0);

    // Split: inject only first 5 bytes (incomplete header)
    ctx.backend.injectRecv(conn_id, header_buf[0..5]);
    ctx.pipeline.tick();

    try testing.expectEqual(@as(u64, 0), ctx.pipeline.applied_total);

    // Inject remaining bytes
    ctx.backend.injectRecv(conn_id, header_buf[5..]);
    ctx.pipeline.tick();

    try testing.expectEqual(@as(u64, 1), ctx.pipeline.applied_total);
}

test "recv_buf compaction preserves unconsumed data" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-compact");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Inject a complete ping frame + partial next frame header
    var header_buf: [rpc.FRAME_HEADER_SIZE]u8 = undefined;
    rpc.writeFrameHeader(&header_buf, rpc.MSG_PING, 1, 0);
    ctx.backend.injectRecv(conn_id, &header_buf);

    // Partial header of next frame (3 bytes)
    ctx.backend.injectRecv(conn_id, &[_]u8{ rpc.MSG_PING, 0x02, 0x00 });

    ctx.pipeline.tick();

    // First ping processed
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.applied_total);

    // The 3 bytes of partial frame should still be in recv_buf
    const c = ctx.backend.conn(conn_id);
    try testing.expectEqual(@as(u32, 3), c.recv_pos);
    try testing.expectEqual(rpc.MSG_PING, c.recv_buf[0]);
}

// ============================================================================
// HTTP Integration Tests
// ============================================================================

test "HTTP GET /api/v1/info returns version" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-http-info");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;
    ctx.injectHttp(conn_id, "GET /api/v1/info HTTP/1.1\r\nHost: localhost\r\n\r\n");
    ctx.pipeline.tick();

    const resp = ctx.readHttpResponse(conn_id).?;
    try testing.expectEqual(@as(u16, 200), TestContext.httpResponseStatus(resp).?);
    const body = TestContext.httpResponseBody(resp).?;
    try testing.expect(std.mem.indexOf(u8, body, "\"version\"") != null);
    // Read bypasses batch — applied_total should be 0.
    try testing.expectEqual(@as(u64, 0), ctx.pipeline.applied_total);
}

test "HTTP GET unknown route returns 404" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-http-404");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;
    ctx.injectHttp(conn_id, "GET /nonexistent HTTP/1.1\r\nHost: localhost\r\n\r\n");
    ctx.pipeline.tick();

    const resp = ctx.readHttpResponse(conn_id).?;
    try testing.expectEqual(@as(u16, 404), TestContext.httpResponseStatus(resp).?);
}

test "HTTP POST /api/v1/enqueue creates job" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-http-enq");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;
    const body = "{\"queue\":\"default\",\"priority\":5}";
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf,
        "POST /api/v1/enqueue HTTP/1.1\r\nContent-Length: {d}\r\nHost: localhost\r\n\r\n{s}",
        .{ body.len, body },
    ) catch unreachable;

    ctx.injectHttp(conn_id, req);
    ctx.pipeline.tick();

    const resp = ctx.readHttpResponse(conn_id).?;
    try testing.expectEqual(@as(u16, 201), TestContext.httpResponseStatus(resp).?);
    const resp_body = TestContext.httpResponseBody(resp).?;
    // Response should contain a generated job_id.
    try testing.expect(std.mem.indexOf(u8, resp_body, "\"id\":\"job_") != null);
    // Batch was used.
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.applied_total);
}

test "HTTP protocol detection — same pipeline handles both" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-http-mixed");
    defer ctx.destroy();

    // RPC connection: ping
    const rpc_conn = ctx.backend.connect().?;
    ctx.injectFrame(rpc_conn, rpc.MSG_PING, 1, "");

    // HTTP connection: GET info
    const http_conn = ctx.backend.connect().?;
    ctx.injectHttp(http_conn, "GET /api/v1/info HTTP/1.1\r\nHost: localhost\r\n\r\n");

    ctx.pipeline.tick();

    // RPC conn should have pong
    const rpc_resp = ctx.readResponseHeader(rpc_conn).?;
    try testing.expectEqual(rpc.MSG_PONG, rpc_resp.msg_type);

    // HTTP conn should have 200 JSON
    const http_resp = ctx.readHttpResponse(http_conn).?;
    try testing.expectEqual(@as(u16, 200), TestContext.httpResponseStatus(http_resp).?);

    // Protocol detection should be sticky
    const rpc_c = ctx.backend.conn(rpc_conn);
    try testing.expectEqual(ConnState.Protocol.rpc, rpc_c.protocol);
    const http_c = ctx.backend.conn(http_conn);
    try testing.expectEqual(ConnState.Protocol.http, http_c.protocol);
}

test "HTTP incomplete request waits for more data" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-http-partial");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;
    // Send partial headers (no \r\n\r\n terminator yet).
    ctx.injectHttp(conn_id, "GET /api/v1/info HTTP/1.1\r\nHost: local");
    ctx.pipeline.tick();

    // No response yet.
    try testing.expect(ctx.readHttpResponse(conn_id) == null);
    try testing.expectEqual(@as(u64, 0), ctx.pipeline.applied_total);
}

// ============================================================================
// Fetch Subscription Tests
// ============================================================================

test "fetch with no jobs stores subscription (no response)" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-fetch-sub");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Fetch on empty queue — should subscribe, not respond.
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1); // credits
    fw.writeU32(30000); // lease_ms
    fw.writePrefixed("worker-1"); // worker_id
    fw.writeU8(1); // queue_count
    fw.writePrefixed("empty-queue");

    ctx.injectFrame(conn_id, rpc.MSG_FETCH_BATCH, 10, fw.written());
    ctx.pipeline.tick();

    // No response — connection is subscribed.
    try testing.expect(ctx.readResponseHeader(conn_id) == null);

    // ConnState should be marked as waiting.
    const c = ctx.backend.conn(conn_id);
    try testing.expect(c.waiting);
    try testing.expectEqual(@as(u8, 1), c.queue_count);
    try testing.expectEqualStrings("empty-queue", c.queue_bufs[0][0..c.queue_lens[0]]);
    try testing.expectEqual(@as(u32, 1), c.prefetch);
    try testing.expectEqual(@as(u32, 10), c.last_req_id);

    // Pipeline should track the waiting connection.
    try testing.expectEqual(@as(u32, 1), ctx.pipeline.waiting_conn_count);
}

test "enqueue fulfills waiting fetch subscription" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-fetch-push");
    defer ctx.destroy();

    const fetch_conn = ctx.backend.connect().?;
    const enq_conn = ctx.backend.connect().?;

    // 1. Fetch on empty queue — subscribes.
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("push-queue");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 5, fw.written());
    ctx.pipeline.tick();

    try testing.expect(ctx.readResponseHeader(fetch_conn) == null);
    try testing.expect(ctx.backend.conn(fetch_conn).waiting);

    // Drain send_done so enqueue conn can be used.
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // 2. Enqueue a job to the subscribed queue.
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("push-queue");
    ew.writePrefixed("pushed-job-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0); // flags

    ctx.injectFrame(enq_conn, rpc.MSG_ENQUEUE_BATCH, 6, ew.written());
    ctx.pipeline.tick();

    // Enqueue conn should have its response.
    const enq_resp = ctx.readResponseHeader(enq_conn).?;
    try testing.expectEqual(rpc.MSG_ENQUEUE_BATCH_RESP, enq_resp.msg_type);

    // Fetch conn should have received a pushed MSG_FETCH_BATCH_RESP.
    const fetch_c = ctx.backend.conn(fetch_conn);
    try testing.expect(fetch_c.send_len > 0);
    const fetch_resp_data = fetch_c.send_buf[0..fetch_c.send_len];
    const fetch_hdr = rpc.readFrameHeader(fetch_resp_data).?;
    try testing.expectEqual(rpc.MSG_FETCH_BATCH_RESP, fetch_hdr.msg_type);
    try testing.expectEqual(@as(u32, 5), fetch_hdr.req_id); // matches original fetch req_id

    // Parse the pushed fetch response.
    const payload = fetch_resp_data[rpc.FRAME_HEADER_SIZE .. rpc.FRAME_HEADER_SIZE + fetch_hdr.payload_len];
    var r = BufReader{ .data = payload };
    const count = try r.readU16();
    try testing.expectEqual(@as(u16, 1), count);
    const job_id = try r.readPrefixed();
    try testing.expectEqualStrings("pushed-job-1", job_id);

    // Subscription stays active (permanent), but prefetch exhausted.
    try testing.expect(fetch_c.waiting);
    try testing.expectEqual(@as(u32, 0), fetch_c.prefetch);
    try testing.expectEqual(@as(u32, 1), ctx.pipeline.waiting_conn_count);
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.subscriptions_fulfilled);
}

test "ack replenishes prefetch and triggers second push" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-ack-replenish");
    defer ctx.destroy();

    const fetch_conn = ctx.backend.connect().?;
    const enq_conn = ctx.backend.connect().?;

    // 1. Subscribe with prefetch=1.
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1); // prefetch
    fw.writeU32(30000);
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("replenish-queue");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 5, fw.written());
    ctx.pipeline.tick();

    // Drain send_done.
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // 2. Enqueue job-1 → should push to subscriber.
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("replenish-queue");
    ew.writePrefixed("job-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(enq_conn, rpc.MSG_ENQUEUE_BATCH, 6, ew.written());
    ctx.pipeline.tick();

    // Verify: pushed job-1, prefetch=0.
    const fetch_c = ctx.backend.conn(fetch_conn);
    try testing.expect(fetch_c.send_len > 0);
    try testing.expectEqual(@as(u32, 0), fetch_c.prefetch);
    try testing.expect(fetch_c.waiting);

    // Drain sends.
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // 3. Ack job-1 → should replenish prefetch to 1.
    var ack_buf: [256]u8 = undefined;
    var aw = BufWriter{ .buf = &ack_buf };
    aw.writeU16(1); // count
    aw.writePrefixed("job-1"); // job_id
    aw.writePrefixed("replenish-queue"); // queue
    aw.writeU8(0); // ack_status (done)
    aw.writeU8(0); // flags

    ctx.injectFrame(fetch_conn, rpc.MSG_ACK_BATCH, 7, aw.written());
    ctx.pipeline.tick();

    // Verify: prefetch replenished.
    try testing.expectEqual(@as(u32, 1), fetch_c.prefetch);

    // Drain sends.
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // 4. Enqueue job-2 → should push again (prefetch=1).
    ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("replenish-queue");
    ew.writePrefixed("job-2");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(enq_conn, rpc.MSG_ENQUEUE_BATCH, 8, ew.written());
    ctx.pipeline.tick();

    // Should have pushed job-2.
    try testing.expectEqual(@as(u64, 2), ctx.pipeline.subscriptions_fulfilled);
    try testing.expectEqual(@as(u32, 0), fetch_c.prefetch);
}

test "fetch subscription not fulfilled for unrelated queue" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-fetch-nomatch");
    defer ctx.destroy();

    const fetch_conn = ctx.backend.connect().?;
    const enq_conn = ctx.backend.connect().?;

    // Subscribe to "queue-a".
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("queue-a");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 1, fw.written());
    ctx.pipeline.tick();
    try testing.expect(ctx.backend.conn(fetch_conn).waiting);

    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Enqueue to "queue-b" — should NOT fulfill the subscription.
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("queue-b");
    ew.writePrefixed("unrelated-job");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(enq_conn, rpc.MSG_ENQUEUE_BATCH, 2, ew.written());
    ctx.pipeline.tick();

    // Fetch conn should still be waiting — no push.
    try testing.expect(ctx.backend.conn(fetch_conn).waiting);
    try testing.expectEqual(@as(u32, 1), ctx.pipeline.waiting_conn_count);
    try testing.expectEqual(@as(u64, 0), ctx.pipeline.subscriptions_fulfilled);
}

test "subscription cleared on disconnect" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-fetch-disc");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Subscribe.
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("disc-queue");

    ctx.injectFrame(conn_id, rpc.MSG_FETCH_BATCH, 1, fw.written());
    ctx.pipeline.tick();
    try testing.expectEqual(@as(u32, 1), ctx.pipeline.waiting_conn_count);

    // Disconnect.
    ctx.backend.disconnect(conn_id);
    ctx.pipeline.tick();

    // Waiting list should be cleaned up.
    try testing.expectEqual(@as(u32, 0), ctx.pipeline.waiting_conn_count);
}

// ============================================================================
// Maintenance Scheduling Tests
// ============================================================================

test "maintenance scheduling" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-maint");
    defer ctx.destroy();

    // --- Idle tick fires maintenance ---
    ctx.pipeline.config.promote_interval_ns = 1_000_000_000;
    ctx.pipeline.tick();
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.maintenance_runs);
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.applied_total);

    // --- Same clock → doesn't fire again ---
    ctx.pipeline.tick();
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.maintenance_runs);

    // --- Advance clock past interval → fires again ---
    advanceTestClock(2_000_000_000);
    ctx.pipeline.tick();
    try testing.expectEqual(@as(u64, 2), ctx.pipeline.maintenance_runs);
    try testing.expectEqual(@as(u64, 2), ctx.pipeline.applied_total);

    // --- All 6 actions fire in one tick ---
    ctx.pipeline.config.reclaim_interval_ns = 1_000_000_000;
    ctx.pipeline.config.unique_interval_ns = 1_000_000_000;
    ctx.pipeline.config.rate_limit_interval_ns = 1_000_000_000;
    ctx.pipeline.config.expire_interval_ns = 1_000_000_000;
    ctx.pipeline.config.purge_interval_ns = 1_000_000_000;
    advanceTestClock(2_000_000_000);
    ctx.pipeline.tick();
    // promote + 5 new actions = 6 in this tick, 8 total
    try testing.expectEqual(@as(u64, 8), ctx.pipeline.maintenance_runs);

    // --- Coexists with client frames ---
    advanceTestClock(2_000_000_000);
    const conn_id = ctx.backend.connect().?;
    ctx.injectFrame(conn_id, rpc.MSG_PING, 1, "");
    ctx.pipeline.tick();
    // Pong response arrives despite maintenance.
    const resp = ctx.readResponseHeader(conn_id).?;
    try testing.expectEqual(rpc.MSG_PONG, resp.msg_type);
    try testing.expect(ctx.pipeline.maintenance_runs > 8);
}

test "rpc auth: gate blocks unauthenticated, handshake accepts/rejects" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-rpc-auth");
    defer ctx.destroy();
    ctx.pipeline.config.admin_password = "s3cr3t";

    // Unauthenticated PING is gated → connection closed, no PONG.
    {
        const conn = ctx.backend.connect().?;
        ctx.injectFrame(conn, rpc.MSG_PING, 1, "");
        ctx.pipeline.tick();
        try testing.expect(ctx.readResponseHeader(conn) == null);
    }

    // Correct credential → MSG_AUTH_RESP with status ok (0) and admin role (0).
    {
        const conn = ctx.backend.connect().?;
        var abuf: [64]u8 = undefined;
        var aw = BufWriter{ .buf = &abuf };
        aw.writePrefixed("s3cr3t");
        ctx.injectFrame(conn, rpc.MSG_AUTH, 2, aw.written());
        ctx.pipeline.tick();
        const resp = ctx.readResponse(conn).?;
        try testing.expectEqual(rpc.MSG_AUTH_RESP, resp.header.msg_type);
        try testing.expectEqual(@as(u8, 0), resp.payload[0]); // status ok
        try testing.expect(ctx.backend.conn(conn).rpc_authenticated);
    }

    // Wrong credential → MSG_AUTH_RESP status fail (1), connection stays unauthenticated.
    {
        const conn = ctx.backend.connect().?;
        var abuf: [64]u8 = undefined;
        var aw = BufWriter{ .buf = &abuf };
        aw.writePrefixed("wrong-pass");
        ctx.injectFrame(conn, rpc.MSG_AUTH, 3, aw.written());
        ctx.pipeline.tick();
        const resp = ctx.readResponse(conn).?;
        try testing.expectEqual(rpc.MSG_AUTH_RESP, resp.header.msg_type);
        try testing.expectEqual(@as(u8, 1), resp.payload[0]); // status fail
        try testing.expect(!ctx.backend.conn(conn).rpc_authenticated);
    }
}

test "cron scheduler fires a due cron and enqueues its job" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-cron-fire");
    defer ctx.destroy();

    const now: u64 = 1_700_000_000_000_000_000; // fixed base ns

    // Create an every-minute cron with no client-supplied next_run_ns — the
    // handler must compute it from the schedule.
    {
        var b = ctx.stores[0].newBatch();
        defer b.close();
        const op_data = ops_mod.OpData{ .cron_create = .{
            .cron_id = "cron-1",
            .name = "test-cron",
            .queue = "cron-queue",
            .schedule = "* * * * *",
            .enabled = true,
            .created_at_ns = now,
        } };
        const res = ctx.handler.apply(&b, .cron_create, &op_data);
        try testing.expect(res.err == null);
        b.commit();
    }

    // Scan two minutes later — the cron is due and should fire once.
    {
        var b = ctx.stores[0].newBatch();
        defer b.close();
        const later = now + 2 * 60 * 1_000_000_000;
        const op_data = ops_mod.OpData{ .maintenance = .{ .action = .cron, .now_ns = later } };
        const res = ctx.handler.apply(&b, .maintenance, &op_data);
        b.commit();
        try testing.expectEqual(@as(u32, 1), res.affected);
    }

    // The fired job is now pending in the cron's queue.
    try testing.expect(ctx.handler.pending.queueCount("cron-queue") >= 1);
}

test "maintenance promote wakes fetch subscription" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-maint-wake");
    defer ctx.destroy();

    // Enqueue a scheduled job (500ms in the future).
    const enq_conn = ctx.backend.connect().?;
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("sched-queue");
    ew.writePrefixed("sched-job-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0); // backoff
    ew.writeU32(0); // base_delay
    ew.writeU32(0); // max_delay
    ew.writeU32(0); // unique_period
    ew.writeU64(@intCast(@as(i64, @atomicLoad(i64, &test_clock_ns, .monotonic)) + 500_000_000)); // scheduled_at_ns
    ew.writeU32(0); // expire_after
    ew.writeU16(0); // chain_step
    ew.writeU16(0); // flags

    ctx.injectFrame(enq_conn, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
    ctx.pipeline.tick();

    // Drain send_done.
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fetch — job is scheduled (not pending), so 0 jobs → subscription stored.
    const fetch_conn = ctx.backend.connect().?;
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1); // credits
    fw.writeU32(30000); // lease_ms
    fw.writePrefixed("worker-1");
    fw.writeU8(1); // queue_count
    fw.writePrefixed("sched-queue");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 5, fw.written());
    ctx.pipeline.tick();
    try testing.expect(ctx.backend.conn(fetch_conn).waiting);

    // Advance clock past scheduled time + enable promote.
    advanceTestClock(2_000_000_000); // +2s (past 500ms schedule)
    ctx.pipeline.config.promote_interval_ns = 1_000_000_000;
    ctx.pipeline.tick();

    // Promote should have fired and found the scheduled job.
    try testing.expect(ctx.pipeline.maintenance_runs >= 1);
    // Job should now be pending — fetch subscription fulfilled, but subscription stays active.
    try testing.expect(ctx.backend.conn(fetch_conn).waiting);
    try testing.expectEqual(@as(u32, 0), ctx.backend.conn(fetch_conn).prefetch);
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.subscriptions_fulfilled);
}

test "raft pipelined prepares — enqueue deferred until token commits" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-raft-pipeline");
    defer ctx.destroy();
    ctx.enableRaftAsLeader();

    const enq_conn = ctx.backend.connect().?;
    const fetch_conn = ctx.backend.connect().?;

    // 1. Enqueue a job — response encoded but deferred in prepare slot.
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("sync-queue");
    ew.writePrefixed("sync-job-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(enq_conn, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
    ctx.pipeline.tick();

    try testing.expectEqual(@as(u32, 1), ctx.pipeline.prepare_count);
    // Response encoded in send_buf but send not queued.
    try testing.expect(ctx.backend.conn(enq_conn).send_len > 0);

    // 2. Fetch arrives — subscribe-only, no mutations, flush immediately.
    //    Job is committed to KV from step 1, so fulfillSubscriptions finds it.
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("sync-queue");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 5, fw.written());
    ctx.pipeline.tick();

    // Fetch fulfilled: the push is claimed + proposed. Enqueue still deferred.
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.subscriptions_fulfilled);
    try testing.expect(ctx.pipeline.prepare_count >= 1);

    // 3. Commit all proposals (host side) — flush prepare slots.
    ctx.raft.finishAll(.committed);
    ctx.pipeline.tick();

    try testing.expectEqual(@as(u32, 0), ctx.pipeline.prepare_count);
    try testing.expectEqual(@as(u32, 0), ctx.pipeline.maint_token_count);

    // Enqueue response sent after commit.
    const enq_resp = ctx.readResponse(enq_conn).?;
    try testing.expectEqual(rpc.MSG_ENQUEUE_BATCH_RESP, enq_resp.header.msg_type);
    try testing.expectEqual(@as(u32, 1), enq_resp.header.req_id);
}

test "raft pipelined prepares — multiple batches in flight" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-raft-multi-slot");
    defer ctx.destroy();
    ctx.enableRaftAsLeader();

    const conn1 = ctx.backend.connect().?;
    const conn2 = ctx.backend.connect().?;

    // 1. Enqueue job-1 — deferred in slot 0.
    var enq1_buf: [512]u8 = undefined;
    var ew1 = BufWriter{ .buf = &enq1_buf };
    ew1.writeU16(1);
    ew1.writePrefixed("pipe-queue");
    ew1.writePrefixed("pipe-job-1");
    ew1.writeU8(128);
    ew1.writeU16(3);
    ew1.writeU8(0);
    ew1.writeU32(0);
    ew1.writeU32(0);
    ew1.writeU32(0);
    ew1.writeU64(0);
    ew1.writeU32(0);
    ew1.writeU16(0);
    ew1.writeU16(0);

    ctx.injectFrame(conn1, rpc.MSG_ENQUEUE_BATCH, 1, ew1.written());
    ctx.pipeline.tick();

    try testing.expectEqual(@as(u32, 1), ctx.pipeline.prepare_count);
    try testing.expectEqual(@as(u32, 1), ctx.pipeline.prepare_slots[0].token_count);

    // 2. Enqueue job-2 — deferred in slot 1.
    var enq2_buf: [512]u8 = undefined;
    var ew2 = BufWriter{ .buf = &enq2_buf };
    ew2.writeU16(1);
    ew2.writePrefixed("pipe-queue");
    ew2.writePrefixed("pipe-job-2");
    ew2.writeU8(128);
    ew2.writeU16(3);
    ew2.writeU8(0);
    ew2.writeU32(0);
    ew2.writeU32(0);
    ew2.writeU32(0);
    ew2.writeU64(0);
    ew2.writeU32(0);
    ew2.writeU16(0);
    ew2.writeU16(0);

    ctx.injectFrame(conn2, rpc.MSG_ENQUEUE_BATCH, 2, ew2.written());
    ctx.pipeline.tick();

    try testing.expectEqual(@as(u32, 2), ctx.pipeline.prepare_count);
    try testing.expectEqual(@as(u32, 2), ctx.raft.spawned_count);

    // 3. Commit all — both slots flushed in one tick.
    ctx.raft.finishAll(.committed);
    ctx.pipeline.tick();

    try testing.expectEqual(@as(u32, 0), ctx.pipeline.prepare_count);

    // Both responses available.
    const resp1 = ctx.readResponse(conn1).?;
    try testing.expectEqual(rpc.MSG_ENQUEUE_BATCH_RESP, resp1.header.msg_type);
    try testing.expectEqual(@as(u32, 1), resp1.header.req_id);

    const resp2 = ctx.readResponse(conn2).?;
    try testing.expectEqual(rpc.MSG_ENQUEUE_BATCH_RESP, resp2.header.msg_type);
    try testing.expectEqual(@as(u32, 2), resp2.header.req_id);
}

test "raft rejects an over-cap amplifying enqueue; single-node accepts it (Bug B)" {
    const allocator = testing.allocator;

    // One enqueue frame whose RECORDED mutations amplify far past its ~48 KiB
    // wire size: many jobs, each with a 64-byte queue, a distinct id, and a
    // 255-byte tag string. Every tag repeats queue+id in a tq| index key, so
    // the mutations blow past a raft entry's cap while the wire frame stays
    // under max_payload_size. proposeRecordedFrames cannot split a frame across
    // entries, so without the boundary check this would panic the leader on
    // commit (the old confirmed bug). The SAME frame must apply fine on a
    // single node, where there is no entry cap.
    const job_count: u16 = 130;
    const queue = "q" ** 64;
    const tags = "t" ** 255;

    const payload = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(payload);
    var w = BufWriter{ .buf = payload };
    w.writeU16(job_count);
    var idx: u16 = 0;
    while (idx < job_count) : (idx += 1) {
        var id_buf: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&id_buf, "amp-job-{d:0>5}", .{idx}) catch unreachable;
        w.writePrefixed(queue);
        w.writePrefixed(id);
        w.writeU8(128); // priority
        w.writeU16(0); // max_retries
        w.writeU8(0); // backoff = none
        w.writeU32(0); // base_delay_ms
        w.writeU32(0); // max_delay_ms
        w.writeU32(0); // unique_period_s
        w.writeU64(0); // scheduled_at_ns
        w.writeU32(0); // expire_after_ms
        w.writeU16(0); // chain_step
        w.writeU16(rpc.FLAG_TAGS);
        w.writePrefixed(tags);
    }
    const frame_payload = w.written();
    // Sanity: the wire frame is legal (under the default 64 KiB payload cap),
    // so the rejection is purely about the amplified replication size.
    try testing.expect(frame_payload.len < 64 * 1024);

    // --- Cluster mode: rejected at the boundary, nothing proposed or written. ---
    {
        const ctx = try TestContext.create("/tmp/corvo-pv2-bugb-cluster");
        defer ctx.destroy();
        ctx.enableRaftAsLeader();

        const conn = ctx.backend.connect().?;
        ctx.injectFrame(conn, rpc.MSG_ENQUEUE_BATCH, 1, frame_payload);
        ctx.pipeline.tick();

        // Rejected before handler.apply: no mutations recorded → no proposal,
        // no prepare slot, no panic.
        try testing.expectEqual(@as(u32, 0), ctx.raft.spawned_count);
        try testing.expectEqual(@as(u32, 0), ctx.pipeline.prepare_count);

        // Response carries the enqueue error flag: [count:u16][err:u8].
        const resp = ctx.readResponse(conn).?;
        try testing.expectEqual(rpc.MSG_ENQUEUE_BATCH_RESP, resp.header.msg_type);
        try testing.expectEqual(@as(u8, 1), resp.payload[2]);

        // Nothing reached the KV.
        var vb = ctx.stores[0].newBatch();
        defer vb.close();
        var key_buf: keys.KeyBuf = undefined;
        var job_buf: [4096]u8 = undefined;
        try testing.expect(vb.getInto(keys.jobKey(&key_buf, "amp-job-00000"), &job_buf) == null);
    }

    // --- Single-node mode: the SAME batch is accepted (no entry cap). ---
    {
        const ctx = try TestContext.create("/tmp/corvo-pv2-bugb-single");
        defer ctx.destroy();

        const conn = ctx.backend.connect().?;
        ctx.injectFrame(conn, rpc.MSG_ENQUEUE_BATCH, 1, frame_payload);
        ctx.pipeline.tick();

        const resp = ctx.readResponse(conn).?;
        try testing.expectEqual(rpc.MSG_ENQUEUE_BATCH_RESP, resp.header.msg_type);
        try testing.expectEqual(@as(u8, 0), resp.payload[2]); // no error

        var vb = ctx.stores[0].newBatch();
        defer vb.close();
        var key_buf: keys.KeyBuf = undefined;
        var job_buf: [4096]u8 = undefined;
        try testing.expect(vb.getInto(keys.jobKey(&key_buf, "amp-job-00000"), &job_buf) != null);
    }
}

// ============================================================================
// Handler Guard Condition Tests
// ============================================================================

test "ack with wrong lease_token is rejected" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-lease-reject");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Enqueue a job via RPC
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("lease-q");
    ew.writePrefixed("lease-job-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fetch via RPC (subscribe then fulfilled immediately since job exists)
    const fetch_conn = ctx.backend.connect().?;
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1); // prefetch
    fw.writeU32(2000); // lease_ms = 2s
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("lease-q");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 1, fw.written());
    ctx.pipeline.tick();

    // Subscription should be fulfilled immediately (job already pending)
    const fetch_c = ctx.backend.conn(fetch_conn);
    try testing.expect(fetch_c.send_len > 0);

    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Verify job is now active with lease_token=1
    var key_buf: keys.KeyBuf = undefined;
    var vb = ctx.stores[0].newBatch();
    var job_buf: [4096]u8 = undefined;
    var job_bytes = vb.getInto(keys.jobKey(&key_buf, "lease-job-1"), &job_buf);
    try testing.expect(job_bytes != null);
    var job = codec.decodeJob(job_bytes.?);
    try testing.expectEqual(types.JobState.active, job.state);
    const first_token = job.lease_token;
    try testing.expect(first_token > 0);
    vb.close();

    // Advance clock past lease expiry (2s) and trigger reclaim
    advanceTestClock(3_000_000_000);
    ctx.pipeline.config.reclaim_interval_ns = 1_000_000_000;
    ctx.pipeline.tick(); // auto-maintenance reclaims the job
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fetch again on a different connection — gets new lease_token
    const fetch_conn2 = ctx.backend.connect().?;
    fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-2");
    fw.writeU8(1);
    fw.writePrefixed("lease-q");

    ctx.injectFrame(fetch_conn2, rpc.MSG_FETCH_BATCH, 2, fw.written());
    ctx.pipeline.tick();

    const fetch_c2 = ctx.backend.conn(fetch_conn2);
    try testing.expect(fetch_c2.send_len > 0); // re-fetched
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Verify job has a new (different) lease_token
    var vb2 = ctx.stores[0].newBatch();
    job_bytes = vb2.getInto(keys.jobKey(&key_buf, "lease-job-1"), &job_buf);
    try testing.expect(job_bytes != null);
    job = codec.decodeJob(job_bytes.?);
    try testing.expectEqual(types.JobState.active, job.state);
    try testing.expect(job.lease_token != first_token); // new token
    vb2.close();

    // Now try to ack with wrong lease_token via HTTP
    const ack_conn = ctx.backend.connect().?;
    const ack_body = "{\"job_id\":\"lease-job-1\",\"queue\":\"lease-q\",\"lease_token\":1}";
    var http_buf: [512]u8 = undefined;
    var http_w = BufWriter{ .buf = &http_buf };
    http_w.writeBytes("POST /api/v1/ack HTTP/1.1\r\nHost: localhost\r\nContent-Length: ");
    http_w.writeBytes(std.fmt.comptimePrint("{d}", .{ack_body.len}));
    http_w.writeBytes("\r\n\r\n");
    http_w.writeBytes(ack_body);
    ctx.backend.injectRecv(ack_conn, http_w.written());
    ctx.pipeline.tick();

    // Job should still be active (stale ack rejected)
    var vb3 = ctx.stores[0].newBatch();
    defer vb3.close();
    job_bytes = vb3.getInto(keys.jobKey(&key_buf, "lease-job-1"), &job_buf);
    try testing.expect(job_bytes != null);
    job = codec.decodeJob(job_bytes.?);
    try testing.expectEqual(types.JobState.active, job.state);
}

test "ack non-active job is no-op" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-ack-nonactive");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Enqueue a job
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("noack-q");
    ew.writePrefixed("noack-job-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Try to ack it while it's still pending (never fetched)
    var ack_buf: [256]u8 = undefined;
    var aw = BufWriter{ .buf = &ack_buf };
    aw.writeU16(1);
    aw.writePrefixed("noack-job-1");
    aw.writePrefixed("noack-q");
    aw.writeU8(0); // ack_status = done
    aw.writeU8(0); // flags

    ctx.injectFrame(conn_id, rpc.MSG_ACK_BATCH, 2, aw.written());
    ctx.pipeline.tick();

    // Job should still be pending
    var key_buf: keys.KeyBuf = undefined;
    var verify_batch = ctx.stores[0].newBatch();
    defer verify_batch.close();
    var job_buf: [4096]u8 = undefined;
    const job_bytes = verify_batch.getInto(keys.jobKey(&key_buf, "noack-job-1"), &job_buf);
    try testing.expect(job_bytes != null);
    const job = codec.decodeJob(job_bytes.?);
    try testing.expectEqual(types.JobState.pending, job.state);
}

test "ack nonexistent job is no-op" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-ack-noexist");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Ack a job that doesn't exist
    var ack_buf: [256]u8 = undefined;
    var aw = BufWriter{ .buf = &ack_buf };
    aw.writeU16(1);
    aw.writePrefixed("ghost-job-xyz");
    aw.writePrefixed("some-queue");
    aw.writeU8(0); // ack_status = done
    aw.writeU8(0); // flags

    ctx.injectFrame(conn_id, rpc.MSG_ACK_BATCH, 1, aw.written());
    ctx.pipeline.tick();

    // Should not crash, applied_total should reflect the op was processed
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.applied_total);
}

test "fail with wrong lease_token is rejected" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-fail-lease");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Enqueue
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("fail-lease-q");
    ew.writePrefixed("fail-lease-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fetch with short lease
    const fetch_conn = ctx.backend.connect().?;
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(2000); // 2s lease
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("fail-lease-q");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 1, fw.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Reclaim + re-fetch (new lease_token)
    advanceTestClock(3_000_000_000);
    ctx.pipeline.config.reclaim_interval_ns = 1_000_000_000;
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    const fetch_conn2 = ctx.backend.connect().?;
    fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-2");
    fw.writeU8(1);
    fw.writePrefixed("fail-lease-q");

    ctx.injectFrame(fetch_conn2, rpc.MSG_FETCH_BATCH, 2, fw.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fail with stale lease_token via HTTP
    const fail_conn = ctx.backend.connect().?;
    const fail_body = "{\"job_id\":\"fail-lease-1\",\"queue\":\"fail-lease-q\",\"lease_token\":1,\"error\":\"oops\"}";
    var http_buf: [512]u8 = undefined;
    var http_w = BufWriter{ .buf = &http_buf };
    http_w.writeBytes("POST /api/v1/fail HTTP/1.1\r\nHost: localhost\r\nContent-Length: ");
    http_w.writeBytes(std.fmt.comptimePrint("{d}", .{fail_body.len}));
    http_w.writeBytes("\r\n\r\n");
    http_w.writeBytes(fail_body);
    ctx.backend.injectRecv(fail_conn, http_w.written());
    ctx.pipeline.tick();

    // Job should still be active (stale fail rejected)
    var key_buf: keys.KeyBuf = undefined;
    var verify_batch = ctx.stores[0].newBatch();
    defer verify_batch.close();
    var job_buf: [4096]u8 = undefined;
    const job_bytes = verify_batch.getInto(keys.jobKey(&key_buf, "fail-lease-1"), &job_buf);
    try testing.expect(job_bytes != null);
    const job = codec.decodeJob(job_bytes.?);
    try testing.expectEqual(types.JobState.active, job.state);
}

test "fetch from paused queue returns empty" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-fetch-paused");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Enqueue a job
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("pause-q");
    ew.writePrefixed("pause-job-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Pause the queue via RPC (MSG_QUEUE_CONFIG with pause action)
    var qcfg_buf: [256]u8 = undefined;
    var qw = BufWriter{ .buf = &qcfg_buf };
    qw.writePrefixed("pause-q");
    qw.writeU8(@intFromEnum(ops_mod.QueueAction.pause)); // action = pause
    qw.writeU32(0); // max_concurrency
    qw.writeU32(0); // rate_limit
    qw.writeU32(0); // rate_window_ms
    qw.writeU8(0); // fairness

    ctx.injectFrame(conn_id, rpc.MSG_QUEUE_CONFIG, 2, qw.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Try to fetch — should get no jobs (subscription waits, queue paused)
    const fetch_conn = ctx.backend.connect().?;
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("pause-q");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 3, fw.written());
    ctx.pipeline.tick();

    // No response — subscription is held (queue paused)
    const fetch_c = ctx.backend.conn(fetch_conn);
    try testing.expectEqual(@as(u32, 0), fetch_c.send_len);
}

test "double ack same job is no-op" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-double-ack");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Enqueue
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("dack-q");
    ew.writePrefixed("dack-job-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fetch
    const fetch_conn = ctx.backend.connect().?;
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("dack-q");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 2, fw.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    const applied_before = ctx.pipeline.applied_total;

    // Ack once
    var ack_buf: [256]u8 = undefined;
    var aw = BufWriter{ .buf = &ack_buf };
    aw.writeU16(1);
    aw.writePrefixed("dack-job-1");
    aw.writePrefixed("dack-q");
    aw.writeU8(0);
    aw.writeU8(0);

    ctx.injectFrame(fetch_conn, rpc.MSG_ACK_BATCH, 3, aw.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Job is auto-deleted after ack (persist_completed=false by default)
    var key_buf: keys.KeyBuf = undefined;
    var vb = ctx.stores[0].newBatch();
    var job_buf: [4096]u8 = undefined;
    const job_bytes = vb.getInto(keys.jobKey(&key_buf, "dack-job-1"), &job_buf);
    try testing.expect(job_bytes == null); // deleted
    vb.close();

    // Ack again — should be no-op (job doesn't exist), no crash
    aw = BufWriter{ .buf = &ack_buf };
    aw.writeU16(1);
    aw.writePrefixed("dack-job-1");
    aw.writePrefixed("dack-q");
    aw.writeU8(0);
    aw.writeU8(0);

    ctx.injectFrame(fetch_conn, rpc.MSG_ACK_BATCH, 4, aw.written());
    ctx.pipeline.tick();

    // Should not crash — op was processed
    try testing.expect(ctx.pipeline.applied_total > applied_before);
}

test "fetch respects max_concurrency" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-maxconc");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Enqueue two jobs (creates the queue)
    var enq_buf: [512]u8 = undefined;
    for ([_][]const u8{ "conc-job-1", "conc-job-2" }) |job_id| {
        var ew = BufWriter{ .buf = &enq_buf };
        ew.writeU16(1);
        ew.writePrefixed("conc-q");
        ew.writePrefixed(job_id);
        ew.writeU8(128);
        ew.writeU16(3);
        ew.writeU8(0);
        ew.writeU32(0);
        ew.writeU32(0);
        ew.writeU32(0);
        ew.writeU64(0);
        ew.writeU32(0);
        ew.writeU16(0);
        ew.writeU16(0);

        ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
        ctx.pipeline.tick();
        ctx.backend.submit();
        _ = ctx.backend.drain(&ctx.pipeline.completions);
    }

    // Set queue max_concurrency=1 via RPC
    var qcfg_buf: [256]u8 = undefined;
    var qw = BufWriter{ .buf = &qcfg_buf };
    qw.writePrefixed("conc-q");
    qw.writeU8(@intFromEnum(ops_mod.QueueAction.concurrency));
    qw.writeU32(1); // max_concurrency = 1
    qw.writeU32(0);
    qw.writeU32(0);
    qw.writeU8(0);

    ctx.injectFrame(conn_id, rpc.MSG_QUEUE_CONFIG, 2, qw.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fetch 1 job (saturates max_concurrency)
    const fetch_conn = ctx.backend.connect().?;
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1); // prefetch=1
    fw.writeU32(30000);
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("conc-q");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 3, fw.written());
    ctx.pipeline.tick();

    const fetch_c = ctx.backend.conn(fetch_conn);
    try testing.expect(fetch_c.send_len > 0); // got job 1
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Second fetch on different connection — should get nothing (at max_concurrency)
    const fetch_conn2 = ctx.backend.connect().?;
    fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-2");
    fw.writeU8(1);
    fw.writePrefixed("conc-q");

    ctx.injectFrame(fetch_conn2, rpc.MSG_FETCH_BATCH, 4, fw.written());
    ctx.pipeline.tick();

    // No response — subscription waits because concurrency is saturated
    const fetch_c2 = ctx.backend.conn(fetch_conn2);
    try testing.expectEqual(@as(u32, 0), fetch_c2.send_len);
}

test "single fetch with prefetch > max_concurrency only returns max_concurrency jobs" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-maxconc-prefetch");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Enqueue 5 jobs
    var enq_buf: [512]u8 = undefined;
    for ([_][]const u8{ "mc-job-1", "mc-job-2", "mc-job-3", "mc-job-4", "mc-job-5" }) |job_id| {
        var ew = BufWriter{ .buf = &enq_buf };
        ew.writeU16(1);
        ew.writePrefixed("mc-q");
        ew.writePrefixed(job_id);
        ew.writeU8(128);
        ew.writeU16(3);
        ew.writeU8(0);
        ew.writeU32(0);
        ew.writeU32(0);
        ew.writeU32(0);
        ew.writeU64(0);
        ew.writeU32(0);
        ew.writeU16(0);
        ew.writeU16(0);

        ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
        ctx.pipeline.tick();
        ctx.backend.submit();
        _ = ctx.backend.drain(&ctx.pipeline.completions);
    }

    // Set queue max_concurrency=1
    var qcfg_buf: [256]u8 = undefined;
    var qw = BufWriter{ .buf = &qcfg_buf };
    qw.writePrefixed("mc-q");
    qw.writeU8(@intFromEnum(ops_mod.QueueAction.concurrency));
    qw.writeU32(1); // max_concurrency = 1
    qw.writeU32(0);
    qw.writeU32(0);
    qw.writeU8(0);

    ctx.injectFrame(conn_id, rpc.MSG_QUEUE_CONFIG, 2, qw.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fetch with prefetch=5 — should only get 1 job due to max_concurrency=1
    const fetch_conn = ctx.backend.connect().?;
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(5); // prefetch=5
    fw.writeU32(30000);
    fw.writePrefixed("worker-mc");
    fw.writeU8(1);
    fw.writePrefixed("mc-q");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 3, fw.written());
    ctx.pipeline.tick();

    const resp = ctx.readResponse(fetch_conn).?;
    try testing.expectEqual(rpc.MSG_FETCH_BATCH_RESP, resp.header.msg_type);

    var r = BufReader{ .data = resp.payload };
    const fetched_count = try r.readU16();
    // Must be exactly 1, not 5 — max_concurrency caps it within a single fetch batch
    try testing.expectEqual(@as(u16, 1), fetched_count);
}

test "reclaim transitions expired active job back to pending" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-reclaim");
    defer ctx.destroy();

    const conn_id = ctx.backend.connect().?;

    // Enqueue
    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("reclaim-q");
    ew.writePrefixed("reclaim-job-1");
    ew.writeU8(128);
    ew.writeU16(3); // max_retries=3
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 1, ew.written());
    ctx.pipeline.tick();
    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Fetch with short lease (2s)
    const fetch_conn = ctx.backend.connect().?;
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(2000); // 2s lease
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("reclaim-q");

    ctx.injectFrame(fetch_conn, rpc.MSG_FETCH_BATCH, 2, fw.written());
    ctx.pipeline.tick();

    // Verify it was fetched (active)
    var key_buf: keys.KeyBuf = undefined;
    var vb = ctx.stores[0].newBatch();
    var job_buf: [4096]u8 = undefined;
    var job_bytes = vb.getInto(keys.jobKey(&key_buf, "reclaim-job-1"), &job_buf);
    try testing.expect(job_bytes != null);
    var job = codec.decodeJob(job_bytes.?);
    try testing.expectEqual(types.JobState.active, job.state);
    vb.close();

    ctx.backend.submit();
    _ = ctx.backend.drain(&ctx.pipeline.completions);

    // Advance past lease expiry and trigger reclaim
    advanceTestClock(3_000_000_000); // +3s (past 2s lease)
    ctx.pipeline.config.reclaim_interval_ns = 1_000_000_000;
    ctx.pipeline.tick();

    // Job should be back to pending (reclaimed)
    var vb2 = ctx.stores[0].newBatch();
    defer vb2.close();
    job_bytes = vb2.getInto(keys.jobKey(&key_buf, "reclaim-job-1"), &job_buf);
    try testing.expect(job_bytes != null);
    job = codec.decodeJob(job_bytes.?);
    try testing.expectEqual(types.JobState.pending, job.state);
}

// ============================================================================
// Raft Replication Tests
// ============================================================================

test "raft step-down evicts fetch subscribers with MSG_NOT_LEADER (Bug A)" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-raft-stepdown-evict");
    defer ctx.destroy();
    ctx.enableRaftAsLeader();

    // Subscribe a worker to an empty queue — it stays waiting (no jobs).
    const conn = ctx.backend.connect().?;
    var fetch_buf: [256]u8 = undefined;
    var fw = BufWriter{ .buf = &fetch_buf };
    fw.writeU16(1);
    fw.writeU32(30000);
    fw.writePrefixed("worker-1");
    fw.writeU8(1);
    fw.writePrefixed("evict-queue");
    ctx.injectFrame(conn, rpc.MSG_FETCH_BATCH, 9, fw.written());
    ctx.pipeline.tick();
    try testing.expect(ctx.backend.conn(conn).waiting);
    try testing.expectEqual(@as(u32, 1), ctx.pipeline.waiting_conn_count);

    // Leadership lost. No in-flight proposals, so the next tick steps down and
    // must drain the subscriber: a fetch claim is a local write a follower may
    // not serve, so the worker is told to redial the leader rather than hang.
    ctx.raft.is_leader = false;
    ctx.pipeline.tick();

    try testing.expectEqual(TestPipeline.RaftState.follower, ctx.pipeline.raft_state);
    try testing.expectEqual(@as(u32, 0), ctx.pipeline.waiting_conn_count);
    try testing.expect(!ctx.backend.conn(conn).waiting);

    const resp = ctx.readResponse(conn).?;
    try testing.expectEqual(rpc.MSG_NOT_LEADER, resp.header.msg_type);
}

test "raft follower — write frames answered MSG_NOT_LEADER, nothing committed" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-raft-follower");
    defer ctx.destroy();
    ctx.raft.is_leader = false;
    ctx.pipeline.config.raft = ctx.raft.iface();
    ctx.pipeline.raft_state = .follower;

    const conn_id = ctx.backend.connect().?;

    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("fw-queue");
    ew.writePrefixed("fw-job-1");
    ew.writeU8(128);
    ew.writeU16(3);
    ew.writeU8(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU32(0);
    ew.writeU64(0);
    ew.writeU32(0);
    ew.writeU16(0);
    ew.writeU16(0);

    ctx.injectFrame(conn_id, rpc.MSG_ENQUEUE_BATCH, 7, ew.written());
    ctx.pipeline.tick();

    // Rejected immediately: no proposal, no prepare slot, NOT_LEADER frame.
    try testing.expectEqual(@as(u32, 0), ctx.raft.spawned_count);
    try testing.expectEqual(@as(u32, 0), ctx.pipeline.prepare_count);
    const resp = ctx.readResponse(conn_id).?;
    try testing.expectEqual(rpc.MSG_NOT_LEADER, resp.header.msg_type);
    try testing.expectEqual(@as(u32, 7), resp.header.req_id);

    // Nothing reached the KV.
    var vb = ctx.stores[0].newBatch();
    defer vb.close();
    var key_buf: keys.KeyBuf = undefined;
    var job_buf: [512]u8 = undefined;
    try testing.expect(vb.getInto(keys.jobKey(&key_buf, "fw-job-1"), &job_buf) == null);
}

test "raft leadership acquisition — barrier commit rebuilds then leads" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-raft-acquire");
    defer ctx.destroy();
    ctx.raft.is_leader = false;
    ctx.pipeline.config.raft = ctx.raft.iface();
    ctx.pipeline.raft_state = .follower;

    // Follower ticks: no barrier proposed while not leader.
    ctx.pipeline.tick();
    try testing.expectEqual(TestPipeline.RaftState.follower, ctx.pipeline.raft_state);
    try testing.expectEqual(@as(u32, 0), ctx.raft.spawned_count);

    // Host reports leadership → barrier proposed, state = acquiring.
    ctx.raft.is_leader = true;
    ctx.pipeline.tick();
    try testing.expectEqual(TestPipeline.RaftState.acquiring, ctx.pipeline.raft_state);
    try testing.expectEqual(@as(u32, 1), ctx.raft.spawned_count);

    // Barrier still pending → stays acquiring.
    ctx.pipeline.tick();
    try testing.expectEqual(TestPipeline.RaftState.acquiring, ctx.pipeline.raft_state);

    // Barrier commits → rebuild + leading.
    ctx.raft.finishAll(.committed);
    ctx.pipeline.tick();
    try testing.expectEqual(TestPipeline.RaftState.leading, ctx.pipeline.raft_state);
}

test "raft leadership acquisition — barrier failure falls back to follower" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-raft-acquire-fail");
    defer ctx.destroy();
    ctx.raft.is_leader = true;
    ctx.pipeline.config.raft = ctx.raft.iface();
    ctx.pipeline.raft_state = .follower;

    ctx.pipeline.tick();
    try testing.expectEqual(TestPipeline.RaftState.acquiring, ctx.pipeline.raft_state);

    // Leadership lost before the barrier committed — no local writes
    // happened, so this is a clean fallback, not divergence.
    ctx.raft.is_leader = false;
    ctx.raft.finishAll(.failed);
    ctx.pipeline.tick();
    try testing.expectEqual(TestPipeline.RaftState.follower, ctx.pipeline.raft_state);
}
