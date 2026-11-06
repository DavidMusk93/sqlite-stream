# Archive format v1

## Envelope

An archive contains exactly one Zstandard frame with a checksum and at most an
8 MiB window. Concatenated frames, including an empty second frame, fail.
Integers use little-endian encoding. No alignment padding is inserted.
The format version is experimental; incompatible changes require a new magic.

| Position       | Encoding                | Meaning                                     |
| -------------- | ----------------------- | ------------------------------------------- |
| Header         | 8 bytes `SQLSTRM1`      | Version identification                      |
| Catalog length | unsigned 32-bit         | JSON byte count                             |
| Catalog        | UTF-8 JSON              | Schema and traversal metadata               |
| Tables         | Ordered sequences below | One sequence per catalog table              |
| Footer marker  | 8 bytes `ENDSTRM1`      | All tables ended                            |
| Total rows     | unsigned 64-bit         | Count across all tables                     |
| Digest         | 32 raw bytes            | SHA-256 of all preceding uncompressed bytes |

The catalog records `user_version`, `application_id`, objects (`kind`, `name`,
original `sql`) and tables (`name`, insertable `columns`, ordering columns
`order`, `without_rowid`). Discovery sorts objects by binary type/name and
tables by binary name, with `sqlite_sequence` last.

## Rows and cells

Each table emits zero or more rows. A row starts with byte `1`, followed by
exactly as many cells as the catalog's column count. Byte `0` ends the table,
followed by its unsigned 64-bit row count. There is no per-row length prefix.

| Cell tag | Payload                                | SQLite type |
| -------: | -------------------------------------- | ----------- |
| 0        | None                                   | NULL        |
| 1        | Signed 64-bit integer                  | INTEGER     |
| 2        | 64-bit IEEE-754 bit pattern            | REAL        |
| 3        | Unsigned 32-bit byte length, raw bytes | TEXT        |
| 4        | Unsigned 32-bit byte length, raw bytes | BLOB        |

TEXT may contain NUL or invalid UTF-8; its bytes are never JSON encoded.
Schema identifiers and SQL must be valid UTF-8 without NUL. Empty TEXT and BLOB
remain distinct from NULL.

Ordinary tables include an accessible hidden rowid and sort by it. WITHOUT
ROWID tables sort by their declared primary key, respecting SQLite collations.
Generated columns are omitted from inserts and recomputed from their DDL.
AUTOINCREMENT sequence values are restored after application rows.

## Integrity contract

Backup holds one read transaction for schema discovery, integrity and foreign
key checks, and the full row scan. The digest includes catalog bytes, row tags,
typed payloads, table counts and footer count. It excludes the digest itself.
stderr reports the digest, total rows and table count; stdout carries archive
bytes when requested.

Restore recreates tables and compares discovered insertion metadata, inserts
rows using bound parameters, then creates indices, views and triggers.
It rejects invalid tags, sizes, counts, digest, incomplete frames or trailing
bytes. It then checks schema, SQLite integrity and foreign keys, and rescans
the entire restored logical database to compare its digest and row count.
Only a successful transaction and file synchronization permit publication.

This preserves the supported logical state, not physical page order,
freelist, planner statistics or SQLite file hashes. A checksum is not a
signature; external authentication is required to establish archive provenance.
