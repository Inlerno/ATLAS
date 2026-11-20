# ATLAS — Local AI Assistant

Модульный локальный голосовой ИИ-помощник для Windows 10/11. Проект создаётся с нуля; `Inlerno/Voice_Assistant` — только функциональный референс, не источник кода для автоматического копирования.

## Цель
Приложение с локальной LLM через LM Studio, голосовым вводом/выводом, гибридным интерфейсом Orb + Chat, управляемой памятью, Telegram-интеграцией и безопасными командами управления Windows.

## Стек
- Tauri 2 + Rust + Tokio
- React + TypeScript + Vite
- Tailwind CSS + shadcn/ui, Framer Motion, Lucide
- Zustand
- SQLite + SQLx
- LM Studio как основной LLM provider через OpenAI-compatible API

## Принципы
1. Local-first; сетевые функции только как явно включённые интеграции.
2. Модульность и управляемый lifecycle.
3. Пользователь выбирает модели, движки и функции.
4. Никакого произвольного shell/PowerShell от LLM.
5. Сбой необязательного модуля не завершает приложение.
6. Python не является обязательным runtime конечного продукта.

## Быстрый старт (Windows)
Требования: Git for Windows, Node.js `^20.19.0` или `>=22.12.0` (требование Vite 8; рекомендуется актуальный LTS; для `npm test` — `^22.22.2`, `^24.15.0` или `>=26`: требование jsdom 31 и Vitest 5), Rust stable **1.90+** (`x86_64-pc-windows-msvc`), Microsoft C++ Build Tools, WebView2 Runtime — см. официальные Tauri 2 prerequisites.

```powershell
git clone https://github.com/Inlerno/ATLAS.git C:\dev\atlas
cd C:\dev\atlas
npm ci
npm run tauri dev
```

В обычной сборке модулей пока нет: окно показывает панель модулей с текстом «Модули не зарегистрированы».

### Демо-модули
Для ручной проверки менеджера модулей есть три демо-модуля — `demo.base` ← `demo.service` ← `demo.client`. Они собираются только с feature `demo-modules`; в обычной сборке и в установщике их нет.

```powershell
npm run tauri dev -- --features demo-modules
```

Все три изначально отключены. Настройки (кнопка «Настройки», JSON) вызывают сбои по требованию:
- `fail_on_start: true` — модуль не запускается;
- `panic_after_secs: N` — фоновая задача модуля аварийно завершается через N секунд после запуска (`null` — никогда);
- `tick_interval_secs: N` (только `demo.service`) — период события `Tick`; `demo.client` пишет каждое полученное событие в журнал.

Настройки и решения «включён / отключён» пока хранятся только в памяти и теряются при закрытии приложения (постоянное хранение — отдельный этап).

### Хранилище (SQLite)
При запуске приложение открывает базу SQLite в каталоге локальных данных `%LOCALAPPDATA%\com.inlerno.atlas`:
- `data\atlas.db` — база (во время записи рядом ненадолго появляется `atlas.db-journal`);
- `storage.initialized` — отметка, что база была создана;
- `storage.lock` — служебный файл первого запуска; сам по себе ничего не значит.

Драйвер SQLite (`sqlx-sqlite 0.8.6`) собирается из временной локальной копии в `vendor/sqlx-sqlite` с двумя изменениями: в сборку попадает исправленная SQLite 3.54.1 (RUSTSEC-2026-0459), и каждое соединение открывается так, что его закрытие не переносит WAL в файл базы. Это не официальный выпуск sqlx; подробности и условие удаления — `vendor/sqlx-sqlite/ATLAS_FORK.md`.

Пользовательских данных в базе пока нет: настройки модулей начнут сохраняться в ней на следующем этапе. Результат открытия виден в журнале (`logs\`): `database opened … state=ready`, `database opened read-only: changes will not be saved` или `database unavailable` с причиной. Приложение запускается и при недоступной базе.

Если рядом с базой оказались файлы `atlas.db-wal` или `atlas.db-shm` (сам ATLAS в режиме WAL не работает), база не открывается: в журнале `database unavailable … unexpected WAL files next to the database` либо `… step=journal-mode mode=wal` (шаг может называться также `probe-journal-mode`, `migrations-journal-mode`, `journal-mode-final`). ATLAS не переносит содержимое такого файла в базу, не пишет в обнаруженный файл и сам эти файлы не удаляет: разберитесь, откуда они, и уберите их вручную при закрытом ATLAS. Режим журнала проверяется внутри каждой транзакции открытия, а все миграции одного запуска фиксируются вместе или не применяются вовсе. Это не полная защита от программы, которая меняет каталог `data` одновременно с ATLAS: SQLite может прочитать подложенный файл, создаёт или перезаписывает `atlas.db-shm`, при самом первом запуске, пока база пуста, удаляет `atlas.db-wal` сама, а файл, подложенный во время уже идущей транзакции, остаётся рядом с базой и делает её недоступной до его удаления (ADR-016).

Ручная проверка хранилища на Windows — `tools\windows\sqlite-foundation-check.ps1` (описание и меры защиты существующих данных — в начале файла).

Приложение никогда само не удаляет, не пересоздаёт и не перезаписывает базу. Если файл базы пропал, а отметка осталась, в журнале будет `database file missing` и новая база **не** создаётся — чтобы потеря данных не прошла незаметно.

**Сброс хранилища вручную** (все данные базы будут потеряны): закройте ATLAS и удалите **оба** объекта — каталог `data` и файл `storage.initialized`. При следующем запуске база создаётся заново.

### Проверки
```powershell
npm run build
npm test
cd src-tauri
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
cargo clippy --all-targets --features demo-modules -- -D warnings
cargo test --features demo-modules
```

Держите репозиторий в коротком ASCII-пути вне OneDrive.

## Документация
- `CLAUDE.md` — проектные инструкции Claude.
- `docs/ARCHITECTURE.md` — архитектура.
- `docs/ROADMAP.md` — этапы.
- `docs/DEVELOPMENT_WORKFLOW.md` — процесс разработки с Claude (прямой доступ к репозиторию, PR, проверка на Windows).
- `docs/FIRST_STAGE.md` — первый этап.
- `docs/CLAUDE_CHAT_PROMPTS.md` — готовые запросы.
- `docs/DEVELOPMENT_LOG.md` — версии окружения и журнал проверок.
