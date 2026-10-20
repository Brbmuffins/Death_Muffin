import { describe, expect, it } from 'vitest';
import { AREAS, AREA_ORDER } from '../../content/areas';
import { NECRO_LIMITS, applySave, blankState } from '../necroRules';

const run = (...a: Parameters<typeof applySave>) => {
  const r = applySave(...a);
  if (!r.ok) throw new Error(r.error);
  return r.state;
};

/** A ground a new character has not opened, and a hall (kills are never counted in a hall). */
const sealed = AREA_ORDER.find((id) => !AREAS[id].safe && !blankState().unlockedAreas.includes(id))!;
const hall = AREA_ORDER.find((id) => AREAS[id].safe)!;
/** A kill count one save always accepts (a save takes at most NECRO_LIMITS.killsPerSave). */
const KILLS = Math.min(30, NECRO_LIMITS.killsPerSave);

describe('applySave: kills in a ground the character has not opened', () => {
  it('are ignored unless the kill ledger backed them', () => {
    const s = blankState();
    expect(run(s, { areaKills: { [sealed]: KILLS } }).areaKills[sealed]).toBeUndefined();
  });
  it('count (and persist in the tally) when the ledger backed them: being carried counts', () => {
    const s = blankState();
    const r = run(s, { areaKills: { [sealed]: KILLS, [hall]: 5 } }, { backed: { [sealed]: KILLS, [hall]: 5 } });
    expect(r.areaKills[sealed]).toBe(KILLS);
    expect(r.areaKills[hall]).toBeUndefined();
    expect(r.totalKills).toBe(KILLS);
    expect(r.unlockedAreas).not.toContain(sealed);
  });
  it('count only as far as the ledger backs them (audit mode does not clamp the request)', () => {
    const backed = Math.floor(KILLS / 2);
    const r = run(blankState(), { areaKills: { [sealed]: KILLS } }, { backed: { [sealed]: backed } });
    expect(r.areaKills[sealed]).toBe(backed);
    expect(r.totalKills).toBe(backed);
  });
});
