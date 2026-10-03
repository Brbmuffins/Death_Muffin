/** Phones and tablets, decided when a card is shown (a player may switch devices); re-read at most twice a second. */
let cached = false;
let cachedAt = -1e9;

export function touchNow(): boolean {
  const t = typeof performance !== 'undefined' ? performance.now() : 0;
  if (t - cachedAt < 500 && t >= cachedAt) return cached;
  cachedAt = t;
  try {
    cached = document.body.classList.contains('touch') || window.matchMedia('(pointer: coarse)').matches;
  } catch {
    cached = false;
  }
  return cached;
}
