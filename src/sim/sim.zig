//! VOPR Simulator — deterministic simulation with invariant checking.
//!
//! Single-node simulation: creates a Talon DB, Engine, Store, Server, and
//! N simulated clients. Each tick advances the clock, runs client actions
//! through HTTP route handlers, and periodically checks KV invariants.
//! Seed-based reproduction.
//!
//! Run: zig build sim

const std = @import("std");
const talon = @import("talon");
const corvo = @import("corvo");

const kv = corvo.kv;
const engine_mod = corvo.engine;
const store_mod = corvo.store;
const server_mod = corvo.server;

const SimClock = @import("clock.zig").SimClock;
const setGlobalClock = @import("clock.zig").setGlobalClock;
const globalClockNow = @import("clock.zig").globalClockNow;
const Config = @import("config.zig").Config;
const SimClient = @import("client.zig").SimClient;
const invariants = @import("invariants.zig");

/// Maximum number of simulated queues.
const max_queues = 8;
/// Maximum number of simulated clients.
const max_clients = 16;

/// Run a complete single-node simulation. Returns error on invariant violation.
pub fn run(allocator: std.mem.Allocator, config: Config) !void {
    // Resolve seed: 0 means pick from timestamp.
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

    // --- KV store + engine + store + server ---
    const store = kv.Store.init(db);
    var stores = [1]kv.Store{store};

    var clock = SimClock.init(1_000_000_000_000); // start at 1000s
    setGlobalClock(&clock);

    var engine = engine_mod.Engine.init(allocator, &stores, .{
        .clock_fn = &globalClockNow,
        .talon_sync = false,
    });
    defer engine.deinit();

    var corvo_store = store_mod.Store.init(allocator, &engine, null);
    var server = server_mod.Server.init(allocator, &corvo_store, .{});

    // --- Queue names ---
    const num_queues: usize = @min(config.queues, max_queues);
    var queue_name_bufs: [max_queues][32]u8 = undefined;
    var queue_slices: [max_queues][]const u8 = undefined;

    for (0..num_queues) |i| {
        const name = std.fmt.bufPrint(&queue_name_bufs[i], "queue-{d}", .{i}) catch unreachable;
        queue_slices[i] = name;
    }
    const queues = queue_slices[0..num_queues];

    // --- Clients ---
    const num_clients: usize = @min(config.clients, max_clients);
    var clients: [max_clients]SimClient = undefined;

    for (0..num_clients) |i| {
        clients[i] = SimClient.init(
            @intCast(i),
            seed +% @as(u64, i) +% 1,
            &engine,
            &server,
            config,
            queues,
        );
        clients[i].rng = clients[i].prng.random();
    }

    // --- Main tick loop ---
    var tick: u32 = 0;
    while (tick < config.ticks) : (tick += 1) {
        // Advance clock by tick duration.
        clock.advance(config.tick_duration_ns);

        // Random time jump (simulates clock skew / idle periods).
        if (rng.float(f64) < config.time_jump_prob) {
            const jump = rng.intRangeAtMost(i64, 1_000_000, config.time_jump_max_ns);
            clock.advance(jump);
        }

        // Each client performs one action.
        for (clients[0..num_clients]) |*c| {
            c.act();
        }

        // Periodic invariant checks.
        if (tick > 0 and tick % config.check_interval == 0) {
            const result = invariants.checkAll(
                &stores[0],
                engine.getHandler(),
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
            engine.getHandler(),
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
    var total_batch_creates: u32 = 0;
    var total_batch_seals: u32 = 0;
    var total_maintenance: u32 = 0;
    var total_heartbeats: u32 = 0;
    var total_queue_ops: u32 = 0;

    for (clients[0..num_clients]) |c| {
        total_enqueued += c.enqueued;
        total_fetched += c.fetched;
        total_acked += c.acked;
        total_failed += c.failed;
        total_bulk += c.bulk_ops;
        total_batch_creates += c.batch_creates;
        total_batch_seals += c.batch_seals;
        total_maintenance += c.maintenance_ops;
        total_heartbeats += c.heartbeats;
        total_queue_ops += c.queue_ops;
    }

    std.debug.print(
        "OK seed={d} ticks={d} clients={d} queues={d} | enq={d} fetch={d} ack={d} fail={d} bulk={d} batch={d}/{d} maint={d} hb={d} qop={d}\n",
        .{
            seed,           config.ticks,     num_clients,        num_queues,
            total_enqueued, total_fetched,     total_acked,        total_failed,
            total_bulk,     total_batch_creates, total_batch_seals, total_maintenance,
            total_heartbeats, total_queue_ops,
        },
    );
}

// ============================================================================
// Tests — just run a short sim to verify it compiles + doesn't crash.
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
