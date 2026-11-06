use anyhow::Result;
use clap::{Parser, Subcommand};
use rusqlite::{Connection, OpenFlags};
use std::path::PathBuf;

use sqlite_stream::{Limits, schema};

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
    }
    Ok(())
}
