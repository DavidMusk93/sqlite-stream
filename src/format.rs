use std::io::{Read, Write};

use anyhow::{Context, Result, bail, ensure};
use rusqlite::types::{ToSql, ToSqlOutput, ValueRef};
use sha2::{Digest, Sha256};

use crate::{Limits, schema::Catalog};

const MAGIC: &[u8; 8] = b"SQLSTRM1";
const END: &[u8; 8] = b"ENDSTRM1";

#[derive(Debug, PartialEq)]
pub enum Cell {
    Null,
    Integer(i64),
    Real(f64),
    Text(Vec<u8>),
    Blob(Vec<u8>),
}

impl ToSql for Cell {
    fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
        Ok(ToSqlOutput::Borrowed(match self {
            Self::Null => ValueRef::Null,
            Self::Integer(v) => ValueRef::Integer(*v),
            Self::Real(v) => ValueRef::Real(*v),
            Self::Text(v) => ValueRef::Text(v),
            Self::Blob(v) => ValueRef::Blob(v),
        }))
    }
}

pub struct Encoder<W> {
    writer: W,
    hash: Sha256,
    limits: Limits,
    table_rows: u64,
    total_rows: u64,
}

impl<W: Write> Encoder<W> {
    pub fn new(writer: W, catalog: &Catalog, limits: Limits) -> Result<Self> {
        let mut encoder = Self {
            writer,
            hash: Sha256::new(),
            limits,
            table_rows: 0,
            total_rows: 0,
        };
        let schema = serde_json::to_vec(catalog)?;
        ensure!(
            schema.len() <= limits.schema_bytes,
            "encoded schema exceeds budget"
        );
        encoder.bytes(MAGIC)?;
        encoder.bytes(&(schema.len() as u32).to_le_bytes())?;
        encoder.bytes(&schema)?;
        Ok(encoder)
    }

    fn bytes(&mut self, bytes: &[u8]) -> Result<()> {
        self.writer.write_all(bytes)?;
        self.hash.update(bytes);
        Ok(())
    }

    pub fn row(&mut self, cells: &[ValueRef<'_>]) -> Result<()> {
        let size: usize = cells
            .iter()
            .map(|cell| match cell {
                ValueRef::Null => 1,
                ValueRef::Integer(_) | ValueRef::Real(_) => 9,
                ValueRef::Text(v) | ValueRef::Blob(v) => 5 + v.len(),
            })
            .sum();
        ensure!(
            size <= self.limits.row_bytes,
            "row exceeds {} byte budget",
            self.limits.row_bytes
        );
        self.bytes(&[1])?;
        for cell in cells {
            match cell {
                ValueRef::Null => self.bytes(&[0])?,
                ValueRef::Integer(v) => {
                    self.bytes(&[1])?;
                    self.bytes(&v.to_le_bytes())?;
                }
                ValueRef::Real(v) => {
                    self.bytes(&[2])?;
                    self.bytes(&v.to_bits().to_le_bytes())?;
                }
                ValueRef::Text(v) | ValueRef::Blob(v) => {
                    self.bytes(&[if matches!(cell, ValueRef::Text(_)) {
                        3
                    } else {
                        4
                    }])?;
                    self.bytes(&(v.len() as u32).to_le_bytes())?;
                    self.bytes(v)?;
                }
            }
        }
        self.table_rows = self
            .table_rows
            .checked_add(1)
            .context("row count overflow")?;
        self.total_rows = self
            .total_rows
            .checked_add(1)
            .context("row count overflow")?;
        Ok(())
    }

    pub fn end_table(&mut self) -> Result<()> {
        self.bytes(&[0])?;
        self.bytes(&self.table_rows.to_le_bytes())?;
        self.table_rows = 0;
        Ok(())
    }

    pub fn finish(mut self) -> Result<(W, [u8; 32], u64)> {
        self.bytes(END)?;
        self.bytes(&self.total_rows.to_le_bytes())?;
        let digest: [u8; 32] = self.hash.finalize().into();
        self.writer.write_all(&digest)?;
        Ok((self.writer, digest, self.total_rows))
    }
}

pub struct Decoder<R> {
    reader: R,
    hash: Sha256,
    limits: Limits,
    table_rows: u64,
    total_rows: u64,
}

impl<R: Read> Decoder<R> {
    pub fn new(reader: R, limits: Limits) -> Result<(Self, Catalog)> {
        let mut decoder = Self {
            reader,
            hash: Sha256::new(),
            limits,
            table_rows: 0,
            total_rows: 0,
        };
        ensure!(
            &decoder.bytes::<8>()? == MAGIC,
            "unknown archive magic/version"
        );
        let length = u32::from_le_bytes(decoder.bytes()?) as usize;
        ensure!(
            length <= limits.schema_bytes,
            "archive schema exceeds budget"
        );
        let mut schema = vec![0; length];
        decoder.read_bytes(&mut schema)?;
        let catalog = serde_json::from_slice(&schema).context("invalid archive schema")?;
        Ok((decoder, catalog))
    }

    fn read_bytes(&mut self, bytes: &mut [u8]) -> Result<()> {
        self.reader
            .read_exact(bytes)
            .context("truncated or unreadable archive")?;
        self.hash.update(bytes);
        Ok(())
    }

    fn bytes<const N: usize>(&mut self) -> Result<[u8; N]> {
        let mut bytes = [0; N];
        self.read_bytes(&mut bytes)?;
        Ok(bytes)
    }

    /// Holds only this row. Every allocation is preceded by a cumulative row-budget check.
    pub fn row(&mut self, columns: usize) -> Result<Option<Vec<Cell>>> {
        match self.bytes::<1>()?[0] {
            0 => {
                let expected = u64::from_le_bytes(self.bytes()?);
                ensure!(expected == self.table_rows, "table row count mismatch");
                self.table_rows = 0;
                return Ok(None);
            }
            1 => {}
            tag => bail!("invalid row tag {tag}"),
        }
        ensure!(columns <= 2001, "archive column count exceeds budget");
        let mut cells = Vec::with_capacity(columns);
        let mut size = 0usize;
        for _ in 0..columns {
            let tag = self.bytes::<1>()?[0];
            size += 1;
            let cell = match tag {
                0 => Cell::Null,
                1 | 2 => {
                    size += 8;
                    ensure!(size <= self.limits.row_bytes, "archive row exceeds budget");
                    let bits = self.bytes()?;
                    if tag == 1 {
                        Cell::Integer(i64::from_le_bytes(bits))
                    } else {
                        Cell::Real(f64::from_bits(u64::from_le_bytes(bits)))
                    }
                }
                3 | 4 => {
                    let length = u32::from_le_bytes(self.bytes()?) as usize;
                    size = size
                        .checked_add(4 + length)
                        .context("row budget overflow")?;
                    ensure!(size <= self.limits.row_bytes, "archive row exceeds budget");
                    let mut bytes = vec![0; length];
                    self.read_bytes(&mut bytes)?;
                    if tag == 3 {
                        Cell::Text(bytes)
                    } else {
                        Cell::Blob(bytes)
                    }
                }
                _ => bail!("invalid cell tag {tag}"),
            };
            ensure!(size <= self.limits.row_bytes, "archive row exceeds budget");
            cells.push(cell);
        }
        self.table_rows = self
            .table_rows
            .checked_add(1)
            .context("row count overflow")?;
        self.total_rows = self
            .total_rows
            .checked_add(1)
            .context("row count overflow")?;
        Ok(Some(cells))
    }

    pub fn finish(mut self) -> Result<([u8; 32], u64)> {
        ensure!(&self.bytes::<8>()? == END, "missing complete footer");
        let expected = u64::from_le_bytes(self.bytes()?);
        ensure!(expected == self.total_rows, "total row count mismatch");
        let actual: [u8; 32] = self.hash.finalize().into();
        let mut digest = [0; 32];
        self.reader
            .read_exact(&mut digest)
            .context("truncated digest")?;
        ensure!(digest == actual, "archive SHA-256 mismatch");
        ensure!(self.reader.read(&mut [0])? == 0, "trailing archive data");
        Ok((actual, self.total_rows))
    }
}
