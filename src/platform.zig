const std = @import("std");
pub const c = @import("c");
pub const allocator = std.heap.page_allocator;
pub fn z(bytes: []const u8) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, bytes, 0) != null) return error.EmbeddedNul;
    return allocator.dupeSentinel(u8, bytes, 0);
}
pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn log(comptime format: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(allocator, format ++ "\n", args) catch return;
    defer allocator.free(text);
    _ = c.write(2, text.ptr, text.len);
}
pub const Limits = struct {
    row_bytes: usize = 8 * 1024 * 1024,
    schema_bytes: usize = 4 * 1024 * 1024,
    archive_bytes: u64 = std.math.maxInt(u64),
    database_bytes: u64 = std.math.maxInt(u64),
    rows: u64 = std.math.maxInt(u64),
    wal_bytes: u64 = std.math.maxInt(u64),
    timeout_ms: i64 = 60 * 60 * 1000,
};
pub const Control = struct {
    limits: Limits,
    deadline: i64,
    wal: ?[:0]u8 = null,
    pub fn init(limits: Limits) !Control {
        if (limits.row_bytes < 1024 or limits.row_bytes > 256 * 1024 * 1024 or limits.schema_bytes < 1024 or limits.schema_bytes > 4 * 1024 * 1024 or limits.timeout_ms <= 0 or limits.timeout_ms > 7 * 86400000) return error.InvalidBudget;
        return .{ .limits = limits, .deadline = c.ss_monotonic_ms() + limits.timeout_ms };
    }
    pub fn deinit(self: *Control) void {
        if (self.wal) |path| allocator.free(path);
    }
    pub fn check(self: *const Control) !void {
        if (c.ss_cancelled() != 0) return error.Cancelled;
        if (c.ss_monotonic_ms() >= self.deadline) return error.Deadline;
        if (self.wal) |path| {
            var size: u64 = 0;
            const rc = c.ss_file_size(path.ptr, &size);
            if (rc < 0) return error.WalStat;
            if (rc == 0 and size > self.limits.wal_bytes) return error.WalBudget;
        }
    }
};
pub const Fd = struct {
    fd: c_int,
    flags: c_int,
    control: *const Control,
    bytes: u64 = 0,
    pub fn init(fd: c_int, control: *const Control) !Fd {
        const flags = c.fcntl(fd, c.F_GETFL);
        if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.DescriptorFlags;
        return .{ .fd = fd, .flags = flags, .control = control };
    }
    pub fn deinit(self: *Fd) void {
        _ = c.fcntl(self.fd, c.F_SETFL, self.flags);
    }
    fn ready(self: *Fd, events: c_short) !void {
        while (true) {
            try self.control.check();
            var poll: c.struct_pollfd = .{ .fd = self.fd, .events = events, .revents = 0 };
            const rc = c.poll(&poll, 1, 50);
            if (rc > 0) return;
            if (rc < 0 and c.ss_errno() != c.EINTR) return error.Poll;
        }
    }
    pub fn read(self: *Fd, buffer: []u8) !usize {
        while (true) {
            try self.ready(c.POLLIN);
            const n = c.read(self.fd, buffer.ptr, buffer.len);
            if (n < 0) {
                if (c.ss_errno() == c.EAGAIN or c.ss_errno() == c.EINTR) continue;
                return error.Read;
            }
            const count: usize = @intCast(n);
            if (count > self.control.limits.archive_bytes -| self.bytes) return error.ArchiveBudget;
            self.bytes += count;
            try self.control.check();
            return count;
        }
    }
    pub fn write(self: *Fd, buffer: []const u8) !void {
        if (buffer.len > self.control.limits.archive_bytes -| self.bytes) return error.ArchiveBudget;
        var offset: usize = 0;
        while (offset < buffer.len) {
            try self.ready(c.POLLOUT);
            const n = c.write(self.fd, buffer[offset..].ptr, buffer.len - offset);
            if (n < 0) {
                if (c.ss_errno() == c.EAGAIN or c.ss_errno() == c.EINTR) continue;
                return error.Write;
            }
            if (n == 0) return error.Write;
            offset += @intCast(n);
            self.bytes += @intCast(n);
            try self.control.check();
        }
    }
};
