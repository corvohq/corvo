//! Corvo server — main entry point.
//!
//! Usage: corvo [options]
//!   --bind       Listen address (default: 0.0.0.0)
//!   --port       Listen port (default: 8080)
//!   --rpc-port   RPC port (default: 9878)
//!   --data-dir   Data directory (default: /tmp/corvo-data)
//!   --no-mirror  Disable SQLite mirror
//!   --node-id    Node ID for cluster mode (enables PBR)
//!   --peers      Comma-separated peers: node-2@host:port,node-3@host:port
//!   --pbr-port   PBR transport port (default: 9001)

const std = @import("std");
const talon = @import("talon");
const corvo = @import("corvo");

const kv = corvo.kv;
const engine_mod = corvo.engine;
const mirror_mod = corvo.mirror;
const store_mod = corvo.store;
const server_mod = corvo.server;
const rpc_mod = corvo.rpc;
const rpc_uring_mod = corvo.rpc_uring;
const scheduler_mod = corvo.scheduler;
const cluster_mod = corvo.cluster;
const pipeline_mod = corvo.pipeline;

const log = std.log.scoped(.corvo);

var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var g_server: *server_mod.Server = undefined;

fn handleSignal(_: c_int) callconv(.c) void {
    running.store(false, .monotonic);
    g_server.running.store(false, .monotonic);
}

// ============================================================================
// Peer parsing: "node-2@host:port,node-3@host:port"
// ============================================================================

const MAX_PEERS = 8;

const ParsedPeers = struct {
    ids: [MAX_PEERS][]const u8 = undefined,
    addrs: [MAX_PEERS]std.net.Address = undefined,
    count: usize = 0,
};

fn parsePeers(peers_str: []const u8) ParsedPeers {
    var result = ParsedPeers{};
    var remaining = peers_str;

    while (remaining.len > 0 and result.count < MAX_PEERS) {
        // Find comma or end
        var end = remaining.len;
        for (remaining, 0..) |c, i| {
            if (c == ',') {
                end = i;
                break;
            }
        }
        const peer = remaining[0..end];
        remaining = if (end < remaining.len) remaining[end + 1 ..] else "";

        if (peer.len == 0) continue;

        // Parse "node-id@host:port"
        const at_pos = std.mem.indexOfScalar(u8, peer, '@') orelse continue;
        const node_id = peer[0..at_pos];
        const addr_str = peer[at_pos + 1 ..];

        // Parse host:port
        const colon_pos = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse continue;
        const host = addr_str[0..colon_pos];
        const port_str = addr_str[colon_pos + 1 ..];
        const port_num = std.fmt.parseInt(u16, port_str, 10) catch continue;

        const addr = std.net.Address.parseIp(host, port_num) catch
            std.net.Address.parseIp("127.0.0.1", port_num) catch continue;

        result.ids[result.count] = node_id;
        result.addrs[result.count] = addr;
        result.count += 1;
    }

    return result;
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // --- Parse CLI args ---
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    var bind: []const u8 = "0.0.0.0";
    var port: u16 = 8080;
    var rpc_port: u16 = 9878;
    var data_dir: []const u8 = "/tmp/corvo-data";
    var no_mirror = false;
    var no_oplog = false;
    var use_io_uring = false;
    var node_id: []const u8 = "";
    var peers_str: []const u8 = "";
    var pbr_port: u16 = 9001;
    var shutdown_timeout_s: u16 = 30;
    var worker_count: u16 = 0;
    var rate_limit_enabled = false;
    var rate_limit_rps: f64 = 1000;
    var durability: []const u8 = "strong-pipelined";

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--bind")) {
            bind = args.next() orelse {
                log.err("--bind requires an argument", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const port_str = args.next() orelse {
                log.err("--port requires an argument", .{});
                return;
            };
            port = std.fmt.parseInt(u16, port_str, 10) catch {
                log.err("invalid port: {s}", .{port_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--rpc-port")) {
            const rpc_port_str = args.next() orelse {
                log.err("--rpc-port requires an argument", .{});
                return;
            };
            rpc_port = std.fmt.parseInt(u16, rpc_port_str, 10) catch {
                log.err("invalid rpc-port: {s}", .{rpc_port_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            data_dir = args.next() orelse {
                log.err("--data-dir requires an argument", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--no-mirror")) {
            no_mirror = true;
        } else if (std.mem.eql(u8, arg, "--no-oplog")) {
            no_oplog = true;
        } else if (std.mem.eql(u8, arg, "--io-uring")) {
            use_io_uring = true;
        } else if (std.mem.eql(u8, arg, "--node-id")) {
            node_id = args.next() orelse {
                log.err("--node-id requires an argument", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--peers")) {
            peers_str = args.next() orelse {
                log.err("--peers requires an argument", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--pbr-port")) {
            const pbr_port_str = args.next() orelse {
                log.err("--pbr-port requires an argument", .{});
                return;
            };
            pbr_port = std.fmt.parseInt(u16, pbr_port_str, 10) catch {
                log.err("invalid pbr-port: {s}", .{pbr_port_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--shutdown-timeout")) {
            const timeout_str = args.next() orelse {
                log.err("--shutdown-timeout requires an argument", .{});
                return;
            };
            shutdown_timeout_s = std.fmt.parseInt(u16, timeout_str, 10) catch {
                log.err("invalid shutdown-timeout: {s}", .{timeout_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--threads")) {
            const w_str = args.next() orelse {
                log.err("--threads requires an argument", .{});
                return;
            };
            worker_count = std.fmt.parseInt(u16, w_str, 10) catch {
                log.err("invalid threads: {s}", .{w_str});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--durability")) {
            durability = args.next() orelse {
                log.err("--durability requires: eventual, strong, strong-pipelined", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--rate-limit")) {
            rate_limit_enabled = true;
        } else if (std.mem.eql(u8, arg, "--rate-limit-rps")) {
            const rps_str = args.next() orelse {
                log.err("--rate-limit-rps requires an argument", .{});
                return;
            };
            rate_limit_rps = std.fmt.parseFloat(f64, rps_str) catch {
                log.err("invalid rate-limit-rps: {s}", .{rps_str});
                return;
            };
            rate_limit_enabled = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Corvo — distributed job queue
                \\
                \\Usage: corvo [options]
                \\
                \\Options:
                \\  --bind <addr>       Listen address (default: 0.0.0.0)
                \\  --port <port>       HTTP port (default: 8080)
                \\  --rpc-port <port>   Binary RPC port (default: 9878)
                \\  --data-dir <dir>    Data directory (default: /tmp/corvo-data)
                \\  --no-mirror         Disable SQLite mirror
                \\  --no-oplog          Disable oplog
                \\  --io-uring          Use io_uring RPC server (Linux only)
                \\  --node-id <id>      Node ID (enables cluster mode)
                \\  --peers <spec>      Peers: node-2@host:port,node-3@host:port
                \\  --pbr-port <port>   PBR transport port (default: 9001)
                \\  --shutdown-timeout <s>  Graceful shutdown timeout in seconds (default: 30)
                \\  --threads <n>          HTTP server threads (default: CPU count)
                \\  --rate-limit           Enable HTTP rate limiting
                \\  --rate-limit-rps <n>   Rate limit requests/sec per client (default: 1000)
                \\  --help              Show this help
                \\
            , .{});
            return;
        }
    }

    // --- Cluster mode detection ---
    const cluster_mode = node_id.len > 0 and peers_str.len > 0;
    const parsed_peers = if (cluster_mode) parsePeers(peers_str) else ParsedPeers{};

    if (cluster_mode) {
        std.debug.print("corvo: cluster mode (node={s}, peers={d}, pbr-port={d})\n", .{
            node_id, parsed_peers.count, pbr_port,
        });
    }

    // --- Open Talon DB ---
    std.debug.print("corvo: starting (bind={s}, http={d}, rpc={d}, data={s})\n", .{ bind, port, rpc_port, data_dir });

    // Ensure data directory exists.
    std.fs.cwd().makePath(data_dir) catch {};

    // Build KV path.
    var kv_path_buf: [256]u8 = undefined;
    const kv_path = std.fmt.bufPrint(&kv_path_buf, "{s}/kv", .{data_dir}) catch {
        log.err("data-dir path too long", .{});
        return;
    };

    const db = try talon.DB.open(allocator, kv_path, .{});
    defer db.close();

    // --- Engine ---
    var oplog_path_buf: [256]u8 = undefined;
    const oplog_path_slice = std.fmt.bufPrint(&oplog_path_buf, "{s}/oplog.bin", .{data_dir}) catch {
        log.err("oplog path too long", .{});
        return;
    };
    var oplog_path_z: [257]u8 = undefined;
    @memcpy(oplog_path_z[0..oplog_path_slice.len], oplog_path_slice);
    oplog_path_z[oplog_path_slice.len] = 0;

    // In cluster mode, always enable oplog (needed for replication).
    const use_oplog = cluster_mode or !no_oplog;

    const kvstore = kv.Store.init(db);
    var stores = [1]kv.Store{kvstore};

    // --- Cluster Node (optional) ---
    var cluster_node: ?cluster_mod.ClusterNode = null;
    var repl_hook: ?pipeline_mod.ReplHook = null;

    if (cluster_mode) {
        const pbr_addr = std.net.Address.parseIp(bind, pbr_port) catch
            std.net.Address.parseIp("0.0.0.0", pbr_port) catch unreachable;

        cluster_node = cluster_mod.ClusterNode.init(allocator, &stores, .{
            .node_id = node_id,
            .peer_ids = parsed_peers.ids[0..parsed_peers.count],
            .peer_addrs = parsed_peers.addrs[0..parsed_peers.count],
            .bind_addr = pbr_addr,
        });
        try cluster_node.?.start();
        repl_hook = cluster_node.?.replHook();
    }
    defer if (cluster_node) |*cn| cn.deinit();

    const dur: pipeline_mod.Durability = if (std.mem.eql(u8, durability, "eventual"))
        .eventual
    else if (std.mem.eql(u8, durability, "strong"))
        .strong
    else
        .strong_pipelined;

    var engine = engine_mod.Engine.init(allocator, &stores, .{
        .node_id = if (node_id.len > 0) node_id else "node-1",
        .oplog_path = if (use_oplog) oplog_path_z[0..oplog_path_slice.len :0] else null,
        .durability = dur,
    });
    defer engine.deinit();

    // --- Mirror (optional) ---
    var mirror: ?mirror_mod.Mirror = null;
    if (!no_mirror) {
        var mirror_path_buf: [256]u8 = undefined;
        const mirror_path_slice = std.fmt.bufPrint(&mirror_path_buf, "{s}/mirror.db", .{data_dir}) catch {
            log.err("mirror path too long", .{});
            return;
        };
        // Null-terminate for C FFI.
        var mirror_path_z: [257]u8 = undefined;
        @memcpy(mirror_path_z[0..mirror_path_slice.len], mirror_path_slice);
        mirror_path_z[mirror_path_slice.len] = 0;

        mirror = mirror_mod.Mirror.init(allocator, mirror_path_z[0..mirror_path_slice.len :0]) catch |err| {
            log.err("failed to init mirror: {}", .{err});
            return;
        };
        try mirror.?.start();
    }
    defer if (mirror) |*m| m.deinit();

    // --- Start async pipeline ---
    try engine.startPipelineWithHook(repl_hook);
    defer engine.stopPipeline();

    // --- Store ---
    var store = store_mod.Store.init(
        allocator,
        &engine,
        if (mirror) |*m| m else null,
    );

    // --- Scheduler ---
    var sched = scheduler_mod.Scheduler.init(&store, .{});
    try sched.start();
    defer sched.stop();

    // --- Wait for leader election in cluster mode ---
    if (cluster_node) |*cn| {
        std.debug.print("corvo: waiting for leader election...\n", .{});
        if (cn.waitForLeader(15_000)) {
            const state = cn.election.currentState();
            if (state.state == .leader) {
                std.debug.print("corvo: this node is the leader\n", .{});
            } else {
                std.debug.print("corvo: leader is {s}\n", .{state.leader_id});
            }
        } else {
            std.debug.print("corvo: WARNING: no leader elected after 15s\n", .{});
        }
    }

    // --- HTTP Server ---
    var server = server_mod.Server.init(allocator, &store, .{
        .bind_address = bind,
        .port = port,
        .worker_count = worker_count,
        .rate_limit = .{
            .enabled = rate_limit_enabled,
            .write_rps = rate_limit_rps,
            .write_burst = rate_limit_rps * 2,
            .read_rps = rate_limit_rps * 2,
            .read_burst = rate_limit_rps * 4,
        },
    });
    server.scheduler = &sched;
    if (cluster_node) |*cn| {
        server.cluster = cn;
        cn.handler = engine.getHandler();
        engine.lease_check = cn.leaseCheck();
        // Wire pipeline ack callback for non-blocking strong durability.
        if (engine.pipeline) |*p| {
            cluster_mod.g_pipeline_for_ack = p;
        }
    }
    try server.start();
    defer server.stop();

    // --- Binary RPC Server ---
    const rpc_config = rpc_mod.RpcConfig{
        .bind_address = bind,
        .port = rpc_port,
    };

    var rpc_server: ?rpc_mod.RpcServer = null;
    var rpc_uring_server: ?*rpc_uring_mod.IoUringRpcServer = null;

    if (use_io_uring) {
        const s = try rpc_uring_mod.IoUringRpcServer.create(allocator, &store, rpc_config);
        try s.start();
        rpc_uring_server = s;
        std.debug.print("corvo: listening http={s}:{d} rpc={s}:{d} (io_uring)\n", .{ bind, port, bind, rpc_port });
    } else {
        rpc_server = rpc_mod.RpcServer.init(allocator, &store, rpc_config);
        try rpc_server.?.start();
        std.debug.print("corvo: listening http={s}:{d} rpc={s}:{d}\n", .{ bind, port, bind, rpc_port });
    }
    defer if (rpc_server) |*s| s.stop();
    defer if (rpc_uring_server) |s| s.stop();

    // --- Set up signal handling ---
    g_server = &server;

    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

    // --- Wait for signal ---
    while (running.load(.monotonic)) {
        std.Thread.sleep(1_000_000_000); // 1s
    }

    std.debug.print("\ncorvo: received signal, shutting down gracefully (timeout={d}s)...\n", .{shutdown_timeout_s});

    // Spawn a watchdog thread that force-exits after the timeout.
    const timeout_ns: u64 = @as(u64, shutdown_timeout_s) * 1_000_000_000;
    const watchdog = std.Thread.spawn(.{}, struct {
        fn run(ns: u64) void {
            std.Thread.sleep(ns);
            std.debug.print("corvo: shutdown timeout exceeded, forcing exit\n", .{});
            std.process.exit(1);
        }
    }.run, .{timeout_ns}) catch null;
    if (watchdog) |w| w.detach();

    // Stop accepting new connections and close active ones.
    server.stop();
    std.debug.print("corvo: http server stopped\n", .{});

    // Stop RPC servers.
    if (rpc_server) |*s| {
        s.stop();
        rpc_server = null;
    }
    if (rpc_uring_server) |s| {
        s.stop();
        rpc_uring_server = null;
    }

    // Stop scheduler (no more maintenance/cron ticks).
    sched.stop();

    // Flush mirror to ensure all pending writes are committed.
    if (mirror) |*m| {
        m.stop();
        std.debug.print("corvo: mirror flushed\n", .{});
    }

    // Stop engine pipeline (drains in-flight batches).
    engine.stopPipeline();
    std.debug.print("corvo: pipeline drained\n", .{});

    // Stop cluster node if running.
    if (cluster_node) |*cn| {
        cn.deinit();
        cluster_node = null;
    }

    std.debug.print("corvo: shutdown complete\n", .{});
}
