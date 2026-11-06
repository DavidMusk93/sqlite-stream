# Security and resource boundaries

## Archive trust

Archives contain original CREATE definitions. The SQLite authorizer permits
only the declared object and required schema bookkeeping while preparing it.
It rejects ATTACH, arbitrary PRAGMAs, virtual/temporary objects, extra SQL,
and CREATE TABLE AS SELECT. Extension loading is omitted from the SQLite
build; trusted schema is disabled.

Tables are checked against independently discovered metadata before loading.
Data enters parameterized INSERT statements. Triggers are installed after
all rows, so recovery does not fire them. Trigger and view definitions can
affect future queries made by another application; inspect their definitions
before opening an untrusted restored database.

The authorizer and checks reduce the allowed SQL surface; they are not an OS
sandbox or protection against vulnerabilities in SQLite or Zstandard.
Restore unknown input as an unprivileged user inside appropriate filesystem,
CPU and memory restrictions. SHA-256 detects corruption but provides no
authentication.

## Output ownership

Archive and database file destinations must not exist, including dangling
symlinks. A private sibling directory has mode 0700 and its data file mode 0600.
Restore journals stay in that directory. Publication uses an atomic hard link,
then synchronizes the destination directory.

Use a trusted parent directory. Concurrent replacement of parent paths by an
attacker is outside this contract. Filesystems must support hard links and
directory fsync. Once the link succeeds, a directory-fsync failure leaves a
complete file with uncertain crash durability and reports
`PublishedButDirectorySyncFailed`.

Handled failures close SQLite and descriptors, release the source transaction
and remove staging files. SIGKILL, a crash or power loss may leave a private
`.sqlite-stream-*` directory; inspect it before removing it. stdout consumers
must require successful producer exit and complete archive verification.

## Resource model

Rows stream through SQLite cursors, typed encoding and fixed compression
buffers. No full-database row collection or JSON byte arrays are used.
SQLite can materialize a complete row or value; the default encoded row limit
is 8 MiB and oversized values fail. This is bounded row handling, not arbitrary
large-cell streaming.

Catalog JSON is capped at 4 MiB with a separate 16 MiB parsing arena; compression
and decompression windows are capped at 8 MiB. SQLite uses a 2 MiB page-cache
target, mmap is disabled and temporary work uses files. These parameters do
not enforce a hard process RSS ceiling. SQLite statements and index builds
can require additional memory and temporary disk.

| Option                 | Scope                                  | Default   |
| ---------------------- | -------------------------------------- | --------- |
| `--max-row-bytes`      | Encoded cell payloads and tags per row | 8388608   |
| `--max-rows`           | Total rows                             | Unlimited |
| `--max-archive-bytes`  | Compressed bytes read or written       | Unlimited |
| `--max-database-bytes` | Restored main database pages           | Unlimited |
| `--max-wal-bytes`      | Observed source WAL file size          | Unlimited |
| `--timeout-seconds`    | Cooperative elapsed-time deadline      | 3600      |

Row limits accept 1024 through 268435456 bytes; deadlines accept 1 through
604800 seconds. Database limits round down to SQLite pages and do not include
journals, index-build temporary files or total filesystem usage.
`verify` restores to scratch and therefore needs full database disk space.

WAL limits inspect the current source `-wal` pathname, not cumulative writes.
A slow consumer pins the read snapshot until completion, cancellation or
failure. SQLite progress callbacks and nonblocking pipe polling check budgets.
Regular-file I/O, fsync and individual C-library calls cannot guarantee an
immediate hard deadline. Use filesystem quotas and external process limits
when hard limits are required.

## Unsupported inputs

Virtual/shadow tables, UTF-16 databases, inaccessible hidden rowids, custom
SQLite functions/collations/modules, corrupt data and foreign key violations
fail explicitly when encountered. An empty database is supported.
Views and triggers retain SQL without executing future application paths;
retained definitions do not prove all future queries have their dependencies.
