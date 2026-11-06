use rusqlite::Connection;
use sqlite_stream::{Limits, schema};

#[test]
fn arbitrary_identifiers_generated_columns_and_rowid_keys() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch(
        r#"
        CREATE TABLE "a""b" (rowid TEXT, "_rowid_" TEXT, v BLOB, g TEXT AS (rowid || '!'));
        CREATE TABLE keyed(a TEXT, b INTEGER, PRIMARY KEY(a,b)) WITHOUT ROWID, STRICT;
        CREATE TABLE seq(id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT);
        CREATE INDEX idx ON seq(v);
        CREATE VIEW vw AS SELECT v FROM seq;
        CREATE TRIGGER tr AFTER INSERT ON seq BEGIN UPDATE seq SET v=v WHERE id=new.id; END;
        BEGIN;
    "#,
    )
    .unwrap();
    let catalog = schema::discover(&db, Limits::default()).unwrap();
    let quoted = catalog.tables.iter().find(|t| t.name == "a\"b").unwrap();
    assert_eq!(quoted.columns, ["oid", "rowid", "_rowid_", "v"]);
    assert_eq!(quoted.order, ["oid"]);
    let keyed = catalog.tables.iter().find(|t| t.name == "keyed").unwrap();
    assert_eq!(keyed.columns, ["a", "b"]);
    assert_eq!(keyed.order, ["a", "b"]);
    assert!(keyed.without_rowid);
    assert_eq!(catalog.tables.last().unwrap().name, "sqlite_sequence");
    assert_eq!(catalog.objects.len(), 6);
}

#[test]
fn unsupported_virtual_tables_fail_instead_of_skipping_data() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch("CREATE VIRTUAL TABLE search USING fts5(body); BEGIN;")
        .unwrap();
    assert!(
        schema::discover(&db, Limits::default())
            .unwrap_err()
            .to_string()
            .contains("unsupported")
    );
}

#[test]
fn shadowed_rowids_and_metadata_overflow_are_explicit_errors() {
    let db = Connection::open_in_memory().unwrap();
    db.execute_batch("CREATE TABLE x(rowid,oid,_rowid_); BEGIN;")
        .unwrap();
    assert!(
        schema::discover(&db, Limits::default())
            .unwrap_err()
            .to_string()
            .contains("shadowed")
    );
    let db = Connection::open_in_memory().unwrap();
    let ddl = format!("CREATE TABLE x({} TEXT); BEGIN;", "a".repeat(1024));
    db.execute_batch(&ddl).unwrap();
    assert!(
        schema::discover(
            &db,
            Limits {
                schema_bytes: 1024,
                ..Limits::default()
            }
        )
        .is_err()
    );
}
