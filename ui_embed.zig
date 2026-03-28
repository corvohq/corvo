//! Embedded UI assets — HTMX + Tailwind CSS dashboard.
//!
//! Static assets are pre-gzipped at build time and served with
//! Content-Encoding: gzip. This keeps send_buf small.

const std = @import("std");

// Embedded assets — pre-gzipped.
const htmx_js_gz = @embedFile("ui/htmx.min.js.gz");
const tailwind_css_gz = @embedFile("ui/tailwind.css.gz");
const favicon_svg_gz = @embedFile("ui/dist/favicon.svg.gz");
const logo_full_svg_gz = @embedFile("ui/dist/logo-full.svg.gz");

// HTML templates.
pub const layout_html = @embedFile("ui/templates/layout.html");

/// Largest embedded asset size. send_buf must fit this + HTTP headers (~200B).
pub const max_asset_size: usize = htmx_js_gz.len;

comptime {
    // Verify htmx is actually the largest.
    std.debug.assert(htmx_js_gz.len >= tailwind_css_gz.len);
    std.debug.assert(htmx_js_gz.len >= favicon_svg_gz.len);
    std.debug.assert(htmx_js_gz.len >= logo_full_svg_gz.len);
}

pub const EmbeddedFile = struct {
    data: []const u8,
    content_type: []const u8,
    gzipped: bool,
};

/// Look up a static asset by path (relative to /ui/).
/// Returns null for paths that should be server-rendered HTML pages.
pub fn lookup(path: []const u8) ?EmbeddedFile {
    if (eql(path, "/htmx.min.js"))
        return .{ .data = htmx_js_gz, .content_type = "application/javascript", .gzipped = true };
    if (eql(path, "/tailwind.css"))
        return .{ .data = tailwind_css_gz, .content_type = "text/css", .gzipped = true };
    if (eql(path, "/favicon.svg"))
        return .{ .data = favicon_svg_gz, .content_type = "image/svg+xml", .gzipped = true };
    if (eql(path, "/logo-full.svg"))
        return .{ .data = logo_full_svg_gz, .content_type = "image/svg+xml", .gzipped = true };
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
