import { describe, expect, it } from 'vitest';
import { ResolutionGovernor, budgetFps, shouldProcessFrame, isFpsCap } from '../framePacing';

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
  it('Max (0) never skips a frame, even on a 144 Hz screen', () => {
    let last = 1;
    let n = 0;
    for (let t = 1; t < 1001; t += 1000 / 144) {
      if (shouldProcessFrame(t, last, 0)) { n++; last = t; }
    }
    expect(n).toBeGreaterThan(140);
    expect(budgetFps(0)).toBe(60);
    expect(budgetFps(30)).toBe(30);
  });
  it('validates caps', () => {
    expect(isFpsCap(0)).toBe(true);
    expect(isFpsCap(30)).toBe(true);
    expect(isFpsCap(45)).toBe(false);
    expect(isFpsCap('30')).toBe(false);
  });
});

describe('resolution governor', () => {
  /** Feed `seconds` of frames at a steady smoothed frame time; returns how many times the scale changed. */
  const run = (g: ResolutionGovernor, seconds: number, ms: number, fps = 60) => {
    let changes = 0;
    for (let t = 0; t < seconds; t += ms / 1000) if (g.frame(ms / 1000, ms, fps)) changes++;
    return changes;
  };

  it('keeps full resolution when frames hold the cap', () => {
    const g = new ResolutionGovernor();
    expect(run(g, 30, 16.7)).toBe(0);
    expect(g.scale).toBe(1);
  });

  it('steps down under sustained slow frames, never below the floor', () => {
    const g = new ResolutionGovernor();
    run(g, 6, 30);
    expect(g.scale).toBe(0.9);
    run(g, 600, 40);
    expect(g.scale).toBeGreaterThanOrEqual(ResolutionGovernor.MIN);
    expect(g.scale).toBeLessThan(0.65);
  });

  it('does not act on a 3 s dip, and changes at most once per 20 s', () => {
    const g = new ResolutionGovernor();
    expect(run(g, 3, 40)).toBe(0);
    const g2 = new ResolutionGovernor();
    // 60 s of steady misses: first change after ~3.5 s, then one per 20 s at most.
    expect(run(g2, 60, 40)).toBeLessThanOrEqual(4);
    expect(run(new ResolutionGovernor(), 21, 40)).toBeLessThanOrEqual(2);
  });

  it('stands down while held (area entry / scene load) and restarts its trend afterwards', () => {
    const g = new ResolutionGovernor();
    g.hold();
    expect(run(g, 9, 40)).toBe(0);
    expect(g.scale).toBe(1);
    run(g, 6, 40);
    expect(g.scale).toBe(0.9);
  });

  it('ignores a short hitch', () => {
    const g = new ResolutionGovernor();
    run(g, 3, 16.7);
    run(g, 1, 40);
    run(g, 3, 16.7);
    expect(g.scale).toBe(1);
  });

  it('judges against the 30 fps budget when capped', () => {
    const g = new ResolutionGovernor();
    expect(run(g, 20, 33.3, 30)).toBe(0);
  });

  it('climbs back with headroom, and a raise that fails at once becomes the ceiling', () => {
    const g = new ResolutionGovernor();
    run(g, 6, 30);
    const low = g.scale;
    run(g, 40, 14);
    expect(g.scale).toBeGreaterThan(low);
    const raised = g.scale;
    run(g, 25, 30);
    expect(g.scale).toBeLessThan(raised);
    run(g, 200, 14);
    expect(g.scale).toBeLessThan(raised);
  });

  it('reset returns to full resolution', () => {
    const g = new ResolutionGovernor();
    run(g, 10, 40);
    g.reset();
    expect(g.scale).toBe(1);
  });
});
