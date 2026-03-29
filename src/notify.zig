//! QueueNotifier — push-based fetch wake mechanism.
//!
//! Ported from Go internal/engine/queue_notify.go + notify_ops.go.
//! Workers park on per-queue waiter lists and wake instantly when
//! a job is enqueued. Uses per-waiter Futex with FIFO wake order.

const std = @import("std");
const assert = @import("assert.zig");
const ops = @import("ops.zig");

/// QueueNotifier provides push-based notification for idle fetch loops.
/// Workers call wait() instead of polling and wake instantly when a job
/// is enqueued to one of the watched queues.
pub const QueueNotifier = struct {
    mu: std.Thread.Mutex = .{},
    /// Per-queue FIFO of waiting workers. Key is queue name (not owned).
    waiters: std.StringHashMap(std.ArrayList(*Waiter)),
    allocator: std.mem.Allocator,
    max_queues: u32 = 100,

    pub fn init(allocator: std.mem.Allocator) QueueNotifier {
        return .{
            .waiters = std.StringHashMap(std.ArrayList(*Waiter)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *QueueNotifier) void {
        var iter = self.waiters.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.waiters.deinit();
    }

    /// Wake one waiter on the given queue (FIFO order). Non-blocking.
    pub fn notify(self: *QueueNotifier, queue: []const u8) void {
        assert.check(queue.len > 0, "QueueNotifier.notify: empty queue name", .{});
        self.mu.lock();
        defer self.mu.unlock();
        self.wakeN(queue, 1);
    }

    /// Wake up to count waiters on the given queue.
    pub fn notifyN(self: *QueueNotifier, queue: []const u8, count: u32) void {
        assert.check(queue.len > 0, "QueueNotifier.notifyN: empty queue name", .{});
        assert.check(count > 0, "QueueNotifier.notifyN: zero count", .{});
        self.mu.lock();
        defer self.mu.unlock();
        self.wakeN(queue, count);
    }

    /// Wake one waiter per queue.
    pub fn notifyQueues(self: *QueueNotifier, queues: []const []const u8) void {
        if (queues.len == 0) return;
        self.mu.lock();
        defer self.mu.unlock();
        for (queues) |q| {
            self.wakeN(q, 1);
        }
    }

    /// Wake up to count waiters from the front of the queue's FIFO.
    /// Caller must hold self.mu.
    fn wakeN(self: *QueueNotifier, queue: []const u8, count: u32) void {
        const list = self.waiters.getPtr(queue) orelse return;
        if (list.items.len == 0) return;

        const wake: usize = @min(count, list.items.len);
        for (list.items[0..wake]) |w| {
            w.wake();
        }

        // Shift remaining waiters to front.
        const remaining = list.items.len - wake;
        if (remaining == 0) {
            list.clearRetainingCapacity();
        } else {
            std.mem.copyForwards(*Waiter, list.items[0..remaining], list.items[wake..]);
            list.shrinkRetainingCapacity(remaining);
        }
    }

    /// Register a waiter for one or more queues. Returns the waiter.
    /// Caller must call unregister() when done (even if woken).
    pub fn register(self: *QueueNotifier, queues: []const []const u8, waiter: *Waiter) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (queues) |q| {
            const list = self.waiters.getOrPut(q) catch unreachable;
            if (!list.found_existing) {
                assert.check(self.waiters.count() <= self.max_queues + 1, "QueueNotifier: queue count ({d}) exceeds max_queues ({d})", .{ self.waiters.count(), self.max_queues });
                list.value_ptr.* = .{};
            }
            list.value_ptr.append(self.allocator, waiter) catch unreachable;
        }
    }

    /// Unregister a waiter from all queues.
    pub fn unregister(self: *QueueNotifier, queues: []const []const u8, waiter: *Waiter) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (queues) |q| {
            if (self.waiters.getPtr(q)) |list| {
                // Remove waiter from list (swap-remove for efficiency).
                var i: usize = 0;
                while (i < list.items.len) {
                    if (list.items[i] == waiter) {
                        _ = list.swapRemove(i);
                        break;
                    }
                    i += 1;
                }
            }
        }
    }

    /// Wake one waiter per queue (all queues with waiters). Used after promote/reclaim
    /// where we don't track which specific queues were affected.
    pub fn notifyAll(self: *QueueNotifier) void {
        self.mu.lock();
        defer self.mu.unlock();
        var iter = self.waiters.iterator();
        while (iter.next()) |entry| {
            const list = entry.value_ptr;
            if (list.items.len > 0) {
                list.items[0].wake();
                const remaining = list.items.len - 1;
                if (remaining == 0) {
                    list.clearRetainingCapacity();
                } else {
                    std.mem.copyForwards(*Waiter, list.items[0..remaining], list.items[1..]);
                    list.shrinkRetainingCapacity(remaining);
                }
            }
        }
    }

    /// Remove all waiters for a deleted queue, waking any that are parked.
    pub fn remove(self: *QueueNotifier, queue: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.waiters.getPtr(queue)) |list| {
            for (list.items) |w| {
                w.wake();
            }
            list.deinit(self.allocator);
            _ = self.waiters.remove(queue);
        }
    }
};

/// A waiter that can be woken by either a thread (futex) or a connection
/// (eventfd/pipe write). Tagged union so QueueNotifier can hold both kinds.
pub const Waiter = union(enum) {
    /// Thread-based: blocks on futex. Used by HTTP long-poll fetch.
    thread: ThreadWaiter,
    /// Connection-based: pokes event loop via eventfd/pipe. Used by bidi RPC.
    conn: ConnWaiter,

    pub fn wake(self: *Waiter) void {
        switch (self.*) {
            .thread => |*t| t.wake(),
            .conn => |*c| c.wake(),
        }
    }
};

/// Thread-based waiter. Blocks the calling thread on a ResetEvent (futex).
pub const ThreadWaiter = struct {
    woken: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    event: std.Thread.ResetEvent = .{},

    pub fn wake(self: *ThreadWaiter) void {
        if (!self.woken.swap(true, .release)) {
            self.event.set();
        }
    }

    pub fn isWoken(self: *const ThreadWaiter) bool {
        return self.woken.load(.acquire);
    }

    /// Block until woken or timeout_ns elapses. Returns true if woken.
    pub fn wait(self: *ThreadWaiter, timeout_ns: u64) bool {
        self.event.timedWait(timeout_ns) catch return false;
        return self.isWoken();
    }
};

/// Connection-based waiter. Pokes an event loop via a single-byte write to
/// an eventfd (Linux) or the write end of a pipe (macOS).
pub const ConnWaiter = struct {
    conn_id: u16,
    wake_fd: i32,

    pub fn wake(self: *ConnWaiter) void {
        const val = [_]u8{1};
        _ = std.posix.write(self.wake_fd, &val) catch {};
    }
};

// ============================================================================
// notifyFromOp — wake fetch waiters after ops that make jobs fetchable
// ============================================================================

/// Wake fetch waiters after an apply that may have made jobs fetchable.
/// Called after each successful apply.
pub fn notifyFromOp(n: *QueueNotifier, op_type: ops.OpType, data: *const ops.OpData, result: *const ops.OpResult) void {
    switch (op_type) {
        .enqueue => {
            for (data.enqueue.jobs) |j| {
                if (j.queue.len > 0) n.notify(j.queue);
            }
        },
        .maintenance => {
            if (result.affected > 0 and
                (data.maintenance.action == .promote or data.maintenance.action == .reclaim))
            {
                n.notifyAll();
            }
        },
        else => {},
    }
}
