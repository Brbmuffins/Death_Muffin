import { AREAS, AREA_ORDER, BOSS_SUMMON_SHARDS, type AreaId } from '../content/areas';
import { BOONS, VOWS, VOW_ORDER, ashesForRun, boonBlocked, boonCost, boonEffects, isUnlocked, legacyVows, unlockCost, vowHeat, vowKey, vowSteps, type BoonId, type BoonRanks, type VowId, type VowRanks } from '../content/ascension';
import { DAMAGE_UPGRADE, LEGION_UPGRADE, WAVE_UPGRADE } from '../content/upgrades';
import { BOSSES, isBossId } from '../content/bosses';

/**
 * Necromancer progression rules — the ONE source of truth shared by the
 * client, the DEV offline backend and the VPS. `npm run build:server-rules`
 * bundles this file (and the content it imports) into
 * `server/vps-handoff/necro-progress/necro-rules.cjs` for the auth server;
 * a unit test fails if that copy is stale.
 *
 * Pure functions only: every rule takes a state (plus the character's gold
 * where money moves) and returns a new state or a player-readable error. The
 * server wraps each call in a row-locked transaction.
 */

export interface NecroState {
  damageTier: number;
  waveTierOwned: number;
  waveTierActive: number;
  /** Legion reinforcement tiers bought this run (gold sink for the thrall kit; resets on Ascension like the other tiers). */
  legionTier: number;
  soulShards: number;
  areaKills: Partial<Record<AreaId, number>>;
  unlockedAreas: AreaId[];
  bossKills: number;
  totalKills: number;
  /** BEST Ascension rank completed (the heat of the richest run burned at the Altar): leaderboard and titles. The rank a run plays at is vowHeat(vows). */
  ascension: number;
  ashes: number;
  boons: BoonRanks;
  /** Vows sworn for the run in progress (they stay sworn across Ascensions until the player changes them). */
  vows: VowRanks;
  /** Vows and boons opened with soul shards ("vow:<id>" / "boon:<id>"); free ones need no entry. */
  unlocks: string[];
  run: { prelateKills: number; peakWaveTier: number; kills: number };
  /** Prelate summons paid for but not yet reported as kills (a kill must follow a summon). */
  summonsPending: number;
  /** The one-time browser-save import has happened. */
  migrated: boolean;
}

/** Per-request ceilings. Saves arrive every ~45 s and on area change / tab hide. */
export const NECRO_LIMITS = {
  killsPerSave: 900,
  shardsPerSave: 30,
  // One-time import of a browser save (browser storage is editable, so it is clamped hard).
  importMaxShards: 40,
  importMaxAreaKills: 20000,
  importMaxBossKills: 200,
  importMaxAscension: 5,
  importMaxAshes: 400,
};

export type RuleResult<T = object> = ({ ok: true; state: NecroState } & T) | { ok: false; error: string };

const clampInt = (v: unknown, lo: number, hi: number) => {
  const n = Math.floor(Number(v));
  return Number.isFinite(n) ? Math.max(lo, Math.min(hi, n)) : lo;
};

export function blankState(): NecroState {
  return {
    damageTier: 0,
    waveTierOwned: 0,
    waveTierActive: 0,
    legionTier: 0,
    soulShards: 0,
    areaKills: {},
    unlockedAreas: ['chapterhouse', 'graves'],
    bossKills: 0,
    totalKills: 0,
    ascension: 0,
    ashes: 0,
    boons: {},
    vows: {},
    unlocks: [],
    run: { prelateKills: 0, peakWaveTier: 0, kills: 0 },
    summonsPending: 0,
    migrated: false,
  };
}

const copy = (s: NecroState): NecroState => ({
  ...s,
  areaKills: { ...s.areaKills },
  unlockedAreas: [...s.unlockedAreas],
  boons: { ...s.boons },
  vows: { ...s.vows },
  unlocks: [...s.unlocks],
  run: { ...s.run },
});

// --- Derived rules ----------------------------------------------------------

export function damageCost(s: NecroState): number | null {
  if (s.damageTier >= DAMAGE_UPGRADE.maxTier) return null;
  return Math.round(DAMAGE_UPGRADE.cost(s.damageTier) * boonEffects(s.boons).damageCostMult);
}

export function waveCost(s: NecroState): number | null {
  if (s.waveTierOwned >= WAVE_UPGRADE.maxTier) return null;
  return Math.round(WAVE_UPGRADE.cost(s.waveTierOwned) * boonEffects(s.boons).waveCostMult);
}

export function legionCost(s: NecroState): number | null {
  if (s.legionTier >= LEGION_UPGRADE.maxTier) return null;
  return LEGION_UPGRADE.cost(s.legionTier);
}

/** Kills needed in the area before `id`'s seal breaks (Swift Seals lowers it). */
export function unlockKills(s: NecroState, id: AreaId): number | null {
  const u = AREAS[id].unlock;
  return u ? Math.max(1, Math.round(u.kills * boonEffects(s.boons).unlockKillsMult)) : null;
}

/**
 * Staff (dev access: `gm_enabled` / admin / gm accounts) stand past every seal: their kills count and their summons work
 * in any area, without their saved `unlockedAreas` changing. Everyone else opens seals with kills.
 */
export interface RuleOpts {
  staff?: boolean;
}
const isOpen = (s: NecroState, id: AreaId, opts?: RuleOpts) => !!opts?.staff || s.unlockedAreas.includes(id);

/** Re-derive opened seals from kill counts (never closes one already open this run). */
function openSeals(s: NecroState) {
  for (const id of AREA_ORDER) {
    const u = AREAS[id].unlock;
    if (!u || s.unlockedAreas.includes(id)) continue;
    if ((s.areaKills[u.area] ?? 0) >= unlockKills(s, id)! && s.unlockedAreas.includes(u.area)) s.unlockedAreas.push(id);
  }
}

// --- Mutations ---------------------------------------------------------------

export interface SaveInput {
  waveTierActive?: number;
  /** Kills since the last save, per area. */
  areaKills?: Partial<Record<AreaId, number>>;
  /** Soul shards picked up since the last save. */
  shards?: number;
  /** Prelate kills since the last save (each must follow a paid summon). */
  prelateKills?: number;
  /** Highest Wave Speed tier the kills were fought at. */
  peakWaveTier?: number;
}

/** Merge a periodic save: clamped deltas, derived unlocks. Never fails (bad input is clamped away). */
export function applySave(state: NecroState, input: SaveInput, opts?: RuleOpts): RuleResult {
  const s = copy(state);
  let budget = NECRO_LIMITS.killsPerSave;
  let kills = 0;
  for (const id of AREA_ORDER) {
    const n = Math.min(budget, clampInt(input.areaKills?.[id], 0, budget));
    // Kills only count where the character can actually be.
    if (!n || AREAS[id].safe || !isOpen(s, id, opts)) continue;
    s.areaKills[id] = (s.areaKills[id] ?? 0) + n;
    budget -= n;
    kills += n;
  }
  s.totalKills += kills;
  s.run.kills += kills;
  s.soulShards += clampInt(input.shards, 0, NECRO_LIMITS.shardsPerSave);
  const prelate = Math.min(clampInt(input.prelateKills, 0, 10), s.summonsPending);
  s.summonsPending -= prelate;
  s.bossKills += prelate;
  s.run.prelateKills += prelate;
  if (kills > 0) s.run.peakWaveTier = Math.max(s.run.peakWaveTier, clampInt(input.peakWaveTier, 0, s.waveTierOwned));
  if (input.waveTierActive !== undefined) s.waveTierActive = clampInt(input.waveTierActive, 0, s.waveTierOwned);
  openSeals(s);
  return { ok: true, state: s };
}

export function purchase(state: NecroState, gold: number, upgrade: 'damage' | 'wave' | 'legion'): RuleResult<{ gold: number; cost: number }> {
  const s = copy(state);
  if (upgrade !== 'damage' && upgrade !== 'wave' && upgrade !== 'legion') return { ok: false, error: 'Unknown upgrade' };
  const cost = upgrade === 'damage' ? damageCost(s) : upgrade === 'wave' ? waveCost(s) : legionCost(s);
  if (cost === null) return { ok: false, error: 'Already at max tier' };
  if (gold < cost) return { ok: false, error: `Not enough gold (need ${cost})` };
  if (upgrade === 'damage') s.damageTier++;
  else if (upgrade === 'legion') s.legionTier++;
  else {
    s.waveTierOwned++;
    s.waveTierActive = s.waveTierOwned;
  }
  return { ok: true, state: s, gold: gold - cost, cost };
}

export function summonPrelate(state: NecroState, opts?: RuleOpts): RuleResult {
  if (state.soulShards < BOSS_SUMMON_SHARDS) {
    return { ok: false, error: `The Sundered Bell demands ${BOSS_SUMMON_SHARDS} soul shards (you have ${state.soulShards}).` };
  }
  if (!isOpen(state, 'sanctum', opts)) return { ok: false, error: 'The Bell Sanctum is still sealed.' };
  const s = copy(state);
  s.soulShards -= BOSS_SUMMON_SHARDS;
  s.summonsPending = Math.min(5, s.summonsPending + 1);
  return { ok: true, state: s };
}

/**
 * Area bosses (2026-09-29): spend that boss's shards; its area must be open. Unlike the Prelate this leaves
 * `summonsPending` alone, which only pays out Prelate kills (the Ascension counter).
 */
export function summonAreaBoss(state: NecroState, boss: unknown, opts?: RuleOpts): RuleResult {
  if (!isBossId(boss) || boss === 'prelate') return { ok: false, error: 'Unknown boss.' };
  const def = BOSSES[boss];
  if (state.soulShards < def.shards) {
    return { ok: false, error: `${def.summonLabel} demands ${def.shards} soul shards (you have ${state.soulShards}).` };
  }
  if (!isOpen(state, def.area, opts)) return { ok: false, error: `${AREAS[def.area].name} is still sealed.` };
  const s = copy(state);
  s.soulShards -= def.shards;
  return { ok: true, state: s };
}

/** The heat the character's sworn vows carry: the rank the current run plays at. */
export function runHeat(state: NecroState): number {
  return vowHeat(state.vows);
}

export function ashesOnAscend(state: NecroState): number {
  return ashesForRun(state.run, runHeat(state));
}

/**
 * Burn the run: damage / Wave Speed / Legion tiers and the run's tally reset, Ashes are paid for the heat the run carried and
 * the best rank rises if this run beat it. Seals, area kills and soul shards stay (2026-10-03): difficulty comes from the vows,
 * which also stay sworn until the player changes them.
 */
export function ascend(state: NecroState): RuleResult<{ earned: number; heat: number }> {
  const earned = ashesOnAscend(state);
  if (!earned) return { ok: false, error: 'Slay the Prelate this run before you Ascend.' };
  const s = copy(state);
  const fx = boonEffects(s.boons);
  const heat = runHeat(s);
  s.ascension = Math.max(s.ascension, heat);
  s.ashes += earned;
  s.damageTier = fx.startDamageTier;
  s.waveTierOwned = 0;
  s.waveTierActive = 0;
  s.legionTier = 0;
  // Unspent shards are kept (they unlock vows and boons); Shard Keeper only sets a floor.
  s.soulShards = Math.max(s.soulShards, fx.startShards);
  s.run = { prelateKills: 0, peakWaveTier: 0, kills: 0 };
  s.summonsPending = 0;
  return { ok: true, state: s, earned, heat };
}

const sameVows = (a: VowRanks, b: VowRanks) => VOW_ORDER.every((id) => vowSteps(a, id) === vowSteps(b, id));

/**
 * Swear the vows for the next run (the whole set, replacing the old one). Each vow must be unlocked and within its steps. Changing
 * the vows while this run has a tally (kills, a Prelate kill) restarts the tally, so the Ashes of a run always match the heat it
 * was fought at: nobody can fight cold and swear hot at the end.
 */
export function swearVows(state: NecroState, input: unknown): RuleResult<{ heat: number; restarted: boolean }> {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return { ok: false, error: 'Unknown vows.' };
  const raw = input as Record<string, unknown>;
  const next: VowRanks = {};
  for (const key of Object.keys(raw)) {
    if (!Object.prototype.hasOwnProperty.call(VOWS, key)) return { ok: false, error: 'Unknown vow.' };
    const id = key as VowId;
    const n = Number(raw[id]);
    if (!Number.isInteger(n) || n < 0 || n > VOWS[id].maxRank) return { ok: false, error: `${VOWS[id].name} can be sworn 0 to ${VOWS[id].maxRank} times.` };
    if (!n) continue;
    if (!isUnlocked(state.unlocks, vowKey(id))) return { ok: false, error: `${VOWS[id].name} is not unlocked yet (${VOWS[id].unlockShards} soul shards at the Altar).` };
    next[id] = n;
  }
  const s = copy(state);
  const changed = !sameVows(state.vows, next);
  s.vows = next;
  const t = s.run;
  const restarted = changed && (t.kills > 0 || t.prelateKills > 0 || t.peakWaveTier > 0);
  if (restarted) s.run = { prelateKills: 0, peakWaveTier: 0, kills: 0 };
  return { ok: true, state: s, heat: vowHeat(next), restarted };
}

/** Open a vow or a boon at the Altar for soul shards. Priced here, never by the client. */
export function unlockEntry(state: NecroState, key: unknown): RuleResult<{ cost: number }> {
  if (typeof key !== 'string') return { ok: false, error: 'Unknown unlock.' };
  const cost = unlockCost(key);
  if (cost === null || cost === 0) return { ok: false, error: 'Nothing to unlock.' };
  if (state.unlocks.includes(key)) return { ok: false, error: 'Already unlocked.' };
  if (state.soulShards < cost) return { ok: false, error: `The Altar asks ${cost} soul shards for that (you have ${state.soulShards}).` };
  const s = copy(state);
  s.soulShards -= cost;
  s.unlocks.push(key);
  return { ok: true, state: s, cost };
}

export function buyBoon(state: NecroState, id: BoonId): RuleResult<{ cost: number }> {
  if (typeof id !== 'string' || !Object.prototype.hasOwnProperty.call(BOONS, id)) return { ok: false, error: 'Unknown boon' };
  const blocked = boonBlocked(id, state.boons, state.ascension, state.unlocks);
  if (blocked) return { ok: false, error: blocked === 'Mastered' ? 'That boon is already mastered.' : blocked.startsWith('Unlock') ? `${BOONS[id].name} is not unlocked yet. ${blocked}.` : `Requires ${blocked}.` };
  const cost = boonCost(id, state.boons)!;
  if (state.ashes < cost) return { ok: false, error: `Not enough Ashes (need ${cost})` };
  const s = copy(state);
  s.ashes -= cost;
  s.boons[id] = (s.boons[id] ?? 0) + 1;
  // Starting boons also take effect for the run in progress.
  if (id === 'first_rites') s.damageTier = Math.max(s.damageTier, boonEffects(s.boons).startDamageTier);
  return { ok: true, state: s, cost };
}

/**
 * One-time import of the progress a character built up in browser storage
 * before the server stored it. Browser storage is editable, so everything is
 * clamped and cross-checked; once imported (or once the server has its own
 * record) it never runs again.
 */
export function importLocal(state: NecroState, raw: unknown): RuleResult {
  if (state.migrated) return { ok: false, error: 'Progress was already imported.' };
  const r = (raw && typeof raw === 'object' ? raw : {}) as Record<string, unknown>;
  const L = NECRO_LIMITS;
  const s = blankState();
  s.migrated = true;
  s.ascension = clampInt(r.ascension, 0, L.importMaxAscension);
  // A browser save from before Vows ran at rank N: that is N steps of Elder Dead, the same world.
  s.vows = legacyVows(s.ascension);
  s.ashes = clampInt(r.ashes, 0, L.importMaxAshes);
  // Boons: valid ids, within max rank and rank gates.
  const boons = (r.boons && typeof r.boons === 'object' ? r.boons : {}) as Record<string, unknown>;
  for (const id of Object.keys(BOONS) as BoonId[]) {
    const want = clampInt(boons[id], 0, BOONS[id].maxRank);
    // Only the boons that existed before the Vows (always open) come across; shard-unlocked ones are earned at the Altar.
    for (let i = 0; i < want && !boonBlocked(id, s.boons, s.ascension, s.unlocks); i++) s.boons[id] = (s.boons[id] ?? 0) + 1;
  }
  s.damageTier = clampInt(r.damageTier, 0, DAMAGE_UPGRADE.maxTier);
  s.waveTierOwned = clampInt(r.waveTierOwned, 0, WAVE_UPGRADE.maxTier);
  s.waveTierActive = clampInt(r.waveTierActive, 0, s.waveTierOwned);
  s.soulShards = clampInt(r.shards ?? r.soulShards, 0, L.importMaxShards);
  const kills = (r.areaKills && typeof r.areaKills === 'object' ? r.areaKills : {}) as Record<string, unknown>;
  for (const id of AREA_ORDER) {
    const n = clampInt(kills[id], 0, L.importMaxAreaKills);
    if (n && !AREAS[id].safe) s.areaKills[id] = n;
  }
  s.bossKills = clampInt(r.bossKills, 0, L.importMaxBossKills);
  s.totalKills = Math.max(
    clampInt(r.totalKills, 0, L.importMaxAreaKills * AREA_ORDER.length),
    Object.values(s.areaKills).reduce((a, b) => a + (b ?? 0), 0),
  );
  const run = (r.run && typeof r.run === 'object' ? r.run : {}) as Record<string, unknown>;
  s.run = {
    prelateKills: clampInt(run.prelateKills, 0, s.bossKills),
    peakWaveTier: clampInt(run.peakWaveTier, 0, s.waveTierOwned),
    kills: clampInt(run.kills, 0, s.totalKills),
  };
  // Seals are re-derived from kills, never trusted from the browser.
  openSeals(s);
  return { ok: true, state: s };
}

/** Normalise a stored row (older rows may miss newer fields). */
export function normalise(raw: unknown): NecroState {
  const b = blankState();
  const r = (raw && typeof raw === 'object' ? raw : {}) as Partial<NecroState>;
  // Rows from before Vows have no `vows`: their rank N becomes N steps of Elder Dead, which is exactly the world they were playing in
  // (+3 levels and +5% rewards per step), and N stays as their best rank. They keep their Ashes and every boon bought.
  const hasVows = !!r.vows && typeof r.vows === 'object' && !Array.isArray(r.vows);
  const best = clampInt(r.ascension, 0, 255);
  const vows: VowRanks = {};
  if (hasVows) for (const id of VOW_ORDER) if (vowSteps(r.vows, id)) vows[id] = vowSteps(r.vows, id);
  const unlocks = Array.isArray(r.unlocks) ? [...new Set(r.unlocks.filter((k): k is string => typeof k === 'string' && unlockCost(k) !== null && unlockCost(k)! > 0))] : [];
  return {
    ...b,
    ...r,
    ascension: best,
    legionTier: clampInt(r.legionTier, 0, LEGION_UPGRADE.maxTier),
    areaKills: { ...(r.areaKills ?? {}) },
    unlockedAreas: Array.isArray(r.unlockedAreas) && r.unlockedAreas.length ? [...r.unlockedAreas] : b.unlockedAreas,
    boons: { ...(r.boons ?? {}) },
    vows: hasVows ? vows : legacyVows(best),
    unlocks,
    run: { ...b.run, ...(r.run ?? {}) },
  };
}
