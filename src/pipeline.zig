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
const io_mod = @import("io.zig");
const rpc = @import("rpc.zig");
const http = @import("http.zig");
const http_read = @import("http_read.zig");
const kv_read = @import("kv_read.zig");
const ops_mod = @import("ops.zig");
const kv = @import("kv.zig");
const handler_mod = @import("handler.zig");
const oplog_mod = @import("oplog.zig");
const notify_mod = @import("notify.zig");
const assert = @import("assert.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const types = @import("types.zig");

const OpHandler = handler_mod.OpHandler;
const QueueNotifier = notify_mod.QueueNotifier;
const ConnState = io_mod.ConnState;
const Protocol = ConnState.Protocol;
const Completion = io_mod.Completion;
const BufReader = rpc.BufReader;
const BufWriter = rpc.BufWriter;

// ========================================================================
// ReplHook — replication callback vtable (module-level, backend-agnostic)
// ========================================================================

/// Called after oplog append with encoded mutations. Cluster mode uses this
/// to fan out mutations to followers via TCP.
pub const ReplHook = struct {
    ptr: *anyopaque,
    replicate_fn: *const fn (ptr: *anyopaque, shard_id: u16, seq: u64, data: []const u8) void,

    pub fn replicate(self: ReplHook, shard_id: u16, seq: u64, data: []const u8) void {
        self.replicate_fn(self.ptr, shard_id, seq, data);
    }
};

pub fn Pipeline(comptime IoBackend: type) type {
    return struct {
        const Self = @This();

        io: *IoBackend,
        handler: *OpHandler,
        stores: []kv.Store,
        oplog: *oplog_mod.Log,
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

        // Sync replication — pipelined prepares.
        // Up to max_prepare_slots batches can be in-flight. Each slot holds
        // deferred sends + recv requeues until replication ack arrives.
        // last_acked_seq is written by the TCP receive thread (via onFollowerAck),
        // read by the pipeline tick thread. Single atomic, single shared state.
        last_acked_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        last_recorded_seq: u64 = 0,
        prepare_slots: [max_prepare_slots]PrepareSlot = [_]PrepareSlot{.{}} ** max_prepare_slots,
        prepare_head: u32 = 0,
        prepare_tail: u32 = 0,
        prepare_count: u32 = 0,
        // Recv connections that arrived while all prepare slots were full.
        // CQEs consumed but data is in recv_buf. Processed when a slot frees up.
        deferred_recv_conns: [max_completions]u16 = undefined,
        deferred_recv_conn_count: u32 = 0,

        // Stats
        ticks_total: u64 = 0,
        applied_total: u64 = 0,
        subscriptions_fulfilled: u64 = 0,
        maintenance_runs: u64 = 0,

        const max_batch_jobs = rpc.MAX_BATCH_JOBS;
        const max_frames: u32 = 256;
        const max_completions: u32 = 256;
        const max_waiting_conns: u32 = 4096;
        const max_notified_queues: u32 = 64;
        const max_prepare_slots: u32 = 4;

        /// Pipelined prepare slot for sync replication. Holds deferred
        /// sends and recv requeues until replication ack arrives.
        const PrepareSlot = struct {
            send_conns: [max_frames + max_waiting_conns]u16 = undefined,
            send_conn_count: u32 = 0,
            recv_conns: [max_completions]u16 = undefined,
            recv_conn_count: u32 = 0,
            ack_seq: u64 = 0,
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
            repl_hook: ?ReplHook = null,
            sync_replication: bool = false,
            /// Adaptive batch coalescing window for sync replication (nanoseconds).
            /// When sync_replication is on and a drain yields fewer than max_frames,
            /// the pipeline continues collecting frames via non-blocking drains until
            /// the batch is full or this window elapses. Zero disables coalescing.
            /// Only applies when sync_replication is true.
            coalesce_window_ns: u64 = 0, // set by main.zig for production
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
            oplog: *oplog_mod.Log,
            notify: *QueueNotifier,
            reader: ?*kv_read.Reader,
            config: Config,
        ) Self {
            return .{
                .io = io_backend,
                .handler = handler,
                .stores = stores,
                .oplog = oplog,
                .notify = notify,
                .reader = reader,
                .config = config,
                .allocator = allocator,
            };
        }

        /// Heap-allocate the pipeline. The struct is ~5MB due to inline
        /// scratch buffers — too large for the default 8MB thread stack.
        pub fn initHeap(
            allocator: std.mem.Allocator,
            io_backend: *IoBackend,
            handler: *OpHandler,
            stores: []kv.Store,
            oplog: *oplog_mod.Log,
            notify: *QueueNotifier,
            reader: ?*kv_read.Reader,
            config: Config,
        ) *Self {
            const self = allocator.create(Self) catch unreachable;
            self.* = init(allocator, io_backend, handler, stores, oplog, notify, reader, config);
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.mut_list.items) |m| {
                if (m.key.len > 0) self.allocator.free(@constCast(m.key));
                if (m.value.len > 0 and m.op != .delete) self.allocator.free(@constCast(m.value));
            }
            self.mut_list.deinit(self.allocator);
        }

        pub fn destroyHeap(self: *Self) void {
            const alloc = self.allocator;
            self.deinit();
            alloc.destroy(self);
        }

        /// Called from TCP receive thread when a follower acks a sequence.
        /// Thread-safe: single atomic write, no locks.
        pub fn onFollowerAck(self: *Self, seq: u64) void {
            const prev = self.last_acked_seq.load(.monotonic);
            if (seq > prev) self.last_acked_seq.store(seq, .release);
        }

        /// Returns a pointer to the ack sequence atomic. Cluster mode wires this
        /// into the TCP fast-path callback for direct atomic updates.
        pub fn ackSeqPtr(self: *Self) *std.atomic.Value(u64) {
            return &self.last_acked_seq;
        }

        // ====================================================================
        // Tick — the entire event loop body
        // ====================================================================

        pub fn tick(self: *Self) void {
            // ---- Phase 1: Flush acked prepare slots (FIFO order) ----
            // Pipelined prepares: up to max_prepare_slots batches in-flight
            // for sync replication. Each slot holds deferred sends + recv
            // requeues until replication ack arrives.
            while (self.prepare_count > 0) {
                const slot = &self.prepare_slots[self.prepare_head];
                if (self.last_acked_seq.load(.acquire) >= slot.ack_seq) {
                    self.flushPrepareSlot(slot);
                    slot.ack_seq = 0;
                    self.prepare_head = (self.prepare_head + 1) % max_prepare_slots;
                    self.prepare_count -= 1;
                } else {
                    break;
                }
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
                        .closed => self.onConnClosed(completion.conn_id),
                        .send_done => {
                            const sc = self.io.conn(completion.conn_id);
                            if (sc.recv_pos > 0) {
                                self.deferRecvConn(completion.conn_id);
                            } else {
                                self.io.queueRecv(completion.conn_id);
                            }
                        },
                    }
                }
                self.io.submit();
                self.ticks_total += 1;
                return;
            }

            // ---- Phase 3: Normal batch processing ----

            // 1. Drain IO completions.
            //    When prepare slots are pending (waiting for follower ack), use
            //    non-blocking drain: the ack arrives via atomic (TCP thread), not
            //    via io_uring CQE, so blocking drain would stall forever when no
            //    other SQEs are in-flight.
            //    With coalescing (sync-repl + no pending slots), the IO layer
            //    collects CQEs for up to coalesce_window_ns to build a larger batch.
            const has_pending = self.prepare_count > 0;
            const coalesce = !has_pending and self.config.sync_replication and
                self.config.repl_hook != null and self.config.coalesce_window_ns > 0;
            const n = if (has_pending)
                self.io.drainNonBlocking(&self.completions)
            else if (coalesce)
                self.io.drainCoalescing(
                    &self.completions,
                    self.config.clock_fn,
                    @as(u64, @intCast(self.config.clock_fn())) + self.config.coalesce_window_ns,
                )
            else
                self.io.drain(&self.completions);

            // Reset per-tick state.
            self.frame_count = 0;
            self.recv_compaction_count = 0;
            self.notified_queue_count = 0;

            // 2. Process completions — collect unique recv conn_ids.
            var recv_conns: [max_completions]u16 = undefined;
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
                    .closed => self.onConnClosed(completion.conn_id),
                    .send_done => {
                        const c = self.io.conn(completion.conn_id);
                        if (c.recv_pos > 0) {
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
                    recv_conns[recv_conn_count] = dc;
                    recv_conn_count += 1;
                }
            }
            self.deferred_recv_conn_count = 0;

            for (recv_conns[0..recv_conn_count]) |conn_id| {
                self.extractFrames(conn_id);
            }

            // Run scheduled maintenance in its own batch, committed before client ops.
            self.runMaintenance();

            if (self.frame_count == 0) {
                if (self.notified_queue_count > 0) {
                    self.fulfillSubscriptions();
                    self.flushSends();
                }
                self.compactRecvBufs();
                self.requeueRecvs(recv_conns[0..recv_conn_count]);
                self.io.submit();
                self.ticks_total += 1;
                return;
            }

            // 3. Execute: decode + apply in single kv.Batch.
            const seq_before = self.last_recorded_seq;
            self.executeBatch();
            const has_new_mutations = self.last_recorded_seq > seq_before;

            // 4. Sync replication with mutations: encode responses now (while
            //    recv_buf slices are still valid), compact recv_bufs, then defer
            //    sends until follower ack. No mutations = no replication needed.
            if (self.config.sync_replication and self.config.repl_hook != null and has_new_mutations) {
                // Capture ack_seq from executeBatch BEFORE fulfillSubscriptions,
                // which may produce additional oplog entries for worker registration.
                // Those entries are replicated but not waited for (matches old behavior
                // where fulfillSubscriptions ran after the ack arrived).
                const batch_ack_seq = self.last_recorded_seq;

                self.encodeResponses();
                self.fulfillSubscriptions();
                self.compactRecvBufs();

                // Fast path: ack already arrived (TCP thread can race ahead).
                if (self.last_acked_seq.load(.acquire) >= batch_ack_seq) {
                    self.flushSends();
                    self.requeueRecvs(recv_conns[0..recv_conn_count]);
                } else {
                    // Save to prepare slot — sends deferred until follower ack.
                    assert.check(
                        self.prepare_count < max_prepare_slots,
                        "pipeline: prepare slot overflow",
                        .{},
                    );
                    const slot = &self.prepare_slots[self.prepare_tail];
                    slot.ack_seq = batch_ack_seq;
                    @memcpy(slot.send_conns[0..self.send_conn_count], self.send_conns[0..self.send_conn_count]);
                    slot.send_conn_count = self.send_conn_count;
                    @memcpy(slot.recv_conns[0..recv_conn_count], recv_conns[0..recv_conn_count]);
                    slot.recv_conn_count = recv_conn_count;
                    self.prepare_tail = (self.prepare_tail + 1) % max_prepare_slots;
                    self.prepare_count += 1;
                }
            } else {
                self.encodeResponses();
                self.fulfillSubscriptions();
                self.flushSends();
                self.compactRecvBufs();
                self.requeueRecvs(recv_conns[0..recv_conn_count]);
            }

            self.io.submit();
            self.ticks_total += 1;
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

                self.frames[self.frame_count] = .{
                    .conn_id = conn_id,
                    .req_id = hdr.req_id,
                    .msg_type = hdr.msg_type,
                    .payload = c.recv_buf[payload_start..frame_end],
                };
                self.frame_count += 1;
                pos = @intCast(frame_end);
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

            // Auth check (skipped for healthz and auth/status).
            const clean_path = if (std.mem.indexOfScalar(u8, req.path, '?')) |qi| req.path[0..qi] else req.path;
            const skip_auth = std.mem.eql(u8, clean_path, "/healthz") or
                std.mem.eql(u8, clean_path, "/api/v1/auth/status") or
                std.mem.eql(u8, clean_path, "/metrics") or
                std.mem.eql(u8, clean_path, "/ui") or
                std.mem.startsWith(u8, clean_path, "/ui/");
            if (!skip_auth) {
                const auth_result = http.checkAuth(req.api_key, req.method, self.reader);
                if (auth_result != .ok) {
                    const resp_len = http.writeAuthError(c.send_buf, auth_result);
                    if (resp_len > 0) {
                        c.send_len = resp_len;
                        self.io.queueSend(conn_id, resp_len);
                    }
                    self.recordRecvCompaction(conn_id, req.total_len);
                    return;
                }
            }

            switch (route) {
                .read => {
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
                    );
                    if (resp_len > 0) {
                        c.send_len = resp_len;
                        self.io.queueSend(conn_id, resp_len);
                    }
                    self.recordRecvCompaction(conn_id, req.total_len);
                },
                .write => |w| {
                    if (self.frame_count >= max_frames) return; // back-pressure

                    // Payload size validation — return 413 instead of asserting.
                    if (req.body.len > self.config.max_payload_size) {
                        const resp_len = http.writeResponse(c.send_buf, 413, "{\"error\":\"payload too large\"}");
                        c.send_len = resp_len;
                        self.io.queueSend(conn_id, resp_len);
                        self.recordRecvCompaction(conn_id, req.total_len);
                        return;
                    }

                    self.frames[self.frame_count] = .{
                        .conn_id = conn_id,
                        .req_id = 0,
                        .msg_type = w.msg_type,
                        .payload = req.body,
                        .protocol = .http,
                        .path_param = w.param,
                        .sub_action = w.sub_action,
                        .http_path = req.path,
                    };
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

            const intervals = [6]struct { ns: u64, last: *u64, action: ops_mod.MaintenanceAction }{
                .{ .ns = self.config.promote_interval_ns, .last = &self.last_promote_ns, .action = .promote },
                .{ .ns = self.config.reclaim_interval_ns, .last = &self.last_reclaim_ns, .action = .reclaim },
                .{ .ns = self.config.unique_interval_ns, .last = &self.last_unique_ns, .action = .unique },
                .{ .ns = self.config.rate_limit_interval_ns, .last = &self.last_rate_limit_ns, .action = .rate_limit },
                .{ .ns = self.config.expire_interval_ns, .last = &self.last_expire_ns, .action = .expire },
                .{ .ns = self.config.purge_interval_ns, .last = &self.last_purge_ns, .action = .purge },
            };

            var any_due = false;
            for (intervals) |iv| {
                if (iv.ns > 0 and now_ns - iv.last.* >= iv.ns) {
                    any_due = true;
                    break;
                }
            }
            if (!any_due) return;

            self.handler.resetEffects();
            var batch = self.stores[0].newBatch();
            defer batch.close();

            const record_mutations = self.config.repl_hook != null;
            if (record_mutations) {
                self.mut_list.clearRetainingCapacity();
                batch.enableRecording(self.allocator, &self.mut_list);
            }
            defer if (record_mutations) batch.freeMutations();

            for (intervals) |iv| {
                if (iv.ns == 0) continue;
                if (now_ns - iv.last.* < iv.ns) continue;

                const cutoff = if (iv.action == .rate_limit and self.handler.max_rate_window_ns > 0)
                    now_ns -| self.handler.max_rate_window_ns
                else
                    now_ns;
                const op_data = ops_mod.OpData{ .maintenance = .{ .action = iv.action, .now_ns = now_ns, .cutoff_ns = cutoff } };
                const result = self.handler.apply(&batch, .maintenance, &op_data);
                self.emitMirrorOp(.maintenance, &op_data, &result);

                if (result.notify_queues) |queues| {
                    self.notify.notifyQueues(queues);
                    for (queues) |q| self.recordNotifiedQueue(q);
                }

                iv.last.* = now_ns;
                self.maintenance_runs += 1;
                self.applied_total += 1;
            }

            batch.commit();

            if (record_mutations and self.mut_list.items.len > 0) {
                self.recordOplog();
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
            self.handler.resetEffects();
            var kv_batch = self.stores[0].newBatch();
            defer kv_batch.close();

            // Record mutations if we have a file-backed oplog OR a repl_hook
            // (cluster mode needs mutation recording even without a file).
            const record_mutations = self.config.repl_hook != null;
            if (record_mutations) {
                self.mut_list.clearRetainingCapacity();
                kv_batch.enableRecording(self.allocator, &self.mut_list);
            }
            defer if (record_mutations) kv_batch.freeMutations();

            for (self.frames[0..self.frame_count], 0..) |*frame, i| {
                self.results[i] = self.decodeAndApply(&kv_batch, frame, @intCast(i));
            }

            kv_batch.commit();
            self.applied_total += self.frame_count;

            if (record_mutations and self.mut_list.items.len > 0) {
                self.recordOplog();
            }

            // Post-commit: notify queue waiters
            for (self.frames[0..self.frame_count], 0..) |frame, i| {
                self.notifyForFrame(&frame, &self.results[i]);
            }
        }

        fn recordOplog(self: *Self) void {
            const encoded = oplog_mod.encodeMutations(self.allocator, self.mut_list.items);
            defer self.allocator.free(encoded);
            const seq = self.oplog.append(0, encoded);
            self.last_recorded_seq = seq;
            if (self.config.repl_hook) |hook| hook.replicate(0, seq, encoded);
        }

        fn decodeAndApply(self: *Self, batch: *kv.WriteBatch, frame: *FrameDesc, frame_idx: u32) ops_mod.OpResult {
            // HTTP writes use JSON decode; RPC uses binary decode.
            if (frame.protocol == .http)
                return self.decodeAndApplyHttp(batch, frame, frame_idx);

            switch (frame.msg_type) {
                rpc.MSG_PING => return .{},

                rpc.MSG_ENQUEUE_BATCH => {
                    var reader = BufReader{ .data = frame.payload };
                    const now_ns = self.nowNs();
                    const parsed = rpc.parseEnqueue(&reader, &self.jobs_buf, now_ns) catch
                        return .{ .err = "parse error" };
                    frame.count = parsed.count;
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
                    const parsed = rpc.bulk.parseBulkAction(&reader, &self.bulk_ids_buf) catch
                        return .{ .err = "parse error" };
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

            // Generate server-side IDs for operations that need them.
            switch (frame.msg_type) {
                rpc.MSG_ENQUEUE_BATCH => {
                    self.http_id_counter += 1;
                    const id = http.generateId(&self.http_id_bufs[frame_idx], now_ns, self.http_id_counter);
                    self.http_scratch.jobs[0].job_id = id;
                    frame.path_param = id;
                },
                rpc.MSG_BATCH_CREATE, rpc.MSG_CRON_CREATE, rpc.MSG_SET_BUDGET, rpc.MSG_MODIFY_ENT_SETTING => {
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
                rpc.MSG_MODIFY_ENT_SETTING => .modify_ent_setting,
                rpc.MSG_GLOBAL_CONFIG => .global_config,
                else => return .{ .err = "unsupported http write" },
            };

            var result = self.handler.apply(batch, op_type, &decoded.op_data);
            self.emitMirrorOp(op_type, &decoded.op_data, &result);

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
                    self.storeSubscription(frame.conn_id, &frame);
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

                // Payload: zero-copy lookup into caller buffer
                var payload_buf: [32768]u8 = undefined;
                var jpk_buf: keys.KeyBuf = undefined;
                const payload_key = keys.jobPayloadKey(&jpk_buf, job_id);
                var store = &self.stores[0];
                var batch = store.newBatch();
                defer batch.close();
                if (batch.getInto(payload_key, &payload_buf)) |payload_bytes| {
                    const pl: u16 = @intCast(@min(payload_bytes.len, 32768));
                    writer.writeU16(pl);
                    writer.writeBytes(payload_bytes[0..pl]);
                } else {
                    writer.writeU16(0);
                }
            }
        }



        // ====================================================================
        // Fetch subscriptions — store and fulfill
        // ====================================================================

        /// Store a fetch subscription in ConnState. Subscribe-only: RPC fetch
        /// always subscribes — fulfillSubscriptions serves pending jobs.
        /// Re-parses the subscription from the frame payload (still valid before compaction).
        fn storeSubscription(self: *Self, conn_id: u16, frame: *const FrameDesc) void {
            const c = self.io.conn(conn_id);
            if (c.phase == .free) return;

            // HTTP: don't subscribe. HTTP is request-response — return empty result immediately.
            // The client will retry (long-poll behavior is handled at a higher level).
            if (frame.protocol == .http) return;

            // Re-parse subscription from frame payload.
            var reader = BufReader{ .data = frame.payload };
            const sub = rpc.parseFetchSubscribe(&reader) catch return;

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

            c.credits = sub.credits;
            c.lease_ms = sub.lease_ms;
            c.last_req_id = frame.req_id;
            c.waiting = true;

            // Record subscribed queues as notified so fulfillSubscriptions
            // checks for pending jobs on the same tick (subscribe-only fetch).
            for (0..sub.queue_count) |qi| {
                self.recordNotifiedQueue(sub.queues[qi]);
            }

            // Add to waiting list (skip if already present).
            for (self.waiting_conns[0..self.waiting_conn_count]) |wc| {
                if (wc == conn_id) return;
            }
            assert.check(
                self.waiting_conn_count < max_waiting_conns,
                "pipeline: waiting_conns overflow",
                .{},
            );
            self.waiting_conns[self.waiting_conn_count] = conn_id;
            self.waiting_conn_count += 1;
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
            if (self.notified_queue_count == 0) return;
            if (self.waiting_conn_count == 0) return;

            // We may modify waiting_conns during iteration (removeWaitingConn uses swap-remove),
            // so iterate by index and handle carefully.
            var fulfilled: [max_waiting_conns]u16 = undefined;
            var fulfilled_count: u32 = 0;

            var kv_batch = self.stores[0].newBatch();
            defer kv_batch.close();
            var did_fulfill = false;

            // Enable mutation recording for oplog + replication.
            const record_mutations = self.config.repl_hook != null;
            if (record_mutations) {
                self.mut_list.clearRetainingCapacity();
                kv_batch.enableRecording(self.allocator, &self.mut_list);
            }
            defer if (record_mutations) kv_batch.freeMutations();

            for (self.waiting_conns[0..self.waiting_conn_count]) |conn_id| {
                const c = self.io.conn(conn_id);
                if (c.phase == .free or !c.waiting) continue;

                // Check if any subscribed queue was notified this tick.
                if (!self.hasQueueOverlap(c)) continue;

                // Try to fetch jobs for this subscription.
                var queue_slices: [16][]const u8 = undefined;
                for (0..c.queue_count) |qi| {
                    queue_slices[qi] = c.queue_bufs[qi][0..c.queue_lens[qi]];
                }

                const op_data = ops_mod.OpData{ .fetch = .{
                    .queues = queue_slices[0..c.queue_count],
                    .worker_id = c.worker_id_buf[0..c.worker_id_len],
                    .lease_duration_ms = c.lease_ms,
                    .count = c.credits,
                    .now_ns = self.nowNs(),
                } };

                const result = self.handler.apply(&kv_batch, .fetch, &op_data);

                if (result.affected == 0) continue; // jobs taken by someone else

                did_fulfill = true;
                self.emitMirrorOp(.fetch, &op_data, &result);

                // Encode MSG_FETCH_BATCH_RESP into send_buf.
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
                self.trackSendConn(conn_id);

                // Clear subscription.
                c.waiting = false;
                c.queue_count = 0;
                c.credits = 0;
                self.subscriptions_fulfilled += 1;

                // Mark for removal from waiting list.
                assert.check(fulfilled_count < max_waiting_conns, "pipeline: fulfilled overflow", .{});
                fulfilled[fulfilled_count] = conn_id;
                fulfilled_count += 1;
            }

            if (did_fulfill) {
                kv_batch.commit();
                if (record_mutations and self.mut_list.items.len > 0) {
                    self.recordOplog();
                }
            }

            // Remove fulfilled connections from waiting list.
            for (fulfilled[0..fulfilled_count]) |conn_id| {
                self.removeWaitingConn(conn_id);
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
        // Notify — wake queue waiters post-commit
        // ====================================================================

        fn notifyForFrame(self: *Self, frame: *const FrameDesc, result: *const ops_mod.OpResult) void {
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
                },
                rpc.MSG_MAINTENANCE => {
                    // Promote/reclaim can make jobs available.
                    if (result.affected > 0) {
                        var reader = BufReader{ .data = frame.payload };
                        const parsed = rpc.management.parseMaintenance(&reader) catch return;
                        switch (parsed.action) {
                            .promote, .reclaim => {
                                if (result.notify_queues) |queues| {
                                    self.notify.notifyQueues(queues);
                                    for (queues) |q| {
                                        self.recordNotifiedQueue(q);
                                    }
                                }
                            },
                            else => {},
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
                if (c.waiting) continue;
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
                if (c.waiting) continue;
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

const TestContext = struct {
    db: *talon.DB,
    stores: [1]kv.Store,
    handler: OpHandler,
    oplog: oplog_mod.Log,
    notify: QueueNotifier,
    backend: SimBackend,
    pipeline: TestPipeline,
    db_path: [*:0]const u8,

    /// Heap-allocate and initialize a TestContext. Pipeline + SimBackend are ~7MB,
    /// too large for the test runner's thread stack.
    fn create(db_path: [*:0]const u8) !*TestContext {
        const allocator = testing.allocator;
        const self = try allocator.create(TestContext);
        self.initInPlace(allocator, db_path, null);
        return self;
    }

    fn createWithOplog(db_path: [*:0]const u8, oplog_path: [*:0]const u8) !*TestContext {
        const allocator = testing.allocator;
        const self = try allocator.create(TestContext);
        self.initInPlace(allocator, db_path, oplog_path);
        return self;
    }

    fn initInPlace(self: *TestContext, allocator: std.mem.Allocator, db_path: [*:0]const u8, oplog_path: ?[*:0]const u8) void {
        @atomicStore(i64, &test_clock_ns, 1_000_000_000_000, .monotonic);

        const path_slice = std.mem.span(db_path);
        std.fs.cwd().deleteTree(path_slice) catch {};
        const db = talon.DB.open(allocator, path_slice, .{ .sync = false }) catch unreachable;

        self.db = db;
        self.stores = [1]kv.Store{kv.Store.init(db)};
        self.handler = OpHandler.init(allocator);
        self.handler.rebuildState(&self.stores);
        self.oplog = oplog_mod.Log.init(allocator, .{ .now_fn = &testClockFn }, oplog_path, 1024);
        self.notify = QueueNotifier.init(allocator);
        self.backend = SimBackend.init(allocator, .{
            .listen_fd = -1,
            .max_conns = 16,
            .recv_buf_size = 65536,
            .send_buf_size = 65536,
        }) catch unreachable;
        self.db_path = db_path;

        self.pipeline = TestPipeline.init(
            allocator,
            &self.backend,
            &self.handler,
            &self.stores,
            &self.oplog,
            &self.notify,
            null,
            .{ .clock_fn = &testClockFn },
        );
    }

    fn destroy(self: *TestContext) void {
        const allocator = testing.allocator;
        self.pipeline.deinit();
        self.backend.deinit(allocator);
        self.handler.deinit();
        self.notify.deinit();
        self.oplog.deinit();
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
    try testing.expectEqual(@as(u32, 1), c.credits);
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

    // Subscription should be cleared.
    try testing.expect(!fetch_c.waiting);
    try testing.expectEqual(@as(u32, 0), ctx.pipeline.waiting_conn_count);
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.subscriptions_fulfilled);
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
    // Job should now be pending — fetch subscription fulfilled.
    try testing.expect(!ctx.backend.conn(fetch_conn).waiting);
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.subscriptions_fulfilled);
}

fn testReplNoop(_: *anyopaque, _: u16, _: u64, _: []const u8) void {}

test "sync-repl pipelined prepares — enqueue deferred, fetch fulfilled immediately" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-sync-repl-pipeline");
    defer ctx.destroy();

    var repl_ctx: u8 = 0;
    ctx.pipeline.config.sync_replication = true;
    ctx.pipeline.config.repl_hook = .{
        .ptr = @ptrCast(&repl_ctx),
        .replicate_fn = &testReplNoop,
    };

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

    // Fetch fulfilled immediately.
    try testing.expectEqual(@as(u64, 1), ctx.pipeline.subscriptions_fulfilled);
    // Enqueue still deferred.
    try testing.expectEqual(@as(u32, 1), ctx.pipeline.prepare_count);

    // 3. Ack the enqueue — flush prepare slot.
    ctx.pipeline.last_acked_seq.store(
        ctx.pipeline.prepare_slots[ctx.pipeline.prepare_head].ack_seq,
        .release,
    );
    ctx.pipeline.tick();

    try testing.expectEqual(@as(u32, 0), ctx.pipeline.prepare_count);

    // Enqueue response sent after ack.
    const enq_resp = ctx.readResponse(enq_conn).?;
    try testing.expectEqual(rpc.MSG_ENQUEUE_BATCH_RESP, enq_resp.header.msg_type);
    try testing.expectEqual(@as(u32, 1), enq_resp.header.req_id);
}

test "sync-repl pipelined prepares — multiple batches in flight" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-sync-repl-multi-slot");
    defer ctx.destroy();

    var repl_ctx: u8 = 0;
    ctx.pipeline.config.sync_replication = true;
    ctx.pipeline.config.repl_hook = .{
        .ptr = @ptrCast(&repl_ctx),
        .replicate_fn = &testReplNoop,
    };

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
    const slot0_seq = ctx.pipeline.prepare_slots[0].ack_seq;
    try testing.expect(slot0_seq > 0);

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
    const slot1_seq = ctx.pipeline.prepare_slots[1].ack_seq;
    try testing.expect(slot1_seq > slot0_seq);

    // 3. Ack all — both slots flushed in one tick.
    ctx.pipeline.last_acked_seq.store(slot1_seq, .release);
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

test "sync-repl pipelined prepares — fast path when ack races ahead" {
    const ctx = try TestContext.create("/tmp/corvo-pv2-sync-repl-fastpath");
    defer ctx.destroy();

    var repl_ctx: u8 = 0;
    ctx.pipeline.config.sync_replication = true;
    ctx.pipeline.config.repl_hook = .{
        .ptr = @ptrCast(&repl_ctx),
        .replicate_fn = &testReplNoop,
    };

    const conn_id = ctx.backend.connect().?;

    // Pre-ack a high sequence — simulates follower being ahead.
    ctx.pipeline.last_acked_seq.store(100, .release);

    var enq_buf: [512]u8 = undefined;
    var ew = BufWriter{ .buf = &enq_buf };
    ew.writeU16(1);
    ew.writePrefixed("fast-queue");
    ew.writePrefixed("fast-job-1");
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

    // Fast path: ack already high enough, no prepare slot used.
    try testing.expectEqual(@as(u32, 0), ctx.pipeline.prepare_count);

    // Response sent immediately.
    const resp = ctx.readResponse(conn_id).?;
    try testing.expectEqual(rpc.MSG_ENQUEUE_BATCH_RESP, resp.header.msg_type);
}
