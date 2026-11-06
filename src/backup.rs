use std::io::Write;

use anyhow::{Context, Result, ensure};
use rusqlite::{Connection, TransactionBehavior};

use crate::{Limits, format::Encoder, schema};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Report {
    pub digest: [u8; 32],
    pub rows: u64,
    pub tables: usize,
}

pub fn check_database(conn: &Connection) -> Result<()> {
    let mut check = conn.prepare("PRAGMA integrity_check")?;
    let mut rows = check.query([])?;
    let mut ok = false;
    while let Some(row) = rows.next()? {
        let result: String = row.get(0)?;
        ensure!(result == "ok", "SQLite integrity check failed: {result}");
        ok = true;
    }
    ensure!(ok, "SQLite integrity check returned no result");
    let mut check = conn.prepare("PRAGMA foreign_key_check")?;
    ensure!(
        check.query([])?.next()?.is_none(),
        "SQLite foreign key check failed"
    );
    Ok(())
}

/// Encodes borrowed SQLite values without collecting table rows or JSON byte arrays.
pub fn scan<W: Write>(
    conn: &Connection,
    catalog: &schema::Catalog,
    writer: W,
    limits: Limits,
) -> Result<(W, Report)> {
    let mut encoder = Encoder::new(writer, catalog, limits)?;
    for table in &catalog.tables {
        let mut statement = conn.prepare(&table.select_sql())?;
        let mut rows = statement.query([])?;
        while let Some(row) = rows.next()? {
            let values = (0..table.columns.len())
                .map(|column| row.get_ref(column))
                .collect::<rusqlite::Result<Vec<_>>>()?;
            encoder
                .row(&values)
                .with_context(|| format!("encoding table {:?}", table.name))?;
        }
        encoder.end_table()?;
    }
    let (writer, digest, rows) = encoder.finish()?;
    Ok((
        writer,
        Report {
            digest,
            rows,
            tables: catalog.tables.len(),
        },
    ))
}

/// Discovery, integrity checks and data traversal observe one SQLite read snapshot.
/// An error invalidates all bytes written so far; callers must stage file outputs.
pub fn backup<W: Write>(conn: &mut Connection, writer: W, limits: Limits) -> Result<Report> {
    schema::configure(conn, limits)?;
    conn.execute_batch("PRAGMA trusted_schema=OFF;")?;
    let transaction = conn.transaction_with_behavior(TransactionBehavior::Deferred)?;
    let catalog = schema::discover(&transaction, limits)?;
    check_database(&transaction)?;
    let mut compressed = zstd::stream::write::Encoder::new(writer, 3)?;
    compressed.window_log(23)?;
    compressed.include_checksum(true)?;
    let (compressed, report) = scan(&transaction, &catalog, compressed, limits)?;
    compressed.finish()?.flush()?;
    transaction.commit()?;
    Ok(report)
}
