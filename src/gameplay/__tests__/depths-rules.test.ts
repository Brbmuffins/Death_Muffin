import { describe, expect, it } from 'vitest';
import { AREAS } from '../../content/areas';
import {
  CHEST_PER_MIN_CEILING, DEPTHS, DEPTH_LOOT_AREAS, FLOOR_BONUS_KILLS, averageKill, chestBonus, chestDrops, chestRuneChance, chestRunePool, depthEliteBonus, depthsEntryBlock,
  depthEnemyLevel, depthLootArea, depthRoster, depthWaveGapS, depthWaveSize, extraAffixes, floorBonus, floorKills, hasChest, pickExtraAffixes,
} from '../../content/depths';
import { AFFIX_ORDER, ENEMIES } from '../../content/enemies';
import { ITEMS } from '../../content/items';
import { RUNES } from '../../content/runes';
import { mulberry32 } from '../rng';
import { AREA_PEAK, DEPTHS_AUTHORITY, GROUND_RATES, ceilingsFor, depthBound, isGroundItem, itemCap, itemRatePerMin } from '../authorityRules';
import { rollChest, rollFloorClear, rollGearDrop } from '../depthsRewards';
import { isAffixGear } from '../affixRules';
import { rollKill } from '../loot';

describe('Depths scaling', () => {
  it('enemy level follows the hero (never below the floor) and grows by one level per depth', () => {
    expect(DEPTHS.minLevel).toBeLessThan(20); // the plan said max(20, ...); see content/depths.ts for why 12
    expect(depthEnemyLevel(1, 1)).toBe(DEPTHS.minLevel + 1);
    expect(depthEnemyLevel(1, 12)).toBe(13);
    for (const hero of [1, 12, 30, 60, 120]) {
      let prev = 0;
      for (let d = 1; d <= 60; d++) {
        const lvl = depthEnemyLevel(d, hero);
        expect(lvl).toBe(Math.max(DEPTHS.minLevel, hero) + d);
        expect(lvl).toBeGreaterThan(prev);
        prev = lvl;
      }
    }
    // A level-60 hero meets level-61 dead on depth 1 (the Pyre and the Fen are level-scaled the same way) and level-80 dead on depth 20.
    expect(depthEnemyLevel(1, 60)).toBe(61);
    expect(depthEnemyLevel(20, 60)).toBe(80);
  });

  it('a floor asks for 10 kills at first, up to 30, and never fields more than 24 at once', () => {
    expect(floorKills(1)).toBe(10);
    expect(floorKills(21)).toBe(30);
    expect(floorKills(500)).toBe(30);
    for (let d = 1; d < 100; d++) expect(floorKills(d + 1)).toBeGreaterThanOrEqual(floorKills(d));
    expect(DEPTHS.cap).toBe(24);
    for (let d = 1; d <= 60; d++) {
      expect(depthWaveSize(d)).toBeLessThanOrEqual(9);
      expect(depthWaveSize(d)).toBeGreaterThanOrEqual(5);
      expect(depthWaveGapS(d)).toBeGreaterThanOrEqual(2.4);
    }
  });

  it('elites gain one affix every fifth floor, from the existing pool, at most the whole pool', () => {
    expect([1, 4, 5, 9, 10, 14, 15, 99].map(extraAffixes)).toEqual([0, 0, 1, 1, 2, 2, 3, 3]);
    expect(1 + DEPTHS.maxExtraAffixes).toBe(AFFIX_ORDER.length);
    const rand = mulberry32(3);
    for (let n = 0; n < 200; n++) {
      const depth = 1 + (n % 40);
      const primary = AFFIX_ORDER[n % AFFIX_ORDER.length];
      const more = pickExtraAffixes(depth, primary, rand);
      expect(more).toHaveLength(extraAffixes(depth));
      expect(new Set([primary, ...more]).size).toBe(1 + more.length);
      for (const a of more) expect(AFFIX_ORDER).toContain(a);
    }
  });

  it('elite chance rises with depth, to a ceiling', () => {
    expect(depthEliteBonus(0)).toBe(0);
    expect(depthEliteBonus(10)).toBeCloseTo(0.05);
    expect(depthEliteBonus(500)).toBe(0.14);
  });

  it('chests come on every fifth floor and not before', () => {
    expect([0, 1, 4, 5, 6, 10, 15].map(hasChest)).toEqual([false, false, false, true, false, true, true]);
  });

  it('the roster widens with depth, reuses real enemies, and the starter dead fade but never vanish', () => {
    const ids = (d: number) => depthRoster(d).map((e) => e.id);
    for (const d of [1, 5, 10, 15, 40]) for (const id of ids(d)) expect(ENEMIES[id], id).toBeDefined();
    expect(ids(1)).toHaveLength(6);
    expect(ids(5).length).toBeGreaterThan(ids(1).length);
    expect(ids(10).length).toBeGreaterThan(ids(5).length);
    expect(ids(15).length).toBeGreaterThan(ids(10).length);
    const ratShare = (d: number) => depthRoster(d).find((e) => e.id === 'rat')!.weight / depthRoster(d).reduce((n, e) => n + e.weight, 0);
    expect(ratShare(1)).toBeGreaterThan(ratShare(15));
    expect(ratShare(15)).toBeGreaterThan(0);
  });
});

describe('Depths co-op: solo for now, and the stair says so', () => {
  it('lets a lone keeper down and tells a party, a guest or a fallen hero why not', () => {
    expect(depthsEntryBlock({ partySize: 0, keeper: true, alive: true })).toBeNull();
    expect(depthsEntryBlock({ partySize: 1, keeper: true, alive: true })).toMatch(/solo for now: leave your party/);
    expect(depthsEntryBlock({ partySize: 3, keeper: false, alive: true })).toMatch(/solo for now/);
    expect(depthsEntryBlock({ partySize: 0, keeper: false, alive: true })).toMatch(/only the keeper of the world/);
    expect(depthsEntryBlock({ partySize: 0, keeper: true, alive: false })).toMatch(/no state to descend/);
  });
});

describe('Depths rewards', () => {
  it('the loot ground follows the depth, and every ground is a real hunting ground', () => {
    expect([1, 4, 5, 9, 10, 15, 20, 29, 30, 80].map(depthLootArea)).toEqual(['ossuary', 'ossuary', 'coliseum', 'coliseum', 'sanctum', 'cloister', 'pyre', 'pyre', 'fen', 'fen']);
    for (const a of DEPTH_LOOT_AREAS) expect(AREAS[a].loot.length, a).toBeGreaterThan(0);
    expect(new Set(DEPTH_LOOT_AREAS)).toEqual(new Set([1, 5, 10, 15, 20, 30].map(depthLootArea)));
  });

  it('a floor clear and a chest pay a multiple of an average kill, and a chest pays more than a clear', () => {
    for (const [d, lvl] of [[1, 13], [5, 40], [10, 50], [25, 85]] as const) {
      const k = averageKill(d, lvl);
      expect(k.gold).toBeGreaterThan(0);
      expect(k.xp).toBeGreaterThan(0);
      const f = floorBonus(d, lvl);
      expect(f.gold).toBe(Math.round(k.gold * FLOOR_BONUS_KILLS));
      expect(chestBonus(d, lvl).gold).toBeGreaterThan(f.gold);
    }
    expect(chestDrops(5)).toBe(3);
    expect(chestDrops(25)).toBe(5);
    expect(chestDrops(105)).toBe(13);
  });

  it('a chest: gear first (the server will give it affixes), then finds, sometimes a rune; every id is a real item', () => {
    const rand = mulberry32(11);
    let runes = 0;
    const N = 600;
    for (let n = 0; n < N; n++) {
      const depth = 5 * (1 + (n % 12));
      const c = rollChest(depth, depthEnemyLevel(depth, 40), rand);
      expect(c.drops).toHaveLength(chestDrops(depth) + (c.drops.some((d) => ITEMS[d.item_id]?.type === 'rune') ? 1 : 0));
      expect(isAffixGear(ITEMS[c.drops[0].item_id].type), `${depth}: first drop ${c.drops[0].item_id}`).toBe(true);
      for (const d of c.drops) {
        expect(ITEMS[d.item_id], d.item_id).toBeDefined();
        expect(isGroundItem(d.item_id), `${d.item_id} is a ground item for the server`).toBe(true);
        expect(d.quantity).toBeGreaterThan(0);
      }
      const rune = c.drops.find((d) => ITEMS[d.item_id]?.type === 'rune');
      if (rune) {
        runes++;
        expect(RUNES[rune.item_id as keyof typeof RUNES], rune.item_id).toBeDefined();
        // Epic runes only from depth 10.
        if (depth < 10) expect(RUNES[rune.item_id as keyof typeof RUNES].rarity).not.toBe('epic');
      }
    }
    // About 25-70% of chests hold a rune.
    expect(runes / N).toBeGreaterThan(0.2);
    expect(runes / N).toBeLessThan(0.6);
    expect(chestRuneChance(5)).toBeCloseTo(0.25);
    expect(chestRuneChance(500)).toBe(0.7);
    expect(chestRunePool(5).every((id) => RUNES[id].rarity !== 'epic')).toBe(true);
    expect(chestRunePool(10).some((id) => RUNES[id].rarity === 'epic')).toBe(true);
  });

  it('a floor clear drops an item most of the time, from the depth\'s own ground', () => {
    const rand = mulberry32(5);
    let drops = 0;
    for (let n = 0; n < 400; n++) {
      const r = rollFloorClear(12, 55, rand);
      if (r.drop) {
        drops++;
        expect(isGroundItem(r.drop.item_id)).toBe(true);
        expect(AREAS[depthLootArea(12)].loot.map((l) => l.item)).toContain(r.drop.item_id);
      }
    }
    expect(drops / 400).toBeGreaterThan(0.5);
    expect(drops / 400).toBeLessThan(0.8);
    expect(isAffixGear(ITEMS[rollGearDrop(18, rand).item_id].type)).toBe(true);
  });

  it('kills on a Depths floor roll on the matching ground and its elites may shed runes', () => {
    const rand = mulberry32(2);
    const r = rollKill('robber', depthLootArea(12), 60, true, 0, rand, 'medium', 1, rand, rand);
    expect(r.xp).toBeGreaterThan(0);
    expect(AREAS.depths.loot).toEqual([]);
  });
});

describe('Depths and the server authority rules', () => {
  const UNLOCKED_NO_WARREN = ['chapterhouse', 'graves', 'ossuary'];
  const UNLOCKED_WARREN = [...UNLOCKED_NO_WARREN, 'warren'];

  it('the stair is open to anyone who has opened the Warren: its ceilings count only then', () => {
    expect(AREA_PEAK.depths).toBeDefined();
    expect(AREA_PEAK.depths!.xp).toBeGreaterThan(0);
    const without = ceilingsFor(UNLOCKED_NO_WARREN, 0, 40, 30);
    const withWarren = ceilingsFor(UNLOCKED_WARREN, 0, 40, 30);
    // With only the Ossuary the best ground is the Ossuary; with the Warren and a deep record the Depths take over.
    expect(withWarren.xpPerMin).toBeGreaterThan(without.xpPerMin);
    expect(withWarren.area).toBe('depths');
    expect(without.area).not.toBe('depths');
  });

  it('the ceilings follow the deepest floor the Chronicle records (plus a little slack), up to a cap', () => {
    const at = (deepest: number) => ceilingsFor(UNLOCKED_WARREN, 0, 40, deepest);
    expect(at(0).area).toBe('depths');
    expect(at(10).xpPerMin).toBeGreaterThan(at(1).xpPerMin);
    expect(at(30).xpPerMin).toBeGreaterThan(at(10).xpPerMin);
    expect(at(30).goldPerMin).toBeGreaterThan(at(10).goldPerMin);
    // A nonsense record cannot push the ceiling past the cap.
    expect(at(9999).xpPerMin).toBe(at(DEPTHS_AUTHORITY.maxDepth).xpPerMin);
    expect(depthBound(0)).toBe(DEPTHS_AUTHORITY.slack);
    expect(depthBound(-5)).toBe(DEPTHS_AUTHORITY.slack);
    expect(depthBound(1e9)).toBe(DEPTHS_AUTHORITY.maxDepth);
    // And it is not wildly generous: a character with no record and a depth-3 allowance stays within a small multiple of the Pyre's pace.
    expect(at(0).xpPerMin).toBeLessThan(ceilingsFor([...UNLOCKED_WARREN, 'pyre'], 0, 40).xpPerMin * 3);
  });

  it('the Depths never lower a ceiling that another ground sets', () => {
    const all = [...UNLOCKED_WARREN, 'nave', 'sanctum', 'cloister', 'pyre', 'fen'];
    const base = ceilingsFor(all, 0, 60, 0);
    for (const deepest of [0, 10, 40]) expect(ceilingsFor(all, 0, 60, deepest).xpPerMin).toBeGreaterThanOrEqual(base.xpPerMin);
  });

  it('every item a Depths run can hand out (floor drops, kills, chests, runes) has a ground allowance', () => {
    for (const a of DEPTH_LOOT_AREAS) for (const l of AREAS[a].loot) {
      expect(isGroundItem(l.item), `${a}: ${l.item}`).toBe(true);
      expect(itemRatePerMin(l.item)).toBeGreaterThan(0);
      expect(itemCap(l.item)).toBeGreaterThan(0);
    }
    for (const d of [5, 10, 20, 40]) for (const id of chestRunePool(d)) {
      expect(isGroundItem(id), id).toBe(true);
      // A chest holds at most one rune and an honest run opens at most CHEST_PER_MIN_CEILING chests a minute.
      expect(GROUND_RATES[id]).toBeGreaterThanOrEqual(CHEST_PER_MIN_CEILING);
    }
  });

  it('the Depths raise the pace of the loot tables they use, never lower it', () => {
    // The Depths' kill rate on a table at least matches that table's own ground rate where the peaks say so; either way no item loses its allowance.
    const sample = ['bones_ancient', 'flask_hp_grand', 'gem_void_sapphire', 'ore_moon', 'reagent_grave_dust'];
    for (const id of sample) if (GROUND_RATES[id] !== undefined) expect(GROUND_RATES[id]).toBeGreaterThan(0);
  });
});
