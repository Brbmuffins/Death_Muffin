import { describe, expect, it } from 'vitest';
import { FALLBACK_STRIDE, FOOT_PHASES, FootstepTracker } from '../footsteps';

describe('footsteps in step with the walk loop', () => {
  it('fires twice per cycle, at the planted-foot phases, at any playback speed', () => {
    for (const speed of [0.5, 1, 2.7]) {
      const t = new FootstepTracker();
      let steps = 0;
      let ph = 0.3;
      for (let i = 0; i < 2000; i++) {
        ph = (ph + 0.004 * speed) % 1; // 2000 frames of a cycle advancing at `speed`
        if (t.step(ph, i * 0.01, 0)) steps++;
      }
      const cycles = (0.004 * speed * 2000);
      expect(Math.abs(steps - cycles * FOOT_PHASES.length)).toBeLessThanOrEqual(1);
    }
  });
  it('does not step on the first frame of a walk and starts fresh after a reset', () => {
    const t = new FootstepTracker();
    expect(t.step(0.9, 0, 0)).toBe(false);
    t.reset();
    expect(t.step(0.99, 0, 0)).toBe(false);
    expect(t.step(0.05, 0, 0)).toBe(true); // wrapped across the 0.04 plant
  });
  it('falls back to a distance stride without a phase', () => {
    const t = new FootstepTracker();
    let steps = 0;
    for (let i = 0; i <= 100; i++) if (t.step(null, i * 0.1, 0)) steps++;
    expect(steps).toBe(Math.floor(10 / FALLBACK_STRIDE));
  });
});
