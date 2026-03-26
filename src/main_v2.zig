//! Corvo v2 server — pipeline_v2 over io_uring/kqueue, single-threaded.
//!
//! Single port handles both RPC (binary) and HTTP (JSON) via protocol detection.
//!
//! Usage: corvo-v2 [options]
//!   --bind       Listen address (default: 0.0.0.0)
//!   --port       Listen port (default: 9878)
//!   --data-dir   Data directory (default: /tmp/corvo-data)
//!   --no-mirror  Disable SQLite mirror

const std = @import("std");
const talon = @import("talon");
const corvo = @import("corvo");

const io_mod = corvo.io;
const kv = corvo.kv;
const handler_mod = corvo.handler;
const oplog_mod = corvo.oplog;
const notify_mod = corvo.notify;
const mirror_mod = corvo.mirror;
const sqlite_read = corvo.sqlite_read;
const pipeline_v2_mod = corvo.pipeline_v2;

const RealPipeline = pipeline_v2_mod.Pipeline(io_mod.Backend);

var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn handleSignal(_: c_int) callconv(.c) void {
    running.store(false, .monotonic);
}

fn realClock() i64 {
    return @intCast(std.time.nanoTimestamp());
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // --- Parse CLI args ---
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    var bind: []const u8 = "0.0.0.0";
    var port: u16 = 9878;
    var data_dir: []const u8 = "/tmp/corvo-data";
    var no_mirror = false;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bind")) {
            bind = args.next() orelse {
                std.debug.print("--bind requires an argument\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const port_str = args.next() orelse {
                std.debug.print("--port requires an argument\n", .{});
                return;
            };
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                std.debug.print("invalid port: {s}\n", .{port_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            data_dir = args.next() orelse {
                std.debug.print("--data-dir requires an argument\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--no-mirror")) {
            no_mirror = true;
        }
    }

    std.debug.print("corvo-v2: starting (bind={s}, port={d}, data={s})\n", .{ bind, port, data_dir });

    // --- Ensure data directory exists ---
    std.fs.cwd().makePath(data_dir) catch {};

    // --- Open Talon DB ---
    var kv_path_buf: [256]u8 = undefined;
    const kv_path = std.fmt.bufPrint(&kv_path_buf, "{s}/kv", .{data_dir}) catch unreachable;
    const db = try talon.DB.open(allocator, kv_path, .{});
    defer db.close();

    const kvstore = kv.Store.init(db);
    var stores = [1]kv.Store{kvstore};

    // --- OpHandler ---
    var handler = handler_mod.OpHandler.init(allocator);
    defer handler.deinit();
    handler.rebuildState(&stores);

    // --- Oplog ---
    var oplog_path_buf: [256]u8 = undefined;
    const oplog_path_slice = std.fmt.bufPrint(&oplog_path_buf, "{s}/oplog", .{data_dir}) catch unreachable;
    var oplog_path_z: [257]u8 = undefined;
    @memcpy(oplog_path_z[0..oplog_path_slice.len], oplog_path_slice);
    oplog_path_z[oplog_path_slice.len] = 0;

    var oplog = oplog_mod.Log.init(allocator, .{ .now_fn = &realClock }, oplog_path_z[0..oplog_path_slice.len :0]);
    defer oplog.deinit();

    // --- QueueNotifier ---
    var notify = notify_mod.QueueNotifier.init(allocator);
    defer notify.deinit();

    // --- Mirror + SQLite reader (optional) ---
    var mirror: ?mirror_mod.Mirror = null;
    var reader: ?sqlite_read.Reader = null;

    if (!no_mirror) {
        var mirror_path_buf: [256]u8 = undefined;
        const mirror_path_slice = std.fmt.bufPrint(&mirror_path_buf, "{s}/mirror.db", .{data_dir}) catch unreachable;
        var mirror_path_z: [257]u8 = undefined;
        @memcpy(mirror_path_z[0..mirror_path_slice.len], mirror_path_slice);
        mirror_path_z[mirror_path_slice.len] = 0;

        mirror = mirror_mod.Mirror.init(allocator, mirror_path_z[0..mirror_path_slice.len :0]) catch |err| {
            std.debug.print("corvo-v2: failed to init mirror: {}\n", .{err});
            return;
        };
        try mirror.?.start();
        reader = sqlite_read.Reader.init(&mirror.?.db);
    }
    defer if (mirror) |*m| m.deinit();

    // --- Create listen socket ---
    const addr = try std.net.Address.parseIp(bind, port);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const listen_fd = listener.stream.handle;

    // --- IO backend ---
    var io_backend = try io_mod.Backend.init(allocator, .{
        .listen_fd = listen_fd,
        .max_conns = 4096,
        .recv_buf_size = 65536,
        .send_buf_size = 65536,
    });
    defer io_backend.deinit(allocator);

    // Seed the first accept
    io_backend.queueAccept();
    io_backend.submit();

    // --- Pipeline ---
    var pipeline = RealPipeline.init(
        allocator,
        &io_backend,
        &handler,
        &stores,
        &oplog,
        &notify,
        if (reader) |*r| r else null,
        if (mirror) |*m| m else null,
        .{
            .clock_fn = &realClock,
            .promote_interval_ns = 1_000_000_000,
            .reclaim_interval_ns = 1_000_000_000,
            .unique_interval_ns = 30_000_000_000,
            .rate_limit_interval_ns = 30_000_000_000,
            .expire_interval_ns = 10_000_000_000,
            .purge_interval_ns = 3_600_000_000_000,
        },
    );
    defer pipeline.deinit();

    // --- Signal handling ---
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

    std.debug.print("corvo-v2: listening on {s}:{d} (rpc+http)\n", .{ bind, port });

    // --- Tick loop ---
    while (running.load(.monotonic)) {
        pipeline.tick();
    }

    std.debug.print("\ncorvo-v2: shutting down ({d} ticks, {d} ops)\n", .{
        pipeline.ticks_total, pipeline.applied_total,
    });
}
