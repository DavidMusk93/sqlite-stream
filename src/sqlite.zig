const std = @import("std");
const p = @import("platform.zig");
pub const c = p.c;
fn failure(rc: c_int) anyerror {
    return switch (rc & 0xff) {
        c.SQLITE_FULL => error.DatabaseBudget,
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.SQLiteBusy,
        c.SQLITE_IOERR, c.SQLITE_NOMEM => error.SQLiteIO,
        c.SQLITE_INTERRUPT => if (c.ss_cancelled() != 0) error.Cancelled else error.Deadline,
        else => error.SQLiteStep,
    };
}
fn progress(context: ?*anyopaque) callconv(.c) c_int {
    const control: *const p.Control = @ptrCast(@alignCast(context.?));
    control.check() catch return 1;
    return 0;
}
pub const Db = struct {
    handle: *c.sqlite3,
    pub fn open(path: []const u8, writable: bool, control: *const p.Control) !Db {
        const path_z = try p.z(path);
        defer p.allocator.free(path_z);
        var handle: ?*c.sqlite3 = null;
        const flags = if (writable) c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE else c.SQLITE_OPEN_READONLY;
        const vfs: ?[*:0]const u8 = if (std.mem.startsWith(u8, path, "/proc/self/fd/")) blk: {
            if (c.ss_register_fd_vfs() != c.SQLITE_OK) return error.SQLiteVFS;
            break :blk "ss-fd";
        } else null;
        if (c.sqlite3_open_v2(path_z, &handle, flags | c.SQLITE_OPEN_NOMUTEX, vfs) != c.SQLITE_OK) {
            if (handle) |h| _ = c.sqlite3_close(h);
            return error.SQLiteOpen;
        }
        const db: Db = .{ .handle = handle.? };
        errdefer db.close();
        _ = c.sqlite3_busy_timeout(db.handle, 50);
        _ = c.sqlite3_limit(db.handle, c.SQLITE_LIMIT_LENGTH, @intCast(control.limits.row_bytes));
        _ = c.sqlite3_limit(db.handle, c.SQLITE_LIMIT_SQL_LENGTH, @intCast(control.limits.schema_bytes));
        c.sqlite3_progress_handler(db.handle, 1000, progress, @constCast(control));
        try db.exec("PRAGMA mmap_size=0; PRAGMA cache_size=-2048; PRAGMA temp_store=FILE; PRAGMA trusted_schema=OFF;");
        return db;
    }
    pub fn close(self: Db) void {
        _ = c.sqlite3_close(self.handle);
    }
    pub fn exec(self: Db, sql: []const u8) !void {
        const sql_z = try p.z(sql);
        defer p.allocator.free(sql_z);
        const rc = c.sqlite3_exec(self.handle, sql_z, null, null, null);
        if (rc != c.SQLITE_OK) {
            p.log("sqlite: {s}", .{std.mem.span(c.sqlite3_errmsg(self.handle))});
            const err = failure(rc);
            return if (err == error.SQLiteStep) error.SQLiteExec else err;
        }
    }
    pub fn prepare(self: Db, sql: []const u8) !Stmt {
        const sql_z = try p.z(sql);
        defer p.allocator.free(sql_z);
        var stmt: ?*c.sqlite3_stmt = null;
        var tail: [*c]const u8 = null;
        if (c.sqlite3_prepare_v2(self.handle, sql_z, @intCast(sql_z.len + 1), &stmt, &tail) != c.SQLITE_OK) {
            p.log("sqlite: {s}", .{std.mem.span(c.sqlite3_errmsg(self.handle))});
            return error.SQLitePrepare;
        }
        const result: Stmt = .{ .handle = stmt orelse return error.EmptySQL };
        errdefer result.close();
        // Preparing a second statement also catches comments followed by SQL.
        var extra: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.handle, tail, -1, &extra, null);
        if (extra) |s| _ = c.sqlite3_finalize(s);
        if (rc != c.SQLITE_OK or extra != null) return error.ExtraSQL;
        return result;
    }
    pub fn scalar(self: Db, sql: []const u8) !i64 {
        const stmt = try self.prepare(sql);
        defer stmt.close();
        if (!try stmt.step()) return error.MissingScalar;
        return c.sqlite3_column_int64(stmt.handle, 0);
    }
    pub fn check(self: Db) !void {
        const integrity = try self.prepare("PRAGMA integrity_check");
        defer integrity.close();
        if (!try integrity.step() or !p.eql(try integrity.text(0), "ok") or try integrity.step()) return error.Integrity;
        const fk = try self.prepare("PRAGMA foreign_key_check");
        defer fk.close();
        if (try fk.step()) return error.ForeignKeys;
    }
};
pub const Stmt = struct {
    handle: *c.sqlite3_stmt,
    pub fn close(self: Stmt) void {
        _ = c.sqlite3_finalize(self.handle);
    }
    pub fn step(self: Stmt) !bool {
        const rc = c.sqlite3_step(self.handle);
        if (rc == c.SQLITE_ROW) return true;
        if (rc == c.SQLITE_DONE) return false;
        p.log("sqlite: {s}", .{std.mem.span(c.sqlite3_errmsg(c.sqlite3_db_handle(self.handle)))});
        return failure(rc);
    }
    pub fn text(self: Stmt, col: c_int) ![]const u8 {
        const ptr = c.sqlite3_column_text(self.handle, col);
        const len = c.sqlite3_column_bytes(self.handle, col);
        if (ptr == null) return error.NullText;
        return ptr[0..@intCast(len)];
    }
    pub fn bindText(self: Stmt, index: c_int, bytes: []const u8) !void {
        // STATIC is safe: the caller retains bytes until step/reset/finalize.
        if (c.sqlite3_bind_text(self.handle, index, bytes.ptr, @intCast(bytes.len), null) != c.SQLITE_OK) return error.Bind;
    }
};
