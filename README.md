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
cargo run -- verify snapshot.sqls.zst --scratch /path/with/free/space
cargo run -- restore snapshot.sqls.zst restored.db
```

Discovery must share a read transaction with later data traversal. UTF-8
databases are supported. Virtual/shadow tables and tables with all three rowid
aliases shadowed are rejected explicitly. Metadata and records have separate
budgets; these are independent of total database size.

## Implementation status

Discovery, the binary codec, compressed snapshot backup, restore and verification are implemented.
Backup uses one read transaction, borrowed row values and an 8 MiB Zstandard
window. Integrity and foreign key checks run before any archive bytes are emitted.
File output is staged and published without overwriting an existing path.
Restore loads tables before creating indices, views and triggers. It preserves
accessible rowids and original AUTOINCREMENT sequence rows, including deleted high
IDs. Before publication it checks integrity, foreign keys, schema equivalence and
the complete logical digest by re-reading the staged database. Verification uses
the same full restore in a disposable file. Invalid or trailing frames are rejected.
Archive DDL is authorized only for its declared object; ATTACH, PRAGMAs, arbitrary
DML, virtual tables and extra SQL statements cannot escape the staging database.
Resource validation and public distribution are subsequent feature commits.
