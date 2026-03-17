//! Corvo benchmark — measures enqueue, lifecycle throughput.
//!
//! Matches Go benchmark parameters:
//!   jobs=100000, concurrency=8, batch=64, queue=bench.q
//!
//! Modes:
//!   1. Direct (single-threaded, manual batching — raw engine throughput)
//!   2. Pipeline (multi-threaded, async pipeline — production-like)
//!   3. 3-node cluster (leader + 2 followers, oplog replication)
//!
//! Run: zig build bench -Doptimize=ReleaseFast

const std = @import("std");
const talon = @import("talon");
const corvo = @import("corvo");
const types = corvo.types;
const ops = corvo.ops;
const kv = corvo.kv;
const engine_mod = corvo.engine;
const oplog_mod = corvo.oplog;
const handler_mod = corvo.handler;
const cluster_sim = corvo.cluster_sim;

const Timer = std.time.Timer;

// ============================================================================
// Config — matches Go benchmark defaults
// ============================================================================

const jobs: u32 = 100_000;
const concurrency: u32 = 8;
const batch_size: u32 = 64;
const queue_name = "bench.q";
const db_path = "/tmp/corvo-bench";

// ============================================================================
// Clock
// ============================================================================

var bench_clock_ns: i64 = 1_000_000_000_000;

fn benchClockFn() i64 {
    return @atomicLoad(i64, &bench_clock_ns, .monotonic);
}

fn advanceClock(delta_ns: i64) void {
    _ = @atomicRmw(i64, &bench_clock_ns, .Add, delta_ns, .monotonic);
}

fn resetClock() void {
    @atomicStore(i64, &bench_clock_ns, 1_000_000_000_000, .monotonic);
}

// ============================================================================
// Engine setup helper
// ============================================================================

fn openEngine(allocator: std.mem.Allocator, stores: *[1]kv.Store) !struct { db: *talon.DB, engine: engine_mod.Engine } {
    std.fs.cwd().deleteTree(db_path) catch {};
    const db = try talon.DB.open(allocator, db_path, .{ .sync = false });
    stores[0] = kv.Store.init(db);
    return .{
        .db = db,
        .engine = engine_mod.Engine.init(allocator, stores, .{
            .clock_fn = &benchClockFn,
            .talon_sync = false,
        }),
    };
}

fn closeEngine(db: *talon.DB, engine: *engine_mod.Engine) void {
    engine.deinit();
    db.close();
    std.fs.cwd().deleteTree(db_path) catch {};
}

// ============================================================================
// Direct enqueue (single-threaded, batched)
// ============================================================================

fn benchEnqueueDirect(engine: *engine_mod.Engine, count: u32) u64 {
    var op_buf: [batch_size]ops.OpInput = undefined;
    var job_bufs: [batch_size][1]ops.EnqueueJob = undefined;
    var id_bufs: [batch_size][64]u8 = undefined;

    var timer = Timer.start() catch unreachable;

    var i: u32 = 0;
    while (i < count) {
        const bs: u32 = @min(batch_size, count - i);

        for (0..bs) |b| {
            const idx = i + @as(u32, @intCast(b));
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);

            const id = std.fmt.bufPrint(&id_bufs[b], "j-{d}", .{idx}) catch unreachable;
            job_bufs[b] = [1]ops.EnqueueJob{.{
                .job_id = id,
                .queue = queue_name,
                .priority = types.priority_default,
                .max_retries = 3,
                .created_at_ns = now_ns,
            }};
            op_buf[b] = .{
                .op_type = .enqueue,
                .data = .{ .enqueue = .{ .jobs = &job_bufs[b], .now_ns = now_ns } },
            };
        }
        _ = engine.applyBatch(op_buf[0..bs]);
        i += bs;
    }

    return timer.read();
}

// ============================================================================
// Direct fetch (pre-enqueue, then time fetch only)
// ============================================================================

fn benchFetchDirect(engine: *engine_mod.Engine, count: u32) u64 {
    var op_buf: [batch_size]ops.OpInput = undefined;
    var job_bufs: [batch_size][1]ops.EnqueueJob = undefined;
    var id_bufs: [batch_size][64]u8 = undefined;

    // Pre-enqueue all jobs (not timed)
    var i: u32 = 0;
    while (i < count) {
        const bs: u32 = @min(batch_size, count - i);
        for (0..bs) |b| {
            const idx = i + @as(u32, @intCast(b));
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);
            const id = std.fmt.bufPrint(&id_bufs[b], "f-{d}", .{idx}) catch unreachable;
            job_bufs[b] = [1]ops.EnqueueJob{.{
                .job_id = id,
                .queue = queue_name,
                .priority = types.priority_default,
                .max_retries = 3,
                .created_at_ns = now_ns,
            }};
            op_buf[b] = .{
                .op_type = .enqueue,
                .data = .{ .enqueue = .{ .jobs = &job_bufs[b], .now_ns = now_ns } },
            };
        }
        _ = engine.applyBatch(op_buf[0..bs]);
        i += bs;
    }

    // Time fetch only
    var timer = Timer.start() catch unreachable;

    i = 0;
    while (i < count) {
        const bs: u32 = @min(batch_size, count - i);
        var fetch_queue_slices: [batch_size][1][]const u8 = undefined;
        for (0..bs) |b| {
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);
            fetch_queue_slices[b] = [1][]const u8{queue_name};
            op_buf[b] = .{
                .op_type = .fetch,
                .data = .{ .fetch = .{
                    .queues = &fetch_queue_slices[b],
                    .worker_id = "bench-worker",
                    .count = 1,
                    .now_ns = now_ns,
                    .lease_duration_ms = 30000,
                } },
            };
        }
        _ = engine.applyBatch(op_buf[0..bs]);
        i += bs;
    }

    return timer.read();
}

// ============================================================================
// Direct ack (pre-enqueue + pre-fetch, then time ack only)
// ============================================================================

fn benchAckDirect(engine: *engine_mod.Engine, count: u32) u64 {
    var op_buf: [batch_size]ops.OpInput = undefined;
    var job_bufs: [batch_size][1]ops.EnqueueJob = undefined;
    var id_bufs: [batch_size][64]u8 = undefined;

    // Pre-enqueue all jobs (not timed)
    var i: u32 = 0;
    while (i < count) {
        const bs: u32 = @min(batch_size, count - i);
        for (0..bs) |b| {
            const idx = i + @as(u32, @intCast(b));
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);
            const id = std.fmt.bufPrint(&id_bufs[b], "a-{d}", .{idx}) catch unreachable;
            job_bufs[b] = [1]ops.EnqueueJob{.{
                .job_id = id,
                .queue = queue_name,
                .priority = types.priority_default,
                .max_retries = 3,
                .created_at_ns = now_ns,
            }};
            op_buf[b] = .{
                .op_type = .enqueue,
                .data = .{ .enqueue = .{ .jobs = &job_bufs[b], .now_ns = now_ns } },
            };
        }
        _ = engine.applyBatch(op_buf[0..bs]);
        i += bs;
    }

    // Pre-fetch all jobs, collecting IDs (not timed)
    // Store all fetched IDs for ack phase
    const all_ids = std.heap.page_allocator.alloc([64]u8, count) catch unreachable;
    defer std.heap.page_allocator.free(all_ids);
    const all_id_lens = std.heap.page_allocator.alloc(u8, count) catch unreachable;
    defer std.heap.page_allocator.free(all_id_lens);
    const all_queues = std.heap.page_allocator.alloc([64]u8, count) catch unreachable;
    defer std.heap.page_allocator.free(all_queues);
    const all_queue_lens = std.heap.page_allocator.alloc(u8, count) catch unreachable;
    defer std.heap.page_allocator.free(all_queue_lens);

    var total_fetched: u32 = 0;
    i = 0;
    while (i < count) {
        const bs: u32 = @min(batch_size, count - i);
        var fetch_queue_slices: [batch_size][1][]const u8 = undefined;
        for (0..bs) |b| {
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);
            fetch_queue_slices[b] = [1][]const u8{queue_name};
            op_buf[b] = .{
                .op_type = .fetch,
                .data = .{ .fetch = .{
                    .queues = &fetch_queue_slices[b],
                    .worker_id = "bench-worker",
                    .count = 1,
                    .now_ns = now_ns,
                    .lease_duration_ms = 30000,
                } },
            };
        }
        var fetch_results: [batch_size]ops.OpResult = undefined;
        _ = engine.applyBatchCollect(op_buf[0..bs], &fetch_results);

        for (0..bs) |b| {
            if (fetch_results[b].affected > 0) {
                const f = &fetch_results[b].fetched[0];
                @memcpy(all_ids[total_fetched][0..f.id_len], f.id_buf[0..f.id_len]);
                all_id_lens[total_fetched] = f.id_len;
                @memcpy(all_queues[total_fetched][0..f.queue_len], f.queue_buf[0..f.queue_len]);
                all_queue_lens[total_fetched] = f.queue_len;
                total_fetched += 1;
            }
        }
        i += bs;
    }

    // Time ack only
    var timer = Timer.start() catch unreachable;

    i = 0;
    while (i < total_fetched) {
        const bs: u32 = @min(batch_size, total_fetched - i);
        var ack_bufs: [batch_size][1]ops.AckJob = undefined;
        for (0..bs) |b| {
            const idx = i + @as(u32, @intCast(b));
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);
            ack_bufs[b] = [1]ops.AckJob{.{
                .job_id = all_ids[idx][0..all_id_lens[idx]],
                .queue = all_queues[idx][0..all_queue_lens[idx]],
            }};
            op_buf[b] = .{
                .op_type = .ack,
                .data = .{ .ack = .{ .acks = &ack_bufs[b], .now_ns = now_ns } },
            };
        }
        _ = engine.applyBatch(op_buf[0..bs]);
        i += bs;
    }

    return timer.read();
}

// ============================================================================
// Direct lifecycle (single-threaded, batched enqueue+fetch+ack)
// ============================================================================

fn benchLifecycleDirect(engine: *engine_mod.Engine, count: u32) u64 {
    var op_buf: [batch_size]ops.OpInput = undefined;
    var job_bufs: [batch_size][1]ops.EnqueueJob = undefined;
    var id_bufs: [batch_size][64]u8 = undefined;
    var fetched_ids: [batch_size][64]u8 = undefined;
    var fetched_id_lens: [batch_size]u8 = undefined;
    var fetched_queues: [batch_size][64]u8 = undefined;
    var fetched_queue_lens: [batch_size]u8 = undefined;

    var timer = Timer.start() catch unreachable;

    var i: u32 = 0;
    while (i < count) {
        const bs: u32 = @min(batch_size, count - i);

        // --- Enqueue batch ---
        for (0..bs) |b| {
            const idx = i + @as(u32, @intCast(b));
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);

            const id = std.fmt.bufPrint(&id_bufs[b], "lc-{d}", .{idx}) catch unreachable;
            job_bufs[b] = [1]ops.EnqueueJob{.{
                .job_id = id,
                .queue = queue_name,
                .priority = types.priority_default,
                .max_retries = 3,
                .created_at_ns = now_ns,
            }};
            op_buf[b] = .{
                .op_type = .enqueue,
                .data = .{ .enqueue = .{ .jobs = &job_bufs[b], .now_ns = now_ns } },
            };
        }
        _ = engine.applyBatch(op_buf[0..bs]);

        // --- Fetch batch ---
        var fetch_queue_slices: [batch_size][1][]const u8 = undefined;
        for (0..bs) |b| {
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);
            fetch_queue_slices[b] = [1][]const u8{queue_name};
            op_buf[b] = .{
                .op_type = .fetch,
                .data = .{ .fetch = .{
                    .queues = &fetch_queue_slices[b],
                    .worker_id = "bench-worker",
                    .count = 1,
                    .now_ns = now_ns,
                    .lease_duration_ms = 30000,
                } },
            };
        }
        var fetch_results: [batch_size]ops.OpResult = undefined;
        _ = engine.applyBatchCollect(op_buf[0..bs], &fetch_results);

        var num_fetched: u32 = 0;
        for (0..bs) |b| {
            if (fetch_results[b].affected > 0) {
                const f = &fetch_results[b].fetched[0];
                @memcpy(fetched_ids[num_fetched][0..f.id_len], f.id_buf[0..f.id_len]);
                fetched_id_lens[num_fetched] = f.id_len;
                @memcpy(fetched_queues[num_fetched][0..f.queue_len], f.queue_buf[0..f.queue_len]);
                fetched_queue_lens[num_fetched] = f.queue_len;
                num_fetched += 1;
            }
        }

        // --- Ack batch ---
        var ack_bufs: [batch_size][1]ops.AckJob = undefined;
        for (0..num_fetched) |b| {
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);
            ack_bufs[b] = [1]ops.AckJob{.{
                .job_id = fetched_ids[b][0..fetched_id_lens[b]],
                .queue = fetched_queues[b][0..fetched_queue_lens[b]],
            }};
            op_buf[b] = .{
                .op_type = .ack,
                .data = .{ .ack = .{ .acks = &ack_bufs[b], .now_ns = now_ns } },
            };
        }
        if (num_fetched > 0) {
            _ = engine.applyBatch(op_buf[0..num_fetched]);
        }

        i += bs;
    }

    return timer.read();
}

// ============================================================================
// Pipeline enqueue (multi-threaded, 8 workers, batch=64 per submit)
// ============================================================================

const PipelineEnqueueCtx = struct {
    engine: *engine_mod.Engine,
    start_idx: u32,
    count: u32,
};

fn pipelineEnqueueWorker(ctx: *PipelineEnqueueCtx) void {
    var i: u32 = 0;
    while (i < ctx.count) {
        const bs: u32 = @min(batch_size, ctx.count - i);

        // Build batch of jobs for a single EnqueueOp submit.
        var job_arr: [batch_size]ops.EnqueueJob = undefined;
        var id_bufs: [batch_size][64]u8 = undefined;
        for (0..bs) |b| {
            const idx = ctx.start_idx + i + @as(u32, @intCast(b));
            const now_ns: u64 = @intCast(benchClockFn());
            advanceClock(1_000);
            const id = std.fmt.bufPrint(&id_bufs[b], "pe-{d}", .{idx}) catch unreachable;
            job_arr[b] = .{
                .job_id = id,
                .queue = queue_name,
                .priority = types.priority_default,
                .max_retries = 3,
                .created_at_ns = now_ns,
            };
        }

        const now_ns: u64 = @intCast(benchClockFn());
        const data = ops.OpData{
            .enqueue = .{ .jobs = job_arr[0..bs], .now_ns = now_ns },
        };
        _ = ctx.engine.submit(.enqueue, &data);
        i += bs;
    }
}

fn benchEnqueuePipeline(engine: *engine_mod.Engine, count: u32, num_threads: u32) u64 {
    const n: usize = @min(num_threads, 16);
    const per_worker = count / @as(u32, @intCast(n));

    var contexts: [16]PipelineEnqueueCtx = undefined;
    var threads: [16]std.Thread = undefined;

    var timer = Timer.start() catch unreachable;

    for (0..n) |w| {
        contexts[w] = .{
            .engine = engine,
            .start_idx = @as(u32, @intCast(w)) * per_worker,
            .count = if (w == n - 1) count - @as(u32, @intCast(w)) * per_worker else per_worker,
        };
        threads[w] = std.Thread.spawn(.{}, pipelineEnqueueWorker, .{&contexts[w]}) catch unreachable;
    }
    for (0..n) |w| threads[w].join();

    return timer.read();
}

// ============================================================================
// Pipeline lifecycle (multi-threaded, pre-enqueue then concurrent fetch+ack)
// Matches Go benchmark: pre-enqueue all, then 8 goroutines fetch+ack
// ============================================================================

const PipelineLifecycleCtx = struct {
    engine: *engine_mod.Engine,
    count: u32,
    completed: u32 = 0,
};

fn pipelineLifecycleWorker(ctx: *PipelineLifecycleCtx) void {
    var done: u32 = 0;
    while (done < ctx.count) {
        // Fetch
        const fetch_now: u64 = @intCast(benchClockFn());
        advanceClock(1_000);
        const fetch_queues = [1][]const u8{queue_name};
        const fetch_data = ops.OpData{
            .fetch = .{
                .queues = &fetch_queues,
                .worker_id = "bench-worker",
                .count = 1,
                .now_ns = fetch_now,
                .lease_duration_ms = 30000,
            },
        };
        const fetch_result = ctx.engine.submit(.fetch, &fetch_data);

        if (fetch_result.affected > 0) {
            // Ack
            const ack_now: u64 = @intCast(benchClockFn());
            advanceClock(1_000);
            const f = &fetch_result.fetched[0];
            const ack_jobs = [1]ops.AckJob{.{
                .job_id = f.id_buf[0..f.id_len],
                .queue = f.queue_buf[0..f.queue_len],
            }};
            const ack_data = ops.OpData{
                .ack = .{ .acks = &ack_jobs, .now_ns = ack_now },
            };
            _ = ctx.engine.submit(.ack, &ack_data);
            done += 1;
        } else {
            // No jobs available, yield
            std.Thread.yield() catch {};
        }
    }
}

fn benchLifecyclePipeline(engine: *engine_mod.Engine, count: u32, num_threads: u32) u64 {
    // Pre-enqueue all jobs via pipeline (not timed, matches Go pattern)
    {
        var i: u32 = 0;
        while (i < count) {
            const bs: u32 = @min(batch_size, count - i);
            var job_arr: [batch_size]ops.EnqueueJob = undefined;
            var id_bufs: [batch_size][64]u8 = undefined;

            for (0..bs) |b| {
                const idx = i + @as(u32, @intCast(b));
                const now_ns: u64 = @intCast(benchClockFn());
                advanceClock(1_000);
                const id = std.fmt.bufPrint(&id_bufs[b], "plc-{d}", .{idx}) catch unreachable;
                job_arr[b] = .{
                    .job_id = id,
                    .queue = queue_name,
                    .priority = types.priority_default,
                    .max_retries = 3,
                    .created_at_ns = now_ns,
                };
            }
            const now_ns: u64 = @intCast(benchClockFn());
            const data = ops.OpData{
                .enqueue = .{ .jobs = job_arr[0..bs], .now_ns = now_ns },
            };
            _ = engine.submit(.enqueue, &data);
            i += bs;
        }
    }

    // Now time the concurrent fetch+ack
    const n: usize = @min(num_threads, 16);
    const per_worker = count / @as(u32, @intCast(n));

    var contexts: [16]PipelineLifecycleCtx = undefined;
    var threads: [16]std.Thread = undefined;

    var timer = Timer.start() catch unreachable;

    for (0..n) |w| {
        contexts[w] = .{
            .engine = engine,
            .count = if (w == n - 1) count - @as(u32, @intCast(w)) * per_worker else per_worker,
        };
        threads[w] = std.Thread.spawn(.{}, pipelineLifecycleWorker, .{&contexts[w]}) catch unreachable;
    }
    for (0..n) |w| threads[w].join();

    return timer.read();
}

// ============================================================================
// 3-node cluster benchmark (leader + 2 followers, oplog replication)
// ============================================================================

fn benchEnqueueCluster(allocator: std.mem.Allocator, count: u32) !u64 {
    var cluster = try cluster_sim.Cluster.init(allocator, 3);
    defer cluster.deinit();

    if (!cluster.electLeader(50)) return error.NoLeader;

    var timer = Timer.start() catch unreachable;

    var i: u32 = 0;
    while (i < count) {
        const bs: u32 = @min(batch_size, count - i);

        // Build batch enqueue
        var job_arr: [batch_size]ops.EnqueueJob = undefined;
        var id_bufs: [batch_size][64]u8 = undefined;

        const now: u64 = @intCast(cluster.clock.nanos);
        cluster.clock.advance(1_000);

        for (0..bs) |b| {
            const idx = i + @as(u32, @intCast(b));
            const id = std.fmt.bufPrint(&id_bufs[b], "cj-{d}", .{idx}) catch unreachable;
            job_arr[b] = .{
                .job_id = id,
                .queue = queue_name,
                .priority = types.priority_default,
                .max_retries = 3,
                .created_at_ns = now,
            };
        }

        const data = ops.OpData{
            .enqueue = .{ .jobs = job_arr[0..bs], .now_ns = now },
        };
        _ = cluster.submitToLeader(.enqueue, &data);

        // Replicate periodically (every 16 batches)
        if ((i / batch_size) % 16 == 0) {
            cluster.tick();
        }

        i += bs;
    }

    // Final replication flush
    cluster.runTicks(10);

    return timer.read();
}

fn benchLifecycleCluster(allocator: std.mem.Allocator, count: u32) !u64 {
    var cluster = try cluster_sim.Cluster.init(allocator, 3);
    defer cluster.deinit();

    if (!cluster.electLeader(50)) return error.NoLeader;

    var timer = Timer.start() catch unreachable;

    var i: u32 = 0;
    while (i < count) {
        const bs: u32 = @min(batch_size, count - i);
        const now: u64 = @intCast(cluster.clock.nanos);
        cluster.clock.advance(1_000);

        // --- Enqueue batch ---
        {
            var job_arr: [batch_size]ops.EnqueueJob = undefined;
            var id_bufs: [batch_size][64]u8 = undefined;

            for (0..bs) |b| {
                const idx = i + @as(u32, @intCast(b));
                const id = std.fmt.bufPrint(&id_bufs[b], "cl-{d}", .{idx}) catch unreachable;
                job_arr[b] = .{
                    .job_id = id,
                    .queue = queue_name,
                    .priority = types.priority_default,
                    .max_retries = 3,
                    .created_at_ns = now,
                };
            }
            const data = ops.OpData{
                .enqueue = .{ .jobs = job_arr[0..bs], .now_ns = now },
            };
            _ = cluster.submitToLeader(.enqueue, &data);
        }

        // --- Fetch batch ---
        const leader = cluster.getLeader() orelse unreachable;
        var num_fetched: u32 = 0;
        var fetched_ids: [batch_size][64]u8 = undefined;
        var fetched_id_lens: [batch_size]u8 = undefined;
        var fetched_queues: [batch_size][64]u8 = undefined;
        var fetched_queue_lens: [batch_size]u8 = undefined;

        for (0..bs) |_| {
            const fetch_now: u64 = @intCast(cluster.clock.nanos);
            cluster.clock.advance(1_000);
            const fetch_queues = [1][]const u8{queue_name};
            const fetch_data = ops.OpData{
                .fetch = .{
                    .queues = &fetch_queues,
                    .worker_id = "bench-worker",
                    .count = 1,
                    .now_ns = fetch_now,
                    .lease_duration_ms = 30000,
                },
            };
            const result = leader.apply(.fetch, &fetch_data);
            if (result.affected > 0) {
                const f = &result.fetched[0];
                @memcpy(fetched_ids[num_fetched][0..f.id_len], f.id_buf[0..f.id_len]);
                fetched_id_lens[num_fetched] = f.id_len;
                @memcpy(fetched_queues[num_fetched][0..f.queue_len], f.queue_buf[0..f.queue_len]);
                fetched_queue_lens[num_fetched] = f.queue_len;
                num_fetched += 1;
            }
        }

        // --- Ack batch ---
        for (0..num_fetched) |b| {
            const ack_now: u64 = @intCast(cluster.clock.nanos);
            cluster.clock.advance(1_000);
            const ack_jobs = [1]ops.AckJob{.{
                .job_id = fetched_ids[b][0..fetched_id_lens[b]],
                .queue = fetched_queues[b][0..fetched_queue_lens[b]],
            }};
            const ack_data = ops.OpData{
                .ack = .{ .acks = &ack_jobs, .now_ns = ack_now },
            };
            _ = leader.apply(.ack, &ack_data);
        }

        // Replicate periodically
        if ((i / batch_size) % 16 == 0) {
            cluster.tick();
        }

        i += bs;
    }

    cluster.runTicks(10);

    return timer.read();
}

// ============================================================================
// Helpers
// ============================================================================

fn formatRate(buf: []u8, count: u32, elapsed_ns: u64) []const u8 {
    if (elapsed_ns == 0) return "inf";
    const ops_per_sec = @as(u64, count) * 1_000_000_000 / elapsed_ns;
    return std.fmt.bufPrint(buf, "{d}", .{ops_per_sec}) catch "?";
}

fn formatDuration(buf: []u8, ns: u64) []const u8 {
    if (ns < 1_000_000) {
        return std.fmt.bufPrint(buf, "{d}.{d}us", .{ ns / 1_000, (ns % 1_000) / 100 }) catch "?";
    } else if (ns < 1_000_000_000) {
        return std.fmt.bufPrint(buf, "{d}.{d}ms", .{ ns / 1_000_000, (ns % 1_000_000) / 100_000 }) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{ ns / 1_000_000_000, (ns % 1_000_000_000) / 100_000_000 }) catch "?";
    }
}

fn printResult(label: []const u8, count: u32, elapsed_ns: u64) void {
    var rate_buf: [32]u8 = undefined;
    var dur_buf: [32]u8 = undefined;
    std.debug.print("  {s: <24} {s: >10} ops/sec  ({s})\n", .{
        label,
        formatRate(&rate_buf, count, elapsed_ns),
        formatDuration(&dur_buf, elapsed_ns),
    });
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    std.debug.print(
        \\
        \\  Corvo Benchmark (zig)
        \\  jobs={d}  concurrency={d}  batch={d}  queue={s}
        \\
        \\  --- Single Node ---
        \\
    , .{ jobs, concurrency, batch_size, queue_name });

    // === Direct enqueue ===
    {
        resetClock();
        var stores: [1]kv.Store = undefined;
        var ctx = try openEngine(allocator, &stores);
        defer closeEngine(ctx.db, &ctx.engine);

        const elapsed = benchEnqueueDirect(&ctx.engine, jobs);
        printResult("direct enqueue:", jobs, elapsed);
    }

    // === Direct fetch ===
    {
        resetClock();
        var stores: [1]kv.Store = undefined;
        var ctx = try openEngine(allocator, &stores);
        defer closeEngine(ctx.db, &ctx.engine);

        const elapsed = benchFetchDirect(&ctx.engine, jobs);
        printResult("direct fetch:", jobs, elapsed);
    }

    // === Direct ack ===
    {
        resetClock();
        var stores: [1]kv.Store = undefined;
        var ctx = try openEngine(allocator, &stores);
        defer closeEngine(ctx.db, &ctx.engine);

        const elapsed = benchAckDirect(&ctx.engine, jobs);
        printResult("direct ack:", jobs, elapsed);
    }

    // === Direct lifecycle ===
    {
        resetClock();
        var stores: [1]kv.Store = undefined;
        var ctx = try openEngine(allocator, &stores);
        defer closeEngine(ctx.db, &ctx.engine);

        const elapsed = benchLifecycleDirect(&ctx.engine, jobs);
        printResult("direct lifecycle:", jobs, elapsed);
    }

    // === Pipeline enqueue ===
    {
        resetClock();
        var stores: [1]kv.Store = undefined;
        var ctx = try openEngine(allocator, &stores);
        defer closeEngine(ctx.db, &ctx.engine);

        try ctx.engine.startPipeline();
        defer ctx.engine.stopPipeline();

        const elapsed = benchEnqueuePipeline(&ctx.engine, jobs, concurrency);
        printResult("pipeline enqueue:", jobs, elapsed);
    }

    // === 3-Node Cluster ===
    std.debug.print(
        \\
        \\  --- 3-Node Cluster ---
        \\
    , .{});

    {
        const elapsed = benchEnqueueCluster(allocator, jobs) catch |e| {
            std.debug.print("  cluster enqueue: FAILED ({s})\n", .{@errorName(e)});
            return;
        };
        printResult("cluster enqueue:", jobs, elapsed);
    }

    {
        const elapsed = benchLifecycleCluster(allocator, jobs) catch |e| {
            std.debug.print("  cluster lifecycle: FAILED ({s})\n", .{@errorName(e)});
            return;
        };
        printResult("cluster lifecycle:", jobs, elapsed);
    }

    // === Rebuild benchmark ===
    std.debug.print(
        \\
        \\  --- Rebuild (startup) ---
        \\
    , .{});
    {
        resetClock();
        var stores: [1]kv.Store = undefined;
        var ctx = try openEngine(allocator, &stores);
        defer closeEngine(ctx.db, &ctx.engine);

        // Enqueue 1M jobs, fetch+ack 90% to simulate real DB with mostly terminal jobs.
        const rebuild_jobs: u32 = 1_000_000;
        const terminal_pct: u32 = 90;
        const terminal_count = rebuild_jobs * terminal_pct / 100;

        // Enqueue all
        {
            var op_buf: [batch_size]ops.OpInput = undefined;
            var job_bufs: [batch_size][1]ops.EnqueueJob = undefined;
            var id_bufs: [batch_size][64]u8 = undefined;

            var i: u32 = 0;
            while (i < rebuild_jobs) {
                const bs: u32 = @min(batch_size, rebuild_jobs - i);
                for (0..bs) |b| {
                    const idx = i + @as(u32, @intCast(b));
                    const now_ns: u64 = @intCast(benchClockFn());
                    advanceClock(1_000);
                    const id = std.fmt.bufPrint(&id_bufs[b], "rb-{d}", .{idx}) catch unreachable;
                    job_bufs[b] = [1]ops.EnqueueJob{.{
                        .job_id = id,
                        .queue = queue_name,
                        .priority = types.priority_default,
                        .max_retries = 3,
                        .created_at_ns = now_ns,
                    }};
                    op_buf[b] = .{
                        .op_type = .enqueue,
                        .data = .{ .enqueue = .{ .jobs = &job_bufs[b], .now_ns = now_ns } },
                    };
                }
                _ = ctx.engine.applyBatch(op_buf[0..bs]);
                i += bs;
            }
        }

        // Fetch+ack terminal_count jobs
        {
            var op_buf: [batch_size]ops.OpInput = undefined;
            var i: u32 = 0;
            while (i < terminal_count) {
                const bs: u32 = @min(batch_size, terminal_count - i);

                // Fetch
                var fetch_queue_slices: [batch_size][1][]const u8 = undefined;
                for (0..bs) |b| {
                    const now_ns: u64 = @intCast(benchClockFn());
                    advanceClock(1_000);
                    fetch_queue_slices[b] = [1][]const u8{queue_name};
                    op_buf[b] = .{
                        .op_type = .fetch,
                        .data = .{ .fetch = .{
                            .queues = &fetch_queue_slices[b],
                            .worker_id = "bench-worker",
                            .count = 1,
                            .now_ns = now_ns,
                            .lease_duration_ms = 30000,
                        } },
                    };
                }
                var fetch_results: [batch_size]ops.OpResult = undefined;
                _ = ctx.engine.applyBatchCollect(op_buf[0..bs], &fetch_results);

                // Ack
                var num_fetched: u32 = 0;
                var ack_bufs: [batch_size][1]ops.AckJob = undefined;
                for (0..bs) |b| {
                    if (fetch_results[b].affected > 0) {
                        const f = &fetch_results[b].fetched[0];
                        const now_ns: u64 = @intCast(benchClockFn());
                        advanceClock(1_000);
                        ack_bufs[num_fetched] = [1]ops.AckJob{.{
                            .job_id = f.id_buf[0..f.id_len],
                            .queue = f.queue_buf[0..f.queue_len],
                        }};
                        op_buf[num_fetched] = .{
                            .op_type = .ack,
                            .data = .{ .ack = .{ .acks = &ack_bufs[num_fetched], .now_ns = now_ns } },
                        };
                        num_fetched += 1;
                    }
                }
                if (num_fetched > 0) {
                    _ = ctx.engine.applyBatch(op_buf[0..num_fetched]);
                }
                i += bs;
            }
        }

        // Now time the rebuild (simulates restart)
        var rebuild_handler = handler_mod.OpHandler.init(allocator);
        defer rebuild_handler.deinit();

        var timer = Timer.start() catch unreachable;
        rebuild_handler.rebuildState(&stores);
        const elapsed = timer.read();

        var dur_buf: [32]u8 = undefined;
        std.debug.print("  rebuild 1M jobs (90% terminal): {s}\n", .{formatDuration(&dur_buf, elapsed)});
        std.debug.print("  pending: {d}, active: {d}\n", .{
            rebuild_handler.pending.queueCount(queue_name),
            rebuild_handler.getActiveCount(queue_name),
        });
    }

    std.debug.print(
        \\
        \\  --- Go Comparison ---
        \\  go single-node enqueue:    208000 ops/sec
        \\  go single-node lifecycle:  105000 ops/sec
        \\  go 3-node enqueue:         164000 ops/sec
        \\  go 3-node lifecycle:        91000 ops/sec
        \\
        \\
    , .{});
}
