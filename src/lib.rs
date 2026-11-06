pub mod backup;
pub mod format;
pub mod restore;
pub mod schema;

/// Limits apply to SQLite records and uncompressed archive metadata, not database size.
#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub row_bytes: usize,
    pub schema_bytes: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            row_bytes: 8 * 1024 * 1024,
            schema_bytes: 4 * 1024 * 1024,
        }
    }
}
