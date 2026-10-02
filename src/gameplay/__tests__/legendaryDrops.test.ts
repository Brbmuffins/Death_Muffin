import { describe, expect, it } from 'vitest';
import { LEGENDARY_DROP, LEGENDARY_SETS, LEGENDARY_SET_IDS, legendaryItemId, legendarySetFor, pickLegendarySet, rollLegendary } from '../../content/legendarySets';
import { ARMOR_BY_ID } from '../../content/armorSets';
import { ITEMS } from '../../content/items';
import { itemCap, isGroundItem } from '../authorityRules';
import { rollBoss, rollKill } from '../loot';

const seeded = (seed: number) => () => {
  seed = (seed * 1664525 + 1013904223) % 4294967296;
  return seed / 4294967296;
};
const isLegendary = (id: string) => ITEMS[id]?.rarity === 'legendary';

describe('legendary drops', () => {
  it('every legendary id is a known, legendary-rarity armor item the server accepts from the ground', () => {
    for (const set of LEGENDARY_SET_IDS) for (const part of ['head', 'chest', 'hands', 'legs', 'feet'] as const) {
      const id = legendaryItemId(set, part);
      expect(ARMOR_BY_ID[id]?.collection, id).toBe(3);
      expect(ITEMS[id].rarity).toBe('legendary');
      expect(isGroundItem(id), id).toBe(true);
      expect(itemCap(id), id).toBeGreaterThanOrEqual(1);
    }
    expect(LEGENDARY_SET_IDS.map((id) => legendarySetFor(LEGENDARY_SETS[id].disciplineId))).toEqual(LEGENDARY_SET_IDS);
  });

  it('smart loot: about 70% of legendary drops are the discipline’s own set, the rest split evenly', () => {
    const rand = seeded(11);
    const n = 20000;
    const counts: Record<string, number> = {};
    for (let i = 0; i < n; i++) { const s = pickLegendarySet('mourner', rand); counts[s] = (counts[s] ?? 0) + 1; }
    expect(counts.requiem_wraiths / n).toBeGreaterThan(0.67);
    expect(counts.requiem_wraiths / n).toBeLessThan(0.73);
    for (const s of ['legion_unburied', 'colossus_mantle', 'plague_choir']) expect(counts[s] / n).toBeGreaterThan(0.08);
    // A discipline with no set of its own gets all four evenly.
    const even: Record<string, number> = {};
    for (let i = 0; i < n; i++) { const s = pickLegendarySet('knight', rand); even[s] = (even[s] ?? 0) + 1; }
    for (const s of LEGENDARY_SET_IDS) expect(even[s] / n).toBeGreaterThan(0.22);
  });

  it('bosses roll about 7% from the Ossuary on, never in the Hollow Graves, and only when a discipline is given', () => {
    const rand = seeded(5);
    let hits = 0;
    const n = 20000;
    for (let i = 0; i < n; i++) if (rollBoss(0, rand, 'medium', 'nave', 4, 'abbess', 'gravecaller').items.some((d) => isLegendary(d.item_id))) hits++;
    expect(hits / n).toBeGreaterThan(0.06);
    expect(hits / n).toBeLessThan(0.08);
    for (let i = 0; i < 3000; i++) expect(rollBoss(0, rand, 'medium', 'graves', 2, 'gravedigger', 'gravecaller').items.some((d) => isLegendary(d.item_id))).toBe(false);
    for (let i = 0; i < 3000; i++) expect(rollBoss(0, rand, 'medium', 'nave', 4).items.some((d) => isLegendary(d.item_id))).toBe(false);
  });

  it('elites drop one very rarely, only in level-scaled areas; ordinary kills never do', () => {
    const rand = seeded(9);
    const n = 100000;
    let scaled = 0;
    let flat = 0;
    let plain = 0;
    for (let i = 0; i < n; i++) {
      if (rollKill('robber', 'cloister', 20, true, 0, rand, 'medium', 1, rand, Math.random, 'rotweaver').items.some((d) => isLegendary(d.item_id))) scaled++;
      if (rollKill('robber', 'nave', 20, true, 0, rand, 'medium', 1, rand, Math.random, 'rotweaver').items.some((d) => isLegendary(d.item_id))) flat++;
      if (rollKill('robber', 'cloister', 20, false, 0, rand, 'medium', 1, rand, Math.random, 'rotweaver').items.some((d) => isLegendary(d.item_id))) plain++;
    }
    expect(scaled / n).toBeGreaterThan(0.002);
    expect(scaled / n).toBeLessThan(0.004);
    expect(flat + plain).toBe(0);
    expect(rollLegendary('rotweaver', LEGENDARY_DROP.eliteChance, () => 0.999)).toBeNull();
    expect(Object.keys(LEGENDARY_SETS)).toHaveLength(4);
  });
});
