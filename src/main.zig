const std = @import("std");
const p = @import("platform.zig");
const s = @import("sqlite.zig");
const schema = @import("schema.zig");
pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        p.log("sqlite-stream: {s}", .{@errorName(err)});
        cExit();
    };
}
fn cExit() noreturn {
    p.c.exit(1);
}
fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(p.allocator);
    defer p.allocator.free(args);
    if (args.len != 3 or !p.eql(args[1], "inspect")) {
        p.log("usage: sqlite-stream inspect DATABASE", .{});
        return error.Usage;
    }
    p.c.ss_signals();
    var control = try p.Control.init(.{});
    defer control.deinit();
    const db = try s.Db.open(args[2], false, &control);
    defer db.close();
    try db.exec("BEGIN");
    const buf = try p.allocator.alloc(u8, 16 * 1024 * 1024);
    defer p.allocator.free(buf);
    var bounded: std.heap.FixedBufferAllocator = .init(buf);
    const catalog = try schema.discover(db, bounded.allocator(), control.limits);
    const json = try catalog.json(p.allocator);
    defer p.allocator.free(json);
    var output = try p.Fd.init(1, &control);
    defer output.deinit();
    try output.write(json);
    try output.write("\n");
    try db.exec("COMMIT");
}
