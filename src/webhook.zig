//! Webhook dispatch — URL parsing, HTTP request building, retry logic.
//!
//! Pure functions, no I/O. The IO backend handles the actual TCP connect/send/recv.
//! HTTP only for V1 (no TLS). Retry with exponential backoff.

const std = @import("std");
const assert = @import("assert.zig");

pub const ParsedUrl = struct {
    host: []const u8 = "",
    port: u16 = 80,
    path: []const u8 = "/",
};

/// Parse an HTTP URL into host, port, path.
/// Supports "http://host:port/path" and "http://host/path".
/// Returns null for invalid or non-HTTP URLs.
pub fn parseUrl(url: []const u8) ?ParsedUrl {
    const scheme = "http://";
    if (!std.mem.startsWith(u8, url, scheme)) return null;
    const after_scheme = url[scheme.len..];
    if (after_scheme.len == 0) return null;

    // Split host:port from path at first '/'.
    const slash_idx = std.mem.indexOfScalar(u8, after_scheme, '/');
    const host_port = if (slash_idx) |si| after_scheme[0..si] else after_scheme;
    const path = if (slash_idx) |si| after_scheme[si..] else "/";

    // Split host and port at ':'.
    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
        const port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return null;
        return .{ .host = host_port[0..colon], .port = port, .path = path };
    }

    return .{ .host = host_port, .port = 80, .path = path };
}

/// Build an HTTP/1.1 POST request into buf. Returns the slice of buf written.
pub fn buildHttpPost(buf: []u8, host: []const u8, path: []const u8, body: []const u8) ?[]const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    w.print("POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ path, host, body.len }) catch return null;
    w.writeAll(body) catch return null;
    return fbs.getWritten();
}

/// Parse HTTP status code from response. Returns 0 on parse failure.
pub fn parseHttpStatus(response: []const u8) u16 {
    // "HTTP/1.1 200 OK\r\n..."
    if (response.len < 12) return 0;
    if (!std.mem.startsWith(u8, response, "HTTP/")) return 0;
    // Find space after version, then parse 3-digit status.
    const space_idx = std.mem.indexOfScalar(u8, response, ' ') orelse return 0;
    if (space_idx + 4 > response.len) return 0;
    return std.fmt.parseInt(u16, response[space_idx + 1 ..][0..3], 10) catch 0;
}

/// Exponential backoff: 1s, 2s, 4s, 8s, 16s.
pub fn nextRetryNs(attempt: u8, now_ns: u64) u64 {
    const base_ns: u64 = 1_000_000_000; // 1 second
    const shift: u6 = @intCast(@min(attempt, 4));
    const delay = base_ns << shift;
    return now_ns + delay;
}

/// Build the JSON payload for a webhook delivery.
pub fn buildEventPayload(buf: []u8, event: []const u8, job_id: []const u8, queue: []const u8, now_ns: u64) ?[]const u8 {
    const result = std.fmt.bufPrint(buf,
        "{{\"event\":\"{s}\",\"job_id\":\"{s}\",\"queue\":\"{s}\",\"timestamp_ns\":{d}}}",
        .{ event, job_id, queue, now_ns },
    ) catch return null;
    return result;
}

/// Reject webhook targets that would let a user-configured URL reach the host's
/// own loopback or the cloud-metadata / link-local range (SSRF). RFC1918 private
/// ranges are intentionally allowed — internal service webhooks are a normal use
/// of a job system — so this blocks the clear-exfil cases without breaking that.
pub fn isBlockedTarget(addr: std.net.Address) bool {
    if (addr.any.family != std.posix.AF.INET) return false;
    const octets = @as([4]u8, @bitCast(addr.in.sa.addr)); // network byte order
    if (octets[0] == 127) return true; // 127.0.0.0/8 loopback
    if (octets[0] == 0) return true; // 0.0.0.0/8 "this host"
    if (octets[0] == 169 and octets[1] == 254) return true; // 169.254.0.0/16 link-local (incl. 169.254.169.254 IMDS)
    return false;
}

/// Resolve a hostname to an IPv4 address. Blocking (one-time per webhook URL).
/// Returns null for blocked (SSRF) targets so the delivery is dropped.
pub fn resolveHost(host: []const u8, port: u16) ?std.net.Address {
    // Try parsing as IP first (no DNS needed).
    const addr = std.net.Address.parseIp4(host, port) catch {
        // Fall back to DNS resolution.
        const list = std.net.Address.resolveIp(host, port) catch return null;
        if (isBlockedTarget(list)) return null;
        return list;
    };
    if (isBlockedTarget(addr)) return null;
    return addr;
}

// ============================================================================
// Tests
// ============================================================================

test "parseUrl basic" {
    const testing = std.testing;

    const url1 = parseUrl("http://localhost:9999/webhook").?;
    try testing.expectEqualStrings("localhost", url1.host);
    try testing.expectEqual(@as(u16, 9999), url1.port);
    try testing.expectEqualStrings("/webhook", url1.path);

    const url2 = parseUrl("http://example.com/hooks/test").?;
    try testing.expectEqualStrings("example.com", url2.host);
    try testing.expectEqual(@as(u16, 80), url2.port);
    try testing.expectEqualStrings("/hooks/test", url2.path);

    const url3 = parseUrl("http://10.0.0.1:8080").?;
    try testing.expectEqualStrings("10.0.0.1", url3.host);
    try testing.expectEqual(@as(u16, 8080), url3.port);
    try testing.expectEqualStrings("/", url3.path);

    try testing.expect(parseUrl("https://example.com") == null);
    try testing.expect(parseUrl("ftp://example.com") == null);
    try testing.expect(parseUrl("") == null);
}

test "buildHttpPost" {
    var buf: [4096]u8 = undefined;
    const req = buildHttpPost(&buf, "localhost", "/webhook", "{\"event\":\"test\"}").?;
    try std.testing.expect(std.mem.startsWith(u8, req, "POST /webhook HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: localhost") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "{\"event\":\"test\"}") != null);
}

test "parseHttpStatus" {
    try std.testing.expectEqual(@as(u16, 200), parseHttpStatus("HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(u16, 404), parseHttpStatus("HTTP/1.1 404 Not Found\r\n"));
    try std.testing.expectEqual(@as(u16, 0), parseHttpStatus("invalid"));
}

test "nextRetryNs" {
    const base: u64 = 1_000_000_000;
    try std.testing.expectEqual(base + base, nextRetryNs(0, base)); // +1s
    try std.testing.expectEqual(base + 2 * base, nextRetryNs(1, base)); // +2s
    try std.testing.expectEqual(base + 4 * base, nextRetryNs(2, base)); // +4s
}
