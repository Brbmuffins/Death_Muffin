/**
 * Windows keep a fixed header (title and close button) and scroll only their body. Panels redraw with `el.innerHTML = ...`
 * starting with a `.cw-panel-head`; call this right after that assignment to move everything after the head into a
 * `.cw-panel-body`, which is the part that scrolls (see `.cw-panel-float` in ui.css).
 */
export function wrapPanelBody(el: HTMLElement): void {
  const head = el.querySelector(':scope > .cw-panel-head');
  if (!head) return;
  const body = document.createElement('div');
  body.className = 'cw-panel-body';
  while (head.nextSibling) body.appendChild(head.nextSibling);
  el.appendChild(body);
}
