# sqlite-stream

Schema-aware SQLite streams in Zig, independent of application tables.
Linux release executables statically link SQLite and Zstandard with musl; remote hosts
need neither a compiler nor installed SQLite libraries.

## Build

```bash
bash scripts/build.sh test
bash scripts/build.sh native
bash scripts/build.sh release
```

The bootstrap pins Zig 0.17.1, SQLite 3.54.1 and Zstandard 1.5.7 by SHA-256.
Sources, compiler, caches and executables stay outside the checkout.
Set `SQLITE_STREAM_CACHE` and `SQLITE_STREAM_OUTPUT` to absolute paths to
override their defaults. Release targets are x86_64/aarch64 Linux and macOS.
Native builds use the build host's libc target. Use the Linux musl release
target when transferring executables to Linux servers.

## Schema discovery

```bash
sqlite-stream inspect path/to/database.db
```

Discovery retains original DDL, accessible rowids, WITHOUT ROWID primary keys
and insertable columns. Generated columns are recomputed on restore.
Schema and row traversal must share one read transaction. UTF-8 databases are
supported; virtual/shadow tables and tables whose three rowid aliases are all
shadowed fail explicitly. Internal planner statistics are recreated by SQLite.

## Backup and restore

```bash
sqlite-stream backup database.db snapshot.sqls.zst
sqlite-stream backup database.db - | ssh server 'sqlite-stream restore - restored.db'
sqlite-stream verify snapshot.sqls.zst --scratch /path/with/free/space
sqlite-stream restore snapshot.sqls.zst restored.db
```

The archive streams live rows as typed binary values inside one Zstandard frame.
It retains NULL, INTEGER, REAL, raw TEXT and BLOB bytes, sparse rowids, schema
versions, indices, views, triggers and AUTOINCREMENT sequence state. It omits
freelist pages and rebuildable index pages. This is a logical archive, not a
byte-for-byte database image.

Backup discovers schema, checks integrity/foreign keys and reads rows in one
read transaction. Restore creates tables, loads rows, then creates the remaining
objects. It checks the footer, schema, integrity, foreign keys and a second
complete logical scan before publishing. `verify` performs the same full
restore in scratch space; it needs room for the restored database.

File destinations must be absent. Outputs are written in a private sibling
directory and published with an atomic hard link after `fsync`. The parent
directory must be trusted and the filesystem must support hard links and
directory synchronization. A `PublishedButDirectorySyncFailed` error means the
complete destination exists but crash durability is uncertain.

## Embedding

`build.zig` exports `library(b, source_root, target, optimize, sqlite_dir, zstd_dir)`.
Import its module as `sqlite_stream`; it compiles the pinned SQLite and Zstandard
once, so the consuming executable must not compile a second amalgamation.
For a local Zig package dependency, set `.sqlite_stream = .{ .path = "../sqlite_stream" }`
in the consumer's `build.zig.zon`, pass `target`, `optimize`, `sqlite-dir` and
`zstd-dir` to `b.dependency("sqlite_stream", ...)`, and import
`dependency.module("sqlite_stream")`. The package also exposes the CLI artifact.
`src/lib.zig` exposes `Control`, `Limits`, `Report`, `Db`, `backup(path, fd, control)`
and `restore(input_fd, output_path, output_fd, control)`.

The caller owns private staging, file identity checks, cleanup, synchronization,
publication and replication. Restore requires an exclusively created empty file
whose path identifies its output descriptor. It never publishes that file.
Linux `/proc/self/fd/<directory>/<name>` database paths use a VFS that preserves
the descriptor-relative name instead of canonicalizing it. VFS initialization
must be serialized. Signal handlers are installed only by an explicit
`initSignals()` call.

## Resource limits

The default limits are 8 MiB per encoded row, 4 MiB schema and one hour elapsed
time. Catalog parsing has a separate 16 MiB allocation ceiling; the Zstandard
window is at most 8 MiB. Database size is independent of these memory limits.
Limits can be tightened for remote operations:

```bash
sqlite-stream backup database.db snapshot.sqls.zst \
  --timeout-seconds 300 --max-wal-bytes 268435456 --max-archive-bytes 1073741824
sqlite-stream restore snapshot.sqls.zst restored.db \
  --max-database-bytes 1073741824 --max-rows 10000000
```

`--max-row-bytes` can raise the row limit up to 256 MiB. SIGINT/SIGTERM and
blocked pipes are handled cooperatively without helper threads. SQLite work
uses a progress hook; source WAL growth can abort a backup and release its read
snapshot. Kernel-blocked regular-file I/O or `fsync` cannot guarantee a hard
wall-clock timeout. Database byte limits cap SQLite pages; journals and scratch
directory space still need an external filesystem quota.

## Safety and scope

Archives contain SQL definitions. Restore restricts execution to the declared
CREATE object, disables extensions/trusted schema and rejects ATTACH, PRAGMAs,
temporary objects, extra statements and CREATE TABLE AS SELECT. It validates
table metadata against the created schema before inserting.

User-defined SQLite functions, collations and virtual modules are unsupported.
UTF-16 databases fail explicitly. Backups with corrupt databases or violated
foreign keys fail rather than silently dropping information. Planner statistics,
page size, journal mode, `data_version`, free pages and physical page ordering
are not preserved. Triggers and views retain their definitions for later use.
SHA-256 and the Zstandard checksum detect corruption; they do not authenticate
an archive. See [the format](docs/format.md) and [security notes](docs/security.md).
