// Golden fixtures for godot/rules/loot (run: npx vite-node tools/godot/fixtures-loot.ts)
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import { AREAS, type AreaId } from '../../server/rules/content/areas';
import { ENEMIES, type EnemyId } from '../../server/rules/content/enemies';
import { ITEMS } from '../../server/rules/content/items';
import { ARMOR_BY_ID } from '../../server/rules/content/armorSets';
import { NECRO_WEAPON_BY_ID } from '../../server/rules/content/necroWeapons';
import { DISCIPLINES } from '../../server/rules/content/disciplines';
import { DIFFICULTIES, DIFFICULTY_ORDER, type Difficulty } from '../../server/rules/content/difficulty';
import { AREA_REAGENT_DROPS, ELITE_REAGENT_MULT, ENEMY_REAGENT_DROPS, BOSS_ICHOR } from '../../server/rules/content/reagents';
import { AREA_RUNE_POOL, BOSS_REPEAT_RUNE_CHANCE, BOSS_RUNE_POOL, ELITE_RUNE_CHANCE_BY_AREA, RUNES, RUNE_ORDER, RUNE_WEIGHT, SURGE_RUNE_CHANCE, eliteRuneChance, pickRune } from '../../server/rules/content/runes';
import { BOSS_IDS, type BossId } from '../../server/rules/content/bosses';
import { LEGENDARY_SETS, LEGENDARY_SET_IDS, LEGENDARY_DROP, LEGENDARY_BOSS_AREAS, LEGENDARY_BOSS_CHANCE, LEGENDARY_ELITE_CHANCE, LEGENDARY_STARTER_AREA, legendaryBossChance, legendaryEliteChance, pickLegendarySet, pickLegendaryItem, rollLegendary, legendarySetFor } from '../../server/rules/content/legendarySets';
import { waveModifiers } from '../../server/rules/content/upgrades';
import { DEPTHS, FLOOR_DROP_CHANCE, FLOOR_BONUS_KILLS, CHEST_KILLS, averageKill, chestBonus, chestDrops, chestRuneChance, chestRunePool, depthLootArea, depthRoster, floorBonus } from '../../server/rules/content/depths';
import { BAG_SLOTS } from '../../server/rules/gameplay/gatheringRules';
import * as loot from '../../src/gameplay/loot';
import * as aff from '../../server/rules/gameplay/affixRules';
import * as affc from '../../src/gameplay/affixes';
import * as lf from '../../src/gameplay/lootFilter';
import * as dr from '../../src/gameplay/depthsRewards';
import { smartTable } from '../../server/rules/gameplay/smartLoot';
import { LootRoller } from '../../src/gameplay/lootRoll';

const out = 'godot/tests/rules-loot/fixtures';
mkdirSync(out, { recursive: true });
const counts: Record<string, number> = {};
const w = (name: string, v: unknown) => {
  writeFileSync(`${out}/${name}.json`, JSON.stringify(v) + '\n');
  counts[name] = Array.isArray(v) ? v.length : Object.keys(v as object).length;
};

// ---------- content subset the GDScript reads (exported from the real modules, never retyped) ----------
const areaIds = Object.keys(AREAS) as AreaId[];
const content = {
  bagSlots: BAG_SLOTS,
  areas: Object.fromEntries(areaIds.map((id) => [id, { itemChance: AREAS[id].itemChance, loot: AREAS[id].loot, scaling: !!AREAS[id].scaling }])),
  enemies: Object.fromEntries(Object.entries(ENEMIES).map(([id, d]) => [id, { gold: d.gold, xp: d.xp }])),
  elite: { goldMult: loot && (await import('../../server/rules/content/enemies')).ELITE.goldMult, xpMult: (await import('../../server/rules/content/enemies')).ELITE.xpMult },
  items: Object.fromEntries(Object.entries(ITEMS).map(([id, m]) => [id, { name: m.name, type: m.type, rarity: m.rarity, sell: m.sell, stack: m.stack ?? null, offlineStats: m.offlineStats ?? null }])),
  armor: Object.fromEntries(Object.entries(ARMOR_BY_ID).map(([id, p]) => [id, p.disciplineId])),
  necroWeapons: Object.keys(NECRO_WEAPON_BY_ID),
  disciplineFamily: Object.fromEntries(Object.entries(DISCIPLINES).map(([id, d]) => [id, d.family])),
  difficulty: Object.fromEntries(Object.entries(DIFFICULTIES).map(([id, d]) => [id, d.rewardMult])),
  reagents: { area: AREA_REAGENT_DROPS, enemy: ENEMY_REAGENT_DROPS, eliteMult: ELITE_REAGENT_MULT, bossIchor: BOSS_ICHOR },
  runes: {
    order: RUNE_ORDER, rarity: Object.fromEntries(RUNE_ORDER.map((id) => [id, RUNES[id].rarity])), weight: RUNE_WEIGHT,
    areaPool: AREA_RUNE_POOL, bossPool: BOSS_RUNE_POOL, eliteChanceByArea: ELITE_RUNE_CHANCE_BY_AREA, eliteChanceDefault: eliteRuneChance('chapterhouse'),
    surgeChance: SURGE_RUNE_CHANCE, bossRepeatChance: BOSS_REPEAT_RUNE_CHANCE,
  },
  legendary: {
    setIds: LEGENDARY_SET_IDS, setDiscipline: Object.fromEntries(LEGENDARY_SET_IDS.map((id) => [id, LEGENDARY_SETS[id].disciplineId])),
    drop: LEGENDARY_DROP, bossAreas: LEGENDARY_BOSS_AREAS, starterArea: LEGENDARY_STARTER_AREA, bossChance: LEGENDARY_BOSS_CHANCE, eliteChance: LEGENDARY_ELITE_CHANCE,
  },
  depths: { rosters: Object.fromEntries([0, 1, 5, 10, 15].map((d) => [d, depthRoster(d)])), minLevel: DEPTHS.minLevel, chestEvery: DEPTHS.chestEvery, floorDropChance: FLOOR_DROP_CHANCE, floorBonusKills: FLOOR_BONUS_KILLS, chestKills: CHEST_KILLS },
};
w('content', content);
// No committed copy any more: the loot rules read DmDb.loot_view(), a projection of godot/data/content/* (this fixture is its oracle).
const NIGHTFALL_TIER = 8; // upgrades.ts WAVE_MILESTONES nightfall; verified by wave_modifiers fixtures below

// ---------- helpers ----------
let seedCtr = 1000;
const nextSeed = () => (seedCtr = (seedCtr * 1103515245 + 12345) % 2147483647);
const R = mulberry32(20261004);
const pick = <T,>(a: readonly T[]): T => a[Math.floor(R() * a.length)];
const disciplines: (string | undefined)[] = [undefined, ...Object.keys(DISCIPLINES), 'nonexistent'];
const difficulties = DIFFICULTY_ORDER as Difficulty[];
const bossIds = BOSS_IDS as BossId[];
const lootAreas = areaIds.filter((a) => AREAS[a].loot.length);
const ownedSets: (string[] | undefined)[] = [undefined, [], ['leg_legion_unburied_head', 'leg_legion_unburied_chest', 'leg_colossus_mantle_head'], LEGENDARY_SET_IDS.flatMap((s) => ['head', 'chest', 'hands', 'legs', 'feet'].map((p) => `leg_${s}_${p}`))];
const ownedFn = (o?: string[]) => (o ? () => new Set(o) : undefined);
const itemIds = Object.keys(ITEMS);

// ---------- waveModifiers (the three fields loot reads) ----------
w('wave_modifiers', Array.from({ length: 30 }, (_, tier) => { const m = waveModifiers(tier); return { tier, rewardMult: m.rewardMult, xpMult: m.xpMult, itemChanceMult: m.itemChanceMult }; }));

// ---------- affix rules ----------
const AFFIX_IDS = aff.AFFIXES.map((a) => a.id);
const defs = aff.AFFIXES.map((a) => ({ id: a.id, kind: a.kind, word: a.word, group: a.group, necro: a.necro, weight: a.weight, unit: a.unit }));
w('affix_defs', defs);
w('affix_ranges', AFFIX_IDS.flatMap((id) => Array.from({ length: 105 }, (_, i) => { const ilvl = i === 0 ? -3 : i === 1 ? 0 : i - 1; return { id, ilvl, range: aff.affixRange(id, ilvl), accept: aff.affixAcceptRange(id, ilvl) }; })).concat([{ id: 'nope', ilvl: 5, range: null, accept: null } as never]));
w('affix_text', AFFIX_IDS.flatMap((id) => [1, 2, 3, 4, 7, 10, 25, 45, 99, 137, 340, 541].map((v) => {
  const a = { id, v };
  return { a, text: aff.affixText(a), necro: aff.affixIsNecro(a), kind: aff.affixKind(a), word: aff.affixWord(a), effect: aff.affixEffect(a), q: [1, 20, 60, 99].map((il) => aff.affixQuality(a, il)) };
})));
w('item_level', [
  ...(['kill', 'elite', 'boss', 'first_kill', 'surge', 'bogus'] as const).flatMap((s) => [1, 2, 10, 50, 94, 95, 99, 100, 250, 0, -4].map((level) => ({ level, source: s, ilvl: aff.itemLevelFor(level, s as never) }))),
  ...[1, 5, 30, 99].flatMap((cl) => [-1, 0, 1, 5, 12, 40, 80, 150].map((l) => ({ characterLevel: cl, level: l, clamp: aff.clampDropLevel(l, cl) }))),
]);
const rarities = ['common', 'uncommon', 'rare', 'epic', 'legendary', 'relic', 'bogus'];
const sources = aff.DROP_SOURCES;
{
  const cases: unknown[] = [];
  for (const rarity of rarities) for (const source of sources) for (let k = 0; k < 40; k++) {
    const seed = nextSeed(); const r = mulberry32(seed);
    cases.push({ rarity, source, seed, count: aff.rollAffixCount(rarity, source, r), after: r() });
  }
  w('affix_count', cases);
}
{
  const cases: unknown[] = [];
  for (let k = 0; k < 3000; k++) {
    const rarity = pick(rarities); const source = pick(sources); const level = pick([1, 3, 8, 12, 20, 25, 26, 33, 45, 60, 80, 99, 120]);
    const seed = nextSeed(); const r = mulberry32(seed);
    const inst = aff.rollInstance({ rarity }, level, source, r);
    cases.push({ rarity, level, source, seed, inst, after: r() });
  }
  w('affix_roll_instance', cases);
}
{
  const cases: unknown[] = [];
  const types = ['weapon', 'armor_head', 'ring', 'material', 'rune', 'consumable', 'offhand'];
  for (let k = 0; k < 1500; k++) {
    const seed = nextSeed(); const r = mulberry32(seed);
    const good = aff.rollInstance({ rarity: pick(rarities) }, pick([1, 10, 30, 70, 99]), pick(sources), r);
    const mode = k % 12;
    let inst: unknown = good; const t = pick(types);
    if (mode === 1) inst = { ...good, ilvl: 0 };
    else if (mode === 2) inst = { ...good, ilvl: 100 };
    else if (mode === 3) inst = { ...good, ilvl: 5.5 };
    else if (mode === 4) inst = { ...good, affixes: [...good.affixes, { id: 'p_str', v: 1 }, { id: 'p_agi', v: 1 }, { id: 'p_int', v: 1 }, { id: 's_ward', v: 3 }] };
    else if (mode === 5 && good.affixes.length) inst = { ...good, affixes: [...good.affixes, good.affixes[0]] };
    else if (mode === 6 && good.affixes.length) inst = { ...good, affixes: [{ id: 'zzz', v: 3 }] };
    else if (mode === 7 && good.affixes.length) inst = { ...good, affixes: [{ ...good.affixes[0], v: good.affixes[0].v + 9999 }] };
    else if (mode === 8 && good.affixes.length) inst = { ...good, affixes: [{ ...good.affixes[0], v: 0 }] };
    else if (mode === 9) inst = null;
    else if (mode === 10) inst = { ilvl: 10, affixes: 'x' };
    else if (mode === 11 && good.affixes.length) inst = { ...good, affixes: [{ ...good.affixes[0], v: 1.5 }] };
    cases.push({ inst, itemType: mode === 0 ? 'weapon' : t, problem: aff.instanceProblem(inst, mode === 0 ? 'weapon' : t), clean: mode === 0 ? aff.cleanInstance(good) : null });
  }
  // legacy-range edge: every affix's accept extremes
  for (const id of AFFIX_IDS) for (const ilvl of [1, 10, 25, 26, 50, 99]) { const [lo, hi] = aff.affixAcceptRange(id, ilvl)!; for (const v of [lo - 1, lo, hi, hi + 1]) { const inst = { ilvl, affixes: [{ id, v }] }; cases.push({ inst, itemType: 'ring', problem: aff.instanceProblem(inst, 'ring'), clean: null }); } }
  w('affix_problem', cases);
}
{
  const cases: unknown[] = [];
  for (let k = 0; k < 600; k++) {
    const seed = nextSeed(); const r = mulberry32(seed);
    const inst = aff.rollInstance({ rarity: pick(rarities) }, pick([1, 10, 30, 70]), pick(sources), r);
    const base = pick(['Iron Helm', 'Bone Ring', 'Scythe']); const br = pick(rarities.slice(0, 6)); const sell = pick([0, 1, 7, 33, 120, 999]);
    const totals = aff.addInstanceTotals(aff.emptyAffixTotals(), inst.affixes);
    cases.push({ inst, base, br, sell, name: aff.affixedName(base, inst.affixes), eff: aff.effectiveRarity(br, inst.affixes.length), sellValue: aff.instanceSellValue(sell, inst), power: aff.instancePower(inst), totals });
  }
  for (const n of [-1, 0, 1, 2, 3, 4, 9]) for (const br of rarities) cases.push({ inst: null, nEff: n, br, eff: aff.effectiveRarity(br, n), sellValue: aff.instanceSellValue(5, null), power: aff.instancePower(null) });
  w('affix_misc', cases);
}

// ---------- decorateSlot / affixes.ts ----------
{
  const cases: unknown[] = [];
  const gear = itemIds.filter((i) => affc.canRoll(i));
  w('can_roll', itemIds.map((id) => ({ id, can: affc.canRoll(id) })).concat([{ id: 'nope', can: affc.canRoll('nope') }]));
  for (let k = 0; k < 600; k++) {
    const seed = nextSeed(); const r = mulberry32(seed);
    const id = pick(gear); const m = ITEMS[id];
    const inst = aff.rollInstance({ rarity: m.rarity }, pick([1, 15, 40, 80]), pick(sources), r);
    const mode = k % 8;
    const row: Record<string, unknown> = { id: 0, slot_index: 3, quantity: 1, equipped: 0, item_id: id, name: m.name, rarity: m.rarity, item_type: m.type, stat_bonus: null, icon_id: null, sell_value: m.sell, crafted: 0 };
    if (mode !== 7) { row.instance_id = 100 + k; row.ilvl = inst.ilvl; row.affixes = mode === 1 ? JSON.stringify(inst.affixes) : mode === 2 ? 'not json' : mode === 3 ? null : mode === 4 ? [...inst.affixes, { id: 5, v: 2 }, { id: 'p_str', v: 1.5 }, null] : inst.affixes; }
    if (mode === 5) row.base_name = 'Prior'; 
    if (mode === 6) { row.instance_id = null; }
    const dec = affc.decorateSlot(row as never);
    const dec2 = affc.decorateSlot(dec);
    cases.push({ row, dec, idem: JSON.stringify(dec2) === JSON.stringify(dec), lines: affc.affixLines(dec), roll: affc.rollOf(dec), title: affc.rollTitleLines(dec) });
  }
  w('decorate_slot', cases);
}

// ---------- smart loot ----------
{
  const cases: unknown[] = [];
  for (const area of lootAreas) for (const d of disciplines) cases.push({ area, disc: d ?? null, table: smartTable(area, d ?? 'nonexistent_none') && (d ? smartTable(area, d) : null) });
  w('smart_table', cases.filter((c: any) => c.table));
}

// ---------- loot rolls ----------
const lootStr = (x: unknown) => x;
w('is_profession_material', itemIds.map((id) => ({ id, v: loot.isProfessionMaterial(id) })).concat([{ id: 'ore_x', v: true }, { id: 'gem', v: false }, { id: 'xlog_a', v: false }]));
w('settle_combat_drop', itemIds.flatMap((id) => [[1, false], [3, true], [7, false], [2, true]].map(([q, kg]) => ({ drop: { item_id: id, quantity: q }, keepGems: kg, res: loot.settleCombatDrop({ item_id: id, quantity: q as number }, kg as boolean) }))).concat([{ drop: { item_id: 'zz_unknown', quantity: 4 }, keepGems: false, res: loot.settleCombatDrop({ item_id: 'zz_unknown', quantity: 4 }, false) }, { drop: { item_id: 'ore_zz', quantity: 4 }, keepGems: false, res: loot.settleCombatDrop({ item_id: 'ore_zz', quantity: 4 }, false) }] as never));
w('kill_loot_const', loot.KILL_LOOT);

{
  const cases: unknown[] = [];
  for (let k = 0; k < 600; k++) {
    const area = pick(lootAreas); const disc = pick(disciplines); const mq = pick([1, 2]);
    const s = nextSeed(); const r = mulberry32(s);
    const d = loot.rollItem(area, r, mq, disc);
    cases.push({ area, disc: disc ?? null, mq, seed: s, drop: d, after: r() });
  }
  w('roll_item', cases);
}
{
  const cases: unknown[] = [];
  const enemyIds = Object.keys(ENEMIES) as EnemyId[];
  for (let k = 0; k < 6000; k++) {
    const area = pick(areaIds); const a = AREAS[area];
    const def = R() < 0.8 && a.enemies.length ? pick(a.enemies).id : pick(enemyIds);
    const level = pick([1, 2, 5, 9, 14, 20, 31, 45, 60, 80]);
    const elite = R() < 0.35; const tier = pick([0, 0, 1, 3, 5, 7, 8, 9, 12]);
    const diff = pick(difficulties); const icm = pick([1, 1, 0.5, 1.5, 2, 6]); const disc = pick(disciplines);
    const owned = pick(ownedSets);
    const sA = nextSeed(), sB = nextSeed(), sC = nextSeed();
    const a1 = mulberry32(sA), b1 = mulberry32(sB), c1 = mulberry32(sC);
    const res = loot.rollKill(def, area, level, elite, tier, a1, diff, icm, b1, c1, disc, ownedFn(owned));
    cases.push({ def, area, level, elite, tier, diff, icm, disc: disc ?? null, owned: owned ?? null, seeds: [sA, sB, sC], res, after: [a1(), b1(), c1()] });
  }
  w('roll_kill', cases);
}
{
  const cases: unknown[] = [];
  for (let k = 0; k < 1500; k++) {
    const area = pick(areaIds); const enemies = AREAS[area].enemies; const def = (enemies.length ? pick(enemies).id : pick(Object.keys(ENEMIES))) as EnemyId;
    const elite = R() < 0.5; const icm = pick([1, 1.5, 3]);
    const s = nextSeed(); const r = mulberry32(s);
    cases.push({ def, area, elite, icm, seed: s, res: loot.rollReagents(def, area, elite, icm, r), after: r() });
  }
  for (const def of ['wraith', 'seraph'] as EnemyId[]) for (const area of areaIds) for (const elite of [false, true]) { const s = nextSeed(); const r = mulberry32(s); cases.push({ def, area, elite, icm: 1, seed: s, res: loot.rollReagents(def, area, elite, 1, r), after: r() }); }
  w('roll_reagents', cases);
}
{
  const cases: unknown[] = [];
  for (let k = 0; k < 1500; k++) {
    const area = pick(areaIds); const icm = pick([1, 1.2, 2, 20]); const s = nextSeed(); const r = mulberry32(s);
    cases.push({ area, icm, seed: s, res: loot.rollEliteRune(area, icm, r), after: r() });
  }
  w('roll_elite_rune', cases);
}
{
  const cases: unknown[] = [];
  for (let k = 0; k < 1000; k++) {
    const area = pick(lootAreas); const disc = pick(disciplines); const s = nextSeed(); const r = mulberry32(s);
    cases.push({ area, disc: disc ?? null, seed: s, res: loot.rollSurgeItem(area, r, disc), after: r() });
  }
  w('roll_surge_item', cases);
}
{
  const cases: unknown[] = [];
  for (let k = 0; k < 1000; k++) {
    const boss = pick([...bossIds, 'bogus' as BossId]); const first = R() < 0.4; const s = nextSeed(); const r = mulberry32(s);
    cases.push({ boss, first, seed: s, res: loot.rollBossRune(boss, first, r), after: r() });
  }
  w('roll_boss_rune', cases);
}
{
  const cases: unknown[] = [];
  for (let k = 0; k < 2500; k++) {
    const area = pick(lootAreas); const tier = pick([0, 1, 4, 8, 11]); const diff = pick(difficulties); const cost = pick([2, 3, 4, 5, 6]);
    const boss = R() < 0.9 ? pick(bossIds) : undefined; const disc = pick(disciplines); const owned = pick(ownedSets);
    const s = nextSeed(); const r = mulberry32(s);
    cases.push({ tier, diff, area, cost, boss: boss ?? null, disc: disc ?? null, owned: owned ?? null, seed: s, res: loot.rollBoss(tier, r, diff, area, cost, boss, disc, ownedFn(owned)), after: r() });
  }
  w('roll_boss', cases);
}
{
  const cases: unknown[] = [];
  for (let k = 0; k < 1500; k++) {
    const area = pick(lootAreas); const disc = pick(disciplines); const s = nextSeed(); const r = mulberry32(s);
    cases.push({ area, disc: disc ?? null, seed: s, res: loot.rollFirstKillItem(area, r, disc), after: r() });
  }
  w('roll_first_kill', cases);
}

// ---------- legendary ----------
{
  const cases: unknown[] = [];
  for (const area of areaIds) cases.push({ area, boss: legendaryBossChance(area), elite: legendaryEliteChance(area) });
  const picks: unknown[] = [];
  for (let k = 0; k < 1500; k++) {
    const disc = pick(disciplines) ?? 'ossuary'; const owned = pick(ownedSets); const chance = pick([0, 0.01, 0.2, 0.5, 1]);
    const s = nextSeed(); const r1 = mulberry32(s), r2 = mulberry32(s), r3 = mulberry32(s);
    picks.push({ disc, owned: owned ?? null, chance, seed: s, set: pickLegendarySet(disc, r1), item: pickLegendaryItem(disc, r2, owned ? new Set(owned) : undefined), roll: rollLegendary(disc, chance, r3, ownedFn(owned)), after: r3() });
  }
  w('legendary_chance', cases);
  w('legendary_pick', picks);
  w('legendary_set_for', Object.keys(DISCIPLINES).concat(['zzz']).map((d) => ({ d, set: legendarySetFor(d) ?? null })));
}

// ---------- bag: addToSlots / sortBagSlots / toSavePayload / lootAction ----------
const slotItems = itemIds.filter((_, i) => i % 3 === 0);
const mkSlot = (idx: number, id: string, qty: number, extra: object = {}) => {
  const m = ITEMS[id];
  return { id: 0, slot_index: idx, quantity: qty, equipped: 0 as const, item_id: id, name: m?.name ?? id, rarity: m?.rarity ?? 'common', item_type: m?.type ?? 'material', stat_bonus: null, icon_id: null, sell_value: m?.sell ?? 0, crafted: 0 as const, ...extra };
};
const randomBag = (fill: number) => {
  const used = new Set<number>(); const slots: any[] = [];
  while (slots.length < fill) {
    const idx = Math.floor(R() * BAG_SLOTS); if (used.has(idx)) continue; used.add(idx);
    const id = pick(R() < 0.5 ? gearOrStack : slotItems);
    slots.push(mkSlot(idx, id, ITEMS[id]?.type === 'material' ? 1 + Math.floor(R() * 120) : 1, { equipped: 0 }));
  }
  if (R() < 0.3) slots.push(mkSlot(100 + Math.floor(R() * 5), pick(slotItems), 1, { equipped: 1 }));
  return slots;
};
const gearOrStack = itemIds.filter((i) => ITEMS[i].type === 'material' && ITEMS[i].stack).slice(0, 30).concat(itemIds.filter((i) => affc.canRoll(i)).slice(0, 30), itemIds.filter((i) => ITEMS[i].type === 'rune' || ITEMS[i].type === 'consumable').slice(0, 10));
{
  const cases: unknown[] = [];
  for (let k = 0; k < 500; k++) {
    const fill = pick([0, 3, 10, 30, 46, 47, 48]);
    const slots = randomBag(fill);
    const id = R() < 0.6 && slots.length ? pick(slots).item_id : pick(itemIds);
    const quantity = pick([1, 1, 2, 5, 40, 120, 300]);
    const drop: any = { item_id: id, quantity };
    if (R() < 0.3 && affc.canRoll(id)) drop.instance = { id: 5 + k, ilvl: 1 + (k % 60), affixes: aff.rollInstance({ rarity: 'rare' }, 20, 'boss', mulberry32(k)).affixes };
    cases.push({ slots, drop, res: loot.addToSlots(slots, drop) });
  }
  w('add_to_slots', cases);
}
{
  const cases: unknown[] = [];
  for (let k = 0; k < 120; k++) {
    const slots = randomBag(pick([2, 8, 20, 40, 48])).map((s: any) => { const g = affc.canRoll(s.item_id); if (!g || R() < 0.5) return s; const inst = aff.rollInstance({ rarity: ITEMS[s.item_id].rarity }, pick([5, 30, 60]), 'elite', mulberry32(nextSeed())); return affc.decorateSlot({ ...s, instance_id: 50 + k, ilvl: inst.ilvl, affixes: inst.affixes }); });
    const lockSet = new Set(slots.filter(() => R() < 0.2).map((s: any) => s.slot_index));
    const moves = new Map<number, number>();
    const res = loot.sortBagSlots(slots, moves, (s) => lockSet.has(s.slot_index));
    const moves2 = new Map<number, number>();
    const res0 = loot.sortBagSlots(slots, moves2);
    cases.push({ slots, locked: [...lockSet], res, moves: [...moves], res0, moves0: [...moves2], payload: loot.toSavePayload(res) });
  }
  w('sort_bag', cases);
}
{
  const cases: unknown[] = [];
  const gear = itemIds.filter((i) => affc.canRoll(i)); const armorIds = gear.filter((i) => ARMOR_BY_ID[i]);
  for (let k = 0; k < 2000; k++) {
    const id = R() < 0.4 && armorIds.length ? pick(armorIds) : R() < 0.9 ? pick(gear) : pick(itemIds);
    const m = ITEMS[id]; const seed = nextSeed();
    let row: any = mkSlot(0, id, 1);
    if (R() < 0.75 && affc.canRoll(id)) { const inst = aff.rollInstance({ rarity: m.rarity }, pick([5, 30, 70]), pick(sources), mulberry32(seed)); row = affc.decorateSlot({ ...row, instance_id: 9, ilvl: inst.ilvl, affixes: inst.affixes }); }
    const rules: any = {}; for (const t of ['common', 'uncommon', 'rare', 'epic', 'legendary']) rules[t] = pick(t === 'legendary' ? ['ground', 'auto'] : ['ground', 'auto', 'gold', 'gold']);
    const keep = R() < 0.3;
    cases.push({ row, rules, keep, action: lf.lootAction(row, rules, keep ? () => true : undefined), actionNoKeepFn: lf.lootAction(row, rules) });
  }
  w('loot_action', cases);
  const rr: unknown[] = [];
  const savedSamples: unknown[] = [undefined, null, 5, 'x', {}, { common: 'gold', legendary: 'gold', epic: 'auto', rare: 'bogus' }, { legendary: 'auto', uncommon: 'gold' }, { common: 'auto', uncommon: 'auto', rare: 'auto', epic: 'auto', legendary: 'ground' }];
  for (const saved of savedSamples) for (const legacy of [undefined, 'common', 'uncommon', 'rare', 'epic', 'legendary', 'zzz']) rr.push({ saved: saved === undefined ? null : saved, legacy: legacy ?? null, rules: lf.readLootRules(saved, legacy) });
  w('read_loot_rules', rr);
  w('actions_for', (['common', 'uncommon', 'rare', 'epic', 'legendary'] as const).map((t) => ({ t, a: lf.actionsFor(t).map((x) => x.id) })));
}

// ---------- depths ----------
{
  const bonuses: unknown[] = [];
  for (let depth = 0; depth <= 45; depth++) for (const level of [1, 12, 30, 60, 90]) bonuses.push({ depth, level, area: depthLootArea(depth), floor: floorBonus(depth, level), chest: chestBonus(depth, level), avg: averageKill(depth, level), drops: chestDrops(depth), runeChance: chestRuneChance(depth), runePool: chestRunePool(depth) });
  w('depths_bonus', bonuses);
  w('depths_roster', Array.from({ length: 41 }, (_, d) => ({ d, roster: depthRoster(d) })));
  const floor: unknown[] = [], gear: unknown[] = [], chest: unknown[] = [];
  for (let k = 0; k < 800; k++) { const depth = 1 + Math.floor(R() * 40), level = pick([1, 12, 33, 70]), disc = pick(disciplines); const s = nextSeed(); const r = mulberry32(s); floor.push({ depth, level, disc: disc ?? null, seed: s, res: dr.rollFloorClear(depth, level, r, disc), after: r() }); }
  for (let k = 0; k < 600; k++) { const depth = 1 + Math.floor(R() * 40), disc = pick(disciplines); const s = nextSeed(); const r = mulberry32(s); gear.push({ depth, disc: disc ?? null, seed: s, res: dr.rollGearDrop(depth, r, disc), after: r() }); }
  for (let k = 0; k < 1000; k++) { const depth = 1 + Math.floor(R() * 40), level = pick([1, 12, 33, 70]), disc = pick(disciplines); const s = nextSeed(); const r = mulberry32(s); chest.push({ depth, level, disc: disc ?? null, seed: s, res: dr.rollChest(depth, level, r, disc), after: r() }); }
  w('depths_floor_clear', floor); w('depths_gear_drop', gear); w('depths_chest', chest);
}

// ---------- lootRoll (client side of server rolls) ----------
{
  const cases: unknown[] = [];
  const gear = itemIds.filter((i) => affc.canRoll(i)); const mats = itemIds.filter((i) => !affc.canRoll(i));
  for (let k = 0; k < 120; k++) {
    const n = pick([0, 1, 3, 12, 13, 25, 30]);
    const drops: any[] = Array.from({ length: n }, () => { const g = R() < 0.7; const d: any = { item_id: pick(g ? gear : mats), quantity: 1 }; if (g && R() < 0.1) d.instance = { id: 1, ilvl: 3, affixes: [] }; return d; });
    const level = pick([1, 20, 50]); const source = pick(sources);
    const mode = pick(['ok', 'ok', 'short', 'mismatch', 'noinst', 'throw']);
    const requests: unknown[] = [];
    const answers: unknown[] = [];
    let callNo = 0;
    const roll = async (cid: number, req: { item_id: string; level: number; source: any }[]) => {
      requests.push({ cid, req }); callNo++;
      if (mode === 'throw' && callNo === 2) { answers.push({ threw: true }); throw new Error('x'); }
      const ans = req.map((d, i) => {
        if (mode === 'short' && i === req.length - 1) return undefined as never;
        if (mode === 'mismatch' && i === 0) return { item_id: 'other', instance_id: 5, ilvl: 4, affixes: [] };
        if (mode === 'noinst' && i % 2 === 0) return { item_id: d.item_id, instance_id: null, ilvl: 1, affixes: [] };
        return { item_id: d.item_id, instance_id: 1000 * callNo + i + 1, ilvl: 2 + i, affixes: [{ id: 'p_str', v: 3 + i }] };
      });
      answers.push(ans.map((a) => a ?? null));
      return ans;
    };
    const before = JSON.parse(JSON.stringify(drops));
    const roller = new LootRoller(77, roll as never);
    await roller.attach(drops, level, source);
    cases.push({ mode, level, source, drops: before, requests, answers, result: drops, pending: roller.pending });
  }
  w('loot_roller', cases);
}

console.log(JSON.stringify(counts, null, 1), 'total cases', Object.values(counts).reduce((a, b) => a + b, 0));
