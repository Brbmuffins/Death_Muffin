import { describe, expect, it } from 'vitest';
import { NEW_BLOOD_DAMAGE_MULT, NEW_BLOOD_XP_CATCHUP, newBloodDamageMult, newBloodXpMult } from '../newBloodTuning';

describe('New Blood catch-up (owner, 3 Oct 2026)', () => {
  it('New Blood hits at the New Blood multiplier, necromancers unchanged', () => {
    expect(newBloodDamageMult('warden')).toBe(NEW_BLOOD_DAMAGE_MULT);
    expect(newBloodDamageMult('necromancer')).toBe(1);
  });
  it('early experience: the start multiplier at level 1, fading in a straight line to x1 at the fade level, never for necromancers', () => {
    const { startMult, fadeLevel } = NEW_BLOOD_XP_CATCHUP;
    expect(newBloodXpMult('monk', 1)).toBeCloseTo(startMult);
    expect(newBloodXpMult('monk', fadeLevel)).toBe(1);
    expect(newBloodXpMult('monk', fadeLevel + 45)).toBe(1);
    expect(newBloodXpMult('necromancer', 1)).toBe(1);
    // the steps between neighbouring levels are all the same size, and never go up
    const step = (newBloodXpMult('knight', 1) - 1) / (fadeLevel - 1);
    for (let l = 1; l < fadeLevel; l++) {
      expect(newBloodXpMult('knight', l) - newBloodXpMult('knight', l + 1)).toBeCloseTo(step, 9);
      expect(newBloodXpMult('knight', l + 1)).toBeLessThanOrEqual(newBloodXpMult('knight', l));
      expect(newBloodXpMult('knight', l)).toBeGreaterThanOrEqual(1);
    }
  });
});
