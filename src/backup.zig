const std = @import("std");
const p = @import("platform.zig");
const s = @import("sqlite.zig");
const schema = @import("schema.zig");
const stream = @import("stream.zig");
const format = @import("format.zig");

pub fn backup(db: s.Db, output: *p.Fd, control: *const p.Control) !format.Report {
    try control.check();
    try db.exec("BEGIN");
    // Rollback releases the read snapshot on every error, including broken pipes.
    var committed = false;
    defer if (!committed) db.exec("ROLLBACK") catch {};
    const buf = try p.allocator.alloc(u8, 16 * 1024 * 1024);
    defer p.allocator.free(buf);
    var bounded: std.heap.FixedBufferAllocator = .init(buf);
    const catalog = try schema.discover(db, bounded.allocator(), control.limits);
    try db.check();
    var writer = try stream.Writer.init(output);
    defer writer.deinit();
    const report = try format.scan(db, catalog, &writer, control);
    try writer.finish();
    try control.check();
    try db.exec("COMMIT");
    committed = true;
    return report;
}
