//! HTTP read handlers — query SQLite mirror, build JSON, write HTTP response.
//!
//! Pure functions: take send_buf + reader, return response length.
//! No IO, no pipeline, no state. Pipeline calls these and queues the send.

const std = @import("std");
const http = @import("http.zig");
const json = @import("json_writer.zig");
const sqlite_read = @import("sqlite_read.zig");

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
    reader: ?*sqlite_read.Reader,
) u32 {
    // Strip query string for route matching.
    const clean = if (std.mem.indexOfScalar(u8, path, '?')) |qi| path[0..qi] else path;

    if (!std.mem.startsWith(u8, clean, "/api/v1/")) return 0;
    const api = clean["/api/v1".len..];

    // Static routes (no mirror needed).
    if (std.mem.eql(u8, api, "/info"))
        return http.writeResponse(send_buf, 200, "{\"version\":\"0.1.0b\",\"engine\":\"zig\"}");
    if (std.mem.eql(u8, api, "/debug/runtime")) return debugRuntime(send_buf);
    if (std.mem.eql(u8, api, "/cluster/status"))
        return http.writeResponse(send_buf, 200, "{\"mode\":\"standalone\",\"status\":\"healthy\",\"state\":\"leader\",\"node_id\":\"node-1\",\"leader\":\"node-1\"}");

    const rdr = reader orelse return writeError(send_buf, 503, "no_mirror");

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
    if (std.mem.eql(u8, api, "/approval-policies")) return approvalPolicies(send_buf, rdr);

    return writeError(send_buf, 404, "not found");
}

// ============================================================================
// Metrics (special — text/plain, not JSON)
// ============================================================================

pub fn metrics(send_buf: []u8, mirror_stats: ?MirrorStats, reader: ?*sqlite_read.Reader) u32 {
    var body_buf: [32768]u8 = undefined;
    var pos: usize = 0;

    if (mirror_stats) |ms| {
        const lag = ms.queued -| ms.committed;
        pos += (std.fmt.bufPrint(
            body_buf[pos..],
            "# HELP corvo_mirror_queued_total Total operations queued to mirror\n" ++
                "# TYPE corvo_mirror_queued_total counter\n" ++
                "corvo_mirror_queued_total {d}\n" ++
                "# HELP corvo_mirror_committed_total Total operations committed to SQLite\n" ++
                "# TYPE corvo_mirror_committed_total counter\n" ++
                "corvo_mirror_committed_total {d}\n" ++
                "# HELP corvo_mirror_dropped_total Operations dropped due to full queue\n" ++
                "# TYPE corvo_mirror_dropped_total counter\n" ++
                "corvo_mirror_dropped_total {d}\n" ++
                "# HELP corvo_mirror_lag Operations pending in mirror queue\n" ++
                "# TYPE corvo_mirror_lag gauge\n" ++
                "corvo_mirror_lag {d}\n",
            .{ ms.queued, ms.committed, ms.dropped, lag },
        ) catch &[0]u8{}).len;
    }

    if (reader) |rdr| {
        var stats_buf: [64]sqlite_read.QueueStats = undefined;
        const qcount = rdr.getQueueStats(&stats_buf) catch 0;
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
                }) |pair| {
                    pos += (std.fmt.bufPrint(
                        body_buf[pos..],
                        "corvo_queue_jobs{{queue=\"{s}\",state=\"{s}\"}} {d}\n",
                        .{ qn, pair[0], pair[1] },
                    ) catch break).len;
                }
            }
        }

        const wcount = rdr.countWorkers() catch 0;
        pos += (std.fmt.bufPrint(
            body_buf[pos..],
            "# HELP corvo_workers_registered Number of registered workers\n" ++
                "# TYPE corvo_workers_registered gauge\n" ++
                "corvo_workers_registered {d}\n",
            .{wcount},
        ) catch &[0]u8{}).len;
    }

    return http.writeResponseText(send_buf, 200, body_buf[0..pos]);
}

pub const MirrorStats = struct {
    queued: u64,
    committed: u64,
    dropped: u64,
};

// ============================================================================
// Individual read handlers
// ============================================================================

fn queues(send_buf: []u8, reader: *sqlite_read.Reader) u32 {
    var queue_buf: [64]sqlite_read.QueueStats = undefined;
    const count = reader.getQueueStats(&queue_buf) catch return writeError(send_buf, 500, "query_failed");

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
        jw.fieldInt("completed", q.completed);
        jw.fieldInt("scheduled", q.scheduled);
        jw.fieldBool("paused", q.paused);
        jw.endObject();
    }
    jw.endArray();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn workers(send_buf: []u8, reader: *sqlite_read.Reader) u32 {
    var worker_buf: [64]sqlite_read.WorkerRow = undefined;
    const count = reader.getWorkers(&worker_buf) catch return writeError(send_buf, 500, "query_failed");

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

fn crons(send_buf: []u8, reader: *sqlite_read.Reader) u32 {
    var cron_buf: [64]sqlite_read.CronRow = undefined;
    const count = reader.listCrons(&cron_buf) catch return writeError(send_buf, 500, "query_failed");

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

fn cron(send_buf: []u8, reader: *sqlite_read.Reader, cron_id: []const u8) u32 {
    const cr = (reader.getCron(cron_id) catch return writeError(send_buf, 500, "query_failed")) orelse
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

fn job(send_buf: []u8, reader: *sqlite_read.Reader, job_id: []const u8) u32 {
    const j = (reader.getJob(job_id) catch return writeError(send_buf, 500, "query_failed")) orelse
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

    if (j.created_at_len > 0) jw.fieldStr("created_at", j.createdAtSlice());
    if (j.started_at_len > 0) jw.fieldStr("started_at", j.startedAtSlice());
    if (j.completed_at_len > 0) jw.fieldStr("completed_at", j.completedAtSlice());
    if (j.failed_at_len > 0) jw.fieldStr("failed_at", j.failedAtSlice());
    if (j.scheduled_at_len > 0) jw.fieldStr("scheduled_at", j.scheduledAtSlice());
    if (j.lease_expires_at_len > 0) jw.fieldStr("lease_expires_at", j.leaseExpiresAtSlice());

    var err_buf: [32]sqlite_read.JobError = undefined;
    const err_count = reader.getJobErrors(job_id, &err_buf) catch 0;
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

fn search(send_buf: []u8, reader: *sqlite_read.Reader, path: []const u8) u32 {
    const query_str = http.extractQueryParam(path, "q") orelse
        return writeError(send_buf, 400, "q parameter is required");
    if (query_str.len == 0) return writeError(send_buf, 400, "q parameter is required");

    var result_buf: [100]sqlite_read.JobRow = undefined;
    const count = reader.searchJobs(query_str, &result_buf) catch blk: {
        break :blk reader.searchJobsLike(query_str, &result_buf) catch 0;
    };

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

fn jobSearch(send_buf: []u8, reader: *sqlite_read.Reader, path: []const u8) u32 {
    const query_str = http.extractQueryParam(path, "q");

    var body_buf: [32768]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginObject();
    jw.beginArrayField("jobs");

    if (query_str) |q| {
        var result_buf: [100]sqlite_read.JobRow = undefined;
        const count = reader.searchJobs(q, &result_buf) catch blk: {
            break :blk reader.searchJobsLike(q, &result_buf) catch 0;
        };
        for (0..count) |i| writeJobRowSummary(&jw, &result_buf[i]);
    } else {
        var job_buf: [100]sqlite_read.JobRow = undefined;
        const count = reader.getJobs(&job_buf) catch 0;
        for (0..count) |i| writeJobRowSummary(&jw, &job_buf[i]);
    }

    jw.endArray();
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn jobSearchPost(send_buf: []u8, reader: *sqlite_read.Reader, body_input: []const u8) u32 {
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

    var job_buf: [100]sqlite_read.JobRow = undefined;
    const actual_limit = @min(limit, @as(u32, @intCast(job_buf.len)));
    var count: u32 = 0;

    if (text_filter) |q| {
        count = reader.searchJobs(q, job_buf[0..actual_limit]) catch blk: {
            break :blk reader.searchJobsLike(q, job_buf[0..actual_limit]) catch 0;
        };
    } else {
        count = reader.queryJobsByQueueState(queue_filter, state_filter, actual_limit, 0, &job_buf) catch 0;
    }

    for (0..count) |i| writeJobRowSummary(&jw, &job_buf[i]);

    jw.endArray();
    jw.fieldInt("total", count);
    jw.fieldBool("has_more", false);
    jw.endObject();
    return http.writeResponse(send_buf, 200, jw.getWritten());
}

fn budgets(send_buf: []u8, reader: *sqlite_read.Reader) u32 {
    var budget_buf: [64]sqlite_read.BudgetRow = undefined;
    const count = reader.listBudgets(&budget_buf) catch return writeError(send_buf, 500, "query_failed");

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

fn apiKeys(send_buf: []u8, reader: *sqlite_read.Reader) u32 {
    var key_buf: [100]sqlite_read.ApiKeyRow = undefined;
    const count = reader.listApiKeys(&key_buf) catch return writeError(send_buf, 500, "query_failed");

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

fn approvalPolicies(send_buf: []u8, reader: *sqlite_read.Reader) u32 {
    var policy_buf: [64]sqlite_read.ApprovalPolicyRow = undefined;
    const count = reader.listApprovalPolicies(&policy_buf) catch return writeError(send_buf, 500, "query_failed");

    var body_buf: [16384]u8 = undefined;
    var jw = json.JsonWriter.init(&body_buf);
    jw.beginArray();
    for (0..count) |i| {
        const row = &policy_buf[i];
        jw.beginObject();
        jw.fieldStr("id", row.idSlice());
        jw.fieldStr("name", row.nameSlice());
        jw.fieldStr("mode", row.modeSlice());
        jw.fieldBool("enabled", row.enabled);
        jw.fieldStr("queue", row.queueSlice());
        jw.fieldStr("tag_key", row.tagKeySlice());
        jw.fieldStr("tag_value", row.tagValueSlice());
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

fn writeJobRowSummary(jw: *json.JsonWriter, j: *const sqlite_read.JobRow) void {
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
