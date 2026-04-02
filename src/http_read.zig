//! HTTP read handlers — query KV store, build JSON, write HTTP response.
//!
//! Pure functions: take send_buf + reader, return response length.
//! No IO, no pipeline, no state. Pipeline calls these and queues the send.

const std = @import("std");
const http = @import("http.zig");
const json = @import("json_writer.zig");
const kv_read = @import("kv_read.zig");
const http_ui = @import("http_ui.zig");
const metrics_mod = @import("metrics.zig");

/// Cluster info for /cluster/status. Set by main.zig after election.
pub const ClusterInfo = struct {
    node_id: []const u8,
    is_leader: *const std.atomic.Value(bool),
    election: *@import("election.zig").Election,
    events: *metrics_mod.ClusterEventRing,
    peer_count: u32,
};

pub var g_cluster_info: ?*const ClusterInfo = null;
pub var g_admin_password: []const u8 = "";
pub var g_config: ?*const @import("config.zig").ServerConfig = null;
pub var g_cluster_node: ?*@import("cluster.zig").ClusterNode = null;
const ui_embed = @import("ui_embed");


// ============================================================================
// Dispatch
// ============================================================================

/// Route an HTTP read request. Writes the full HTTP response into send_buf.
/// Returns bytes written (0 = no response written).
pub fn dispatch(
    method: http.Method,
    path: []const u8,
    param: []const u8,
    body: []const u8,
    send_buf: []u8,
    reader: ?*kv_read.Reader,
    server_metrics: ?*const metrics_mod.ServerMetrics,
) u32 {
    // Strip query string for route matching.
    const clean = if (std.mem.indexOfScalar(u8, path, '?')) |qi| path[0..qi] else path;

    // Health check (outside /api/v1/).
    if (std.mem.eql(u8, clean, "/healthz"))
        return http.writeResponse(send_buf, 200, "{\"status\":\"ok\"}");

    // UI routes — static assets and server-rendered pages.
    if (std.mem.eql(u8, clean, "/ui") or std.mem.startsWith(u8, clean, "/ui/")) {
        const ui_path = if (clean.len > 3) clean[3..] else "/";

        // Logout: clear session cookie, redirect to login.
        if (std.mem.eql(u8, ui_path, "/logout"))
            return http.writeLogoutRedirect(send_buf);

        // Try static asset first.
        if (ui_embed.lookup(ui_path)) |file|
            return http.writeResponseStatic(send_buf, file.data, file.content_type, file.gzipped);
        // Server-rendered HTML page. Pass query string for filter/search params.
        const query = if (std.mem.indexOfScalar(u8, path, '?')) |qi| path[qi + 1 ..] else "";
        return http_ui.dispatch(ui_path, query, send_buf, reader);
    }

    if (!std.mem.startsWith(u8, clean, "/api/v1/")) return 0;
    const api = clean["/api/v1".len..];

    // Static routes (no mirror needed).
    if (std.mem.eql(u8, api, "/info"))
        return serverInfo(send_buf);
    if (std.mem.eql(u8, api, "/debug/runtime")) return debugRuntime(send_buf);
    if (std.mem.eql(u8, api, "/cluster/status"))
        return clusterStatus(send_buf);
    if (std.mem.eql(u8, api, "/auth/status"))
        return authStatus(send_buf);
    if (std.mem.eql(u8, api, "/auth/login") and method == .POST)
        return handleLogin(send_buf, body);
    if (std.mem.eql(u8, api, "/cluster/join") and method == .POST)
        return handleClusterJoin(send_buf, body);

    const rdr = reader orelse return writeError(send_buf, 503, "no_mirror");

    if (std.mem.eql(u8, api, "/jobs/bulk-get") and method == .POST) return bulkGetJobs(send_buf, rdr, body);
    if (std.mem.eql(u8, api, "/jobs/search-by-tag")) return searchByTag(send_buf, rdr, path);
    if (std.mem.eql(u8, api, "/jobs") or std.mem.eql(u8, api, "/jobs/search")) {
        if (method == .POST) return jobSearchPost(send_buf, rdr, body);
        return jobSearch(send_buf, rdr, path);
    }
    if (std.mem.startsWith(u8, api, "/jobs/") and param.len > 0) return job(send_buf, rdr, param);
    if (std.mem.eql(u8, api, "/search")) return search(send_buf, rdr, path);
    if (std.mem.eql(u8, api, "/queues")) return queues(send_buf, rdr);
    if (std.mem.eql(u8, api, "/workers")) return workers(send_buf, rdr);
    if (std.mem.eql(u8, api, "/crons") or std.mem.eql(u8, api, "/cron-jobs")) return crons(send_buf, rdr);
    if (std.mem.startsWith(u8, api, "/cron-jobs/") and param.len > 0) return cron(send_buf, rdr, param);
    if (std.mem.eql(u8, api, "/budgets")) return budgets(send_buf, rdr);
    if (std.mem.eql(u8, api, "/api-keys")) return apiKeys(send_buf, rdr);
    if (std.mem.eql(u8, api, "/webhooks")) return webhooksApi(send_buf, rdr);
    if (std.mem.eql(u8, api, "/audit-logs")) return auditLogs(send_buf, rdr);
    if (std.mem.eql(u8, api, "/cluster/events"))
        return clusterEvents(send_buf);
    if (std.mem.eql(u8, api, "/metrics/throughput"))
        return throughputMetrics(send_buf, server_metrics);
    return writeError(send_buf, 404, "not found");
}

// ============================================================================
// Server info
// ============================================================================

fn serverInfo(send_buf: []u8) u32 {
    var body_buf: [4096]u8 = undefined;
    var w = json.JsonWriter.init(&body_buf);
    w.beginObject();
    w.fieldStr("version", "0.1.0b");
    w.fieldStr("engine", "zig");

    if (g_config) |cfg| {
        w.fieldStr("bind", cfg.bind);
        w.fieldInt("port", cfg.port);
        w.fieldStr("data_dir", cfg.data_dir);
        w.fieldInt("max_conns", cfg.max_conns);
        w.fieldInt("max_payload_size", @as(i64, cfg.max_payload_size));
        w.fieldInt("max_queues", @as(i64, cfg.max_queues));
        w.fieldInt("max_jobs", @as(i64, cfg.max_jobs));
        w.fieldInt("max_tags_per_queue", @as(i64, cfg.max_tags_per_queue));
        w.fieldBool("persist_completed", cfg.persist_completed);
        w.fieldBool("sync_replication", cfg.sync_replication);
        w.fieldBool("cluster_mode", cfg.clusterMode());
        w.fieldBool("admin_password_set", cfg.admin_password.len > 0);
        w.fieldInt("purge_threshold", @as(i64, cfg.purge_threshold));
        w.fieldInt("purge_retention_ns", @as(i64, @intCast(cfg.purge_retention_ns)));
        w.fieldInt("worker_timeout_ns", @as(i64, @intCast(cfg.worker_timeout_ns)));
        if (cfg.discover_dns_name.len > 0)
            w.fieldStr("discover_dns_name", cfg.discover_dns_name);
        if (cfg.node_id.len > 0)
            w.fieldStr("node_id", cfg.node_id);
        if (cfg.peers.len > 0)
            w.fieldStr("peers", cfg.peers);
    }

    w.endObject();
    return http.writeResponse(send_buf, 200, w.getWritten());
}

// ============================================================================
// Admin Auth — login handler
// ============================================================================

fn authStatus(send_buf: []u8) u32 {
    var body_buf: [128]u8 = undefined;
    var w = json.JsonWriter.init(&body_buf);
    w.beginObject();
    w.fieldBool("admin_password_set", g_admin_password.len > 0);
    w.endObject();
    return http.writeResponse(send_buf, 200, w.getWritten());
}

fn handleLogin(send_buf: []u8, body: []const u8) u32 {
    if (g_admin_password.len == 0)
        return http.writeResponse(send_buf, 400, "{\"error\":\"no admin password configured\"}");

    // Parse form body: password=value (URL-encoded form data).
    const password = extractFormValue(body, "password") orelse
        return http.writeRedirect(send_buf, "/ui/login?error=1");

    // Percent-decode the password (browsers encode form values).
    var decoded_buf: [256]u8 = undefined;
    const decoded = percentDecode(password, &decoded_buf);

    if (!std.mem.eql(u8, decoded, g_admin_password))
        return http.writeRedirect(send_buf, "/ui/login?error=1");

    // Valid — set session cookie and redirect to dashboard.
    var token_buf: [64]u8 = undefined;
    const token = http.sessionHash(g_admin_password, &token_buf);
    return http.writeLoginRedirect(send_buf, token);
}

fn extractFormValue(body: []const u8, key: []const u8) ?[]const u8 {
    var rest = body;
    while (rest.len > 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const pair = rest[0..amp];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
            continue;
        };
        if (std.mem.eql(u8, pair[0..eq], key))
            return pair[eq + 1 ..];
        rest = if (amp < rest.len) rest[amp + 1 ..] else "";
    }
    return null;
}

fn percentDecode(input: []const u8, buf: *[256]u8) []const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < input.len and out < buf.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            const hi = hexDigit(input[i + 1]);
            const lo = hexDigit(input[i + 2]);
            if (hi != null and lo != null) {
                buf[out] = (@as(u8, hi.?) << 4) | lo.?;
                out += 1;
                i += 3;
                continue;
            }
        }
        if (input[i] == '+') {
            buf[out] = ' ';
        } else {
            buf[out] = input[i];
        }
        out += 1;
        i += 1;
    }
    return buf[0..out];
}

fn hexDigit(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

// ============================================================================
// Cluster join
// ============================================================================

fn handleClusterJoin(send_buf: []u8, body: []const u8) u32 {
    const cn = g_cluster_node orelse
        return writeError(send_buf, 400, "not in cluster mode");

    if (!cn.isLeader()) {
        const state = cn.election.currentState();
        var body_buf: [256]u8 = undefined;
        var w = json.JsonWriter.init(&body_buf);
        w.beginObject();
        w.fieldStr("error", "not leader");
        w.fieldStr("leader_id", state.leader_id);
        w.endObject();
        return http.writeResponse(send_buf, 409, w.getWritten());
    }

    const node_id = extractJSONString(body, "node_id") orelse
        return writeError(send_buf, 400, "missing node_id");
    const addr_str = extractJSONString(body, "addr") orelse
        return writeError(send_buf, 400, "missing addr");

    // Parse addr as host:port.
    const colon = std.mem.lastIndexOfScalar(u8, addr_str, ':') orelse
        return writeError(send_buf, 400, "invalid addr format");
    const host = addr_str[0..colon];
    const port = std.fmt.parseInt(u16, addr_str[colon + 1 ..], 10) catch
        return writeError(send_buf, 400, "invalid addr port");
    const addr = std.net.Address.parseIp(host, port) catch
        return writeError(send_buf, 400, "invalid addr IP");

    cn.addPeer(node_id, addr);

    var resp_buf: [256]u8 = undefined;
    var w = json.JsonWriter.init(&resp_buf);
    w.beginObject();
    w.fieldStr("status", "ok");
    w.fieldStr("node_id", node_id);
    w.fieldStr("leader_id", cn.config.node_id);
    w.endObject();
    return http.writeResponse(send_buf, 200, w.getWritten());
}

// ============================================================================
// Metrics (special — text/plain, not JSON)
// ============================================================================

pub fn metrics(send_buf: []u8, reader: ?*kv_read.Reader, server_metrics: ?*const metrics_mod.ServerMetrics) u32 {
    var body_buf: [65536]u8 = undefined;
    var pos: usize = 0;

    // Server-side performance metrics (latency histograms + throughput counters).
    if (server_metrics) |sm| {
        pos += sm.writePrometheus(body_buf[pos..]);
    }

    // KV-based queue state gauges.
    if (reader) |rdr| {
        var stats_buf: [64]kv_read.QueueStats = undefined;
        const qcount = rdr.getQueueStats(&stats_buf);
        if (qcount > 0) {
            pos += (std.fmt.bufPrint(
                body_buf[pos..],
                "# HELP corvo_queue_jobs Number of jobs per queue and state\n" ++
                    "# TYPE corvo_queue_jobs gauge\n",
                .{},
            ) catch &[0]u8{}).len;
            for (0..qcount) |i| {
                const q = &stats_buf[i];
                const qn = q.nameSlice();
                inline for (.{
                    .{ "pending", q.pending },
                    .{ "active", q.active },
                    .{ "retrying", q.retrying },
                    .{ "scheduled", q.scheduled },
                    .{ "completed", q.completed },
                    .{ "dead", q.dead },
                    .{ "cancelled", q.cancelled },
                    .{ "held", q.held },
                }) |pair| {
                    pos += (std.fmt.bufPrint(
                        body_buf[pos..],
                        "corvo_queue_jobs{{queue=\"{s}\",state=\"{s}\"}} {d}\n",
                        .{ qn, pair[0], pair[1] },
                    ) catch break).len;
                }
            }
        }

        const wcount = rdr.countWorkers();
        pos += (std.fmt.bufPrint(
            body_buf[pos..],
            "# HELP corvo_workers_registered Number of registered workers\n" ++
                "# TYPE corvo_workers_registered gauge\n" ++
                "corvo_workers_registered {d}\n",
            .{wcount},
        ) catch &[0]u8{}).len;
    }

    // Cluster metrics gauges.
    if (g_cluster_info) |ci| {
        const es = ci.election.currentState();
        const state_val: u8 = @intFromEnum(es.state);
        const now_i: i64 = @intCast(@as(i128, std.time.nanoTimestamp()));
        const lease_valid: u8 = if (ci.election.leaseValid(now_i)) 1 else 0;

        pos += (std.fmt.bufPrint(
            body_buf[pos..],
            "# HELP corvo_cluster_state Node role (0=follower, 1=candidate, 2=leader)\n" ++
                "# TYPE corvo_cluster_state gauge\n" ++
                "corvo_cluster_state {d}\n" ++
                "# HELP corvo_cluster_epoch Current election epoch\n" ++
                "# TYPE corvo_cluster_epoch gauge\n" ++
                "corvo_cluster_epoch {d}\n" ++
                "# HELP corvo_cluster_lease_valid Whether leader lease is valid (1=yes, 0=no)\n" ++
                "# TYPE corvo_cluster_lease_valid gauge\n" ++
                "corvo_cluster_lease_valid {d}\n" ++
                "# HELP corvo_cluster_peers_total Number of cluster peers\n" ++
                "# TYPE corvo_cluster_peers_total gauge\n" ++
                "corvo_cluster_peers_total {d}\n",
            .{ state_val, es.epoch, lease_valid, ci.peer_count },
        ) catch &[0]u8{}).len;
    }

    return http.writeResponseText(send_buf, 200, body_buf[0..pos]);
}

fn clusterStatus(send_buf: []u8) u32 {
    var body_buf: [512]u8 = undefined;
    var w = json.JsonWriter.init(&body_buf);

    const ci = g_cluster_info orelse {
        w.beginObject();
        w.fieldStr("mode", "standalone");
        w.fieldStr("status", "healthy");
        w.fieldStr("state", "leader");
        w.fieldStr("node_id", "standalone");
        w.fieldStr("leader", "standalone");
        w.endObject();
        return http.writeResponse(send_buf, 200, w.getWritten());
    };

    const es = ci.election.currentState();
    const state_str = switch (es.state) {
        .leader => "leader",
        .follower => "follower",
        .candidate => "candidate",
    };

    w.beginObject();
    w.fieldStr("mode", "cluster");
    w.fieldStr("status", "healthy");
    w.fieldStr("state", state_str);
    w.fieldStr("node_id", ci.node_id);
    w.fieldStr("leader", es.leader_id);
    w.fieldInt("epoch", es.epoch);
    w.endObject();
    return http.writeResponse(send_buf, 200, w.getWritten());
}


fn clusterEvents(send_buf: []u8) u32 {
    var body_buf: [8192]u8 = undefined;
    var w = json.JsonWriter.init(&body_buf);

    w.beginObject();
    w.beginArrayField("events");

    const ci = g_cluster_info orelse {
        w.endArray();
        w.endObject();
        return http.writeResponse(send_buf, 200, w.getWritten());
    };

    var event_buf: [64]metrics_mod.ClusterEvent = undefined;
    const count = ci.events.snapshot(&event_buf);
    for (0..count) |i| {
        const ev = &event_buf[i];
        w.beginObject();
        w.fieldStr("type", ev.typeStr());
        w.fieldInt("epoch", ev.epoch);
        w.fieldInt("timestamp_ns", ev.timestamp_ns);
        if (ev.detail_len > 0) w.fieldStr("detail", ev.detailSlice());
        w.endObject();
    }

    w.endArray();
    w.endObject();
    return http.writeResponse(send_buf, 200, w.getWritten());
}

fn throughputMetrics(send_buf: []u8, server_metrics: ?*const metrics_mod.ServerMetrics) u32 {
    var body_buf: [8192]u8 = undefined;
    var w = json.JsonWriter.init(&body_buf);

    const sm = server_metrics orelse {
        w.beginObject();
        w.fieldInt("enqueue_rate", 0);
        w.fieldInt("complete_rate", 0);
        w.fieldInt("fail_rate", 0);
        w.fieldInt("window_seconds", 60);
        w.endObject();
        return http.writeResponse(send_buf, 200, w.getWritten());
    };

    // Use current time for the snapshot window.
    const now_ns: u64 = @intCast(@as(i128, std.time.nanoTimestamp()));
    const snap = sm.throughput.snapshot(now_ns);

    w.beginObject();
    w.fieldInt("enqueued_total", sm.enqueued_total);
    w.fieldInt("completed_total", sm.completed_total);
    w.fieldInt("failed_total", sm.failed_total);
    w.fieldInt("enqueue_rate", snap.enqueue_rate);
    w.fieldInt("complete_rate", snap.complete_rate);
    w.fieldInt("fail_rate", snap.fail_rate);
    w.fieldInt("window_seconds", snap.seconds);
    w.beginArrayField("per_second");
    for (0..snap.seconds) |i| {
        w.beginObject();
        w.fieldInt("enqueued", snap.per_second[i].enqueued);
        w.fieldInt("completed", snap.per_second[i].completed);
        w.fieldInt("failed", snap.per_second[i].failed);
        w.endObject();
    }
    w.endArray();
    w.endObject();
    return http.writeResponse(send_buf, 200, w.getWritten());
}

// ============================================================================
// Individual read handlers
// ============================================================================

fn queues(send_buf: []u8, reader: *kv_read.Reader) u32 {
    var queue_buf: [64]kv_read.QueueStats = undefined;
    const count = reader.getQueueStats(&queue_buf);

    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginArray();
    for (0..count) |i| {
        const q = &queue_buf[i];
        jw.beginObject();
        jw.fieldStr("name", q.nameSlice());
        jw.fieldInt("pending", q.pending);
        jw.fieldInt("active", q.active);
        jw.fieldInt("retrying", q.retrying);
        jw.fieldInt("dead", q.dead);
        jw.fieldInt("cancelled", q.cancelled);
        jw.fieldInt("completed", q.completed);
        jw.fieldInt("scheduled", q.scheduled);
        jw.fieldInt("held", q.held);
        jw.fieldBool("paused", q.paused);
        if (q.oldest_pending_at_len > 0) jw.fieldStr("oldest_pending_at", q.oldestPendingAtSlice());
        jw.endObject();
    }
    jw.endArray();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn workers(send_buf: []u8, reader: *kv_read.Reader) u32 {
    var worker_buf: [64]kv_read.WorkerRow = undefined;
    const count = reader.getWorkers(&worker_buf);

    var body_buf: [16384]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginArray();
    for (0..count) |i| {
        const wk = &worker_buf[i];
        jw.beginObject();
        jw.fieldStr("id", wk.idSlice());
        jw.fieldStr("hostname", wk.hostnameSlice());
        jw.fieldStr("queues", wk.queuesSlice());
        jw.fieldStr("last_heartbeat", wk.lastHeartbeatSlice());
        jw.fieldStr("started_at", wk.startedAtSlice());
        jw.endObject();
    }
    jw.endArray();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn crons(send_buf: []u8, reader: *kv_read.Reader) u32 {
    var cron_buf: [64]kv_read.CronRow = undefined;
    const count = reader.listCrons(&cron_buf, 64, 0);

    var body_buf: [16384]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginArray();
    for (0..count) |i| {
        const cr = &cron_buf[i];
        jw.beginObject();
        jw.fieldStr("id", cr.idSlice());
        jw.fieldStr("name", cr.nameSlice());
        jw.fieldStr("queue", cr.queueSlice());
        jw.fieldStr("schedule", cr.scheduleSlice());
        jw.fieldBool("enabled", cr.enabled);
        jw.endObject();
    }
    jw.endArray();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn cron(send_buf: []u8, reader: *kv_read.Reader, cron_id: []const u8) u32 {
    const cr = reader.getCron(cron_id) orelse
        return writeError(send_buf, 404, "schedule not found");

    var body_buf: [4096]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldStr("id", cr.idSlice());
    jw.fieldStr("name", cr.nameSlice());
    jw.fieldStr("queue", cr.queueSlice());
    jw.fieldStr("schedule", cr.scheduleSlice());
    jw.fieldBool("enabled", cr.enabled);
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn job(send_buf: []u8, reader: *kv_read.Reader, job_id: []const u8) u32 {
    const j = reader.getJob(job_id) orelse
        return writeError(send_buf, 404, "job not found");

    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();

    jw.fieldStr("id", j.idSlice());
    jw.fieldStr("queue", j.queueSlice());
    jw.fieldStr("state", j.stateSlice());
    jw.fieldInt("priority", j.priority);
    jw.fieldInt("attempt", j.attempt);
    jw.fieldInt("max_retries", j.max_retries);

    if (j.retry_backoff_len > 0) jw.fieldStr("retry_backoff", j.retryBackoffSlice());
    if (j.retry_base_delay_ms != 0) jw.fieldInt("retry_base_delay_ms", j.retry_base_delay_ms);
    if (j.retry_max_delay_ms != 0) jw.fieldInt("retry_max_delay_ms", j.retry_max_delay_ms);

    if (j.worker_id_len > 0) jw.fieldStr("worker_id", j.workerIdSlice());
    if (j.hostname_len > 0) jw.fieldStr("hostname", j.hostnameSlice());
    if (j.unique_key_len > 0) jw.fieldStr("unique_key", j.uniqueKeySlice());
    if (j.batch_id_len > 0) jw.fieldStr("batch_id", j.batchIdSlice());
    if (j.parent_id_len > 0) jw.fieldStr("parent_id", j.parentIdSlice());
    if (j.hold_reason_len > 0) jw.fieldStr("hold_reason", j.holdReasonSlice());
    if (j.chain_id_len > 0) {
        jw.fieldStr("chain_id", j.chainIdSlice());
        jw.fieldInt("chain_step", j.chain_step);
    }

    if (j.tags_len > 0) jw.fieldRaw("tags", j.tagsSlice());
    if (j.checkpoint_len > 0) jw.fieldRaw("checkpoint", j.checkpointSlice());
    if (j.result_len > 0) jw.fieldRaw("result", j.resultSlice());
    if (j.progress_len > 0) jw.fieldRaw("progress", j.progressSlice());

    // Payload from separate table.
    var payload_buf: [65536]u8 = undefined;
    if (reader.getJobPayload(job_id, &payload_buf)) |payload| {
        jw.fieldRaw("payload", payload);
    }

    if (j.created_at_len > 0) jw.fieldStr("created_at", j.createdAtSlice());
    if (j.started_at_len > 0) jw.fieldStr("started_at", j.startedAtSlice());
    if (j.completed_at_len > 0) jw.fieldStr("completed_at", j.completedAtSlice());
    if (j.failed_at_len > 0) jw.fieldStr("failed_at", j.failedAtSlice());
    if (j.scheduled_at_len > 0) jw.fieldStr("scheduled_at", j.scheduledAtSlice());
    if (j.lease_expires_at_len > 0) jw.fieldStr("lease_expires_at", j.leaseExpiresAtSlice());
    if (j.expire_at_len > 0) jw.fieldStr("expire_at", j.expireAtSlice());

    var err_buf: [32]kv_read.JobError = undefined;
    const err_count = reader.getJobErrors(job_id, &err_buf);
    if (err_count > 0) {
        jw.beginArrayField("errors");
        for (0..err_count) |i| {
            const e = &err_buf[i];
            jw.beginObject();
            jw.fieldInt("attempt", e.attempt);
            jw.fieldStr("error", e.errorSlice());
            jw.fieldStr("created_at", e.created_at[0..e.created_at_len]);
            jw.endObject();
        }
        jw.endArray();
    }

    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn search(send_buf: []u8, reader: *kv_read.Reader, path: []const u8) u32 {
    const query_str = http.extractQueryParam(path, "q") orelse
        return writeError(send_buf, 400, "q parameter is required");
    if (query_str.len == 0) return writeError(send_buf, 400, "q parameter is required");

    var result_buf: [100]kv_read.JobRow = undefined;
    const count = reader.searchPayload(query_str, &result_buf);

    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldStr("q", query_str);
    jw.beginArrayField("results");
    for (0..count) |i| writeJobRowSummary(&jw, &result_buf[i]);
    jw.endArray();
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn searchByTag(send_buf: []u8, reader: *kv_read.Reader, path: []const u8) u32 {
    const tag_key = http.extractQueryParam(path, "tag_key") orelse
        return writeError(send_buf, 400, "tag_key parameter is required");
    const tag_value = http.extractQueryParam(path, "tag_value") orelse
        return writeError(send_buf, 400, "tag_value parameter is required");
    const queue = http.extractQueryParam(path, "queue") orelse
        return writeError(send_buf, 400, "queue parameter is required");
    const state = http.extractQueryParam(path, "state");
    if (tag_key.len == 0) return writeError(send_buf, 400, "tag_key parameter is required");
    if (tag_value.len == 0) return writeError(send_buf, 400, "tag_value parameter is required");
    if (queue.len == 0) return writeError(send_buf, 400, "queue parameter is required");

    var result_buf: [100]kv_read.JobRow = undefined;
    const count = reader.searchByTag(tag_key, tag_value, queue, state, &result_buf);

    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldStr("tag_key", tag_key);
    jw.fieldStr("tag_value", tag_value);
    jw.fieldStr("queue", queue);
    if (state) |s| jw.fieldStr("state", s);
    jw.beginArrayField("jobs");
    for (0..count) |i| writeJobRowSummary(&jw, &result_buf[i]);
    jw.endArray();
    jw.fieldInt("total", count);
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn jobSearch(send_buf: []u8, reader: *kv_read.Reader, path: []const u8) u32 {
    const query_str = http.extractQueryParam(path, "q");

    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.beginArrayField("jobs");

    if (query_str) |q| {
        var result_buf: [100]kv_read.JobRow = undefined;
        const count = reader.searchPayload(q, &result_buf);
        for (0..count) |i| writeJobRowSummary(&jw, &result_buf[i]);
    } else {
        var job_buf: [100]kv_read.JobRow = undefined;
        const count = reader.getJobs(&job_buf);
        for (0..count) |i| writeJobRowSummary(&jw, &job_buf[i]);
    }

    jw.endArray();
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn jobSearchPost(send_buf: []u8, reader: *kv_read.Reader, body_input: []const u8) u32 {
    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.beginArrayField("jobs");

    const text_filter = extractJSONString(body_input, "payload_contains");
    const queue_filter = extractJSONString(body_input, "queue");
    var state_strs: [1][]const u8 = undefined;
    const state_count = extractJSONStringArray(body_input, "state", &state_strs);
    const state_filter = if (state_count > 0) state_strs[0] else null;
    const limit_val = extractJSONInt(body_input, "limit");
    const limit: u32 = if (limit_val) |l| @intCast(@min(@max(l, 1), 500)) else 100;

    var job_buf: [100]kv_read.JobRow = undefined;
    const actual_limit = @min(limit, @as(u32, @intCast(job_buf.len)));
    var count: u32 = 0;

    if (text_filter) |q| {
        count = reader.searchPayload(q, job_buf[0..actual_limit]);
    } else {
        count = reader.queryJobsByQueueState(queue_filter, state_filter, actual_limit, 0, &job_buf);
    }

    for (0..count) |i| writeJobRowSummary(&jw, &job_buf[i]);

    jw.endArray();
    jw.fieldInt("total", count);
    jw.fieldBool("has_more", false);
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn bulkGetJobs(send_buf: []u8, reader: *kv_read.Reader, body: []const u8) u32 {
    var id_buf: [100][]const u8 = undefined;
    const id_count = extractJSONStringArray(body, "job_ids", &id_buf);
    if (id_count == 0) return writeError(send_buf, 400, "job_ids required");

    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.beginArrayField("jobs");

    for (0..@min(id_count, 100)) |i| {
        const j = reader.getJob(id_buf[i]) orelse continue;
        jw.beginObject();
        jw.fieldStr("id", j.idSlice());
        jw.fieldStr("queue", j.queueSlice());
        jw.fieldStr("state", j.stateSlice());
        jw.fieldInt("priority", j.priority);
        jw.fieldInt("attempt", j.attempt);
        jw.fieldInt("max_retries", j.max_retries);
        jw.endObject();
    }

    jw.endArray();
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn budgets(send_buf: []u8, reader: *kv_read.Reader) u32 {
    var budget_buf: [64]kv_read.BudgetRow = undefined;
    const count = reader.listBudgets(&budget_buf);

    var body_buf: [16384]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginArray();
    for (0..count) |i| {
        const row = &budget_buf[i];
        jw.beginObject();
        jw.fieldStr("scope", row.scopeSlice());
        jw.fieldStr("target", row.targetSlice());
        jw.fieldFloat("daily_usd", row.daily_usd);
        jw.fieldFloat("per_job_usd", row.per_job_usd);
        jw.fieldStr("on_exceed", row.onExceedSlice());
        jw.fieldStr("created_at", row.createdAtSlice());
        jw.endObject();
    }
    jw.endArray();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn apiKeys(send_buf: []u8, reader: *kv_read.Reader) u32 {
    var key_buf: [100]kv_read.ApiKeyRow = undefined;
    const count = reader.listApiKeys(&key_buf);

    var body_buf: [16384]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginArray();
    for (0..count) |i| {
        const row = &key_buf[i];
        jw.beginObject();
        jw.fieldStr("key_hash", row.keyHashSlice());
        jw.fieldStr("name", row.nameSlice());
        jw.fieldStr("role", row.roleSlice());
        jw.fieldBool("enabled", row.enabled);
        jw.fieldStr("created_at", row.createdAtSlice());
        if (row.expires_at_len > 0) jw.fieldStr("expires_at", row.expiresAtSlice());
        jw.endObject();
    }
    jw.endArray();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn webhooksApi(send_buf: []u8, reader: *kv_read.Reader) u32 {
    var wh_buf: [64]kv_read.WebhookRow = undefined;
    const count = reader.listWebhooks(&wh_buf);

    var body_buf: [16384]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginArray();
    for (0..count) |i| {
        const row = &wh_buf[i];
        jw.beginObject();
        jw.fieldStr("id", row.idSlice());
        jw.fieldStr("url", row.urlSlice());
        jw.fieldStr("queue", row.queueFilterSlice());
        jw.fieldStr("events", row.eventsSlice());
        jw.fieldBool("enabled", row.enabled);
        jw.fieldStr("created_at", row.createdAtSlice());
        jw.endObject();
    }
    jw.endArray();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn auditLogs(send_buf: []u8, reader: *kv_read.Reader) u32 {
    var entries: [200]kv_read.AuditEntryRow = undefined;
    const count = reader.listAuditEntries(&entries);

    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginArray();
    for (0..count) |i| {
        const row = &entries[i];
        jw.beginObject();
        jw.fieldStr("op", row.opSlice());
        jw.fieldStr("target", row.targetSlice());
        jw.fieldInt("count", row.count);
        jw.fieldStr("actor", row.actorSlice());
        jw.fieldInt("ts", row.ts);
        jw.fieldStr("created_at", row.createdAtSlice());
        jw.endObject();
    }
    jw.endArray();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn debugRuntime(send_buf: []u8) u32 {
    var body_buf: [256]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldStr("engine", "zig");
    jw.fieldStr("arch", @tagName(@import("builtin").cpu.arch));
    jw.fieldStr("os", @tagName(@import("builtin").os.tag));
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

// ============================================================================
// Helpers
// ============================================================================

fn writeJobRowSummary(jw: *json.JsonWriter, j: *const kv_read.JobRow) void {
    jw.beginObject();
    jw.fieldStr("id", j.idSlice());
    jw.fieldStr("queue", j.queueSlice());
    jw.fieldStr("state", j.stateSlice());
    jw.fieldInt("priority", j.priority);
    jw.fieldInt("attempt", j.attempt);
    jw.fieldInt("max_retries", j.max_retries);
    jw.fieldStr("created_at", j.createdAtSlice());
    if (j.scheduled_at_len > 0) jw.fieldStr("scheduled_at", j.scheduledAtSlice());
    if (j.worker_id_len > 0) jw.fieldStr("worker_id", j.workerIdSlice());
    if (j.tags_len > 0) jw.fieldRaw("tags", j.tagsSlice());
    jw.endObject();
}

fn writeError(send_buf: []u8, status: u16, msg: []const u8) u32 {
    var body_buf: [256]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldStr("error", msg);
    jw.endObject();
    return http.writeResponse(send_buf, status, jw.getWritten());
}

// ============================================================================
// JSON extraction helpers (moved from pipeline — needed by jobSearchPost)
// ============================================================================

pub fn extractJSONString(body: []const u8, key: []const u8) ?[]const u8 {
    // Find "key":"value" pattern.
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    const val_start = start + search_key.len;
    if (val_start >= body.len) return null;
    const end = std.mem.indexOfScalar(u8, body[val_start..], '"') orelse return null;
    return body[val_start..][0..end];
}

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

    // Parse integer.
    var end = i;
    if (end < body.len and body[end] == '-') end += 1;
    while (end < body.len and body[end] >= '0' and body[end] <= '9') end += 1;
    if (end == i) return null;
    return std.fmt.parseInt(i64, body[i..end], 10) catch null;
}

pub fn extractJSONStringArray(body: []const u8, key: []const u8, out: [][]const u8) usize {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":[", .{key}) catch return 0;
    const start = std.mem.indexOf(u8, body, search_key) orelse return 0;
    const arr_start = start + search_key.len;
    if (arr_start >= body.len) return 0;

    var count: usize = 0;
    var i = arr_start;
    while (i < body.len and count < out.len) {
        // Find next string.
        const q1 = std.mem.indexOfScalar(u8, body[i..], '"') orelse break;
        const str_start = i + q1 + 1;
        if (str_start >= body.len) break;
        const q2 = std.mem.indexOfScalar(u8, body[str_start..], '"') orelse break;
        out[count] = body[str_start..][0..q2];
        count += 1;
        i = str_start + q2 + 1;
    }
    return count;
}
