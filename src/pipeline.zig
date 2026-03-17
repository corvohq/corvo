//! Pipeline — async apply pipeline with MPSC batching.
//!
//! Ported from Go internal/engine/node.go.
//! Multiple producer threads submit ops via submit().
//! Single consumer thread (applyLoop) batches and executes.
//! Per-request completion signaling via ResetEvent.

const std = @import("std");
const ops_mod = @import("ops.zig");
const kv = @import("kv.zig");
const handler_mod = @import("handler.zig");
const oplog_mod = @import("oplog.zig");
const notify_mod = @import("notify.zig");
const shard_mod = @import("shard.zig");
const assert = @import("assert.zig");

const OpHandler = handler_mod.OpHandler;
const QueueNotifier = notify_mod.QueueNotifier;

// ============================================================================
// Config
// ============================================================================

/// Hook called after pipeline commits + oplog append with encoded mutations.
/// Used by cluster mode to replicate to followers.
pub const ReplHook = struct {
    ptr: *anyopaque,
    replFn: *const fn (ptr: *anyopaque, shard_id: u16, seq: u64, data: []const u8) void,
    waitFn: ?*const fn (ptr: *anyopaque, seq: u64) void = null,

    pub fn replicate(self: ReplHook, shard_id: u16, seq: u64, data: []const u8) void {
        self.replFn(self.ptr, shard_id, seq, data);
    }

    /// Block until at least one follower has acked the given sequence.
    pub fn waitForAck(self: ReplHook, seq: u64) void {
        if (self.waitFn) |wfn| wfn(self.ptr, seq);
    }
};

pub const Durability = enum {
    /// Ack client after local commit only. Follower replication is async.
    /// Fastest. Data loss if leader dies before follower catches up.
    eventual,
    /// Ack client only after at least one follower confirms the write.
    /// Safest. Higher latency (network round-trip per batch).
    strong,
    /// Ack client after local commit. Wait for previous batch's follower
    /// ack before committing the next batch. Same durability as strong
    /// (at most 1 batch of unacked writes) but overlaps network with local work.
    /// Best balance of safety and throughput.
    strong_pipelined,
};

pub const Config = struct {
    /// Max ops per batch before force-flush.
    batch_max: u32 = 1024,
    /// Max ops per sub-batch execution.
    sub_batch_max: u32 = 64,
    /// Channel buffer size (max pending requests).
    max_pending: u32 = 16384,
    /// Initial wait for batch accumulation (ns).
    min_wait_ns: u64 = 50_000, // 50µs
    /// Max batch accumulation window (ns).
    max_window_ns: u64 = 8_000_000, // 8ms
    /// Threshold to extend deadline from min_wait to max_window.
    extend_at: u32 = 64,
    /// Replication hook — called after oplog append with encoded mutations.
    repl_hook: ?ReplHook = null,
    /// Replication durability mode.
    durability: Durability = .strong_pipelined,
};

// ============================================================================
// Request — lives on caller's stack
// ============================================================================

pub const Request = struct {
    op_type: ops_mod.OpType,
    data: ops_mod.OpData,
    result: ops_mod.OpResult = .{},
    event: std.Thread.ResetEvent = .{},
};

// ============================================================================
// MPSC Request Queue (bounded, mutex-based)
// ============================================================================

const RequestQueue = struct {
    buf: []*Request,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    capacity: usize,
    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    closed: bool = false,

    fn init(allocator: std.mem.Allocator, capacity: usize) !RequestQueue {
        const buf = try allocator.alloc(*Request, capacity);
        return .{
            .buf = buf,
            .capacity = capacity,
        };
    }

    fn deinit(self: *RequestQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
    }

    /// Push a request. Returns false if queue is full (overloaded) or closed.
    fn push(self: *RequestQueue, req: *Request) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) return false;
        if (self.count >= self.capacity) return false;
        self.buf[self.tail] = req;
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
        self.not_empty.signal();
        return true;
    }

    /// Wait for at least one request, then drain up to out.len.
    /// Returns 0 if closed and empty.
    fn waitAndDrain(self: *RequestQueue, out: []*Request, timeout_ns: u64) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count == 0 and !self.closed) {
            self.not_empty.timedWait(&self.mutex, timeout_ns) catch {
                // Timeout — return 0 so caller can check running flag
                return 0;
            };
        }

        if (self.count == 0) return 0;

        const n = @min(self.count, out.len);
        for (0..n) |i| {
            out[i] = self.buf[self.head];
            self.head = (self.head + 1) % self.capacity;
        }
        self.count -= n;
        return n;
    }

    /// Non-blocking drain of available requests.
    fn drain(self: *RequestQueue, out: []*Request) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const n = @min(self.count, out.len);
        for (0..n) |i| {
            out[i] = self.buf[self.head];
            self.head = (self.head + 1) % self.capacity;
        }
        self.count -= n;
        return n;
    }

    fn close(self: *RequestQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.not_empty.broadcast();
    }

    fn pendingCount(self: *RequestQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }
};

// ============================================================================
// Ack tracking — non-blocking follower ack for strong durability
// ============================================================================

const ack_ring_size = 4096;

const AckEntry = struct {
    seq: u64 = 0,
    // Pointers to requests that need signaling when this seq is acked.
    // We store start/end indices into the sub-batch that produced this seq.
    requests: [64]*Request = undefined,
    count: u32 = 0,
};

// ============================================================================
// Pipeline
// ============================================================================

pub const Pipeline = struct {
    config: Config,
    queue: RequestQueue,
    handler: *OpHandler,
    shards: []kv.Store,
    oplog: *oplog_mod.Log,
    notify: *QueueNotifier,
    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    allocator: std.mem.Allocator,

    // Pre-allocated mutation list for per-sub-batch oplog recording.
    mut_list: std.ArrayList(kv.Mutation) = .{},
    // Accumulated mutations across all sub-batches for batch-level replication.
    batch_mut_list: std.ArrayList(kv.Mutation) = .{},

    // --- Non-blocking ack tracking for strong durability ---
    // Requests waiting for follower ack before being signaled to callers.
    // Ring buffer of (seq, requests) pairs. When ack arrives for seq N,
    // all entries with seq <= N are drained and their events signaled.
    ack_ring: [ack_ring_size]AckEntry = [_]AckEntry{.{}} ** ack_ring_size,
    ack_head: usize = 0, // read position (oldest unacked)
    ack_tail: usize = 0, // write position (next free slot)
    ack_count: usize = 0,
    ack_mu: std.Thread.Mutex = .{},
    ack_cond: std.Thread.Condition = .{}, // signaled when ack arrives

    // Last acked sequence from followers (updated by ack callback).
    last_acked_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Stats
    applied_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overload_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    batch_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(
        allocator: std.mem.Allocator,
        handler: *OpHandler,
        shards: []kv.Store,
        oplog: *oplog_mod.Log,
        notify: *QueueNotifier,
        config: Config,
    ) !Pipeline {
        return .{
            .config = config,
            .queue = try RequestQueue.init(allocator, config.max_pending),
            .handler = handler,
            .shards = shards,
            .oplog = oplog,
            .notify = notify,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.stop();
        self.queue.deinit(self.allocator);
        self.mut_list.deinit(self.allocator);
        self.batch_mut_list.deinit(self.allocator);
    }

    pub fn start(self: *Pipeline) !void {
        if (self.running.load(.monotonic)) return;
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, applyLoop, .{self});
    }

    pub fn stop(self: *Pipeline) void {
        if (!self.running.load(.monotonic)) return;
        self.running.store(false, .monotonic);
        self.queue.close();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        // Signal any remaining pending ack entries so callers don't block forever.
        self.ack_mu.lock();
        defer self.ack_mu.unlock();
        while (self.ack_count > 0) {
            const entry = &self.ack_ring[self.ack_head];
            for (0..entry.count) |i| entry.requests[i].event.set();
            entry.count = 0;
            self.ack_head = (self.ack_head + 1) % ack_ring_size;
            self.ack_count -= 1;
        }
    }

    /// Submit an operation and block until the result is ready.
    /// Thread-safe — multiple threads can submit concurrently.
    pub fn submit(self: *Pipeline, op_type: ops_mod.OpType, data: *const ops_mod.OpData) ops_mod.OpResult {
        var req = Request{
            .op_type = op_type,
            .data = data.*,
        };

        if (!self.queue.push(&req)) {
            _ = self.overload_total.fetchAdd(1, .monotonic);
            return .{ .err = "pipeline overloaded" };
        }

        // Block until apply loop processes this request.
        req.event.wait();
        return req.result;
    }

    // ========================================================================
    // Apply loop (runs in background thread)
    // ========================================================================

    fn applyLoop(self: *Pipeline) void {
        const batch_max: usize = @min(self.config.batch_max, 1024);
        const sub_batch_max: usize = self.config.sub_batch_max;

        // Pre-allocate batch buffer on stack.
        var batch_buf: [1024]*Request = undefined;

        while (self.running.load(.monotonic) or self.queue.pendingCount() > 0) {
            // Double-buffered drain: try non-blocking drain first.
            // This picks up requests that accumulated during the previous
            // batch execution, avoiding the blocking wait overhead.
            var batch_size = self.queue.drain(batch_buf[0..batch_max]);

            if (batch_size == 0) {
                // Queue empty — block until work arrives.
                batch_size = self.queue.waitAndDrain(
                    batch_buf[0..batch_max],
                    100_000_000, // 100ms
                );
                if (batch_size == 0) continue;
            }

            // Adaptive spin-accumulate: only when batch is small and we
            // haven't already collected a full batch from the drain above.
            if (batch_size < batch_max) {
                const deadline_ns: u64 = if (batch_size >= self.config.extend_at)
                    self.config.max_window_ns
                else
                    self.config.min_wait_ns;
                var spin_timer = std.time.Timer.start() catch unreachable;
                while (batch_size < batch_max and spin_timer.read() < deadline_ns) {
                    const more = self.queue.drain(batch_buf[batch_size..batch_max]);
                    if (more > 0) {
                        batch_size += more;
                    } else {
                        std.Thread.sleep(1_000); // 1µs
                    }
                }
            }

            if (self.config.repl_hook != null) {
                // Cluster mode: apply sub-batches, encode overlay directly
                // from Talon's arena (zero-copy), replicate once.
                var repl_buf: [4 * 1024 * 1024]u8 = undefined;
                var repl_pos: usize = 4; // reserve 4 bytes for count header
                var total_mutations: u32 = 0;

                var offset: usize = 0;
                while (offset < batch_size) {
                    const end = @min(offset + sub_batch_max, batch_size);
                    const r = self.executeSubBatchLocal(batch_buf[offset..end], repl_buf[repl_pos..]);
                    repl_pos += r.len;
                    total_mutations += r.count;
                    offset = end;
                }

                // Write count header at the start.
                std.mem.writeInt(u32, repl_buf[0..4], total_mutations, .little);

                // Notify queue waiters.
                for (batch_buf[0..batch_size]) |req| {
                    notify_mod.notifyFromOp(self.notify, req.op_type, &req.data);
                }

                // Replicate encoded overlay in one message.
                if (total_mutations > 0) {
                    const seq = self.oplog.append(0, repl_buf[0..repl_pos]);
                    self.config.repl_hook.?.replicate(0, seq, repl_buf[0..repl_pos]);

                    if (self.config.durability != .eventual) {
                        self.pushAckPending(seq, batch_buf[0..batch_size]);
                    } else {
                        for (batch_buf[0..batch_size]) |req| req.event.set();
                    }
                } else {
                    for (batch_buf[0..batch_size]) |req| req.event.set();
                }
            } else {
                // Single-node: use original optimized path.
                var offset: usize = 0;
                while (offset < batch_size) {
                    const end = @min(offset + sub_batch_max, batch_size);
                    self.executeSubBatch(batch_buf[offset..end]);
                    offset = end;
                }
            }

            _ = self.applied_total.fetchAdd(batch_size, .monotonic);
            _ = self.batch_count.fetchAdd(1, .monotonic);
        }
    }

    /// Apply a sub-batch to KV only — no replication, no signaling.
    /// If encode_buf is provided, encodes the overlay directly into it BEFORE
    /// commit (zero-copy from Talon's arena). Returns encoded slice length.
    /// Apply sub-batch to KV. If encode_buf provided, encodes overlay
    /// directly from Talon's arena BEFORE commit (zero-copy).
    /// Returns (bytes_written, mutation_count).
    const EncodeResult = struct { len: usize = 0, count: u32 = 0 };

    fn executeSubBatchLocal(self: *Pipeline, batch: []*Request, encode_buf: ?[]u8) EncodeResult {
        var kv_batch = self.shards[0].newBatch();
        defer kv_batch.close();

        for (batch, 0..) |req, i| {
            req.result = self.handler.apply(&kv_batch, req.op_type, &req.data);
            if (i % 64 == 63) kv_batch.sortOverlay();
        }

        var result = EncodeResult{};
        if (encode_buf) |buf| {
            const r = kv_batch.encodeOverlay(buf);
            result.len = r.len;
            result.count = r.count;
        }

        kv_batch.commit();
        return result;
    }

    /// Single-node path: apply, commit, notify, signal. No replication overhead.
    fn executeSubBatch(self: *Pipeline, batch: []*Request) void {
        if (self.shards.len <= 1) {
            self.executeSubBatchSingleShard(batch, 0);
        } else {
            self.executeSubBatchRouted(batch);
        }

        for (batch) |req| {
            notify_mod.notifyFromOp(self.notify, req.op_type, &req.data);
            req.event.set();
        }
    }

    /// Fast path: all ops go to one shard in a single KV batch.
    fn executeSubBatchSingleShard(self: *Pipeline, batch: []*Request, shard_idx: u16) void {
        var kv_batch = self.shards[shard_idx].newBatch();
        defer kv_batch.close();

        const has_oplog = self.oplog.hasFile();

        if (has_oplog) {
            self.mut_list.clearRetainingCapacity();
            kv_batch.enableRecording(self.allocator, &self.mut_list);
        }
        defer if (has_oplog) kv_batch.freeMutations();

        for (batch, 0..) |req, i| {
            req.result = self.handler.apply(&kv_batch, req.op_type, &req.data);
            // Sort overlay periodically so subsequent batch reads use
            // binary search (O(log n)) instead of linear scan through
            // the unsorted tail.
            if (i % 64 == 63) kv_batch.sortOverlay();
        }

        kv_batch.commit();

        if (has_oplog and self.mut_list.items.len > 0) {
            const encoded = oplog_mod.encodeMutations(self.allocator, self.mut_list.items);
            defer self.allocator.free(encoded);
            const seq = self.oplog.append(shard_idx, encoded);

            // Send to followers (non-blocking). Ack handling is in onFollowerAck.
            if (self.config.repl_hook) |hook| {
                hook.replicate(shard_idx, seq, encoded);
            }
        }
    }

    /// Multi-shard path: route each op to the correct shard, group by shard,
    /// apply each group in its own KV batch.
    fn executeSubBatchRouted(self: *Pipeline, batch: []*Request) void {
        const shard_count: u16 = @intCast(self.shards.len);

        // Check if all ops route to the same shard (common case).
        var first_shard: ?u16 = null;
        var all_same = true;
        for (batch) |req| {
            const route = shard_mod.classifyRoute(shard_count, req.op_type, &req.data);
            const idx = switch (route.mode) {
                .single_shard => route.shard_idx,
                .global => @as(u16, 0),
                .broadcast, .multi_shard => blk: {
                    all_same = false;
                    break :blk route.shard_idx;
                },
            };
            if (first_shard == null) {
                first_shard = idx;
            } else if (idx != first_shard.?) {
                all_same = false;
            }
        }

        // Fast path: all ops target the same shard.
        if (all_same) {
            self.executeSubBatchSingleShard(batch, first_shard orelse 0);
            return;
        }

        // Slow path: per-op apply with individual routing.
        for (batch) |req| {
            const route = shard_mod.classifyRoute(shard_count, req.op_type, &req.data);
            switch (route.mode) {
                .single_shard, .global, .multi_shard => {
                    self.applySingleOp(req, route.shard_idx);
                },
                .broadcast => {
                    // Apply to every shard; keep last result.
                    for (0..shard_count) |s| {
                        req.result = self.applySingleOpInner(req.op_type, &req.data, @intCast(s));
                        if (req.result.err != null) break;
                    }
                },
            }
        }
    }

    /// Apply a single request to a specific shard.
    fn applySingleOp(self: *Pipeline, req: *Request, shard_idx: u16) void {
        req.result = self.applySingleOpInner(req.op_type, &req.data, shard_idx);
    }

    fn applySingleOpInner(self: *Pipeline, op_type: ops_mod.OpType, data: *const ops_mod.OpData, shard_idx: u16) ops_mod.OpResult {
        var kv_batch = self.shards[shard_idx].newBatch();
        defer kv_batch.close();

        const has_oplog = self.oplog.hasFile();

        if (has_oplog) {
            self.mut_list.clearRetainingCapacity();
            kv_batch.enableRecording(self.allocator, &self.mut_list);
        }
        defer if (has_oplog) kv_batch.freeMutations();

        const result = self.handler.apply(&kv_batch, op_type, data);
        kv_batch.commit();

        if (has_oplog and self.mut_list.items.len > 0) {
            const encoded = oplog_mod.encodeMutations(self.allocator, self.mut_list.items);
            defer self.allocator.free(encoded);
            const seq = self.oplog.append(shard_idx, encoded);

            if (self.config.repl_hook) |hook| {
                hook.replicate(shard_idx, seq, encoded);
            }
        }

        return result;
    }

    // ========================================================================
    // Non-blocking ack tracking
    // ========================================================================

    /// Push requests to the ack-pending ring. Called from pipeline thread.
    fn pushAckPending(self: *Pipeline, seq: u64, requests: []*Request) void {
        self.ack_mu.lock();
        defer self.ack_mu.unlock();

        // Check for acks that already arrived while we were applying.
        const already_acked = self.last_acked_seq.load(.acquire);
        if (already_acked >= seq) {
            // Follower already acked this — signal immediately.
            for (requests) |req| req.event.set();
            return;
        }

        if (self.ack_count >= ack_ring_size) {
            // Ring full — fallback to synchronous signal (shouldn't happen in practice).
            for (requests) |req| req.event.set();
            return;
        }

        var entry = &self.ack_ring[self.ack_tail];
        entry.seq = seq;
        entry.count = @intCast(@min(requests.len, 64));
        for (0..entry.count) |i| {
            entry.requests[i] = requests[i];
        }
        // Signal overflow requests immediately if > 64 per batch.
        for (requests[entry.count..]) |req| req.event.set();

        self.ack_tail = (self.ack_tail + 1) % ack_ring_size;
        self.ack_count += 1;
    }

    /// Called when a follower acks a sequence number. Thread-safe —
    /// called from the TCP receive thread or tick loop.
    /// Drains all pending entries with seq <= acked_seq and signals their requests.
    pub fn onFollowerAck(self: *Pipeline, acked_seq: u64) void {
        // Update the atomic so pushAckPending can fast-path.
        const prev = self.last_acked_seq.load(.monotonic);
        if (acked_seq > prev) {
            self.last_acked_seq.store(acked_seq, .release);
        }

        self.ack_mu.lock();
        defer self.ack_mu.unlock();

        while (self.ack_count > 0) {
            const entry = &self.ack_ring[self.ack_head];
            if (entry.seq > acked_seq) break;

            // Signal all requests in this entry.
            for (0..entry.count) |i| {
                entry.requests[i].event.set();
            }
            entry.count = 0;

            self.ack_head = (self.ack_head + 1) % ack_ring_size;
            self.ack_count -= 1;
        }
    }

    // ========================================================================
    // Stats
    // ========================================================================

    pub fn getAppliedTotal(self: *const Pipeline) u64 {
        return self.applied_total.load(.monotonic);
    }

    pub fn getOverloadTotal(self: *const Pipeline) u64 {
        return self.overload_total.load(.monotonic);
    }

    pub fn getBatchCount(self: *const Pipeline) u64 {
        return self.batch_count.load(.monotonic);
    }
};
