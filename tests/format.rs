use rusqlite::types::ValueRef;
use sqlite_stream::{
    Limits,
    format::{Cell, Decoder, Encoder},
    schema::Catalog,
};

fn archive() -> Vec<u8> {
    let catalog = Catalog {
        user_version: 3,
        application_id: 5,
        objects: vec![],
        tables: vec![],
    };
    let mut writer = Encoder::new(Vec::new(), &catalog, Limits::default()).unwrap();
    writer
        .row(&[
            ValueRef::Null,
            ValueRef::Integer(i64::MIN),
            ValueRef::Real(-1.25),
            ValueRef::Text(b"a\0\xff"),
            ValueRef::Blob(b"\0\xff"),
            ValueRef::Text(b""),
            ValueRef::Blob(b""),
        ])
        .unwrap();
    writer.end_table().unwrap();
    writer.finish().unwrap().0
}

#[test]
fn raw_text_and_blob_types_round_trip_without_json_expansion() {
    let bytes = archive();
    let (mut reader, catalog) = Decoder::new(bytes.as_slice(), Limits::default()).unwrap();
    assert_eq!(catalog.user_version, 3);
    assert_eq!(
        reader.row(7).unwrap().unwrap(),
        [
            Cell::Null,
            Cell::Integer(i64::MIN),
            Cell::Real(-1.25),
            Cell::Text(b"a\0\xff".to_vec()),
            Cell::Blob(b"\0\xff".to_vec()),
            Cell::Text(vec![]),
            Cell::Blob(vec![]),
        ]
    );
    assert!(reader.row(7).unwrap().is_none());
    assert_eq!(reader.finish().unwrap().1, 1);
}

#[test]
fn every_truncation_and_corrupt_digest_fails() {
    let bytes = archive();
    let check = |bytes: &[u8]| -> anyhow::Result<()> {
        let (mut reader, _) = Decoder::new(bytes, Limits::default())?;
        while reader.row(7)?.is_some() {}
        reader.finish()?;
        Ok(())
    };
    for end in 0..bytes.len() {
        assert!(check(&bytes[..end]).is_err(), "truncation {end}");
    }
    let mut corrupt = bytes.clone();
    *corrupt.last_mut().unwrap() ^= 1;
    assert!(check(&corrupt).is_err());
    let mut trailing = bytes;
    trailing.push(0);
    assert!(check(&trailing).is_err());
}

#[test]
fn row_and_schema_lengths_are_bounded_before_allocating() {
    let catalog = Catalog {
        user_version: 0,
        application_id: 0,
        objects: vec![],
        tables: vec![],
    };
    let limits = Limits {
        row_bytes: 3,
        ..Limits::default()
    };
    let mut writer = Encoder::new(Vec::new(), &catalog, limits).unwrap();
    assert!(writer.row(&[ValueRef::Blob(&[0; 4])]).is_err());
    let bytes = archive();
    let (mut reader, _) = Decoder::new(bytes.as_slice(), limits).unwrap();
    assert!(reader.row(7).is_err());
    assert!(
        Decoder::new(
            bytes.as_slice(),
            Limits {
                schema_bytes: 1,
                ..Limits::default()
            }
        )
        .is_err()
    );
}
