//! Module configuration (issue #10, MM-5A, ADR-015): the user's decision
//! (`enabled`) and the module's own settings, the store that keeps them and
//! the checks every settings value passes.
//!
//! The lifecycle manager owns the configuration: it reads the store once, at
//! startup, and afterwards only writes to it, always one atomic batch per
//! command. The application keeps it in SQLite between runs
//! ([`super::config_sqlite`], MM-5B); the store here keeps everything in
//! memory, for tests.
//!
//! Settings values never reach the log, events or `Debug` output: they may
//! hold user data. Secrets do not belong in settings at all — only a reference
//! to the operating system's secure storage (e.g. `token_ref`).

#[cfg(test)]
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::io;
#[cfg(test)]
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use serde_json::Value;
use thiserror::Error;

use super::contract::{BoxFuture, ModuleId};

/// Largest settings value: compact JSON, in bytes.
pub const MAX_SETTINGS_BYTES: usize = 65_536;
/// Deepest nesting of objects and arrays in a settings value; the root object
/// is level 1.
pub const MAX_SETTINGS_DEPTH: usize = 128;

/// Normalized key names that look like secrets (lowercase, letters and digits
/// only). A safety net, not a guarantee: the rule is that settings hold no
/// secrets, and review enforces it.
const SECRET_KEYS: &[&str] = &[
    "password",
    "passwd",
    "passphrase",
    "secret",
    "token",
    "apikey",
    "accesstoken",
    "refreshtoken",
    "authtoken",
    "bottoken",
    "privatekey",
    "clientsecret",
    "credentials",
];

/// One stored record: the user's decision and the module's settings.
#[derive(Clone, PartialEq)]
pub struct ModuleConfig {
    pub enabled: bool,
    pub settings: Value,
}

/// Without the settings values (they may hold user data).
impl fmt::Debug for ModuleConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ModuleConfig")
            .field("enabled", &self.enabled)
            .field("settings", &"<hidden>")
            .finish()
    }
}

/// A store operation failed. The text is for the log only: the user sees a
/// fixed message.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("{0}")]
pub struct StoreError(pub String);

/// What [`ModuleConfigStore::replace_if_damaged`] did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplaceResult {
    /// The stored record was damaged and has been replaced.
    Replaced,
    /// The stored record is usable, or there is none: nothing was written.
    NotDamaged,
}

/// Where module configuration is kept.
///
/// Asynchronous, because the real store (SQLite) does I/O. The manager reads
/// every module once at startup and writes only whole batches.
///
/// A record is **damaged** when it exists but cannot be read as a
/// configuration: the reason [`load`](Self::load) fails because of the
/// content. Settings that are read but refused by the checks of the module
/// are not damage: `load` returns them and the manager marks them invalid.
/// An error of the store itself — it cannot be reached, it is busy, read-only
/// or closed — is never taken for damage.
pub trait ModuleConfigStore: Send + Sync {
    /// The record of `id`, or `None` if there is none yet. `Err` if the
    /// record is damaged or the store cannot be read.
    fn load<'a>(
        &'a self,
        id: &'a ModuleId,
    ) -> BoxFuture<'a, Result<Option<ModuleConfig>, StoreError>>;

    /// Saves all entries or none of them, also if the future is dropped; a
    /// dropped call does not tell which. If an id occurs more than once, the
    /// last entry wins. Records of other modules are left untouched.
    fn save_batch<'a>(
        &'a self,
        entries: &'a [(ModuleId, ModuleConfig)],
    ) -> BoxFuture<'a, Result<(), StoreError>>;

    /// Replaces the record of `id` with `config` only if the record stored
    /// now is damaged; a usable record, or none, is left as it is. The check
    /// and the write are one atomic step, so nothing can change the record in
    /// between: the record is checked again here, not taken from an earlier
    /// `load`. All or nothing, also if the future is dropped; a dropped call
    /// does not tell which.
    fn replace_if_damaged<'a>(
        &'a self,
        id: &'a ModuleId,
        config: &'a ModuleConfig,
    ) -> BoxFuture<'a, Result<ReplaceResult, StoreError>>;
}

/// Configuration kept in memory, for tests: what a run of the application
/// keeps in SQLite. Clones share the data, so a test can start a second
/// manager on the same store, as the next run of the application would.
#[cfg(test)]
#[derive(Clone, Default)]
pub struct InMemoryConfigStore {
    records: Arc<Mutex<Records>>,
}

#[cfg(test)]
#[derive(Default)]
struct Records {
    configs: BTreeMap<ModuleId, ModuleConfig>,
    /// Records that exist but are damaged (only tests make them).
    damaged: BTreeSet<ModuleId>,
}

/// The text of `load` for a damaged record; names no value.
#[cfg(test)]
const DAMAGED: &str = "module configuration record is damaged";

#[cfg(test)]
impl InMemoryConfigStore {
    /// A copy of the record of `id`; `None` for a damaged one.
    pub fn get(&self, id: &ModuleId) -> Option<ModuleConfig> {
        lock(&self.records).configs.get(id).cloned()
    }

    /// All usable records.
    pub fn records(&self) -> BTreeMap<ModuleId, ModuleConfig> {
        lock(&self.records).configs.clone()
    }

    /// Makes the record of `id` damaged, as an outside edit of the database
    /// could: `load` fails because of its content.
    pub fn damage(&self, id: &ModuleId) {
        let mut records = lock(&self.records);
        records.configs.remove(id);
        records.damaged.insert(id.clone());
    }
}

#[cfg(test)]
impl fmt::Debug for InMemoryConfigStore {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let records = lock(&self.records);
        f.debug_struct("InMemoryConfigStore")
            .field("records", &records.configs.len())
            .field("damaged", &records.damaged.len())
            .finish()
    }
}

#[cfg(test)]
impl ModuleConfigStore for InMemoryConfigStore {
    fn load<'a>(
        &'a self,
        id: &'a ModuleId,
    ) -> BoxFuture<'a, Result<Option<ModuleConfig>, StoreError>> {
        Box::pin(async move {
            let records = lock(&self.records);
            if records.damaged.contains(id) {
                return Err(StoreError(DAMAGED.to_owned()));
            }
            Ok(records.configs.get(id).cloned())
        })
    }

    fn save_batch<'a>(
        &'a self,
        entries: &'a [(ModuleId, ModuleConfig)],
    ) -> BoxFuture<'a, Result<(), StoreError>> {
        // One lock for the whole batch and no await inside: either the future
        // never runs (nothing is saved) or the batch is saved completely.
        Box::pin(async move {
            let mut records = lock(&self.records);
            for (id, config) in entries {
                // A written record replaces whatever was there.
                records.damaged.remove(id);
                records.configs.insert(id.clone(), config.clone());
            }
            Ok(())
        })
    }

    fn replace_if_damaged<'a>(
        &'a self,
        id: &'a ModuleId,
        config: &'a ModuleConfig,
    ) -> BoxFuture<'a, Result<ReplaceResult, StoreError>> {
        // The check and the write under one lock, without an await: the same
        // guarantees as `save_batch`.
        Box::pin(async move {
            let mut records = lock(&self.records);
            if !records.damaged.remove(id) {
                return Ok(ReplaceResult::NotDamaged);
            }
            records.configs.insert(id.clone(), config.clone());
            Ok(ReplaceResult::Replaced)
        })
    }
}

/// The records stay usable if a holder panicked: recover the lock.
#[cfg(test)]
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// Why a settings value is refused by the common checks. The text names the
/// place, never the value, so it is safe to show and to log.
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum SettingsProblem {
    #[error("вложенность больше {MAX_SETTINGS_DEPTH}")]
    TooDeep,
    #[error("настройки должны быть объектом JSON")]
    NotAnObject,
    #[error("размер больше {MAX_SETTINGS_BYTES} байт")]
    TooLarge,
    #[error("ключ `{path}` похож на секрет: секреты хранятся только в защищённом хранилище ОС")]
    SecretKey { path: String },
}

/// The checks every settings value passes before the module's own validator,
/// in this order: nesting depth (iteratively, before anything recursive),
/// root object, size of compact JSON (counted, not kept in memory), keys that
/// look like secrets at any depth.
pub fn check_settings(value: &Value) -> Result<(), SettingsProblem> {
    if depth_exceeds(value, MAX_SETTINGS_DEPTH) {
        return Err(SettingsProblem::TooDeep);
    }
    if !value.is_object() {
        return Err(SettingsProblem::NotAnObject);
    }
    if compact_size_exceeds(value, MAX_SETTINGS_BYTES) {
        return Err(SettingsProblem::TooLarge);
    }
    if let Some(path) = secret_key_path(value) {
        return Err(SettingsProblem::SecretKey { path });
    }
    Ok(())
}

/// `true` if objects and arrays nest deeper than `limit`. Iterative, so a
/// hostile value cannot overflow the stack.
fn depth_exceeds(value: &Value, limit: usize) -> bool {
    let mut stack = vec![(value, 1usize)];
    while let Some((value, depth)) = stack.pop() {
        let children: Box<dyn Iterator<Item = &Value>> = match value {
            Value::Object(map) => Box::new(map.values()),
            Value::Array(items) => Box::new(items.iter()),
            _ => continue,
        };
        if depth > limit {
            return true;
        }
        stack.extend(children.map(|child| (child, depth + 1)));
    }
    false
}

/// `true` if the compact JSON of `value` is longer than `limit` bytes. Writes
/// into a counter that stops at the limit; the depth is checked before, so the
/// recursive serializer is safe here.
fn compact_size_exceeds(value: &Value, limit: usize) -> bool {
    struct Counter {
        written: usize,
        limit: usize,
    }
    impl io::Write for Counter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.written += buf.len();
            if self.written > self.limit {
                return Err(io::Error::other("limit"));
            }
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }
    let mut counter = Counter { written: 0, limit };
    serde_json::to_writer(&mut counter, value).is_err()
}

/// The path of the first key that looks like a secret, e.g. `engine.api-key`
/// or `accounts[2].Bot_Token`. Iterative; arrays are searched too.
fn secret_key_path(value: &Value) -> Option<String> {
    let mut stack = vec![(value, String::new())];
    while let Some((value, path)) = stack.pop() {
        match value {
            Value::Object(map) => {
                for (key, child) in map {
                    let child_path = if path.is_empty() {
                        key.clone()
                    } else {
                        format!("{path}.{key}")
                    };
                    if is_secret_key(key) {
                        return Some(child_path);
                    }
                    stack.push((child, child_path));
                }
            }
            Value::Array(items) => {
                for (index, child) in items.iter().enumerate() {
                    stack.push((child, format!("{path}[{index}]")));
                }
            }
            _ => {}
        }
    }
    None
}

fn is_secret_key(key: &str) -> bool {
    let normalized: String = key
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect();
    SECRET_KEYS.contains(&normalized.as_str())
}

#[cfg(test)]
mod tests {
    use std::future::Future;
    use std::pin::pin;
    use std::task::{Context, Poll, Waker};

    use serde_json::json;

    use super::*;

    fn id(value: &str) -> ModuleId {
        ModuleId::new(value).expect("valid module id")
    }

    fn ready<F: Future>(future: F) -> F::Output {
        match pin!(future).poll(&mut Context::from_waker(Waker::noop())) {
            Poll::Ready(output) => output,
            Poll::Pending => panic!("the in-memory store never waits"),
        }
    }

    fn config(enabled: bool, settings: Value) -> ModuleConfig {
        ModuleConfig { enabled, settings }
    }

    fn nested(depth: usize) -> Value {
        let mut value = json!({});
        for _ in 1..depth {
            value = json!({ "n": value });
        }
        value
    }

    #[test]
    fn save_batch_saves_all_or_nothing() {
        let store = InMemoryConfigStore::default();
        let batch = vec![
            (id("t.a"), config(true, json!({}))),
            (id("t.b"), config(false, json!({"x": 1}))),
        ];
        // Dropped before it ran: nothing is saved.
        drop(store.save_batch(&batch));
        assert!(store.records().is_empty());
        // Completed: everything is saved.
        ready(store.save_batch(&batch)).expect("saved");
        assert_eq!(store.records().len(), 2);
        assert_eq!(store.get(&id("t.b")), Some(config(false, json!({"x": 1}))));
    }

    #[test]
    fn load_returns_what_was_saved() {
        let store = InMemoryConfigStore::default();
        assert_eq!(ready(store.load(&id("t.a"))), Ok(None));
        let batch = [(id("t.a"), config(true, json!({"level": 3})))];
        ready(store.save_batch(&batch)).expect("saved");
        assert_eq!(
            ready(store.load(&id("t.a"))),
            Ok(Some(config(true, json!({"level": 3}))))
        );
    }

    #[test]
    fn clones_share_the_data() {
        let store = InMemoryConfigStore::default();
        let clone = store.clone();
        ready(store.save_batch(&[(id("t.a"), config(true, json!({})))])).expect("saved");
        assert_eq!(
            ready(clone.load(&id("t.a"))),
            Ok(Some(config(true, json!({}))))
        );
    }

    #[test]
    fn records_of_other_modules_are_left_untouched() {
        let store = InMemoryConfigStore::default();
        ready(store.save_batch(&[(id("old.module"), config(true, json!({"k": 1})))]))
            .expect("saved");
        ready(store.save_batch(&[(id("t.a"), config(false, json!({})))])).expect("saved");
        assert_eq!(
            store.get(&id("old.module")),
            Some(config(true, json!({"k": 1})))
        );
    }

    #[test]
    fn the_last_entry_of_an_id_wins() {
        let store = InMemoryConfigStore::default();
        let batch = [
            (id("t.a"), config(true, json!({"v": 1}))),
            (id("t.a"), config(false, json!({"v": 2}))),
        ];
        ready(store.save_batch(&batch)).expect("saved");
        assert_eq!(store.get(&id("t.a")), Some(config(false, json!({"v": 2}))));
    }

    #[test]
    fn a_damaged_record_fails_to_load_without_naming_a_value() {
        let store = InMemoryConfigStore::default();
        store.damage(&id("t.a"));
        let error = ready(store.load(&id("t.a"))).expect_err("damaged");
        assert_eq!(error, StoreError(DAMAGED.to_owned()));
        assert_eq!(ready(store.load(&id("t.b"))), Ok(None));
    }

    #[test]
    fn only_a_damaged_record_is_replaced() {
        let store = InMemoryConfigStore::default();
        ready(store.save_batch(&[(id("t.usable"), config(true, json!({"k": 1})))])).expect("saved");
        store.damage(&id("t.damaged"));
        let fresh = config(false, json!({"fresh": true}));

        assert_eq!(
            ready(store.replace_if_damaged(&id("t.usable"), &fresh)),
            Ok(ReplaceResult::NotDamaged)
        );
        assert_eq!(
            store.get(&id("t.usable")),
            Some(config(true, json!({"k": 1})))
        );
        assert_eq!(
            ready(store.replace_if_damaged(&id("t.missing"), &fresh)),
            Ok(ReplaceResult::NotDamaged)
        );
        assert_eq!(store.get(&id("t.missing")), None);

        // Dropped before it ran: nothing changes.
        drop(store.replace_if_damaged(&id("t.damaged"), &fresh));
        assert!(ready(store.load(&id("t.damaged"))).is_err());
        assert_eq!(
            ready(store.replace_if_damaged(&id("t.damaged"), &fresh)),
            Ok(ReplaceResult::Replaced)
        );
        assert_eq!(ready(store.load(&id("t.damaged"))), Ok(Some(fresh.clone())));
        // Once replaced, the record is usable: a second call writes nothing.
        assert_eq!(
            ready(store.replace_if_damaged(&id("t.damaged"), &config(true, json!({})))),
            Ok(ReplaceResult::NotDamaged)
        );
        assert_eq!(store.get(&id("t.damaged")), Some(fresh));
    }

    #[test]
    fn debug_hides_settings_values() {
        let record = config(true, json!({"user_name": "Alice-private-value"}));
        let text = format!("{record:?}");
        assert!(!text.contains("Alice-private-value"), "{text}");
        assert!(text.contains("enabled: true"), "{text}");
        let store = InMemoryConfigStore::default();
        ready(store.save_batch(&[(id("t.a"), record)])).expect("saved");
        assert!(!format!("{store:?}").contains("Alice-private-value"));
    }

    #[test]
    fn size_depth_and_secret_key_checks() {
        // Size: 65 536 bytes pass, 65 537 do not. `{"s":"…"}` is 8 bytes plus
        // the string.
        let at_limit = json!({ "s": "x".repeat(MAX_SETTINGS_BYTES - 8) });
        assert_eq!(
            serde_json::to_string(&at_limit).expect("json").len(),
            MAX_SETTINGS_BYTES
        );
        assert_eq!(check_settings(&at_limit), Ok(()));
        let over = json!({ "s": "x".repeat(MAX_SETTINGS_BYTES - 7) });
        assert_eq!(check_settings(&over), Err(SettingsProblem::TooLarge));

        // Depth: 128 pass, 129 do not; arrays count as levels too.
        assert_eq!(check_settings(&nested(MAX_SETTINGS_DEPTH)), Ok(()));
        assert_eq!(
            check_settings(&nested(MAX_SETTINGS_DEPTH + 1)),
            Err(SettingsProblem::TooDeep)
        );
        let mut array_deep = json!({});
        for _ in 1..=MAX_SETTINGS_DEPTH {
            array_deep = json!([array_deep]);
        }
        assert_eq!(
            check_settings(&json!({ "a": array_deep })),
            Err(SettingsProblem::TooDeep)
        );
        // A very deep value is refused without overflowing the stack.
        let mut hostile = json!(1);
        for _ in 0..100_000 {
            hostile = Value::Array(vec![hostile]);
        }
        assert_eq!(check_settings(&hostile), Err(SettingsProblem::TooDeep));
        std::mem::forget(hostile); // dropping it recursively is not under test

        // The root is an object.
        for value in [json!(null), json!(1), json!("x"), json!([])] {
            assert_eq!(check_settings(&value), Err(SettingsProblem::NotAnObject));
        }
        assert_eq!(check_settings(&json!({})), Ok(()));

        // Keys that look like secrets, at any depth and in arrays; the error
        // names the path, never the value.
        for (value, path) in [
            (json!({"password": "hunter2-value"}), "password"),
            (
                json!({"engine": {"api-key": "hunter2-value"}}),
                "engine.api-key",
            ),
            (
                json!({"accounts": [{}, {}, {"Bot_Token": "hunter2-value"}]}),
                "accounts[2].Bot_Token",
            ),
            (json!({"Client Secret": "hunter2-value"}), "Client Secret"),
        ] {
            let problem = check_settings(&value).expect_err("secret-like key");
            assert_eq!(
                problem,
                SettingsProblem::SecretKey {
                    path: path.to_owned()
                }
            );
            assert!(!problem.to_string().contains("hunter2-value"));
        }
        for value in [
            json!({"token_ref": "atlas/telegram"}),
            json!({"secret_ref": "atlas/x"}),
            json!({"max_tokens": 512}),
            json!({"tokens": 3}),
        ] {
            assert_eq!(check_settings(&value), Ok(()), "{value}");
        }
    }
}
