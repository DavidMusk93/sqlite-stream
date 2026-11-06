const p = @import("platform.zig");
const c = p.c;
fn check(rc: usize) !usize {
    if (c.ZSTD_isError(rc) != 0) {
        p.log("zstd: {s}", .{c.ZSTD_getErrorName(rc)});
        return error.Zstandard;
    }
    return rc;
}
pub const Writer = struct {
    fd: *p.Fd,
    context: *c.ZSTD_CCtx,
    raw: [65536]u8 = undefined,
    used: usize = 0,
    output: [131072]u8 = undefined,
    pub fn init(fd: *p.Fd) !Writer {
        const context = c.ZSTD_createCCtx() orelse return error.OutOfMemory;
        errdefer _ = c.ZSTD_freeCCtx(context);
        _ = try check(c.ZSTD_CCtx_setParameter(context, c.ZSTD_c_compressionLevel, 3));
        _ = try check(c.ZSTD_CCtx_setParameter(context, c.ZSTD_c_windowLog, 23));
        _ = try check(c.ZSTD_CCtx_setParameter(context, c.ZSTD_c_checksumFlag, 1));
        return .{ .fd = fd, .context = context };
    }
    pub fn deinit(self: *Writer) void {
        _ = c.ZSTD_freeCCtx(self.context);
    }
    pub fn write(self: *Writer, bytes: []const u8) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const amount = @min(bytes.len - offset, self.raw.len - self.used);
            @memcpy(self.raw[self.used..][0..amount], bytes[offset..][0..amount]);
            self.used += amount;
            offset += amount;
            if (self.used == self.raw.len) try self.flush(c.ZSTD_e_continue);
        }
    }
    fn flush(self: *Writer, mode: c.ZSTD_EndDirective) !void {
        var input: c.ZSTD_inBuffer = .{ .src = &self.raw, .size = self.used, .pos = 0 };
        while (true) {
            try self.fd.control.check();
            var out: c.ZSTD_outBuffer = .{ .dst = &self.output, .size = self.output.len, .pos = 0 };
            const remaining = try check(c.ZSTD_compressStream2(self.context, &out, &input, mode));
            try self.fd.write(self.output[0..out.pos]);
            if (input.pos == input.size and (mode == c.ZSTD_e_continue or remaining == 0)) break;
        }
        self.used = 0;
    }
    pub fn finish(self: *Writer) !void {
        try self.flush(c.ZSTD_e_end);
    }
};
pub const Reader = struct {
    fd: *p.Fd,
    context: *c.ZSTD_DCtx,
    compressed: [65536]u8 = undefined,
    size: usize = 0,
    position: usize = 0,
    ended: bool = false,
    pub fn init(fd: *p.Fd) !Reader {
        const context = c.ZSTD_createDCtx() orelse return error.OutOfMemory;
        errdefer _ = c.ZSTD_freeDCtx(context);
        _ = try check(c.ZSTD_DCtx_setParameter(context, c.ZSTD_d_windowLogMax, 23));
        return .{ .fd = fd, .context = context };
    }
    pub fn deinit(self: *Reader) void {
        _ = c.ZSTD_freeDCtx(self.context);
    }
    pub fn read(self: *Reader, buffer: []u8) !usize {
        if (self.ended) return 0;
        while (true) {
            try self.fd.control.check();
            if (self.position == self.size) {
                self.size = try self.fd.read(&self.compressed);
                self.position = 0;
                if (self.size == 0) return error.TruncatedFrame;
            }
            var input: c.ZSTD_inBuffer = .{ .src = &self.compressed, .size = self.size, .pos = self.position };
            var output: c.ZSTD_outBuffer = .{ .dst = buffer.ptr, .size = buffer.len, .pos = 0 };
            const remaining = try check(c.ZSTD_decompressStream(self.context, &output, &input));
            self.position = input.pos;
            if (remaining == 0) self.ended = true;
            if (output.pos != 0 or self.ended) return output.pos;
        }
    }
    pub fn exact(self: *Reader, buffer: []u8) !void {
        var offset: usize = 0;
        while (offset < buffer.len) {
            const n = try self.read(buffer[offset..]);
            if (n == 0) return error.TruncatedArchive;
            offset += n;
        }
    }
    pub fn finish(self: *Reader) !void {
        var byte: [1]u8 = undefined;
        if (try self.read(&byte) != 0) return error.TrailingArchive;
        if (!self.ended or self.position != self.size or try self.fd.read(&byte) != 0) return error.TrailingFrame;
    }
};
