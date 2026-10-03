import { itemMeta } from '../content/items';
import { SEEDS } from '../content/gardening';
import { ALCHEMY_RECIPES } from '../content/alchemy';
import { MOB_REAGENTS, REAGENT_RECIPES } from '../content/reagents';
import { PROCESSING_RECIPES } from '../content/processing';
import { NODES, SKILLS, type SkillId } from './gatheringRules';

/**
 * Sexton's Contracts: the ONE source of truth for the daily delivery board, shared by the client (mock backend + display)
 * and the Death Muffin backend (`npm run build:server-rules` bundles this into gathering/contract-rules.cjs).
 *
 * Every UTC day each character gets three orders from the Sexton, drawn deterministically from the items their skill levels can
 * actually produce: an easy, a medium and a hard one. Delivering takes the items from the bag and pays gold (and sometimes an
 * item). Finishing all three pays a bonus. Pure and DOM-free.
 */

export const CONTRACT_SLOTS = 3;

export interface ContractItem {
  itemId: string;
  qty: number;
}

export interface Contract {
  slot: number;
  itemId: string;
  qty: number;
  /** The skill that makes it (shown as the order's flavour). */
  skill: SkillId;
  rewardGold: number;
  rewardItem: ContractItem | null;
}

/** UTC calendar day, "YYYY-MM-DD". */
export const dayKey = (ms: number) => new Date(ms).toISOString().slice(0, 10);

/** When the current board is replaced (next 00:00 UTC). */
export function nextResetMs(ms: number): number {
  const d = new Date(ms);
  return Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 1);
}

function hashString(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

/** The alchemy level at which each mob reagent starts to be asked for. */
const MOB_REAGENT_LEVELS: [string, number][] = [['reagent_grave_dust', 1], ['reagent_wraith_ectoplasm', 10], ['reagent_plague_bile', 38], ['reagent_cinder_ash', 52]];

interface Candidate {
  itemId: string;
  skill: SkillId;
  level: number;
  processed: boolean;
  /** A relic order asks for a fixed handful (these drop one in hundreds) and pays RELIC_PREMIUM instead of the usual 1.6x. */
  fixedQty?: number;
}

/**
 * Trade goods that used to be sell-only (2026-10-03, docs/polish/loot.md item 14). The gems, the Reliquary Fragment and the Covenant
 * Seal are rare finds from mining, the carp pools and the Barrow-King's tomb, so the Sexton asks for a small fixed number at the level
 * that finds them, and pays 2x their sell price where an ordinary order pays 1.6x. Nothing here pays an item back that another order
 * asks for, and nothing sells to a vendor for more than it was worth, so there is no gold loop.
 */
export const RELIC_PREMIUM = 2;
/** Share of days on which the hard order is a relic order (when the character's levels allow one). */
export const RELIC_CHANCE = 0.2;
export const RELIC_ORDERS: { itemId: string; skill: SkillId; level: number; qty: number }[] = [
  { itemId: 'gem_grave_garnet', skill: 'mining', level: 10, qty: 3 },
  { itemId: 'reliquary_fragment', skill: 'fishing', level: 30, qty: 3 },
  { itemId: 'gem_bone_opal', skill: 'mining', level: 30, qty: 2 },
  { itemId: 'gem_void_sapphire', skill: 'mining', level: 60, qty: 1 },
  { itemId: 'covenant_seal', skill: 'gravedigging', level: 70, qty: 2 },
];
/** Smelted tin and bronze are asked for like any other processed good (the Workbench has no recipe that eats them). */
const SMELTED_ORDERS: [itemId: string, level: number][] = [['ingot_tin', 3], ['ingot_bronze', 8]];

/** Everything this character could plausibly hand in today, cheapest tier first. */
export function candidatesFor(levels: Partial<Record<SkillId, number>>): Candidate[] {
  const level = (s: SkillId) => Math.max(1, levels[s] ?? 1);
  const seen = new Set<string>();
  const out: Candidate[] = [];
  const add = (c: Candidate) => {
    if (seen.has(c.itemId)) return;
    seen.add(c.itemId);
    out.push(c);
  };
  for (const [itemId, req] of SMELTED_ORDERS) if (req <= level('mining')) add({ itemId, skill: 'mining', level: req, processed: true });
  for (const r of RELIC_ORDERS) if (r.level <= level(r.skill)) add({ itemId: r.itemId, skill: r.skill, level: r.level, processed: false, fixedQty: r.qty });
  // Zone herb patches are skipped: their herbs come in through the seed list below at the level they can be planted.
  for (const n of Object.values(NODES)) if (n.skill !== 'gardening' && n.level <= level(n.skill)) add({ itemId: n.item, skill: n.skill, level: n.level, processed: false });
  for (const [, , skill, req, result] of PROCESSING_RECIPES) {
    if (result.startsWith('tool_')) continue;
    if (req <= level(skill as SkillId)) add({ itemId: result, skill: skill as SkillId, level: req, processed: true });
  }
  // Potions from the Alembic: small numbers, like anything that takes time and herbs to make.
  for (const [, , skill, req, result] of ALCHEMY_RECIPES) if (req <= level(skill as SkillId)) add({ itemId: result, skill: skill as SkillId, level: req, processed: true });
  // Reagent brews and the mob reagents behind them: small orders, gated by the alchemy level that uses them.
  for (const [, , skill, req, result] of REAGENT_RECIPES) if (req <= level(skill as SkillId)) add({ itemId: result, skill: skill as SkillId, level: req, processed: true });
  for (const [id, req] of MOB_REAGENT_LEVELS) if (req <= level('alchemy') && MOB_REAGENTS.includes(id)) add({ itemId: id, skill: 'alchemy', level: req, processed: true });
  // Herbs and logs from the garden: asked for in small numbers, like other things that take a while to make.
  for (const s of SEEDS) if (s.kind === 'herb' && s.level <= level('gardening')) add({ itemId: s.harvest, skill: 'gardening', level: s.level, processed: true });
  return out.sort((a, b) => a.level - b.level || a.itemId.localeCompare(b.itemId));
}

/** What the Sexton asks of this item, if he ever does: the skill and level that unlock the order, and the fixed quantity of a relic order. */
export function orderInfo(itemId: string): { skill: SkillId; level: number; relicQty: number | null } | null {
  const all = Object.fromEntries(Object.keys(SKILLS).map((k) => [k, 99])) as Record<SkillId, number>;
  const c = candidatesFor(all).find((x) => x.itemId === itemId);
  return c ? { skill: c.skill, level: c.level, relicQty: c.fixedQty ?? null } : null;
}

const HARD_REWARDS: { minLevel: number; item: ContractItem }[] = [
  { minLevel: 60, item: { itemId: 'gem_void_sapphire', qty: 1 } },
  { minLevel: 30, item: { itemId: 'gem_bone_opal', qty: 1 } },
  { minLevel: 0, item: { itemId: 'gem_grave_garnet', qty: 1 } },
];
const MEDIUM_REWARDS: ContractItem[] = [
  { itemId: 'flask_hp_minor', qty: 3 },
  { itemId: 'seed_mourning_moss', qty: 2 },
];

/** Today's board for a character. Same inputs, same board: the server and the offline mock agree. */
export function generateBoard(characterId: number, day: string, levels: Partial<Record<SkillId, number>>): Contract[] {
  const rand = mulberry32(hashString(`${characterId}:${day}`));
  const all = candidatesFor(levels);
  // Relic orders only ever stand in for the hard slot (see RELIC_CHANCE), so the bands are built from the ordinary goods.
  const relics = all.filter((c) => c.fixedQty);
  const pool = all.filter((c) => !c.fixedQty);
  // Never fewer than three orders: a brand-new character with a thin pool still gets a board.
  const cands = pool.length >= CONTRACT_SLOTS ? pool : [...pool, ...candidatesFor({}).filter((c) => !pool.includes(c))];
  const third = Math.max(1, Math.floor(cands.length / 3));
  const bands = [cands.slice(0, third), cands.slice(third, third * 2), cands.slice(third * 2)].map((b, i) => (b.length ? b : cands.slice(i)));
  const used = new Set<string>();
  const board: Contract[] = [];
  for (let slot = 0; slot < CONTRACT_SLOTS; slot++) {
    const band = bands[slot].filter((c) => !used.has(c.itemId));
    const from = band.length ? band : cands.filter((c) => !used.has(c.itemId));
    let pick = from[Math.floor(rand() * from.length)] ?? cands[slot % cands.length];
    // Every day the dice are rolled in the same order, so a board does not depend on whether relics were available.
    const relicRoll = rand();
    const relicPick = relics[Math.floor(rand() * relics.length)];
    if (slot === 2 && relicRoll < RELIC_CHANCE && relicPick) pick = relicPick;
    used.add(pick.itemId);
    // Higher tiers ask for fewer; processed goods (three logs a plank) ask for far fewer; the hard order asks for less than the easy.
    let qty = Math.round(Math.min(80, Math.max(12, 70 - pick.level * 0.5)) * [1, 0.8, 0.6][slot]);
    if (pick.processed) qty = Math.max(6, Math.round(qty * 0.4));
    qty = Math.max(4, qty + Math.floor(rand() * 5) - 2);
    if (pick.fixedQty) qty = pick.fixedQty;
    const sell = itemMeta(pick.itemId).sell;
    const rewardGold = Math.round(qty * sell * (pick.fixedQty ? RELIC_PREMIUM : 1.6) + 20 * (slot + 1));
    let rewardItem: ContractItem | null = null;
    // A relic order hands back only the plainest gem: the rarer gems it asks for are never paid out again.
    if (slot === 2) rewardItem = pick.fixedQty ? HARD_REWARDS[HARD_REWARDS.length - 1].item : HARD_REWARDS.find((r) => pick.level >= r.minLevel)!.item;
    else if (slot === 1 && rand() < 0.35) rewardItem = MEDIUM_REWARDS[Math.floor(rand() * MEDIUM_REWARDS.length)];
    board.push({ slot, itemId: pick.itemId, qty, skill: pick.skill, rewardGold, rewardItem });
  }
  return board;
}

/** Paid once, when the last of the day's three orders is handed in. */
export function bonusFor(board: Contract[]): { gold: number; item: ContractItem } {
  const gold = Math.round(board.reduce((n, c) => n + c.rewardGold, 0) * 0.5);
  return { gold, item: { itemId: 'gem_grave_garnet', qty: 1 } };
}

/** Consecutive days (ending today or yesterday) with at least one order handed in. `doneDays` are "YYYY-MM-DD" strings. */
export function streakOf(doneDays: string[], today: string): number {
  const days = new Set(doneDays);
  const step = (d: string, by: number) => dayKey(Date.parse(`${d}T00:00:00Z`) + by * 86_400_000);
  let cursor = days.has(today) ? today : step(today, -1);
  let n = 0;
  while (days.has(cursor)) {
    n++;
    cursor = step(cursor, -1);
  }
  return n;
}
