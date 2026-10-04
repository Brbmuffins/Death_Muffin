/** How far a window body must scroll before its Back to top button appears. */
export const BACK_TO_TOP_AFTER = 120;
/** The button fades away this long after the last scroll, so it never hides text for long (it returns on the next scroll). */
export const BACK_TO_TOP_HIDE_MS = 2000;

/**
 * Windows keep a fixed header (title and close button) and scroll only their body. Panels redraw with `el.innerHTML = ...`
 * starting with a `.cw-panel-head`; call this right after that assignment to move everything after the head into a
 * `.cw-panel-body`, which is the part that scrolls (see `.cw-panel-float` in ui.css). The body also gets a "Back to top"
 * button that appears while it is scrolled down and tucks away 2 seconds after scrolling stops, so the tabs and filters
 * at the top are one click away without the button covering text.
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
  let lastScroll = 0;
  let hovered = false;
  let timer = 0;
  btn.addEventListener('mouseenter', () => (hovered = true));
  btn.addEventListener('mouseleave', () => {
    hovered = false;
    lastScroll = performance.now();
  });
  const setShown = (on: boolean) => {
    shown = on;
    dock.classList.toggle('show', on);
  };
  // One timer per window, re-armed only when it fires: scrolling just stamps the time.
  const check = () => {
    timer = 0;
    const left = BACK_TO_TOP_HIDE_MS - (performance.now() - lastScroll);
    if (!shown) return;
    if (hovered || left > 0) timer = window.setTimeout(check, hovered ? BACK_TO_TOP_HIDE_MS : left);
    else setShown(false);
  };
  body.addEventListener(
    'scroll',
    () => {
      if (body.scrollTop <= BACK_TO_TOP_AFTER) {
        if (shown) setShown(false);
        return;
      }
      lastScroll = performance.now();
      if (!shown) setShown(true);
      if (!timer) timer = window.setTimeout(check, BACK_TO_TOP_HIDE_MS);
    },
    { passive: true },
  );
  el.appendChild(body);
}
