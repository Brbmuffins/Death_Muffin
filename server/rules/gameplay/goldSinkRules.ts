/**
 * Two gold sinks (GRIND-LOOP §3 #7 and docs/polish/loot.md #17), pure rules shared by the client, the offline mock and the backend
 * (`npm run build:server-rules` bundles this file into gathering/gold-sink-rules.cjs; reforge.cjs and boss-key.cjs price and roll with it).
 *
 *  1. Reforge (Workbench): pay gold to re-roll the VALUE of one affix on a rolled piece. The affix stays; only its number is drawn again,
 *     uniformly over the range the item level allows today (`affixRange`, read from affixRules so a retune needs no change here). The price
 *     rises every time the same piece is reforged.
 *  2. Empowered summon (area-boss altars): a Covenant Seal plus gold calls the boss in an Empowered form (BossBrain level knob, more health),
 *     and the kill pays one server-rolled prize: an epic-or-better piece with better legendary odds than an ordinary kill.
 */
import { AREAS } from '../content/areas';
import { ITEMS } from '../content/items';
import { BOSSES, type BossId } from '../content/bosses';
import { legendaryBossChance, pickLegendaryItem } from '../content/legendarySets';
import {
  AFFIXES, affixRange, effectiveRarity, isAffixGear, MAX_AFFIXES, rollInstance,
  type DropSource, type ItemInstanceData,
} from './affixRules';
import { smartTable } from './smartLoot';

// --- Reforge -------------------------------------------------------------------------------------------------------------------------

export const REFORGE = {
  /** Gold per item level for the first reforge of a common or uncommon piece. */
  goldPerIlvl: 40,
  /** Price multiplier per reforge already done on this piece. */
  growth: 1.25,
  /** Reforges after which the price stops rising (1.25^20 is about 87x). */
  maxSteps: 20,
  /** Nothing costs more than this, whatever the item level. */
  cap: 2_000_000,
  /** By the rarity the piece shows (affix count included). */
  rarityMult: { common: 1, uncommon: 1, rare: 1.5, epic: 2.5, legendary: 4, relic: 4 } as Record<string, number>,
} as const;

/** What the next reforge of this piece costs. `baseRarity` is the item's own rarity; the affix count lifts it to what the tooltip shows. */
export function reforgeCost(ilvl: number, baseRarity: string, affixCount: number, rerolls: number): number {
  const shown = effectiveRarity(baseRarity, affixCount);
  const mult = REFORGE.rarityMult[shown] ?? 1;
  const step = Math.max(0, Math.min(REFORGE.maxSteps, Math.floor(Number(rerolls) || 0)));
  const raw = REFORGE.goldPerIlvl * Math.max(1, Math.floor(ilvl)) * mult * Math.pow(REFORGE.growth, step);
  return Math.min(REFORGE.cap, Math.max(1, Math.round(raw)));
}

/** Why this affix cannot be reforged, or null. The best possible roll is never re-drawn (it could only get worse and costs gold). */
export function reforgeProblem(inst: ItemInstanceData, index: number): string | null {
  const a = Number.isInteger(index) ? inst.affixes[index] : undefined;
  if (!a) return 'Choose one of the affixes.';
  const r = affixRange(a.id, inst.ilvl);
  if (!r) return 'That affix cannot be reforged.';
  if (r[0] === r[1]) return 'That affix has only one possible value.';
  if (a.v >= r[1]) return 'That roll is already as high as this item level allows.';
  return null;
}

/** A fresh value for the affix: uniform over today's range. `rand` returns [0, 1). */
export function reforgeValue(affixId: string, ilvl: number, rand: () => number): number {
  const r = affixRange(affixId, ilvl);
  if (!r) throw new Error(`unknown affix ${affixId}`);
  const [lo, hi] = r;
  return lo + Math.min(hi - lo, Math.floor(rand() * (hi - lo + 1)));
}

// --- Empowered summons ---------------------------------------------------------------------------------------------------------------

export const COVENANT_SEAL = 'covenant_seal';

export const EMPOWER = {
  /** Gold = goldPerShardSq x shards^2: 30k at the Gravedigger King (2 shards) up to 367.5k at the Mire Mother (7). */
  goldPerShardSq: 7_500,
  /** Added to the boss's level (the BossBrain level knob scales health 22% and damage 15% per level). */
  levelsFlat: 6,
  /** ...plus this share of its level, so the level-scaled grounds feel it too. */
  levelsShare: 0.15,
  /** On top of the level: health multiplier. */
  hpMult: 1.4,
  /** The prize's legendary chance is the ordinary boss chance times this (15% -> 37.5%, the starter boss 3% -> 7.5%). */
  legendaryMult: 2.5,
  legendaryCap: 0.6,
  /** A summon's prize may be claimed this long after the summon (ms): a long fight plus a wipe or two. */
  claimWindowMs: 3 * 60 * 60 * 1000,
  /** A summon the host refused (another boss was awake) can be taken back this soon after (ms). */
  refundWindowMs: 2 * 60 * 1000,
  /** An epic-or-better piece shows three affixes. */
  prizeAffixes: 3,
} as const;

/** The area bosses a Seal can call (not the Prelate: its kills drive Ascension). */
export const EMPOWERABLE: readonly BossId[] = ['gravedigger', 'abbess', 'congregation', 'saint', 'regent', 'mire'];
export type EmpowerableBoss = BossId;
export const canEmpower = (boss: unknown): boss is BossId => typeof boss === 'string' && (EMPOWERABLE as readonly string[]).includes(boss);

/** The ground a boss lives in (its seal must be open to the character). */
export const bossArea = (boss: BossId) => BOSSES[boss].area;

export const empowerGold = (boss: BossId): number => EMPOWER.goldPerShardSq * BOSSES[boss].shards * BOSSES[boss].shards;

/** The level an Empowered boss fights at (BossBrain `state.level`). */
export const empoweredLevel = (level: number): number => Math.round(level + EMPOWER.levelsFlat + level * EMPOWER.levelsShare);

export interface EmpoweredPrize {
  item_id: string;
  legendary: boolean;
}

/** Odds that the prize is a legendary set piece. */
export const empoweredLegendaryChance = (boss: BossId): number => Math.min(EMPOWER.legendaryCap, legendaryBossChance(BOSSES[boss].area) * EMPOWER.legendaryMult);

/**
 * Which piece the prize is: a legendary set piece (odds above, favouring pieces `owned` lacks), otherwise one gear piece from the boss's
 * area table weighted by the usual smart loot, rare-or-better bases four times as likely. Never a material.
 */
export function rollEmpoweredPrize(boss: BossId, disciplineId: string, rand: () => number, owned?: ReadonlySet<string>): EmpoweredPrize {
  if (rand() < empoweredLegendaryChance(boss)) return { item_id: pickLegendaryItem(disciplineId, rand, owned), legendary: true };
  const area = BOSSES[boss].area;
  const gear = (e: { item: string }) => !!ITEMS[e.item] && isAffixGear(ITEMS[e.item].type);
  const smart = smartTable(area, disciplineId).filter(gear);
  const pool = (smart.length ? smart : AREAS[area].loot.filter(gear))
    .map((e) => ({ item: e.item, w: e.weight * (ITEMS[e.item].rarity === 'rare' || ITEMS[e.item].rarity === 'epic' ? 4 : 1) }));
  const total = pool.reduce((n, e) => n + e.w, 0);
  let r = rand() * total;
  for (const e of pool) {
    r -= e.w;
    if (r < 0) return { item_id: e.item, legendary: false };
  }
  return { item_id: pool[pool.length - 1].item, legendary: false };
}

/**
 * The prize's item level and affixes: an ordinary boss roll, redrawn until it carries `prizeAffixes` (so it shows epic), then topped up
 * from unused affix groups if the redraws never got there. A legendary piece keeps whatever the boss roll gives (already above epic).
 * Rolls go through the public rollInstance and affixRange, so affix tuning flows through.
 */
export function rollEmpoweredInstance(prize: EmpoweredPrize, baseRarity: string, level: number, rand: () => number): ItemInstanceData {
  const source: DropSource = 'boss';
  let inst = rollInstance({ rarity: prize.legendary ? 'legendary' : baseRarity }, level, source, rand);
  if (prize.legendary) return inst;
  for (let i = 0; i < 80 && inst.affixes.length < EMPOWER.prizeAffixes; i++) inst = rollInstance({ rarity: 'epic' }, level, source, rand);
  const affixes = [...inst.affixes];
  const used = new Set(affixes.map((a) => AFFIXES.find((d) => d.id === a.id)?.group));
  for (const d of AFFIXES) {
    if (affixes.length >= Math.min(EMPOWER.prizeAffixes, MAX_AFFIXES)) break;
    if (used.has(d.group)) continue;
    used.add(d.group);
    affixes.push({ id: d.id, v: reforgeValue(d.id, inst.ilvl, rand) });
  }
  return { ilvl: inst.ilvl, affixes };
}
