//! RecordingBatch — wraps kv.WriteBatch to capture mutations for oplog replication.
//!
//! Ported from Go internal/engine/recording_batch.go.
//! The underlying batch handles actual storage; this layer records
//! Set/Delete/DeleteRange calls as Mutation entries for the oplog.

const std = @import("std");
const assert = @import("assert.zig");
const kv = @import("kv.zig");

/// Re-export mutation types from kv.zig for backward compatibility.
pub const MutOp = kv.MutOp;
pub const Mutation = kv.Mutation;

/// RecordingBatch wraps a WriteBatch and records all write operations
/// as Mutation entries. After commit, call mutations() to get the
/// recorded mutations for oplog append.
pub const RecordingBatch = struct {
    inner: *kv.WriteBatch,
    muts: std.ArrayList(Mutation),
    allocator: std.mem.Allocator,

    pub fn init(inner: *kv.WriteBatch, allocator: std.mem.Allocator) RecordingBatch {
        return .{
            .inner = inner,
            .muts = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RecordingBatch) void {
        // Free owned copies
        for (self.muts.items) |m| {
            self.allocator.free(@constCast(m.key));
            if (m.value.len > 0 and m.op != .delete) {
                self.allocator.free(@constCast(m.value));
            }
        }
        self.muts.deinit(self.allocator);
        self.inner.close();
    }

    pub fn get(self: *RecordingBatch, key: []const u8) ?[]const u8 {
        return self.inner.get(key);
    }

    pub fn set(self: *RecordingBatch, key: []const u8, value: []const u8) void {
        self.inner.set(key, value);
        const key_copy = self.allocator.dupe(u8, key) catch unreachable;
        const val_copy = self.allocator.dupe(u8, value) catch unreachable;
        self.muts.append(self.allocator, .{ .op = .set, .key = key_copy, .value = val_copy }) catch unreachable;
    }

    pub fn delete(self: *RecordingBatch, key: []const u8) void {
        self.inner.delete(key);
        const key_copy = self.allocator.dupe(u8, key) catch unreachable;
        self.muts.append(self.allocator, .{ .op = .delete, .key = key_copy, .value = "" }) catch unreachable;
    }

    pub fn deleteRange(self: *RecordingBatch, start: []const u8, end: []const u8) void {
        self.inner.deleteRange(start, end);
        const start_copy = self.allocator.dupe(u8, start) catch unreachable;
        const end_copy = self.allocator.dupe(u8, end) catch unreachable;
        self.muts.append(self.allocator, .{ .op = .delete_range, .key = start_copy, .value = end_copy }) catch unreachable;
    }

    pub fn newIter(self: *RecordingBatch, lower: []const u8, upper: []const u8) kv.Iterator {
        return self.inner.newIter(lower, upper);
    }

    pub fn commit(self: *RecordingBatch) void {
        self.inner.commit();
    }

    pub fn close(self: *RecordingBatch) void {
        self.inner.close();
    }

    /// Returns the recorded mutations. Only valid after commit().
    pub fn mutations(self: *const RecordingBatch) []const Mutation {
        return self.muts.items;
    }
};
