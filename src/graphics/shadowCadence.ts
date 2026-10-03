/** Shadow-map budget helpers: a ~30 Hz refresh cadence and a texel-snapped follow for the moon's shadow camera. */

/** Target shadow refresh rate on High. The map is re-rendered at most this often; between refreshes the lit materials keep sampling it. */
export const SHADOW_HZ = 30;
/** Slack so a 60 Hz screen (16.7 ms ticks) refreshes every second frame instead of occasionally every third. */
const SLACK_MS = 2;

/**
 * Decides which rendered frames also re-render the shadow map. The shadow matrix only changes when the map is
 * re-rendered, so skipped frames stay self-consistent: the shadows are merely up to one refresh old.
 */
export class ShadowCadence {
  private last = -Infinity;
  private forced = true;

  /** The next frame must refresh (area change, teleport, quality change, scene swap). */
  force() {
    this.forced = true;
  }

  /** True when this frame (at `nowMs`) should refresh the shadow map. */
  due(nowMs: number, hz = SHADOW_HZ): boolean {
    if (this.forced || !(hz > 0) || nowMs - this.last >= 1000 / hz - SLACK_MS || nowMs < this.last) {
      this.forced = false;
      this.last = nowMs;
      return true;
    }
    return false;
  }
}

export interface SnappedFollow {
  x: number;
  y: number;
  z: number;
}

/**
 * Snaps a shadow-camera look-at point to whole shadow-map texels in light space so the map's texel grid stays fixed on
 * the ground while the camera follows the hero (otherwise shadow edges shimmer as the camera creeps). `offset` is the
 * light's position relative to the target; `texel` is the world size of one shadow texel (frustum width / map size).
 */
export function snapShadowTarget(x: number, z: number, offset: { x: number; y: number; z: number }, texel: number, out: SnappedFollow = { x: 0, y: 0, z: 0 }): SnappedFollow {
  // Light looks along f = -offset. Light-space right = normalize(f x up), light-space up = right x f.
  const fl = Math.hypot(offset.x, offset.y, offset.z) || 1;
  const fx = -offset.x / fl, fy = -offset.y / fl, fz = -offset.z / fl;
  // f x (0,1,0) = (-fz, 0, fx)
  const rl = Math.hypot(fz, fx) || 1;
  const rx = -fz / rl, rz = fx / rl;
  // up = r x f
  const ux = -rz * fy, uy = rz * fx - rx * fz, uz = rx * fy;
  const cr = x * rx + z * rz;
  const cu = x * ux + z * uz; // y is 0 on the ground plane
  const dr = Math.round(cr / texel) * texel - cr;
  const du = Math.round(cu / texel) * texel - cu;
  out.x = x + rx * dr + ux * du;
  out.y = uy * du;
  out.z = z + rz * dr + uz * du;
  return out;
}
