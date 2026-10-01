import { describe, expect, it } from 'vitest';
import { strikeTiming } from '../../graphics/Creature';
import CLIP_TIMINGS from '../../content/clipTimings.json';

describe('strikeTiming: a swing\'s impact frame lands when the sim applies the hit', () => {
  it('a 6.6 s attack (impact at 2.1 s) on a 0.42 s wind-up skips the slow lead-in and hits on time', () => {
    const t = strikeTiming(6.6, 2.1, 0.42);
    expect(t.speed).toBe(2.2);
    expect(t.impactAfter).toBeCloseTo(0.42, 5);
    expect(t.endAt).toBeCloseTo(2.1 + 0.3 * 2.2, 5); // hands back to walk ~0.3 s after the hit, not 4 s later
  });

  it('a short variant (impact at 0.3 s) on a 1 s wind-up slows down instead of hitting early', () => {
    const t = strikeTiming(2.53, 0.3, 1.0);
    expect(t.speed).toBe(0.7);
    expect(t.startAt).toBe(0);
    // Slowest allowed speed still reaches the impact sooner than the wind-up; it is never later than the hit.
    expect(t.impactAfter).toBeLessThanOrEqual(1.0);
  });

  it('a thrall (hit applies at once) opens the clip just before its impact', () => {
    const t = strikeTiming(2.23, 0.5, 0.12);
    expect(t.impactAfter).toBeCloseTo(0.12, 5);
    expect(t.startAt).toBeGreaterThan(0);
  });

  it('every measured model lands its main attack within the sim wind-up range (0.38–1.3 s) at a sane speed', () => {
    for (const [slug, clips] of Object.entries(CLIP_TIMINGS as Record<string, Record<string, number[]>>)) {
      for (const [name, [dur, peak]] of Object.entries(clips)) {
        expect(peak, `${slug}.${name}`).toBeLessThanOrEqual(dur);
        for (const w of [0.38, 0.7, 1.3]) {
          const t = strikeTiming(dur, peak, w);
          expect(t.impactAfter, `${slug}.${name} @${w}`).toBeLessThanOrEqual(w + 1e-6);
          expect(t.endAt).toBeGreaterThan(t.startAt);
        }
      }
    }
  });

  it('unmeasured rigs assume the impact at 35% of the clip', () => {
    expect(strikeTiming(2, undefined, 0.7).impactAfter).toBeCloseTo(0.7, 5);
  });
});
