// A fake Rust core behind the Tauri IPC, for the component tests. It is built
// on the IPC mock of `@tauri-apps/api/mocks`, so `src/lib/ipc.ts` and
// `@tauri-apps/api` run unchanged: only the core's side of `invoke` is
// replaced. Answers are typed with `src/types/modules.ts`, which a Rust test
// checks against the DTOs. A command the test did not set up is rejected, and
// the test fails when it ends.
//
// The event plugin commands are answered here as well, with the arguments
// the real plugin receives (`listen`: event, target, handler; `unlisten`:
// event, eventId), so the tests see which subscriptions are live.
// `mockIPC(…, { shouldMockEvents: true })` is not used: in @tauri-apps/api
// 2.12 its `unlisten` reads `id` while `listen()` sends `eventId`, so a
// removed listener would stay registered in the mock.

import { mockIPC } from "@tauri-apps/api/mocks";
import { expect, onTestFinished } from "vitest";

import type {
  ApplyResult,
  ChangeAction,
  IpcError,
  Module,
  ModuleEvent,
  ModuleId,
  ModuleSettings,
  ModuleState,
  ModuleStatus,
  ReplaceResult,
  UiEvent,
} from "../types/modules";

/** Commands of the core the tests may set up: arguments as `src/lib/ipc.ts` sends them. */
export interface Commands {
  list_modules: { args: Record<string, never>; result: Module[] };
  get_module: { args: { id: ModuleId }; result: Module };
  get_module_settings: { args: { id: ModuleId }; result: ModuleSettings };
  replace_module_config: {
    args: { id: ModuleId; settings: unknown; confirmed: boolean };
    result: ReplaceResult;
  };
  apply_module_change: {
    args: { id: ModuleId; action: ChangeAction; confirmed: boolean; acknowledged: ModuleId[] };
    result: ApplyResult;
  };
}

type Command = keyof Commands;
type Answer<C extends Command> = (
  args: Commands[C]["args"],
) => Commands[C]["result"] | Promise<Commands[C]["result"]>;

/** `ErrorDto`s as the core sends them (`src-tauri/src/dto/mod.rs`). */
export const ERRORS = {
  configAvailable: {
    code: "config_available",
    message:
      "Повреждённая запись конфигурации не обнаружена, замена не выполнена. " +
      "Если модуль всё ещё недоступен, перезапустите приложение",
  },
  configUnavailable: {
    code: "config_unavailable",
    message: "Не удалось прочитать конфигурацию модуля",
  },
  store: { code: "store", message: "Сохранение конфигурации не подтверждено" },
  shutDown: { code: "shut_down", message: "Приложение завершает работу" },
  unknownModule: { code: "unknown_module", message: "Модуль не найден" },
  invalidSettings: {
    code: "invalid_settings",
    message: "Настройки модуля некорректны: fake: the value is invalid",
  },
} satisfies Record<string, IpcError>;

/** The text `toIpcError` shows for a failure of the IPC itself. */
export const INTERNAL_MESSAGE = "Внутренняя ошибка приложения";

/** The state of a module whose configuration could not be read at startup. */
export function configUnavailable(): ModuleStatus {
  return {
    enabled: null,
    state: {
      kind: "configUnavailable",
      error: ERRORS.configUnavailable.message,
      at: Date.UTC(2026, 10, 19, 9, 30),
    },
  };
}

export function moduleOf(
  id: ModuleId,
  displayName: string,
  status: { enabled: boolean | null; state: ModuleState },
  dependencies: ModuleId[] = [],
): Module {
  return {
    descriptor: {
      id,
      displayName,
      description: `Тестовый модуль ${displayName}.`,
      version: "0.1.0",
      dependencies,
      defaultEnabled: false,
    },
    enabled: status.enabled,
    state: status.state,
    health: null,
    restartRequired: false,
  };
}

interface Call {
  cmd: string;
  args: Record<string, unknown>;
}

interface Subscription {
  event: string;
  handler: number;
}

/** Set by `mockIPC`: runs a callback registered with `transformCallback`. */
function runCallback(handler: number, data: unknown): void {
  const internals = (
    window as unknown as { __TAURI_INTERNALS__: { runCallback(id: number, data: unknown): void } }
  ).__TAURI_INTERNALS__;
  internals.runCallback(handler, data);
}

export class FakeCore {
  /** The core's snapshot: what `list_modules` and `get_module` answer. */
  readonly modules = new Map<ModuleId, Module>();
  /** Every command, in order, with a copy of its arguments. */
  readonly calls: Call[] = [];
  /** Commands nobody set up; the test fails if there are any. */
  readonly unexpected: string[] = [];
  private readonly answers = new Map<string, (args: never) => unknown>();
  private readonly subscriptions = new Map<number, Subscription>();
  private nextEventId = 1;
  private seq = 0;

  constructor(modules: Module[]) {
    for (const module of modules) this.modules.set(module.descriptor.id, structuredClone(module));
    this.answer("list_modules", () =>
      [...this.modules.values()].map((module) => structuredClone(module)),
    );
    this.answer("get_module", ({ id }) => {
      const module = this.modules.get(id);
      if (module === undefined) throw ERRORS.unknownModule;
      return structuredClone(module);
    });
    mockIPC((cmd, args) => this.invoke(cmd, (args ?? {}) as Record<string, unknown>));
    onTestFinished(() => {
      expect(this.unexpected, "commands the test did not set up").toEqual([]);
    });
  }

  /** Sets up the answer to `cmd`. An `IpcError` it throws rejects the command. */
  answer<C extends Command>(cmd: C, answer: Answer<C>): void {
    this.answers.set(cmd, answer as (args: never) => unknown);
  }

  /** Arguments of every call of `cmd`, in order. */
  callsOf<C extends Command>(cmd: C): Commands[C]["args"][] {
    return this.calls
      .filter((call) => call.cmd === cmd)
      .map((call) => call.args as Commands[C]["args"]);
  }

  /** The commands of the core called so far, without the event plugin. */
  commands(): string[] {
    return this.calls.map((call) => call.cmd).filter((cmd) => !cmd.startsWith("plugin:event|"));
  }

  /** Events with live subscriptions, one entry per subscription, sorted. */
  liveSubscriptions(): string[] {
    return [...this.subscriptions.values()].map((subscription) => subscription.event).sort();
  }

  /** Changes the snapshot of a module, as the manager does before it publishes. */
  update(id: ModuleId, status: ModuleStatus): void {
    const module = this.modules.get(id);
    if (module === undefined) throw new Error(`no module ${id}`);
    this.modules.set(id, { ...module, enabled: status.enabled, state: status.state });
  }

  /** Delivers a module event as the bridge does: `modules://event`, `{ seq, atUnixMs, event }`. */
  publish(event: ModuleEvent): void {
    this.seq += 3; // `seq` grows, but not by one (the bus carries more events).
    const payload: UiEvent = { seq: this.seq, atUnixMs: Date.now(), event };
    for (const [id, subscription] of this.subscriptions) {
      if (subscription.event === "modules://event") {
        // A copy for each listener: the real IPC delivers serialized events.
        runCallback(subscription.handler, {
          event: subscription.event,
          id,
          payload: structuredClone(payload),
        });
      }
    }
  }

  private invoke(cmd: string, args: Record<string, unknown>): unknown {
    this.calls.push({ cmd, args: structuredClone(args) });
    switch (cmd) {
      case "plugin:event|listen": {
        const id = this.nextEventId++;
        this.subscriptions.set(id, {
          event: args.event as string,
          handler: args.handler as number,
        });
        return id;
      }
      case "plugin:event|unlisten":
        this.subscriptions.delete(args.eventId as number);
        return null;
    }
    const answer = this.answers.get(cmd);
    if (answer === undefined) {
      this.unexpected.push(cmd);
      throw new Error(`the test did not set up the command ${cmd}`);
    }
    return answer(args as never);
  }
}
