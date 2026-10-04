import { describe, expect, it } from 'vitest';
import { AFK_AWAY_CAP_S, AWAY_MIN_S, AwayClock, catchUpSeconds } from '../awayClock';

describe('away clock', () => {
  it('measures the wall-clock gap and moves the mark so a second is never counted twice', () => {
    const c = new AwayClock(1_000);
    expect(c.lap(61_000)).toBe(60);
    expect(c.lap(61_000)).toBe(0);
    expect(c.lap(62_500)).toBe(1.5);
  });

  it('the hidden-tab interval and the resume share one mark (no double counting)', () => {
    const c = new AwayClock(0);
    const tick = c.lap(60_000); // throttled hidden-tab tick takes the first minute
    const resume = c.lap(75_000); // the return only owns what the tick did not
    expect(tick).toBe(60);
    expect(resume).toBe(15);
  });

  it('ignores a clock that went backwards or is not finite', () => {
    const c = new AwayClock(10_000);
    expect(c.lap(5_000)).toBe(0);
    expect(c.lap(NaN)).toBe(0);
  });

  it('catches nothing up for hitches, and caps long absences at the server AFK window', () => {
    expect(catchUpSeconds(0.2)).toBe(0);
    expect(catchUpSeconds(AWAY_MIN_S - 0.01)).toBe(0);
    expect(catchUpSeconds(AWAY_MIN_S)).toBe(AWAY_MIN_S);
    expect(catchUpSeconds(45)).toBe(45);
    expect(catchUpSeconds(3600)).toBe(AFK_AWAY_CAP_S);
    expect(catchUpSeconds(Infinity)).toBe(0);
  });
});
