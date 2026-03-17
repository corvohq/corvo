//! Token-bucket rate limiter per client.
//!
//! Clients identified by API key hash or IP address.
//! Separate read and write token buckets.

const std = @import("std");

// ============================================================================
// Config
// ============================================================================

pub const RateLimitConfig = struct {
    enabled: bool = false,
    read_rps: f64 = 2000,
    read_burst: f64 = 4000,
    write_rps: f64 = 1000,
    write_burst: f64 = 2000,
};

// ============================================================================
// Token bucket
// ============================================================================

const Bucket = struct {
    tokens: f64,
    last_ns: i64,
};

const ClientBuckets = struct {
    read: Bucket,
    write: Bucket,
    last_access_ns: i64,
};

// ============================================================================
// Rate Limiter
// ============================================================================

const max_clients = 1024;

pub const RateLimiter = struct {
    config: RateLimitConfig,
    // Fixed-size client table — hash map is overkill for typical client counts.
    keys: [max_clients][32]u8 = undefined,
    key_lens: [max_clients]u8 = [_]u8{0} ** max_clients,
    clients: [max_clients]ClientBuckets = undefined,
    used: u32 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(config: RateLimitConfig) RateLimiter {
        return .{ .config = config };
    }

    /// Check if a request is allowed. Returns true if allowed, false if rate-limited.
    /// `cost` is the number of tokens to consume (1 for single requests, N for batches).
    pub fn allow(self: *RateLimiter, client_key: []const u8, is_write: bool, cost: u32) bool {
        if (!self.config.enabled) return true;

        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ns: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        const slot = self.getOrCreateClient(client_key, now_ns);
        if (slot == null) return true; // Table full, allow.

        const c = &self.clients[slot.?];
        c.last_access_ns = now_ns;

        const bucket = if (is_write) &c.write else &c.read;
        const rps = if (is_write) self.config.write_rps else self.config.read_rps;
        const burst = if (is_write) self.config.write_burst else self.config.read_burst;

        // Replenish tokens.
        const elapsed_s: f64 = @as(f64, @floatFromInt(now_ns - bucket.last_ns)) / 1_000_000_000.0;
        bucket.tokens = @min(burst, bucket.tokens + elapsed_s * rps);
        bucket.last_ns = now_ns;

        const fcost: f64 = @floatFromInt(cost);
        if (bucket.tokens >= fcost) {
            bucket.tokens -= fcost;
            return true;
        }
        return false;
    }

    /// Evict clients inactive for more than 10 minutes. Call periodically.
    pub fn evictStale(self: *RateLimiter) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now_ns: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        const ten_min_ns: i64 = 600_000_000_000;
        var i: u32 = 0;
        while (i < self.used) {
            if (now_ns - self.clients[i].last_access_ns > ten_min_ns) {
                // Swap with last and shrink.
                self.used -= 1;
                if (i < self.used) {
                    self.keys[i] = self.keys[self.used];
                    self.key_lens[i] = self.key_lens[self.used];
                    self.clients[i] = self.clients[self.used];
                }
                self.key_lens[self.used] = 0;
            } else {
                i += 1;
            }
        }
    }

    fn getOrCreateClient(self: *RateLimiter, client_key: []const u8, now_ns: i64) ?u32 {
        const klen: u8 = @intCast(@min(client_key.len, 32));

        // Search existing.
        for (0..self.used) |i| {
            if (self.key_lens[i] == klen and
                std.mem.eql(u8, self.keys[i][0..klen], client_key[0..klen]))
            {
                return @intCast(i);
            }
        }

        // Create new.
        if (self.used >= max_clients) return null;
        const slot = self.used;
        @memcpy(self.keys[slot][0..klen], client_key[0..klen]);
        self.key_lens[slot] = klen;
        self.clients[slot] = .{
            .read = .{ .tokens = self.config.read_burst, .last_ns = now_ns },
            .write = .{ .tokens = self.config.write_burst, .last_ns = now_ns },
            .last_access_ns = now_ns,
        };
        self.used += 1;
        return slot;
    }
};

/// Extract client identifier from request headers.
/// Priority: API key hash > IP from X-Forwarded-For > "anonymous".
pub fn clientKey(api_key: ?[]const u8, buf: *[32]u8) []const u8 {
    if (api_key) |k| {
        if (k.len > 0) {
            // Hash the API key to a short identifier.
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(k, &hash, .{});
            // "ak:" + first 8 hex chars = 11 bytes
            @memcpy(buf[0..3], "ak:");
            const hex = std.fmt.bytesToHex(hash[0..4], .lower);
            @memcpy(buf[3..11], &hex);
            return buf[0..11];
        }
    }
    @memcpy(buf[0..5], "anon:");
    return buf[0..5];
}

/// Determine if a request method is a write operation.
pub fn isWriteMethod(method: []const u8) bool {
    return std.mem.eql(u8, method, "POST") or
        std.mem.eql(u8, method, "PUT") or
        std.mem.eql(u8, method, "DELETE");
}

// ============================================================================
// Tests
// ============================================================================

test "rate limiter - disabled allows all" {
    var rl = RateLimiter.init(.{ .enabled = false });
    try std.testing.expect(rl.allow("client1", false, 1));
    try std.testing.expect(rl.allow("client1", true, 1));
}

test "rate limiter - respects burst limit" {
    var rl = RateLimiter.init(.{
        .enabled = true,
        .write_rps = 10,
        .write_burst = 5,
        .read_rps = 10,
        .read_burst = 5,
    });

    // First 5 requests should succeed (burst = 5).
    for (0..5) |_| {
        try std.testing.expect(rl.allow("c1", true, 1));
    }
    // 6th should fail.
    try std.testing.expect(!rl.allow("c1", true, 1));
}

test "rate limiter - separate read/write buckets" {
    var rl = RateLimiter.init(.{
        .enabled = true,
        .write_rps = 10,
        .write_burst = 2,
        .read_rps = 10,
        .read_burst = 2,
    });

    // Exhaust write.
    try std.testing.expect(rl.allow("c1", true, 2));
    try std.testing.expect(!rl.allow("c1", true, 1));

    // Read should still work.
    try std.testing.expect(rl.allow("c1", false, 1));
}

test "rate limiter - different clients are independent" {
    var rl = RateLimiter.init(.{
        .enabled = true,
        .write_rps = 10,
        .write_burst = 2,
        .read_rps = 10,
        .read_burst = 2,
    });

    try std.testing.expect(rl.allow("c1", true, 2));
    try std.testing.expect(!rl.allow("c1", true, 1));
    // c2 is independent.
    try std.testing.expect(rl.allow("c2", true, 1));
}

test "rate limiter - batch cost" {
    var rl = RateLimiter.init(.{
        .enabled = true,
        .write_rps = 10,
        .write_burst = 10,
        .read_rps = 10,
        .read_burst = 10,
    });

    // Cost 8 leaves 2 tokens.
    try std.testing.expect(rl.allow("c1", true, 8));
    // Cost 3 should fail (only 2 left).
    try std.testing.expect(!rl.allow("c1", true, 3));
    // Cost 2 should succeed.
    try std.testing.expect(rl.allow("c1", true, 2));
}

test "clientKey - with API key" {
    var buf: [32]u8 = undefined;
    const key = clientKey("test-key-123", &buf);
    try std.testing.expect(std.mem.startsWith(u8, key, "ak:"));
    try std.testing.expectEqual(@as(usize, 11), key.len);
}

test "clientKey - anonymous" {
    var buf: [32]u8 = undefined;
    const key = clientKey(null, &buf);
    try std.testing.expectEqualStrings("anon:", key);
}

test "isWriteMethod" {
    try std.testing.expect(isWriteMethod("POST"));
    try std.testing.expect(isWriteMethod("PUT"));
    try std.testing.expect(isWriteMethod("DELETE"));
    try std.testing.expect(!isWriteMethod("GET"));
    try std.testing.expect(!isWriteMethod("OPTIONS"));
}
