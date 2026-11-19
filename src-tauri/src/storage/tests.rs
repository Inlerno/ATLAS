//! Tests of the storage infrastructure.
//!
//! They run on a runtime with the normal clock: under the paused clock of the
//! module manager harness sqlx reports timeouts at once, because its work
//! happens on a thread the runtime does not see.

use std::fs;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use sqlx::Connection;
use sqlx::sqlite::{SqliteConnectOptions, SqliteConnection};
use sqlx::{ConnectOptions, Row};

use super::database::{
    self, Access, DATA_DIR, DATABASE_FILE, Failure, InitLock, LOCK_FILE, Layout, MARKER_FILE,
    Opened, SHM_SUFFIX, Settings, Verdict, WAL_SUFFIX, classify_probe,
};
use super::migrations::{self, Embedded, MIGRATIONS, list_defect};
use super::{ConfigStoreError, ReplaceCheck, State, Storage, StorageError, StoredModuleConfig};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn run<F: Future>(test: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread()
        .enable_time()
        .build()
        .expect("test runtime")
        .block_on(test)
}

/// A unique directory under the system temporary directory, removed on drop.
struct TempRoot(PathBuf);

impl TempRoot {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_nanos())
            .unwrap_or_default();
        // A space and non-ASCII letters: the path is passed to SQLite as a
        // path, not as a URL.
        let path = std::env::temp_dir().join(format!(
            "atlas storage тест {tag}-{}-{}-{nanos}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).expect("create the temporary root");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }

    fn layout(&self) -> Layout {
        Layout::new(self.0.clone())
    }
}

impl Drop for TempRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

const CREATE_ITEMS: Embedded = Embedded {
    version: 1,
    name: "create_items",
    sql: include_str!("test_migrations/0001_create_items.sql"),
};
const ADD_NOTE: Embedded = Embedded {
    version: 2,
    name: "add_note",
    sql: include_str!("test_migrations/0002_add_note.sql"),
};

const NONE: &[Embedded] = &[];
const ONE: &[Embedded] = &[CREATE_ITEMS];
const TWO: &[Embedded] = &[CREATE_ITEMS, ADD_NOTE];
/// The second migration fails in its second statement.
const BROKEN: &[Embedded] = &[
    CREATE_ITEMS,
    Embedded {
        version: 2,
        name: "broken",
        sql: "CREATE TABLE half (id INTEGER PRIMARY KEY);\nINSERT INTO no_such_table VALUES (1);\n",
    },
];
/// Version 1 with a text other than the one in `ONE`.
const EDITED: &[Embedded] = &[Embedded {
    version: 1,
    name: "create_items",
    sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT) STRICT;\n",
}];

fn test_migrations_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/storage/test_migrations")
}

async fn open_with(layout: &Layout, settings: &Settings) -> Result<Opened, StorageError> {
    let (opened, _lock) = database::open(layout, settings).await;
    opened
}

async fn open(layout: &Layout, list: &'static [Embedded]) -> Result<Opened, StorageError> {
    open_with(layout, &Settings::new(list)).await
}

/// Opens, expects success and closes: one finished run of the application.
async fn session(layout: &Layout, list: &'static [Embedded]) -> (Access, bool, usize) {
    let opened = open(layout, list).await.expect("the database opens");
    let summary = (opened.access, opened.created, opened.applied);
    opened.conn.close().await.expect("close");
    summary
}

fn reason(result: Result<Opened, StorageError>) -> String {
    match result {
        Ok(_) => panic!("the opening was expected to fail"),
        Err(error) => error.to_string(),
    }
}

/// A plain connection to an existing database, as another program would open it.
async fn raw(layout: &Layout) -> SqliteConnection {
    SqliteConnectOptions::new()
        .filename(&layout.database)
        .connect()
        .await
        .expect("raw connection")
}

async fn count(conn: &mut SqliteConnection, sql: &str) -> i64 {
    sqlx::query_scalar(sql)
        .fetch_one(conn)
        .await
        .expect("count query")
}

async fn applied_versions(conn: &mut SqliteConnection) -> Vec<i64> {
    sqlx::query("SELECT version FROM _sqlx_migrations ORDER BY version")
        .fetch_all(conn)
        .await
        .expect("applied versions")
        .iter()
        .map(|row| row.get(0))
        .collect()
}

async fn insert_item(layout: &Layout, name: &str) {
    let mut conn = raw(layout).await;
    sqlx::query("INSERT INTO items (name) VALUES (?1)")
        .bind(name)
        .execute(&mut conn)
        .await
        .expect("insert");
    conn.close().await.expect("close");
}

async fn items(layout: &Layout) -> i64 {
    let mut conn = raw(layout).await;
    let found = count(&mut conn, "SELECT count(*) FROM items").await;
    conn.close().await.expect("close");
    found
}

/// Compares a migration list with the `.sql` files of a directory: every file
/// is listed and every entry has its file, named `NNNN_<name>.sql`, with the
/// embedded text and without CR. A missing directory is an empty one.
fn files_defect(list: &[Embedded], dir: &Path) -> Result<(), String> {
    let mut on_disk: Vec<String> = match fs::read_dir(dir) {
        Ok(entries) => entries
            .map(|entry| entry.expect("directory entry").file_name())
            .map(|name| name.to_string_lossy().into_owned())
            .filter(|name| name.ends_with(".sql"))
            .collect(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Vec::new(),
        Err(error) => return Err(format!("cannot read {}: {error}", dir.display())),
    };
    on_disk.sort();
    let listed: Vec<String> = list.iter().map(migrations::file_name).collect();
    if on_disk != listed {
        return Err(format!(
            "files {on_disk:?} do not match the list {listed:?}"
        ));
    }
    for entry in list {
        let name = migrations::file_name(entry);
        let bytes = fs::read(dir.join(&name)).map_err(|error| format!("{name}: {error}"))?;
        if bytes.contains(&b'\r') {
            return Err(format!("{name} contains a carriage return"));
        }
        if bytes != entry.sql.as_bytes() {
            return Err(format!("{name} differs from the embedded text"));
        }
    }
    Ok(())
}

impl Storage {
    fn for_test(root: &Path, list: &'static [Embedded]) -> Self {
        Self::with_settings(Ok(root.to_path_buf()), Settings::new(list))
    }

    async fn kind(&self) -> &'static str {
        match &*self.inner.state.lock().await {
            State::Pending => "pending",
            State::Ready(_) => "ready",
            State::ReadOnly(_) => "read-only",
            State::Unavailable => "unavailable",
            State::Closed => "closed",
        }
    }
}

// ---------------------------------------------------------------------------
// First run and the marker
// ---------------------------------------------------------------------------

#[test]
fn layout_is_the_agreed_one() {
    let layout = Layout::new(PathBuf::from("root"));
    assert_eq!(layout.data_dir, Path::new("root").join("data"));
    assert_eq!(
        layout.database,
        Path::new("root").join("data").join("atlas.db")
    );
    assert_eq!(layout.marker, Path::new("root").join("storage.initialized"));
    assert_eq!(layout.lock, Path::new("root").join("storage.lock"));
    assert_eq!(
        (DATA_DIR, DATABASE_FILE, MARKER_FILE, LOCK_FILE),
        ("data", "atlas.db", "storage.initialized", "storage.lock")
    );
}

#[test]
fn first_run_creates_the_database_then_the_marker() {
    run(async {
        let root = TempRoot::new("first");
        let layout = root.layout();
        let mut opened = open(&layout, NONE).await.expect("first run");
        assert_eq!(opened.access, Access::ReadWrite);
        assert!(opened.created);
        assert_eq!((opened.applied, opened.latest), (0, 0));
        assert!(layout.database.is_file());
        assert!(layout.marker.is_file());
        // The empty product list still creates the service table of sqlx.
        let tables = count(
            &mut opened.conn,
            "SELECT count(*) FROM sqlite_master WHERE name = '_sqlx_migrations'",
        )
        .await;
        assert_eq!(tables, 1);
        assert_eq!(count(&mut opened.conn, "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE '_sqlx%' AND name NOT LIKE 'sqlite_%'").await, 0);
        // The agreed connection settings.
        let journal: String = sqlx::query_scalar("PRAGMA journal_mode")
            .fetch_one(&mut opened.conn)
            .await
            .expect("journal mode");
        assert_eq!(journal, "delete");
        assert_eq!(count(&mut opened.conn, "PRAGMA synchronous").await, 2);
        assert_eq!(count(&mut opened.conn, "PRAGMA foreign_keys").await, 1);
        opened.conn.close().await.expect("close");
        // After a clean close only the database file is left.
        let left: Vec<_> = fs::read_dir(&layout.data_dir)
            .expect("data directory")
            .map(|entry| entry.expect("entry").file_name())
            .collect();
        assert_eq!(left, vec![std::ffi::OsString::from(DATABASE_FILE)]);
    });
}

#[test]
fn second_run_opens_the_same_database() {
    run(async {
        let root = TempRoot::new("second");
        let layout = root.layout();
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, true, 1));
        insert_item(&layout, "kept").await;
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, false, 0));
        assert_eq!(items(&layout).await, 1);
    });
}

#[test]
fn database_without_marker_continues_the_first_run() {
    run(async {
        let root = TempRoot::new("no-marker");
        let layout = root.layout();
        session(&layout, ONE).await;
        insert_item(&layout, "kept").await;
        fs::remove_file(&layout.marker).expect("remove the marker");

        assert_eq!(session(&layout, TWO).await, (Access::ReadWrite, false, 1));
        assert!(layout.marker.is_file());
        assert_eq!(items(&layout).await, 1);
    });
}

#[test]
fn marker_without_database_is_unavailable_and_creates_nothing() {
    run(async {
        let root = TempRoot::new("lost");
        let layout = root.layout();
        session(&layout, ONE).await;

        // Only the file is lost.
        fs::remove_file(&layout.database).expect("remove the database");
        assert_eq!(reason(open(&layout, ONE).await), "database file missing");
        assert!(!layout.database.exists());

        // The whole data directory is lost.
        fs::remove_dir(&layout.data_dir).expect("remove the data directory");
        assert_eq!(reason(open(&layout, ONE).await), "database file missing");
        assert!(!layout.data_dir.exists());
    });
}

#[test]
fn failed_marker_makes_the_run_unavailable_and_the_next_run_continues() {
    run(async {
        let root = TempRoot::new("marker-fails");
        let mut broken = root.layout();
        broken.marker = root.path().join("no-such-directory").join(MARKER_FILE);
        let error = reason(open(&broken, ONE).await);
        assert!(error.starts_with("step=marker "), "{error}");

        // The migrated database stays; the next run adds the marker.
        let layout = root.layout();
        assert!(layout.database.is_file());
        assert!(!layout.marker.exists());
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, false, 0));
        assert!(layout.marker.is_file());
    });
}

#[test]
fn unknown_files_in_the_data_directory_are_left_alone() {
    run(async {
        let root = TempRoot::new("unknown");
        let layout = root.layout();
        fs::create_dir(&layout.data_dir).expect("data directory");
        let stranger = layout.data_dir.join("notes.txt");
        fs::write(&stranger, b"not ours").expect("write");
        fs::create_dir(layout.data_dir.join("folder")).expect("folder");

        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, true, 1));
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, false, 0));
        assert_eq!(fs::read(&stranger).expect("read"), b"not ours");
        assert!(layout.data_dir.join("folder").is_dir());
    });
}

#[test]
fn file_that_is_not_a_database_is_never_overwritten() {
    run(async {
        let garbage = vec![0x5a_u8; 4096];
        for with_marker in [false, true] {
            let root = TempRoot::new("garbage");
            let layout = root.layout();
            fs::create_dir(&layout.data_dir).expect("data directory");
            fs::write(&layout.database, &garbage).expect("write");
            if with_marker {
                fs::write(&layout.marker, b"").expect("marker");
            }
            let error = reason(open(&layout, ONE).await);
            // SQLITE_NOTADB.
            assert!(error.contains("code=26"), "{error}");
            assert_eq!(fs::read(&layout.database).expect("read"), garbage);
            assert_eq!(layout.marker.exists(), with_marker);
        }
    });
}

#[test]
fn manual_reset_removes_the_data_directory_and_the_marker() {
    run(async {
        let root = TempRoot::new("reset");
        let layout = root.layout();
        session(&layout, ONE).await;
        insert_item(&layout, "old").await;

        // Half of the documented procedure is not a reset.
        fs::remove_dir_all(&layout.data_dir).expect("remove the data directory");
        assert_eq!(reason(open(&layout, ONE).await), "database file missing");

        // Both objects removed: a first run again, with an empty database.
        fs::remove_file(&layout.marker).expect("remove the marker");
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, true, 1));
        assert_eq!(items(&layout).await, 0);
    });
}

// ---------------------------------------------------------------------------
// Two instances in a first run
// ---------------------------------------------------------------------------

#[test]
fn first_run_is_refused_while_another_instance_holds_the_lock() {
    run(async {
        let root = TempRoot::new("locked");
        let layout = root.layout();
        let held = InitLock::acquire(&layout.lock).expect("the other instance takes the lock");

        let error = reason(open(&layout, ONE).await);
        assert_eq!(error, "another instance is initializing storage");
        assert!(!layout.data_dir.exists());
        assert!(!layout.marker.exists());

        // The lock file stays and means nothing once it is released.
        drop(held);
        assert!(layout.lock.is_file());
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, true, 1));
        assert!(layout.lock.is_file());
    });
}

#[test]
fn state_is_checked_again_after_the_lock_is_taken() {
    run(async {
        let root = TempRoot::new("recheck");
        let layout = root.layout();
        // Between "no marker" and the lock another instance completes the
        // whole first run and stores a row.
        let other = layout.clone();
        let mut settings = Settings::new(ONE);
        settings.before_lock = Some(Arc::new(move || {
            let other = other.clone();
            std::thread::spawn(move || {
                run(async {
                    assert_eq!(session(&other, ONE).await, (Access::ReadWrite, true, 1));
                    insert_item(&other, "theirs").await;
                })
            })
            .join()
            .expect("the other instance");
        }));

        let opened = open_with(&layout, &settings).await.expect("opens");
        // Not a first run any more: nothing is created or applied.
        assert!(!opened.created);
        assert_eq!(opened.applied, 0);
        opened.conn.close().await.expect("close");
        assert_eq!(items(&layout).await, 1);
    });
}

#[test]
fn state_checked_after_the_lock_can_be_a_lost_database() {
    run(async {
        let root = TempRoot::new("recheck-lost");
        let layout = root.layout();
        let marker = layout.marker.clone();
        let mut settings = Settings::new(ONE);
        settings.before_lock = Some(Arc::new(move || {
            fs::write(&marker, b"").expect("marker appears");
        }));
        assert_eq!(
            reason(open_with(&layout, &settings).await),
            "database file missing"
        );
        assert!(!layout.data_dir.exists());
    });
}

#[test]
fn two_simultaneous_first_runs_never_both_fail_and_never_damage_the_database() {
    for round in 0..20 {
        let root = TempRoot::new("race");
        let layout = root.layout();
        let barrier = Arc::new(std::sync::Barrier::new(2));
        let runs: Vec<_> = (0..2)
            .map(|_| {
                let layout = layout.clone();
                let barrier = Arc::clone(&barrier);
                std::thread::spawn(move || {
                    run(async {
                        barrier.wait();
                        match open(&layout, TWO).await {
                            Ok(opened) => {
                                opened.conn.close().await.expect("close");
                                None
                            }
                            Err(error) => Some(error.to_string()),
                        }
                    })
                })
            })
            .collect();
        let failures: Vec<String> = runs
            .into_iter()
            .filter_map(|run| run.join().expect("instance"))
            .collect();
        assert!(
            failures.len() < 2,
            "round {round}: both failed: {failures:?}"
        );
        for failure in &failures {
            assert_eq!(failure, "another instance is initializing storage");
        }
        run(async {
            assert!(layout.marker.is_file());
            assert_eq!(session(&layout, TWO).await, (Access::ReadWrite, false, 0));
            let mut conn = raw(&layout).await;
            assert_eq!(applied_versions(&mut conn).await, vec![1, 2]);
            conn.close().await.expect("close");
        });
    }
}

#[test]
fn normal_run_does_not_depend_on_the_lock_file() {
    run(async {
        let root = TempRoot::new("normal-lock");
        let layout = root.layout();
        session(&layout, ONE).await;
        // Held by someone else: a normal run does not take the lock.
        let _held = InitLock::acquire(&layout.lock).expect("lock");
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, false, 0));
        // Absent: nothing recreates it.
        drop(_held);
        fs::remove_file(&layout.lock).expect("remove the lock file");
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, false, 0));
        assert!(!layout.lock.exists());
    });
}

const HOLDER_ROOT: &str = "ATLAS_STORAGE_TEST_LOCK_HOLDER";

/// Not a test of its own: the child process of
/// `lock_is_released_when_its_holder_is_killed`. It begins a first run —
/// takes the lock, creates the data directory — and then hangs.
#[test]
#[ignore = "helper process, started by another test"]
fn helper_holds_the_first_run_lock() {
    let Some(root) = std::env::var_os(HOLDER_ROOT) else {
        return;
    };
    let layout = Layout::new(PathBuf::from(root));
    let _held = InitLock::acquire(&layout.lock).expect("lock");
    fs::create_dir(&layout.data_dir).expect("data directory");
    fs::write(layout.root.join("holder.ready"), b"").expect("ready");
    std::thread::sleep(Duration::from_secs(120));
}

#[test]
fn lock_is_released_when_its_holder_is_killed() {
    let root = TempRoot::new("crash");
    let layout = root.layout();
    let mut holder = std::process::Command::new(std::env::current_exe().expect("test binary"))
        .args([
            "--ignored",
            "--exact",
            "storage::tests::helper_holds_the_first_run_lock",
        ])
        .env(HOLDER_ROOT, root.path())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .expect("start the holder");
    let ready = root.path().join("holder.ready");
    let started = std::time::Instant::now();
    while !ready.exists() {
        assert!(
            started.elapsed() < Duration::from_secs(60),
            "the holder did not start"
        );
        assert!(
            holder.try_wait().expect("holder status").is_none(),
            "the holder exited early"
        );
        std::thread::sleep(Duration::from_millis(20));
    }

    run(async {
        // Another process is in its first run: refused, nothing touched.
        let error = reason(open(&layout, ONE).await);
        assert_eq!(error, "another instance is initializing storage");
        assert!(!layout.database.exists());
    });

    holder.kill().expect("kill the holder");
    holder.wait().expect("reap the holder");

    run(async {
        // The interrupted first run (data directory, no database, no
        // marker) is continued by the next start.
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, true, 1));
        assert!(layout.marker.is_file());
    });
}

const INSTANCE_ROLE: &str = "ATLAS_STORAGE_TEST_INSTANCE_ROLE";
const INSTANCE_ROOT: &str = "ATLAS_STORAGE_TEST_INSTANCE_ROOT";
/// The prefix of the lines the test processes exchange over pipes.
const SAYS: &str = "ATLAS-TEST ";

/// Not a test of its own: one ATLAS instance as a separate process, driven by
/// `two_processes_contend_for_the_first_run` over its standard input and
/// output. No step depends on timing.
///
/// - role `hold`: begins a first run (takes the lock, creates the data
///   directory), says `holding`, waits for a line, releases the lock without
///   finishing, says `released` and stays alive until its input is closed —
///   so the lock is seen to be released by the process, not by its exit;
/// - role `session`: opens the storage, reads when told and then ends as
///   told (`process_end_with_an_attached_wal_copies_nothing_into_the_database`);
/// - role `open`: opens the storage as a start of the application does and
///   says what came of it.
#[test]
#[ignore = "helper process, started by another test"]
fn helper_instance_process() {
    use std::io::{BufRead, Write};
    let (Some(role), Some(root)) = (
        std::env::var_os(INSTANCE_ROLE),
        std::env::var_os(INSTANCE_ROOT),
    ) else {
        return;
    };
    let layout = Layout::new(PathBuf::from(root));
    let say = |text: &str| {
        let mut out = std::io::stdout().lock();
        writeln!(out, "{SAYS}{text}").expect("say");
        out.flush().expect("flush");
    };
    if role == "hold" {
        fs::create_dir_all(&layout.root).expect("root");
        let held = InitLock::acquire(&layout.lock).expect("lock");
        match fs::create_dir(&layout.data_dir) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => panic!("data directory: {error}"),
        }
        say("holding");
        let mut lines = std::io::stdin().lock().lines();
        let line = lines.next().expect("a line").expect("read");
        assert_eq!(line, "release");
        drop(held);
        say("released");
        // Stays alive until the input is closed.
        for line in lines {
            line.expect("read");
        }
    } else if role == "session" {
        // A session of the storage that is told what to do with its
        // connection: `read`, then `close`, `drop` or `exit`.
        run(async {
            let mut opened = open(&layout, ONE).await.expect("opens");
            say(&format!(
                "opened mode={}",
                journal_mode(&mut opened.conn).await
            ));
            let mut lines = std::io::stdin().lock().lines();
            assert_eq!(lines.next().expect("a line").expect("read"), "read");
            let planted = count(
                &mut opened.conn,
                "SELECT count(*) FROM sqlite_master WHERE name = 'planted'",
            )
            .await;
            say(&format!(
                "read planted={planted} mode={}",
                journal_mode(&mut opened.conn).await
            ));
            match lines.next().expect("a line").expect("read").as_str() {
                "close" => opened.conn.close().await.expect("close"),
                "drop" => drop(opened),
                // As the application ends: no destructor runs.
                "exit" => std::process::exit(0),
                other => panic!("unknown command {other}"),
            }
            say("done");
            for line in lines {
                line.expect("read");
            }
        });
    } else {
        run(async {
            match open(&layout, ONE).await {
                Ok(opened) => {
                    say(&format!(
                        "opened created={} applied={}",
                        opened.created, opened.applied
                    ));
                    opened.conn.close().await.expect("close");
                }
                Err(error) => say(&format!("refused {error}")),
            }
        });
    }
}

/// A running helper process and the pipes to it.
struct Instance {
    child: std::process::Child,
    input: Option<std::process::ChildStdin>,
    output: std::io::BufReader<std::process::ChildStdout>,
}

impl Instance {
    fn start(role: &str, root: &Path) -> Self {
        use std::process::Stdio;
        let mut child = std::process::Command::new(std::env::current_exe().expect("test binary"))
            .args([
                "--ignored",
                "--exact",
                "--nocapture",
                "storage::tests::helper_instance_process",
            ])
            .env(INSTANCE_ROLE, role)
            .env(INSTANCE_ROOT, root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("start the instance");
        Self {
            input: child.stdin.take(),
            output: std::io::BufReader::new(child.stdout.take().expect("stdout")),
            child,
        }
    }

    /// Blocks until the process says something; its end before that is a
    /// failure.
    fn hears(&mut self) -> String {
        use std::io::BufRead;
        loop {
            let mut line = String::new();
            let read = self.output.read_line(&mut line).expect("read the instance");
            assert!(read > 0, "the instance ended without an answer");
            if let Some(said) = line.trim_end().strip_prefix(SAYS) {
                return said.to_owned();
            }
        }
    }

    fn tell(&mut self, line: &str) {
        use std::io::Write;
        let input = self.input.as_mut().expect("input is open");
        writeln!(input, "{line}").expect("tell the instance");
        input.flush().expect("flush");
    }

    /// Closes the input and waits for a normal end.
    fn finish(mut self) {
        drop(self.input.take());
        assert!(self.child.wait().expect("wait").success());
    }

    fn kill(mut self) {
        self.child.kill().expect("kill");
        self.child.wait().expect("reap");
    }
}

/// What a separate `open` process reports.
fn start_of_another_process(root: &Path) -> String {
    let mut instance = Instance::start("open", root);
    let said = instance.hears();
    instance.finish();
    said
}

#[test]
fn two_processes_contend_for_the_first_run() {
    let root = TempRoot::new("processes");
    let layout = root.layout();

    // A takes the lock and holds it until told otherwise.
    let mut a = Instance::start("hold", root.path());
    assert_eq!(a.hears(), "holding");

    // B, another process, is refused and touches nothing.
    assert_eq!(
        start_of_another_process(root.path()),
        "refused another instance is initializing storage"
    );
    assert!(!layout.database.exists());
    assert!(!layout.marker.exists());

    // A releases the lock and is still running.
    a.tell("release");
    assert_eq!(a.hears(), "released");
    assert!(a.child.try_wait().expect("status").is_none());

    // A new process continues the unfinished first run…
    assert_eq!(
        start_of_another_process(root.path()),
        "opened created=true applied=1"
    );
    assert!(layout.marker.is_file());
    a.finish();

    // …and with the marker in place a start does not care about the lock,
    // even while another process holds it.
    let mut held = Instance::start("hold", root.path());
    assert_eq!(held.hears(), "holding");
    assert_eq!(
        start_of_another_process(root.path()),
        "opened created=false applied=0"
    );
    held.kill();
}

#[test]
fn killed_first_run_is_continued_by_another_process() {
    let root = TempRoot::new("processes-crash");
    let layout = root.layout();
    let mut a = Instance::start("hold", root.path());
    assert_eq!(a.hears(), "holding");
    assert_eq!(
        start_of_another_process(root.path()),
        "refused another instance is initializing storage"
    );

    // The owner of the lock dies without releasing it: the system does.
    a.kill();
    assert!(layout.data_dir.is_dir());
    assert!(!layout.database.exists());
    assert_eq!(
        start_of_another_process(root.path()),
        "opened created=true applied=1"
    );
    assert!(layout.marker.is_file());
    // The next start is a normal one.
    assert_eq!(
        start_of_another_process(root.path()),
        "opened created=false applied=0"
    );
}

// ---------------------------------------------------------------------------
// WAL files next to the database and the journal mode
// ---------------------------------------------------------------------------

/// Every file of the data directory, byte for byte.
fn data_files(layout: &Layout) -> Vec<(String, Vec<u8>)> {
    let mut files: Vec<(String, Vec<u8>)> = fs::read_dir(&layout.data_dir)
        .expect("data directory")
        .map(|entry| entry.expect("entry"))
        .map(|entry| {
            (
                entry.file_name().to_string_lossy().into_owned(),
                fs::read(entry.path()).expect("file"),
            )
        })
        .collect();
    files.sort();
    files
}

async fn journal_mode(conn: &mut SqliteConnection) -> String {
    sqlx::query_scalar("PRAGMA journal_mode")
        .fetch_one(conn)
        .await
        .expect("journal mode")
}

/// Real WAL files with a committed change: a copy of the database is
/// switched to WAL elsewhere and given a table `planted`. Returns the `-wal`
/// and the `-shm` file as they are while that change is only in the WAL.
async fn real_wal_for(layout: &Layout, elsewhere: &Path) -> (Vec<u8>, Vec<u8>) {
    let copy = elsewhere.join("copy.db");
    fs::copy(&layout.database, &copy).expect("copy the database");
    let mut conn = SqliteConnectOptions::new()
        .filename(&copy)
        .connect()
        .await
        .expect("copy opens");
    assert_eq!(
        sqlx::query_scalar::<_, String>("PRAGMA journal_mode = wal")
            .fetch_one(&mut conn)
            .await
            .expect("switch to wal"),
        "wal"
    );
    sqlx::query("CREATE TABLE planted (id INTEGER PRIMARY KEY)")
        .execute(&mut conn)
        .await
        .expect("change in the wal");
    let wal = fs::read(elsewhere.join(format!("copy.db{WAL_SUFFIX}"))).expect("wal file");
    let shm = fs::read(elsewhere.join(format!("copy.db{SHM_SUFFIX}"))).expect("shm file");
    assert!(wal.len() > 32);
    conn.close().await.expect("close");
    (wal, shm)
}

/// Whether the database file, taken alone, has the table `planted`: a copy
/// of the file without anything next to it is opened elsewhere.
async fn database_alone_has_planted(layout: &Layout) -> bool {
    let elsewhere = TempRoot::new("alone");
    let copy = elsewhere.path().join("alone.db");
    fs::copy(&layout.database, &copy).expect("copy the database");
    let mut conn = SqliteConnectOptions::new()
        .filename(&copy)
        .connect()
        .await
        .expect("copy opens");
    let found = count(
        &mut conn,
        "SELECT count(*) FROM sqlite_master WHERE name = 'planted'",
    )
    .await;
    conn.close().await.expect("close");
    found == 1
}

/// `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` of an open connection, read from SQLite
/// itself (a negative argument asks without changing).
async fn no_checkpoint_on_close(conn: &mut SqliteConnection) -> i32 {
    let mut handle = conn.lock_handle().await.expect("handle");
    let mut value: std::ffi::c_int = -1;
    // SAFETY: the handle is a live `sqlite3*`, locked for this call; the
    // verb takes an `int` and an `int*`, as passed.
    let status = unsafe {
        libsqlite3_sys::sqlite3_db_config(
            handle.as_raw_handle().as_ptr(),
            libsqlite3_sys::SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE,
            -1 as std::ffi::c_int,
            &mut value as *mut std::ffi::c_int,
        )
    };
    assert_eq!(status, libsqlite3_sys::SQLITE_OK);
    value
}

/// RUSTSEC-2026-0459 is fixed in SQLite 3.54.0. The build gets a fixed SQLite
/// only through the local fork of `sqlx-sqlite` (`vendor/sqlx-sqlite`): if the
/// `[patch]` is lost, this fails.
#[test]
fn bundled_sqlite_is_a_fixed_version() {
    run(async {
        let root = TempRoot::new("sqlite-version");
        let opened = open(&root.layout(), NONE).await.expect("opens");
        let version: Vec<u32> = opened
            .sqlite_version
            .split('.')
            .map(|part| part.parse().expect("a number"))
            .collect();
        assert!(
            version >= vec![3, 54, 0],
            "SQLite {} is affected by RUSTSEC-2026-0459",
            opened.sqlite_version
        );
        opened.conn.close().await.expect("close");
    });
}

#[test]
fn layout_names_the_wal_files_of_the_database() {
    let layout = Layout::new(PathBuf::from("root"));
    assert_eq!(
        layout.wal,
        Path::new("root").join("data").join("atlas.db-wal")
    );
    assert_eq!(
        layout.shm,
        Path::new("root").join("data").join("atlas.db-shm")
    );
    assert_eq!(WAL_SUFFIX, "-wal");
    assert_eq!(SHM_SUFFIX, "-shm");
}

#[test]
fn wal_files_next_to_the_database_make_it_unavailable_and_nothing_is_touched() {
    let cases: [(&[&str], &str); 3] = [
        (
            &["atlas.db-wal"],
            "unexpected WAL files next to the database: atlas.db-wal; the database was not opened",
        ),
        (
            &["atlas.db-shm"],
            "unexpected WAL files next to the database: atlas.db-shm; the database was not opened",
        ),
        (
            &["atlas.db-wal", "atlas.db-shm"],
            "unexpected WAL files next to the database: atlas.db-wal, atlas.db-shm; the database was not opened",
        ),
    ];
    for (names, expected) in cases {
        run(async {
            let root = TempRoot::new("wal-files");
            let layout = root.layout();
            session(&layout, ONE).await;
            insert_item(&layout, "kept").await;
            for name in names {
                fs::write(layout.data_dir.join(name), b"not written by ATLAS").expect("plant");
            }
            let before = data_files(&layout);
            assert_eq!(before.len(), 1 + names.len());

            assert_eq!(reason(open(&layout, ONE).await), expected, "{names:?}");
            assert_eq!(data_files(&layout), before, "{names:?}: files changed");

            // The same through the service.
            let storage = Storage::for_test(root.path(), ONE);
            storage.open().await;
            assert_eq!(storage.kind().await, "unavailable");
            storage.close().await;
            assert_eq!(data_files(&layout), before, "{names:?}: files changed");

            // Only the user removes them; then the database opens as it was.
            for name in names {
                fs::remove_file(layout.data_dir.join(name)).expect("remove by hand");
            }
            assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, false, 0));
            assert_eq!(items(&layout).await, 1);
        });
    }
}

#[test]
fn real_wal_file_is_not_read_into_the_database() {
    run(async {
        let root = TempRoot::new("wal-real");
        let elsewhere = TempRoot::new("wal-real-source");
        let layout = root.layout();
        session(&layout, ONE).await;
        insert_item(&layout, "kept").await;
        let (wal, _shm) = real_wal_for(&layout, elsewhere.path()).await;
        fs::write(&layout.wal, &wal).expect("plant the wal");
        let before = data_files(&layout);

        assert_eq!(
            reason(open(&layout, ONE).await),
            "unexpected WAL files next to the database: atlas.db-wal; the database was not opened"
        );
        // SQLite was never given the file: the database and the WAL are as
        // they were, and the change in the WAL is not in the database.
        assert_eq!(data_files(&layout), before);
        fs::remove_file(&layout.wal).expect("remove by hand");
        let mut conn = raw(&layout).await;
        assert_eq!(
            count(
                &mut conn,
                "SELECT count(*) FROM sqlite_master WHERE name = 'planted'"
            )
            .await,
            0
        );
        assert_eq!(journal_mode(&mut conn).await, "delete");
        conn.close().await.expect("close");
    });
}

#[test]
fn stray_wal_files_stop_a_first_run_too() {
    for name in ["atlas.db-wal", "atlas.db-shm"] {
        run(async {
            let root = TempRoot::new("wal-first-run");
            let layout = root.layout();
            fs::create_dir(&layout.data_dir).expect("data directory");
            fs::write(layout.data_dir.join(name), b"stray").expect("plant");
            let before = data_files(&layout);

            let error = reason(open(&layout, ONE).await);
            assert!(error.starts_with("unexpected WAL files"), "{error}");
            assert_eq!(data_files(&layout), before);
            assert!(!layout.database.exists());
            assert!(!layout.marker.exists());
        });
    }
}

#[test]
fn first_and_later_runs_use_the_rollback_journal_and_leave_no_wal_files() {
    run(async {
        let root = TempRoot::new("journal-mode");
        let layout = root.layout();
        for (created, applied) in [(true, 2), (false, 0), (false, 0)] {
            let mut opened = open(&layout, TWO).await.expect("opens");
            assert_eq!((opened.created, opened.applied), (created, applied));
            assert_eq!(opened.access, Access::ReadWrite);
            assert_eq!(journal_mode(&mut opened.conn).await, "delete");
            assert!(!layout.wal.exists());
            assert!(!layout.shm.exists());
            opened.conn.close().await.expect("close");
            assert_eq!(
                data_files(&layout)
                    .into_iter()
                    .map(|(name, _)| name)
                    .collect::<Vec<_>>(),
                vec!["atlas.db"]
            );
        }
    });
}

#[test]
fn database_in_wal_mode_is_unavailable_and_is_not_switched_back() {
    run(async {
        let root = TempRoot::new("wal-header");
        let layout = root.layout();
        session(&layout, ONE).await;
        insert_item(&layout, "kept").await;
        // Another program switched the database to WAL and closed it cleanly:
        // the mode is in the header of the file, nothing lies next to it.
        let mut conn = raw(&layout).await;
        assert_eq!(
            sqlx::query_scalar::<_, String>("PRAGMA journal_mode = wal")
                .fetch_one(&mut conn)
                .await
                .expect("switch to wal"),
            "wal"
        );
        conn.close().await.expect("close");
        assert!(!layout.wal.exists());
        assert!(!layout.shm.exists());
        let before = fs::read(&layout.database).expect("database");

        assert_eq!(
            reason(open(&layout, ONE).await),
            "step=journal-mode mode=wal expected=delete"
        );
        // Not migrated, not probed, not switched back.
        assert_eq!(fs::read(&layout.database).expect("database"), before);
        // Reading a database in WAL mode made SQLite create its two files;
        // the close did not checkpoint, so it did not remove them either. The
        // WAL is empty: nothing was written.
        assert_eq!(fs::read(&layout.wal).expect("wal").len(), 0);
        assert!(layout.shm.is_file());

        // The next start stops even earlier, at the files.
        let storage = Storage::for_test(root.path(), ONE);
        storage.open().await;
        assert_eq!(storage.kind().await, "unavailable");
        storage.close().await;
        assert!(
            reason(open(&layout, ONE).await).starts_with("unexpected WAL files"),
            "the files stop the next start"
        );
        assert_eq!(fs::read(&layout.database).expect("database"), before);

        let mut conn = raw(&layout).await;
        assert_eq!(journal_mode(&mut conn).await, "wal");
        assert_eq!(count(&mut conn, "SELECT count(*) FROM items").await, 1);
        conn.close().await.expect("close");
    });
}

// ---------------------------------------------------------------------------
// No checkpoint on close (N-1): a WAL that got attached is never copied into
// the database by ATLAS
// ---------------------------------------------------------------------------

/// Plants files into the data directory when called: the other process of a
/// race.
fn planter(files: Vec<(PathBuf, Vec<u8>)>) -> Arc<dyn Fn() + Send + Sync> {
    Arc::new(move || {
        for (path, bytes) in &files {
            fs::write(path, bytes).expect("plant");
        }
    })
}

#[test]
fn every_connection_is_opened_without_checkpoint_on_close() {
    run(async {
        let root = TempRoot::new("no-ckpt-flag");
        let layout = root.layout();
        // The connection of the storage: first run and a later run.
        for _ in 0..2 {
            let mut opened = open(&layout, ONE).await.expect("opens");
            assert_eq!(no_checkpoint_on_close(&mut opened.conn).await, 1);
            assert_eq!(
                count(&mut opened.conn, "PRAGMA wal_autocheckpoint").await,
                0
            );
            assert_eq!(count(&mut opened.conn, "PRAGMA synchronous").await, 2);
            assert_eq!(count(&mut opened.conn, "PRAGMA foreign_keys").await, 1);
            assert_eq!(journal_mode(&mut opened.conn).await, "delete");
            opened.conn.close().await.expect("close");
        }
        // A read-only handle too.
        let mut read_only = Settings::new(ONE);
        read_only.read_only_handle = true;
        let mut opened = open_with(&layout, &read_only).await.expect("opens");
        assert!(matches!(opened.access, Access::ReadOnly { .. }));
        assert_eq!(no_checkpoint_on_close(&mut opened.conn).await, 1);
        opened.conn.close().await.expect("close");
        // And any other connection made through the fork: the flag is set at
        // `sqlite3_open_v2`, not asked for by the caller.
        let mut conn = raw(&layout).await;
        assert_eq!(no_checkpoint_on_close(&mut conn).await, 1);
        conn.close().await.expect("close");
    });
}

#[test]
fn closing_a_connection_in_wal_mode_copies_nothing_into_the_database() {
    run(async {
        // The flag at work, on SQLite itself: a database in WAL mode with a
        // committed change is closed and dropped, and the change stays in the
        // WAL file.
        for by_drop in [false, true] {
            let root = TempRoot::new("no-ckpt-close");
            let layout = root.layout();
            session(&layout, ONE).await;
            let mut conn = raw(&layout).await;
            assert_eq!(
                sqlx::query_scalar::<_, String>("PRAGMA journal_mode = wal")
                    .fetch_one(&mut conn)
                    .await
                    .expect("switch to wal"),
                "wal"
            );
            sqlx::query("CREATE TABLE planted (id INTEGER PRIMARY KEY)")
                .execute(&mut conn)
                .await
                .expect("change in the wal");
            let database = fs::read(&layout.database).expect("database");
            let wal = fs::read(&layout.wal).expect("wal");
            if by_drop {
                drop(conn);
                // The handle is closed on the connection's thread; another
                // connection to the same file is the evidence that follows.
            } else {
                conn.close().await.expect("close");
            }
            assert_eq!(fs::read(&layout.database).expect("database"), database);
            assert_eq!(fs::read(&layout.wal).expect("wal"), wal);
            assert!(!database_alone_has_planted(&layout).await);
        }
    });
}

#[test]
fn wal_slipped_in_before_the_opening_is_not_copied_into_the_database() {
    for with_shm in [false, true] {
        run(async {
            let root = TempRoot::new("wal-race");
            let elsewhere = TempRoot::new("wal-race-source");
            let layout = root.layout();
            session(&layout, ONE).await;
            insert_item(&layout, "kept").await;
            let (wal, shm) = real_wal_for(&layout, elsewhere.path()).await;
            let database = fs::read(&layout.database).expect("database");

            // The files appear after the check for them and before SQLite
            // opens the database.
            let mut files = vec![(layout.wal.clone(), wal.clone())];
            if with_shm {
                files.push((layout.shm.clone(), shm));
            }
            let mut settings = Settings::new(ONE);
            settings.before_connect = Some(planter(files.clone()));

            // SQLite attached the WAL: the opening stops at the journal mode,
            // before the probe and the migrations.
            assert_eq!(
                reason(open_with(&layout, &settings).await),
                "step=journal-mode mode=wal expected=delete",
                "with_shm={with_shm}"
            );
            // The connection was closed, and nothing was copied: the database
            // file and the WAL file are byte for byte what they were.
            assert_eq!(fs::read(&layout.database).expect("database"), database);
            assert_eq!(fs::read(&layout.wal).expect("wal"), wal);
            assert!(!database_alone_has_planted(&layout).await);
            // Not kept as it was: SQLite creates or rebuilds the `-shm` file
            // when it attaches a WAL. Only its presence is promised.
            assert!(layout.shm.is_file());

            // The same through the service, on a fresh copy of the situation.
            let root = TempRoot::new("wal-race-service");
            let layout = root.layout();
            session(&layout, ONE).await;
            insert_item(&layout, "kept").await;
            let database = fs::read(&layout.database).expect("database");
            let mut settings = Settings::new(ONE);
            let files = files
                .into_iter()
                .map(|(path, bytes)| {
                    let name = path.file_name().expect("name").to_owned();
                    (layout.data_dir.join(name), bytes)
                })
                .collect();
            settings.before_connect = Some(planter(files));
            let storage = Storage::with_settings(Ok(root.path().to_path_buf()), settings);
            storage.open().await;
            assert_eq!(storage.kind().await, "unavailable");
            storage.close_within(Duration::from_secs(30)).await;
            assert_eq!(storage.kind().await, "closed");
            assert_eq!(fs::read(&layout.database).expect("database"), database);
            assert_eq!(fs::read(&layout.wal).expect("wal"), wal);

            // The next start refuses at the files; once the user has removed
            // them the database opens with what it had.
            assert!(reason(open(&layout, ONE).await).starts_with("unexpected WAL files"));
            assert_eq!(fs::read(&layout.database).expect("database"), database);
            fs::remove_file(&layout.wal).expect("remove by hand");
            fs::remove_file(&layout.shm).expect("remove by hand");
            assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, false, 0));
            assert_eq!(items(&layout).await, 1);
            assert!(!database_alone_has_planted(&layout).await);
        });
    }
}

#[test]
fn wal_slipped_in_before_the_last_check_stops_the_opening() {
    run(async {
        let root = TempRoot::new("wal-final-check");
        let elsewhere = TempRoot::new("wal-final-check-source");
        let layout = root.layout();
        session(&layout, ONE).await;
        let (wal, _shm) = real_wal_for(&layout, elsewhere.path()).await;
        let database = fs::read(&layout.database).expect("database");

        let mut settings = Settings::new(ONE);
        settings.before_final_check = Some(planter(vec![(layout.wal.clone(), wal.clone())]));
        assert_eq!(
            reason(open_with(&layout, &settings).await),
            "step=journal-mode-final mode=wal expected=delete"
        );
        assert_eq!(fs::read(&layout.database).expect("database"), database);
        assert_eq!(fs::read(&layout.wal).expect("wal"), wal);
        assert!(!database_alone_has_planted(&layout).await);
    });
}

/// Scenario A. Guards against a write probe that runs in WAL mode: the file
/// appears after the first check of the journal mode, the probe attaches it
/// when its transaction starts, and must stop before writing.
#[test]
fn wal_slipped_in_before_the_write_probe_is_refused_inside_its_transaction() {
    run(async {
        let root = TempRoot::new("wal-before-probe");
        let elsewhere = TempRoot::new("wal-before-probe-source");
        let layout = root.layout();
        session(&layout, ONE).await;
        insert_item(&layout, "kept").await;
        let (wal, _shm) = real_wal_for(&layout, elsewhere.path()).await;
        let database = fs::read(&layout.database).expect("database");

        let mut settings = Settings::new(ONE);
        settings.before_probe = Some(planter(vec![(layout.wal.clone(), wal.clone())]));
        assert_eq!(
            reason(open_with(&layout, &settings).await),
            "step=probe-journal-mode mode=wal expected=delete"
        );
        assert_eq!(fs::read(&layout.database).expect("database"), database);
        assert_eq!(fs::read(&layout.wal).expect("wal"), wal);
        assert!(!database_alone_has_planted(&layout).await);
        // Not promised to stay away: SQLite creates it when it attaches a WAL.
        assert!(layout.shm.is_file());

        // Through the service: unavailable (a fresh copy of the situation).
        let root = TempRoot::new("wal-before-probe-service");
        let layout = root.layout();
        session(&layout, ONE).await;
        let mut settings = Settings::new(ONE);
        settings.before_probe = Some(planter(vec![(layout.wal.clone(), wal.clone())]));
        let storage = Storage::with_settings(Ok(root.path().to_path_buf()), settings);
        storage.open().await;
        assert_eq!(storage.kind().await, "unavailable");
        storage.close().await;
        assert_eq!(fs::read(&layout.wal).expect("wal"), wal);
    });
}

/// Scenario B. Guards against migrations written into a foreign WAL: the
/// file appears after the write probe, a migration is waiting, and without
/// the check inside the transaction sqlx would commit it into that file.
#[test]
fn wal_slipped_in_before_the_migrations_is_refused_and_nothing_is_migrated() {
    run(async {
        let root = TempRoot::new("wal-before-migrations");
        let elsewhere = TempRoot::new("wal-before-migrations-source");
        let layout = root.layout();
        session(&layout, ONE).await;
        let (wal, _shm) = real_wal_for(&layout, elsewhere.path()).await;
        let database = fs::read(&layout.database).expect("database");

        // The second migration has not been applied yet.
        let mut settings = Settings::new(TWO);
        settings.before_migrations = Some(planter(vec![(layout.wal.clone(), wal.clone())]));
        assert_eq!(
            reason(open_with(&layout, &settings).await),
            "step=migrations-journal-mode mode=wal expected=delete"
        );
        // Neither file received the migration.
        assert_eq!(fs::read(&layout.database).expect("database"), database);
        assert_eq!(fs::read(&layout.wal).expect("wal"), wal);

        // Once the user has removed the files: the migration is still to be
        // applied, and it is.
        fs::remove_file(&layout.wal).expect("remove by hand");
        fs::remove_file(&layout.shm).expect("remove by hand");
        let mut conn = raw(&layout).await;
        assert_eq!(applied_versions(&mut conn).await, vec![1]);
        conn.close().await.expect("close");
        assert_eq!(session(&layout, TWO).await, (Access::ReadWrite, false, 1));
        assert!(!database_alone_has_planted(&layout).await);
    });
}

/// Scenario C, a known limit kept visible. A `-wal` file that appears while
/// the transaction of the migrations is already open is not noticed by that
/// transaction: SQLite settled its journal mode at its first read. What
/// holds: ATLAS writes nothing into the foreign file — the migrations go into
/// the database through the rollback journal. What does not: the foreign file
/// now lies beside a database it no longer matches, SQLite creates `-shm`
/// when the next transaction attaches it, and the opening then stops at the
/// last check — with the migrations committed.
#[test]
fn known_limit_wal_appearing_inside_the_migration_transaction() {
    run(async {
        let root = TempRoot::new("wal-inside-migrations");
        let elsewhere = TempRoot::new("wal-inside-migrations-source");
        let layout = root.layout();
        session(&layout, ONE).await;
        let (wal, _shm) = real_wal_for(&layout, elsewhere.path()).await;
        let database = fs::read(&layout.database).expect("database");

        let mut settings = Settings::new(TWO);
        settings.inside_migrations = Some(planter(vec![(layout.wal.clone(), wal.clone())]));
        assert_eq!(
            reason(open_with(&layout, &settings).await),
            "step=journal-mode-final mode=wal expected=delete"
        );

        // The foreign WAL: byte for byte what was planted.
        assert_eq!(fs::read(&layout.wal).expect("wal"), wal);
        // The database: changed, by the migration alone.
        assert_ne!(fs::read(&layout.database).expect("database"), database);
        assert!(!database_alone_has_planted(&layout).await);
        // `-shm`: created by SQLite when the last check attached the WAL.
        assert!(layout.shm.is_file());

        // With the files removed by hand the database is the migrated one.
        fs::remove_file(&layout.wal).expect("remove by hand");
        fs::remove_file(&layout.shm).expect("remove by hand");
        let mut conn = raw(&layout).await;
        assert_eq!(applied_versions(&mut conn).await, vec![1, 2]);
        conn.close().await.expect("close");
        assert_eq!(session(&layout, TWO).await, (Access::ReadWrite, false, 0));
    });
}

/// Scenario G. Guards the read-only branch: it writes nothing, and it does
/// not read the migration records around the check of the journal mode — a
/// WAL that appears before its transaction stops it like any other.
#[test]
fn read_only_branch_checks_the_journal_mode_inside_its_transactions() {
    run(async {
        for (step, expected) in [
            ("probe", "step=probe-journal-mode mode=wal expected=delete"),
            (
                "migrations",
                "step=migrations-journal-mode mode=wal expected=delete",
            ),
        ] {
            let root = TempRoot::new("wal-read-only");
            let elsewhere = TempRoot::new("wal-read-only-source");
            let layout = root.layout();
            session(&layout, ONE).await;
            let (wal, _shm) = real_wal_for(&layout, elsewhere.path()).await;
            let database = fs::read(&layout.database).expect("database");

            // Without a WAL: read-only, and nothing is written.
            let mut settings = Settings::new(ONE);
            settings.read_only_handle = true;
            let opened = open_with(&layout, &settings).await.expect("opens");
            assert!(matches!(opened.access, Access::ReadOnly { .. }), "{step}");
            opened.conn.close().await.expect("close");
            assert_eq!(fs::read(&layout.database).expect("database"), database);

            // With a WAL appearing before the transaction of that step.
            let plant = planter(vec![(layout.wal.clone(), wal.clone())]);
            let mut settings = Settings::new(ONE);
            settings.read_only_handle = true;
            if step == "probe" {
                settings.before_probe = Some(plant);
            } else {
                settings.before_migrations = Some(plant);
            }
            assert_eq!(
                reason(open_with(&layout, &settings).await),
                expected,
                "{step}"
            );
            assert_eq!(fs::read(&layout.database).expect("database"), database);
            assert_eq!(fs::read(&layout.wal).expect("wal"), wal);
        }
    });
}

/// Known limit, kept visible: on a first run the database is still empty when
/// SQLite first reads it, and SQLite itself deletes a `-wal` file it finds
/// then. Nothing of it reaches the database, but the file is gone.
#[test]
fn known_limit_sqlite_deletes_a_wal_slipped_into_a_first_run() {
    run(async {
        let root = TempRoot::new("wal-first-run-race");
        let elsewhere = TempRoot::new("wal-first-run-race-source");
        let layout = root.layout();
        // A WAL made for some other database.
        let other = elsewhere.layout();
        session(&other, ONE).await;
        let (wal, _shm) = real_wal_for(&other, elsewhere.path()).await;

        let mut settings = Settings::new(ONE);
        settings.before_connect = Some(planter(vec![(layout.wal.clone(), wal)]));
        let mut opened = open_with(&layout, &settings).await.expect("first run");
        assert!(opened.created);
        assert_eq!(opened.applied, 1);
        assert_eq!(journal_mode(&mut opened.conn).await, "delete");
        assert!(!layout.wal.exists(), "SQLite deleted the stray WAL");
        assert_eq!(
            count(
                &mut opened.conn,
                "SELECT count(*) FROM sqlite_master WHERE name = 'planted'"
            )
            .await,
            0
        );
        opened.conn.close().await.expect("close");
    });
}

/// Known limit, kept visible: a `-wal` file that appears while the session
/// runs is attached by the next read, which sees its content. What holds even
/// then: closing the connection copies nothing into the database file.
#[test]
fn known_limit_wal_appearing_mid_session_is_read_but_never_copied_into_the_database() {
    run(async {
        let root = TempRoot::new("wal-mid-session");
        let elsewhere = TempRoot::new("wal-mid-session-source");
        let layout = root.layout();
        session(&layout, ONE).await;
        let (wal, _shm) = real_wal_for(&layout, elsewhere.path()).await;
        let database = fs::read(&layout.database).expect("database");

        let mut opened = open(&layout, ONE).await.expect("opens");
        assert_eq!(journal_mode(&mut opened.conn).await, "delete");
        fs::write(&layout.wal, &wal).expect("plant mid-session");

        // Not prevented: the connection now reads the foreign content.
        assert_eq!(
            count(
                &mut opened.conn,
                "SELECT count(*) FROM sqlite_master WHERE name = 'planted'"
            )
            .await,
            1
        );
        // The check a reader has to make before a transaction (MM-5B).
        assert_eq!(journal_mode(&mut opened.conn).await, "wal");

        opened.conn.close().await.expect("close");
        assert_eq!(fs::read(&layout.database).expect("database"), database);
        assert_eq!(fs::read(&layout.wal).expect("wal"), wal);
        assert!(!database_alone_has_planted(&layout).await);
    });
}

/// How a session that attached a foreign WAL can end, each in a process of
/// its own: the connection is dropped, the process exits with the connection
/// open (what `std::process::exit` does to the application), the process is
/// killed. In none of them does the database file change.
#[test]
fn process_end_with_an_attached_wal_copies_nothing_into_the_database() {
    for end in ["close", "drop", "exit", "kill"] {
        let root = TempRoot::new("wal-process-end");
        let elsewhere = TempRoot::new("wal-process-end-source");
        let layout = root.layout();
        let wal = run(async {
            session(&layout, ONE).await;
            real_wal_for(&layout, elsewhere.path()).await.0
        });
        let database = fs::read(&layout.database).expect("database");

        let mut instance = Instance::start("session", root.path());
        assert_eq!(instance.hears(), "opened mode=delete", "{end}");
        fs::write(&layout.wal, &wal).expect("plant mid-session");
        instance.tell("read");
        assert_eq!(instance.hears(), "read planted=1 mode=wal", "{end}");
        match end {
            "kill" => instance.kill(),
            "exit" => {
                instance.tell("exit");
                drop(instance.input.take());
                assert!(instance.child.wait().expect("wait").success());
            }
            _ => {
                instance.tell(end);
                assert_eq!(instance.hears(), "done", "{end}");
                instance.finish();
            }
        }

        assert_eq!(
            fs::read(&layout.database).expect("database"),
            database,
            "{end}"
        );
        assert_eq!(fs::read(&layout.wal).expect("wal"), wal, "{end}");
        assert!(!run(database_alone_has_planted(&layout)), "{end}");
    }
}

// ---------------------------------------------------------------------------
// Read-only and the classification of errors
// ---------------------------------------------------------------------------

fn failed(code: Option<i32>) -> Result<(), Failure> {
    Err(Failure {
        code,
        message: "text".to_owned(),
    })
}

#[test]
fn only_codes_8_and_1544_with_a_clean_rollback_mean_read_only() {
    assert_eq!(classify_probe(Ok(()), Ok(())), Verdict::Writable);
    assert_eq!(
        classify_probe(failed(Some(8)), Ok(())),
        Verdict::ReadOnly(8)
    );
    assert_eq!(
        classify_probe(failed(Some(1544)), Ok(())),
        Verdict::ReadOnly(1544)
    );

    let unavailable = |write, rollback, expected: &str| match classify_probe(write, rollback) {
        Verdict::Unavailable(reason) => assert_eq!(reason, expected),
        other => panic!("expected unavailable, got {other:?}"),
    };
    // A failed rollback is never read-only, whatever the write said.
    for write in [Ok(()), failed(Some(8)), failed(Some(1544))] {
        unavailable(
            write,
            failed(Some(1)),
            "step=probe-rollback code=1 message=text",
        );
    }
    // BUSY, LOCKED, IOERR and extended I/O codes, CORRUPT, FULL, NOTADB, the
    // other READONLY_* codes (RECOVERY, CANTLOCK, ROLLBACK, DBMOVED,
    // CANTINIT), and an unknown code.
    for code in [
        5, 6, 10, 266, 5898, 11, 13, 26, 264, 520, 776, 1032, 1288, 99999,
    ] {
        for rollback in [Ok(()), failed(Some(1))] {
            unavailable(
                failed(Some(code)),
                rollback,
                &format!("step=probe code={code} message=text"),
            );
        }
    }
    // An error that is not from SQLite.
    unavailable(failed(None), Ok(()), "step=probe error=text");
}

#[test]
fn read_only_handle_gives_read_only_with_the_extended_code() {
    run(async {
        let root = TempRoot::new("ro-handle");
        let layout = root.layout();
        session(&layout, TWO).await;
        insert_item(&layout, "kept").await;

        let mut settings = Settings::new(TWO);
        settings.read_only_handle = true;
        let mut opened = open_with(&layout, &settings).await.expect("opens");
        assert_eq!(opened.access, Access::ReadOnly { code: 8 });
        assert_eq!((opened.applied, opened.latest), (0, 2));
        // Reading works; the data is the real one.
        assert_eq!(
            count(&mut opened.conn, "SELECT count(*) FROM items").await,
            1
        );
        opened.conn.close().await.expect("close");
    });
}

#[test]
fn read_only_database_with_other_migrations_is_unavailable() {
    run(async {
        let root = TempRoot::new("ro-migrations");
        let layout = root.layout();
        session(&layout, ONE).await;
        let read_only = |list| {
            let mut settings = Settings::new(list);
            settings.read_only_handle = true;
            settings
        };
        let before = fs::read(&layout.database).expect("read");

        // Behind the application: the missing migration cannot be applied.
        let error = reason(open_with(&layout, &read_only(TWO)).await);
        assert_eq!(
            error,
            "migrations: the database is read-only and has 1 of 2 migrations"
        );
        // Ahead of the application.
        let error = reason(open_with(&layout, &read_only(NONE)).await);
        assert!(error.contains("newer than the application"), "{error}");
        // A changed migration.
        let error = reason(open_with(&layout, &read_only(EDITED)).await);
        assert!(error.contains("migration 1 was changed"), "{error}");

        assert_eq!(fs::read(&layout.database).expect("read"), before);
    });
}

#[test]
fn read_only_database_without_the_migrations_table_is_unavailable() {
    run(async {
        let root = TempRoot::new("ro-no-table");
        let layout = root.layout();
        fs::create_dir(&layout.data_dir).expect("data directory");
        // A valid, empty SQLite database: no service table.
        fs::write(&layout.database, b"").expect("empty database");
        fs::write(&layout.marker, b"").expect("marker");
        let mut settings = Settings::new(NONE);
        settings.read_only_handle = true;
        let error = reason(open_with(&layout, &settings).await);
        assert_eq!(
            error,
            "migrations: the migrations table is missing and the database is read-only"
        );
        assert_eq!(fs::metadata(&layout.database).expect("metadata").len(), 0);
    });
}

/// Whether file permissions bind this process (they do not bind root).
#[cfg(unix)]
fn permissions_bind(dir: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    let probe = dir.join("permission-probe");
    fs::write(&probe, b"").expect("probe file");
    fs::set_permissions(&probe, fs::Permissions::from_mode(0o444)).expect("chmod");
    let bound = fs::OpenOptions::new().write(true).open(&probe).is_err();
    fs::remove_file(&probe).expect("remove the probe");
    bound
}

#[cfg(unix)]
#[test]
fn write_protected_file_and_directory_give_read_only() {
    use std::os::unix::fs::PermissionsExt;
    run(async {
        let root = TempRoot::new("ro-permissions");
        let layout = root.layout();
        session(&layout, ONE).await;
        if !permissions_bind(root.path()) {
            eprintln!("skipped: file permissions do not bind this user (root)");
            return;
        }
        let mode = |path: &Path, mode| {
            fs::set_permissions(path, fs::Permissions::from_mode(mode)).expect("chmod")
        };

        // SQLITE_READONLY: the file is write-protected.
        mode(&layout.database, 0o444);
        let opened = open(&layout, ONE).await.expect("opens");
        assert_eq!(opened.access, Access::ReadOnly { code: 8 });
        opened.conn.close().await.expect("close");
        mode(&layout.database, 0o644);

        // SQLITE_READONLY_DIRECTORY: the journal cannot be created.
        mode(&layout.data_dir, 0o555);
        let opened = open(&layout, ONE).await.expect("opens");
        mode(&layout.data_dir, 0o755);
        assert_eq!(opened.access, Access::ReadOnly { code: 1544 });
        opened.conn.close().await.expect("close");
    });
}

#[test]
fn database_locked_by_another_connection_is_unavailable_not_read_only() {
    run(async {
        let root = TempRoot::new("busy");
        let layout = root.layout();
        session(&layout, ONE).await;
        let mut other = raw(&layout).await;
        sqlx::query("BEGIN IMMEDIATE")
            .execute(&mut other)
            .await
            .expect("the other connection takes the write lock");

        let mut settings = Settings::new(ONE);
        settings.busy_timeout = Some(Duration::from_millis(50));
        let error = reason(open_with(&layout, &settings).await);
        // SQLITE_BUSY.
        assert!(error.starts_with("step=probe code=5 "), "{error}");

        sqlx::query("ROLLBACK")
            .execute(&mut other)
            .await
            .expect("rollback");
        other.close().await.expect("close");
    });
}

/// Needs a file system without free space, which a test cannot arrange
/// portably: point `ATLAS_STORAGE_TEST_FULL_ROOT` at an initialised storage
/// root on a full file system and run with `--ignored`.
#[test]
#[ignore = "needs a full file system: ATLAS_STORAGE_TEST_FULL_ROOT"]
fn full_disk_is_unavailable_not_read_only() {
    let Some(root) = std::env::var_os("ATLAS_STORAGE_TEST_FULL_ROOT") else {
        return;
    };
    run(async {
        let layout = Layout::new(PathBuf::from(root));
        let error = reason(open(&layout, NONE).await);
        // SQLITE_FULL.
        assert!(error.starts_with("step=probe code=13 "), "{error}");
    });
}

#[test]
fn corrupt_database_is_unavailable_and_untouched() {
    run(async {
        let root = TempRoot::new("corrupt");
        let layout = root.layout();
        session(&layout, ONE).await;
        // Keep the 100-byte header, destroy the rest of the schema page.
        let mut bytes = fs::read(&layout.database).expect("read");
        for byte in &mut bytes[100..4096] {
            *byte = 0xff;
        }
        fs::write(&layout.database, &bytes).expect("write");

        let error = reason(open(&layout, ONE).await);
        // SQLITE_CORRUPT, found as soon as the connection reads the schema.
        assert!(error.contains(" code=11 "), "{error}");
        assert_eq!(fs::read(&layout.database).expect("read"), bytes);
    });
}

#[test]
fn database_path_that_cannot_be_opened_is_unavailable() {
    run(async {
        let root = TempRoot::new("cantopen");
        let layout = root.layout();
        // A directory where the file should be.
        fs::create_dir_all(&layout.database).expect("directory");
        fs::write(&layout.marker, b"").expect("marker");
        let error = reason(open(&layout, ONE).await);
        // SQLITE_CANTOPEN (14). The extended code depends on the platform:
        // plain 14 on Linux, SQLITE_CANTOPEN_ISDIR (526) on Windows; either
        // way the storage is unavailable and the journal has the full code.
        let code: i32 = error
            .strip_prefix("step=open code=")
            .and_then(|rest| rest.split(' ').next())
            .and_then(|code| code.parse().ok())
            .unwrap_or_else(|| panic!("no code in: {error}"));
        assert_eq!(code & 0xff, 14, "{error}");
        assert!(layout.database.is_dir());
    });
}

// ---------------------------------------------------------------------------
// Migrations
// ---------------------------------------------------------------------------

const fn entry(version: i64, name: &'static str, sql: &'static str) -> Embedded {
    Embedded { version, name, sql }
}

#[test]
fn list_must_be_1_2_3_without_gaps_or_repeats() {
    let ok = "SELECT 1;\n";
    assert_eq!(list_defect(&[]), None);
    assert_eq!(list_defect(TWO), None);
    let version = "version is not the next number (1, 2, 3…)";
    // Does not start at 1.
    assert_eq!(list_defect(&[entry(2, "a", ok)]), Some((0, version)));
    assert_eq!(list_defect(&[entry(0, "a", ok)]), Some((0, version)));
    // A gap.
    assert_eq!(
        list_defect(&[entry(1, "a", ok), entry(3, "b", ok)]),
        Some((1, version))
    );
    // A repeat.
    assert_eq!(
        list_defect(&[entry(1, "a", ok), entry(1, "b", ok)]),
        Some((1, version))
    );
    // Out of order.
    assert_eq!(
        list_defect(&[entry(2, "a", ok), entry(1, "b", ok)]),
        Some((0, version))
    );
    // Names and line endings.
    assert_eq!(list_defect(&[entry(1, "", ok)]), Some((0, "name is empty")));
    assert_eq!(
        list_defect(&[entry(1, "Add Note", ok)]),
        Some((0, "name is not [a-z0-9_]+"))
    );
    assert_eq!(
        list_defect(&[entry(1, "a", "SELECT 1;\r\n")]),
        Some((0, "SQL contains a carriage return"))
    );
}

#[test]
fn invalid_list_is_refused_before_anything_is_applied() {
    run(async {
        const GAP: &[Embedded] = &[CREATE_ITEMS, entry(3, "later", "SELECT 1;\n")];
        const REPEAT: &[Embedded] = &[CREATE_ITEMS, entry(1, "again", "SELECT 1;\n")];
        const CRLF: &[Embedded] = &[entry(1, "crlf", "SELECT 1;\r\n")];
        for list in [GAP, REPEAT, CRLF] {
            let root = TempRoot::new("bad-list");
            let layout = root.layout();
            let error = reason(open(&layout, list).await);
            assert!(
                error.starts_with("migrations: invalid migration list at index"),
                "{error}"
            );
            // Not even the first, valid migration was applied.
            let mut conn = raw(&layout).await;
            assert_eq!(
                count(&mut conn, "SELECT count(*) FROM sqlite_master").await,
                0
            );
            conn.close().await.expect("close");
            assert!(!layout.marker.exists());
        }
    });
}

#[test]
fn product_list_matches_the_migrations_directory() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
    assert_eq!(files_defect(MIGRATIONS, &dir), Ok(()));
    // MM-5B: the module configuration table.
    assert_eq!(MIGRATIONS.len(), 1);
    assert_eq!(
        migrations::file_name(&MIGRATIONS[0]),
        "0001_module_config.sql"
    );
}

#[test]
fn list_and_files_are_compared_both_ways() {
    let dir = test_migrations_dir();
    assert_eq!(files_defect(TWO, &dir), Ok(()));
    // A file that is not in the list.
    let error = files_defect(ONE, &dir).expect_err("unlisted file");
    assert!(error.contains("0002_add_note.sql"), "{error}");
    // An entry without its file, and a name that differs from the file name.
    assert!(files_defect(BROKEN, &dir).is_err());
    const RENAMED: &[Embedded] = &[
        CREATE_ITEMS,
        entry(
            2,
            "add_notes",
            include_str!("test_migrations/0002_add_note.sql"),
        ),
    ];
    assert!(files_defect(RENAMED, &dir).is_err());
    // The embedded text is the text of the file.
    const OTHER_TEXT: &[Embedded] = &[CREATE_ITEMS, entry(2, "add_note", "SELECT 1;\n")];
    let error = files_defect(OTHER_TEXT, &dir).expect_err("different text");
    assert!(error.contains("differs from the embedded text"), "{error}");
}

#[test]
fn file_with_a_carriage_return_is_reported() {
    let root = TempRoot::new("crlf-file");
    const CRLF: &[Embedded] = &[entry(1, "crlf", "SELECT 1;\r\n")];
    fs::write(root.path().join("0001_crlf.sql"), b"SELECT 1;\r\n").expect("write");
    let error = files_defect(CRLF, root.path()).expect_err("carriage return");
    assert!(error.contains("carriage return"), "{error}");
}

#[test]
fn migrations_are_applied_once_and_only_the_missing_ones() {
    run(async {
        let root = TempRoot::new("apply");
        let layout = root.layout();
        assert_eq!(session(&layout, ONE).await.2, 1);
        assert_eq!(session(&layout, ONE).await.2, 0);
        // The application is updated: one more migration.
        assert_eq!(session(&layout, TWO).await.2, 1);
        assert_eq!(session(&layout, TWO).await.2, 0);
        let mut conn = raw(&layout).await;
        assert_eq!(applied_versions(&mut conn).await, vec![1, 2]);
        assert_eq!(
            count(&mut conn, "SELECT count(*) FROM pragma_table_info('items')").await,
            3
        );
        conn.close().await.expect("close");
    });
}

/// Guards the atomicity of a run: with a transaction per migration the
/// first migration would stay applied when the second fails.
#[test]
fn failed_migration_rolls_back_the_whole_run() {
    run(async {
        // On a first run: nothing at all is left.
        let root = TempRoot::new("broken");
        let layout = root.layout();
        let error = reason(open(&layout, BROKEN).await);
        assert!(error.starts_with("migrations: "), "{error}");
        assert!(error.contains("migration 2"), "{error}");
        // A first run that failed has no marker.
        assert!(!layout.marker.exists());

        let mut conn = raw(&layout).await;
        // Neither the first migration, which succeeded, nor the first
        // statement of the failed one, nor the table of the migrator.
        assert_eq!(
            count(&mut conn, "SELECT count(*) FROM sqlite_master").await,
            0
        );
        conn.close().await.expect("close");

        // Through the service the storage is not ready.
        let storage = Storage::for_test(root.path(), BROKEN);
        storage.open().await;
        assert_eq!(storage.kind().await, "unavailable");
        storage.close().await;

        // With the cause removed the same database gets the whole set.
        assert_eq!(session(&layout, TWO).await, (Access::ReadWrite, false, 2));

        // On a database that already has migrations: what was there stays,
        // nothing of the failed run does.
        let root = TempRoot::new("broken-later");
        let layout = root.layout();
        session(&layout, NONE).await;
        let before = fs::read(&layout.database).expect("database");
        let error = reason(open(&layout, BROKEN).await);
        assert!(error.contains("migration 2"), "{error}");
        assert_eq!(fs::read(&layout.database).expect("database"), before);
        let mut conn = raw(&layout).await;
        assert_eq!(applied_versions(&mut conn).await, Vec::<i64>::new());
        assert_eq!(
            count(
                &mut conn,
                "SELECT count(*) FROM sqlite_master WHERE name IN ('items', 'half')"
            )
            .await,
            0
        );
        conn.close().await.expect("close");
        assert_eq!(session(&layout, TWO).await, (Access::ReadWrite, false, 2));
    });
}

/// Guards the other half of the atomicity: a set of migrations that succeeds
/// is committed as a whole and the storage becomes ready.
#[test]
fn several_migrations_are_committed_together_and_the_storage_is_ready() {
    run(async {
        let root = TempRoot::new("several");
        let layout = root.layout();
        let storage = Storage::for_test(root.path(), TWO);
        storage.open().await;
        assert_eq!(storage.kind().await, "ready");
        storage.close().await;
        let mut conn = raw(&layout).await;
        assert_eq!(applied_versions(&mut conn).await, vec![1, 2]);
        // The second migration added a column to the table of the first.
        assert_eq!(
            count(&mut conn, "SELECT count(*) FROM pragma_table_info('items')").await,
            3
        );
        assert_eq!(journal_mode(&mut conn).await, "delete");
        conn.close().await.expect("close");
        assert!(!layout.data_dir.join("atlas.db-journal").exists());
    });
}

/// Guards against reporting the storage as open after a `COMMIT` that did not
/// happen. A reader in another connection holds a shared lock: the migration
/// can be prepared, but its `COMMIT` cannot get the exclusive lock and fails
/// with `SQLITE_BUSY`.
#[test]
fn commit_that_fails_applies_nothing_and_the_storage_is_not_ready() {
    run(async {
        let root = TempRoot::new("commit-busy");
        let layout = root.layout();
        session(&layout, ONE).await;
        let before = fs::read(&layout.database).expect("database");

        let mut reader = raw(&layout).await;
        sqlx::query("BEGIN")
            .execute(&mut reader)
            .await
            .expect("begin");
        assert_eq!(count(&mut reader, "SELECT count(*) FROM items").await, 0);

        let mut settings = Settings::new(TWO);
        settings.busy_timeout = Some(Duration::from_millis(100));
        let error = reason(open_with(&layout, &settings).await);
        assert!(
            error.starts_with("step=migrations-commit code=5 "),
            "{error}"
        );
        let mut settings = Settings::new(TWO);
        settings.busy_timeout = Some(Duration::from_millis(100));
        let storage = Storage::with_settings(Ok(root.path().to_path_buf()), settings);
        storage.open().await;
        assert_eq!(storage.kind().await, "unavailable");
        storage.close().await;

        sqlx::query("ROLLBACK")
            .execute(&mut reader)
            .await
            .expect("end of the read");
        // Nothing of the migration is in the database, and the connection of
        // the failed opening left no journal behind.
        assert_eq!(applied_versions(&mut reader).await, vec![1]);
        reader.close().await.expect("close");
        assert_eq!(fs::read(&layout.database).expect("database"), before);
        assert!(!layout.data_dir.join("atlas.db-journal").exists());
        // The next start applies it.
        assert_eq!(session(&layout, TWO).await, (Access::ReadWrite, false, 1));
    });
}

#[test]
fn database_newer_than_the_application_is_unavailable_and_unchanged() {
    run(async {
        let root = TempRoot::new("newer");
        let layout = root.layout();
        session(&layout, TWO).await;
        let before = fs::read(&layout.database).expect("read");
        for list in [ONE, NONE] {
            let error = reason(open(&layout, list).await);
            assert!(
                error.starts_with("migrations: the database is newer than the application"),
                "{error}"
            );
        }
        assert_eq!(fs::read(&layout.database).expect("read"), before);
    });
}

#[test]
fn edited_migration_is_unavailable_and_unchanged() {
    run(async {
        let root = TempRoot::new("edited");
        let layout = root.layout();
        session(&layout, ONE).await;
        let before = fs::read(&layout.database).expect("read");
        let error = reason(open(&layout, EDITED).await);
        assert_eq!(
            error,
            "migrations: migration 1 was changed after it was applied"
        );
        assert_eq!(fs::read(&layout.database).expect("read"), before);
    });
}

#[test]
fn applied_versions_must_be_exactly_1_to_k() {
    run(async {
        let root = TempRoot::new("applied-gap");
        let layout = root.layout();
        session(&layout, TWO).await;
        let mut conn = raw(&layout).await;
        sqlx::query("DELETE FROM _sqlx_migrations WHERE version = 1")
            .execute(&mut conn)
            .await
            .expect("delete");
        conn.close().await.expect("close");

        let error = reason(open(&layout, TWO).await);
        assert_eq!(
            error,
            "migrations: applied versions are not 1..=1: found version 2"
        );
        // Nothing was applied to "repair" it.
        let mut conn = raw(&layout).await;
        assert_eq!(applied_versions(&mut conn).await, vec![2]);
        conn.close().await.expect("close");
    });
}

#[test]
fn partially_applied_migration_is_unavailable() {
    run(async {
        let root = TempRoot::new("dirty");
        let layout = root.layout();
        session(&layout, ONE).await;
        let mut conn = raw(&layout).await;
        sqlx::query("UPDATE _sqlx_migrations SET success = FALSE")
            .execute(&mut conn)
            .await
            .expect("update");
        conn.close().await.expect("close");
        let error = reason(open(&layout, ONE).await);
        assert_eq!(error, "migrations: migration 1 was applied only partially");
    });
}

// ---------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------

async fn ready(root: &TempRoot) -> Storage {
    let storage = Storage::for_test(root.path(), ONE);
    storage.open().await;
    assert_eq!(storage.kind().await, "ready");
    storage
}

async fn stored(storage: &Storage) -> i64 {
    match &mut *storage.inner.state.lock().await {
        State::Ready(conn) => count(conn, "SELECT count(*) FROM items").await,
        _ => panic!("the storage is not ready"),
    }
}

#[test]
fn committed_transaction_survives_a_reopening() {
    run(async {
        let root = TempRoot::new("commit");
        let storage = ready(&root).await;
        {
            let mut state = storage.inner.state.lock().await;
            let State::Ready(conn) = &mut *state else {
                panic!("the storage is not ready");
            };
            let mut transaction = conn.begin().await.expect("begin");
            for name in ["a", "b"] {
                sqlx::query("INSERT INTO items (name) VALUES (?1)")
                    .bind(name)
                    .execute(&mut *transaction)
                    .await
                    .expect("insert");
            }
            transaction.commit().await.expect("commit");
        }
        storage.close().await;

        let storage = ready(&root).await;
        assert_eq!(stored(&storage).await, 2);
        storage.close().await;
    });
}

#[test]
fn rolled_back_transaction_leaves_nothing() {
    run(async {
        let root = TempRoot::new("rollback");
        let storage = ready(&root).await;
        {
            let mut state = storage.inner.state.lock().await;
            let State::Ready(conn) = &mut *state else {
                panic!("the storage is not ready");
            };
            let mut transaction = conn.begin().await.expect("begin");
            sqlx::query("INSERT INTO items (name) VALUES ('a')")
                .execute(&mut *transaction)
                .await
                .expect("insert");
            transaction.rollback().await.expect("rollback");
        }
        assert_eq!(stored(&storage).await, 0);
        storage.close().await;
    });
}

#[test]
fn cancelled_future_leaves_no_partial_data() {
    run(async {
        let root = TempRoot::new("cancel");
        let storage = ready(&root).await;
        let (inserted, wait_inserted) = tokio::sync::oneshot::channel();
        let writer = {
            let storage = storage.clone();
            tokio::spawn(async move {
                let mut state = storage.inner.state.lock().await;
                let State::Ready(conn) = &mut *state else {
                    panic!("the storage is not ready");
                };
                let mut transaction = conn.begin().await.expect("begin");
                sqlx::query("INSERT INTO items (name) VALUES ('first of two')")
                    .execute(&mut *transaction)
                    .await
                    .expect("insert");
                inserted.send(()).expect("signal");
                // The second insert and the commit never happen.
                std::future::pending::<()>().await;
            })
        };
        wait_inserted.await.expect("the first row is inserted");
        writer.abort();
        assert!(writer.await.expect_err("aborted").is_cancelled());

        // The same connection: the abandoned transaction is rolled back.
        assert_eq!(stored(&storage).await, 0);
        storage.close().await;
        // And after a reopening.
        let storage = ready(&root).await;
        assert_eq!(stored(&storage).await, 0);
        storage.close().await;
    });
}

// ---------------------------------------------------------------------------
// The service: one result per session, closing
// ---------------------------------------------------------------------------

#[test]
fn opening_result_stays_for_the_session() {
    run(async {
        let root = TempRoot::new("once");
        let storage = Storage::for_test(root.path(), ONE);
        assert_eq!(storage.kind().await, "pending");
        // The marker without a database: unavailable.
        fs::write(root.layout().marker, b"").expect("marker");
        storage.open().await;
        assert_eq!(storage.kind().await, "unavailable");
        // The cause is removed, but there is no second opening in a session.
        fs::remove_file(root.layout().marker).expect("remove the marker");
        storage.open().await;
        assert_eq!(storage.kind().await, "unavailable");
        assert!(!root.layout().data_dir.exists());
        storage.close().await;
        assert_eq!(storage.kind().await, "closed");
    });
}

#[test]
fn unknown_location_is_unavailable() {
    run(async {
        let storage = Storage::new(Err(crate::error::AppError::Io(std::io::Error::other(
            "no data directory",
        ))));
        storage.open().await;
        assert_eq!(storage.kind().await, "unavailable");
        storage.close().await;
    });
}

#[test]
fn read_only_is_a_state_of_the_service() {
    run(async {
        let root = TempRoot::new("ro-service");
        session(&root.layout(), ONE).await;
        let mut settings = Settings::new(ONE);
        settings.read_only_handle = true;
        let storage = Storage::with_settings(Ok(root.path().to_path_buf()), settings);
        storage.open().await;
        assert_eq!(storage.kind().await, "read-only");
        storage.close().await;
        assert_eq!(storage.kind().await, "closed");
    });
}

#[test]
fn close_is_idempotent_and_safe_from_several_tasks() {
    run(async {
        let root = TempRoot::new("close");
        let storage = ready(&root).await;
        let closers: Vec<_> = (0..4)
            .map(|_| {
                let storage = storage.clone();
                tokio::spawn(async move { storage.close().await })
            })
            .collect();
        for closer in closers {
            closer.await.expect("close task");
        }
        storage.close().await;
        assert_eq!(storage.kind().await, "closed");
        // Closed is final: a late opening does nothing.
        storage.open().await;
        assert_eq!(storage.kind().await, "closed");
        // The file is free: a new session opens it.
        let again = ready(&root).await;
        again.close().await;
    });
}

#[test]
fn close_before_the_opening_started_prevents_it() {
    run(async {
        let root = TempRoot::new("close-first");
        let storage = Storage::for_test(root.path(), ONE);
        storage.close().await;
        storage.open().await;
        assert_eq!(storage.kind().await, "closed");
        assert!(!root.layout().data_dir.exists());
    });
}

#[test]
fn close_waits_for_an_opening_in_progress() {
    run(async {
        let root = TempRoot::new("close-during-open");
        let storage = Storage::for_test(root.path(), TWO);
        let opening = tokio::spawn(storage.open());
        // Let the opening take the state before the close asks for it.
        tokio::task::yield_now().await;
        storage.close().await;
        opening.await.expect("opening task");
        assert_eq!(storage.kind().await, "closed");

        // The first run was completed, not cut in half.
        let layout = root.layout();
        assert!(layout.marker.is_file());
        assert_eq!(session(&layout, TWO).await, (Access::ReadWrite, false, 0));
    });
}

#[test]
fn first_bounded_close_times_out_and_later_ones_do_not_wait_again() {
    run(async {
        let root = TempRoot::new("close-limit");
        let storage = ready(&root).await;
        {
            // Something holds the state, as a stuck opening would.
            let _held = storage.inner.state.lock().await;
            let limit = Duration::from_millis(200);
            let started = std::time::Instant::now();
            storage.close_within(limit).await;
            assert!(
                started.elapsed() >= limit,
                "the first close waits its limit"
            );

            // The fallback of the exit asks again with a full limit of its
            // own: the deadline of the session has passed, it returns at once.
            for _ in 0..3 {
                let again = std::time::Instant::now();
                storage.close_within(Duration::from_secs(30)).await;
                assert!(
                    again.elapsed() < Duration::from_secs(2),
                    "waited again: {:?}",
                    again.elapsed()
                );
            }
        }
        // Nobody got the state: the storage is not reported as closed.
        assert_eq!(storage.kind().await, "ready");
        // Past the deadline a close still takes what is free at once.
        let late = std::time::Instant::now();
        storage.close_within(Duration::from_secs(30)).await;
        assert!(late.elapsed() < Duration::from_secs(2));
        assert_eq!(storage.kind().await, "closed");
        // The file is free: a new session opens it.
        ready(&root).await.close().await;
    });
}

#[test]
fn bounded_closes_from_several_tasks_share_one_deadline() {
    run(async {
        let root = TempRoot::new("close-shared");
        let storage = ready(&root).await;
        let held = storage.inner.state.lock().await;
        let started = std::time::Instant::now();
        // The first call sets the deadline; the others bring longer limits.
        let limits = [200_u64, 30_000, 60_000, 30_000];
        let closers: Vec<_> = limits
            .into_iter()
            .map(|limit| {
                let storage = storage.clone();
                tokio::spawn(
                    async move { storage.close_within(Duration::from_millis(limit)).await },
                )
            })
            .collect();
        for closer in closers {
            closer.await.expect("close task");
        }
        assert!(started.elapsed() >= Duration::from_millis(200));
        assert!(
            started.elapsed() < Duration::from_secs(5),
            "all of them end at the first deadline: {:?}",
            started.elapsed()
        );
        drop(held);
        assert_eq!(storage.kind().await, "ready");
        storage.close().await;
        assert_eq!(storage.kind().await, "closed");
    });
}

#[test]
fn opening_then_bounded_close_works_as_before() {
    run(async {
        let root = TempRoot::new("close-normal");
        let storage = Storage::for_test(root.path(), TWO);
        storage.open().await;
        assert_eq!(storage.kind().await, "ready");
        let started = std::time::Instant::now();
        storage.close_within(Duration::from_secs(30)).await;
        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(storage.kind().await, "closed");
        // Again, bounded and not: nothing to do.
        storage.close_within(Duration::from_secs(30)).await;
        storage.close().await;
        assert_eq!(storage.kind().await, "closed");

        let layout = root.layout();
        assert!(!layout.data_dir.join("atlas.db-journal").exists());
        assert_eq!(session(&layout, TWO).await, (Access::ReadWrite, false, 0));
    });
}

#[test]
fn opening_that_outlives_a_bounded_close_closes_its_own_connection() {
    run(async {
        let root = TempRoot::new("close-stuck-open");
        let layout = root.layout();
        session(&layout, ONE).await;
        // Another program holds the file: the opening waits in its read check.
        let mut other = raw(&layout).await;
        sqlx::query("BEGIN EXCLUSIVE")
            .execute(&mut other)
            .await
            .expect("exclusive lock");

        let storage = Storage::for_test(root.path(), ONE);
        let opening = tokio::spawn(storage.open());
        tokio::task::yield_now().await;
        // The exit gives up waiting, and its fallback does not wait again.
        storage.close_within(Duration::from_millis(100)).await;
        assert!(!opening.is_finished());
        let again = std::time::Instant::now();
        storage.close_within(Duration::from_secs(30)).await;
        assert!(again.elapsed() < Duration::from_secs(2));
        assert!(!opening.is_finished());

        sqlx::query("ROLLBACK")
            .execute(&mut other)
            .await
            .expect("rollback");
        other.close().await.expect("close");
        // The opening was not cut short. Nobody will come back to close what
        // it opened, so it closes the connection itself: the storage is
        // closed in fact, not only in name.
        opening.await.expect("opening task");
        assert_eq!(storage.kind().await, "closed");
        assert_eq!(session(&layout, ONE).await, (Access::ReadWrite, false, 0));
    });
}

#[test]
fn opening_that_starts_after_a_given_up_close_opens_nothing() {
    run(async {
        let root = TempRoot::new("close-before-open");
        let storage = Storage::for_test(root.path(), ONE);
        {
            let _held = storage.inner.state.lock().await;
            storage.close_within(Duration::from_millis(50)).await;
        }
        // The close never reached the state; the opening starts only now.
        assert_eq!(storage.kind().await, "pending");
        storage.open().await;
        assert_eq!(storage.kind().await, "closed");
        let layout = root.layout();
        assert!(!layout.data_dir.exists());
        assert!(!layout.marker.exists());
        assert!(!layout.lock.exists());
    });
}

// ---------------------------------------------------------------------------
// Module configuration (MM-5B, #21): the product migration
// ---------------------------------------------------------------------------

async fn module_rows(layout: &Layout) -> Vec<(String, i64, String)> {
    let mut conn = raw(layout).await;
    let rows =
        sqlx::query_as("SELECT module_id, enabled, settings FROM module_config ORDER BY module_id")
            .fetch_all(&mut conn)
            .await
            .expect("module rows");
    conn.close().await.expect("close");
    rows
}

/// Stores a row as an outside edit could, with the checks of the schema
/// switched off for that one connection.
async fn plant_row(layout: &Layout, id: &str, enabled: i64, settings: &str) {
    let mut conn = raw(layout).await;
    sqlx::query("PRAGMA ignore_check_constraints = ON")
        .execute(&mut conn)
        .await
        .expect("checks off");
    sqlx::query("INSERT INTO module_config (module_id, enabled, settings) VALUES (?1, ?2, ?3)")
        .bind(id)
        .bind(enabled)
        .bind(settings)
        .execute(&mut conn)
        .await
        .expect("plant row");
    conn.close().await.expect("close");
}

fn row(id: &str, enabled: i64, settings: &str) -> (String, i64, String) {
    (id.to_owned(), enabled, settings.to_owned())
}

#[test]
fn product_migration_creates_a_strict_module_config_table() {
    run(async {
        let root = TempRoot::new("product-migration");
        let layout = root.layout();
        assert_eq!(
            session(&layout, MIGRATIONS).await,
            (Access::ReadWrite, true, 1)
        );
        let mut conn = raw(&layout).await;
        for (sql, what) in [
            (
                "INSERT INTO module_config VALUES ('a', 1, '{}')",
                "valid row",
            ),
            (
                "INSERT INTO module_config VALUES ('b', 0, '[1]')",
                "valid row",
            ),
        ] {
            sqlx::query(sql).execute(&mut conn).await.expect(what);
        }
        for sql in [
            // STRICT: no value that cannot be converted without loss.
            "INSERT INTO module_config VALUES ('c', 'yes', '{}')",
            "INSERT INTO module_config VALUES (X'61', 1, '{}')",
            "INSERT INTO module_config VALUES ('g', 1, X'7B7D')",
            // The checks.
            "INSERT INTO module_config VALUES ('d', 2, '{}')",
            "INSERT INTO module_config VALUES ('e', 1, 'not json')",
            "INSERT INTO module_config VALUES ('f', 1, NULL)",
            // One row per module.
            "INSERT INTO module_config VALUES ('a', 0, '{}')",
        ] {
            assert!(sqlx::query(sql).execute(&mut conn).await.is_err(), "{sql}");
        }
        conn.close().await.expect("close");
        assert_eq!(
            module_rows(&layout).await,
            vec![row("a", 1, "{}"), row("b", 0, "[1]")]
        );
    });
}

#[test]
fn foundation_database_gets_the_table_once() {
    run(async {
        let root = TempRoot::new("product-migration-upgrade");
        let layout = root.layout();
        // A database of the SQLite foundation: no product migrations.
        assert_eq!(session(&layout, NONE).await, (Access::ReadWrite, true, 0));
        assert_eq!(
            session(&layout, MIGRATIONS).await,
            (Access::ReadWrite, false, 1)
        );
        assert_eq!(
            session(&layout, MIGRATIONS).await,
            (Access::ReadWrite, false, 0)
        );
        let mut conn = raw(&layout).await;
        assert_eq!(applied_versions(&mut conn).await, vec![1]);
        conn.close().await.expect("close");
        assert!(module_rows(&layout).await.is_empty());
    });
}

// ---------------------------------------------------------------------------
// Module configuration: waiting for the opening
// ---------------------------------------------------------------------------

fn storage_waiting(root: &TempRoot, readiness: Duration) -> Storage {
    Storage::with_readiness(
        Ok(root.path().to_path_buf()),
        Settings::new(MIGRATIONS),
        readiness,
    )
}

async fn product(root: &TempRoot) -> Storage {
    let storage = Storage::for_test(root.path(), MIGRATIONS);
    storage.open().await;
    assert_eq!(storage.kind().await, "ready");
    storage
}

/// The three operations at once, each in a task of its own, as the module
/// manager could issue them before the opening has a result.
fn three_operations(
    storage: &Storage,
) -> Vec<tokio::task::JoinHandle<Result<(), ConfigStoreError>>> {
    let read = {
        let storage = storage.clone();
        tokio::spawn(async move { storage.read_module_config("a").await.map(drop) })
    };
    let write = {
        let storage = storage.clone();
        tokio::spawn(async move { storage.write_module_configs(&[("a", true, "{}")]).await })
    };
    let replace = {
        let storage = storage.clone();
        tokio::spawn(async move {
            storage
                .replace_module_config_if("a", false, "{}", |_| true)
                .await
                .map(drop)
        })
    };
    vec![read, write, replace]
}

async fn results(
    tasks: Vec<tokio::task::JoinHandle<Result<(), ConfigStoreError>>>,
) -> Vec<Result<(), ConfigStoreError>> {
    let mut found = Vec::new();
    for task in tasks {
        found.push(task.await.expect("operation task"));
    }
    found
}

#[test]
fn operations_issued_before_the_opening_wait_for_its_result() {
    run(async {
        let root = TempRoot::new("config-before-open");
        // A long deadline: the operations must not need it.
        let storage = storage_waiting(&root, Duration::from_secs(30));
        let tasks = three_operations(&storage);
        tokio::task::yield_now().await;
        assert!(tasks.iter().all(|task| !task.is_finished()));

        // They wait without the state lock: the opening gets it and finishes.
        let started = std::time::Instant::now();
        tokio::time::timeout(Duration::from_secs(10), storage.open())
            .await
            .expect("the opening is not blocked by waiting operations");
        assert_eq!(results(tasks).await, vec![Ok(()), Ok(()), Ok(())]);
        assert!(started.elapsed() < Duration::from_secs(10));
        assert_eq!(module_rows(&root.layout()).await.len(), 1);
        storage.close().await;
    });
}

#[test]
fn every_waiting_operation_gets_the_same_failed_result() {
    run(async {
        let root = TempRoot::new("config-unavailable");
        // A marker without a database: the opening is unavailable.
        fs::write(root.layout().marker, b"").expect("marker");
        let storage = storage_waiting(&root, Duration::from_secs(30));
        let tasks = three_operations(&storage);
        tokio::task::yield_now().await;
        storage.open().await;
        assert_eq!(
            results(tasks).await,
            vec![Err(ConfigStoreError::Unavailable); 3]
        );
        // And every later one, at once.
        assert_eq!(
            storage.read_module_config("a").await,
            Err(ConfigStoreError::Unavailable)
        );
        storage.close().await;
    });
}

#[test]
fn close_before_the_opening_ends_the_wait_at_once() {
    run(async {
        let root = TempRoot::new("config-close-first");
        let storage = storage_waiting(&root, Duration::from_secs(30));
        let tasks = three_operations(&storage);
        tokio::task::yield_now().await;
        let started = std::time::Instant::now();
        storage.close().await;
        assert_eq!(results(tasks).await, vec![Err(ConfigStoreError::Closed); 3]);
        assert!(started.elapsed() < Duration::from_secs(5));
        storage.open().await;
        assert_eq!(storage.kind().await, "closed");
        assert!(!root.layout().data_dir.exists());
    });
}

#[test]
fn close_during_the_opening_gives_closed_to_waiting_operations() {
    run(async {
        let root = TempRoot::new("config-close-during-open");
        let layout = root.layout();
        session(&layout, MIGRATIONS).await;
        // Another program holds the file: the opening waits in its read check.
        let mut other = raw(&layout).await;
        sqlx::query("BEGIN EXCLUSIVE")
            .execute(&mut other)
            .await
            .expect("exclusive lock");
        let mut settings = Settings::new(MIGRATIONS);
        settings.busy_timeout = Some(Duration::from_secs(30));
        let storage = Storage::with_readiness(
            Ok(root.path().to_path_buf()),
            settings,
            Duration::from_secs(30),
        );
        let opening = tokio::spawn(storage.open());
        tokio::task::yield_now().await;
        let tasks = three_operations(&storage);
        let closing = {
            let storage = storage.clone();
            tokio::spawn(async move { storage.close().await })
        };
        tokio::time::sleep(Duration::from_millis(100)).await;
        sqlx::query("ROLLBACK")
            .execute(&mut other)
            .await
            .expect("rollback");
        other.close().await.expect("close");

        opening.await.expect("opening task");
        closing.await.expect("closing task");
        assert_eq!(results(tasks).await, vec![Err(ConfigStoreError::Closed); 3]);
        assert!(module_rows(&layout).await.is_empty());
    });
}

#[test]
fn aborted_opening_ends_the_wait_at_the_readiness_deadline() {
    run(async {
        let root = TempRoot::new("config-aborted-open");
        let layout = root.layout();
        session(&layout, MIGRATIONS).await;
        let mut other = raw(&layout).await;
        sqlx::query("BEGIN EXCLUSIVE")
            .execute(&mut other)
            .await
            .expect("exclusive lock");
        let mut settings = Settings::new(MIGRATIONS);
        settings.busy_timeout = Some(Duration::from_secs(30));
        let storage = Storage::with_readiness(
            Ok(root.path().to_path_buf()),
            settings,
            Duration::from_millis(300),
        );
        let opening = tokio::spawn(storage.open());
        tokio::time::sleep(Duration::from_millis(50)).await;
        opening.abort();
        assert!(opening.await.expect_err("aborted").is_cancelled());

        let started = std::time::Instant::now();
        assert_eq!(
            storage.read_module_config("a").await,
            Err(ConfigStoreError::ReadinessExpired)
        );
        assert!(started.elapsed() >= Duration::from_millis(200));
        assert!(started.elapsed() < Duration::from_secs(5));
        assert_eq!(storage.kind().await, "pending");

        sqlx::query("ROLLBACK")
            .execute(&mut other)
            .await
            .expect("rollback");
        other.close().await.expect("close");
    });
}

#[test]
fn a_second_opening_changes_nothing_for_the_operations() {
    run(async {
        let root = TempRoot::new("config-second-open");
        let storage = product(&root).await;
        storage.open().await;
        storage
            .write_module_configs(&[("a", true, "{}")])
            .await
            .expect("write");
        assert_eq!(
            storage.read_module_config("a").await,
            Ok(Some(StoredModuleConfig {
                enabled: 1,
                settings: "{}".to_owned()
            }))
        );
        storage.close().await;
    });
}

#[test]
fn late_opening_after_the_readiness_deadline_stays_unusable_for_the_session() {
    let root = TempRoot::new("config-late-open");
    let layout = root.layout();
    let logs = crate::modules::testing::capture_logs(|| {
        run(async {
            session(&layout, MIGRATIONS).await;
            let mut other = raw(&layout).await;
            sqlx::query("BEGIN EXCLUSIVE")
                .execute(&mut other)
                .await
                .expect("exclusive lock");
            let mut settings = Settings::new(MIGRATIONS);
            settings.busy_timeout = Some(Duration::from_secs(30));
            let storage = Storage::with_readiness(
                Ok(root.path().to_path_buf()),
                settings,
                Duration::from_millis(200),
            );
            let opening = tokio::spawn(storage.open());
            assert_eq!(
                storage.read_module_config("a").await,
                Err(ConfigStoreError::ReadinessExpired)
            );

            // The opening goes on and succeeds after the deadline.
            sqlx::query("ROLLBACK")
                .execute(&mut other)
                .await
                .expect("rollback");
            other.close().await.expect("close");
            opening.await.expect("opening task");
            assert_eq!(storage.kind().await, "ready");

            // Still nothing for the rest of the session, at once.
            let started = std::time::Instant::now();
            assert_eq!(
                storage.read_module_config("a").await,
                Err(ConfigStoreError::ReadinessExpired)
            );
            assert_eq!(
                storage.write_module_configs(&[("a", true, "{}")]).await,
                Err(ConfigStoreError::ReadinessExpired)
            );
            assert_eq!(
                storage
                    .replace_module_config_if("a", false, "{}", |_| true)
                    .await,
                Err(ConfigStoreError::ReadinessExpired)
            );
            assert!(started.elapsed() < Duration::from_millis(100));
            storage.close().await;
        });
    });
    run(async { assert!(module_rows(&layout).await.is_empty(), "nothing was written") });
    let deadline = crate::modules::testing::log_line(&logs, "storage readiness deadline passed");
    assert!(deadline.contains("ERROR"), "{deadline}");
    assert!(deadline.contains("limit_ms=200"), "{deadline}");
    let late =
        crate::modules::testing::log_line(&logs, "database opened after the readiness deadline");
    assert!(late.contains("WARN"), "{late}");
}

// ---------------------------------------------------------------------------
// Module configuration: the operations
// ---------------------------------------------------------------------------

#[test]
fn written_configuration_is_read_back_after_a_reopening() {
    run(async {
        let root = TempRoot::new("config-roundtrip");
        let storage = product(&root).await;
        storage
            .write_module_configs(&[("a", true, r#"{"x":1}"#), ("b", false, "{}")])
            .await
            .expect("write");
        storage.close().await;

        let storage = product(&root).await;
        assert_eq!(
            storage.read_module_config("a").await,
            Ok(Some(StoredModuleConfig {
                enabled: 1,
                settings: r#"{"x":1}"#.to_owned()
            }))
        );
        assert_eq!(
            storage.read_module_config("b").await,
            Ok(Some(StoredModuleConfig {
                enabled: 0,
                settings: "{}".to_owned()
            }))
        );
        assert_eq!(storage.read_module_config("c").await, Ok(None));
        storage.close().await;
    });
}

#[test]
fn a_batch_is_saved_completely_or_not_at_all() {
    run(async {
        let root = TempRoot::new("config-batch");
        let layout = root.layout();
        let storage = product(&root).await;
        // The second entry breaks a check of the schema.
        let error = storage
            .write_module_configs(&[("a", true, "{}"), ("b", true, "not json")])
            .await
            .expect_err("the batch is refused");
        let ConfigStoreError::Database(text) = &error else {
            panic!("{error:?}");
        };
        assert!(
            text.starts_with("step=config-write-upsert code=275 "),
            "{text}"
        );
        assert!(!text.contains("not json"), "no value in the error: {text}");
        assert!(module_rows(&layout).await.is_empty());
        // The connection is not left inside a transaction.
        storage
            .write_module_configs(&[("a", true, "{}")])
            .await
            .expect("the next batch");
        assert_eq!(module_rows(&layout).await, vec![row("a", 1, "{}")]);
        storage.close().await;
    });
}

#[test]
fn the_last_entry_of_an_id_wins() {
    run(async {
        let root = TempRoot::new("config-duplicates");
        let storage = product(&root).await;
        storage
            .write_module_configs(&[("a", true, r#"{"v":1}"#), ("a", false, r#"{"v":2}"#)])
            .await
            .expect("write");
        assert_eq!(
            module_rows(&root.layout()).await,
            vec![row("a", 0, r#"{"v":2}"#)]
        );
        storage.close().await;
    });
}

#[test]
fn rows_of_other_modules_are_left_untouched() {
    run(async {
        let root = TempRoot::new("config-others");
        let layout = root.layout();
        session(&layout, MIGRATIONS).await;
        plant_row(&layout, "unknown.module", 1, r#"{"keep":true}"#).await;
        plant_row(&layout, "z", 0, "not json").await;
        let storage = product(&root).await;
        storage
            .write_module_configs(&[("a", true, "{}")])
            .await
            .expect("write");
        storage.close().await;
        assert_eq!(
            module_rows(&layout).await,
            vec![
                row("a", 1, "{}"),
                row("unknown.module", 1, r#"{"keep":true}"#),
                row("z", 0, "not json"),
            ]
        );
    });
}

#[test]
fn an_empty_batch_does_nothing_and_waits_for_nothing() {
    run(async {
        let root = TempRoot::new("config-empty");
        // Never opened.
        let storage = storage_waiting(&root, Duration::from_secs(30));
        let started = std::time::Instant::now();
        assert_eq!(storage.write_module_configs(&[]).await, Ok(()));
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(!root.layout().data_dir.exists());
    });
}

#[test]
fn read_only_database_is_read_but_never_written() {
    run(async {
        let root = TempRoot::new("config-read-only");
        let layout = root.layout();
        session(&layout, MIGRATIONS).await;
        plant_row(&layout, "a", 1, "{}").await;
        plant_row(&layout, "b", 1, "not json").await;
        let before = data_files(&layout);

        let mut settings = Settings::new(MIGRATIONS);
        settings.read_only_handle = true;
        let storage = Storage::with_settings(Ok(root.path().to_path_buf()), settings);
        storage.open().await;
        assert_eq!(storage.kind().await, "read-only");
        assert_eq!(
            storage.read_module_config("a").await,
            Ok(Some(StoredModuleConfig {
                enabled: 1,
                settings: "{}".to_owned()
            }))
        );
        assert_eq!(
            storage.write_module_configs(&[("a", false, "{}")]).await,
            Err(ConfigStoreError::ReadOnly)
        );
        assert_eq!(
            storage
                .replace_module_config_if("b", false, "{}", |_| true)
                .await,
            Err(ConfigStoreError::ReadOnly)
        );
        storage.close().await;
        assert_eq!(data_files(&layout), before);
    });
}

#[test]
fn operations_check_the_journal_mode_inside_their_transaction() {
    run(async {
        let root = TempRoot::new("config-wal");
        let elsewhere = TempRoot::new("config-wal-source");
        let layout = root.layout();
        session(&layout, MIGRATIONS).await;
        plant_row(&layout, "a", 1, "not json").await;
        let (wal, _shm) = real_wal_for(&layout, elsewhere.path()).await;
        let database = fs::read(&layout.database).expect("database");

        let storage = product(&root).await;
        // A WAL file appears while the session runs (ADR-016, known limit):
        // each operation finds it inside its transaction and does nothing.
        fs::write(&layout.wal, &wal).expect("plant mid-session");
        for (operation, step) in [
            ("read", "config-read-journal-mode"),
            ("write", "config-write-journal-mode"),
            ("replace", "config-replace-journal-mode"),
        ] {
            let result = match operation {
                "read" => storage.read_module_config("a").await.map(drop),
                "write" => storage.write_module_configs(&[("a", false, "{}")]).await,
                _ => storage
                    .replace_module_config_if("a", false, "{}", |_| true)
                    .await
                    .map(drop),
            };
            let Err(ConfigStoreError::Database(text)) = result else {
                panic!("{operation}: {result:?}");
            };
            assert!(
                text.starts_with(&format!("step={step} mode=wal ")),
                "{text}"
            );
        }
        storage.close().await;
        assert_eq!(fs::read(&layout.database).expect("database"), database);
        assert_eq!(fs::read(&layout.wal).expect("wal"), wal);
        assert!(!database_alone_has_planted(&layout).await);
    });
}

/// Decision O-13: a write that meets another connection's write transaction
/// fails at once. The operations read before they write, so SQLite does not
/// call the busy handler (it could deadlock) and returns `SQLITE_BUSY`.
#[test]
fn a_busy_database_fails_a_write_at_once_and_changes_nothing() {
    run(async {
        let root = TempRoot::new("config-busy");
        let layout = root.layout();
        session(&layout, MIGRATIONS).await;
        plant_row(&layout, "a", 1, "not json").await;
        // The default busy timeout of 5 s: the operations must not use it.
        let storage = product(&root).await;
        let mut other = raw(&layout).await;
        sqlx::query("BEGIN IMMEDIATE")
            .execute(&mut other)
            .await
            .expect("the other connection takes the write lock");

        let started = std::time::Instant::now();
        let write = storage.write_module_configs(&[("b", true, "{}")]).await;
        let replace = storage
            .replace_module_config_if("a", false, "{}", |_| true)
            .await;
        assert!(started.elapsed() < Duration::from_secs(2), "no waiting");
        for result in [write.map(drop), replace.map(drop)] {
            let Err(ConfigStoreError::Database(text)) = result else {
                panic!("{result:?}");
            };
            assert!(text.contains(" code=5 "), "SQLITE_BUSY: {text}");
        }
        // Reading is not blocked by a write lock.
        assert_eq!(
            storage.read_module_config("a").await,
            Ok(Some(StoredModuleConfig {
                enabled: 1,
                settings: "not json".to_owned()
            }))
        );

        sqlx::query("ROLLBACK")
            .execute(&mut other)
            .await
            .expect("rollback");
        other.close().await.expect("close");
        assert_eq!(module_rows(&layout).await, vec![row("a", 1, "not json")]);
        // Nothing is retried; the next operation works.
        storage
            .write_module_configs(&[("b", true, "{}")])
            .await
            .expect("write");
        storage.close().await;
    });
}

#[test]
fn a_damaged_row_is_replaced_in_one_transaction() {
    run(async {
        let root = TempRoot::new("config-replace");
        let layout = root.layout();
        session(&layout, MIGRATIONS).await;
        plant_row(&layout, "a", 1, "not json").await;
        let storage = product(&root).await;
        let mut seen = None;
        let result = storage
            .replace_module_config_if("a", false, r#"{"fresh":true}"#, |row| {
                seen = row.cloned();
                true
            })
            .await;
        assert_eq!(result, Ok(ReplaceCheck::Replaced));
        assert_eq!(
            seen,
            Some(StoredModuleConfig {
                enabled: 1,
                settings: "not json".to_owned()
            })
        );
        assert_eq!(
            module_rows(&layout).await,
            vec![row("a", 0, r#"{"fresh":true}"#)]
        );
        storage.close().await;
    });
}

#[test]
fn a_usable_or_missing_row_is_not_replaced() {
    run(async {
        let root = TempRoot::new("config-not-replaced");
        let layout = root.layout();
        session(&layout, MIGRATIONS).await;
        plant_row(&layout, "a", 1, r#"{"keep":1}"#).await;
        let storage = product(&root).await;
        let before = fs::read(&layout.database).expect("database");

        let mut seen = None;
        let result = storage
            .replace_module_config_if("a", false, "{}", |row| {
                seen = row.cloned();
                false
            })
            .await;
        assert_eq!(result, Ok(ReplaceCheck::NotDamaged));
        assert_eq!(
            seen,
            Some(StoredModuleConfig {
                enabled: 1,
                settings: r#"{"keep":1}"#.to_owned()
            })
        );

        let mut seen_missing = Some(None);
        let result = storage
            .replace_module_config_if("missing", false, "{}", |row| {
                seen_missing = Some(row.cloned());
                false
            })
            .await;
        assert_eq!(result, Ok(ReplaceCheck::NotDamaged));
        assert_eq!(seen_missing, Some(None));

        storage.close().await;
        assert_eq!(fs::read(&layout.database).expect("database"), before);
        assert_eq!(
            module_rows(&layout).await,
            vec![row("a", 1, r#"{"keep":1}"#)]
        );
    });
}

#[test]
fn a_failed_replacement_keeps_the_damaged_row() {
    run(async {
        let root = TempRoot::new("config-replace-fails");
        let layout = root.layout();
        session(&layout, MIGRATIONS).await;
        plant_row(&layout, "a", 1, "not json").await;
        let storage = product(&root).await;
        // The new settings break a check of the schema.
        let result = storage
            .replace_module_config_if("a", false, "also not json", |_| true)
            .await;
        let Err(ConfigStoreError::Database(text)) = result else {
            panic!("{result:?}");
        };
        assert!(
            text.starts_with("step=config-replace-upsert code=275 "),
            "{text}"
        );
        assert_eq!(module_rows(&layout).await, vec![row("a", 1, "not json")]);
        storage.close().await;
    });
}

// ---------------------------------------------------------------------------
// Boundaries
// ---------------------------------------------------------------------------

fn rust_sources(dir: &Path, found: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).expect("source directory") {
        let path = entry.expect("entry").path();
        if path.is_dir() {
            rust_sources(&path, found);
        } else if path.extension().is_some_and(|extension| extension == "rs") {
            found.push(path);
        }
    }
}

#[test]
fn sqlx_is_used_only_inside_the_storage_directory() {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    let storage = src.join("storage");
    let mut sources = Vec::new();
    rust_sources(&src, &mut sources);
    assert!(sources.len() > 10);
    for path in sources {
        let text = fs::read_to_string(&path).expect("source file");
        if !path.starts_with(&storage) {
            assert!(
                !text.contains("sqlx"),
                "{} mentions sqlx outside src/storage/",
                path.display()
            );
        } else if !path.ends_with("tests.rs") {
            // Loading SQLite extensions is always compiled into sqlx 0.8.6;
            // the rule is not to call it. The same goes for a second journal
            // mode and for `sqlx::migrate!()`.
            for forbidden in [".extension(", ".journal_mode(", "migrate!("] {
                assert!(
                    !text.replace("sqlx::migrate!()", "").contains(forbidden),
                    "{} calls {forbidden}",
                    path.display()
                );
            }
        }
    }
}
