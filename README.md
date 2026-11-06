# sqlite-stream

Schema-aware SQLite streams in Zig, independent of application tables.
Linux executables statically link SQLite and Zstandard with musl; remote hosts
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

## Schema discovery

```bash
sqlite-stream inspect path/to/database.db
```

Discovery retains original DDL, accessible rowids, WITHOUT ROWID primary keys
and insertable columns. Generated columns are recomputed on restore.
Schema and row traversal must share one read transaction. UTF-8 databases are
supported; virtual/shadow tables and tables whose three rowid aliases are all
shadowed fail explicitly. Internal planner statistics are recreated by SQLite.
