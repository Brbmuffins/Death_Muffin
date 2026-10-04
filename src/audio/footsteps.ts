/**
 * Footstep timing for the hero, in step with the walk animation. Pure (no WebAudio): the scene feeds it the walk loop's
 * phase (Creature.loopPhase) and position each frame, and plays a surface step whenever it reports a footfall.
 *
 * A walk cycle has two footfalls, half a cycle apart, so a step is due each time the phase crosses `FOOT_PHASES`; that follows the
 * clip at whatever speed the stride matching set (the old fixed timer drifted from the feet). Without a phase (the clip is not
 * loaded, or a one-shot is playing) it falls back to one step per `FALLBACK_STRIDE` units walked.
 */
/** Where in the loop the feet plant (fractions of the cycle). The two are half a cycle apart. */
export const FOOT_PHASES = [0.04, 0.54] as const;
export const FALLBACK_STRIDE = 1.35;

export class FootstepTracker {
  private last = -1;
  private px = NaN;
  private pz = NaN;
  private dist = 0;

  /** True when a foot lands this frame. `phase` is null when no walk loop is playing. */
  step(phase: number | null, x: number, z: number): boolean {
    const moved = Number.isNaN(this.px) ? 0 : Math.hypot(x - this.px, z - this.pz);
    this.px = x;
    this.pz = z;
    if (phase === null) {
      this.last = -1;
      this.dist += moved;
      if (this.dist >= FALLBACK_STRIDE) {
        this.dist = 0;
        return true;
      }
      return false;
    }
    this.dist = 0;
    const prev = this.last;
    this.last = phase;
    if (prev < 0) return false;
    for (const f of FOOT_PHASES) {
      // crossed f going forward, allowing for the loop wrapping from ~1 back to ~0
      if (prev <= phase ? prev < f && phase >= f : prev < f || phase >= f) return true;
    }
    return false;
  }

  /** The hero stopped: the next walk starts fresh (no step on the first frame). */
  reset() {
    this.last = -1;
    this.px = NaN;
    this.pz = NaN;
    this.dist = 0;
  }
}
