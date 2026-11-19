//! Helpers for tests outside this directory that need what only the storage
//! may do: touch the database file directly (`sqlx` stays inside
//! `src/storage/`).

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use sqlx::{ConnectOptions, Connection};

use super::database::Layout;

/// A unique directory under the system temporary directory, removed on drop:
/// the application's local data directory of one test.
pub struct TempDataDir(PathBuf);

impl TempDataDir {
    pub fn new(tag: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "atlas storage support {tag}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("create the temporary data directory");
        Self(path)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDataDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

async fn connect(root: &Path) -> SqliteConnection {
    SqliteConnectOptions::new()
        .filename(&Layout::new(root.to_path_buf()).database)
        .connect()
        .await
        .expect("a plain connection to the database")
}

/// Stores a module configuration row as an outside edit could, with the checks
/// of the schema switched off for that one connection. The database must have
/// been opened and migrated once.
pub async fn plant_module_config_row(root: &Path, id: &str, enabled: i64, settings: &str) {
    let mut conn = connect(root).await;
    sqlx::query("PRAGMA ignore_check_constraints = ON")
        .execute(&mut conn)
        .await
        .expect("checks off");
    sqlx::query(
        "INSERT INTO module_config (module_id, enabled, settings) VALUES (?1, ?2, ?3) \
         ON CONFLICT (module_id) DO UPDATE SET enabled = excluded.enabled, \
         settings = excluded.settings",
    )
    .bind(id)
    .bind(enabled)
    .bind(settings)
    .execute(&mut conn)
    .await
    .expect("plant a row");
    conn.close().await.expect("close");
}

/// Every module configuration row, ordered by module.
pub async fn module_config_rows(root: &Path) -> Vec<(String, i64, String)> {
    let mut conn = connect(root).await;
    let rows =
        sqlx::query_as("SELECT module_id, enabled, settings FROM module_config ORDER BY module_id")
            .fetch_all(&mut conn)
            .await
            .expect("module rows");
    conn.close().await.expect("close");
    rows
}

/// The bytes of the database file.
pub fn database_bytes(root: &Path) -> Vec<u8> {
    fs::read(Layout::new(root.to_path_buf()).database).expect("the database file")
}

/// Leaves a marker without a database: the next opening is unavailable and
/// creates nothing.
pub fn lose_the_database(root: &Path) {
    let layout = Layout::new(root.to_path_buf());
    fs::write(&layout.marker, b"").expect("marker");
}
