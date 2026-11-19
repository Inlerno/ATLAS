//! SQLite storage: a core service (SQLite foundation, ADR-016, ADR-011).
//!
//! The service owns the database file: where it lives, how it is opened and
//! migrated, and how it is closed on exit. It is created at startup, opens
//! the database once in the background and keeps the result for the whole
//! session: there is no reopening and no retry.
//!
//! Other services reach the database only through typed operations of this
//! service — today the module configuration (MM-5B, #21) — never through the
//! connection. An operation waits for the result of the opening, bounded by
//! one readiness deadline for the whole session ([`READINESS_TIMEOUT`]): it
//! never sees "not open yet", and if the deadline passes first, nothing is
//! read or written for the rest of the session even if the database opens
//! later. `sqlx` is used only inside this directory.

mod database;
mod migrations;
mod module_config;
#[cfg(test)]
pub(crate) mod test_support;
#[cfg(test)]
mod tests;

pub use module_config::{ConfigStoreError, ReplaceCheck, StoredModuleConfig};

use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use sqlx::Connection;
use sqlx::sqlite::SqliteConnection;
use thiserror::Error;
use tokio::sync::{Mutex, MutexGuard, SetOnce};
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

/// How long, at most, the operations of a session wait for the result of the
/// opening (decision O-3). One deadline for the whole session, counted from
/// the first operation that waits: a limit, not an expected delay — the
/// opening takes milliseconds (measured on Windows, 17.11.2026).
pub const READINESS_TIMEOUT: Duration = Duration::from_secs(5);

/// The result of the opening as the operations see it: published once, by the
/// opening or by a close, whichever ends the `Pending` state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Ready,
    ReadOnly,
    Unavailable,
    Closed,
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
    /// Set when the `Pending` state ends, while the state lock is still held:
    /// whoever wakes up on it then takes the lock and finds the final state.
    outcome: SetOnce<Outcome>,
    /// How long the operations wait for `outcome` ([`READINESS_TIMEOUT`]).
    readiness_timeout: Duration,
    /// The one readiness deadline of the session, set by the first operation
    /// that waits.
    readiness_deadline: OnceLock<Instant>,
    /// The deadline passed without a result: no operation runs for the rest
    /// of the session, whatever the opening does later.
    readiness_expired: AtomicBool,
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
        Self::with_readiness(root, settings, READINESS_TIMEOUT)
    }

    fn with_readiness(
        root: Result<PathBuf, String>,
        settings: Settings,
        readiness_timeout: Duration,
    ) -> Self {
        Self {
            inner: Arc::new(Inner {
                layout: root.map(Layout::new),
                settings,
                state: Mutex::new(State::Pending),
                close_requested: AtomicBool::new(false),
                close_deadline: OnceLock::new(),
                outcome: SetOnce::new(),
                readiness_timeout,
                readiness_deadline: OnceLock::new(),
                readiness_expired: AtomicBool::new(false),
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
                publish(&inner, Outcome::Closed);
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
            publish(&inner, Outcome::of(&state));
            if inner.readiness_expired.load(Ordering::SeqCst)
                && matches!(*state, State::Ready(_) | State::ReadOnly(_))
            {
                tracing::warn!(
                    "database opened after the readiness deadline: module configuration \
                     stays unavailable for this session"
                );
            }
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
        // Wakes operations still waiting when the opening never ran; after an
        // opening the result is already published and stays as it was.
        publish(&self.inner, Outcome::Closed);
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

// ---------------------------------------------------------------------------
// Module configuration (MM-5B, #21)
// ---------------------------------------------------------------------------

/// Whether an operation reads only or also writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Purpose {
    Read,
    Write,
}

impl Storage {
    /// The stored configuration of the module `id`, or `None` if there is
    /// none. Works on a read-only database too.
    pub async fn read_module_config(
        &self,
        id: &str,
    ) -> Result<Option<StoredModuleConfig>, ConfigStoreError> {
        let mut state = self.usable(Purpose::Read).await?;
        module_config::read(connection(&mut state)?, id).await
    }

    /// Saves every `(id, enabled, settings)` entry or none of them, in one
    /// transaction; an id given twice keeps its last entry. An empty batch
    /// does nothing and waits for nothing.
    pub async fn write_module_configs(
        &self,
        entries: &[(&str, bool, &str)],
    ) -> Result<(), ConfigStoreError> {
        if entries.is_empty() {
            return Ok(());
        }
        let mut state = self.usable(Purpose::Write).await?;
        module_config::write(connection(&mut state)?, entries).await
    }

    /// Replaces the row of `id` with `(enabled, settings)` only if
    /// `is_damaged`, given the row as it is now (or `None`), says so. The
    /// check and the write are one transaction.
    pub async fn replace_module_config_if(
        &self,
        id: &str,
        enabled: bool,
        settings: &str,
        is_damaged: impl FnOnce(Option<&StoredModuleConfig>) -> bool + Send,
    ) -> Result<ReplaceCheck, ConfigStoreError> {
        let mut state = self.usable(Purpose::Write).await?;
        module_config::replace_if(connection(&mut state)?, id, enabled, settings, is_damaged).await
    }

    /// Waits for the result of the opening without holding the state lock —
    /// the opening needs that lock — then takes the lock and checks that the
    /// storage can serve `purpose`. The wait is bounded by the one readiness
    /// deadline of the session; once it has passed without a result, every
    /// operation fails at once for the rest of the session.
    async fn usable(&self, purpose: Purpose) -> Result<MutexGuard<'_, State>, ConfigStoreError> {
        let inner = &self.inner;
        if inner.readiness_expired.load(Ordering::SeqCst) {
            return Err(ConfigStoreError::ReadinessExpired);
        }
        let deadline = *inner
            .readiness_deadline
            .get_or_init(|| Instant::now() + inner.readiness_timeout);
        if tokio::time::timeout_at(deadline, inner.outcome.wait())
            .await
            .is_err()
            && inner.outcome.get().is_none()
        {
            if !inner.readiness_expired.swap(true, Ordering::SeqCst) {
                tracing::error!(
                    limit_ms = inner.readiness_timeout.as_millis() as u64,
                    "storage readiness deadline passed: module configuration is not read \
                     or written in this session"
                );
            }
            return Err(ConfigStoreError::ReadinessExpired);
        }
        let state = inner.state.lock().await;
        match (&*state, purpose) {
            (State::Ready(_), _) | (State::ReadOnly(_), Purpose::Read) => Ok(state),
            (State::ReadOnly(_), Purpose::Write) => Err(ConfigStoreError::ReadOnly),
            (State::Unavailable, _) => Err(ConfigStoreError::Unavailable),
            (State::Closed, _) => Err(ConfigStoreError::Closed),
            // A result was published, yet nothing is open: never wait twice.
            (State::Pending, _) => Err(ConfigStoreError::NotOpen),
        }
    }
}

/// The connection of an open state; [`Storage::usable`] has checked it.
fn connection<'a>(
    state: &'a mut MutexGuard<'_, State>,
) -> Result<&'a mut SqliteConnection, ConfigStoreError> {
    match &mut **state {
        State::Ready(conn) | State::ReadOnly(conn) => Ok(conn),
        State::Pending => Err(ConfigStoreError::NotOpen),
        State::Unavailable => Err(ConfigStoreError::Unavailable),
        State::Closed => Err(ConfigStoreError::Closed),
    }
}

impl Outcome {
    fn of(state: &State) -> Self {
        match state {
            State::Ready(_) => Self::Ready,
            State::ReadOnly(_) => Self::ReadOnly,
            // Not reached: the opening always leaves a final state.
            State::Pending | State::Unavailable => Self::Unavailable,
            State::Closed => Self::Closed,
        }
    }
}

/// Publishes the result of the opening. Only the first call counts: the
/// result of a session never changes.
fn publish(inner: &Inner, outcome: Outcome) {
    let _ = inner.outcome.set(outcome);
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
