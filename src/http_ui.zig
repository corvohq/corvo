//! Server-rendered HTML UI — HTMX + Tailwind CSS dashboard.
//!
//! Pure functions: take send_buf + reader, return response length.
//! Renders complete HTML pages or HTMX partial fragments.
//!
//! Layout shell (sidebar, header, scripts) lives in ui/templates/layout.html.
//! Page functions render only their content, then splice it into the template.

const std = @import("std");
const http = @import("http.zig");
const html = @import("html_writer.zig");
const sqlite_read = @import("sqlite_read.zig");
const ui_embed = @import("ui_embed");

/// Max HTML body size. Pages render into a buffer of this size.
/// With HTTP headers (~200 bytes), total response stays under 33KB.
const page_buf_size = 32768;

/// Max table rows per page. Keeps HTML under page_buf_size.
const max_table_rows = 25;

/// Layout template — full page shell with {{title}} and {{content}} placeholders.
const layout_template = ui_embed.layout_html;

// Compile-time template validation: all {{ have matching }}, all keys are known.
comptime {
    @setEvalBranchQuota(layout_template.len * 2);
    var pos: usize = 0;
    while (pos < layout_template.len -| 1) : (pos += 1) {
        if (layout_template[pos] == '{' and layout_template[pos + 1] == '{') {
            const close = std.mem.indexOfPos(u8, layout_template, pos + 2, "}}") orelse
                @compileError("layout.html: unclosed {{ placeholder");
            const key = layout_template[pos + 2 .. close];
            if (!std.mem.eql(u8, key, "title") and !std.mem.eql(u8, key, "content")) {
                @compileError("layout.html: unknown placeholder: " ++ key);
            }
            pos = close + 1;
        }
    }
}

// ============================================================================
// Dispatch
// ============================================================================

/// Route a UI page request. Returns bytes written to send_buf.
pub fn dispatch(path: []const u8, query: []const u8, send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    // Full page routes.
    if (eql(path, "/") or eql(path, "")) return dashboard(send_buf, reader);
    if (eql(path, "/queues")) return queuesPage(send_buf, reader);
    if (std.mem.startsWith(u8, path, "/queues/")) return queueDetailPage(send_buf, reader, path["/queues/".len..], query);
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
// Template Rendering
// ============================================================================

/// Splice title and content into the layout template, then write the HTTP response.
fn renderPage(send_buf: []u8, title: []const u8, content: []const u8) u32 {
    var buf: [page_buf_size]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const w = stream.writer();
    var pos: usize = 0;

    while (std.mem.indexOfPos(u8, layout_template, pos, "{{")) |start| {
        w.writeAll(layout_template[pos..start]) catch unreachable;
        const close = (std.mem.indexOfPos(u8, layout_template, start + 2, "}}") orelse unreachable) + 2;
        const key = layout_template[start + 2 .. close - 2];
        if (eql(key, "title")) {
            w.writeAll(title) catch unreachable;
        } else if (eql(key, "content")) {
            w.writeAll(content) catch unreachable;
        }
        pos = close;
    }
    w.writeAll(layout_template[pos..]) catch unreachable;

    return http.writeResponseHtml(send_buf, 200, stream.getWritten());
}

// ============================================================================
// Full Pages
// ============================================================================

fn dashboard(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var content_buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&content_buf);

    // Stats cards container — auto-refreshes via HTMX.
    hw.open("div");
    hw.attr("id", "dashboard-stats");
    hw.attr("hx-get", "/ui/partials/dashboard-stats");
    hw.attr("hx-trigger", "every 5s");
    hw.attr("hx-swap", "innerHTML");
    writeDashboardStats(&hw, reader);
    hw.close("div");

    return renderPage(send_buf, "Dashboard", hw.getWritten());
}

fn queuesPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var content_buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&content_buf);

    hw.open("div");
    hw.attr("id", "queues-table");
    hw.attr("hx-get", "/ui/partials/queues-table");
    hw.attr("hx-trigger", "every 5s");
    hw.attr("hx-swap", "innerHTML");
    writeQueuesTable(&hw, reader);
    hw.close("div");

    return renderPage(send_buf, "Queues", hw.getWritten());
}

fn queueDetailPage(send_buf: []u8, reader: ?*sqlite_read.Reader, queue_name: []const u8, query: []const u8) u32 {
    var content_buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&content_buf);

    const state_filter = getQueryParam(query, "state");

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

    // Stats bar — per-state counts for this queue.
    const rdr = reader orelse {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No data available");
        hw.close("p");
        hw.close("div");
        return renderPage(send_buf, "Queue Detail", hw.getWritten());
    };

    var queue_buf: [64]sqlite_read.QueueStats = undefined;
    const q_count = rdr.getQueueStats(&queue_buf) catch 0;
    var qs: ?*const sqlite_read.QueueStats = null;
    for (0..q_count) |i| {
        if (eql(queue_buf[i].nameSlice(), queue_name)) {
            qs = &queue_buf[i];
            break;
        }
    }

    if (qs) |q| {
        hw.open("div");
        hw.attr("class", "grid grid-cols-2 md:grid-cols-4 gap-4");
        statCard(&hw, "Pending", q.pending, "text-blue-700");
        statCard(&hw, "Active", q.active, "text-green-700");
        statCard(&hw, "Dead", q.dead, "text-red-600");
        statCardInt(&hw, "Completed", q.completed, "text-gray-900");
        hw.close("div");
    }

    // Filter tabs + search bar.
    hw.open("div");
    hw.attr("class", "flex flex-col sm:flex-row sm:items-center gap-3");

    // Tabs.
    hw.open("div");
    hw.attr("class", "flex flex-wrap gap-1");
    filterTab(&hw, queue_name, null, "All", state_filter, qs);
    filterTab(&hw, queue_name, "pending", "Pending", state_filter, qs);
    filterTab(&hw, queue_name, "active", "Active", state_filter, qs);
    filterTab(&hw, queue_name, "retrying", "Retrying", state_filter, qs);
    filterTab(&hw, queue_name, "dead", "Dead", state_filter, qs);
    filterTab(&hw, queue_name, "completed", "Completed", state_filter, qs);
    filterTab(&hw, queue_name, "scheduled", "Scheduled", state_filter, qs);
    filterTab(&hw, queue_name, "held", "Held", state_filter, qs);
    hw.close("div");

    // Search bar.
    hw.voidElem("input");
    hw.attr("type", "text");
    hw.attr("placeholder", "Filter jobs...");
    hw.attr("class", "px-3 py-1.5 border border-gray-300 rounded-md text-sm focus:ring-2 focus:ring-blue-500 focus:border-blue-500 sm:ml-auto w-full sm:w-48");
    hw.attr("oninput", "corvoFilterRows(this.value)");

    hw.close("div");

    // Job table — filtered by state.
    hw.open("div");
    hw.attr("id", "queue-jobs");
    var job_buf: [max_table_rows]sqlite_read.JobRow = undefined;
    const count = rdr.queryJobsByQueueState(queue_name, state_filter, max_table_rows, 0, &job_buf) catch 0;
    writeJobTable(&hw, job_buf[0..count], .queue_detail);
    hw.close("div");

    hw.close("div");

    return renderPage(send_buf, "Queue Detail", hw.getWritten());
}

fn deadLetterPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    return jobListPage(send_buf, reader, "Dead Letter", "dead", .dead);
}

fn heldJobsPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    return jobListPage(send_buf, reader, "Held Jobs", "held", .held);
}

fn scheduledJobsPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    return jobListPage(send_buf, reader, "Scheduled Jobs", "scheduled", .scheduled);
}

fn jobListPage(send_buf: []u8, reader: ?*sqlite_read.Reader, title: []const u8, state: []const u8, actions: RowActions) u32 {
    var content_buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&content_buf);

    const rdr = reader orelse {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No data available");
        hw.close("p");
        return renderPage(send_buf, title, hw.getWritten());
    };

    var job_buf: [max_table_rows]sqlite_read.JobRow = undefined;
    const count = rdr.queryJobsByQueueState(null, state, max_table_rows, 0, &job_buf) catch 0;

    writeJobTable(&hw, job_buf[0..count], actions);

    return renderPage(send_buf, title, hw.getWritten());
}

fn jobDetailPage(send_buf: []u8, reader: ?*sqlite_read.Reader, job_id: []const u8) u32 {
    var content_buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&content_buf);

    const rdr = reader orelse {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No data available");
        hw.close("p");
        return renderPage(send_buf, "Job Detail", hw.getWritten());
    };

    const j = (rdr.getJob(job_id) catch null) orelse {
        hw.open("p");
        hw.attr("class", "text-red-500");
        hw.text("Job not found");
        hw.close("p");
        return renderPage(send_buf, "Job Detail", hw.getWritten());
    };

    hw.open("div");
    hw.attr("class", "space-y-6");

    // Header: job ID + state badge + actions.
    hw.open("div");
    hw.attr("class", "flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3");
    hw.open("div");
    hw.attr("class", "flex items-center gap-3");
    hw.open("h2");
    hw.attr("class", "text-xl font-semibold text-gray-900 font-mono");
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

    // Metadata grid — 2-column layout.
    hw.open("div");
    hw.attr("class", "grid grid-cols-1 md:grid-cols-2 gap-6");

    // Left column: job properties.
    hw.open("div");
    hw.attr("class", "bg-white border border-gray-200 rounded-lg");
    hw.open("div");
    hw.attr("class", "px-4 py-3 border-b border-gray-200");
    hw.open("h3");
    hw.attr("class", "text-sm font-semibold text-gray-900");
    hw.text("Properties");
    hw.close("h3");
    hw.close("div");
    hw.open("table");
    hw.attr("class", "w-full text-sm");
    hw.open("tbody");
    hw.attr("class", "divide-y divide-gray-100");
    detailRow(&hw, "Queue", j.queueSlice());
    detailRow(&hw, "State", j.stateSlice());
    detailRowFmt(&hw, "Priority", "{d}", .{j.priority});
    detailRowFmt(&hw, "Attempt", "{d}/{d}", .{ j.attempt, j.max_retries });
    if (j.worker_id_len > 0) detailRow(&hw, "Worker", j.workerIdSlice());
    hw.close("tbody");
    hw.close("table");
    hw.close("div");

    // Right column: timestamps.
    hw.open("div");
    hw.attr("class", "bg-white border border-gray-200 rounded-lg");
    hw.open("div");
    hw.attr("class", "px-4 py-3 border-b border-gray-200");
    hw.open("h3");
    hw.attr("class", "text-sm font-semibold text-gray-900");
    hw.text("Timeline");
    hw.close("h3");
    hw.close("div");
    hw.open("div");
    hw.attr("class", "p-4");
    hw.open("ol");
    hw.attr("class", "relative border-l border-gray-200 ml-3 space-y-4");
    if (j.created_at_len > 0) timelineEntry(&hw, "Created", j.createdAtSlice(), "bg-blue-500");
    if (j.scheduled_at_len > 0) timelineEntry(&hw, "Scheduled", j.scheduledAtSlice(), "bg-purple-500");
    if (j.started_at_len > 0) timelineEntry(&hw, "Started", j.startedAtSlice(), "bg-green-500");
    if (j.completed_at_len > 0) timelineEntry(&hw, "Completed", j.completedAtSlice(), "bg-gray-500");
    if (j.failed_at_len > 0) timelineEntry(&hw, "Failed", j.failedAtSlice(), "bg-red-500");
    hw.close("ol");
    hw.close("div");
    hw.close("div");

    hw.close("div"); // grid

    // Payload with copy button.
    var payload_buf: [4096]u8 = undefined;
    if (rdr.getJobPayload(job_id, &payload_buf) catch null) |payload| {
        hw.open("div");
        hw.attr("class", "bg-white border border-gray-200 rounded-lg");
        hw.open("div");
        hw.attr("class", "px-4 py-3 border-b border-gray-200 flex items-center justify-between");
        hw.open("h3");
        hw.attr("class", "text-sm font-semibold text-gray-900");
        hw.text("Payload");
        hw.close("h3");
        hw.open("button");
        hw.attr("onclick", "corvoPayloadCopy(this)");
        hw.attr("class", "text-xs text-gray-500 hover:text-gray-700 font-medium");
        hw.text("Copy");
        hw.close("button");
        hw.close("div");
        hw.open("pre");
        hw.attr("id", "job-payload");
        hw.attr("class", "p-4 text-xs font-mono overflow-x-auto text-gray-800 bg-gray-50 rounded-b-lg");
        hw.text(payload);
        hw.close("pre");
        hw.close("div");
    }

    // Error history.
    var err_buf: [16]sqlite_read.JobError = undefined;
    const err_count = rdr.getJobErrors(job_id, &err_buf) catch 0;
    if (err_count > 0) {
        hw.open("div");
        hw.attr("class", "bg-white border border-gray-200 rounded-lg");
        hw.open("div");
        hw.attr("class", "px-4 py-3 border-b border-gray-200");
        hw.open("h3");
        hw.attr("class", "text-sm font-semibold text-gray-900");
        hw.text("Error History");
        hw.close("h3");
        hw.close("div");
        hw.open("div");
        hw.attr("class", "divide-y divide-gray-100");
        for (0..err_count) |i| {
            const err = &err_buf[i];
            hw.open("div");
            hw.attr("class", "px-4 py-3");
            hw.open("div");
            hw.attr("class", "flex items-center gap-2 mb-1");
            hw.open("span");
            hw.attr("class", "text-xs font-medium text-gray-500");
            hw.textFmt("Attempt {d}", .{err.attempt});
            hw.close("span");
            if (err.created_at_len > 0) {
                hw.open("span");
                hw.attr("class", "text-xs text-gray-400");
                hw.text(err.created_at[0..err.created_at_len]);
                hw.close("span");
            }
            hw.close("div");
            hw.open("pre");
            hw.attr("class", "text-xs text-red-700 bg-red-50 rounded p-2 overflow-x-auto");
            hw.text(err.errorSlice());
            hw.close("pre");
            hw.close("div");
        }
        hw.close("div");
        hw.close("div");
    }

    hw.close("div"); // space-y-6

    return renderPage(send_buf, "Job Detail", hw.getWritten());
}

fn workersPage(send_buf: []u8, reader: ?*sqlite_read.Reader) u32 {
    var content_buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&content_buf);

    const rdr = reader orelse {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No data available");
        hw.close("p");
        return renderPage(send_buf, "Workers", hw.getWritten());
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
        hw.attr("class", "bg-white border border-gray-200 rounded-lg overflow-x-auto");
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

    return renderPage(send_buf, "Workers", hw.getWritten());
}

fn clusterPage(send_buf: []u8, _: ?*sqlite_read.Reader) u32 {
    var content_buf: [page_buf_size]u8 = undefined;
    var hw = html.HtmlWriter.init(&content_buf);

    hw.open("div");
    hw.attr("class", "bg-white border border-gray-200 rounded-lg overflow-x-auto");

    // Status header.
    hw.open("div");
    hw.attr("class", "px-6 py-4 border-b border-gray-200 flex items-center gap-2");
    hw.open("span");
    hw.attr("class", "inline-block w-2.5 h-2.5 rounded-full bg-green-500");
    hw.close("span");
    hw.open("span");
    hw.attr("class", "text-sm font-medium text-gray-900");
    hw.text("Standalone Mode");
    hw.close("span");
    hw.close("div");

    // Details table.
    hw.open("table");
    hw.attr("class", "w-full text-sm");
    hw.open("tbody");
    hw.attr("class", "divide-y divide-gray-100");
    detailRow(&hw, "Node ID", "node-1");
    detailRow(&hw, "State", "leader");
    detailRow(&hw, "Status", "healthy");
    hw.close("tbody");
    hw.close("table");
    hw.close("div");

    return renderPage(send_buf, "Cluster", hw.getWritten());
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


const RowActions = enum { none, dead, held, scheduled, queue_detail };

fn writeJobTable(hw: *html.HtmlWriter, jobs: []const sqlite_read.JobRow, actions: RowActions) void {
    if (jobs.len == 0) {
        hw.open("p");
        hw.attr("class", "text-gray-500");
        hw.text("No jobs");
        hw.close("p");
        return;
    }

    // Bulk action bar (hidden by default, shown via JS when checkboxes selected).
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
    // Select-all checkbox.
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
        // Row checkbox.
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

fn timelineEntry(hw: *html.HtmlWriter, label: []const u8, timestamp: []const u8, dot_color: []const u8) void {
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
    hw.text(timestamp);
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

    // Count badge.
    if (qs) |q| {
        const count: i32 = if (state) |s| blk: {
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
        hw.textFmt("{d}", .{count});
        hw.close("span");
    }

    hw.close("a");
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
