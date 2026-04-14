//! CLI client commands — thin HTTP wrappers around the Corvo API.
//!
//! Architecture:
//!   Client    — testable API: structured params → HttpResponse (no arg parsing, no process exit)
//!   cmd*      — CLI wrappers: parse args → Client method → printResponse

const std = @import("std");
const net = std.net;
const posix = std.posix;

// ============================================================================
// HTTP client — minimal, no allocations, stack-only
// ============================================================================

pub const HttpResponse = struct {
    status: u16,
    body: []const u8,
};

fn parseHostPort(server: []const u8) struct { host: []const u8, port: u16 } {
    // Strip "http://" prefix.
    var addr = server;
    if (std.mem.startsWith(u8, addr, "http://")) {
        addr = addr["http://".len..];
    } else if (std.mem.startsWith(u8, addr, "https://")) {
        addr = addr["https://".len..];
    }
    // Strip trailing slash.
    if (addr.len > 0 and addr[addr.len - 1] == '/') {
        addr = addr[0 .. addr.len - 1];
    }
    // Split host:port.
    if (std.mem.lastIndexOfScalar(u8, addr, ':')) |colon| {
        const port = std.fmt.parseInt(u16, addr[colon + 1 ..], 10) catch 8080;
        return .{ .host = addr[0..colon], .port = port };
    }
    return .{ .host = addr, .port = 8080 };
}

pub fn httpRequest(
    method: []const u8,
    server: []const u8,
    path: []const u8,
    body: ?[]const u8,
    api_key: []const u8,
    resp_buf: []u8,
) HttpResponse {
    const hp = parseHostPort(server);

    // Try numeric IP first, then DNS resolution.
    const stream = if (net.Address.parseIp(hp.host, hp.port)) |address|
        net.tcpConnectToAddress(address) catch {
            return .{ .status = 0, .body = "failed to connect to server" };
        }
    else |_|
        net.tcpConnectToHost(std.heap.page_allocator, hp.host, hp.port) catch {
            return .{ .status = 0, .body = "failed to connect to server" };
        };
    defer stream.close();

    // Build HTTP request.
    var req_buf: [8192]u8 = undefined;
    var pos: usize = 0;

    // Request line.
    pos += (std.fmt.bufPrint(req_buf[pos..], "{s} {s} HTTP/1.1\r\n", .{ method, path }) catch return .{ .status = 0, .body = "request too large" }).len;

    // Host header.
    pos += (std.fmt.bufPrint(req_buf[pos..], "Host: {s}\r\n", .{hp.host}) catch return .{ .status = 0, .body = "request too large" }).len;

    // Connection: close.
    pos += (std.fmt.bufPrint(req_buf[pos..], "Connection: close\r\n", .{}) catch return .{ .status = 0, .body = "request too large" }).len;

    // API key.
    if (api_key.len > 0) {
        pos += (std.fmt.bufPrint(req_buf[pos..], "Authorization: Bearer {s}\r\n", .{api_key}) catch return .{ .status = 0, .body = "request too large" }).len;
    }

    // Content headers + body.
    if (body) |b| {
        pos += (std.fmt.bufPrint(req_buf[pos..], "Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{b.len}) catch return .{ .status = 0, .body = "request too large" }).len;
        if (pos + b.len > req_buf.len) return .{ .status = 0, .body = "request body too large" };
        @memcpy(req_buf[pos .. pos + b.len], b);
        pos += b.len;
    } else {
        pos += (std.fmt.bufPrint(req_buf[pos..], "\r\n", .{}) catch return .{ .status = 0, .body = "request too large" }).len;
    }

    // Send.
    _ = stream.write(req_buf[0..pos]) catch {
        return .{ .status = 0, .body = "failed to send request" };
    };

    // Read response — stop when Content-Length body is complete (server may keep-alive).
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = stream.read(resp_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
        // Check if we have full headers + body.
        const buf = resp_buf[0..total];
        if (std.mem.indexOf(u8, buf, "\r\n\r\n")) |hdr_end| {
            const body_start = hdr_end + 4;
            const headers = buf[0..hdr_end];
            if (findContentLength(headers)) |cl| {
                if (total >= body_start + cl) break;
            } else if (std.mem.indexOf(u8, headers, "Transfer-Encoding: chunked") != null) {
                if (std.mem.indexOf(u8, buf[body_start..], "0\r\n\r\n") != null) break;
            } else {
                break; // No Content-Length, no chunked — stop after headers.
            }
        }
    }

    if (total == 0) return .{ .status = 0, .body = "empty response" };

    // Parse HTTP status.
    const resp_data = resp_buf[0..total];
    // Find "HTTP/1.1 NNN"
    if (resp_data.len < 12) return .{ .status = 0, .body = "invalid response" };
    const status = std.fmt.parseInt(u16, resp_data[9..12], 10) catch 0;

    // Find body (after \r\n\r\n).
    if (std.mem.indexOf(u8, resp_data, "\r\n\r\n")) |hdr_end| {
        const body_start = hdr_end + 4;
        // Handle chunked transfer encoding.
        if (std.mem.indexOf(u8, resp_data[0..hdr_end], "Transfer-Encoding: chunked") != null) {
            // Parse first chunk size and return its data.
            const chunk_data = resp_data[body_start..];
            if (std.mem.indexOf(u8, chunk_data, "\r\n")) |chunk_hdr_end| {
                const chunk_size = std.fmt.parseInt(usize, chunk_data[0..chunk_hdr_end], 16) catch 0;
                if (chunk_size > 0) {
                    const data_start = chunk_hdr_end + 2;
                    const data_end = @min(data_start + chunk_size, chunk_data.len);
                    return .{ .status = status, .body = chunk_data[data_start..data_end] };
                }
            }
            return .{ .status = status, .body = "" };
        }
        return .{ .status = status, .body = resp_data[body_start..] };
    }

    return .{ .status = status, .body = "" };
}

fn findContentLength(headers: []const u8) ?usize {
    const needle = "Content-Length: ";
    const pos = std.mem.indexOf(u8, headers, needle) orelse return null;
    const start = pos + needle.len;
    const end = std.mem.indexOfScalarPos(u8, headers, start, '\r') orelse headers.len;
    return std.fmt.parseInt(usize, headers[start..end], 10) catch null;
}

// ============================================================================
// Client — testable API layer (no arg parsing, no process exit)
//
// Usage:
//   const client = Client{ .server = "http://localhost:9878" };
//   var resp_buf: [65536]u8 = undefined;
//   const resp = client.enqueue(.{ .queue = "emails", .payload = "{}" }, &resp_buf);
// ============================================================================

pub const Client = struct {
    server: []const u8 = "http://localhost:9878",
    api_key: []const u8 = "",

    // -- Enqueue --------------------------------------------------------------

    pub const EnqueueParams = struct {
        queue: []const u8,
        payload: []const u8 = "",
        priority: []const u8 = "",
        max_retries: []const u8 = "",
        unique_key: []const u8 = "",
        scheduled_at: []const u8 = "",
        tags: []const u8 = "",
        group: []const u8 = "",
    };

    pub fn enqueue(self: Client, params: EnqueueParams, resp_buf: []u8) HttpResponse {
        var body_buf: [65536]u8 = undefined;
        var body_pos: usize = 0;

        body_pos += (std.fmt.bufPrint(body_buf[body_pos..], "{{\"queue\":\"{s}\"", .{params.queue}) catch return errResp("body too large")).len;

        if (params.payload.len > 0) {
            if (params.payload[0] == '{' or params.payload[0] == '[' or params.payload[0] == '"') {
                body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"payload\":{s}", .{params.payload}) catch return errResp("body too large")).len;
            } else {
                body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"payload\":\"{s}\"", .{params.payload}) catch return errResp("body too large")).len;
            }
        }

        if (params.priority.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"priority\":{s}", .{params.priority}) catch return errResp("body too large")).len;
        if (params.max_retries.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"max_retries\":{s}", .{params.max_retries}) catch return errResp("body too large")).len;
        if (params.unique_key.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"unique_key\":\"{s}\"", .{params.unique_key}) catch return errResp("body too large")).len;
        if (params.scheduled_at.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"scheduled_at\":\"{s}\"", .{params.scheduled_at}) catch return errResp("body too large")).len;
        if (params.tags.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"tags\":{s}", .{params.tags}) catch return errResp("body too large")).len;
        if (params.group.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"group\":\"{s}\"", .{params.group}) catch return errResp("body too large")).len;

        body_buf[body_pos] = '}';
        body_pos += 1;

        return httpRequest("POST", self.server, "/api/v1/enqueue", body_buf[0..body_pos], self.api_key, resp_buf);
    }

    // -- Job operations -------------------------------------------------------

    pub fn inspectJob(self: Client, job_id: []const u8, resp_buf: []u8) HttpResponse {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/jobs/{s}", .{job_id}) catch return errResp("job-id too long");
        return httpRequest("GET", self.server, path, null, self.api_key, resp_buf);
    }

    pub fn jobAction(self: Client, job_id: []const u8, action: []const u8, resp_buf: []u8) HttpResponse {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/jobs/{s}/{s}", .{ job_id, action }) catch return errResp("job-id too long");
        return httpRequest("POST", self.server, path, null, self.api_key, resp_buf);
    }

    pub fn deleteJob(self: Client, job_id: []const u8, resp_buf: []u8) HttpResponse {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/jobs/{s}", .{job_id}) catch return errResp("job-id too long");
        return httpRequest("DELETE", self.server, path, null, self.api_key, resp_buf);
    }

    pub fn moveJob(self: Client, job_id: []const u8, target_queue: []const u8, resp_buf: []u8) HttpResponse {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/jobs/{s}/move", .{job_id}) catch return errResp("job-id too long");
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{{\"queue\":\"{s}\"}}", .{target_queue}) catch return errResp("queue name too long");
        return httpRequest("POST", self.server, path, body, self.api_key, resp_buf);
    }

    // -- Bulk -----------------------------------------------------------------

    pub const BulkParams = struct {
        action: []const u8,
        job_ids: []const u8, // comma-separated
        move_to_queue: []const u8 = "",
    };

    pub fn bulk(self: Client, params: BulkParams, resp_buf: []u8) HttpResponse {
        var body_buf: [65536]u8 = undefined;
        var body_pos: usize = 0;

        body_pos += (std.fmt.bufPrint(body_buf[body_pos..], "{{\"action\":\"{s}\",\"job_ids\":[", .{params.action}) catch return errResp("body too large")).len;

        // Parse comma-separated job_ids, emit as JSON array.
        var first = true;
        var it = std.mem.splitScalar(u8, params.job_ids, ',');
        while (it.next()) |id| {
            const trimmed = std.mem.trim(u8, id, " ");
            if (trimmed.len == 0) continue;
            if (!first) {
                body_buf[body_pos] = ',';
                body_pos += 1;
            }
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], "\"{s}\"", .{trimmed}) catch return errResp("body too large")).len;
            first = false;
        }
        body_buf[body_pos] = ']';
        body_pos += 1;

        if (params.move_to_queue.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"move_to_queue\":\"{s}\"", .{params.move_to_queue}) catch return errResp("body too large")).len;

        body_buf[body_pos] = '}';
        body_pos += 1;

        return httpRequest("POST", self.server, "/api/v1/jobs/bulk", body_buf[0..body_pos], self.api_key, resp_buf);
    }

    // -- Queue operations -----------------------------------------------------

    pub fn get(self: Client, path: []const u8, resp_buf: []u8) HttpResponse {
        return httpRequest("GET", self.server, path, null, self.api_key, resp_buf);
    }

    pub fn queueAction(self: Client, queue_name: []const u8, action: []const u8, resp_buf: []u8) HttpResponse {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/queues/{s}/{s}", .{ queue_name, action }) catch return errResp("queue name too long");
        return httpRequest("POST", self.server, path, null, self.api_key, resp_buf);
    }

    pub fn deleteQueue(self: Client, queue_name: []const u8, resp_buf: []u8) HttpResponse {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/queues/{s}", .{queue_name}) catch return errResp("queue name too long");
        return httpRequest("DELETE", self.server, path, null, self.api_key, resp_buf);
    }

    // -- Search ---------------------------------------------------------------

    pub const SearchParams = struct {
        query: []const u8 = "",
        queue: []const u8 = "",
        state: []const u8 = "",
    };

    pub fn search(self: Client, params: SearchParams, resp_buf: []u8) HttpResponse {
        // POST with filters if queue/state specified.
        if (params.queue.len > 0 or params.state.len > 0) {
            var body_buf: [4096]u8 = undefined;
            var body_pos: usize = 0;
            body_buf[0] = '{';
            body_pos = 1;

            var has_field = false;
            if (params.queue.len > 0) {
                body_pos += (std.fmt.bufPrint(body_buf[body_pos..], "\"queue\":\"{s}\"", .{params.queue}) catch return errResp("body too large")).len;
                has_field = true;
            }
            if (params.state.len > 0) {
                if (has_field) {
                    body_buf[body_pos] = ',';
                    body_pos += 1;
                }
                body_pos += (std.fmt.bufPrint(body_buf[body_pos..], "\"state\":[\"{s}\"]", .{params.state}) catch return errResp("body too large")).len;
            }
            body_buf[body_pos] = '}';
            body_pos += 1;

            return httpRequest("POST", self.server, "/api/v1/jobs/search", body_buf[0..body_pos], self.api_key, resp_buf);
        }

        // Otherwise GET, optionally with query param.
        if (params.query.len > 0) {
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "/api/v1/jobs/search?q={s}", .{params.query}) catch return errResp("query too long");
            return httpRequest("GET", self.server, path, null, self.api_key, resp_buf);
        }
        return httpRequest("GET", self.server, "/api/v1/jobs/search", null, self.api_key, resp_buf);
    }

    // -- Cron -----------------------------------------------------------------

    pub const CronCreateParams = struct {
        name: []const u8,
        queue: []const u8,
        schedule: []const u8,
        payload: []const u8 = "",
        timezone: []const u8 = "",
    };

    pub fn cronCreate(self: Client, params: CronCreateParams, resp_buf: []u8) HttpResponse {
        var body_buf: [4096]u8 = undefined;
        var body_pos: usize = 0;

        body_pos += (std.fmt.bufPrint(body_buf[body_pos..], "{{\"name\":\"{s}\",\"queue\":\"{s}\",\"schedule\":\"{s}\"", .{ params.name, params.queue, params.schedule }) catch return errResp("body too large")).len;

        if (params.payload.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"payload\":\"{s}\"", .{params.payload}) catch return errResp("body too large")).len;
        if (params.timezone.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"timezone\":\"{s}\"", .{params.timezone}) catch return errResp("body too large")).len;

        body_buf[body_pos] = '}';
        body_pos += 1;

        return httpRequest("POST", self.server, "/api/v1/cron-jobs", body_buf[0..body_pos], self.api_key, resp_buf);
    }

    pub fn cronDelete(self: Client, cron_id: []const u8, resp_buf: []u8) HttpResponse {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/cron-jobs/{s}", .{cron_id}) catch return errResp("cron-id too long");
        return httpRequest("DELETE", self.server, path, null, self.api_key, resp_buf);
    }

    pub fn cronAction(self: Client, cron_id: []const u8, action: []const u8, resp_buf: []u8) HttpResponse {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v1/cron-jobs/{s}/{s}", .{ cron_id, action }) catch return errResp("cron-id too long");
        return httpRequest("POST", self.server, path, null, self.api_key, resp_buf);
    }
};

fn errResp(msg: []const u8) HttpResponse {
    return .{ .status = 0, .body = msg };
}

// ============================================================================
// CLI layer — arg parsing, dispatch, response printing
// ============================================================================

const CliOpts = struct {
    server: []const u8 = "http://localhost:9878",
    api_key: []const u8 = "",
    json: bool = false,
};

fn printResponse(resp: HttpResponse) void {
    if (resp.status == 0) {
        std.debug.print("error: {s}\n", .{resp.body});
        std.process.exit(1);
    }
    if (resp.body.len > 0) {
        _ = posix.write(posix.STDOUT_FILENO, resp.body) catch {};
        _ = posix.write(posix.STDOUT_FILENO, "\n") catch {};
    }
    if (resp.status >= 400) {
        std.process.exit(1);
    }
}

// ============================================================================
// Subcommand dispatch
// ============================================================================

pub fn dispatch(first_arg: []const u8, args: *std.process.ArgIterator) void {
    if (eql(first_arg, "enqueue")) return cmdEnqueue(args);
    if (eql(first_arg, "inspect")) return cmdInspect(args);
    if (eql(first_arg, "requeue")) return cmdJobAction(args, "requeue");
    if (eql(first_arg, "cancel")) return cmdJobAction(args, "cancel");
    if (eql(first_arg, "hold")) return cmdJobAction(args, "hold");
    if (eql(first_arg, "approve")) return cmdJobAction(args, "approve");
    if (eql(first_arg, "reject")) return cmdJobAction(args, "reject");
    if (eql(first_arg, "delete")) return cmdDelete(args);
    if (eql(first_arg, "move")) return cmdMove(args);
    if (eql(first_arg, "bulk")) return cmdBulk(args);

    // Queue management.
    if (eql(first_arg, "queues")) return cmdSimpleGet(args, "/api/v1/queues");
    if (eql(first_arg, "pause")) return cmdQueueAction(args, "pause");
    if (eql(first_arg, "resume")) return cmdQueueAction(args, "resume");
    if (eql(first_arg, "clear")) return cmdQueueAction(args, "clear");
    if (eql(first_arg, "drain")) return cmdQueueAction(args, "drain");
    if (eql(first_arg, "destroy")) return cmdQueueDelete(args);

    // Search & observability.
    if (eql(first_arg, "search")) return cmdSearch(args);
    if (eql(first_arg, "workers")) return cmdSimpleGet(args, "/api/v1/workers");
    if (eql(first_arg, "status")) return cmdSimpleGet(args, "/api/v1/info");

    // Cron jobs.
    if (eql(first_arg, "cron-list")) return cmdSimpleGet(args, "/api/v1/cron-jobs");
    if (eql(first_arg, "cron-create")) return cmdCronCreate(args);
    if (eql(first_arg, "cron-delete")) return cmdCronDelete(args);
    if (eql(first_arg, "cron-pause")) return cmdCronAction(args, "pause");
    if (eql(first_arg, "cron-resume")) return cmdCronAction(args, "resume");
    if (eql(first_arg, "cron-trigger")) return cmdCronAction(args, "trigger");

    // Seed data for manual testing.
    if (eql(first_arg, "seed")) return cmdSeed(args);

    // Unknown command — print help.
    printHelp();
    std.process.exit(1);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn printHelp() void {
    std.debug.print(
        \\Corvo — distributed job queue
        \\
        \\Usage: corvo <command> [options]
        \\
        \\Server:
        \\  server              Start the Corvo server
        \\
        \\Job Operations:
        \\  enqueue             Enqueue a job
        \\  inspect             Show full job detail                        ~ mirror
        \\  requeue             Requeue a failed/dead job
        \\  cancel              Cancel a pending/active job
        \\  delete              Delete a job
        \\  hold                Move a job to held state
        \\  approve             Approve a held job back to pending
        \\  reject              Reject a held job to dead state
        \\  move                Move a job to another queue
        \\  bulk                Apply bulk action to explicit job IDs
        \\
        \\Queue Management:
        \\  queues              List all queues with stats                  ~ mirror
        \\  pause               Pause a queue
        \\  resume              Resume a paused queue
        \\  clear               Clear pending/scheduled jobs in a queue
        \\  destroy             Delete a queue and all its jobs
        \\  drain               Drain a queue (pause + wait for active)
        \\
        \\Search & Observability:
        \\  search              Search jobs with filters                    ~ mirror
        \\  workers             List connected workers                      ~ mirror
        \\  status              Show server status and queue summary
        \\
        \\Cron Jobs:
        \\  cron-list           List cron jobs                              ~ mirror
        \\  cron-create         Create a cron job
        \\  cron-delete         Delete a cron job
        \\  cron-pause          Pause a cron job
        \\  cron-resume         Resume a cron job
        \\  cron-trigger        Trigger a cron job immediately
        \\
        \\Testing:
        \\  seed                Populate server with sample data for manual testing
        \\
        \\Global Options:
        \\  --server <url>      Server URL (default: http://localhost:9878)
        \\  --api-key <key>     API key for authentication (env: CORVO_API_KEY)
        \\  --help              Show this help
        \\
        \\Commands marked ~ mirror read from the SQLite mirror (eventually consistent).
        \\
    , .{});
}

// ============================================================================
// Shared option parsing
// ============================================================================

fn parseOpts(args: *std.process.ArgIterator, positional: [][]const u8, max_positional: usize) struct { opts: CliOpts, positional_count: usize } {
    var opts = CliOpts{};
    var pos_count: usize = 0;

    // Check env var for API key.
    if (std.posix.getenv("CORVO_API_KEY")) |key| {
        opts.api_key = key;
    }

    while (args.next()) |arg| {
        if (eql(arg, "--server")) {
            opts.server = args.next() orelse {
                fatal("--server requires a URL argument");
                unreachable;
            };
        } else if (eql(arg, "--api-key")) {
            opts.api_key = args.next() orelse {
                fatal("--api-key requires an argument");
                unreachable;
            };
        } else if (eql(arg, "--json")) {
            opts.json = true;
        } else if (eql(arg, "--help") or eql(arg, "-h")) {
            // Subcommand-specific help would go here.
            printHelp();
            std.process.exit(0);
        } else if (arg.len > 0 and arg[0] == '-') {
            fatal2("unknown option: {s}", arg);
            unreachable;
        } else {
            // Positional argument.
            if (pos_count < max_positional) {
                positional[pos_count] = arg;
                pos_count += 1;
            }
        }
    }

    return .{ .opts = opts, .positional_count = pos_count };
}

fn fatal(msg: []const u8) void {
    std.debug.print("error: {s}\n", .{msg});
    std.process.exit(1);
}

fn fatal2(comptime fmt: []const u8, arg: []const u8) void {
    std.debug.print("error: " ++ fmt ++ "\n", .{arg});
    std.process.exit(1);
}

// ============================================================================
// enqueue <queue> <payload> [options]
// ============================================================================

fn cmdEnqueue(args: *std.process.ArgIterator) void {
    var opts = CliOpts{};
    var queue: []const u8 = "";
    var payload: []const u8 = "";
    var priority: []const u8 = "";
    var max_retries: []const u8 = "";
    var unique_key: []const u8 = "";
    var scheduled_at: []const u8 = "";
    var tags: []const u8 = "";
    var group: []const u8 = "";
    var pos_count: usize = 0;

    if (std.posix.getenv("CORVO_API_KEY")) |key| opts.api_key = key;

    while (args.next()) |arg| {
        if (eql(arg, "--server")) {
            opts.server = args.next() orelse { fatal("--server requires an argument"); unreachable; };
        } else if (eql(arg, "--api-key")) {
            opts.api_key = args.next() orelse { fatal("--api-key requires an argument"); unreachable; };
        } else if (eql(arg, "--priority")) {
            priority = args.next() orelse { fatal("--priority requires an argument"); unreachable; };
        } else if (eql(arg, "--max-retries")) {
            max_retries = args.next() orelse { fatal("--max-retries requires an argument"); unreachable; };
        } else if (eql(arg, "--unique-key")) {
            unique_key = args.next() orelse { fatal("--unique-key requires an argument"); unreachable; };
        } else if (eql(arg, "--scheduled-at")) {
            scheduled_at = args.next() orelse { fatal("--scheduled-at requires an argument"); unreachable; };
        } else if (eql(arg, "--tags")) {
            tags = args.next() orelse { fatal("--tags requires an argument"); unreachable; };
        } else if (eql(arg, "--group")) {
            group = args.next() orelse { fatal("--group requires an argument"); unreachable; };
        } else if (eql(arg, "--help") or eql(arg, "-h")) {
            std.debug.print(
                \\Usage: corvo enqueue <queue> <payload> [options]
                \\
                \\Enqueue a job to a queue.
                \\
                \\Arguments:
                \\  <queue>                Queue name
                \\  <payload>              Job payload (JSON string)
                \\
                \\Options:
                \\  --priority <n>         Job priority (0-255, default: 128)
                \\  --max-retries <n>      Maximum retry attempts (default: 3)
                \\  --unique-key <key>     Unique deduplication key
                \\  --scheduled-at <time>  Schedule for later (RFC3339)
                \\  --tags <json>          Tags as JSON object
                \\  --group <name>         Concurrency group name
                \\  --server <url>         Server URL (default: http://localhost:9878)
                \\  --api-key <key>        API key (env: CORVO_API_KEY)
                \\
            , .{});
            std.process.exit(0);
        } else if (arg.len > 0 and arg[0] == '-') {
            fatal2("unknown option: {s}", arg);
            unreachable;
        } else {
            if (pos_count == 0) queue = arg
            else if (pos_count == 1) payload = arg;
            pos_count += 1;
        }
    }

    if (queue.len == 0) { fatal("usage: corvo enqueue <queue> <payload>"); unreachable; }

    const client = Client{ .server = opts.server, .api_key = opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.enqueue(.{
        .queue = queue,
        .payload = payload,
        .priority = priority,
        .max_retries = max_retries,
        .unique_key = unique_key,
        .scheduled_at = scheduled_at,
        .tags = tags,
        .group = group,
    }, &resp_buf));
}

// ============================================================================
// inspect <job-id>
// ============================================================================

fn cmdInspect(args: *std.process.ArgIterator) void {
    var positional: [1][]const u8 = undefined;
    const result = parseOpts(args, &positional, 1);
    if (result.positional_count == 0) { fatal("usage: corvo inspect <job-id>"); unreachable; }

    const client = Client{ .server = result.opts.server, .api_key = result.opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.inspectJob(positional[0], &resp_buf));
}

// ============================================================================
// requeue/cancel/hold/approve/reject <job-id>
// ============================================================================

fn cmdJobAction(args: *std.process.ArgIterator, action: []const u8) void {
    var positional: [1][]const u8 = undefined;
    const result = parseOpts(args, &positional, 1);
    if (result.positional_count == 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "usage: corvo {s} <job-id>", .{action}) catch "usage: corvo <action> <job-id>";
        fatal(msg);
        unreachable;
    }

    const client = Client{ .server = result.opts.server, .api_key = result.opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.jobAction(positional[0], action, &resp_buf));
}

// ============================================================================
// delete <job-id>
// ============================================================================

fn cmdDelete(args: *std.process.ArgIterator) void {
    var positional: [1][]const u8 = undefined;
    const result = parseOpts(args, &positional, 1);
    if (result.positional_count == 0) { fatal("usage: corvo delete <job-id>"); unreachable; }

    const client = Client{ .server = result.opts.server, .api_key = result.opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.deleteJob(positional[0], &resp_buf));
}

// ============================================================================
// move <job-id> <queue>
// ============================================================================

fn cmdMove(args: *std.process.ArgIterator) void {
    var positional: [2][]const u8 = undefined;
    const result = parseOpts(args, &positional, 2);
    if (result.positional_count < 2) { fatal("usage: corvo move <job-id> <queue>"); unreachable; }

    const client = Client{ .server = result.opts.server, .api_key = result.opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.moveJob(positional[0], positional[1], &resp_buf));
}

// ============================================================================
// bulk <action> [options]
// ============================================================================

fn cmdBulk(args: *std.process.ArgIterator) void {
    var opts = CliOpts{};
    var action: []const u8 = "";
    var job_ids: []const u8 = "";
    var move_to_queue: []const u8 = "";
    var pos_count: usize = 0;

    if (std.posix.getenv("CORVO_API_KEY")) |key| opts.api_key = key;

    while (args.next()) |arg| {
        if (eql(arg, "--server")) {
            opts.server = args.next() orelse { fatal("--server requires an argument"); unreachable; };
        } else if (eql(arg, "--api-key")) {
            opts.api_key = args.next() orelse { fatal("--api-key requires an argument"); unreachable; };
        } else if (eql(arg, "--job-ids")) {
            job_ids = args.next() orelse { fatal("--job-ids requires an argument"); unreachable; };
        } else if (eql(arg, "--move-to-queue")) {
            move_to_queue = args.next() orelse { fatal("--move-to-queue requires an argument"); unreachable; };
        } else if (eql(arg, "--help") or eql(arg, "-h")) {
            std.debug.print(
                \\Usage: corvo bulk <action> --job-ids <id1,id2,...> [options]
                \\
                \\Apply a bulk action to an explicit list of jobs.
                \\
                \\Actions: requeue, cancel, delete, move, hold, approve, reject, promote
                \\
                \\Options:
                \\  --job-ids <ids>          Comma-separated job IDs (required)
                \\  --move-to-queue <name>   Target queue (for move action)
                \\  --server <url>           Server URL (default: http://localhost:9878)
                \\  --api-key <key>          API key (env: CORVO_API_KEY)
                \\
            , .{});
            std.process.exit(0);
        } else if (arg.len > 0 and arg[0] == '-') {
            fatal2("unknown option: {s}", arg);
            unreachable;
        } else {
            if (pos_count == 0) action = arg;
            pos_count += 1;
        }
    }

    if (action.len == 0) { fatal("usage: corvo bulk <action> --job-ids <ids>"); unreachable; }
    if (job_ids.len == 0) { fatal("--job-ids is required"); unreachable; }

    const client = Client{ .server = opts.server, .api_key = opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.bulk(.{
        .action = action,
        .job_ids = job_ids,
        .move_to_queue = move_to_queue,
    }, &resp_buf));
}

// ============================================================================
// Simple GET commands (queues, workers, status, cron-list)
// ============================================================================

fn cmdSimpleGet(args: *std.process.ArgIterator, path: []const u8) void {
    var positional: [0][]const u8 = undefined;
    const result = parseOpts(args, &positional, 0);
    const client = Client{ .server = result.opts.server, .api_key = result.opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.get(path, &resp_buf));
}

// ============================================================================
// Queue management: pause/resume/clear/drain <queue>
// ============================================================================

fn cmdQueueAction(args: *std.process.ArgIterator, action: []const u8) void {
    var positional: [1][]const u8 = undefined;
    const result = parseOpts(args, &positional, 1);
    if (result.positional_count == 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "usage: corvo {s} <queue>", .{action}) catch "usage: corvo <action> <queue>";
        fatal(msg);
        unreachable;
    }

    const client = Client{ .server = result.opts.server, .api_key = result.opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.queueAction(positional[0], action, &resp_buf));
}

// ============================================================================
// destroy <queue>
// ============================================================================

fn cmdQueueDelete(args: *std.process.ArgIterator) void {
    var positional: [1][]const u8 = undefined;
    const result = parseOpts(args, &positional, 1);
    if (result.positional_count == 0) { fatal("usage: corvo destroy <queue>"); unreachable; }

    const client = Client{ .server = result.opts.server, .api_key = result.opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.deleteQueue(positional[0], &resp_buf));
}

// ============================================================================
// search [options]
// ============================================================================

fn cmdSearch(args: *std.process.ArgIterator) void {
    var opts = CliOpts{};
    var query: []const u8 = "";
    var queue: []const u8 = "";
    var state: []const u8 = "";
    var pos_count: usize = 0;

    if (std.posix.getenv("CORVO_API_KEY")) |key| opts.api_key = key;

    while (args.next()) |arg| {
        if (eql(arg, "--server")) {
            opts.server = args.next() orelse { fatal("--server requires an argument"); unreachable; };
        } else if (eql(arg, "--api-key")) {
            opts.api_key = args.next() orelse { fatal("--api-key requires an argument"); unreachable; };
        } else if (eql(arg, "--queue")) {
            queue = args.next() orelse { fatal("--queue requires an argument"); unreachable; };
        } else if (eql(arg, "--state")) {
            state = args.next() orelse { fatal("--state requires an argument"); unreachable; };
        } else if (eql(arg, "--help") or eql(arg, "-h")) {
            std.debug.print(
                \\Usage: corvo search [query] [options]
                \\
                \\Search jobs with filters. Reads from SQLite mirror (eventually consistent).
                \\
                \\Arguments:
                \\  [query]              Search query string (optional)
                \\
                \\Options:
                \\  --queue <name>       Filter by queue
                \\  --state <state>      Filter by state (pending, active, dead, etc.)
                \\  --server <url>       Server URL (default: http://localhost:9878)
                \\  --api-key <key>      API key (env: CORVO_API_KEY)
                \\
            , .{});
            std.process.exit(0);
        } else if (arg.len > 0 and arg[0] == '-') {
            fatal2("unknown option: {s}", arg);
            unreachable;
        } else {
            if (pos_count == 0) query = arg;
            pos_count += 1;
        }
    }

    const client = Client{ .server = opts.server, .api_key = opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.search(.{
        .query = query,
        .queue = queue,
        .state = state,
    }, &resp_buf));
}

// ============================================================================
// Cron: cron-create
// ============================================================================

fn cmdCronCreate(args: *std.process.ArgIterator) void {
    var opts = CliOpts{};
    var name: []const u8 = "";
    var queue: []const u8 = "";
    var schedule: []const u8 = "";
    var payload: []const u8 = "";
    var timezone: []const u8 = "";

    if (std.posix.getenv("CORVO_API_KEY")) |key| opts.api_key = key;

    while (args.next()) |arg| {
        if (eql(arg, "--server")) {
            opts.server = args.next() orelse { fatal("--server requires an argument"); unreachable; };
        } else if (eql(arg, "--api-key")) {
            opts.api_key = args.next() orelse { fatal("--api-key requires an argument"); unreachable; };
        } else if (eql(arg, "--name")) {
            name = args.next() orelse { fatal("--name requires an argument"); unreachable; };
        } else if (eql(arg, "--queue")) {
            queue = args.next() orelse { fatal("--queue requires an argument"); unreachable; };
        } else if (eql(arg, "--schedule")) {
            schedule = args.next() orelse { fatal("--schedule requires an argument"); unreachable; };
        } else if (eql(arg, "--payload")) {
            payload = args.next() orelse { fatal("--payload requires an argument"); unreachable; };
        } else if (eql(arg, "--timezone")) {
            timezone = args.next() orelse { fatal("--timezone requires an argument"); unreachable; };
        } else if (eql(arg, "--help") or eql(arg, "-h")) {
            std.debug.print(
                \\Usage: corvo cron-create [options]
                \\
                \\Create a cron job.
                \\
                \\Options:
                \\  --name <name>          Cron job name (required)
                \\  --queue <queue>         Target queue (required)
                \\  --schedule <cron>       Cron schedule expression (required)
                \\  --payload <json>        Job payload
                \\  --timezone <tz>         Timezone (e.g. America/New_York)
                \\  --server <url>          Server URL (default: http://localhost:9878)
                \\  --api-key <key>         API key (env: CORVO_API_KEY)
                \\
            , .{});
            std.process.exit(0);
        } else if (arg.len > 0 and arg[0] == '-') {
            fatal2("unknown option: {s}", arg);
            unreachable;
        }
    }

    if (name.len == 0) { fatal("--name is required"); unreachable; }
    if (queue.len == 0) { fatal("--queue is required"); unreachable; }
    if (schedule.len == 0) { fatal("--schedule is required"); unreachable; }

    const client = Client{ .server = opts.server, .api_key = opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.cronCreate(.{
        .name = name,
        .queue = queue,
        .schedule = schedule,
        .payload = payload,
        .timezone = timezone,
    }, &resp_buf));
}

// ============================================================================
// Cron: cron-delete <cron-id>
// ============================================================================

fn cmdCronDelete(args: *std.process.ArgIterator) void {
    var positional: [1][]const u8 = undefined;
    const result = parseOpts(args, &positional, 1);
    if (result.positional_count == 0) { fatal("usage: corvo cron-delete <cron-id>"); unreachable; }

    const client = Client{ .server = result.opts.server, .api_key = result.opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.cronDelete(positional[0], &resp_buf));
}

// ============================================================================
// Cron: cron-pause/cron-resume/cron-trigger <cron-id>
// ============================================================================

fn cmdCronAction(args: *std.process.ArgIterator, action: []const u8) void {
    var positional: [1][]const u8 = undefined;
    const result = parseOpts(args, &positional, 1);
    if (result.positional_count == 0) {
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "usage: corvo cron-{s} <cron-id>", .{action}) catch "usage: corvo cron-<action> <cron-id>";
        fatal(msg);
        unreachable;
    }

    const client = Client{ .server = result.opts.server, .api_key = result.opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.cronAction(positional[0], action, &resp_buf));
}

// ============================================================================
// seed — populate server with sample data for manual testing
// ============================================================================

fn cmdSeed(args: *std.process.ArgIterator) void {
    var positional: [0][]const u8 = undefined;
    const parsed = parseOpts(args, &positional, 0);
    const client = Client{ .server = parsed.opts.server, .api_key = parsed.opts.api_key };
    var resp_buf: [65536]u8 = undefined;

    // Verify connectivity.
    const info = client.get("/api/v1/info", &resp_buf);
    if (info.status == 0) {
        fatal(info.body);
        unreachable;
    }

    std.debug.print("Seeding {s} ...\n\n", .{parsed.opts.server});

    // Collect job IDs for post-enqueue actions.
    // Store IDs inline in a flat buffer to avoid allocation.
    var id_store: [8192]u8 = undefined;
    var id_store_pos: usize = 0;
    var cancel_ids: [16][]const u8 = undefined;
    var cancel_count: usize = 0;
    var hold_ids: [16][]const u8 = undefined;
    var hold_count: usize = 0;
    var reject_ids: [16][]const u8 = undefined;
    var reject_count: usize = 0;

    // --- Enqueue jobs ---
    var total_ok: usize = 0;
    var total_fail: usize = 0;

    inline for (seed_queues) |sq| {
        var ok: usize = 0;
        var fail: usize = 0;
        var queue_cancel: usize = 0;
        var queue_hold: usize = 0;
        var queue_reject: usize = 0;
        for (sq.jobs) |job| {
            const resp = client.enqueue(job, &resp_buf);
            if (resp.status >= 200 and resp.status < 300) {
                ok += 1;
                if (extractJobId(resp.body)) |jid| {
                    if (queue_cancel < sq.cancel_first) {
                        if (storeId(&id_store, &id_store_pos, &cancel_ids, &cancel_count, jid))
                            queue_cancel += 1;
                    } else if (queue_reject < sq.reject_first) {
                        // reject requires hold first — store in both lists
                        if (storeId(&id_store, &id_store_pos, &hold_ids, &hold_count, jid)) {
                            if (storeId(&id_store, &id_store_pos, &reject_ids, &reject_count, jid))
                                queue_reject += 1;
                        }
                    } else if (queue_hold < sq.hold_first) {
                        if (storeId(&id_store, &id_store_pos, &hold_ids, &hold_count, jid))
                            queue_hold += 1;
                    }
                }
            } else {
                fail += 1;
            }
        }
        // Numbered batch for pagination testing.
        if (sq.batch_count > 0) {
            var i: usize = 0;
            while (i < sq.batch_count) : (i += 1) {
                var payload_buf: [256]u8 = undefined;
                const payload = std.fmt.bufPrint(&payload_buf, sq.batch_template, .{i + 1}) catch continue;
                const resp = client.enqueue(.{
                    .queue = sq.jobs[0].queue,
                    .payload = payload,
                    .priority = sq.batch_priority,
                    .tags = sq.batch_tags,
                }, &resp_buf);
                if (resp.status >= 200 and resp.status < 300) {
                    ok += 1;
                } else {
                    fail += 1;
                }
            }
        }
        total_ok += ok;
        total_fail += fail;
        if (fail > 0) {
            std.debug.print("  {s}: {d} enqueued, {d} failed\n", .{ sq.jobs[0].queue, ok, fail });
        } else {
            std.debug.print("  {s}: {d} enqueued\n", .{ sq.jobs[0].queue, ok });
        }
    }

    // --- Post-enqueue state transitions ---
    var cancelled: usize = 0;
    for (cancel_ids[0..cancel_count]) |job_id| {
        const resp = client.jobAction(job_id, "cancel", &resp_buf);
        if (resp.status >= 200 and resp.status < 300) cancelled += 1;
    }
    var held: usize = 0;
    for (hold_ids[0..hold_count]) |job_id| {
        const resp = client.jobAction(job_id, "hold", &resp_buf);
        if (resp.status >= 200 and resp.status < 300) held += 1;
    }
    var rejected: usize = 0;
    for (reject_ids[0..reject_count]) |job_id| {
        const resp = client.jobAction(job_id, "reject", &resp_buf);
        if (resp.status >= 200 and resp.status < 300) rejected += 1;
    }
    if (cancelled > 0) std.debug.print("\n  Cancelled {d} jobs\n", .{cancelled});
    if (held > 0) std.debug.print("  Held {d} jobs\n", .{held});
    if (rejected > 0) std.debug.print("  Rejected {d} jobs → dead\n", .{rejected});

    // --- Pause a queue ---
    const pause_resp = client.queueAction("report-generation", "pause", &resp_buf);
    if (pause_resp.status >= 200 and pause_resp.status < 300)
        std.debug.print("  Paused report-generation\n", .{});

    // --- Cron jobs ---
    const crons = [_]Client.CronCreateParams{
        .{ .name = "daily-cleanup", .queue = "data-imports", .schedule = "0 2 * * *", .payload = "{\"task\":\"cleanup\"}" },
        .{ .name = "hourly-health-check", .queue = "webhook-delivery", .schedule = "0 * * * *", .payload = "{\"task\":\"health-check\"}" },
        .{ .name = "weekly-digest", .queue = "email-notifications", .schedule = "0 9 * * 1", .payload = "{\"task\":\"weekly-digest\"}" },
    };
    var cron_ok: usize = 0;
    for (crons) |cron| {
        const resp = client.cronCreate(cron, &resp_buf);
        if (resp.status >= 200 and resp.status < 300) cron_ok += 1;
    }
    std.debug.print("  Created {d} cron jobs\n", .{cron_ok});

    std.debug.print("\nDone — {d} jobs enqueued across {d} queues.\n", .{ total_ok, seed_queues.len });
}

fn storeId(id_store: *[8192]u8, pos: *usize, ids: *[16][]const u8, count: *usize, jid: []const u8) bool {
    if (count.* >= 16 or pos.* + jid.len > id_store.len) return false;
    @memcpy(id_store[pos.* .. pos.* + jid.len], jid);
    ids[count.*] = id_store[pos.* .. pos.* + jid.len];
    pos.* += jid.len;
    count.* += 1;
    return true;
}

/// Extract job ID from enqueue response: {"job":{"id":"job_xxx"}} → "job_xxx"
fn extractJobId(body: []const u8) ?[]const u8 {
    const needle = "\"id\":\"";
    const start = (std.mem.indexOf(u8, body, needle) orelse return null) + needle.len;
    const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse return null;
    return body[start..end];
}

const SeedQueue = struct {
    jobs: []const Client.EnqueueParams,
    batch_count: usize = 0,
    batch_template: []const u8 = "",
    batch_priority: []const u8 = "",
    batch_tags: []const u8 = "",
    cancel_first: usize = 0,
    hold_first: usize = 0,
    reject_first: usize = 0, // hold then reject → dead
};

const seed_queues = [_]SeedQueue{
    // --- email-notifications ---
    .{
        .jobs = &.{
            .{ .queue = "email-notifications", .payload = "{\"to\":\"alice@example.com\",\"template\":\"welcome\",\"name\":\"Alice\"}", .tags = "{\"category\":\"email\",\"type\":\"onboarding\"}" },
            .{ .queue = "email-notifications", .payload = "{\"to\":\"bob@example.com\",\"template\":\"password-reset\",\"token\":\"r3s3t\"}", .priority = "75", .tags = "{\"category\":\"email\",\"type\":\"security\"}" },
            .{ .queue = "email-notifications", .payload = "{\"to\":\"carol@example.com\",\"template\":\"order-confirmation\",\"order_id\":\"ORD-1042\"}", .tags = "{\"category\":\"email\",\"type\":\"transactional\"}" },
            .{ .queue = "email-notifications", .payload = "{\"to\":\"dave@example.com\",\"template\":\"shipping-update\",\"tracking\":\"1Z999AA10\"}", .tags = "{\"category\":\"email\",\"type\":\"transactional\"}" },
            .{ .queue = "email-notifications", .payload = "{\"to\":\"eve@example.com\",\"template\":\"invoice\",\"amount\":249.99}", .tags = "{\"category\":\"email\",\"type\":\"billing\"}" },
            .{ .queue = "email-notifications", .payload = "{\"to\":\"frank@example.com\",\"template\":\"welcome\",\"name\":\"Frank\"}", .tags = "{\"category\":\"email\",\"type\":\"onboarding\"}" },
            .{ .queue = "email-notifications", .payload = "{\"to\":\"grace@example.com\",\"template\":\"password-reset\",\"token\":\"x7k2m\"}", .priority = "75", .tags = "{\"category\":\"email\",\"type\":\"security\"}" },
            .{ .queue = "email-notifications", .payload = "{\"to\":\"heidi@example.com\",\"template\":\"weekly-digest\",\"week\":\"2026-W13\"}", .scheduled_at = "2026-04-07T09:00:00Z", .tags = "{\"category\":\"email\",\"type\":\"marketing\"}" },
        },
        .batch_count = 20,
        .batch_template = "{{\"to\":\"user{d}@example.com\",\"template\":\"notification\"}}",
        .batch_tags = "{{\"category\":\"email\",\"type\":\"bulk\"}}",
        .cancel_first = 5,
    },
    // --- payment-processing ---
    .{
        .jobs = &.{
            .{ .queue = "payment-processing", .payload = "{\"customer\":\"cus_A1\",\"amount\":9900,\"currency\":\"usd\",\"method\":\"card\"}", .priority = "75", .tags = "{\"provider\":\"stripe\",\"type\":\"charge\"}" },
            .{ .queue = "payment-processing", .payload = "{\"customer\":\"cus_B2\",\"amount\":4500,\"currency\":\"usd\",\"method\":\"card\"}", .priority = "75", .tags = "{\"provider\":\"stripe\",\"type\":\"charge\"}" },
            .{ .queue = "payment-processing", .payload = "{\"customer\":\"cus_C3\",\"amount\":19900,\"currency\":\"eur\",\"method\":\"sepa\"}", .priority = "90", .tags = "{\"provider\":\"sepa\",\"type\":\"charge\"}" },
            .{ .queue = "payment-processing", .payload = "{\"type\":\"refund\",\"charge\":\"ch_abc\",\"amount\":2500}", .priority = "90", .tags = "{\"provider\":\"stripe\",\"type\":\"refund\"}" },
            .{ .queue = "payment-processing", .payload = "{\"type\":\"subscription\",\"customer\":\"cus_D4\",\"plan\":\"pro_monthly\"}", .tags = "{\"type\":\"subscription\",\"plan\":\"pro_monthly\"}" },
            .{ .queue = "payment-processing", .payload = "{\"type\":\"subscription\",\"customer\":\"cus_E5\",\"plan\":\"team_annual\"}", .tags = "{\"type\":\"subscription\",\"plan\":\"team_annual\"}" },
            .{ .queue = "payment-processing", .payload = "{\"type\":\"payout\",\"account\":\"acct_F6\",\"amount\":150000}", .priority = "50", .tags = "{\"type\":\"payout\"}" },
            .{ .queue = "payment-processing", .payload = "{\"customer\":\"cus_G7\",\"amount\":7200,\"currency\":\"gbp\",\"method\":\"card\"}", .priority = "75", .tags = "{\"provider\":\"stripe\",\"type\":\"charge\"}" },
        },
        .batch_count = 15,
        .batch_template = "{{\"customer\":\"cus_{d}\",\"amount\":1000,\"currency\":\"usd\"}}",
        .batch_priority = "75",
        .batch_tags = "{{\"type\":\"batch\"}}",
        .cancel_first = 3,
    },
    // --- report-generation ---
    .{
        .jobs = &.{
            .{ .queue = "report-generation", .payload = "{\"type\":\"monthly-revenue\",\"month\":\"2026-03\"}", .group = "monthly", .tags = "{\"category\":\"finance\",\"cadence\":\"monthly\"}" },
            .{ .queue = "report-generation", .payload = "{\"type\":\"user-activity\",\"month\":\"2026-03\"}", .group = "monthly", .tags = "{\"category\":\"analytics\",\"cadence\":\"monthly\"}" },
            .{ .queue = "report-generation", .payload = "{\"type\":\"churn-analysis\",\"quarter\":\"Q1-2026\"}", .group = "quarterly", .tags = "{\"category\":\"analytics\",\"cadence\":\"quarterly\"}" },
            .{ .queue = "report-generation", .payload = "{\"type\":\"audit-trail\",\"month\":\"2026-03\"}", .group = "monthly", .priority = "90", .tags = "{\"category\":\"compliance\",\"cadence\":\"monthly\"}" },
            .{ .queue = "report-generation", .payload = "{\"type\":\"inventory\",\"warehouse\":\"us-east\"}", .tags = "{\"category\":\"ops\",\"region\":\"us-east\"}" },
            .{ .queue = "report-generation", .payload = "{\"type\":\"sla-compliance\",\"month\":\"2026-03\"}", .group = "monthly", .tags = "{\"category\":\"compliance\",\"cadence\":\"monthly\"}" },
        },
        .batch_count = 12,
        .batch_template = "{{\"type\":\"export\",\"dataset\":\"table_{d}\"}}",
        .batch_tags = "{{\"category\":\"export\"}}",
        .hold_first = 3,
    },
    // --- data-imports ---
    .{
        .jobs = &.{
            .{ .queue = "data-imports", .payload = "{\"source\":\"salesforce\",\"object\":\"contacts\",\"records\":15000}", .tags = "{\"source\":\"salesforce\",\"type\":\"crm\"}" },
            .{ .queue = "data-imports", .payload = "{\"source\":\"stripe\",\"object\":\"invoices\",\"since\":\"2026-03-01\"}", .tags = "{\"source\":\"stripe\",\"type\":\"billing\"}" },
            .{ .queue = "data-imports", .payload = "{\"source\":\"csv\",\"file\":\"products_march.csv\",\"rows\":4200}", .tags = "{\"source\":\"csv\",\"type\":\"catalog\"}" },
            .{ .queue = "data-imports", .payload = "{\"source\":\"api\",\"endpoint\":\"partner-feed\",\"format\":\"json\"}", .tags = "{\"source\":\"api\",\"type\":\"partner\"}" },
            .{ .queue = "data-imports", .payload = "{\"source\":\"s3\",\"bucket\":\"data-lake\",\"prefix\":\"events/2026-03/\"}", .scheduled_at = "2026-04-01T00:00:00Z", .tags = "{\"source\":\"s3\",\"type\":\"data-lake\"}" },
            .{ .queue = "data-imports", .payload = "{\"source\":\"postgres\",\"table\":\"legacy_orders\",\"batch_size\":5000}", .scheduled_at = "2026-04-01T02:00:00Z", .tags = "{\"source\":\"postgres\",\"type\":\"migration\"}" },
            .{ .queue = "data-imports", .payload = "{\"source\":\"hubspot\",\"object\":\"deals\",\"records\":8300}", .scheduled_at = "2026-04-02T06:00:00Z", .tags = "{\"source\":\"hubspot\",\"type\":\"crm\"}" },
        },
        .reject_first = 2,
    },
    // --- webhook-delivery ---
    .{
        .jobs = &.{
            .{ .queue = "webhook-delivery", .payload = "{\"url\":\"https://acme.com/hooks\",\"event\":\"order.created\",\"order_id\":\"ORD-1042\"}", .tags = "{\"event\":\"order.created\",\"target\":\"acme\"}", .max_retries = "5" },
            .{ .queue = "webhook-delivery", .payload = "{\"url\":\"https://acme.com/hooks\",\"event\":\"payment.succeeded\",\"charge\":\"ch_abc\"}", .tags = "{\"event\":\"payment.succeeded\",\"target\":\"acme\"}", .max_retries = "5" },
            .{ .queue = "webhook-delivery", .payload = "{\"url\":\"https://partner.io/ingest\",\"event\":\"user.signup\",\"user_id\":\"usr_123\"}", .tags = "{\"event\":\"user.signup\",\"target\":\"partner\"}", .max_retries = "5" },
            .{ .queue = "webhook-delivery", .payload = "{\"url\":\"https://partner.io/ingest\",\"event\":\"user.upgraded\",\"plan\":\"pro\"}", .tags = "{\"event\":\"user.upgraded\",\"target\":\"partner\"}", .max_retries = "5" },
            .{ .queue = "webhook-delivery", .payload = "{\"url\":\"https://analytics.co/events\",\"event\":\"report.generated\",\"report_id\":\"rpt_789\"}", .tags = "{\"event\":\"report.generated\",\"target\":\"analytics\"}", .max_retries = "5" },
            .{ .queue = "webhook-delivery", .payload = "{\"url\":\"https://slack.com/api/incoming\",\"event\":\"alert.triggered\",\"severity\":\"high\"}", .priority = "90", .tags = "{\"event\":\"alert.triggered\",\"target\":\"slack\"}", .max_retries = "5" },
        },
        .batch_count = 15,
        .batch_template = "{{\"url\":\"https://example.com/hook\",\"event\":\"item.processed\",\"item_id\":{d}}}",
        .batch_tags = "{{\"event\":\"item.processed\",\"type\":\"batch\"}}",
    },
};
