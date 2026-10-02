import STRIDE_JSON from '../content/strideSpeeds.json';

/**
 * Pure rules for locomotion: which looping clip a creature should play for a ground speed and how fast, so its feet
 * stay planted instead of skating. Stride speeds are measured per model (tools/build-stride-speeds.mjs): the planted
 * feet's speed relative to the body, in body-heights per second, so a scaled elite or boss strides at its own pace.
 */

export interface StrideRow {
  walk?: number;
  run?: number;
}

/** Measured stride speeds, body-heights per second (src/content/strideSpeeds.json). */
export const STRIDES = STRIDE_JSON as Record<string, StrideRow>;

/** Walk speed assumed for a rig nobody measured (body-heights per second; the shipped biped rigs all sit near 0.7). */
export const DEFAULT_WALK = 0.7;
/** Slowest and fastest playback of a locomotion clip. Past the fast end the feet slide a little rather than flail. */
export const LOCO_MIN = 0.4;
export const WALK_MAX = 3;
export const RUN_MAX = 2.4;
/** A model with a run clip switches to it once the walk would need this many times its natural pace, and back below RUN_DOWN. */
export const RUN_UP = 2;
export const RUN_DOWN = 1.6;

export interface LocomotionPlan {
  clip: 'walk' | 'run';
  /** Playback speed of the clip. */
  timeScale: number;
  /** The clip's natural ground speed (units per second) at timeScale 1. */
  stride: number;
  /** Share of the ground speed the feet will still slide (0 = planted). */
  residual: number;
}

/** Largest walk playback for a body of this height: big bosses keep a heavier cadence than a rat. */
export function walkCap(height: number): number {
  return Math.min(WALK_MAX, Math.max(1.6, WALK_MAX * Math.sqrt(2 / Math.max(0.1, height))));
}

/**
 * Pick walk or run (with hysteresis through `wasRun`) and the playback speed that matches `ground` (units/s) for a body
 * `height` units tall (its world height, scale included).
 */
export function planLocomotion(row: StrideRow | undefined, height: number, ground: number, hasRun: boolean, wasRun = false): LocomotionPlan {
  const walkU = (row?.walk ?? DEFAULT_WALK) * height;
  const runU = hasRun && row?.run ? row.run * height : 0;
  const run = runU > 0 && ground > walkU * (wasRun ? RUN_DOWN : RUN_UP);
  const stride = run ? runU : walkU;
  const max = run ? RUN_MAX : walkCap(height);
  const timeScale = Math.min(max, Math.max(LOCO_MIN, ground / stride));
  return { clip: run ? 'run' : 'walk', timeScale, stride, residual: ground > 1e-3 ? Math.abs(ground - timeScale * stride) / ground : 0 };
}

/** Exponential smoothing of a measured speed (time constant `tau` seconds), framerate independent. */
export function smoothSpeed(prev: number, sample: number, dt: number, tau = 0.12): number {
  return prev + (sample - prev) * (1 - Math.exp(-Math.max(0, dt) / tau));
}

/** Ground speed from one frame's displacement. A jump of more than `maxStep` units is a teleport and reads as standing still. */
export function stepSpeed(dx: number, dz: number, dt: number, maxStep = 3): number {
  const d = Math.hypot(dx, dz);
  return dt > 1e-5 && d <= maxStep ? d / dt : 0;
}

/** Shortest signed angle from `a` to `b`, radians. */
export function angleDelta(a: number, b: number): number {
  let d = b - a;
  while (d > Math.PI) d -= Math.PI * 2;
  while (d < -Math.PI) d += Math.PI * 2;
  return d;
}

/**
 * Turn `cur` toward `target`: an exponential ease (`rate` per second) that never exceeds `maxRate` rad/s, so a sudden
 * about-face is seen as a turn instead of a snap.
 */
export function turnToward(cur: number, target: number, dt: number, rate: number, maxRate = Infinity): number {
  const d = angleDelta(cur, target);
  const lim = maxRate * dt;
  return cur + Math.max(-lim, Math.min(lim, d * Math.min(1, dt * rate)));
}
