use anyhow::{Context, Result, bail, ensure};
use rusqlite::{Connection, limits::Limit};
use serde::{Deserialize, Serialize};

use crate::Limits;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Object {
    pub kind: String,
    pub name: String,
    pub sql: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Table {
    pub name: String,
    /// Includes a separately preserved rowid when it is accessible.
    pub columns: Vec<String>,
    pub order: Vec<String>,
    pub without_rowid: bool,
}

impl Table {
    pub fn select_sql(&self) -> String {
        format!(
            "SELECT {} FROM {} ORDER BY {}",
            self.columns
                .iter()
                .map(|s| quote(s))
                .collect::<Vec<_>>()
                .join(","),
            quote(&self.name),
            self.order
                .iter()
                .map(|s| quote(s))
                .collect::<Vec<_>>()
                .join(","),
        )
    }

    pub fn insert_sql(&self) -> String {
        format!(
            "INSERT INTO {} ({}) VALUES ({})",
            quote(&self.name),
            self.columns
                .iter()
                .map(|s| quote(s))
                .collect::<Vec<_>>()
                .join(","),
            vec!["?"; self.columns.len()].join(","),
        )
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Catalog {
    pub user_version: i64,
    pub application_id: i64,
    pub objects: Vec<Object>,
    pub tables: Vec<Table>,
}

pub fn quote(name: &str) -> String {
    format!("\"{}\"", name.replace('"', "\"\""))
}

pub fn configure(conn: &Connection, limits: Limits) -> Result<()> {
    ensure!(
        (1024..=i32::MAX as usize).contains(&limits.row_bytes),
        "invalid row budget"
    );
    ensure!(
        (1024..=16 * 1024 * 1024).contains(&limits.schema_bytes),
        "invalid schema budget"
    );
    conn.set_limit(Limit::SQLITE_LIMIT_LENGTH, limits.row_bytes as i32)?;
    conn.set_limit(Limit::SQLITE_LIMIT_SQL_LENGTH, limits.schema_bytes as i32)?;
    conn.execute_batch("PRAGMA mmap_size=0; PRAGMA cache_size=-2048; PRAGMA temp_store=FILE;")?;
    Ok(())
}

/// Must run inside the caller's read transaction so DDL and rows share a snapshot.
pub fn discover(conn: &Connection, limits: Limits) -> Result<Catalog> {
    let encoding: String = conn.query_row("PRAGMA encoding", [], |row| row.get(0))?;
    ensure!(
        encoding == "UTF-8",
        "format v1 supports UTF-8 databases; found {encoding}"
    );
    let mut bytes = 0usize;
    let mut objects = Vec::new();
    let mut statement = conn.prepare(
        "SELECT type,name,sql FROM sqlite_schema WHERE sql IS NOT NULL
         AND substr(name,1,7) <> 'sqlite_' ORDER BY type,name COLLATE BINARY",
    )?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        let object = Object {
            kind: row.get(0)?,
            name: row.get(1)?,
            sql: row.get(2)?,
        };
        ensure!(
            matches!(object.kind.as_str(), "table" | "index" | "view" | "trigger"),
            "unknown schema object"
        );
        charge(
            &mut bytes,
            object.name.len() + object.sql.len() + 128,
            limits,
        )?;
        ensure!(objects.len() < 10_000, "too many schema objects");
        objects.push(object);
    }
    let mut tables = Vec::new();
    let mut statement = conn.prepare(
        "SELECT name,type,wr FROM pragma_table_list
         WHERE schema='main' ORDER BY name COLLATE BINARY",
    )?;
    let mut rows = statement.query([])?;
    while let Some(row) = rows.next()? {
        let name: String = row.get(0)?;
        let kind: String = row.get(1)?;
        if matches!(kind.as_str(), "virtual" | "shadow") {
            bail!("unsupported {kind} table {name:?}; no tables will be silently omitted");
        }
        if kind == "view" {
            continue; // Definition is already in objects; views have no independent rows.
        }
        if name.starts_with("sqlite_") && name != "sqlite_sequence" {
            continue; // Internal schema/statistics are recreated by SQLite, not user data.
        }
        ensure!(kind == "table", "unknown table kind {kind}");
        let without_rowid: bool = row.get(2)?;
        let mut columns = Vec::new();
        let mut primary = Vec::new();
        let mut names = Vec::new();
        let mut xinfo =
            conn.prepare("SELECT name,pk,hidden FROM pragma_table_xinfo(?) ORDER BY cid")?;
        let mut info = xinfo.query([&name])?;
        while let Some(column) = info.next()? {
            let column_name: String = column.get(0)?;
            charge(&mut bytes, column_name.len() * 3 + 64, limits)?;
            let pk: i64 = column.get(1)?;
            let hidden: i64 = column.get(2)?;
            names.push(column_name.clone());
            if hidden == 0 {
                if pk > 0 {
                    primary.push((pk, column_name.clone()));
                }
                columns.push(column_name);
            }
        }
        ensure!(
            !columns.is_empty() && columns.len() <= 2000,
            "unsupported column count in {name:?}"
        );
        let order = if without_rowid {
            primary.sort_by_key(|(position, _)| *position);
            ensure!(!primary.is_empty(), "missing primary key in {name:?}");
            primary.into_iter().map(|(_, name)| name).collect()
        } else {
            let alias = ["rowid", "_rowid_", "oid"].into_iter().find(|candidate| {
                !names
                    .iter()
                    .any(|name| name.eq_ignore_ascii_case(candidate))
            });
            let Some(alias) = alias else {
                bail!(
                    "all rowid aliases are shadowed in {name:?}; lossless rowid access is unavailable"
                );
            };
            columns.insert(0, alias.to_owned());
            vec![alias.to_owned()]
        };
        charge(&mut bytes, name.len() + 128, limits)?;
        let table = Table {
            name,
            columns,
            order,
            without_rowid,
        };
        conn.prepare(&table.select_sql())
            .with_context(|| format!("cannot read table {:?}", table.name))?;
        tables.push(table);
        ensure!(tables.len() <= 10_000, "too many tables");
    }
    // AUTOINCREMENT inserts mutate sqlite_sequence. Restore its original rows last.
    tables.sort_by(|a, b| {
        (a.name == "sqlite_sequence")
            .cmp(&(b.name == "sqlite_sequence"))
            .then_with(|| a.name.cmp(&b.name))
    });
    Ok(Catalog {
        user_version: conn.query_row("PRAGMA user_version", [], |r| r.get(0))?,
        application_id: conn.query_row("PRAGMA application_id", [], |r| r.get(0))?,
        objects,
        tables,
    })
}

fn charge(bytes: &mut usize, amount: usize, limits: Limits) -> Result<()> {
    *bytes = bytes
        .checked_add(amount)
        .context("schema budget overflow")?;
    ensure!(
        *bytes <= limits.schema_bytes,
        "schema exceeds {} byte budget",
        limits.schema_bytes
    );
    Ok(())
}
