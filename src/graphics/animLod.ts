/**
 * Pure rules for animation level-of-detail and the small throttles around it: near bodies animate every frame, mid
 * distance ~24 Hz, far or off-screen ~10 Hz (the skipped time accumulates, so motion stays correct); a body in a
 * one-shot (swing, cast) is never throttled. Also the burst cap on additive flinches and the HUD redraw gate.
 */
export const ANIM_MID_S = 1 / 24;
export const ANIM_FAR_S = 1 / 10;

/** Seconds that must accumulate before a body's mixer updates again (0 = every frame). `ax`/`az` are |offset| from the camera focus. */
export function animInterval(ax: number, az: number, busy: boolean, crowded: boolean): number {
  const nearX = crowded ? 10 : 13;
  const nearZ = crowded ? 9 : 11;
  if (busy || (ax < nearX && az < nearZ)) return 0;
  return ax > 26 || az > 22 ? ANIM_FAR_S : ANIM_MID_S;
}

/** Distance LOD for a figure at `dist` from the hero (guide NPCs): near 0, mid 1/24 s, far 1/10 s. */
export function distanceInterval(dist: number, busy: boolean, near = 12, far = 24): number {
  if (busy || dist < near) return 0;
  return dist < far ? ANIM_MID_S : ANIM_FAR_S;
}

/** At most `burst` starts inside any `windowMs`; returns true (and records the start) when one is allowed. `starts` is the caller's scratch list. */
export function allowBurst(starts: number[], now: number, burst: number, windowMs: number): boolean {
  while (starts.length && now - starts[0] > windowMs) starts.shift();
  if (starts.length >= burst) return false;
  starts.push(now);
  return true;
}

/** HUD readouts redraw at most every `intervalMs`; a clock that jumped back also counts as due. */
export function hudDue(now: number, last: number, intervalMs: number): boolean {
  return now - last >= intervalMs || now < last;
}
