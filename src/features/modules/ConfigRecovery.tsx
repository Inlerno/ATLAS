// Recovery of a module configuration (issue #21). The stored record could not
// be read at startup (`configUnavailable`); the user types new settings, and
// after the confirmation the core replaces the record if it is damaged. The
// stored record is neither loaded nor shown here, the module stays disabled,
// and nothing is restarted.

import { useEffect, useId, useRef, useState } from "react";

import type { Module, ModuleId } from "../../types/modules";
import { nameOf } from "./labels";
import { blockedBy, confirmReplacement, requestReplacement, type Step } from "./recovery";

interface Props {
  id: ModuleId;
  modules: Module[];
  /** The record was replaced. The new state of the modules arrives as events. */
  onReplaced: () => void;
  /** Closes the panel; nothing is changed. */
  onClose: () => void;
}

export function ConfigRecovery({ id, modules, onReplaced, onClose }: Props) {
  // Empty: the stored record is not shown, not even as a starting point.
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // The settings the core asked to confirm; the dialog is open while set.
  const [pending, setPending] = useState<{ settings: unknown } | null>(null);
  const hint = useId();

  const show = (step: Step) => {
    switch (step.kind) {
      case "invalid":
      case "error":
        setPending(null);
        setError(step.message);
        break;
      case "confirm":
        setPending({ settings: step.settings });
        break;
      case "replaced":
        setPending(null);
        onReplaced();
        break;
    }
  };

  const run = async (next: () => Promise<Step>) => {
    setError(null);
    setBusy(true);
    try {
      show(await next());
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="settings">
      <p id={hint} className="module-meta">
        Сохранённая запись не загружается и не показывается. Введите новые настройки в формате
        JSON: после подтверждения они заменят запись, если она повреждена. Модуль останется
        отключённым.
      </p>
      <textarea
        aria-label={`Новые настройки модуля ${id} в формате JSON`}
        aria-describedby={hint}
        value={text}
        placeholder="Например: {}"
        spellCheck={false}
        rows={Math.min(12, Math.max(4, text.split("\n").length))}
        onChange={(event) => setText(event.target.value)}
        disabled={busy}
      />
      <div className="settings-actions">
        <button
          type="button"
          className="primary"
          onClick={() => void run(() => requestReplacement(id, text))}
          disabled={busy}
        >
          Заменить конфигурацию…
        </button>
        <button type="button" onClick={onClose} disabled={busy}>
          Отмена
        </button>
      </div>
      {error && (
        <p className="notice notice-error" role="status">
          {error}
        </p>
      )}

      {pending && (
        <ReplaceConfigDialog
          name={nameOf(id, modules)}
          blocked={blockedBy(id, modules).map((other) => nameOf(other, modules))}
          busy={busy}
          onConfirm={() => void run(() => confirmReplacement(id, pending.settings))}
          onCancel={() => setPending(null)}
        />
      )}
    </div>
  );
}

interface DialogProps {
  name: string;
  /** Names of the modules blocked by this one now. */
  blocked: string[];
  /** The replacement is being applied: nothing can be pressed. */
  busy: boolean;
  onConfirm: () => void;
  /** Closes the dialog; nothing is changed. */
  onCancel: () => void;
}

function ReplaceConfigDialog({ name, blocked, busy, onConfirm, onCancel }: DialogProps) {
  const element = useRef<HTMLDialogElement>(null);
  const title = useId();

  useEffect(() => {
    const current = element.current;
    if (current && !current.open) current.showModal();
    return () => current?.close();
  }, []);

  return (
    <dialog
      ref={element}
      className="change-dialog"
      aria-labelledby={title}
      onCancel={(event) => {
        // Esc: the same as «Отмена», and not while the replacement is applied.
        event.preventDefault();
        if (!busy) onCancel();
      }}
    >
      <h2 id={title}>Заменить конфигурацию: {name}</h2>
      <p>
        Сохранённая запись конфигурации будет удалена и заменена введёнными настройками. Вернуть
        прежнюю запись будет нельзя.
      </p>
      <ul className="affected">
        <li>Модуль останется отключённым: включите его, когда будете готовы.</li>
        {blocked.length > 0 && (
          <li>
            Останутся заблокированными, пока вы не подтвердите для них «Восстановить»:{" "}
            {blocked.join(", ")}.
          </li>
        )}
        <li>Если запись окажется читаемой, замена не выполнится: перезапустите приложение.</li>
      </ul>
      <div className="dialog-actions">
        <button type="button" onClick={onCancel} disabled={busy} autoFocus>
          Отмена
        </button>
        <button type="button" className="primary" onClick={onConfirm} disabled={busy}>
          {busy ? "Выполняется…" : "Заменить"}
        </button>
      </div>
    </dialog>
  );
}
