// The recovery panel (#21) as the user sees it. The core is a fake behind
// the real IPC layer (src/test/fakeCore.ts); `recovery.ts` and `lib/ipc.ts`
// are the real ones.

import { act, render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import {
  type Commands,
  ERRORS,
  FakeCore,
  INTERNAL_MESSAGE,
  configUnavailable,
  moduleOf,
} from "../../test/fakeCore";
import type { IpcError, ReplaceResult } from "../../types/modules";
import { ConfigRecovery } from "./ConfigRecovery";
import { EMPTY_TEXT, INVALID_JSON } from "./recovery";

const SERVICE = moduleOf("demo.service", "DEMO Service", configUnavailable(), ["demo.base"]);
const CLIENT = moduleOf(
  "demo.client",
  "DEMO Client",
  {
    enabled: true,
    state: { kind: "blocked", by: "demo.service", reason: "dependencyConfigUnavailable" },
  },
  ["demo.service"],
);
const MODULES = [SERVICE, CLIENT];
const DIALOG = "Заменить конфигурацию: DEMO Service (demo.service)";

type ReplaceArgs = Commands["replace_module_config"]["args"];

/** `{` and `[` start key names in user-event; doubled they are typed as is. */
const literally = (text: string) => text.replace(/[{[]/g, (bracket) => bracket + bracket);

function setup(answer?: (args: ReplaceArgs) => ReplaceResult | Promise<ReplaceResult>) {
  const core = new FakeCore(MODULES);
  if (answer) core.answer("replace_module_config", answer);
  const onReplaced = vi.fn();
  const onClose = vi.fn();
  const user = userEvent.setup();
  render(
    <ConfigRecovery
      id="demo.service"
      modules={MODULES}
      onReplaced={onReplaced}
      onClose={onClose}
    />,
  );
  const field = screen.getByRole("textbox", {
    name: "Новые настройки модуля demo.service в формате JSON",
  });
  return {
    core,
    user,
    field,
    onReplaced,
    onClose,
    type: (text: string) => user.type(field, literally(text)),
    submit: () => user.click(screen.getByRole("button", { name: "Заменить конфигурацию…" })),
    dialog: () => screen.queryByRole("dialog", { name: DIALOG }),
    confirm: () =>
      user.click(
        within(screen.getByRole("dialog", { name: DIALOG })).getByRole("button", {
          name: "Заменить",
        }),
      ),
    status: () => screen.queryByRole("status"),
  };
}

/** First request: the confirmation is required; the confirmed one: `then`. */
function confirmThen(then: () => ReplaceResult | Promise<ReplaceResult>) {
  return ({ confirmed }: ReplaceArgs): ReplaceResult | Promise<ReplaceResult> =>
    confirmed ? then() : { outcome: "confirmationRequired" };
}

function rejectWith(error: IpcError | string): never {
  throw error;
}

function deferred<T>() {
  let resolve: (value: T) => void = () => {};
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

describe("ConfigRecovery", () => {
  it("opens with an empty field and asks the core for nothing", () => {
    const t = setup();
    expect(t.field).toHaveValue("");
    // The stored record is not read (no `get_module_settings`), not even as a starting point.
    expect(t.core.commands()).toEqual([]);
    expect(t.dialog()).not.toBeInTheDocument();
  });

  it("sends nothing while the text is empty or not JSON, and keeps the text", async () => {
    const t = setup(confirmThen(() => ({ outcome: "replaced" })));
    await t.submit();
    expect(t.status()).toHaveTextContent(EMPTY_TEXT);

    await t.type('{"level": 1');
    await t.submit();
    expect(t.status()).toHaveTextContent(INVALID_JSON);
    expect(t.field).toHaveValue('{"level": 1');

    expect(t.core.callsOf("replace_module_config")).toEqual([]);
    expect(t.dialog()).not.toBeInTheDocument();
  });

  it("sends the JSON without the confirmation first and shows the confirmation the core asks for", async () => {
    const t = setup(confirmThen(() => ({ outcome: "replaced" })));
    await t.type('{"level": 1, "name": "Ёж"}');
    await t.submit();

    expect(t.core.callsOf("replace_module_config")).toEqual([
      { id: "demo.service", settings: { level: 1, name: "Ёж" }, confirmed: false },
    ]);
    const dialog = screen.getByRole("dialog", { name: DIALOG });
    expect(dialog).toHaveTextContent("Модуль останется отключённым");
    // The module this one blocks now is named.
    expect(dialog).toHaveTextContent("DEMO Client (demo.client)");
    expect(dialog).toHaveTextContent("Если запись окажется читаемой, замена не выполнится");
    expect(t.onReplaced).not.toHaveBeenCalled();
  });

  it("«Отмена» closes the confirmation and sends nothing more", async () => {
    const t = setup(confirmThen(() => ({ outcome: "replaced" })));
    await t.type('{"level": 1}');
    await t.submit();
    await t.user.click(
      within(screen.getByRole("dialog", { name: DIALOG })).getByRole("button", { name: "Отмена" }),
    );

    expect(t.dialog()).not.toBeInTheDocument();
    expect(t.core.callsOf("replace_module_config")).toHaveLength(1);
    expect(t.field).toHaveValue('{"level": 1}');
    expect(t.onReplaced).not.toHaveBeenCalled();
    expect(t.onClose).not.toHaveBeenCalled();
  });

  it("Esc closes the confirmation and sends nothing more", async () => {
    const t = setup(confirmThen(() => ({ outcome: "replaced" })));
    await t.type('{"level": 1}');
    await t.submit();
    expect(t.dialog()).toBeInTheDocument();

    await t.user.keyboard("{Escape}");

    expect(t.dialog()).not.toBeInTheDocument();
    expect(t.core.callsOf("replace_module_config")).toHaveLength(1);
    expect(t.field).toHaveValue('{"level": 1}');
    expect(t.onReplaced).not.toHaveBeenCalled();
  });

  it("«Заменить» repeats the request once, with the same settings and the confirmation", async () => {
    const t = setup(confirmThen(() => ({ outcome: "replaced" })));
    await t.type('{"level": 1, "nested": {"list": [1, 2]}}');
    await t.submit();
    await t.confirm();

    const [first, second] = t.core.callsOf("replace_module_config");
    expect(t.core.callsOf("replace_module_config")).toHaveLength(2);
    expect(first).toEqual({
      id: "demo.service",
      settings: { level: 1, nested: { list: [1, 2] } },
      confirmed: false,
    });
    expect(second).toEqual({ ...first, confirmed: true });
    expect(t.onReplaced).toHaveBeenCalledTimes(1);
    expect(t.dialog()).not.toBeInTheDocument();
    expect(t.status()).not.toBeInTheDocument();
  });

  it("sends each request once while it is in flight", async () => {
    const first = deferred<ReplaceResult>();
    const second = deferred<ReplaceResult>();
    const t = setup(({ confirmed }) => (confirmed ? second.promise : first.promise));
    await t.type("{}");

    const submit = screen.getByRole("button", { name: "Заменить конфигурацию…" });
    await t.user.click(submit);
    expect(submit).toBeDisabled();
    expect(t.field).toBeDisabled();
    await t.user.click(submit);
    first.resolve({ outcome: "confirmationRequired" });
    const dialog = await screen.findByRole("dialog", { name: DIALOG });
    expect(t.core.callsOf("replace_module_config")).toHaveLength(1);

    await t.confirm();
    const busy = within(dialog).getByRole("button", { name: "Выполняется…" });
    expect(busy).toBeDisabled();
    expect(within(dialog).getByRole("button", { name: "Отмена" })).toBeDisabled();
    await t.user.click(busy);
    // Esc does not close the confirmation while the replacement is applied.
    await t.user.keyboard("{Escape}");
    expect(t.dialog()).toBeInTheDocument();
    expect(t.core.callsOf("replace_module_config")).toHaveLength(2);

    second.resolve({ outcome: "replaced" });
    await waitFor(() => expect(t.onReplaced).toHaveBeenCalledTimes(1));
    expect(t.core.callsOf("replace_module_config")).toHaveLength(2);
  });

  // Chromium (WebView2) may send a non-cancelable `cancel` on repeated Esc and
  // close the dialog while the confirmed request runs. Whatever the reply,
  // it must still leave a consistent state.
  it.each([
    ["replaced", null],
    ["store", ERRORS.store],
  ] as const)(
    "after the dialog was closed natively, the reply resets the state: %s",
    async (_, error) => {
      let answer: (result: ReplaceResult) => void = () => {};
      let fail: (reason: IpcError) => void = () => {};
      const reply = new Promise<ReplaceResult>((resolve, reject) => {
        answer = resolve;
        fail = reject;
      });
      const t = setup(({ confirmed }) => (confirmed ? reply : { outcome: "confirmationRequired" }));
      await t.type('{"level": 1}');
      await t.submit();
      await t.confirm();
      const dialog = screen.getByRole("dialog", { name: DIALOG }) as HTMLDialogElement;

      // What Chromium does then: a `cancel` that cannot be prevented, then close().
      act(() => {
        if (dialog.dispatchEvent(new Event("cancel", { cancelable: false }))) dialog.close();
      });
      expect(dialog.open).toBe(false);
      expect(t.field).toBeDisabled();

      await act(async () => {
        if (error === null) answer({ outcome: "replaced" });
        else fail(error);
      });

      expect(t.dialog()).not.toBeInTheDocument();
      expect(t.core.callsOf("replace_module_config")).toHaveLength(2);
      if (error === null) {
        expect(t.onReplaced).toHaveBeenCalledTimes(1);
      } else {
        expect(t.onReplaced).not.toHaveBeenCalled();
        expect(t.status()).toHaveTextContent(error.message);
        expect(t.field).toHaveValue('{"level": 1}');
        expect(t.field).toBeEnabled();
        // The user can start again: the next request asks for the confirmation anew.
        await t.submit();
        expect(screen.getByRole("dialog", { name: DIALOG })).toHaveAttribute("open");
        expect(t.core.callsOf("replace_module_config").map((call) => call.confirmed)).toEqual([
          false,
          true,
          false,
        ]);
      }
    },
  );

  describe("keeps the typed JSON after an error", () => {
    const TEXT = '{\n  "level": 1,\n  "name": "Ёж"\n}';

    it.each([
      ["invalid_settings", ERRORS.invalidSettings, ERRORS.invalidSettings.message],
      ["config_available", ERRORS.configAvailable, ERRORS.configAvailable.message],
      ["store", ERRORS.store, ERRORS.store.message],
      ["shut_down", ERRORS.shutDown, ERRORS.shutDown.message],
      ["a failure of the IPC", "IPC: the webview lost the core", INTERNAL_MESSAGE],
    ] as const)("of the confirmed request: %s", async (_, error, message) => {
      const t = setup(confirmThen(() => rejectWith(error)));
      await t.type(TEXT);
      await t.submit();
      await t.confirm();

      expect(t.status()).toHaveTextContent(message);
      expect(t.field).toHaveValue(TEXT);
      expect(t.field).toBeEnabled();
      expect(t.dialog()).not.toBeInTheDocument();
      expect(t.core.callsOf("replace_module_config").map((call) => call.confirmed)).toEqual([
        false,
        true,
      ]);
      expect(t.onReplaced).not.toHaveBeenCalled();
      if (typeof error === "string")
        expect(screen.queryByText(error, { exact: false })).not.toBeInTheDocument();
    });

    it.each([
      ["config_available", ERRORS.configAvailable, ERRORS.configAvailable.message],
      ["unknown_module", ERRORS.unknownModule, ERRORS.unknownModule.message],
      ["shut_down", ERRORS.shutDown, ERRORS.shutDown.message],
      ["a failure of the IPC", "IPC: the webview lost the core", INTERNAL_MESSAGE],
    ] as const)("of the first request: %s", async (_, error, message) => {
      const t = setup(() => rejectWith(error));
      await t.type(TEXT);
      await t.submit();

      expect(t.status()).toHaveTextContent(message);
      expect(t.field).toHaveValue(TEXT);
      expect(t.dialog()).not.toBeInTheDocument();
      expect(t.core.callsOf("replace_module_config")).toHaveLength(1);
      expect(t.onReplaced).not.toHaveBeenCalled();
    });

    it("and the corrected text is sent again from the start", async () => {
      const t = setup(({ confirmed, settings }) => {
        if (!confirmed) return { outcome: "confirmationRequired" };
        return "invalid" in (settings as object)
          ? rejectWith(ERRORS.invalidSettings)
          : { outcome: "replaced" };
      });
      await t.type('{"invalid": true}');
      await t.submit();
      await t.confirm();
      expect(t.status()).toHaveTextContent(ERRORS.invalidSettings.message);
      expect(t.field).toHaveValue('{"invalid": true}');

      await t.user.clear(t.field);
      await t.type('{"level": 2}');
      await t.submit();
      expect(t.status()).not.toBeInTheDocument();
      await t.confirm();

      expect(t.core.callsOf("replace_module_config")).toEqual([
        { id: "demo.service", settings: { invalid: true }, confirmed: false },
        { id: "demo.service", settings: { invalid: true }, confirmed: true },
        { id: "demo.service", settings: { level: 2 }, confirmed: false },
        { id: "demo.service", settings: { level: 2 }, confirmed: true },
      ]);
      expect(t.onReplaced).toHaveBeenCalledTimes(1);
    });
  });

  it("«Отмена» of the panel closes it and sends nothing", async () => {
    const t = setup();
    await t.type('{"level": 1}');
    await t.user.click(screen.getByRole("button", { name: "Отмена" }));
    expect(t.onClose).toHaveBeenCalledTimes(1);
    expect(t.core.commands()).toEqual([]);
  });
});
