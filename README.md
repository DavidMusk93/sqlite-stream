# sqlite-stream

Schema-aware SQLite backup and restore streams, independent of application tables.

## Development

The first feature discovers ordinary tables, accessible rowids, WITHOUT ROWID
primary keys, insertable columns, and original DDL. Its binary codec preserves
NULL, INTEGER, REAL, raw TEXT bytes and BLOB bytes; a SHA-256 footer and row
counts reject incomplete archives. SQLite is bundled; no application SDK is needed.

```bash
cargo test
cargo run -- inspect path/to/database.db
cargo run -- backup path/to/database.db snapshot.sqls.zst
cargo run -- backup path/to/database.db - > snapshot.sqls.zst
```

Discovery must share a read transaction with later data traversal. UTF-8
databases are supported. Virtual/shadow tables and tables with all three rowid
aliases shadowed are rejected explicitly. Metadata and records have separate
budgets; these are independent of total database size.

## Implementation status

Discovery, the binary codec and compressed snapshot backup are implemented.
Backup uses one read transaction, borrowed row values and an 8 MiB Zstandard
window. Integrity and foreign key checks run before any archive bytes are emitted.
File output is staged and published without overwriting an existing path.
Restore, resource validation and publication are subsequent feature commits.
