const std = @import("std");
const p = @import("platform.zig");
const s = @import("sqlite.zig");
const schema = @import("schema.zig");
const stream = @import("stream.zig");
const c = p.c;
const Hash = std.crypto.hash.sha2.Sha256;
pub const Report = struct { digest: [32]u8, rows: u64, tables: usize };
pub const Sink = struct {
    pub fn write(_: *Sink, _: []const u8) !void {}
};
pub fn Encoder(comptime W: type) type {
    return struct {
        writer: *W,
        control: *const p.Control,
        hash: Hash = .init(.{}),
        rows: u64 = 0,
        table_rows: u64 = 0,
        const Self = @This();
        pub fn init(writer: *W, catalog: schema.Catalog, control: *const p.Control) !Self {
            var self: Self = .{ .writer = writer, .control = control };
            const json = try catalog.json(p.allocator);
            defer p.allocator.free(json);
            if (json.len > control.limits.schema_bytes) return error.SchemaBudget;
            try self.bytes("SQLSTRM1");
            try self.integer(u32, @intCast(json.len));
            try self.bytes(json);
            return self;
        }
        fn bytes(self: *Self, data: []const u8) !void {
            try self.writer.write(data);
            self.hash.update(data);
        }
        fn integer(self: *Self, comptime T: type, value: T) !void {
            var buf: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &buf, value, .little);
            try self.bytes(&buf);
        }
        pub fn row(self: *Self, stmt: s.Stmt) !void {
            try self.control.check();
            if (self.rows >= self.control.limits.rows) return error.RowCountBudget;
            const columns: usize = @intCast(c.sqlite3_column_count(stmt.handle));
            var size: usize = 0;
            for (0..columns) |i| {
                const col: c_int = @intCast(i);
                const kind = c.sqlite3_column_type(stmt.handle, col);
                size += switch (kind) {
                    c.SQLITE_NULL => 1,
                    c.SQLITE_INTEGER, c.SQLITE_FLOAT => 9,
                    c.SQLITE_TEXT, c.SQLITE_BLOB => 5 + @as(usize, @intCast(c.sqlite3_column_bytes(stmt.handle, col))),
                    else => return error.CellType,
                };
            }
            if (size > self.control.limits.row_bytes) return error.RowBytesBudget;
            try self.bytes(&.{1});
            for (0..columns) |i| {
                const col: c_int = @intCast(i);
                const kind = c.sqlite3_column_type(stmt.handle, col);
                switch (kind) {
                    c.SQLITE_NULL => try self.bytes(&.{0}),
                    c.SQLITE_INTEGER => {
                        try self.bytes(&.{1});
                        try self.integer(i64, c.sqlite3_column_int64(stmt.handle, col));
                    },
                    c.SQLITE_FLOAT => {
                        try self.bytes(&.{2});
                        try self.integer(u64, @bitCast(c.sqlite3_column_double(stmt.handle, col)));
                    },
                    c.SQLITE_TEXT, c.SQLITE_BLOB => {
                        const ptr = if (kind == c.SQLITE_TEXT) c.sqlite3_column_text(stmt.handle, col) else @as([*c]const u8, @ptrCast(c.sqlite3_column_blob(stmt.handle, col)));
                        const len: usize = @intCast(c.sqlite3_column_bytes(stmt.handle, col));
                        if (len > 0 and ptr == null) return error.OutOfMemory;
                        try self.bytes(&.{if (kind == c.SQLITE_TEXT) 3 else 4});
                        try self.integer(u32, @intCast(len));
                        if (len > 0) try self.bytes(ptr[0..len]);
                    },
                    else => return error.CellType,
                }
            }
            self.rows += 1;
            self.table_rows += 1;
        }
        pub fn endTable(self: *Self) !void {
            try self.bytes(&.{0});
            try self.integer(u64, self.table_rows);
            self.table_rows = 0;
        }
        pub fn finish(self: *Self, tables: usize) !Report {
            try self.bytes("ENDSTRM1");
            try self.integer(u64, self.rows);
            const digest = self.hash.finalResult();
            try self.writer.write(&digest);
            return .{ .digest = digest, .rows = self.rows, .tables = tables };
        }
    };
}
pub fn scan(db: s.Db, catalog: schema.Catalog, writer: anytype, control: *const p.Control) !Report {
    var encoder = try Encoder(@TypeOf(writer.*)).init(writer, catalog, control);
    for (catalog.tables) |table| {
        const sql = try table.select(p.allocator);
        defer p.allocator.free(sql);
        const stmt = try db.prepare(sql);
        defer stmt.close();
        while (try stmt.step()) try encoder.row(stmt);
        try encoder.endTable();
    }
    return encoder.finish(catalog.tables.len);
}
pub const Cell = union(enum) { null_value, integer: i64, real: f64, text: []const u8, blob: []const u8 };
pub const Decoder = struct {
    reader: *stream.Reader,
    control: *const p.Control,
    hash: Hash = .init(.{}),
    rows: u64 = 0,
    table_rows: u64 = 0,
    pub fn header(self: *Decoder, a: std.mem.Allocator) !schema.Catalog {
        var magic: [8]u8 = undefined;
        try self.bytes(&magic);
        if (!p.eql(&magic, "SQLSTRM1")) return error.ArchiveVersion;
        const length = try self.integer(u32);
        if (length > self.control.limits.schema_bytes) return error.SchemaBudget;
        const json = try a.alloc(u8, length);
        try self.bytes(json);
        const catalog = (try std.json.parseFromSlice(schema.Catalog, a, json, .{ .allocate = .alloc_always })).value;
        try catalog.validate(self.control.limits);
        return catalog;
    }
    fn bytes(self: *Decoder, buf: []u8) !void {
        try self.reader.exact(buf);
        self.hash.update(buf);
    }
    fn integer(self: *Decoder, comptime T: type) !T {
        var buf: [@sizeOf(T)]u8 = undefined;
        try self.bytes(&buf);
        return std.mem.readInt(T, &buf, .little);
    }
    pub fn row(self: *Decoder, cells: []Cell, a: std.mem.Allocator) !bool {
        const tag = try self.integer(u8);
        if (tag == 0) {
            if (try self.integer(u64) != self.table_rows) return error.TableCount;
            self.table_rows = 0;
            return false;
        }
        if (tag != 1) return error.RowTag;
        if (self.rows >= self.control.limits.rows) return error.RowCountBudget;
        var size: usize = 0;
        for (cells) |*cell| {
            const kind = try self.integer(u8);
            size += 1;
            switch (kind) {
                0 => cell.* = .null_value,
                1, 2 => {
                    size += 8;
                    if (size > self.control.limits.row_bytes) return error.RowBytesBudget;
                    const bits = try self.integer(u64);
                    cell.* = if (kind == 1) .{ .integer = @bitCast(bits) } else .{ .real = @bitCast(bits) };
                },
                3, 4 => {
                    const len = try self.integer(u32);
                    size += 4 + @as(usize, len);
                    if (size > self.control.limits.row_bytes) return error.RowBytesBudget;
                    // Allocate one extra byte so zero-length TEXT/BLOB bind non-null.
                    const data = try a.alloc(u8, @as(usize, len) + 1);
                    try self.bytes(data[0..len]);
                    cell.* = if (kind == 3) .{ .text = data[0..len] } else .{ .blob = data[0..len] };
                },
                else => return error.CellTag,
            }
            if (size > self.control.limits.row_bytes) return error.RowBytesBudget;
        }
        self.rows += 1;
        self.table_rows += 1;
        return true;
    }
    pub fn finish(self: *Decoder, tables: usize) !Report {
        var end: [8]u8 = undefined;
        try self.bytes(&end);
        if (!p.eql(&end, "ENDSTRM1") or try self.integer(u64) != self.rows) return error.Footer;
        const actual = self.hash.finalResult();
        var expected: [32]u8 = undefined;
        try self.reader.exact(&expected);
        if (!p.eql(&expected, &actual)) return error.Digest;
        try self.reader.finish();
        return .{ .digest = actual, .rows = self.rows, .tables = tables };
    }
};
