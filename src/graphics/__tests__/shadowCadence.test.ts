import { describe, expect, it } from 'vitest';
import { ShadowCadence, snapShadowTarget } from '../shadowCadence';

describe('ShadowCadence', () => {
  it('refreshes the first frame, then every other frame on a 60 Hz screen (~30 Hz)', () => {
    const c = new ShadowCadence();
    let n = 0;
    for (let t = 1000; t < 2000; t += 1000 / 60) if (c.due(t)) n++;
    expect(n).toBeGreaterThan(28);
    expect(n).toBeLessThan(33);
  });
  it('holds ~30 Hz on a 144 Hz screen and refreshes every frame at a 30 fps cap', () => {
    for (const [hz, lo, hi] of [[144, 28, 34], [30, 28, 32]] as const) {
      const c = new ShadowCadence();
      let n = 0;
      for (let t = 1000; t < 2000; t += 1000 / hz) if (c.due(t)) n++;
      expect(n).toBeGreaterThanOrEqual(lo);
      expect(n).toBeLessThanOrEqual(hi);
    }
  });
  it('force() refreshes the very next frame', () => {
    const c = new ShadowCadence();
    c.due(1000);
    expect(c.due(1005)).toBe(false);
    c.force();
    expect(c.due(1010)).toBe(true);
    expect(c.due(1015)).toBe(false);
  });
  it('recovers when the clock goes backwards', () => {
    const c = new ShadowCadence();
    c.due(5000);
    expect(c.due(100)).toBe(true);
  });
});

describe('snapShadowTarget', () => {
  const off = { x: -14, y: 30, z: 12 };
  const texel = 60 / 1024;
  const lightAxes = () => {
    const l = Math.hypot(off.x, off.y, off.z);
    const f = { x: -off.x / l, y: -off.y / l, z: -off.z / l };
    const rl = Math.hypot(f.z, f.x);
    return { rx: -f.z / rl, rz: f.x / rl };
  };
  it('lands on whole texels in light space', () => {
    const { rx, rz } = lightAxes();
    for (const [x, z] of [[3.1, -7.7], [120.123, 55.5], [-40.9, 0.01]]) {
      const s = snapShadowTarget(x, z, off, texel);
      const r = s.x * rx + s.z * rz;
      expect(Math.abs(r / texel - Math.round(r / texel))).toBeLessThan(1e-6);
    }
  });
  it('moves the target by less than a texel (diagonal) and is stable between texel steps', () => {
    const a = snapShadowTarget(10, 10, off, texel);
    expect(Math.hypot(a.x - 10, a.z - 10, a.y)).toBeLessThan(texel * 1.5);
    // A nudge of a tenth of a texel along light-right from a ground point already on the grid does not move the target.
    const g = snapShadowTarget(a.x, a.z, off, texel);
    expect(Math.hypot(g.x - a.x, g.z - a.z)).toBeLessThan(texel * 1.5);
  });
  it('is stable for tiny moves inside one texel cell (no per-frame creep)', () => {
    const { rx, rz } = lightAxes();
    const base = snapShadowTarget(50.0, 20.0, off, texel);
    const moved = snapShadowTarget(50.0 + 1e-4, 20.0 + 1e-4, off, texel);
    // the light-right coordinate (what the texel grid is made of) is identical or one whole texel apart
    const dr = (moved.x - base.x) * rx + (moved.z - base.z) * rz;
    const k = dr / texel;
    expect(Math.abs(k - Math.round(k))).toBeLessThan(1e-6);
  });
  it('keeps the target on the light ray plane: only the light-space right/up shift', () => {
    const s = snapShadowTarget(33.3, -12.2, off, texel);
    const l = Math.hypot(off.x, off.y, off.z);
    // displacement is perpendicular to the light direction
    const d = { x: s.x - 33.3, y: s.y, z: s.z + 12.2 };
    expect(Math.abs(d.x * off.x + d.y * off.y + d.z * off.z) / l).toBeLessThan(1e-9);
  });
});
