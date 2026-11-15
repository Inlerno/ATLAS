//! Opening the database file (SQLite foundation, ADR-016).
//!
//! One connection for the whole session: rollback journal (the SQLite
//! default, not set), `synchronous = FULL`, `foreign_keys = ON`,
//! `wal_autocheckpoint = 0`. The connection is never reopened and nothing is
//! retried.
//!
//! First run and a lost database are told apart by a marker file outside the
//! data directory ([`Layout::marker`]):
//!
//! | marker | database | meaning                 | action                              |
//! |--------|----------|-------------------------|-------------------------------------|
//! | no     | no       | first run               | create, migrate, create the marker  |
//! | no     | yes      | interrupted first run   | open, migrate, create the marker    |
//! | yes    | yes      | normal run              | open                                |
//! | yes    | no       | the database is lost    | unavailable, nothing is created     |
//!
//! An existing database file is never deleted, recreated or overwritten.
//! Initialisation (no marker yet) runs under a lock file so that two
//! instances do not initialise the storage at once; a normal run takes no
//! lock.
//!
//! # WAL files
//!
//! SQLite switches a database to WAL on its own when a `-wal` file lies next
//! to it, whatever journal mode the application expects: on the first read it
//! attaches the file, and a normal close would then copy its frames into the
//! database file (a checkpoint) and delete it. Three things stand against
//! that, in this order:
//!
//! 1. Before opening: a database with a `-wal` or `-shm` file beside it is
//!    not opened ([`refuse_wal_files`]).
//! 2. At opening: the local fork of `sqlx-sqlite` sets
//!    `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` straight after `sqlite3_open_v2`,
//!    before any statement. Whatever this connection attached, closing it
//!    copies nothing into the database file and deletes no WAL file.
//!    `wal_autocheckpoint = 0` turns off the checkpoint after a commit.
//! 3. After opening: the journal mode must be `delete`. It is checked after
//!    the first read, **inside every transaction that is about to write**
//!    (the write probe, the migrations) and again before the storage is
//!    reported as open. Otherwise nothing more is done and the storage is
//!    unavailable. The mode is never switched back: changing it away from WAL
//!    is itself a checkpoint.
//!
//! Why inside the transaction. SQLite looks for a `-wal` file only when a
//! connection that holds no lock starts a transaction; once the transaction
//! has read the file the mode is settled until it ends. A check made before
//! the transaction leaves a gap in which a file can appear and the write
//! would go into it; a check made inside, after the first read and before the
//! first write, leaves none: if it says `delete`, this transaction writes
//! through the rollback journal into the database itself, and if it says
//! `wal`, the transaction is rolled back having written nothing.
//! `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` alone does not do this: it keeps a WAL
//! from being copied into the database on close, not from being written to.
//!
//! What this does **not** give. The checks are not a lock: a process that may
//! write to the data directory at the same moment can slip a file in after
//! the check. SQLite then reads it; it creates or rewrites the `-shm` file;
//! on a first run, with the database still empty, it deletes the `-wal` file
//! itself. A `-wal` file that appears while a transaction is already open is
//! not noticed by it: the transaction changes the database as intended and
//! the stray file is left beside a database it no longer matches. A `-wal`
//! file that appears while the session runs is attached by the next
//! transaction, which then sees foreign content: whoever reads or writes
//! through this connection later (MM-5B) must make the same check inside each
//! of its transactions.

use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{ErrorKind, Write};
use std::path::{Path, PathBuf};

use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection, SqliteSynchronous};
use sqlx::{ConnectOptions, Connection};
use sqlx::{Sqlite, Transaction};

use super::StorageError;
use super::migrations::{self, Embedded};

/// The data directory inside the application's local data directory.
pub(super) const DATA_DIR: &str = "data";
/// The database file inside the data directory.
pub(super) const DATABASE_FILE: &str = "atlas.db";
/// The marker of a completed first run, next to the data directory.
pub(super) const MARKER_FILE: &str = "storage.initialized";
/// The lock file held during the first run, next to the data directory.
pub(super) const LOCK_FILE: &str = "storage.lock";

/// What SQLite appends to the name of the database file for the files of the
/// WAL mode. ATLAS never creates them.
pub(super) const WAL_SUFFIX: &str = "-wal";
pub(super) const SHM_SUFFIX: &str = "-shm";
/// The journal mode ATLAS expects: the rollback journal, deleted after each
/// transaction.
const JOURNAL_MODE: &str = "delete";

/// `SQLITE_READONLY`: the database file cannot be written.
const SQLITE_READONLY: i32 = 8;
/// `SQLITE_READONLY_DIRECTORY`: the journal cannot be created next to it.
const SQLITE_READONLY_DIRECTORY: i32 = 1544;

/// Where the storage keeps its files.
#[derive(Debug, Clone)]
pub(super) struct Layout {
    /// The application's local data directory.
    pub root: PathBuf,
    pub data_dir: PathBuf,
    pub database: PathBuf,
    /// `atlas.db-wal` and `atlas.db-shm`: must not exist.
    pub wal: PathBuf,
    pub shm: PathBuf,
    pub marker: PathBuf,
    pub lock: PathBuf,
}

impl Layout {
    pub fn new(root: PathBuf) -> Self {
        let data_dir = root.join(DATA_DIR);
        Self {
            database: data_dir.join(DATABASE_FILE),
            wal: data_dir.join(format!("{DATABASE_FILE}{WAL_SUFFIX}")),
            shm: data_dir.join(format!("{DATABASE_FILE}{SHM_SUFFIX}")),
            marker: root.join(MARKER_FILE),
            lock: root.join(LOCK_FILE),
            data_dir,
            root,
        }
    }
}

/// What the opening works with. The test-only fields provoke conditions that
/// cannot be arranged portably from outside.
pub(super) struct Settings {
    pub migrations: &'static [Embedded],
    /// Shortens the wait for a lock held by another connection.
    #[cfg(test)]
    pub busy_timeout: Option<std::time::Duration>,
    /// Opens the file with a read-only handle: every write fails with
    /// `SQLITE_READONLY` on any platform and for any user.
    #[cfg(test)]
    pub read_only_handle: bool,
    /// Runs in the first-run branch right before the lock is taken.
    #[cfg(test)]
    pub before_lock: Option<std::sync::Arc<dyn Fn() + Send + Sync>>,
    /// Runs between the check for WAL files and the opening of the database:
    /// the moment another process could slip a file in.
    #[cfg(test)]
    pub before_connect: Option<std::sync::Arc<dyn Fn() + Send + Sync>>,
    /// Runs after the first check of the journal mode, right before the write
    /// probe begins its transaction.
    #[cfg(test)]
    pub before_probe: Option<std::sync::Arc<dyn Fn() + Send + Sync>>,
    /// Runs after the write probe, right before the transaction of the
    /// migrations begins.
    #[cfg(test)]
    pub before_migrations: Option<std::sync::Arc<dyn Fn() + Send + Sync>>,
    /// Runs inside the transaction of the migrations, after its check of the
    /// journal mode and before anything is migrated.
    #[cfg(test)]
    pub inside_migrations: Option<std::sync::Arc<dyn Fn() + Send + Sync>>,
    /// Runs after the migrations, right before the last check of the journal
    /// mode.
    #[cfg(test)]
    pub before_final_check: Option<std::sync::Arc<dyn Fn() + Send + Sync>>,
}

impl Settings {
    pub fn new(migrations: &'static [Embedded]) -> Self {
        Self {
            migrations,
            #[cfg(test)]
            busy_timeout: None,
            #[cfg(test)]
            read_only_handle: false,
            #[cfg(test)]
            before_lock: None,
            #[cfg(test)]
            before_connect: None,
            #[cfg(test)]
            before_probe: None,
            #[cfg(test)]
            before_migrations: None,
            #[cfg(test)]
            inside_migrations: None,
            #[cfg(test)]
            before_final_check: None,
        }
    }
}

/// Whether the open database accepts writes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Access {
    ReadWrite,
    /// The write probe failed with this extended SQLite code (8 or 1544).
    ReadOnly {
        code: i32,
    },
}

/// An open, checked and migrated database.
pub(super) struct Opened {
    pub conn: SqliteConnection,
    pub access: Access,
    /// The database file was created by this run.
    pub created: bool,
    pub sqlite_version: String,
    /// Migrations applied by this run and the schema version after it.
    pub applied: usize,
    pub latest: usize,
}

/// The first-run lock: held from before the re-check of the files until the
/// result of the opening is published. Dropping it releases the lock; the
/// file itself stays and means nothing.
pub(super) struct InitLock {
    _file: File,
}

impl InitLock {
    pub(super) fn acquire(path: &Path) -> Result<Self, StorageError> {
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(|error| StorageError::Open(format!("step=lock-file error={error}")))?;
        match file.try_lock() {
            Ok(()) => Ok(Self { _file: file }),
            Err(TryLockError::WouldBlock) => Err(StorageError::Open(
                "another instance is initializing storage".to_owned(),
            )),
            Err(TryLockError::Error(error)) => {
                Err(StorageError::Open(format!("step=lock error={error}")))
            }
        }
    }
}

/// Opens the database by the rules of the module. The lock, if one was taken,
/// is returned so that the caller releases it after publishing the result.
pub(super) async fn open(
    layout: &Layout,
    settings: &Settings,
) -> (Result<Opened, StorageError>, Option<InitLock>) {
    let (marker, database) = match presence(layout) {
        Ok(found) => found,
        Err(error) => return (Err(error), None),
    };
    match (marker, database) {
        (true, true) => (connect(layout, settings, false).await, None),
        (true, false) => (Err(missing()), None),
        (false, _) => first_run(layout, settings).await,
    }
}

/// The initialisation branch: no marker yet. Runs under the lock.
async fn first_run(
    layout: &Layout,
    settings: &Settings,
) -> (Result<Opened, StorageError>, Option<InitLock>) {
    // The root is not a sign of anything (the log directory lives in it).
    if let Err(error) = fs::create_dir_all(&layout.root) {
        let error = StorageError::Open(format!("step=root-directory error={error}"));
        return (Err(error), None);
    }
    #[cfg(test)]
    if let Some(hook) = &settings.before_lock {
        hook();
    }
    let lock = match InitLock::acquire(&layout.lock) {
        Ok(lock) => lock,
        Err(error) => return (Err(error), None),
    };
    (initialise(layout, settings).await, Some(lock))
}

/// With the lock held, looks at the files again — another instance may have
/// finished the first run in between — and completes the initialisation.
async fn initialise(layout: &Layout, settings: &Settings) -> Result<Opened, StorageError> {
    match presence(layout)? {
        (true, true) => connect(layout, settings, false).await,
        (true, false) => Err(missing()),
        (false, database) => {
            match fs::create_dir(&layout.data_dir) {
                Ok(()) => {}
                Err(error) if error.kind() == ErrorKind::AlreadyExists => {}
                Err(error) => {
                    return Err(StorageError::Open(format!(
                        "step=data-directory error={error}"
                    )));
                }
            }
            // An existing file is opened as it is; only a first run creates.
            let opened = connect(layout, settings, !database).await?;
            if let Err(error) = create_marker(&layout.marker) {
                // The database stays: the next run finds it without the
                // marker and continues from there.
                let _ = opened.conn.close().await;
                return Err(StorageError::Open(format!("step=marker error={error}")));
            }
            Ok(opened)
        }
    }
}

/// Whether the marker and the database file exist. Any answer other than
/// "exists" or "not found" is an error: the state is then unknown.
fn presence(layout: &Layout) -> Result<(bool, bool), StorageError> {
    Ok((
        exists(&layout.marker, "marker")?,
        exists(&layout.database, "database-file")?,
    ))
}

fn exists(path: &Path, what: &str) -> Result<bool, StorageError> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(StorageError::Open(format!(
            "step=look-for-{what} error={error}"
        ))),
    }
}

fn missing() -> StorageError {
    StorageError::Open("database file missing".to_owned())
}

/// Creates the marker: "create only if absent", then flushed to disk. Only
/// its existence matters; the content is never read.
fn create_marker(path: &Path) -> std::io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(b"ATLAS storage initialised. Do not delete: see README, storage reset.\n")?;
    file.sync_all()
}

/// Refuses to open the database while a WAL file lies next to it: SQLite
/// would read it, switch the database to WAL and could change the database
/// file. Nothing is deleted, renamed or repaired: the files stay for the user
/// to look at. Also applies to a first run, where SQLite would delete a stray
/// `-wal` on its own.
fn refuse_wal_files(layout: &Layout) -> Result<(), StorageError> {
    let found: Vec<&str> = [(&layout.wal, "atlas.db-wal"), (&layout.shm, "atlas.db-shm")]
        .into_iter()
        .map(|(path, name)| exists(path, name).map(|found| found.then_some(name)))
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .flatten()
        .collect();
    if found.is_empty() {
        Ok(())
    } else {
        Err(StorageError::Open(format!(
            "unexpected WAL files next to the database: {}; the database was not opened",
            found.join(", ")
        )))
    }
}

/// Connects, then checks and migrates. `create` is true only for a first run
/// without a database file.
async fn connect(
    layout: &Layout,
    settings: &Settings,
    create: bool,
) -> Result<Opened, StorageError> {
    refuse_wal_files(layout)?;
    #[cfg(test)]
    if let Some(hook) = &settings.before_connect {
        hook();
    }
    let mut conn = options(layout, settings, create)
        .connect()
        .await
        .map_err(|error| unavailable("open", &Failure::of(&error)))?;
    match prepare(&mut conn, settings).await {
        Ok((access, sqlite_version, applied)) => Ok(Opened {
            conn,
            access,
            created: create,
            sqlite_version,
            applied: applied.applied,
            latest: applied.latest,
        }),
        Err(error) => {
            // Safe whatever the connection attached: it never checkpoints on
            // close (module documentation, "WAL files").
            let _ = conn.close().await;
            Err(error)
        }
    }
}

/// How the one connection is opened.
///
/// The local fork of `sqlx-sqlite` sets `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE`
/// straight after `sqlite3_open_v2`, before the statements below; nothing here
/// asks for it and nothing can leave it out. sqlx then runs, in this order,
/// `PRAGMA foreign_keys = ON` and `PRAGMA synchronous = FULL` (the first
/// statement that reads the file) and `PRAGMA wal_autocheckpoint = 0` (a
/// setting of the connection: it reads nothing).
fn options(layout: &Layout, settings: &Settings, create: bool) -> SqliteConnectOptions {
    #[cfg(not(test))]
    let _ = settings;
    // The journal mode is not set: a new file uses the rollback journal, and
    // setting it on a database in WAL mode would checkpoint the WAL.
    let options = SqliteConnectOptions::new()
        .filename(&layout.database)
        .create_if_missing(create)
        .foreign_keys(true)
        .synchronous(SqliteSynchronous::Full)
        // No checkpoint after a commit either, should this connection ever
        // find itself in WAL mode.
        .pragma("wal_autocheckpoint", "0");
    #[cfg(test)]
    let options = match settings.busy_timeout {
        Some(limit) => options.busy_timeout(limit),
        None => options,
    }
    .read_only(settings.read_only_handle);
    options
}

/// Fails unless the connection uses the rollback journal. Nothing is switched
/// back: leaving WAL mode would checkpoint the WAL into the database.
///
/// `PRAGMA journal_mode` only reports what the connection last settled on; it
/// is a read of the file that makes SQLite look for a `-wal` file again. So
/// the file is read first.
async fn require_rollback_journal(
    conn: &mut SqliteConnection,
    step: &str,
) -> Result<(), StorageError> {
    let _objects: i64 = sqlx::query_scalar("SELECT count(*) FROM sqlite_master")
        .fetch_one(&mut *conn)
        .await
        .map_err(|error| unavailable(step, &Failure::of(&error)))?;
    let journal_mode: String = sqlx::query_scalar("PRAGMA journal_mode")
        .fetch_one(&mut *conn)
        .await
        .map_err(|error| unavailable(step, &Failure::of(&error)))?;
    if journal_mode.eq_ignore_ascii_case(JOURNAL_MODE) {
        Ok(())
    } else {
        Err(StorageError::Open(format!(
            "step={step} mode={journal_mode} expected={JOURNAL_MODE}"
        )))
    }
}

/// Begins a transaction and checks, inside it, that it runs on the rollback
/// journal (module documentation, "Why inside the transaction"). On any
/// failure the transaction is rolled back before the error is returned.
async fn begin_on_rollback_journal<'c>(
    conn: &'c mut SqliteConnection,
    step: &str,
) -> Result<Transaction<'c, Sqlite>, StorageError> {
    let mut transaction = conn
        .begin()
        .await
        .map_err(|error| unavailable(&format!("{step}-begin"), &Failure::of(&error)))?;
    // `BEGIN` takes no lock: the read inside the check is what starts the
    // transaction in SQLite and settles the journal mode for its duration.
    if let Err(error) =
        require_rollback_journal(&mut transaction, &format!("{step}-journal-mode")).await
    {
        // Nothing was written. Should the rollback fail as well, the caller
        // closes the connection, which ends the transaction.
        let _ = transaction.rollback().await;
        return Err(error);
    }
    Ok(transaction)
}

/// Read check, journal mode, write probe, then the migrations (the migrator
/// for a writable database, a check that writes nothing for a read-only one),
/// then the journal mode once more.
async fn prepare(
    conn: &mut SqliteConnection,
    settings: &Settings,
) -> Result<(Access, String, migrations::Applied), StorageError> {
    let _objects: i64 = sqlx::query_scalar("SELECT count(*) FROM sqlite_master")
        .fetch_one(&mut *conn)
        .await
        .map_err(|error| unavailable("read", &Failure::of(&error)))?;
    // After the first read SQLite has settled the mode: `wal` here means the
    // file says so or a `-wal` file appeared after the check before opening.
    // Nothing else is done with such a database: no probe, no migration.
    require_rollback_journal(conn, "journal-mode").await?;
    let sqlite_version: String = sqlx::query_scalar("SELECT sqlite_version()")
        .fetch_one(&mut *conn)
        .await
        .map_err(|error| unavailable("read", &Failure::of(&error)))?;
    #[cfg(test)]
    if let Some(hook) = &settings.before_probe {
        hook();
    }
    let access = match probe_write(conn).await? {
        Verdict::Writable => Access::ReadWrite,
        Verdict::ReadOnly(code) => Access::ReadOnly { code },
        Verdict::Unavailable(reason) => return Err(StorageError::Open(reason)),
    };
    #[cfg(test)]
    if let Some(hook) = &settings.before_migrations {
        hook();
    }
    let applied = migrate(conn, settings, access).await?;
    #[cfg(test)]
    if let Some(hook) = &settings.before_final_check {
        hook();
    }
    // A `-wal` file that appeared since the last transaction is attached by
    // this read: the storage must not be reported as open.
    require_rollback_journal(conn, "journal-mode-final").await?;
    Ok((access, sqlite_version, applied))
}

/// The migrations of this run, as one transaction: all of them are committed
/// together or none is.
///
/// The journal mode is checked inside that transaction before anything is
/// written, so the migrations cannot be written into a foreign WAL. The
/// migrator of sqlx runs inside it: its own `begin` and `commit` for each
/// migration become `SAVEPOINT` and `RELEASE` (sqlx counts the depth and
/// issues `COMMIT` only at depth 1), so nothing is committed before the
/// `COMMIT` here.
///
/// A database that cannot be written is only read, in a transaction of the
/// same kind that is always rolled back.
async fn migrate(
    conn: &mut SqliteConnection,
    settings: &Settings,
    access: Access,
) -> Result<migrations::Applied, StorageError> {
    let mut transaction = begin_on_rollback_journal(conn, "migrations").await?;
    #[cfg(test)]
    if let Some(hook) = &settings.inside_migrations {
        hook();
    }
    match access {
        Access::ReadWrite => {
            match migrations::run(&mut transaction, settings.migrations).await {
                Ok(applied) => {
                    // A failed `COMMIT` leaves nothing applied: sqlx rolls
                    // the transaction back when it is dropped, and the caller
                    // closes the connection.
                    transaction
                        .commit()
                        .await
                        .map_err(|error| unavailable("migrations-commit", &Failure::of(&error)))?;
                    Ok(applied)
                }
                Err(error) => {
                    // Everything this run applied goes with it.
                    let _ = transaction.rollback().await;
                    Err(StorageError::Migration(error))
                }
            }
        }
        // The migrator could try to write: only the reading check runs.
        Access::ReadOnly { .. } => {
            let verified =
                migrations::verify_read_only(&mut transaction, settings.migrations).await;
            let _ = transaction.rollback().await;
            verified.map_err(StorageError::Migration)
        }
    }
}

/// The write probe: sets `PRAGMA user_version` to its current value inside a
/// transaction and rolls it back. Neither sqlx nor ATLAS uses `user_version`;
/// the file content does not change.
///
/// The transaction first checks its journal mode: a probe that found itself
/// in WAL mode writes nothing and the storage is unavailable.
async fn probe_write(conn: &mut SqliteConnection) -> Result<Verdict, StorageError> {
    let mut transaction = begin_on_rollback_journal(conn, "probe").await?;
    let current: i64 = match sqlx::query_scalar("PRAGMA user_version")
        .fetch_one(&mut *transaction)
        .await
    {
        Ok(current) => current,
        Err(error) => {
            let _ = transaction.rollback().await;
            return Err(unavailable("probe-read", &Failure::of(&error)));
        }
    };
    // An integer read from the database itself: not text from outside.
    let write = sqlx::query(&format!("PRAGMA user_version = {current}"))
        .execute(&mut *transaction)
        .await
        .map(drop)
        .map_err(|error| Failure::of(&error));
    let rollback = transaction
        .rollback()
        .await
        .map_err(|error| Failure::of(&error));
    Ok(classify_probe(write, rollback))
}

/// A failed step: the extended SQLite code, if the error has one, and its text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Failure {
    pub code: Option<i32>,
    pub message: String,
}

impl Failure {
    fn of(error: &sqlx::Error) -> Self {
        match error {
            // sqlx reports the extended result code as a decimal string.
            sqlx::Error::Database(database) => Self {
                code: database.code().and_then(|code| code.parse().ok()),
                message: database.message().to_owned(),
            },
            other => Self {
                code: None,
                message: other.to_string(),
            },
        }
    }
}

/// The result of the write probe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Verdict {
    Writable,
    ReadOnly(i32),
    Unavailable(String),
}

/// Read-only is only this: the write was refused with `SQLITE_READONLY` (8)
/// or `SQLITE_READONLY_DIRECTORY` (1544) and the rollback succeeded.
/// Everything else — busy, full, I/O, an unknown code, an error without a
/// code, a failed rollback — is unavailable: an unknown condition is never
/// taken for "read-only".
pub(super) fn classify_probe(write: Result<(), Failure>, rollback: Result<(), Failure>) -> Verdict {
    match (write, rollback) {
        (Ok(()), Ok(())) => Verdict::Writable,
        (Ok(()), Err(failure)) => Verdict::Unavailable(describe("probe-rollback", &failure)),
        (
            Err(Failure {
                code: Some(code @ (SQLITE_READONLY | SQLITE_READONLY_DIRECTORY)),
                ..
            }),
            rollback,
        ) => match rollback {
            Ok(()) => Verdict::ReadOnly(code),
            Err(failure) => Verdict::Unavailable(describe("probe-rollback", &failure)),
        },
        (Err(failure), _) => Verdict::Unavailable(describe("probe", &failure)),
    }
}

fn unavailable(step: &str, failure: &Failure) -> StorageError {
    StorageError::Open(describe(step, failure))
}

fn describe(step: &str, failure: &Failure) -> String {
    match failure.code {
        Some(code) => format!("step={step} code={code} message={}", failure.message),
        None => format!("step={step} error={}", failure.message),
    }
}
