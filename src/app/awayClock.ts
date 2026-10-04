/**
 * Wall-clock bookkeeping for "the page was away" (phone app switch, frozen/suspended tab, throttled hidden timers).
 *
 * Phone browsers freeze a page the moment you leave it, so neither requestAnimationFrame nor the hidden-tab interval
 * runs and the frame clock's dt is clamped on return: the time away simply vanished. This clock is the single source of
 * truth for "time nobody has simulated yet". Every consumer (a rendered frame, a hidden-tab tick, a resume event) takes
 * its share with `lap()`, which also moves the mark, so the same wall-clock second can never be counted twice.
 */

/** Gaps shorter than this are ordinary frame hitches, not an absence. */
export const AWAY_MIN_S = 3;

/**
 * The most away time that is caught up at once. Matches the server's AFK budget window
 * (`afk ? 90_000` in gathering-rules): the server only ever credits 90 s of unclaimed time per request, so claiming
 * more would just be dropped. It is also the cap the hidden-tab interval has always used.
 */
export const AFK_AWAY_CAP_S = 90;

export class AwayClock {
  private mark: number;

  constructor(nowMs: number) {
    this.mark = nowMs;
  }

  /** Seconds since the last lap (0 when the wall clock went backwards), and move the mark to `nowMs`. */
  lap(nowMs: number): number {
    const gap = (nowMs - this.mark) / 1000;
    this.mark = nowMs;
    return Number.isFinite(gap) && gap > 0 ? gap : 0;
  }
}

/** How much of a raw gap is worth catching up: nothing for hitches, otherwise capped. */
export function catchUpSeconds(rawGapS: number): number {
  if (!Number.isFinite(rawGapS) || rawGapS < AWAY_MIN_S) return 0;
  return Math.min(rawGapS, AFK_AWAY_CAP_S);
}
