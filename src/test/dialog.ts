// jsdom implements <dialog> only as the `open` attribute (checked with jsdom
// 31): there is no showModal() or close(), and Esc sends no close request.
// This adds the part of the HTML behaviour the components rely on:
// - showModal() opens the dialog as a modal one; close() closes it and fires
//   `close`;
// - Esc, when no handler prevented its keydown, is a close request to the
//   topmost modal dialog: a cancelable `cancel` event, after which the dialog
//   closes unless the event was cancelled.
// Not emulated: the top layer, the inertness of the rest of the page, and
// focus moving into the dialog (React's autoFocus focuses the element).

export function installDialog(): void {
  const prototype = HTMLDialogElement.prototype;
  // The environment has its own implementation: use it.
  if (typeof prototype.showModal === "function") return;

  const modal: HTMLDialogElement[] = [];

  prototype.showModal = function showModal(this: HTMLDialogElement) {
    if (this.open) {
      if (modal.includes(this)) return;
      throw new DOMException(
        "The dialog is already open as a non-modal dialog.",
        "InvalidStateError",
      );
    }
    if (!this.isConnected) {
      throw new DOMException("The dialog is not connected.", "InvalidStateError");
    }
    this.setAttribute("open", "");
    modal.push(this);
  };

  prototype.close = function close(this: HTMLDialogElement) {
    if (!this.open) return;
    this.removeAttribute("open");
    const index = modal.indexOf(this);
    if (index !== -1) modal.splice(index, 1);
    this.dispatchEvent(new Event("close"));
  };

  window.addEventListener("keydown", (event) => {
    if (event.key !== "Escape" || event.defaultPrevented) return;
    const open = modal.filter((dialog) => dialog.isConnected);
    const dialog = open[open.length - 1];
    if (dialog === undefined) return;
    if (dialog.dispatchEvent(new Event("cancel", { cancelable: true }))) dialog.close();
  });
}
