// The logic of the configuration recovery (#21) without the components. The
// IPC call is the `replace` parameter: the functions are tested against a fake
// with the shape of `replaceModuleConfig`.

import { describe, expect, it, vi } from "vitest";

import { ERRORS, INTERNAL_MESSAGE, configUnavailable, moduleOf } from "../../test/fakeCore";
import type { ModuleState, ReplaceResult } from "../../types/modules";
import {
  EMPTY_TEXT,
  INVALID_JSON,
  type Replace,
  blockedBy,
  canReplaceConfig,
  confirmReplacement,
  parseSettings,
  requestReplacement,
} from "./recovery";

const ID = "demo.service";

function replaceAnswering(...answers: (ReplaceResult | Error | object)[]) {
  const replace = vi.fn<Replace>();
  for (const answer of answers) {
    if ("outcome" in answer) replace.mockResolvedValueOnce(answer as ReplaceResult);
    else replace.mockRejectedValueOnce(answer);
  }
  return replace;
}

describe("parseSettings", () => {
  it("refuses an empty text and a text that is not JSON", () => {
    for (const text of ["", "   ", "\n\t"]) {
      expect(parseSettings(text)).toEqual({ ok: false, error: EMPTY_TEXT });
    }
    for (const text of ["{", '{"level": 1', "{level: 1}", "{'a': 1}", "[1,]"]) {
      expect(parseSettings(text)).toEqual({ ok: false, error: INVALID_JSON });
    }
  });

  // Whether the value is acceptable settings is decided by the core
  // (`invalid_settings`), not here.
  it("checks only the syntax: any JSON value is passed on as parsed", () => {
    expect(parseSettings('{"level": 1, "nested": {"list": [1, "два"]}}')).toEqual({
      ok: true,
      settings: { level: 1, nested: { list: [1, "два"] } },
    });
    for (const [text, settings] of [
      ["[1]", [1]],
      ["null", null],
      ["42", 42],
      ['"text"', "text"],
    ] as const) {
      expect(parseSettings(text)).toEqual({ ok: true, settings });
    }
  });
});

describe("requestReplacement", () => {
  it("sends nothing for a text that is not JSON", async () => {
    const replace = vi.fn<Replace>();
    expect(await requestReplacement(ID, "", replace)).toEqual({
      kind: "invalid",
      message: EMPTY_TEXT,
    });
    expect(await requestReplacement(ID, "{oops", replace)).toEqual({
      kind: "invalid",
      message: INVALID_JSON,
    });
    expect(replace).not.toHaveBeenCalled();
  });

  it("asks the core once, without the confirmation, and passes on its request to confirm", async () => {
    const replace = replaceAnswering({ outcome: "confirmationRequired" });
    const step = await requestReplacement(ID, '{"level": 1}', replace);
    expect(replace).toHaveBeenCalledTimes(1);
    expect(replace).toHaveBeenCalledWith(ID, { level: 1 }, false);
    expect(step).toEqual({ kind: "confirm", settings: { level: 1 } });
  });

  it("takes `replaced` as it comes", async () => {
    const replace = replaceAnswering({ outcome: "replaced" });
    expect(await requestReplacement(ID, "{}", replace)).toEqual({ kind: "replaced" });
    expect(replace).toHaveBeenCalledTimes(1);
  });
});

describe("confirmReplacement", () => {
  it("repeats the request once, with the confirmation and exactly the settings it is given", async () => {
    const settings = { level: 1 };
    const replace = replaceAnswering({ outcome: "replaced" });
    expect(await confirmReplacement(ID, settings, replace)).toEqual({ kind: "replaced" });
    expect(replace).toHaveBeenCalledTimes(1);
    expect(replace).toHaveBeenCalledWith(ID, settings, true);
    expect(replace.mock.calls[0][1]).toBe(settings);
  });

  it("confirms the settings the core was asked about in the first request", async () => {
    const replace = replaceAnswering({ outcome: "confirmationRequired" }, { outcome: "replaced" });
    const first = await requestReplacement(ID, '{"level": 1, "name": "Ёж"}', replace);
    if (first.kind !== "confirm") throw new Error(`expected a confirmation, got ${first.kind}`);
    expect(await confirmReplacement(ID, first.settings, replace)).toEqual({ kind: "replaced" });

    expect(replace).toHaveBeenCalledTimes(2);
    const [[, asked, unconfirmed], [, confirmed, withConfirmation]] = replace.mock.calls;
    expect([unconfirmed, withConfirmation]).toEqual([false, true]);
    expect(confirmed).toBe(asked);
    expect(confirmed).toEqual({ level: 1, name: "Ёж" });
  });
});

describe("errors of the IPC", () => {
  it("show the core's message and are not retried", async () => {
    for (const error of [ERRORS.configAvailable, ERRORS.shutDown, ERRORS.unknownModule]) {
      const replace = replaceAnswering(error);
      expect(await requestReplacement(ID, "{}", replace)).toEqual({
        kind: "error",
        message: error.message,
      });
      expect(replace).toHaveBeenCalledTimes(1);
    }
    for (const error of [ERRORS.invalidSettings, ERRORS.configAvailable, ERRORS.store]) {
      const replace = replaceAnswering(error);
      expect(await confirmReplacement(ID, {}, replace)).toEqual({
        kind: "error",
        message: error.message,
      });
      expect(replace).toHaveBeenCalledTimes(1);
    }
  });

  it("that are not an ErrorDto show a fixed text, not their own", async () => {
    const failure = new Error("IPC channel closed: C:\\Users\\someone\\secret");
    for (const step of [
      await requestReplacement(ID, "{}", replaceAnswering(failure)),
      await confirmReplacement(ID, {}, replaceAnswering(failure)),
    ]) {
      expect(step).toEqual({ kind: "error", message: INTERNAL_MESSAGE });
    }
  });
});

describe("canReplaceConfig", () => {
  it("is true only where the configuration could not be read", () => {
    const states: ModuleState[] = [
      { kind: "stopped" },
      { kind: "initializing" },
      { kind: "starting" },
      { kind: "running" },
      { kind: "stopping" },
      { kind: "failed", phase: "start", error: "сбой", at: 0 },
      { kind: "blocked", by: "demo.base", reason: "dependencyConfigUnavailable" },
    ];
    for (const state of states) expect(canReplaceConfig(state), state.kind).toBe(false);
    expect(canReplaceConfig(configUnavailable().state)).toBe(true);
  });
});

describe("blockedBy", () => {
  it("lists the modules blocked by the module now, for any reason, in list order", () => {
    const blocked = (by: string, reason: "dependencyFailed" | "dependencyConfigUnavailable") => ({
      enabled: true,
      state: { kind: "blocked", by, reason } as const,
    });
    const modules = [
      moduleOf("demo.service", "DEMO Service", configUnavailable()),
      moduleOf(
        "demo.client",
        "DEMO Client",
        blocked("demo.service", "dependencyConfigUnavailable"),
      ),
      moduleOf("demo.other", "DEMO Other", blocked("demo.base", "dependencyFailed")),
      moduleOf("demo.third", "DEMO Third", blocked("demo.service", "dependencyFailed")),
      moduleOf("demo.base", "DEMO Base", { enabled: true, state: { kind: "running" } }),
    ];
    expect(blockedBy("demo.service", modules)).toEqual(["demo.client", "demo.third"]);
    expect(blockedBy("demo.base", modules)).toEqual(["demo.other"]);
    expect(blockedBy("demo.client", modules)).toEqual([]);
  });
});
