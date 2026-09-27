/**
 * Gathering rules: the ONE source of truth for the skilling layer, shared by
 * the client (feel + node UI), the DEV offline backend and the Death Muffin
 * backend. `npm run build:server-rules` bundles this file into
 * `server/death-muffin/backend/gathering/gathering-rules.cjs`, and a unit test
 * fails if that copy is stale. Spec: docs/PROFESSIONS-ROADMAP.md §4, §8, §9.
 *
 * Pure and DOM-free. Everything random takes an `rng` so the server, the
 * client and the tests can each supply their own.
 */

export type SkillId = 'woodcutting' | 'mining' | 'fishing' | 'gravedigging' | 'gardening';
/** Skills worked on world nodes (gardening uses plots, not nodes). */
export type GatherSkill = Exclude<SkillId, 'gardening'>;
export const GATHER_SKILLS: GatherSkill[] = ['woodcutting', 'mining', 'fishing', 'gravedigging'];
export const ALL_SKILLS: SkillId[] = ['woodcutting', 'mining', 'fishing', 'gravedigging', 'gardening'];

export interface SkillMeta {
  name: string;
  /** Covenant name shown under the skill. */
  rite: string;
  /** Floating-text / XP-bar colour. */
  color: string;
  /** Which hero clip loops while working. */
  gesture: 'dig' | 'cast';
  /** Procedural SFX recipe name in audio/Audio.ts. */
  sfx: 'chop' | 'pick' | 'splash' | 'shovel';
  verb: string;
}

export const SKILLS: Record<SkillId, SkillMeta> = {
  woodcutting: { name: 'Woodcutting', rite: 'Rite of Coffin-Oak', color: '#c9a36b', gesture: 'dig', sfx: 'chop', verb: 'Chop' },
  mining: { name: 'Mining', rite: 'Rite of Grave-Iron', color: '#b7bcc4', gesture: 'dig', sfx: 'pick', verb: 'Mine' },
  fishing: { name: 'Fishing', rite: 'Rite of the Black Water', color: '#6fb3c8', gesture: 'cast', sfx: 'splash', verb: 'Fish' },
  gravedigging: { name: 'Gravedigging', rite: 'Rite of the Sexton', color: '#d8cfa8', gesture: 'dig', sfx: 'shovel', verb: 'Dig' },
  gardening: { name: 'Grave Gardening', rite: 'Rite of the Mourning Bed', color: '#9fc27a', gesture: 'cast', sfx: 'shovel', verb: 'Tend' },
};

/** One RuneScape tick. Most nodes take 4–8 ticks per action. */
export const TICK_MS = 600;
export const LEVEL_CAP = 99;
/** Extra actions a batch may claim beyond the elapsed time (network jitter, first batch). */
export const GATHER_BURST = 3;
/** A batch never earns credit for more than this much idle time (no "pause, then claim an hour"). */
export const GATHER_MAX_WINDOW_MS = 30_000;
/** Hard ceiling per character per hour, whatever the nodes. */
export const GATHER_MAX_ACTIONS_PER_HOUR = 1800;
/** Client batching cadence (and the most actions one request may carry). */
export const GATHER_FLUSH_MS = 8_000;
export const GATHER_MAX_BATCH = 40;

export type NodeKind = 'tree' | 'seam' | 'geode' | 'pool' | 'grave';

export interface LootLine {
  item: string;
  /** Chance per successful action (0–1). */
  chance: number;
  qty?: [number, number];
}

export interface NodeDef {
  id: string;
  skill: GatherSkill;
  name: string;
  kind: NodeKind;
  level: number;
  /** XP per successful action. */
  xp: number;
  /** Ticks per action (× TICK_MS). */
  ticks: number;
  /** The main item every success grants. */
  item: string;
  /** Successes before the node depletes (host rolls in this range). Rich nodes get ×1.5. */
  yields: [number, number];
  /** Seconds until a depleted node is back. Rich nodes get ×0.5. */
  respawnS: number;
  /** Extra finds rolled on each success. */
  extras: LootLine[];
  /** Gold per success (gravedigging). */
  gold?: [number, number];
  /** Vein / water / soil tint for the stand-in and GLB material mask. */
  tint: number;
}

export const RICH_YIELD = 1.5;
export const RICH_RESPAWN = 0.5;

const node = (d: Omit<NodeDef, 'extras'> & { extras?: LootLine[] }): NodeDef => ({ extras: [], ...d });

/** Crow's nests in felled trees (1/200): a seed or a mourning ring. */
const CROWS_NEST: LootLine[] = [
  { item: 'seed_mourning_moss', chance: 1 / 300 },
  { item: 'ring_copper', chance: 1 / 600 },
];
const GEMS = (scale: number): LootLine[] => [
  { item: 'gem_grave_garnet', chance: (1 / 250) * 0.6 * scale },
  { item: 'gem_bone_opal', chance: (1 / 250) * 0.3 * scale },
  { item: 'gem_void_sapphire', chance: (1 / 250) * 0.1 * scale },
];

const NODE_LIST: NodeDef[] = [
  // Woodcutting
  node({ id: 'coffin_oak', skill: 'woodcutting', name: 'Coffin-Oak', kind: 'tree', level: 1, xp: 6, ticks: 4, item: 'log_oak', yields: [1, 4], respawnS: 8, extras: CROWS_NEST, tint: 0x6b5236 }),
  node({ id: 'hangman_elm', skill: 'woodcutting', name: "Hangman's Elm", kind: 'tree', level: 15, xp: 14, ticks: 5, item: 'log_elm', yields: [3, 6], respawnS: 12, extras: CROWS_NEST, tint: 0x5d5a3c }),
  node({ id: 'bleeding_willow', skill: 'woodcutting', name: 'Bleeding Willow', kind: 'tree', level: 30, xp: 24, ticks: 5, item: 'log_willow', yields: [4, 8], respawnS: 15, extras: CROWS_NEST, tint: 0x7a3a34 }),
  node({ id: 'churchyard_yew', skill: 'woodcutting', name: 'Churchyard Yew', kind: 'tree', level: 45, xp: 38, ticks: 6, item: 'log_yew', yields: [5, 10], respawnS: 30, extras: CROWS_NEST, tint: 0x2f4a33 }),
  node({ id: 'blackthorn', skill: 'woodcutting', name: 'Blackthorn', kind: 'tree', level: 60, xp: 55, ticks: 7, item: 'log_blackthorn', yields: [6, 12], respawnS: 45, extras: CROWS_NEST, tint: 0x2a2530 }),
  node({ id: 'ghostwood', skill: 'woodcutting', name: 'Ghostwood', kind: 'tree', level: 75, xp: 80, ticks: 8, item: 'log_ghostwood', yields: [6, 12], respawnS: 60, extras: CROWS_NEST, tint: 0x9fb8b0 }),
  node({ id: 'bone_elder', skill: 'woodcutting', name: 'Bone Elder', kind: 'tree', level: 90, xp: 115, ticks: 8, item: 'log_bone_elder', yields: [8, 14], respawnS: 120, extras: CROWS_NEST, tint: 0xe6dcc4 }),
  // Mining: one seam model, tinted per ore; geodes for the top tiers.
  node({ id: 'seam_copper', skill: 'mining', name: 'Copper Seam', kind: 'seam', level: 1, xp: 6, ticks: 4, item: 'ore_copper', yields: [1, 3], respawnS: 5, extras: GEMS(1), tint: 0x3fa37a }),
  node({ id: 'seam_tin', skill: 'mining', name: 'Tin Seam', kind: 'seam', level: 1, xp: 6, ticks: 4, item: 'ore_tin', yields: [1, 3], respawnS: 5, extras: GEMS(1), tint: 0x9aa3a8 }),
  node({ id: 'seam_iron', skill: 'mining', name: 'Iron Seam', kind: 'seam', level: 10, xp: 12, ticks: 5, item: 'ore_iron', yields: [2, 4], respawnS: 9, extras: GEMS(1), tint: 0x9a5a3c }),
  node({ id: 'seam_bronze', skill: 'mining', name: 'Bronze Seam', kind: 'seam', level: 20, xp: 18, ticks: 5, item: 'ore_bronze', yields: [2, 5], respawnS: 12, extras: GEMS(1), tint: 0xc08a4a }),
  node({ id: 'seam_silver', skill: 'mining', name: 'Silver Seam', kind: 'seam', level: 30, xp: 24, ticks: 5, item: 'ore_silver', yields: [3, 6], respawnS: 18, extras: GEMS(1.2), tint: 0xd8dde6 }),
  node({ id: 'seam_gold', skill: 'mining', name: 'Gold Seam', kind: 'seam', level: 40, xp: 32, ticks: 6, item: 'ore_gold', yields: [3, 6], respawnS: 25, extras: GEMS(1.4), tint: 0xe8b84a }),
  node({ id: 'seam_steel', skill: 'mining', name: 'Steel Seam', kind: 'seam', level: 50, xp: 42, ticks: 6, item: 'ore_steel', yields: [4, 7], respawnS: 32, extras: GEMS(1.6), tint: 0x7d8fa6 }),
  node({ id: 'geode_hell', skill: 'mining', name: 'Hell Geode', kind: 'geode', level: 65, xp: 60, ticks: 7, item: 'ore_hell', yields: [4, 8], respawnS: 45, extras: GEMS(2), tint: 0xe0522a }),
  node({ id: 'geode_moon', skill: 'mining', name: 'Moon Geode', kind: 'geode', level: 80, xp: 90, ticks: 8, item: 'ore_moon', yields: [5, 9], respawnS: 60, extras: GEMS(2.5), tint: 0x9ec4ff }),
  // Fishing: spots drift, so a "depleted" pool is a spot that moved on.
  node({ id: 'pool_still', skill: 'fishing', name: 'Still Pool', kind: 'pool', level: 1, xp: 6, ticks: 4, item: 'fish_river', yields: [8, 16], respawnS: 6, extras: [{ item: 'ring_copper', chance: 1 / 400 }], tint: 0x2c4a52 }),
  node({ id: 'pool_eels', skill: 'fishing', name: 'Crypt Eels', kind: 'pool', level: 15, xp: 14, ticks: 5, item: 'fish_crypt_eel', yields: [8, 16], respawnS: 8, extras: [{ item: 'ring_copper', chance: 1 / 400 }], tint: 0x31503f }),
  node({ id: 'pool_carp', skill: 'fishing', name: 'Bell Carp', kind: 'pool', level: 30, xp: 24, ticks: 5, item: 'fish_bell_carp', yields: [10, 18], respawnS: 10, extras: [{ item: 'reliquary_fragment', chance: 1 / 300 }], tint: 0x5a5a38 }),
  node({ id: 'pool_pike', skill: 'fishing', name: 'Drowned Pike', kind: 'pool', level: 45, xp: 38, ticks: 6, item: 'fish_drowned_pike', yields: [10, 18], respawnS: 12, extras: [{ item: 'reliquary_fragment', chance: 1 / 250 }], tint: 0x24404a }),
  node({ id: 'pool_lantern', skill: 'fishing', name: 'Lanternfish', kind: 'pool', level: 62, xp: 58, ticks: 7, item: 'fish_lanternfish', yields: [12, 20], respawnS: 14, extras: [{ item: 'reliquary_fragment', chance: 1 / 200 }], tint: 0x3a6a5a }),
  node({ id: 'pool_coelacanth', skill: 'fishing', name: 'Abyssal Coelacanth', kind: 'pool', level: 80, xp: 95, ticks: 8, item: 'fish_coelacanth', yields: [12, 20], respawnS: 16, extras: [{ item: 'covenant_seal', chance: 1 / 300 }], tint: 0x1a2c44 }),
  // Gravedigging: the necromancer's own skill.
  node({
    id: 'grave_pauper', skill: 'gravedigging', name: "Pauper's Grave", kind: 'grave', level: 1, xp: 7, ticks: 4, item: 'bones_old',
    yields: [2, 4], respawnS: 10, gold: [0, 2], tint: 0x4a3c2c, extras: [{ item: 'seed_mourning_moss', chance: 1 / 12 }],
  }),
  node({
    id: 'grave_mound', skill: 'gravedigging', name: 'Burial Mound', kind: 'grave', level: 20, xp: 18, ticks: 5, item: 'bones_barrow',
    yields: [3, 5], respawnS: 18, gold: [1, 4], tint: 0x4d4632, extras: [{ item: 'ring_copper', chance: 1 / 120 }, { item: 'seed_mourning_moss', chance: 1 / 20 }],
  }),
  node({
    id: 'grave_crypt', skill: 'gravedigging', name: 'Crypt Collapse', kind: 'grave', level: 40, xp: 34, ticks: 6, item: 'bones_crypt',
    yields: [3, 6], respawnS: 30, gold: [2, 6], tint: 0x5a5650,
    extras: [{ item: 'ore_silver', chance: 1 / 8 }, { item: 'reliquary_fragment', chance: 1 / 60 }],
  }),
  node({
    id: 'grave_barrow_king', skill: 'gravedigging', name: "Barrow-King's Tomb", kind: 'grave', level: 70, xp: 70, ticks: 8, item: 'bones_ancient',
    yields: [4, 8], respawnS: 60, gold: [4, 12], tint: 0x6a5a3a,
    extras: [
      { item: 'covenant_seal', chance: 1 / 40 },
      { item: 'reliquary_fragment', chance: 1 / 25 },
      { item: 'helm_gold', chance: 1 / 900 },
      { item: 'chest_iron', chance: 1 / 700 },
      { item: 'kit_iron_warden', chance: 1 / 800 },
    ],
  }),
];

export const NODES: Record<string, NodeDef> = Object.fromEntries(NODE_LIST.map((n) => [n.id, n]));
export const NODE_IDS = NODE_LIST.map((n) => n.id);
export const nodesForSkill = (skill: GatherSkill) => NODE_LIST.filter((n) => n.skill === skill);

/** Every item id the rules can grant (a unit test checks each is a known item). */
export function grantableItems(): string[] {
  const ids = new Set<string>();
  for (const n of NODE_LIST) {
    ids.add(n.item);
    for (const e of n.extras) ids.add(e.item);
  }
  return [...ids];
}

export const actionMs = (def: NodeDef) => def.ticks * TICK_MS;

// ── XP curve (§9) ─────────────────────────────────────────────────────────────

/** Live server rule: XP into the next level = level × 50 (99 ≈ 243k total). */
export const xpToNextLive = (level: number) => Math.max(1, level) * 50;
/** Recommended curve: the live rule through 20, then +3.5% per level (99 ≈ 1.53M total). */
export const xpToNextCurve = (level: number) => Math.round(50 * Math.max(1, level) * Math.pow(1.035, Math.max(0, level - 20)));

/** Owner decision (roadmap §12 q1). The live rule stays until the owner adopts the curve. */
export const XP_CURVE = 'live' as 'live' | 'curve';
export const xpToNext = (level: number) => (XP_CURVE === 'curve' ? xpToNextCurve(level) : xpToNextLive(level));

export function totalXpFor(level: number, fn: (l: number) => number = xpToNext) {
  let t = 0;
  for (let l = 1; l < level; l++) t += fn(l);
  return t;
}

export interface SkillProgress {
  level: number;
  /** XP into the current level (the `professions.skill_xp` column). */
  xp: number;
}

/** Adds XP, rolling levels over; stops at LEVEL_CAP (XP stays banked at 0 there). */
export function addSkillXp(p: SkillProgress, gained: number): SkillProgress & { leveled: number } {
  let level = Math.max(1, Math.min(LEVEL_CAP, Math.floor(p.level) || 1));
  let xp = Math.max(0, Math.floor(p.xp) || 0) + Math.max(0, Math.floor(gained));
  let leveled = 0;
  while (level < LEVEL_CAP && xp >= xpToNext(level)) {
    xp -= xpToNext(level);
    level++;
    leveled++;
  }
  if (level >= LEVEL_CAP) xp = 0;
  return { level, xp, leveled };
}

// ── Actions ───────────────────────────────────────────────────────────────────

/** Chance that one action succeeds. Tools are optional speed-ups (roadmap §12 q2): +5% per tier. */
export function successChance(def: NodeDef, level: number, toolTier = 0) {
  const p = 0.45 + 0.01 * (level - def.level) + 0.05 * toolTier;
  return Math.max(0.2, Math.min(0.9, p));
}

export interface ItemGrant {
  itemId: string;
  qty: number;
}

export interface ActionRoll {
  success: boolean;
  xp: number;
  gold: number;
  items: ItemGrant[];
}

const randInt = (rng: () => number, lo: number, hi: number) => lo + Math.floor(rng() * (hi - lo + 1));

/** One work cycle on a node. Returns an empty roll when the player is below the node's level. */
export function rollGather(def: NodeDef, level: number, rng: () => number, toolTier = 0): ActionRoll {
  if (level < def.level || rng() >= successChance(def, level, toolTier)) return { success: false, xp: 0, gold: 0, items: [] };
  const items: ItemGrant[] = [{ itemId: def.item, qty: 1 }];
  for (const e of def.extras) {
    if (rng() < e.chance) items.push({ itemId: e.item, qty: e.qty ? randInt(rng, e.qty[0], e.qty[1]) : 1 });
  }
  return { success: true, xp: def.xp, gold: def.gold ? randInt(rng, def.gold[0], def.gold[1]) : 0, items };
}

export interface BatchResult {
  progress: SkillProgress;
  successes: number;
  xp: number;
  gold: number;
  items: ItemGrant[];
  leveled: number;
}

/** Rolls `actions` cycles in order, levelling up mid-batch (a level-up improves the next roll). */
export function rollBatch(def: NodeDef, start: SkillProgress, actions: number, rng: () => number, toolTier = 0): BatchResult {
  let progress: SkillProgress = { level: start.level, xp: start.xp };
  const bag = new Map<string, number>();
  let xp = 0;
  let gold = 0;
  let successes = 0;
  let leveled = 0;
  for (let i = 0; i < actions; i++) {
    const r = rollGather(def, progress.level, rng, toolTier);
    if (!r.success) continue;
    successes++;
    xp += r.xp;
    gold += r.gold;
    for (const g of r.items) bag.set(g.itemId, (bag.get(g.itemId) ?? 0) + g.qty);
    const next = addSkillXp(progress, r.xp);
    leveled += next.leveled;
    progress = { level: next.level, xp: next.xp };
  }
  return { progress, successes, xp, gold, items: [...bag].map(([itemId, qty]) => ({ itemId, qty })), leveled };
}

/** Expected XP per hour of continuous work on an always-available node (balance tests + Codex). */
export function xpPerHour(def: NodeDef, level: number, toolTier = 0) {
  return (3_600_000 / actionMs(def)) * successChance(def, level, toolTier) * def.xp;
}

// ── Time budget (server side of POST /api/gather) ────────────────────────────

export interface GatherLedger {
  /** ms timestamp of the last accepted batch (0 = never). */
  lastAt: number;
  /** Start of the current hour window (ms) and the actions accepted inside it. */
  hourStart: number;
  hourActions: number;
}

export const blankLedger = (): GatherLedger => ({ lastAt: 0, hourStart: 0, hourActions: 0 });

export type BudgetResult = { ok: true; accepted: number; ledger: GatherLedger } | { ok: false; error: string };

/**
 * How many of the claimed actions the elapsed time allows:
 * `floor(min(now − last, window) / actionMs) + burst`, capped per hour.
 * A first batch (no ledger) gets the burst plus one window of credit.
 */
export function checkBudget(def: NodeDef, ledger: GatherLedger, claimed: number, now: number, afk = false): BudgetResult {
  const want = Math.floor(Number(claimed));
  if (!Number.isFinite(want) || want < 1) return { ok: false, error: 'Nothing to gather' };
  if (afk && !ledger.lastAt) return { ok: false, error: 'Start AFK gathering from Skills first.' };
  const windowMs = afk ? 90_000 : GATHER_MAX_WINDOW_MS;
  const elapsed = ledger.lastAt > 0 ? Math.max(0, now - ledger.lastAt) : windowMs;
  const byTime = Math.floor(Math.min(elapsed, windowMs) / actionMs(def)) + (afk ? 0 : GATHER_BURST);
  const rolled = now - ledger.hourStart >= 3_600_000 || ledger.hourStart === 0;
  const hourStart = rolled ? now : ledger.hourStart;
  const hourActions = rolled ? 0 : ledger.hourActions;
  const byHour = GATHER_MAX_ACTIONS_PER_HOUR - hourActions;
  const accepted = Math.min(want, byTime, byHour, GATHER_MAX_BATCH);
  if (accepted <= 0) {
    return { ok: false, error: byHour <= 0 ? 'Your hands are spent for this hour. Rest, then gather again.' : 'You are gathering faster than your hands allow. Slow down.' };
  }
  // AFK consumes earned time rather than discarding it at the first background
  // batch. No burst allowance: repeated requests cannot create free work.
  const lastAt = afk ? Math.max(ledger.lastAt, now - windowMs) + accepted * actionMs(def) : now;
  return { ok: true, accepted, ledger: { lastAt, hourStart, hourActions: hourActions + accepted } };
}

// ── Bag placement (shared by the server grant and the offline mock) ──────────

export const BAG_SLOTS = 24;
/** Gathered materials stack to this many (migration 002 sets max_stack_size to match). */
export const MATERIAL_STACK = 250;

export interface BagRow {
  slot: number;
  itemId: string;
  qty: number;
}

export interface Placement {
  /** Stacks topped up: slot → new quantity. */
  updates: { slot: number; qty: number }[];
  /** New rows in free slots. */
  inserts: BagRow[];
  stored: ItemGrant[];
  rejected: ItemGrant[];
}

/**
 * Where a grant lands: top up existing stacks, then fill free slots 0–23.
 * `maxStack(itemId)` returns 1 for gear. Anything that doesn't fit is rejected.
 */
export function placeItems(bag: BagRow[], grants: ItemGrant[], maxStack: (itemId: string) => number): Placement {
  const rows = bag.map((r) => ({ ...r }));
  const touched = new Map<number, number>();
  const inserts: BagRow[] = [];
  const stored: ItemGrant[] = [];
  const rejected: ItemGrant[] = [];
  const used = new Set(rows.map((r) => r.slot));
  for (const g of grants) {
    let left = g.qty;
    const cap = Math.max(1, maxStack(g.itemId));
    for (const r of [...rows, ...inserts]) {
      if (left <= 0) break;
      if (r.itemId !== g.itemId || r.qty >= cap) continue;
      const add = Math.min(left, cap - r.qty);
      r.qty += add;
      left -= add;
      if (rows.includes(r)) touched.set(r.slot, r.qty);
    }
    for (let s = 0; s < BAG_SLOTS && left > 0; s++) {
      if (used.has(s)) continue;
      const add = Math.min(left, cap);
      inserts.push({ slot: s, itemId: g.itemId, qty: add });
      used.add(s);
      left -= add;
    }
    if (g.qty - left > 0) stored.push({ itemId: g.itemId, qty: g.qty - left });
    if (left > 0) rejected.push({ itemId: g.itemId, qty: left });
  }
  return { updates: [...touched].map(([slot, qty]) => ({ slot, qty })), inserts, stored, rejected };
}
