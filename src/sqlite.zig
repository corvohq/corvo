//! SQLite wrapper — thin Zig interface over C sqlite3.
//!
//! Provides DB, Statement, and Row abstractions for the SQLite mirror.
//! All strings returned by column accessors are valid only until the
//! next step() or finalize() call (sqlite3 owns the memory).

const std = @import("std");
const assert_mod = @import("assert.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

// ============================================================================
// DB
// ============================================================================

pub const DB = struct {
    handle: *c.sqlite3,

    pub const OpenFlags = struct {
        read_only: bool = false,
        in_memory: bool = false,
    };

    pub fn open(path: [*:0]const u8, flags: OpenFlags) !DB {
        _ = flags;
        var handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path, &handle);
        if (rc != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SqliteOpenFailed;
        }

        var db = DB{ .handle = handle.? };
        // Apply default PRAGMAs for mirror use.
        try db.execPragmas();
        return db;
    }

    pub fn close(self: *DB) void {
        _ = c.sqlite3_close(self.handle);
    }

    fn execPragmas(self: *DB) !void {
        // WAL mode for concurrent reads.
        try self.exec("PRAGMA journal_mode=WAL");
        // Synchronous OFF — mirror is not source of truth.
        try self.exec("PRAGMA synchronous=OFF");
        // Reasonable cache size.
        try self.exec("PRAGMA cache_size=-32000"); // 32MB
        // Foreign keys.
        try self.exec("PRAGMA foreign_keys=ON");
    }

    /// Execute a statement that returns no rows.
    pub fn exec(self: *DB, sql: [*:0]const u8) !void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.handle, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.SqliteExecFailed;
        }
    }

    /// Execute a multi-statement SQL string.
    pub fn execMulti(self: *DB, sql: []const u8) !void {
        // sqlite3_exec handles multiple statements separated by semicolons.
        // But it needs a null-terminated string. We'll use a prepared statement
        // approach that handles multiple statements.
        var remaining = sql;
        while (remaining.len > 0) {
            var stmt: ?*c.sqlite3_stmt = null;
            var tail: [*c]const u8 = null;
            const rc = c.sqlite3_prepare_v2(
                self.handle,
                remaining.ptr,
                @intCast(remaining.len),
                &stmt,
                &tail,
            );
            if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;

            if (stmt) |s| {
                defer _ = c.sqlite3_finalize(s);
                const step_rc = c.sqlite3_step(s);
                if (step_rc != c.SQLITE_DONE and step_rc != c.SQLITE_ROW) {
                    return error.SqliteStepFailed;
                }
            }

            if (tail) |t| {
                const offset = @intFromPtr(t) - @intFromPtr(remaining.ptr);
                if (offset >= remaining.len) break;
                remaining = remaining[offset..];
                // Skip whitespace.
                while (remaining.len > 0 and (remaining[0] == ' ' or remaining[0] == '\n' or remaining[0] == '\r' or remaining[0] == '\t' or remaining[0] == ';')) {
                    remaining = remaining[1..];
                }
            } else break;
        }
    }

    /// Prepare a statement for repeated execution.
    pub fn prepare(self: *DB, sql: [*:0]const u8) !Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        return .{ .handle = stmt.? };
    }

    /// Prepare a statement from a runtime-length slice.
    pub fn prepareDynamic(self: *DB, sql: []const u8) !Stmt {
        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len), &stmt, null);
        if (rc != c.SQLITE_OK) return error.SqlitePrepareFailed;
        return .{ .handle = stmt.? };
    }

    /// Begin a transaction.
    pub fn begin(self: *DB) !void {
        try self.exec("BEGIN");
    }

    /// Commit a transaction.
    pub fn commit(self: *DB) !void {
        try self.exec("COMMIT");
    }

    /// Rollback a transaction.
    pub fn rollback(self: *DB) void {
        self.exec("ROLLBACK") catch {};
    }

    /// Get last error message.
    pub fn errmsg(self: *DB) [*:0]const u8 {
        return c.sqlite3_errmsg(self.handle);
    }

    /// Get last insert rowid.
    pub fn lastInsertRowId(self: *DB) i64 {
        return c.sqlite3_last_insert_rowid(self.handle);
    }

    /// Get number of rows changed by last statement.
    pub fn changes(self: *DB) i32 {
        return c.sqlite3_changes(self.handle);
    }
};

// ============================================================================
// Statement
// ============================================================================

pub const Stmt = struct {
    handle: *c.sqlite3_stmt,

    /// Bind a text value (1-indexed).
    pub fn bindText(self: *Stmt, idx: c_int, text: []const u8) void {
        _ = c.sqlite3_bind_text(self.handle, idx, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT);
    }

    /// Bind a null-terminated text value (1-indexed).
    pub fn bindTextZ(self: *Stmt, idx: c_int, text: [*:0]const u8) void {
        _ = c.sqlite3_bind_text(self.handle, idx, text, -1, c.SQLITE_STATIC);
    }

    /// Bind an integer value (1-indexed).
    pub fn bindInt(self: *Stmt, idx: c_int, val: i32) void {
        _ = c.sqlite3_bind_int(self.handle, idx, val);
    }

    /// Bind an i64 value (1-indexed).
    pub fn bindInt64(self: *Stmt, idx: c_int, val: i64) void {
        _ = c.sqlite3_bind_int64(self.handle, idx, val);
    }

    /// Bind a double value (1-indexed).
    pub fn bindDouble(self: *Stmt, idx: c_int, val: f64) void {
        _ = c.sqlite3_bind_double(self.handle, idx, val);
    }

    /// Bind NULL (1-indexed).
    pub fn bindNull(self: *Stmt, idx: c_int) void {
        _ = c.sqlite3_bind_null(self.handle, idx);
    }

    /// Bind optional text — binds NULL if null.
    pub fn bindOptText(self: *Stmt, idx: c_int, text: ?[]const u8) void {
        if (text) |t| {
            self.bindText(idx, t);
        } else {
            self.bindNull(idx);
        }
    }

    /// Execute and step through results. Returns true if a row is available.
    pub fn step(self: *Stmt) !bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        return error.SqliteStepFailed;
    }

    /// Execute statement ignoring results.
    pub fn exec(self: *Stmt) !void {
        _ = try self.step();
    }

    /// Reset for re-execution with new bindings.
    pub fn reset(self: *Stmt) void {
        _ = c.sqlite3_reset(self.handle);
        _ = c.sqlite3_clear_bindings(self.handle);
    }

    /// Finalize (free) the statement.
    pub fn finalize(self: *Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    // --- Column accessors (0-indexed) ---

    /// Get column as text. Returns null if NULL. Pointer valid until next step/finalize.
    pub fn columnText(self: *Stmt, idx: c_int) ?[]const u8 {
        const ptr = c.sqlite3_column_text(self.handle, idx);
        if (ptr == null) return null;
        const len = c.sqlite3_column_bytes(self.handle, idx);
        return ptr[0..@intCast(len)];
    }

    /// Get column as i32.
    pub fn columnInt(self: *Stmt, idx: c_int) i32 {
        return c.sqlite3_column_int(self.handle, idx);
    }

    /// Get column as i64.
    pub fn columnInt64(self: *Stmt, idx: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, idx);
    }

    /// Get column as f64.
    pub fn columnDouble(self: *Stmt, idx: c_int) f64 {
        return c.sqlite3_column_double(self.handle, idx);
    }

    /// Check if column is NULL.
    pub fn columnIsNull(self: *Stmt, idx: c_int) bool {
        return c.sqlite3_column_type(self.handle, idx) == c.SQLITE_NULL;
    }

    /// Get number of columns in result set.
    pub fn columnCount(self: *Stmt) c_int {
        return c.sqlite3_column_count(self.handle);
    }
};

// ============================================================================
// Tests
// ============================================================================

test "open in-memory DB" {
    var db = try DB.open(":memory:", .{});
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)");
    try db.exec("INSERT INTO t VALUES (1, 'hello')");

    var stmt = try db.prepare("SELECT name FROM t WHERE id = 1");
    defer stmt.finalize();

    const has_row = try stmt.step();
    try std.testing.expect(has_row);
    const name = stmt.columnText(0);
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("hello", name.?);
}

test "prepared statement rebind" {
    var db = try DB.open(":memory:", .{ .in_memory = true });
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER, val TEXT)");

    var insert = try db.prepare("INSERT INTO t VALUES (?, ?)");
    defer insert.finalize();

    insert.bindInt(1, 1);
    insert.bindText(2, "one");
    try insert.exec();
    insert.reset();

    insert.bindInt(1, 2);
    insert.bindText(2, "two");
    try insert.exec();
    insert.reset();

    var sel = try db.prepare("SELECT val FROM t ORDER BY id");
    defer sel.finalize();

    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("one", sel.columnText(0).?);
    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("two", sel.columnText(0).?);
    try std.testing.expect(!(try sel.step()));
}

test "transaction commit" {
    var db = try DB.open(":memory:", .{ .in_memory = true });
    defer db.close();

    try db.exec("CREATE TABLE t (id INTEGER)");
    try db.begin();
    try db.exec("INSERT INTO t VALUES (1)");
    try db.exec("INSERT INTO t VALUES (2)");
    try db.commit();

    var stmt = try db.prepare("SELECT COUNT(*) FROM t");
    defer stmt.finalize();
    _ = try stmt.step();
    try std.testing.expectEqual(@as(i32, 2), stmt.columnInt(0));
}
