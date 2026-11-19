//! Embedded schema migrations (SQLite foundation, ADR-016).
//!
//! Migration SQL is compiled into the binary with `include_str!` and listed
//! explicitly in [`MIGRATIONS`]; nothing is read from disk at run time and
//! `sqlx::migrate!()` is not used. sqlx 0.8.6 checks a dirty migration, a
//! version missing from the list and a changed checksum, but not the order,
//! gaps or duplicates of version numbers, so those are checked here: at
//! compile time for the product list, and again before every run.
//!
//! Rules: migrations only go forward, an applied migration is never edited,
//! versions are 1, 2, 3… without gaps, and a file is named
//! `NNNN_<name>.sql` (`src-tauri/migrations/`), with LF line endings.

use std::borrow::Cow;
use std::future::Future;
use std::pin::Pin;

use sqlx::error::BoxDynError;
use sqlx::migrate::{Migrate, Migration, MigrationSource, MigrationType, Migrator};
use sqlx::sqlite::SqliteConnection;

/// One migration compiled into the binary.
pub(super) struct Embedded {
    pub version: i64,
    /// The part of the file name after the number: `[a-z0-9_]+`.
    pub name: &'static str,
    pub sql: &'static str,
}

/// The product migrations.
pub(super) const MIGRATIONS: &[Embedded] = &[
    // MM-5B (#21): the configuration of the modules, one row per module.
    Embedded {
        version: 1,
        name: "module_config",
        sql: include_str!("../../migrations/0001_module_config.sql"),
    },
];

// A product list that breaks the rules does not compile.
const _: () = assert!(
    list_defect(MIGRATIONS).is_none(),
    "MIGRATIONS: versions must be 1, 2, 3… in order, names [a-z0-9_]+, SQL without CR"
);

/// The first rule a list breaks, as (index, reason); `None` for a valid list.
///
/// Versions must be exactly 1, 2, 3… in list order: this one check covers the
/// start at 1, the ascending order, gaps and duplicates.
pub(super) const fn list_defect(list: &[Embedded]) -> Option<(usize, &'static str)> {
    let mut index = 0;
    while index < list.len() {
        let entry = &list[index];
        if entry.version != index as i64 + 1 {
            return Some((index, "version is not the next number (1, 2, 3…)"));
        }
        let name = entry.name.as_bytes();
        if name.is_empty() {
            return Some((index, "name is empty"));
        }
        let mut at = 0;
        while at < name.len() {
            if !matches!(name[at], b'a'..=b'z' | b'0'..=b'9' | b'_') {
                return Some((index, "name is not [a-z0-9_]+"));
            }
            at += 1;
        }
        let sql = entry.sql.as_bytes();
        let mut at = 0;
        while at < sql.len() {
            if sql[at] == b'\r' {
                return Some((index, "SQL contains a carriage return"));
            }
            at += 1;
        }
        index += 1;
    }
    None
}

/// The file a migration is embedded from.
#[cfg(test)]
pub(super) fn file_name(entry: &Embedded) -> String {
    format!("{:04}_{}.sql", entry.version, entry.name)
}

/// What a migration run did.
pub(super) struct Applied {
    /// Migrations applied by this run.
    pub applied: usize,
    /// The schema version after it; 0 for an empty schema.
    pub latest: usize,
}

/// Brings the schema to the version of `list`.
///
/// Before anything is applied the list is validated and the versions already
/// in the database must be exactly `1..=k` with `k` no greater than the list
/// and with matching checksums; otherwise nothing is applied.
///
/// The caller runs this inside a transaction of its own (`database::migrate`)
/// and commits it afterwards: sqlx then wraps each migration and its record
/// in a savepoint instead of a transaction, and the migrations of one run are
/// applied all together or not at all.
pub(super) async fn run(
    conn: &mut SqliteConnection,
    list: &'static [Embedded],
) -> Result<Applied, String> {
    let migrations = resolve(list)?;
    conn.ensure_migrations_table()
        .await
        .map_err(|error| format!("could not create the migrations table: {error}"))?;
    let before = applied_prefix(conn, &migrations).await?;
    let migrator = Migrator::new(Source(migrations))
        .await
        .map_err(|error| error.to_string())?;
    // `run_direct`, not `run`: with `run` the future of every caller fails to
    // be `Send` ("implementation of `Acquire` is not general enough"), which
    // is the reason sqlx gives for this method. It is public but hidden from
    // the documentation; the sqlx version is pinned exactly (`=0.8.6`).
    migrator
        .run_direct(conn)
        .await
        .map_err(|error| error.to_string())?;
    Ok(Applied {
        applied: list.len() - before,
        latest: list.len(),
    })
}

/// The check for a database that cannot be written: nothing is created or
/// applied. The migrations table must exist and hold exactly the versions and
/// checksums of `list`.
pub(super) async fn verify_read_only(
    conn: &mut SqliteConnection,
    list: &'static [Embedded],
) -> Result<Applied, String> {
    let migrations = resolve(list)?;
    let tables: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = '_sqlx_migrations'",
    )
    .fetch_one(&mut *conn)
    .await
    .map_err(|error| format!("could not look for the migrations table: {error}"))?;
    if tables == 0 {
        return Err("the migrations table is missing and the database is read-only".to_owned());
    }
    let present = applied_prefix(conn, &migrations).await?;
    if present != migrations.len() {
        return Err(format!(
            "the database is read-only and has {present} of {} migrations",
            migrations.len()
        ));
    }
    Ok(Applied {
        applied: 0,
        latest: present,
    })
}

fn resolve(list: &'static [Embedded]) -> Result<Vec<Migration>, String> {
    if let Some((index, reason)) = list_defect(list) {
        return Err(format!("invalid migration list at index {index}: {reason}"));
    }
    Ok(list
        .iter()
        .map(|entry| {
            Migration::new(
                entry.version,
                Cow::Borrowed(entry.name),
                MigrationType::Simple,
                Cow::Borrowed(entry.sql),
                false,
            )
        })
        .collect())
}

/// How many migrations of the list the database already has: they must be
/// exactly versions `1..=k`, each with the checksum of the list.
async fn applied_prefix(
    conn: &mut SqliteConnection,
    migrations: &[Migration],
) -> Result<usize, String> {
    if let Some(version) = conn
        .dirty_version()
        .await
        .map_err(|error| format!("could not read the migrations table: {error}"))?
    {
        return Err(format!("migration {version} was applied only partially"));
    }
    let mut applied = conn
        .list_applied_migrations()
        .await
        .map_err(|error| format!("could not read the migrations table: {error}"))?;
    applied.sort_by_key(|migration| migration.version);
    for (index, found) in applied.iter().enumerate() {
        if found.version != index as i64 + 1 {
            return Err(format!(
                "applied versions are not 1..={}: found version {}",
                applied.len(),
                found.version
            ));
        }
        let Some(known) = migrations.get(index) else {
            return Err(format!(
                "the database is newer than the application: version {} is unknown",
                found.version
            ));
        };
        if known.checksum != found.checksum {
            return Err(format!(
                "migration {} was changed after it was applied",
                found.version
            ));
        }
    }
    Ok(applied.len())
}

/// Hands the embedded list to the sqlx migrator.
struct Source(Vec<Migration>);

impl std::fmt::Debug for Source {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Source({} migrations)", self.0.len())
    }
}

impl MigrationSource<'static> for Source {
    fn resolve(
        self,
    ) -> Pin<Box<dyn Future<Output = Result<Vec<Migration>, BoxDynError>> + Send + 'static>> {
        Box::pin(async move { Ok(self.0) })
    }
}
