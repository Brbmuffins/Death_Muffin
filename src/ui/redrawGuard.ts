/**
 * A panel that redraws from a timer or a server push replaces its buttons. A click whose press landed on the old button and whose
 * release lands on the new one never fires, so the click is swallowed. `controlUnderPointer` says whether a redraw that nobody asked
 * for should wait: the pointer is over a control, or a dropdown / text box has focus (an open native picker closes on a redraw).
 * Redraws the player causes (their own click) are not guarded: they run on purpose.
 */
export const CONTROL_ACTIVE_SELECTOR = 'button:hover, select:hover, select:focus, input:hover, input:focus';

export function controlUnderPointer(panel: Pick<Element, 'querySelector'> | null): boolean {
  return !!panel?.querySelector(CONTROL_ACTIVE_SELECTOR);
}
