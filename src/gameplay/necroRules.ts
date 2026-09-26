import { AREAS, AREA_ORDER, BOSS_SUMMON_SHARDS, type AreaId } from '../content/areas';
import { ASCENSION, BOONS, ashesForRun, boonBlocked, boonCost, boonEffects, type BoonId, type BoonRanks } from '../content/ascension';
import { DAMAGE_UPGRADE, WAVE_UPGRADE } from '../content/upgrades';

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
  soulShards: number;
  areaKills: Partial<Record<AreaId, number>>;
  unlockedAreas: AreaId[];
  bossKills: number;
  totalKills: number;
  ascension: number;
  ashes: number;
  boons: BoonRanks;
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
    soulShards: 0,
    areaKills: {},
    unlockedAreas: ['chapterhouse', 'graves'],
    bossKills: 0,
    totalKills: 0,
    ascension: 0,
    ashes: 0,
    boons: {},
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

/** Kills needed in the area before `id`'s seal breaks (Swift Seals lowers it). */
export function unlockKills(s: NecroState, id: AreaId): number | null {
  const u = AREAS[id].unlock;
  return u ? Math.max(1, Math.round(u.kills * boonEffects(s.boons).unlockKillsMult)) : null;
}

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
export function applySave(state: NecroState, input: SaveInput): RuleResult {
  const s = copy(state);
  let budget = NECRO_LIMITS.killsPerSave;
  let kills = 0;
  for (const id of AREA_ORDER) {
    const n = Math.min(budget, clampInt(input.areaKills?.[id], 0, budget));
    // Kills only count where the character can actually be.
    if (!n || AREAS[id].safe || !s.unlockedAreas.includes(id)) continue;
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

export function purchase(state: NecroState, gold: number, upgrade: 'damage' | 'wave'): RuleResult<{ gold: number; cost: number }> {
  const s = copy(state);
  const cost = upgrade === 'damage' ? damageCost(s) : upgrade === 'wave' ? waveCost(s) : null;
  if (upgrade !== 'damage' && upgrade !== 'wave') return { ok: false, error: 'Unknown upgrade' };
  if (cost === null) return { ok: false, error: 'Already at max tier' };
  if (gold < cost) return { ok: false, error: `Not enough gold (need ${cost})` };
  if (upgrade === 'damage') s.damageTier++;
  else {
    s.waveTierOwned++;
    s.waveTierActive = s.waveTierOwned;
  }
  return { ok: true, state: s, gold: gold - cost, cost };
}

export function summonPrelate(state: NecroState): RuleResult {
  if (state.soulShards < BOSS_SUMMON_SHARDS) {
    return { ok: false, error: `The Sundered Bell demands ${BOSS_SUMMON_SHARDS} soul shards (you have ${state.soulShards}).` };
  }
  if (!state.unlockedAreas.includes('sanctum')) return { ok: false, error: 'The Bell Sanctum is still sealed.' };
  const s = copy(state);
  s.soulShards -= BOSS_SUMMON_SHARDS;
  s.summonsPending = Math.min(5, s.summonsPending + 1);
  return { ok: true, state: s };
}

export function ashesOnAscend(state: NecroState): number {
  return state.ascension >= ASCENSION.maxRank ? 0 : ashesForRun(state.run, state.ascension);
}

/** Burn the run: the local layer resets, rank and Ashes rise, starting boons apply. */
export function ascend(state: NecroState): RuleResult<{ earned: number }> {
  const earned = ashesOnAscend(state);
  if (!earned) return { ok: false, error: 'Slay the Prelate this run before you Ascend.' };
  const s = copy(state);
  const fx = boonEffects(s.boons);
  s.ascension += 1;
  s.ashes += earned;
  s.damageTier = fx.startDamageTier;
  s.waveTierOwned = 0;
  s.waveTierActive = 0;
  s.soulShards = fx.startShards;
  s.areaKills = {};
  s.unlockedAreas = ['chapterhouse', 'graves'];
  s.run = { prelateKills: 0, peakWaveTier: 0, kills: 0 };
  s.summonsPending = 0;
  return { ok: true, state: s, earned };
}

export function buyBoon(state: NecroState, id: BoonId): RuleResult<{ cost: number }> {
  if (!(id in BOONS)) return { ok: false, error: 'Unknown boon' };
  const blocked = boonBlocked(id, state.boons, state.ascension);
  if (blocked) return { ok: false, error: blocked === 'Mastered' ? 'That boon is already mastered.' : `Requires ${blocked}.` };
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
  s.ashes = clampInt(r.ashes, 0, L.importMaxAshes);
  // Boons: valid ids, within max rank and rank gates.
  const boons = (r.boons && typeof r.boons === 'object' ? r.boons : {}) as Record<string, unknown>;
  for (const id of Object.keys(BOONS) as BoonId[]) {
    const want = clampInt(boons[id], 0, BOONS[id].maxRank);
    for (let i = 0; i < want && !boonBlocked(id, s.boons, s.ascension); i++) s.boons[id] = (s.boons[id] ?? 0) + 1;
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
  return {
    ...b,
    ...r,
    areaKills: { ...(r.areaKills ?? {}) },
    unlockedAreas: Array.isArray(r.unlockedAreas) && r.unlockedAreas.length ? [...r.unlockedAreas] : b.unlockedAreas,
    boons: { ...(r.boons ?? {}) },
    run: { ...b.run, ...(r.run ?? {}) },
  };
}
