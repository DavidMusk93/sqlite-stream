const std = @import("std");
const p = @import("platform.zig");
const s = @import("sqlite.zig");
const c = p.c;
pub const Object = struct { kind: []const u8, name: []const u8, sql: []const u8 };
pub const Table = struct {
    name: []const u8,
    columns: []const []const u8,
    order: []const []const u8,
    without_rowid: bool,
    pub fn select(self: Table, a: std.mem.Allocator) ![]const u8 {
        const columns = try identifiers(a, self.columns);
        const order = try identifiers(a, self.order);
        const name = try quote(a, self.name);
        defer a.free(columns);
        defer a.free(order);
        defer a.free(name);
        return std.fmt.allocPrint(a, "SELECT {s} FROM {s} ORDER BY {s}", .{ columns, name, order });
    }
    pub fn insert(self: Table, a: std.mem.Allocator) ![]const u8 {
        const columns = try identifiers(a, self.columns);
        const name = try quote(a, self.name);
        defer a.free(columns);
        defer a.free(name);
        const placeholders = try a.alloc([]const u8, self.columns.len);
        defer a.free(placeholders);
        @memset(placeholders, "?");
        const values = try std.mem.join(a, ",", placeholders);
        defer a.free(values);
        return std.fmt.allocPrint(a, "INSERT INTO {s} ({s}) VALUES ({s})", .{ name, columns, values });
    }
};
pub const Catalog = struct {
    user_version: i64,
    application_id: i64,
    objects: []const Object,
    tables: []const Table,
    pub fn json(self: Catalog, a: std.mem.Allocator) ![]const u8 {
        return std.json.Stringify.valueAlloc(a, self, .{});
    }
    pub fn validate(self: Catalog, limits: p.Limits) !void {
        if (self.user_version < std.math.minInt(i32) or self.user_version > std.math.maxInt(i32) or self.application_id < std.math.minInt(i32) or self.application_id > std.math.maxInt(i32)) return error.InvalidVersion;
        if (self.objects.len > 1024 or self.tables.len > 1024) return error.SchemaItems;
        var bytes: usize = 0;
        for (self.objects, 0..) |object, i| {
            if (!p.eql(object.kind, "table") and !p.eql(object.kind, "index") and !p.eql(object.kind, "view") and !p.eql(object.kind, "trigger")) return error.ObjectKind;
            try nameCheck(object.name);
            if (std.ascii.startsWithIgnoreCase(object.name, "sqlite_")) return error.InternalObject;
            try nameCheck(object.sql);
            for (self.objects[0..i]) |previous| if (p.eql(previous.kind, object.kind) and std.ascii.eqlIgnoreCase(previous.name, object.name)) return error.DuplicateObject;
            bytes += object.name.len + object.sql.len + 128;
        }
        for (self.tables, 0..) |table, i| {
            try nameCheck(table.name);
            for (self.tables[0..i]) |previous| if (std.ascii.eqlIgnoreCase(previous.name, table.name)) return error.DuplicateTable;
            if (table.columns.len == 0 or table.columns.len > 2001 or table.order.len == 0 or table.order.len > table.columns.len) return error.ColumnCount;
            for (table.columns, 0..) |column, j| {
                try nameCheck(column);
                for (table.columns[0..j]) |previous| if (std.ascii.eqlIgnoreCase(previous, column)) return error.DuplicateColumn;
                bytes += column.len * 3 + 64;
            }
            for (table.order, 0..) |column, j| {
                if (!contains(table.columns, column)) return error.OrderColumn;
                if (contains(table.order[0..j], column)) return error.OrderColumn;
            }
            bytes += table.name.len + 128;
        }
        if (bytes > limits.schema_bytes) return error.SchemaBudget;
    }
};
fn nameCheck(name: []const u8) !void {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, 0) != null or !std.unicode.utf8ValidateSlice(name)) return error.InvalidName;
}
fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| if (std.ascii.eqlIgnoreCase(candidate, name)) return true;
    return false;
}
pub fn quote(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.array_list.Managed(u8) = .init(a);
    errdefer out.deinit();
    try out.append('"');
    for (name) |ch| {
        try out.append(ch);
        if (ch == '"') try out.append(ch);
    }
    try out.append('"');
    return out.toOwnedSlice();
}
fn identifiers(a: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    const quoted = try a.alloc([]const u8, names.len);
    defer a.free(quoted);
    var used: usize = 0;
    defer for (quoted[0..used]) |name| a.free(name);
    for (names, 0..) |name, i| {
        quoted[i] = try quote(a, name);
        used += 1;
    }
    return std.mem.join(a, ",", quoted);
}
// The caller owns the read transaction and the bounded catalog allocator.
pub fn discover(db: s.Db, a: std.mem.Allocator, limits: p.Limits) !Catalog {
    const encoding = try db.prepare("PRAGMA encoding");
    defer encoding.close();
    if (!try encoding.step() or !p.eql(try encoding.text(0), "UTF-8")) return error.UnsupportedEncoding;
    var objects: std.array_list.Managed(Object) = .init(a);
    const definitions = try db.prepare("SELECT type,name,sql FROM sqlite_schema WHERE sql IS NOT NULL AND substr(name,1,7)<>'sqlite_' ORDER BY type,name COLLATE BINARY");
    defer definitions.close();
    var charge: usize = 0;
    while (try definitions.step()) {
        if (objects.items.len >= 1024) return error.SchemaItems;
        const kind = try definitions.text(0);
        const name = try definitions.text(1);
        const sql = try definitions.text(2);
        charge += name.len + sql.len + 128;
        if (charge > limits.schema_bytes) return error.SchemaBudget;
        try objects.append(.{ .kind = try a.dupe(u8, kind), .name = try a.dupe(u8, name), .sql = try a.dupe(u8, sql) });
    }
    var tables: std.array_list.Managed(Table) = .init(a);
    const list = try db.prepare("SELECT name,type,wr FROM pragma_table_list WHERE schema='main' ORDER BY (name='sqlite_sequence'),name COLLATE BINARY");
    defer list.close();
    while (try list.step()) {
        const name = try list.text(0);
        const kind = try list.text(1);
        if (p.eql(kind, "virtual") or p.eql(kind, "shadow")) return error.UnsupportedVirtualTable;
        if (p.eql(kind, "view")) continue;
        if (std.mem.startsWith(u8, name, "sqlite_") and !p.eql(name, "sqlite_sequence")) continue;
        if (!p.eql(kind, "table") or tables.items.len >= 1024) return error.SchemaItems;
        const wr = c.sqlite3_column_int(list.handle, 2) != 0;
        const info = try db.prepare("SELECT name,pk,hidden FROM pragma_table_xinfo(?) ORDER BY cid");
        defer info.close();
        try info.bindText(1, name);
        var names: std.array_list.Managed([]const u8) = .init(a);
        var columns: std.array_list.Managed([]const u8) = .init(a);
        const Primary = struct { position: i64, name: []const u8 };
        var primary: std.array_list.Managed(Primary) = .init(a);
        while (try info.step()) {
            const column = try info.text(0);
            charge += column.len * 3 + 64;
            if (charge > limits.schema_bytes or names.items.len >= 2000) return error.SchemaBudget;
            const copy = try a.dupe(u8, column);
            try names.append(copy);
            if (c.sqlite3_column_int(info.handle, 2) != 0) continue; // Generated columns are recomputed.
            try columns.append(copy);
            const pk = c.sqlite3_column_int64(info.handle, 1);
            if (pk > 0) try primary.append(.{ .position = pk, .name = copy });
        }
        if (columns.items.len == 0) return error.ColumnCount;
        var order: std.array_list.Managed([]const u8) = .init(a);
        if (wr) {
            std.mem.sort(Primary, primary.items, {}, struct {
                fn less(_: void, x: Primary, y: Primary) bool {
                    return x.position < y.position;
                }
            }.less);
            for (primary.items) |key| try order.append(key.name);
        } else {
            var alias: ?[]const u8 = null;
            for ([_][]const u8{ "rowid", "_rowid_", "oid" }) |candidate| {
                if (!contains(names.items, candidate)) {
                    alias = candidate;
                    break;
                }
            }
            const selected = alias orelse return error.ShadowedRowid;
            try columns.insert(0, selected);
            try order.append(selected);
        }
        charge += name.len + 128;
        if (charge > limits.schema_bytes) return error.SchemaBudget;
        const table: Table = .{ .name = try a.dupe(u8, name), .columns = try columns.toOwnedSlice(), .order = try order.toOwnedSlice(), .without_rowid = wr };
        const sql = try table.select(p.allocator);
        defer p.allocator.free(sql);
        const test_read = try db.prepare(sql);
        test_read.close();
        try tables.append(table);
    }
    const result: Catalog = .{ .user_version = try db.scalar("PRAGMA user_version"), .application_id = try db.scalar("PRAGMA application_id"), .objects = try objects.toOwnedSlice(), .tables = try tables.toOwnedSlice() };
    try result.validate(limits);
    return result;
}
