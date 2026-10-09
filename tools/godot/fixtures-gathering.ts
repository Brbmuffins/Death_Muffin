/**
 * Golden fixtures for godot/rules/gathering + godot/rules/inventory, generated FROM the TypeScript.
 * Run: npx vite-node tools/godot/fixtures-gathering.ts   ->  godot/tests/rules-gathering/fixtures/*.json
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import * as GR from '../../server/rules/gameplay/gatheringRules';
import { NODES, NODE_IDS, SKILLS, addSkillXp, checkBudget, placeItems, rollBatch, rollGather, successChance, toolTierFor, toolKindOf, beltSlotOf, beltSlotKind, bestToolPerKind, isBeltSlot, xpPerHour, xpToNextCurve, xpToNextLive, totalXpFor, toolItemId, actionMs, type NodeDef } from '../../server/rules/gameplay/gatheringRules';
import { standSpot, gatherBlocker, nextAutoNode } from '../../src/gameplay/gatherPlan';
import * as LAB from '../../server/rules/gameplay/laborRules';
import * as GAR from '../../server/rules/gameplay/gardeningRules';
import * as CON from '../../server/rules/gameplay/contractRules';
import * as SAL from '../../server/rules/gameplay/salvageRules';
import * as GS from '../../server/rules/gameplay/goldSinkRules';
import { AFFIXES, affixRange } from '../../server/rules/gameplay/affixRules';
import { BOSSES } from '../../server/rules/content/bosses';
import { ALL_RECIPE_ROWS } from '../../src/content/recipes';
import { clampCraftQty, hasSkillAndMaterials, maxCraftable } from '../../src/gameplay/craftQuantity';
import { addToSlots, sortBagSlots } from '../../src/gameplay/loot';
import { ItemLocks, junkSlots, salvageBelowRare } from '../../src/gameplay/itemLocks';
import * as V from '../../server/rules/gameplay/vaultRules';
import * as PB from '../../src/gameplay/beltRules';
import { ITEMS, itemMeta } from '../../server/rules/content/items';
import { SEEDS, PLOTS } from '../../server/rules/content/gardening';
import type { InventorySlot } from '../../src/net/types';

const out = 'godot/tests/rules-gathering/fixtures';
mkdirSync(out, { recursive: true });
const w = (name: string, v: unknown) => writeFileSync(`${out}/${name}.json`, JSON.stringify(v) + '\n');

const R = mulberry32(20261004);
const rint = (lo: number, hi: number) => lo + Math.floor(R() * (hi - lo + 1));
const rpick = <T>(l: T[]): T => l[Math.floor(R() * l.length)];
const nodes: NodeDef[] = Object.values(NODES);

// ── xp ──
{
  const cases: unknown[] = [];
  for (let l = 0; l <= 100; l++) cases.push({ k: 'next', level: l, live: xpToNextLive(l), curve: xpToNextCurve(l) });
  for (const l of [1, 2, 10, 50, 99, 100]) cases.push({ k: 'total', level: l, v: totalXpFor(l), curve: totalXpFor(l, xpToNextCurve) });
  const odd = [0, 1.7, 99, 100, 150, -3];
  for (let i = 0; i < 300; i++) {
    const p = { level: i < 6 ? odd[i] : rint(1, 99), xp: R() < 0.1 ? -5 : Math.floor(R() * 6000) };
    const gained = R() < 0.1 ? -4 : R() < 0.2 ? 12.9 : Math.floor(R() * (R() < 0.3 ? 400000 : 4000));
    cases.push({ k: 'add', p, gained, out: addSkillXp(p, gained) });
  }
  w('xp', cases);
}

// ── chance / xp per hour ──
{
  const cases: unknown[] = [];
  for (const n of nodes) for (const level of [1, n.level - 20, n.level - 1, n.level, n.level + 7, n.level + 40, 99]) for (const tier of [0, 1, 3, 6]) {
    if (level < 1) continue;
    cases.push({ node: n.id, level, tier, chance: successChance(n, level, tier), xph: xpPerHour(n, level, tier), ms: actionMs(n) });
  }
  w('chance', cases);
}

// ── rolls ──
{
  const gather: unknown[] = [];
  for (const n of nodes) for (const level of [Math.max(1, n.level - 1), n.level, n.level + 12, 99]) for (const tier of [0, 5]) for (const seed of [rint(1, 1e9), rint(1, 1e9)]) {
    const rng = mulberry32(seed);
    const rolls = Array.from({ length: 6 }, () => rollGather(n, level, rng, tier));
    gather.push({ node: n.id, level, tier, seed, rolls });
  }
  w('gather_rolls', gather);
  const batch: unknown[] = [];
  for (let i = 0; i < 260; i++) {
    const n = rpick(nodes);
    const start = { level: rint(Math.max(1, n.level - 2), Math.min(99, n.level + 30)), xp: rint(0, 800) };
    const actions = i % 20 === 0 ? 800 : rint(1, 80);
    const tier = rint(0, 6);
    const floor = R() < 0.15 ? 99 : 0;
    const seed = rint(1, 1e9);
    batch.push({ node: n.id, start, actions, tier, floor, seed, out: rollBatch(n, start, actions, mulberry32(seed), tier, floor) });
  }
  w('batch', batch);
}

// ── budget ──
{
  const cases: unknown[] = [];
  for (let i = 0; i < 400; i++) {
    const n = rpick(nodes);
    const now = 1_700_000_000_000 + rint(0, 5e8);
    const never = R() < 0.2;
    const ledger = { lastAt: never ? 0 : now - rint(0, 200_000), hourStart: R() < 0.15 ? 0 : now - rint(0, 4_000_000), hourActions: R() < 0.15 ? rint(1700, 1800) : rint(0, 1500) };
    const claimed = R() < 0.1 ? rpick([0, -2, 1.9]) : rint(1, 60);
    const afk = R() < 0.4;
    cases.push({ node: n.id, ledger, claimed, now, afk, out: checkBudget(n, ledger, claimed, now, afk) });
  }
  w('budget', cases);
}

// ── tools & belt ──
{
  const ids = ['tool_hatchet_copper', 'tool_hatchet_moon', 'tool_pickaxe_iron', 'tool_pickaxe_steel', 'tool_rod_silver', 'tool_spade_hell', 'tool_spade_bogus', 'tool_hatchet_', 'tool_', 'ore_copper', '', 'tool_rod_copper', 'tool_pickaxe_copper'];
  const tiers: unknown[] = [];
  for (const skill of ['woodcutting', 'mining', 'fishing', 'gravedigging', 'gardening', 'alchemy']) {
    for (let i = 0; i < 20; i++) {
      const held = Array.from({ length: rint(0, 5) }, () => rpick(ids));
      tiers.push({ skill, held, tier: toolTierFor(skill as GR.SkillId, held) });
    }
    for (let t = 1; t <= 6; t++) if (GR.TOOL_KIND[skill as GR.SkillId]) tiers.push({ skill, id_for_tier: t, id: toolItemId(skill as GR.SkillId, t) });
  }
  const kinds = ids.map((id) => ({ id, kind: toolKindOf(id), slot: beltSlotOf(id) }));
  const slots = [-1, 0, 109, 110, 111, 112, 113, 114, 115].map((s) => ({ slot: s, isBelt: isBeltSlot(s), kind: beltSlotKind(s) }));
  const bests: unknown[] = [];
  for (let i = 0; i < 40; i++) {
    const held = Array.from({ length: rint(0, 8) }, () => rpick(ids));
    bests.push({ held, best: bestToolPerKind(held) });
  }
  w('tools', { tiers, kinds, slots, bests });
}

// ── place items ──
{
  const stackTable: Record<string, number> = { log_oak: 250, ore_copper: 250, fish_river: 250, bones_old: 250, ring_copper: 1, helm_gold: 1, flask_hp_minor: 99, seed_mourning_moss: 99, gem_grave_garnet: 250 };
  const idl = Object.keys(stackTable);
  const cases: unknown[] = [];
  for (let i = 0; i < 200; i++) {
    const used = new Set<number>();
    const bag = Array.from({ length: rint(0, 47) }, () => {
      let s = rint(0, 47);
      while (used.has(s)) s = (s + 1) % 48;
      used.add(s);
      const itemId = rpick(idl);
      return { slot: s, itemId, qty: rint(1, stackTable[itemId]) };
    });
    const grants = Array.from({ length: rint(1, 5) }, () => {
      const itemId = rpick(idl);
      return { itemId, qty: rint(1, itemId.startsWith('log') ? 700 : 30) };
    });
    cases.push({ bag, grants, out: placeItems(bag, grants, (id) => stackTable[id] ?? 1) });
  }
  w('place_items', { stackTable, cases });
}

// ── gather plan ──
{
  const stands: unknown[] = [];
  for (let i = 0; i < 120; i++) {
    const n = { type: rpick(NODE_IDS), x: R() * 40 - 20, z: R() * 40 - 20 };
    const circles = Array.from({ length: rint(0, 6) }, () => ({ x: n.x + R() * 4 - 2, z: n.z + R() * 4 - 2, r: 0.3 + R() * 1.2 }));
    if (i % 15 === 0) circles.push({ x: n.x, z: n.z, r: 50 });
    const from = { x: R() * 40 - 20, z: R() * 40 - 20 };
    const r = R() < 0.2 ? 0.7 : 0.45;
    const nav = { blocked: (x: number, z: number, rr: number) => circles.some((c) => Math.hypot(x - c.x, z - c.z) < c.r + rr) };
    stands.push({ node: n, circles, from, r, out: i % 3 === 0 ? standSpot(nav, n, from.x, from.z) : standSpot(nav, n, from.x, from.z, r), defaultR: i % 3 === 0 });
  }
  const blockers = NODE_IDS.concat(['nope']).flatMap((t) => [1, 10, 50].map((level) => ({ type: t, level, out: gatherBlocker(t, level) })));
  const autos: unknown[] = [];
  for (let i = 0; i < 80; i++) {
    const type = rpick(['coffin_oak', 'seam_iron', 'pool_still']);
    const list = Array.from({ length: rint(0, 8) }, () => ({ type: R() < 0.7 ? type : 'seam_tin', x: Math.floor(R() * 10), z: Math.floor(R() * 10), area: R() < 0.8 ? 'graves' : 'chapterhouse', remaining: R() < 0.3 ? 0 : rint(1, 5) }));
    const from = { type, x: Math.floor(R() * 10), z: Math.floor(R() * 10), area: 'graves' };
    const level = rint(1, 30);
    const px = R() * 10, pz = R() * 10;
    const o = nextAutoNode({ from, nodes: list, level, x: px, z: pz });
    autos.push({ from, nodes: list, level, x: px, z: pz, out: o ? list.indexOf(o) : -1 });
  }
  w('plan', { stands, blockers, autos });
}

// ── labor ──
{
  const levelsRand = () => Object.fromEntries((['woodcutting', 'mining', 'fishing', 'gravedigging', 'gardening'] as const).filter(() => R() < 0.85).map((s) => [s, rint(1, 99)]));
  const cases: unknown[] = [];
  for (let i = 0; i < 60; i++) {
    const levels = levelsRand();
    cases.push({ k: 'posts', levels, total: LAB.totalGatherLevel(levels), slots: LAB.laborSlots(LAB.totalGatherLevel(levels)), posts: LAB.postsFor(levels).map((n) => n.id) });
  }
  for (const t of [-5, 0, 49, 50, 100, 149, 150, 400]) cases.push({ k: 'slots', total: t, slots: LAB.laborSlots(t) });
  for (const id of NODE_IDS.concat(['nope'])) for (const lv of [1, 30, 99]) cases.push({ k: 'assign', node: id, levels: { woodcutting: lv, mining: lv, fishing: lv, gravedigging: lv, gardening: lv }, out: LAB.assignBlocker(id, { woodcutting: lv, mining: lv, fishing: lv, gravedigging: lv, gardening: lv }) });
  for (let i = 0; i < 150; i++) {
    const n = rpick(nodes.filter((x) => x.skill !== 'gardening'));
    const elapsed = rpick([0, 1000, 60_000, 3_600_000, 5 * 3_600_000, 9 * 3_600_000, rint(0, 40_000_000)]);
    const level = rint(n.level, 99);
    cases.push({ k: 'est', node: n.id, level, elapsed, actions: LAB.laborActions(n, elapsed), est: LAB.estimate(n, level, elapsed) });
  }
  for (let i = 0; i < 80; i++) {
    const n = rpick(nodes.filter((x) => x.skill !== 'gardening'));
    const start = { level: rint(n.level, Math.min(99, n.level + 30)), xp: rint(0, 800) };
    const elapsed = rint(1_000_000, 30_000_000);
    const parts = ['post', rint(1, 99), i, 1700000000000 + i];
    const seed = LAB.hashSeed(...parts);
    cases.push({ k: 'roll', node: n.id, start, elapsed, parts, seed, out: LAB.rollLabor(n, start, elapsed, LAB.claimRng(seed)) });
  }
  w('labor', cases);
}

// ── garden ──
{
  const cases: unknown[] = [];
  for (const s of SEEDS) for (const c of [false, true]) cases.push({ k: 'grow', seed: s.id, composted: c, ms: GAR.growMs(s, c) });
  const now = 1_700_000_000_000;
  const rows = [null, { plot: 'h0', seedId: null, plantedAt: 0, readyAt: 0, composted: false }, { plot: 'h0', seedId: 'seed_mourning_moss', plantedAt: now - 1000, readyAt: now + 5000, composted: false }, { plot: 'h0', seedId: 'seed_mourning_moss', plantedAt: now - 9000, readyAt: now - 1, composted: true }, { plot: 'h0', seedId: 'seed_mourning_moss', plantedAt: now - 9000, readyAt: now, composted: true }];
  rows.forEach((row, i) => cases.push({ k: 'state', i, row, now, out: GAR.stateOf(row, now) }));
  for (const plot of [...PLOTS.map((p) => p.id), 'zz']) for (const seedId of [...SEEDS.map((s) => s.id), 'nope']) for (const level of [1, 40, 99]) for (let ri = 0; ri < rows.length; ri += 2) {
    cases.push({ k: 'plant', plot, seedId, level, ri, now, out: GAR.plantBlocker(GAR.plotDef(plot), seedId, level, rows[ri], now) });
  }
  for (const s of SEEDS) for (let i = 0; i < 6; i++) {
    const seed = rint(1, 1e9);
    cases.push({ k: 'harvest', seed: s.id, rseed: seed, out: GAR.rollHarvest(s, mulberry32(seed)) });
  }
  for (const ms of [-5, 0, 1, 999, 1000, 1001, 45_000, 59_999, 60_000, 35 * 60_000, 3_600_000, 4_800_000, 90_000_000]) cases.push({ k: 'text', ms, out: GAR.remainingText(ms) });
  w('garden', cases);
}

// ── contracts ──
{
  const skills = ['woodcutting', 'mining', 'fishing', 'gravedigging', 'gardening', 'alchemy', 'salvaging'];
  const levelsRand = () => Object.fromEntries(skills.filter(() => R() < 0.8).map((s) => [s, R() < 0.2 ? rint(1, 5) : rint(1, 99)]));
  const boards: unknown[] = [];
  const all99 = Object.fromEntries(skills.map((s) => [s, 99]));
  for (let i = 0; i < 260; i++) {
    const levels = i < 3 ? ({} as Record<string, number>) : i === 3 ? all99 : levelsRand();
    const day = CON.dayKey(1_700_000_000_000 + i * 86_400_000 * 3);
    const characterId = rint(1, 5000);
    const board = CON.generateBoard(characterId, day, levels);
    boards.push({ characterId, day, levels, board, bonus: CON.bonusFor(board) });
  }
  const cands: unknown[] = [];
  for (const lv of [0, 1, 5, 10, 20, 30, 45, 60, 80, 99]) {
    const levels = Object.fromEntries(skills.map((s) => [s, lv]));
    cands.push({ levels, out: CON.candidatesFor(levels) });
  }
  const infos = CON.candidatesFor(all99).map((c) => ({ id: c.itemId, out: CON.orderInfo(c.itemId) })).concat([{ id: 'nope', out: CON.orderInfo('nope') }]);
  const days = [0, 1_700_000_000_000, 1_700_000_000_000 + 86_399_999, 1_709_251_199_999, 1_709_251_200_000, 4_102_444_800_000].map((ms) => ({ ms, day: CON.dayKey(ms), next: CON.nextResetMs(ms) }));
  const streaks: unknown[] = [];
  for (let i = 0; i < 60; i++) {
    const base = 1_700_000_000_000;
    const today = CON.dayKey(base + rint(0, 60) * 86_400_000);
    const done = Array.from({ length: rint(0, 12) }, () => CON.dayKey(Date.parse(today + 'T00:00:00Z') - rint(-1, 14) * 86_400_000));
    streaks.push({ done, today, out: CON.streakOf(done, today) });
  }
  w('contracts', { boards, cands, infos, days, streaks });
}

// ── salvage ──
{
  const cases: unknown[] = [];
  const idl = ['sword_copper', 'oak_staff', 'wand_bone', 'grimoire_x', 'tome_y', 'crozier_a', 'book_b', 'helm_gold', 'ring_copper', 'rune_a'];
  const types = ['weapon', 'offhand', 'armor_head', 'ring', 'trinket', 'rune', 'armor_chest'];
  for (let i = 0; i < 400; i++) {
    const item: SAL.SalvageItem = { id: rpick(idl), item_type: rpick(types), rarity: rpick([...SAL.SALVAGE_RARITIES, 'bogus']) };
    if (R() < 0.5) { item.ilvl = rint(0, 90); item.affixes = rint(0, 4); } else if (R() < 0.2) item.affixes = rint(0, 3);
    const level = R() < 0.1 ? rpick([0, -4, 150, 12.7]) : rint(1, 99);
    const seed = rint(1, 1e9);
    cases.push({ item, level, seed, preview: SAL.salvagePreview(item), out: SAL.salvageYield(item, level, mulberry32(seed)) });
  }
  const merges = Array.from({ length: 20 }, () => {
    const lists = Array.from({ length: rint(0, 4) }, () => Array.from({ length: rint(0, 4) }, () => ({ item_id: rpick(['a', 'b', 'c']), quantity: rint(1, 5) })));
    return { lists, out: SAL.mergeGrants(lists) };
  });
  w('salvage', { cases, merges, ids: SAL.salvageItemIds(), gear: ['weapon', 'rune', 'material', 'ring', 'consumable'].map((t) => ({ t, gear: SAL.isSalvageGear(t), rune: SAL.isSalvageRune(t), any: SAL.isSalvageable(t) })) });
}

// ── reforge / gold sinks ──
{
  const costs: unknown[] = [];
  for (const rar of ['common', 'uncommon', 'rare', 'epic', 'legendary', 'relic', 'weird']) for (const aff of [0, 1, 2, 3, 4, 7]) for (const ilvl of [1, 17, 55, 120, 3000, 9.9, 0]) for (const rr of [0, 1, 5, 19, 20, 25, -3, 2.7]) {
    costs.push({ ilvl, rar, aff, rr, out: GS.reforgeCost(ilvl, rar, aff, rr) });
  }
  const ranges: Record<string, [number, number] | null> = {};
  const ilvls = [1, 5, 18, 40, 90];
  for (const a of AFFIXES) for (const l of ilvls) ranges[`${a.id}|${l}`] = affixRange(a.id, l);
  ranges['nope|18'] = null;
  const ids = AFFIXES.map((a) => a.id);
  const problems: unknown[] = [];
  const values: unknown[] = [];
  for (let i = 0; i < 200; i++) {
    const ilvl = rpick(ilvls);
    const affixes = Array.from({ length: rint(0, 3) }, () => { const id = R() < 0.05 ? 'nope' : rpick(ids); const r = ranges[`${id}|${ilvl}`]; return { id, v: r ? rint(r[0], r[1] + 1) : 3 }; });
    const inst = { ilvl, affixes };
    const index = rpick([0, 1, 2, 3, -1, 1.5]);
    problems.push({ inst, index, out: GS.reforgeProblem(inst as never, index) });
    const id = R() < 0.03 ? ids[0] : rpick(ids);
    const seed = rint(1, 1e9);
    values.push({ id, ilvl, seed, out: GS.reforgeValue(id, ilvl, mulberry32(seed)) });
  }
  const empower = Object.keys(BOSSES).map((b) => ({ boss: b, shards: (BOSSES as Record<string, { shards: number }>)[b].shards, can: GS.canEmpower(b), gold: GS.empowerGold(b as never) }));
  const levels = [1, 5, 10, 33, 50, 75, 99].map((l) => ({ l, out: GS.empoweredLevel(l) }));
  w('gold_sink', { costs, ranges, problems, values, empower, levels, can: ['mire', 'prelate', 'x'].map((b) => ({ b, out: GS.canEmpower(b) })), seal: GS.COVENANT_SEAL, EMPOWER: GS.EMPOWER });
}

// ── recipes / craft ──
const recipeOf = (row: (typeof ALL_RECIPE_ROWS)[number]) => ({ id: row[0], name: row[1], skill: row[2], skill_level_required: row[3], result_item_id: row[4], result_quantity: row[5], ingredients: row[6].map(([item_id, quantity]) => ({ item_id, quantity })) });
const slot = (slot_index: number, item_id: string, quantity: number, extra: Partial<InventorySlot> = {}): InventorySlot => {
  const m = itemMeta(item_id);
  return { id: slot_index, slot_index, quantity, equipped: 0, item_id, name: m.name, rarity: m.rarity, item_type: m.type, stat_bonus: null, icon_id: null, sell_value: m.sell, crafted: 0, ...extra } as InventorySlot;
};
{
  const recs = ALL_RECIPE_ROWS.map(recipeOf);
  const qtys = [undefined, null, 0, -1, 1, 5.9, 100, 101, 1e9, NaN, 'abc', '7', '3.5', '', true, Infinity].map((raw) => ({ raw: raw === undefined ? '__undef' : Number.isNaN(raw) ? '__nan' : raw === Infinity ? '__inf' : raw, out: clampCraftQty(raw) }));
  const qty2 = [[7, 3], [250, 3], [0, 5], [1000, 1]].map(([raw, max]) => ({ raw, max, out: clampCraftQty(raw, max) }));
  const mats = ['material_copper_shard', 'ore_copper', 'ingot_copper', 'ingot_iron', 'plank_oak', 'log_oak', 'fish_fillet', 'fish_river', 'ore_tin', 'bone_meal', 'bones_old'];
  const stackFor = (id: string) => ITEMS[id]?.stack ?? (ITEMS[id] && ITEMS[id].type !== 'material' && ITEMS[id].type !== 'rune' ? 1 : 1e12);
  const craft: unknown[] = [];
  for (let i = 0; i < 250; i++) {
    const rec = R() < 0.6 ? rpick(recs.filter((r) => r.ingredients.every((g) => ITEMS[g.item_id]))) : rpick(recs);
    const used = new Set<number>();
    const slots: InventorySlot[] = [];
    const add = (id: string, q: number, eq = false) => {
      let s = rint(0, 47);
      if (R() < 0.1) s = rint(100, 115);
      while (used.has(s)) s = (s + 1) % 120;
      used.add(s);
      slots.push(slot(s, id, q, eq ? { equipped: 1 } : {}));
    };
    for (const g of rec.ingredients) if (R() < 0.9) for (let k = 0; k < rint(1, 3); k++) add(g.item_id, rint(1, 40));
    for (let k = 0; k < rint(0, R() < 0.3 ? 46 : 8); k++) add(rpick(mats), rint(1, 250));
    for (let k = 0; k < rint(0, 3); k++) add(rpick(mats), 1, true);
    const space = Object.fromEntries([rec.result_item_id, ...slots.map((s) => s.item_id), ...rec.ingredients.map((g) => g.item_id)].map((id) => [id, stackFor(id) >= 1e12 ? 1e12 : stackFor(id)]));
    const bagSize = rpick([48, 48, 48, 12]);
    const cap = rpick([100, 100, 7]);
    craft.push({ rec, slots, bagSize, space, cap, out: maxCraftable(rec as never, slots, { bagSize, stackOf: (id) => space[id] ?? 1e12 }, cap) });
    const skill = rint(1, 99);
    const counts: Record<string, number> = {};
    for (const s of slots) counts[s.item_id] = (counts[s.item_id] ?? 0) + s.quantity;
    craft.push({ k: 'has', rec, skill, counts, out: hasSkillAndMaterials(rec as never, skill, (id) => counts[id] ?? 0) });
  }
  w('recipes', { count: recs.length, ids: recs.map((r) => r.id), first: recs.slice(0, 3), last: recs[recs.length - 1], row0: recipeOf(ALL_RECIPE_ROWS[0]), qtys, qty2, craft, bySkill: Object.fromEntries(['mining', 'fishing', 'woodcutting', 'gravedigging', 'alchemy'].map((s) => [s, recs.filter((r) => r.skill === s).map((r) => r.id)])) });
}

// ── bag: addToSlots / sortBagSlots ──
const bagItems = ['ore_copper', 'log_oak', 'bones_old', 'fish_river', 'ring_copper', 'helm_gold', 'flask_hp_minor', 'seed_mourning_moss', 'sword_copper', 'gem_grave_garnet', 'bone_meal', 'plank_oak', 'ingot_iron', 'nonexistent_item', 'staff_oak'];
{
  const adds: unknown[] = [];
  for (let i = 0; i < 300; i++) {
    const used = new Set<number>();
    let slots: InventorySlot[] = [];
    const n = R() < 0.15 ? 48 : rint(0, 30);
    for (let k = 0; k < n; k++) {
      let s = rint(0, 47);
      if (R() < 0.08) s = rint(100, 112);
      while (used.has(s)) s = (s + 1) % 113;
      used.add(s);
      const id = rpick(bagItems);
      const m = ITEMS[id];
      slots.push(slot(s, id, m?.stack ? rint(1, m.stack) : 1, R() < 0.1 ? { equipped: 1 } : {}));
    }
    const drop = { item_id: rpick(bagItems), quantity: R() < 0.3 ? rint(200, 900) : rint(1, 40) };  // rolled-instance drops go through the loot track's decorateSlot hook (see run.gd)
    const res = addToSlots(slots, drop as never);
    adds.push({ slots, drop, out: res });
  }
  const sorts: unknown[] = [];
  for (let i = 0; i < 200; i++) {
    const used = new Set<number>();
    const slots: InventorySlot[] = [];
    for (let k = 0; k < rint(0, 40); k++) {
      let s = rint(0, 47);
      if (R() < 0.1) s = rint(100, 112);
      while (used.has(s)) s = (s + 1) % 113;
      used.add(s);
      const id = rpick(bagItems);
      const m = ITEMS[id];
      const q = m?.stack ? rint(1, m.stack) : 1;
      const extra: Partial<InventorySlot> = {};
      if (R() < 0.1) extra.equipped = 1;
      if (R() < 0.3 && m && m.type !== 'material') { extra.ilvl = rint(1, 60); extra.instance_id = rint(1, 999); }
      if (R() < 0.1) extra.rarity = rpick(['rare', 'epic', 'legendary', 'relic']);
      slots.push(slot(s, id, q, extra));
    }
    const lockedSet = new Set(slots.filter(() => R() < 0.1).map((s) => s.slot_index));
    const withLocks = R() < 0.5;
    const moves = new Map<number, number>();
    const res = sortBagSlots(slots, moves, withLocks ? (s) => lockedSet.has(s.slot_index) : undefined);
    sorts.push({ slots, locked: withLocks ? [...lockedSet] : null, out: res, moves: [...moves] });
  }
  w('bag_add', adds);
  w('bag_sort', sorts);
}

// ── locks / junk / salvage-below-rare ──
{
  const necro = ['necro_a', 'necro_b'];
  const cases: unknown[] = [];
  const gear = ['sword_copper', 'helm_gold', 'ring_copper', 'staff_oak', 'chest_iron', 'ore_copper', 'flask_hp_minor'];
  for (let i = 0; i < 150; i++) {
    const used = new Set<number>();
    const slots: InventorySlot[] = [];
    for (let k = 0; k < rint(0, 40); k++) {
      let s = rint(0, 47);
      if (R() < 0.1) s = rint(100, 112);
      while (used.has(s)) s = (s + 1) % 113;
      used.add(s);
      const id = rpick(gear);
      const extra: Partial<InventorySlot> = { rarity: rpick(['common', 'uncommon', 'rare', 'epic']) as never };
      if (R() < 0.1) extra.equipped = 1;
      if (R() < 0.15) extra.sell_value = 0;
      if (R() < 0.3) (extra as { inst?: unknown }).inst = { id: 1, ilvl: 5, affixes: [{ id: rpick([...necro, 'plain']), v: 1 }] };
      slots.push(slot(s, id, 1, extra));
    }
    const locked = slots.filter(() => R() < 0.15).map((s) => [s.slot_index, s.item_id] as [number, string]);
    if (R() < 0.3 && slots.length) locked.push([slots[0].slot_index, 'stale_item']);
    const keepSet = new Set(slots.filter(() => R() < 0.15).map((s) => s.slot_index));
    const withKeep = R() < 0.5;
    const store = { v: JSON.stringify(locked) };
    const locks = new ItemLocks(3, { getItem: () => store.v, setItem: (_k: string, v: string) => { store.v = v; } } as never);
    // the affix-necro predicate is injected on the Godot side; TS uses the real affixIsNecro, so make necro ids real: use a stub via module? Use only plain results here.
    const keep = withKeep ? (s: InventorySlot) => keepSet.has(s.slot_index) : undefined;
    // TS affixIsNecro is data-driven; to keep fixtures independent of affix tuning we record which slots have an affix whose id starts with necro_ and drop that field from TS input
    const tsSlots = slots.map((s) => { const c = { ...s } as InventorySlot & { inst?: unknown }; if (c.inst) delete c.inst; return c as InventorySlot; });
    const junkIdx = junkSlots(tsSlots, locks, keep).map((s) => s.slot_index);
    const salvIdx = salvageBelowRare(tsSlots, locks, keep).map((s) => s.slot_index);
    // slots WITH necro affix are expected to be excluded in Godot: compute that exclusion here from the same rule
    const hasNecro = (s: InventorySlot & { inst?: { affixes: { id: string }[] } }) => !!s.inst && s.inst.affixes.some((a) => necro.includes(a.id));
    const slotsRaw = slots as (InventorySlot & { inst?: { affixes: { id: string }[] } })[];
    cases.push({
      slots, locked, keep: withKeep ? [...keepSet] : null,
      isLocked: slots.map((s) => locks.isLocked(s)),
      slotsOf: locks.slotsOf(slots),
      junk: junkIdx.filter((i) => !hasNecro(slotsRaw.find((s) => s.slot_index === i)!)),
      salvage: salvIdx.filter((i) => !hasNecro(slotsRaw.find((s) => s.slot_index === i)!)),
    });
  }
  // operation sequences
  const ops: unknown[] = [];
  for (let i = 0; i < 40; i++) {
    const store = { v: '' };
    const locks = new ItemLocks(7, { getItem: () => store.v || null, setItem: (_k: string, v: string) => { store.v = v; } } as never);
    const steps: unknown[] = [];
    let slots: InventorySlot[] = Array.from({ length: 10 }, (_, k) => slot(k, rpick(gear), 1));
    for (let st = 0; st < 12; st++) {
      const kind = rpick(['toggle', 'toggle', 'remap', 'prune']);
      if (kind === 'toggle') {
        const s = rpick(slots);
        steps.push({ kind, slot: s.slot_index, item_id: s.item_id, out: locks.toggle(s) });
      } else if (kind === 'remap') {
        const moves = new Map<number, number>();
        const perm = [...Array(10).keys()].sort(() => R() - 0.5);
        perm.forEach((to, from) => { if (R() < 0.8) moves.set(from, to); });
        locks.remap(moves);
        steps.push({ kind, moves: [...moves] });
        slots = slots.map((s) => ({ ...s, slot_index: moves.get(s.slot_index) ?? s.slot_index }));
      } else {
        slots = slots.map((s) => (R() < 0.3 ? { ...s, item_id: rpick(gear) } : s)).filter(() => R() < 0.9);
        locks.prune(slots);
        steps.push({ kind, slots: slots.map((s) => [s.slot_index, s.item_id]) });
      }
      steps.push({ kind: 'state', locked: slots.map((s) => locks.isLocked(s)), stored: store.v });
    }
    ops.push({ initial: Array.from({ length: 10 }, (_, k) => k), steps });
  }
  w('locks', { cases, ops, key: ['dm_locks_v1_3'] });
}

// ── vault ──
{
  const ids = ['ore_copper', 'log_oak', 'bones_old', 'ring_copper', 'helm_gold', 'sword_copper', 'flask_hp_minor', 'rune_a', 'rune_b', 'fish_river', 'ingot_iron', 'seed_mourning_moss', 'staff_oak', 'bone_meal'];
  const infoTable: Record<string, V.VaultItemInfo> = {};
  for (const id of ids) {
    const m = itemMeta(id);
    infoTable[id] = { maxStack: m.stack ?? (m.type === 'material' || m.type === 'rune' ? 250 : m.type === 'consumable' ? 99 : 1), itemType: ['rune_a', 'rune_b'].includes(id) ? 'rune' : m.type, rarity: m.rarity };
  }
  infoTable['rune_a'].maxStack = 20;
  const info: V.VaultInfo = (id) => infoTable[id] ?? { maxStack: 1, itemType: 'material', rarity: 'common' };
  const mkRows = (size: number, n: number, allowFixed: boolean): V.VaultRow[] => {
    const used = new Set<number>();
    const rows: V.VaultRow[] = [];
    for (let k = 0; k < n; k++) {
      let s = rint(0, size - 1);
      while (used.has(s)) s = (s + 1) % size;
      used.add(s);
      const id = rpick(ids);
      const gear = info(id).maxStack === 1;
      const row: V.VaultRow = { slot: s, itemId: id, qty: gear ? 1 : rint(1, info(id).maxStack) };
      if (gear && R() < 0.5) { row.inst = rint(1, 5000); if (R() < 0.8) row.power = rint(0, 3) * 1000 + rint(1, 80); }
      if (allowFixed && R() < 0.1) row.fixed = true;
      rows.push(row);
    }
    return rows;
  };
  const moves: unknown[] = [];
  for (let i = 0; i < 250; i++) {
    const bag = mkRows(48, rint(0, R() < 0.2 ? 48 : 25), true);
    const vault = mkRows(120, rint(0, R() < 0.2 ? 120 : 70), false);
    const mode = rpick(['deposit', 'withdraw', 'many_m', 'many_a', 'sort', 'grants']);
    const base = { bag, vault, mode };
    if (mode === 'deposit' || mode === 'withdraw') {
      const src = mode === 'deposit' ? bag : vault;
      const slotN = src.length && R() < 0.9 ? rpick(src).slot : rint(0, 47);
      const qty = rpick([undefined, 1, 3, 0, -2, 2.5, 999, NaN]);
      const res = mode === 'deposit' ? V.depositStack(bag, vault, slotN, qty, info) : V.withdrawStack(bag, vault, slotN, qty, info);
      moves.push({ ...base, slot: slotN, qty: qty === undefined ? null : Number.isNaN(qty) ? '__nan' : qty, out: res });
    } else if (mode === 'many_m' || mode === 'many_a') {
      const except = bag.filter(() => R() < 0.15).map((r) => r.slot);
      moves.push({ ...base, except, out: V.depositMany(bag, vault, mode === 'many_m' ? 'materials' : 'all', except, info) });
    } else if (mode === 'sort') {
      moves.push({ ...base, out: V.sortVault(vault, info) });
    } else {
      const grants = Array.from({ length: rint(1, 4) }, () => ({ itemId: rpick(ids), qty: rint(1, 400) }));
      moves.push({ ...base, grants, out: V.addGrants(bag, grants, info) });
    }
  }
  w('vault', { infoTable, moves, consts: { VAULT_SLOTS: V.VAULT_SLOTS, VAULT_TAB_SIZE: V.VAULT_TAB_SIZE } });
}

// ── potion belt ──
{
  const cases: unknown[] = [];
  for (let i = 0; i < 40; i++) {
    const counts: Record<string, number> = {};
    for (const id of PB.HEAL_ORDER) if (R() < 0.4) counts[id] = rint(1, 5);
    cases.push({ k: 'pick', counts, out: PB.healPick((id) => counts[id] ?? 0) });
  }
  for (const hasItem of [false, true]) for (const active of [false, true]) for (const cooling of [false, true]) cases.push({ k: 'state', hasItem, active, cooling, out: PB.beltState({ hasItem, active, cooling }) });
  w('potion_belt', cases);
}
w('consts', { TICK_MS: GR.TICK_MS, LEVEL_CAP: GR.LEVEL_CAP, GATHER_BURST: GR.GATHER_BURST, GATHER_MAX_WINDOW_MS: GR.GATHER_MAX_WINDOW_MS, GATHER_MAX_ACTIONS_PER_HOUR: GR.GATHER_MAX_ACTIONS_PER_HOUR, GATHER_FLUSH_MS: GR.GATHER_FLUSH_MS, GATHER_MAX_BATCH: GR.GATHER_MAX_BATCH, BAG_SLOTS: GR.BAG_SLOTS, MATERIAL_STACK: GR.MATERIAL_STACK, BELT_BASE: GR.BELT_BASE, BELT_KINDS: GR.BELT_KINDS, TOOL_METALS: GR.TOOL_METALS, TOOL_KIND: GR.TOOL_KIND, SKILLS: Object.keys(SKILLS), RICH_YIELD: GR.RICH_YIELD, RICH_RESPAWN: GR.RICH_RESPAWN });
console.log('fixtures written');
