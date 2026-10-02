/** Pure frame-pacing decisions for the render loop (battery saver). */

export type FpsCap = 30 | 60;

export function isFpsCap(v: unknown): v is FpsCap {
  return v === 30 || v === 60;
}

/** Slack so a 60 Hz screen (16.7 ms ticks) is not accidentally halved by jitter. */
const SLACK_MS = 2;

/** True when enough time has passed since the last processed frame to run another at the capped rate. */
export function shouldProcessFrame(now: number, last: number, fps: number): boolean {
  if (!(last > 0)) return true;
  return now - last >= 1000 / fps - SLACK_MS;
}

/** While a full-screen panel covers the 3D view we only redraw ~6 times a second. */
export const COVERED_RENDER_MS = 1000 / 6;

export function shouldRender(now: number, lastRender: number, covered: boolean): boolean {
  if (!covered || !(lastRender > 0)) return true;
  return now - lastRender >= COVERED_RENDER_MS;
}
