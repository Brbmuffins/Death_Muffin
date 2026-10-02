import { settings } from '../app/settings';

/**
 * Hitstop: a 2-4 frame micro-freeze of the picture on a heavy impact. Visual only: it scales the time that animation
 * mixers and particles see, never the sim clock, so damage, cooldowns and networking are untouched.
 *
 * Crowds must not stutter, so freezes are rationed: a minimum gap between them and a leaky budget (a freeze spends its
 * length; the budget refills at REFILL seconds per second), which caps the share of time spent frozen at about 12%.
 */
export const FRAME = 1 / 60;
export const MIN_FRAMES = 2;
export const MAX_FRAMES = 4;
export const MIN_GAP = 0.3;
export const BUDGET_MAX = 0.25;
export const REFILL = 0.12;

/** Freeze length in seconds for an impact weight in 0..1 (0 = light, 1 = boss slam). */
export function hitstopSeconds(weight: number): number {
  const w = Math.min(1, Math.max(0, weight));
  return Math.round(MIN_FRAMES + w * (MAX_FRAMES - MIN_FRAMES)) * FRAME;
}

export class HitStop {
  private left = 0;
  private gap = 0;
  private budget = BUDGET_MAX;
  /** Seconds frozen in total (QA reads it). */
  total = 0;
  count = 0;
  /** When true requests are ignored (reduced motion). */
  disabled = () => false;

  /** Ask for a freeze. Returns the seconds granted (0 when refused or already frozen longer). */
  request(weight: number): number {
    if (this.disabled()) return 0;
    const sec = hitstopSeconds(weight);
    if (this.left > 0) {
      // A stronger hit may extend the running freeze but never stack on top of it.
      if (sec > this.left && this.budget >= sec - this.left) {
        this.budget -= sec - this.left;
        this.total += sec - this.left;
        this.left = sec;
      }
      return 0;
    }
    if (this.gap > 0 || this.budget < sec) return 0;
    this.budget -= sec;
    this.left = sec;
    this.gap = MIN_GAP;
    this.total += sec;
    this.count++;
    return sec;
  }

  /** Advance by a real frame; returns the time the picture should advance (0 while frozen, the remainder after). */
  tick(dt: number): number {
    this.budget = Math.min(BUDGET_MAX, this.budget + dt * REFILL);
    this.gap = Math.max(0, this.gap - dt);
    if (this.left <= 0) return dt;
    const used = Math.min(this.left, dt);
    this.left -= used;
    return dt - used;
  }

  get frozen(): boolean {
    return this.left > 0;
  }

  /** Multiplier for the frame's dt in animation and particles: 0 while frozen. */
  scale = 1;

  /** Call once per frame with the real dt; sets `scale` for the visual updates that follow. */
  frame(dt: number) {
    this.scale = dt > 0 ? this.tick(dt) / dt : 1;
  }

  reset() {
    this.left = 0;
    this.gap = 0;
    this.budget = BUDGET_MAX;
    this.scale = 1;
  }
}

/** The one in the game. */
export const hitstop = new HitStop();
hitstop.disabled = () => settings.reducedMotion;
