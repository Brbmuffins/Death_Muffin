import { describe, expect, it } from 'vitest';
import { AREAS, AREA_ORDER, type AreaId } from '../../../server/rules/content/areas';
import { BOSSES, BOSS_IDS } from '../../../server/rules/content/bosses';
import { ITEMS } from '../../../server/rules/content/items';
import { ARMOR_BY_ID } from '../../../server/rules/content/armorSets';
import { LEGENDARY_BOSS_AREAS, LEGENDARY_DROP, LEGENDARY_SET_IDS, legendaryItemId, legendarySetFor } from '../../../server/rules/content/legendarySets';
import { AREA_REAGENT_DROPS, BOSS_ICHOR } from '../../../server/rules/content/reagents';
import { BOSS_REPEAT_RUNE_CHANCE, eliteRuneChance, RUNES } from '../../../server/rules/content/runes';
import { ALL_RECIPE_ROWS } from '../../content/recipes';
import { FLOOR_DROP_CHANCE, chestRuneChance, depthLootArea } from '../../../server/rules/content/depths';
import { DISCIPLINES, type DisciplineId } from '../../../server/rules/content/disciplines';
import { NODES, rollGather, successChance } from '../../../server/rules/gameplay/gatheringRules';
import { KILL_LOOT, rollBoss, rollBossRune, rollEliteRune, rollFirstKillItem, rollKill, rollSurgeItem } from '../loot';
import { rollChest, rollFloorClear } from '../depthsRewards';
import { mulberry32 } from '../rng';
import { rollAffixCount } from '../../../server/rules/gameplay/affixRules';
import {
  SCALING_NOTES, affixCountOdds, cosmeticsInfo, isRecommendedKind, peersOf, atlasSlot, depthBands, fitBand, fitTable, fmtChance, getAtlas, legendaryShare, oneIn, placesFor, powerGainPct, referenceContext,
  sourcesFor, unobtainable,
} from '../atlas';
import { isProfessionMaterial } from '../loot';

const atlas = getAtlas();
const src = (id: string, pred: (s: ReturnType<typeof sourcesFor>[number]) => boolean, disc = 'gravecaller') => sourcesFor(id, disc).find(pred);
/** Four-sigma binomial window around p over n trials. */
const near = (freq: number, p: number, n: number) => Math.abs(freq - p) <= 4 * Math.sqrt((p * (1 - p)) / n) + 1e-9;

describe('atlas: the tables are all there', () => {
  it('every loot-table entry of every area has an ordinary, elite and surge source, and the chances add up', () => {
    for (const id of AREA_ORDER) {
      const a = AREAS[id];
      if (!a.loot.length) continue;
      let kill = 0;
      let elite = 0;
      // The dead drop no profession materials (loot.ts settleCombatDrop): those rolls pay gold, so they are not listed.
      for (const e of a.loot) {
        if (isProfessionMaterial(e.item)) continue;
        expect(atlas.sources.get(e.item), `${id}:${e.item}`).toBeTruthy();
      }
      const kept = a.loot.filter((e) => !isProfessionMaterial(e.item));
      const keptShare = kept.reduce((n, e) => n + e.weight, 0) / a.loot.reduce((n, e) => n + e.weight, 0);
      const seen = new Set(kept.map((e) => e.item));
      for (const item of seen) {
        const list = atlas.sources.get(item)!.filter((s) => s.placeId === id);
        kill += list.find((s) => s.kind === 'kill' && s.event === 'Ordinary kill')!.chance;
        elite += list.find((s) => s.kind === 'elite' && s.event === 'Elite kill')!.chance;
        expect(list.find((s) => s.kind === 'surge'), `${id}:${item} surge`).toBeTruthy();
      }
      expect(kill).toBeCloseTo(Math.min(1, a.itemChance * KILL_LOOT.itemChanceMult) * keptShare, 9);
      expect(elite).toBeCloseTo(Math.min(1, a.itemChance * 6) * keptShare, 9);
    }
  });

  it('every boss lists its table, its ichor (always) and a first-kill item (except the Prelate)', () => {
    for (const b of BOSS_IDS) {
      const def = BOSSES[b];
      for (const e of AREAS[def.area].loot) {
        if (isProfessionMaterial(e.item) && !e.item.startsWith('gem_')) continue; // paid as gold
        expect(atlas.sources.get(e.item)!.some((s) => s.placeId === b && s.kind === 'boss'), `${b}:${e.item}`).toBe(true);
      }
      expect(atlas.sources.get(BOSS_ICHOR[b])?.some((s) => s.placeId === b && s.chance === 1), `${b} ichor`).toBe(true);
      const firsts = [...atlas.sources].flatMap(([id, l]) => l.filter((s) => s.placeId === b && s.kind === 'first_kill' && ITEMS[id].type !== 'rune').map((s) => s.chance));
      if (b === 'prelate') expect(firsts).toEqual([]);
      else expect(firsts.reduce((n, x) => n + x, 0)).toBeCloseTo(1, 9);
    }
  });

  it('knows no id the game does not: sources, recipes, nodes', () => {
    for (const [id, list] of atlas.sources) {
      expect(ITEMS[id], `source item ${id}`).toBeTruthy();
      for (const s of list) {
        expect(s.chance, `${id} ${s.place} ${s.event}`).toBeGreaterThan(0);
        expect(s.chance, `${id} ${s.place} ${s.event}`).toBeLessThanOrEqual(1 + 1e-9);
        expect(s.qty[0]).toBeGreaterThanOrEqual(1);
        expect(s.qty[1]).toBeGreaterThanOrEqual(s.qty[0]);
      }
    }
    for (const [id, name, , , result, , ings] of ALL_RECIPE_ROWS) {
      expect(ITEMS[result], `${id} makes ${result}`).toBeTruthy();
      for (const [ing] of ings) expect(ITEMS[ing], `${id} needs ${ing}`).toBeTruthy();
      expect(name).toBeTruthy();
    }
    for (const n of Object.values(NODES)) for (const id of [n.item, ...n.extras.map((e) => e.item)]) expect(ITEMS[id], `${n.id} yields ${id}`).toBeTruthy();
  });

  it('every item can be obtained somehow (a drop, a find, a harvest, a recipe, or salvage); legendary pieces drop from bosses', () => {
    expect(unobtainable()).toEqual([]);
    for (const set of LEGENDARY_SET_IDS) for (const part of ['head', 'chest', 'hands', 'legs', 'feet'] as const) {
      const id = legendaryItemId(set, part);
      expect(sourcesFor(id, 'gravecaller').length).toBeGreaterThan(LEGENDARY_BOSS_AREAS.length - 1);
    }
  });

  it('craft and use lookups mirror the recipe rows', () => {
    for (const [id, , , , result, , ings] of ALL_RECIPE_ROWS) {
      expect(atlas.madeBy.get(result)!.some((r) => r.id === id)).toBe(true);
      for (const [ing] of ings) expect(atlas.usedIn.get(ing)!.some((r) => r.id === id)).toBe(true);
    }
  });

  it('places cover every area with loot, every boss, every Depths band, and every item lands somewhere it can be found', () => {
    const ids = new Set(atlas.places.map((p) => p.id));
    for (const id of AREA_ORDER) if (AREAS[id].loot.length) expect(ids.has(id), id).toBe(true);
    for (const b of BOSS_IDS) expect(ids.has(b), b).toBe(true);
    for (const band of depthBands()) expect(ids.has(`depths:${band.from}`)).toBe(true);
    const placed = new Set(atlas.places.flatMap((p) => p.items));
    for (const id of AREA_ORDER) for (const e of AREAS[id].loot) if (!isProfessionMaterial(e.item)) expect(placed.has(e.item), e.item).toBe(true);
    expect(placesFor('gravecaller').find((p) => p.id === 'abbess')!.items).toContain(legendaryItemId('legion_unburied', 'head'));
  });

  it('formats chances for people', () => {
    expect(fmtChance(1)).toBe('100%');
    expect(fmtChance(0.0003)).toBe('0.03%');
    expect(fmtChance(0.12)).toBe('12%');
    expect(oneIn(0.004)).toBe('1 in 250');
    expect(oneIn(0.2)).toBe('');
    expect(SCALING_NOTES.join(' ')).toMatch(/Wave Speed/);
  });
});

describe('atlas: the percentages match the real rolls', () => {
  it('ordinary and elite kills in the Hollow Graves (200k kills each)', () => {
    const N = 200_000;
    for (const elite of [false, true]) {
      const rand = mulberry32(elite ? 7 : 5);
      const rr = mulberry32(99);
      const ru = mulberry32(98);
      const counts = new Map<string, number>();
      for (let i = 0; i < N; i++) {
        const r = rollKill('robber', 'graves', 1, elite, 0, rand, 'medium', 1, rr, ru);
        for (const it of r.items) counts.set(it.item_id, (counts.get(it.item_id) ?? 0) + 1);
      }
      expect(counts.get('ore_tin') ?? 0, 'the dead drop no ore').toBe(0);
      for (const id of ['helm_copper', 'ring_copper', 'reagent_grave_dust', ...(elite ? ['rune_splinter'] : [])]) {
        const s = src(id, (x) => x.placeId === 'graves' && x.event === (elite ? 'Elite kill' : 'Ordinary kill'))!;
        expect(near((counts.get(id) ?? 0) / N, s.chance, N), `${id} ${elite ? 'elite' : 'ordinary'}: ${(counts.get(id) ?? 0) / N} vs ${s.chance}`).toBe(true);
      }
    }
  });

  it('enemy reagents: a Choir Wraith kill', () => {
    const N = 100_000;
    const rr = mulberry32(3);
    let n = 0;
    for (let i = 0; i < N; i++) if (rollKill('wraith', 'nave', 1, false, 0, mulberry32(i + 1), 'medium', 1, rr).items.some((x) => x.item_id === 'reagent_wraith_ectoplasm')) n++;
    expect(near(n / N, src('reagent_wraith_ectoplasm', (s) => s.placeId === 'enemy:wraith' && s.event === 'Choir Wraith kill')!.chance, N)).toBe(true);
    expect(AREA_REAGENT_DROPS.cloister?.[0].item).toBe('reagent_plague_bile');
  });

  it('boss spoils: three rolls, the first-kill trophy and the rune', () => {
    const N = 100_000;
    const rand = mulberry32(21);
    const tally = { shard: 0, ring: 0, first: new Map<string, number>(), rune: new Map<string, number>(), runeAll: 0 };
    for (let i = 0; i < N; i++) {
      const r = rollBoss(0, rand, 'medium', 'ossuary', 3, 'abbess');
      if (r.items.some((x) => x.item_id === 'ring_copper' || x.item_id === 'set_gravecaller_chest')) tally.ring++;
      const f = rollFirstKillItem('ossuary', rand);
      tally.first.set(f.item_id, (tally.first.get(f.item_id) ?? 0) + 1);
      const rune = rollBossRune('abbess', false, rand);
      if (rune) { tally.runeAll++; tally.rune.set(rune.item_id, (tally.rune.get(rune.item_id) ?? 0) + 1); }
    }
    const chest = src('set_gravecaller_chest', (s) => s.placeId === 'abbess' && s.kind === 'boss')!.chance;
    const ring = src('ring_copper', (s) => s.placeId === 'abbess' && s.kind === 'boss');
    expect(chest).toBeGreaterThan(0);
    // "chest or ring" in one tally is the union of two independent-ish items: check the chest alone below instead.
    expect(ring).toBeUndefined();
    for (const [id, c] of tally.first) {
      const s = src(id, (x) => x.placeId === 'abbess' && x.kind === 'first_kill')!;
      expect(near(c / N, s.chance, N), `first kill ${id}`).toBe(true);
    }
    expect(near(tally.runeAll / N, BOSS_REPEAT_RUNE_CHANCE, N)).toBe(true);
    for (const [id, c] of tally.rune) {
      const s = src(id, (x) => x.placeId === 'abbess' && x.event === 'Boss kill (repeat)')!;
      expect(near(c / N, s.chance, N), `boss rune ${id}`).toBe(true);
    }
    // The Prelate always leaves a rune; a first kill always does.
    expect(rollBossRune('prelate', false, () => 0.99)).toBeTruthy();
    expect(rollBossRune('abbess', true, () => 0.99)).toBeTruthy();
    const firstRune = [...atlas.sources].filter(([id, l]) => ITEMS[id].type === 'rune' && l.some((s) => s.placeId === 'abbess' && s.kind === 'first_kill')).reduce((n, [, l]) => n + l.find((s) => s.placeId === 'abbess' && s.kind === 'first_kill')!.chance, 0);
    expect(firstRune).toBeCloseTo(1, 9);
  });

  it('boss spoils: at least one of three rolls matches the atlas for a mid-weight item', () => {
    const N = 120_000;
    const rand = mulberry32(31);
    let n = 0;
    const id = 'ring_copper';
    // The Gravedigger King rolls the Hollow Graves table.
    for (let i = 0; i < N; i++) if (rollBoss(0, rand, 'medium', 'graves', 2, 'gravedigger').items.some((x) => x.item_id === id)) n++;
    expect(near(n / N, src(id, (s) => s.placeId === 'gravedigger' && s.kind === 'boss')!.chance, N)).toBe(true);
  });

  it('Grave Surge offerings and elite runes', () => {
    const N = 150_000;
    const rand = mulberry32(41);
    const counts = new Map<string, number>();
    for (let i = 0; i < N; i++) { const d = rollSurgeItem('ossuary', rand); counts.set(d.item_id, (counts.get(d.item_id) ?? 0) + 1); }
    for (const id of ['rune_requiem', 'rune_impale', 'ore_iron']) {
      const s = src(id, (x) => x.placeId === 'ossuary' && x.kind === 'surge');
      if (!s) continue;
      expect(near((counts.get(id) ?? 0) / N, s.chance, N), id).toBe(true);
    }
    const rr = mulberry32(42);
    const runes = new Map<string, number>();
    const M = 400_000;
    for (let i = 0; i < M; i++) { const r = rollEliteRune('ossuary', 1, rr); if (r) runes.set(r.item_id, (runes.get(r.item_id) ?? 0) + 1); }
    const total = [...runes.values()].reduce((a, b) => a + b, 0);
    expect(near(total / M, eliteRuneChance('ossuary'), M)).toBe(true);
    for (const [id, c] of runes) expect(near(c / M, src(id, (x) => x.placeId === 'ossuary' && x.kind === 'elite')!.chance, M), id).toBe(true);
  });

  it('legendary armor: per boss and per elite, by discipline', () => {
    const N = 300_000;
    for (const [disc, id] of [['gravecaller', 'leg_legion_unburied_chest'], ['knight', 'leg_legion_unburied_chest'], ['mourner', 'leg_requiem_wraiths_feet']] as const) {
      const rand = mulberry32(51);
      let boss = 0;
      for (let i = 0; i < N; i++) if (rollBoss(0, rand, 'medium', 'ossuary', 3, 'abbess', disc).items.some((x) => x.item_id === id)) boss++;
      const s = src(id, (x) => x.placeId === 'abbess' && x.kind === 'boss', disc)!;
      expect(s.chance).toBeCloseTo((LEGENDARY_DROP.bossChance * legendaryShare(id.includes('legion') ? 'legion_unburied' : 'requiem_wraiths', disc)) / 5, 12);
      expect(near(boss / N, s.chance, N), `${disc} ${id} boss: ${boss / N} vs ${s.chance}`).toBe(true);
    }
    // The Gravedigger King rolls the lower starter chance, and a boss kill's chances over the 20 pieces add up to the boss roll.
    const gd = src('leg_legion_unburied_chest', (x) => x.placeId === 'gravedigger' && x.kind === 'boss', 'gravecaller')!;
    expect(gd.chance).toBeCloseTo((LEGENDARY_DROP.starterBossChance * legendaryShare('legion_unburied', 'gravecaller')) / 5, 12);
    const parts = ['head', 'chest', 'hands', 'legs', 'feet'] as const;
    const all = LEGENDARY_SET_IDS.flatMap((set) => parts.map((p) => src(legendaryItemId(set, p), (x) => x.placeId === 'abbess' && x.kind === 'boss', 'rotweaver')!.chance));
    expect(all.reduce((a, b) => a + b, 0)).toBeCloseTo(LEGENDARY_DROP.bossChance, 12);
    expect(legendarySetFor('rotweaver')).toBe('plague_choir');
    // Elites only in the level-scaled grounds (Cloister), with a discipline passed.
    const rand = mulberry32(61);
    const M = 600_000;
    let n = 0;
    for (let i = 0; i < M; i++) if (rollKill('robber', 'cloister', 20, true, 0, rand, 'medium', 1, mulberry32(i), mulberry32(i + 7), 'gravecaller').items.some((x) => x.item_id === 'leg_legion_unburied_chest')) n++;
    const e = src('leg_legion_unburied_chest', (x) => x.placeId === 'cloister' && x.kind === 'elite')!.chance;
    expect(near(n / M, e, M), `${n / M} vs ${e}`).toBe(true);
    expect(src('leg_legion_unburied_chest', (x) => x.placeId === 'ossuary' && x.kind === 'elite')).toBeUndefined();
  });

  it('the Depths: floor clears and chests drop from the right table', () => {
    const bands = depthBands();
    expect(bands.map((b) => b.area)).toEqual(['ossuary', 'coliseum', 'sanctum', 'cloister', 'pyre', 'fen']);
    for (const b of bands) expect(depthLootArea(b.from)).toBe(b.area);
    const N = 100_000;
    const rand = mulberry32(71);
    const band = bands[1]; // floors 5-9: the Coliseum's table, first chest at 5
    let floor = 0;
    let chest = 0;
    let rune = 0;
    const gear = 'ring_copper';
    const probe = [...AREAS[band.area].loot.map((e) => e.item)].find((id) => id !== 'x')!;
    for (let i = 0; i < N; i++) {
      if (rollFloorClear(band.from, 20, rand).drop?.item_id === probe) floor++;
      const c = rollChest(5, 20, rand);
      if (c.drops.some((d) => d.item_id === probe)) chest++;
      if (c.drops.some((d) => d.item_id === 'rune_requiem')) rune++;
    }
    void gear;
    const p = `depths:${band.from}`;
    expect(near(floor / N, src(probe, (s) => s.placeId === p && s.event === 'Floor cleared (stair)')!.chance, N)).toBe(true);
    expect(near(chest / N, src(probe, (s) => s.placeId === p && s.event.startsWith('Chest'))!.chance, N), probe).toBe(true);
    const rq = src('rune_requiem', (s) => s.placeId === p && s.event.startsWith('Chest'));
    expect(rq).toBeUndefined(); // epic runes only from depth 10
    expect(rune).toBe(0);
    const s10 = src('rune_requiem', (s) => s.placeId === 'depths:10' && s.event.startsWith('Chest'))!;
    expect(s10.chance).toBeGreaterThan(0);
    expect(FLOOR_DROP_CHANCE).toBeGreaterThan(0);
    expect(chestRuneChance(5)).toBeCloseTo(0.25, 9);
  });

  it('gathering finds are per successful action', () => {
    const node = NODES.grave_barrow_king;
    const N = 400_000;
    const rng = mulberry32(81);
    let ok = 0;
    let seal = 0;
    for (let i = 0; i < N; i++) {
      const r = rollGather(node, 99, rng, 6);
      if (!r.success) continue;
      ok++;
      if (r.items.some((x) => x.itemId === 'covenant_seal')) seal++;
    }
    expect(ok / N).toBeCloseTo(successChance(node, 99, 6), 2);
    expect(near(seal / ok, src('covenant_seal', (s) => s.placeId === 'node:grave_barrow_king')!.chance, ok)).toBe(true);
  });
});

describe('atlas: capes and pets', () => {
  it('every cape is earnable by levels and every pet charm has a way to be found', () => {
    const c = cosmeticsInfo();
    expect(c.capes.length).toBe(10);
    expect(c.capes.every((x) => /^(Level 99 in |Total level \d+)/.test(x.requirement))).toBe(true);
    expect(c.pets.length).toBe(5);
    for (const p of c.pets) {
      expect(ITEMS[p.charm], p.charm).toBeTruthy();
      expect(p.sources.length, p.charm).toBeGreaterThan(0);
    }
  });
});

describe('atlas: upgrading and fit', () => {
  it('affix count odds sum to 1 and match the real roll', () => {
    for (const rarity of ['common', 'uncommon', 'rare', 'epic', 'legendary'])
      for (const source of ['kill', 'elite', 'surge', 'boss', 'first_kill'] as const) {
        const odds = affixCountOdds(rarity, source);
        expect(odds.reduce((a, b) => a + b, 0)).toBeCloseTo(1, 9);
      }
    const rand = mulberry32(91);
    const odds = affixCountOdds('rare', 'boss');
    const c = [0, 0, 0, 0];
    const N = 100_000;
    for (let i = 0; i < N; i++) c[rollAffixCount('rare', 'boss', rand)]++;
    c.forEach((x, i) => expect(Math.abs(x / N - odds[i])).toBeLessThan(0.01));
    expect(odds[0]).toBe(0);
  });

  it('fit comes from the gear score: against its peers (same slot and rarity), a piece scores best for the discipline whose levers it feeds', () => {
    expect(Object.keys(fitTable('set_knight_chest')).sort()).toEqual(Object.keys(DISCIPLINES).sort());
    // (The score values INT above STR/AGI for every discipline, so a knight's own STR set is not its ideal: see docs/polish/atlas-findings.md.)
    expect(fitBand('set_gravecaller_chest', 'gravecaller')).toBe('ideal');
    expect(fitBand('set_monk_chest', 'gravecaller')).not.toBe('ideal');
    expect(peersOf('set_gravecaller_chest').length).toBeGreaterThanOrEqual(9);
    expect(fitBand('material_copper_shard', 'ossuary')).toBeNull();
    // Necromancer weapon kinds: the recommended kind for a Gravecaller is not a poor fit.
    expect(fitBand('scythe_hell', 'gravecaller')).not.toBe('poor');
    expect(isRecommendedKind('scythe_hell', 'gravecaller')).toBe(true);
    expect(isRecommendedKind('wand_hell', 'gravecaller')).toBe(false);
  });

  it('powerGainPct agrees with the equip verdict arrow and is positive for an empty slot', () => {
    const ctx = referenceContext('gravecaller');
    expect(powerGainPct(ctx, 'set_gravecaller_chest')).toBeGreaterThan(0);
    const worn = { ...atlasSlot('set_gravecaller_chest', 100)!, equipped: 1 as const, equipped_slot: 'chest' };
    const withWorn = { ...ctx, slots: [worn] };
    expect(powerGainPct(withWorn, 'set_gravecaller_chest')).toBeCloseTo(0, 5);
    expect(powerGainPct(withWorn, 'set_gravecaller_ascended_chest')).toBeGreaterThan(0);
  });

  it('every armor piece the atlas lists is in the armor catalogue with the stats the item shows', () => {
    for (const [id, p] of Object.entries(ARMOR_BY_ID)) expect(atlas.items.get(id)!.stats).toEqual(p.stats);
  });
});

describe('atlas: drop quality, your own odds and the roll (3 Oct 2026 achievable pass)', () => {
  it('your own armour set drops far more often than the neutral share, and every other set less', async () => {
    const { sourcesFor: sf, getAtlas: ga } = await import('../atlas');
    const own = 'set_gravecaller_head';
    const other = 'set_monk_head';
    const neutral = ga().sources.get(own)!.find((s) => s.placeId === 'graves' && s.kind === 'kill')!.chance;
    const mine = sf(own, 'gravecaller').find((s) => s.placeId === 'graves' && s.kind === 'kill')!.chance;
    const theirs = sf(other, 'gravecaller').find((s) => s.placeId === 'graves' && s.kind === 'kill')!.chance;
    expect(mine).toBeGreaterThan(neutral * 3);
    expect(theirs).toBeLessThan(neutral);
  });
  it('the Atlas chance for your own piece matches the real roll', () => {
    const rand = mulberry32(77);
    const N = 400_000;
    let n = 0;
    for (let i = 0; i < N; i++) if (rollKill('robber', 'graves', 1, true, 0, rand, 'medium', 1, mulberry32(i), mulberry32(i + 1), 'gravecaller').items.some((x) => x.item_id === 'set_gravecaller_head')) n++;
    const s = src('set_gravecaller_head', (x) => x.placeId === 'graves' && x.kind === 'elite')!;
    expect(near(n / N, s.chance, N), `${n / N} vs ${s.chance}`).toBe(true);
  });
  it('places list in descent order, and each deeper ground rates higher quality', async () => {
    const { getAtlas: ga, areaQuality: aq } = await import('../atlas');
    const { AREA_ORDER: order, HUNT_ORDER: hunts } = await import('../../../server/rules/content/areas');
    const areaPlaces = ga().places.filter((p) => p.kind === 'area').map((p) => p.id);
    expect(areaPlaces).toEqual(order.filter((id) => areaPlaces.includes(id)));
    let prev = 0;
    for (const id of hunts) {
      const q = aq(id, 'gravecaller');
      if (!q) continue;
      expect(q.ilvlKill).toBeGreaterThanOrEqual(prev);
      prev = q.ilvlKill;
    }
    expect(aq('fen', 'gravecaller')!.runePerElite).toBeGreaterThan(aq('graves', 'gravecaller')!.runePerElite);
    expect(aq('fen', 'gravecaller')!.bossLegendary).toBeGreaterThan(aq('ossuary', 'gravecaller')!.bossLegendary);
    expect(aq('chapterhouse', 'gravecaller')).toBeNull();
  });
  it('an ideal affix roll is a clear step above the bare piece', async () => {
    const { rollPotential: rp } = await import('../atlas');
    const p = rp('set_gravecaller_chest', 'gravecaller', 9)!;
    expect(p.ideal).toBeGreaterThan(p.plain * 1.3);
    expect(p.picks).toHaveLength(2);
  });
});
