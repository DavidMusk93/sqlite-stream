use rusqlite::Connection;
use sqlite_stream::{Limits, backup, format::Encoder, restore, schema};

fn complex_source() -> Connection {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(
        r#"
        PRAGMA foreign_keys=OFF; PRAGMA user_version=73; PRAGMA application_id=-27;
        CREATE TABLE "a""z" (id INTEGER PRIMARY KEY AUTOINCREMENT, v, g TEXT AS (hex(v)) STORED);
        CREATE TABLE parent(a TEXT COLLATE NOCASE, b INTEGER, PRIMARY KEY(a,b)) WITHOUT ROWID, STRICT;
        CREATE TABLE child(p TEXT, n INTEGER, FOREIGN KEY(p,n) REFERENCES parent(a,b));
        CREATE TABLE cycle_a(id INTEGER PRIMARY KEY, b REFERENCES cycle_b(id));
        CREATE TABLE cycle_b(id INTEGER PRIMARY KEY, a REFERENCES cycle_a(id));
        INSERT INTO "a""z"(id,v) VALUES(-4,NULL),(9,x'00ff'),(12,CAST(x'61ff00' AS TEXT)),(17,-1.5),(99,'gone');
        DELETE FROM "a""z" WHERE id=99;
        INSERT INTO parent VALUES('B',2),('a',1);
        INSERT INTO child(rowid,p,n) VALUES(-9,'A',1);
        INSERT INTO cycle_a VALUES(1,1); INSERT INTO cycle_b VALUES(1,1);
        CREATE INDEX ix ON "a""z"(v) WHERE v IS NOT NULL;
        CREATE VIEW vw AS SELECT v FROM "a""z";
        CREATE TRIGGER tr AFTER INSERT ON child BEGIN UPDATE child SET n=n WHERE rowid=new.rowid; END;
        "#,
    ).unwrap();
    db
}

#[test]
fn full_schema_raw_types_keys_sequences_and_cycles_round_trip() {
    let dir = tempfile::tempdir().unwrap();
    let mut source = complex_source();
    let mut bytes = vec![];
    let original = backup::backup(&mut source, &mut bytes, Limits::default()).unwrap();
    assert_eq!(
        restore::verify(bytes.as_slice(), dir.path(), Limits::default()).unwrap(),
        original
    );
    let path = dir.path().join("restored.db");
    assert_eq!(
        restore::restore(bytes.as_slice(), &path, Limits::default()).unwrap(),
        original
    );
    let db = Connection::open(path).unwrap();
    assert_eq!(
        db.query_row("SELECT seq FROM sqlite_sequence", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        99
    );
    assert_eq!(
        db.query_row(
            "SELECT typeof(v)||':'||hex(v) FROM \"a\"\"z\" WHERE id=12",
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        "text:61FF00"
    );
    assert_eq!(
        db.query_row("SELECT rowid FROM child", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        -9
    );
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
}

#[test]
fn corrupt_truncated_and_trailing_archives_never_publish() {
    let dir = tempfile::tempdir().unwrap();
    let mut bytes = vec![];
    backup::backup(&mut complex_source(), &mut bytes, Limits::default()).unwrap();
    let path = dir.path().join("out.db");
    for end in 0..bytes.len() {
        assert!(
            restore::restore(&bytes[..end], &path, Limits::default()).is_err(),
            "truncation {end}"
        );
        assert!(!path.exists());
    }
    let mut corrupt = bytes.clone();
    let index = corrupt.len() / 2;
    corrupt[index] ^= 128;
    assert!(restore::restore(corrupt.as_slice(), &path, Limits::default()).is_err());
    bytes.extend(zstd::stream::encode_all(&b""[..], 3).unwrap());
    assert!(restore::restore(bytes.as_slice(), &path, Limits::default()).is_err());
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
}

#[test]
fn existing_destination_and_malicious_sql_are_rejected() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("keep.db");
    std::fs::write(&path, b"keep").unwrap();
    assert!(restore::restore(&b""[..], &path, Limits::default()).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"keep");
    let path = dir.path().join("output.db");
    let escaped = dir.path().join("escape.db");
    for sql in [
        format!("ATTACH '{}' AS escaped", escaped.display()),
        "PRAGMA writable_schema=ON".to_owned(),
        "CREATE TABLE x(v); CREATE TABLE extra(v)".to_owned(),
        "CREATE TABLE x AS SELECT randomblob(1000000) AS v".to_owned(),
        "CREATE VIRTUAL TABLE x USING fts5(v)".to_owned(),
    ] {
        let mut catalog =
            schema::discover(&Connection::open_in_memory().unwrap(), Limits::default()).unwrap();
        catalog.objects.push(schema::Object {
            kind: "table".into(),
            name: "x".into(),
            sql,
        });
        let encoder = Encoder::new(vec![], &catalog, Limits::default()).unwrap();
        let raw = encoder.finish().unwrap().0;
        let bytes = zstd::stream::encode_all(raw.as_slice(), 3).unwrap();
        assert!(restore::restore(bytes.as_slice(), &path, Limits::default()).is_err());
        assert!(!path.exists());
        assert!(!escaped.exists());
    }
}
