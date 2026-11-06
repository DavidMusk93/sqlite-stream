//! In-process codec API. Callers own filesystem identity checks, private staging,
//! fsync/publication, retention and replication. No subprocesses are launched.
const p = @import("platform.zig");
pub const Control = p.Control;
pub const Limits = p.Limits;
pub const Report = @import("format.zig").Report;
pub const Db = @import("sqlite.zig").Db;
pub const initSignals = p.c.ss_signals;

pub fn backup(source_path: []const u8, output_fd: c_int, control: *const Control) !Report {
    const source = try Db.open(source_path, false, control);
    defer source.close();
    var output = try p.Fd.init(output_fd, control);
    defer output.deinit();
    return @import("backup.zig").backup(source, &output, control);
}

/// Restore into a caller-owned empty file. The path must identify output_fd;
/// its directory must be private, and failure requires caller cleanup.
pub fn restore(input_fd: c_int, output_path: []const u8, output_fd: c_int, control: *const Control) !Report {
    var input = try p.Fd.init(input_fd, control);
    defer input.deinit();
    return @import("restore.zig").loadInto(&input, output_path, output_fd, control);
}
