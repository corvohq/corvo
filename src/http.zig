//! HTTP protocol module — parse, route, encode/decode for pipeline_v2.
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

    return .{
        .method = method,
        .path = path,
        .body = body,
        .total_len = total_len,
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

fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
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
        // Non-API routes: /healthz, /metrics, etc. — all reads.
        if (std.mem.eql(u8, clean, "/healthz")) return .read;
        if (std.mem.eql(u8, clean, "/metrics")) return .read;
        return .not_found;
    }

    const api = clean["/api/v1".len..];

    // --- Write routes (POST/PUT/DELETE that mutate state) ---

    if (method == .POST) {
        if (std.mem.eql(u8, api, "/enqueue"))
            return .{ .write = .{ .msg_type = rpc.MSG_ENQUEUE_BATCH, .param = "" } };

        if (std.mem.eql(u8, api, "/fetch") or std.mem.eql(u8, api, "/fetch/batch"))
            return .{ .write = .{ .msg_type = rpc.MSG_FETCH_BATCH, .param = "" } };

        if (std.mem.eql(u8, api, "/heartbeat"))
            return .{ .write = .{ .msg_type = rpc.MSG_HEARTBEAT, .param = "" } };

        // POST /api/v1/ack/{job_id}
        if (std.mem.startsWith(u8, api, "/ack/")) {
            const param = api["/ack/".len..];
            if (param.len > 0)
                return .{ .write = .{ .msg_type = rpc.MSG_ACK_BATCH, .param = param } };
        }

        // POST /api/v1/fail/{job_id}
        if (std.mem.startsWith(u8, api, "/fail/")) {
            const param = api["/fail/".len..];
            if (param.len > 0)
                return .{ .write = .{ .msg_type = rpc.MSG_FAIL_BATCH, .param = param } };
        }

        // POST /api/v1/jobs/search is a read (query via POST body)
        if (std.mem.eql(u8, api, "/jobs/search") or std.mem.eql(u8, api, "/jobs")) {
            return .read;
        }
    }

    // --- Read routes (GET, or POST search) ---

    if (method == .GET) {
        // All GET routes under /api/v1/ are reads.
        return .read;
    }

    return .not_found;
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
/// `id_buf` is filled with a generated job_id when needed.
pub fn decodeWrite(
    msg_type: u8,
    body: []const u8,
    param: []const u8,
    now_ns: u64,
    scratch: *DecodeScratch,
) DecodeResult {
    switch (msg_type) {
        rpc.MSG_ENQUEUE_BATCH => return decodeEnqueue(body, now_ns, scratch),
        rpc.MSG_FETCH_BATCH => return decodeFetch(body, now_ns, scratch),
        rpc.MSG_ACK_BATCH => return decodeAck(body, param, now_ns, scratch),
        rpc.MSG_FAIL_BATCH => return decodeFail(body, param, now_ns, scratch),
        rpc.MSG_HEARTBEAT => return decodeHeartbeat(body, now_ns, scratch),
        else => return .{ .op_data = .{ .enqueue = .{} }, .count = 0 },
    }
}

pub const DecodeScratch = struct {
    jobs: [1]ops_mod.EnqueueJob = undefined,
    acks: [1]ops_mod.AckJob = undefined,
    fails: [1]ops_mod.FailJob = undefined,
    hb_ids: [128][]const u8 = undefined,
    hb_ops: [128]ops_mod.HeartbeatJobOp = undefined,
    queue_slices: [16][]const u8 = undefined,
    id_buf: [64]u8 = undefined,
};

fn decodeEnqueue(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    const queue = extractJSONString(body, "queue") orelse
        return errResult(.enqueue);

    // Preserve pre-set job_id from pipeline (generated before decode).
    const preset_id = scratch.jobs[0].job_id;

    var job = ops_mod.EnqueueJob{
        .job_id = preset_id,
        .queue = queue,
        .created_at_ns = now_ns,
    };
    // Priority: default 128
    if (extractJSONInt(body, "priority")) |p|
        job.priority = @intCast(std.math.clamp(p, 0, 255));

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

    scratch.jobs[0] = job;

    return .{
        .op_data = .{ .enqueue = .{
            .jobs = scratch.jobs[0..1],
            .now_ns = now_ns,
        } },
        .count = 1,
    };
}

fn decodeFetch(body: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    // Extract queues array.
    const queue_count = extractJSONStringArray(body, "queues", &scratch.queue_slices);
    if (queue_count == 0) return errResult(.fetch);

    const worker_id = extractJSONString(body, "worker_id") orelse "";
    const count_val = extractJSONInt(body, "count");
    const count: u32 = if (count_val) |c| @intCast(std.math.clamp(c, 1, 512)) else 1;

    return .{
        .op_data = .{ .fetch = .{
            .queues = scratch.queue_slices[0..queue_count],
            .worker_id = worker_id,
            .count = count,
            .lease_duration_ms = 30_000,
            .now_ns = now_ns,
        } },
        .count = 1,
    };
}

fn decodeAck(body: []const u8, job_id: []const u8, now_ns: u64, scratch: *DecodeScratch) DecodeResult {
    var ack = ops_mod.AckJob{
        .job_id = job_id,
    };

    if (body.len > 0) {
        if (extractJSONRaw(body, "result")) |r| ack.result = r;
        if (extractJSONRaw(body, "checkpoint")) |cp| ack.checkpoint = cp;
        if (extractJSONString(body, "hold_reason")) |hr| ack.hold_reason = hr;
        if (extractJSONInt(body, "lease_token")) |lt| ack.lease_token = @intCast(lt);
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
pub fn encodeWriteResponse(
    send_buf: []u8,
    msg_type: u8,
    result: *const ops_mod.OpResult,
    job_id: []const u8,
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
            var body_buf: [512]u8 = undefined;
            var jw = json.JsonWriter.init(&body_buf);
            jw.beginObject();
            jw.beginObjectField("job");
            jw.fieldStr("id", job_id);
            jw.endObject();
            jw.endObject();
            return writeResponse(send_buf, 201, jw.getWritten());
        },
        rpc.MSG_FETCH_BATCH => {
            return encodeFetchResponse(send_buf, result);
        },
        rpc.MSG_ACK_BATCH,
        rpc.MSG_FAIL_BATCH,
        => return writeResponse(send_buf, 200, "{\"status\":\"ok\"}"),
        rpc.MSG_HEARTBEAT => return writeResponse(send_buf, 200, "{\"status\":\"ok\"}"),
        else => return writeResponse(send_buf, 200, "{\"status\":\"ok\"}"),
    }
}

fn encodeFetchResponse(send_buf: []u8, result: *const ops_mod.OpResult) u32 {
    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);

    const count = result.affected;
    if (count == 0) {
        return writeResponse(send_buf, 200, "{\"jobs\":[]}");
    }

    jw.beginObject();
    jw.beginArrayField("jobs");
    for (0..count) |i| {
        const f = &result.fetched[i];
        jw.beginObject();
        jw.fieldStr("id", f.id_buf[0..f.id_len]);
        jw.fieldStr("queue", f.queue_buf[0..f.queue_len]);
        jw.fieldInt("attempt", f.attempt);
        jw.fieldInt("max_retries", f.max_retries);
        jw.fieldInt("lease_token", f.lease_token);
        jw.endObject();
    }
    jw.endArray();
    jw.endObject();
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

// ============================================================================
// JSON Extraction Helpers — zero-alloc parsing from raw JSON bytes
// ============================================================================

/// Extract a JSON string value: "key":"value" → value.
pub fn extractJSONString(body: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    const val_start = start + search_key.len;
    if (val_start >= body.len) return null;
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
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":[", .{key}) catch return 0;
    const start = std.mem.indexOf(u8, body, search_key) orelse return 0;
    const arr_start = start + search_key.len;
    if (arr_start >= body.len) return 0;

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
}

test "classifyRoute — not found" {
    try std.testing.expect(classifyRoute(.GET, "/nonexistent") == .not_found);
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
