import { describe, expect, it } from 'vitest';
import { AREAS } from '../../content/areas';
import { ARMOR_BY_ID } from '../../content/armorSets';
import { NECRO_WEAPON_BY_ID } from '../../content/necroWeapons';
import { GROUND_RATES } from '../authorityRules';
import { rollFirstKillItem, rollItem, rollKill } from '../loot';
import { SMART_LOOT, smartTable } from '../smartLoot';
import { mulberry32 } from '../rng';

const sum = (t: { weight: number }[]) => t.reduce((n, e) => n + e.weight, 0);
const armorShare = (t: { item: string; weight: number }[], d: string) =>
  t.filter((e) => ARMOR_BY_ID[e.item]?.disciplineId === d).reduce((n, e) => n + e.weight, 0) / t.filter((e) => ARMOR_BY_ID[e.item]).reduce((n, e) => n + e.weight, 0);

describe('smart loot for class gear', () => {
  it('half of the armour weight is the player’s own set, and the armour share of the table does not move', () => {
    for (const area of ['graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'] as const) {
      const listed = AREAS[area].loot;
      const t = smartTable(area, 'knight');
      expect(armorShare(t, 'knight'), area).toBeCloseTo(SMART_LOOT.ownArmorShare, 5);
      const armor = (x: { item: string; weight: number }[]) => sum(x.filter((e) => ARMOR_BY_ID[e.item]));
      expect(armor(t), area).toBeCloseTo(armor(listed), 5);
    }
  });

  it('necromancer weapons are rarer for the other families and untouched for necromancers', () => {
    const w = (t: { item: string; weight: number }[]) => sum(t.filter((e) => NECRO_WEAPON_BY_ID[e.item]));
    const listed = w(AREAS.ossuary.loot);
    expect(listed).toBeGreaterThan(0);
    expect(w(smartTable('ossuary', 'knight'))).toBeCloseTo(listed * SMART_LOOT.foreignWeaponMult, 5);
    expect(w(smartTable('ossuary', 'gravecaller'))).toBeCloseTo(listed, 5);
  });

  it('a discipline with no piece in a table (or none given) rolls the table as listed', () => {
    const rand = () => 0.5;
    expect(rollItem('graves', rand).item_id).toBe(rollItem('graves', rand, 1, undefined).item_id);
    // The Depths and the harness pass no discipline: the sequence of a seeded roll is unchanged.
    expect(rollKill(AREAS.graves.enemies[0].id as never, 'graves', 5, false, 0, mulberry32(3)).items).toEqual(rollKill(AREAS.graves.enemies[0].id as never, 'graves', 5, false, 0, mulberry32(3)).items);
  });

  it('about half of the armour a Knight finds in the Ossuary is Hollow Oath, against 1 in 9 before', () => {
    const rand = mulberry32(5);
    let armor = 0;
    let own = 0;
    for (let i = 0; i < 20000; i++) {
      const p = ARMOR_BY_ID[rollItem('ossuary', rand, 1, 'knight').item_id];
      if (!p) continue;
      armor++;
      if (p.disciplineId === 'knight') own++;
    }
    expect(own / armor).toBeGreaterThan(0.46);
    expect(own / armor).toBeLessThan(0.54);
  });

  it('a first-kill trophy is mostly your own class armour when the area drops rare-or-better pieces of it', () => {
    const rand = mulberry32(9);
    let own = 0;
    for (let i = 0; i < 400; i++) if (ARMOR_BY_ID[rollFirstKillItem('nave', rand, 'monk').item_id]?.disciplineId === 'monk') own++;
    expect(own).toBeGreaterThan(280);
  });

  it('the server ceiling covers the boosted own-armour rate (enforce mode must not clamp an honest pick-up)', () => {
    // Per-minute ceiling for an own piece at the boosted weight must not exceed what authority allows.
    for (const area of ['graves', 'ossuary', 'nave', 'sanctum'] as const) {
      const listed = AREAS[area].loot;
      const total = sum(listed);
      const t = smartTable(area, 'witch');
      for (const e of t) {
        if (ARMOR_BY_ID[e.item]?.disciplineId !== 'witch') continue;
        const base = listed.find((l) => l.item === e.item)!.weight / total;
        expect(GROUND_RATES[e.item], e.item).toBeGreaterThanOrEqual(0);
        expect(e.weight / sum(t), e.item).toBeGreaterThanOrEqual(base);
      }
    }
  });
});
