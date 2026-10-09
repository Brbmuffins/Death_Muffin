/**
 * Server authority, step 2: kill reports. Pure rules shared by the Death Muffin backend (kills.cjs, bundled into
 * gathering/kill-rules.cjs by `npm run build:server-rules`), the browser's reporter and the tests.
 *
 * The browser still plays the sim and rolls every kill. What changes is that it must also REPORT each kill (what died, where, how old,
 * elite or not) in small batches. The server validates the batch against the real time that passed and against the game's own tables,
 * and from the valid part derives what those kills were WORTH: kills per ground, XP, gold, soul shards, Depths floors. Those are
 * credits; the save routes (level/XP/gold, necromancer kills/shards, Chronicle, leaderboard) can only be paid out of them.
 *
 * XP is deterministic in the game (loot.ts rollKill), so the server's number is exact. Gold and shards are random draws: the credit is the
 * BEST roll the game could have made (ELITE shards 2, a gold roll's top end), so an honest client is never short and a cheater never gets more
 * than the luckiest honest player. docs/SERVER-AUTHORITY.md "Step 2" has the whole design.
 */

import { AREAS, AREA_ORDER, type AreaId } from '../content/areas';
import { ASCENSION } from '../content/ascension';
import { BOSSES, type BossId } from '../content/bosses';
import { CHEST_KILLS, DEPTHS, FLOOR_BONUS_KILLS, chestBonus, depthEliteBonus, depthEnemyLevel, depthRoster, floorBonus, hasChest } from '../content/depths';
import { DIFFICULTIES, type Difficulty } from '../content/difficulty';
import { ELITE, ENEMIES, WAVE_THEMES, type EnemyId } from '../content/enemies';
import { WAVE_UPGRADE, waveModifiers } from '../content/upgrades';
import { AREA_PEAK, AUTHORITY, DEPTHS_AUTHORITY } from './authorityRules';
import { CHAIN } from './killChain';
import { newBloodXpMult } from './newBloodTuning';

// ── Limits ────────────────────────────────────────────────────────────────────────────────────────────────────────────

export const KILLS = {
  /** Kill-rate ceiling: this many times the best honest kills/min of the best ground the character has open (AREA_PEAK.kills). */
  RATE_HEADROOM: 1.5,
  /** Idle time banks for at most this long, so a character that sat out an hour cannot report an hour of kills in one batch. */
  BANK_MINUTES: 30,
  /** A character the ledger has not seen starts with this many minutes in the bank. */
  FIRST_MINUTES: 5,
  /** Shape limits for one report (a flush every 45 s carries well under this). */
  MAX_GROUPS: 160,
  MAX_BOSSES: 12,
  MAX_FLOORS: 60,
  MAX_PER_GROUP: 6000,
  MAX_PER_REPORT: 12000,
  /** A sequence number may not be this far (ms) ahead of the server clock. */
  SEQ_FUTURE_SLACK_MS: 10 * 60_000,
  /** A kill-mix may exceed a ground's own (and its processions') spawn weights by this factor plus a flat allowance (packs, thralls, Risen raised from corpses, luck). */
  MIX_FACTOR: 2,
  MIX_FLAT: 12,
  /** Non-roster dead that really die in a ground: raised Risen and a Deacon's penitents. They may be this share of the batch plus the flat allowance. */
  EXTRA_SHARE: 0.35,
  /** Elites may be this factor above the best honest elite chance of the ground, plus a flat allowance. */
  ELITE_FACTOR: 2,
  ELITE_FLAT: 6,
  /** The stored hero level lags the real one by up to a save (a level-up flushes the report first, but two saves can cross); the Depths' enemy level reads it with this much slack. */
  HERO_LEVEL_SLACK: 15,
  /** A level may be this far above the highest the ground could serve. Exact by default: the sim's enemy level is area level plus Ascension, so there is nothing to forgive. */
  LEVEL_SLACK: 0,
  /** Lump-sum XP that is not a kill: a rounding and race allowance. Refills at this many XP per minute up to LUMP_XP_CAP. */
  LUMP_XP_PER_MIN: 300,
  LUMP_XP_CAP: 3000,
  /** Non-kill gold (labour, contracts, milestones, a Grave Surge, gathering finds). Refills like the step-1 non-combat rate. */
  LUMP_GOLD_PER_MIN: AUTHORITY.NONCOMBAT_GOLD_PER_MIN,
  LUMP_GOLD_CAP: AUTHORITY.NONCOMBAT_GOLD_PER_MIN * 60 + AUTHORITY.GOLD_BURST,
  /** Boss kills: an honest fight takes 2-3 minutes (summon, fight), so 0.5/min is generous; this many times it, banked for BOSS_BANK_MINUTES. */
  BOSS_PER_MIN: 0.5,
  BOSS_HEADROOM: 3,
  BOSS_BANK_MINUTES: 10,
  /** Floor clears: the step-1 pace ceiling of the Depths (content/depths.ts FLOORS_PER_MIN_CEILING) times this, banked for FLOOR_BANK_MINUTES. */
  FLOOR_HEADROOM: 2,
  FLOOR_BANK_MINUTES: 20,
  /** Play time (Chronicle playSeconds) may rise by at most real elapsed seconds, banked this long, plus a flat slack for a flush that lands late. */
  PLAY_BANK_SECONDS: 3600,
  PLAY_FIRST_SECONDS: 180,
  /** Depth: a floor that is cleared proves the next one; a peak may sit this far past the deepest proven floor (the flush race). */
  DEPTH_PEAK_SLACK: 1,
} as const;

export type Mode = 'off' | 'audit' | 'enforce';

// ── Report shape ──────────────────────────────────────────────────────────────────────────────────────────────────────

/** Kills of one kind. `xpMult`/`goldMult` are the client's own multipliers beyond rollKill (Ascension, chain, Omen, tonic, catch-up). */
export interface KillGroup {
  area: string;
  def: string;
  level: number;
  elite: boolean;
  tier: number;
  diff: string;
  /** Ascension rank of the world (a guest fights in the host's). */
  rank: number;
  xpMult: number;
  goldMult: number;
  /** Shard multiplier (the Omen of the Tolling). */
  shardMult: number;
  n: number;
}
export interface BossKill {
  boss: string;
  tier: number;
  diff: string;
  /** First kill of this boss for the character (browser trophy record): two more shards. */
  first: boolean;
  /** An Empowered boss (goldSinkRules): the id of the bound summon (empowered_summons) this kill ends, so the prize claim can be tied to a reported kill. */
  summon?: number;
  n: number;
}
export interface FloorClear {
  depth: number;
  level: number;
  /** The floor's stair opened (its quota was met): pays the floor bonus and proves the next depth. */
  clear: boolean;
  /** The floor's chest was opened (a depth that has one): pays the chest bonus. One entry may be both, or either. */
  chest: boolean;
  /** rewardMult of the clear (Ascension x Omen). */
  mult: number;
}
export interface KillReport {
  seq: number;
  groups: KillGroup[];
  bosses: BossKill[];
  floors: FloorClear[];
}

const int = (v: unknown, lo: number, hi: number, d = lo): number => {
  const n = Math.trunc(Number(v));
  return Number.isFinite(n) ? Math.max(lo, Math.min(hi, n)) : d;
};
const real = (v: unknown, lo: number, hi: number, d = 1): number => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.max(lo, Math.min(hi, n)) : d;
};

/** Normalise untrusted JSON into a KillReport (shape and numeric bounds only; the rules below judge meaning). Returns null when it is not a report at all. */
export function parseKillReport(raw: unknown): KillReport | null {
  if (!raw || typeof raw !== 'object') return null;
  const r = raw as Record<string, unknown>;
  const seq = Math.trunc(Number(r.seq));
  if (!Number.isFinite(seq) || seq <= 0) return null;
  const arr = (v: unknown, max: number): unknown[] => (Array.isArray(v) ? v.slice(0, max) : []);
  const groups: KillGroup[] = [];
  for (const g of arr(r.groups, KILLS.MAX_GROUPS)) {
    if (!g || typeof g !== 'object') continue;
    const x = g as Record<string, unknown>;
    const n = int(x.n, 0, KILLS.MAX_PER_GROUP, 0);
    if (!n || typeof x.area !== 'string' || typeof x.def !== 'string') continue;
    groups.push({
      area: x.area, def: x.def, level: int(x.level, 1, 2000, 1), elite: x.elite === true || x.elite === 1, tier: int(x.tier, 0, 99, 0),
      diff: typeof x.diff === 'string' ? x.diff : 'medium', rank: int(x.rank, 0, 99, 0),
      xpMult: real(x.xpMult, 0, 50, 1), goldMult: real(x.goldMult, 0, 50, 1), shardMult: real(x.shardMult, 0, 50, 1), n,
    });
  }
  const bosses: BossKill[] = [];
  for (const b of arr(r.bosses, KILLS.MAX_BOSSES)) {
    if (!b || typeof b !== 'object') continue;
    const x = b as Record<string, unknown>;
    const n = int(x.n, 0, 20, 0);
    if (!n || typeof x.boss !== 'string') continue;
    const summon = int(x.summon, 0, Number.MAX_SAFE_INTEGER, 0);
    bosses.push({ boss: x.boss, tier: int(x.tier, 0, 99, 0), diff: typeof x.diff === 'string' ? x.diff : 'medium', first: x.first === true, ...(summon ? { summon } : {}), n });
  }
  const floors: FloorClear[] = [];
  for (const f of arr(r.floors, KILLS.MAX_FLOORS)) {
    if (!f || typeof f !== 'object') continue;
    const x = f as Record<string, unknown>;
    const clear = x.clear !== false;
    const chest = x.chest === true;
    if (!clear && !chest) continue;
    floors.push({ depth: int(x.depth, 1, 999, 1), level: int(x.level, 1, 2000, 1), clear, chest, mult: real(x.mult, 0, 20, 1) });
  }
  return { seq, groups, bosses, floors };
}

// ── What a kill is worth ──────────────────────────────────────────────────────────────────────────────────────────────

const isDifficulty = (d: string): d is Difficulty => d in DIFFICULTIES;
const isBoss = (b: string): b is BossId => b in BOSSES;

/** XP of one kill before the client's own multipliers: loot.ts rollKill's formula, exactly. */
export function killXpBase(def: EnemyId, level: number, elite: boolean, tier: number, diff: Difficulty): number {
  const d = ENEMIES[def];
  return d.xp * (1 + 0.25 * (level - 1)) * waveModifiers(tier).xpMult * DIFFICULTIES[diff].rewardMult * (elite ? ELITE.xpMult : 1);
}
/** The best gold roll of one kill before the client's own multipliers (the top of the enemy's range). */
export function killGoldMax(def: EnemyId, level: number, elite: boolean, tier: number, diff: Difficulty): number {
  const d = ENEMIES[def];
  return d.gold[1] * (1 + 0.15 * (level - 1)) * waveModifiers(tier).rewardMult * DIFFICULTIES[diff].rewardMult * (elite ? ELITE.goldMult : 1);
}
/** The most soul shards one elite can shed (rollKill: 1, or 2 on a 25% roll). */
export const ELITE_SHARDS_MAX = 2;

/** Highest multipliers the client could honestly apply on top of rollKill, so a claimed `xpMult` is capped, never trusted. */
export function multCaps(rank: number, heroLevel: number): { xp: number; gold: number; shard: number } {
  const r = Math.min(ASCENSION.maxRank, Math.max(0, rank) + AUTHORITY.COOP_RANK_ALLOWANCE);
  const asc = 1 + ASCENSION.rewardPerRank * r;
  const gold = asc * AUTHORITY.CHAIN * AUTHORITY.OMEN;
  return { gold, xp: gold * AUTHORITY.WISDOM * newBloodXpMult('new_blood', heroLevel), shard: 2 };
}

/** Highest chain multiplier the client can apply (a Requiem chain); multCaps uses AUTHORITY.CHAIN, the same number. */
export const CHAIN_MAX = 1 + Math.max(...CHAIN.tiers.map((t) => t.bonus));

// ── Which ground, which dead, how old ─────────────────────────────────────────────────────────────────────────────────

export const isCombatGround = (id: string): id is AreaId => id in AREAS && !AREAS[id as AreaId].safe;

/** The dead a ground serves: its spawn table, the processions that visit it (30% of waves arrive as a themed band, with a lead), plus the two kinds that arrive outside both (raised Risen, a Deacon's penitents). Depths: the deepest roster. */
export function rosterIds(area: AreaId, deepest = 0): Set<string> {
  const base = area === 'depths' ? depthRoster(Math.max(1, deepest)) : AREAS[area].enemies;
  const out = new Set<string>(base.map((e) => e.id));
  for (const t of WAVE_THEMES[area] ?? []) {
    for (const e of t.roster) out.add(e.id);
    if (t.lead) out.add(t.lead);
  }
  out.add('risen');
  out.add('penitent');
  return out;
}

/**
 * The highest enemy level a ground can serve a character: its own level aged by Ascension (a co-op guest fights in the host's world, so the
 * record's rank plus the step-1 co-op allowance). A level-scaled ground follows the strongest hero in the world; here that is the character's
 * own level with HERO_LEVEL_SLACK, the same assumption the step-1 ceilings make (a guest in a much stronger host's scaled ground is paid at their own level).
 */
export function maxEnemyLevel(area: AreaId, heroLevel: number, rank: number, deepest = 0): number {
  const a = AREAS[area];
  const aged = Math.min(ASCENSION.maxRank, rank + AUTHORITY.COOP_RANK_ALLOWANCE) * ASCENSION.levelsPerRank;
  if (area === 'depths') return depthEnemyLevel(Math.min(DEPTHS_AUTHORITY.maxDepth, deepest + DEPTHS_AUTHORITY.slack), heroLevel + KILLS.HERO_LEVEL_SLACK) + aged + KILLS.LEVEL_SLACK;
  const base = a.scaling ? Math.max(a.scaling.minLevel, Math.min(255, heroLevel + KILLS.HERO_LEVEL_SLACK)) : a.level;
  return base + aged + KILLS.LEVEL_SLACK;
}

/** The best honest elite share of a ground (its own chance, Wave Speed 8, Hard, the Omen, and on the Depths the floor's bonus). */
export function maxEliteShare(area: AreaId, deepest = 0): number {
  const bonus = 0.004 * WAVE_UPGRADE.maxTier + DIFFICULTIES.hard.eliteBonus + 0.06 + (area === 'depths' ? depthEliteBonus(Math.min(DEPTHS_AUTHORITY.maxDepth, deepest + DEPTHS_AUTHORITY.slack)) : 0);
  return Math.min(1, AREAS[area].eliteChance + bonus);
}

/**
 * How many of `n` kills of each enemy kind a ground can honestly produce. A kind's best honest share is the larger of its share of the ground's own
 * spawn weights and its share of any procession that visits (a whole batch can be one themed band), pack kinds counting for their pack size, a
 * procession's lead for a fixed quarter. The allowance is that share times MIX_FACTOR plus a flat amount. Kinds outside the ground are not in the map.
 */
export function mixAllowance(area: AreaId, total: number, deepest = 0): Map<string, number> {
  const share = new Map<string, number>();
  const bump = (id: string, v: number) => share.set(id, Math.max(share.get(id) ?? 0, v));
  const weigh = (list: readonly { id: string; weight: number }[]) => {
    const eff = list.map((e) => {
      const pack = ENEMIES[e.id as EnemyId]?.pack;
      return { id: e.id, w: e.weight * (pack ? (pack[0] + pack[1]) / 2 : 1) };
    });
    const sum = eff.reduce((n, e) => n + e.w, 0) || 1;
    for (const e of eff) bump(e.id, e.w / sum);
  };
  weigh(area === 'depths' ? depthRoster(Math.max(1, deepest + DEPTHS_AUTHORITY.slack)) : AREAS[area].enemies);
  for (const t of WAVE_THEMES[area] ?? []) {
    weigh(t.roster);
    if (t.lead) bump(t.lead, 0.25);
  }
  const out = new Map<string, number>();
  for (const [id, v] of share) out.set(id, Math.ceil(v * total * KILLS.MIX_FACTOR) + KILLS.MIX_FLAT);
  for (const extra of ['risen', 'penitent']) if (!out.has(extra)) out.set(extra, Math.ceil(total * KILLS.EXTRA_SHARE) + KILLS.MIX_FLAT);
  return out;
}

/** Kills per real minute the ledger believes in, for the best ground in `unlocked` (the Depths count when the Warren is open). */
export function killsPerMin(unlocked: readonly string[]): number {
  let best = 0;
  for (const id of AREA_ORDER) {
    const peak = AREA_PEAK[id];
    if (!peak || !unlocked.includes(id === 'depths' ? 'warren' : id)) continue;
    if (peak.kills > best) best = peak.kills;
  }
  return Math.ceil(Math.max(best, AREA_PEAK.graves?.kills ?? 0) * KILLS.RATE_HEADROOM);
}

// ── Evaluating a report ───────────────────────────────────────────────────────────────────────────────────────────────

export interface Credits {
  /** Per-ground kills the character may claim in a necromancer save. */
  kills: Record<string, number>;
  xp: number;
  gold: number;
  shards: number;
  /** Bell-Sworn Prelate kills a necromancer save may claim (the leaderboard's boss kills and the Altar's key). */
  prelate: number;
}
export interface Finding {
  kind: string;
  [k: string]: unknown;
}
export interface KillContext {
  unlocked: readonly string[];
  ascension: number;
  heroLevel: number;
  /** Deepest floor the ledger has proven (grandfathered from the Chronicle at first sight). */
  deepest: number;
  /** Kills the ledger will still believe right now (the bucket after refill). */
  killBucket: number;
  bossBucket: number;
  floorBucket: number;
  /** The highest floor already cleared (proven), so a clear needs its predecessor. */
  maxCleared: number;
  staff: boolean;
}
export interface Evaluation {
  credits: Credits;
  /** Kills accepted overall, bosses accepted, floors accepted (for the buckets). */
  killsAccepted: number;
  bossesAccepted: number;
  floorsAccepted: number;
  /** The deepest floor this report proves (cleared depth + 1), or 0. */
  depthProved: number;
  findings: Finding[];
}

const emptyCredits = (): Credits => ({ kills: {}, xp: 0, gold: 0, shards: 0, prelate: 0 });

/** Whether a ground's kills may be reported by a character that has `unlocked` (a seal that this batch opens counts: the previous ground must be open). */
export function groundOpen(area: AreaId, unlocked: readonly string[]): boolean {
  if (area === 'depths') return unlocked.includes('warren');
  const a = AREAS[area];
  if (!a.unlock && !a.instance) return true;
  if (unlocked.includes(area)) return true;
  return !!a.unlock && (unlocked.includes(a.unlock.area) || !AREAS[a.unlock.area].unlock);
}

/**
 * Judge a report. Pure: no clock, no database. Everything over the character's bucket, outside the game's tables or off its mix is
 * dropped and named in `findings`; what is left is converted into credits. `staff` reports are credited whole (dev access) but still named.
 */
export function evaluateKillReport(report: KillReport, ctx: KillContext): Evaluation {
  const findings: Finding[] = [];
  const credits = emptyCredits();
  let budget = ctx.staff ? Infinity : Math.floor(ctx.killBucket);
  let killsAccepted = 0;
  const heroLevel = Math.max(1, ctx.heroLevel);

  // Pass 1: shape per group (ground, kind, level, multipliers) and the ground's totals for the mix and elite rules.
  type Ok = KillGroup & { id: AreaId; diffId: Difficulty };
  const ok: Ok[] = [];
  const rejected = { ground: 0, kind: 0, level: 0, difficulty: 0 };
  for (const g of report.groups) {
    if (!isCombatGround(g.area) || !groundOpen(g.area, ctx.unlocked)) { rejected.ground += g.n; continue; }
    const id = g.area as AreaId;
    if (!(g.def in ENEMIES) || ENEMIES[g.def as EnemyId].inert || !rosterIds(id, ctx.deepest + DEPTHS_AUTHORITY.slack).has(g.def)) { rejected.kind += g.n; continue; }
    if (g.level > maxEnemyLevel(id, heroLevel, ctx.ascension, ctx.deepest)) { rejected.level += g.n; continue; }
    if (!isDifficulty(g.diff)) { rejected.difficulty += g.n; continue; }
    ok.push({ ...g, id, diffId: g.diff as Difficulty });
  }
  for (const [why, n] of Object.entries(rejected)) if (n > 0) findings.push({ kind: 'kill_invalid', why, kills: n });

  // Mix and elite share per ground, over the batch.
  const byArea = new Map<AreaId, Ok[]>();
  for (const g of ok) byArea.set(g.id, [...(byArea.get(g.id) ?? []), g]);
  const allowed = new Map<Ok, number>();
  for (const [id, groups] of byArea) {
    const total = groups.reduce((n, g) => n + g.n, 0);
    // Dev access plays outside the mix and the elite share (it summons what it likes); it is still named in the audit by its own reports.
    if (ctx.staff) { for (const g of groups) allowed.set(g, g.n); continue; }
    const mix = mixAllowance(id, total, ctx.deepest);
    const left = new Map(mix);
    const eliteShare = maxEliteShare(id, ctx.deepest);
    let eliteLeft = Math.ceil(total * eliteShare * KILLS.ELITE_FACTOR) + KILLS.ELITE_FLAT;
    let mixDropped = 0;
    let eliteDropped = 0;
    // Non-elites first, so the cap on elites bites the rich kills and not the plain ones.
    for (const g of [...groups].sort((a, b) => Number(a.elite) - Number(b.elite))) {
      let n = g.n;
      const room = left.get(g.def) ?? 0;
      if (n > room) { mixDropped += n - room; n = room; }
      left.set(g.def, room - n);
      if (g.elite) {
        if (n > eliteLeft) { eliteDropped += n - eliteLeft; n = eliteLeft; }
        eliteLeft -= n;
      }
      allowed.set(g, n);
    }
    if (mixDropped > 0) findings.push({ kind: 'kill_mix', area: id, dropped: mixDropped, of: total });
    if (eliteDropped > 0) findings.push({ kind: 'kill_elite', area: id, dropped: eliteDropped, of: total, share: eliteShare });
  }

  // Pass 2: the time bucket, in report order, then the value of what is left.
  let overRate = 0;
  const caps = multCaps(Math.max(ctx.ascension, 0), heroLevel);
  const nb = newBloodXpMult('new_blood', heroLevel);
  for (const g of ok) {
    let n = allowed.get(g) ?? 0;
    if (n > budget) { overRate += n - budget; n = Math.max(0, budget); }
    budget -= n;
    if (n <= 0) continue;
    killsAccepted += n;
    const xpMult = Math.min(g.xpMult, caps.xp);
    const goldMult = Math.min(g.goldMult, caps.gold);
    const xpEach = Math.round(Math.round(killXpBase(g.def as EnemyId, g.level, g.elite, Math.min(g.tier, WAVE_UPGRADE.maxTier), g.diffId)) * xpMult);
    const goldEach = Math.round(Math.round(killGoldMax(g.def as EnemyId, g.level, g.elite, Math.min(g.tier, WAVE_UPGRADE.maxTier), g.diffId)) * goldMult);
    credits.xp += xpEach * n;
    credits.gold += goldEach * n;
    if (g.elite) credits.shards += Math.ceil(ELITE_SHARDS_MAX * Math.min(g.shardMult, caps.shard)) * n;
    credits.kills[g.id] = (credits.kills[g.id] ?? 0) + n;
  }
  if (overRate > 0) findings.push({ kind: 'kill_rate', dropped: overRate, bucket: Math.floor(ctx.killBucket) });

  // Bosses: bounded by their own bucket; each pays its shard-cost's worth of gold, XP and shards (loot.ts rollBoss).
  let bossBudget = ctx.staff ? Infinity : Math.floor(ctx.bossBucket);
  let bossesAccepted = 0;
  for (const b of report.bosses) {
    if (!isBoss(b.boss) || !isDifficulty(b.diff)) { findings.push({ kind: 'boss_invalid', boss: b.boss }); continue; }
    const def = BOSSES[b.boss];
    if (!groundOpen(def.area, ctx.unlocked)) { findings.push({ kind: 'boss_invalid', boss: b.boss, why: 'ground' }); continue; }
    const n = Math.min(b.n, Math.max(0, bossBudget));
    if (n < b.n) findings.push({ kind: 'boss_rate', boss: b.boss, claimed: b.n, accepted: n });
    bossBudget -= n;
    if (n <= 0) continue;
    bossesAccepted += n;
    if (b.boss === 'prelate') credits.prelate += n;
    const k = def.shards / 5;
    const tier = Math.min(b.tier, WAVE_UPGRADE.maxTier);
    credits.gold += Math.round(320 * k * waveModifiers(tier).rewardMult * DIFFICULTIES[b.diff as Difficulty].rewardMult) * n;
    // Boss XP and gold are not scaled by Ascension, chain or the Omen (WorldScene boss handler); only the New Blood catch-up applies to XP (gainXp).
    credits.xp += Math.round(Math.round(900 * k * DIFFICULTIES[b.diff as Difficulty].rewardMult) * nb) * n;
    credits.shards += ((def.shards >= 5 ? 3 : Math.max(1, def.shards - 1)) + (b.first && b.boss !== 'prelate' ? 2 : 0)) * n;
  }

  // Depths floors: each clear proves the next depth; a clear needs its predecessor cleared before (or in this batch).
  let floorBudget = ctx.staff ? Infinity : Math.floor(ctx.floorBucket);
  let floorsAccepted = 0;
  let maxCleared = ctx.maxCleared;
  let depthProved = 0;
  if (report.floors.length && !ctx.unlocked.includes('warren') && !ctx.staff) findings.push({ kind: 'floor_invalid', why: 'warren sealed', floors: report.floors.length });
  else {
    for (const f of [...report.floors].sort((a, b) => a.depth - b.depth)) {
      if (!ctx.staff && f.depth > maxCleared + 1) { findings.push({ kind: 'floor_invalid', depth: f.depth, why: 'skipped floors', maxCleared }); continue; }
      if (floorBudget < 1) { findings.push({ kind: 'floor_rate', depth: f.depth }); continue; }
      if (f.level > depthEnemyLevel(f.depth, heroLevel + KILLS.HERO_LEVEL_SLACK) + ASCENSION.maxRank * ASCENSION.levelsPerRank + KILLS.LEVEL_SLACK && !ctx.staff) { findings.push({ kind: 'floor_invalid', depth: f.depth, why: 'level' }); continue; }
      floorBudget -= 1;
      const mult = Math.min(f.mult, multCaps(ctx.ascension, heroLevel).gold / AUTHORITY.CHAIN);
      if (f.clear) {
        floorsAccepted += 1;
        maxCleared = Math.max(maxCleared, f.depth);
        depthProved = Math.max(depthProved, f.depth + 1);
        const fb = floorBonus(f.depth, f.level);
        credits.gold += Math.round(fb.gold * mult);
        credits.xp += Math.round(Math.round(fb.xp * mult) * nb);
      }
      if (f.chest && hasChest(f.depth)) {
        const cb = chestBonus(f.depth, f.level);
        credits.gold += Math.round(cb.gold * mult);
        credits.xp += Math.round(Math.round(cb.xp * mult) * nb);
      }
    }
  }
  return { credits, killsAccepted, bossesAccepted, floorsAccepted, depthProved, findings };
}

/** Kills per minute and boss/floor bank sizes for the ledger buckets. */
export function bucketCaps(unlocked: readonly string[]) {
  const perMin = killsPerMin(unlocked);
  return {
    killPerMin: perMin,
    killCap: perMin * KILLS.BANK_MINUTES,
    bossPerMin: KILLS.BOSS_PER_MIN * KILLS.BOSS_HEADROOM,
    bossCap: Math.ceil(KILLS.BOSS_PER_MIN * KILLS.BOSS_HEADROOM * KILLS.BOSS_BANK_MINUTES),
    floorPerMin: 3 * KILLS.FLOOR_HEADROOM,
    floorCap: 3 * KILLS.FLOOR_HEADROOM * KILLS.FLOOR_BANK_MINUTES,
  };
}

/** Exported so tests can read the constants that ride on the floors. */
export const FLOOR_RULES = { FLOOR_BONUS_KILLS, CHEST_KILLS, chestEvery: DEPTHS.chestEvery };

/** The rank a character plays at, from its sworn vows (the backend stores vows; the ceilings above take a rank). */
export { vowHeat } from '../content/ascension';
