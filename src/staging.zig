const std = @import("std");
const p = @import("platform.zig");
const c = p.c;
// Use a private sibling directory; SQLite's journal is private as well.
pub const Stage = struct {
    directory: [:0]u8,
    path: [:0]u8,
    fd: c_int,
    pub fn init(parent: []const u8) !Stage {
        const template = try std.fmt.allocPrintSentinel(p.allocator, "{s}/.sqlite-stream-XXXXXX", .{parent}, 0);
        errdefer p.allocator.free(template);
        if (c.mkdtemp(template.ptr) == null) return error.StagingDirectory;
        errdefer _ = c.rmdir(template);
        const path = try std.fmt.allocPrintSentinel(p.allocator, "{s}/database", .{template}, 0);
        errdefer p.allocator.free(path);
        const fd = c.open(path.ptr, c.O_RDWR | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return error.StagingFile;
        return .{ .directory = template, .path = path, .fd = fd };
    }
    pub fn deinit(self: *Stage) void {
        _ = c.close(self.fd);
        _ = c.unlink(self.path);
        for ([_][]const u8{ "-journal", "-wal", "-shm" }) |suffix| {
            const side = std.fmt.allocPrintSentinel(p.allocator, "{s}{s}", .{ self.path, suffix }, 0) catch continue;
            defer p.allocator.free(side);
            _ = c.unlink(side);
        }
        _ = c.rmdir(self.directory);
        p.allocator.free(self.path);
        p.allocator.free(self.directory);
    }
    pub fn sync(self: Stage) !void {
        if (c.fsync(self.fd) != 0) return error.Sync;
    }
    pub fn publish(self: Stage, destination: []const u8) !void {
        const parent = std.fs.path.dirname(destination) orelse ".";
        const parent_z = try p.z(parent);
        defer p.allocator.free(parent_z);
        const fd = c.open(parent_z.ptr, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC, @as(c_uint, 0));
        if (fd < 0) return error.ParentDirectory;
        defer _ = c.close(fd);
        const name = try p.z(std.fs.path.basename(destination));
        defer p.allocator.free(name);
        // Hard-link publication is atomic and fails if any destination exists.
        if (c.linkat(c.AT_FDCWD, self.path, fd, name.ptr, 0) != 0) return error.Publish;
        if (c.fsync(fd) != 0) return error.PublishedButDirectorySyncFailed;
    }
};
