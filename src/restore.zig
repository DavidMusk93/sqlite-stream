const std = @import("std");
const p = @import("platform.zig");
const s = @import("sqlite.zig");
const schema = @import("schema.zig");
const stream = @import("stream.zig");
const format = @import("format.zig");
const staging = @import("staging.zig");
const c = p.c;
const Authorization = struct { object: schema.Object, created: bool = false };
fn text(ptr: [*c]const u8) []const u8 {
    return if (ptr == null) "" else std.mem.span(ptr);
}
fn authorize(context: ?*anyopaque, action: c_int, first: [*c]const u8, second: [*c]const u8, database: [*c]const u8, _: [*c]const u8) callconv(.c) c_int {
    const auth: *Authorization = @ptrCast(@alignCast(context.?));
    const object = auth.object;
    const a = text(first);
    const b = text(second);
    if (database != null and !p.eql(text(database), "main")) return c.SQLITE_DENY;
    const kind: []const u8 = switch (action) {
        c.SQLITE_CREATE_TABLE => "table",
        c.SQLITE_CREATE_INDEX => "index",
        c.SQLITE_CREATE_VIEW => "view",
        c.SQLITE_CREATE_TRIGGER => "trigger",
        else => "",
    };
    if (p.eql(kind, object.kind) and p.eql(a, object.name)) {
        auth.created = true;
        return c.SQLITE_OK;
    }
    const allowed = switch (action) {
        c.SQLITE_REINDEX => p.eql(object.kind, "index") and p.eql(a, object.name),
        c.SQLITE_CREATE_INDEX => p.eql(object.kind, "table") and p.eql(b, object.name) and std.mem.startsWith(u8, a, "sqlite_autoindex_"),
        c.SQLITE_CREATE_TABLE => p.eql(object.kind, "table") and p.eql(a, "sqlite_sequence"),
        c.SQLITE_INSERT, c.SQLITE_UPDATE => p.eql(a, "sqlite_master") or p.eql(a, "sqlite_schema"),
        c.SQLITE_READ => true,
        // CTAS invokes SELECT without a separate INSERT authorizer event.
        // Ordinary table definitions cannot contain subqueries.
        c.SQLITE_SELECT => !p.eql(object.kind, "table"),
        c.SQLITE_FUNCTION => !std.ascii.eqlIgnoreCase(b, "load_extension") and !std.ascii.eqlIgnoreCase(b, "readfile") and !std.ascii.eqlIgnoreCase(b, "writefile"),
        else => false,
    };
    return if (allowed) c.SQLITE_OK else c.SQLITE_DENY;
}
pub fn create(db: s.Db, object: schema.Object) !void {
    var auth: Authorization = .{ .object = object };
    if (c.sqlite3_set_authorizer(db.handle, authorize, &auth) != c.SQLITE_OK) return error.Authorizer;
    defer _ = c.sqlite3_set_authorizer(db.handle, null, null);
    const stmt = try db.prepare(object.sql);
    defer stmt.close();
    if (try stmt.step() or !auth.created) return error.WrongCreateObject;
}
fn equalJson(a: anytype, b: @TypeOf(a)) !bool {
    const left = try std.json.Stringify.valueAlloc(p.allocator, a, .{});
    defer p.allocator.free(left);
    const right = try std.json.Stringify.valueAlloc(p.allocator, b, .{});
    defer p.allocator.free(right);
    return p.eql(left, right);
}
fn discoverEqual(db: s.Db, catalog: schema.Catalog, complete: bool, control: *const p.Control) !void {
    const buf = try p.allocator.alloc(u8, 16 * 1024 * 1024);
    defer p.allocator.free(buf);
    var bounded: std.heap.FixedBufferAllocator = .init(buf);
    const actual = try schema.discover(db, bounded.allocator(), control.limits);
    if (complete) {
        if (!try equalJson(actual, catalog)) return error.SchemaMismatch;
    } else if (!try equalJson(actual.tables, catalog.tables)) return error.TableMismatch;
}
fn bind(stmt: s.Stmt, cells: []const format.Cell) !void {
    _ = c.sqlite3_reset(stmt.handle);
    _ = c.sqlite3_clear_bindings(stmt.handle);
    for (cells, 0..) |cell, i| {
        const index: c_int = @intCast(i + 1);
        const rc = switch (cell) {
            .null_value => c.sqlite3_bind_null(stmt.handle, index),
            .integer => |v| c.sqlite3_bind_int64(stmt.handle, index, v),
            .real => |v| c.sqlite3_bind_double(stmt.handle, index, v),
            .text => |v| c.sqlite3_bind_text(stmt.handle, index, v.ptr, @intCast(v.len), null),
            .blob => |v| c.sqlite3_bind_blob(stmt.handle, index, v.ptr, @intCast(v.len), null),
        };
        if (rc != c.SQLITE_OK) return error.Bind;
    }
}
pub fn load(input: *p.Fd, stage: *staging.Stage, control: *const p.Control) !format.Report {
    try control.check();
    var reader = try stream.Reader.init(input);
    defer reader.deinit();
    var decoder: format.Decoder = .{ .reader = &reader, .control = control };
    const catalog_buf = try p.allocator.alloc(u8, 16 * 1024 * 1024);
    defer p.allocator.free(catalog_buf);
    var catalog_allocator: std.heap.FixedBufferAllocator = .init(catalog_buf);
    const catalog = try decoder.header(catalog_allocator.allocator());
    const db = try s.Db.open(stage.path, true, control);
    defer db.close();
    const pages = control.limits.database_bytes / @as(u64, @intCast(try db.scalar("PRAGMA page_size")));
    if (pages == 0) return error.DatabaseBudget;
    const setting = try std.fmt.allocPrint(p.allocator, "PRAGMA max_page_count={d}; PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=OFF; BEGIN IMMEDIATE;", .{@min(pages, 4294967294)});
    defer p.allocator.free(setting);
    try db.exec(setting);
    var committed = false;
    defer if (!committed) db.exec("ROLLBACK") catch {};
    for (catalog.objects) |object| if (p.eql(object.kind, "table")) try create(db, object);
    try discoverEqual(db, catalog, false, control);
    // One reusable row buffer; no accumulation across tables or rows.
    const row_buf = try p.allocator.alloc(u8, control.limits.row_bytes + 2001);
    defer p.allocator.free(row_buf);
    var row_allocator: std.heap.FixedBufferAllocator = .init(row_buf);
    var cells: [2001]format.Cell = undefined;
    for (catalog.tables) |table| {
        if (p.eql(table.name, "sqlite_sequence")) try db.exec("DELETE FROM sqlite_sequence");
        const sql = try table.insert(p.allocator);
        defer p.allocator.free(sql);
        const insert = try db.prepare(sql);
        defer insert.close();
        while (true) {
            row_allocator.reset();
            const row = cells[0..table.columns.len];
            if (!try decoder.row(row, row_allocator.allocator())) break;
            try control.check();
            try bind(insert, row);
            if (try insert.step()) return error.InsertResult;
            // Clear bindings before the borrowed row buffer is reused.
            _ = c.sqlite3_reset(insert.handle);
            _ = c.sqlite3_clear_bindings(insert.handle);
        }
    }
    const report = try decoder.finish(catalog.tables.len);
    for (catalog.objects) |object| if (!p.eql(object.kind, "table")) try create(db, object);
    const versions = try std.fmt.allocPrint(p.allocator, "PRAGMA user_version={d}; PRAGMA application_id={d};", .{ catalog.user_version, catalog.application_id });
    defer p.allocator.free(versions);
    try db.exec(versions);
    try db.check();
    try discoverEqual(db, catalog, true, control);
    var sink: format.Sink = .{};
    const actual = try format.scan(db, catalog, &sink, control);
    if (!p.eql(&report.digest, &actual.digest) or report.rows != actual.rows) return error.ContentMismatch;
    try db.exec("COMMIT");
    committed = true;
    try stage.sync();
    try control.check();
    return report;
}
