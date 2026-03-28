const std = @import("std");
const assert = @import("assert.zig");

pub const max_depth = 16;

pub const HtmlWriter = struct {
    stream: std.io.FixedBufferStream([]u8),
    depth: u8 = 0,
    in_tag: bool = false,

    pub fn init(buf: []u8) HtmlWriter {
        return .{ .stream = std.io.fixedBufferStream(buf) };
    }

    pub fn getWritten(self: *HtmlWriter) []const u8 {
        return self.stream.getWritten();
    }

    // -- Elements --

    /// Open a tag: `<div`. Call attr() for attributes, then text/open/close auto-closes with `>`.
    pub fn open(self: *HtmlWriter, tag: []const u8) void {
        self.closeOpenTag();
        self.writeByte('<');
        self.writeAll(tag);
        self.in_tag = true;
        self.depth += 1;
    }

    /// Close a tag: `</div>`.
    pub fn close(self: *HtmlWriter, tag: []const u8) void {
        self.closeOpenTag();
        assert.check(self.depth > 0, "HtmlWriter: unbalanced close", .{});
        self.depth -= 1;
        self.writeAll("</");
        self.writeAll(tag);
        self.writeByte('>');
    }

    /// Void element (self-closing): `<br>`, `<img>`, `<input>`, `<hr>`, `<meta>`, `<link>`.
    /// Call attr() after this for attributes; next open/close/text auto-closes with `>`.
    pub fn voidElem(self: *HtmlWriter, tag: []const u8) void {
        self.closeOpenTag();
        self.writeByte('<');
        self.writeAll(tag);
        self.in_tag = true;
        // Don't increment depth — void elements don't get closed.
    }

    /// Open + close with text content: `<span class="x">hello</span>`.
    /// Convenience for open/text/close pattern.
    pub fn elem(self: *HtmlWriter, tag: []const u8, content: []const u8) void {
        self.closeOpenTag();
        self.writeByte('<');
        self.writeAll(tag);
        self.writeByte('>');
        self.writeEscaped(content);
        self.writeAll("</");
        self.writeAll(tag);
        self.writeByte('>');
    }

    // -- Attributes --

    /// Write an attribute on the current open tag: ` class="value"`.
    pub fn attr(self: *HtmlWriter, name: []const u8, value: []const u8) void {
        assert.check(self.in_tag, "HtmlWriter: attr outside tag", .{});
        self.writeByte(' ');
        self.writeAll(name);
        self.writeAll("=\"");
        self.writeAttrEscaped(value);
        self.writeByte('"');
    }

    /// Write a boolean attribute (no value): ` disabled`.
    pub fn attrBool(self: *HtmlWriter, name: []const u8) void {
        assert.check(self.in_tag, "HtmlWriter: attrBool outside tag", .{});
        self.writeByte(' ');
        self.writeAll(name);
    }

    /// Write an attribute with a formatted integer value: ` data-count="42"`.
    pub fn attrFmt(self: *HtmlWriter, name: []const u8, comptime fmt: []const u8, args: anytype) void {
        assert.check(self.in_tag, "HtmlWriter: attrFmt outside tag", .{});
        self.writeByte(' ');
        self.writeAll(name);
        self.writeAll("=\"");
        self.stream.writer().print(fmt, args) catch unreachable;
        self.writeByte('"');
    }

    // -- Content --

    /// Write escaped text content.
    pub fn text(self: *HtmlWriter, content: []const u8) void {
        self.closeOpenTag();
        self.writeEscaped(content);
    }

    /// Write a formatted string as escaped text content.
    pub fn textFmt(self: *HtmlWriter, comptime fmt: []const u8, args: anytype) void {
        self.closeOpenTag();
        // Format into a temp buffer, then escape.
        var buf: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch {
            self.writeAll("[fmt overflow]");
            return;
        };
        self.writeEscaped(s);
    }

    /// Write raw HTML (no escaping). Use for trusted content only.
    pub fn raw(self: *HtmlWriter, html: []const u8) void {
        self.closeOpenTag();
        self.writeAll(html);
    }

    /// Write the doctype declaration.
    pub fn doctype(self: *HtmlWriter) void {
        self.writeAll("<!DOCTYPE html>");
    }

    // -- Internal --

    fn closeOpenTag(self: *HtmlWriter) void {
        if (self.in_tag) {
            self.writeByte('>');
            self.in_tag = false;
        }
    }

    fn writeEscaped(self: *HtmlWriter, s: []const u8) void {
        const w = self.stream.writer();
        for (s) |c| {
            switch (c) {
                '&' => w.writeAll("&amp;") catch unreachable,
                '<' => w.writeAll("&lt;") catch unreachable,
                '>' => w.writeAll("&gt;") catch unreachable,
                '"' => w.writeAll("&quot;") catch unreachable,
                '\'' => w.writeAll("&#x27;") catch unreachable,
                else => w.writeByte(c) catch unreachable,
            }
        }
    }

    fn writeAttrEscaped(self: *HtmlWriter, s: []const u8) void {
        const w = self.stream.writer();
        for (s) |c| {
            switch (c) {
                '&' => w.writeAll("&amp;") catch unreachable,
                '"' => w.writeAll("&quot;") catch unreachable,
                else => w.writeByte(c) catch unreachable,
            }
        }
    }

    fn writeByte(self: *HtmlWriter, byte: u8) void {
        self.stream.writer().writeByte(byte) catch unreachable;
    }

    fn writeAll(self: *HtmlWriter, bytes: []const u8) void {
        self.stream.writer().writeAll(bytes) catch unreachable;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "simple div with text" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("div");
    hw.text("hello");
    hw.close("div");
    try std.testing.expectEqualStrings("<div>hello</div>", hw.getWritten());
}

test "nested elements" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("div");
    hw.open("span");
    hw.text("inner");
    hw.close("span");
    hw.close("div");
    try std.testing.expectEqualStrings("<div><span>inner</span></div>", hw.getWritten());
}

test "attributes" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("div");
    hw.attr("class", "container");
    hw.attr("id", "main");
    hw.text("content");
    hw.close("div");
    try std.testing.expectEqualStrings("<div class=\"container\" id=\"main\">content</div>", hw.getWritten());
}

test "htmx attributes" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("div");
    hw.attr("hx-get", "/ui/partials/stats");
    hw.attr("hx-trigger", "every 5s");
    hw.attr("hx-swap", "innerHTML");
    hw.close("div");
    try std.testing.expectEqualStrings(
        "<div hx-get=\"/ui/partials/stats\" hx-trigger=\"every 5s\" hx-swap=\"innerHTML\"></div>",
        hw.getWritten(),
    );
}

test "void element" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.voidElem("input");
    hw.attr("type", "text");
    hw.attr("name", "q");
    hw.voidElem("br");
    hw.open("p");
    hw.text("after");
    hw.close("p");
    try std.testing.expectEqualStrings("<input type=\"text\" name=\"q\"><br><p>after</p>", hw.getWritten());
}

test "elem shorthand" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.elem("h1", "Dashboard");
    try std.testing.expectEqualStrings("<h1>Dashboard</h1>", hw.getWritten());
}

test "html escaping" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("p");
    hw.text("x < y & a > b \"quoted\" it's");
    hw.close("p");
    try std.testing.expectEqualStrings(
        "<p>x &lt; y &amp; a &gt; b &quot;quoted&quot; it&#x27;s</p>",
        hw.getWritten(),
    );
}

test "attribute escaping" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("a");
    hw.attr("href", "/search?q=a&b=c");
    hw.text("link");
    hw.close("a");
    try std.testing.expectEqualStrings(
        "<a href=\"/search?q=a&amp;b=c\">link</a>",
        hw.getWritten(),
    );
}

test "boolean attribute" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("input");
    hw.attr("type", "checkbox");
    hw.attrBool("disabled");
    hw.attrBool("checked");
    // void element — don't close
    try std.testing.expectEqualStrings("<input type=\"checkbox\" disabled checked", hw.getWritten());
}

test "doctype + html structure" {
    var buf: [512]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.doctype();
    hw.open("html");
    hw.open("head");
    hw.elem("title", "Corvo");
    hw.close("head");
    hw.open("body");
    hw.elem("h1", "Hello");
    hw.close("body");
    hw.close("html");
    try std.testing.expectEqualStrings(
        "<!DOCTYPE html><html><head><title>Corvo</title></head><body><h1>Hello</h1></body></html>",
        hw.getWritten(),
    );
}

test "raw html" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("div");
    hw.raw("<svg><circle r=\"5\"/></svg>");
    hw.close("div");
    try std.testing.expectEqualStrings(
        "<div><svg><circle r=\"5\"/></svg></div>",
        hw.getWritten(),
    );
}

test "textFmt" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("span");
    hw.textFmt("{d} jobs", .{@as(u32, 42)});
    hw.close("span");
    try std.testing.expectEqualStrings("<span>42 jobs</span>", hw.getWritten());
}

test "attrFmt" {
    var buf: [256]u8 = undefined;
    var hw = HtmlWriter.init(&buf);
    hw.open("div");
    hw.attrFmt("data-count", "{d}", .{@as(u32, 99)});
    hw.close("div");
    try std.testing.expectEqualStrings("<div data-count=\"99\"></div>", hw.getWritten());
}
