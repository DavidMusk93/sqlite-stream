use anyhow::Result;
use clap::{Parser, Subcommand};
use rusqlite::{Connection, OpenFlags};
use std::{io, path::PathBuf};

use sqlite_stream::{Limits, backup, schema};

#[derive(Parser)]
#[command(version, about = "Schema-aware SQLite backup and restore streams")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Discover supported tables and objects from one consistent read snapshot.
    Inspect { database: PathBuf },
    /// Stream a consistent logical snapshot; use '-' to write the archive to stdout.
    Backup { database: PathBuf, output: PathBuf },
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Inspect { database } => {
            let conn = Connection::open_with_flags(database, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            schema::configure(&conn, Limits::default())?;
            conn.execute_batch("BEGIN")?;
            let catalog = schema::discover(&conn, Limits::default())?;
            println!("{}", serde_json::to_string_pretty(&catalog)?);
        }
        Command::Backup { database, output } => {
            let mut conn = Connection::open_with_flags(database, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            let report = if output.as_os_str() == "-" {
                backup::backup(&mut conn, io::stdout().lock(), Limits::default())?
            } else {
                let parent = output
                    .parent()
                    .filter(|p| !p.as_os_str().is_empty())
                    .unwrap_or_else(|| std::path::Path::new("."));
                let mut stage = tempfile::NamedTempFile::new_in(parent)?;
                let report = backup::backup(&mut conn, stage.as_file_mut(), Limits::default())?;
                stage.as_file().sync_all()?;
                stage.persist_noclobber(&output)?;
                std::fs::File::open(parent)?.sync_all()?;
                report
            };
            eprintln!("backed up {} rows in {} tables", report.rows, report.tables);
        }
    }
    Ok(())
}
