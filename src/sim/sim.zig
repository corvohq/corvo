//! VOPR Simulator — deterministic simulation with invariant checking.
//!
//! Single-node simulation: creates a Pipeline v2 over SimBackend and
//! N simulated clients with persistent connections. Each tick:
//!   1. Advance clock (+ random time jumps)
//!   2. Each client injects one RPC frame into SimBackend
//!   3. pipeline.tick() — drain, decode, executeBatch, encode, submit
//!   4. Each client reads its response and updates state
//!   5. Periodic KV invariant checks
//!
//! All operations go through the real write path. Deterministic: same seed
//! produces identical behavior (SimBackend makes drain() deterministic).
//!
//! Run: zig build sim

const std = @import("std");
const talon = @import("talon");
const corvo = @import("corvo");

const kv = corvo.kv;
const handler_mod = corvo.handler;
const oplog_mod = corvo.oplog;
const notify_mod = corvo.notify;
const mirror_mod = corvo.mirror;
const pipeline_v2 = corvo.pipeline_v2;
const io_mod = corvo.io;

const SimClock = @import("clock.zig").SimClock;
const setGlobalClock = @import("clock.zig").setGlobalClock;
const globalClockNow = @import("clock.zig").globalClockNow;
const Config = @import("config.zig").Config;
const SimClient = @import("client.zig").SimClient;
const invariants = @import("invariants.zig");

const max_queues = 8;
const max_clients = 16;

const SimBackend = io_mod.SimBackend;
const Pipeline = pipeline_v2.Pipeline(SimBackend);

pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    const seed: u64 = if (config.seed == 0)
        @intCast(@as(u128, @bitCast(std.time.nanoTimestamp())) & 0xFFFFFFFFFFFFFFFF)
    else
        config.seed;

    var rng_state = std.Random.DefaultPrng.init(seed);
    const rng = rng_state.random();

    // --- Talon DB in temp directory ---
    const dir_path = "/tmp/corvo-sim";
    std.fs.cwd().deleteTree(dir_path) catch {};

    const db = try talon.DB.open(allocator, dir_path, .{ .sync = false });
    defer {
        db.close();
        std.fs.cwd().deleteTree(dir_path) catch {};
    }

    // --- KV store ---
    const store = kv.Store.init(db);
    var stores = [1]kv.Store{store};

    // --- Clock ---
    var clock = SimClock.init(1_000_000_000_000); // start at 1000s
    setGlobalClock(&clock);

    // --- Handler ---
    var handler = handler_mod.OpHandler.init(allocator);
    defer handler.deinit();
    handler.rebuildState(&stores);

    // --- Oplog ---
    var oplog = oplog_mod.Log.init(allocator, .{ .now_fn = &globalClockNow }, null, 1024);
    defer oplog.deinit();

    // --- Notifier ---
    var notify_inst = notify_mod.QueueNotifier.init(allocator);
    defer notify_inst.deinit();

    // --- Mirror (in-memory SQLite for invariant checking) ---
    var mirror = try mirror_mod.Mirror.initInMemory(allocator);
    defer mirror.deinit();

    // --- SimBackend ---
    var backend = try SimBackend.init(allocator, .{
        .listen_fd = -1,
        .max_conns = max_clients + 4,
        .recv_buf_size = 65536,
        .send_buf_size = 65536,
    });
    defer backend.deinit(allocator);

    // --- Pipeline ---
    var pipeline = Pipeline.init(
        allocator,
        &backend,
        &handler,
        &stores,
        &oplog,
        &notify_inst,
        null,
        &mirror,
        .{
            .clock_fn = &globalClockNow,
            .promote_interval_ns = 1_000_000_000, // 1s
            .reclaim_interval_ns = 1_000_000_000, // 1s
            .unique_interval_ns = 30_000_000_000, // 30s
            .rate_limit_interval_ns = 30_000_000_000, // 30s
            .expire_interval_ns = 10_000_000_000, // 10s
            .purge_interval_ns = 3_600_000_000_000, // 1h
        },
    );
    defer pipeline.deinit();

    // --- Queue names ---
    const num_queues: usize = @min(config.queues, max_queues);
    var queue_name_bufs: [max_queues][32]u8 = undefined;
    var queue_slices: [max_queues][]const u8 = undefined;

    for (0..num_queues) |i| {
        const name = std.fmt.bufPrint(&queue_name_bufs[i], "queue-{d}", .{i}) catch unreachable;
        queue_slices[i] = name;
    }
    const queues = queue_slices[0..num_queues];

    // --- Clients (each gets a persistent SimBackend connection) ---
    // Pipeline handles maintenance internally — clients don't send maintenance frames.
    // Client-sent maintenance in the same batch as acks causes double-decrement of active counts
    // (WriteBatch iterator sees base state, not pending writes from other ops in the batch).
    var client_config = config;
    client_config.maintenance_rate = 0;

    const num_clients: usize = @min(config.clients, max_clients);
    var clients: [max_clients]SimClient = undefined;

    for (0..num_clients) |i| {
        const conn_id = backend.connect() orelse unreachable;
        clients[i] = SimClient.init(
            @intCast(i),
            seed +% @as(u64, i) +% 1,
            &backend,
            conn_id,
            client_config,
            queues,
        );
        clients[i].rng = clients[i].prng.random();
    }

    // --- Main tick loop ---
    var tick: u32 = 0;
    while (tick < config.ticks) : (tick += 1) {
        // Advance clock
        clock.advance(config.tick_duration_ns);

        // Random time jump (simulates clock skew / idle periods)
        if (rng.float(f64) < config.time_jump_prob) {
            const jump = rng.intRangeAtMost(i64, 1_000_000, config.time_jump_max_ns);
            clock.advance(jump);
        }

        // Phase 1: each client injects one RPC frame
        for (clients[0..num_clients]) |*c| {
            c.inject();
        }

        // Phase 2: pipeline processes all frames in one batch
        pipeline.tick();

        // Flush mirror synchronously (no background thread in sim).
        mirror.flushAll();

        // Phase 3: each client reads its response
        for (clients[0..num_clients]) |*c| {
            c.processResponse();
        }

        // Periodic invariant checks
        if (tick > 0 and tick % config.check_interval == 0) {
            const result = invariants.checkAll(
                &stores[0],
                &handler,
                &mirror,
                tick,
                seed,
            );
            if (result) |err| {
                std.debug.print(
                    "\nINVARIANT VIOLATION at tick {d} seed {d}: [{s}] {s}\n",
                    .{ err.tick, err.seed, err.name, err.format() },
                );
                return error.InvariantViolation;
            }
        }
    }

    // --- Final invariant check ---
    {
        const result = invariants.checkAll(
            &stores[0],
            &handler,
            &mirror,
            config.ticks,
            seed,
        );
        if (result) |err| {
            std.debug.print(
                "\nFINAL INVARIANT VIOLATION seed {d}: [{s}] {s}\n",
                .{ err.seed, err.name, err.format() },
            );
            return error.InvariantViolation;
        }
    }

    // --- Stats ---
    var total_enqueued: u32 = 0;
    var total_fetched: u32 = 0;
    var total_acked: u32 = 0;
    var total_failed: u32 = 0;
    var total_bulk: u32 = 0;
    var total_maintenance: u32 = 0;
    var total_heartbeats: u32 = 0;
    var total_queue_ops: u32 = 0;

    for (clients[0..num_clients]) |c| {
        total_enqueued += c.enqueued;
        total_fetched += c.fetched;
        total_acked += c.acked;
        total_failed += c.failed;
        total_bulk += c.bulk_ops;
        total_maintenance += c.maintenance_ops;
        total_heartbeats += c.heartbeats;
        total_queue_ops += c.queue_ops;
    }

    std.debug.print(
        "OK seed={d} ticks={d} clients={d} queues={d} | enq={d} fetch={d} ack={d} fail={d} bulk={d} maint={d} hb={d} qop={d}\n",
        .{
            seed,            config.ticks,       num_clients,        num_queues,
            total_enqueued,  total_fetched,      total_acked,        total_failed,
            total_bulk,      total_maintenance,  total_heartbeats,   total_queue_ops,
        },
    );
}

// ============================================================================
// Tests — run short sims to verify compile + correctness.
// ============================================================================

test "sim smoke" {
    try run(std.testing.allocator, .{
        .seed = 42,
        .ticks = 100,
        .clients = 2,
        .queues = 2,
    });
}

test "sim stress" {
    try run(std.testing.allocator, .{
        .seed = 12345,
        .ticks = 5000,
        .clients = 5,
        .queues = 3,
    });
}
