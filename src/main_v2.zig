//! Corvo v2 server — pipeline_v2 over io_uring/kqueue, single-threaded.
//!
//! Single port handles both RPC (binary) and HTTP (JSON) via protocol detection.
//! Supports single-node and cluster mode (PBR with leader election).
//!
//! Usage: corvo-v2 [options]
//!   --bind       Listen address (default: 0.0.0.0)
//!   --port       Listen port (default: 9878)
//!   --data-dir   Data directory (default: /tmp/corvo-data)
//!   --no-mirror  Disable SQLite mirror
//!   --node-id    Node ID for cluster mode (enables cluster)
//!   --peers      Comma-separated peer list: id@host:port,id@host:port,...
//!   --sync-repl  Enable sync replication (wait for follower ack before responding)

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
const cluster_mod = corvo.cluster;

const RealPipeline = pipeline_v2_mod.Pipeline(io_mod.Backend);

var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn handleSignal(_: c_int) callconv(.c) void {
    running.store(false, .monotonic);
}

fn realClock() i64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============================================================================
// Peer parsing: "id@host:port"
// ============================================================================

const PeerSpec = struct {
    id: []const u8,
    addr: std.net.Address,
};

const max_peers = 6;

fn parsePeers(spec: []const u8, ids_out: *[max_peers][]const u8, addrs_out: *[max_peers]std.net.Address) !u8 {
    var count: u8 = 0;
    var rest = spec;

    while (rest.len > 0) {
        // Find end of this peer spec (comma or end of string).
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        const entry = rest[0..end];
        rest = if (end < rest.len) rest[end + 1 ..] else "";

        if (entry.len == 0) continue;

        // Parse "id@host:port"
        const at_pos = std.mem.indexOfScalar(u8, entry, '@') orelse return error.InvalidPeerSpec;
        const id = entry[0..at_pos];
        const host_port = entry[at_pos + 1 ..];

        const colon_pos = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.InvalidPeerSpec;
        const host = host_port[0..colon_pos];
        const port_str = host_port[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPeerSpec;

        // Cluster transport bind port = server port + 1000 (convention).
        const cluster_port = port + 1000;

        ids_out[count] = id;
        addrs_out[count] = try std.net.Address.parseIp(host, cluster_port);
        count += 1;
    }

    return count;
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
    var node_id: ?[]const u8 = null;
    var peers_spec: ?[]const u8 = null;
    var sync_repl = false;

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
        } else if (std.mem.eql(u8, arg, "--node-id")) {
            node_id = args.next() orelse {
                std.debug.print("--node-id requires an argument\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--peers")) {
            peers_spec = args.next() orelse {
                std.debug.print("--peers requires an argument\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--sync-repl")) {
            sync_repl = true;
        }
    }

    const cluster_mode = node_id != null;
    if (cluster_mode and peers_spec == null) {
        std.debug.print("--node-id requires --peers\n", .{});
        return;
    }

    std.debug.print("corvo-v2: starting (bind={s}, port={d}, data={s}{s})\n", .{
        bind, port, data_dir, if (cluster_mode) ", cluster" else "",
    });

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

    // --- Cluster setup (optional) ---
    var cluster_node: ?cluster_mod.ClusterNode = null;
    var repl_hook: ?pipeline_v2_mod.ReplHook = null;

    if (cluster_mode) {
        var peer_ids: [max_peers][]const u8 = undefined;
        var peer_addrs: [max_peers]std.net.Address = undefined;
        const peer_count = parsePeers(peers_spec.?, &peer_ids, &peer_addrs) catch {
            std.debug.print("invalid --peers format (expected: id@host:port,...)\n", .{});
            return;
        };

        // Cluster transport binds on server port + 1000.
        const cluster_port: u16 = port + 1000;
        const cluster_bind_addr = try std.net.Address.parseIp(bind, cluster_port);

        cluster_node = cluster_mod.ClusterNode.init(allocator, &stores, .{
            .node_id = node_id.?,
            .peer_ids = peer_ids[0..peer_count],
            .peer_addrs = peer_addrs[0..peer_count],
            .bind_addr = cluster_bind_addr,
        });

        try cluster_node.?.start();
        repl_hook = cluster_node.?.replHook();

        std.debug.print("corvo-v2: cluster node={s}, peers={d}, transport=:{d}\n", .{
            node_id.?, peer_count, cluster_port,
        });
    }
    defer if (cluster_node) |*cn| cn.deinit();

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
            .repl_hook = repl_hook,
            .sync_replication = sync_repl,
        },
    );
    defer pipeline.deinit();

    // Wire cluster ack notification to pipeline's atomic.
    if (cluster_mode) {
        cluster_mod.g_ack_seq_ptr = pipeline.ackSeqPtr();
    }

    // --- Signal handling ---
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

    // Wait for leader election if in cluster mode.
    if (cluster_node) |*cn| {
        std.debug.print("corvo-v2: waiting for leader election...\n", .{});
        if (!cn.waitForLeader(30000)) {
            std.debug.print("corvo-v2: leader election timed out\n", .{});
            return;
        }
        const state = cn.election.currentState();
        std.debug.print("corvo-v2: leader elected (epoch={d}, leader={s})\n", .{
            state.epoch, if (state.leader_id.len > 0) state.leader_id else "(self)",
        });
    }

    std.debug.print("corvo-v2: listening on {s}:{d} (rpc+http)\n", .{ bind, port });

    // --- Tick loop ---
    while (running.load(.monotonic)) {
        pipeline.tick();
    }

    std.debug.print("\ncorvo-v2: shutting down ({d} ticks, {d} ops)\n", .{
        pipeline.ticks_total, pipeline.applied_total,
    });
}
