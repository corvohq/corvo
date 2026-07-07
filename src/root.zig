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
pub const cron_expr = @import("cron_expr.zig");
pub const handler = @import("handler.zig");
pub const recording = @import("recording.zig");
pub const oplog = @import("oplog.zig");
pub const notify = @import("notify.zig");
pub const shard = @import("shard.zig");
pub const raft_storage = @import("raft_storage.zig");
pub const raft_codec = @import("raft_codec.zig");
pub const raft_transport = @import("raft_transport.zig");
pub const raft_net = @import("raft_net.zig");
pub const raft_fsm = @import("raft_fsm.zig");
pub const raft_batcher = @import("raft_batcher.zig");
pub const raft_runtime = @import("raft_runtime.zig");
pub const raft_host = @import("raft_host.zig");
pub const raft_gate = @import("raft_gate.zig");
pub const pipeline = @import("pipeline.zig");
pub const pending_index = @import("pending_index.zig");
pub const indexer = @import("indexer.zig");

// KV read layer — reads directly from Talon KV store.
pub const kv_read = @import("kv_read.zig");
pub const http_read = @import("http_read.zig");
pub const http_ui = @import("http_ui.zig");

// IO backend (io_uring / kqueue / sim)
pub const io = @import("io.zig");

// Binary RPC protocol (encode/decode, zero IO)
pub const rpc = @import("rpc.zig");

// Server configuration
pub const server_config = @import("config.zig");

// Re-exported dependencies
pub const zigstache = @import("zigstache");
pub const talon = @import("talon");

// Webhook dispatch
pub const webhook = @import("webhook.zig");

// Performance metrics
pub const metrics = @import("metrics.zig");

// CLI client
pub const cli = @import("cli.zig");

test {
    const testing = @import("std").testing;
    // Pull in module tests.
    testing.refAllDecls(@import("assert.zig"));
    testing.refAllDecls(@import("types.zig"));
    testing.refAllDecls(@import("ops.zig"));
    testing.refAllDecls(@import("keys.zig"));
    testing.refAllDecls(@import("codec.zig"));
    testing.refAllDecls(@import("kv.zig"));
    testing.refAllDecls(@import("cron_expr.zig"));
    testing.refAllDecls(@import("handler.zig"));
    testing.refAllDecls(@import("oplog.zig"));
    testing.refAllDecls(@import("shard.zig"));
    testing.refAllDecls(@import("raft_storage.zig"));
    testing.refAllDecls(@import("raft_codec.zig"));
    testing.refAllDecls(@import("raft_transport.zig"));
    testing.refAllDecls(@import("raft_net.zig"));
    testing.refAllDecls(@import("raft_fsm.zig"));
    testing.refAllDecls(@import("raft_batcher.zig"));
    testing.refAllDecls(@import("raft_runtime.zig"));
    testing.refAllDecls(@import("raft_host.zig"));
    testing.refAllDecls(@import("raft_gate.zig"));
    testing.refAllDecls(@import("pipeline.zig"));
    testing.refAllDecls(@import("pending_index.zig"));
    testing.refAllDecls(@import("indexer.zig"));
    testing.refAllDecls(@import("io.zig"));
    testing.refAllDecls(@import("config.zig"));
    testing.refAllDecls(@import("kv_read.zig"));
    testing.refAllDecls(@import("webhook.zig"));
}
