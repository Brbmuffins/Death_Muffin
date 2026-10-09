/**
 * Golden fixtures for godot/rules/gear (run: npx vite-node tools/godot/fixtures-gear.ts).
 * Every expected value is produced by the REAL TS modules (gameplay/gearStats.ts, atlas.ts, setBonuses.ts, content/setBonuses.ts ...).
 * One case per random character + gear set; the cases must run in file order (gearStats keeps a reference-hero cache keyed by discipline id and
 * thrall cap, like the web does, so the order the contexts are judged in is part of the fixture).
 * Output: godot/tests/gear/fixtures/*.json, each {fn, cases:[{in, out}]}.
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { mulberry32 } from '../../src/gameplay/rng';
import { DISCIPLINES, type Discipline, type DisciplineId } from '../../server/rules/content/disciplines';
import { ARMOR_PIECES } from '../../server/rules/content/armorSets';
import { ITEMS } from '../../server/rules/content/items';
import { NECRO_WEAPONS } from '../../server/rules/content/necroWeapons';
import { AFFIXES, AFFIX_GEAR_TYPES, affixAcceptRange } from '../../server/rules/gameplay/affixRules';
import {
  STAT_PRIORITY, compareEquip, gearPower, itemAffixEffects, itemStatEffects, itemVerdict, lookingFor, simulateEquip, statSheet, weakestSlots, effectText,
  type StatContext,
} from '../../src/gameplay/gearStats';
import { atlasSlot, powerGainPct, setOutlook } from '../../src/gameplay/atlas';
import { applySetMods, resolveSetBonuses, setDiffText, setStatus } from '../../src/gameplay/setBonuses';
import { describeEffect, SET_BONUSES } from '../../src/content/setBonuses';
import { itemTypeLabel } from '../../src/ui/gearText';
import type { InventorySlot, Character } from '../../src/net/types';

const OUT = 'godot/tests/gear/fixtures';
mkdirSync(OUT, { recursive: true });
const counts: Record<string, number> = {};
const w = (fn: string, cases: { in: unknown; out: unknown }[]) => {
  writeFileSync(`${OUT}/${fn}.json`, JSON.stringify({ fn, cases }) + '\n');
  counts[fn] = cases.length;
};

const rand = mulberry32(20261005);
const R = (n: number) => Math.floor(rand() * n);
const pick = <T>(a: readonly T[]): T => a[R(a.length)];
const chance = (p: number) => rand() < p;
const range = (lo: number, hi: number) => lo + R(hi - lo + 1);
const J = <T>(x: T): T => JSON.parse(JSON.stringify(x));

// --- random characters, gear and contexts ------------------------------------------------------------------------------------

const STATS = ['stat_str', 'stat_agi', 'stat_int', 'stat_vit'];
const randStats = () => Object.fromEntries(STATS.filter(() => chance(0.5)).map((k) => [k, range(1, 14)]));
const GEAR_IDS = Object.keys(ITEMS).filter((id) => (AFFIX_GEAR_TYPES as readonly string[]).includes(ITEMS[id].type));
const NON_GEAR = Object.keys(ITEMS).filter((id) => ITEMS[id].type === 'material');
const BY_TYPE = (t: string) => GEAR_IDS.filter((id) => ITEMS[id].type === t);
const NECRO_MAIN = NECRO_WEAPONS.filter((x) => x.slot === 'main_hand');
const NECRO_OFF = NECRO_WEAPONS.filter((x) => x.slot === 'off_hand');
const PARTS = ['head', 'chest', 'hands', 'legs', 'feet'];

function inst() {
  if (chance(0.45)) return undefined;
  const ilvl = range(1, 99);
  const groups = new Set<string>();
  const affixes: { id: string; v: number }[] = [];
  for (let i = 0, n = range(1, 3); i < n; i++) {
    const a = pick(AFFIXES);
    if (groups.has(a.group)) continue;
    groups.add(a.group);
    const [lo, hi] = affixAcceptRange(a.id, ilvl)!;
    affixes.push({ id: a.id, v: range(lo, hi) });
  }
  return { id: R(1e6), ilvl, affixes };
}

let rowId = 1;
function row(itemId: string, equipped: 0 | 1, slotIndex: number, over: Partial<InventorySlot> & { stat_bonus?: Record<string, number> | null } = {}): InventorySlot {
  const m = ITEMS[itemId];
  const nw = NECRO_WEAPONS.find((x) => x.id === itemId);
  const r: Record<string, unknown> = {
    id: rowId++, slot_index: slotIndex, quantity: 1, equipped, item_id: itemId, name: m.name, rarity: m.rarity, item_type: m.type,
    stat_bonus: m.offlineStats ?? nw?.stats ?? randStats(), icon_id: null, sell_value: m.sell, crafted: 0, ...over,
  };
  if (chance(0.3)) r.item_equipment_slot = null;
  if (AFFIX_GEAR_TYPES.includes(m.type as never)) { const i = inst(); if (i) r.inst = i; }
  return r as unknown as InventorySlot;
}

function randomSlots(): InventorySlot[] {
  const slots: InventorySlot[] = [];
  let bag = 0;
  const setPieces = chance(0.7) ? ARMOR_PIECES.filter((p) => p.setId === pick(ARMOR_PIECES).setId) : [];
  const part = (p: string) => (setPieces.length && chance(0.85) ? setPieces.find((x) => x.part === p) : undefined) ?? pick(ARMOR_PIECES.filter((x) => x.part === p));
  // worn
  PARTS.forEach((p, i) => { if (chance(0.78)) { const piece = part(p); if (ITEMS[piece.id]) slots.push(row(piece.id, 1, 100 + i, { stat_bonus: piece.stats })); } });
  if (chance(0.75)) { const m = chance(0.8) ? pick(NECRO_MAIN) : null; slots.push(row(m?.id ?? pick(BY_TYPE('weapon')), 1, 105)); }
  if (chance(0.6)) { const o = chance(0.8) ? pick(NECRO_OFF) : null; slots.push(row(o?.id ?? pick(BY_TYPE('offhand')), 1, 106)); }
  if (chance(0.5)) slots.push(row(pick(BY_TYPE('ring')), 1, 107));
  if (chance(0.4)) slots.push(row(pick(BY_TYPE('trinket')), 1, 108));
  // Legion kit rows: worn by the thralls, never by you (but simulateEquip does not know that)
  if (chance(0.4)) slots.push(row(chance(0.5) ? pick(NECRO_MAIN).id : pick(BY_TYPE('weapon')), 1, 120, { equipped_slot: 'kit_weapon' } as never));
  if (chance(0.3)) slots.push(row(pick(ARMOR_PIECES).id, 1, 121, { equipped_slot: 'kit_armor' } as never));
  // bag: gear to compare, some non-gear
  for (let i = 0, n = range(1, 9); i < n; i++) {
    const kind = R(7);
    let id: string;
    if (kind <= 2) { const piece = part(pick(PARTS)); id = piece.id; }
    else if (kind === 3) id = pick(NECRO_MAIN).id;
    else if (kind === 4) id = pick(NECRO_OFF).id;
    else if (kind === 5) id = pick([...BY_TYPE('ring'), ...BY_TYPE('trinket'), ...BY_TYPE('weapon'), ...BY_TYPE('offhand')]);
    else id = pick(NON_GEAR);
    if (!ITEMS[id]) continue;
    slots.push(row(id, 0, bag++));
  }
  return slots;
}

const CHAR_NAMES = ['x'];
function randomCharacter(): Character {
  return { id: 1, class_index: 1, class_name: CHAR_NAMES[0], level: chance(0.04) ? 0 : range(1, 70), experience: 0, gold: 0, stat_str: range(0, 60), stat_agi: range(0, 60), stat_int: range(0, 90), stat_vit: range(0, 80) } as Character;
}

interface Case { character: Character; slots: InventorySlot[]; disc: { id: string; name: string; family: string; mods: Record<string, unknown> }; applied: boolean; damageTier: number; legion?: unknown }

function makeCase(boons: boolean): { ctx: StatContext; c: Case } {
  const id = pick(Object.keys(DISCIPLINES)) as DisciplineId;
  const base = DISCIPLINES[id];
  const character = randomCharacter();
  const slots = randomSlots();
  let mods = { ...base.mods } as Record<string, number | string | boolean>;
  let legion: unknown;
  if (boons) {
    mods.thrallCap = (mods.thrallCap as number) + range(0, 2);
    mods.maxHpMult = (mods.maxHpMult as number) * (1 + range(0, 20) / 100);
    mods.essenceRegenMult = (mods.essenceRegenMult as number) * (1 + range(0, 30) / 100);
    mods.thrallHpMult = (mods.thrallHpMult as number) * (1 + range(0, 25) / 100);
    mods.wardPerThrall = (mods.wardPerThrall as number) + range(0, 4) / 100;
    mods.corpseHeal = (mods.corpseHeal as number) + range(0, 3) / 100;
    if (chance(0.7) && base.family === 'necromancer') {
      const lg = { hpMult: 1, damageMult: 1, speedMult: 1, wardAdd: 0, kit: { hp: range(0, 20) / 100, damage: range(0, 20) / 100, speed: 0, ward: 0 }, reinforce: { tier: range(0, 5), hp: range(0, 30) / 100, damage: range(0, 30) / 100, speed: 0 } };
      mods.thrallHpMult = (mods.thrallHpMult as number) * (1 + lg.kit.hp) * (1 + lg.reinforce.hp);
      mods.thrallDamageMult = (mods.thrallDamageMult as number) * (1 + lg.kit.damage) * (1 + lg.reinforce.damage);
      legion = lg;
    }
  }
  const applied = chance(0.75);
  const plain = { ...base, mods: mods as unknown as Discipline['mods'] } as Discipline;
  const discipline = applied ? ({ ...plain, mods: applySetMods(plain.mods, resolveSetBonuses(slots).totals) } as Discipline) : plain;
  const damageTier = range(0, 25);
  const ctx: StatContext = { character, slots, discipline, damageTier, ...(legion ? { legion: legion as never } : {}) };
  return { ctx, c: { character, slots, disc: { id: base.id, name: base.name, family: base.family, mods: J(plain.mods) }, applied, damageTier, legion } };
}

const idx = (list: readonly InventorySlot[]) => list.map((s) => s.slot_index);
const fixVerdict = (v: ReturnType<typeof itemVerdict>) => (v ? { ...v, replaced: idx(v.replaced) } : null);
const fixCompare = (c: ReturnType<typeof compareEquip>) => (c ? { ...c, replaced: idx(c.replaced) } : null);

function evaluate(ctx: StatContext) {
  const bag = ctx.slots.filter((s) => !s.equipped && s.slot_index < 120);
  const worn = ctx.slots.filter((s) => s.equipped && s.slot_index < 120);
  const verdicts: Record<string, unknown> = {};
  for (const s of ctx.slots) verdicts[`${s.slot_index}:${s.id}`] = fixVerdict(itemVerdict(ctx, s));
  const compares: Record<string, unknown> = {};
  for (const s of bag.slice(0, 5)) compares[`${s.slot_index}:${s.id}`] = fixCompare(compareEquip(ctx, s));
  const statFx: Record<string, unknown> = {};
  const affFx: Record<string, unknown> = {};
  for (const s of [...bag.slice(0, 3), ...worn.slice(0, 2)]) {
    statFx[`${s.slot_index}:${s.id}`] = itemStatEffects(ctx, s).map((e) => ({ ...e, text: effectText(e.lines) }));
    affFx[`${s.slot_index}:${s.id}`] = itemAffixEffects(ctx, s).map((e) => ({ ...e, text: e.text, fx: effectText(e.lines) }));
  }
  const sims: Record<string, unknown> = {};
  for (const s of bag.slice(0, 4)) {
    const sim = simulateEquip(ctx.slots, s.slot_index);
    sims[`${s.slot_index}:${s.id}`] = { slots: idx(sim.slots.filter((x) => x.equipped)), displaced: idx(sim.displaced), gearSlot: sim.gearSlot ?? '' };
  }
  const setIds = ARMOR_PIECES.map((p) => p.id);
  const atlasIds = [pick(setIds), pick(setIds), pick(setIds), pick(setIds), pick(GEAR_IDS), pick(GEAR_IDS)];
  const atlas: Record<string, unknown> = {};
  for (const id of atlasIds) {
    const slot = atlasSlot(id);
    atlas[id] = {
      outlook: setOutlook(ctx, id),
      verdict: slot ? fixVerdict(itemVerdict({ ...ctx, slots: [...ctx.slots, slot] }, slot)) : null,
      gain: powerGainPct(ctx, id),
    };
  }
  return {
    sheet: statSheet(ctx), looking: lookingFor(ctx), weakest: weakestSlots(ctx, 9), power: gearPower(ctx),
    verdicts, compares, statFx, affFx, sims, atlas, sets: resolveSetBonuses(ctx.slots).sets.map((s) => ({ setId: s.setId, worn: s.worn, missing: s.missing, lines: s.bonuses.map((b) => b.lines) })),
  };
}

// STAT_PRIORITY is computed at module load: the cache is primed with the bare disciplines before anything else (the Godot side does the same).
const cases: { in: unknown; out: unknown }[] = [];
for (let i = 0; i < 160; i++) {
  const { ctx, c } = makeCase(i >= 90);
  cases.push({ in: J(c), out: J(evaluate(ctx)) });
}
w('context', cases);

// set text: every bonus line, every set at every worn count
const setCases: { in: unknown; out: unknown }[] = [];
for (const [setId, bonuses] of Object.entries(SET_BONUSES)) {
  for (const b of bonuses) setCases.push({ in: J(b.effect), out: describeEffect(b.effect) });
  const parts = ['head', 'chest', 'hands', 'legs', 'feet'] as const;
  for (let n = 0; n <= 5; n++) setCases.push({ in: { setId, parts: parts.slice(0, n) }, out: J(setStatus(setId, parts.slice(0, n) as never)) });
}
w('set_status', setCases);
w('set_diff_text', [
  { in: { gained: [{ setName: 'A', pieces: 2 }, { setName: 'A', pieces: 4 }, { setName: 'B', pieces: 2 }], lost: [] }, out: setDiffText({ gained: [{ setName: 'A', pieces: 2 }, { setName: 'A', pieces: 4 }, { setName: 'B', pieces: 2 }], lost: [] }) },
  { in: { gained: [{ setName: 'A', pieces: 5 }], lost: [{ setName: 'C', pieces: 2 }, { setName: 'C', pieces: 4 }] }, out: setDiffText({ gained: [{ setName: 'A', pieces: 5 }], lost: [{ setName: 'C', pieces: 2 }, { setName: 'C', pieces: 4 }] }) },
  { in: { gained: [], lost: [] }, out: '' },
] as never);

// item type labels
const labelIds = Object.keys(ITEMS);
w('type_label', labelIds.map((id) => ({ in: { item_id: id, item_type: ITEMS[id].type }, out: itemTypeLabel({ item_id: id, item_type: ITEMS[id].type } as never) })));

// priority table as the web computed it
w('stat_priority', [{ in: null, out: J(STAT_PRIORITY) }]);

// JS formatting helpers (toFixed ties, number printing, locale grouping)
const fmtCases: { in: unknown; out: unknown }[] = [];
const tieValues = [-0.0004, -0.5, -2.5, -0.049, 0.5, 1.5, 2.5, 0.25, 0.75, 1.25, 2.125, 0.125, 0.375, 10.5, 99.95, 0.05, 0.15, 0.35, 1.005, 12.345, 100, 0, 3.0000001];
for (const x of tieValues) for (const d of [0, 1, 2, 3]) fmtCases.push({ in: { x, d }, out: { fixed: x.toFixed(d), plus: String(+x.toFixed(d)) } });
for (let i = 0; i < 300; i++) { const x = (rand() - 0.2) * 2000; const d = R(4); fmtCases.push({ in: { x, d }, out: { fixed: x.toFixed(d), plus: String(+x.toFixed(d)) } }); }
w('js_fmt', fmtCases);
w('locale', [0, 1, 999, 1000, 1234, 12345, 123456, 1234567, 1.5, 1234.5678].map((x) => ({ in: x, out: x.toLocaleString() })));

console.log(counts);
