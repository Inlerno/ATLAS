// Texts of the modules panel (issue #12).

import type {
  BlockReason,
  Blocker,
  ChangeAction,
  FailurePhase,
  Health,
  Module,
  ModuleId,
  ModuleState,
  PlanStep,
} from "../../types/modules";

const PHASES: Record<FailurePhase, string> = {
  initialize: "инициализация",
  start: "запуск",
  run: "работа",
  stop: "остановка",
  healthCheck: "проверка состояния",
  settings: "настройки",
};

/** `DEMO Service (demo.service)`; the bare ID for a module that is not listed. */
export function nameOf(id: ModuleId, modules: Module[]): string {
  const module = modules.find((candidate) => candidate.descriptor.id === id);
  return module ? `${module.descriptor.displayName} (${id})` : id;
}

export function stateLabel(state: ModuleState): string {
  switch (state.kind) {
    case "stopped":
      return "Остановлен";
    case "initializing":
      return "Инициализация…";
    case "starting":
      return "Запуск…";
    case "running":
      return "Работает";
    case "stopping":
      return "Остановка…";
    case "failed":
      return `Сбой (${PHASES[state.phase]})`;
    case "blocked":
      return "Заблокирован";
    case "configUnavailable":
      return "Конфигурация недоступна";
  }
}

function blockText(reason: BlockReason, by: ModuleId, modules: Module[]): string {
  const name = nameOf(by, modules);
  switch (reason) {
    case "dependencyFailed":
      return `Зависимость ${name} в состоянии сбоя. Сначала восстановите её.`;
    case "dependencyDisabled":
      return `Зависимость ${name} отключена.`;
    case "dependencyConfigUnavailable": {
      // The reason stays after the dependency's record is replaced (#21):
      // the module waits for a confirmed «Восстановить».
      const dependency = modules.find((module) => module.descriptor.id === by);
      return dependency === undefined || dependency.state.kind === "configUnavailable"
        ? `Конфигурация зависимости ${name} недоступна: восстановите её или перезапустите приложение.`
        : `Конфигурация зависимости ${name} была недоступна. Чтобы запустить модуль, нажмите «Восстановить».`;
    }
  }
}

function timeOf(at: number): string {
  return new Date(at).toLocaleTimeString("ru-RU");
}

/** Explanation under the state: the error, the blocking module. `null` — nothing to add. */
export function stateDetails(state: ModuleState, modules: Module[]): string | null {
  switch (state.kind) {
    case "failed":
      return `${state.error} (${timeOf(state.at)})`;
    case "blocked":
      return blockText(state.reason, state.by, modules);
    case "configUnavailable":
      return `${state.error} (${timeOf(state.at)}). Конфигурация будет прочитана заново при следующем запуске приложения; если запись повреждена, её можно заменить: «Восстановить конфигурацию».`;
    default:
      return null;
  }
}

export function healthLabel(health: Health | null): string {
  if (health === null) return "не проверялось";
  switch (health.status) {
    case "healthy":
      return "исправен";
    case "degraded":
      return `работает с замечаниями: ${health.message}`;
    case "unhealthy":
      return `неисправен: ${health.message}`;
  }
}

const ACTIONS: Record<ChangeAction, string> = {
  enable: "Включить",
  disable: "Отключить",
  recover: "Восстановить",
  restart: "Перезапустить",
};

export function actionLabel(action: ChangeAction): string {
  return ACTIONS[action];
}

/** What happens to the other modules, e.g. «Также будут включены». */
export function affectedLabel(action: ChangeAction): string {
  switch (action) {
    case "enable":
      return "Также будут включены и запущены:";
    case "disable":
      return "Также будут остановлены и отключены:";
    case "recover":
      return "Также будут запущены:";
    case "restart":
      return "Также будут перезапущены:";
  }
}

export function stepLabel(step: PlanStep, modules: Module[]): string {
  const name = nameOf(step.id, modules);
  switch (step.kind) {
    case "enable":
      return `включить ${name}`;
    case "start":
      return `запустить ${name}`;
    case "stop":
      return `остановить ${name}`;
    case "disable":
      return `отключить ${name}`;
  }
}

/** Why the module stands in the way of a change. */
export function blockerLabel(blocker: Blocker, modules: Module[]): string {
  const name = nameOf(blocker.id, modules);
  switch (blocker.state.kind) {
    case "failed":
    case "blocked":
      return `Сначала восстановите ${name} — сейчас: ${stateLabel(blocker.state).toLowerCase()}.`;
    case "configUnavailable":
      return `Конфигурация ${name} недоступна: восстановите её или перезапустите приложение.`;
    default:
      return `${name} — сейчас: ${stateLabel(blocker.state).toLowerCase()}.`;
  }
}
