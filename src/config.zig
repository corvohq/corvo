//! Server configuration — config file parser.
//!
//! Config file: simple key = value format, # comments, blank lines.
//! Load order: defaults → file (--config) → CLI args.
//!
//! Cluster identity: an explicit `cluster-id` (u64, non-zero) shared by all
//! voters; the raft layer drops cross-cluster traffic.

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
