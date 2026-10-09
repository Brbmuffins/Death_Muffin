import * as THREE from 'three';
import type { Rect } from '../../server/rules/content/areas';

/**
 * Where the camera actually looks: the ground-plane (y = 0) footprint of its view frustum.
 * Area streaming, shadow casting and the shadow camera size all used to assume "~30 m around the hero"; that is
 * true for a 16:9 window at the default zoom and false for a wider window or the widest zoom, where whole corners of the
 * screen are further than that and lost their props, floors and shadows. These helpers measure the real thing.
 */

const SAMPLES: [number, number][] = [
  [-1, -1], [0, -1], [1, -1],
  [-1, 0], [1, 0],
  [-1, 1], [0, 1], [1, 1],
];

/** Where a ray that never reaches the ground (a camera tilted up) is treated as ending: far past anything drawn. */
export const FOOTPRINT_FAR = 90;

const ray = new THREE.Vector3();
const near = new THREE.Vector3();
const pts = SAMPLES.map(() => ({ x: 0, z: 0 }));

/** Ground points hit by the rays through the screen's corners and edge midpoints. `camera.matrixWorld` and the projection must be current. The returned array is reused by the next call (per-frame use allocates nothing). */
export function footprintPoints(camera: THREE.PerspectiveCamera): { x: number; z: number }[] {
  const o = camera.position;
  for (let i = 0; i < SAMPLES.length; i++) {
    const [nx, ny] = SAMPLES[i];
    const out = pts[i];
    near.set(nx, ny, 0.5).unproject(camera);
    ray.copy(near).sub(o).normalize();
    if (ray.y < -0.02) {
      const t = -o.y / ray.y;
      out.x = o.x + ray.x * t;
      out.z = o.z + ray.z * t;
    } else {
      const h = Math.hypot(ray.x, ray.z) || 1;
      out.x = o.x + (ray.x / h) * FOOTPRINT_FAR;
      out.z = o.z + (ray.z / h) * FOOTPRINT_FAR;
    }
  }
  return pts;
}

/** The footprint's bounding rectangle, grown by `margin` metres (camera lag, tall props leaning into view). */
export function footprintRect(camera: THREE.PerspectiveCamera, margin = 6): Rect {
  let x0 = Infinity, z0 = Infinity, x1 = -Infinity, z1 = -Infinity;
  for (const p of footprintPoints(camera)) {
    if (p.x < x0) x0 = p.x;
    if (p.x > x1) x1 = p.x;
    if (p.z < z0) z0 = p.z;
    if (p.z > z1) z1 = p.z;
  }
  return { x0: x0 - margin, z0: z0 - margin, x1: x1 + margin, z1: z1 + margin };
}

export function rectsOverlap(a: Rect, b: Rect) {
  return a.x0 <= b.x1 && a.x1 >= b.x0 && a.z0 <= b.z1 && a.z1 >= b.z0;
}

/** Furthest footprint point from (x, z): how far from the hero something can still be on screen. */
export function footprintReach(camera: THREE.PerspectiveCamera, x: number, z: number) {
  let r = 0;
  for (const p of footprintPoints(camera)) r = Math.max(r, Math.hypot(p.x - x, p.z - z));
  return r;
}

/**
 * Half-size (m) the moon's orthographic shadow camera needs so every footprint point falls inside it, never below `min`
 * (the old fixed 30) and never above `max` (texel density: a 1024 map over 2*max metres). `lightView` is the shadow camera's
 * matrixWorldInverse; the camera is square so one number serves both axes.
 */
export function shadowHalfExtent(camera: THREE.PerspectiveCamera, lightView: THREE.Matrix4, min = 30, max = 48, pad = 1.06, step = 4) {
  let h = 0;
  const v = new THREE.Vector3();
  for (const p of footprintPoints(camera)) {
    v.set(p.x, 0, p.z).applyMatrix4(lightView);
    h = Math.max(h, Math.abs(v.x), Math.abs(v.y));
  }
  // Whole steps, so the camera's follow lag never makes the box (and with it every shadow texel) shimmer; the default view stays exactly `min`.
  const need = h * pad;
  return need <= min ? min : Math.min(max, Math.ceil(need / step) * step);
}
