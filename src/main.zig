const std = @import("std");
const p = @import("platform.zig");
const s = @import("sqlite.zig");
const schema = @import("schema.zig");
const backup = @import("backup.zig");
const restore = @import("restore.zig");
const staging = @import("staging.zig");
const format = @import("format.zig");
const c = p.c;
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
    if (args.len == 2 and p.eql(args[1], "--version")) {
        const version = "sqlite-stream 0.1.0 (Zig; SQLite 3.54.1; Zstandard 1.5.7)\n";
        _ = c.write(1, version.ptr, version.len);
        return;
    }
    if (args.len < 3 or p.eql(args[1], "--help")) {
        usage();
        if (args.len == 2 and p.eql(args[1], "--help")) return;
        return error.Usage;
    }
    c.ss_signals();
    var limits: p.Limits = .{};
    var scratch: []const u8 = ".";
    const command = args[1];
    const is_inspect = p.eql(command, "inspect");
    const is_backup = p.eql(command, "backup");
    const is_restore = p.eql(command, "restore");
    const is_verify = p.eql(command, "verify");
    if (!is_inspect and !is_backup and !is_restore and !is_verify) return error.Usage;
    const positional: usize = if (is_backup or is_restore) 4 else 3;
    if (args.len < positional) return error.Usage;
    var i = positional;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.MissingOptionValue;
        const option = args[i];
        const value = args[i + 1];
        if (p.eql(option, "--scratch")) {
            if (!is_verify) return error.Usage;
            scratch = value;
            continue;
        }
        const number = try std.fmt.parseInt(u64, value, 10);
        if (p.eql(option, "--timeout-seconds")) {
            if (number == 0 or number > 7 * 86400) return error.InvalidBudget;
            limits.timeout_ms = @intCast(number * 1000);
        } else if (p.eql(option, "--max-archive-bytes")) limits.archive_bytes = number else if (p.eql(option, "--max-database-bytes")) limits.database_bytes = number else if (p.eql(option, "--max-rows")) limits.rows = number else if (p.eql(option, "--max-wal-bytes")) limits.wal_bytes = number else if (p.eql(option, "--max-row-bytes")) limits.row_bytes = std.math.cast(usize, number) orelse return error.InvalidBudget else return error.UnknownOption;
    }
    var control = try p.Control.init(limits);
    defer control.deinit();
    if (is_inspect or is_backup) {
        control.wal = try std.fmt.allocPrintSentinel(p.allocator, "{s}-wal", .{args[2]}, 0);
        const db = try s.Db.open(args[2], false, &control);
        defer db.close();
        if (is_inspect) {
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
        } else if (p.eql(args[3], "-")) {
            var output = try p.Fd.init(1, &control);
            defer output.deinit();
            report(try backup.backup(db, &output, &control));
        } else {
            try absent(args[3]);
            var stage = try staging.Stage.init(std.fs.path.dirname(args[3]) orelse ".");
            defer stage.deinit();
            var output = try p.Fd.init(stage.fd, &control);
            defer output.deinit();
            const result = try backup.backup(db, &output, &control);
            try stage.sync();
            try control.check();
            try stage.publish(args[3]);
            report(result);
        }
    } else {
        if (is_restore) try absent(args[3]);
        const path = try p.z(args[2]);
        defer p.allocator.free(path);
        const fd = if (p.eql(args[2], "-")) 0 else c.open(path.ptr, c.O_RDONLY | c.O_CLOEXEC | c.O_NOFOLLOW, @as(c_uint, 0));
        if (fd < 0) return error.InputOpen;
        defer if (fd != 0) {
            _ = c.close(fd);
        };
        var input = try p.Fd.init(fd, &control);
        defer input.deinit();
        var stage = try staging.Stage.init(if (is_restore) std.fs.path.dirname(args[3]) orelse "." else scratch);
        defer stage.deinit();
        const result = try restore.load(&input, &stage, &control);
        if (is_restore) {
            try control.check();
            try stage.publish(args[3]);
        }
        report(result);
    }
}
fn absent(path: []const u8) !void {
    const path_z = try p.z(path);
    defer p.allocator.free(path_z);
    if (c.ss_exists(path_z.ptr) != 0) return error.DestinationExistsOrUnavailable;
}
fn report(value: format.Report) void {
    const hex = std.fmt.bytesToHex(value.digest, .lower);
    p.log("{{\"tables\":{d},\"rows\":{d},\"sha256\":\"{s}\"}}", .{ value.tables, value.rows, hex });
}
fn usage() void {
    p.log(
        \\usage: sqlite-stream inspect DATABASE [OPTIONS]
        \\       sqlite-stream backup DATABASE ARCHIVE|- [OPTIONS]
        \\       sqlite-stream restore ARCHIVE|- DATABASE [OPTIONS]
        \\       sqlite-stream verify ARCHIVE|- [--scratch DIRECTORY] [OPTIONS]
        \\options: --timeout-seconds N --max-row-bytes N --max-rows N
        \\         --max-archive-bytes N --max-database-bytes N --max-wal-bytes N
    , .{});
}
