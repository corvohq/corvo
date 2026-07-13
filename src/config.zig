//! Server configuration — config file parser + cluster config hash.
//!
//! Config file: simple key = value format, # comments, blank lines.
//! Load order: defaults → file (--config) → CLI args.
//!
//! Cluster identity: an explicit `cluster-id` (u64, non-zero) shared by all
//! voters; the raft layer drops cross-cluster traffic.
//!
//! Cluster config hash: `clusterHash()` folds the *shared* parameters — the
//! ones that govern replicated state-machine and maintenance behavior (payload
//! bounds, queue/job/tag limits, completion persistence, and every maintenance
//! interval that runs on the leader and replicates through the raft log). All
//! voters must agree on these: a node whose replicated maintenance behaves
//! differently (e.g. a shorter purge retention) can, once it wins an election,
//! delete or mutate terminal jobs cluster-wide THROUGH the raft log —
//! unrecoverable replicated data loss. Nodes exchange the hash inside the
//! HMAC-bound peer handshake (raft_net.zig), which runs on every connection
//! whether or not a cluster secret is set; a mismatch refuses the peer
//! connection, so a misconfigured node cannot join, replicate, or win an
//! election. Node-local settings (bind, ports, data dir, conn caps, identity,
//! the secret itself) are deliberately excluded — they legitimately differ
//! per node.

const std = @import("std");
const assert = @import("assert.zig");
const rpc = @import("rpc.zig");

pub const ServerConfig = struct {
    // ================================================================
    // Node-local settings (NOT included in cluster hash)
    // ================================================================

    bind: []const u8 = "0.0.0.0",
    port: u16 = 9878,
    data_dir: []const u8 = "/tmp/corvo-data",
    mirror: bool = true,
    max_conns: u16 = 4096,
    /// fdatasync the KV store on every commit (talon's Options.sync). Off by
    /// default: fsync bounds every commit by device flush latency. Without it
    /// a power loss can drop recently-committed writes — including persisted
    /// raft state (votes, log entries), which violates raft's persistence
    /// assumptions in cluster mode. Recommended for cluster production; see
    /// docs/operating-corvo.md.
    sync: bool = false,

    // Auth
    admin_password: []const u8 = "",

    // Cluster identity (node-local). node_id enables raft mode; peer specs
    // are `id[:uuidhex]@host:port` with the peer's CLIENT address (the raft
    // transport binds/dials on port + 1000, see resolvedClusterPort).
    node_id: []const u8 = "",
    peers: []const u8 = "",
    cluster_port: u16 = 0, // 0 = server port + 1000
    /// Cluster identifier shared by all voters; raft drops cross-cluster
    /// traffic. Required (non-zero) in cluster mode.
    cluster_id: u64 = 0,
    /// Shared secret authenticating peer connections (HMAC challenge-response
    /// on the cluster port). Empty = unauthenticated (single-node / trusted net).
    /// Set via --cluster-secret or the CORVO_CLUSTER_SECRET env var.
    cluster_secret: []const u8 = "",

    // ================================================================
    // Shared settings (included in cluster hash — must match across nodes)
    // ================================================================

    max_payload_size: u32 = 64 * 1024,
    max_queues: u32 = 100,
    max_jobs: u32 = 0, // 0 = unlimited
    max_tags_per_queue: u32 = 1000,
    persist_completed: bool = false,

    // Maintenance intervals (nanoseconds, 0 = disabled)
    promote_interval_ns: u64 = 1_000_000_000,
    reclaim_interval_ns: u64 = 1_000_000_000,
    unique_interval_ns: u64 = 30_000_000_000,
    rate_limit_interval_ns: u64 = 30_000_000_000,
    expire_interval_ns: u64 = 10_000_000_000,
    purge_interval_ns: u64 = 3_600_000_000_000,
    purge_retention_ns: u64 = 14 * 24 * 3_600_000_000_000, // 14 days — terminal jobs older than this are purged
    purge_threshold: u32 = 10_000, // 0 = disabled; purge early when terminal job count exceeds this
    workers_interval_ns: u64 = 30_000_000_000, // 30s — clean up stale workers
    worker_timeout_ns: u64 = 60_000_000_000, // 60s — workers with no heartbeat for this long are removed
    cron_interval_ns: u64 = 10_000_000_000, // 10s — scan cron schedules for due fires (minute resolution)

    // ================================================================
    // Accessors
    // ================================================================

    pub fn clusterMode(self: *const ServerConfig) bool {
        return self.node_id.len > 0;
    }

    /// Resolved cluster port: explicit value or server port + 1000.
    pub fn resolvedClusterPort(self: *const ServerConfig) u16 {
        return if (self.cluster_port > 0) self.cluster_port else self.port +| 1000;
    }

    // ================================================================
    // Cluster config hash
    // ================================================================

    /// FNV-1a hash of the shared parameters every voter must agree on.
    /// Exchanged inside the authenticated raft peer handshake
    /// (raft_net.zig); a mismatch refuses the connection so a node whose
    /// replicated behavior would diverge cannot join, replicate, or win an
    /// election. The order below is part of the wire contract — never
    /// reorder or drop a field without bumping all nodes together.
    ///
    /// Per-field audit — a field is INCLUDED iff two nodes disagreeing on it
    /// produces divergent *replicated* state or maintenance (which runs only
    /// on the leader and ships through the raft log, so a failover to a
    /// differently-configured node corrupts or destroys committed data):
    ///
    ///   INCLUDED (shared, replicated):
    ///     max_payload_size    — boundary bound on accepted job payloads; a
    ///                           new leader with a smaller cap rejects writes
    ///                           its predecessor accepted and replicated.
    ///     max_queues          — replicated queue-count limit.
    ///     max_jobs            — global cap over all KV jobs; a lower cap on a
    ///                           new leader rejects/evicts replicated jobs.
    ///     max_tags_per_queue  — replicated per-queue tag limit.
    ///     persist_completed   — decides auto-delete of completed jobs on ack;
    ///                           divergence means a new leader deletes (through
    ///                           the log) jobs a peer expects retained. (Master
    ///                           omitted this — a latent hole; added here.)
    ///     promote/reclaim/unique/rate_limit/expire interval_ns — maintenance
    ///                           loops that mutate jobs on the leader and
    ///                           replicate; divergent cadence => divergent
    ///                           replicated effects across failover.
    ///     purge_interval_ns / purge_retention_ns / purge_threshold — the
    ///                           purge pass deletes terminal jobs THROUGH the
    ///                           log; a node with a short retention that wins an
    ///                           election wipes terminal jobs cluster-wide. This
    ///                           is the exact data-loss the check exists for.
    ///                           (Master hashed purge_threshold but NOT the
    ///                           retention — the most dangerous omission.)
    ///     workers_interval_ns / worker_timeout_ns — stale-worker cleanup (and,
    ///                           reusing workers_interval, webhook dispatch)
    ///                           runs on the leader and replicates worker/record
    ///                           deletes; divergence removes records a peer keeps.
    ///     cron_interval_ns    — cron scanning fires jobs (enqueue mutations)
    ///                           through the log on the leader; kept in lockstep
    ///                           with the other maintenance cadences so failover
    ///                           behavior is identical.
    ///
    ///   EXCLUDED (node-local, legitimately per-node):
    ///     bind, port, data_dir, cluster_port — network/disk placement.
    ///     mirror, max_conns                  — local resource knobs.
    ///     sync                               — local durability knob (fsync on
    ///                                          commit); affects crash recovery
    ///                                          of THIS node's disk, not the
    ///                                          replicated state machine.
    ///     admin_password                     — local auth; must never be hashed
    ///                                          or leaked onto the wire.
    ///     node_id, peers                     — per-node identity/topology view.
    ///     cluster_id                         — cluster identity, already
    ///                                          enforced in every frame header
    ///                                          (raft drops cross-cluster traffic).
    ///     cluster_secret                     — the HMAC key itself; a mismatch
    ///                                          already fails the handshake.
    pub fn clusterHash(self: *const ServerConfig) u64 {
        var h: u64 = 0xcbf29ce484222325; // FNV-1a offset basis
        h = fnvU32(h, self.max_payload_size);
        h = fnvU32(h, self.max_queues);
        h = fnvU32(h, self.max_jobs);
        h = fnvU32(h, self.max_tags_per_queue);
        h = fnvByte(h, @intFromBool(self.persist_completed));
        h = fnvU64(h, self.promote_interval_ns);
        h = fnvU64(h, self.reclaim_interval_ns);
        h = fnvU64(h, self.unique_interval_ns);
        h = fnvU64(h, self.rate_limit_interval_ns);
        h = fnvU64(h, self.expire_interval_ns);
        h = fnvU64(h, self.purge_interval_ns);
        h = fnvU64(h, self.purge_retention_ns);
        h = fnvU32(h, self.purge_threshold);
        h = fnvU64(h, self.workers_interval_ns);
        h = fnvU64(h, self.worker_timeout_ns);
        h = fnvU64(h, self.cron_interval_ns);
        return h;
    }

    // ================================================================
    // Config file parsing
    // ================================================================

    pub const ParseError = error{
        MissingSeparator,
        EmptyKey,
        UnknownKey,
        InvalidValue,
    };

    pub const ValidateError = error{
        InvalidMaxPayloadSize,
        InvalidMaxConns,
        InvalidMaxQueues,
        ClusterMissingNodeId,
        ClusterMissingClusterId,
    };

    /// Validate config invariants. Call after loading file + CLI args.
    pub fn validate(self: *const ServerConfig) ValidateError!void {
        if (self.max_payload_size == 0 or self.max_payload_size > rpc.MAX_PAYLOAD_SIZE)
            return error.InvalidMaxPayloadSize;
        if (self.max_conns == 0)
            return error.InvalidMaxConns;
        if (self.max_queues == 0)
            return error.InvalidMaxQueues;
        if (self.node_id.len == 0 and self.peers.len > 0)
            return error.ClusterMissingNodeId;
        if (self.clusterMode() and self.cluster_id == 0)
            return error.ClusterMissingClusterId;
    }

    /// Parse config file content into this ServerConfig.
    /// String values are slices into `content` — caller must ensure
    /// `content` outlives the config's string fields.
    pub fn loadFile(self: *ServerConfig, content: []const u8) ParseError!void {
        var pos: usize = 0;
        while (pos < content.len) {
            const line_end = std.mem.indexOfScalarPos(u8, content, pos, '\n') orelse content.len;
            const line = std.mem.trim(u8, content[pos..line_end], " \t\r");
            pos = line_end + 1;

            if (line.len == 0 or line[0] == '#') continue;

            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.MissingSeparator;
            const key = std.mem.trimRight(u8, line[0..eq], " \t");
            const val = std.mem.trimLeft(u8, line[eq + 1 ..], " \t");
            if (key.len == 0) return error.EmptyKey;

            try self.applyKeyValue(key, val);
        }
    }

    fn applyKeyValue(self: *ServerConfig, key: []const u8, val: []const u8) ParseError!void {
        if (eql(key, "bind")) {
            self.bind = val;
        } else if (eql(key, "port")) {
            self.port = parseInt(u16, val) orelse return error.InvalidValue;
        } else if (eql(key, "data-dir")) {
            self.data_dir = val;
        } else if (eql(key, "mirror")) {
            self.mirror = parseBool(val) orelse return error.InvalidValue;
        } else if (eql(key, "max-conns")) {
            self.max_conns = parseInt(u16, val) orelse return error.InvalidValue;
        } else if (eql(key, "sync")) {
            self.sync = parseBool(val) orelse return error.InvalidValue;
        } else if (eql(key, "max-payload-size")) {
            self.max_payload_size = parseInt(u32, val) orelse return error.InvalidValue;
        } else if (eql(key, "max-queues")) {
            self.max_queues = parseInt(u32, val) orelse return error.InvalidValue;
        } else if (eql(key, "max-jobs")) {
            self.max_jobs = parseInt(u32, val) orelse return error.InvalidValue;
        } else if (eql(key, "persist-completed")) {
            self.persist_completed = parseBool(val) orelse return error.InvalidValue;
        } else if (eql(key, "max-tags-per-queue")) {
            self.max_tags_per_queue = parseInt(u32, val) orelse return error.InvalidValue;
        } else if (eql(key, "promote-interval")) {
            self.promote_interval_ns = parseInt(u64, val) orelse return error.InvalidValue;
        } else if (eql(key, "reclaim-interval")) {
            self.reclaim_interval_ns = parseInt(u64, val) orelse return error.InvalidValue;
        } else if (eql(key, "unique-interval")) {
            self.unique_interval_ns = parseInt(u64, val) orelse return error.InvalidValue;
        } else if (eql(key, "rate-limit-interval")) {
            self.rate_limit_interval_ns = parseInt(u64, val) orelse return error.InvalidValue;
        } else if (eql(key, "expire-interval")) {
            self.expire_interval_ns = parseInt(u64, val) orelse return error.InvalidValue;
        } else if (eql(key, "purge-interval")) {
            self.purge_interval_ns = parseInt(u64, val) orelse return error.InvalidValue;
        } else if (eql(key, "purge-threshold")) {
            self.purge_threshold = parseInt(u32, val) orelse return error.InvalidValue;
        } else if (eql(key, "purge-retention")) {
            self.purge_retention_ns = (parseInt(u64, val) orelse return error.InvalidValue) * 3_600_000_000_000;
        } else if (eql(key, "node-id")) {
            self.node_id = val;
        } else if (eql(key, "peers")) {
            self.peers = val;
        } else if (eql(key, "cluster-port")) {
            self.cluster_port = parseInt(u16, val) orelse return error.InvalidValue;
        } else if (eql(key, "cluster-id")) {
            self.cluster_id = parseInt(u64, val) orelse return error.InvalidValue;
        } else if (eql(key, "admin-password")) {
            self.admin_password = val;
        } else {
            return error.UnknownKey;
        }
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    fn parseInt(comptime T: type, val: []const u8) ?T {
        return std.fmt.parseInt(T, val, 10) catch null;
    }

    fn parseBool(val: []const u8) ?bool {
        if (eql(val, "true") or eql(val, "1") or eql(val, "yes")) return true;
        if (eql(val, "false") or eql(val, "0") or eql(val, "no")) return false;
        return null;
    }
};

// ============================================================================
// FNV-1a helpers for clusterHash (little-endian byte folding, order-sensitive)
// ============================================================================

fn fnvByte(h: u64, b: u8) u64 {
    return (h ^ b) *% 0x00000100000001B3;
}

fn fnvU32(h: u64, v: u32) u64 {
    const bytes = std.mem.toBytes(v);
    var r = h;
    for (&bytes) |b| r = fnvByte(r, b);
    return r;
}

fn fnvU64(h: u64, v: u64) u64 {
    const bytes = std.mem.toBytes(v);
    var r = h;
    for (&bytes) |b| r = fnvByte(r, b);
    return r;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "config: defaults" {
    const c = ServerConfig{};
    try testing.expectEqualStrings("0.0.0.0", c.bind);
    try testing.expectEqual(@as(u16, 9878), c.port);
    try testing.expectEqualStrings("/tmp/corvo-data", c.data_dir);
    try testing.expect(c.mirror);
    try testing.expect(!c.clusterMode());
    try c.validate();
}

test "config: parse file" {
    const content =
        \\# Server config
        \\bind = 127.0.0.1
        \\port = 3000
        \\data-dir = /var/lib/corvo
        \\max-payload-size = 131072
        \\max-queues = 200
        \\cluster-id = 42
        \\node-id = node-1
        \\peers = node-2@10.0.0.2:9878,node-3@10.0.0.3:9878
        \\
    ;
    var c = ServerConfig{};
    try c.loadFile(content);
    try testing.expectEqualStrings("127.0.0.1", c.bind);
    try testing.expectEqual(@as(u16, 3000), c.port);
    try testing.expectEqualStrings("/var/lib/corvo", c.data_dir);
    try testing.expectEqual(@as(u32, 131072), c.max_payload_size);
    try testing.expectEqual(@as(u32, 200), c.max_queues);
    try testing.expectEqual(@as(u64, 42), c.cluster_id);
    try testing.expect(c.clusterMode());
    try c.validate();
}

test "config: blank lines and comments" {
    const content =
        \\
        \\# Comment
        \\port = 5000
        \\
        \\# Another comment
        \\max-conns = 8192
        \\
    ;
    var c = ServerConfig{};
    try c.loadFile(content);
    try testing.expectEqual(@as(u16, 5000), c.port);
    try testing.expectEqual(@as(u16, 8192), c.max_conns);
}

test "config: unknown key errors" {
    var c = ServerConfig{};
    try testing.expectError(error.UnknownKey, c.loadFile("bogus = 42\n"));
}

test "config: missing separator errors" {
    var c = ServerConfig{};
    try testing.expectError(error.MissingSeparator, c.loadFile("no-equals\n"));
}

test "config: invalid value errors" {
    var c = ServerConfig{};
    try testing.expectError(error.InvalidValue, c.loadFile("port = abc\n"));
}

test "config: cluster hash deterministic and non-zero" {
    const c1 = ServerConfig{};
    const c2 = ServerConfig{};
    try testing.expectEqual(c1.clusterHash(), c2.clusterHash());
    try testing.expect(c1.clusterHash() != 0);
}

test "config: cluster hash changes with each shared param" {
    const base = ServerConfig{};
    // Every field folded into clusterHash must move the hash when it changes.
    const cases = [_]ServerConfig{
        blk: { var c = base; c.max_payload_size = 131072; break :blk c; },
        blk: { var c = base; c.max_queues = 200; break :blk c; },
        blk: { var c = base; c.max_jobs = 5; break :blk c; },
        blk: { var c = base; c.max_tags_per_queue = 42; break :blk c; },
        blk: { var c = base; c.persist_completed = true; break :blk c; },
        blk: { var c = base; c.promote_interval_ns = 5_000_000_000; break :blk c; },
        blk: { var c = base; c.reclaim_interval_ns = 5_000_000_000; break :blk c; },
        blk: { var c = base; c.unique_interval_ns = 5_000_000_000; break :blk c; },
        blk: { var c = base; c.rate_limit_interval_ns = 5_000_000_000; break :blk c; },
        blk: { var c = base; c.expire_interval_ns = 5_000_000_000; break :blk c; },
        blk: { var c = base; c.purge_interval_ns = 5_000_000_000; break :blk c; },
        blk: { var c = base; c.purge_retention_ns = 3_600_000_000_000; break :blk c; },
        blk: { var c = base; c.purge_threshold = 5; break :blk c; },
        blk: { var c = base; c.workers_interval_ns = 5_000_000_000; break :blk c; },
        blk: { var c = base; c.worker_timeout_ns = 5_000_000_000; break :blk c; },
        blk: { var c = base; c.cron_interval_ns = 5_000_000_000; break :blk c; },
    };
    for (cases) |c| try testing.expect(base.clusterHash() != c.clusterHash());
}

test "config: cluster hash ignores node-local params" {
    const c1 = ServerConfig{};
    var c2 = ServerConfig{};
    c2.bind = "192.168.1.1";
    c2.port = 3000;
    c2.data_dir = "/other/path";
    c2.mirror = false;
    c2.max_conns = 8192;
    c2.sync = true;
    c2.admin_password = "hunter2";
    c2.node_id = "node-2";
    c2.peers = "node-1@10.0.0.1:9878";
    c2.cluster_port = 12345;
    c2.cluster_id = 999;
    c2.cluster_secret = "shared-secret";
    try testing.expectEqual(c1.clusterHash(), c2.clusterHash());
}

test "config: validate catches bad config" {
    {
        // node_id + cluster_id is valid (single-node raft).
        var c = ServerConfig{};
        c.node_id = "node-1";
        c.cluster_id = 7;
        try c.validate();
    }
    {
        // Cluster mode without a cluster id is rejected.
        var c = ServerConfig{};
        c.node_id = "node-1";
        try testing.expectError(error.ClusterMissingClusterId, c.validate());
    }
    {
        var c = ServerConfig{};
        c.peers = "node-2@10.0.0.2:9878";
        try testing.expectError(error.ClusterMissingNodeId, c.validate());
    }
    {
        var c = ServerConfig{};
        c.max_payload_size = 0;
        try testing.expectError(error.InvalidMaxPayloadSize, c.validate());
    }
    {
        var c = ServerConfig{};
        c.max_conns = 0;
        try testing.expectError(error.InvalidMaxConns, c.validate());
    }
}

test "config: bool parsing" {
    var c = ServerConfig{};
    try c.loadFile("mirror = false\n");
    try testing.expect(!c.mirror);

    try c.loadFile("mirror = yes\n");
    try testing.expect(c.mirror);

    try c.loadFile("mirror = 0\n");
    try testing.expect(!c.mirror);
}

test "config: sync option" {
    var c = ServerConfig{};
    try testing.expect(!c.sync); // opt-in: default off

    try c.loadFile("sync = true\n");
    try testing.expect(c.sync);

    try c.loadFile("sync = false\n");
    try testing.expect(!c.sync);

    try testing.expectError(error.InvalidValue, c.loadFile("sync = maybe\n"));
}
