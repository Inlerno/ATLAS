//! The module configuration table (MM-5B, #21): the statements behind the
//! consumer operations of [`super::Storage`].
//!
//! Every operation is one transaction on the session's connection and checks
//! the journal mode inside it before it reads or writes anything (ADR-016,
//! measure 4: [`database::begin_on_rollback_journal`]). The transaction
//! starts as a plain `BEGIN` (`DEFERRED`) and reads first, so a write that
//! meets another connection's write transaction fails at once with
//! `SQLITE_BUSY` instead of waiting (decision O-13): nothing is retried.
//!
//! Plain types only: the storage knows nothing of the module manager. What a
//! row means — whether its content is usable — is decided by the caller.

// Stage A of #21: the module configuration adapter (stage B) is the caller.
#![cfg_attr(not(test), allow(dead_code))]

use std::fmt;

use sqlx::sqlite::SqliteConnection;
use thiserror::Error;

use super::database;

/// A row as the database holds it. The caller decides whether the content is
/// usable: the storage neither parses the settings nor checks the flag.
#[derive(Clone, PartialEq, Eq)]
pub struct StoredModuleConfig {
    /// The `enabled` column; the schema allows only 0 and 1.
    pub enabled: i64,
    /// The `settings` column: JSON text by the schema.
    pub settings: String,
}

/// Without the settings text: it may hold user data.
impl fmt::Debug for StoredModuleConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("StoredModuleConfig")
            .field("enabled", &self.enabled)
            .field("settings", &"<hidden>")
            .finish()
    }
}

/// What a conditional replacement did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplaceCheck {
    /// The row was judged unusable and has been replaced.
    Replaced,
    /// The row was usable or absent: nothing was written.
    NotDamaged,
}

/// Why a module configuration operation did not complete. Texts are for the
/// log only: they may contain local paths and SQLite messages, never stored
/// values.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum ConfigStoreError {
    /// The opening gave no result before the readiness deadline of the
    /// session; nothing is read or written for the rest of it.
    #[error("storage readiness deadline passed")]
    ReadinessExpired,
    /// The result of the opening was published but the storage is not open:
    /// it is never waited for twice.
    #[error("storage is not open")]
    NotOpen,
    #[error("storage unavailable")]
    Unavailable,
    /// The database is open but cannot be written.
    #[error("storage is read-only")]
    ReadOnly,
    #[error("storage closed")]
    Closed,
    /// A statement failed: step, SQLite code and message.
    #[error("{0}")]
    Database(String),
}

const SELECT: &str = "SELECT enabled, settings FROM module_config WHERE module_id = ?1";
const UPSERT: &str = "INSERT INTO module_config (module_id, enabled, settings) VALUES (?1, ?2, ?3) \
     ON CONFLICT (module_id) DO UPDATE SET enabled = excluded.enabled, settings = excluded.settings";

/// The row of `id`, or `None` if there is none. `None` comes only from a
/// query that completed, in a transaction that ended cleanly.
pub(super) async fn read(
    conn: &mut SqliteConnection,
    id: &str,
) -> Result<Option<StoredModuleConfig>, ConfigStoreError> {
    let mut transaction = begin(conn, "config-read").await?;
    let row = match select(&mut transaction, id, "config-read").await {
        Ok(row) => row,
        Err(error) => {
            let _ = transaction.rollback().await;
            return Err(error);
        }
    };
    // A read changes nothing; the transaction is ended so that the next one
    // starts clean.
    transaction
        .rollback()
        .await
        .map_err(|error| failed("config-read-end", &error))?;
    Ok(row)
}

/// Writes every entry or none. Entries are applied in order, so an id given
/// twice keeps its last entry; rows of other modules are left untouched.
pub(super) async fn write(
    conn: &mut SqliteConnection,
    entries: &[(&str, bool, &str)],
) -> Result<(), ConfigStoreError> {
    let mut transaction = begin(conn, "config-write").await?;
    for (id, enabled, settings) in entries {
        if let Err(error) = upsert(&mut transaction, id, *enabled, settings, "config-write").await {
            let _ = transaction.rollback().await;
            return Err(error);
        }
    }
    // A failed `COMMIT` leaves nothing written: the transaction is rolled
    // back when it is dropped.
    transaction
        .commit()
        .await
        .map_err(|error| failed("config-write-commit", &error))
}

/// Reads the row of `id` and, only if `is_damaged` says so, replaces it — in
/// one transaction, so nothing can change the row between the check and the
/// write.
pub(super) async fn replace_if(
    conn: &mut SqliteConnection,
    id: &str,
    enabled: bool,
    settings: &str,
    is_damaged: impl FnOnce(Option<&StoredModuleConfig>) -> bool,
) -> Result<ReplaceCheck, ConfigStoreError> {
    let mut transaction = begin(conn, "config-replace").await?;
    let row = match select(&mut transaction, id, "config-replace").await {
        Ok(row) => row,
        Err(error) => {
            let _ = transaction.rollback().await;
            return Err(error);
        }
    };
    if !is_damaged(row.as_ref()) {
        transaction
            .rollback()
            .await
            .map_err(|error| failed("config-replace-end", &error))?;
        return Ok(ReplaceCheck::NotDamaged);
    }
    if let Err(error) = upsert(&mut transaction, id, enabled, settings, "config-replace").await {
        let _ = transaction.rollback().await;
        return Err(error);
    }
    transaction
        .commit()
        .await
        .map_err(|error| failed("config-replace-commit", &error))?;
    Ok(ReplaceCheck::Replaced)
}

async fn begin<'c>(
    conn: &'c mut SqliteConnection,
    step: &str,
) -> Result<sqlx::Transaction<'c, sqlx::Sqlite>, ConfigStoreError> {
    database::begin_on_rollback_journal(conn, step)
        .await
        .map_err(|error| ConfigStoreError::Database(error.to_string()))
}

async fn select(
    conn: &mut SqliteConnection,
    id: &str,
    step: &str,
) -> Result<Option<StoredModuleConfig>, ConfigStoreError> {
    sqlx::query_as::<_, (i64, String)>(SELECT)
        .bind(id)
        .fetch_optional(conn)
        .await
        .map(|row| row.map(|(enabled, settings)| StoredModuleConfig { enabled, settings }))
        .map_err(|error| failed(&format!("{step}-select"), &error))
}

async fn upsert(
    conn: &mut SqliteConnection,
    id: &str,
    enabled: bool,
    settings: &str,
    step: &str,
) -> Result<(), ConfigStoreError> {
    sqlx::query(UPSERT)
        .bind(id)
        .bind(i64::from(enabled))
        .bind(settings)
        .execute(conn)
        .await
        .map(drop)
        .map_err(|error| failed(&format!("{step}-upsert"), &error))
}

fn failed(step: &str, error: &sqlx::Error) -> ConfigStoreError {
    ConfigStoreError::Database(database::describe(step, &database::Failure::of(error)))
}
