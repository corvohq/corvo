const std = @import("std");
const assert = @import("assert.zig");

pub const max_depth = 8;

pub const JsonWriter = struct {
    stream: std.io.FixedBufferStream([]u8),
    depth: u8 = 0,
    needs_comma: [max_depth]bool = [_]bool{false} ** max_depth,

    pub fn init(buf: []u8) JsonWriter {
        return .{ .stream = std.io.fixedBufferStream(buf) };
    }

    pub fn getWritten(self: *JsonWriter) []const u8 {
        return self.stream.getWritten();
    }

    // -- Structure --

    pub fn beginObject(self: *JsonWriter) void {
        self.maybeComma();
        self.writeByte('{');
        self.push();
    }

    pub fn beginObjectField(self: *JsonWriter, key: []const u8) void {
        self.maybeComma();
        self.writeKey(key);
        self.writeByte('{');
        self.push();
    }

    pub fn endObject(self: *JsonWriter) void {
        self.pop();
        self.writeByte('}');
    }

    pub fn beginArray(self: *JsonWriter) void {
        self.maybeComma();
        self.writeByte('[');
        self.push();
    }

    pub fn beginArrayField(self: *JsonWriter, key: []const u8) void {
        self.maybeComma();
        self.writeKey(key);
        self.writeByte('[');
        self.push();
    }

    pub fn endArray(self: *JsonWriter) void {
        self.pop();
        self.writeByte(']');
    }

    // -- Fields (key:value inside an object) --

    pub fn fieldStr(self: *JsonWriter, key: []const u8, value: []const u8) void {
        self.maybeComma();
        self.writeKey(key);
        self.writeEscapedString(value);
    }

    pub fn fieldInt(self: *JsonWriter, key: []const u8, value: anytype) void {
        self.maybeComma();
        self.writeKey(key);
        self.stream.writer().print("{d}", .{value}) catch unreachable;
    }

    pub fn fieldFloat(self: *JsonWriter, key: []const u8, value: anytype) void {
        self.maybeComma();
        self.writeKey(key);
        self.stream.writer().print("{d:.2}", .{value}) catch unreachable;
    }

    pub fn fieldBool(self: *JsonWriter, key: []const u8, value: bool) void {
        self.maybeComma();
        self.writeKey(key);
        self.writeAll(if (value) "true" else "false");
    }

    pub fn fieldNull(self: *JsonWriter, key: []const u8) void {
        self.maybeComma();
        self.writeKey(key);
        self.writeAll("null");
    }

    pub fn fieldRaw(self: *JsonWriter, key: []const u8, raw_json: []const u8) void {
        self.maybeComma();
        self.writeKey(key);
        self.writeAll(raw_json);
    }

    pub fn fieldStrOpt(self: *JsonWriter, key: []const u8, value: ?[]const u8) void {
        if (value) |v| self.fieldStr(key, v);
    }

    // -- Array elements --

    pub fn elemStr(self: *JsonWriter, value: []const u8) void {
        self.maybeComma();
        self.writeEscapedString(value);
    }

    pub fn elemInt(self: *JsonWriter, value: anytype) void {
        self.maybeComma();
        self.stream.writer().print("{d}", .{value}) catch unreachable;
    }

    pub fn elemRaw(self: *JsonWriter, raw_json: []const u8) void {
        self.maybeComma();
        self.writeAll(raw_json);
    }

    // -- Internal helpers --

    fn maybeComma(self: *JsonWriter) void {
        if (self.depth > 0 and self.needs_comma[self.depth - 1]) {
            self.writeByte(',');
        }
        if (self.depth > 0) {
            self.needs_comma[self.depth - 1] = true;
        }
    }

    fn push(self: *JsonWriter) void {
        assert.check(self.depth < max_depth, "JsonWriter: max depth exceeded", .{});
        self.needs_comma[self.depth] = false;
        self.depth += 1;
    }

    fn pop(self: *JsonWriter) void {
        assert.check(self.depth > 0, "JsonWriter: unbalanced end", .{});
        self.depth -= 1;
    }

    fn writeKey(self: *JsonWriter, key: []const u8) void {
        self.writeByte('"');
        self.writeAll(key);
        self.writeByte('"');
        self.writeByte(':');
    }

    fn writeEscapedString(self: *JsonWriter, s: []const u8) void {
        const w = self.stream.writer();
        w.writeByte('"') catch unreachable;
        for (s) |c| {
            switch (c) {
                '"' => w.writeAll("\\\"") catch unreachable,
                '\\' => w.writeAll("\\\\") catch unreachable,
                '\n' => w.writeAll("\\n") catch unreachable,
                '\r' => w.writeAll("\\r") catch unreachable,
                '\t' => w.writeAll("\\t") catch unreachable,
                0x08 => w.writeAll("\\b") catch unreachable,
                0x0C => w.writeAll("\\f") catch unreachable,
                else => {
                    if (c < 0x20 or c == 0x7F) {
                        w.print("\\u{X:0>4}", .{c}) catch unreachable;
                    } else {
                        w.writeByte(c) catch unreachable;
                    }
                },
            }
        }
        w.writeByte('"') catch unreachable;
    }

    fn writeByte(self: *JsonWriter, byte: u8) void {
        self.stream.writer().writeByte(byte) catch unreachable;
    }

    fn writeAll(self: *JsonWriter, bytes: []const u8) void {
        self.stream.writer().writeAll(bytes) catch unreachable;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "simple object" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.fieldStr("id", "abc");
    jw.fieldInt("count", @as(u32, 42));
    jw.fieldBool("ok", true);
    jw.endObject();
    try std.testing.expectEqualStrings("{\"id\":\"abc\",\"count\":42,\"ok\":true}", jw.getWritten());
}

test "nested object" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.beginObjectField("job");
    jw.fieldStr("id", "j1");
    jw.fieldStr("queue", "default");
    jw.fieldInt("priority", @as(u8, 3));
    jw.endObject();
    jw.endObject();
    try std.testing.expectEqualStrings("{\"job\":{\"id\":\"j1\",\"queue\":\"default\",\"priority\":3}}", jw.getWritten());
}

test "array" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginArray();
    jw.elemStr("a");
    jw.elemStr("b");
    jw.elemInt(@as(u32, 1));
    jw.endArray();
    try std.testing.expectEqualStrings("[\"a\",\"b\",1]", jw.getWritten());
}

test "array field" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.beginArrayField("items");
    jw.elemStr("x");
    jw.elemStr("y");
    jw.endArray();
    jw.endObject();
    try std.testing.expectEqualStrings("{\"items\":[\"x\",\"y\"]}", jw.getWritten());
}

test "escaped strings" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.fieldStr("msg", "hello \"world\"\nline2");
    jw.endObject();
    try std.testing.expectEqualStrings("{\"msg\":\"hello \\\"world\\\"\\nline2\"}", jw.getWritten());
}

test "control characters escaped" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.fieldStr("val", "\x00\x1F\x7F");
    jw.endObject();
    try std.testing.expectEqualStrings("{\"val\":\"\\u0000\\u001F\\u007F\"}", jw.getWritten());
}

test "fieldStrOpt skips null" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.fieldStr("a", "1");
    jw.fieldStrOpt("b", null);
    jw.fieldStr("c", "2");
    jw.endObject();
    try std.testing.expectEqualStrings("{\"a\":\"1\",\"c\":\"2\"}", jw.getWritten());
}

test "fieldNull" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.fieldNull("x");
    jw.endObject();
    try std.testing.expectEqualStrings("{\"x\":null}", jw.getWritten());
}

test "fieldRaw" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.fieldRaw("data", "{\"nested\":true}");
    jw.endObject();
    try std.testing.expectEqualStrings("{\"data\":{\"nested\":true}}", jw.getWritten());
}

test "empty object and array" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.beginObjectField("empty_obj");
    jw.endObject();
    jw.beginArrayField("empty_arr");
    jw.endArray();
    jw.endObject();
    try std.testing.expectEqualStrings("{\"empty_obj\":{},\"empty_arr\":[]}", jw.getWritten());
}

test "fieldFloat" {
    var buf: [256]u8 = undefined;
    var jw = JsonWriter.init(&buf);
    jw.beginObject();
    jw.fieldFloat("price", @as(f64, 3.14));
    jw.endObject();
    try std.testing.expectEqualStrings("{\"price\":3.14}", jw.getWritten());
}
