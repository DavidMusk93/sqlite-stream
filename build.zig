const std = @import("std");

fn module(b: *std.Build, root: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sqlite: []const u8, zstd: []const u8) *std.Build.Module {
    const m = b.createModule(.{ .root_source_file = b.path(root), .target = target, .optimize = optimize, .link_libc = true });
    const abi = b.addTranslateC(.{ .root_source_file = b.path("src/abi.h"), .target = target, .optimize = optimize, .link_libc = true });
    abi.addIncludePath(.{ .cwd_relative = sqlite });
    abi.addIncludePath(.{ .cwd_relative = zstd });
    m.addImport("c", abi.createModule());
    m.addIncludePath(.{ .cwd_relative = sqlite });
    m.addIncludePath(.{ .cwd_relative = zstd });
    m.addCSourceFile(.{ .file = b.path("src/abi.c"), .flags = &.{"-std=c11"} });
    m.addCSourceFile(.{
        .file = .{ .cwd_relative = b.pathJoin(&.{ sqlite, "sqlite3.c" }) },
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_OMIT_LOAD_EXTENSION", "-DSQLITE_DEFAULT_MEMSTATUS=0" },
    });
    for ([_][]const u8{
        "common/debug.c",                      "common/entropy_common.c",            "common/error_private.c",
        "common/fse_decompress.c",             "common/xxhash.c",                    "common/zstd_common.c",
        "compress/fse_compress.c",             "compress/hist.c",                    "compress/huf_compress.c",
        "compress/zstd_compress.c",            "compress/zstd_compress_literals.c",  "compress/zstd_compress_sequences.c",
        "compress/zstd_compress_superblock.c", "compress/zstd_double_fast.c",        "compress/zstd_fast.c",
        "compress/zstd_lazy.c",                "compress/zstd_ldm.c",                "compress/zstd_opt.c",
        "compress/zstd_preSplit.c",            "decompress/huf_decompress.c",        "decompress/zstd_ddict.c",
        "decompress/zstd_decompress.c",        "decompress/zstd_decompress_block.c",
    }) |source| {
        m.addCSourceFile(.{
            .file = .{ .cwd_relative = b.pathJoin(&.{ zstd, source }) },
            .flags = &.{ "-DZSTD_DISABLE_ASM", "-DZSTD_LEGACY_SUPPORT=0" },
        });
    }
    return m;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sqlite = b.option([]const u8, "sqlite-dir", "Verified SQLite amalgamation") orelse @panic("use scripts/build.sh");
    const zstd = b.option([]const u8, "zstd-dir", "Verified Zstandard lib directory") orelse @panic("use scripts/build.sh");
    b.installArtifact(b.addExecutable(.{ .name = "sqlite-stream", .root_module = module(b, "src/main.zig", target, optimize, sqlite, zstd) }));
    const tests = b.addTest(.{ .root_module = module(b, "src/tests.zig", target, optimize, sqlite, zstd) });
    b.step("test", "Run native contract tests").dependOn(&b.addRunArtifact(tests).step);
}
