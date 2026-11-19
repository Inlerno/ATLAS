// The configuration recovery (#21) inside the modules panel: where it is
// offered, which panel opens, and how the panel follows the core's events
// after a replacement. The core is a fake behind the real IPC layer
// (src/test/fakeCore.ts); `useModules`, `lib/ipc.ts` and the components are
// the real ones.

import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it } from "vitest";

import { ERRORS, FakeCore, configUnavailable, moduleOf } from "../../test/fakeCore";
import type { Module, ModuleEvent } from "../../types/modules";
import { ModulesPanel } from "./ModulesPanel";

const MODULES: Module[] = [
  moduleOf("demo.base", "DEMO Base", { enabled: true, state: { kind: "running" } }),
  moduleOf("demo.service", "DEMO Service", configUnavailable(), ["demo.base"]),
  moduleOf(
    "demo.client",
    "DEMO Client",
    {
      enabled: true,
      state: { kind: "blocked", by: "demo.service", reason: "dependencyConfigUnavailable" },
    },
    ["demo.service"],
  ),
  moduleOf("demo.extra", "DEMO Extra", configUnavailable()),
  moduleOf("demo.failed", "DEMO Failed", {
    enabled: true,
    state: {
      kind: "failed",
      phase: "start",
      error: "Модуль не ответил вовремя",
      at: Date.UTC(2026, 10, 19, 9, 31),
    },
  }),
  moduleOf("demo.off", "DEMO Off", { enabled: false, state: { kind: "stopped" } }),
];

const RECOVER_CONFIG = "Восстановить конфигурацию";

/** The card of a module in the list. */
function card(id: string): HTMLElement {
  const item = screen.getByText(id, { selector: "code" }).closest("li");
  if (item === null) throw new Error(`no card of ${id}`);
  return item;
}

async function setup() {
  const core = new FakeCore(MODULES);
  const user = userEvent.setup();
  const view = render(<ModulesPanel />);
  await screen.findByText("demo.base", { selector: "code" });
  return { core, user, view };
}

/** Delivers events as the bridge does, and lets the panel apply them and read the module again. */
async function deliver(core: FakeCore, ...events: ModuleEvent[]) {
  await act(async () => {
    for (const event of events) core.publish(event);
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

describe("ModulesPanel: configuration recovery", () => {
  it("offers the recovery only where the configuration could not be read", async () => {
    await setup();
    for (const [id, offered] of [
      ["demo.base", false],
      ["demo.service", true],
      ["demo.client", false],
      ["demo.extra", true],
      ["demo.failed", false],
      ["demo.off", false],
    ] as const) {
      const button = within(card(id)).queryByRole("button", { name: RECOVER_CONFIG });
      expect(button !== null, id).toBe(offered);
    }
    expect(card("demo.service")).toHaveTextContent(
      "если запись повреждена, её можно заменить: «Восстановить конфигурацию»",
    );
    expect(card("demo.client")).toHaveTextContent(
      "Конфигурация зависимости DEMO Service (demo.service) недоступна: восстановите её или перезапустите приложение.",
    );
  });

  it("opens the recovery of the chosen module, one panel at a time, without reading its record", async () => {
    const { core, user } = await setup();
    // The real core answers so for a module whose configuration could not be read.
    core.answer("get_module_settings", () => {
      throw ERRORS.configUnavailable;
    });
    const service = () => card("demo.service");

    await user.click(within(service()).getByRole("button", { name: RECOVER_CONFIG }));
    const field = within(service()).getByRole("textbox", {
      name: "Новые настройки модуля demo.service в формате JSON",
    });
    expect(field).toHaveValue("");
    expect(
      within(service()).getByRole("button", { name: "Скрыть восстановление" }),
    ).toHaveAttribute("aria-expanded", "true");
    expect(screen.getAllByRole("textbox")).toHaveLength(1);
    expect(core.callsOf("get_module_settings")).toEqual([]);

    // The normal settings of the same module replace the recovery panel.
    await user.click(within(service()).getByRole("button", { name: "Настройки" }));
    expect(field).not.toBeInTheDocument();
    expect(await within(service()).findByRole("status")).toHaveTextContent(
      ERRORS.configUnavailable.message,
    );
    expect(within(service()).getByRole("button", { name: RECOVER_CONFIG })).toHaveAttribute(
      "aria-expanded",
      "false",
    );
    // Read by the normal editor (twice: <StrictMode> runs its effect twice in development).
    const reads = core.callsOf("get_module_settings");
    expect(reads.length).toBeGreaterThan(0);
    expect(reads.every(({ id }) => id === "demo.service")).toBe(true);

    // The recovery of another module closes them.
    await user.click(within(card("demo.extra")).getByRole("button", { name: RECOVER_CONFIG }));
    expect(within(service()).queryByRole("status")).not.toBeInTheDocument();
    expect(screen.getAllByRole("textbox")).toEqual([
      within(card("demo.extra")).getByRole("textbox", {
        name: "Новые настройки модуля demo.extra в формате JSON",
      }),
    ]);

    await user.click(
      within(card("demo.extra")).getByRole("button", { name: "Скрыть восстановление" }),
    );
    expect(screen.queryAllByRole("textbox")).toEqual([]);
  });

  it("after the replacement follows the core's events: nothing restarts, the dependent waits for «Восстановить»", async () => {
    const { core, user } = await setup();
    core.answer("replace_module_config", ({ id, confirmed }) => {
      if (!confirmed) return { outcome: "confirmationRequired" };
      // The manager changes its snapshot, then publishes (the test delivers the events below).
      core.update(id, { enabled: false, state: { kind: "stopped" } });
      return { outcome: "replaced" };
    });

    await user.click(within(card("demo.service")).getByRole("button", { name: RECOVER_CONFIG }));
    await user.type(within(card("demo.service")).getByRole("textbox"), "{{}");
    await user.click(
      within(card("demo.service")).getByRole("button", { name: "Заменить конфигурацию…" }),
    );
    const dialog = screen.getByRole("dialog", {
      name: "Заменить конфигурацию: DEMO Service (demo.service)",
    });
    expect(dialog).toHaveTextContent("DEMO Client (demo.client)");
    await user.click(within(dialog).getByRole("button", { name: "Заменить" }));

    expect(screen.getByRole("alert")).toHaveTextContent(
      "Конфигурация DEMO Service (demo.service) заменена. Модуль отключён: включите его, когда будете готовы. " +
        "Заблокированные им модули запустите кнопкой «Восстановить».",
    );
    expect(within(card("demo.service")).queryByRole("textbox")).not.toBeInTheDocument();
    // Until the events arrive, the panel shows what it had: it reads nothing on its own.
    expect(within(card("demo.service")).getByText("Конфигурация недоступна")).toBeInTheDocument();
    expect(core.commands()).toEqual([
      "list_modules",
      "replace_module_config",
      "replace_module_config",
    ]);

    await deliver(
      core,
      { type: "settingsChanged", id: "demo.service", restartRequired: false },
      {
        type: "statusChanged",
        id: "demo.service",
        previous: configUnavailable(),
        current: { enabled: false, state: { kind: "stopped" } },
      },
    );

    const service = card("demo.service");
    expect(within(service).getByText("Остановлен")).toBeInTheDocument();
    expect(within(service).getByRole("switch")).not.toBeChecked();
    expect(within(service).getByRole("switch")).toBeEnabled();
    expect(service).toHaveTextContent("отключён");
    expect(within(service).queryByRole("button", { name: RECOVER_CONFIG })).not.toBeInTheDocument();
    // Read again because of the events — and nothing else: no restart, no start, no list reload.
    expect(core.commands()).toEqual([
      "list_modules",
      "replace_module_config",
      "replace_module_config",
      "get_module",
      "get_module",
    ]);
    expect(core.callsOf("get_module")).toEqual([{ id: "demo.service" }, { id: "demo.service" }]);

    // The dependent stays blocked and is told what to do now.
    const client = card("demo.client");
    expect(within(client).getByText("Заблокирован")).toBeInTheDocument();
    expect(client).toHaveTextContent(
      "Конфигурация зависимости DEMO Service (demo.service) была недоступна. Чтобы запустить модуль, нажмите «Восстановить».",
    );

    // «Восстановить» is a change of its own, which the core asks to confirm.
    core.answer("apply_module_change", ({ id, action }) => ({
      outcome: "confirmationRequired",
      plan: {
        action,
        target: id,
        affected: ["demo.service"],
        steps: [
          { kind: "enable", id: "demo.service" },
          { kind: "start", id: "demo.service" },
          { kind: "start", id: "demo.client" },
        ],
        requiresConfirmation: true,
        blockers: [],
      },
    }));
    await user.click(within(client).getByRole("button", { name: "Восстановить" }));
    const recover = screen.getByRole("dialog", { name: "Восстановить: DEMO Client (demo.client)" });
    await user.click(within(recover).getByRole("button", { name: "Отмена" }));
    expect(core.callsOf("apply_module_change")).toEqual([
      { id: "demo.client", action: "recover", confirmed: false, acknowledged: [] },
    ]);
    expect(within(card("demo.client")).getByText("Заблокирован")).toBeInTheDocument();
    expect(within(card("demo.service")).getByText("Остановлен")).toBeInTheDocument();
  });

  it("removes its event subscriptions when it unmounts", async () => {
    const { core, view } = await setup();
    expect(core.liveSubscriptions()).toEqual(["modules://event", "modules://resync"]);

    view.unmount();

    await waitFor(() => expect(core.liveSubscriptions()).toEqual([]));
    const count = (cmd: string) => core.calls.filter((call) => call.cmd === cmd).length;
    expect(count("plugin:event|unlisten")).toBe(count("plugin:event|listen"));
  });
});
