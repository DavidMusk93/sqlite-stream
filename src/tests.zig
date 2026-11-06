const std = @import("std");
const p = @import("platform.zig");
const s = @import("sqlite.zig");
const schema = @import("schema.zig");
const backup = @import("backup.zig");
const restore = @import("restore.zig");
const staging = @import("staging.zig");
const stream = @import("stream.zig");
const format = @import("format.zig");
const c = p.c;

test "embedded API uses the same codec and caller-owned restore file" {
    const lib = @import("lib.zig");
    var control = try lib.Control.init(.{});
    defer control.deinit();
    var source = try staging.Stage.init("/tmp");
    defer source.deinit();
    {
        const db = try lib.Db.open(source.path, true, &control);
        defer db.close();
        try db.exec("CREATE TABLE x(v); INSERT INTO x VALUES(1),(x'00ff')");
    }
    var archive = try staging.Stage.init("/tmp");
    defer archive.deinit();
    const expected = try lib.backup(source.path, archive.fd, &control);
    try rewind(archive.fd);
    var target = try staging.Stage.init("/tmp");
    defer target.deinit();
    try std.testing.expectEqual(expected, try lib.restore(archive.fd, target.path, target.fd, &control));
}

test "descriptor VFS keeps SQLite filenames bound to the opened directory" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    var control = try p.Control.init(.{});
    defer control.deinit();
    var stage = try staging.Stage.init("/tmp");
    defer stage.deinit();
    const fd = c.open(stage.directory.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC, @as(c_uint, 0));
    if (fd < 0) return error.Open;
    defer _ = c.close(fd);
    const path = try std.fmt.allocPrint(p.allocator, "/proc/self/fd/{d}/database", .{fd});
    defer p.allocator.free(path);
    const db = try s.Db.open(path, true, &control);
    defer db.close();
    try db.exec("CREATE TABLE x(v); INSERT INTO x VALUES(7)");
    try std.testing.expectEqualStrings(path, std.mem.span(c.sqlite3_db_filename(db.handle, "main")));
    try std.testing.expectEqual(@as(i64, 7), try db.scalar("SELECT v FROM x"));
}

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

const complex_sql =
    \\PRAGMA user_version=73; PRAGMA application_id=-27;
    \\CREATE TABLE "a""z" (id INTEGER PRIMARY KEY AUTOINCREMENT, v, g TEXT AS (hex(v)) STORED);
    \\CREATE TABLE parent(a TEXT COLLATE NOCASE, b INTEGER, PRIMARY KEY(a,b)) WITHOUT ROWID, STRICT;
    \\CREATE TABLE child(p TEXT, n INTEGER, FOREIGN KEY(p,n) REFERENCES parent(a,b));
    \\CREATE TABLE cycle_a(id INTEGER PRIMARY KEY, b REFERENCES cycle_b(id));
    \\CREATE TABLE cycle_b(id INTEGER PRIMARY KEY, a REFERENCES cycle_a(id));
    \\INSERT INTO "a""z"(id,v) VALUES(-4,NULL),(9,x'00ff'),(12,CAST(x'61ff00' AS TEXT)),(17,-1.5),(99,'gone'),(101,''),(102,x'');
    \\DELETE FROM "a""z" WHERE id=99 OR id=102;
    \\INSERT INTO parent VALUES('B',2),('a',1);
    \\INSERT INTO child(rowid,p,n) VALUES(-9,'A',1);
    \\INSERT INTO cycle_a VALUES(1,1); INSERT INTO cycle_b VALUES(1,1);
    \\CREATE INDEX ix ON "a""z"(v) WHERE v IS NOT NULL;
    \\CREATE VIEW vw AS SELECT v FROM "a""z";
    \\CREATE TRIGGER tr AFTER INSERT ON child BEGIN UPDATE child SET n=n WHERE rowid=new.rowid; END;
;

fn rewind(fd: c_int) !void {
    if (c.lseek(fd, 0, c.SEEK_SET) < 0) return error.Seek;
}

test "compressed round trip preserves schema raw text sequences cycles and sparse rowids" {
    var control = try p.Control.init(.{});
    defer control.deinit();
    const source = try s.Db.open(":memory:", true, &control);
    defer source.close();
    try source.exec(complex_sql);
    var archive = try staging.Stage.init("/tmp");
    defer archive.deinit();
    var output = try p.Fd.init(archive.fd, &control);
    defer output.deinit();
    const original = try backup.backup(source, &output, &control);
    try std.testing.expect(c.sqlite3_get_autocommit(source.handle) != 0);
    try rewind(archive.fd);
    var input = try p.Fd.init(archive.fd, &control);
    defer input.deinit();
    var target = try staging.Stage.init("/tmp");
    defer target.deinit();
    const restored = try restore.load(&input, &target, &control);
    try std.testing.expectEqual(original, restored);
    const db = try s.Db.open(target.path, false, &control);
    defer db.close();
    try std.testing.expectEqual(@as(i64, 102), try db.scalar("SELECT seq FROM sqlite_sequence"));
    try std.testing.expectEqual(@as(i64, -9), try db.scalar("SELECT rowid FROM child"));
    const raw = try db.prepare("SELECT typeof(v)||':'||hex(v) FROM \"a\"\"z\" WHERE id=12");
    defer raw.close();
    try std.testing.expect(try raw.step());
    try std.testing.expectEqualStrings("text:61FF00", try raw.text(0));
}

test "guarded DDL rejects attach pragma extra SQL CTAS and mismatched objects" {
    var control = try p.Control.init(.{});
    defer control.deinit();
    const db = try s.Db.open(":memory:", true, &control);
    defer db.close();
    const Case = struct { sql: []const u8, expected: anyerror };
    for ([_]Case{
        .{ .sql = "ATTACH '/tmp/sqlite-stream-escape.db' AS escaped", .expected = error.SQLitePrepare },
        .{ .sql = "PRAGMA writable_schema=ON", .expected = error.SQLitePrepare },
        .{ .sql = "CREATE TABLE x(v); CREATE TABLE extra(v)", .expected = error.ExtraSQL },
        .{ .sql = "CREATE TABLE x AS SELECT randomblob(10000) AS v", .expected = error.SQLitePrepare },
        .{ .sql = "CREATE VIRTUAL TABLE x USING fts5(v)", .expected = error.SQLitePrepare },
        .{ .sql = "CREATE TABLE wrong(v)", .expected = error.SQLitePrepare },
    }) |case| {
        try std.testing.expectError(case.expected, restore.create(db, .{ .kind = "table", .name = "x", .sql = case.sql }));
        try std.testing.expectEqual(@as(i64, 0), try db.scalar("SELECT count(*) FROM sqlite_schema WHERE name IN ('x','wrong','extra')"));
    }
}

test "every compressed truncation corruption and trailing empty frame is rejected" {
    var control = try p.Control.init(.{});
    defer control.deinit();
    const db = try s.Db.open(":memory:", true, &control);
    defer db.close();
    try db.exec("CREATE TABLE x(v); INSERT INTO x VALUES(x'00ff'),(CAST(x'61ff00' AS TEXT)),(1.25),(''),(x''),(NULL)");
    var archive = try staging.Stage.init("/tmp");
    defer archive.deinit();
    var output = try p.Fd.init(archive.fd, &control);
    defer output.deinit();
    _ = try backup.backup(db, &output, &control);
    const length = c.lseek(archive.fd, 0, c.SEEK_END);
    const bytes = try std.testing.allocator.alloc(u8, @intCast(length));
    defer std.testing.allocator.free(bytes);
    try rewind(archive.fd);
    try std.testing.expectEqual(length, c.read(archive.fd, bytes.ptr, bytes.len));
    for (0..bytes.len) |end| {
        if (c.ftruncate(archive.fd, @intCast(end)) != 0) return error.Truncate;
        try rewind(archive.fd);
        if (c.write(archive.fd, bytes.ptr, end) != end) return error.Write;
        try expectInvalid(archive.fd, &control);
    }
    try rewind(archive.fd);
    if (c.ftruncate(archive.fd, @intCast(bytes.len)) != 0) return error.Truncate;
    bytes[bytes.len / 2] ^= 128;
    if (c.write(archive.fd, bytes.ptr, bytes.len) != bytes.len) return error.Write;
    try expectInvalid(archive.fd, &control);
    bytes[bytes.len / 2] ^= 128;
    try rewind(archive.fd);
    if (c.write(archive.fd, bytes.ptr, bytes.len) != bytes.len) return error.Write;
    var writer = try stream.Writer.init(&output);
    defer writer.deinit();
    try writer.finish(); // A valid empty second Zstandard frame is still trailing data.
    try expectInvalid(archive.fd, &control);
}
fn expectInvalid(fd: c_int, control: *const p.Control) !void {
    try rewind(fd);
    var input = try p.Fd.init(fd, control);
    defer input.deinit();
    var target = try staging.Stage.init("/tmp");
    defer target.deinit();
    if (restore.load(&input, &target, control)) |_| return error.InvalidArchiveAccepted else |_| {}
}

test "backup row and archive budgets roll back the source transaction" {
    var control = try p.Control.init(.{ .rows = 1 });
    defer control.deinit();
    const db = try s.Db.open(":memory:", true, &control);
    defer db.close();
    try db.exec("CREATE TABLE x(v); INSERT INTO x VALUES(1),(2)");
    var archive = try staging.Stage.init("/tmp");
    defer archive.deinit();
    var output = try p.Fd.init(archive.fd, &control);
    defer output.deinit();
    try std.testing.expectError(error.RowCountBudget, backup.backup(db, &output, &control));
    try std.testing.expect(c.sqlite3_get_autocommit(db.handle) != 0);
    control.limits.rows = std.math.maxInt(u64);
    control.limits.archive_bytes = 1;
    try std.testing.expectError(error.ArchiveBudget, backup.backup(db, &output, &control));
    try std.testing.expect(c.sqlite3_get_autocommit(db.handle) != 0);
}
