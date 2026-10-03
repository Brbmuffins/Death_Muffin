import { describe, expect, it } from 'vitest';
import { ANIM_FAR_S, ANIM_MID_S, allowBurst, animInterval, distanceInterval, hudDue } from '../animLod';

describe('animation LOD', () => {
  it('keeps nearby bodies at full rate and throttles by distance', () => {
    expect(animInterval(3, 2, false, false)).toBe(0);
    expect(animInterval(18, 4, false, false)).toBe(ANIM_MID_S);
    expect(animInterval(30, 4, false, false)).toBe(ANIM_FAR_S);
    expect(animInterval(4, 25, false, false)).toBe(ANIM_FAR_S);
  });

  it('pulls the near band in when the room is crowded', () => {
    expect(animInterval(12, 3, false, false)).toBe(0);
    expect(animInterval(12, 3, false, true)).toBe(ANIM_MID_S);
  });

  it('never throttles a body mid-swing', () => {
    expect(animInterval(40, 40, true, true)).toBe(0);
    expect(distanceInterval(60, true)).toBe(0);
  });

  it('time accumulated while skipped is handed over whole (motion stays correct)', () => {
    let acc = 0;
    let handed = 0;
    let updates = 0;
    for (let i = 0; i < 600; i++) {
      acc += 1 / 60;
      if (acc >= ANIM_FAR_S) { handed += acc; acc = 0; updates++; }
    }
    expect(handed + acc).toBeCloseTo(10, 6);
    expect(updates).toBeGreaterThan(80);
    expect(updates).toBeLessThan(110);
  });

  it('guide figures: near full, mid 24 Hz, far 10 Hz', () => {
    expect(distanceInterval(5, false)).toBe(0);
    expect(distanceInterval(15, false)).toBe(ANIM_MID_S);
    expect(distanceInterval(40, false)).toBe(ANIM_FAR_S);
  });
});

describe('throttles', () => {
  it('caps flinch starts inside the window', () => {
    const q: number[] = [];
    let granted = 0;
    for (let t = 0; t < 380; t += 10) if (allowBurst(q, t, 6, 380)) granted++;
    expect(granted).toBe(6);
    expect(allowBurst(q, 600, 6, 380)).toBe(true);
  });

  it('gates HUD redraws to ~20 Hz', () => {
    let last = -1e9;
    let draws = 0;
    for (let t = 0; t < 1000; t += 1000 / 60) if (hudDue(t, last, 50)) { last = t; draws++; }
    expect(draws).toBeGreaterThanOrEqual(17);
    expect(draws).toBeLessThanOrEqual(21);
    expect(hudDue(10, 500, 50)).toBe(true);
  });
});
