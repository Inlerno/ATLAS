//! The module configuration store of the application (MM-5B, #21): the
//! [`ModuleConfigStore`] of the module manager on the SQLite storage
//! (ADR-016).
//!
//! The storage knows rows of plain values; this adapter turns them into
//! configurations and decides what a damaged record is. A record is damaged
//! when its row cannot be read as a configuration — `enabled` is neither 0
//! nor 1, or the settings are not JSON — the same rule for `load` and for
//! `replace_if_damaged`, so that only a record whose content is proven unusable
//! can be replaced (decision O-10b). Whether the settings suit the module is
//! not decided here: the manager checks them after `load`.
//!
//! Errors of the storage become a [`StoreError`] with a text for the log; no
//! stored value is ever part of it.

use serde_json::Value;

use super::config::{ModuleConfig, ModuleConfigStore, ReplaceResult, StoreError};
use super::contract::{BoxFuture, ModuleId};
use crate::storage::{ConfigStoreError, ReplaceCheck, Storage, StoredModuleConfig};

/// The text of `load` for a damaged record; names no value.
const DAMAGED: &str = "module configuration record is damaged";

/// [`ModuleConfigStore`] on the SQLite storage. Every call waits for the
/// opening of the database, bounded by the storage's readiness deadline.
#[derive(Clone)]
pub struct SqliteConfigStore {
    storage: Storage,
}

impl SqliteConfigStore {
    pub fn new(storage: Storage) -> Self {
        Self { storage }
    }
}

impl ModuleConfigStore for SqliteConfigStore {
    fn load<'a>(
        &'a self,
        id: &'a ModuleId,
    ) -> BoxFuture<'a, Result<Option<ModuleConfig>, StoreError>> {
        Box::pin(async move {
            match self.storage.read_module_config(id.as_str()).await {
                Ok(None) => Ok(None),
                Ok(Some(row)) => decode(&row)
                    .map(Some)
                    .map_err(|reason| StoreError(format!("{DAMAGED}: {reason}"))),
                Err(error) => Err(store_error(&error)),
            }
        })
    }

    fn save_batch<'a>(
        &'a self,
        entries: &'a [(ModuleId, ModuleConfig)],
    ) -> BoxFuture<'a, Result<(), StoreError>> {
        Box::pin(async move {
            let texts = entries
                .iter()
                .map(|(_, config)| encode(&config.settings))
                .collect::<Result<Vec<_>, _>>()?;
            let rows: Vec<(&str, bool, &str)> = entries
                .iter()
                .zip(&texts)
                .map(|((id, config), text)| (id.as_str(), config.enabled, text.as_str()))
                .collect();
            self.storage
                .write_module_configs(&rows)
                .await
                .map_err(|error| store_error(&error))
        })
    }

    fn replace_if_damaged<'a>(
        &'a self,
        id: &'a ModuleId,
        config: &'a ModuleConfig,
    ) -> BoxFuture<'a, Result<ReplaceResult, StoreError>> {
        Box::pin(async move {
            let text = encode(&config.settings)?;
            // Damage is proven only by a row that exists and does not decode:
            // a missing row is not damage (decision O-10c).
            let damaged =
                |row: Option<&StoredModuleConfig>| row.is_some_and(|row| decode(row).is_err());
            match self
                .storage
                .replace_module_config_if(id.as_str(), config.enabled, &text, damaged)
                .await
            {
                Ok(ReplaceCheck::Replaced) => Ok(ReplaceResult::Replaced),
                Ok(ReplaceCheck::NotDamaged) => Ok(ReplaceResult::NotDamaged),
                Err(error) => Err(store_error(&error)),
            }
        })
    }
}

/// A row as a configuration, or why it is damaged (a fixed text, no value).
fn decode(row: &StoredModuleConfig) -> Result<ModuleConfig, &'static str> {
    let enabled = match row.enabled {
        0 => false,
        1 => true,
        _ => return Err("enabled is neither 0 nor 1"),
    };
    let settings: Value =
        serde_json::from_str(&row.settings).map_err(|_| "settings are not JSON")?;
    Ok(ModuleConfig { enabled, settings })
}

fn encode(settings: &Value) -> Result<String, StoreError> {
    serde_json::to_string(settings)
        .map_err(|_| StoreError("module settings could not be serialized".to_owned()))
}

fn store_error(error: &ConfigStoreError) -> StoreError {
    StoreError(format!("module configuration storage: {error}"))
}

#[cfg(test)]
mod tests {
    use std::future::Future;
    use std::path::Path;
    use std::time::Duration;

    use serde_json::json;

    use super::*;
    use crate::events::bus::EventBus;
    use crate::modules::contract::{ModuleFactory, ModuleState};
    use crate::modules::manager::{self, ApplyOutcome, ModuleManagerHandle};
    use crate::modules::plan::{ChangeAction, Confirmation};
    use crate::modules::testing::{FakeFactory, id};
    use crate::storage::test_support::{
        TempDataDir, database_bytes, lose_the_database, module_config_rows, plant_module_config_row,
    };

    /// The normal clock: the storage works on a thread of its own, which a
    /// paused clock does not see (as in the storage tests).
    fn run<F: Future>(test: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread()
            .enable_time()
            .build()
            .expect("test runtime")
            .block_on(test)
    }

    async fn opened(root: &Path) -> Storage {
        let storage = Storage::new(Ok(root.to_path_buf()));
        storage.open().await;
        storage
    }

    fn config(enabled: bool, settings: Value) -> ModuleConfig {
        ModuleConfig { enabled, settings }
    }

    fn row(module: &str, enabled: i64, settings: &str) -> (String, i64, String) {
        (module.to_owned(), enabled, settings.to_owned())
    }

    // -----------------------------------------------------------------------
    // The store
    // -----------------------------------------------------------------------

    #[test]
    fn saved_configuration_is_loaded_after_a_reopening() {
        run(async {
            let root = TempDataDir::new("adapter-roundtrip");
            let storage = opened(root.path()).await;
            let store = SqliteConfigStore::new(storage.clone());
            assert_eq!(store.load(&id("t.a")).await, Ok(None));
            store
                .save_batch(&[
                    (id("t.a"), config(true, json!({"level": 3, "name": "x"}))),
                    (id("t.b"), config(false, json!({}))),
                ])
                .await
                .expect("saved");
            storage.close().await;

            let storage = opened(root.path()).await;
            let store = SqliteConfigStore::new(storage.clone());
            assert_eq!(
                store.load(&id("t.a")).await,
                Ok(Some(config(true, json!({"level": 3, "name": "x"}))))
            );
            assert_eq!(
                store.load(&id("t.b")).await,
                Ok(Some(config(false, json!({}))))
            );
            storage.close().await;
        });
    }

    #[test]
    fn the_last_entry_of_an_id_wins_as_in_memory() {
        run(async {
            let root = TempDataDir::new("adapter-duplicates");
            let storage = opened(root.path()).await;
            let store = SqliteConfigStore::new(storage.clone());
            store
                .save_batch(&[
                    (id("t.a"), config(true, json!({"v": 1}))),
                    (id("t.a"), config(false, json!({"v": 2}))),
                ])
                .await
                .expect("saved");
            assert_eq!(
                store.load(&id("t.a")).await,
                Ok(Some(config(false, json!({"v": 2}))))
            );
            storage.close().await;
        });
    }

    #[test]
    fn a_row_that_does_not_decode_is_damaged_and_names_no_value() {
        run(async {
            let root = TempDataDir::new("adapter-damaged");
            opened(root.path()).await.close().await;
            plant_module_config_row(root.path(), "t.json", 1, "secret-value-not-json").await;
            plant_module_config_row(root.path(), "t.flag", 2, "{}").await;
            plant_module_config_row(root.path(), "t.ok", 1, r#"{"invalid": true}"#).await;
            let storage = opened(root.path()).await;
            let store = SqliteConfigStore::new(storage.clone());

            let error = store.load(&id("t.json")).await.expect_err("damaged");
            assert_eq!(error.0, format!("{DAMAGED}: settings are not JSON"));
            assert!(!error.0.contains("secret-value"));
            let error = store.load(&id("t.flag")).await.expect_err("damaged");
            assert_eq!(error.0, format!("{DAMAGED}: enabled is neither 0 nor 1"));
            // Settings the module may refuse are not damage: they decode.
            assert_eq!(
                store.load(&id("t.ok")).await,
                Ok(Some(config(true, json!({"invalid": true}))))
            );
            storage.close().await;
        });
    }

    #[test]
    fn only_a_damaged_row_is_replaced() {
        run(async {
            let root = TempDataDir::new("adapter-replace");
            opened(root.path()).await.close().await;
            plant_module_config_row(root.path(), "t.damaged", 1, "not json").await;
            plant_module_config_row(root.path(), "t.usable", 1, r#"{"invalid": true}"#).await;
            let storage = opened(root.path()).await;
            let store = SqliteConfigStore::new(storage.clone());
            let fresh = config(false, json!({"fresh": true}));

            assert_eq!(
                store.replace_if_damaged(&id("t.usable"), &fresh).await,
                Ok(ReplaceResult::NotDamaged)
            );
            assert_eq!(
                store.replace_if_damaged(&id("t.missing"), &fresh).await,
                Ok(ReplaceResult::NotDamaged)
            );
            assert_eq!(
                store.replace_if_damaged(&id("t.damaged"), &fresh).await,
                Ok(ReplaceResult::Replaced)
            );
            assert_eq!(store.load(&id("t.damaged")).await, Ok(Some(fresh.clone())));
            storage.close().await;
            assert_eq!(
                module_config_rows(root.path()).await,
                vec![
                    row("t.damaged", 0, r#"{"fresh":true}"#),
                    row("t.usable", 1, r#"{"invalid": true}"#),
                ]
            );
        });
    }

    #[test]
    fn a_storage_error_is_never_taken_for_damage() {
        run(async {
            let root = TempDataDir::new("adapter-unavailable");
            opened(root.path()).await.close().await;
            plant_module_config_row(root.path(), "t.a", 1, "not json").await;
            // The data directory is gone, the marker stays: unavailable.
            std::fs::remove_dir_all(root.path().join("data")).expect("remove data");
            let storage = opened(root.path()).await;
            let store = SqliteConfigStore::new(storage.clone());
            let expected =
                StoreError("module configuration storage: storage unavailable".to_owned());
            assert_eq!(store.load(&id("t.a")).await, Err(expected.clone()));
            assert_eq!(
                store
                    .replace_if_damaged(&id("t.a"), &config(false, json!({})))
                    .await,
                Err(expected.clone())
            );
            assert_eq!(
                store
                    .save_batch(&[(id("t.a"), config(false, json!({})))])
                    .await,
                Err(expected)
            );
            storage.close().await;
            assert!(!root.path().join("data").exists(), "nothing was created");
        });
    }

    // -----------------------------------------------------------------------
    // The module manager on the real store (MM-5A behaviour, again)
    // -----------------------------------------------------------------------

    /// A manager for fake modules `(id, dependencies)` on `storage`, ready.
    async fn manager_on(storage: &Storage, modules: &[(&str, &[&str])]) -> ModuleManagerHandle {
        let catalog: Vec<Box<dyn ModuleFactory>> = modules
            .iter()
            .map(|(module, dependencies)| {
                Box::new(FakeFactory::new(module, dependencies).0) as Box<dyn ModuleFactory>
            })
            .collect();
        let store = Box::new(SqliteConfigStore::new(storage.clone()));
        let (manager, actor) = manager::create(catalog, store, EventBus::new(4096));
        tokio::spawn(actor);
        for _ in 0..1000 {
            if manager.is_ready() {
                return manager;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("the manager did not become ready");
    }

    async fn enable(manager: &ModuleManagerHandle, module: &str) {
        let plan = manager
            .plan(ChangeAction::Enable, &id(module))
            .expect("plan");
        let confirmation = Confirmation {
            confirmed: true,
            acknowledged: plan.affected,
        };
        match manager
            .apply(ChangeAction::Enable, id(module), confirmation)
            .await
        {
            Ok(ApplyOutcome::Applied(_)) => {}
            other => panic!("enable {module}: {other:?}"),
        }
    }

    fn state(manager: &ModuleManagerHandle, module: &str) -> (Option<bool>, String) {
        let status = manager.statuses().expect("ready")[&id(module)].clone();
        let state = match status.state {
            ModuleState::Running => "Running".to_owned(),
            ModuleState::Stopped => "Stopped".to_owned(),
            ModuleState::ConfigUnavailable { .. } => "ConfigUnavailable".to_owned(),
            ModuleState::Blocked { by, reason } => format!("Blocked({by}, {reason:?})"),
            other => format!("{other:?}"),
        };
        (status.enabled, state)
    }

    #[test]
    fn decisions_and_settings_survive_a_restart() {
        run(async {
            let root = TempDataDir::new("manager-restart");
            let modules: &[(&str, &[&str])] = &[("t.a", &[]), ("t.b", &["t.a"])];
            let storage = opened(root.path()).await;
            let manager = manager_on(&storage, modules).await;
            enable(&manager, "t.b").await;
            manager
                .update_settings(id("t.a"), json!({"level": 2}))
                .await
                .expect("settings");
            manager.shutdown().await.expect("shutdown");
            storage.close().await;

            // The next run of the application.
            let storage = opened(root.path()).await;
            let manager = manager_on(&storage, modules).await;
            assert_eq!(state(&manager, "t.a"), (Some(true), "Running".to_owned()));
            assert_eq!(state(&manager, "t.b"), (Some(true), "Running".to_owned()));
            assert_eq!(
                *manager.get_settings(&id("t.a")).expect("settings").value,
                json!({"level": 2})
            );
            manager.shutdown().await.expect("shutdown");
            storage.close().await;
            assert_eq!(
                module_config_rows(root.path()).await,
                vec![row("t.a", 1, r#"{"level":2}"#), row("t.b", 1, "{}")]
            );
        });
    }

    #[test]
    fn a_damaged_record_makes_its_module_config_unavailable_and_is_not_overwritten() {
        run(async {
            let root = TempDataDir::new("manager-damaged");
            opened(root.path()).await.close().await;
            plant_module_config_row(root.path(), "t.a", 1, "not json").await;
            // The dependent is enabled: it would start if it could.
            plant_module_config_row(root.path(), "t.b", 1, "{}").await;
            let before = database_bytes(root.path());
            let modules: &[(&str, &[&str])] = &[("t.a", &[]), ("t.b", &["t.a"])];
            let storage = opened(root.path()).await;
            let manager = manager_on(&storage, modules).await;
            assert_eq!(
                state(&manager, "t.a"),
                (None, "ConfigUnavailable".to_owned())
            );
            assert_eq!(
                state(&manager, "t.b"),
                (
                    Some(true),
                    "Blocked(t.a, DependencyConfigUnavailable)".to_owned()
                )
            );
            // Settings of such a module cannot be written.
            assert!(manager.update_settings(id("t.a"), json!({})).await.is_err());
            manager.shutdown().await.expect("shutdown");
            storage.close().await;
            assert_eq!(database_bytes(root.path()), before);
        });
    }

    #[test]
    fn an_unavailable_storage_makes_every_module_config_unavailable() {
        run(async {
            let root = TempDataDir::new("manager-unavailable");
            lose_the_database(root.path());
            let storage = opened(root.path()).await;
            let manager = manager_on(&storage, &[("t.a", &[]), ("t.b", &[])]).await;
            assert_eq!(
                state(&manager, "t.a"),
                (None, "ConfigUnavailable".to_owned())
            );
            assert_eq!(
                state(&manager, "t.b"),
                (None, "ConfigUnavailable".to_owned())
            );
            manager.shutdown().await.expect("shutdown");
            storage.close().await;
        });
    }
}
