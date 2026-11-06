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
```

Discovery must share a read transaction with later data traversal. UTF-8
databases are supported. Virtual/shadow tables and tables with all three rowid
aliases shadowed are rejected explicitly. Metadata and records have separate
budgets; these are independent of total database size.

## Implementation status

The discovery command and codec are implemented. The backup/restore pipeline,
resource validation and publication are subsequent feature commits.
