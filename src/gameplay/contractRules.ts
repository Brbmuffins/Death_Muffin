import { itemMeta } from '../content/items';
import { SEEDS } from '../content/gardening';
import { ALCHEMY_RECIPES } from '../content/alchemy';
import { PROCESSING_RECIPES } from '../content/processing';
import { NODES, type SkillId } from './gatheringRules';

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

interface Candidate {
  itemId: string;
  skill: SkillId;
  level: number;
  processed: boolean;
}

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
  for (const n of Object.values(NODES)) if (n.level <= level(n.skill)) add({ itemId: n.item, skill: n.skill, level: n.level, processed: false });
  for (const [, , skill, req, result] of PROCESSING_RECIPES) {
    if (result.startsWith('tool_')) continue;
    if (req <= level(skill as SkillId)) add({ itemId: result, skill: skill as SkillId, level: req, processed: true });
  }
  // Potions from the Alembic: small numbers, like anything that takes time and herbs to make.
  for (const [, , skill, req, result] of ALCHEMY_RECIPES) if (req <= level(skill as SkillId)) add({ itemId: result, skill: skill as SkillId, level: req, processed: true });
  // Herbs and logs from the garden: asked for in small numbers, like other things that take a while to make.
  for (const s of SEEDS) if (s.kind === 'herb' && s.level <= level('gardening')) add({ itemId: s.harvest, skill: 'gardening', level: s.level, processed: true });
  return out.sort((a, b) => a.level - b.level || a.itemId.localeCompare(b.itemId));
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
  const pool = candidatesFor(levels);
  // Never fewer than three orders: a brand-new character with a thin pool still gets a board.
  const cands = pool.length >= CONTRACT_SLOTS ? pool : [...pool, ...candidatesFor({}).filter((c) => !pool.includes(c))];
  const third = Math.max(1, Math.floor(cands.length / 3));
  const bands = [cands.slice(0, third), cands.slice(third, third * 2), cands.slice(third * 2)].map((b, i) => (b.length ? b : cands.slice(i)));
  const used = new Set<string>();
  const board: Contract[] = [];
  for (let slot = 0; slot < CONTRACT_SLOTS; slot++) {
    const band = bands[slot].filter((c) => !used.has(c.itemId));
    const from = band.length ? band : cands.filter((c) => !used.has(c.itemId));
    const pick = from[Math.floor(rand() * from.length)] ?? cands[slot % cands.length];
    used.add(pick.itemId);
    // Higher tiers ask for fewer; processed goods (three logs a plank) ask for far fewer; the hard order asks for less than the easy.
    let qty = Math.round(Math.min(80, Math.max(12, 70 - pick.level * 0.5)) * [1, 0.8, 0.6][slot]);
    if (pick.processed) qty = Math.max(6, Math.round(qty * 0.4));
    qty = Math.max(4, qty + Math.floor(rand() * 5) - 2);
    const sell = itemMeta(pick.itemId).sell;
    const rewardGold = Math.round(qty * sell * 1.6 + 20 * (slot + 1));
    let rewardItem: ContractItem | null = null;
    if (slot === 2) rewardItem = HARD_REWARDS.find((r) => pick.level >= r.minLevel)!.item;
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
