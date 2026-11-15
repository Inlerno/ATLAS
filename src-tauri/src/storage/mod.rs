//! SQLite storage: a core service (SQLite foundation, ADR-016, ADR-011).
//!
//! The service owns the database file: where it lives, how it is opened and
//! migrated, and how it is closed on exit. It is created at startup, opens
//! the database once in the background and keeps the result for the whole
//! session: there is no reopening and no retry.
//!
//! What it does not have yet: access to the database for other services.
//! That arrives with the first consumer (MM-5B), which waits for the same
//! opening result as [`Storage::close`] does — it never sees "not open yet".
//! `sqlx` is used only inside this directory.

mod database;
mod migrations;
#[cfg(test)]
mod tests;

use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use sqlx::Connection;
use sqlx::sqlite::SqliteConnection;
use thiserror::Error;
use tokio::sync::Mutex;
use tokio::time::Instant;

use crate::error::AppError;
use database::{Access, Layout, Settings};

/// Why the storage is unavailable. The texts are for the log only: they may
/// contain local paths and never contain stored values.
#[derive(Debug, Error)]
enum StorageError {
    /// The application data directory could not be resolved.
    #[error("storage location: {0}")]
    Location(String),
    /// The file could not be opened, read or probed, or the first-run rules
    /// refused it (lost database, another instance initialising, marker).
    #[error("{0}")]
    Open(String),
    /// The schema cannot be brought to the version of the application.
    #[error("migrations: {0}")]
    Migration(String),
}

/// The storage service. Cloning shares the same service.
#[derive(Clone)]
pub struct Storage {
    inner: Arc<Inner>,
}

struct Inner {
    /// The file layout, or why the location is unknown.
    layout: Result<Layout, String>,
    settings: Settings,
    /// Held for the whole opening and the whole closing: whoever takes it
    /// sees a finished result, never an opening in progress.
    state: Mutex<State>,
    /// A close was asked for, whether or not it got through. An opening that
    /// finishes after this closes its own connection: nobody else may come
    /// back for it.
    close_requested: AtomicBool,
    /// The one deadline of all bounded closes of the session, set by the
    /// first [`Storage::close_within`]. A later call waits only for what is
    /// left of it: the exit never waits for the storage twice.
    close_deadline: OnceLock<Instant>,
}

/// The state of the storage within one session; there is no way back.
enum State {
    /// Not opened yet (or the opening is running and holds the lock).
    Pending,
    /// Open; the write probe passed.
    Ready(SqliteConnection),
    /// Open, but the file cannot be written (SQLite codes 8 or 1544).
    ReadOnly(SqliteConnection),
    /// Not open until the next start; the reason is in the log.
    Unavailable,
    Closed,
}

impl Storage {
    /// Creates the service. Does not touch the disk and never fails: a
    /// location error is kept and becomes the result of the opening.
    pub fn new(app_local_data_dir: Result<PathBuf, AppError>) -> Self {
        Self::with_settings(
            app_local_data_dir.map_err(|error| error.to_string()),
            Settings::new(migrations::MIGRATIONS),
        )
    }

    fn with_settings(root: Result<PathBuf, String>, settings: Settings) -> Self {
        Self {
            inner: Arc::new(Inner {
                layout: root.map(Layout::new),
                settings,
                state: Mutex::new(State::Pending),
                close_requested: AtomicBool::new(false),
                close_deadline: OnceLock::new(),
            }),
        }
    }

    /// Opens the database: first-run rules, read check, write probe,
    /// migrations. Meant to be spawned once at startup; the result stays for
    /// the session. Does nothing if the storage is already open or closed.
    pub fn open(&self) -> impl Future<Output = ()> + Send + 'static + use<> {
        let inner = Arc::clone(&self.inner);
        async move {
            let mut state = inner.state.lock().await;
            if !matches!(*state, State::Pending) {
                return;
            }
            if inner.close_requested.load(Ordering::SeqCst) {
                // The exit began before the opening did: nothing is opened
                // or created.
                *state = State::Closed;
                return;
            }
            let (opened, init_lock) = match &inner.layout {
                Ok(layout) => database::open(layout, &inner.settings).await,
                Err(reason) => (Err(StorageError::Location(reason.clone())), None),
            };
            let path = inner
                .layout
                .as_ref()
                .map(|layout| layout.database.display().to_string())
                .unwrap_or_default();
            // A close asked for while the opening ran may have given up
            // waiting. The opening itself cannot be cut short safely, so it
            // was completed; now the connection is closed here instead of
            // being left open for a close that will not come.
            let closing = inner.close_requested.load(Ordering::SeqCst);
            *state = match opened {
                Ok(opened) if closing => {
                    tracing::info!(
                        %path,
                        "database opened after the exit began: closing it"
                    );
                    close_connection(opened.conn).await;
                    State::Closed
                }
                Ok(opened) => {
                    tracing::info!(
                        applied = opened.applied,
                        latest = opened.latest,
                        "database migrations applied"
                    );
                    match opened.access {
                        Access::ReadWrite => {
                            tracing::info!(
                                %path,
                                created = opened.created,
                                sqlite_version = %opened.sqlite_version,
                                state = "ready",
                                "database opened"
                            );
                            State::Ready(opened.conn)
                        }
                        Access::ReadOnly { code } => {
                            tracing::error!(
                                %path,
                                code,
                                sqlite_version = %opened.sqlite_version,
                                "database opened read-only: changes will not be saved"
                            );
                            State::ReadOnly(opened.conn)
                        }
                    }
                }
                Err(error) => {
                    tracing::error!(%path, %error, "database unavailable");
                    State::Unavailable
                }
            };
            // The first-run lock is released only now, after the result is
            // published.
            drop(init_lock);
        }
    }

    /// Closes the connection. Waits for an opening in progress; safe to call
    /// more than once and from several tasks. Closing is tidiness, not a
    /// condition of durability: committed transactions are already on disk.
    pub async fn close(&self) {
        // Before waiting: an opening in progress sees it when it finishes,
        // even if this call is dropped meanwhile.
        self.inner.close_requested.store(true, Ordering::SeqCst);
        let mut state = self.inner.state.lock().await;
        match std::mem::replace(&mut *state, State::Closed) {
            State::Ready(conn) | State::ReadOnly(conn) => close_connection(conn).await,
            State::Pending | State::Unavailable | State::Closed => {}
        }
    }

    /// [`Storage::close`] with a bounded wait, for the exit path: a stuck
    /// disk must not hold the exit forever. If the limit passes, SQLite
    /// restores consistency at the next opening.
    ///
    /// The limit of the first call sets one deadline for the session; every
    /// later call, from any task, waits only until that same deadline. After
    /// it has passed a call takes what can be had at once and returns: the
    /// exit does not wait for the storage a second time. An opening still
    /// running then closes its own connection when it finishes (see
    /// [`Storage::open`]) unless the process ends first.
    pub async fn close_within(&self, limit: Duration) {
        let now = Instant::now();
        let deadline = *self.inner.close_deadline.get_or_init(|| now + limit);
        if tokio::time::timeout_at(deadline, self.close())
            .await
            .is_err()
        {
            tracing::warn!(
                limit_ms = limit.as_millis() as u64,
                waited_ms = now.elapsed().as_millis() as u64,
                "database not closed within the limit"
            );
        }
    }
}

/// Closes a connection and says how it went. If the caller is dropped while
/// this waits, sqlx has already told the connection's thread to shut down:
/// the handle is closed there.
async fn close_connection(conn: SqliteConnection) {
    match conn.close().await {
        Ok(()) => tracing::info!("database closed"),
        Err(error) => tracing::warn!(%error, "database closed with an error"),
    }
}
