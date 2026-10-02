/**
 * Panels redraw by assigning `el.innerHTML`, which throws away every scrolling child and resets the panel's own scrollTop to 0.
 * During AFK gathering that happens on each XP/loot tick, so a player who scrolled down is snapped back to the top.
 * `preserveScroll(el, redraw)` records the scroll offset of `el` and of every scrolled descendant, runs the redraw, then restores
 * the offsets. Descendants are matched by tag + class list + occurrence index, which survives a same-shaped redraw.
 */
const keyOf = (n: Element) => `${n.tagName}.${typeof n.className === 'string' ? n.className : ''}`;

export function preserveScroll<T>(el: HTMLElement, redraw: () => T): T {
  const top = el.scrollTop;
  const left = el.scrollLeft;
  const saved: { key: string; nth: number; top: number; left: number }[] = [];
  const seen = new Map<string, number>();
  for (const n of Array.from(el.querySelectorAll<HTMLElement>('*'))) {
    const key = keyOf(n);
    const nth = seen.get(key) ?? 0;
    seen.set(key, nth + 1);
    if (n.scrollTop > 0 || n.scrollLeft > 0) saved.push({ key, nth, top: n.scrollTop, left: n.scrollLeft });
  }
  const result = redraw();
  if (saved.length) {
    const seen2 = new Map<string, number>();
    const want = new Map(saved.map((s) => [`${s.key}#${s.nth}`, s]));
    for (const n of Array.from(el.querySelectorAll<HTMLElement>('*'))) {
      const key = keyOf(n);
      const nth = seen2.get(key) ?? 0;
      seen2.set(key, nth + 1);
      const s = want.get(`${key}#${nth}`);
      if (s) { n.scrollTop = s.top; n.scrollLeft = s.left; }
    }
  }
  if (top) el.scrollTop = top;
  if (left) el.scrollLeft = left;
  return result;
}
