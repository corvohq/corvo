//! HTTP read handlers — query KV store, build JSON, write HTTP response.
//!
//! Pure functions: take send_buf + reader, return response length.
//! No IO, no pipeline, no state. Pipeline calls these and queues the send.

const std = @import("std");
const http = @import("http.zig");
const json = @import("json_writer.zig");
const kv = @import("kv.zig");
const kv_read = @import("kv_read.zig");
const http_ui = @import("http_ui.zig");
const metrics_mod = @import("metrics.zig");
const version = @import("version.zig");

/// Cluster info for /cluster/status. Set by main.zig at raft startup.
/// is_leader points at the RaftHost's atomic — the raft thread owns it,
/// reads here are lock-free.
pub const ClusterInfo = struct {
    node_id: []const u8,
    is_leader: *const std.atomic.Value(bool),
    peer_count: u8,
};

pub var g_cluster_info: ?*const ClusterInfo = null;
pub var g_admin_password: []const u8 = "";
pub var g_config: ?*const @import("config.zig").ServerConfig = null;
pub var g_raft_host: ?*@import("raft_host.zig").RaftHost = null;
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
    store: *kv.Store,
    now_ns: u64,
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

    // Backup/restore endpoints.
    if (std.mem.eql(u8, api, "/backup") and method == .POST)
        return backupCreate(send_buf, store, now_ns);
    if (std.mem.startsWith(u8, api, "/backup/")) {
        const backup_id = api["/backup/".len..];
        if (backup_id.len > 0) {
            if (method == .GET) return backupDownload(send_buf, backup_id, path);
            if (method == .DELETE) return backupDelete(send_buf, backup_id);
        }
    }
    if (std.mem.eql(u8, api, "/restore") and method == .POST)
        return restoreInit(send_buf, now_ns);
    if (std.mem.startsWith(u8, api, "/restore/")) {
        const rest = api["/restore/".len..];
        if (std.mem.endsWith(u8, rest, "/apply") and method == .POST) {
            const restore_id = rest[0 .. rest.len - "/apply".len];
            if (restore_id.len > 0) return restoreApply(send_buf, store, restore_id);
        } else if (rest.len > 0 and method == .PUT) {
            return restoreUpload(send_buf, rest, body, path);
        }
    }

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
    w.fieldStr("version", version.string);
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
        w.fieldBool("cluster_mode", cfg.clusterMode());
        w.fieldBool("admin_password_set", cfg.admin_password.len > 0);
        w.fieldInt("purge_threshold", @as(i64, cfg.purge_threshold));
        w.fieldInt("purge_retention_ns", @as(i64, @intCast(cfg.purge_retention_ns)));
        w.fieldInt("worker_timeout_ns", @as(i64, @intCast(cfg.worker_timeout_ns)));
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

    if (!http.constantTimeEql(decoded, g_admin_password))
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
        const state_val: u8 = if (ci.is_leader.load(.acquire)) 2 else 0;

        pos += (std.fmt.bufPrint(
            body_buf[pos..],
            "# HELP corvo_cluster_state Node role (0=follower, 2=leader)\n" ++
                "# TYPE corvo_cluster_state gauge\n" ++
                "corvo_cluster_state {d}\n" ++
                "# HELP corvo_cluster_peers_total Number of cluster peers\n" ++
                "# TYPE corvo_cluster_peers_total gauge\n" ++
                "corvo_cluster_peers_total {d}\n",
            .{ state_val, ci.peer_count },
        ) catch &[0]u8{}).len;
    }

    return http.writeResponseText(send_buf, 200, body_buf[0..pos]);
}

fn clusterStatus(send_buf: []u8) u32 {
    var body_buf: [2048]u8 = undefined;
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

    const is_leader = ci.is_leader.load(.acquire);
    const state_str = if (is_leader) "leader" else "follower";

    w.beginObject();
    w.fieldStr("mode", "cluster");
    w.fieldStr("status", "healthy");
    w.fieldStr("state", state_str);
    w.fieldStr("node_id", ci.node_id);
    // Leader identity is not plumbed out of the raft host yet; a follower
    // reports only its own role. SDKs redial their peer set on
    // MSG_NOT_LEADER, and operators read state per node.
    w.fieldStr("leader", if (is_leader) ci.node_id else "");
    w.fieldInt("peer_count", ci.peer_count);
    w.endObject();
    return http.writeResponse(send_buf, 200, w.getWritten());
}


fn clusterEvents(send_buf: []u8) u32 {
    // Raft leadership events are not surfaced yet (the PBR event ring's
    // producer was removed with the PBR stack). Keep the endpoint shape so
    // UI/Console clients don't break; events return once the raft host
    // publishes transitions.
    var body_buf: [256]u8 = undefined;
    var w = json.JsonWriter.init(&body_buf);
    w.beginObject();
    w.beginArrayField("events");
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

    const text_filter = http.extractJSONString(body_input, "payload_contains");
    const queue_filter = http.extractJSONString(body_input, "queue");
    var state_strs: [8][]const u8 = undefined;
    const state_count = http.extractJSONStringArray(body_input, "state", &state_strs);
    const limit_val = http.extractJSONInt(body_input, "limit");
    const limit: u32 = if (limit_val) |l| @intCast(@min(@max(l, 1), 500)) else 100;
    const offset_val = http.extractJSONInt(body_input, "offset");
    const offset: u32 = if (offset_val) |o| @intCast(@max(o, 0)) else 0;

    var job_buf: [501]kv_read.JobRow = undefined;
    const fetch_limit = limit + 1; // +1 to detect has_more
    var count: u32 = 0;

    if (text_filter) |q| {
        count = reader.searchPayload(q, job_buf[0..fetch_limit]);
    } else if (state_count > 1) {
        // Multi-state: distribute global offset across states using counters.
        var skip_left: u32 = offset;
        for (0..state_count) |si| {
            const remaining = fetch_limit - count;
            if (remaining == 0) break;

            if (skip_left > 0) {
                const state_total: u32 = @intCast(@max(
                    if (queue_filter) |qf| reader.countJobsByQueueState(qf, state_strs[si]) else reader.countJobsByState(state_strs[si]),
                    0,
                ));
                if (state_total <= skip_left) {
                    skip_left -= state_total;
                    continue;
                }
            }

            count += reader.queryJobsByQueueState(queue_filter, state_strs[si], remaining, skip_left, job_buf[count..]);
            skip_left = 0;
        }
    } else {
        const state_filter = if (state_count > 0) state_strs[0] else null;
        count = reader.queryJobsByQueueState(queue_filter, state_filter, fetch_limit, offset, &job_buf);
    }

    var has_more = false;
    if (count > limit) {
        has_more = true;
        count = limit;
    }

    for (0..count) |i| writeJobRowSummary(&jw, &job_buf[i]);

    jw.endArray();
    jw.fieldInt("total", count);
    jw.fieldBool("has_more", has_more);
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn bulkGetJobs(send_buf: []u8, reader: *kv_read.Reader, body: []const u8) u32 {
    var id_buf: [100][]const u8 = undefined;
    const id_count = http.extractJSONStringArray(body, "job_ids", &id_buf);
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
// Backup / Restore
// ============================================================================

const backup_base_dir = "/tmp/corvo-backup-";
const max_chunk_size: u32 = 60000;

/// POST /api/v1/backup — checkpoint to temp dir, return backup metadata.
fn backupCreate(send_buf: []u8, store: *kv.Store, now_ns: u64) u32 {
    var id_buf: [32]u8 = undefined;
    const backup_id = std.fmt.bufPrint(&id_buf, "{d}", .{now_ns}) catch
        return writeError(send_buf, 500, "id_format_failed");

    var dir_buf: [128]u8 = undefined;
    const snap_dir = std.fmt.bufPrint(&dir_buf, "{s}{s}", .{ backup_base_dir, backup_id }) catch
        return writeError(send_buf, 500, "backup_id_too_long");

    store.db.checkpoint(snap_dir) catch
        return writeError(send_buf, 500, "checkpoint_failed");

    // Stat the checkpoint files for total_bytes.
    const db_size = fileSize(snap_dir, "talon.db");
    const vlog_size = fileSize(snap_dir, "talon.vlog");
    const total_bytes = db_size + vlog_size;

    var body_buf: [512]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldStr("backup_id", backup_id);
    jw.fieldInt("total_bytes", @as(i64, @intCast(total_bytes)));
    jw.fieldInt("db_bytes", @as(i64, @intCast(db_size)));
    jw.fieldInt("vlog_bytes", @as(i64, @intCast(vlog_size)));
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

/// GET /api/v1/backup/{id}?file=talon.db&offset=0&length=60000 — download chunk.
fn backupDownload(send_buf: []u8, backup_id: []const u8, path: []const u8) u32 {
    const file_name = http.extractQueryParam(path, "file") orelse
        return writeError(send_buf, 400, "file_param_required");
    if (!std.mem.eql(u8, file_name, "talon.db") and !std.mem.eql(u8, file_name, "talon.vlog"))
        return writeError(send_buf, 400, "invalid_file");

    const offset = blk: {
        const s = http.extractQueryParam(path, "offset") orelse break :blk @as(u64, 0);
        break :blk std.fmt.parseInt(u64, s, 10) catch break :blk @as(u64, 0);
    };
    const length = blk: {
        const s = http.extractQueryParam(path, "length") orelse break :blk max_chunk_size;
        const v = std.fmt.parseInt(u32, s, 10) catch break :blk max_chunk_size;
        break :blk @min(v, max_chunk_size);
    };

    var dir_buf: [128]u8 = undefined;
    const snap_dir = std.fmt.bufPrint(&dir_buf, "{s}{s}", .{ backup_base_dir, backup_id }) catch
        return writeError(send_buf, 400, "invalid_backup_id");

    var path_buf: [192]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ snap_dir, file_name }) catch
        return writeError(send_buf, 500, "path_too_long");

    const file = std.fs.cwd().openFile(file_path, .{}) catch
        return writeError(send_buf, 404, "backup_not_found");
    defer file.close();

    file.seekTo(offset) catch return writeError(send_buf, 500, "seek_failed");

    // Write HTTP headers first, then read file data directly after.
    var stream = std.io.fixedBufferStream(send_buf);
    const w = stream.writer();
    // We need Content-Length, so read into a temp area first.
    const header_max: u32 = 256;
    const body_space = @as(u32, @intCast(send_buf.len)) - header_max;
    const read_len = @min(length, body_space);
    var chunk_buf: [60000]u8 = undefined;
    const actual_read = @min(read_len, @as(u32, @intCast(chunk_buf.len)));
    const n = file.readAll(chunk_buf[0..actual_read]) catch return writeError(send_buf, 500, "read_failed");

    w.print("HTTP/1.1 200 OK\r\n", .{}) catch return 0;
    w.print("Content-Type: application/octet-stream\r\n", .{}) catch return 0;
    w.print("Content-Length: {d}\r\n", .{n}) catch return 0;
    w.writeAll("Connection: keep-alive\r\n") catch return 0;
    w.writeAll("Access-Control-Allow-Origin: *\r\n") catch return 0;
    w.writeAll("\r\n") catch return 0;
    w.writeAll(chunk_buf[0..n]) catch return 0;

    return @intCast(stream.pos);
}

/// DELETE /api/v1/backup/{id} — cleanup temp directory.
fn backupDelete(send_buf: []u8, backup_id: []const u8) u32 {
    var dir_buf: [128]u8 = undefined;
    const snap_dir = std.fmt.bufPrint(&dir_buf, "{s}{s}", .{ backup_base_dir, backup_id }) catch
        return writeError(send_buf, 400, "invalid_backup_id");
    std.fs.cwd().deleteTree(snap_dir) catch {};
    return http.writeResponse(send_buf, 200, "{\"status\":\"deleted\"}");
}

/// POST /api/v1/restore — init restore, create temp dir, return restore_id.
fn restoreInit(send_buf: []u8, now_ns: u64) u32 {
    var id_buf: [32]u8 = undefined;
    const restore_id = std.fmt.bufPrint(&id_buf, "{d}", .{now_ns}) catch
        return writeError(send_buf, 500, "id_format_failed");

    var dir_buf: [128]u8 = undefined;
    const restore_dir = std.fmt.bufPrint(&dir_buf, "/tmp/corvo-restore-{s}", .{restore_id}) catch
        return writeError(send_buf, 500, "restore_id_too_long");
    std.fs.cwd().makePath(restore_dir) catch
        return writeError(send_buf, 500, "mkdir_failed");

    var body_buf: [256]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldStr("restore_id", restore_id);
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

/// PUT /api/v1/restore/{id}?file=talon.db&offset=0 — upload chunk.
fn restoreUpload(send_buf: []u8, restore_id: []const u8, body: []const u8, path: []const u8) u32 {
    const file_name = http.extractQueryParam(path, "file") orelse
        return writeError(send_buf, 400, "file_param_required");
    if (!std.mem.eql(u8, file_name, "talon.db") and !std.mem.eql(u8, file_name, "talon.vlog"))
        return writeError(send_buf, 400, "invalid_file");

    const offset = blk: {
        const s = http.extractQueryParam(path, "offset") orelse break :blk @as(u64, 0);
        break :blk std.fmt.parseInt(u64, s, 10) catch break :blk @as(u64, 0);
    };

    var dir_buf: [128]u8 = undefined;
    const restore_dir = std.fmt.bufPrint(&dir_buf, "/tmp/corvo-restore-{s}", .{restore_id}) catch
        return writeError(send_buf, 400, "invalid_restore_id");

    var path_buf: [192]u8 = undefined;
    const file_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ restore_dir, file_name }) catch
        return writeError(send_buf, 500, "path_too_long");

    // Open or create the file, write the chunk at the given offset.
    const file = std.fs.cwd().createFile(file_path, .{ .truncate = false }) catch
        return writeError(send_buf, 500, "create_failed");
    defer file.close();
    file.seekTo(offset) catch return writeError(send_buf, 500, "seek_failed");
    file.writeAll(body) catch return writeError(send_buf, 500, "write_failed");

    var body_buf: [128]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.fieldInt("bytes_written", @as(i64, @intCast(body.len)));
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

/// POST /api/v1/restore/{id}/apply — live restore from uploaded files.
fn restoreApply(send_buf: []u8, store: *kv.Store, restore_id: []const u8) u32 {
    var dir_buf: [128]u8 = undefined;
    const restore_dir = std.fmt.bufPrint(&dir_buf, "/tmp/corvo-restore-{s}", .{restore_id}) catch
        return writeError(send_buf, 400, "invalid_restore_id");

    store.db.restore(restore_dir) catch
        return writeError(send_buf, 500, "restore_failed");

    // Cleanup temp files.
    std.fs.cwd().deleteTree(restore_dir) catch {};

    return http.writeResponse(send_buf, 200, "{\"status\":\"restored\"}");
}

fn fileSize(dir: []const u8, name: []const u8) u64 {
    var path_buf: [192]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return 0;
    const file = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer file.close();
    const stat = file.stat() catch return 0;
    return stat.size;
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
// Tests
// ============================================================================

const talon = @import("talon");
const testing = std.testing;

test "backup and restore round-trip" {
    // Use page_allocator for the DB — talon's restore() replaces internal
    // structures without freeing the old ones, which trips testing.allocator's
    // leak detector. This is a known talon limitation, not a corvo bug.
    const allocator = std.heap.page_allocator;

    const db_path = "/tmp/corvo-test-backup-rt";
    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};
    const db = try talon.DB.open(allocator, db_path, .{ .sync = false });
    defer db.close();
    var store = kv.Store.init(db);

    // Write a known key.
    var batch = store.newBatch();
    batch.set("test-key", "original-value");
    batch.commit();
    batch.close();

    // Backup via HTTP handler with deterministic clock.
    var send_buf: [65536]u8 = undefined;
    const backup_ns: u64 = 1000000;
    const create_len = backupCreate(&send_buf, &store, backup_ns);
    try testing.expect(create_len > 0);

    // Copy backup_id out of send_buf before it gets reused.
    const resp = send_buf[0..create_len];
    const body_start = std.mem.indexOf(u8, resp, "\r\n\r\n").? + 4;
    var backup_id_buf: [32]u8 = undefined;
    const backup_id_src = http.extractJSONString(resp[body_start..], "backup_id").?;
    @memcpy(backup_id_buf[0..backup_id_src.len], backup_id_src);
    const backup_id = backup_id_buf[0..backup_id_src.len];

    var snap_dir_buf: [128]u8 = undefined;
    const snap_dir = try std.fmt.bufPrint(&snap_dir_buf, "{s}{s}", .{ backup_base_dir, backup_id });
    defer std.fs.cwd().deleteTree(snap_dir) catch {};

    // Overwrite data to prove restore works.
    var batch2 = store.newBatch();
    batch2.set("test-key", "overwritten");
    batch2.commit();
    batch2.close();

    var read_batch = store.newBatch();
    try testing.expectEqualStrings("overwritten", read_batch.get("test-key").?);
    read_batch.close();

    // Init restore with a different clock value.
    const restore_ns: u64 = 2000000;
    const init_len = restoreInit(&send_buf, restore_ns);
    try testing.expect(init_len > 0);

    // Copy restore_id out of send_buf.
    const init_body_start = std.mem.indexOf(u8, send_buf[0..init_len], "\r\n\r\n").? + 4;
    var restore_id_buf: [32]u8 = undefined;
    const restore_id_src = http.extractJSONString(send_buf[init_body_start..init_len], "restore_id").?;
    @memcpy(restore_id_buf[0..restore_id_src.len], restore_id_src);
    const restore_id = restore_id_buf[0..restore_id_src.len];

    var restore_dir_buf: [128]u8 = undefined;
    const restore_dir = try std.fmt.bufPrint(&restore_dir_buf, "/tmp/corvo-restore-{s}", .{restore_id});
    defer std.fs.cwd().deleteTree(restore_dir) catch {};

    // Upload backup files to restore dir via HTTP handler.
    for ([_][]const u8{ "talon.db", "talon.vlog" }) |fname| {
        var src_path_buf: [192]u8 = undefined;
        const src_path = try std.fmt.bufPrint(&src_path_buf, "{s}/{s}", .{ snap_dir, fname });
        const src_file = try std.fs.cwd().openFile(src_path, .{});
        defer src_file.close();
        const src_stat = try src_file.stat();

        var offset: u64 = 0;
        var file_buf: [4096]u8 = undefined;
        while (offset < src_stat.size) {
            const n = try src_file.read(&file_buf);
            if (n == 0) break;
            var upload_path_buf: [256]u8 = undefined;
            const upload_path = try std.fmt.bufPrint(&upload_path_buf, "/api/v1/restore/{s}?file={s}&offset={d}", .{ restore_id, fname, offset });
            const ul_len = restoreUpload(&send_buf, restore_id, file_buf[0..n], upload_path);
            try testing.expect(ul_len > 0);
            try testing.expect(std.mem.startsWith(u8, send_buf[0..ul_len], "HTTP/1.1 200"));
            offset += n;
        }

        // Verify uploaded file matches source size.
        var dst_path_buf: [192]u8 = undefined;
        const dst_path = try std.fmt.bufPrint(&dst_path_buf, "{s}/{s}", .{ restore_dir, fname });
        const dst_stat = try std.fs.cwd().statFile(dst_path);
        try testing.expectEqual(src_stat.size, dst_stat.size);
    }

    // Apply restore via HTTP handler.
    const apply_len = restoreApply(&send_buf, &store, restore_id);
    try testing.expect(apply_len > 0);
    try testing.expect(std.mem.startsWith(u8, send_buf[0..apply_len], "HTTP/1.1 200"));

    // Verify original data is back.
    var read_batch2 = store.newBatch();
    try testing.expectEqualStrings("original-value", read_batch2.get("test-key").?);
    read_batch2.close();
}

test "backup download chunked" {
    const allocator = testing.allocator;

    const db_path = "/tmp/corvo-test-backup-dl";
    std.fs.cwd().deleteTree(db_path) catch {};
    defer std.fs.cwd().deleteTree(db_path) catch {};
    const db = try talon.DB.open(allocator, db_path, .{ .sync = false });
    defer db.close();
    var store = kv.Store.init(db);

    // Write data so files aren't empty.
    var batch = store.newBatch();
    batch.set("k1", "v1");
    batch.commit();
    batch.close();

    // Create backup.
    var send_buf: [65536]u8 = undefined;
    const create_len = backupCreate(&send_buf, &store, 3000000);
    try testing.expect(create_len > 0);

    // Copy backup_id out of send_buf.
    const resp = send_buf[0..create_len];
    const body_start = std.mem.indexOf(u8, resp, "\r\n\r\n").? + 4;
    var backup_id_buf: [32]u8 = undefined;
    const backup_id_src = http.extractJSONString(resp[body_start..], "backup_id").?;
    @memcpy(backup_id_buf[0..backup_id_src.len], backup_id_src);
    const backup_id = backup_id_buf[0..backup_id_src.len];

    defer _ = backupDelete(&send_buf, backup_id);

    // Download first chunk of talon.db.
    var path_buf: [256]u8 = undefined;
    const dl_path = std.fmt.bufPrint(&path_buf, "/api/v1/backup/{s}?file=talon.db&offset=0&length=1024", .{backup_id}) catch unreachable;
    const dl_len = backupDownload(&send_buf, backup_id, dl_path);
    try testing.expect(dl_len > 0);
    try testing.expect(std.mem.startsWith(u8, send_buf[0..dl_len], "HTTP/1.1 200"));
    try testing.expect(std.mem.indexOf(u8, send_buf[0..dl_len], "application/octet-stream") != null);
}

