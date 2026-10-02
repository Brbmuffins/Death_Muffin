import { describe, expect, it } from 'vitest';
import { shouldProcessFrame, shouldRender, isFpsCap } from '../framePacing';

describe('frame pacing', () => {
  it('always processes the first frame', () => {
    expect(shouldProcessFrame(1000, 0, 30)).toBe(true);
  });
  it('halves a 120 Hz screen at 60 fps', () => {
    let last = 1;
    let n = 0;
    for (let t = 1; t < 1001; t += 1000 / 120) {
      if (shouldProcessFrame(t, last, 60)) { n++; last = t; }
    }
    expect(n).toBeGreaterThan(55);
    expect(n).toBeLessThan(65);
  });
  it('keeps a 60 Hz screen at 60 and halves it at 30', () => {
    for (const [fps, lo, hi] of [[60, 58, 61], [30, 28, 32]] as const) {
      let last = 1;
      let n = 0;
      for (let t = 1; t < 1001; t += 1000 / 60) {
        if (shouldProcessFrame(t, last, fps)) { n++; last = t; }
      }
      expect(n).toBeGreaterThanOrEqual(lo);
      expect(n).toBeLessThanOrEqual(hi);
    }
  });
  it('throttles rendering only while covered', () => {
    expect(shouldRender(1000, 990, false)).toBe(true);
    expect(shouldRender(1000, 990, true)).toBe(false);
    expect(shouldRender(1200, 990, true)).toBe(true);
  });
  it('validates caps', () => {
    expect(isFpsCap(30)).toBe(true);
    expect(isFpsCap(45)).toBe(false);
    expect(isFpsCap('30')).toBe(false);
  });
});
