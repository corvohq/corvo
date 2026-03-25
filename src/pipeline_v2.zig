//! Pipeline v2 — single-threaded tick loop, generic over IoBackend.
//!
//! THE write path. Replaces the old MPSC pipeline + engine + store.
//! One thread, one event loop, zero synchronization.
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
const Completion = io_mod.Completion;
const BufReader = rpc.BufReader;
const BufWriter = rpc.BufWriter;

pub fn Pipeline(comptime IoBackend: type) type {
    return struct {
        const Self = @This();

        io: *IoBackend,
        handler: *OpHandler,
        stores: []kv.Store,
        oplog: *oplog_mod.Log,
        notify: *QueueNotifier,
        config: Config,

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

        // Stats
        ticks_total: u64 = 0,
        applied_total: u64 = 0,

        const max_batch_jobs = rpc.MAX_BATCH_JOBS;
        const max_frames: u32 = 256;
        const max_completions: u32 = 256;

        // ====================================================================
        // Config
        // ====================================================================

        pub const Config = struct {
            clock_fn: *const fn () i64,
            batch_max: u32 = 256,
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
        };

        const RecvCompaction = struct {
            conn_id: u16,
            consumed: u32,
        };

        // ====================================================================
        // Lifecycle
        // ====================================================================

        pub fn init(
            io_backend: *IoBackend,
            handler: *OpHandler,
            stores: []kv.Store,
            oplog: *oplog_mod.Log,
            notify: *QueueNotifier,
            config: Config,
        ) Self {
            return .{
                .io = io_backend,
                .handler = handler,
                .stores = stores,
                .oplog = oplog,
                .notify = notify,
                .config = config,
            };
        }

        // ====================================================================
        // Tick — the entire event loop body
        // ====================================================================

        pub fn tick(self: *Self) void {
            // 1. Drain IO completions
            const n = self.io.drain(&self.completions);

            // 2. Process completions — collect unique recv conn_ids
            self.frame_count = 0;
            self.recv_compaction_count = 0;

            var recv_conns: [max_completions]u16 = undefined;
            var recv_conn_count: u32 = 0;

            for (self.completions[0..n]) |completion| {
                switch (completion.event) {
                    .recv => {
                        // Deduplicate: only process each conn once per tick
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
                    .accept => self.io.queueAccept(),
                    .closed => {},
                    .send_done => self.io.queueRecv(completion.conn_id),
                }
            }

            for (recv_conns[0..recv_conn_count]) |conn_id| {
                self.extractFrames(conn_id);
            }

            if (self.frame_count == 0) {
                self.io.submit();
                self.ticks_total += 1;
                return;
            }

            // 3. Execute: decode + apply in single kv.Batch
            self.executeBatch();

            // 4. Encode responses into send_bufs, queue sends
            self.encodeResponses();

            // 5. Compact recv_bufs (payload slices no longer needed)
            self.compactRecvBufs();

            // 6. Submit all queued IO
            self.io.submit();
            self.ticks_total += 1;
        }

        // ====================================================================
        // Frame extraction — parse RPC frames from recv_bufs
        // ====================================================================

        fn extractFrames(self: *Self, conn_id: u16) void {
            const c = self.io.conn(conn_id);
            if (c.phase == .free) return;

            var pos: u32 = 0;
            const data_end = c.recv_pos;

            while (pos + @as(u32, rpc.FRAME_HEADER_SIZE) <= data_end) {
                const hdr = rpc.readFrameHeader(c.recv_buf[pos..data_end]) orelse break;

                if (hdr.payload_len > rpc.MAX_PAYLOAD_SIZE) {
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

            // Record compaction (deferred until after execute+encode)
            if (pos > 0) {
                assert.check(
                    self.recv_compaction_count < max_completions,
                    "pipeline: recv_compaction overflow",
                    .{},
                );
                self.recv_compactions[self.recv_compaction_count] = .{
                    .conn_id = conn_id,
                    .consumed = pos,
                };
                self.recv_compaction_count += 1;
            }
        }

        // ====================================================================
        // Execute — decode + apply in a single kv.Batch
        // ====================================================================

        fn executeBatch(self: *Self) void {
            var kv_batch = self.stores[0].newBatch();
            defer kv_batch.close();

            for (self.frames[0..self.frame_count], 0..) |*frame, i| {
                self.results[i] = self.decodeAndApply(&kv_batch, frame);
            }

            kv_batch.commit();
            self.applied_total += self.frame_count;

            // Post-commit: notify queue waiters
            for (self.frames[0..self.frame_count], 0..) |frame, i| {
                self.notifyForFrame(&frame, &self.results[i]);
            }
        }

        fn decodeAndApply(self: *Self, batch: *kv.WriteBatch, frame: *FrameDesc) ops_mod.OpResult {
            switch (frame.msg_type) {
                rpc.MSG_PING => return .{},

                rpc.MSG_ENQUEUE_BATCH => {
                    var reader = BufReader{ .data = frame.payload };
                    const now_ns = self.nowNs();
                    const parsed = rpc.parseEnqueue(&reader, &self.jobs_buf, now_ns) catch
                        return .{ .err = "parse error" };
                    frame.count = parsed.count;
                    const op_data = ops_mod.OpData{ .enqueue = parsed.op };
                    return self.handler.apply(batch, .enqueue, &op_data);
                },

                rpc.MSG_ACK_BATCH => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.parseAck(&reader, &self.acks_buf) catch
                        return .{ .err = "parse error" };
                    frame.count = parsed.count;
                    var op = parsed.op;
                    op.now_ns = self.nowNs();
                    const op_data = ops_mod.OpData{ .ack = op };
                    return self.handler.apply(batch, .ack, &op_data);
                },

                rpc.MSG_FAIL_BATCH => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.parseFail(&reader, &self.fails_buf) catch
                        return .{ .err = "parse error" };
                    frame.count = parsed.count;
                    var op = parsed.op;
                    op.now_ns = self.nowNs();
                    const op_data = ops_mod.OpData{ .fail = op };
                    return self.handler.apply(batch, .fail, &op_data);
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
                    return self.handler.apply(batch, .heartbeat, &op_data);
                },

                rpc.MSG_FETCH_BATCH => {
                    var reader = BufReader{ .data = frame.payload };
                    const sub = rpc.parseFetchSubscribe(&reader) catch
                        return .{ .err = "parse error" };
                    const now_ns = self.nowNs();
                    var queue_slices: [16][]const u8 = undefined;
                    for (0..sub.queue_count) |i| {
                        queue_slices[i] = sub.queues[i];
                    }
                    const op_data = ops_mod.OpData{ .fetch = .{
                        .queues = queue_slices[0..sub.queue_count],
                        .worker_id = sub.worker_id,
                        .lease_duration_ms = sub.lease_ms,
                        .count = sub.credits,
                        .now_ns = now_ns,
                    } };
                    return self.handler.apply(batch, .fetch, &op_data);
                },

                rpc.MSG_MAINTENANCE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.management.parseMaintenance(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .maintenance = parsed };
                    return self.handler.apply(batch, .maintenance, &op_data);
                },

                rpc.MSG_QUEUE_CONFIG => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.management.parseQueueConfig(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .queue_config = parsed };
                    return self.handler.apply(batch, .queue_config, &op_data);
                },

                rpc.MSG_CLEAR_QUEUE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.management.parseClearQueue(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .clear_queue = parsed };
                    return self.handler.apply(batch, .clear_queue, &op_data);
                },

                rpc.MSG_DELETE_QUEUE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.management.parseDeleteQueue(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .delete_queue = parsed };
                    return self.handler.apply(batch, .delete_queue, &op_data);
                },

                rpc.MSG_BULK_ACTION => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.bulk.parseBulkAction(&reader, &self.bulk_ids_buf) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .bulk_action = parsed };
                    return self.handler.apply(batch, .bulk_action, &op_data);
                },

                rpc.MSG_BATCH_CREATE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.batch.parseBatchCreate(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .batch_create = parsed };
                    return self.handler.apply(batch, .batch_create, &op_data);
                },

                rpc.MSG_BATCH_SEAL => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.batch.parseBatchSeal(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .batch_seal = parsed };
                    return self.handler.apply(batch, .batch_seal, &op_data);
                },

                rpc.MSG_CRON_CREATE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.cron.parseCronCreate(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .cron_create = parsed };
                    return self.handler.apply(batch, .cron_create, &op_data);
                },

                rpc.MSG_CRON_UPDATE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.cron.parseCronUpdate(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .cron_update = parsed };
                    return self.handler.apply(batch, .cron_update, &op_data);
                },

                rpc.MSG_CRON_DELETE => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.cron.parseCronDelete(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .cron_delete = parsed };
                    return self.handler.apply(batch, .cron_delete, &op_data);
                },

                rpc.MSG_CRON_TRIGGER => {
                    var reader = BufReader{ .data = frame.payload };
                    const parsed = rpc.cron.parseCronTrigger(&reader) catch
                        return .{ .err = "parse error" };
                    const op_data = ops_mod.OpData{ .cron_trigger = parsed };
                    return self.handler.apply(batch, .cron_trigger, &op_data);
                },

                else => return .{ .err = "unknown message type" },
            }
        }

        // ====================================================================
        // Encode — write responses into send_bufs
        // ====================================================================

        fn encodeResponses(self: *Self) void {
            // Track which connections have response data to send.
            var send_conns: [max_frames]u16 = undefined;
            var send_conn_count: u32 = 0;

            for (self.frames[0..self.frame_count], 0..) |frame, i| {
                const c = self.io.conn(frame.conn_id);
                if (c.phase == .free) continue;

                const resp_type = switch (frame.msg_type) {
                    rpc.MSG_PING => rpc.MSG_PONG,
                    else => rpc.responseType(frame.msg_type) orelse continue,
                };

                // Track first write to this conn
                if (c.send_len == 0) {
                    send_conns[send_conn_count] = frame.conn_id;
                    send_conn_count += 1;
                }

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

            // Queue one send per connection with accumulated data
            for (send_conns[0..send_conn_count]) |conn_id| {
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
                        }
                    } else {
                        var reader = BufReader{ .data = frame.payload };
                        const parsed = rpc.parseFail(&reader, &self.fails_buf) catch return;
                        for (parsed.op.jobs) |job| {
                            self.notify.notify(job.queue);
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
                                // We don't know which queues were affected.
                                // The old code used notifyFromOp which checks result.notify_queues.
                                if (result.notify_queues) |queues| {
                                    self.notify.notifyQueues(queues);
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
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
        // Helpers
        // ====================================================================

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

    /// Initialize in-place: allocates DB/handler/backend, then wires pipeline.
    /// Must be called on an already-placed struct (e.g., `var ctx: TestContext = undefined;`).
    fn init(self: *TestContext, db_path: [*:0]const u8) !void {
        const allocator = testing.allocator;

        @atomicStore(i64, &test_clock_ns, 1_000_000_000_000, .monotonic);

        const path_slice = std.mem.span(db_path);
        std.fs.cwd().deleteTree(path_slice) catch {};
        const db = try talon.DB.open(allocator, path_slice, .{ .sync = false });

        self.db = db;
        self.stores = [1]kv.Store{kv.Store.init(db)};
        self.handler = OpHandler.init(allocator);
        self.handler.rebuildState(&self.stores);
        self.oplog = oplog_mod.Log.init(allocator, .{ .now_fn = &testClockFn }, null);
        self.notify = QueueNotifier.init(allocator);
        self.backend = try SimBackend.init(allocator, .{
            .listen_fd = -1,
            .max_conns = 16,
            .recv_buf_size = 65536,
            .send_buf_size = 65536,
        });
        self.db_path = db_path;

        // Wire pipeline with stable pointers (self is already at final location)
        self.pipeline = TestPipeline.init(
            &self.backend,
            &self.handler,
            &self.stores,
            &self.oplog,
            &self.notify,
            .{ .clock_fn = &testClockFn },
        );
    }

    fn deinit(self: *TestContext) void {
        const allocator = testing.allocator;
        self.backend.deinit(allocator);
        self.handler.deinit();
        self.notify.deinit();
        self.oplog.deinit();
        self.db.close();
        const path_slice = std.mem.span(self.db_path);
        std.fs.cwd().deleteTree(path_slice) catch {};
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
};

test "ping/pong round-trip" {
    var ctx: TestContext = undefined;
    try ctx.init("/tmp/corvo-pv2-ping");
    defer ctx.deinit();

    const conn_id = ctx.backend.connect().?;
    ctx.injectFrame(conn_id, rpc.MSG_PING, 42, "");

    ctx.pipeline.tick();

    const resp = ctx.readResponse(conn_id).?;
    try testing.expectEqual(rpc.MSG_PONG, resp.header.msg_type);
    try testing.expectEqual(@as(u32, 42), resp.header.req_id);
    try testing.expectEqual(@as(u32, 0), resp.header.payload_len);
}

test "enqueue round-trip" {
    var ctx: TestContext = undefined;
    try ctx.init("/tmp/corvo-pv2-enqueue");
    defer ctx.deinit();

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
    var ctx: TestContext = undefined;
    try ctx.init("/tmp/corvo-pv2-multi");
    defer ctx.deinit();

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
    var ctx: TestContext = undefined;
    try ctx.init("/tmp/corvo-pv2-fetch");
    defer ctx.deinit();

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
    var ctx: TestContext = undefined;
    try ctx.init("/tmp/corvo-pv2-partial");
    defer ctx.deinit();

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
    var ctx: TestContext = undefined;
    try ctx.init("/tmp/corvo-pv2-compact");
    defer ctx.deinit();

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
