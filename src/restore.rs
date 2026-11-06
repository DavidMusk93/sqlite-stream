use std::{
    fs::File,
    io::{self, BufRead, BufReader, Read},
    path::Path,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};

use anyhow::{Context, Result, ensure};
use rusqlite::{
    Connection,
    hooks::{AuthAction, AuthContext, Authorization},
    params_from_iter,
};
use tempfile::NamedTempFile;

use crate::{
    Limits,
    backup::{self, Report},
    format::Decoder,
    schema,
};

/// Archive SQL is limited to the declared CREATE object. No transaction, PRAGMA,
/// ATTACH, temporary object, DML, extension or virtual-table action is authorized.
fn create_object(conn: &mut Connection, object: &schema::Object) -> Result<()> {
    let expected = object.clone();
    let created = Arc::new(AtomicBool::new(false));
    let observed = created.clone();
    conn.authorizer(Some(move |context: AuthContext<'_>| {
        if context.database_name.is_some_and(|name| name != "main") {
            return Authorization::Deny;
        }
        let matches = match context.action {
            AuthAction::CreateTable { table_name } => {
                expected.kind == "table" && table_name == expected.name
            }
            AuthAction::CreateIndex { index_name, .. } => {
                expected.kind == "index" && index_name == expected.name
            }
            AuthAction::CreateView { view_name } => {
                expected.kind == "view" && view_name == expected.name
            }
            AuthAction::CreateTrigger { trigger_name, .. } => {
                expected.kind == "trigger" && trigger_name == expected.name
            }
            _ => false,
        };
        if matches {
            observed.store(true, Ordering::Relaxed);
            return Authorization::Allow;
        }
        let allowed = match context.action {
            AuthAction::Reindex { index_name } => {
                expected.kind == "index" && index_name == expected.name
            }
            AuthAction::CreateIndex {
                index_name,
                table_name,
            } => {
                expected.kind == "table"
                    && table_name == expected.name
                    && index_name.starts_with("sqlite_autoindex_")
            }
            AuthAction::CreateTable {
                table_name: "sqlite_sequence",
            } => expected.kind == "table",
            AuthAction::Insert { table_name } | AuthAction::Update { table_name, .. } => {
                matches!(table_name, "sqlite_master" | "sqlite_schema")
            }
            AuthAction::Read { .. } | AuthAction::Select => true,
            AuthAction::Function { function_name } => !["load_extension", "readfile", "writefile"]
                .iter()
                .any(|name| function_name.eq_ignore_ascii_case(name)),
            _ => false,
        };
        if allowed {
            Authorization::Allow
        } else {
            Authorization::Deny
        }
    }))?;
    let result = conn.execute(&object.sql, []);
    let clear = conn.authorizer(None::<fn(AuthContext<'_>) -> Authorization>);
    result.with_context(|| format!("creating {} {:?}", object.kind, object.name))?;
    clear?;
    ensure!(
        created.load(Ordering::Relaxed),
        "SQL did not create its declared object"
    );
    Ok(())
}

fn load<R: Read>(reader: R, stage: &NamedTempFile, limits: Limits) -> Result<Report> {
    let mut compressed =
        zstd::stream::read::Decoder::with_buffer(BufReader::new(reader))?.single_frame();
    compressed.window_log_max(23)?;
    let (mut decoder, catalog) = Decoder::new(compressed, limits)?;
    catalog.validate(limits)?;
    let mut conn = Connection::open(stage.path())?;
    schema::configure(&conn, limits)?;
    conn.execute_batch(
        "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL;
         PRAGMA foreign_keys=OFF; PRAGMA trusted_schema=OFF; BEGIN IMMEDIATE;",
    )?;
    for object in catalog.objects.iter().filter(|o| o.kind == "table") {
        create_object(&mut conn, object)?;
    }
    let actual = schema::discover(&conn, limits)?;
    ensure!(
        actual.tables == catalog.tables,
        "archive table metadata does not match DDL"
    );
    for table in &catalog.tables {
        if table.name == "sqlite_sequence" {
            conn.execute("DELETE FROM sqlite_sequence", [])?;
        }
        let mut insert = conn.prepare(&table.insert_sql())?;
        while let Some(cells) = decoder.row(table.columns.len())? {
            insert
                .execute(params_from_iter(&cells))
                .with_context(|| format!("loading table {:?}", table.name))?;
        }
    }
    let (compressed, digest, rows) = decoder.finish_with_reader()?;
    let mut trailing = compressed.finish();
    ensure!(trailing.fill_buf()?.is_empty(), "trailing compressed data");
    for object in catalog.objects.iter().filter(|o| o.kind != "table") {
        create_object(&mut conn, object)?;
    }
    conn.execute_batch(&format!(
        "PRAGMA user_version={}; PRAGMA application_id={};",
        catalog.user_version, catalog.application_id,
    ))?;
    backup::check_database(&conn)?;
    let restored_catalog = schema::discover(&conn, limits)?;
    ensure!(
        restored_catalog == catalog,
        "restored schema does not match archive"
    );
    let (_, report) = backup::scan(&conn, &restored_catalog, io::sink(), limits)?;
    ensure!(
        report.digest == digest && report.rows == rows,
        "restored content does not match archive"
    );
    conn.execute_batch("COMMIT")?;
    conn.close().map_err(|(_, error)| error)?;
    stage.as_file().sync_all()?;
    Ok(report)
}

pub fn parent(path: &Path) -> &Path {
    path.parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."))
}

/// Loads and verifies in a private sibling file, then atomically publishes without
/// replacing anything at the destination. Failure before publication drops staging.
pub fn restore<R: Read>(reader: R, destination: &Path, limits: Limits) -> Result<Report> {
    ensure!(!destination.try_exists()?, "destination already exists");
    let stage = NamedTempFile::new_in(parent(destination))?;
    let report = load(reader, &stage, limits)?;
    stage.persist_noclobber(destination)?;
    File::open(parent(destination))?.sync_all()?;
    Ok(report)
}

/// Verification includes a complete scratch restore, integrity, foreign keys and
/// a second canonical scan; a checksum by itself does not prove restore fidelity.
pub fn verify<R: Read>(reader: R, scratch: &Path, limits: Limits) -> Result<Report> {
    let stage = NamedTempFile::new_in(scratch)?;
    load(reader, &stage, limits)
}
