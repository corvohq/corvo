//! HTTP protocol module — parse, route, encode/decode for pipeline.
//!
//! Pure functions. No IO, no state. Pipeline calls these.
//! Owns all HTTP protocol details — pipeline stays protocol-ignorant.
//!
//! Read routes are handled inline (response written directly to send_buf).
//! Write routes produce FrameDescs for the pipeline batch.

const std = @import("std");
const assert = @import("assert.zig");
const ops_mod = @import("ops.zig");
const types = @import("types.zig");
const rpc = @import("rpc.zig");
const http_read = @import("http_read.zig");
const sqlite_read = @import("sqlite_read.zig");
const json = @import("json_writer.zig");
const kv = @import("kv.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");

// ============================================================================
// Types
// ============================================================================

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,
};

pub const HttpRequest = struct {
    method: Method,
    path: []const u8,
    body: []const u8,
    total_len: u32,
    api_key: ?[]const u8 = null,
};

// ============================================================================
// Request Parsing
// ============================================================================

/// Parse an HTTP/1.1 request from raw bytes.
/// Returns null if the request is incomplete (partial headers or body).
pub fn parseRequest(data: []const u8) ?HttpRequest {
    // Find end of headers.
    const header_end = findHeaderEnd(data) orelse return null;
    const header_section = data[0..header_end];
    const body_start: u32 = @intCast(header_end + 4); // skip \r\n\r\n

    // Parse request line.
    const line_end = std.mem.indexOf(u8, header_section, "\r\n") orelse return null;
    const request_line = header_section[0..line_end];

    const method = parseMethod(request_line) orelse return null;

    // Extract path: between first space and second space.
    const path_start = (std.mem.indexOfScalar(u8, request_line, ' ') orelse return null) + 1;
    const path_end_rel = std.mem.indexOfScalar(u8, request_line[path_start..], ' ') orelse return null;
    const path = request_line[path_start..][0..path_end_rel];

    // Extract Content-Length for body.
    const content_length = extractContentLength(header_section);

    // Check if we have the full body.
    const total_len = body_start + content_length;
    if (data.len < total_len) return null;

    const body = if (content_length > 0) data[body_start..total_len] else "";

    // Extract API key from X-API-Key or Authorization: Bearer headers.
    const api_key = extractApiKey(header_section);

    return .{
        .method = method,
        .path = path,
        .body = body,
        .total_len = total_len,
        .api_key = api_key,
    };
}

fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;
    var i: usize = 0;
    while (i + 3 < data.len) : (i += 1) {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n')
            return i;
    }
    return null;
}

fn parseMethod(line: []const u8) ?Method {
    if (std.mem.startsWith(u8, line, "GET ")) return .GET;
    if (std.mem.startsWith(u8, line, "POST ")) return .POST;
    if (std.mem.startsWith(u8, line, "PUT ")) return .PUT;
    if (std.mem.startsWith(u8, line, "DELETE ")) return .DELETE;
    if (std.mem.startsWith(u8, line, "PATCH ")) return .PATCH;
    if (std.mem.startsWith(u8, line, "HEAD ")) return .HEAD;
    if (std.mem.startsWith(u8, line, "OPTIONS ")) return .OPTIONS;
    return null;
}

fn extractContentLength(headers: []const u8) u32 {
    // Case-insensitive search for Content-Length header.
    var i: usize = 0;
    while (i + 16 < headers.len) : (i += 1) {
        if ((headers[i] == 'C' or headers[i] == 'c') and
            eqlIgnoreCase(headers[i..][0..16], "content-length: "))
        {
            const val_start = i + 16;
            var val_end = val_start;
            while (val_end < headers.len and headers[val_end] >= '0' and headers[val_end] <= '9')
                val_end += 1;
            if (val_end > val_start)
                return std.fmt.parseInt(u32, headers[val_start..val_end], 10) catch 0;
        }
        // Skip to next line.
        if (headers[i] == '\n') continue;
    }
    return 0;
}

fn extractApiKey(headers: []const u8) ?[]const u8 {
    // Scan headers line by line.
    var start: usize = 0;
    while (start < headers.len) {
        const end = std.mem.indexOf(u8, headers[start..], "\r\n") orelse headers.len - start;
        const line = headers[start..][0..end];
        start += end + 2;

        // X-API-Key: {key}
        if (line.len > 11 and (line[0] == 'X' or line[0] == 'x') and eqlIgnoreCase(line[0..11], "x-api-key: ")) {
            const val = std.mem.trimLeft(u8, line[11..], " \t");
            if (val.len > 0) return val;
        }
        // Authorization: Bearer {key}
        if (line.len > 14 and (line[0] == 'A' or line[0] == 'a') and eqlIgnoreCase(line[0..15], "authorization: ")) {
            const val = std.mem.trimLeft(u8, line[15..], " \t");
            if (val.len > 7 and eqlIgnoreCase(val[0..7], "bearer ")) {
                const key = std.mem.trimLeft(u8, val[7..], " \t");
                if (key.len > 0) return key;
            }
        }
    }
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        const al = if (ac >= 'A' and ac <= 'Z') ac + 32 else ac;
        const bl = if (bc >= 'A' and bc <= 'Z') bc + 32 else bc;
        if (al != bl) return false;
    }
    return true;
}

// ============================================================================
// Response Framing
// ============================================================================

/// Write an HTTP/1.1 JSON response into send_buf. Returns bytes written.
pub fn writeResponse(send_buf: []u8, status: u16, json_body: []const u8) u32 {
    return writeResponseInner(send_buf, status, "application/json", json_body);
}

/// Write an HTTP/1.1 text/plain response into send_buf. Returns bytes written.
pub fn writeResponseText(send_buf: []u8, status: u16, text_body: []const u8) u32 {
    return writeResponseInner(send_buf, status, "text/plain; charset=utf-8", text_body);
}

/// Write an HTTP/1.1 HTML response into send_buf. Returns bytes written.
pub fn writeResponseHtml(send_buf: []u8, status: u16, html_body: []const u8) u32 {
    return writeResponseInner(send_buf, status, "text/html; charset=utf-8", html_body);
}

/// Write an HTTP/1.1 response for a static embedded file.
/// If gzipped=true, adds Content-Encoding: gzip header.
pub fn writeResponseStatic(send_buf: []u8, data: []const u8, content_type: []const u8, gzipped: bool) u32 {
    var stream = std.io.fixedBufferStream(send_buf);
    const w = stream.writer();

    w.writeAll("HTTP/1.1 200 OK\r\n") catch return 0;
    w.print("Content-Type: {s}\r\n", .{content_type}) catch return 0;
    w.print("Content-Length: {d}\r\n", .{data.len}) catch return 0;
    if (gzipped) w.writeAll("Content-Encoding: gzip\r\n") catch return 0;
    w.writeAll("Cache-Control: public, max-age=31536000, immutable\r\n") catch return 0;
    w.writeAll("Connection: keep-alive\r\n") catch return 0;
    w.writeAll("\r\n") catch return 0;
    w.writeAll(data) catch return 0;

    return @intCast(stream.pos);
}

fn writeResponseInner(send_buf: []u8, status: u16, content_type: []const u8, body: []const u8) u32 {
    var stream = std.io.fixedBufferStream(send_buf);
    const w = stream.writer();

    w.print("HTTP/1.1 {d} {s}\r\n", .{ status, statusText(status) }) catch return 0;
    w.print("Content-Type: {s}\r\n", .{content_type}) catch return 0;
    w.print("Content-Length: {d}\r\n", .{body.len}) catch return 0;
    w.writeAll("Connection: keep-alive\r\n") catch return 0;
    w.writeAll("Access-Control-Allow-Origin: *\r\n") catch return 0;
    w.writeAll("\r\n") catch return 0;
    w.writeAll(body) catch return 0;

    return @intCast(stream.pos);
}

/// Write CORS preflight response (204 No Content with CORS headers).
pub fn writeCorsPreflightResponse(send_buf: []u8) u32 {
    var stream = std.io.fixedBufferStream(send_buf);
    const w = stream.writer();
    w.writeAll("HTTP/1.1 204 No Content\r\n") catch return 0;
    w.writeAll("Access-Control-Allow-Origin: *\r\n") catch return 0;
    w.writeAll("Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS\r\n") catch return 0;
    w.writeAll("Access-Control-Allow-Headers: Content-Type, Authorization, X-API-Key\r\n") catch return 0;
    w.writeAll("Access-Control-Max-Age: 86400\r\n") catch return 0;
    w.writeAll("Connection: keep-alive\r\n") catch return 0;
    w.writeAll("\r\n") catch return 0;
    return @intCast(stream.pos);
}

fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        503 => "Service Unavailable",
        else => "OK",
    };
}

// ============================================================================
// Query Parameter Extraction
// ============================================================================

/// Extract a query parameter value from a path string.
/// e.g., extractQueryParam("/api/v1/jobs?q=hello&limit=10", "q") => "hello"
pub fn extractQueryParam(path: []const u8, key: []const u8) ?[]const u8 {
    const qi = std.mem.indexOfScalar(u8, path, '?') orelse return null;
    var params = path[qi + 1 ..];

    while (params.len > 0) {
        // Find key=value pair.
        const amp = std.mem.indexOfScalar(u8, params, '&') orelse params.len;
        const pair = params[0..amp];

        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            params = if (amp < params.len) params[amp + 1 ..] else "";
            continue;
        };

        if (std.mem.eql(u8, pair[0..eq], key)) {
            return pair[eq + 1 ..];
        }

        params = if (amp < params.len) params[amp + 1 ..] else "";
    }
    return null;
}

// ============================================================================
// Route Classification
// ============================================================================

pub const RouteAction = union(enum) {
    /// Read route — handled inline by http_read, bypasses pipeline batch.
    read,
    /// Write route — produces a frame for the pipeline batch.
    write: struct {
        msg_type: u8,
        param: []const u8,
        sub_action: []const u8,
    },
    /// Route not found.
    not_found,
    /// Method not allowed for this route.
    method_not_allowed,
};

/// Classify an HTTP request as read or write.
/// For writes, returns the equivalent RPC msg_type and extracted path param.
pub fn classifyRoute(method: Method, path: []const u8) RouteAction {
    // Strip query string.
    const clean = if (std.mem.indexOfScalar(u8, path, '?')) |qi| path[0..qi] else path;

    if (!std.mem.startsWith(u8, clean, "/api/v1/")) {
        if (std.mem.eql(u8, clean, "/healthz")) return .read;
        if (std.mem.eql(u8, clean, "/metrics")) return .read;
        if (std.mem.eql(u8, clean, "/ui") or std.mem.startsWith(u8, clean, "/ui/")) return .read;
        return .not_found;
    }

    const api = clean["/api/v1".len..];

    switch (method) {
        .POST => {
            // --- Exact path matches ---
            if (std.mem.eql(u8, api, "/enqueue"))
                return writeRoute(rpc.MSG_ENQUEUE_BATCH, "", "");
            if (std.mem.eql(u8, api, "/fetch"))
                return writeRoute(rpc.MSG_FETCH_BATCH, "", "");
            if (std.mem.eql(u8, api, "/ack"))
                return writeRoute(rpc.MSG_ACK_BATCH, "", "");
            if (std.mem.eql(u8, api, "/heartbeat"))
                return writeRoute(rpc.MSG_HEARTBEAT, "", "");
            if (std.mem.eql(u8, api, "/jobs/bulk"))
                return writeRoute(rpc.MSG_BULK_ACTION, "", "");
            if (std.mem.eql(u8, api, "/batch"))
                return writeRoute(rpc.MSG_BATCH_CREATE, "", "");
            if (std.mem.eql(u8, api, "/cron-jobs") or std.mem.eql(u8, api, "/crons"))
                return writeRoute(rpc.MSG_CRON_CREATE, "", "");
            if (std.mem.eql(u8, api, "/budgets"))
                return writeRoute(rpc.MSG_SET_BUDGET, "", "");
            if (std.mem.eql(u8, api, "/approval-policies"))
                return writeRoute(rpc.MSG_MODIFY_ENT_SETTING, "", "approval_policy");
            if (std.mem.eql(u8, api, "/auth/keys"))
                return writeRoute(rpc.MSG_MODIFY_ENT_SETTING, "", "api_key");

            if (std.mem.eql(u8, api, "/jobs/bulk-get"))
                return .read;

            // POST reads
            if (std.mem.eql(u8, api, "/jobs/search") or std.mem.eql(u8, api, "/jobs"))
                return .read;

            // --- Prefix matches with path params ---
            if (std.mem.startsWith(u8, api, "/ack/"))
                return writeRoute(rpc.MSG_ACK_BATCH, api["/ack/".len..], "");
            if (std.mem.startsWith(u8, api, "/fail/"))
                return writeRoute(rpc.MSG_FAIL_BATCH, api["/fail/".len..], "");

            // /jobs/{id}/{action}
            if (std.mem.startsWith(u8, api, "/jobs/"))
                return classifyJobPostAction(api["/jobs/".len..]);

            // /queues/{name}/{action}
            if (std.mem.startsWith(u8, api, "/queues/"))
                return classifyQueueAction(.POST, api["/queues/".len..]);

            // /batch/{id}/seal
            if (std.mem.startsWith(u8, api, "/batch/")) {
                const rest = api["/batch/".len..];
                if (std.mem.endsWith(u8, rest, "/seal")) {
                    const id = rest[0 .. rest.len - "/seal".len];
                    if (id.len > 0) return writeRoute(rpc.MSG_BATCH_SEAL, id, "");
                }
            }

            // /cron-jobs/{id}/{action} or /crons/{id}/{action}
            if (std.mem.startsWith(u8, api, "/cron-jobs/"))
                return classifyCronPostAction(api["/cron-jobs/".len..]);
            if (std.mem.startsWith(u8, api, "/crons/"))
                return classifyCronPostAction(api["/crons/".len..]);

            // Webhooks: POST /webhooks/{queue}
            if (std.mem.startsWith(u8, api, "/webhooks/")) {
                const queue = api["/webhooks/".len..];
                if (queue.len > 0) return writeRoute(rpc.MSG_ENQUEUE_BATCH, queue, "webhook");
            }
        },

        .PUT => {
            // PUT /cron-jobs/{id} or /crons/{id}
            if (std.mem.startsWith(u8, api, "/cron-jobs/")) {
                const id = api["/cron-jobs/".len..];
                if (id.len > 0 and std.mem.indexOfScalar(u8, id, '/') == null)
                    return writeRoute(rpc.MSG_CRON_UPDATE, id, "");
            }
            if (std.mem.startsWith(u8, api, "/crons/")) {
                const id = api["/crons/".len..];
                if (id.len > 0 and std.mem.indexOfScalar(u8, id, '/') == null)
                    return writeRoute(rpc.MSG_CRON_UPDATE, id, "");
            }
        },

        .DELETE => {
            // DELETE /jobs/{id}
            if (std.mem.startsWith(u8, api, "/jobs/")) {
                const id = api["/jobs/".len..];
                if (id.len > 0 and std.mem.indexOfScalar(u8, id, '/') == null)
                    return writeRoute(rpc.MSG_BULK_ACTION, id, "delete");
            }

            // DELETE /queues/{name}[/{setting}]
            if (std.mem.startsWith(u8, api, "/queues/"))
                return classifyQueueAction(.DELETE, api["/queues/".len..]);

            // DELETE /cron-jobs/{id} or /crons/{id}
            if (std.mem.startsWith(u8, api, "/cron-jobs/")) {
                const id = api["/cron-jobs/".len..];
                if (id.len > 0 and std.mem.indexOfScalar(u8, id, '/') == null)
                    return writeRoute(rpc.MSG_CRON_DELETE, id, "");
            }
            if (std.mem.startsWith(u8, api, "/crons/")) {
                const id = api["/crons/".len..];
                if (id.len > 0 and std.mem.indexOfScalar(u8, id, '/') == null)
                    return writeRoute(rpc.MSG_CRON_DELETE, id, "");
            }

            // DELETE /budgets/{scope}/{target}
            if (std.mem.startsWith(u8, api, "/budgets/")) {
                const rest = api["/budgets/".len..];
                if (std.mem.indexOfScalar(u8, rest, '/')) |s| {
                    const scope = rest[0..s];
                    const target = rest[s + 1 ..];
                    if (scope.len > 0 and target.len > 0)
                        return writeRoute(rpc.MSG_DELETE_BUDGET, scope, target);
                }
            }

            // DELETE /approval-policies/{id}
            if (std.mem.startsWith(u8, api, "/approval-policies/")) {
                const id = api["/approval-policies/".len..];
                if (id.len > 0)
                    return writeRoute(rpc.MSG_MODIFY_ENT_SETTING, id, "approval_policy_delete");
            }

            // DELETE /auth/keys
            if (std.mem.eql(u8, api, "/auth/keys"))
                return writeRoute(rpc.MSG_MODIFY_ENT_SETTING, "", "api_key_delete");
        },

        .GET => return .read,

        .OPTIONS => return .read, // CORS preflight handled inline

        else => {},
    }

    return .not_found;
}

fn writeRoute(msg_type: u8, param: []const u8, sub_action: []const u8) RouteAction {
    return .{ .write = .{ .msg_type = msg_type, .param = param, .sub_action = sub_action } };
}

fn classifyJobPostAction(rest: []const u8) RouteAction {
    // rest = "{id}/{action}"
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .not_found;
    const id = rest[0..slash];
    const action = rest[slash + 1 ..];
    if (id.len == 0 or action.len == 0) return .not_found;

    // Validate known actions
    const valid = [_][]const u8{ "requeue", "cancel", "hold", "approve", "reject", "move" };
    for (valid) |v| {
        if (std.mem.eql(u8, action, v))
            return writeRoute(rpc.MSG_BULK_ACTION, id, action);
    }
    return .not_found;
}

fn classifyQueueAction(method: Method, rest: []const u8) RouteAction {
    // rest = "{name}" or "{name}/{action}"
    const slash = std.mem.indexOfScalar(u8, rest, '/');
    const name = if (slash) |s| rest[0..s] else rest;
    const action = if (slash) |s| rest[s + 1 ..] else "";
    if (name.len == 0) return .not_found;

    if (method == .DELETE) {
        if (action.len == 0) return writeRoute(rpc.MSG_DELETE_QUEUE, name, "");
        // DELETE /queues/{name}/throttle or /fairness → remove setting
        if (std.mem.eql(u8, action, "throttle")) return writeRoute(rpc.MSG_QUEUE_CONFIG, name, "throttle_remove");
        if (std.mem.eql(u8, action, "fairness")) return writeRoute(rpc.MSG_QUEUE_CONFIG, name, "fairness_remove");
        return .not_found;
    }

    // POST
    if (action.len == 0) return .not_found;
    if (std.mem.eql(u8, action, "clear")) return writeRoute(rpc.MSG_CLEAR_QUEUE, name, "");

    const valid = [_][]const u8{ "pause", "resume", "concurrency", "throttle", "fairness", "drain" };
    for (valid) |v| {
        if (std.mem.eql(u8, action, v))
            return writeRoute(rpc.MSG_QUEUE_CONFIG, name, action);
    }
    return .not_found;
}

fn classifyCronPostAction(rest: []const u8) RouteAction {
    // rest = "{id}/{action}"
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return .not_found;
    const id = rest[0..slash];
    const action = rest[slash + 1 ..];
    if (id.len == 0 or action.len == 0) return .not_found;

    if (std.mem.eql(u8, action, "trigger")) return writeRoute(rpc.MSG_CRON_TRIGGER, id, "");
    if (std.mem.eql(u8, action, "pause")) return writeRoute(rpc.MSG_CRON_UPDATE, id, "pause");
    if (std.mem.eql(u8, action, "resume")) return writeRoute(rpc.MSG_CRON_UPDATE, id, "resume");
    return .not_found;
}

// ============================================================================
// Auth — API key validation
// ============================================================================

pub const AuthResult = enum {
    ok,
    unauthorized,
    forbidden,
};

/// Hash an API key with SHA256, return hex string in `out`.
pub fn hashApiKey(key: []const u8, out: *[64]u8) []const u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(key, &hash, .{});
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        out[i * 2] = hex_chars[byte >> 4];
        out[i * 2 + 1] = hex_chars[byte & 0x0f];
    }
    return out[0..64];
}

/// Check auth for an HTTP request. Returns ok if no auth is configured,
/// unauthorized if auth is required but missing/invalid, forbidden if role insufficient.
pub fn checkAuth(
    api_key: ?[]const u8,
    method: Method,
    reader: ?*sqlite_read.Reader,
) AuthResult {
    const rdr = reader orelse return .ok; // no mirror = no auth checking
    const key_count = rdr.countEnabledApiKeys() catch return .ok;
    if (key_count == 0) return .ok; // no keys configured = auth disabled

    const raw_key = api_key orelse return .unauthorized;
    if (raw_key.len == 0) return .unauthorized;

    var hash_buf: [64]u8 = undefined;
    const key_hash = hashApiKey(raw_key, &hash_buf);

    const row = rdr.getApiKeyByHash(key_hash) catch return .unauthorized;
    if (row == null) return .unauthorized;
    const r = row.?;
    if (!r.enabled) return .unauthorized;

    // Role-based access: readonly can only GET, worker can't manage.
    const role = r.roleSlice();
    if (std.mem.eql(u8, role, "readonly") and method != .GET) return .forbidden;

    return .ok;
}

/// Write a 401 or 403 response.
pub fn writeAuthError(send_buf: []u8, auth_result: AuthResult) u32 {
    return switch (auth_result) {
        .unauthorized => writeResponse(send_buf, 401, "{\"error\":\"unauthorized\"}"),
        .forbidden => writeResponse(send_buf, 403, "{\"error\":\"forbidden\"}"),
        .ok => 0,
    };
}

// ============================================================================
// Protocol Detection
// ============================================================================

/// Detect protocol from the first byte of data.
/// RPC msg_types are 0x01–0x1A; HTTP methods start with ASCII letters.
pub fn isHttpByte(first_byte: u8) bool {
    return first_byte >= 'A' and first_byte <= 'Z';
}

// ============================================================================
// Write Request Decode — JSON body → OpData
// ============================================================================

pub const DecodeResult = struct {
    op_data: ops_mod.OpData,
    count: u16,
};

/// Decode an HTTP write request body into an OpData for the pipeline batch.
/// `scratch` provides pre-allocated buffers for parsed data.
pub fn decodeWrite(
    msg_type: u8,
    body: []const u8,
    param: []const u8,
    sub_action: []const u8,
    now_ns: u64,
    scratch: *DecodeScratch,
    http_path: []const u8,
) DecodeResult {
    switch (msg_type) {
        rpc.MSG_ENQUEUE_BATCH => {
            if (std.mem.eql(u8, sub_action, "webhook"))
                return decodeWebhook(body, param, http_path, now_ns, scratch);
            return decodeEnqueue(body, now_ns, scratch);
        },
        rpc.MSG_FETCH_BATCH => return decodeFetch(body, now_ns, scratch),
        rpc.MSG_ACK_BATCH => return decodeAck(body, param, now_ns, scratch),
        rpc.MSG_FAIL_BATCH => return decodeFail(body, param, now_ns, scratch),
        rpc.MSG_HEARTBEAT => return decodeHeartbeat(body, now_ns, scratch),
        rpc.MSG_BULK_ACTION => return decodeBulkAction(body, param, sub_action, now_ns, scratch),
        rpc.MSG_QUEUE_CONFIG => return decodeQueueConfig(body, param, sub_action),
        rpc.MSG_CLEAR_QUEUE => return .{ .op_data = .{ .clear_queue = .{ .queue = param, .now_ns = now_ns } }, .count = 1 },
        rpc.MSG_DELETE_QUEUE => return .{ .op_data = .{ .delete_queue = .{ .queue = param, .now_ns = now_ns } }, .count = 1 },
        rpc.MSG_BATCH_CREATE => return decodeBatchCreate(body, now_ns, scratch),
        rpc.MSG_BATCH_SEAL => return .{ .op_data = .{ .batch_seal = .{ .batch_id = param, .now_ns = now_ns } }, .count = 1 },
        rpc.MSG_CRON_CREATE => return decodeCronCreate(body, now_ns, scratch),
        rpc.MSG_CRON_UPDATE => return decodeCronUpdate(body, param, sub_action, now_ns),
        rpc.MSG_CRON_DELETE => return .{ .op_data = .{ .cron_delete = .{ .cron_id = param } }, .count = 1 },
        rpc.MSG_CRON_TRIGGER => return .{ .op_data = .{ .cron_trigger = .{
            .cron_id = param,
            .job_id = scratch.id_buf2[0..scratch.id2_len],
            .now_ns = now_ns,
        } }, .count = 1 },
        rpc.MSG_SET_BUDGET => return decodeSetBudget(body, now_ns, scratch),
        rpc.MSG_DELETE_BUDGET => return .{ .op_data = .{ .delete_budget = .{ .scope = param, .target = sub_action } }, .count = 1 },
        rpc.MSG_MODIFY_ENT_SETTING => return decodeEntSetting(body, param, sub_action, scratch),
        else => return .{ .op_data = .{ .enqueue = .{} }, .count = 0 },
    }
}

pub const DecodeScratch = struct {
    jobs: [64]ops_mod.EnqueueJob = undefined,
    acks: [128]ops_mod.AckJob = undefined,
    fails: [1]ops_mod.FailJob = undefined,
    hb_ids: [128][]const u8 = undefined,
    hb_ops: [128]ops_mod.HeartbeatJobOp = undefined,
    queue_slices: [16][]const u8 = undefined,
    id_buf: [64]u8 = undefined,
    // Bulk action job_ids (parsed from JSON array)
    bulk_ids: [128][]const u8 = undefined,
    // Secondary ID buf for generated cron_id, batch_id, budget_id, trigger job_id
    id_buf2: [64]u8 = undefined,
    id2_len: u8 = 0,
};

fn decodeEnqueue(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    // Batch format: {"jobs":[{...},{...},...]}
    if (extractJSONRaw(body, "jobs") != null)
        return decodeEnqueueBatch(body, now_ns, scratch);

    const queue = extractJSONString(body, "queue") orelse
        return errResult(.enqueue);

    // Preserve pre-set job_id from pipeline (generated before decode).
    const preset_id = scratch.jobs[0].job_id;

    var job = ops_mod.EnqueueJob{
        .job_id = preset_id,
        .queue = queue,
        .created_at_ns = now_ns,
        .max_retries = 3,
        .backoff = .exponential,
        .base_delay_ms = 5_000,
        .max_delay_ms = 600_000,
    };
    // Priority: integer or named string ("critical"=100, "high"=75, "normal"=50, "low"=25)
    if (extractJSONInt(body, "priority")) |p| {
        job.priority = @intCast(std.math.clamp(p, 0, 100));
    } else if (extractJSONString(body, "priority")) |s| {
        job.priority = parsePriorityString(s);
    }

    if (extractJSONInt(body, "max_retries")) |mr|
        job.max_retries = @intCast(std.math.clamp(mr, 0, 100));

    // Payload: extract raw JSON value.
    if (extractJSONRaw(body, "payload")) |pl|
        job.payload = pl;

    if (extractJSONString(body, "unique_key")) |uk|
        job.unique_key = uk;

    if (extractJSONInt(body, "unique_period")) |up|
        job.unique_period_s = @intCast(std.math.clamp(up, 0, 86400 * 30));

    if (extractJSONRaw(body, "tags")) |t|
        job.tags = t;

    if (extractJSONRaw(body, "checkpoint")) |cp|
        job.checkpoint = cp;

    if (extractJSONString(body, "group")) |g|
        job.group = g;

    if (extractJSONInt(body, "expire_after_ms")) |e|
        job.expire_after_ms = @intCast(std.math.clamp(e, 0, 86400_000 * 30));

    if (extractJSONString(body, "batch_id")) |bid|
        job.batch_id = bid;

    if (extractJSONString(body, "parent_id")) |pid|
        job.parent_id = pid;

    if (extractJSONString(body, "chain_id")) |cid|
        job.chain_id = cid;

    if (extractJSONInt(body, "chain_step")) |cs|
        job.chain_step = @intCast(std.math.clamp(cs, 0, 65535));

    if (extractJSONString(body, "retry_backoff")) |rb| {
        if (std.mem.eql(u8, rb, "exponential")) job.backoff = .exponential
        else if (std.mem.eql(u8, rb, "linear")) job.backoff = .linear;
    }

    if (extractJSONInt(body, "retry_base_delay_ms")) |d|
        job.base_delay_ms = @intCast(std.math.clamp(d, 0, 3600_000));

    if (extractJSONInt(body, "retry_max_delay_ms")) |d|
        job.max_delay_ms = @intCast(std.math.clamp(d, 0, 86400_000));

    if (extractJSONString(body, "scheduled_at")) |sat| {
        job.scheduled_at_ns = parseRfc3339Ns(sat) orelse 0;
    }

    if (extractJSONRaw(body, "chain_config")) |cc| job.chain_config = cc;
    if (extractJSONString(body, "chain")) |_| {
        // "chain" as object — extractJSONRaw gives us the raw JSON
        if (extractJSONRaw(body, "chain")) |cv| job.chain_config = cv;
    }
    if (job.chain_config != null and job.chain_id == null) job.chain_id = job.job_id;

    if (job.scheduled_at_ns > 0) job.state = .scheduled;

    scratch.jobs[0] = job;

    return .{
        .op_data = .{ .enqueue = .{
            .jobs = scratch.jobs[0..1],
            .now_ns = now_ns,
        } },
        .count = 1,
    };
}

fn decodeEnqueueBatch(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    const jobs_raw = extractJSONRaw(body, "jobs") orelse return errResult(.enqueue);
    if (jobs_raw.len < 2 or jobs_raw[0] != '[') return errResult(.enqueue);
    const inner = jobs_raw[1 .. jobs_raw.len - 1];

    var count: u16 = 0;
    var pos: usize = 0;
    while (pos < inner.len and count < 64) {
        // Skip whitespace and commas
        while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == ',' or
            inner[pos] == '\n' or inner[pos] == '\r' or inner[pos] == '\t')) pos += 1;
        if (pos >= inner.len) break;
        if (inner[pos] != '{') break;

        // Find matching closing brace
        var depth: u32 = 0;
        var end = pos;
        while (end < inner.len) : (end += 1) {
            if (inner[end] == '{') depth += 1
            else if (inner[end] == '}') {
                depth -= 1;
                if (depth == 0) { end += 1; break; }
            }
        }

        const job_json = inner[pos..end];
        pos = end;

        // Job ID is pre-set by pipeline before decode.
        const preset_id = scratch.jobs[count].job_id;
        scratch.jobs[count] = decodeSingleJob(job_json, preset_id, now_ns);
        count += 1;
    }

    if (count == 0) return errResult(.enqueue);

    return .{
        .op_data = .{ .enqueue = .{
            .jobs = scratch.jobs[0..count],
            .now_ns = now_ns,
        } },
        .count = count,
    };
}

fn decodeSingleJob(body: []const u8, job_id: []const u8, now_ns: u64) ops_mod.EnqueueJob {
    var job = ops_mod.EnqueueJob{
        .job_id = job_id,
        .queue = extractJSONString(body, "queue") orelse "",
        .created_at_ns = now_ns,
        .max_retries = 3,
        .backoff = .exponential,
        .base_delay_ms = 5_000,
        .max_delay_ms = 600_000,
    };
    if (extractJSONInt(body, "priority")) |p| {
        job.priority = @intCast(std.math.clamp(p, 0, 100));
    } else if (extractJSONString(body, "priority")) |s| {
        job.priority = parsePriorityString(s);
    }
    if (extractJSONInt(body, "max_retries")) |mr|
        job.max_retries = @intCast(std.math.clamp(mr, 0, 100));
    if (extractJSONRaw(body, "payload")) |pl| job.payload = pl;
    if (extractJSONString(body, "unique_key")) |uk| job.unique_key = uk;
    if (extractJSONRaw(body, "tags")) |t| job.tags = t;
    if (extractJSONString(body, "group")) |g| job.group = g;
    if (extractJSONString(body, "batch_id")) |bid| job.batch_id = bid;
    if (extractJSONString(body, "parent_id")) |pid| job.parent_id = pid;
    if (extractJSONString(body, "chain_id")) |cid| job.chain_id = cid;
    if (extractJSONInt(body, "chain_step")) |cs|
        job.chain_step = @intCast(std.math.clamp(cs, 0, 65535));
    if (extractJSONRaw(body, "chain_config")) |cc| job.chain_config = cc;
    if (extractJSONString(body, "chain")) |_| {
        if (extractJSONRaw(body, "chain")) |cv| job.chain_config = cv;
    }
    if (job.chain_config != null and job.chain_id == null) job.chain_id = job.job_id;
    if (extractJSONString(body, "scheduled_at")) |sat| {
        job.scheduled_at_ns = parseRfc3339Ns(sat) orelse 0;
    }
    if (extractJSONInt(body, "expire_after_ms")) |e|
        job.expire_after_ms = @intCast(std.math.clamp(e, 0, 86400_000 * 30));
    if (extractJSONString(body, "retry_backoff")) |rb| {
        if (std.mem.eql(u8, rb, "exponential")) job.backoff = .exponential
        else if (std.mem.eql(u8, rb, "linear")) job.backoff = .linear;
    }
    if (extractJSONInt(body, "retry_base_delay_ms")) |d|
        job.base_delay_ms = @intCast(std.math.clamp(d, 0, 3600_000));
    if (extractJSONInt(body, "retry_max_delay_ms")) |d|
        job.max_delay_ms = @intCast(std.math.clamp(d, 0, 86400_000));
    if (job.scheduled_at_ns > 0) job.state = .scheduled;
    return job;
}

fn decodeWebhook(body: []const u8, queue: []const u8, path: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    const preset_id = scratch.jobs[0].job_id;
    var job = ops_mod.EnqueueJob{
        .job_id = preset_id,
        .queue = queue,
        .created_at_ns = now_ns,
        .max_retries = 3,
        .backoff = .exponential,
        .base_delay_ms = 5_000,
        .max_delay_ms = 600_000,
    };

    // Body becomes payload (raw JSON or empty object).
    job.payload = if (body.len > 0) body else "{}";

    // Query params override defaults.
    if (extractQueryParam(path, "priority")) |p| {
        job.priority = parsePriorityString(p);
    }
    if (extractQueryParam(path, "unique_key")) |uk| job.unique_key = uk;
    if (extractQueryParam(path, "max_retries")) |mr| {
        const v = std.fmt.parseInt(i64, mr, 10) catch 3;
        job.max_retries = @intCast(std.math.clamp(v, 0, 100));
    }
    if (extractQueryParam(path, "scheduled_at")) |sat| {
        job.scheduled_at_ns = parseRfc3339Ns(sat) orelse 0;
    }
    if (job.scheduled_at_ns > 0) job.state = .scheduled;

    scratch.jobs[0] = job;
    return .{
        .op_data = .{ .enqueue = .{ .jobs = scratch.jobs[0..1], .now_ns = now_ns } },
        .count = 1,
    };
}

fn decodeFetch(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    // Extract queues array.
    const queue_count = extractJSONStringArray(body, "queues", &scratch.queue_slices);
    if (queue_count == 0) return errResult(.fetch);

    const worker_id = extractJSONString(body, "worker_id") orelse "";
    const hostname = extractJSONString(body, "hostname") orelse "";
    const count_val = extractJSONInt(body, "count");
    const count: u32 = if (count_val) |c| @intCast(std.math.clamp(c, 1, 512)) else 1;

    return .{
        .op_data = .{ .fetch = .{
            .queues = scratch.queue_slices[0..queue_count],
            .worker_id = worker_id,
            .hostname = hostname,
            .count = count,
            .lease_duration_ms = 30_000,
            .now_ns = now_ns,
        } },
        .count = 1,
    };
}

fn decodeAck(body: []const u8, job_id_param: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    // Batch format: {"acks":[{"job_id":"..."},...]} or {"job_ids":["...",...]}
    if (job_id_param.len == 0 and body.len > 0) {
        return decodeAckBatch(body, now_ns, scratch);
    }

    // Single ack: job_id from URL param or body
    const job_id = if (job_id_param.len > 0) job_id_param else (extractJSONString(body, "job_id") orelse "");

    var ack = ops_mod.AckJob{
        .job_id = job_id,
    };

    if (body.len > 0) {
        if (extractJSONRaw(body, "result")) |r| ack.result = r;
        if (extractJSONRaw(body, "checkpoint")) |cp| ack.checkpoint = cp;
        if (extractJSONString(body, "hold_reason")) |hr| ack.hold_reason = hr;
        if (extractJSONInt(body, "lease_token")) |lt| ack.lease_token = @intCast(lt);
        if (extractJSONString(body, "ack_status")) |as_str| {
            if (std.mem.eql(u8, as_str, "hold")) ack.ack_status = .hold;
        }
    }

    scratch.acks[0] = ack;

    return .{
        .op_data = .{ .ack = .{
            .acks = scratch.acks[0..1],
            .now_ns = now_ns,
        } },
        .count = 1,
    };
}

fn decodeAckBatch(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    // Format 1: {"acks":[{"job_id":"...","result":"..."},...]}
    if (extractJSONRaw(body, "acks")) |acks_raw| {
        if (acks_raw.len >= 2 and acks_raw[0] == '[') {
            const inner = acks_raw[1 .. acks_raw.len - 1];
            var count: u16 = 0;
            var pos: usize = 0;
            while (pos < inner.len and count < 128) {
                while (pos < inner.len and (inner[pos] == ' ' or inner[pos] == ',' or
                    inner[pos] == '\n' or inner[pos] == '\r' or inner[pos] == '\t')) pos += 1;
                if (pos >= inner.len) break;
                if (inner[pos] != '{') break;
                var depth: u32 = 0;
                var end = pos;
                while (end < inner.len) : (end += 1) {
                    if (inner[end] == '{') depth += 1
                    else if (inner[end] == '}') {
                        depth -= 1;
                        if (depth == 0) { end += 1; break; }
                    }
                }
                const obj = inner[pos..end];
                pos = end;

                const jid = extractJSONString(obj, "job_id") orelse continue;
                var ack = ops_mod.AckJob{ .job_id = jid };
                if (extractJSONRaw(obj, "result")) |r| ack.result = r;
                if (extractJSONRaw(obj, "checkpoint")) |cp| ack.checkpoint = cp;
                if (extractJSONString(obj, "hold_reason")) |hr| ack.hold_reason = hr;
                if (extractJSONString(obj, "ack_status")) |as_str| {
                    if (std.mem.eql(u8, as_str, "hold")) ack.ack_status = .hold;
                }
                scratch.acks[count] = ack;
                count += 1;
            }
            if (count > 0) return .{
                .op_data = .{ .ack = .{ .acks = scratch.acks[0..count], .now_ns = now_ns } },
                .count = count,
            };
        }
    }

    // Format 2: {"job_ids":["id1","id2",...]}
    var id_buf: [128][]const u8 = undefined;
    const id_count = extractJSONStringArray(body, "job_ids", &id_buf);
    if (id_count > 0) {
        const count: u16 = @intCast(@min(id_count, 128));
        for (0..count) |i| {
            scratch.acks[i] = ops_mod.AckJob{ .job_id = id_buf[i] };
        }
        return .{
            .op_data = .{ .ack = .{ .acks = scratch.acks[0..count], .now_ns = now_ns } },
            .count = count,
        };
    }

    return errResult(.ack);
}

fn decodeFail(body: []const u8, job_id: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    var fail = ops_mod.FailJob{
        .job_id = job_id,
    };

    if (body.len > 0) {
        if (extractJSONString(body, "error")) |e| fail.error_msg = e;
        if (extractJSONString(body, "backtrace")) |bt| fail.backtrace = bt;
        if (extractJSONInt(body, "lease_token")) |lt| fail.lease_token = @intCast(lt);
    }

    scratch.fails[0] = fail;

    return .{
        .op_data = .{ .fail = .{
            .jobs = scratch.fails[0..1],
            .now_ns = now_ns,
        } },
        .count = 1,
    };
}

fn decodeHeartbeat(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    const worker_id = extractJSONString(body, "worker_id") orelse
        return errResult(.heartbeat);

    // Parse jobs array: [{"job_id":"...","progress":"...","checkpoint":"..."}]
    const jobs_raw = extractJSONRaw(body, "jobs") orelse
        return .{
        .op_data = .{ .heartbeat = .{
            .job_ids = &.{},
            .job_ops = &.{},
            .worker_id = worker_id,
            .now_ns = now_ns,
        } },
        .count = 0,
    };

    var count: usize = 0;
    var pos: usize = 0;
    while (count < 128 and pos < jobs_raw.len) {
        // Find next object.
        const obj_start = std.mem.indexOfScalar(u8, jobs_raw[pos..], '{') orelse break;
        const obj_end = std.mem.indexOfScalar(u8, jobs_raw[pos + obj_start..], '}') orelse break;
        const obj = jobs_raw[pos + obj_start .. pos + obj_start + obj_end + 1];

        const jid = extractJSONString(obj, "job_id") orelse {
            pos = pos + obj_start + obj_end + 1;
            continue;
        };

        scratch.hb_ids[count] = jid;
        scratch.hb_ops[count] = .{
            .progress = extractJSONRaw(obj, "progress"),
            .checkpoint = extractJSONRaw(obj, "checkpoint"),
        };
        count += 1;
        pos = pos + obj_start + obj_end + 1;
    }

    return .{
        .op_data = .{ .heartbeat = .{
            .job_ids = scratch.hb_ids[0..count],
            .job_ops = scratch.hb_ops[0..count],
            .worker_id = worker_id,
            .now_ns = now_ns,
        } },
        .count = @intCast(count),
    };
}

fn decodeBulkAction(body: []const u8, param: []const u8, sub_action: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    if (sub_action.len > 0) {
        // Single-job action from URL: /jobs/{id}/{action}
        scratch.bulk_ids[0] = param;
        const action = parseBulkAction(sub_action) orelse return .{ .op_data = .{ .bulk_action = .{} }, .count = 0 };
        var op = ops_mod.BulkActionOp{
            .job_ids = scratch.bulk_ids[0..1],
            .action = action,
            .now_ns = now_ns,
        };
        if (action == .move) {
            op.move_to_queue = extractJSONString(body, "queue") orelse "";
        }
        return .{ .op_data = .{ .bulk_action = op }, .count = 1 };
    }

    // Bulk from body: POST /jobs/bulk
    const action_str = extractJSONString(body, "action") orelse
        return .{ .op_data = .{ .bulk_action = .{} }, .count = 0 };
    const action = parseBulkAction(action_str) orelse
        return .{ .op_data = .{ .bulk_action = .{} }, .count = 0 };
    const count = extractJSONStringArray(body, "job_ids", &scratch.bulk_ids);
    if (count == 0) return .{ .op_data = .{ .bulk_action = .{} }, .count = 0 };

    var op = ops_mod.BulkActionOp{
        .job_ids = scratch.bulk_ids[0..count],
        .action = action,
        .now_ns = now_ns,
    };
    if (action == .move)
        op.move_to_queue = extractJSONString(body, "move_to_queue");
    if (action == .change_priority) {
        if (extractJSONInt(body, "priority")) |p|
            op.priority = @intCast(std.math.clamp(p, 0, 255));
    }
    return .{ .op_data = .{ .bulk_action = op }, .count = @intCast(count) };
}

fn parseBulkAction(s: []const u8) ?ops_mod.BulkAction {
    if (std.mem.eql(u8, s, "delete")) return .delete;
    if (std.mem.eql(u8, s, "cancel")) return .cancel;
    if (std.mem.eql(u8, s, "move")) return .move;
    if (std.mem.eql(u8, s, "requeue")) return .requeue;
    if (std.mem.eql(u8, s, "change_priority")) return .change_priority;
    if (std.mem.eql(u8, s, "hold")) return .hold;
    if (std.mem.eql(u8, s, "approve")) return .approve;
    if (std.mem.eql(u8, s, "reject")) return .reject;
    return null;
}

fn decodeQueueConfig(body: []const u8, queue: []const u8, sub_action: []const u8) DecodeResult {
    var op = ops_mod.QueueOp{ .queue = queue };

    if (std.mem.eql(u8, sub_action, "pause") or std.mem.eql(u8, sub_action, "drain")) {
        op.action = .pause;
    } else if (std.mem.eql(u8, sub_action, "resume")) {
        op.action = .@"resume";
    } else if (std.mem.eql(u8, sub_action, "concurrency")) {
        op.action = .concurrency;
        if (extractJSONInt(body, "max")) |m|
            op.max_concurrency = @intCast(std.math.clamp(m, 0, std.math.maxInt(i32)));
    } else if (std.mem.eql(u8, sub_action, "throttle")) {
        op.action = .throttle;
        if (extractJSONInt(body, "rate")) |r|
            op.rate_limit = @intCast(std.math.clamp(r, 0, std.math.maxInt(i32)));
        op.rate_window_ms = if (extractJSONInt(body, "window_ms")) |w|
            @intCast(std.math.clamp(w, 0, std.math.maxInt(i32)))
        else
            1000;
    } else if (std.mem.eql(u8, sub_action, "fairness")) {
        op.action = .fairness;
        op.fairness = true;
    } else if (std.mem.eql(u8, sub_action, "throttle_remove")) {
        op.action = .throttle;
        op.rate_limit = 0;
        op.rate_window_ms = 0;
    } else if (std.mem.eql(u8, sub_action, "fairness_remove")) {
        op.action = .fairness;
        op.fairness = false;
    } else {
        return .{ .op_data = .{ .queue_config = .{} }, .count = 0 };
    }

    return .{ .op_data = .{ .queue_config = op }, .count = 1 };
}

fn decodeBatchCreate(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    const callback_queue = extractJSONString(body, "callback_queue") orelse "";
    return .{
        .op_data = .{ .batch_create = .{
            .batch_id = scratch.id_buf2[0..scratch.id2_len],
            .callback_queue = callback_queue,
            .callback_payload = extractJSONRaw(body, "callback_payload"),
            .created_at_ns = now_ns,
        } },
        .count = 1,
    };
}

fn decodeCronCreate(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    const name = extractJSONString(body, "name") orelse
        return .{ .op_data = .{ .cron_create = .{} }, .count = 0 };
    const queue = extractJSONString(body, "queue") orelse
        return .{ .op_data = .{ .cron_create = .{} }, .count = 0 };
    const schedule = extractJSONString(body, "schedule") orelse
        return .{ .op_data = .{ .cron_create = .{} }, .count = 0 };

    var op = ops_mod.CreateCronOp{
        .cron_id = scratch.id_buf2[0..scratch.id2_len],
        .name = name,
        .queue = queue,
        .schedule = schedule,
        .timezone = extractJSONString(body, "timezone") orelse "UTC",
        .payload = extractJSONRaw(body, "payload"),
        .unique_key = extractJSONString(body, "unique_key"),
        .created_at_ns = now_ns,
        .now_ns = now_ns,
    };
    if (extractJSONInt(body, "max_retries")) |mr|
        op.max_retries = @intCast(std.math.clamp(mr, 0, 100));
    if (extractJSONBool(body, "enabled")) |e|
        op.enabled = e;

    return .{ .op_data = .{ .cron_create = op }, .count = 1 };
}

fn decodeCronUpdate(body: []const u8, cron_id: []const u8, sub_action: []const u8, now_ns: u64) DecodeResult {
    var op = ops_mod.UpdateCronOp{
        .cron_id = cron_id,
        .now_ns = now_ns,
    };

    if (std.mem.eql(u8, sub_action, "pause")) {
        op.enabled = false;
    } else if (std.mem.eql(u8, sub_action, "resume")) {
        op.enabled = true;
    } else {
        // Full update from body
        op.name = extractJSONString(body, "name");
        op.queue = extractJSONString(body, "queue");
        op.schedule = extractJSONString(body, "schedule");
        op.timezone = extractJSONString(body, "timezone");
        op.payload = extractJSONRaw(body, "payload");
        op.unique_key = extractJSONString(body, "unique_key");
        if (extractJSONInt(body, "max_retries")) |mr|
            op.max_retries = @intCast(std.math.clamp(mr, 0, 100));
        if (extractJSONBool(body, "enabled")) |e|
            op.enabled = e;
    }

    return .{ .op_data = .{ .cron_update = op }, .count = 1 };
}

fn decodeSetBudget(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    const scope = extractJSONString(body, "scope") orelse "";
    const target = extractJSONString(body, "target") orelse "";

    var op = ops_mod.SetBudgetOp{
        .id = scratch.id_buf2[0..scratch.id2_len],
        .scope = scope,
        .target = target,
        .created_at_ns = now_ns,
    };
    if (extractJSONFloat(body, "daily_usd")) |d| op.daily_usd = d;
    if (extractJSONFloat(body, "per_job_usd")) |p| op.per_job_usd = p;
    if (extractJSONString(body, "on_exceed")) |oe| op.on_exceed = oe;

    return .{ .op_data = .{ .set_budget = op }, .count = 1 };
}

fn decodeEntSetting(body: []const u8, param: []const u8, sub_action: []const u8, scratch: *DecodeScratch) DecodeResult {
    if (std.mem.eql(u8, sub_action, "approval_policy")) {
        return .{ .op_data = .{ .modify_ent_setting = .{
            .setting = .approval_policy,
            .id = scratch.id_buf2[0..scratch.id2_len],
            .data = if (body.len > 0) body else null,
        } }, .count = 1 };
    }
    if (std.mem.eql(u8, sub_action, "approval_policy_delete")) {
        return .{ .op_data = .{ .modify_ent_setting = .{
            .setting = .approval_policy,
            .id = param,
            .data = null,
        } }, .count = 1 };
    }
    if (std.mem.eql(u8, sub_action, "api_key")) {
        return .{ .op_data = .{ .modify_ent_setting = .{
            .setting = .api_key,
            .id = scratch.id_buf2[0..scratch.id2_len],
            .data = if (body.len > 0) body else null,
        } }, .count = 1 };
    }
    if (std.mem.eql(u8, sub_action, "api_key_delete")) {
        // key_hash from body
        const key_hash = extractJSONString(body, "key_hash") orelse "";
        return .{ .op_data = .{ .modify_ent_setting = .{
            .setting = .api_key,
            .id = key_hash,
            .data = null,
        } }, .count = 1 };
    }
    return .{ .op_data = .{ .modify_ent_setting = .{} }, .count = 0 };
}

/// Extract a JSON boolean value: "key":true → true, "key":false → false.
pub fn extractJSONBool(body: []const u8, key: []const u8) ?bool {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    var val_start = start + search_key.len;
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start >= body.len) return null;
    if (val_start + 4 <= body.len and std.mem.eql(u8, body[val_start..][0..4], "true")) return true;
    if (val_start + 5 <= body.len and std.mem.eql(u8, body[val_start..][0..5], "false")) return false;
    return null;
}

/// Extract a JSON float value: "key":1.5 → 1.5.
pub fn extractJSONFloat(body: []const u8, key: []const u8) ?f64 {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    var val_start = start + search_key.len;
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start >= body.len) return null;
    var end = val_start;
    if (end < body.len and body[end] == '-') end += 1;
    while (end < body.len and ((body[end] >= '0' and body[end] <= '9') or body[end] == '.'))
        end += 1;
    if (end == val_start) return null;
    return std.fmt.parseFloat(f64, body[val_start..end]) catch null;
}

fn errResult(comptime op: ops_mod.OpType) DecodeResult {
    return .{
        .op_data = switch (op) {
            .enqueue => .{ .enqueue = .{} },
            .fetch => .{ .fetch = .{} },
            .ack => .{ .ack = .{} },
            .fail => .{ .fail = .{} },
            .heartbeat => .{ .heartbeat = .{} },
            else => unreachable,
        },
        .count = 0,
    };
}

// ============================================================================
// Write Response Encode — OpResult → JSON HTTP response
// ============================================================================

/// Encode an OpResult as a JSON HTTP response. Returns bytes written to send_buf.
/// `store` is used by fetch responses to load payload/checkpoint/tags from KV.
pub fn encodeWriteResponse(
    send_buf: []u8,
    msg_type: u8,
    result: *const ops_mod.OpResult,
    path_param: []const u8,
    sub_action: []const u8,
    store: ?*kv.Store,
    request_body: []const u8,
) u32 {
    if (result.err) |err| {
        if (std.mem.eql(u8, err, "unique_existing")) {
            const uid = result.unique_job_id_buf[0..result.unique_job_id_len];
            var body_buf: [256]u8 = undefined;
            var jw = json.JsonWriter.init(&body_buf);
            jw.beginObject();
            jw.fieldBool("unique_existing", true);
            jw.fieldStr("unique_job_id", uid);
            jw.endObject();
            return writeResponse(send_buf, 409, jw.getWritten());
        }
        return writeErrorResponse(send_buf, 500, err);
    }

    switch (msg_type) {
        rpc.MSG_ENQUEUE_BATCH => {
            // Batch enqueue: result.affected > 1, job_ids in fetched array
            if (result.affected > 1) {
                var body_buf: [8192]u8 = undefined;
                var jw = json.JsonWriter.init(&body_buf);
                jw.beginObject();
                jw.beginArrayField("job_ids");
                for (0..result.affected) |i| {
                    jw.elemStr(result.fetched[i].id_buf[0..result.fetched[i].id_len]);
                }
                jw.endArray();
                jw.endObject();
                return writeResponse(send_buf, 201, jw.getWritten());
            }
            // Single enqueue
            var body_buf: [512]u8 = undefined;
            var jw = json.JsonWriter.init(&body_buf);
            jw.beginObject();
            jw.beginObjectField("job");
            jw.fieldStr("id", path_param);
            jw.endObject();
            jw.endObject();
            return writeResponse(send_buf, 201, jw.getWritten());
        },
        rpc.MSG_FETCH_BATCH => return encodeFetchResponse(send_buf, result, store),
        rpc.MSG_ACK_BATCH => {
            if (result.affected > 1) {
                var body_buf: [128]u8 = undefined;
                var jw = json.JsonWriter.init(&body_buf);
                jw.beginObject();
                jw.fieldInt("acked", result.affected);
                jw.endObject();
                return writeResponse(send_buf, 200, jw.getWritten());
            }
            return writeResponse(send_buf, 200, "{\"status\":\"ok\"}");
        },
        rpc.MSG_FAIL_BATCH => return writeResponse(send_buf, 200, "{\"status\":\"ok\"}"),
        rpc.MSG_HEARTBEAT => return encodeHeartbeatResponse(send_buf, request_body, store),
        rpc.MSG_BULK_ACTION => return encodeAffectedResponse(send_buf, result.affected, sub_action),
        rpc.MSG_QUEUE_CONFIG => return encodeQueueConfigResponse(send_buf, sub_action),
        rpc.MSG_CLEAR_QUEUE => return encodeAffectedResponse(send_buf, result.affected, ""),
        rpc.MSG_DELETE_QUEUE => return writeResponse(send_buf, 200, "{\"status\":\"deleted\"}"),
        rpc.MSG_BATCH_CREATE => {
            var body_buf: [256]u8 = undefined;
            var jw = json.JsonWriter.init(&body_buf);
            jw.beginObject();
            jw.fieldStr("batch_id", path_param);
            jw.endObject();
            return writeResponse(send_buf, 201, jw.getWritten());
        },
        rpc.MSG_BATCH_SEAL => return writeResponse(send_buf, 200, "{\"status\":\"ok\"}"),
        rpc.MSG_CRON_CREATE => {
            var body_buf: [256]u8 = undefined;
            var jw = json.JsonWriter.init(&body_buf);
            jw.beginObject();
            jw.fieldStr("cron_id", path_param);
            jw.endObject();
            return writeResponse(send_buf, 201, jw.getWritten());
        },
        rpc.MSG_CRON_UPDATE, rpc.MSG_CRON_DELETE, rpc.MSG_CRON_TRIGGER => return writeResponse(send_buf, 200, "{\"status\":\"ok\"}"),
        rpc.MSG_SET_BUDGET, rpc.MSG_DELETE_BUDGET => return writeResponse(send_buf, 200, "{\"status\":\"ok\"}"),
        rpc.MSG_MODIFY_ENT_SETTING => return writeResponse(send_buf, 200, "{\"status\":\"ok\"}"),
        else => return writeResponse(send_buf, 200, "{\"status\":\"ok\"}"),
    }
}

fn encodeAffectedResponse(send_buf: []u8, affected: u32, sub_action: []const u8) u32 {
    // Single-job actions with a sub_action get a status response
    if (sub_action.len > 0 and !std.mem.eql(u8, sub_action, "delete")) {
        if (std.mem.eql(u8, sub_action, "move"))
            return writeResponse(send_buf, 200, "{\"status\":\"moved\"}");
        return writeResponse(send_buf, 200, "{\"status\":\"ok\"}");
    }
    var body_buf: [128]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldInt("affected", affected);
    jw.endObject();
    return writeResponse(send_buf, 200, jw.getWritten());
}

fn encodeQueueConfigResponse(send_buf: []u8, sub_action: []const u8) u32 {
    if (std.mem.eql(u8, sub_action, "pause")) return writeResponse(send_buf, 200, "{\"status\":\"paused\"}");
    if (std.mem.eql(u8, sub_action, "resume")) return writeResponse(send_buf, 200, "{\"status\":\"resumed\"}");
    if (std.mem.eql(u8, sub_action, "drain")) return writeResponse(send_buf, 200, "{\"status\":\"draining\"}");
    return writeResponse(send_buf, 200, "{\"status\":\"ok\"}");
}

fn encodeFetchResponse(send_buf: []u8, result: *const ops_mod.OpResult, store: ?*kv.Store) u32 {
    const count = result.affected;
    if (count == 0) {
        return writeResponse(send_buf, 200, "{\"job_id\":\"\",\"queue\":\"\",\"payload\":null,\"attempt\":0,\"max_retries\":0,\"lease_duration\":0}");
    }

    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);

    const f = &result.fetched[0];
    const job_id = f.id_buf[0..f.id_len];

    jw.beginObject();
    jw.fieldStr("job_id", job_id);
    jw.fieldStr("queue", f.queue_buf[0..f.queue_len]);
    jw.fieldInt("attempt", f.attempt);
    jw.fieldInt("max_retries", f.max_retries);
    jw.fieldInt("lease_duration", f.lease_duration_ms / 1000);
    jw.fieldInt("lease_token", f.lease_token);

    if (store) |s| {
        var batch = s.newBatch();
        defer batch.close();

        // Load payload from KV
        var payload_buf: [32768]u8 = undefined;
        var jpk_buf: keys.KeyBuf = undefined;
        const payload_key = keys.jobPayloadKey(&jpk_buf, job_id);
        if (batch.getInto(payload_key, &payload_buf)) |payload_bytes| {
            jw.fieldRaw("payload", payload_bytes);
        } else {
            jw.fieldRaw("payload", "null");
        }

        // Load checkpoint and tags from job header
        var header_buf: [4096]u8 = undefined;
        var jk_buf: keys.KeyBuf = undefined;
        const job_key = keys.jobKey(&jk_buf, job_id);
        if (batch.getInto(job_key, &header_buf)) |job_bytes| {
            const job_decoded = codec.decodeJob(job_bytes);
            if (job_decoded.checkpoint) |cp| {
                if (cp.len > 0) jw.fieldRaw("checkpoint", cp);
            }
            if (job_decoded.tags) |tags| {
                if (tags.len > 0) jw.fieldRaw("tags", tags);
            }
        }
    } else {
        jw.fieldRaw("payload", "null");
    }

    jw.endObject();
    return writeResponse(send_buf, 200, jw.getWritten());
}

fn encodeHeartbeatResponse(send_buf: []u8, request_body: []const u8, store: ?*kv.Store) u32 {
    // Re-parse job IDs from the request body to build per-job status map.
    const jobs_raw = extractJSONRaw(request_body, "jobs") orelse
        return writeResponse(send_buf, 200, "{\"status\":\"ok\"}");

    var body_buf: [8192]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.beginObjectField("jobs");

    var pos: usize = 0;
    while (pos < jobs_raw.len) {
        const obj_start = std.mem.indexOfScalar(u8, jobs_raw[pos..], '{') orelse break;
        const obj_end = std.mem.indexOfScalar(u8, jobs_raw[pos + obj_start..], '}') orelse break;
        const obj = jobs_raw[pos + obj_start .. pos + obj_start + obj_end + 1];

        const jid = extractJSONString(obj, "job_id") orelse {
            pos = pos + obj_start + obj_end + 1;
            continue;
        };

        // Check if job exists in KV (zero-alloc via getInto).
        const status: []const u8 = if (store) |s| blk: {
            var batch = s.newBatch();
            defer batch.close();
            var jk_buf: keys.KeyBuf = undefined;
            const job_key = keys.jobKey(&jk_buf, jid);
            var val_buf: [4096]u8 = undefined;
            break :blk if (batch.getInto(job_key, &val_buf) != null) "ok" else "cancel";
        } else "ok";

        jw.beginObjectField(jid);
        jw.beginObject();
        jw.fieldStr("status", status);
        jw.endObject();

        pos = pos + obj_start + obj_end + 1;
    }

    jw.endObject(); // close "jobs"
    jw.endObject(); // close root
    return writeResponse(send_buf, 200, jw.getWritten());
}

fn writeErrorResponse(send_buf: []u8, status: u16, msg: []const u8) u32 {
    var body_buf: [256]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldStr("error", msg);
    jw.endObject();
    return writeResponse(send_buf, status, jw.getWritten());
}

/// Parse RFC3339 timestamp to nanoseconds since epoch.
/// Supports: "2024-01-15T10:30:00Z" and "2024-01-15T10:30:00+05:00"
pub fn parseRfc3339Ns(s: []const u8) ?u64 {
    if (s.len < 20) return null;
    const year = std.fmt.parseInt(u32, s[0..4], 10) catch return null;
    if (s[4] != '-') return null;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    if (s[7] != '-') return null;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    if (s[10] != 'T' and s[10] != 't') return null;
    const hour = std.fmt.parseInt(u32, s[11..13], 10) catch return null;
    if (s[13] != ':') return null;
    const minute = std.fmt.parseInt(u32, s[14..16], 10) catch return null;
    if (s[16] != ':') return null;
    const second = std.fmt.parseInt(u32, s[17..19], 10) catch return null;

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    const epoch_days: i64 = 719528;
    const y: i64 = @intCast(year);
    const m: i64 = @intCast(month);
    const d: i64 = @intCast(day);
    const adj_m = if (m > 2) m - 3 else m + 9;
    const adj_y = if (m <= 2) y - 1 else y;
    const total_days = adj_y * 365 + @divFloor(adj_y, 4) - @divFloor(adj_y, 100) + @divFloor(adj_y, 400) +
        @divFloor(adj_m * 306 + 5, 10) + d - 1 - epoch_days + 60;

    var offset_seconds: i64 = 0;
    if (s.len > 19) {
        if (s[19] == 'Z' or s[19] == 'z') {
            // UTC
        } else if ((s[19] == '+' or s[19] == '-') and s.len >= 25) {
            const oh = std.fmt.parseInt(i64, s[20..22], 10) catch return null;
            const om = std.fmt.parseInt(i64, s[23..25], 10) catch return null;
            offset_seconds = (oh * 3600 + om * 60);
            if (s[19] == '+') offset_seconds = -offset_seconds;
        }
    }

    const total_seconds = total_days * 86400 + @as(i64, @intCast(hour)) * 3600 +
        @as(i64, @intCast(minute)) * 60 + @as(i64, @intCast(second)) + offset_seconds;

    if (total_seconds < 0) return null;
    return @intCast(total_seconds * 1_000_000_000);
}

fn parsePriorityString(s: []const u8) u8 {
    if (std.mem.eql(u8, s, "critical")) return types.priority_critical;
    if (std.mem.eql(u8, s, "high")) return types.priority_high;
    if (std.mem.eql(u8, s, "normal")) return types.priority_default;
    if (std.mem.eql(u8, s, "low")) return types.priority_low;
    const n = std.fmt.parseInt(i64, s, 10) catch return types.priority_default;
    return @intCast(std.math.clamp(n, 0, 100));
}

// ============================================================================
// JSON Extraction Helpers — zero-alloc parsing from raw JSON bytes
// ============================================================================

/// Extract a JSON string value: "key":"value" or "key": "value" → value.
pub fn extractJSONString(body: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    var val_start = start + search_key.len;
    // Skip whitespace between : and opening quote.
    while (val_start < body.len and (body[val_start] == ' ' or body[val_start] == '\t')) val_start += 1;
    if (val_start >= body.len or body[val_start] != '"') return null;
    val_start += 1; // skip opening quote
    // Find closing quote, handling escaped quotes.
    var i = val_start;
    while (i < body.len) : (i += 1) {
        if (body[i] == '"' and (i == val_start or body[i - 1] != '\\')) break;
    }
    if (i >= body.len) return null;
    return body[val_start..i];
}

/// Extract a JSON integer value: "key":123 → 123.
pub fn extractJSONInt(body: []const u8, key: []const u8) ?i64 {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    const val_start = start + search_key.len;
    if (val_start >= body.len) return null;

    // Skip whitespace.
    var i = val_start;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) i += 1;
    if (i >= body.len) return null;

    // Don't parse strings or objects as ints.
    if (body[i] == '"' or body[i] == '{' or body[i] == '[') return null;

    var end = i;
    if (end < body.len and body[end] == '-') end += 1;
    while (end < body.len and body[end] >= '0' and body[end] <= '9') end += 1;
    if (end == i) return null;
    return std.fmt.parseInt(i64, body[i..end], 10) catch null;
}

/// Extract a raw JSON value (string, object, array, number, bool, null).
/// Returns the raw bytes of the value including quotes for strings.
pub fn extractJSONRaw(body: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    var val_start = start + search_key.len;
    if (val_start >= body.len) return null;

    // Skip whitespace.
    while (val_start < body.len and (body[val_start] == ' ' or body[val_start] == '\t'))
        val_start += 1;
    if (val_start >= body.len) return null;

    return switch (body[val_start]) {
        '"' => extractJSONStringRaw(body, val_start),
        '{' => extractBracketed(body, val_start, '{', '}'),
        '[' => extractBracketed(body, val_start, '[', ']'),
        else => extractPrimitive(body, val_start),
    };
}

fn extractJSONStringRaw(body: []const u8, start: usize) ?[]const u8 {
    // Return the string content without surrounding quotes.
    var i = start + 1;
    while (i < body.len) : (i += 1) {
        if (body[i] == '"' and body[i - 1] != '\\')
            return body[start + 1 .. i];
    }
    return null;
}

fn extractBracketed(body: []const u8, start: usize, open: u8, close: u8) ?[]const u8 {
    var depth: u32 = 0;
    var in_string = false;
    var i = start;
    while (i < body.len) : (i += 1) {
        if (in_string) {
            if (body[i] == '"' and body[i - 1] != '\\') in_string = false;
            continue;
        }
        if (body[i] == '"') {
            in_string = true;
        } else if (body[i] == open) {
            depth += 1;
        } else if (body[i] == close) {
            depth -= 1;
            if (depth == 0) return body[start .. i + 1];
        }
    }
    return null;
}

fn extractPrimitive(body: []const u8, start: usize) ?[]const u8 {
    var end = start;
    while (end < body.len and body[end] != ',' and body[end] != '}' and body[end] != ']' and body[end] != ' ')
        end += 1;
    if (end == start) return null;
    return body[start..end];
}

/// Extract a JSON array of strings: "key":["a","b"] → fills out with slices.
pub fn extractJSONStringArray(body: []const u8, key: []const u8, out: [][]const u8) usize {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return 0;
    const start = std.mem.indexOf(u8, body, search_key) orelse return 0;
    var arr_start = start + search_key.len;
    // Skip whitespace between : and [
    while (arr_start < body.len and (body[arr_start] == ' ' or body[arr_start] == '\t')) arr_start += 1;
    if (arr_start >= body.len or body[arr_start] != '[') return 0;
    arr_start += 1; // skip [

    var count: usize = 0;
    var i = arr_start;
    while (i < body.len and count < out.len) {
        const q1 = std.mem.indexOfScalar(u8, body[i..], '"') orelse break;
        const str_start = i + q1 + 1;
        if (str_start >= body.len) break;
        // Check for array end before this quote.
        const bracket = std.mem.indexOfScalar(u8, body[i..], ']') orelse break;
        if (bracket < q1) break;

        var str_end = str_start;
        while (str_end < body.len) : (str_end += 1) {
            if (body[str_end] == '"' and (str_end == str_start or body[str_end - 1] != '\\')) break;
        }
        if (str_end >= body.len) break;
        out[count] = body[str_start..str_end];
        count += 1;
        i = str_end + 1;
    }
    return count;
}

// ============================================================================
// ID Generation — deterministic, for HTTP requests that need server-generated IDs
// ============================================================================

/// Generate a job ID into `buf` using timestamp + counter.
/// Returns the slice of buf that was written.
pub fn generateId(buf: []u8, now_ns: u64, counter: u64) []const u8 {
    const ts_ms = now_ns / 1_000_000;
    return std.fmt.bufPrint(buf, "job_{x}_{x}", .{ ts_ms, counter }) catch "job_err";
}

// ============================================================================
// Tests
// ============================================================================

test "parseRequest — simple GET" {
    const raw = "GET /api/v1/info HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const req = parseRequest(raw).?;
    try std.testing.expectEqual(Method.GET, req.method);
    try std.testing.expectEqualStrings("/api/v1/info", req.path);
    try std.testing.expectEqual(@as(usize, 0), req.body.len);
    try std.testing.expectEqual(@as(u32, @intCast(raw.len)), req.total_len);
}

test "parseRequest — POST with body" {
    const raw = "POST /api/v1/enqueue HTTP/1.1\r\nContent-Length: 19\r\nHost: localhost\r\n\r\n{\"queue\":\"default\"}";
    const req = parseRequest(raw).?;
    try std.testing.expectEqual(Method.POST, req.method);
    try std.testing.expectEqualStrings("/api/v1/enqueue", req.path);
    try std.testing.expectEqualStrings("{\"queue\":\"default\"}", req.body);
}

test "parseRequest — incomplete headers" {
    const raw = "GET /api/v1/info HTTP/1.1\r\nHost: local";
    try std.testing.expect(parseRequest(raw) == null);
}

test "parseRequest — incomplete body" {
    const raw = "POST /api/v1/enqueue HTTP/1.1\r\nContent-Length: 100\r\n\r\n{\"queue\":\"default\"}";
    try std.testing.expect(parseRequest(raw) == null);
}

test "writeResponse" {
    var buf: [512]u8 = undefined;
    const len = writeResponse(&buf, 200, "{\"ok\":true}");
    const resp = buf[0..len];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, resp, "{\"ok\":true}"));
    try std.testing.expect(std.mem.indexOf(u8, resp, "Content-Length: 11\r\n") != null);
}

test "extractQueryParam" {
    try std.testing.expectEqualStrings("hello", extractQueryParam("/api?q=hello", "q").?);
    try std.testing.expectEqualStrings("10", extractQueryParam("/api?q=hello&limit=10", "limit").?);
    try std.testing.expect(extractQueryParam("/api?q=hello", "missing") == null);
    try std.testing.expect(extractQueryParam("/api", "q") == null);
}

test "classifyRoute — reads" {
    try std.testing.expect(classifyRoute(.GET, "/api/v1/info") == .read);
    try std.testing.expect(classifyRoute(.GET, "/api/v1/queues") == .read);
    try std.testing.expect(classifyRoute(.GET, "/api/v1/jobs/abc") == .read);
}

test "classifyRoute — writes" {
    const enq = classifyRoute(.POST, "/api/v1/enqueue");
    try std.testing.expect(enq == .write);
    try std.testing.expectEqual(rpc.MSG_ENQUEUE_BATCH, enq.write.msg_type);

    const ack = classifyRoute(.POST, "/api/v1/ack/job-123");
    try std.testing.expect(ack == .write);
    try std.testing.expectEqualStrings("job-123", ack.write.param);

    // Bulk
    const bulk = classifyRoute(.POST, "/api/v1/jobs/bulk");
    try std.testing.expect(bulk == .write);
    try std.testing.expectEqual(rpc.MSG_BULK_ACTION, bulk.write.msg_type);

    // Single job action
    const cancel = classifyRoute(.POST, "/api/v1/jobs/j1/cancel");
    try std.testing.expect(cancel == .write);
    try std.testing.expectEqualStrings("j1", cancel.write.param);
    try std.testing.expectEqualStrings("cancel", cancel.write.sub_action);

    // Queue config
    const pause = classifyRoute(.POST, "/api/v1/queues/myq/pause");
    try std.testing.expect(pause == .write);
    try std.testing.expectEqual(rpc.MSG_QUEUE_CONFIG, pause.write.msg_type);
    try std.testing.expectEqualStrings("myq", pause.write.param);
    try std.testing.expectEqualStrings("pause", pause.write.sub_action);

    // Queue clear
    const clear = classifyRoute(.POST, "/api/v1/queues/q1/clear");
    try std.testing.expect(clear == .write);
    try std.testing.expectEqual(rpc.MSG_CLEAR_QUEUE, clear.write.msg_type);

    // Queue delete
    const qdel = classifyRoute(.DELETE, "/api/v1/queues/q1");
    try std.testing.expect(qdel == .write);
    try std.testing.expectEqual(rpc.MSG_DELETE_QUEUE, qdel.write.msg_type);
    try std.testing.expectEqualStrings("q1", qdel.write.param);

    // Batch
    const bc = classifyRoute(.POST, "/api/v1/batch");
    try std.testing.expect(bc == .write);
    try std.testing.expectEqual(rpc.MSG_BATCH_CREATE, bc.write.msg_type);

    const seal = classifyRoute(.POST, "/api/v1/batch/b1/seal");
    try std.testing.expect(seal == .write);
    try std.testing.expectEqualStrings("b1", seal.write.param);

    // Cron
    const cc = classifyRoute(.POST, "/api/v1/cron-jobs");
    try std.testing.expect(cc == .write);
    try std.testing.expectEqual(rpc.MSG_CRON_CREATE, cc.write.msg_type);

    const cu = classifyRoute(.PUT, "/api/v1/cron-jobs/c1");
    try std.testing.expect(cu == .write);
    try std.testing.expectEqual(rpc.MSG_CRON_UPDATE, cu.write.msg_type);

    const cd = classifyRoute(.DELETE, "/api/v1/crons/c1");
    try std.testing.expect(cd == .write);
    try std.testing.expectEqual(rpc.MSG_CRON_DELETE, cd.write.msg_type);

    const ct = classifyRoute(.POST, "/api/v1/cron-jobs/c1/trigger");
    try std.testing.expect(ct == .write);
    try std.testing.expectEqual(rpc.MSG_CRON_TRIGGER, ct.write.msg_type);

    // Budget
    const bs = classifyRoute(.POST, "/api/v1/budgets");
    try std.testing.expect(bs == .write);
    try std.testing.expectEqual(rpc.MSG_SET_BUDGET, bs.write.msg_type);

    const bd = classifyRoute(.DELETE, "/api/v1/budgets/queue/default");
    try std.testing.expect(bd == .write);
    try std.testing.expectEqualStrings("queue", bd.write.param);
    try std.testing.expectEqualStrings("default", bd.write.sub_action);

    // DELETE job
    const jdel = classifyRoute(.DELETE, "/api/v1/jobs/j1");
    try std.testing.expect(jdel == .write);
    try std.testing.expectEqual(rpc.MSG_BULK_ACTION, jdel.write.msg_type);
    try std.testing.expectEqualStrings("delete", jdel.write.sub_action);
}

test "classifyRoute — not found" {
    try std.testing.expect(classifyRoute(.GET, "/nonexistent") == .not_found);
}

test "classifyRoute — queue throttle delete" {
    const del = classifyRoute(.DELETE, "/api/v1/queues/tq/throttle");
    try std.testing.expect(del == .write);
    try std.testing.expectEqual(rpc.MSG_QUEUE_CONFIG, del.write.msg_type);
    try std.testing.expectEqualStrings("throttle_remove", del.write.sub_action);
}

test "decodeBulkAction — single job cancel" {
    var scratch = DecodeScratch{};
    const result = decodeBulkAction("", "job-1", "cancel", 1000, &scratch);
    const op = result.op_data.bulk_action;
    try std.testing.expectEqual(@as(usize, 1), op.job_ids.len);
    try std.testing.expectEqualStrings("job-1", op.job_ids[0]);
    try std.testing.expectEqual(ops_mod.BulkAction.cancel, op.action);
}

test "decodeBulkAction — bulk from body" {
    var scratch = DecodeScratch{};
    const body = "{\"action\":\"cancel\",\"job_ids\":[\"j1\",\"j2\"]}";
    const result = decodeBulkAction(body, "", "", 1000, &scratch);
    const op = result.op_data.bulk_action;
    try std.testing.expectEqual(@as(usize, 2), op.job_ids.len);
    try std.testing.expectEqual(ops_mod.BulkAction.cancel, op.action);
}

test "decodeQueueConfig — pause" {
    const result = decodeQueueConfig("", "myq", "pause");
    const op = result.op_data.queue_config;
    try std.testing.expectEqualStrings("myq", op.queue);
    try std.testing.expectEqual(ops_mod.QueueAction.pause, op.action);
}

test "decodeQueueConfig — concurrency" {
    const result = decodeQueueConfig("{\"max\":5}", "cq", "concurrency");
    const op = result.op_data.queue_config;
    try std.testing.expectEqual(ops_mod.QueueAction.concurrency, op.action);
    try std.testing.expectEqual(@as(u32, 5), op.max_concurrency);
}

test "decodeQueueConfig — throttle" {
    const result = decodeQueueConfig("{\"rate\":10,\"window_ms\":2000}", "tq", "throttle");
    const op = result.op_data.queue_config;
    try std.testing.expectEqual(ops_mod.QueueAction.throttle, op.action);
    try std.testing.expectEqual(@as(u32, 10), op.rate_limit);
    try std.testing.expectEqual(@as(u32, 2000), op.rate_window_ms);
}

test "decodeCronCreate" {
    var scratch = DecodeScratch{};
    scratch.id2_len = 4;
    @memcpy(scratch.id_buf2[0..4], "cid1");
    const body = "{\"name\":\"test\",\"queue\":\"cq\",\"schedule\":\"* * * * *\",\"max_retries\":3}";
    const result = decodeCronCreate(body, 1000, &scratch);
    const op = result.op_data.cron_create;
    try std.testing.expectEqualStrings("test", op.name);
    try std.testing.expectEqualStrings("cq", op.queue);
    try std.testing.expectEqualStrings("* * * * *", op.schedule);
    try std.testing.expectEqual(@as(u16, 3), op.max_retries);
}

test "extractJSONBool" {
    try std.testing.expectEqual(@as(?bool, true), extractJSONBool("{\"enabled\":true}", "enabled"));
    try std.testing.expectEqual(@as(?bool, false), extractJSONBool("{\"enabled\":false}", "enabled"));
    try std.testing.expect(extractJSONBool("{\"count\":1}", "count") == null);
}

test "extractJSONFloat" {
    const v = extractJSONFloat("{\"daily_usd\":100.5}", "daily_usd");
    try std.testing.expect(v != null);
    try std.testing.expectApproxEqRel(@as(f64, 100.5), v.?, 0.001);
}

test "extractJSONString" {
    try std.testing.expectEqualStrings("default", extractJSONString("{\"queue\":\"default\"}", "queue").?);
    try std.testing.expect(extractJSONString("{\"queue\":\"default\"}", "missing") == null);
}

test "extractJSONInt" {
    try std.testing.expectEqual(@as(i64, 42), extractJSONInt("{\"count\":42}", "count").?);
    try std.testing.expectEqual(@as(i64, -1), extractJSONInt("{\"val\":-1}", "val").?);
    try std.testing.expect(extractJSONInt("{\"count\":42}", "missing") == null);
}

test "extractJSONRaw — object" {
    const body = "{\"payload\":{\"foo\":\"bar\"}}";
    try std.testing.expectEqualStrings("{\"foo\":\"bar\"}", extractJSONRaw(body, "payload").?);
}

test "extractJSONRaw — array" {
    const body = "{\"tags\":[\"a\",\"b\"]}";
    try std.testing.expectEqualStrings("[\"a\",\"b\"]", extractJSONRaw(body, "tags").?);
}

test "extractJSONRaw — string" {
    const body = "{\"name\":\"hello\"}";
    try std.testing.expectEqualStrings("hello", extractJSONRaw(body, "name").?);
}

test "extractJSONStringArray" {
    const body = "{\"queues\":[\"q1\",\"q2\",\"q3\"]}";
    var out: [4][]const u8 = undefined;
    const count = extractJSONStringArray(body, "queues", &out);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("q1", out[0]);
    try std.testing.expectEqualStrings("q2", out[1]);
    try std.testing.expectEqualStrings("q3", out[2]);
}

test "generateId" {
    var buf: [64]u8 = undefined;
    const id = generateId(&buf, 1_000_000_000_000, 1);
    try std.testing.expect(std.mem.startsWith(u8, id, "job_"));
    try std.testing.expect(id.len > 4);
}

test "decodeEnqueue" {
    const body = "{\"queue\":\"default\",\"priority\":5,\"max_retries\":3,\"payload\":{\"foo\":\"bar\"}}";
    var scratch = DecodeScratch{};
    const result = decodeEnqueue(body, 1000, &scratch);
    const op = result.op_data.enqueue;
    try std.testing.expectEqual(@as(usize, 1), op.jobs.len);
    try std.testing.expectEqualStrings("default", op.jobs[0].queue);
    try std.testing.expectEqual(@as(u8, 5), op.jobs[0].priority);
    try std.testing.expectEqual(@as(u16, 3), op.jobs[0].max_retries);
    try std.testing.expectEqualStrings("{\"foo\":\"bar\"}", op.jobs[0].payload.?);
}

test "decodeFetch" {
    const body = "{\"queues\":[\"q1\",\"q2\"],\"worker_id\":\"w1\",\"count\":10}";
    var scratch = DecodeScratch{};
    const result = decodeFetch(body, 1000, &scratch);
    const op = result.op_data.fetch;
    try std.testing.expectEqual(@as(usize, 2), op.queues.len);
    try std.testing.expectEqualStrings("q1", op.queues[0]);
    try std.testing.expectEqualStrings("w1", op.worker_id);
    try std.testing.expectEqual(@as(u32, 10), op.count);
}

test "decodeAck" {
    const body = "{\"lease_token\":42}";
    var scratch = DecodeScratch{};
    const result = decodeAck(body, "job-1", 1000, &scratch);
    const op = result.op_data.ack;
    try std.testing.expectEqual(@as(usize, 1), op.acks.len);
    try std.testing.expectEqualStrings("job-1", op.acks[0].job_id);
    try std.testing.expectEqual(@as(u64, 42), op.acks[0].lease_token);
}
