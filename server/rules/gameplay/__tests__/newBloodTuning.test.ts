import { describe, expect, it } from 'vitest';
import { NEW_BLOOD_DAMAGE_MULT, newBloodDamageMult, newBloodXpMult } from '../newBloodTuning';

describe('New Blood catch-up (owner, 3 Oct 2026)', () => {
  it('hits 1.5x harder, necromancers unchanged', () => {
    expect(NEW_BLOOD_DAMAGE_MULT).toBe(1.5);
    expect(newBloodDamageMult('warden')).toBe(1.5);
    expect(newBloodDamageMult('necromancer')).toBe(1);
  });
  it('early experience: x2 at level 1, fading to x1 at level 15, never for necromancers', () => {
    expect(newBloodXpMult('monk', 1)).toBeCloseTo(2);
    expect(newBloodXpMult('monk', 8)).toBeCloseTo(1.5);
    expect(newBloodXpMult('monk', 15)).toBe(1);
    expect(newBloodXpMult('monk', 60)).toBe(1);
    expect(newBloodXpMult('necromancer', 1)).toBe(1);
    for (let l = 1; l < 15; l++) expect(newBloodXpMult('knight', l + 1)).toBeLessThan(newBloodXpMult('knight', l));
  });
});
