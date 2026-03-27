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

    // Read response.
    var total: usize = 0;
    while (total < resp_buf.len) {
        const n = stream.read(resp_buf[total..]) catch break;
        if (n == 0) break;
        total += n;
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

// ============================================================================
// Client — testable API layer (no arg parsing, no process exit)
//
// Usage:
//   const client = Client{ .server = "http://localhost:8080" };
//   var resp_buf: [65536]u8 = undefined;
//   const resp = client.enqueue(.{ .queue = "emails", .payload = "{}" }, &resp_buf);
// ============================================================================

pub const Client = struct {
    server: []const u8 = "http://localhost:8080",
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
        queue: []const u8,
        state: []const u8 = "",
        target_queue: []const u8 = "",
        limit: []const u8 = "",
    };

    pub fn bulk(self: Client, params: BulkParams, resp_buf: []u8) HttpResponse {
        var body_buf: [4096]u8 = undefined;
        var body_pos: usize = 0;

        body_pos += (std.fmt.bufPrint(body_buf[body_pos..], "{{\"action\":\"{s}\",\"queue\":\"{s}\"", .{ params.action, params.queue }) catch return errResp("body too large")).len;

        if (params.state.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"state\":\"{s}\"", .{params.state}) catch return errResp("body too large")).len;
        if (params.target_queue.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"target_queue\":\"{s}\"", .{params.target_queue}) catch return errResp("body too large")).len;
        if (params.limit.len > 0)
            body_pos += (std.fmt.bufPrint(body_buf[body_pos..], ",\"limit\":{s}", .{params.limit}) catch return errResp("body too large")).len;

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
    server: []const u8 = "http://localhost:8080",
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
    if (eql(first_arg, "retry")) return cmdJobAction(args, "retry");
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
        \\  retry               Retry a failed/dead job
        \\  cancel              Cancel a pending/active job
        \\  delete              Delete a job
        \\  hold                Move a job to held state
        \\  approve             Approve a held job back to pending
        \\  reject              Reject a held job to dead state
        \\  move                Move a job to another queue
        \\  bulk                Apply bulk action (retry, delete, cancel, move, requeue)
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
        \\Global Options:
        \\  --server <url>      Server URL (default: http://localhost:8080)
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
                \\  --server <url>         Server URL (default: http://localhost:8080)
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
// retry/cancel/hold/approve/reject <job-id>
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
    var queue: []const u8 = "";
    var state: []const u8 = "";
    var target_queue: []const u8 = "";
    var limit: []const u8 = "";
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
        } else if (eql(arg, "--target-queue")) {
            target_queue = args.next() orelse { fatal("--target-queue requires an argument"); unreachable; };
        } else if (eql(arg, "--limit")) {
            limit = args.next() orelse { fatal("--limit requires an argument"); unreachable; };
        } else if (eql(arg, "--help") or eql(arg, "-h")) {
            std.debug.print(
                \\Usage: corvo bulk <action> --queue <queue> [options]
                \\
                \\Apply a bulk action to jobs in a queue.
                \\
                \\Actions: retry, delete, cancel, move, requeue
                \\
                \\Options:
                \\  --queue <name>          Queue name (required)
                \\  --state <state>         Filter by state (dead, failed, completed, etc.)
                \\  --target-queue <name>   Target queue (for move action)
                \\  --limit <n>             Maximum number of jobs to affect
                \\  --server <url>          Server URL (default: http://localhost:8080)
                \\  --api-key <key>         API key (env: CORVO_API_KEY)
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

    if (action.len == 0) { fatal("usage: corvo bulk <action> --queue <queue>"); unreachable; }
    if (queue.len == 0) { fatal("--queue is required for bulk operations"); unreachable; }

    const client = Client{ .server = opts.server, .api_key = opts.api_key };
    var resp_buf: [65536]u8 = undefined;
    printResponse(client.bulk(.{
        .action = action,
        .queue = queue,
        .state = state,
        .target_queue = target_queue,
        .limit = limit,
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
                \\  --server <url>       Server URL (default: http://localhost:8080)
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
                \\  --server <url>          Server URL (default: http://localhost:8080)
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


