/** How far a window body must scroll before its Back to top button appears. */
export const BACK_TO_TOP_AFTER = 120;

/**
 * Windows keep a fixed header (title and close button) and scroll only their body. Panels redraw with `el.innerHTML = ...`
 * starting with a `.cw-panel-head`; call this right after that assignment to move everything after the head into a
 * `.cw-panel-body`, which is the part that scrolls (see `.cw-panel-float` in ui.css). The body also gets a "Back to top"
 * button that appears once it is scrolled down, so the tabs and filters at the top are one click away.
 */
export function wrapPanelBody(el: HTMLElement): void {
  const head = el.querySelector(':scope > .cw-panel-head');
  if (!head) return;
  const body = document.createElement('div');
  body.className = 'cw-panel-body';
  while (head.nextSibling) body.appendChild(head.nextSibling);
  const dock = document.createElement('div');
  dock.className = 'cw-back-top';
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.textContent = '↑ Back to top';
  btn.setAttribute('aria-label', 'Back to top');
  btn.addEventListener('click', () => {
    body.scrollTop = 0;
  });
  dock.appendChild(btn);
  body.appendChild(dock);
  let shown = false;
  body.addEventListener(
    'scroll',
    () => {
      const far = body.scrollTop > BACK_TO_TOP_AFTER;
      if (far === shown) return;
      shown = far;
      dock.classList.toggle('show', far);
    },
    { passive: true },
  );
  el.appendChild(body);
}
