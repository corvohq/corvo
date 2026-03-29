//! PendingIndex — in-memory priority queue of pending job IDs per queue.
//!
//! Eliminates B+ tree iterator scans during fetch by maintaining an in-memory
//! index of pending jobs. Populated at startup from KV, then kept in sync by
//! handlers (enqueue, promote, reclaim, ack-continue, bulk retry/requeue).
//!
//! All access is from the single apply thread — no synchronization needed.
//! Stale entries (from cancel/delete/hold) are handled via lazy validation:
//! fetch pops an entry, checks if the job is still pending in KV, skips if not.

const std = @import("std");
const assert = @import("assert.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const kv = @import("kv.zig");

pub const PendingEntry = struct {
    inv_priority: u8, // 255 - priority (lower = higher priority, sorts first)
    created_ns: u64,
    job_id_buf: [64]u8 = undefined,
    job_id_len: u8 = 0,

    pub fn jobId(self: *const PendingEntry) []const u8 {
        return self.job_id_buf[0..self.job_id_len];
    }

    pub fn order(_: void, a: PendingEntry, b: PendingEntry) std.math.Order {
        if (a.inv_priority != b.inv_priority) return std.math.order(a.inv_priority, b.inv_priority);
        if (a.created_ns != b.created_ns) return std.math.order(a.created_ns, b.created_ns);
        return std.mem.order(u8, a.jobId(), b.jobId());
    }
};

const PendingHeap = std.PriorityQueue(PendingEntry, void, PendingEntry.order);

pub const PendingIndex = struct {
    queues: std.StringHashMap(PendingHeap),
    allocator: std.mem.Allocator,
    max_queues: u32 = 100,

    pub fn init(allocator: std.mem.Allocator) PendingIndex {
        return .{
            .queues = std.StringHashMap(PendingHeap).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PendingIndex) void {
        var it = self.queues.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
            entry.value_ptr.deinit();
        }
        self.queues.deinit();
    }

    /// Push a pending job entry. Only call for jobs entering pending state.
    pub fn push(self: *PendingIndex, queue: []const u8, priority: u8, created_ns: u64, job_id: []const u8) void {
        if (job_id.len == 0 or job_id.len > 64) return;

        const heap = self.queues.getOrPut(queue) catch unreachable;
        if (!heap.found_existing) {
            assert.check(self.queues.count() <= self.max_queues + 1, "PendingIndex: queue count ({d}) exceeds max_queues ({d})", .{ self.queues.count(), self.max_queues });
            heap.key_ptr.* = self.allocator.dupe(u8, queue) catch unreachable;
            heap.value_ptr.* = PendingHeap.init(self.allocator, {});
        }

        var entry: PendingEntry = .{
            .inv_priority = 255 - priority,
            .created_ns = created_ns,
        };
        const jl: u8 = @intCast(job_id.len);
        @memcpy(entry.job_id_buf[0..jl], job_id[0..jl]);
        entry.job_id_len = jl;

        heap.value_ptr.add(entry) catch unreachable;
    }

    /// Pop the highest-priority pending entry for a queue. Returns null if empty.
    pub fn pop(self: *PendingIndex, queue: []const u8) ?PendingEntry {
        if (self.queues.getPtr(queue)) |heap| {
            return heap.removeOrNull();
        }
        return null;
    }

    /// Clear all entries for a queue.
    /// Clear all queues. Used after snapshot restore to rebuild from KV.
    pub fn clear(self: *PendingIndex) void {
        var it = self.queues.iterator();
        while (it.next()) |entry| {
            self.allocator.free(@constCast(entry.key_ptr.*));
            entry.value_ptr.deinit();
        }
        self.queues.clearRetainingCapacity();
    }

    pub fn clearQueue(self: *PendingIndex, queue: []const u8) void {
        if (self.queues.getPtr(queue)) |heap| {
            while (heap.removeOrNull()) |_| {}
        }
    }

    /// Number of entries for a queue (may include stale entries).
    pub fn queueCount(self: *PendingIndex, queue: []const u8) u32 {
        if (self.queues.getPtr(queue)) |heap| {
            return @intCast(heap.count());
        }
        return 0;
    }

    /// Rebuild index from KV store by scanning all j| keys and
    /// selecting jobs with state=pending. Called once at startup.
    pub fn rebuild(self: *PendingIndex, shards: []kv.Store) void {
        for (shards) |*shard| {
            var batch = shard.newBatch();
            defer batch.close();

            var jp_buf: keys.KeyBuf = undefined;
            var jpe_buf: keys.KeyBuf = undefined;
            const jp = keys.prefix_job;
            @memcpy(jp_buf[0..jp.len], jp);
            const end = keys.prefixEnd(&jpe_buf, jp_buf[0..jp.len]) orelse continue;

            var iter = batch.newIter(jp_buf[0..jp.len], end);
            defer iter.close();

            if (!iter.first()) continue;

            var count: u32 = 0;
            while (true) {
                const val = iter.value();
                const job = codec.decodeJob(val);
                if (job.state == .pending) {
                    self.push(job.queue, job.priority, job.created_at_ns, job.id);
                    count += 1;
                }
                if (!iter.next()) break;
            }
            if (count > 0) {
                std.debug.print("pending_index: rebuilt {d} entries from KV\n", .{count});
            }
        }
    }

    /// Parse a pending key into its components.
    /// Key format: p|{queue}\x00{inv_priority:1}{created_ns:8BE}{job_id}
    fn parsePendingKey(key: []const u8) ?struct {
        queue: []const u8,
        inv_priority: u8,
        created_ns: u64,
        job_id: []const u8,
    } {
        const prefix_len = keys.prefix_pending.len; // "p|" = 2
        if (key.len < prefix_len + 1 + 1 + 8 + 1) return null;

        // Find \x00 separator after queue name.
        var sep_pos: usize = prefix_len;
        while (sep_pos < key.len) : (sep_pos += 1) {
            if (key[sep_pos] == 0x00) break;
        }
        if (sep_pos >= key.len) return null;
        if (sep_pos + 1 + 8 >= key.len) return null;

        return .{
            .queue = key[prefix_len..sep_pos],
            .inv_priority = key[sep_pos + 1],
            .created_ns = keys.getU64BE(key[sep_pos + 2 .. sep_pos + 10]),
            .job_id = key[sep_pos + 10 ..],
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "PendingIndex push/pop ordering" {
    var idx = PendingIndex.init(std.testing.allocator);
    defer idx.deinit();

    // Push jobs with different priorities.
    idx.push("q", 100, 1000, "high-pri");
    idx.push("q", 50, 1000, "low-pri");
    idx.push("q", 100, 500, "high-pri-early");

    // Pop should return highest priority first, then earliest.
    const e1 = idx.pop("q").?;
    try std.testing.expectEqualStrings("high-pri-early", e1.jobId());

    const e2 = idx.pop("q").?;
    try std.testing.expectEqualStrings("high-pri", e2.jobId());

    const e3 = idx.pop("q").?;
    try std.testing.expectEqualStrings("low-pri", e3.jobId());

    try std.testing.expect(idx.pop("q") == null);
}

test "PendingIndex clearQueue" {
    var idx = PendingIndex.init(std.testing.allocator);
    defer idx.deinit();

    idx.push("q1", 50, 1000, "j1");
    idx.push("q1", 50, 2000, "j2");
    idx.push("q2", 50, 3000, "j3");

    idx.clearQueue("q1");

    try std.testing.expect(idx.pop("q1") == null);
    try std.testing.expect(idx.pop("q2") != null);
}

test "PendingIndex queueCount" {
    var idx = PendingIndex.init(std.testing.allocator);
    defer idx.deinit();

    try std.testing.expectEqual(@as(u32, 0), idx.queueCount("q"));
    idx.push("q", 50, 1000, "j1");
    idx.push("q", 50, 2000, "j2");
    try std.testing.expectEqual(@as(u32, 2), idx.queueCount("q"));
}

test "PendingIndex parsePendingKey" {
    var buf: keys.KeyBuf = undefined;
    const pk = keys.pendingKey(&buf, "myqueue", 100, 5000, "job-42");
    const parsed = PendingIndex.parsePendingKey(pk).?;
    try std.testing.expectEqualStrings("myqueue", parsed.queue);
    try std.testing.expectEqual(@as(u8, 255 - 100), parsed.inv_priority);
    try std.testing.expectEqual(@as(u64, 5000), parsed.created_ns);
    try std.testing.expectEqualStrings("job-42", parsed.job_id);
}
