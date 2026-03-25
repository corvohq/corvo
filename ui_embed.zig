//! Embedded UI assets — compile-time embedded SPA dashboard.
//!
//! Uses @embedFile to include the pre-built UI from ui/dist/ at compile time.
//! Serves at /ui/* with SPA fallback (non-file paths return index.html).
//!
//! This file lives at the project root so @embedFile can reach ui/dist/.

const std = @import("std");

// Embedded assets (relative to this file at project root).
const index_html = @embedFile("ui/dist/index.html");
const favicon_svg = @embedFile("ui/dist/favicon.svg");
const logo_full_svg = @embedFile("ui/dist/logo-full.svg");
const index_js = @embedFile("ui/dist/assets/index-Be2C-ojH.js");
const index_css = @embedFile("ui/dist/assets/index-DqOUNrgT.css");

pub const EmbeddedFile = struct {
    data: []const u8,
    content_type: []const u8,
};

/// Look up an embedded UI file by path (relative to /ui/).
/// Returns null if not found — caller should fall back to index.html for SPA routing.
pub fn lookup(path: []const u8) ?EmbeddedFile {
    if (eql(path, "/") or eql(path, "/index.html") or path.len == 0) {
        return .{ .data = index_html, .content_type = "text/html; charset=utf-8" };
    }
    if (eql(path, "/favicon.svg")) {
        return .{ .data = favicon_svg, .content_type = "image/svg+xml" };
    }
    if (eql(path, "/logo-full.svg")) {
        return .{ .data = logo_full_svg, .content_type = "image/svg+xml" };
    }
    if (eql(path, "/assets/index-Be2C-ojH.js")) {
        return .{ .data = index_js, .content_type = "application/javascript" };
    }
    if (eql(path, "/assets/index-DqOUNrgT.css")) {
        return .{ .data = index_css, .content_type = "text/css" };
    }
    return null;
}

/// SPA fallback — returns index.html for any unrecognized path.
pub fn indexHtml() EmbeddedFile {
    return .{ .data = index_html, .content_type = "text/html; charset=utf-8" };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
