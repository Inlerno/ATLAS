# REV3 — источники и трассировка

## 1. Прочитанные источники

### 1.1 Репозиторий `Inlerno/ATLAS`, `main` = `e250a07beea046a551a9fc8cc6ca2fc0ff59d54e`

| Источник | Что использовано |
|---|---|
| `CLAUDE.md` | стек, правила процесса, безопасность |
| `docs/ROADMAP.md:1–12` | этапы 0–8; Stage 7: Telegram allowlist, «token storage» |
| `docs/ARCHITECTURE.md:145–155, 187–188` | порядок выхода, «после модулей писать некому» |
| `docs/DECISIONS.md` (ADR-001…016; решения 3, 12, 23, 24, 28, 31; строки 17, 49, 79, 183, 197, 233) | совместимость (10 §1) |
| `src-tauri/src/modules/manager.rs` | преобразование ошибок, `ShutDown`, прерванные проверки здоровья, очередь команд при остановке (07 §5) |
| `src-tauri/src/commands/modules.rs:155–195` | форма существующих команд (07 §2.3, 06 §4.3) |
| `src-tauri/src/dto/modules.rs` | `ModuleDto` без значений настроек |
| `src-tauri/src/storage/mod.rs:299–324` | типизированные операции конфигурации (CF-5, F-11) |
| `src-tauri/tauri.conf.json:21` | `csp: null` (F-17) |
| `src-tauri/Cargo.toml` | нет крейта `windows`; версии Tauri, sqlx |
| `git log` (`main`) | авторство коммитов (13 §2) |

### 1.2 Предыдущие пакеты

| Источник | Состав |
|---|---|
| REV2 | 12 файлов: `README`, `MOBILE_ARCHITECTURE`, `SECURITY_PERMISSION_MATRIX`, `REQUEST_LIFECYCLE`, `IOS_LICENSING_REVIEW`, `MULTI_PLATFORM_ROADMAP`, `DEPENDENCY_MAP`, `PLATFORM_COMPATIBILITY_AUDIT`, `MOBILE_IMPLEMENTATION_ISSUES`, `MPA_ADR_DRAFTS`, `OWNER_DECISIONS`, `CHANGELOG`; копия в проекте Claude `claude/MPA_MOBILE_ARCHITECTURE_PACKAGE.md` |
| Ревью REV2 | 7 документов: `ARCHITECTURAL_REVIEW`, `ARCHITECTURE_RISKS`, `CONFLICT_RESOLUTION`, `ROADMAP_VALIDATION`, `OWNER_DECISIONS_RECOMMENDATIONS`, `ADR_PROPOSAL`, `FINAL_RECOMMENDATION`; объединённая копия; `claude/MPA_REV2_REVIEW.md` |
| ТЗ владельца | первое ТЗ MPA; ТЗ REV2 (2026-11-20); ТЗ ревью; ТЗ REV3 (2026-11-21); ответ «Ok» о публикации (2026-11-21) |

### 1.3 Внешние источники

Требования App Store и Google Play — документ 13 §6. Проверены по страницам Apple и Google 2026-11-20 при подготовке ревью. Документация Tauri 2 по мобильным плагинам — 02 §8.

## 2. Недоступные источники

| Источник | Последствие |
|---|---|
| Заключение юриста; документы о правах на AI-assisted код; CLA | B1, B2, B3 остаются OPEN; 13 — фактический материал, не юридический вывод |
| Windows-машина владельца, Windows CI для этого пакета | ничего не проверено на Windows; пакет — только документация |
| Устройства Android и iOS, Mac, Xcode, учётные записи разработчика | поведение мобильных сборок не проверено (R-09, R-29, R-32, R-34) |
| План Stage 7 (не написан) | покрытие хранения ключей неизвестно (R-08, MI-02a) |
| Обновлённый ADR-016 (этап E #21) | формулировка CF-5 отложена |
| Веб-интерфейс GitHub | список PR показывал #39 открытым; по `git` он слит — использованы данные `git` |

## 3. Неподтверждённые утверждения

Помечены в документах меткой [ДОПУЩ] или [ВНЕШН]:
- Применимость позиции FSF о несовместимости GPL с условиями App Store к ATLAS — не установлена.
- Возможность использовать аппаратные ключи Keystore/Secure Enclave из TLS-стека Rust — предполагается невозможной; поэтому выбрана аутентификация на прикладном уровне (R-25). Проверяется в MS-03a.
- Поведение CSP и capabilities Tauri 2 на Android и iOS, достаточное для изоляции WebView от сети, — не проверено (R-32).
- Сборка вендорного `sqlx-sqlite` и bundled SQLite 3.54.1 для мобильных целей — не проверена (R-09).
- Числовые параметры (пауза 250 мс, очередь 4, таймаут 30 с, сроки 120 с, 5 мин, 30 и 180 дней) — предложения, не замеры.
- Требования магазинов действуют на дату проверки и могут измениться.

## 4. Трассировка находок ревью → REV3

| Находка | Место исправления в REV3 | Статус (REV3_G0_READINESS) |
|---|---|---|
| F-01 | 02 §1–§5, §10; 04 §7 | RESOLVED-IN-DESIGN |
| F-02 | 07 §2.2, §3, §7, §8.2 | RESOLVED-IN-DESIGN |
| F-03 | 07 §4, §5, §6, §9 | RESOLVED-IN-DESIGN |
| F-04 | 09; 11 §3; 01 §7; 14 (MI-02a) | RESOLVED в документации (срок); гейты PENDING |
| F-05 | 13 | OPEN |
| F-06 | 11 §4 | PENDING (принятие гейтов, OD-15) |
| F-07 | 03 §7; 07 §6; 12 (ADR-018) | PENDING (CF-2) |
| F-08 | 06 §6; 07 §4.1 | RESOLVED-IN-DESIGN |
| F-09 | 07 §2.1 | RESOLVED-IN-DESIGN |
| F-10 | 13 §6; R-19, R-20 | OPEN (выполняется при выпуске) |
| F-11 | 10 §2 (CF-5) | PENDING (#21 этап E) |
| F-12 | 08 §6 | RESOLVED-IN-DESIGN |
| F-13 | 05 §2 | RESOLVED-IN-DESIGN |
| F-14 | 08 §3 | RESOLVED-IN-DESIGN; ручная проверка Windows позже |
| F-15 | 04 §6 | PENDING (цепочка хэшей) |
| F-16 | 06 §3; OD-14 | PENDING |
| F-17 | 04 §3, §8; 11 §4 (G3) | OPEN до задания CSP |
| F-18 | 08 §5 | PENDING (срок поддержки) |
| F-19 | 08 §7 | MONITOR (замер в G4) |
| F-20 | R-24; 14 (MS-01) | OPEN |
| F-21 | 10 §5; 11 §7; R-21 | RESOLVED-IN-DESIGN (правило формулировок) |
| F-22 | 02 §8; 13 §4; R-15 | OPEN |
| F-23 | 10 §2 | RESOLVED-IN-DESIGN |
| F-24 | 11 §4; 14 §2 | RESOLVED-IN-DESIGN; разрешение на спайки PENDING |
| F-25 | REV3_DECISION_REGISTER §1; 11 §4 | RESOLVED-IN-DESIGN |
| F-26 | REV3_DECISION_REGISTER (OD-9) | PENDING |

Риски ревью RK-01…RK-26 и REV2 R-M1…R-M14 сопоставлены в столбце «Было» реестра рисков.

## 5. Трассировка требований ТЗ REV3

| Раздел ТЗ | Где выполнено |
|---|---|
| §4 F-01…F-05 | REV3_G0_READINESS §3.1; документы 02, 07, 09, 13 |
| §5 A–D | 09; 06 §6; 08 §6; 07 §4–§9 |
| §6 CF-1…CF-6 | 10 §2 |
| §7 реестр рисков | REV3_RISK_REGISTER |
| §8 реестр решений | REV3_DECISION_REGISTER |
| §9 ADR | 12 |
| §10 совместимость с Desktop | 10 §1, §3, §4 |
| §11 структура пакета | README; REV2_TO_REV3_CHANGELOG §1 |
| §12 диаграммы | REV3_G0_READINESS §4 |
| §13 self-review | REV3_G0_READINESS §3, §5 |
| §14 оценка G0 | REV3_G0_READINESS §1–§2 |
