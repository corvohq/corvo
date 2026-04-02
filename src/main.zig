//! Corvo server — single-threaded pipeline over io_uring/kqueue.
//!
//! Single port handles both RPC (binary) and HTTP (JSON) via protocol detection.
//! Supports single-node and cluster mode (PBR with leader election).
//!
//! Configuration: defaults → config file (--config) → CLI args.
//!
//! Usage: corvo [options]
//!   --config <path>           Config file (key = value format)
//!   --bind <addr>             Listen address (default: 0.0.0.0)
//!   --port <port>             Listen port (default: 9878)
//!   --data-dir <dir>          Data directory (default: /tmp/corvo-data)
//!   --node-id <id>            Node ID for cluster mode (enables cluster)
//!   --peers <spec>            Comma-separated peer list: id@host:port,...
//!   --sync-repl               Enable sync replication
//!   --max-payload-size <n>    Max payload size in bytes (default: 65536)
//!   --max-conns <n>           Max concurrent connections (default: 4096)
//!   --max-queues <n>          Max number of queues (default: 100)
//!   --max-jobs <n>            Max total jobs (default: 0 = unlimited)
//!   --max-tags-per-queue <n>  Max fairness tags per queue (default: 1000)
//!   --admin-password <pw>     Admin password (locks UI + API, enables session auth)
//!   --help                    Show this help

const std = @import("std");
const talon = @import("talon");
const corvo = @import("corvo");

const config_mod = corvo.server_config;
const io_mod = corvo.io;
const kv = corvo.kv;
const rpc = corvo.rpc;
const handler_mod = corvo.handler;
const oplog_mod = corvo.oplog;
const notify_mod = corvo.notify;
const kv_read = corvo.kv_read;
const http_read = corvo.http_read;
const pipeline_mod = corvo.pipeline;
const cluster_mod = corvo.cluster;

const RealPipeline = pipeline_mod.Pipeline(io_mod.Backend);
const ServerConfig = config_mod.ServerConfig;

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

const max_peers = 6;

fn parsePeers(spec: []const u8, ids_out: *[max_peers][]const u8, addrs_out: *[max_peers]std.net.Address) !u8 {
    var count: u8 = 0;
    var rest = spec;

    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        const entry = rest[0..end];
        rest = if (end < rest.len) rest[end + 1 ..] else "";

        if (entry.len == 0) continue;

        const at_pos = std.mem.indexOfScalar(u8, entry, '@') orelse return error.InvalidPeerSpec;
        const id = entry[0..at_pos];
        const host_port = entry[at_pos + 1 ..];

        const colon_pos = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.InvalidPeerSpec;
        const host = host_port[0..colon_pos];
        const port_str = host_port[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPeerSpec;

        // Peer spec port is the cluster transport port directly.
        ids_out[count] = id;
        addrs_out[count] = try std.net.Address.parseIp(host, port);
        count += 1;
    }

    return count;
}

/// Resolve a DNS name to discover cluster peers.
/// Returns the total peer count (existing + discovered).
fn discoverPeers(
    allocator: std.mem.Allocator,
    dns_name: []const u8,
    cluster_port: u16,
    bind_addr: []const u8,
    http_port: u16,
    ids_out: *[max_peers][]const u8,
    addrs_out: *[max_peers]std.net.Address,
    id_bufs: *[max_peers][64]u8,
    existing_count: u8,
) u8 {
    // Resolve self address for filtering.
    const self_addr = std.net.Address.parseIp(bind_addr, http_port) catch return existing_count;

    // DNS name must be null-terminated for getaddrinfo.
    var name_buf: [256]u8 = undefined;
    if (dns_name.len >= name_buf.len) return existing_count;
    @memcpy(name_buf[0..dns_name.len], dns_name);
    name_buf[dns_name.len] = 0;

    const list = std.net.getAddressList(allocator, name_buf[0..dns_name.len :0], cluster_port) catch |err| {
        std.debug.print("corvo: DNS discovery failed for {s}: {}\n", .{ dns_name, err });
        return existing_count;
    };
    defer list.deinit();

    var count = existing_count;
    for (list.addrs) |addr| {
        if (count >= max_peers) break;

        // Filter out self.
        if (isSelfAddr(addr, self_addr)) continue;

        // Check for duplicates against existing peers.
        var dup = false;
        for (addrs_out[0..count]) |existing| {
            if (addr.eql(existing)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        // Generate peer ID from address (e.g., "10.0.0.2:10878").
        const id = std.fmt.bufPrint(&id_bufs[count], "{any}", .{addr}) catch continue;
        ids_out[count] = id;
        addrs_out[count] = addr;
        count += 1;
    }
    return count;
}

fn isSelfAddr(addr: std.net.Address, self_addr: std.net.Address) bool {
    // Compare IP bytes (ignore port since DNS may resolve to HTTP port).
    switch (addr.any.family) {
        std.posix.AF.INET => {
            // Check against 0.0.0.0 (bind-all) — any resolved IP is "self".
            if (self_addr.in.sa.addr == 0) return false; // Can't filter when binding to all.
            return addr.in.sa.addr == self_addr.in.sa.addr;
        },
        std.posix.AF.INET6 => {
            return std.mem.eql(u8, &addr.in6.sa.addr, &self_addr.in6.sa.addr);
        },
        else => return false,
    }
}

/// Try to join an existing cluster by sending POST /api/v1/cluster/join
/// to each discovered peer. Best-effort — failure is not fatal (we may
/// be the first node bootstrapping).
fn tryJoinCluster(
    peer_addrs: []const std.net.Address,
    node_id: []const u8,
    self_cluster_addr: std.net.Address,
) void {
    var body_buf: [512]u8 = undefined;
    var self_addr_buf: [64]u8 = undefined;
    const self_addr_str = std.fmt.bufPrint(&self_addr_buf, "{any}", .{self_cluster_addr}) catch return;

    const body = std.fmt.bufPrint(&body_buf,
        \\{{"node_id":"{s}","addr":"{s}"}}
    , .{ node_id, self_addr_str }) catch return;

    for (peer_addrs) |addr| {
        // Derive HTTP port from cluster port (cluster = http + 1000).
        const peer_http_port = addr.getPort() -| 1000;
        if (peer_http_port == 0) continue;

        // Build HTTP address for the peer.
        var peer_http_addr = addr;
        peer_http_addr.setPort(peer_http_port);

        // Simple TCP connection + HTTP POST.
        const stream = std.net.tcpConnectToAddress(peer_http_addr) catch continue;
        defer stream.close();

        var req_buf: [1024]u8 = undefined;
        const req = std.fmt.bufPrint(&req_buf,
            "POST /api/v1/cluster/join HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ body.len, body },
        ) catch continue;

        _ = stream.write(req) catch continue;

        var resp_buf: [1024]u8 = undefined;
        const n = stream.read(&resp_buf) catch continue;
        if (n > 0) {
            const resp = resp_buf[0..n];
            if (std.mem.indexOf(u8, resp, "200 OK") != null) {
                std.debug.print("corvo: joined cluster via {any}\n", .{peer_http_addr});
                return;
            }
            // Not leader — try next peer.
        }
    }

    std.debug.print("corvo: no existing cluster found, bootstrapping as single node\n", .{});
}

// ============================================================================
// Help
// ============================================================================

fn printHelp() void {
    std.debug.print(
        \\corvo — single-threaded pipeline server
        \\
        \\Usage: corvo [options]
        \\
        \\Options:
        \\  --config <path>           Config file (key = value format)
        \\  --bind <addr>             Listen address (default: 0.0.0.0)
        \\  --port <port>             Listen port (default: 9878)
        \\  --data-dir <dir>          Data directory (default: /tmp/corvo-data)
        \\  --max-payload-size <n>    Max payload bytes (default: 65536, max: 262144)
        \\  --max-conns <n>           Max connections (default: 4096)
        \\  --max-queues <n>          Max queues (default: 100)
        \\  --max-jobs <n>            Max total jobs (default: 0 = unlimited)
        \\  --max-tags-per-queue <n>  Max fairness tags per queue (default: 1000)
        \\  --purge-threshold <n>     Early purge when terminal count exceeds n (default: 10000)
        \\  --persist-completed       Keep completed jobs until purge (default: off)
        \\  --node-id <id>            Node ID (enables cluster mode)
        \\  --peers <spec>            Peers: id@host:port,id@host:port,...
        \\  --discover-dns-name <n>   DNS name for peer auto-discovery
        \\  --sync-repl               Enable sync replication
        \\  --admin-password <pw>     Admin password (locks UI + API)
        \\  --help                    Show this help
        \\
        \\Config file format:
        \\  # comment
        \\  key = value
        \\
        \\  See docs/pipeline-refactor-v2.md for config keys.
        \\
    , .{});
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    // --- Check for CLI subcommands before server startup ---
    {
        var peek = try std.process.argsWithAllocator(allocator);
        defer peek.deinit();
        _ = peek.next(); // skip program name
        if (peek.next()) |first_arg| {
            if (first_arg.len > 0 and first_arg[0] != '-') {
                corvo.cli.dispatch(first_arg, &peek);
                return;
            }
        }
    }

    var config = ServerConfig{};

    // --- First pass: find --config path ---
    var config_path_buf: [256]u8 = undefined;
    var config_path_len: usize = 0;
    {
        var scan = try std.process.argsWithAllocator(allocator);
        defer scan.deinit();
        _ = scan.next(); // skip program name
        while (scan.next()) |arg| {
            if (std.mem.eql(u8, arg, "--config")) {
                if (scan.next()) |path| {
                    const len = @min(path.len, config_path_buf.len);
                    @memcpy(config_path_buf[0..len], path[0..len]);
                    config_path_len = len;
                }
                break;
            }
        }
    }

    // --- Load config file (if specified) ---
    var file_buf: [8192]u8 = undefined;
    if (config_path_len > 0) {
        const path = config_path_buf[0..config_path_len];
        const file = std.fs.cwd().openFile(path, .{}) catch {
            std.debug.print("corvo: failed to open config file: {s}\n", .{path});
            return;
        };
        defer file.close();
        const n = file.readAll(&file_buf) catch {
            std.debug.print("corvo: failed to read config file: {s}\n", .{path});
            return;
        };
        config.loadFile(file_buf[0..n]) catch |err| {
            std.debug.print("corvo: config file error: {s}\n", .{@errorName(err)});
            return;
        };
    }

    // --- Second pass: CLI args override config file ---
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            _ = args.next(); // already handled
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--bind")) {
            config.bind = args.next() orelse {
                std.debug.print("--bind requires an argument\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse {
                std.debug.print("--port requires an argument\n", .{});
                return;
            };
            config.port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("invalid port: {s}\n", .{val});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            config.data_dir = args.next() orelse {
                std.debug.print("--data-dir requires an argument\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--no-mirror")) {
            // Kept for backward compat — no-op, mirror removed.
        } else if (std.mem.eql(u8, arg, "--node-id")) {
            config.node_id = args.next() orelse {
                std.debug.print("--node-id requires an argument\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--peers")) {
            config.peers = args.next() orelse {
                std.debug.print("--peers requires an argument\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--discover-dns-name")) {
            config.discover_dns_name = args.next() orelse {
                std.debug.print("--discover-dns-name requires an argument\n", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--sync-repl")) {
            config.sync_replication = true;
        } else if (std.mem.eql(u8, arg, "--max-payload-size")) {
            const val = args.next() orelse {
                std.debug.print("--max-payload-size requires an argument\n", .{});
                return;
            };
            config.max_payload_size = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid max-payload-size: {s}\n", .{val});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--max-conns")) {
            const val = args.next() orelse {
                std.debug.print("--max-conns requires an argument\n", .{});
                return;
            };
            config.max_conns = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("invalid max-conns: {s}\n", .{val});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--max-queues")) {
            const val = args.next() orelse {
                std.debug.print("--max-queues requires an argument\n", .{});
                return;
            };
            config.max_queues = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid max-queues: {s}\n", .{val});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--max-jobs")) {
            const val = args.next() orelse {
                std.debug.print("--max-jobs requires an argument\n", .{});
                return;
            };
            config.max_jobs = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid max-jobs: {s}\n", .{val});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--max-tags-per-queue")) {
            const val = args.next() orelse {
                std.debug.print("--max-tags-per-queue requires an argument\n", .{});
                return;
            };
            config.max_tags_per_queue = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid max-tags-per-queue: {s}\n", .{val});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--purge-threshold")) {
            const val = args.next() orelse {
                std.debug.print("--purge-threshold requires an argument\n", .{});
                return;
            };
            config.purge_threshold = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid purge-threshold: {s}\n", .{val});
                return;
            };
        } else if (std.mem.eql(u8, arg, "--persist-completed")) {
            config.persist_completed = true;
        } else if (std.mem.eql(u8, arg, "--admin-password")) {
            config.admin_password = args.next() orelse {
                std.debug.print("--admin-password requires an argument\n", .{});
                return;
            };
        }
    }

    // --- Validate config ---
    config.validate() catch |err| {
        std.debug.print("corvo: config error: {s}\n", .{@errorName(err)});
        return;
    };

    const cluster_mode = config.clusterMode();

    std.debug.print("corvo: starting (bind={s}, port={d}, data={s}{s})\n", .{
        config.bind, config.port, config.data_dir, if (cluster_mode) ", cluster" else "",
    });

    // --- Ensure data directory exists ---
    std.fs.cwd().makePath(config.data_dir) catch {};

    // --- Open Talon DB ---
    std.debug.print("corvo: opening data store ({s}/kv)...\n", .{config.data_dir});
    var kv_path_buf: [256]u8 = undefined;
    const kv_path = std.fmt.bufPrint(&kv_path_buf, "{s}/kv", .{config.data_dir}) catch unreachable;
    const db = try talon.DB.open(allocator, kv_path, .{});
    defer db.close();

    const kvstore = kv.Store.init(db);
    var stores = [1]kv.Store{kvstore};

    // --- OpHandler ---
    std.debug.print("corvo: rebuilding state...\n", .{});
    var handler = handler_mod.OpHandler.init(allocator);
    handler.max_queues = config.max_queues;
    handler.max_jobs = config.max_jobs;
    handler.max_tags_per_queue = config.max_tags_per_queue;
    handler.persist_completed = config.persist_completed;
    handler.pending.max_queues = config.max_queues;
    defer handler.deinit();
    handler.rebuildState(&stores);

    // --- Oplog ---
    var oplog_path_buf: [256]u8 = undefined;
    const oplog_path_slice = std.fmt.bufPrint(&oplog_path_buf, "{s}/oplog", .{config.data_dir}) catch unreachable;
    var oplog_path_z: [257]u8 = undefined;
    @memcpy(oplog_path_z[0..oplog_path_slice.len], oplog_path_slice);
    oplog_path_z[oplog_path_slice.len] = 0;

    var oplog = oplog_mod.Log.init(allocator, .{ .now_fn = &realClock }, oplog_path_z[0..oplog_path_slice.len :0], 8192);
    defer oplog.deinit();

    // --- QueueNotifier ---
    var notify = notify_mod.QueueNotifier.init(allocator);
    notify.max_queues = config.max_queues;
    defer notify.deinit();

    // --- KV reader (reads directly from Talon KV store) ---
    var kv_reader = kv_read.Reader.init(&stores[0]);

    // --- Cluster setup (optional) ---
    var cluster_node: ?cluster_mod.ClusterNode = null;
    var repl_hook: ?pipeline_mod.ReplHook = null;

    if (cluster_mode) {
        var peer_ids: [max_peers][]const u8 = undefined;
        var peer_addrs: [max_peers]std.net.Address = undefined;
        var peer_count: u8 = 0;

        // Static peers from --peers flag.
        if (config.peers.len > 0) {
            peer_count = parsePeers(config.peers, &peer_ids, &peer_addrs) catch {
                std.debug.print("invalid --peers format (expected: id@host:port,...)\n", .{});
                return;
            };
        }

        // Cluster transport binds on server port + 1000.
        const cluster_port = config.resolvedClusterPort();
        const cluster_bind_addr = try std.net.Address.parseIp(config.bind, cluster_port);

        // DNS discovery — resolve DNS name to find peers.
        // Peer IDs are generated from the address (host:cluster_port) since
        // we don't know their node IDs until they join.
        var dns_id_bufs: [max_peers][64]u8 = undefined;
        if (config.discover_dns_name.len > 0) {
            const discovered = discoverPeers(
                allocator,
                config.discover_dns_name,
                cluster_port,
                config.bind,
                config.port,
                &peer_ids,
                &peer_addrs,
                &dns_id_bufs,
                peer_count,
            );
            if (discovered > peer_count) {
                std.debug.print("corvo: discovered {d} peers via DNS ({s})\n", .{
                    discovered - peer_count, config.discover_dns_name,
                });
                peer_count = discovered;
            } else {
                std.debug.print("corvo: no new peers discovered via DNS ({s})\n", .{
                    config.discover_dns_name,
                });
            }
        }

        cluster_node = cluster_mod.ClusterNode.init(allocator, &stores, .{
            .node_id = config.node_id,
            .peer_ids = peer_ids[0..peer_count],
            .peer_addrs = peer_addrs[0..peer_count],
            .bind_addr = cluster_bind_addr,
            .config_hash = config.clusterHash(),
        });

        try cluster_node.?.start();
        repl_hook = cluster_node.?.replHook();
        http_read.g_cluster_node = &(cluster_node.?);

        // If we discovered peers via DNS, try to join the cluster.
        // The join request tells the leader about us so it adds us as a peer.
        if (config.discover_dns_name.len > 0 and peer_count > 0) {
            tryJoinCluster(
                peer_addrs[0..peer_count],
                config.node_id,
                cluster_bind_addr,
            );
        }

        std.debug.print("corvo: cluster node={s}, peers={d}, transport=:{d}, config_hash={x}\n", .{
            config.node_id, peer_count, cluster_port, config.clusterHash(),
        });
    }
    defer if (cluster_node) |*cn| cn.deinit();

    // --- Create listen socket ---
    const addr = try std.net.Address.parseIp(config.bind, config.port);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const listen_fd = listener.stream.handle;

    // --- IO backend ---
    // Buffer sizes derived from max_payload_size: must fit a complete frame
    // (header + payload) plus headroom for protocol framing.
    const buf_size: u32 = config.max_payload_size + @as(u32, rpc.FRAME_HEADER_SIZE) + 1024;
    var io_backend = try io_mod.Backend.init(allocator, .{
        .listen_fd = listen_fd,
        .max_conns = config.max_conns,
        .recv_buf_size = buf_size,
        .send_buf_size = buf_size,
    });
    defer io_backend.deinit(allocator);

    // Seed the first accept
    io_backend.queueAccept();
    io_backend.submit();

    // --- Pipeline (heap-allocated: ~5MB struct, too large for thread stack) ---
    var pipeline = RealPipeline.initHeap(
        allocator,
        &io_backend,
        &handler,
        &stores,
        &oplog,
        &notify,
        &kv_reader,
        .{
            .clock_fn = &realClock,
            .max_payload_size = config.max_payload_size,
            .promote_interval_ns = config.promote_interval_ns,
            .reclaim_interval_ns = config.reclaim_interval_ns,
            .unique_interval_ns = config.unique_interval_ns,
            .rate_limit_interval_ns = config.rate_limit_interval_ns,
            .expire_interval_ns = config.expire_interval_ns,
            .purge_interval_ns = config.purge_interval_ns,
            .purge_retention_ns = config.purge_retention_ns,
            .workers_interval_ns = config.workers_interval_ns,
            .webhook_interval_ns = config.workers_interval_ns, // same as workers (1s default)
            .worker_timeout_ns = config.worker_timeout_ns,
            .repl_hook = repl_hook,
            .sync_replication = config.sync_replication,
            .coalesce_window_ns = if (config.sync_replication) 200_000 else 0,
            .admin_password = config.admin_password,
        },
    );
    defer pipeline.destroyHeap();

    // Run initial maintenance before accepting connections.
    std.debug.print("corvo: running startup maintenance...\n", .{});
    pipeline.warmup();

    // Wire cluster ack notification to pipeline's atomic + oplog for retry.
    if (cluster_mode) {
        cluster_mod.g_ack_seq_ptr = pipeline.ackSeqPtr();
        cluster_node.?.oplog = &oplog;
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
    var cluster_info: http_read.ClusterInfo = undefined;
    if (cluster_node) |*cn| {
        std.debug.print("corvo: waiting for leader election...\n", .{});
        if (!cn.waitForLeader(30000)) {
            std.debug.print("corvo: leader election timed out\n", .{});
            return;
        }
        const state = cn.election.currentState();
        std.debug.print("corvo: leader elected (epoch={d}, leader={s})\n", .{
            state.epoch, if (state.leader_id.len > 0) state.leader_id else "(self)",
        });
        cluster_info = .{
            .node_id = config.node_id,
            .is_leader = &cn.is_leader_flag,
            .election = &cn.election,
            .events = &cn.events,
            .peer_count = @intCast(cn.config.peer_ids.len),
        };
        http_read.g_cluster_info = &cluster_info;
    }

    // --- Admin auth + config ---
    http_read.g_admin_password = config.admin_password;
    http_read.g_config = &config;
    corvo.http_ui.g_auth_enabled = config.admin_password.len > 0;
    corvo.http_ui.g_persist_completed = config.persist_completed;
    corvo.http_ui.g_metrics = &handler.metrics;

    std.debug.print("corvo: listening on {s}:{d} (rpc+http)\n", .{ config.bind, config.port });

    // --- Tick loop ---
    while (running.load(.monotonic)) {
        pipeline.tick();
    }

    std.debug.print("\ncorvo: shutting down ({d} ticks, {d} ops)\n", .{
        pipeline.ticks_total, pipeline.applied_total,
    });
}
