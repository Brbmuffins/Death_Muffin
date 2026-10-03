/** Pure frame-pacing decisions for the render loop (battery saver). */

/** 0 = "Max": no cap, the display's own refresh rate (120/144 Hz screens run at full speed). */
export type FpsCap = 0 | 30 | 60;

export function isFpsCap(v: unknown): v is FpsCap {
  return v === 0 || v === 30 || v === 60;
}

/** The rate the resolution governor judges frame times against (Max is judged against 60: a 144 Hz miss is not a GPU problem). */
export function budgetFps(cap: number): number {
  return cap > 0 ? cap : 60;
}

/** Slack so a 60 Hz screen (16.7 ms ticks) is not accidentally halved by jitter. */
const SLACK_MS = 2;

/** True when enough time has passed since the last processed frame to run another at the capped rate. */
export function shouldProcessFrame(now: number, last: number, fps: number): boolean {
  if (!(last > 0) || !(fps > 0)) return true;
  return now - last >= 1000 / fps - SLACK_MS;
}

/**
 * Dynamic resolution: when frames sustainedly miss the cap's budget (a GPU that can't keep up), render fewer pixels;
 * when there is headroom again, step back up. A step up that fails right away becomes the ceiling, so it doesn't ping-pong.
 *
 * Every change resizes the canvas (a hitch, and a blurrier picture), so it is deliberately timid: it needs several
 * seconds of sustained misses, changes at most once per MIN_GAP_S, takes small steps, and never acts while `hold()`
 * is active (area entry / scene load, when frames are slow for reasons that pass).
 */
export class ResolutionGovernor {
  /** Multiplier on the quality preset's pixel ratio. */
  scale = 1;
  private ceiling = 1;
  private over = 0;
  private under = 0;
  private sinceChange = ResolutionGovernor.MIN_GAP_S;
  private raisedFrom = 0;
  private held = 0;

  static readonly MIN = 0.6;
  static readonly STEP = 0.9;
  /** Seconds a frame-time trend must hold before acting. */
  static readonly DOWN_AFTER_S = 3.5;
  static readonly UP_AFTER_S = 15;
  /** Minimum seconds between two changes. */
  static readonly MIN_GAP_S = 20;
  /** Seconds to stand down after an area entry or scene load. */
  static readonly HOLD_S = 10;

  /** Ignore frame times for `seconds` (a scene load or area entry); trends restart afterwards. */
  hold(seconds = ResolutionGovernor.HOLD_S) {
    this.held = Math.max(this.held, seconds);
    this.over = this.under = 0;
  }

  /** Feed one processed frame: `dtS` real seconds, `smoothMs` the smoothed frame time, `fps` the cap. Returns true when `scale` changed. */
  frame(dtS: number, smoothMs: number, fps: number): boolean {
    const budget = 1000 / fps;
    this.sinceChange += dtS;
    if (this.held > 0) {
      this.held -= dtS;
      this.over = this.under = 0;
      return false;
    }
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
    const settled = this.sinceChange >= ResolutionGovernor.MIN_GAP_S;
    if (settled && this.over >= ResolutionGovernor.DOWN_AFTER_S && this.scale > ResolutionGovernor.MIN) {
      // Dropping straight after a raise: the raised level is too much, stay below it.
      if (this.raisedFrom && this.sinceChange < 60) this.ceiling = this.raisedFrom;
      this.raisedFrom = 0;
      return this.set(Math.max(ResolutionGovernor.MIN, this.scale * ResolutionGovernor.STEP));
    }
    if (settled && this.under >= ResolutionGovernor.UP_AFTER_S && this.scale < this.ceiling) {
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
    this.over = this.under = 0;
    this.sinceChange = ResolutionGovernor.MIN_GAP_S;
    this.held = 0;
  }

  private set(s: number) {
    this.scale = Math.round(s * 100) / 100;
    if (this.scale > 0.98) this.scale = 1;
    this.over = this.under = this.sinceChange = 0;
    return true;
  }
}
