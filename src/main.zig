//! Corvo server — single-threaded pipeline over io_uring/kqueue.
//!
//! Single port handles both RPC (binary) and HTTP (JSON) via protocol detection.
//! Supports single-node and cluster mode (raft consensus; see
//! docs/raft-wiring.md).
//!
//! Configuration: defaults → config file (--config) → CLI args.
//!
//! Usage: corvo [options]
//!   --config <path>           Config file (key = value format)
//!   --bind <addr>             Listen address (default: 0.0.0.0)
//!   --port <port>             Listen port (default: 9878)
//!   --data-dir <dir>          Data directory (default: /tmp/corvo-data)
//!   --sync                    fdatasync on every commit (default: off)
//!   --node-id <id>            Node ID (enables cluster mode)
//!   --peers <spec>            Peer list: id[:uuidhex]@host:port,... (client addrs)
//!   --cluster-id <n>          Cluster identifier (u64, required in cluster mode)
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
const notify_mod = corvo.notify;
const kv_read = corvo.kv_read;
const http_read = corvo.http_read;
const pipeline_mod = corvo.pipeline;
const raft_host_mod = corvo.raft_host;
const raft_runtime_mod = corvo.raft_runtime;

const RealPipeline = pipeline_mod.Pipeline(io_mod.Backend);
const ServerConfig = config_mod.ServerConfig;
const RaftHost = raft_host_mod.RaftHost;

// RaftIface adapter — bridges the pipeline's consensus vtable to RaftHost.
fn raftProposeFn(ptr: *anyopaque, muts: []const kv.Mutation) ?*pipeline_mod.ProposeToken {
    const host: *RaftHost = @ptrCast(@alignCast(ptr));
    return host.proposeAsync(muts) catch |err| switch (err) {
        // Raft-inbox backpressure — retryable. The pipeline bounds its
        // in-flight proposal window, so null is reported there as
        // "raft inbox full"; keep that message accurate for this case only.
        error.InboxFull => null,
        // Allocation failure copying the proposal is NOT backpressure —
        // conflating it with InboxFull would surface as a misleading
        // "raft inbox full" panic. Fail-stop with the real cause.
        error.OutOfMemory => @panic("corvo: out of memory copying raft proposal"),
        // Lifecycle errors from the shared HostError set: proposeAsync never
        // returns these, and main only wires this fn after host.start().
        error.AlreadyStarted, error.NotStarted => unreachable,
    };
}

fn raftIsLeaderFn(ptr: *anyopaque) bool {
    const host: *RaftHost = @ptrCast(@alignCast(ptr));
    return host.isLeader();
}

var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn handleSignal(_: c_int) callconv(.c) void {
    running.store(false, .monotonic);
}

fn realClock() i64 {
    return @intCast(std.time.nanoTimestamp());
}

// ============================================================================
// Peer parsing: "id[:uuidhex]@host:port" — host:port is the peer's CLIENT
// address; the raft transport dials port + 1000 (resolvedClusterPort
// convention). uuid defaults to deriveUuid(id) for static clusters.
// ============================================================================

const max_peers = 6;

const ParsedPeer = struct {
    spec: raft_host_mod.PeerSpec,
    /// Raft transport address (client port + 1000).
    raft_addr: std.net.Address,
};

fn parsePeers(spec: []const u8, out: *[max_peers]ParsedPeer) !u8 {
    var count: u8 = 0;
    var rest = spec;

    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
        const entry = rest[0..end];
        rest = if (end < rest.len) rest[end + 1 ..] else "";

        if (entry.len == 0) continue;
        if (count >= max_peers) return error.TooManyPeers;

        const at_pos = std.mem.indexOfScalar(u8, entry, '@') orelse return error.InvalidPeerSpec;
        var id = entry[0..at_pos];
        const host_port = entry[at_pos + 1 ..];

        // Optional explicit uuid: "id:uuidhex".
        var uuid: u128 = 0;
        if (std.mem.indexOfScalar(u8, id, ':')) |colon| {
            uuid = std.fmt.parseInt(u128, id[colon + 1 ..], 16) catch return error.InvalidPeerSpec;
            if (uuid == 0) return error.InvalidPeerSpec;
            id = id[0..colon];
        }
        if (id.len == 0) return error.InvalidPeerSpec;
        if (uuid == 0) uuid = raft_host_mod.deriveUuid(id);

        const colon_pos = std.mem.lastIndexOfScalar(u8, host_port, ':') orelse return error.InvalidPeerSpec;
        const host = host_port[0..colon_pos];
        const port_str = host_port[colon_pos + 1 ..];
        const client_port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPeerSpec;
        // The raft transport dials client port + 1000, which must itself fit
        // in a u16. Peer specs are operator input (boundary): reject instead
        // of saturating, which would silently collide ports > 64535 on 65535.
        if (client_port > std.math.maxInt(u16) - 1000) return error.InvalidPeerSpec;

        var addr = try std.net.Address.parseIp(host, client_port);
        addr.setPort(client_port + 1000);

        out[count] = .{
            .spec = .{ .id = id, .uuid = uuid },
            .raft_addr = addr,
        };
        count += 1;
    }

    return count;
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
        \\  --sync                    fdatasync on every commit (default: off; recommended
        \\                            for cluster production — see docs/operating-corvo.md)
        \\  --max-payload-size <n>    Max payload bytes (default: 65536, max: 262144)
        \\  --max-conns <n>           Max connections (default: 4096)
        \\  --max-queues <n>          Max queues (default: 100)
        \\  --max-jobs <n>            Max total jobs (default: 0 = unlimited)
        \\  --max-tags-per-queue <n>  Max fairness tags per queue (default: 1000)
        \\  --purge-threshold <n>     Early purge when terminal count exceeds n (default: 10000)
        \\  --persist-completed       Keep completed jobs until purge (default: off)
        \\  --node-id <id>            Node ID (enables cluster mode)
        \\  --peers <spec>            Peers: id[:uuidhex]@host:port,... (client addrs;
        \\                            raft transport uses port + 1000)
        \\  --cluster-id <n>          Cluster identifier (u64, required in cluster mode)
        \\  --admin-password <pw>     Admin password (locks UI + API)
        \\  --cluster-secret <s>      Shared secret authenticating peer connections
        \\                            (or set CORVO_CLUSTER_SECRET)
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
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const val = args.next() orelse {
                std.debug.print("--port requires an argument\n", .{});
                                std.process.exit(1);
            };
            config.port = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("invalid port: {s}\n", .{val});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            config.data_dir = args.next() orelse {
                std.debug.print("--data-dir requires an argument\n", .{});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--no-mirror")) {
            // Kept for backward compat — no-op, mirror removed.
        } else if (std.mem.eql(u8, arg, "--node-id")) {
            config.node_id = args.next() orelse {
                std.debug.print("--node-id requires an argument\n", .{});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--peers")) {
            config.peers = args.next() orelse {
                std.debug.print("--peers requires an argument\n", .{});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--cluster-id")) {
            const val = args.next() orelse {
                std.debug.print("--cluster-id requires an argument\n", .{});
                                std.process.exit(1);
            };
            config.cluster_id = std.fmt.parseInt(u64, val, 10) catch {
                std.debug.print("invalid cluster-id: {s}\n", .{val});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--max-payload-size")) {
            const val = args.next() orelse {
                std.debug.print("--max-payload-size requires an argument\n", .{});
                                std.process.exit(1);
            };
            config.max_payload_size = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid max-payload-size: {s}\n", .{val});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--max-conns")) {
            const val = args.next() orelse {
                std.debug.print("--max-conns requires an argument\n", .{});
                                std.process.exit(1);
            };
            config.max_conns = std.fmt.parseInt(u16, val, 10) catch {
                std.debug.print("invalid max-conns: {s}\n", .{val});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--max-queues")) {
            const val = args.next() orelse {
                std.debug.print("--max-queues requires an argument\n", .{});
                                std.process.exit(1);
            };
            config.max_queues = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid max-queues: {s}\n", .{val});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--max-jobs")) {
            const val = args.next() orelse {
                std.debug.print("--max-jobs requires an argument\n", .{});
                                std.process.exit(1);
            };
            config.max_jobs = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid max-jobs: {s}\n", .{val});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--max-tags-per-queue")) {
            const val = args.next() orelse {
                std.debug.print("--max-tags-per-queue requires an argument\n", .{});
                                std.process.exit(1);
            };
            config.max_tags_per_queue = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid max-tags-per-queue: {s}\n", .{val});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--purge-threshold")) {
            const val = args.next() orelse {
                std.debug.print("--purge-threshold requires an argument\n", .{});
                                std.process.exit(1);
            };
            config.purge_threshold = std.fmt.parseInt(u32, val, 10) catch {
                std.debug.print("invalid purge-threshold: {s}\n", .{val});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--persist-completed")) {
            config.persist_completed = true;
        } else if (std.mem.eql(u8, arg, "--sync")) {
            config.sync = true;
        } else if (std.mem.eql(u8, arg, "--admin-password")) {
            config.admin_password = args.next() orelse {
                std.debug.print("--admin-password requires an argument\n", .{});
                                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--cluster-secret")) {
            config.cluster_secret = args.next() orelse {
                std.debug.print("--cluster-secret requires an argument\n", .{});
                                std.process.exit(1);
            };
        } else {
            // CLI input is a boundary: an unrecognized flag (including
            // --key=value forms — flags take space-separated values) must
            // fail loudly, never start the server with defaults.
            std.debug.print("unknown argument: {s} (see --help)\n", .{arg});
            std.process.exit(1);
        }
    }

    // Env fallback for the cluster secret (avoids the secret appearing in the
    // process argv / command line). Explicit --cluster-secret takes precedence.
    if (config.cluster_secret.len == 0) {
        if (std.process.getEnvVarOwned(allocator, "CORVO_CLUSTER_SECRET")) |v| {
            config.cluster_secret = v; // lives for the process lifetime
        } else |_| {}
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
    // --sync: fdatasync on every commit. Off by default (opt-in); without it
    // a power loss can drop committed writes, including persisted raft state
    // — see the --sync section in docs/operating-corvo.md.
    const db = try talon.DB.open(allocator, kv_path, .{ .sync = config.sync });
    defer db.close();

    const kvstore = kv.Store.init(db);
    var stores = [1]kv.Store{kvstore};

    // --- OpHandler ---
    // In cluster mode the in-memory state is NOT rebuilt at boot: the raft
    // thread may still be applying committed entries, and a follower's
    // handler state is unused (writes are rejected with MSG_NOT_LEADER).
    // The pipeline rebuilds it on leadership acquisition, after the barrier
    // proposal commits (docs/raft-wiring.md).
    // Heap-allocated for the same reason as the Pipeline below: OpHandler
    // embeds the indexer's multi-megabyte effect buffers — far too large for
    // the thread stack (a stack OpHandler overflows the 8 MB default limit
    // on the first deep request path and dies with a silent SIGSEGV).
    const handler = try allocator.create(handler_mod.OpHandler);
    defer allocator.destroy(handler);
    handler.* = handler_mod.OpHandler.init(allocator);
    handler.max_queues = config.max_queues;
    handler.max_jobs = config.max_jobs;
    handler.max_tags_per_queue = config.max_tags_per_queue;
    handler.persist_completed = config.persist_completed;
    handler.pending.max_queues = config.max_queues;
    defer handler.deinit();
    if (!cluster_mode) {
        std.debug.print("corvo: rebuilding state...\n", .{});
        handler.rebuildState(&stores);
    }

    // --- QueueNotifier ---
    var notify = notify_mod.QueueNotifier.init(allocator);
    notify.max_queues = config.max_queues;
    defer notify.deinit();

    // --- KV reader (reads directly from Talon KV store) ---
    var kv_reader = kv_read.Reader.init(&stores[0]);

    // --- Raft cluster setup (optional) ---
    var raft_host: ?*RaftHost = null;
    var raft_iface: ?pipeline_mod.RaftIface = null;
    var cluster_peer_count: u8 = 0;
    // Serializes talon access between the pipeline thread and the raft
    // thread (talon is single-threaded; see docs/raft-wiring.md).
    var db_lock: std.Thread.Mutex = .{};

    if (cluster_mode) {
        var parsed_peers: [max_peers]ParsedPeer = undefined;
        var peer_count: u8 = 0;
        if (config.peers.len > 0) {
            peer_count = parsePeers(config.peers, &parsed_peers) catch {
                std.debug.print("invalid --peers format (expected: id[:uuidhex]@host:port,...)\n", .{});
                return;
            };
        }
        cluster_peer_count = peer_count;

        var peer_specs: [max_peers]raft_host_mod.PeerSpec = undefined;
        for (parsed_peers[0..peer_count], 0..) |p, i| peer_specs[i] = p.spec;

        // Raft transport binds on server port + 1000.
        const cluster_port = config.resolvedClusterPort();
        const cluster_bind_addr = try std.net.Address.parseIp(config.bind, cluster_port);

        // Buffers must fit a full raft frame (entries carry whole batches
        // of encoded mutations).
        const raft_buf_size: u32 = 2 * 1024 * 1024;

        const host = try RaftHost.create(allocator, db, .{
            .runtime = .{
                .node_id = config.node_id,
                .instance_uuid = raft_host_mod.deriveUuid(config.node_id),
                .cluster_id = config.cluster_id,
                .peers = peer_specs[0..peer_count],
                .raft_config = raft_runtime_mod.defaultConfig(),
            },
            .peer_net = .{
                .self_id = config.node_id,
                .bind_addr = cluster_bind_addr,
                .recv_buf_size = raft_buf_size,
                .send_buf_size = raft_buf_size,
                .cluster_secret = config.cluster_secret,
                // Shared-config hash: peers exchange this in the handshake on
                // every connection (secret or not) and refuse a node whose
                // shared cluster params differ (would diverge on replicated
                // maintenance). See config.zig clusterHash() and
                // docs/raft-wiring.md.
                .config_hash = config.clusterHash(),
            },
            .db_lock = &db_lock,
        });
        for (parsed_peers[0..peer_count]) |p| {
            try host.registerPeer(p.spec.id, p.raft_addr);
        }
        try host.start();
        raft_host = host;
        raft_iface = .{
            .ptr = @ptrCast(host),
            .propose_fn = &raftProposeFn,
            .is_leader_fn = &raftIsLeaderFn,
        };
        http_read.g_raft_host = host;

        std.debug.print("corvo: raft node={s}, cluster_id={d}, peers={d}, transport=:{d}\n", .{
            config.node_id, config.cluster_id, peer_count, cluster_port,
        });
    }
    defer if (raft_host) |h| h.destroy();

    // --- Create listen socket ---
    const addr = try std.net.Address.parseIp(config.bind, config.port);
    var listener = try addr.listen(.{ .reuse_address = true });
    defer listener.deinit();
    const listen_fd = listener.stream.handle;

    // --- IO backend ---
    // Buffer sizes must fit a complete frame plus an HTTP fetch response's JSON
    // fields and headers around a maximum-size payload.
    const buf_size: u32 = config.max_payload_size + @as(u32, rpc.FRAME_HEADER_SIZE) + 4096;
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
        handler,
        &stores,
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
            .purge_threshold = config.purge_threshold,
            .workers_interval_ns = config.workers_interval_ns,
            .cron_interval_ns = config.cron_interval_ns,
            .webhook_interval_ns = config.workers_interval_ns, // same as workers (1s default)
            .worker_timeout_ns = config.worker_timeout_ns,
            .raft = raft_iface,
            .db_lock = if (cluster_mode) &db_lock else null,
            .coalesce_window_ns = if (cluster_mode) 200_000 else 0,
            .admin_password = config.admin_password,
        },
    );
    defer pipeline.destroyHeap();

    // Run initial maintenance before accepting connections. Cluster mode
    // skips this: warmup mutates the KV outside the raft log, and the
    // pipeline runs the equivalent on leadership acquisition.
    if (!cluster_mode) {
        std.debug.print("corvo: running startup maintenance...\n", .{});
        pipeline.warmup();
    }

    // --- Signal handling ---
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);

    // Cluster mode serves immediately: writes get MSG_NOT_LEADER/503 until
    // this node acquires leadership; reads are served from the local KV.
    var cluster_info: http_read.ClusterInfo = undefined;
    if (raft_host) |host| {
        cluster_info = .{
            .node_id = config.node_id,
            .is_leader = &host.is_leader,
            .peer_count = cluster_peer_count,
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
