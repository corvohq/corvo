//! Server-rendered HTML UI — HTMX + Tailwind CSS dashboard.
//!
//! Page structure lives in ui/templates/*.html files.
//! Zig code renders only dynamic content (data tables, stats, charts) and
//! splices it into templates via {{placeholder}} substitution.

const std = @import("std");
const zigstache = @import("zigstache");
const http = @import("http.zig");
const kv_read = @import("kv_read.zig");
const ui_embed = @import("ui_embed");

/// Whether admin password auth is enabled (set by main.zig).
pub var g_auth_enabled: bool = false;

/// Whether enterprise mode is active (set by enterprise main.zig).
/// Controls sidebar nav visibility for enterprise links.
pub var g_enterprise: bool = false;

/// Enterprise UI dispatch hook — set by enterprise binary at startup.
/// Called for UI paths not matched by core. Returns response length, or null for 404.
pub var ent_ui_dispatch: ?*const fn ([]const u8, []const u8, []u8, ?*kv_read.Reader) ?u32 = null;

/// Max HTML body size. Pages render into a buffer of this size.
/// Mustache templates with dark mode classes + inline SVG icons need headroom.
/// send_buf is 64KB (IO layer — do not change). Layout ~8KB + HTTP headers ~200B.
/// page_buf must fit within send_buf after layout wrapping.
const send_buf_size = 65536;
const layout_overhead = 8400;
pub const page_buf_size = send_buf_size - layout_overhead;
const render_buf_size = send_buf_size - 200;

/// Max table rows per page.
const max_table_rows = 25;

comptime {
    std.debug.assert(page_buf_size + layout_overhead <= send_buf_size);
    std.debug.assert(render_buf_size < send_buf_size);
}

/// Comptime-parsed Mustache templates.
const layout_tmpl = zigstache.Template.parse(ui_embed.layout_html) catch unreachable;
const dashboard_tmpl = zigstache.Template.parse(ui_embed.dashboard_html) catch unreachable;
const dashboard_stats_tmpl = zigstache.Template.parse(ui_embed.dashboard_stats_html) catch unreachable;
const queues_tmpl = zigstache.Template.parse(ui_embed.queues_html) catch unreachable;
const queues_table_tmpl = zigstache.Template.parse(ui_embed.queues_table_html) catch unreachable;
const queue_detail_tmpl = zigstache.Template.parse(ui_embed.queue_detail_html) catch unreachable;
const job_list_tmpl = zigstache.Template.parse(ui_embed.job_list_html) catch unreachable;
const job_table_tmpl = zigstache.Template.parse(ui_embed.job_table_html) catch unreachable;
const job_detail_tmpl = zigstache.Template.parse(ui_embed.job_detail_html) catch unreachable;
const workers_tmpl = zigstache.Template.parse(ui_embed.workers_html) catch unreachable;
const pagination_tmpl = zigstache.Template.parse(ui_embed.pagination_html) catch unreachable;
const login_tmpl = zigstache.Template.parse(ui_embed.login_html) catch unreachable;
const api_keys_tmpl = zigstache.Template.parse(ui_embed.api_keys_html) catch unreachable;

// ============================================================================
// Dispatch
// ============================================================================

/// Route a UI page request. Returns bytes written to send_buf.
pub fn dispatch(path: []const u8, query: []const u8, send_buf: []u8, reader: ?*kv_read.Reader) u32 {
    // Login page (standalone, no layout).
    if (eql(path, "/login")) return loginPage(send_buf, query);

    // Full page routes.
    if (eql(path, "/") or eql(path, "")) return dashboard(send_buf, reader);
    if (eql(path, "/queues")) return queuesPage(send_buf, reader);
    if (std.mem.startsWith(u8, path, "/queues/")) return queueDetailPage(send_buf, reader, path["/queues/".len..], query);
    if (eql(path, "/dead-letter")) return deadLetterPage(send_buf, reader, query);
    if (eql(path, "/held")) return heldJobsPage(send_buf, reader, query);
    if (eql(path, "/scheduled")) return scheduledJobsPage(send_buf, reader, query);
    if (std.mem.startsWith(u8, path, "/jobs/")) return jobDetailPage(send_buf, reader, path["/jobs/".len..]);
    if (eql(path, "/workers")) return workersPage(send_buf, reader);
    if (eql(path, "/cluster")) return clusterPage(send_buf, reader);
    if (eql(path, "/api-keys")) return apiKeysPage(send_buf, reader);

    // HTMX partial routes (fragments, no layout).
    if (eql(path, "/partials/dashboard-stats")) return dashboardStatsPartial(send_buf, reader);
    if (eql(path, "/partials/queues-table")) return queuesTablePartial(send_buf, reader);
    if (eql(path, "/partials/enqueue-form")) return enqueueFormPartial(send_buf);

    if (ent_ui_dispatch) |ent_dispatch| {
        if (ent_dispatch(path, query, send_buf, reader)) |n| return n;
    }

    return http.writeResponseHtml(send_buf, 404, "<h1>Not Found</h1>");
}

// ============================================================================
// Template Engine
// ============================================================================

/// Splice title and content into the layout template, then write the HTTP response.
pub fn renderPage(send_buf: []u8, title: []const u8, content: []const u8) u32 {
    var buf: [render_buf_size]u8 = undefined;
    const rendered = layout_tmpl.render(&buf, .{
        .title = title,
        .content = content,
        .show_logout = g_auth_enabled,
        .enterprise = g_enterprise,
    }) catch |err| switch (err) {
        error.BufferOverflow => return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>"),
    };
    return http.writeResponseHtml(send_buf, 200, rendered);
}

// ============================================================================
// Login Page (standalone — no layout wrapper)
// ============================================================================

fn loginPage(send_buf: []u8, query: []const u8) u32 {
    const has_error = getQueryParam(query, "error") != null;
    var buf: [render_buf_size]u8 = undefined;
    const rendered = login_tmpl.render(&buf, .{ .has_error = has_error }) catch
        return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return http.writeResponseHtml(send_buf, 200, rendered);
}

// ============================================================================
// Full Pages
// ============================================================================

fn dashboard(send_buf: []u8, reader: ?*kv_read.Reader) u32 {
    var queue_buf: [64]kv_read.QueueStats = undefined;
    var queue_views: [64]QueueView = undefined;
    var bar_buf: [64]BarView = undefined;
    var job_buf: [10]kv_read.JobRow = undefined;
    var failure_views: [10]FailureView = undefined;

    const has_data = reader != null;
    const queues = getQueueViews(reader, &queue_buf, &queue_views);

    var total_pending: i64 = 0;
    var total_active: i64 = 0;
    var total_dead: i64 = 0;
    for (queue_buf[0..queues.len]) |q| {
        total_pending += q.pending;
        total_active += q.active;
        total_dead += q.dead;
    }
    const worker_count: i32 = if (reader) |rdr| rdr.countWorkers() else 0;
    const bars = if (queues.len > 0) buildBarViews(queue_buf[0..queues.len], &bar_buf) else bar_buf[0..0];
    const failures = if (reader) |rdr| getFailureViews(rdr, &job_buf, &failure_views) else failure_views[0..0];

    const data = .{
        .has_data = has_data,
        .total_pending = total_pending,
        .total_active = total_active,
        .total_dead = total_dead,
        .queue_count = @as(i64, @intCast(queues.len)),
        .worker_count = worker_count,
        .has_bars = queues.len > 0,
        .chart_w = @as(u32, 600),
        .chart_total_h = @as(u32, 190),
        .bars = bars,
        .has_failures = failures.len > 0,
        .failures = failures,
        .has_queues = queues.len > 0,
        .queues = queues,
    };

    var content_buf: [page_buf_size]u8 = undefined;
    const content = dashboard_tmpl.renderWithPartials(&content_buf, data, .{
        .stats = &dashboard_stats_tmpl,
        .queues_table = &queues_table_tmpl,
    }) catch return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, "Dashboard", content);
}

fn queuesPage(send_buf: []u8, reader: ?*kv_read.Reader) u32 {
    var queue_buf: [64]kv_read.QueueStats = undefined;
    var views: [64]QueueView = undefined;
    const queues = getQueueViews(reader, &queue_buf, &views);

    var content_buf: [page_buf_size]u8 = undefined;
    const content = queues_tmpl.renderWithPartials(&content_buf, .{
        .queues = queues,
    }, .{ .table = &queues_table_tmpl }) catch
        return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, "Queues", content);
}

fn queueDetailPage(send_buf: []u8, reader: ?*kv_read.Reader, queue_name: []const u8, query: []const u8) u32 {
    const state_filter = getQueryParam(query, "state");
    const tag_key = getQueryParam(query, "tag_key");
    const tag_value = getQueryParam(query, "tag_value");
    const has_tag_search = tag_key != null and tag_value != null and tag_key.?.len > 0 and tag_value.?.len > 0;
    const page = parsePageParam(query);
    const offset: u32 = page * max_table_rows;

    // Find this queue's stats.
    var queue_stats_buf: [64]kv_read.QueueStats = undefined;
    var qs: ?*const kv_read.QueueStats = null;
    if (reader) |rdr| {
        const q_count = rdr.getQueueStats(&queue_stats_buf);
        for (0..q_count) |i| {
            if (eql(queue_stats_buf[i].nameSlice(), queue_name)) {
                qs = &queue_stats_buf[i];
                break;
            }
        }
    }
    const paused = if (qs) |q| q.paused else false;

    // Filter tabs — preserve tag params in URLs.
    const filter_states = [_]?[]const u8{ null, "pending", "active", "retrying", "dead", "completed", "scheduled", "held" };
    const filter_labels = [_][]const u8{ "All", "Pending", "Active", "Retrying", "Dead", "Completed", "Scheduled", "Held" };
    var tab_url_bufs: [8][256]u8 = undefined;
    var filter_tabs: [8]FilterTabView = undefined;
    for (filter_states, filter_labels, 0..) |fs, fl, i| {
        var s = std.io.fixedBufferStream(&tab_url_bufs[i]);
        s.writer().print("/ui/queues/{s}", .{queue_name}) catch {};
        if (fs) |state| s.writer().print("?state={s}", .{state}) catch {};
        if (has_tag_search) {
            const sep: []const u8 = if (fs != null) "&" else "?";
            s.writer().print("{s}tag_key={s}&tag_value={s}", .{ sep, tag_key.?, tag_value.? }) catch {};
        }
        const is_active = if (fs) |st| (if (state_filter) |cf| eql(st, cf) else false) else state_filter == null;
        filter_tabs[i] = .{
            .href = s.getWritten(),
            .label = fl,
            .count = if (qs) |q| filterCount(q, fs) else 0,
            .tab_class = if (is_active) active_tab_class else inactive_tab_class,
        };
    }

    // Job views — use tag search or standard query.
    var job_buf: [max_table_rows]kv_read.JobRow = undefined;
    var job_views: [max_table_rows]JobView = undefined;
    var count: usize = 0;
    if (has_tag_search) {
        if (reader) |rdr| {
            count = rdr.searchByTag(tag_key.?, tag_value.?, queue_name, state_filter, &job_buf);
        }
    } else {
        if (reader) |rdr| {
            count = rdr.queryJobsByQueueState(queue_name, state_filter, max_table_rows, offset, &job_buf);
        }
    }
    const jobs = getJobViews(job_buf[0..count], &job_views, .queue_detail);

    var bulk_buf: [2]BulkAction = undefined;
    const bulk_actions = getBulkActions(.queue_detail, &bulk_buf);

    // Clear tag URL — preserves state filter only.
    var clear_tag_buf: [256]u8 = undefined;
    var clear_tag_s = std.io.fixedBufferStream(&clear_tag_buf);
    clear_tag_s.writer().print("/ui/queues/{s}", .{queue_name}) catch {};
    if (state_filter) |sf| clear_tag_s.writer().print("?state={s}", .{sf}) catch {};

    // Pagination.
    const total: u32 = if (has_tag_search) @intCast(count) else if (qs) |q| queueStateCount(q, state_filter) else 0;
    const total_pages = if (total > 0) (total + max_table_rows - 1) / max_table_rows else 1;
    var pag_base_buf: [256]u8 = undefined;
    var pag_base_s = std.io.fixedBufferStream(&pag_base_buf);
    pag_base_s.writer().print("/ui/queues/{s}?", .{queue_name}) catch {};
    if (state_filter) |sf| pag_base_s.writer().print("state={s}&", .{sf}) catch {};
    if (has_tag_search) pag_base_s.writer().print("tag_key={s}&tag_value={s}&", .{ tag_key.?, tag_value.? }) catch {};
    var nav_bufs: [4][256]u8 = undefined;
    var page_links: [10]PageLink = undefined;
    var page_url_bufs: [10][256]u8 = undefined;
    const base = pag_base_s.getWritten();
    const pag = buildPaginationData(base, page, total_pages, &nav_bufs, &page_links, &page_url_bufs);

    const tabs: []const FilterTabView = &filter_tabs;
    var content_buf: [page_buf_size]u8 = undefined;
    const content = queue_detail_tmpl.renderWithPartials(&content_buf, .{
        .queue_name = queue_name,
        .is_paused = paused,
        .export_state = if (state_filter) |sf| sf else "",
        .has_stats = qs != null,
        .pending = if (qs) |q| q.pending else @as(i32, 0),
        .active = if (qs) |q| q.active else @as(i32, 0),
        .dead = if (qs) |q| q.dead else @as(i32, 0),
        .completed = if (qs) |q| q.completed else @as(i32, 0),
        .filter_tabs = tabs,
        .tag_key = if (tag_key) |tk| tk else "",
        .tag_value = if (tag_value) |tv| tv else "",
        .has_tag_search = has_tag_search,
        .clear_tag_url = clear_tag_s.getWritten(),
        .has_bulk = true,
        .bulk_actions = bulk_actions,
        .has_jobs = count > 0,
        .jobs = jobs,
        .has_pages = pag.has_pages,
        .page_display = pag.page_display,
        .total_pages = pag.total_pages,
        .has_prev = pag.has_prev,
        .prev_url = pag.prev_url,
        .first_url = pag.first_url,
        .has_next = pag.has_next,
        .next_url = pag.next_url,
        .last_url = pag.last_url,
        .pages = pag.pages,
    }, .{ .job_table = &job_table_tmpl, .pagination = &pagination_tmpl }) catch
        return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, "Queue Detail", content);
}

fn deadLetterPage(send_buf: []u8, reader: ?*kv_read.Reader, query: []const u8) u32 {
    return jobListPage(send_buf, reader, "Dead Letter", "dead", .dead, "/ui/dead-letter", query);
}

fn heldJobsPage(send_buf: []u8, reader: ?*kv_read.Reader, query: []const u8) u32 {
    return jobListPage(send_buf, reader, "Held Jobs", "held", .held, "/ui/held", query);
}

fn scheduledJobsPage(send_buf: []u8, reader: ?*kv_read.Reader, query: []const u8) u32 {
    return jobListPage(send_buf, reader, "Scheduled Jobs", "scheduled", .scheduled, "/ui/scheduled", query);
}

fn jobListPage(send_buf: []u8, reader: ?*kv_read.Reader, title: []const u8, state: []const u8, actions: RowActions, base_path: []const u8, query: []const u8) u32 {
    const rdr = reader orelse return renderPage(send_buf, title, "<p class=\"text-zinc-500 dark:text-zinc-400\">No data available</p>");

    const page = parsePageParam(query);
    const queue_filter = getQueryParam(query, "queue");
    const offset: u32 = page * max_table_rows;

    // Total count for pagination.
    const total: u32 = @intCast(@max(if (queue_filter) |qf|
        rdr.countJobsByQueueState(qf, state)
    else
        rdr.countJobsByState(state), 0));
    const total_pages = if (total > 0) (total + max_table_rows - 1) / max_table_rows else 1;

    // Job views.
    var job_buf: [max_table_rows]kv_read.JobRow = undefined;
    var job_views: [max_table_rows]JobView = undefined;
    const count = rdr.queryJobsByQueueState(queue_filter, state, max_table_rows, offset, &job_buf);
    const jobs = getJobViews(job_buf[0..count], &job_views, actions);

    var bulk_buf: [2]BulkAction = undefined;
    const bulk_actions = getBulkActions(actions, &bulk_buf);

    // Pagination.
    var pag_base_buf: [256]u8 = undefined;
    var pag_base_s = std.io.fixedBufferStream(&pag_base_buf);
    pag_base_s.writer().print("{s}?", .{base_path}) catch {};
    if (queue_filter) |qf| pag_base_s.writer().print("queue={s}&", .{qf}) catch {};
    var nav_bufs: [4][256]u8 = undefined;
    var page_links: [10]PageLink = undefined;
    var page_url_bufs: [10][256]u8 = undefined;
    const base = pag_base_s.getWritten();
    const pag = buildPaginationData(base, page, total_pages, &nav_bufs, &page_links, &page_url_bufs);

    var content_buf: [page_buf_size]u8 = undefined;
    const content = job_list_tmpl.renderWithPartials(&content_buf, .{
        .export_state = state,
        .export_queue = if (queue_filter) |qf| qf else "",
        .has_bulk = actions != .none,
        .bulk_actions = bulk_actions,
        .has_jobs = count > 0,
        .jobs = jobs,
        .has_pages = pag.has_pages,
        .page_display = pag.page_display,
        .total_pages = pag.total_pages,
        .has_prev = pag.has_prev,
        .prev_url = pag.prev_url,
        .first_url = pag.first_url,
        .has_next = pag.has_next,
        .next_url = pag.next_url,
        .last_url = pag.last_url,
        .pages = pag.pages,
    }, .{ .job_table = &job_table_tmpl, .pagination = &pagination_tmpl }) catch
        return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, title, content);
}

fn jobDetailPage(send_buf: []u8, reader: ?*kv_read.Reader, job_id: []const u8) u32 {
    const rdr = reader orelse return renderPage(send_buf, "Job Detail", "<p class=\"text-zinc-500 dark:text-zinc-400\">No data available</p>");
    const j = rdr.getJob(job_id) orelse return renderPage(send_buf, "Job Detail", "<p class=\"text-red-500 dark:text-red-400\">Job not found</p>");

    // Properties.
    var props: [5]PropView = undefined;
    var prop_count: usize = 0;
    var pri_buf: [16]u8 = undefined;
    var attempt_buf: [16]u8 = undefined;

    var pri_s = std.io.fixedBufferStream(&pri_buf);
    pri_s.writer().print("{d}", .{j.priority}) catch {};
    var att_s = std.io.fixedBufferStream(&attempt_buf);
    att_s.writer().print("{d}/{d}", .{ j.attempt, j.max_retries }) catch {};

    props[0] = .{ .label = "Queue", .value = j.queueSlice() };
    props[1] = .{ .label = "State", .value = j.stateSlice() };
    props[2] = .{ .label = "Priority", .value = pri_s.getWritten() };
    props[3] = .{ .label = "Attempt", .value = att_s.getWritten() };
    prop_count = 4;
    if (j.worker_id_len > 0) {
        props[prop_count] = .{ .label = "Worker", .value = j.workerIdSlice() };
        prop_count += 1;
    }
    const parent_id = if (j.parent_id_len > 0) j.parentIdSlice() else "";

    // Timeline.
    var timeline: [5]TimelineView = undefined;
    var tl_count: usize = 0;
    if (j.created_at_len > 0) {
        timeline[tl_count] = .{ .label = "Created", .timestamp = j.createdAtSlice(), .dot_class = "bg-blue-500" };
        tl_count += 1;
    }
    if (j.scheduled_at_len > 0) {
        timeline[tl_count] = .{ .label = "Scheduled", .timestamp = j.scheduledAtSlice(), .dot_class = "bg-purple-500" };
        tl_count += 1;
    }
    if (j.started_at_len > 0) {
        timeline[tl_count] = .{ .label = "Started", .timestamp = j.startedAtSlice(), .dot_class = "bg-emerald-500" };
        tl_count += 1;
    }
    if (j.completed_at_len > 0) {
        timeline[tl_count] = .{ .label = "Completed", .timestamp = j.completedAtSlice(), .dot_class = "bg-zinc-500" };
        tl_count += 1;
    }
    if (j.failed_at_len > 0) {
        timeline[tl_count] = .{ .label = "Failed", .timestamp = j.failedAtSlice(), .dot_class = "bg-red-500" };
        tl_count += 1;
    }

    // Payload.
    var raw_payload: [4096]u8 = undefined;
    const payload = rdr.getJobPayload(job_id, &raw_payload);

    // Errors.
    var err_rows: [16]kv_read.JobError = undefined;
    const err_count = rdr.getJobErrors(job_id, &err_rows);
    var error_views: [16]ErrorView = undefined;
    for (0..err_count) |i| {
        const err = &err_rows[i];
        error_views[i] = .{
            .attempt = err.attempt,
            .message = err.errorSlice(),
            .created_at = err.created_at[0..err.created_at_len],
            .has_timestamp = err.created_at_len > 0,
        };
    }

    const properties: []const PropView = props[0..prop_count];
    const tl: []const TimelineView = timeline[0..tl_count];
    const errors: []const ErrorView = error_views[0..err_count];

    const state_str = j.stateSlice();
    const is_terminal = std.mem.eql(u8, state_str, "completed") or
        std.mem.eql(u8, state_str, "dead") or
        std.mem.eql(u8, state_str, "cancelled");
    const is_active = std.mem.eql(u8, state_str, "active");
    const is_held = std.mem.eql(u8, state_str, "held");
    const is_scheduled = std.mem.eql(u8, state_str, "scheduled");

    var content_buf: [page_buf_size]u8 = undefined;
    const content = job_detail_tmpl.render(&content_buf, .{
        .job_id = j.idSlice(),
        .state = state_str,
        .state_class = stateBadgeClassDark(state_str),
        .properties = properties,
        .timeline = tl,
        .has_payload = payload != null,
        .payload = if (payload) |p| p else "",
        .has_errors = err_count > 0,
        .errors = errors,
        .can_requeue = is_terminal,
        .can_promote = is_scheduled,
        .can_cancel = !is_terminal and !is_held,
        .can_delete = !is_active,
        .can_approve = is_held,
        .has_parent = parent_id.len > 0,
        .parent_id = parent_id,
    }) catch return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, "Job Detail", content);
}

fn workersPage(send_buf: []u8, reader: ?*kv_read.Reader) u32 {
    const WorkerView = struct {
        id: []const u8,
        hostname: []const u8,
        queues: []const u8,
        last_heartbeat: []const u8,
        started_at: []const u8,
    };

    var worker_buf: [64]kv_read.WorkerRow = undefined;
    const count: usize = if (reader) |rdr| rdr.getWorkers(&worker_buf) else 0;

    var views: [64]WorkerView = undefined;
    for (0..count) |i| {
        const wk = &worker_buf[i];
        views[i] = .{
            .id = wk.idSlice(),
            .hostname = wk.hostnameSlice(),
            .queues = wk.queuesSlice(),
            .last_heartbeat = wk.lastHeartbeatSlice(),
            .started_at = wk.startedAtSlice(),
        };
    }

    var content_buf: [page_buf_size]u8 = undefined;
    const workers: []const WorkerView = views[0..count];
    const content = workers_tmpl.render(&content_buf, .{
        .workers = workers,
    }) catch return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, "Workers", content);
}

fn clusterPage(send_buf: []u8, _: ?*kv_read.Reader) u32 {
    return renderPage(send_buf, "Cluster", ui_embed.cluster_html);
}

fn apiKeysPage(send_buf: []u8, reader: ?*kv_read.Reader) u32 {
    var key_buf: [100]kv_read.ApiKeyRow = undefined;
    const count: usize = if (reader) |rdr| rdr.listApiKeys(&key_buf) else 0;

    const ApiKeyView = struct {
        name: []const u8,
        key_hash: []const u8,
        key_hash_short: []const u8,
        role: []const u8,
        enabled: bool,
        created_at: []const u8,
    };

    var views: [100]ApiKeyView = undefined;
    for (0..count) |i| {
        const row = &key_buf[i];
        const kh = row.keyHashSlice();
        views[i] = .{
            .name = row.nameSlice(),
            .key_hash = kh,
            .key_hash_short = if (kh.len > 12) kh[0..12] else kh,
            .role = row.roleSlice(),
            .enabled = row.enabled,
            .created_at = row.createdAtSlice(),
        };
    }

    var content_buf: [page_buf_size]u8 = undefined;
    const content = api_keys_tmpl.render(&content_buf, .{
        .has_keys = count > 0,
        .keys = views[0..count],
    }) catch return renderPage(send_buf, "API Keys", "<p>Page too large</p>");
    return renderPage(send_buf, "API Keys", content);
}

// ============================================================================
// HTMX Partials
// ============================================================================

fn dashboardStatsPartial(send_buf: []u8, reader: ?*kv_read.Reader) u32 {
    var queue_buf: [64]kv_read.QueueStats = undefined;
    var queue_views: [64]QueueView = undefined;
    var bar_buf: [64]BarView = undefined;
    var job_buf: [10]kv_read.JobRow = undefined;
    var failure_views: [10]FailureView = undefined;

    const has_data = reader != null;
    const queues = getQueueViews(reader, &queue_buf, &queue_views);

    var total_pending: i64 = 0;
    var total_active: i64 = 0;
    var total_dead: i64 = 0;
    for (queue_buf[0..queues.len]) |q| {
        total_pending += q.pending;
        total_active += q.active;
        total_dead += q.dead;
    }
    const worker_count: i32 = if (reader) |rdr| rdr.countWorkers() else 0;
    const bars = if (queues.len > 0) buildBarViews(queue_buf[0..queues.len], &bar_buf) else bar_buf[0..0];
    const failures = if (reader) |rdr| getFailureViews(rdr, &job_buf, &failure_views) else failure_views[0..0];

    var buf: [page_buf_size]u8 = undefined;
    const result = dashboard_stats_tmpl.renderWithPartials(&buf, .{
        .has_data = has_data,
        .total_pending = total_pending,
        .total_active = total_active,
        .total_dead = total_dead,
        .queue_count = @as(i64, @intCast(queues.len)),
        .worker_count = worker_count,
        .has_bars = queues.len > 0,
        .chart_w = @as(u32, 600),
        .chart_total_h = @as(u32, 190),
        .bars = bars,
        .has_failures = failures.len > 0,
        .failures = failures,
        .has_queues = queues.len > 0,
        .queues = queues,
    }, .{ .queues_table = &queues_table_tmpl }) catch
        return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return http.writeResponseHtml(send_buf, 200, result);
}

fn queuesTablePartial(send_buf: []u8, reader: ?*kv_read.Reader) u32 {
    var queue_buf: [64]kv_read.QueueStats = undefined;
    var views: [64]QueueView = undefined;
    const queues = getQueueViews(reader, &queue_buf, &views);

    var buf: [page_buf_size]u8 = undefined;
    const result = queues_table_tmpl.render(&buf, .{
        .queues = queues,
    }) catch return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return http.writeResponseHtml(send_buf, 200, result);
}

fn enqueueFormPartial(send_buf: []u8) u32 {
    return http.writeResponseHtml(send_buf, 200, ui_embed.enqueue_form_html);
}

// ============================================================================
// View Structs + Data Builders
// ============================================================================

const BarView = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    label_x: u32,
    label_y: u32,
    value_x: u32,
    value_y: u32,
    name: []const u8,
    total: i64,
    has_value: bool,
};

const FailureView = struct {
    id: []const u8,
    queue: []const u8,
    priority: i32,
    attempt: i32,
    max_retries: i32,
    created_at: []const u8,
};

const BulkAction = struct {
    action: []const u8,
    label: []const u8,
    class: []const u8,
};

const JobView = struct {
    id: []const u8,
    queue: []const u8,
    state: []const u8,
    state_class: []const u8,
    priority: i32,
    attempt: i32,
    max_retries: i32,
    created_at: []const u8,
    has_cb: bool,
};

const PageLink = struct {
    label: u32,
    url: []const u8,
    is_current: bool,
};

const PropView = struct {
    label: []const u8,
    value: []const u8,
};

const TimelineView = struct {
    label: []const u8,
    timestamp: []const u8,
    dot_class: []const u8,
};

const ErrorView = struct {
    attempt: i32,
    message: []const u8,
    created_at: []const u8,
    has_timestamp: bool,
};

const FilterTabView = struct {
    href: []const u8,
    label: []const u8,
    count: i32,
    tab_class: []const u8,
};

const active_tab_class = "px-3 py-1.5 text-sm font-medium rounded-md bg-indigo-100 dark:bg-indigo-900 text-indigo-700 dark:text-indigo-300";
const inactive_tab_class = "px-3 py-1.5 text-sm font-medium rounded-md text-zinc-600 dark:text-zinc-400 hover:bg-zinc-100 dark:hover:bg-zinc-800";

const QueueView = struct {
    name: []const u8,
    pending: i32,
    active: i32,
    retrying: i32,
    dead: i32,
    completed: i32,
    scheduled: i32,
    held: i32,
    paused: bool,
};

fn getQueueViews(reader: ?*kv_read.Reader, queue_buf: *[64]kv_read.QueueStats, views: *[64]QueueView) []const QueueView {
    const rdr = reader orelse return views[0..0];
    const count = rdr.getQueueStats(queue_buf);
    for (0..count) |i| {
        const q = &queue_buf[i];
        views[i] = .{
            .name = q.nameSlice(),
            .pending = q.pending,
            .active = q.active,
            .retrying = q.retrying,
            .dead = q.dead,
            .completed = q.completed,
            .scheduled = q.scheduled,
            .held = q.held,
            .paused = q.paused,
        };
    }
    return views[0..count];
}

fn getJobViews(
    jobs: []const kv_read.JobRow,
    views: *[max_table_rows]JobView,
    actions: RowActions,
) []const JobView {
    const has_cb = actions != .none;
    for (jobs, 0..) |*j, i| {
        views[i] = .{
            .id = j.idSlice(),
            .queue = j.queueSlice(),
            .state = j.stateSlice(),
            .state_class = stateBadgeClassDark(j.stateSlice()),
            .priority = j.priority,
            .attempt = j.attempt,
            .max_retries = j.max_retries,
            .created_at = j.createdAtSlice(),
            .has_cb = has_cb,
        };
    }
    return views[0..jobs.len];
}

fn getBulkActions(actions: RowActions, buf: *[2]BulkAction) []const BulkAction {
    return switch (actions) {
        .dead => blk: {
            buf[0] = .{ .action = "retry", .label = "Retry All", .class = "bg-indigo-600 hover:bg-indigo-700" };
            buf[1] = .{ .action = "delete", .label = "Delete All", .class = "bg-red-600 hover:bg-red-700" };
            break :blk buf[0..2];
        },
        .held => blk: {
            buf[0] = .{ .action = "approve", .label = "Approve All", .class = "bg-emerald-600 hover:bg-emerald-700" };
            buf[1] = .{ .action = "reject", .label = "Reject All", .class = "bg-red-600 hover:bg-red-700" };
            break :blk buf[0..2];
        },
        .scheduled => blk: {
            buf[0] = .{ .action = "run", .label = "Run All", .class = "bg-indigo-600 hover:bg-indigo-700" };
            buf[1] = .{ .action = "delete", .label = "Delete All", .class = "bg-red-600 hover:bg-red-700" };
            break :blk buf[0..2];
        },
        .queue_detail => blk: {
            buf[0] = .{ .action = "cancel", .label = "Cancel All", .class = "bg-amber-600 hover:bg-amber-700" };
            buf[1] = .{ .action = "delete", .label = "Delete All", .class = "bg-red-600 hover:bg-red-700" };
            break :blk buf[0..2];
        },
        .none => buf[0..0],
    };
}

const PaginationData = struct {
    has_pages: bool,
    page_display: u32,
    total_pages: u32,
    has_prev: bool,
    prev_url: []const u8,
    first_url: []const u8,
    has_next: bool,
    next_url: []const u8,
    last_url: []const u8,
    pages: []const PageLink,
};

fn buildPaginationData(base_url: []const u8, page: u32, total_pages: u32, nav_bufs: *[4][256]u8, links: *[10]PageLink, url_bufs: *[10][256]u8) PaginationData {
    var first_s = std.io.fixedBufferStream(&nav_bufs[0]);
    var prev_s = std.io.fixedBufferStream(&nav_bufs[1]);
    var next_s = std.io.fixedBufferStream(&nav_bufs[2]);
    var last_s = std.io.fixedBufferStream(&nav_bufs[3]);
    first_s.writer().print("{s}page=0", .{base_url}) catch {};
    prev_s.writer().print("{s}page={d}", .{ base_url, page -| 1 }) catch {};
    next_s.writer().print("{s}page={d}", .{ base_url, page + 1 }) catch {};
    last_s.writer().print("{s}page={d}", .{ base_url, total_pages -| 1 }) catch {};
    return .{
        .has_pages = total_pages > 1,
        .page_display = page + 1,
        .total_pages = total_pages,
        .has_prev = page > 0,
        .prev_url = prev_s.getWritten(),
        .first_url = first_s.getWritten(),
        .has_next = page + 1 < total_pages,
        .next_url = next_s.getWritten(),
        .last_url = last_s.getWritten(),
        .pages = buildPageLinks(base_url, page, total_pages, links, url_bufs),
    };
}

/// Sliding window: 5 pages centered on current.
fn buildPageLinks(base_url: []const u8, page: u32, total_pages: u32, links: *[10]PageLink, url_bufs: *[10][256]u8) []const PageLink {
    const window = 5;
    const half = window / 2;
    // Clamp window so current is centered (or as close as possible at edges).
    const win_start = if (page >= half) @min(page - half, total_pages -| window) else 0;
    const win_end = @min(win_start + window, total_pages);
    var count: usize = 0;
    for (win_start..win_end) |p| {
        var s = std.io.fixedBufferStream(&url_bufs[count]);
        s.writer().print("{s}page={d}", .{ base_url, p }) catch {};
        links[count] = .{ .label = @as(u32, @intCast(p)) + 1, .url = s.getWritten(), .is_current = p == page };
        count += 1;
    }
    return links[0..count];
}

fn buildBarViews(queues: []const kv_read.QueueStats, bars: *[64]BarView) []const BarView {
    const chart_h: u32 = 160;
    const bar_gap: u32 = 4;
    const n: u32 = @intCast(queues.len);
    const bar_w: u32 = @min((600 -| (n -| 1) * bar_gap) / @max(n, 1), 60);

    var max_val: i64 = 1;
    for (queues) |q| {
        const total = q.pending + q.active + q.retrying;
        if (total > max_val) max_val = total;
    }

    for (0..queues.len) |i| {
        const total: i64 = queues[i].pending + queues[i].active + queues[i].retrying;
        const bar_h: u32 = @intCast(@max(@divTrunc(total * chart_h, max_val), 0));
        const x: u32 = @as(u32, @intCast(i)) * (bar_w + bar_gap);
        bars[i] = .{
            .x = x,
            .y = chart_h - bar_h,
            .w = bar_w,
            .h = bar_h,
            .label_x = x + bar_w / 2,
            .label_y = chart_h + 16,
            .value_x = x + bar_w / 2,
            .value_y = (chart_h - bar_h) -| 4,
            .name = queues[i].nameSlice(),
            .total = total,
            .has_value = total > 0,
        };
    }
    return bars[0..n];
}

fn getFailureViews(reader: *kv_read.Reader, job_buf: *[10]kv_read.JobRow, views: *[10]FailureView) []const FailureView {
    const count = reader.queryJobsByQueueState(null, "dead", 10, 0, job_buf);
    for (0..count) |i| {
        const j = &job_buf[i];
        views[i] = .{
            .id = j.idSlice(),
            .queue = j.queueSlice(),
            .priority = j.priority,
            .attempt = j.attempt,
            .max_retries = j.max_retries,
            .created_at = j.createdAtSlice(),
        };
    }
    return views[0..count];
}

// ============================================================================
// Helpers
// ============================================================================

const RowActions = enum { none, dead, held, scheduled, queue_detail };

fn stateBadgeClassDark(state: []const u8) []const u8 {
    if (eql(state, "pending")) return "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium bg-blue-50 dark:bg-blue-950 text-blue-700 dark:text-blue-400";
    if (eql(state, "active")) return "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium bg-emerald-50 dark:bg-emerald-950 text-emerald-700 dark:text-emerald-400";
    if (eql(state, "completed")) return "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-400";
    if (eql(state, "dead")) return "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium bg-red-50 dark:bg-red-950 text-red-700 dark:text-red-400";
    if (eql(state, "retrying")) return "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium bg-orange-50 dark:bg-orange-950 text-orange-700 dark:text-orange-400";
    if (eql(state, "scheduled")) return "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium bg-purple-50 dark:bg-purple-950 text-purple-700 dark:text-purple-400";
    if (eql(state, "held")) return "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium bg-amber-50 dark:bg-amber-950 text-amber-700 dark:text-amber-400";
    return "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-400";
}

fn filterCount(q: *const kv_read.QueueStats, state: ?[]const u8) i32 {
    if (state) |s| {
        if (eql(s, "pending")) return q.pending;
        if (eql(s, "active")) return q.active;
        if (eql(s, "retrying")) return q.retrying;
        if (eql(s, "dead")) return q.dead;
        if (eql(s, "completed")) return q.completed;
        if (eql(s, "scheduled")) return q.scheduled;
        if (eql(s, "held")) return q.held;
        return 0;
    }
    return q.pending + q.active + q.retrying + q.dead + q.completed + q.scheduled + q.held;
}

fn queueStateCount(q: *const kv_read.QueueStats, state: ?[]const u8) u32 {
    return @intCast(@max(filterCount(q, state), 0));
}

fn parsePageParam(query: []const u8) u32 {
    const page_str = getQueryParam(query, "page") orelse return 0;
    return std.fmt.parseInt(u32, page_str, 10) catch 0;
}

fn getQueryParam(query: []const u8, key: []const u8) ?[]const u8 {
    var rest = query;
    while (rest.len > 0) {
        const amp = std.mem.indexOfScalar(u8, rest, '&') orelse rest.len;
        const param = rest[0..amp];
        const eq_pos = std.mem.indexOfScalar(u8, param, '=') orelse {
            rest = if (amp < rest.len) rest[amp + 1 ..] else "";
            continue;
        };
        if (eql(param[0..eq_pos], key)) return param[eq_pos + 1 ..];
        rest = if (amp < rest.len) rest[amp + 1 ..] else "";
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
