/**
 * Visual knockback: a hit shoves the DRAWN body along a short offset that eases back to its sim position. The sim never
 * sees it (positions, collisions and corpse spots are untouched). A critically damped spring gives the weighty
 * "shove, then settle" without overshoot.
 */
export interface Knock {
  x: number;
  z: number;
  vx: number;
  vz: number;
}

/** Spring stiffness (1/s); critical damping uses 2*sqrt(k). Settles in about 0.45 s. */
export const KNOCK_K = 140;
export const KNOCK_MAX = 0.6;

/**
 * Impulse for a hit: `frac` is the share of the target's max hp the hit took, `mass` its weight (scale squared; bosses
 * pass a large one). Returns the starting velocity (u/s) along (dx, dz), the direction from the attacker.
 */
export function knockImpulse(frac: number, mass: number, dx: number, dz: number): { vx: number; vz: number } {
  const len = Math.hypot(dx, dz) || 1;
  const push = Math.min(1, Math.max(0, frac)) ** 0.6 * 16 / Math.max(0.6, mass);
  const v = Math.min(push, 20);
  return { vx: (dx / len) * v, vz: (dz / len) * v };
}

/** Advance the spring by dt; offsets stay within KNOCK_MAX. Semi-implicit Euler, substepped for stability. */
export function stepKnock(k: Knock, dt: number) {
  const n = Math.max(1, Math.ceil(dt / (1 / 120)));
  const h = dt / n;
  const c = 2 * Math.sqrt(KNOCK_K);
  for (let i = 0; i < n; i++) {
    k.vx += (-KNOCK_K * k.x - c * k.vx) * h;
    k.vz += (-KNOCK_K * k.z - c * k.vz) * h;
    k.x += k.vx * h;
    k.z += k.vz * h;
  }
  const d = Math.hypot(k.x, k.z);
  if (d > KNOCK_MAX) {
    k.x *= KNOCK_MAX / d;
    k.z *= KNOCK_MAX / d;
  }
  if (d < 1e-3 && Math.hypot(k.vx, k.vz) < 0.02) k.x = k.z = k.vx = k.vz = 0;
}

export function knockActive(k: Knock): boolean {
  return k.x !== 0 || k.z !== 0 || k.vx !== 0 || k.vz !== 0;
}

/**
 * Death settle: after a body lands it eases down by `depth` over `dur` seconds (smoothstep), so a corpse seems to
 * weigh into the ground rather than stopping dead. Pure; the caller applies it to the model's y only.
 */
export function settleDepth(t: number, depth: number, dur = 0.45): number {
  const k = Math.min(1, Math.max(0, t / dur));
  return depth * k * k * (3 - 2 * k);
}
