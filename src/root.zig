//! corvo: Distributed job queue.
//!
//! This root module re-exports all public types for use by downstream
//! modules (simulator, benchmarks, CLI).

pub const assert = @import("assert.zig");
pub const types = @import("types.zig");
pub const ops = @import("ops.zig");
pub const keys = @import("keys.zig");
pub const codec = @import("codec.zig");
pub const kv = @import("kv.zig");
pub const handler = @import("handler.zig");
pub const recording = @import("recording.zig");
pub const oplog = @import("oplog.zig");
pub const notify = @import("notify.zig");
pub const shard = @import("shard.zig");
pub const election = @import("election.zig");
pub const replicator = @import("replicator.zig");
pub const follower = @import("follower.zig");
pub const transport = @import("transport.zig");
pub const tcp_transport = @import("tcp_transport.zig");
pub const pipeline = @import("pipeline.zig");
pub const pending_index = @import("pending_index.zig");

// SQLite mirror modules — exported for downstream use but tests
// run via separate `zig build test-sqlite` target to avoid
// interaction with talon's memory-mapped I/O.
pub const sqlite = @import("sqlite.zig");
pub const schema = @import("schema.zig");
pub const mirror = @import("mirror.zig");
pub const sqlite_read = @import("sqlite_read.zig");

// IO backend (io_uring / kqueue / sim)
pub const io = @import("io.zig");

// Binary RPC protocol (encode/decode, zero IO)
pub const rpc = @import("rpc.zig");

// Cluster mode (PBR)
pub const cluster = @import("cluster.zig");

// Server configuration
pub const server_config = @import("config.zig");

// CLI client
pub const cli = @import("cli.zig");

// Cluster simulator
pub const cluster_sim = @import("cluster_sim.zig");

test {
    const testing = @import("std").testing;
    // Pull in non-sqlite module tests.
    testing.refAllDecls(@import("assert.zig"));
    testing.refAllDecls(@import("types.zig"));
    testing.refAllDecls(@import("ops.zig"));
    testing.refAllDecls(@import("keys.zig"));
    testing.refAllDecls(@import("codec.zig"));
    testing.refAllDecls(@import("kv.zig"));
    testing.refAllDecls(@import("handler.zig"));
    testing.refAllDecls(@import("oplog.zig"));
    testing.refAllDecls(@import("shard.zig"));
    testing.refAllDecls(@import("election.zig"));
    testing.refAllDecls(@import("replicator.zig"));
    testing.refAllDecls(@import("follower.zig"));
    testing.refAllDecls(@import("transport.zig"));
    testing.refAllDecls(@import("pipeline.zig"));
    testing.refAllDecls(@import("pending_index.zig"));
    testing.refAllDecls(@import("cluster_sim.zig"));
    testing.refAllDecls(@import("io.zig"));
    testing.refAllDecls(@import("config.zig"));
    // sqlite, schema, mirror, sqlite_read — tested via `zig build test-sqlite`
}
