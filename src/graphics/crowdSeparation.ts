/**
 * View-layer crowd separation. The sim keeps bodies apart with one partial pass per tick, so a pack closing on the hero
 * still stacks: models overlap and limbs clip. This takes the sim positions and returns how far each *drawn* body should
 * slide so the pack reads as individuals. It never touches the sim (hits, ranges and AI keep the true positions); the
 * view eases toward the result, and the slide is capped, so it only ever dresses the crowd.
 */

export interface CrowdBody {
  x: number;
  z: number;
  /** Drawn footprint radius. */
  r: number;
  /** How readily it yields (0 = immovable, e.g. the hero). */
  w: number;
}

export interface SeparationOptions {
  iterations?: number;
  /** Largest slide of any body from its sim position, units. */
  maxOffset?: number;
  /** Fraction of the summed radii bodies are pushed apart to (below 1 lets neighbours touch). */
  fit?: number;
}

/**
 * Offsets (dx, dz per body, written into `out`, length >= 2n) that relax overlaps among `bodies`. Pairs push apart along
 * their line of centres in proportion to how much each yields; two passes settle a clump without a long solver.
 */
/** Reused between frames: the view calls this every frame with a similar-sized crowd. */
let scratchX = new Float32Array(64);
let scratchZ = new Float32Array(64);

export function separateBodies(bodies: readonly CrowdBody[], out: Float32Array, opts: SeparationOptions = {}, count = bodies.length) {
  const n = count;
  const iterations = opts.iterations ?? 2;
  const maxOffset = opts.maxOffset ?? 0.5;
  const fit = opts.fit ?? 0.95;
  const px = scratchX.length >= n ? scratchX : (scratchX = new Float32Array(n * 2));
  const pz = scratchZ.length >= n ? scratchZ : (scratchZ = new Float32Array(n * 2));
  for (let i = 0; i < n; i++) {
    px[i] = bodies[i].x;
    pz[i] = bodies[i].z;
  }
  for (let it = 0; it < iterations; it++) {
    for (let i = 0; i < n; i++) {
      const a = bodies[i];
      for (let j = i + 1; j < n; j++) {
        const b = bodies[j];
        const min = (a.r + b.r) * fit;
        const dx = px[j] - px[i];
        const dz = pz[j] - pz[i];
        if (dx > min || dx < -min || dz > min || dz < -min) continue;
        const d = Math.hypot(dx, dz);
        if (d >= min) continue;
        let nx = dx / d;
        let nz = dz / d;
        if (d < 1e-4) {
          // Stacked exactly: split along a direction that differs per pair so a clump unravels.
          const ang = (i * 12.9898 + j * 78.233) % (Math.PI * 2);
          nx = Math.cos(ang);
          nz = Math.sin(ang);
        }
        const total = a.w + b.w;
        if (total <= 0) continue;
        const push = min - d;
        const pa = (a.w / total) * push;
        const pb = (b.w / total) * push;
        px[i] -= nx * pa;
        pz[i] -= nz * pa;
        px[j] += nx * pb;
        pz[j] += nz * pb;
      }
    }
  }
  for (let i = 0; i < n; i++) {
    let ox = px[i] - bodies[i].x;
    let oz = pz[i] - bodies[i].z;
    const len = Math.hypot(ox, oz);
    if (len > maxOffset) {
      ox *= maxOffset / len;
      oz *= maxOffset / len;
    }
    out[i * 2] = ox;
    out[i * 2 + 1] = oz;
  }
}

/** Overlapping pairs (centres closer than `fit` of the summed radii): the crowd metric the QA smoke reports. */
export function countOverlaps(bodies: readonly CrowdBody[], fit = 0.8): number {
  let hits = 0;
  for (let i = 0; i < bodies.length; i++) {
    for (let j = i + 1; j < bodies.length; j++) {
      const a = bodies[i];
      const b = bodies[j];
      if (Math.hypot(a.x - b.x, a.z - b.z) < (a.r + b.r) * fit) hits++;
    }
  }
  return hits;
}
