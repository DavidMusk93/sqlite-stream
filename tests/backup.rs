use std::io::{self, Write};

use rusqlite::{Connection, OpenFlags};
use sqlite_stream::{
    Limits, backup,
    format::{Cell, Decoder},
};

#[test]
fn concurrent_schema_and_rows_do_not_split_the_snapshot() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("live.db");
    let writer = Connection::open(&path).unwrap();
    writer
        .execute_batch(
            "PRAGMA journal_mode=WAL; CREATE TABLE data(v);
             INSERT INTO data VALUES (x'00ff'),('old');",
        )
        .unwrap();
    struct Sink {
        database: Connection,
        bytes: Vec<u8>,
        changed: bool,
    }
    impl Write for Sink {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            if !self.changed {
                self.database
                    .execute_batch(
                        "ALTER TABLE data ADD COLUMN extra;
                         UPDATE data SET v='new'; CREATE TABLE later(x);",
                    )
                    .unwrap();
                self.changed = true;
            }
            self.bytes.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let mut sink = Sink {
        database: writer,
        bytes: vec![],
        changed: false,
    };
    let mut reader = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let report = backup::backup(&mut reader, &mut sink, Limits::default()).unwrap();
    assert!(sink.changed);
    let raw = zstd::stream::decode_all(sink.bytes.as_slice()).unwrap();
    let (mut stream, catalog) = Decoder::new(raw.as_slice(), Limits::default()).unwrap();
    assert_eq!(catalog.tables.len(), 1);
    assert_eq!(catalog.tables[0].columns, ["rowid", "v"]);
    assert_eq!(
        stream.row(2).unwrap().unwrap(),
        [Cell::Integer(1), Cell::Blob(vec![0, 255])]
    );
    assert_eq!(
        stream.row(2).unwrap().unwrap(),
        [Cell::Integer(2), Cell::Text(b"old".to_vec())]
    );
    assert!(stream.row(2).unwrap().is_none());
    assert_eq!(stream.finish().unwrap(), (report.digest, 2));
}

#[test]
fn source_errors_are_checked_before_output_and_sink_errors_propagate() {
    let mut db = Connection::open_in_memory().unwrap();
    db.execute_batch("CREATE VIRTUAL TABLE v USING fts5(text)")
        .unwrap();
    let mut output = vec![];
    assert!(backup::backup(&mut db, &mut output, Limits::default()).is_err());
    assert!(output.is_empty());
    let mut db = Connection::open_in_memory().unwrap();
    db.execute_batch("CREATE TABLE x(v); INSERT INTO x VALUES(zeroblob(4096));")
        .unwrap();
    assert!(
        backup::backup(
            &mut db,
            &mut output,
            Limits {
                row_bytes: 1024,
                ..Limits::default()
            }
        )
        .is_err()
    );
    struct Broken;
    impl Write for Broken {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::Error::from_raw_os_error(28))
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    assert!(backup::backup(&mut db, Broken, Limits::default()).is_err());
    assert!(db.is_autocommit());
}
