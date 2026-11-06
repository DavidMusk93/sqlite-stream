const std = @import("std");
const p = @import("platform.zig");
const s = @import("sqlite.zig");
const schema = @import("schema.zig");

test "discover rowids generated columns strict without rowid and original DDL" {
    var control = try p.Control.init(.{});
    defer control.deinit();
    const db = try s.Db.open(":memory:", true, &control);
    defer db.close();
    try db.exec(
        \\CREATE TABLE "a""b"(id INTEGER PRIMARY KEY AUTOINCREMENT, t TEXT, b BLOB, g TEXT GENERATED ALWAYS AS (t||'!') STORED) STRICT;
        \\CREATE TABLE keys(a TEXT, b INTEGER, PRIMARY KEY(b,a)) WITHOUT ROWID;
        \\CREATE INDEX lookup ON keys(a);
        \\CREATE VIEW v AS SELECT * FROM keys;
        \\CREATE TRIGGER tr AFTER INSERT ON keys BEGIN SELECT 1; END;
        \\PRAGMA user_version=17;
        \\BEGIN;
    );
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const catalog = try schema.discover(db, arena.allocator(), .{});
    try std.testing.expectEqual(@as(usize, 3), catalog.tables.len);
    try std.testing.expectEqual(@as(usize, 5), catalog.objects.len);
    try std.testing.expectEqual(@as(i64, 17), catalog.user_version);
    try std.testing.expectEqualStrings("sqlite_sequence", catalog.tables[2].name);
    try std.testing.expectEqualStrings("rowid", catalog.tables[0].columns[0]);
    try std.testing.expectEqual(@as(usize, 4), catalog.tables[0].columns.len);
    try std.testing.expectEqualStrings("b", catalog.tables[1].order[0]);
    try std.testing.expectEqualStrings("a", catalog.tables[1].order[1]);
}

test "unsupported schemas fail explicitly and identifiers are quoted" {
    var control = try p.Control.init(.{});
    defer control.deinit();
    const db = try s.Db.open(":memory:", true, &control);
    defer db.close();
    try db.exec("CREATE TABLE shadow(rowid,_rowid_,oid); BEGIN;");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ShadowedRowid, schema.discover(db, arena.allocator(), .{}));
    const quoted = try schema.quote(std.testing.allocator, "a\"b");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("\"a\"\"b\"", quoted);
}

test "single statement preparation rejects a second statement" {
    var control = try p.Control.init(.{});
    defer control.deinit();
    const db = try s.Db.open(":memory:", true, &control);
    defer db.close();
    try std.testing.expectError(error.ExtraSQL, db.prepare("SELECT 1; /* comment */ SELECT 2;"));
}
