import { AREAS, AREA_ORDER, type AreaId } from '../content/areas';
import { BOSSES, BOSS_IDS, type BossId } from '../content/bosses';
import { DISCIPLINES, type DisciplineId } from '../content/disciplines';
import { ENEMIES, type EnemyId } from '../content/enemies';
import { EQUIP_SLOTS, equipSlotOf, type EquipSlot } from '../content/gear';
import { ITEMS } from '../content/items';
import { AREA_REAGENT_DROPS, BOSS_ICHOR, ELITE_REAGENT_MULT, ENEMY_REAGENT_DROPS } from '../content/reagents';
import { AREA_RUNE_POOL, BOSS_REPEAT_RUNE_CHANCE, BOSS_RUNE_POOL, ELITE_RUNE_CHANCE, RUNES, RUNE_WEIGHT, SURGE_RUNE_CHANCE, type RuneId } from '../content/runes';
import { ARMOR_PIECES, ARMOR_BY_ID } from '../content/armorSets';
import { LEGENDARY_BOSS_AREAS, LEGENDARY_DROP, legendaryBossChance, LEGENDARY_SETS, LEGENDARY_SET_IDS, legendaryItemId, legendarySetFor, type LegendaryPart } from '../content/legendarySets';
import { NECRO_TIER_INFO, NECRO_WEAPONS } from '../content/necroWeapons';
import { SET_BONUSES, SET_NAMES, describeEffect } from '../content/setBonuses';
import { SEEDS } from '../content/gardening';
import { CAPES, GARDEN_PET_CHANCE, PETS, PET_CHANCE, type CapeDef } from '../content/cosmetics';
import { CHEST_KILLS, FLOOR_DROP_CHANCE, DEPTHS, chestDrops, chestRuneChance, chestRunePool, depthLootArea, hasChest } from '../content/depths';
import { ALL_RECIPE_ROWS } from '../content/recipes';
import { BREWS } from '../content/brews';
import { milestoneActive, waveModifiers } from '../content/upgrades';
import { DIFFICULTIES } from '../content/difficulty';
import { NODES, SKILLS, type SkillId } from './gatheringRules';
import { KILL_LOOT } from './loot';
import { AFFIX_GEAR_TYPES, ILVL_MAX, MAX_AFFIXES, itemLevelFor, rollAffixCount, type DropSource as AffixSource } from './affixRules';
import { salvagePreview } from './salvageRules';
import { gearPower, simulateEquip, RECOMMENDED_WEAPONS, type StatContext } from './gearStats';
import type { Character, InventorySlot, ItemType, Rarity } from '../net/types';

/**
 * The Gear Atlas's data (docs/LOOT-TABLES.md is generated from it; ui/AtlasPanel.ts draws it): for every item, where it comes from
 * and how often, what makes it, what it makes, what salvaging pays, how to upgrade it and how well it suits each discipline.
 *
 * Nothing here is a number of its own. Every chance is computed from the same tables and constants the rolls read (loot.ts,
 * areas.ts, runes.ts, reagents.ts, legendarySets.ts, depths.ts, gatheringRules.ts, salvageRules.ts, affixRules.ts), and the fit is
 * the existing gear score (gearStats.gearPower), so a change to any of them moves the Atlas with it. Unit tests (atlas.test.ts) roll
 * the real functions a few hundred thousand times and check the Atlas against them.
 *
 * Chances are "per event, at default settings": Medium difficulty, Wave Speed tier 0, no fortune tonic. See SCALING_NOTES.
 * Pure data and cached: nothing runs until the first call to getAtlas().
 */

export type SourceKind = 'kill' | 'elite' | 'surge' | 'boss' | 'first_kill' | 'depths' | 'gather' | 'garden' | 'salvage';

export interface DropSource {
  kind: SourceKind;
  /** area id, boss id, `depths:<from>`, node id, ... (what the Area tab groups by). */
  placeId: string;
  /** Where, in words: "The Hollow Graves", "The Gravedigger King", "Coffin-Oak". */
  place: string;
  /** What has to happen: "Ordinary kill", "Elite kill", "Boss kill", "Chop (Woodcutting 1)". */
  event: string;
  /** Chance per event of getting at least one (0..1). */
  chance: number;
  /** Quantity when it drops. */
  qty: [number, number];
  /** The area whose level sets the item level of a gear drop from here. */
  area?: AreaId;
  /** What the drop is rolled as (item level and affix odds). */
  ilvlSource?: AffixSource;
  /** One short clause: "3 rolls", "the first kill only". */
  note?: string;
}

export interface RecipeInfo {
  id: string;
  name: string;
  profession: string;
  level: number;
  station: string;
  result: string;
  qty: number;
  ings: { item: string; qty: number }[];
}

export interface AtlasItem {
  id: string;
  name: string;
  type: ItemType;
  rarity: Rarity;
  slot: EquipSlot | null;
  stats: Record<string, number>;
  lore?: string;
  icon?: string;
  /** Rolls item level and affixes (gear, not materials). */
  gear: boolean;
  setId?: string;
  /** Necromancer weapon kind (staff, scythe, ...) when it is one of the weapon line. */
  weaponKind?: string;
  /** The nearest ground's level (or the weapon tier's): a rough "when can I have this". */
  level: number;
}

export interface Place {
  id: string;
  name: string;
  kind: 'area' | 'boss' | 'depths' | 'gather';
  level: number;
  /** Every item with a source here, best chance first. */
  items: string[];
}

export interface SetInfo {
  id: string;
  name: string;
  collection: 1 | 2 | 3;
  disciplineId: string;
  pieces: string[];
  bonuses: { pieces: number; name?: string; lines: string[] }[];
}

export interface Atlas {
  items: Map<string, AtlasItem>;
  /** Drop sources by item, best chance first (legendary pieces: see sourcesFor). */
  sources: Map<string, DropSource[]>;
  /** Recipes by what they make / by what they eat. */
  madeBy: Map<string, RecipeInfo[]>;
  usedIn: Map<string, RecipeInfo[]>;
  places: Place[];
  sets: SetInfo[];
}

const GEAR_TYPES: readonly string[] = AFFIX_GEAR_TYPES;

/** The depths bands: [first floor, last floor or Infinity, the hunting ground whose table the floor drops from]. */
export function depthBands(): { from: number; to: number; area: AreaId }[] {
  const bands: { from: number; to: number; area: AreaId }[] = [];
  for (let d = 1; d <= 200; d++) {
    const area = depthLootArea(d);
    const last = bands[bands.length - 1];
    if (last && last.area === area) last.to = d;
    else bands.push({ from: d, to: d, area });
  }
  bands[bands.length - 1].to = Infinity;
  return bands;
}

const bandLabel = (b: { from: number; to: number }) => (b.to === Infinity ? `floors ${b.from}+` : b.from === b.to ? `floor ${b.from}` : `floors ${b.from}-${b.to}`);

/** Where a recipe is made, in words. */
export function stationOf(r: { id: string; profession: string }): string {
  if (r.id.startsWith('mill_')) return 'Sawpit (Sexton’s Acre) or Workbench';
  if (r.id.startsWith('cook_')) return 'Cooking Fire (Sexton’s Acre) or Workbench';
  if (r.id.startsWith('grind_')) return 'Bone Kiln (Sexton’s Acre) or Workbench';
  if (r.profession === 'alchemy') return 'Great Cauldron (Alchemist’s Wing)';
  if (r.profession === 'woodcutting') return 'Workbench or Sawpit';
  if (r.profession === 'mining' || r.profession === 'gravedigging') return 'Workbench or Bone Kiln';
  return 'Workbench';
}

export const skillName = (profession: string): string => SKILLS[profession as SkillId]?.name ?? profession;

/** "0.35%", "12%", "100%": three significant digits at the small end. */
export function fmtChance(p: number): string {
  const v = p * 100;
  if (v >= 99.995) return '100%';
  const s = v >= 10 ? v.toFixed(1) : v >= 1 ? v.toFixed(2) : v >= 0.1 ? v.toFixed(2) : v.toFixed(3);
  return `${s.replace(/\.?0+$/, '')}%`;
}
/** "1 in 250" for a chance per event (empty at 5% and up, where it adds nothing). */
export const oneIn = (p: number): string => (p > 0 && p < 0.05 ? `1 in ${Math.round(1 / p).toLocaleString('en-US')}` : '');
export const fmtQty = (q: [number, number]): string => (q[0] === q[1] ? `${q[0]}` : `${q[0]}-${q[1]}`);

// --- Scaling notes (the numbers behind "what moves these percentages") -------------------------------------------------------------

export const SCALING_NOTES: string[] = (() => {
  const w1 = waveModifiers(1).itemChanceMult - 1;
  const fortune = Object.entries(BREWS).filter(([, b]) => b.effects.some((e) => e.kind === 'fortune')).map(([id, b]) => `${ITEMS[id]?.name ?? id} (+${Math.round(b.effects.find((e) => e.kind === 'fortune')!.value * 100)}%)`);
  const diffs = Object.values(DIFFICULTIES);
  let nightfall = 0;
  for (let t = 1; t <= 60 && !nightfall; t++) if (milestoneActive('nightfall', t)) nightfall = t;
  return [
    `Ordinary kills roll an area item at ${KILL_LOOT.itemChanceMult}x the area's item chance (stacks of materials are x${KILL_LOOT.materialQtyMult}); elites roll at 6x, capped at 100%.`,
    `Wave Speed tier raises the item chance of kills and the elite rune chance by +${+(w1 * 100).toFixed(0)}% per tier${nightfall ? ` (and +${Math.round((waveModifiers(nightfall).itemChanceMult - (1 + w1 * nightfall)) * 100)}% more from tier ${nightfall}, the Nightfall milestone)` : ''}.`,
    `A fortune tonic multiplies the item chance of kills, reagent drops and the elite rune chance${fortune.length ? `: ${fortune.join(', ')}` : ''}. It does not change boss spoils, Grave Surge offerings or legendary odds.`,
    `Difficulty changes gold and experience and how often elites appear (${diffs.map((d) => `${d.name} ${d.eliteBonus >= 0 ? '+' : ''}${+(d.eliteBonus * 100).toFixed(1)} points`).join(', ')} on every area's elite chance), not what a kill drops.`,
    `Reagent drops are a separate roll per kill, ${ELITE_REAGENT_MULT}x as likely from an elite. Rune and legendary rolls are separate again.`,
    `Bosses roll the area table three times and always leave their ichor; a legendary piece is a ${+(LEGENDARY_DROP.bossChance * 100).toFixed(2)}% roll per boss kill (${+(LEGENDARY_DROP.starterBossChance * 100).toFixed(2)}% for the Gravedigger King).`,
  ];
})();

// --- Building the atlas ----------------------------------------------------------------------------------------------------------

let cache: Atlas | null = null;

const isMaterialId = (id: string) => ITEMS[id]?.type === 'material';
const levelOf = (area: AreaId) => AREAS[area].level;

/** Share of each entry of an area's weighted loot table (a repeated item adds up). */
export function tableShares(area: AreaId): Map<string, number> {
  const loot = AREAS[area].loot;
  const total = loot.reduce((n, e) => n + e.weight, 0);
  const out = new Map<string, number>();
  for (const e of loot) out.set(e.item, (out.get(e.item) ?? 0) + e.weight / total);
  return out;
}

/** Share of each rune in a pool, by pickRune's weights. */
function runeShares(pool: readonly RuneId[]): Map<RuneId, number> {
  const w = pool.map((id) => RUNE_WEIGHT[RUNES[id].rarity]);
  const total = w.reduce((a, b) => a + b, 0) || 1;
  const out = new Map<RuneId, number>();
  pool.forEach((id, i) => out.set(id, (out.get(id) ?? 0) + w[i] / total));
  return out;
}

/** A boss's first-kill item: rollFirstKillItem draws until a rare or epic, up to 30 tries, then falls back. Exact odds. */
function firstKillShares(area: AreaId): Map<string, number> {
  const shares = tableShares(area);
  const eligible = [...shares].filter(([id]) => ITEMS[id]?.rarity === 'rare' || ITEMS[id]?.rarity === 'epic');
  const q = eligible.reduce((n, [, s]) => n + s, 0);
  const out = new Map<string, number>();
  const tail = Math.pow(1 - q, 30);
  for (const [id, s] of eligible) out.set(id, (q > 0 ? (s / q) * (1 - tail) : 0));
  // After 30 misses: a rare gear piece of the table, uniformly, or the historical rare helm.
  const rares = AREAS[area].loot.map((e) => e.item).filter((id) => ITEMS[id] && ITEMS[id].type !== 'material' && (ITEMS[id].rarity === 'rare' || ITEMS[id].rarity === 'epic'));
  if (tail > 0) {
    const pool = rares.length ? rares : ['helm_gold'];
    for (const id of pool) out.set(id, (out.get(id) ?? 0) + tail / pool.length);
  }
  return out;
}

function buildItems(): Map<string, AtlasItem> {
  const out = new Map<string, AtlasItem>();
  for (const [id, m] of Object.entries(ITEMS)) {
    const slot = equipSlotOf({ item_type: m.type, equipped_slot: null, item_equipment_slot: null });
    const weapon = NECRO_WEAPONS.find((w) => w.id === id);
    const armor = ARMOR_BY_ID[id];
    out.set(id, {
      id, name: m.name, type: m.type, rarity: m.rarity, slot, stats: m.offlineStats ?? {}, lore: m.lore, icon: m.icon,
      gear: GEAR_TYPES.includes(m.type), setId: armor?.setId, weaponKind: weapon?.kind, level: 1,
    });
  }
  return out;
}

function buildSources(): Map<string, DropSource[]> {
  const sources = new Map<string, DropSource[]>();
  const add = (id: string, s: DropSource) => {
    const list = sources.get(id) ?? [];
    // One source per (place, event): a repeated table entry already adds up in tableShares.
    list.push(s);
    sources.set(id, list);
  };
  const mq = (id: string, mult = 1): [number, number] => (isMaterialId(id) ? [1 * mult, 2 * mult] : [1, 1]);

  // Hunting grounds: ordinary kills, elites, Grave Surges.
  for (const areaId of AREA_ORDER) {
    const a = AREAS[areaId];
    if (!a.loot.length) continue;
    const pOrdinary = Math.min(1, a.itemChance * KILL_LOOT.itemChanceMult);
    const pElite = Math.min(1, a.itemChance * 6);
    const pool = AREA_RUNE_POOL[areaId];
    for (const [id, share] of tableShares(areaId)) {
      add(id, { kind: 'kill', placeId: areaId, place: a.name, event: 'Ordinary kill', chance: pOrdinary * share, qty: mq(id, KILL_LOOT.materialQtyMult), area: areaId, ilvlSource: 'elite', note: 'gear rolls at elite quality' });
      add(id, { kind: 'elite', placeId: areaId, place: a.name, event: 'Elite kill', chance: pElite * share, qty: mq(id), area: areaId, ilvlSource: 'elite' });
      add(id, { kind: 'surge', placeId: areaId, place: a.name, event: 'Grave Surge offering', chance: (pool?.length ? 1 - SURGE_RUNE_CHANCE : 1) * share, qty: mq(id), area: areaId, ilvlSource: 'surge' });
    }
    // Reagents of the ground.
    for (const d of AREA_REAGENT_DROPS[areaId] ?? []) {
      add(d.item, { kind: 'kill', placeId: areaId, place: a.name, event: 'Ordinary kill', chance: Math.min(1, d.chance), qty: d.qty, area: areaId });
      add(d.item, { kind: 'elite', placeId: areaId, place: a.name, event: 'Elite kill', chance: Math.min(1, d.chance * ELITE_REAGENT_MULT), qty: d.qty, area: areaId });
    }
    // Runes: elites and surges, from the area's pool.
    if (pool?.length) {
      for (const [id, share] of runeShares(pool)) {
        add(id, { kind: 'elite', placeId: areaId, place: a.name, event: 'Elite kill', chance: ELITE_RUNE_CHANCE * share, qty: [1, 1], area: areaId });
        add(id, { kind: 'surge', placeId: areaId, place: a.name, event: 'Grave Surge offering', chance: SURGE_RUNE_CHANCE * share, qty: [1, 1], area: areaId });
      }
    }
  }

  // Spirits shed ectoplasm wherever they walk.
  for (const [enemy, drops] of Object.entries(ENEMY_REAGENT_DROPS) as [EnemyId, NonNullable<(typeof ENEMY_REAGENT_DROPS)[EnemyId]>][]) {
    const where = AREA_ORDER.filter((id) => AREAS[id].enemies.some((e) => e.id === enemy)).map((id) => AREAS[id].name);
    for (const d of drops) {
      add(d.item, { kind: 'kill', placeId: `enemy:${enemy}`, place: ENEMIES[enemy].name, event: `${ENEMIES[enemy].name} kill`, chance: d.chance, qty: d.qty, note: where.length ? `walks ${where.join(', ')}` : undefined });
      add(d.item, { kind: 'elite', placeId: `enemy:${enemy}`, place: ENEMIES[enemy].name, event: `Elite ${ENEMIES[enemy].name} kill`, chance: Math.min(1, d.chance * ELITE_REAGENT_MULT), qty: d.qty });
    }
  }

  // Bosses: three rolls of the area table, a guaranteed ichor, a rune, the first-kill trophy.
  for (const b of BOSS_IDS) {
    const def = BOSSES[b];
    const area = def.area;
    for (const [id, share] of tableShares(area)) {
      add(id, { kind: 'boss', placeId: b, place: def.name, event: 'Boss kill', chance: 1 - Math.pow(1 - share, 3), qty: mq(id), area, ilvlSource: 'boss', note: '3 rolls of the area table' });
    }
    if (b !== 'prelate') {
      for (const [id, p] of firstKillShares(area)) add(id, { kind: 'first_kill', placeId: b, place: def.name, event: 'First kill (once per character)', chance: p, qty: [1, 1], area, ilvlSource: 'first_kill', note: 'a guaranteed rare or better' });
    }
    add(BOSS_ICHOR[b], { kind: 'boss', placeId: b, place: def.name, event: 'Boss kill', chance: 1, qty: [1, 1], area, note: 'always' });
    const pool = BOSS_RUNE_POOL[b];
    if (pool?.length) {
      const sure = b === 'prelate';
      for (const [id, share] of runeShares(pool)) {
        add(id, { kind: 'boss', placeId: b, place: def.name, event: sure ? 'Boss kill' : 'Boss kill (repeat)', chance: (sure ? 1 : BOSS_REPEAT_RUNE_CHANCE) * share, qty: [1, 1], area, note: sure ? 'always leaves a rune' : `${Math.round(BOSS_REPEAT_RUNE_CHANCE * 100)}% to leave a rune` });
        if (!sure) add(id, { kind: 'first_kill', placeId: b, place: def.name, event: 'First kill (once per character)', chance: share, qty: [1, 1], area, note: 'always leaves a rune' });
      }
    }
  }

  // The Catacomb Depths: floors drop from the hunting ground whose gear matches the depth.
  for (const band of depthBands()) {
    const area = band.area;
    const a = AREAS[area];
    const placeId = `depths:${band.from}`;
    const place = `Catacomb Depths, ${bandLabel(band)}`;
    const pOrdinary = Math.min(1, a.itemChance * KILL_LOOT.itemChanceMult);
    const pElite = Math.min(1, a.itemChance * 6);
    const shares = tableShares(area);
    const firstChest = hasChest(band.from) ? band.from : Math.ceil(band.from / DEPTHS.chestEvery) * DEPTHS.chestEvery;
    const chestHere = firstChest <= band.to && firstChest > 0;
    const gearTotal = [...shares].reduce((n, [id, s]) => n + (GEAR_TYPES.includes(ITEMS[id]?.type ?? '') ? s : 0), 0);
    const rolls = chestDrops(firstChest) - 1;
    for (const [id, share] of shares) {
      const dq = mq(id);
      add(id, { kind: 'depths', placeId, place, event: 'Ordinary kill', chance: pOrdinary * share, qty: mq(id, KILL_LOOT.materialQtyMult), area, ilvlSource: 'elite' });
      add(id, { kind: 'depths', placeId, place, event: 'Elite kill', chance: pElite * share, qty: dq, area, ilvlSource: 'elite' });
      add(id, { kind: 'depths', placeId, place, event: 'Floor cleared (stair)', chance: FLOOR_DROP_CHANCE * share, qty: dq, area, ilvlSource: 'elite', note: `${Math.round(FLOOR_DROP_CHANCE * 100)}% chance of one item` });
      if (chestHere) {
        // The first drop of a chest is gear (rolled until the table yields some); the rest are plain rolls of the table.
        const isGear = GEAR_TYPES.includes(ITEMS[id]?.type ?? '');
        const g = isGear && gearTotal > 0 ? share / gearTotal : 0;
        add(id, { kind: 'depths', placeId, place, event: `Chest (floor ${firstChest})`, chance: 1 - (1 - g) * Math.pow(1 - share, rolls), qty: dq, area, ilvlSource: 'elite', note: `${rolls + 1} drops, the first is gear` });
      }
    }
    for (const d of AREA_REAGENT_DROPS[area] ?? []) {
      add(d.item, { kind: 'depths', placeId, place, event: 'Ordinary kill', chance: Math.min(1, d.chance), qty: d.qty, area });
      add(d.item, { kind: 'depths', placeId, place, event: 'Elite kill', chance: Math.min(1, d.chance * ELITE_REAGENT_MULT), qty: d.qty, area });
    }
    const pool = AREA_RUNE_POOL[area];
    if (pool?.length) for (const [id, share] of runeShares(pool)) add(id, { kind: 'depths', placeId, place, event: 'Elite kill', chance: ELITE_RUNE_CHANCE * share, qty: [1, 1], area });
    if (chestHere) {
      for (const [id, share] of runeShares(chestRunePool(firstChest))) add(id, { kind: 'depths', placeId, place, event: `Chest (floor ${firstChest})`, chance: chestRuneChance(firstChest) * share, qty: [1, 1], area, note: `${fmtChance(chestRuneChance(firstChest))} to hold a rune; rises +2% per chest` });
    }
  }

  // Gathering nodes (chance per successful action).
  for (const n of Object.values(NODES)) {
    const event = `${SKILLS[n.skill].verb} (${SKILLS[n.skill].name} ${n.level})`;
    add(n.item, { kind: 'gather', placeId: `node:${n.id}`, place: n.name, event, chance: 1, qty: [1, 1], note: 'every successful action' });
    for (const e of n.extras) add(e.item, { kind: 'gather', placeId: `node:${n.id}`, place: n.name, event, chance: e.chance, qty: e.qty ?? [1, 1], note: 'a rare find on a successful action' });
  }

  // Grave Gardening harvests.
  for (const s of SEEDS) {
    add(s.harvest, { kind: 'garden', placeId: `seed:${s.id}`, place: 'Mourning Bed (Sexton’s Acre)', event: `Harvest ${ITEMS[s.id]?.name ?? s.id} (Gardening ${s.level}, ${s.growMin} min)`, chance: 1, qty: s.yields, note: `${Math.round(s.seedBack * 100)}% to give a seed back` });
  }

  // Pets: the Shroud Moth's charm also turns up when a Mourning Bed is harvested.
  const moth = PETS.find((p) => p.skill === 'gardening');
  if (moth) add(moth.charm, { kind: 'garden', placeId: 'garden:charm', place: 'Mourning Bed (Sexton\u2019s Acre)', event: 'Harvest a plot', chance: GARDEN_PET_CHANCE, qty: [1, 1], note: 'one charm in about 35 harvests' });

  // Salvage: what the Bone Grinder pays, by rarity (metal gear gives ingots; staffs, wands and books give planks).
  for (const rarity of ['common', 'uncommon', 'rare', 'epic', 'legendary'] as Rarity[]) {
    const metal = salvagePreview({ id: 'sword', item_type: 'weapon', rarity });
    const wood = salvagePreview({ id: 'staff', item_type: 'weapon', rarity });
    const event = `Salvage ${rarity} gear`;
    for (const [list, label] of [[metal.materials, 'metal gear'], [wood.materials, 'staffs, wands and books']] as const) {
      for (const id of list) add(id, { kind: 'salvage', placeId: 'salvage', place: 'Bone Grinder (Sexton’s Acre)', event, chance: 1 / list.length, qty: metal.materialQty, note: label });
    }
    for (const r of metal.reagents) add(r.id, { kind: 'salvage', placeId: 'salvage', place: 'Bone Grinder (Sexton’s Acre)', event, chance: r.chance, qty: r.qty });
  }

  for (const list of sources.values()) list.sort((x, y) => y.chance - x.chance);
  return sources;
}

function buildRecipes(): { madeBy: Map<string, RecipeInfo[]>; usedIn: Map<string, RecipeInfo[]> } {
  const madeBy = new Map<string, RecipeInfo[]>();
  const usedIn = new Map<string, RecipeInfo[]>();
  for (const [id, name, profession, level, result, qty, ings] of ALL_RECIPE_ROWS) {
    const r: RecipeInfo = { id, name, profession, level, station: stationOf({ id, profession }), result, qty, ings: ings.map(([item, n]) => ({ item, qty: n })) };
    (madeBy.get(result) ?? madeBy.set(result, []).get(result)!).push(r);
    for (const i of r.ings) (usedIn.get(i.item) ?? usedIn.set(i.item, []).get(i.item)!).push(r);
  }
  return { madeBy, usedIn };
}

function buildSets(): SetInfo[] {
  const ids = [...new Set(ARMOR_PIECES.map((p) => p.setId))];
  return ids.map((id) => {
    const pieces = ARMOR_PIECES.filter((p) => p.setId === id);
    return {
      id, name: SET_NAMES[id] ?? id, collection: pieces[0].collection, disciplineId: pieces[0].disciplineId,
      pieces: pieces.map((p) => p.id),
      bonuses: (SET_BONUSES[id] ?? []).map((b) => ({ pieces: b.pieces, name: b.name, lines: describeEffect(b.effect) })),
    };
  });
}

export function getAtlas(): Atlas {
  if (cache) return cache;
  const items = buildItems();
  const sources = buildSources();
  const { madeBy, usedIn } = buildRecipes();
  const sets = buildSets();

  // The level of the nearest ground that drops it (or its weapon tier / recipe), for "within reach" filters.
  for (const [id, it] of items) {
    const lv = (sources.get(id) ?? []).filter((s) => s.area).map((s) => levelOf(s.area!));
    const w = NECRO_WEAPONS.find((x) => x.id === id);
    const legendary = ARMOR_BY_ID[id]?.collection === 3 ? Math.min(...LEGENDARY_BOSS_AREAS.map(levelOf)) : null;
    it.level = legendary ?? (lv.length ? Math.min(...lv) : w ? NECRO_TIER_INFO[w.tier].level : (madeBy.get(id) ?? []).length ? Math.max(1, Math.min(...madeBy.get(id)!.map((r) => r.level))) : 1);
  }

  // Places for the Area tab: grounds, bosses, Depths bands, gathering nodes.
  const byPlace = new Map<string, { name: string; kind: Place['kind']; level: number; items: Map<string, number> }>();
  const put = (placeId: string, name: string, kind: Place['kind'], level: number, item: string, chance: number) => {
    const p = byPlace.get(placeId) ?? byPlace.set(placeId, { name, kind, level, items: new Map() }).get(placeId)!;
    p.items.set(item, Math.max(p.items.get(item) ?? 0, chance));
  };
  for (const [item, list] of sources) {
    for (const s of list) {
      if (s.kind === 'salvage' || s.kind === 'garden') continue;
      if (s.placeId.startsWith('enemy:')) continue;
      const kind: Place['kind'] = s.kind === 'depths' ? 'depths' : s.kind === 'gather' ? 'gather' : s.kind === 'boss' || s.kind === 'first_kill' ? 'boss' : 'area';
      const level = s.area ? levelOf(s.area) : 1;
      put(s.placeId, s.place, kind, level, item, s.chance);
    }
  }
  const order = (p: Place) => (p.kind === 'area' ? 0 : p.kind === 'boss' ? 1 : p.kind === 'depths' ? 2 : 3);
  const places: Place[] = [...byPlace].map(([id, p]) => ({ id, name: p.name, kind: p.kind, level: p.level, items: [...p.items].sort((a, b) => b[1] - a[1]).map(([i]) => i) }));
  places.sort((a, b) => order(a) - order(b) || a.level - b.level || a.name.localeCompare(b.name));

  cache = { items, sources, madeBy, usedIn, places, sets };
  return cache;
}

/** Every place a legendary drop can come from, for a player of `disciplineId` (their own set is likelier: smart loot). */
export function legendaryShare(setId: string, disciplineId: string): number {
  const own = legendarySetFor(disciplineId);
  const others = LEGENDARY_SET_IDS.filter((id) => id !== own);
  if (!own) return 1 / others.length;
  return setId === own ? LEGENDARY_DROP.ownShare : (1 - LEGENDARY_DROP.ownShare) / others.length;
}

const LEGENDARY_PARTS = 5;

/** Drop sources of an item. Legendary armor depends on your discipline (smart loot), so the discipline is a parameter. */
export function sourcesFor(itemId: string, disciplineId: string): DropSource[] {
  const atlas = getAtlas();
  const base = atlas.sources.get(itemId) ?? [];
  const piece = ARMOR_BY_ID[itemId];
  if (!piece || piece.collection !== 3) return base;
  const share = legendaryShare(piece.setId, disciplineId) / LEGENDARY_PARTS;
  const out: DropSource[] = [];
  for (const b of BOSS_IDS) {
    const def = BOSSES[b];
    const bossChance = legendaryBossChance(def.area);
    if (!bossChance) continue;
    out.push({ kind: 'boss', placeId: b, place: def.name, event: 'Boss kill', chance: bossChance * share, qty: [1, 1], area: def.area, ilvlSource: 'boss', note: `${fmtChance(bossChance)} legendary roll` });
  }
  for (const areaId of AREA_ORDER) {
    if (!AREAS[areaId].scaling || !AREAS[areaId].loot.length) continue;
    out.push({ kind: 'elite', placeId: areaId, place: AREAS[areaId].name, event: 'Elite kill', chance: LEGENDARY_DROP.eliteChance * share, qty: [1, 1], area: areaId, ilvlSource: 'elite', note: 'level-scaled grounds only' });
  }
  for (const band of depthBands()) {
    if (!AREAS[band.area].scaling) continue;
    out.push({ kind: 'depths', placeId: `depths:${band.from}`, place: `Catacomb Depths, ${bandLabel(band)}`, event: 'Elite kill', chance: LEGENDARY_DROP.eliteChance * share, qty: [1, 1], area: band.area, ilvlSource: 'elite' });
  }
  return [...out, ...base].sort((a, b) => b.chance - a.chance);
}

/** The place list as seen by a discipline: legendary sets add their boss and elite sources. */
export function placesFor(disciplineId: string): Place[] {
  const atlas = getAtlas();
  const extra = new Map<string, Set<string>>();
  for (const setId of LEGENDARY_SET_IDS) {
    for (const part of ['head', 'chest', 'hands', 'legs', 'feet'] as LegendaryPart[]) {
      const id = legendaryItemId(setId, part);
      for (const s of sourcesFor(id, disciplineId)) (extra.get(s.placeId) ?? extra.set(s.placeId, new Set()).get(s.placeId)!).add(id);
    }
  }
  return atlas.places.map((p) => ({ ...p, items: [...p.items, ...[...(extra.get(p.id) ?? [])].filter((i) => !p.items.includes(i))] }));
}

// --- Capes and pets ----------------------------------------------------------------------------------------------------------------

export interface CosmeticsInfo {
  capes: { id: string; name: string; lore: string; requirement: string; skill?: string }[];
  pets: { id: string; name: string; rarity: Rarity; charm: string; skill: string; lore: string; sources: DropSource[] }[];
  notes: string[];
}

const capeRequirement = (c: CapeDef) => (c.skill ? `Level 99 in ${SKILLS[c.skill].name}` : `Total level ${c.total} across all ${Object.keys(SKILLS).length} skills`);

/** Every cape and pet, how each is earned (from content/cosmetics.ts and the gathering nodes), and what they do (nothing but look). */
export function cosmeticsInfo(): CosmeticsInfo {
  const atlas = getAtlas();
  return {
    capes: CAPES.map((c) => ({ id: c.id, name: c.name, lore: c.lore, requirement: capeRequirement(c), skill: c.skill })),
    pets: PETS.map((p) => ({ id: p.id, name: p.name, rarity: p.rarity, charm: p.charm, skill: SKILLS[p.skill].name, lore: p.lore, sources: atlas.sources.get(p.charm) ?? [] })),
    notes: [
      `Capes and pets are purely cosmetic: they give no stats, no drops and no combat effect, and capes are not items (they never take a bag slot or drop). A pet's charm is an item.`,
      `Capes are earned by skill levels alone (no drops, shops or crafting). A mastery cape needs level 99 in its skill; the three mantles need a total level. All of them are one tier: there are no rarer or legendary capes.`,
      `Pets come from charms, a rare find while you work (about 1 in ${Math.round(1 / PET_CHANCE).toLocaleString('en-US')} successful actions on the matching skill's nodes, a little likelier on higher tiers). Adopt a charm (the Adopt button on it in your bag, or in Capes & Pets) and the companion is yours for good (the charm is spent); until then it can be sold (250 gold) or kept in the Vault.`,
      'To use them: open Capes & Pets (the N key, or Capes & Pets in the Menu), press Wear on an unlocked cape (Take off to remove it), Adopt on a charm in your bag, then Call on an adopted pet (Send away to dismiss it). Other players see what you wear.',
    ],
  };
}

// --- Upgrading -------------------------------------------------------------------------------------------------------------------

/** Odds of 0, 1, 2 and 3 affixes for a base rarity dropped from `source`, read from the real roll by sweeping its one random number. */
export function affixCountOdds(rarity: string, source: AffixSource): number[] {
  const N = 4000;
  const counts = [0, 0, 0, 0];
  for (let i = 0; i < N; i++) {
    const u = (i + 0.5) / N;
    counts[Math.min(MAX_AFFIXES, rollAffixCount(rarity, source, () => u))]++;
  }
  return counts.map((c) => c / N);
}

export const itemLevelAt = (level: number, source: AffixSource): number => itemLevelFor(level, source);
export { ILVL_MAX, MAX_AFFIXES };

/** Item level offsets by source, read through itemLevelFor (so they follow the rule). */
export const ILVL_OFFSETS: Record<AffixSource, number> = {
  kill: itemLevelFor(50, 'kill') - 50, elite: itemLevelFor(50, 'elite') - 50, boss: itemLevelFor(50, 'boss') - 50,
  first_kill: itemLevelFor(50, 'first_kill') - 50, surge: itemLevelFor(50, 'surge') - 50,
};

export const SOURCE_LABEL: Record<AffixSource, string> = { kill: 'Ordinary kill', elite: 'Elite / ordinary kill', boss: 'Boss kill', first_kill: 'First kill', surge: 'Grave Surge' };

// --- Fit and upgrade arrows (the existing gear score) ----------------------------------------------------------------------------

const referenceCharacter = (): Character => ({
  id: 0, class_index: 1, class_name: '', level: 20, experience: 0, gold: 0, stat_str: 10, stat_agi: 10, stat_int: 10, stat_vit: 10,
});

/** The hero the atlas judges "fit" on: gearStats' own reference (level 20, every stat 10, nothing worn) in a discipline. */
export function referenceContext(disciplineId: DisciplineId): StatContext {
  return { character: referenceCharacter(), slots: [], discipline: DISCIPLINES[disciplineId], damageTier: 0 };
}

/** A bag row for a catalogue item (no roll: base stats), so the gear score can judge it exactly like a bag item. */
export function atlasSlot(itemId: string, slotIndex = 9999): InventorySlot | null {
  const m = ITEMS[itemId];
  if (!m || !GEAR_TYPES.includes(m.type)) return null;
  return {
    id: 0, slot_index: slotIndex, quantity: 1, equipped: 0, item_id: itemId, name: m.name, rarity: m.rarity, item_type: m.type,
    stat_bonus: m.offlineStats ?? null, icon_id: null, sell_value: m.sell, crafted: 0,
  };
}

/** Percent of power wearing the item adds to `ctx` (negative when it replaces something better). */
export function powerGainPct(ctx: StatContext, itemId: string): number {
  const s = atlasSlot(itemId);
  if (!s) return 0;
  const sim = simulateEquip([...ctx.slots, s], s.slot_index);
  const a = gearPower(ctx).total;
  return a > 0 ? ((gearPower(ctx, sim.slots).total - a) / a) * 100 : 0;
}

const fitCache = new Map<string, Record<DisciplineId, number>>();
/** Percent of power the item adds for a reference hero of each discipline (empty gear): how well it suits each. */
export function fitTable(itemId: string): Record<DisciplineId, number> {
  let t = fitCache.get(itemId);
  if (!t) {
    t = {} as Record<DisciplineId, number>;
    for (const id of Object.keys(DISCIPLINES) as DisciplineId[]) t[id] = Math.round(powerGainPct(referenceContext(id), itemId) * 10) / 10;
    fitCache.set(itemId, t);
  }
  return t;
}

export type FitBand = 'ideal' | 'good' | 'okay' | 'poor';
export const FIT_LABEL: Record<FitBand, string> = { ideal: 'Ideal', good: 'Good', okay: 'Okay', poor: 'Poor' };

const gainCache = new Map<string, number>();
const gainFor = (disciplineId: string, itemId: string): number => {
  const key = `${disciplineId}:${itemId}`;
  let g = gainCache.get(key);
  if (g === undefined) {
    g = powerGainPct(referenceContext(disciplineId as DisciplineId), itemId);
    gainCache.set(key, g);
  }
  return g;
};

/** The gear of the same slot and rarity: the pieces a stat choice is made between (armor sets differ in stats, not in size). */
export function peersOf(itemId: string): string[] {
  const it = getAtlas().items.get(itemId);
  if (!it?.gear || !it.slot) return [];
  return [...getAtlas().items.values()].filter((x) => x.gear && x.slot === it.slot && x.rarity === it.rarity).map((x) => x.id);
}

/**
 * How well the piece suits the discipline against its peers (same slot, same rarity), on the gear score: 90%+ of the best peer's
 * gain is ideal, 70%+ good, 40%+ okay. Null for non-gear, or a piece with no peer to compare with.
 */
export function fitBand(itemId: string, disciplineId: string): FitBand | null {
  const peers = peersOf(itemId);
  if (peers.length < 2) return null;
  const best = Math.max(...peers.map((id) => gainFor(disciplineId, id)));
  if (best <= 0) return 'poor';
  const r = gainFor(disciplineId, itemId) / best;
  return r >= 0.9 ? 'ideal' : r >= 0.7 ? 'good' : r >= 0.4 ? 'okay' : 'poor';
}

/** Is this one of the weapon kinds the Character sheet recommends for the discipline? */
export function isRecommendedKind(itemId: string, disciplineId: string): boolean {
  const k = getAtlas().items.get(itemId)?.weaponKind;
  return !!k && !!RECOMMENDED_WEAPONS[disciplineId as DisciplineId]?.kinds.includes(k as never);
}

// --- Queries the panel and the doc share -------------------------------------------------------------------------------------------

export const SLOT_ORDER: EquipSlot[] = EQUIP_SLOTS.map((s) => s.id);
export const slotLabel = (slot: EquipSlot): string => EQUIP_SLOTS.find((s) => s.id === slot)?.label ?? slot;

/** Every gear item of a slot. */
export function gearForSlot(slot: EquipSlot): AtlasItem[] {
  return [...getAtlas().items.values()].filter((i) => i.gear && i.slot === slot);
}

/** Gear with no way to get it (no drop, no recipe, no gathering find): the data findings list reads this. */
export function unobtainable(): string[] {
  const a = getAtlas();
  return [...a.items.keys()].filter((id) => {
    const it = a.items.get(id)!;
    if (it.rarity === 'legendary' && ARMOR_BY_ID[id]?.collection === 3) return false;
    return !(a.sources.get(id)?.length) && !(a.madeBy.get(id)?.length);
  });
}

export { ARMOR_BY_ID, LEGENDARY_SETS, CHEST_KILLS };
