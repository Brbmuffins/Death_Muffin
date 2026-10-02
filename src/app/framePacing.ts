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

/**
 * Dynamic resolution: when frames sustainedly miss the cap's budget (a GPU that can't keep up), render fewer pixels;
 * when there is headroom again, step back up. A step up that fails right away becomes the ceiling, so it doesn't ping-pong.
 */
export class ResolutionGovernor {
  /** Multiplier on the quality preset's pixel ratio. */
  scale = 1;
  private ceiling = 1;
  private over = 0;
  private under = 0;
  private sinceChange = 0;
  private raisedFrom = 0;

  static readonly MIN = 0.6;
  static readonly STEP = 0.85;
  /** Seconds a frame-time trend must hold before acting. */
  static readonly DOWN_AFTER_S = 2;
  static readonly UP_AFTER_S = 12;

  /** Feed one processed frame: `dtS` real seconds, `smoothMs` the smoothed frame time, `fps` the cap. Returns true when `scale` changed. */
  frame(dtS: number, smoothMs: number, fps: number): boolean {
    const budget = 1000 / fps;
    this.sinceChange += dtS;
    // Let the smoothed frame time settle after a change before judging it.
    if (this.sinceChange < 1.5) return false;
    if (smoothMs > budget * 1.3) {
      this.over += dtS;
      this.under = 0;
    } else if (smoothMs < budget * 1.08) {
      this.under += dtS;
      this.over = 0;
    } else {
      this.over = 0;
      this.under = 0;
    }
    if (this.over >= ResolutionGovernor.DOWN_AFTER_S && this.scale > ResolutionGovernor.MIN) {
      // Dropping straight after a raise: the raised level is too much, stay below it.
      if (this.raisedFrom && this.sinceChange < 6) this.ceiling = this.raisedFrom;
      this.raisedFrom = 0;
      return this.set(Math.max(ResolutionGovernor.MIN, this.scale * ResolutionGovernor.STEP));
    }
    if (this.under >= ResolutionGovernor.UP_AFTER_S && this.scale < this.ceiling) {
      this.raisedFrom = this.scale;
      return this.set(Math.min(this.ceiling, this.scale / ResolutionGovernor.STEP));
    }
    return false;
  }

  /** Quality or cap changed by the player: start over at full resolution. */
  reset() {
    this.scale = 1;
    this.ceiling = 1;
    this.raisedFrom = 0;
    this.over = this.under = this.sinceChange = 0;
  }

  private set(s: number) {
    this.scale = Math.round(s * 100) / 100;
    if (this.scale > 0.98) this.scale = 1;
    this.over = this.under = this.sinceChange = 0;
    return true;
  }
}
