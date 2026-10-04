import { describe, expect, it } from 'vitest';
import { reportLines, sameLoadout, type LoadoutBody } from '../LoadoutPresets';

const KEYS = ['bone_needle', 'marrow_spear', 'exhume', 'miasma', 'black_litany'];
const body = (over: Partial<LoadoutBody> = {}): LoadoutBody => ({ rites: { primary: 'bone_needle', keys: KEYS }, runes: {}, weapon: null, offhand: null, ...over });
const name = (id: string) => id.replace(/_/g, ' ');

describe('reportLines', () => {
  it('says what was left out and why, in words', () => {
    const lines = reportLines({
      unchanged: false,
      applied: [],
      skipped: [
        { part: 'weapon', rite: null, itemId: 'wand_bone', reason: 'missing' },
        { part: 'offhand', rite: null, itemId: 'skull_focus_bone', reason: 'no_room' },
        { part: 'rune', rite: 'exhume', itemId: 'rune_bone_colossus', reason: 'missing' },
        { part: 'rune', rite: 'bone_needle', itemId: null, reason: 'no_room' },
      ],
    }, name);
    expect(lines).toHaveLength(4);
    expect(lines[0]).toMatch(/wand bone is not in your bag.*Vault/);
    expect(lines[1]).toMatch(/not worn.*free bag slots/);
    expect(lines[2]).toMatch(/Bone Colossus.*Exhume.*not in your bag/);
    expect(lines[3]).toMatch(/Bone Needle still holds its rune/);
  });
  it('is silent when nothing was skipped', () => expect(reportLines({ unchanged: false, applied: [], skipped: [] }, name)).toEqual([]));
});

describe('sameLoadout', () => {
  it('matches on rites, runes and the hands the preset names', () => {
    const w = { itemId: 'wand_bone', instanceId: null };
    expect(sameLoadout(body({ weapon: w }), body({ weapon: w, offhand: { itemId: 'skull_focus_bone', instanceId: null } }))).toBe(true);
    expect(sameLoadout(body({ weapon: w }), body())).toBe(false);
    expect(sameLoadout(body({ weapon: w }), body({ weapon: { itemId: 'wand_bone', instanceId: 5 } }))).toBe(false);
    expect(sameLoadout(body({ runes: { exhume: 'rune_bone_colossus' } }), body())).toBe(false);
    expect(sameLoadout(body(), body({ rites: { primary: 'bone_fan', keys: KEYS } }))).toBe(false);
  });
});
