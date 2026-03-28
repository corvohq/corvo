//! Server-rendered HTML UI — HTMX + Tailwind CSS dashboard.
//!
//! Pure functions: take send_buf + reader, return response length.
//! Renders complete HTML pages or HTMX partial fragments.
//!
//! Minimum send_buf: 17KB. The largest embedded asset (htmx.min.js.gz)
//! is ~16.3KB; HTML pages are capped at page_buf_size to stay within bounds.

const std = @import("std");
const http = @import("http.zig");
const html = @import("html_writer.zig");
const sqlite_read = @import("sqlite_read.zig");

/// Max HTML body size. Pages render into a buffer of this size.
/// With HTTP headers (~200 bytes), total response stays under 33KB.
const page_buf_size = 32768;

/// Max table rows per page. Keeps HTML under page_buf_size.
const max_table_rows = 25;

// ============================================================================
// Dispatch
// ============================================================================

/// Route a UI page request. Returns bytes written to send_buf.
pub fn dispatch(path: []const u8, send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    // Full page routes.
    if (eql(path, "/") or eql(path, "")) return dashboard(send_buf, reader);
    if (eql(path, "/queues")) return queuesPage(send_buf, reader);
    if (std.mem.startsWith(u8, path, "/queues/")) return queueDetailPage(send_buf, reader, path["/queues/".len..]);
    if (eql(path, "/dead-letter")) return deadLetterPage(send_buf, reader);
    if (eql(path, "/held")) return heldJobsPage(send_buf, reader);
    if (eql(path, "/scheduled")) return scheduledJobsPage(send_buf, reader);
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
// Full Pages
// ============================================================================

fn dashboard(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);

    layoutStart(&hw, "Dashboard", "/");

    // Stats cards container — auto-refreshes via HTMX.
    hw.open("div");
    hw.attr("id", "dashboard-stats");
    hw.attr("hx-get", "/ui/partials/dashboard-stats");
    hw.attr("hx-trigger", "every 5s");
    hw.attr("hx-swap", "innerHTML");
    writeDashboardStats(&hw, reader);
    hw.close("div");

    layoutEnd(&hw);
    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
}

fn queuesPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);

    layoutStart(&hw, "Queues", "/queues");

    hw.open("div");
    hw.attr("id", "queues-table");
    hw.attr("hx-get", "/ui/partials/queues-table");
    hw.attr("hx-trigger", "every 5s");
    hw.attr("hx-swap", "innerHTML");
    writeQueuesTable(&hw, reader);
    hw.close("div");

    layoutEnd(&hw);
    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
}

fn queueDetailPage(send_buf: []u8, reader: ?*sqlite_read.Reader, queue_name: []const u8) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);

    layoutStart(&hw, "Queue Detail", "/queues");

    hw.open("div");
    hw.attr("class", "space-y-6");

    // Queue header with actions.
    hw.open("div");
    hw.attr("class", "flex items-center justify-between");
    hw.open("h2");
    hw.attr("class", "text-xl font-semibold text-gray-900");
    hw.text(queue_name);
    hw.close("h2");
    hw.open("div");
    hw.attr("class", "flex gap-2");
    writeQueueActionButton(&hw, queue_name, "pause", "Pause", "bg-yellow-500 hover:bg-yellow-600");
    writeQueueActionButton(&hw, queue_name, "resume", "Resume", "bg-green-500 hover:bg-green-600");
    writeQueueActionButton(&hw, queue_name, "drain", "Drain", "bg-blue-500 hover:bg-blue-600");
    hw.close("div");
    hw.close("div");

    // Jobs for this queue.
    writeQueueJobsTable(&hw, reader, queue_name);

    hw.close("div");

    layoutEnd(&hw);
    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
}

fn deadLetterPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    return jobListPage(send_buf, reader, "Dead Letter", "dead", "/dead-letter", .dead);
}

fn heldJobsPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    return jobListPage(send_buf, reader, "Held Jobs", "held", "/held", .held);
}

fn scheduledJobsPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    return jobListPage(send_buf, reader, "Scheduled Jobs", "scheduled", "/scheduled", .scheduled);
}

fn jobListPage(send_buf: []u8, reader: ?*sqlite_read.Reader, title: []const u8, state: []const u8, nav_path: []const u8, actions: RowActions) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);

    layoutStart(&hw, title, nav_path);

    const rdr = reader orelse {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No data available");
        hw.close("p");
        layoutEnd(&hw);
        return http.writeResponseHtml(send_buf, 200, hw.getWritten());
    };

    var job_buf: [max_table_rows]sqlite_read.JobRow = undefined;
    const count = rdr.queryJobsByQueueState(null, state, max_table_rows, 0, &job_buf) catch 0;

    writeJobTable(&hw, job_buf[0..count], actions);

    layoutEnd(&hw);
    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
}

fn jobDetailPage(send_buf: []u8, reader: ?*sqlite_read.Reader, job_id: []const u8) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);

    layoutStart(&hw, "Job Detail", "/jobs");

    const rdr = reader orelse {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No data available");
        hw.close("p");
        layoutEnd(&hw);
        return http.writeResponseHtml(send_buf, 200, hw.getWritten());
    };

    const j = (rdr.getJob(job_id) catch null) orelse {
        hw.open("p");
        hw.attr("class", "text-red-500");
        hw.text("Job not found");
        hw.close("p");
        layoutEnd(&hw);
        return http.writeResponseHtml(send_buf, 200, hw.getWritten());
    };

    hw.open("div");
    hw.attr("class", "space-y-6");

    // Header with actions.
    hw.open("div");
    hw.attr("class", "flex items-center justify-between");
    hw.open("div");
    hw.open("h2");
    hw.attr("class", "text-xl font-semibold text-gray-900");
    hw.text(j.idSlice());
    hw.close("h2");
    hw.open("span");
    hw.attr("class", stateBadgeClass(j.stateSlice()));
    hw.text(j.stateSlice());
    hw.close("span");
    hw.close("div");
    hw.open("div");
    hw.attr("class", "flex gap-2");
    writeJobActionButton(&hw, job_id, "retry", "Retry", "bg-blue-500 hover:bg-blue-600");
    writeJobActionButton(&hw, job_id, "cancel", "Cancel", "bg-yellow-500 hover:bg-yellow-600");
    writeJobActionButton(&hw, job_id, "delete", "Delete", "bg-red-500 hover:bg-red-600");
    hw.close("div");
    hw.close("div");

    // Details table.
    hw.open("div");
    hw.attr("class", "bg-white border border-gray-200 rounded-lg overflow-hidden");
    hw.open("table");
    hw.attr("class", "w-full text-sm");
    hw.open("tbody");
    hw.attr("class", "divide-y divide-gray-100");
    detailRow(&hw, "Queue", j.queueSlice());
    detailRow(&hw, "State", j.stateSlice());
    detailRowFmt(&hw, "Priority", "{d}", .{j.priority});
    detailRowFmt(&hw, "Attempt", "{d}/{d}", .{ j.attempt, j.max_retries });
    if (j.worker_id_len > 0) detailRow(&hw, "Worker", j.workerIdSlice());
    if (j.created_at_len > 0) detailRow(&hw, "Created", j.createdAtSlice());
    if (j.started_at_len > 0) detailRow(&hw, "Started", j.startedAtSlice());
    if (j.completed_at_len > 0) detailRow(&hw, "Completed", j.completedAtSlice());
    if (j.failed_at_len > 0) detailRow(&hw, "Failed", j.failedAtSlice());
    if (j.scheduled_at_len > 0) detailRow(&hw, "Scheduled", j.scheduledAtSlice());
    hw.close("tbody");
    hw.close("table");
    hw.close("div");

    // Payload.
    var payload_buf: [4096]u8 = undefined;
    if (rdr.getJobPayload(job_id, &payload_buf) catch null) |payload| {
        hw.open("div");
        hw.attr("class", "space-y-2");
        hw.elem("h3", "Payload");
        hw.open("pre");
        hw.attr("class", "bg-gray-50 border border-gray-200 rounded-lg p-4 text-xs overflow-x-auto");
        hw.text(payload);
        hw.close("pre");
        hw.close("div");
    }

    hw.close("div");

    layoutEnd(&hw);
    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
}

fn workersPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);

    layoutStart(&hw, "Workers", "/workers");

    const rdr = reader orelse {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No data available");
        hw.close("p");
        layoutEnd(&hw);
        return http.writeResponseHtml(send_buf, 200, hw.getWritten());
    };

    var worker_buf: [64]sqlite_read.WorkerRow = undefined;
    const count = rdr.getWorkers(&worker_buf) catch 0;

    if (count == 0) {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No workers connected");
        hw.close("p");
    } else {
        hw.open("div");
        hw.attr("class", "bg-white border border-gray-200 rounded-lg overflow-hidden");
        hw.open("table");
        hw.attr("class", "w-full text-sm");
        hw.open("thead");
        hw.open("tr");
        hw.attr("class", "border-b border-gray-200 bg-gray-50");
        tableHeader(&hw, "ID");
        tableHeader(&hw, "Hostname");
        tableHeader(&hw, "Queues");
        tableHeader(&hw, "Last Heartbeat");
        tableHeader(&hw, "Started");
        hw.close("tr");
        hw.close("thead");
        hw.open("tbody");
        hw.attr("class", "divide-y divide-gray-100");
        for (0..count) |i| {
            const wk = &worker_buf[i];
            hw.open("tr");
            hw.attr("class", "hover:bg-gray-50");
            tableCell(&hw, wk.idSlice());
            tableCell(&hw, wk.hostnameSlice());
            tableCell(&hw, wk.queuesSlice());
            tableCell(&hw, wk.lastHeartbeatSlice());
            tableCell(&hw, wk.startedAtSlice());
            hw.close("tr");
        }
        hw.close("tbody");
        hw.close("table");
        hw.close("div");
    }

    layoutEnd(&hw);
    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
}

fn clusterPage(send_buf: []u8, _: ?*sqlite_read.Reader) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);

    layoutStart(&hw, "Cluster", "/cluster");

    hw.open("div");
    hw.attr("class", "bg-white border border-gray-200 rounded-lg p-6");
    hw.open("div");
    hw.attr("class", "space-y-4");
    hw.open("div");
    hw.attr("class", "flex items-center gap-2");
    hw.open("span");
    hw.attr("class", "inline-block w-2 h-2 rounded-full bg-green-500");
    hw.close("span");
    hw.elem("span", "Standalone Mode");
    hw.close("div");
    detailRow(&hw, "Node ID", "node-1");
    detailRow(&hw, "State", "leader");
    detailRow(&hw, "Status", "healthy");
    hw.close("div");
    hw.close("div");

    layoutEnd(&hw);
    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
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
    var buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&buf);

    // Modal backdrop.
    hw.open("div");
    hw.attr("class", "fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50");
    hw.attr("onclick", "if(event.target===this)document.getElementById('modal').innerHTML=''");

    // Modal content.
    hw.open("div");
    hw.attr("class", "bg-white rounded-lg shadow-xl w-full max-w-lg p-6");

    hw.open("div");
    hw.attr("class", "flex items-center justify-between mb-4");
    hw.elem("h2", "Enqueue Job");
    hw.open("button");
    hw.attr("onclick", "document.getElementById('modal').innerHTML=''");
    hw.attr("class", "text-gray-400 hover:text-gray-600 text-xl");
    hw.raw("&times;");
    hw.close("button");
    hw.close("div");

    hw.open("form");
    hw.attr("hx-post", "/api/v1/enqueue");
    hw.attr("hx-swap", "none");
    hw.attr("hx-on::after-request", "if(event.detail.successful)document.getElementById('modal').innerHTML=''");

    formField(&hw, "queue", "Queue", "text", "default");
    formTextarea(&hw, "payload", "Payload (JSON)", "{\"key\": \"value\"}");

    hw.open("div");
    hw.attr("class", "flex gap-2 mt-4");
    hw.open("button");
    hw.attr("type", "submit");
    hw.attr("class", "px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-lg hover:bg-blue-700");
    hw.text("Enqueue");
    hw.close("button");
    hw.open("button");
    hw.attr("type", "button");
    hw.attr("onclick", "document.getElementById('modal').innerHTML=''");
    hw.attr("class", "px-4 py-2 text-sm font-medium text-gray-700 bg-gray-100 rounded-lg hover:bg-gray-200");
    hw.text("Cancel");
    hw.close("button");
    hw.close("div");

    hw.close("form");
    hw.close("div"); // modal content
    hw.close("div"); // backdrop

    return http.writeResponseHtml(send_buf, 200, hw.getWritten());
}

fn formField(hw: *html.HtmlWriter, name: []const u8, label_text: []const u8, input_type: []const u8, placeholder: []const u8) void {
    hw.open("div");
    hw.attr("class", "mb-3");
    hw.open("label");
    hw.attr("class", "block text-sm font-medium text-gray-700 mb-1");
    hw.text(label_text);
    hw.close("label");
    hw.voidElem("input");
    hw.attr("type", input_type);
    hw.attr("name", name);
    hw.attr("placeholder", placeholder);
    hw.attr("class", "w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500");
    hw.close("div");
}

fn formTextarea(hw: *html.HtmlWriter, name: []const u8, label_text: []const u8, placeholder: []const u8) void {
    hw.open("div");
    hw.attr("class", "mb-3");
    hw.open("label");
    hw.attr("class", "block text-sm font-medium text-gray-700 mb-1");
    hw.text(label_text);
    hw.close("label");
    hw.open("textarea");
    hw.attr("name", name);
    hw.attr("rows", "4");
    hw.attr("placeholder", placeholder);
    hw.attr("class", "w-full px-3 py-2 border border-gray-300 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 font-mono");
    hw.close("textarea");
    hw.close("div");
}

// ============================================================================
// Layout
// ============================================================================

fn layoutStart(hw: *html.HtmlWriter, title: []const u8, current_path: []const u8) void {
    hw.doctype();
    hw.open("html");
    hw.attr("lang", "en");
    hw.open("head");
    hw.voidElem("meta");
    hw.attr("charset", "UTF-8");
    hw.voidElem("meta");
    hw.attr("name", "viewport");
    hw.attr("content", "width=device-width, initial-scale=1.0");
    hw.open("title");
    hw.text(title);
    hw.raw(" - Corvo");
    hw.close("title");
    hw.voidElem("link");
    hw.attr("rel", "icon");
    hw.attr("href", "/ui/favicon.svg");
    hw.voidElem("link");
    hw.attr("rel", "stylesheet");
    hw.attr("href", "/ui/tailwind.css");
    hw.open("script");
    hw.attr("src", "/ui/htmx.min.js");
    hw.close("script");
    hw.close("head");

    hw.open("body");
    hw.attr("class", "bg-gray-50 text-gray-900 min-h-screen");

    // Shell: sidebar + main content.
    hw.open("div");
    hw.attr("class", "flex min-h-screen");

    // Toast container for HTMX action feedback.
    hw.open("div");
    hw.attr("id", "toast");
    hw.attr("class", "fixed top-4 right-4 z-50");
    hw.close("div");

    // Sidebar.
    writeSidebar(hw, current_path);

    // Main content area.
    hw.open("main");
    hw.attr("class", "flex-1 p-6");

    hw.open("div");
    hw.attr("class", "max-w-7xl mx-auto");

    // Page header with enqueue button.
    hw.open("div");
    hw.attr("class", "flex items-center justify-between mb-6");
    hw.open("h1");
    hw.attr("class", "text-2xl font-bold text-gray-900");
    hw.text(title);
    hw.close("h1");
    hw.open("button");
    hw.attr("hx-get", "/ui/partials/enqueue-form");
    hw.attr("hx-target", "#modal");
    hw.attr("hx-swap", "innerHTML");
    hw.attr("class", "px-4 py-2 text-sm font-medium text-white bg-blue-600 rounded-lg hover:bg-blue-700");
    hw.text("Enqueue Job");
    hw.close("button");
    hw.close("div");

    // Modal container.
    hw.open("div");
    hw.attr("id", "modal");
    hw.close("div");
}

fn layoutEnd(hw: *html.HtmlWriter) void {
    hw.close("div"); // max-w-7xl
    hw.close("main");
    hw.close("div"); // flex shell

    // Toast script: show success/error after HTMX POST actions.
    hw.open("script");
    hw.raw(
        \\document.body.addEventListener('htmx:afterRequest',function(e){
        \\var t=document.getElementById('toast');if(!t)return;
        \\var ok=e.detail.successful;
        \\var c=ok?'bg-green-600':'bg-red-600';
        \\var m=ok?'Done':'Error';
        \\t.innerHTML='<div class="'+c+' text-white px-4 py-2 rounded shadow text-sm">'+m+'</div>';
        \\setTimeout(function(){t.innerHTML=''},2000)
        \\})
    );
    hw.close("script");

    hw.close("body");
    hw.close("html");
}

fn writeSidebar(hw: *html.HtmlWriter, current_path: []const u8) void {
    hw.open("aside");
    hw.attr("class", "w-56 bg-white border-r border-gray-200 flex flex-col min-h-screen");

    // Logo.
    hw.open("div");
    hw.attr("class", "h-14 flex items-center px-4 border-b border-gray-200");
    hw.open("a");
    hw.attr("href", "/ui/");
    hw.voidElem("img");
    hw.attr("src", "/ui/logo-full.svg");
    hw.attr("alt", "Corvo");
    hw.attr("class", "h-6");
    hw.close("a");
    hw.close("div");

    // Nav links.
    hw.open("nav");
    hw.attr("class", "flex-1 p-3 space-y-1");
    navLink(hw, "/ui/", "Dashboard", current_path);
    navLink(hw, "/ui/queues", "Queues", current_path);
    navLink(hw, "/ui/scheduled", "Scheduled", current_path);
    navLink(hw, "/ui/dead-letter", "Dead Letter", current_path);
    navLink(hw, "/ui/held", "Held Jobs", current_path);
    navLink(hw, "/ui/workers", "Workers", current_path);
    navLink(hw, "/ui/cluster", "Cluster", current_path);
    hw.close("nav");

    hw.close("aside");
}

const nav_base = "flex items-center gap-3 rounded-md px-3 py-2 text-sm font-medium transition-colors ";
const nav_active = nav_base ++ "bg-gray-100 text-gray-900";
const nav_inactive = nav_base ++ "text-gray-500 hover:bg-gray-50 hover:text-gray-900";

fn navLink(hw: *html.HtmlWriter, href: []const u8, label: []const u8, current_path: []const u8) void {
    // Match: "/ui/" is active only for exact "/", others match prefix.
    const full_current = current_path;
    const active = if (eql(href, "/ui/"))
        eql(full_current, "/") or eql(full_current, "")
    else blk: {
        const nav_path = href["/ui".len..];
        break :blk eql(full_current, nav_path) or std.mem.startsWith(u8, full_current, nav_path);
    };

    hw.open("a");
    hw.attr("href", href);
    hw.attr("class", if (active) nav_active else nav_inactive);
    hw.text(label);
    hw.close("a");
}

// ============================================================================
// Shared Components
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
    statCard(hw, "Pending", total_pending, "text-blue-600", "bg-blue-50");
    statCard(hw, "Active", total_active, "text-green-600", "bg-green-50");
    statCard(hw, "Completed", total_completed, "text-gray-600", "bg-gray-50");
    statCard(hw, "Dead", total_dead, "text-red-600", "bg-red-50");
    statCardInt(hw, "Workers", worker_count, "text-purple-600", "bg-purple-50");
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
    // Find max value for scaling.
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

        // Bar.
        hw.open("rect");
        hw.attrFmt("x", "{d}", .{x});
        hw.attrFmt("y", "{d}", .{y});
        hw.attrFmt("width", "{d}", .{bar_w});
        hw.attrFmt("height", "{d}", .{bar_h});
        hw.attr("fill", "#3b82f6");
        hw.attr("rx", "2");
        hw.close("rect");

        // Label.
        hw.open("text");
        hw.attrFmt("x", "{d}", .{x + bar_w / 2});
        hw.attrFmt("y", "{d}", .{chart_h + 16});
        hw.attr("text-anchor", "middle");
        hw.attr("class", "text-xs fill-gray-500");
        hw.text(q.nameSlice());
        hw.close("text");

        // Value on top.
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

fn statCard(hw: *html.HtmlWriter, label: []const u8, value: i64, text_class: []const u8, bg_class: []const u8) void {
    hw.open("div");
    hw.attrFmt("class", "rounded-lg border border-gray-200 p-4 {s}", .{bg_class});
    hw.open("div");
    hw.attr("class", "text-xs font-medium text-gray-500 uppercase tracking-wider");
    hw.text(label);
    hw.close("div");
    hw.open("div");
    hw.attrFmt("class", "mt-1 text-2xl font-bold {s}", .{text_class});
    hw.textFmt("{d}", .{value});
    hw.close("div");
    hw.close("div");
}

fn statCardInt(hw: *html.HtmlWriter, label: []const u8, value: i32, text_class: []const u8, bg_class: []const u8) void {
    hw.open("div");
    hw.attrFmt("class", "rounded-lg border border-gray-200 p-4 {s}", .{bg_class});
    hw.open("div");
    hw.attr("class", "text-xs font-medium text-gray-500 uppercase tracking-wider");
    hw.text(label);
    hw.close("div");
    hw.open("div");
    hw.attrFmt("class", "mt-1 text-2xl font-bold {s}", .{text_class});
    hw.textFmt("{d}", .{value});
    hw.close("div");
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
    hw.attr("class", "bg-white border border-gray-200 rounded-lg overflow-hidden");
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
        // Queue name as link.
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
        // Status badge.
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

fn writeQueueJobsTable(hw: *html.HtmlWriter, reader: ?*sqlite_read.Reader, queue_name: []const u8) void {
    const rdr = reader orelse return;
    var job_buf: [max_table_rows]sqlite_read.JobRow = undefined;
    const count = rdr.queryJobsByQueueState(queue_name, null, max_table_rows, 0, &job_buf) catch 0;
    writeJobTable(hw, job_buf[0..count], .queue_detail);
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

    hw.open("div");
    hw.attr("class", "bg-white border border-gray-200 rounded-lg overflow-hidden");
    hw.open("table");
    hw.attr("class", "w-full text-sm");
    hw.open("thead");
    hw.open("tr");
    hw.attr("class", "border-b border-gray-200 bg-gray-50");
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
        // Job ID as link.
        hw.open("td");
        hw.attr("class", "px-4 py-2 font-mono text-xs");
        hw.open("a");
        hw.attrFmt("href", "/ui/jobs/{s}", .{j.idSlice()});
        hw.attr("class", "text-blue-600 hover:underline");
        hw.text(j.idSlice());
        hw.close("a");
        hw.close("td");
        tableCell(hw, j.queueSlice());
        // State badge.
        hw.open("td");
        hw.attr("class", "px-4 py-2");
        hw.open("span");
        hw.attr("class", stateBadgeClass(j.stateSlice()));
        hw.text(j.stateSlice());
        hw.close("span");
        hw.close("td");
        tableCellFmt(hw, "{d}", .{j.priority});
        tableCellFmt(hw, "{d}/{d}", .{ j.attempt, j.max_retries });
        tableCell(hw, j.createdAtSlice());
        // Row actions.
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

fn rowAction(hw: *html.HtmlWriter, job_id: []const u8, action: []const u8, label: []const u8, class: []const u8) void {
    hw.open("button");
    hw.attrFmt("hx-post", "/api/v1/jobs/{s}/{s}", .{ job_id, action });
    hw.attr("hx-swap", "none");
    hw.attrFmt("class", "text-xs font-medium {s}", .{class});
    hw.text(label);
    hw.close("button");
}

// ============================================================================
// Reusable HTML Helpers
// ============================================================================

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

fn tableCellInt(hw: *html.HtmlWriter, value: i64) void {
    hw.open("td");
    hw.attr("class", "px-4 py-2 text-gray-700 tabular-nums");
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
