//! Server-rendered HTML UI — HTMX + Tailwind CSS dashboard.
//!
//! Page structure lives in ui/templates/*.html files.
//! Zig code renders only dynamic content (data tables, stats, charts) and
//! splices it into templates via {{placeholder}} substitution.

const std = @import("std");
const zigstache = @import("zigstache");
const http = @import("http.zig");
const html = @import("html_writer.zig");
const sqlite_read = @import("sqlite_read.zig");
const ui_embed = @import("ui_embed");

/// Max HTML body size. Pages render into a buffer of this size.
/// With HTTP headers (~200 bytes), total response stays under 33KB.
const page_buf_size = 32768;

/// Layout-expanded page buffer. Must fit layout template + page content + HTTP headers
/// within send_buf (~66KB). Layout is ~4KB, headers ~200B.
const render_buf_size = 65000;

/// Max table rows per page. Keeps HTML under page_buf_size.
const max_table_rows = 25;

/// Comptime-parsed Mustache templates.
const layout_tmpl = zigstache.Template.parse(ui_embed.layout_html) catch unreachable;
const dashboard_tmpl = zigstache.Template.parse(ui_embed.dashboard_html) catch unreachable;
const queues_tmpl = zigstache.Template.parse(ui_embed.queues_html) catch unreachable;
const queue_detail_tmpl = zigstache.Template.parse(ui_embed.queue_detail_html) catch unreachable;
const job_list_tmpl = zigstache.Template.parse(ui_embed.job_list_html) catch unreachable;
const job_detail_tmpl = zigstache.Template.parse(ui_embed.job_detail_html) catch unreachable;
const workers_tmpl = zigstache.Template.parse(ui_embed.workers_html) catch unreachable;

// ============================================================================
// Dispatch
// ============================================================================

/// Route a UI page request. Returns bytes written to send_buf.
pub fn dispatch(path: []const u8, query: []const u8, send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
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

    // HTMX partial routes (fragments, no layout).
    if (eql(path, "/partials/dashboard-stats")) return dashboardStatsPartial(send_buf, reader);
    if (eql(path, "/partials/queues-table")) return queuesTablePartial(send_buf, reader);
    if (eql(path, "/partials/enqueue-form")) return enqueueFormPartial(send_buf);

    return http.writeResponseHtml(send_buf, 404, "<h1>Not Found</h1>");
}

// ============================================================================
// Template Engine
// ============================================================================

/// Splice title and content into the layout template, then write the HTTP response.
fn renderPage(send_buf: []u8, title: []const u8, content: []const u8) u32 {
    var buf: [render_buf_size]u8 = undefined;
    const rendered = layout_tmpl.render(&buf, .{ .title = title, .content = content }) catch |err| switch (err) {
        error.BufferOverflow => return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>"),
    };
    return http.writeResponseHtml(send_buf, 200, rendered);
}

// ============================================================================
// Full Pages
// ============================================================================

fn dashboard(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var stats_buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&stats_buf);
    writeDashboardStats(&hw, reader);

    var content_buf: [page_buf_size]u8 = undefined;
    const content = dashboard_tmpl.render(&content_buf, .{ .stats = hw.getWritten() }) catch
        return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, "Dashboard", content);
}

fn queuesPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var table_buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&table_buf);
    writeQueuesTable(&hw, reader);

    var content_buf: [page_buf_size]u8 = undefined;
    const content = queues_tmpl.render(&content_buf, .{ .table = hw.getWritten() }) catch
        return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, "Queues", content);
}

fn queueDetailPage(send_buf: []u8, reader: ?*sqlite_read.Reader, queue_name: []const u8, query: []const u8) u32 {
    // Action buttons (always shown).
    var btn_buf: [4096]u8 = undefined;
    var btn_hw = html.HtmlWriter.init(&btn_buf);
    writeQueueActionButton(&btn_hw, queue_name, "pause", "Pause", "bg-yellow-500 hover:bg-yellow-600");
    writeQueueActionButton(&btn_hw, queue_name, "resume", "Resume", "bg-green-500 hover:bg-green-600");
    writeQueueActionButton(&btn_hw, queue_name, "drain", "Drain", "bg-blue-500 hover:bg-blue-600");

    const rdr = reader orelse {
        var content_buf: [page_buf_size]u8 = undefined;
        const content = queue_detail_tmpl.render(&content_buf, .{
            .queue_name = queue_name,
            .status_badge = "",
            .action_buttons = btn_hw.getWritten(),
            .export_buttons = "",
            .stats_bar = "",
            .filter_section = "",
            .job_table = "<p class=\"text-gray-500\">No data available</p>",
            .pagination = "",
        }) catch return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
        return renderPage(send_buf, "Queue Detail", content);
    };

    const state_filter = getQueryParam(query, "state");
    const page = parsePageParam(query);
    const offset: u32 = page * max_table_rows;

    // Stats bar.
    var stats_buf: [4096]u8 = undefined;
    var stats_hw = html.HtmlWriter.init(&stats_buf);
    var queue_stats_buf: [64]sqlite_read.QueueStats = undefined;
    const q_count = rdr.getQueueStats(&queue_stats_buf) catch 0;
    var qs: ?*const sqlite_read.QueueStats = null;
    for (0..q_count) |i| {
        if (eql(queue_stats_buf[i].nameSlice(), queue_name)) {
            qs = &queue_stats_buf[i];
            break;
        }
    }
    const paused = if (qs) |q| q.paused else false;
    const status_badge: []const u8 = if (paused)
        "<span class=\"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800\">Paused</span>"
    else
        "<span class=\"inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800\">Active</span>";

    if (qs) |q| {
        stats_hw.open("div");
        stats_hw.attr("class", "grid grid-cols-2 md:grid-cols-4 gap-4");
        statCard(&stats_hw, "Pending", q.pending, "text-blue-700");
        statCard(&stats_hw, "Active", q.active, "text-green-700");
        statCard(&stats_hw, "Dead", q.dead, "text-red-600");
        statCardInt(&stats_hw, "Completed", q.completed, "text-gray-900");
        stats_hw.close("div");
    }

    // Filter section (tabs + search).
    var filter_buf: [4096]u8 = undefined;
    var filter_hw = html.HtmlWriter.init(&filter_buf);
    filter_hw.open("div");
    filter_hw.attr("class", "flex flex-col sm:flex-row sm:items-center gap-3");
    filter_hw.open("div");
    filter_hw.attr("class", "flex flex-wrap gap-1");
    filterTab(&filter_hw, queue_name, null, "All", state_filter, qs);
    filterTab(&filter_hw, queue_name, "pending", "Pending", state_filter, qs);
    filterTab(&filter_hw, queue_name, "active", "Active", state_filter, qs);
    filterTab(&filter_hw, queue_name, "retrying", "Retrying", state_filter, qs);
    filterTab(&filter_hw, queue_name, "dead", "Dead", state_filter, qs);
    filterTab(&filter_hw, queue_name, "completed", "Completed", state_filter, qs);
    filterTab(&filter_hw, queue_name, "scheduled", "Scheduled", state_filter, qs);
    filterTab(&filter_hw, queue_name, "held", "Held", state_filter, qs);
    filter_hw.close("div");
    filter_hw.voidElem("input");
    filter_hw.attr("type", "text");
    filter_hw.attr("placeholder", "Filter jobs...");
    filter_hw.attr("class", "px-3 py-1.5 border border-gray-300 rounded-md text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 sm:ml-auto w-full sm:w-48");
    filter_hw.attr("oninput", "corvoFilterRows(this.value)");
    filter_hw.close("div");

    // Export buttons.
    var export_buf: [4096]u8 = undefined;
    var export_hw = html.HtmlWriter.init(&export_buf);
    writeExportButtons(&export_hw, state_filter, queue_name);

    // Job table.
    var table_buf: [page_buf_size]u8 = undefined;
    var table_hw = html.HtmlWriter.init(&table_buf);
    var job_buf: [max_table_rows]sqlite_read.JobRow = undefined;
    const count = rdr.queryJobsByQueueState(queue_name, state_filter, max_table_rows, offset, &job_buf) catch 0;
    writeJobTable(&table_hw, job_buf[0..count], .queue_detail);

    // Pagination.
    var pag_buf: [4096]u8 = undefined;
    var pag_hw = html.HtmlWriter.init(&pag_buf);
    const total: u32 = if (qs) |q| queueStateCount(q, state_filter) else 0;
    const total_pages = if (total > 0) (total + max_table_rows - 1) / max_table_rows else 1;
    var url_buf: [256]u8 = undefined;
    var url_stream = std.io.fixedBufferStream(&url_buf);
    url_stream.writer().print("/ui/queues/{s}?", .{queue_name}) catch {};
    if (state_filter) |sf| url_stream.writer().print("state={s}&", .{sf}) catch {};
    writePagination(&pag_hw, url_stream.getWritten(), page, total_pages);

    var content_buf: [page_buf_size]u8 = undefined;
    const content = queue_detail_tmpl.render(&content_buf, .{
        .queue_name = queue_name,
        .status_badge = status_badge,
        .action_buttons = btn_hw.getWritten(),
        .export_buttons = export_hw.getWritten(),
        .stats_bar = stats_hw.getWritten(),
        .filter_section = filter_hw.getWritten(),
        .job_table = table_hw.getWritten(),
        .pagination = pag_hw.getWritten(),
    }) catch return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, "Queue Detail", content);
}

fn deadLetterPage(send_buf: []u8, reader: ?*sqlite_read.Reader, query: []const u8) u32 {
    return jobListPage(send_buf, reader, "Dead Letter", "dead", .dead, "/ui/dead-letter", query);
}

fn heldJobsPage(send_buf: []u8, reader: ?*sqlite_read.Reader, query: []const u8) u32 {
    return jobListPage(send_buf, reader, "Held Jobs", "held", .held, "/ui/held", query);
}

fn scheduledJobsPage(send_buf: []u8, reader: ?*sqlite_read.Reader, query: []const u8) u32 {
    return jobListPage(send_buf, reader, "Scheduled Jobs", "scheduled", .scheduled, "/ui/scheduled", query);
}

fn jobListPage(send_buf: []u8, reader: ?*sqlite_read.Reader, title: []const u8, state: []const u8, actions: RowActions, base_path: []const u8, query: []const u8) u32 {
    const rdr = reader orelse return renderPage(send_buf, title, "<p class=\"text-gray-500\">No data available</p>");

    const page = parsePageParam(query);
    const queue_filter = getQueryParam(query, "queue");
    const offset: u32 = page * max_table_rows;

    // Total count for pagination.
    const total: u32 = @intCast(@max(if (queue_filter) |qf|
        rdr.countJobsByQueueState(qf, state) catch @as(i32, 0)
    else
        rdr.countJobsByState(state) catch @as(i32, 0), 0));
    const total_pages = if (total > 0) (total + max_table_rows - 1) / max_table_rows else 1;

    // Export buttons.
    var export_buf: [4096]u8 = undefined;
    var export_hw = html.HtmlWriter.init(&export_buf);
    writeExportButtons(&export_hw, state, if (queue_filter) |qf| qf else null);

    // Job table.
    var table_buf: [page_buf_size]u8 = undefined;
    var table_hw = html.HtmlWriter.init(&table_buf);
    var job_buf: [max_table_rows]sqlite_read.JobRow = undefined;
    const count = rdr.queryJobsByQueueState(queue_filter, state, max_table_rows, offset, &job_buf) catch 0;
    writeJobTable(&table_hw, job_buf[0..count], actions);

    // Pagination.
    var pag_buf: [4096]u8 = undefined;
    var pag_hw = html.HtmlWriter.init(&pag_buf);
    var url_buf: [256]u8 = undefined;
    var url_stream = std.io.fixedBufferStream(&url_buf);
    url_stream.writer().print("{s}?", .{base_path}) catch {};
    if (queue_filter) |qf| url_stream.writer().print("queue={s}&", .{qf}) catch {};
    writePagination(&pag_hw, url_stream.getWritten(), page, total_pages);

    var content_buf: [page_buf_size]u8 = undefined;
    const content = job_list_tmpl.render(&content_buf, .{
        .export_buttons = export_hw.getWritten(),
        .job_table = table_hw.getWritten(),
        .pagination = pag_hw.getWritten(),
    }) catch return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, title, content);
}

fn jobDetailPage(send_buf: []u8, reader: ?*sqlite_read.Reader, job_id: []const u8) u32 {
    const rdr = reader orelse return renderPage(send_buf, "Job Detail", "<p class=\"text-gray-500\">No data available</p>");
    const j = (rdr.getJob(job_id) catch null) orelse return renderPage(send_buf, "Job Detail", "<p class=\"text-red-500\">Job not found</p>");

    // Action buttons.
    var btn_buf: [4096]u8 = undefined;
    var btn_hw = html.HtmlWriter.init(&btn_buf);
    writeJobActionButton(&btn_hw, job_id, "retry", "Retry", "bg-blue-500 hover:bg-blue-600");
    writeJobActionButton(&btn_hw, job_id, "cancel", "Cancel", "bg-yellow-500 hover:bg-yellow-600");
    writeJobActionButton(&btn_hw, job_id, "delete", "Delete", "bg-red-500 hover:bg-red-600");

    // Properties table rows.
    var props_buf: [4096]u8 = undefined;
    var props_hw = html.HtmlWriter.init(&props_buf);
    detailRow(&props_hw, "Queue", j.queueSlice());
    detailRow(&props_hw, "State", j.stateSlice());
    detailRowFmt(&props_hw, "Priority", "{d}", .{j.priority});
    detailRowFmt(&props_hw, "Attempt", "{d}/{d}", .{ j.attempt, j.max_retries });
    if (j.worker_id_len > 0) detailRow(&props_hw, "Worker", j.workerIdSlice());

    // Timeline entries.
    var time_buf: [4096]u8 = undefined;
    var time_hw = html.HtmlWriter.init(&time_buf);
    if (j.created_at_len > 0) timelineEntry(&time_hw, "Created", j.createdAtSlice());
    if (j.scheduled_at_len > 0) timelineEntry(&time_hw, "Scheduled", j.scheduledAtSlice());
    if (j.started_at_len > 0) timelineEntry(&time_hw, "Started", j.startedAtSlice());
    if (j.completed_at_len > 0) timelineEntry(&time_hw, "Completed", j.completedAtSlice());
    if (j.failed_at_len > 0) timelineEntry(&time_hw, "Failed", j.failedAtSlice());

    // Payload section.
    var payload_buf: [8192]u8 = undefined;
    var payload_hw = html.HtmlWriter.init(&payload_buf);
    var raw_payload: [4096]u8 = undefined;
    if (rdr.getJobPayload(job_id, &raw_payload) catch null) |payload| {
        payload_hw.open("div");
        payload_hw.attr("class", "bg-white border border-gray-200 rounded-lg");
        payload_hw.open("div");
        payload_hw.attr("class", "px-4 py-3 border-b border-gray-200 flex items-center justify-between");
        payload_hw.open("h3");
        payload_hw.attr("class", "text-sm font-semibold text-gray-900");
        payload_hw.text("Payload");
        payload_hw.close("h3");
        payload_hw.open("button");
        payload_hw.attr("onclick", "corvoPayloadCopy(this)");
        payload_hw.attr("class", "text-xs text-gray-500 hover:text-gray-700 font-medium");
        payload_hw.text("Copy");
        payload_hw.close("button");
        payload_hw.close("div");
        payload_hw.open("pre");
        payload_hw.attr("id", "job-payload");
        payload_hw.attr("class", "p-4 text-xs font-mono overflow-x-auto text-gray-800 bg-gray-50 rounded-b-lg");
        payload_hw.text(payload);
        payload_hw.close("pre");
        payload_hw.close("div");
    }

    // Error history section.
    var errors_buf: [8192]u8 = undefined;
    var errors_hw = html.HtmlWriter.init(&errors_buf);
    var err_rows: [16]sqlite_read.JobError = undefined;
    const err_count = rdr.getJobErrors(job_id, &err_rows) catch 0;
    if (err_count > 0) {
        errors_hw.open("div");
        errors_hw.attr("class", "bg-white border border-gray-200 rounded-lg");
        errors_hw.open("div");
        errors_hw.attr("class", "px-4 py-3 border-b border-gray-200");
        errors_hw.open("h3");
        errors_hw.attr("class", "text-sm font-semibold text-gray-900");
        errors_hw.text("Error History");
        errors_hw.close("h3");
        errors_hw.close("div");
        errors_hw.open("div");
        errors_hw.attr("class", "divide-y divide-gray-100");
        for (0..err_count) |i| {
            const err = &err_rows[i];
            errors_hw.open("div");
            errors_hw.attr("class", "px-4 py-3");
            errors_hw.open("div");
            errors_hw.attr("class", "flex items-center gap-2 mb-1");
            errors_hw.open("span");
            errors_hw.attr("class", "text-xs font-medium text-gray-500");
            errors_hw.textFmt("Attempt {d}", .{err.attempt});
            errors_hw.close("span");
            if (err.created_at_len > 0) {
                errors_hw.open("span");
                errors_hw.attr("class", "text-xs text-gray-400");
                errors_hw.open("time");
                errors_hw.attr("data-ts", err.created_at[0..err.created_at_len]);
                errors_hw.text(err.created_at[0..err.created_at_len]);
                errors_hw.close("time");
                errors_hw.close("span");
            }
            errors_hw.close("div");
            errors_hw.open("pre");
            errors_hw.attr("class", "text-xs text-red-700 bg-red-50 rounded p-2 overflow-x-auto");
            errors_hw.text(err.errorSlice());
            errors_hw.close("pre");
            errors_hw.close("div");
        }
        errors_hw.close("div");
        errors_hw.close("div");
    }

    var content_buf: [page_buf_size]u8 = undefined;
    const content = job_detail_tmpl.render(&content_buf, .{
        .job_id = j.idSlice(),
        .state = j.stateSlice(),
        .state_badge_class = stateBadgeClass(j.stateSlice()),
        .action_buttons = btn_hw.getWritten(),
        .properties = props_hw.getWritten(),
        .timeline = time_hw.getWritten(),
        .payload_section = payload_hw.getWritten(),
        .errors_section = errors_hw.getWritten(),
    }) catch return http.writeResponseHtml(send_buf, 500, "<h1>Page too large</h1>");
    return renderPage(send_buf, "Job Detail", content);
}

fn workersPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    const WorkerView = struct {
        id: []const u8,
        hostname: []const u8,
        queues: []const u8,
        last_heartbeat: []const u8,
        started_at: []const u8,
    };

    var worker_buf: [64]sqlite_read.WorkerRow = undefined;
    const count: usize = if (reader) |rdr| rdr.getWorkers(&worker_buf) catch 0 else 0;

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

fn clusterPage(send_buf: []u8, _: ?*sqlite_read.Reader) u32 {
    return renderPage(send_buf, "Cluster", ui_embed.cluster_html);
}

// ============================================================================
// HTMX Partials
// ============================================================================

fn dashboardStatsPartial(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);
    writeDashboardStats(&hw, reader);
    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
}

fn queuesTablePartial(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);
    writeQueuesTable(&hw, reader);
    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
}

fn enqueueFormPartial(send_buf: []u8) u32 {
    return http.writeResponseHtml(send_buf, 200, ui_embed.enqueue_form_html);
}

// ============================================================================
// Dynamic Content Writers
// ============================================================================

fn writeDashboardStats(hw: *html.HtmlWriter, reader: ?*sqlite_read.Reader) void {
    const rdr = reader orelse {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("Waiting for data...");
        hw.close("p");
        return;
    };

    var queue_buf: [64]sqlite_read.QueueStats = undefined;
    const count = rdr.getQueueStats(&queue_buf) catch 0;

    // Aggregate stats.
    var total_pending: i64 = 0;
    var total_active: i64 = 0;
    var total_dead: i64 = 0;
    var total_completed: i64 = 0;
    for (0..count) |i| {
        total_pending += queue_buf[i].pending;
        total_active += queue_buf[i].active;
        total_dead += queue_buf[i].dead;
        total_completed += queue_buf[i].completed;
    }

    const worker_count = rdr.countWorkers() catch 0;

    // Stats grid.
    hw.open("div");
    hw.attr("class", "grid grid-cols-2 lg:grid-cols-5 gap-4 mb-6");
    statCard(hw, "Total Pending", total_pending, "text-gray-900");
    statCard(hw, "Active", total_active, "text-gray-900");
    statCard(hw, "Dead", total_dead, "text-red-600");
    statCard(hw, "Queues", @as(i64, @intCast(count)), "text-gray-900");
    statCardInt(hw, "Workers", worker_count, "text-gray-900");
    hw.close("div");

    // SVG bar chart — queue sizes at a glance.
    if (count > 0) {
        writeQueueBarChart(hw, queue_buf[0..count]);
    }

    // Recent failures.
    {
        var dead_buf: [10]sqlite_read.JobRow = undefined;
        const dead_count = rdr.queryJobsByQueueState(null, "dead", 10, 0, &dead_buf) catch 0;
        if (dead_count > 0) {
            hw.open("div");
            hw.attr("class", "mb-6");
            hw.open("h2");
            hw.attr("class", "text-lg font-semibold text-gray-900 mb-3");
            hw.text("Recent Failures");
            hw.close("h2");
            writeJobTable(hw, dead_buf[0..dead_count], .dead);
            hw.close("div");
        }
    }

    // Queue summary table.
    if (count > 0) {
        hw.open("h2");
        hw.attr("class", "text-lg font-semibold text-gray-900 mb-3");
        hw.text("Queues");
        hw.close("h2");
        writeQueuesTable(hw, reader);
    }
}

fn writeQueueBarChart(hw: *html.HtmlWriter, queues: []const sqlite_read.QueueStats) void {
    var max_val: i64 = 1;
    for (queues) |q| {
        const total = q.pending + q.active + q.retrying;
        if (total > max_val) max_val = total;
    }

    const chart_w: u32 = 600;
    const chart_h: u32 = 160;
    const bar_gap: u32 = 4;
    const n: u32 = @intCast(queues.len);
    const bar_w: u32 = if (n > 0) @min((chart_w - (n - 1) * bar_gap) / n, 60) else 40;

    hw.open("div");
    hw.attr("class", "bg-white border border-gray-200 rounded-lg p-4 mb-6");
    hw.open("svg");
    hw.attrFmt("width", "{d}", .{chart_w});
    hw.attrFmt("height", "{d}", .{chart_h + 30});
    hw.attr("class", "w-full");
    hw.attrFmt("viewBox", "0 0 {d} {d}", .{ chart_w, chart_h + 30 });

    for (queues, 0..) |q, i| {
        const total = q.pending + q.active + q.retrying;
        const bar_h: u32 = if (max_val > 0) @intCast(@divTrunc(total * chart_h, max_val)) else 0;
        const x: u32 = @as(u32, @intCast(i)) * (bar_w + bar_gap);
        const y: u32 = chart_h - bar_h;

        hw.open("rect");
        hw.attrFmt("x", "{d}", .{x});
        hw.attrFmt("y", "{d}", .{y});
        hw.attrFmt("width", "{d}", .{bar_w});
        hw.attrFmt("height", "{d}", .{bar_h});
        hw.attr("fill", "#3b82f6");
        hw.attr("rx", "2");
        hw.close("rect");

        hw.open("text");
        hw.attrFmt("x", "{d}", .{x + bar_w / 2});
        hw.attrFmt("y", "{d}", .{chart_h + 16});
        hw.attr("text-anchor", "middle");
        hw.attr("class", "text-xs fill-gray-500");
        hw.text(q.nameSlice());
        hw.close("text");

        if (total > 0) {
            hw.open("text");
            hw.attrFmt("x", "{d}", .{x + bar_w / 2});
            hw.attrFmt("y", "{d}", .{y -| 4});
            hw.attr("text-anchor", "middle");
            hw.attr("class", "text-xs fill-gray-700 font-medium");
            hw.textFmt("{d}", .{total});
            hw.close("text");
        }
    }

    hw.close("svg");
    hw.close("div");
}

fn writeQueuesTable(hw: *html.HtmlWriter, reader: ?*sqlite_read.Reader) void {
    const rdr = reader orelse return;
    var queue_buf: [64]sqlite_read.QueueStats = undefined;
    const count = rdr.getQueueStats(&queue_buf) catch return;

    if (count == 0) {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No queues");
        hw.close("p");
        return;
    }

    hw.open("div");
    hw.attr("class", "bg-white border border-gray-200 rounded-lg overflow-x-auto");
    hw.open("table");
    hw.attr("class", "w-full text-sm");
    hw.open("thead");
    hw.open("tr");
    hw.attr("class", "border-b border-gray-200 bg-gray-50");
    tableHeader(hw, "Queue");
    tableHeader(hw, "Pending");
    tableHeader(hw, "Active");
    tableHeader(hw, "Retrying");
    tableHeader(hw, "Dead");
    tableHeader(hw, "Completed");
    tableHeader(hw, "Scheduled");
    tableHeader(hw, "Held");
    tableHeader(hw, "Status");
    hw.close("tr");
    hw.close("thead");
    hw.open("tbody");
    hw.attr("class", "divide-y divide-gray-100");
    for (0..count) |i| {
        const q = &queue_buf[i];
        hw.open("tr");
        hw.attr("class", "hover:bg-gray-50");
        hw.open("td");
        hw.attr("class", "px-4 py-2 font-medium");
        hw.open("a");
        hw.attrFmt("href", "/ui/queues/{s}", .{q.nameSlice()});
        hw.attr("class", "text-blue-600 hover:underline");
        hw.text(q.nameSlice());
        hw.close("a");
        hw.close("td");
        tableCellInt(hw, q.pending);
        tableCellInt(hw, q.active);
        tableCellInt(hw, q.retrying);
        tableCellInt(hw, q.dead);
        tableCellInt(hw, q.completed);
        tableCellInt(hw, q.scheduled);
        tableCellInt(hw, q.held);
        hw.open("td");
        hw.attr("class", "px-4 py-2");
        hw.open("span");
        hw.attr("class", if (q.paused)
            "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800"
        else
            "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800");
        hw.text(if (q.paused) "paused" else "active");
        hw.close("span");
        hw.close("td");
        hw.close("tr");
    }
    hw.close("tbody");
    hw.close("table");
    hw.close("div");
}

const RowActions = enum { none, dead, held, scheduled, queue_detail };

fn writeJobTable(hw: *html.HtmlWriter, jobs: []const sqlite_read.JobRow, actions: RowActions) void {
    if (jobs.len == 0) {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No jobs");
        hw.close("p");
        return;
    }

    // Bulk action bar.
    if (actions != .none) {
        hw.open("div");
        hw.attr("id", "bulk-bar");
        hw.attr("class", "hidden mb-3 p-3 bg-blue-50 border border-blue-200 rounded-lg flex items-center gap-3");
        hw.open("span");
        hw.attr("id", "bulk-count");
        hw.attr("class", "text-sm font-medium text-blue-800");
        hw.text("0 selected");
        hw.close("span");
        switch (actions) {
            .dead => {
                bulkButton(hw, "retry", "Retry All", "bg-blue-600 hover:bg-blue-700");
                bulkButton(hw, "delete", "Delete All", "bg-red-600 hover:bg-red-700");
            },
            .held => {
                bulkButton(hw, "approve", "Approve All", "bg-green-600 hover:bg-green-700");
                bulkButton(hw, "reject", "Reject All", "bg-red-600 hover:bg-red-700");
            },
            .scheduled => {
                bulkButton(hw, "run", "Run All", "bg-blue-600 hover:bg-blue-700");
                bulkButton(hw, "delete", "Delete All", "bg-red-600 hover:bg-red-700");
            },
            .queue_detail => {
                bulkButton(hw, "cancel", "Cancel All", "bg-yellow-600 hover:bg-yellow-700");
                bulkButton(hw, "delete", "Delete All", "bg-red-600 hover:bg-red-700");
            },
            .none => {},
        }
        hw.close("div");
    }

    hw.open("div");
    hw.attr("class", "bg-white border border-gray-200 rounded-lg overflow-x-auto");
    hw.open("table");
    hw.attr("class", "w-full text-sm");
    hw.open("thead");
    hw.open("tr");
    hw.attr("class", "border-b border-gray-200 bg-gray-50");
    if (actions != .none) {
        hw.open("th");
        hw.attr("class", "px-4 py-2 w-8");
        hw.voidElem("input");
        hw.attr("type", "checkbox");
        hw.attr("id", "select-all");
        hw.attr("class", "rounded");
        hw.attr("onchange", "corvoToggleAll(this.checked)");
        hw.close("th");
    }
    tableHeader(hw, "ID");
    tableHeader(hw, "Queue");
    tableHeader(hw, "State");
    tableHeader(hw, "Priority");
    tableHeader(hw, "Attempt");
    tableHeader(hw, "Created");
    if (actions != .none) tableHeader(hw, "Actions");
    hw.close("tr");
    hw.close("thead");
    hw.open("tbody");
    hw.attr("class", "divide-y divide-gray-100");
    for (jobs) |*j| {
        hw.open("tr");
        hw.attr("class", "hover:bg-gray-50");
        if (actions != .none) {
            hw.open("td");
            hw.attr("class", "px-4 py-2");
            hw.voidElem("input");
            hw.attr("type", "checkbox");
            hw.attr("class", "job-cb rounded");
            hw.attrFmt("data-id", "{s}", .{j.idSlice()});
            hw.attr("onchange", "corvoUpdateBulk()");
            hw.close("td");
        }
        hw.open("td");
        hw.attr("class", "px-4 py-2 font-mono text-xs");
        hw.open("a");
        hw.attrFmt("href", "/ui/jobs/{s}", .{j.idSlice()});
        hw.attr("class", "text-blue-600 hover:underline");
        hw.text(j.idSlice());
        hw.close("a");
        hw.close("td");
        tableCell(hw, j.queueSlice());
        hw.open("td");
        hw.attr("class", "px-4 py-2");
        hw.open("span");
        hw.attr("class", stateBadgeClass(j.stateSlice()));
        hw.text(j.stateSlice());
        hw.close("span");
        hw.close("td");
        tableCellFmt(hw, "{d}", .{j.priority});
        tableCellFmt(hw, "{d}/{d}", .{ j.attempt, j.max_retries });
        timestampCell(hw, j.createdAtSlice());
        if (actions != .none) {
            hw.open("td");
            hw.attr("class", "px-4 py-2");
            hw.open("div");
            hw.attr("class", "flex gap-1");
            switch (actions) {
                .dead => {
                    rowAction(hw, j.idSlice(), "retry", "Retry", "text-blue-600 hover:text-blue-800");
                    rowAction(hw, j.idSlice(), "delete", "Delete", "text-red-600 hover:text-red-800");
                },
                .held => {
                    rowAction(hw, j.idSlice(), "approve", "Approve", "text-green-600 hover:text-green-800");
                    rowAction(hw, j.idSlice(), "reject", "Reject", "text-red-600 hover:text-red-800");
                },
                .scheduled => {
                    rowAction(hw, j.idSlice(), "run", "Run Now", "text-blue-600 hover:text-blue-800");
                    rowAction(hw, j.idSlice(), "delete", "Delete", "text-red-600 hover:text-red-800");
                },
                .queue_detail => {
                    rowAction(hw, j.idSlice(), "cancel", "Cancel", "text-yellow-600 hover:text-yellow-800");
                    rowAction(hw, j.idSlice(), "delete", "Delete", "text-red-600 hover:text-red-800");
                },
                .none => {},
            }
            hw.close("div");
            hw.close("td");
        }
        hw.close("tr");
    }
    hw.close("tbody");
    hw.close("table");
    hw.close("div");
}

// ============================================================================
// Reusable HTML Helpers
// ============================================================================

fn statCard(hw: *html.HtmlWriter, label: []const u8, value: i64, text_class: []const u8) void {
    hw.open("div");
    hw.attr("class", "bg-white rounded-lg border border-gray-200 p-4");
    hw.open("div");
    hw.attr("class", "text-xs font-medium text-gray-500 uppercase tracking-wider");
    hw.text(label);
    hw.close("div");
    hw.open("div");
    hw.attrFmt("class", "mt-1 text-2xl font-semibold {s}", .{text_class});
    hw.textFmt("{d}", .{value});
    hw.close("div");
    hw.close("div");
}

fn statCardInt(hw: *html.HtmlWriter, label: []const u8, value: i32, text_class: []const u8) void {
    hw.open("div");
    hw.attr("class", "bg-white rounded-lg border border-gray-200 p-4");
    hw.open("div");
    hw.attr("class", "text-xs font-medium text-gray-500 uppercase tracking-wider");
    hw.text(label);
    hw.close("div");
    hw.open("div");
    hw.attrFmt("class", "mt-1 text-2xl font-semibold {s}", .{text_class});
    hw.textFmt("{d}", .{value});
    hw.close("div");
    hw.close("div");
}

fn bulkButton(hw: *html.HtmlWriter, action: []const u8, label: []const u8, btn_class: []const u8) void {
    hw.open("button");
    hw.attrFmt("onclick", "corvoBulkAction('{s}')", .{action});
    hw.attrFmt("class", "px-3 py-1 text-xs font-medium text-white rounded {s}", .{btn_class});
    hw.text(label);
    hw.close("button");
}

fn rowAction(hw: *html.HtmlWriter, job_id: []const u8, action: []const u8, label: []const u8, class: []const u8) void {
    hw.open("button");
    hw.attrFmt("hx-post", "/api/v1/jobs/{s}/{s}", .{ job_id, action });
    hw.attr("hx-swap", "none");
    hw.attrFmt("class", "text-xs font-medium {s}", .{class});
    hw.text(label);
    hw.close("button");
}

fn tableHeader(hw: *html.HtmlWriter, label: []const u8) void {
    hw.open("th");
    hw.attr("class", "px-4 py-2 text-left text-xs font-medium text-gray-500 uppercase tracking-wider");
    hw.text(label);
    hw.close("th");
}

fn tableCell(hw: *html.HtmlWriter, value: []const u8) void {
    hw.open("td");
    hw.attr("class", "px-4 py-2 text-gray-700");
    hw.text(value);
    hw.close("td");
}

fn timestampCell(hw: *html.HtmlWriter, value: []const u8) void {
    hw.open("td");
    hw.attr("class", "px-4 py-2 text-gray-700");
    hw.open("time");
    hw.attr("data-ts", value);
    hw.text(value);
    hw.close("time");
    hw.close("td");
}

fn tableCellInt(hw: *html.HtmlWriter, value: i64) void {
    hw.open("td");
    hw.attr("class", "px-4 py-2 text-right text-gray-700 tabular-nums");
    hw.textFmt("{d}", .{value});
    hw.close("td");
}

fn tableCellFmt(hw: *html.HtmlWriter, comptime fmt: []const u8, args: anytype) void {
    hw.open("td");
    hw.attr("class", "px-4 py-2 text-gray-700");
    hw.textFmt(fmt, args);
    hw.close("td");
}

fn detailRow(hw: *html.HtmlWriter, label: []const u8, value: []const u8) void {
    hw.open("tr");
    hw.open("td");
    hw.attr("class", "px-4 py-2 text-gray-500 font-medium w-40");
    hw.text(label);
    hw.close("td");
    hw.open("td");
    hw.attr("class", "px-4 py-2 text-gray-900");
    hw.text(value);
    hw.close("td");
    hw.close("tr");
}

fn detailRowFmt(hw: *html.HtmlWriter, label: []const u8, comptime fmt: []const u8, args: anytype) void {
    hw.open("tr");
    hw.open("td");
    hw.attr("class", "px-4 py-2 text-gray-500 font-medium w-40");
    hw.text(label);
    hw.close("td");
    hw.open("td");
    hw.attr("class", "px-4 py-2 text-gray-900");
    hw.textFmt(fmt, args);
    hw.close("td");
    hw.close("tr");
}

fn timelineEntry(hw: *html.HtmlWriter, label: []const u8, timestamp: []const u8) void {
    const dot_color = if (eql(label, "Created")) "bg-blue-500"
        else if (eql(label, "Scheduled")) "bg-purple-500"
        else if (eql(label, "Started")) "bg-green-500"
        else if (eql(label, "Completed")) "bg-gray-500"
        else if (eql(label, "Failed")) "bg-red-500"
        else "bg-gray-400";
    hw.open("li");
    hw.attr("class", "ml-6");
    hw.open("span");
    hw.attrFmt("class", "absolute -left-1.5 w-3 h-3 rounded-full {s}", .{dot_color});
    hw.close("span");
    hw.open("div");
    hw.attr("class", "text-sm font-medium text-gray-900");
    hw.text(label);
    hw.close("div");
    hw.open("div");
    hw.attr("class", "text-xs text-gray-500");
    hw.open("time");
    hw.attr("data-ts", timestamp);
    hw.text(timestamp);
    hw.close("time");
    hw.close("div");
    hw.close("li");
}

fn stateBadgeClass(state: []const u8) []const u8 {
    if (eql(state, "pending")) return "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-blue-100 text-blue-800";
    if (eql(state, "active")) return "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-green-100 text-green-800";
    if (eql(state, "completed")) return "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-800";
    if (eql(state, "dead")) return "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-red-100 text-red-800";
    if (eql(state, "retrying")) return "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-orange-100 text-orange-800";
    if (eql(state, "scheduled")) return "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-purple-100 text-purple-800";
    if (eql(state, "held")) return "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-yellow-100 text-yellow-800";
    return "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium bg-gray-100 text-gray-800";
}

fn filterTab(hw: *html.HtmlWriter, queue_name: []const u8, state: ?[]const u8, label: []const u8, current_filter: ?[]const u8, qs: ?*const sqlite_read.QueueStats) void {
    const active = if (state) |s| (if (current_filter) |cf| eql(s, cf) else false) else current_filter == null;

    hw.open("a");
    if (state) |s| {
        hw.attrFmt("href", "/ui/queues/{s}?state={s}", .{ queue_name, s });
    } else {
        hw.attrFmt("href", "/ui/queues/{s}", .{queue_name});
    }
    hw.attr("class", if (active)
        "px-3 py-1.5 text-sm font-medium rounded-md bg-blue-100 text-blue-700"
    else
        "px-3 py-1.5 text-sm font-medium rounded-md text-gray-600 hover:bg-gray-100");
    hw.text(label);

    if (qs) |q| {
        const cnt: i32 = if (state) |s| blk: {
            if (eql(s, "pending")) break :blk q.pending;
            if (eql(s, "active")) break :blk q.active;
            if (eql(s, "retrying")) break :blk q.retrying;
            if (eql(s, "dead")) break :blk q.dead;
            if (eql(s, "completed")) break :blk q.completed;
            if (eql(s, "scheduled")) break :blk q.scheduled;
            if (eql(s, "held")) break :blk q.held;
            break :blk 0;
        } else q.pending + q.active + q.retrying + q.dead + q.completed + q.scheduled + q.held;

        hw.open("span");
        hw.attr("class", "ml-1 text-xs opacity-70");
        hw.textFmt("{d}", .{cnt});
        hw.close("span");
    }

    hw.close("a");
}

fn writePagination(hw: *html.HtmlWriter, base_url: []const u8, page: u32, total_pages: u32) void {
    if (total_pages <= 1) return;

    hw.open("div");
    hw.attr("class", "flex items-center justify-between mt-4");

    hw.open("span");
    hw.attr("class", "text-sm text-gray-500");
    hw.textFmt("Page {d} of {d}", .{ page + 1, total_pages });
    hw.close("span");

    hw.open("div");
    hw.attr("class", "flex gap-2");

    if (page > 0) {
        hw.open("a");
        hw.attrFmt("href", "{s}page={d}", .{ base_url, page - 1 });
        hw.attr("class", "px-3 py-1.5 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50");
        hw.raw("&larr; Previous");
        hw.close("a");
    }

    if (page + 1 < total_pages) {
        hw.open("a");
        hw.attrFmt("href", "{s}page={d}", .{ base_url, page + 1 });
        hw.attr("class", "px-3 py-1.5 text-sm font-medium text-gray-700 bg-white border border-gray-300 rounded-md hover:bg-gray-50");
        hw.raw("Next &rarr;");
        hw.close("a");
    }

    hw.close("div");
    hw.close("div");
}

fn writeExportButtons(hw: *html.HtmlWriter, state: ?[]const u8, queue: ?[]const u8) void {
    hw.open("button");
    hw.attrFmt("onclick", "corvoExport('json','{s}','{s}')", .{ state orelse "", queue orelse "" });
    hw.attr("class", "px-2 py-1 text-xs font-medium text-gray-600 bg-white border border-gray-300 rounded hover:bg-gray-50");
    hw.text("JSON");
    hw.close("button");
    hw.open("button");
    hw.attrFmt("onclick", "corvoExport('csv','{s}','{s}')", .{ state orelse "", queue orelse "" });
    hw.attr("class", "px-2 py-1 text-xs font-medium text-gray-600 bg-white border border-gray-300 rounded hover:bg-gray-50");
    hw.text("CSV");
    hw.close("button");
}

fn writeQueueFilter(hw: *html.HtmlWriter, rdr: *sqlite_read.Reader, base_path: []const u8, current_queue: ?[]const u8) void {
    var queue_buf: [64]sqlite_read.QueueStats = undefined;
    const count = rdr.getQueueStats(&queue_buf) catch 0;
    if (count == 0) return;

    hw.open("select");
    hw.attr("class", "px-3 py-1.5 border border-gray-300 rounded-md text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500");
    hw.attrFmt("onchange", "location.href=this.value?'{s}?queue='+this.value:'{s}'", .{ base_path, base_path });

    hw.open("option");
    hw.attr("value", "");
    hw.text("All Queues");
    hw.close("option");

    for (0..count) |i| {
        hw.open("option");
        hw.attr("value", queue_buf[i].nameSlice());
        if (current_queue) |cq| {
            if (eql(cq, queue_buf[i].nameSlice())) hw.attrBool("selected");
        }
        hw.text(queue_buf[i].nameSlice());
        hw.close("option");
    }

    hw.close("select");
}

fn queueStateCount(q: *const sqlite_read.QueueStats, state: ?[]const u8) u32 {
    const val: i32 = if (state) |s| blk: {
        if (eql(s, "pending")) break :blk q.pending;
        if (eql(s, "active")) break :blk q.active;
        if (eql(s, "retrying")) break :blk q.retrying;
        if (eql(s, "dead")) break :blk q.dead;
        if (eql(s, "completed")) break :blk q.completed;
        if (eql(s, "scheduled")) break :blk q.scheduled;
        if (eql(s, "held")) break :blk q.held;
        break :blk 0;
    } else q.pending + q.active + q.retrying + q.dead + q.completed + q.scheduled + q.held;
    return @intCast(@max(val, 0));
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

fn writeQueueActionButton(hw: *html.HtmlWriter, queue_name: []const u8, action: []const u8, label: []const u8, btn_class: []const u8) void {
    hw.open("button");
    hw.attrFmt("hx-post", "/api/v1/queues/{s}/{s}", .{ queue_name, action });
    hw.attr("hx-swap", "none");
    hw.attrFmt("class", "px-3 py-1.5 text-xs font-medium text-white rounded {s}", .{btn_class});
    hw.text(label);
    hw.close("button");
}

fn writeJobActionButton(hw: *html.HtmlWriter, job_id: []const u8, action: []const u8, label: []const u8, btn_class: []const u8) void {
    hw.open("button");
    hw.attrFmt("hx-post", "/api/v1/jobs/{s}/{s}", .{ job_id, action });
    hw.attr("hx-swap", "none");
    hw.attrFmt("class", "px-3 py-1.5 text-xs font-medium text-white rounded {s}", .{btn_class});
    hw.text(label);
    hw.close("button");
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
