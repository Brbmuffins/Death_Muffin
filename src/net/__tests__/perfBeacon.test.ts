import { describe, expect, it } from 'vitest';
import { FrameStats } from '../perfBeacon';

describe('FrameStats', () => {
  it('computes p50 / p95 / max and the worst gap time', () => {
    const f = new FrameStats();
    for (let i = 0; i < 100; i++) f.record(i === 40 ? 500 : 10 + (i % 5), i);
    const s = f.summary();
    expect(s.n).toBe(100);
    expect(s.p50).toBeGreaterThanOrEqual(10);
    expect(s.p50).toBeLessThanOrEqual(14);
    expect(s.p95).toBeLessThanOrEqual(14);
    expect(s.max).toBe(500);
    expect(f.maxAt).toBe(40);
  });

  it('is a fixed ring: overflow keeps the newest samples and never grows', () => {
    const f = new FrameStats();
    for (let i = 0; i < 10000; i++) f.record(i < 5000 ? 100 : 10, i);
    const s = f.summary();
    expect(s.n).toBe(10000);
    expect(s.p50).toBe(10); // the 100 ms samples have been overwritten
    expect(s.max).toBe(100); // max is tracked for the whole window
  });

  it('reset starts a clean window', () => {
    const f = new FrameStats();
    f.record(300, 1);
    f.reset();
    expect(f.summary()).toEqual({ n: 0, p50: 0, p95: 0, max: 0 });
    f.record(8, 2);
    expect(f.summary().max).toBe(8);
  });
});
