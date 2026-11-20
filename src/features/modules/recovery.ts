// Logic of the configuration recovery (issue #21), apart from the components
// so that it can be tested without rendering. Only the JSON syntax is checked
// here. Whether the module qualifies, whether its stored record is damaged and
// whether the settings are acceptable is decided by the Rust core, which also
// requires the confirmation: nothing is replaced without it.

import { replaceModuleConfig, toIpcError } from "../../lib/ipc";
import type { Module, ModuleId, ModuleState, ReplaceResult } from "../../types/modules";

/** The IPC call. A parameter so that tests can pass their own. */
export type Replace = (
  id: ModuleId,
  settings: unknown,
  confirmed: boolean,
) => Promise<ReplaceResult>;

export const EMPTY_TEXT = "Введите новые настройки в формате JSON.";
export const INVALID_JSON = "Текст не является корректным JSON.";

/**
 * The recovery is offered where the configuration could not be read. The core
 * tells whether the stored record is really damaged: a readable one is never
 * replaced (`config_available`).
 */
export function canReplaceConfig(state: ModuleState): boolean {
  return state.kind === "configUnavailable";
}

export type Parsed = { ok: true; settings: unknown } | { ok: false; error: string };

/** Checks the JSON syntax only; anything else about the settings is up to the core. */
export function parseSettings(text: string): Parsed {
  if (text.trim() === "") return { ok: false, error: EMPTY_TEXT };
  try {
    return { ok: true, settings: JSON.parse(text) as unknown };
  } catch {
    return { ok: false, error: INVALID_JSON };
  }
}

export type Step =
  /** Nothing was sent: the text is empty or not JSON. */
  | { kind: "invalid"; message: string }
  /** Nothing changed: the core asks to confirm the replacement with exactly `settings`. */
  | { kind: "confirm"; settings: unknown }
  /** The record was replaced. The new state of the modules arrives as events. */
  | { kind: "replaced" }
  /** Refused or failed. The core's message; it never contains the settings. */
  | { kind: "error"; message: string };

function stepOf(result: ReplaceResult, settings: unknown): Step {
  switch (result.outcome) {
    case "replaced":
      return { kind: "replaced" };
    case "confirmationRequired":
      return { kind: "confirm", settings };
  }
}

async function call(
  replace: Replace,
  id: ModuleId,
  settings: unknown,
  confirmed: boolean,
): Promise<Step> {
  try {
    return stepOf(await replace(id, settings, confirmed), settings);
  } catch (error) {
    return { kind: "error", message: toIpcError(error).message };
  }
}

/** The first request, without the confirmation: the core changes nothing. */
export function requestReplacement(
  id: ModuleId,
  text: string,
  replace: Replace = replaceModuleConfig,
): Promise<Step> {
  const parsed = parseSettings(text);
  if (!parsed.ok) return Promise.resolve({ kind: "invalid", message: parsed.error });
  return call(replace, id, parsed.settings, false);
}

/** The user confirmed the replacement with `settings`, the value the core was asked about. */
export function confirmReplacement(
  id: ModuleId,
  settings: unknown,
  replace: Replace = replaceModuleConfig,
): Promise<Step> {
  return call(replace, id, settings, true);
}

/**
 * Modules blocked by `id` now. They stay blocked after the replacement, until
 * the user confirms «Восстановить» for them.
 */
export function blockedBy(id: ModuleId, modules: Module[]): ModuleId[] {
  return modules
    .filter(({ state }) => state.kind === "blocked" && state.by === id)
    .map(({ descriptor }) => descriptor.id);
}
