import { describe, expect, it } from 'vitest';
import { applySave, blankState } from '../necroRules';

const run = (...a: Parameters<typeof applySave>) => {
  const r = applySave(...a);
  if (!r.ok) throw new Error(r.error);
  return r.state;
};

describe('applySave: kills in a ground the character has not opened', () => {
  it('are ignored unless the kill ledger backed them', () => {
    const s = blankState();
    expect(run(s, { areaKills: { nave: 30 } }).areaKills.nave).toBeUndefined();
  });
  it('count (and persist in the tally) when the ledger backed them: being carried counts', () => {
    const s = blankState();
    const r = run(s, { areaKills: { nave: 30, chapterhouse: 5 } }, { backed: { nave: 30, chapterhouse: 5 } });
    expect(r.areaKills.nave).toBe(30);
    expect(r.areaKills.chapterhouse).toBeUndefined();
    expect(r.totalKills).toBe(30);
    expect(r.unlockedAreas).not.toContain('nave');
  });
  it('count only as far as the ledger backs them (audit mode does not clamp the request)', () => {
    const r = run(blankState(), { areaKills: { nave: 30 } }, { backed: { nave: 12 } });
    expect(r.areaKills.nave).toBe(12);
    expect(r.totalKills).toBe(12);
  });
});
