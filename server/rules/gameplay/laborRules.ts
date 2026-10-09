import { GATHER_SKILLS, NODES, actionMs, addSkillXp, rollBatch, successChance, type GatherSkill, type ItemGrant, type NodeDef, type SkillProgress } from './gatheringRules';

/**
 * Grave Laborers (thrall labour): the raised dead work a gathering post for you, slowly, while you fight, explore or sleep. Shared by
 * the client (panel + offline mock) and the Death Muffin backend (`npm run build:server-rules` bundles this into gathering/labor-rules.cjs).
 *
 * Work accrues on the server's clock from the moment a post is assigned, up to a cap, and is collected on demand. It reuses the gather
 * rolls, so seeds, gems and other finds still drop. A laborer works at a fraction of a player's own pace and earns a fraction of the XP.
 * Pure and DOM-free; everything random takes an `rng`.
 */

export const LABOR = {
  /** Share of a player's own action rate. */
  factor: 0.12,
  /** Work stops accruing after this long without a collection. */
  capMs: 8 * 3_600_000,
  /** Share of the XP a player would earn from the same finds. */
  xpFrac: 0.25,
  maxSlots: 4,
  /** Total gathering levels (across the four gather skills) per extra laborer. */
  levelsPerSlot: 50,
};

/** How many laborers you command: one to start, another for every 50 total gathering levels, up to four. */
export const laborSlots = (totalLevel: number) => Math.min(LABOR.maxSlots, 1 + Math.floor(Math.max(0, totalLevel) / LABOR.levelsPerSlot));

/** Total levels over the four gathering skills. */
export const totalGatherLevel = (levels: Partial<Record<string, number>>) => GATHER_SKILLS.reduce((n, s) => n + Math.max(1, levels[s] ?? 1), 0);

/** Work posts a laborer can take: every base node your level allows (the zone herb patches are for you to forage, not the dead). */
export function postsFor(levels: Partial<Record<string, number>>): NodeDef[] {
  return Object.values(NODES).filter((n) => n.skill !== 'gardening' && (levels[n.skill] ?? 1) >= n.level);
}

export function assignBlocker(nodeType: string, levels: Partial<Record<string, number>>): string | null {
  const def = NODES[nodeType];
  if (!def || def.skill === 'gardening') return 'That is not a place to work.';
  if ((levels[def.skill] ?? 1) < def.level) return `Requires level ${def.level}.`;
  return null;
}

/** Cycles a laborer completes in `elapsedMs` of work (capped). */
export function laborActions(def: NodeDef, elapsedMs: number): number {
  const ms = Math.max(0, Math.min(elapsedMs, LABOR.capMs));
  return Math.floor((ms / actionMs(def)) * LABOR.factor);
}

/** What the panel shows while work piles up: the main find and XP you can expect (finds vary; this is the average). */
export function estimate(def: NodeDef, level: number, elapsedMs: number) {
  const actions = laborActions(def, elapsedMs);
  const wins = actions * successChance(def, level);
  return { actions, items: Math.round(wins), xp: Math.round(wins * def.xp * LABOR.xpFrac) };
}

export interface LaborResult {
  items: ItemGrant[];
  gold: number;
  xp: number;
  actions: number;
  progress: SkillProgress;
  leveled: number;
}

/** Rolls a collection. XP is scaled down to the laborer's share and applied to the real skill level. */
export function rollLabor(def: NodeDef, start: SkillProgress, elapsedMs: number, rng: () => number): LaborResult {
  const actions = laborActions(def, elapsedMs);
  // Roll at the current level (a laborer does not level you mid-collection); the XP share is added afterwards.
  const batch = rollBatch(def, { level: start.level, xp: 0 }, actions, rng, 0);
  const xp = Math.floor(batch.xp * LABOR.xpFrac);
  const next = addSkillXp(start, xp);
  return { items: batch.items, gold: batch.gold, xp, actions, progress: { level: next.level, xp: next.xp }, leveled: next.leveled };
}

export function hashSeed(...parts: (string | number)[]): number {
  let h = 2166136261;
  for (const ch of parts.join(':')) {
    h ^= ch.charCodeAt(0);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

/** A repeatable rng for one collection (same post, same start, same moment: same result, so a refused claim cannot be re-rolled). */
export function claimRng(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export type { GatherSkill };
