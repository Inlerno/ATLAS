# Local fork of `sqlx-sqlite` 0.8.6 for ATLAS

This directory is **not an official sqlx release**. It is a temporary local
copy of the `sqlx-sqlite` crate, kept in the ATLAS repository to remove
RUSTSEC-2026-0459 (CVE-2026-119375) from the build. See ADR-016 in
`docs/DECISIONS.md`.

## Origin

- Package: `sqlx-sqlite` 0.8.6, exactly as published on crates.io.
- Archive: `sqlx-sqlite-0.8.6.crate`, SHA-256
  `c2d12fe70b2c1b4401038055f90f151b78208de1f9f89a7dbfd41587a10c3eea`
  (the checksum `Cargo.lock` recorded for the registry package).
- Upstream: <https://github.com/launchbadge/sqlx>, commit
  `bab1b022bd56a64f9a08b46b36b97c5cff19d77e`, path `sqlx-sqlite`
  (from `.cargo_vcs_info.json`, kept here unchanged).
- Licence: MIT OR Apache-2.0, unchanged. `LICENSE-MIT` and `LICENSE-APACHE`
  are the files of the published package; the copyright belongs to the sqlx
  authors. The changes made here are offered under
  the same terms.

## The changes

There are two, and nothing else differs from the published package.

**1. `Cargo.toml`, one line** — a fixed SQLite:

```diff
 [dependencies.libsqlite3-sys]
-version = "0.30.1"
+version = "0.40.0"
```

**2. `src/connection/establish.rs`** — no checkpoint when a connection is
closed. In `EstablishParams::establish`, straight after the check of the
result of `sqlite3_open_v2()` and before anything else is done with the
handle, the fork calls

```c
sqlite3_db_config(db, SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, 1, &enabled);
```

and fails the connection if SQLite reports an error or `enabled != 1`. The
import list of the file gains `SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE`. The change
is marked `ATLAS fork` in the source. It applies to every connection opened
through this crate; there is no option to turn it off, and the public API of
sqlx is unchanged.

`Cargo.toml.orig` is the upstream manifest as published and still shows
`0.30.1`; cargo does not read it. This file, `ATLAS_FORK.md`, is the only
file added.

To see the exact difference: unpack the archive named above and run
`diff -r sqlx-sqlite-0.8.6 vendor/sqlx-sqlite`.

## Why

`libsqlite3-sys` 0.30.1 bundles SQLite 3.46.0, which is affected by
RUSTSEC-2026-0459. The fix is in `libsqlite3-sys` >= 0.39.0;
0.40.0 bundles SQLite 3.54.1. `sqlx-sqlite` 0.8.6 requires
`libsqlite3-sys` 0.30.x and the newest release, 0.9.0, requires `< 0.38.0`,
so no published sqlx accepts a fixed version. Only one `libsqlite3-sys` can be
in a build (`links = "sqlite3"`), and a `[patch]` of `libsqlite3-sys` alone
cannot satisfy the 0.30.x requirement.

## Why no checkpoint on close

SQLite attaches a `-wal` file it finds next to a database on the first read,
whatever journal mode the application expects, and `sqlite3_close()` then
copies its frames into the database file and deletes it. ATLAS uses the
rollback journal and treats a WAL file next to its database as foreign. sqlx
runs its own PRAGMAs inside `connect()`, and one of them
(`PRAGMA synchronous`) already reads the file, so the flag has to be set
before sqlx executes anything: only the driver can do that. With the flag
set, closing a connection (`close()`, a drop, an error inside `connect()`)
leaves the database file and the `-wal` file as they are.

What the flag does not do: it does not stop SQLite from reading an attached
WAL, from creating or rewriting the `-shm` file, or from deleting a `-wal`
file next to a database that is still empty. See ADR-016.

## How it is used

`src-tauri/Cargo.toml`:

```toml
[patch.crates-io]
sqlx-sqlite = { path = "../vendor/sqlx-sqlite" }
```

## When to remove

Remove this directory and the `[patch.crates-io]` entry when ATLAS can use an
official sqlx release whose `sqlx-sqlite` accepts `libsqlite3-sys` >= 0.39.0
within the project's Rust version, then update `Cargo.lock` and ADR-016.

Removing the fork also removes change 2. ATLAS must then set
`SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE` some other way before the first statement
of a connection, or the protection described in ADR-016 is gone; the storage
test `every_connection_is_opened_without_checkpoint_on_close` fails if it is.

Until then: do not edit the sources here beyond the two changes. To re-create
the copy, unpack the archive named above and re-apply them.
