import { AREAS, AREA_ORDER, GLOBAL_ENEMY_CAP, type AreaId } from '../../content/areas';
import { DEPTHS, depthEliteBonus, depthEnemyLevel, depthRoster, depthWaveGapS, depthWaveSize, floorKills, hasChest, pickExtraAffixes } from '../../content/depths';
import { floorHops, floorSeed, generateFloor, roomAt, type DepthsFloor } from '../depthsFloor';
import {
  AFFIX_ORDER,
  AFFIX_TUNING,
  CENSER,
  ELITE,
  ENEMIES,
  PROCESSION,
  SCREAM,
  DUST,
  PLAGUE_FLASK,
  EMBER_BOLT,
  EMBER_DEATH,
  SLAG_POOL,
  FRENZY,
  WARD,
  BURROW,
  UNBIND,
  TEMPLAR_SHIELD,
  SURGE,
  WAVE_THEMES,
  enemyDamageScale,
  enemyHpScale,
  type EliteAffix,
  type EnemyId,
  type WaveTheme,
} from '../../content/enemies';
import {
  SIGNATURE,
  DETONATE,
  FRACTURE,
  LITANY_MAX_MULT,
  LITANY_PER_CORPSE,
  LITANY_PER_RESONANT,
  LITANY_PER_THRALL,
  MIASMA_SLOW,
  WATCHMANS_WARD_SLOW,
  ABILITIES,
  BONE_MANTLE,
  CARRION_SEED,
  GRAVE_FROST,
  BONE_PRISON,
  GRAVE_HANDS,
  GRAVE_OFFERING,
  GRAVE_BRAND,
  SHIELD_BASH,
  RALLY,
  WITHERED,
} from '../../content/abilities';
import { NIGHTFALL_SHROUD_CHANCE, RESTLESS_SURGE_MULT, milestoneActive, waveModifiers } from '../../content/upgrades';
import { DIFFICULTIES, type Difficulty } from '../../content/difficulty';
import { ascensionLevels } from '../../content/ascension';
import type { Omen } from '../../content/omens';
import type { ThrallKind } from '../../content/disciplines';
import { BONE_HEX, CHILL, HEMORRHAGE, PLAGUE_BURST, SANCTIFIED } from '../../content/statuses';
import type { Nav } from '../nav';
import { LEGEND, clampSimLegend, simLegendActive, type SimLegend } from '../legendary';
import { pickWeighted } from '../rng';
import { BOSS_RADIUS, makeBossBrains, type BossBrain, type CoverBox } from './BossBrain';
import { BOSSES, isBossId, type BossId } from '../../content/bosses';
import { FEN_LURE, HAG_HEX, SEXTON_HOOK, WISP_PULSE } from '../../content/fen';
import { NODES, RICH_RESPAWN, RICH_YIELD, type NodeDef } from '../gatheringRules';
import { NODE_REACH } from '../../content/layout';
import { NECRO_WEAPON_TUNING } from '../../content/necroWeapons';
import { RUNE_TUNING } from '../../content/runes';
import type {
  BossState,
  Corpse,
  CorpseGoneReason,
  DepthsRun,
  Enemy,
  Intent,
  PlayerBody,
  SimEvent,
  SurgeState,
  Thrall,
  Zone,
  SimNode,
} from './types';

/** An area with no living player for this long sinks back into its graves (see crumbleVacant). */
const VACANT_CRUMBLE_S = 8;
/** Seconds after an arrival until Wave Speed is at full pressure (see rampTier). */
const RAMP_S = 30;
const AGGRO_RANGE = 15;
const DEPTHS_AGGRO = 36;
const CORPSE_LIFETIME = 26;
const TOXIC_RUPTURE = 5;
const MAX_CORPSES = 45;
/** A cone blow reaches this far beyond the enemy's attackRange (a body's width); the telegraph draws it too. */
export const CONE_REACH_PAD = 0.4;
const THRALL_LEASH = 13;
const THRALL_TELEPORT = 24;
const PLAYER_RADIUS = 0.45;
const SPAWN_MIN_DIST = 9;
const SPAWN_MAX_DIST = 30;
const RISE_TIME = 1.1;
const THRALL_RISE_TIME = 0.9;

const THRALL_BASE = {
  warrior: { range: 1.3, interval: 1.0, speed: 5.6 },
  shieldbearer: { range: 1.3, interval: 1.25, speed: 5.2 },
  hound: { range: 1.2, interval: 0.7, speed: 7.2 },
  wraith: { range: 5.5, interval: 1.1, speed: 5.8 },
  // Corpse-born specialists (FUTURE_CONTENT 0.2 thrall variety).
  archer: { range: 7.5, interval: 1.3, speed: 5.4 },
  bonemage: { range: 6.5, interval: 1.8, speed: 5.2 },
  plaguebearer: { range: 1.3, interval: 1.2, speed: 4.8 },
  // Bone Colossus rune (content/runes.ts): one giant, slow, wide-cleaving thrall.
  colossus: { range: RUNE_TUNING.colossus.range, interval: RUNE_TUNING.colossus.interval, speed: RUNE_TUNING.colossus.speed },
} as const;

/** Legion places a thrall fills against the cap: the Bone Colossus takes more than one. */
export const thrallWeight = (kind: ThrallKind): number => (kind === 'colossus' ? RUNE_TUNING.colossus.slots : 1);

/** Proper segment intersection (touching endpoints don't count). */
function segmentsCross(ax: number, az: number, bx: number, bz: number, cx: number, cz: number, dx: number, dz: number) {
  const o = (px: number, pz: number, qx: number, qz: number, rx: number, rz: number) => (qx - px) * (rz - pz) - (qz - pz) * (rx - px);
  const d1 = o(cx, cz, dx, dz, ax, az);
  const d2 = o(cx, cz, dx, dz, bx, bz);
  const d3 = o(ax, az, bx, bz, cx, cz);
  const d4 = o(ax, az, bx, bz, dx, dz);
  return d1 * d2 < 0 && d3 * d4 < 0;
}

/** Which specialist a corpse rises as (disciplines' own kinds otherwise). */
function thrallFromCorpse(c: Corpse, discipline: ThrallKind): ThrallKind {
  if (discipline === 'wraith') return 'wraith';
  if (c.kind === 'swift') return 'hound';
  if (c.enemy === 'penitent') return 'archer';
  if (c.enemy === 'deacon') return 'bonemage';
  if (c.enemy === 'sac') return 'plaguebearer';
  return discipline;
}

/** Relative hp / hit of each thrall kind against the caster's base thrall stats. */
const THRALL_SCALE: Partial<Record<ThrallKind, { hp: number; dmg: number }>> = {
  hound: { hp: 0.75, dmg: 1 },
  archer: { hp: 0.7, dmg: 0.85 },
  bonemage: { hp: 0.7, dmg: 0.7 },
  plaguebearer: { hp: 1.1, dmg: 0.8 },
};

/**
 * The authoritative world. Runs on the room host (or solo). Everything that
 * isn't a player body lives here: enemies, thralls, corpses, zones, waves and
 * the Prelate. Clients talk to it through Intents; it answers with Events.
 */
export class WorldSim {
  readonly enemies = new Map<number, Enemy>();
  readonly thralls = new Map<number, Thrall>();
  readonly corpses = new Map<number, Corpse>();
  readonly zones = new Map<number, Zone>();
  /** Lich Acolyte Unbindings waiting to climb out (host-only). */
  private unbinds: { at: number; by: number; x: number; z: number; area: AreaId }[] = [];
  readonly players = new Map<string, PlayerBody>();
  /** Gathering nodes (placements from the layout; depletion is host-authoritative). */
  readonly nodes = new Map<string, SimNode>();
  /** Every area boss's brain (one awake at a time); `boss` is the awake one, or the last one summoned. */
  readonly bosses: Record<BossId, BossBrain>;
  private bossId: BossId = 'prelate';
  get boss(): BossBrain {
    return this.bosses[this.bossId];
  }
  /** Drowned Congregation cover (the nave pews' boxes; WorldScene passes them from the layout). */
  cover: CoverBox[] = [];
  setCover(boxes: CoverBox[]) {
    this.cover = boxes;
  }
  /**
   * An area's enemy level. Level-scaled areas (the Plague Cloister) match the highest-level living player in them,
   * never below their floor, so XP per kill keeps pace with any character; the rest use their fixed level.
   * Ascension adds its levels either way.
   */
  areaLevel(area: AreaId): number {
    const def = AREAS[area];
    if (area === 'depths') {
      // The Catacomb Depths: the highest living hero on the floor sets the level, depth raises it (content/depths.ts).
      let top = 0;
      for (const p of this.players.values()) if (p.alive && p.area === area && (p.level ?? 0) > top) top = Math.min(999, p.level!);
      return depthEnemyLevel(this.depths?.depth ?? 1, top) + ascensionLevels(this.ascension);
    }
    let level = def.level;
    if (def.scaling) {
      level = def.scaling.minLevel;
      for (const p of this.players.values()) if (p.alive && p.area === area && (p.level ?? 0) > level) level = Math.min(999, p.level!);
    }
    return level + ascensionLevels(this.ascension);
  }

  /** A boss's rot pool: a hostile toxic zone (the Plague Saint heals while she stands in one). */
  addHostilePool(x: number, z: number, r: number, dps: number, seconds: number): Zone {
    const zone: Zone = { id: this.id(), kind: 'toxic', owner: '', x, z, r, until: this.time + seconds, bornAt: this.time, tick: 1, dps, slow: 1, witheredCap: 0, bloom: false, hostile: true };
    this.zones.set(zone.id, zone);
    this.emit({ t: 'zone', zone });
    return zone;
  }

  /** Host migration: continue the awake boss on its own brain (older snapshots have no id: the Prelate). */
  adoptBoss(state: BossState) {
    this.bossId = isBossId(state.id) ? state.id : 'prelate';
    Object.assign(this.boss.state, state, { id: this.bossId });
    this.boss.resume();
  }

  /** Host's active wave-speed tier (drives every area this sim runs). */
  waveTier = 0;
  /** The week's Omen (content/omens.ts): elite chance, wave size and elite affix. Null = none (tests, older hosts). */
  omen: Omen | null = null;
  /** Host's session difficulty: scales enemy/boss HP and damage for new spawns. */
  difficulty: Difficulty = 'medium';
  /** World keeper's Ascension rank: every enemy and the Prelate run this many ranks older. */
  ascension = 0;
  time = 0;
  /** The running Grave Surge, if any. */
  surge: SurgeState | null = null;
  /** The Catacomb Depths run in progress (host-only; null between runs). */
  depths: DepthsRun | null = null;
  /** Combat seconds until the next Grave Surge (only counts down while someone fights). */
  surgeIn = SURGE.firstDelayS;

  private events: SimEvent[] = [];
  private nextId = 1;
  private waveTimers = new Map<AreaId, number>();
  /** Seconds each hunting ground has stood without a living player (see crumbleVacant). */
  private vacantS = new Map<AreaId, number>();
  /** When each hunting ground last greeted an arrival (Wave Speed builds up from here, see rampTier). */
  private arrivedAt = new Map<AreaId, number>();
  /** Regular waves spawned per area (Elite Vanguard alternates). */
  private waveCounts = new Map<AreaId, number>();
  /** Ossuary Walls standing right now (segments enemies can't cross). */
  readonly walls = new Map<number, { id: number; owner: string; x0: number; z0: number; x1: number; z1: number; until: number }>();
  /** Hollow Knight — armed Grave Brands: the first enemy within range is rooted. */
  readonly brands = new Map<number, { owner: string; x: number; z: number; area: AreaId; until: number }>();
  /** Surge origins in front of crypt props (from the layout); breaches are the fallback. */
  private crypts: { area: AreaId; x: number; z: number }[] = [];
  private dotAccum = new Map<number, number>();
  private bloomed = new Set<number>();
  /** Legendary set mods per owner (host-clamped from the owner's 'legend' intent); empty = every legendary mechanic off. */
  private legends = new Map<string, SimLegend>();
  /** Thralls raised per owner, for the Legion Champion (every Nth). Lives as long as the sim does. */
  private raised = new Map<string, number>();
  /** The owner's last real Miasma cast (what a Chain Plague burst copies), and the burst clouds standing. */
  private lastMiasma = new Map<string, { r: number; dps: number; durationMs: number; cap: number; bloom: boolean }>();
  private plagueZones = new Set<number>();
  /** Legendary spear rally on the boss. */
  private bossMark: { by: string; until: number; bonus: number } | null = null;
  private anyPlague = false;

  constructor(
    private nav: Nav,
    readonly rand: () => number = Math.random,
  ) {
    this.bosses = makeBossBrains(this);
  }

  id() {
    return this.nextId++;
  }

  /** After seeding from a mirror (host migration) keep new ids above the old ones. */
  reserveIds(maxUsed: number) {
    this.nextId = Math.max(this.nextId, maxUsed + 1);
  }

  emit(ev: SimEvent) {
    this.events.push(ev);
  }

  drain(): SimEvent[] {
    const out = this.events;
    this.events = [];
    return out;
  }

  get bossState(): BossState {
    return this.boss.state;
  }

  // --- Players ---

  setPlayer(body: PlayerBody) {
    this.players.set(body.id, body);
  }

  removePlayer(id: string) {
    this.players.delete(id);
    for (const t of [...this.thralls.values()]) if (t.owner === id) this.killThrall(t, 'crumbled');
    this.legends.delete(id);
    this.raised.delete(id);
    this.lastMiasma.delete(id);
    this.anyPlague = [...this.legends.values()].some((v) => v.witheredBurstAt > 0);
  }

  playersIn(area: AreaId) {
    return [...this.players.values()].filter((p) => p.alive && p.area === area);
  }

  // --- Intents ---

  apply(intent: Intent) {
    switch (intent.t) {
      case 'hit':
        return this.applyHit(intent);
      case 'miasma':
        return this.applyMiasma(intent);
      case 'exhume':
        return this.applyExhume(intent);
      case 'litany':
        return this.applyLitany(intent);
      case 'summonBoss': {
        // One awake boss per world: a second summon is refused and its caller refunded (the client explains why).
        if (this.boss.state.active) {
          this.emit({ t: 'bossBusy', by: intent.by, boss: isBossId(intent.boss) ? intent.boss : 'prelate', awake: this.bossId });
          return;
        }
        this.bossId = isBossId(intent.boss) ? intent.boss : 'prelate';
        return this.boss.awaken(intent.by);
      }
      case 'detonate':
        return this.applyDetonate(intent);
      case 'signature':
        return this.applySignature(intent);
      case 'gather':
        return this.applyGather(intent);
      case 'legend': {
        const l = clampSimLegend(intent.mods);
        if (simLegendActive(l)) this.legends.set(intent.by, l);
        else this.legends.delete(intent.by);
        this.anyPlague = [...this.legends.values()].some((v) => v.witheredBurstAt > 0);
        return;
      }
      case 'recallThralls':
        for (const t of this.thralls.values()) {
          if (t.owner !== intent.by) continue;
          t.x = intent.x + (this.rand() - 0.5) * 2;
          t.z = intent.z + (this.rand() - 0.5) * 2;
          t.target = null;
        }
    }
  }

  /**
   * `from` is where a directed blow came from (the caster, or the thrall that struck). Only directed
   * blows can glance off a Bell Templar's shield; zones and damage over time pass none.
   */
  damageEnemy(e: Enemy, amount: number, by: string, from?: { x: number; z: number }) {
    if (e.state === 'dead' || e.hp <= 0) return 0;
    // A Barrow Ghoul underground (burrowed, or winding up its eruption) cannot be touched.
    if (e.state === 'burrow' || (e.erupting != null && e.state === 'windup')) return 0;
    const def = ENEMIES[e.def];
    let shield = 1;
    if (def.shield && from && e.fracture === 0) {
      let d = Math.abs(Math.atan2(from.x - e.x, from.z - e.z) - e.facing) % (Math.PI * 2);
      if (d > Math.PI) d = Math.PI * 2 - d;
      if (d <= (TEMPLAR_SHIELD.halfArcDeg * Math.PI) / 180) {
        shield = TEMPLAR_SHIELD.passThrough;
        if (this.time >= (e.blockFxAt ?? 0)) {
          e.blockFxAt = this.time + 0.25;
          this.emit({ t: 'shieldBlock', id: e.id, x: e.x, z: e.z });
        }
      }
    }
    const dmg = amount * (1 + FRACTURE.perStack * e.fracture) * this.damageTakenMult(e) * shield;
    e.hp -= dmg;
    e.flash = 1;
    e.lastHitBy = by;
    // Barrow Ghoul: the first time it drops below half it digs back in (still hittable while it digs).
    if (def.burrow && !e.dugIn && e.hp > 0 && e.hp < e.maxHp * BURROW.digAtFrac) {
      e.dugIn = true;
      e.digPending = true;
      e.state = 'recover';
      e.stateT = 0;
      e.groundT = Math.max(0, BURROW.digS - 0.3);
      this.emit({ t: 'digIn', id: e.id, x: e.x, z: e.z });
    }
    return dmg;
  }

  /** Shrouded elites shrug off half of everything unless they stand in a player's rot. */
  damageTakenMult(e: Enemy) {
    const shroud = this.hasAffix(e, 'shrouded') && !this.inFriendlyMiasma(e) ? AFFIX_TUNING.shrouded.damageTakenMult : 1;
    return shroud * ((e.sanctT ?? 0) > 0 ? SANCTIFIED.damageTakenMult : 1);
  }

  /** Inside a player-owned Miasma circle (or the rot pool a Corpse Explosion leaves)? */
  inFriendlyMiasma(e: { x: number; z: number; radius: number }) {
    for (const z of this.zones.values()) {
      if (z.hostile || (z.kind !== 'miasma' && z.kind !== 'rot')) continue;
      if (Math.hypot(e.x - z.x, e.z - z.z) <= z.r + e.radius) return true;
    }
    return false;
  }

  private applyHit(h: Extract<Intent, { t: 'hit' }>) {
    if (h.boss) {
      this.boss.damage(h.dmg, h.by, h.fracture ?? 0);
      return;
    }
    const caster = this.players.get(h.by);
    const from = caster ? { x: caster.x, z: caster.z } : undefined;
    if (h.spear) this.spearRally(h, caster);
    for (const id of h.ids) {
      const e = this.enemies.get(id);
      // Underground (tunnelling or winding up its eruption): no damage and no statuses either.
      if (!e || e.state === 'burrow' || (e.erupting != null && e.state === 'windup')) continue;
      this.damageEnemy(e, h.dmg, h.by, from);
      if (h.bleed && h.bleed > 0) {
        // Hemorrhage: the strongest bleed wins; the host caps what a hit may claim.
        const dps = Math.min(h.bleed, h.dmg * HEMORRHAGE.maxFrac);
        if (dps >= (e.bleedDps ?? 0) || (e.bleedT ?? 0) <= 0) {
          e.bleedDps = dps;
          e.bleedOwner = h.by;
        }
        e.bleedT = HEMORRHAGE.durationS;
      }
      if (h.fracture) {
        e.fracture = Math.min(FRACTURE.maxStacks, e.fracture + h.fracture);
        e.fractureT = FRACTURE.durationMs / 1000;
      }
      // Grave Frost: the host owns the duration; a claim can only ask for it.
      if (h.chill) e.chillT = Math.max(e.chillT ?? 0, GRAVE_FROST.chillS);
      if (h.root) e.rootT = Math.max(e.rootT ?? 0, typeof h.rootS === 'number' && h.rootS > 0 ? Math.min(RUNE_TUNING.impale.rootS, h.rootS) : BONE_PRISON.rootS);
      if (h.slow) e.slowT = Math.max(e.slowT, GRAVE_HANDS.tickS + 0.2);
      // Rot Lance: one Withered stack at most per hit, up to a clamped cap; dps scales with the hit.
      if (h.withered && h.withered > 0) this.wither(e, 1, Math.min(12, Math.max(1, Math.floor(h.witheredCap ?? DETONATE.rotWitheredCap))), h.dmg * WITHERED.dpsPerStack, h.by);
    }
  }

  /** Legion Champion 5: a Marrow Spear hit marks its nearest target; the owner's thralls turn on it and hit it harder for a few seconds. */
  private spearRally(h: Extract<Intent, { t: 'hit' }>, caster: PlayerBody | undefined) {
    const leg = this.legends.get(h.by);
    if (!leg || leg.spearRally <= 0) return;
    let mark: Enemy | null = null;
    let bestD = Infinity;
    if (!h.boss) {
      for (const id of h.ids) {
        const e = this.enemies.get(id);
        if (!e || e.state === 'dead' || e.state === 'burrow') continue;
        const d = caster ? Math.hypot(e.x - caster.x, e.z - caster.z) : 0;
        if (d < bestD) (mark = e), (bestD = d);
      }
    }
    const b = this.boss.state;
    if (mark) {
      mark.markT = LEGEND.rallyS;
      mark.markBonus = leg.spearRally;
      mark.markBy = h.by;
      this.emit({ t: 'legend', kind: 'rally', by: h.by, x: mark.x, z: mark.z, id: mark.id });
    } else if (h.boss && b.active) {
      this.bossMark = { by: h.by, until: this.time + LEGEND.rallyS, bonus: leg.spearRally };
      this.emit({ t: 'legend', kind: 'rally', by: h.by, x: b.x, z: b.z, id: -1 });
    } else return;
    for (const t of this.ownedThralls(h.by)) {
      if (t.state === 'rising') continue;
      t.target = mark ? mark.id : null;
    }
  }

  /** The legion's extra damage on whatever the owner's Marrow Spear marked (1 when nothing is). */
  private rallyMult(t: Thrall, e: Enemy | null): number {
    if (e) return (e.markT ?? 0) > 0 && e.markBy === t.owner ? 1 + (e.markBonus ?? 0) : 1;
    const m = this.bossMark;
    return m && m.by === t.owner && this.time < m.until ? 1 + m.bonus : 1;
  }

  /** Add Withered stacks the way zones do (the strongest dps wins, the stacker owns the kill). */
  private wither(e: Enemy, stacks: number, cap: number, dps: number, by: string) {
    e.withered = Math.min(cap, e.withered + stacks);
    e.witheredT = WITHERED.durationMs / 1000;
    e.witheredDps = Math.max(e.witheredDps, dps);
    e.witheredOwner = by;
  }

  private corpseAt(x: number, z: number, r: number, area?: AreaId | null) {
    let best: Corpse | null = null;
    let bestD = r;
    for (const c of this.corpses.values()) {
      if (area && c.area !== area) continue;
      if (c.echoOwner) continue;
      const d = Math.hypot(c.x - x, c.z - z);
      if (d <= bestD) (best = c), (bestD = d);
    }
    return best;
  }

  private applyMiasma(m: Extract<Intent, { t: 'miasma' }>) {
    if (this.legends.get(m.by)?.witheredBurstAt) this.lastMiasma.set(m.by, { r: m.r, dps: m.dps, durationMs: m.durationMs, cap: m.witheredCap, bloom: m.bloom });
    const zone: Zone = {
      id: this.id(),
      kind: 'miasma',
      owner: m.by,
      x: m.x,
      z: m.z,
      r: m.r,
      until: this.time + m.durationMs / 1000,
      bornAt: this.time,
      tick: 0,
      dps: m.dps,
      slow: MIASMA_SLOW,
      witheredCap: m.witheredCap,
      bloom: m.bloom,
      hostile: false,
    };
    // Relic runes: Creeping Rot (a drifting circle; the host owns the speed) and Contagion (what it withers spreads on death).
    if (typeof m.creep === 'number' && m.creep > 0) zone.creep = Math.min(RUNE_TUNING.creepingRot.speed, m.creep);
    if (m.contagion) zone.contagion = true;
    this.zones.set(zone.id, zone);
    this.emit({ t: 'zone', zone });
  }

  private ownedThralls(owner: string) {
    return [...this.thralls.values()].filter((t) => t.owner === owner && t.state !== 'dead');
  }

  private applyExhume(x: Extract<Intent, { t: 'exhume' }>) {
    if (x.colossus) return this.raiseColossus(x);
    // Mass Grave rune: up to three corpses near the point, each at the rune's share of a thrall's health and damage (the host owns both).
    // A lone corpse is raised at full strength: the penalty is for spreading the magic, not for having nothing to spread it over.
    const count = Math.max(1, Math.min(RUNE_TUNING.massGrave.count, Math.floor(Number.isFinite(x.count) ? x.count! : 1)));
    const r = count > 1 ? Math.max(x.r, RUNE_TUNING.massGrave.pickRadius) : x.r;
    const hall = this.players.get(x.by)?.area ?? null;
    const picks = [...this.corpses.values()]
      .filter((c) => !c.echoOwner && (!hall || c.area === hall) && Math.hypot(c.x - x.x, c.z - x.z) <= r)
      .sort((a, b) => Math.hypot(a.x - x.x, a.z - x.z) - Math.hypot(b.x - x.x, b.z - x.z))
      .slice(0, count);
    if (!picks.length) {
      this.emit({ t: 'exhumed', by: x.by, ok: false, x: x.x, z: x.z });
      return;
    }
    const statMult = picks.length > 1 ? RUNE_TUNING.massGrave.statMult : 1;
    for (const c of picks) this.raiseFrom(x, c, statMult);
  }

  /** Make room for `weight` more legion places: the oldest ordinary thrall crumbles first, a Colossus last. Returns the first crumbled id. */
  private makeRoom(owner: string, cap: number, weight: number): number | undefined {
    let crumbled: number | undefined;
    const owned = this.ownedThralls(owner).sort((a, b) => (a.kind === 'colossus' ? 1 : 0) - (b.kind === 'colossus' ? 1 : 0) || a.bornAt - b.bornAt);
    let used = owned.reduce((n, t) => n + thrallWeight(t.kind), 0);
    while (owned.length && used + weight > cap) {
      const o = owned.shift()!;
      used -= thrallWeight(o.kind);
      crumbled ??= o.id;
      this.killThrall(o, 'crumbled');
    }
    return crumbled;
  }

  /** One ordinary exhume: this corpse becomes a thrall for the intent's owner. */
  private raiseFrom(x: Extract<Intent, { t: 'exhume' }>, best: Corpse, statMult: number): void {
    this.removeCorpse(best, 'consumed', x.by);
    const crumbled = this.makeRoom(x.by, x.cap, 1);
    const kind = thrallFromCorpse(best, x.kind);
    const scale = THRALL_SCALE[kind] ?? { hp: 1, dmg: 1 };
    const empowered = best.kind === 'resonant' || best.elite;
    const base = THRALL_BASE[kind];
    // Legion Champion: every Nth thrall this owner raises is a Champion (2x health and damage; the view makes it bigger).
    const raisedN = (this.raised.get(x.by) ?? 0) + 1;
    this.raised.set(x.by, raisedN);
    const every = this.legends.get(x.by)?.championEvery ?? 0;
    const champion = every > 0 && raisedN % every === 0;
    const slotsUsed = new Set(this.ownedThralls(x.by).map((t) => t.slot));
    let slot = 0;
    while (slotsUsed.has(slot)) slot++;
    const t: Thrall = {
      id: this.id(),
      owner: x.by,
      kind,
      x: best.x,
      z: best.z,
      facing: best.facing,
      hp: x.hp * (empowered ? 1.5 : 1) * scale.hp * statMult * (champion ? LEGEND.championHp : 1),
      maxHp: x.hp * (empowered ? 1.5 : 1) * scale.hp * statMult * (champion ? LEGEND.championHp : 1),
      damage: x.damage * (empowered ? 1.5 : 1) * scale.dmg * statMult * (champion ? LEGEND.championDamage : 1),
      attackInterval: base.interval / x.attackSpeedMult,
      range: base.range,
      speed: base.speed,
      state: 'rising',
      stateT: 0,
      attackCd: 0.4,
      target: null,
      slot,
      bornAt: this.time,
      empowered,
      flash: 0,
      gait: 0,
      moving: false,
    };
    if (champion) t.champion = true;
    if (kind === 'wraith' && x.allyHeal && x.allyHeal > 0) t.allyHeal = Math.min(NECRO_WEAPON_TUNING.mourning_bell.allyHealFrac * 1.5, x.allyHeal);
    this.thralls.set(t.id, t);
    this.emit({ t: 'thrall', id: t.id, owner: t.owner, kind, x: t.x, z: t.z, empowered });
    this.emit({ t: 'exhumed', by: x.by, ok: true, corpseKind: best.kind, x: best.x, z: best.z, crumbled });
  }

  /**
   * Bone Colossus rune: the corpses nearest the point (up to five, at least three, within the rune's radius) are consumed and one giant thrall
   * rises where they lay. Its strength scales with how many were spent; the host owns every number. A player keeps one colossus: a new one replaces it.
   */
  private raiseColossus(x: Extract<Intent, { t: 'exhume' }>) {
    const T = RUNE_TUNING.colossus;
    const r = Math.min(T.pickRadius, Math.max(0.2, x.r));
    const near = [...this.corpses.values()]
      .filter((c) => !c.echoOwner && Math.hypot(c.x - x.x, c.z - x.z) <= r)
      .sort((a, b) => Math.hypot(a.x - x.x, a.z - x.z) - Math.hypot(b.x - x.x, b.z - x.z))
      .slice(0, T.corpses);
    if (near.length < T.minCorpses) {
      this.emit({ t: 'exhumed', by: x.by, ok: false, x: x.x, z: x.z, why: 'few' });
      return;
    }
    const n = near.length;
    const cx = near.reduce((a, c) => a + c.x, 0) / n;
    const cz = near.reduce((a, c) => a + c.z, 0) / n;
    const empowered = near.some((c) => c.kind === 'resonant' || c.elite);
    for (const c of near) this.removeCorpse(c, 'consumed', x.by);
    for (const old of this.ownedThralls(x.by)) if (old.kind === 'colossus') this.killThrall(old, 'crumbled');
    const crumbled = this.makeRoom(x.by, x.cap, T.slots);
    const slotsUsed = new Set(this.ownedThralls(x.by).map((t) => t.slot));
    let slot = 0;
    while (slotsUsed.has(slot)) slot++;
    const hp = x.hp * T.hpPerCorpse * n;
    const t: Thrall = {
      id: this.id(),
      owner: x.by,
      kind: 'colossus',
      x: cx,
      z: cz,
      facing: near[0].facing,
      hp,
      maxHp: hp,
      damage: x.damage * T.damagePerCorpse * n,
      attackInterval: THRALL_BASE.colossus.interval / x.attackSpeedMult,
      range: THRALL_BASE.colossus.range,
      speed: THRALL_BASE.colossus.speed,
      state: 'rising',
      stateT: 0,
      attackCd: 0.8,
      target: null,
      slot,
      bornAt: this.time,
      empowered,
      flash: 0,
      gait: 0,
      moving: false,
    };
    this.thralls.set(t.id, t);
    this.emit({ t: 'thrall', id: t.id, owner: t.owner, kind: 'colossus', x: t.x, z: t.z, empowered });
    this.emit({ t: 'exhumed', by: x.by, ok: true, corpseKind: near[0].kind, x: cx, z: cz, crumbled });
  }

  /** Requiem rune: litanies waiting to burst (host-only). */
  private pendingLitanies: { at: number; l: Extract<Intent, { t: 'litany' }> }[] = [];

  private applyLitany(l: Extract<Intent, { t: 'litany' }>) {
    // Requiem rune: mark the ground now, burst later. What the burst eats (corpses, thralls) is decided then.
    const delay = Math.min(RUNE_TUNING.requiem.delayMs, Math.max(0, Number.isFinite(l.delayMs) ? l.delayMs! : 0));
    if (delay > 0) {
      this.pendingLitanies.push({ at: this.time + delay / 1000, l: { ...l, delayMs: 0 } });
      this.emit({ t: 'requiem', by: l.by, x: l.x, z: l.z, r: l.r, ms: delay });
      return;
    }
    let corpses = 0;
    let resonant = 0;
    const tethers: [number, number][] = [];
    const hall = this.players.get(l.by)?.area ?? null;
    for (const c of [...this.corpses.values()]) {
      if (c.echoOwner || (hall && c.area !== hall)) continue;
      if (Math.hypot(c.x - l.x, c.z - l.z) > l.r) continue;
      if (c.kind === 'resonant') resonant++;
      else corpses++;
      tethers.push([c.x, c.z]);
      this.removeCorpse(c, 'litany', l.by);
    }
    let thralls = 0;
    for (const t of this.ownedThralls(l.by)) {
      if (Math.hypot(t.x - l.x, t.z - l.z) > l.r) continue;
      thralls++;
      tethers.push([t.x, t.z]);
      // Hollow Choir rune: the thrall sings and stays.
      if (l.spare) continue;
      this.killThrall(t, 'sacrificed');
      if (l.leaveCorpses) this.addCorpse(t.x, t.z, 'normal', 'risen', false, t.facing, 1, this.nav.areaAt(t.x, t.z) ?? 'graves');
    }
    const mult = Math.min(
      LITANY_MAX_MULT,
      ABILITIES.black_litany.power + LITANY_PER_CORPSE * corpses + LITANY_PER_RESONANT * resonant + LITANY_PER_THRALL * thralls,
    );
    const dmg = l.spellPower * mult;
    let targets = 0;
    for (const e of this.enemies.values()) {
      if (e.state === 'dead' || Math.hypot(e.x - l.x, e.z - l.z) > l.r + e.radius) continue;
      this.damageEnemy(e, dmg, l.by);
      targets++;
    }
    if (this.boss.state.active && Math.hypot(this.boss.state.x - l.x, this.boss.state.z - l.z) <= l.r + BOSS_RADIUS) {
      this.boss.damage(dmg, l.by, 0);
      targets++;
    }
    this.emit({ t: 'litanyResult', by: l.by, x: l.x, z: l.z, r: l.r, corpses, resonant, thralls: l.spare ? 0 : thralls, ...(l.spare ? { spared: thralls } : {}), targets, tethers });
    if (targets) this.emit({ t: 'dmg', x: l.x, z: l.z, amount: Math.round(dmg), kind: 'litany', by: l.by });
  }

  private tickPendingLitanies() {
    if (!this.pendingLitanies.length) return;
    const due = this.pendingLitanies.filter((p) => this.time >= p.at);
    if (!due.length) return;
    this.pendingLitanies = this.pendingLitanies.filter((p) => this.time < p.at);
    for (const p of due) this.applyLitany(p.l);
  }

  /**
   * Corpse Explosion. The host owns the blast radius and the corpse modifiers;
   * the client only names the corpse and its own damage (clamped here too).
   */
  private applyDetonate(d: Extract<Intent, { t: 'detonate' }>) {
    const c = this.corpses.get(d.corpseId);
    const hall = this.players.get(d.by)?.area ?? null;
    if (!c || c.echoOwner || (hall && c.area !== hall)) {
      // Claimed by someone else first (the caster refunds on ok:false).
      this.emit({ t: 'detonated', by: d.by, ok: false, corpseId: d.corpseId, x: 0, z: 0, r: 0 });
      return;
    }
    const base = Math.min(DETONATE.maxDamage, Math.max(0, Number.isFinite(d.dmg) ? d.dmg : 0));
    const r = DETONATE.radius * (c.kind === 'resonant' ? DETONATE.resonantRadiusMult : 1);
    const dmg = base * (c.elite ? DETONATE.eliteDamageMult : 1);
    let targets = 0;
    for (const e of this.enemies.values()) {
      if (e.state === 'dead' || Math.hypot(e.x - c.x, e.z - c.z) > r + e.radius) continue;
      this.damageEnemy(e, dmg, d.by);
      targets++;
    }
    const b = this.boss.state;
    if (b.active && Math.hypot(b.x - c.x, b.z - c.z) <= r + BOSS_RADIUS) {
      this.boss.damage(dmg, d.by, 0);
      targets++;
    }
    // Announce before the corpse goes so views shatter the body instead of sinking it.
    this.emit({
      t: 'detonated',
      by: d.by,
      ok: true,
      corpseId: c.id,
      x: c.x,
      z: c.z,
      r,
      corpseKind: c.kind,
      elite: c.elite,
      targets,
      dmg: Math.round(dmg),
    });
    this.removeCorpse(c, 'burst', d.by);
    if (c.kind === 'toxic') {
      // The sac's venom, turned: a friendly rot pool that withers what stays in it.
      const zone: Zone = {
        id: this.id(),
        kind: 'rot',
        owner: d.by,
        x: c.x,
        z: c.z,
        r: DETONATE.rotRadius * Math.max(1, c.scale),
        until: this.time + DETONATE.rotDurationMs / 1000,
        bornAt: this.time,
        tick: 0,
        dps: base * DETONATE.rotDpsShare,
        slow: MIASMA_SLOW,
        witheredCap: DETONATE.rotWitheredCap,
        bloom: false,
        hostile: false,
      };
      this.zones.set(zone.id, zone);
      this.emit({ t: 'zone', zone });
    }
  }

  // --- Corpses / thralls ---

  addCorpse(x: number, z: number, kind: Corpse['kind'], enemy: EnemyId, elite: boolean, facing: number, scale: number, area: AreaId) {
    if (kind === 'none') return;
    if (this.corpses.size >= MAX_CORPSES) {
      const oldest = [...this.corpses.values()].sort((a, b) => a.bornAt - b.bornAt)[0];
      if (oldest) this.removeCorpse(oldest, 'expired');
    }
    const c: Corpse = {
      id: this.id(),
      x,
      z,
      kind,
      enemy,
      elite,
      facing,
      scale,
      area,
      bornAt: this.time,
      expiresAt: this.time + CORPSE_LIFETIME,
      ruptureAt: kind === 'toxic' ? this.time + TOXIC_RUPTURE : Infinity,
    };
    this.corpses.set(c.id, c);
    this.emit({ t: 'corpse', corpse: c });
    return c;
  }

  removeCorpse(c: Corpse, reason: CorpseGoneReason, by?: string) {
    if (!this.corpses.delete(c.id)) return;
    this.bloomed.delete(c.id);
    this.emit({ t: 'corpseGone', id: c.id, reason, by });
  }

  killThrall(t: Thrall, reason: 'killed' | 'sacrificed' | 'crumbled') {
    if (!this.thralls.delete(t.id)) return;
    t.state = 'dead';
    this.emit({ t: 'thrallGone', id: t.id, owner: t.owner, x: t.x, z: t.z, reason });
    if (t.kind === 'plaguebearer' && reason !== 'crumbled') this.plagueBurst(t);
    // Legion of the Unburied: a thrall that is KILLED bursts into bone. Sacrificed (Litany) and crumbled (cap, recall, owner gone) ones do not.
    if (reason === 'killed') this.deathBurst(t);
    // Only a thrall that was killed can be unbound; sacrificed and crumbled ones are safe.
    if (reason === 'killed') this.tryUnbind(t);
  }

  private deathBurst(t: Thrall) {
    const frac = this.legends.get(t.owner)?.thrallDeathBurst ?? 0;
    if (frac <= 0) return;
    const dmg = frac * t.maxHp;
    const r = LEGEND.deathBurstR;
    let hit = 0;
    for (const e of this.enemies.values()) {
      if (e.state === 'dead' || Math.hypot(e.x - t.x, e.z - t.z) > r + e.radius) continue;
      this.damageEnemy(e, dmg, t.owner);
      hit++;
    }
    const b = this.boss.state;
    if (b.active && Math.hypot(b.x - t.x, b.z - t.z) <= r + BOSS_RADIUS) {
      this.boss.damage(dmg, t.owner, 0);
      hit++;
    }
    this.emit({ t: 'legend', kind: 'deathBurst', by: t.owner, x: t.x, z: t.z, r });
    if (hit) this.emit({ t: 'dmg', x: t.x, z: t.z, amount: Math.round(dmg), kind: 'burst', by: t.owner });
  }

  /** Lich Acolyte: the nearest ready acolyte in reach claims a fallen thrall; a Risen climbs out shortly after. */
  private tryUnbind(t: Thrall) {
    for (const e of this.enemies.values()) {
      if (!ENEMIES[e.def].unbind || e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow') || e.hp <= 0) continue;
      if ((e.unbindCd ?? 0) > 0 || Math.hypot(e.x - t.x, e.z - t.z) > UNBIND.range) continue;
      let alive = this.unbinds.filter((u) => u.by === e.id).length;
      for (const o of this.enemies.values()) if (o.unboundBy === e.id && o.state !== 'dead') alive++;
      if (alive >= UNBIND.maxAlive) continue;
      e.unbindCd = UNBIND.cooldownS;
      this.unbinds.push({ at: this.time + UNBIND.delayS, by: e.id, x: t.x, z: t.z, area: e.area });
      this.emit({ t: 'unbind', id: e.id, x: e.x, z: e.z, tx: t.x, tz: t.z });
      return;
    }
  }

  private tickUnbinds() {
    for (let i = this.unbinds.length - 1; i >= 0; i--) {
      const u = this.unbinds[i];
      if (this.time < u.at) continue;
      this.unbinds.splice(i, 1);
      const a = this.enemies.get(u.by);
      if (!a || a.state === 'dead' || a.hp <= 0) continue; // a dead acolyte cancels its Unbinding
      this.spawnEnemy('risen', u.area, u.x, u.z, false).unboundBy = a.id;
    }
  }

  /** Barrow Ghoul underground: tunnel toward the target, then wind up an eruption (at most a few per target). */
  private tickBurrow(e: Enemy, dt: number) {
    const target = this.pickTarget(e);
    e.targetPlayer = target?.player?.id ?? null;
    e.targetThrall = target?.thrall?.id ?? null;
    if (!target) return;
    const key = target.player?.id ?? target.thrall!.id;
    const d = Math.hypot(target.x - e.x, target.z - e.z);
    if (d <= BURROW.surfaceR || (e.burrowLeft ?? Infinity) <= 0) {
      let busy = 0;
      for (const o of this.enemies.values()) if (o !== e && o.erupting === key && o.state === 'windup') busy++;
      if (busy >= BURROW.maxPerTarget) return; // wait underground so the rings stay readable
      e.state = 'windup';
      e.stateT = 0;
      e.erupting = key;
      e.aimX = target.x;
      e.aimZ = target.z;
      e.facing = Math.atan2(target.x - e.x, target.z - e.z);
      this.emit({ t: 'telegraph', id: e.id, kind: 'erupt', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: this.eruptMs(e), r: BURROW.eruptR });
      return;
    }
    const px = e.x;
    const pz = e.z;
    this.moveEnemy(e, target.x, target.z, dt, BURROW.speed / e.speed);
    if (e.burrowLeft !== undefined) e.burrowLeft -= Math.hypot(e.x - px, e.z - pz);
  }

  /** The eruption windup: generous in the first room. */
  private eruptMs(e: Enemy) {
    return (e.area === 'graves' ? BURROW.eruptMsGraves : BURROW.eruptMs) * (e.elite ? 0.85 : 1);
  }

  // --- Signature rites ---

  private applySignature(g: Extract<Intent, { t: 'signature' }>) {
    const caster = this.players.get(g.by);
    // Aim is clamped around the caster's reported body (the client only proposes).
    const clampAim = (range: number): [number, number] => {
      if (!caster) return [g.x, g.z];
      const dx = g.x - caster.x;
      const dz = g.z - caster.z;
      const d = Math.hypot(dx, dz);
      return d <= range ? [g.x, g.z] : [caster.x + (dx / d) * range, caster.z + (dz / d) * range];
    };
    const sp = Math.min(1e5, Math.max(0, Number.isFinite(g.sp) ? g.sp : 0));
    switch (g.sig) {
      case 'wall': {
        const W = SIGNATURE.wall;
        const [cx, cz] = clampAim(W.maxCastRange);
        let dx = g.dx;
        let dz = g.dz;
        const dl = Math.hypot(dx, dz);
        if (!Number.isFinite(dl) || dl < 1e-6) [dx, dz] = [0, -1];
        else [dx, dz] = [dx / dl, dz / dl];
        // The wall runs across the aim line.
        const px = -dz * (W.length / 2);
        const pz = dx * (W.length / 2);
        const wall = { id: this.id(), owner: g.by, x0: cx - px, z0: cz - pz, x1: cx + px, z1: cz + pz, until: this.time + W.durationS };
        this.walls.set(wall.id, wall);
        this.emit({ t: 'wall', id: wall.id, owner: g.by, x0: wall.x0, z0: wall.z0, x1: wall.x1, z1: wall.z1, ms: W.durationS * 1000 });
        return;
      }
      case 'rend': {
        const R = SIGNATURE.rend;
        // The legion leaps within the hall the caster stands in: aimed across a wall into the next one it lands at the last point on this side.
        const [ax, az] = clampAim(R.maxCastRange);
        const [cx, cz] = caster?.area ? this.lastPointInArea(caster.area, caster.x, caster.z, ax, az) : [ax, az];
        const legion = this.ownedThralls(g.by).filter((t) => t.state !== 'rising');
        const leaps: [number, number, number, number][] = [];
        const hit = new Set<number>();
        legion.forEach((t, i) => {
          const ang = (i / Math.max(1, legion.length)) * Math.PI * 2;
          const [tx, tz] = this.nav.resolve(cx + Math.cos(ang) * 1.2, cz + Math.sin(ang) * 1.2, 0.4);
          leaps.push([t.x, t.z, tx, tz]);
          t.x = tx;
          t.z = tz;
          t.hp = Math.max(1, t.hp - t.maxHp * R.hpCost);
          t.attackCd = 0.2;
          for (const e of this.enemies.values()) {
            if (e.state === 'dead' || Math.hypot(e.x - tx, e.z - tz) > R.cleaveRadius + e.radius) continue;
            this.damageEnemy(e, t.damage * R.damageMult * this.cursedMult(t), g.by, t);
            hit.add(e.id);
          }
          const b = this.boss.state;
          if (b.active && Math.hypot(b.x - tx, b.z - tz) <= R.cleaveRadius + BOSS_RADIUS) this.boss.damage(t.damage * R.damageMult * this.cursedMult(t), g.by, 0);
        });
        this.emit({ t: 'rend', by: g.by, x: cx, z: cz, leaps, hits: hit.size });
        return;
      }
      case 'dirge': {
        const D = SIGNATURE.dirge;
        const [cx, cz] = clampAim(1);
        this.addZone({ kind: 'dirge', owner: g.by, x: cx, z: cz, r: D.radius, durationS: D.durationS, dps: sp * ABILITIES.dirge.power, witheredCap: 0 });
        return;
      }
      case 'bloom': {
        const B = SIGNATURE.bloom;
        const [cx, cz] = clampAim(B.maxCastRange);
        this.addZone({ kind: 'flower', owner: g.by, x: cx, z: cz, r: B.radius, durationS: B.durationS, dps: sp * ABILITIES.plague_bloom.power, witheredCap: B.witheredCap, gen: 0 });
        return;
      }
      case 'mantle': {
        // Bone Mantle (a Grimoire rite): like Black Litany, the host decides which corpses go.
        // The nearest few are drawn in; the caster's client turns the count into its barrier.
        const [cx, cz] = clampAim(1);
        const r = ABILITIES.bone_mantle.radius;
        const near = [...this.corpses.values()]
          .filter((c) => !c.echoOwner && (!caster?.area || c.area === caster.area))
          .map((c) => ({ c, d: Math.hypot(c.x - cx, c.z - cz) }))
          .filter((o) => o.d <= r)
          .sort((a, b) => a.d - b.d)
          .slice(0, BONE_MANTLE.maxCorpses);
        const tethers: [number, number][] = [];
        for (const { c } of near) {
          tethers.push([c.x, c.z]);
          this.removeCorpse(c, 'consumed', g.by);
        }
        this.emit({ t: 'mantle', by: g.by, x: cx, z: cz, r, corpses: near.length, tethers });
        return;
      }
      case 'offering': {
        // Grave Offering: the corpse nearest the aim (within 0.9m, in the caster's hall) is consumed once.
        const [cx, cz] = clampAim(ABILITIES.grave_offering.range + 1);
        const c = this.corpseAt(cx, cz, GRAVE_OFFERING.pickRadius, caster?.area);
        if (!c) {
          this.emit({ t: 'offering', by: g.by, ok: false, x: cx, z: cz });
          return;
        }
        this.removeCorpse(c, 'consumed', g.by);
        this.emit({ t: 'offering', by: g.by, ok: true, x: c.x, z: c.z, corpseKind: c.kind, elite: c.elite });
        return;
      }
      case 'bash': {
        // Shield Bash: the host owns the strike and the stun. Walk the charge
        // line from the caster and take the first living body it meets.
        let dx = g.dx;
        let dz = g.dz;
        const dl = Math.hypot(dx, dz);
        if (!Number.isFinite(dl) || dl < 1e-6) [dx, dz] = [0, -1];
        else [dx, dz] = [dx / dl, dz / dl];
        const ox = caster?.x ?? g.x;
        const oz = caster?.z ?? g.z;
        let first: Enemy | null = null;
        let bestT = Infinity;
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow')) continue;
          if (caster?.area && e.area !== caster.area) continue;
          const rx = e.x - ox;
          const rz = e.z - oz;
          const along = rx * dx + rz * dz;
          if (along < -e.radius || along > SHIELD_BASH.dashM + e.radius) continue;
          // Perpendicular distance from the charge line.
          if (Math.abs(rx * -dz + rz * dx) > e.radius + ABILITIES.shield_bash.radius) continue;
          if (along < bestT) (first = e), (bestT = along);
        }
        const boss = this.boss.state;
        if (caster?.area === BOSSES[this.bossId].area && boss.active) {
          const rx = boss.x - ox;
          const rz = boss.z - oz;
          const along = rx * dx + rz * dz;
          const across = Math.abs(rx * -dz + rz * dx);
          if (along >= -BOSS_RADIUS && along <= SHIELD_BASH.dashM + BOSS_RADIUS
            && across <= BOSS_RADIUS + ABILITIES.shield_bash.radius && along < bestT) {
            this.boss.damage(sp * ABILITIES.shield_bash.power, g.by, 0);
            this.boss.stagger(SHIELD_BASH.bossStunS);
            this.emit({ t: 'bash', by: g.by, x: boss.x, z: boss.z, id: null });
            return;
          }
        }
        if (!first) {
          this.emit({ t: 'bash', by: g.by, x: ox + dx * SHIELD_BASH.dashM, z: oz + dz * SHIELD_BASH.dashM, id: null });
          return;
        }
        this.damageEnemy(first, sp * ABILITIES.shield_bash.power, g.by);
        first.stunT = Math.max(first.stunT ?? 0, SHIELD_BASH.stunS);
        this.emit({ t: 'bash', by: g.by, x: first.x, z: first.z, id: first.id });
        return;
      }
      case 'vigil': {
        // Corpse Vigil: spend one body. The regeneration itself is the caster's.
        const [cx, cz] = clampAim(ABILITIES.corpse_vigil.range + 1);
        const c = this.corpseAt(cx, cz, ABILITIES.corpse_vigil.radius, caster?.area);
        if (!c) {
          this.emit({ t: 'vigil', by: g.by, ok: false, x: cx, z: cz });
          return;
        }
        this.removeCorpse(c, 'consumed', g.by);
        this.emit({ t: 'vigil', by: g.by, ok: true, x: c.x, z: c.z });
        return;
      }
      case 'brand': {
        // Grave Brand: spend the body and arm a trap the host watches.
        const [cx, cz] = clampAim(ABILITIES.grave_brand.range + 1);
        const c = this.corpseAt(cx, cz, ABILITIES.grave_brand.radius, caster?.area);
        if (!c) {
          this.emit({ t: 'brand', by: g.by, ok: false, sprung: false, x: cx, z: cz });
          return;
        }
        const area = c.area;
        const [bx, bz] = [c.x, c.z];
        this.removeCorpse(c, 'consumed', g.by);
        this.brands.set(this.id(), { owner: g.by, x: bx, z: bz, area, until: this.time + GRAVE_BRAND.lifeS });
        this.emit({ t: 'brand', by: g.by, ok: true, sprung: false, x: bx, z: bz });
        return;
      }
      case 'rally': {
        const [cx, cz] = clampAim(ABILITIES.rally_dead.range);
        const secs = Math.min(RALLY.durationS + RALLY.gravecallerBonusS, Math.max(RALLY.durationS, Number.isFinite(g.dur) ? (g.dur as number) : RALLY.durationS));
        let focus: Enemy | null = null;
        let bestD = Infinity;
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow')) continue;
          const d = Math.hypot(e.x - cx, e.z - cz);
          if (d < bestD) (focus = e), (bestD = d);
        }
        const ids: number[] = [];
        for (const t of this.ownedThralls(g.by)) {
          t.rallyT = secs;
          t.hp = Math.min(t.maxHp, t.hp + t.maxHp * RALLY.healFrac);
          if (focus && Math.hypot(focus.x - t.x, focus.z - t.z) < THRALL_LEASH) t.target = focus.id;
          ids.push(t.id);
        }
        this.emit({ t: 'rally', by: g.by, x: cx, z: cz, ids });
        return;
      }
      case 'seed': {
        // Carrion Seed: one live seed per caster; a new one withers the old, harmlessly.
        const [cx, cz] = clampAim(ABILITIES.carrion_seed.range + 1);
        const c = this.corpseAt(cx, cz, CARRION_SEED.pickRadius, caster?.area);
        if (!c) return;
        for (const o of this.corpses.values()) {
          if (o.seedOwner !== g.by || o === c) continue;
          this.clearSeed(o);
        }
        c.seedOwner = g.by;
        c.seedDmg = sp * ABILITIES.carrion_seed.power;
        c.seedCap = Math.min(12, Math.max(1, Math.floor(Number.isFinite(g.cap) ? (g.cap as number) : CARRION_SEED.witheredCap)));
        c.seedArmedAt = this.time + CARRION_SEED.armS;
        c.seedExpires = Math.min(c.expiresAt, this.time + CARRION_SEED.lifeS);
        this.emit({ t: 'seeded', by: g.by, corpseId: c.id, x: c.x, z: c.z, armMs: CARRION_SEED.armS * 1000 });
        return;
      }
      default:
        this.applyNewBlood(g, caster, sp);
        return;
    }
  }

  /** Resolve New Blood corpse, control and area rites on the room host. */
  private applyNewBlood(g: Extract<Intent, { t: 'signature' }>, caster: PlayerBody | undefined, sp: number) {
    const fail = (x = g.x, z = g.z) => this.emit({ t: 'newBlood', by: g.by, kind: g.sig, ok: false, x, z });
    if (!caster || !caster.alive || !caster.area) return fail();
    const def = ABILITIES[g.sig as keyof typeof ABILITIES];
    if (!def) return fail();
    const dx = g.x - caster.x, dz = g.z - caster.z, dist = Math.hypot(dx, dz);
    const reach = def.range || def.radius || 1;
    const x = dist > reach ? caster.x + dx / dist * reach : g.x;
    const z = dist > reach ? caster.z + dz / dist * reach : g.z;
    const event = (amount?: number, targetId?: number, tx?: number, tz?: number) =>
      this.emit({ t: 'newBlood', by: g.by, kind: g.sig, ok: true, x, z, amount, targetId, tx, tz });
    const body = (r = 1.25, echo = false) => [...this.corpses.values()]
      .filter((c) => c.area === caster.area && (echo ? !!c.echoOwner && (c.echoOwner === g.by || c.echoOwner === '*') : !c.echoOwner)
        && Math.hypot(c.x - x, c.z - z) <= r)
      .sort((a, b) => Math.hypot(a.x - x, a.z - z) - Math.hypot(b.x - x, b.z - z))[0];
    const foe = (range: number) => [...this.enemies.values()]
      .filter((e) => e.state !== 'dead' && (e.state !== 'rising' && e.state !== 'burrow') && e.area === caster.area
        && Math.hypot(e.x - x, e.z - z) <= e.radius + 0.8 && Math.hypot(e.x - caster.x, e.z - caster.z) <= range + e.radius)
      .sort((a, b) => Math.hypot(a.x - x, a.z - z) - Math.hypot(b.x - x, b.z - z))[0];
    switch (g.sig) {
      case 'lantern_cone': {
        const len = Math.hypot(dx, dz) || 1;
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || e.area !== caster.area || Math.hypot(e.x - caster.x, e.z - caster.z) > 7 + e.radius) continue;
          const vx = e.x - caster.x, vz = e.z - caster.z;
          if ((vx * dx + vz * dz) / (Math.max(0.01, Math.hypot(vx, vz)) * len) < Math.cos(Math.PI / 5)) continue;
          this.stripShroud(e);
          if (e.def === 'wraith') e.stunT = Math.max(e.stunT ?? 0, 1.5);
        }
        event(); return;
      }
      case 'chain_pull': case 'hook_pull': {
        const e = foe(def.range); if (!e) return fail(x, z);
        const [tx, tz] = this.nav.resolveInArea(caster.area, caster.x + 0.8, caster.z + 0.8, e.radius);
        e.x = tx; e.z = tz; e.rootT = Math.max(e.rootT ?? 0, 0.25);
        this.damageEnemy(e, sp * def.power, g.by);
        event(undefined, e.id, tx, tz); return;
      }
      case 'burn_the_dead': {
        const bodies = [...this.corpses.values()].filter((c) => !c.echoOwner && c.area === caster.area && Math.hypot(c.x - x, c.z - z) <= 4)
          .sort((a, b) => Math.hypot(a.x - x, a.z - z) - Math.hypot(b.x - x, b.z - z)).slice(0, 3);
        if (!bodies.length) return fail(x, z);
        for (const c of bodies) {
          this.removeCorpse(c, 'consumed', g.by);
          this.addZone({ kind: 'warden_fire', owner: g.by, x: c.x, z: c.z, r: 1.5, durationS: 5, dps: sp * def.power, witheredCap: 0 });
        }
        event(bodies.length * 20); return;
      }
      case 'watchmans_ward':
        this.addZone({ kind: 'warden_ward', owner: g.by, x, z, r: 5, durationS: 8, dps: 0, witheredCap: 0 });
        event(); return;
      case 'cremate': {
        const c = body(); if (!c) return fail(x, z);
        this.removeCorpse(c, 'consumed', g.by);
        this.addZone({ kind: 'warden_fire', owner: g.by, x: c.x, z: c.z, r: 1.5, durationS: 3, dps: sp * def.power, witheredCap: 0 });
        event(20); return;
      }
      case 'last_light': {
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || e.area !== caster.area || Math.hypot(e.x - caster.x, e.z - caster.z) > 12 + e.radius) continue;
          this.stripShroud(e);
          e.stunT = Math.max(e.stunT ?? 0, 1);
          this.damageEnemy(e, sp * def.power, g.by);
        }
        for (const p of this.players.values()) if (p.alive && p.area === caster.area && Math.hypot(p.x - caster.x, p.z - caster.z) <= 12)
          this.emit({ t: 'newBlood', by: g.by, kind: 'heal', ok: true, x: p.x, z: p.z, amount: 0.1, player: p.id });
        event(); return;
      }
      case 'toll': case 'great_toll': {
        const radius = g.sig === 'toll' ? 4 : 9;
        const resonant = [...this.corpses.values()].some((c) => c.kind === 'resonant' && c.area === caster.area && Math.hypot(c.x - caster.x, c.z - caster.z) <= radius);
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || e.area !== caster.area || Math.hypot(e.x - caster.x, e.z - caster.z) > radius + e.radius) continue;
          this.damageEnemy(e, sp * def.power * (resonant ? 1.5 : 1), g.by);
          if (g.sig === 'great_toll') e.silenceT = Math.max(e.silenceT ?? 0, 3);
          else {
            if (e.state === 'windup' || e.state === 'channel') e.state = 'recover';
            if ((g.dur ?? 0) > 0) e.stunT = Math.max(e.stunT ?? 0, 0.6);
          }
        }
        event(); return;
      }
      case 'resonant_step': {
        const sx = caster.x, sz = caster.z;
        const vx = x - sx, vz = z - sz, len = Math.hypot(vx, vz) || 1;
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || e.area !== caster.area) continue;
          const ex = e.x - sx, ez = e.z - sz;
          const along = Math.max(0, Math.min(len, (ex * vx + ez * vz) / len));
          if (Math.hypot(ex - vx / len * along, ez - vz / len * along) <= e.radius + 0.8) this.damageEnemy(e, sp * def.power, g.by);
        }
        event(); return;
      }
      case 'knell': {
        const e = foe(9); if (!e) return fail(x, z);
        e.knellBeats = 3; e.knellNext = this.time + 1.2; e.knellOwner = g.by; e.knellDamage = sp * def.power * 1.6;
        event(undefined, e.id); return;
      }
      case 'sound_the_corpse': {
        const c = body(); if (!c) return fail(x, z);
        c.kind = 'resonant'; this.emit({ t: 'corpse', corpse: c });
        for (const e of this.enemies.values()) if (e.state !== 'dead' && e.area === c.area && Math.hypot(e.x - c.x, e.z - c.z) <= 3 + e.radius)
          this.damageEnemy(e, sp * def.power, g.by);
        event(); return;
      }
      case 'harvest': case 'butcher': case 'lay_to_rest': {
        const c = body(); if (!c) return fail(x, z);
        this.removeCorpse(c, 'consumed', g.by);
        if (g.sig === 'butcher') for (let i = 0; i < 3; i++) {
          const angle = i * Math.PI * 2 / 3;
          this.addZone({ kind: 'witch_charm', owner: g.by, x: c.x + Math.cos(angle), z: c.z + Math.sin(angle), r: 0.65, durationS: 20, dps: 0, witheredCap: 0 });
        }
        if (g.sig === 'lay_to_rest') for (const offset of [-0.8, 0.8]) {
          const [ex, ez] = this.nav.resolveInArea(c.area, c.x + offset, c.z + 0.5, 0.4);
          const echo = this.addCorpse(ex, ez, 'normal', c.enemy, false, c.facing, 0.7, c.area);
          if (echo) { echo.echoOwner = g.by; echo.expiresAt = this.time + 20; }
        }
        event(g.sig === 'harvest' ? 30 : undefined); return;
      }
      case 'crow_swarm':
        this.addZone({ kind: 'witch_crows', owner: g.by, x, z, r: 3, durationS: 5, dps: sp * def.power, witheredCap: 0 });
        event(); return;
      case 'hex_charm': {
        const e = foe(9); if (!e) return fail(x, z);
        e.hexT = 8; e.hexOwner = g.by;
        event(undefined, e.id); return;
      }
      case 'murder_of_crows': {
        const existing = [...this.zones.values()].find((zone) => zone.kind === 'witch_crows' && zone.owner === g.by && zone.gen === 1);
        if (existing) { existing.x = x; existing.z = z; this.emit({ t: 'zone', zone: existing }); }
        else this.addZone({ kind: 'witch_crows', owner: g.by, x, z, r: 4, durationS: 8, dps: sp * def.power, witheredCap: 0, gen: 1 });
        event(); return;
      }
      case 'echo': {
        const c = body(1.25, true); if (!c) return fail(x, z);
        const owned = this.ownedThralls(g.by);
        if (owned.length >= 5) this.killThrall(owned.sort((a, b) => a.bornAt - b.bornAt)[0], 'crumbled');
        this.removeCorpse(c, 'raised', g.by);
        const t: Thrall = { id: this.id(), owner: g.by, kind: 'wraith', x: c.x, z: c.z, facing: c.facing,
          hp: 35 + sp, maxHp: 35 + sp, damage: Math.max(5, sp * 0.6), attackInterval: THRALL_BASE.wraith.interval,
          range: THRALL_BASE.wraith.range, speed: THRALL_BASE.wraith.speed, state: 'rising', stateT: 0, attackCd: 0.4,
          target: null, slot: owned.length, bornAt: this.time, empowered: false, flash: 0, gait: 0, moving: false,
          echoUntil: this.time + 10 };
        this.thralls.set(t.id, t);
        this.emit({ t: 'thrall', id: t.id, owner: g.by, kind: 'wraith', x: t.x, z: t.z, empowered: false });
        event(undefined, t.id); return;
      }
      case 'veil_tear':
        this.addZone({ kind: 'veil_rift', owner: g.by, x, z, r: 3, durationS: 2, dps: sp * def.power, witheredCap: 0 });
        event(); return;
      case 'crossing': {
        const c = body(1.25, true); if (!c || Math.hypot(c.x - caster.x, c.z - caster.z) > 12) return fail(x, z);
        const [tx, tz] = this.nav.resolveInArea(c.area, c.x, c.z, 0.45);
        event(undefined, undefined, tx, tz); return;
      }
      default: fail(); return;
    }
  }

  private addZone(o: { kind: Zone['kind']; owner: string; x: number; z: number; r: number; durationS: number; dps: number; witheredCap: number; gen?: number }) {
    const zone: Zone = {
      id: this.id(),
      kind: o.kind,
      owner: o.owner,
      x: o.x,
      z: o.z,
      r: o.r,
      until: this.time + o.durationS,
      bornAt: this.time,
      tick: 0,
      dps: o.dps,
      slow: MIASMA_SLOW,
      witheredCap: o.witheredCap,
      bloom: false,
      hostile: false,
      ...(o.kind === 'flower' ? { gen: o.gen ?? 0, spreadT: SIGNATURE.bloom.spreadEveryS } : o.gen != null ? { gen: o.gen } : {}),
    };
    this.zones.set(zone.id, zone);
    this.emit({ t: 'zone', zone });
    return zone;
  }

  /** Dirge: mend players and thralls inside each second; enemy casters inside stay Silenced. */
  private tickDirge(z: Zone, pulse: boolean) {
    const D = SIGNATURE.dirge;
    for (const e of this.enemies.values()) {
      if (e.state !== 'dead' && Math.hypot(e.x - z.x, e.z - z.z) <= z.r + e.radius) e.silenceT = D.silenceS;
    }
    if (!pulse) return;
    for (const p of this.players.values()) {
      if (p.alive && Math.hypot(p.x - z.x, p.z - z.z) <= z.r + PLAYER_RADIUS) this.emit({ t: 'heal', player: p.id, amount: z.dps, x: p.x, z: p.z });
    }
    for (const t of this.thralls.values()) {
      if (t.state !== 'dead' && Math.hypot(t.x - z.x, t.z - z.z) <= z.r) t.hp = Math.min(t.maxHp, t.hp + t.maxHp * D.thrallHealFrac);
    }
  }

  /** Plague Bloom: every few seconds a flower seeds the nearest corpse (consuming it) with a new bloom. */
  private tickBloomSpread(z: Zone, dt: number) {
    const B = SIGNATURE.bloom;
    if ((z.gen ?? 0) >= B.maxGenerations) return;
    z.spreadT = (z.spreadT ?? B.spreadEveryS) - dt;
    if (z.spreadT > 0) return;
    z.spreadT = B.spreadEveryS;
    let best: Corpse | null = null;
    let bestD = B.spreadReach;
    for (const c of this.corpses.values()) {
      const d = Math.hypot(c.x - z.x, c.z - z.z);
      if (d > 0.5 && d < bestD) {
        bestD = d;
        best = c;
      }
    }
    if (!best) return;
    this.removeCorpse(best, 'consumed', z.owner);
    this.addZone({ kind: 'flower', owner: z.owner, x: best.x, z: best.z, r: z.r, durationS: B.childDurationS, dps: z.dps, witheredCap: z.witheredCap, gen: (z.gen ?? 0) + 1 });
  }

  /** Walk from (fx, fz) toward (tx, tz) and stop at the last point still inside `area` (a leap never crosses a wall or a sealed door). */
  private lastPointInArea(area: AreaId, fx: number, fz: number, tx: number, tz: number): [number, number] {
    const n = Math.max(1, Math.ceil(Math.hypot(tx - fx, tz - fz) / 0.5));
    let best: [number, number] = [fx, fz];
    for (let i = 1; i <= n; i++) {
      const x = fx + ((tx - fx) * i) / n;
      const z = fz + ((tz - fz) * i) / n;
      if (this.nav.areaAt(x, z) !== area) break;
      best = [x, z];
    }
    return best;
  }

  private updateWalls() {
    for (const w of [...this.walls.values()]) {
      if (this.time < w.until) continue;
      this.walls.delete(w.id);
      this.emit({ t: 'wallGone', id: w.id });
    }
    this.tickBrands();
  }

  /** Grave Brands: expire quietly, or root the first body that walks onto one. */
  private tickBrands() {
    for (const [id, b] of [...this.brands]) {
      if (this.time >= b.until) {
        this.brands.delete(id);
        continue;
      }
      for (const e of this.enemies.values()) {
        if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow') || e.area !== b.area) continue;
        if (Math.hypot(e.x - b.x, e.z - b.z) > GRAVE_BRAND.triggerR + e.radius) continue;
        e.rootT = Math.max(e.rootT ?? 0, GRAVE_BRAND.rootS);
        this.brands.delete(id);
        this.emit({ t: 'brand', by: b.owner, ok: true, sprung: true, x: b.x, z: b.z });
        break;
      }
    }
  }

  /** Does the segment a→b cross a standing wall? */
  private wallBetween(ax: number, az: number, bx: number, bz: number) {
    for (const w of this.walls.values()) if (segmentsCross(ax, az, bx, bz, w.x0, w.z0, w.x1, w.z1)) return true;
    return this.nav.sightBlocked(ax, az, bx, bz);
  }

  /** Keep a mover on the side of every wall it started on. */
  private pushOffWalls(px: number, pz: number, x: number, z: number, radius: number): [number, number] {
    const half = SIGNATURE.wall.thickness / 2 + radius;
    for (const w of this.walls.values()) {
      const wx = w.x1 - w.x0;
      const wz = w.z1 - w.z0;
      const len2 = wx * wx + wz * wz;
      const t = Math.max(0, Math.min(1, ((x - w.x0) * wx + (z - w.z0) * wz) / len2));
      const cx = w.x0 + wx * t;
      const cz = w.z0 + wz * t;
      const d = Math.hypot(x - cx, z - cz);
      const crossed = segmentsCross(px, pz, x, z, w.x0, w.z0, w.x1, w.z1);
      if (d >= half && !crossed) continue;
      // Normal pointing to the side the mover came from.
      const len = Math.sqrt(len2);
      let nx = -wz / len;
      let nz = wx / len;
      if ((px - cx) * nx + (pz - cz) * nz < 0) [nx, nz] = [-nx, -nz];
      x = cx + nx * half;
      z = cz + nz * half;
    }
    return [x, z];
  }

  /** A fallen plague bearer ruptures: rot damage around it and a friendly withering pool. */
  private plagueBurst(t: Thrall) {
    const dmg = t.damage * PLAGUE_BURST.damageMult;
    for (const e of this.enemies.values()) {
      if (e.state === 'dead' || Math.hypot(e.x - t.x, e.z - t.z) > PLAGUE_BURST.radius + e.radius) continue;
      this.damageEnemy(e, dmg, t.owner);
    }
    const b = this.boss.state;
    if (b.active && Math.hypot(b.x - t.x, b.z - t.z) <= PLAGUE_BURST.radius + BOSS_RADIUS) this.boss.damage(dmg, t.owner, 0);
    this.emit({ t: 'burst', kind: 'bloom', x: t.x, z: t.z, r: PLAGUE_BURST.radius });
    const zone: Zone = {
      id: this.id(),
      kind: 'rot',
      owner: t.owner,
      x: t.x,
      z: t.z,
      r: PLAGUE_BURST.poolRadius,
      until: this.time + PLAGUE_BURST.poolMs / 1000,
      bornAt: this.time,
      tick: 0,
      dps: t.damage * PLAGUE_BURST.poolDpsShare,
      slow: MIASMA_SLOW,
      witheredCap: DETONATE.rotWitheredCap,
      bloom: false,
      hostile: false,
    };
    this.zones.set(zone.id, zone);
    this.emit({ t: 'zone', zone });
  }

  /** What an enemy's blow is worth right now (Bone Hex softens it). */
  /** A Bog Hag's hex: the thrall deals less while it lasts. */
  private cursedMult(t: Thrall) {
    return (t.cursedT ?? 0) > 0 ? HAG_HEX.thrallDamageMult : 1;
  }

  private blow(e: Enemy) {
    return e.damage * ((e.hexT ?? 0) > 0 ? BONE_HEX.damageMult : 1);
  }

  // --- Spawning ---

  /** `affix` forces an elite affix (tests / debug); otherwise elites roll one. */
  spawnEnemy(def: EnemyId, area: AreaId, x: number, z: number, elite: boolean, rising = true, affix?: EliteAffix): Enemy {
    const d = ENEMIES[def];
    const level = this.areaLevel(area);
    const wave = waveModifiers(this.rampTier(area));
    const diff = DIFFICULTIES[this.difficulty];
    const hp = d.hp * enemyHpScale(level) * wave.enemyHpMult * diff.enemyHpMult * (elite ? ELITE.hpMult : 1) * this.partyHpScale();
    const e: Enemy = {
      id: this.id(),
      def,
      area,
      level,
      elite,
      x,
      z,
      facing: this.rand() * Math.PI * 2,
      hp,
      maxHp: hp,
      damage: d.damage * enemyDamageScale(level) * wave.enemyDamageMult * diff.enemyDamageMult * (elite ? ELITE.damageMult : 1),
      speed: d.speed * (0.92 + this.rand() * 0.16),
      radius: d.radius * (elite ? 1.25 : 1),
      scale: d.scale * (elite ? ELITE.scale : 1),
      state: rising ? (d.burrow ? 'burrow' : 'rising') : 'move',
      stateT: 0,
      attackCd: 0.5 + this.rand(),
      targetPlayer: null,
      targetThrall: null,
      aimX: x,
      aimZ: z,
      channelCorpse: null,
      flankSide: this.rand() < 0.5 ? -1 : 1,
      fracture: 0,
      fractureT: 0,
      withered: 0,
      witheredT: 0,
      witheredDps: 0,
      witheredOwner: '',
      slowT: 0,
      lastHitBy: '',
      flash: 0,
      gait: this.rand() * 10,
      moving: false,
    };
    if (elite) e.affix = affix ?? AFFIX_ORDER[Math.floor(this.rand() * AFFIX_ORDER.length)];
    // The Catacomb Depths: one more affix every fifth floor (content/depths.ts extraAffixes), distinct from the first.
    if (elite && area === 'depths' && this.depths) {
      const more = pickExtraAffixes(this.depths.depth, e.affix, this.rand);
      if (more.length) e.extra = more.map((a) => ({ affix: a }));
    }
    // Common dead only carry an affix when something grants it (Nightfall's Shroud).
    else if (affix) e.affix = affix;
    this.enemies.set(e.id, e);
    this.emit({ t: 'spawn', id: e.id, def, x, z, elite, ...(e.affix ? { affix: e.affix } : {}) });
    return e;
  }

  private partyHpScale() {
    const n = Math.max(1, this.players.size);
    return 1 + 0.5 * (n - 1);
  }

  private aliveIn(area: AreaId) {
    let n = 0;
    for (const e of this.enemies.values()) if (e.area === area && e.state !== 'dead') n++;
    return n;
  }

  private spawnWave(area: AreaId, first = false) {
    const def = AREAS[area];
    const mods = waveModifiers(this.rampTier(area));
    const cap = Math.round(def.cap * mods.capMult);
    const room = Math.min(cap - this.aliveIn(area), GLOBAL_ENEMY_CAP - this.enemies.size);
    if (room <= 0) return;
    // The arrival wave is a fixed greeting; the Wave Speed dial only shapes what follows.
    let count = Math.round(first ? def.waveSize * 1.3 : def.waveSize * mods.sizeMult * (this.omen?.waveSizeMult ?? 1));
    count = Math.min(count, room);
    const pool = this.fairBreaches(area);
    // Bigger waves split across breaches so they arrive from more than one side.
    const breachCount = Math.min(pool.length, count > 11 ? 3 : count > 5 ? 2 : 1);
    const chosen: [number, number][] = [];
    for (let i = 0; i < breachCount; i++) chosen.push(pool[Math.floor(this.rand() * pool.length)]);
    // Elite Vanguard: every other wave after the greeting climbs out behind an elite.
    const n = first ? 0 : (this.waveCounts.get(area) ?? 0) + 1;
    if (!first) this.waveCounts.set(area, n);
    const vanguard = !first && n % 2 === 1 && milestoneActive('vanguard', this.rampTier(area));
    // Processions: now and then a wave arrives as a themed band instead of the usual mix.
    const themes = WAVE_THEMES[area];
    const theme: WaveTheme | undefined =
      !first && themes?.length && n >= PROCESSION.minWave && this.rand() < PROCESSION.chance
        ? themes[Math.floor(this.rand() * themes.length)]
        : undefined;
    if (theme) count = Math.max(1, Math.min(room, Math.round(count * theme.sizeMult)));
    // `count` is bodies, so a Skull-Rat pack fills several places in the wave.
    let hasElite = false;
    let spawned = 0;
    for (let i = 0; spawned < count; i++) {
      const [bx, bz] = chosen[i % chosen.length];
      const lead = i === 0 ? theme?.lead : undefined;
      // Vanguard: the first pick that can be elite is (packs never are, so the next one tries).
      const band = this.spawnAtBreach(area, bx, bz, vanguard && !hasElite && !lead, theme?.roster, lead, count - spawned);
      if (!band.length) break;
      spawned += band.length;
      if (band[0].elite) hasElite = true;
    }
    for (const [x, z] of chosen) this.emit({ t: 'wave', area, count: spawned, x, z, ...(theme ? { theme: theme.id } : {}) });
  }

  /** Breaches at a fair distance from every player; falls back to any breach. */
  private fairBreaches(area: AreaId): [number, number][] {
    const def = AREAS[area];
    const players = this.playersIn(area);
    const ok = def.breaches.filter(([bx, bz]) =>
      players.every((p) => {
        const d = Math.hypot(p.x - bx, p.z - bz);
        return d >= SPAWN_MIN_DIST && d <= SPAWN_MAX_DIST;
      }),
    );
    return ok.length ? ok : def.breaches;
  }

  /**
   * One wave pick climbing out beside a breach (area roster or a procession's, elite roll).
   * Pack enemies (Skull-Rats) bring their pack, never more than `room`. Returns every body spawned.
   */
  private spawnAtBreach(
    area: AreaId,
    bx: number,
    bz: number,
    forceElite = false,
    roster: { id: EnemyId; weight: number }[] = AREAS[area].enemies,
    lead?: EnemyId,
    room = Infinity,
  ): Enemy[] {
    const def = AREAS[area];
    const mods = waveModifiers(this.rampTier(area));
    const at = () => {
      const ang = this.rand() * Math.PI * 2;
      const rr = 0.5 + this.rand() * 2.4;
      return this.nav.resolveInArea(area, bx + Math.cos(ang) * rr, bz + Math.sin(ang) * rr, 0.5);
    };
    const id = lead ?? pickWeighted(roster, this.rand())?.id;
    if (!id || room <= 0) return [];
    const pack = ENEMIES[id].pack;
    const roll = this.rand() < def.eliteChance + mods.eliteBonus + DIFFICULTIES[this.difficulty].eliteBonus + (this.omen?.eliteBonus ?? 0) + (area === 'depths' && this.depths ? depthEliteBonus(this.depths.depth) : 0);
    // Pack animals never come elite (a whole elite swarm would be a wall of health).
    const elite = id !== 'risen' && !pack && (forceElite || roll);
    // Nightfall: the common dead climb out Shrouded.
    const shroud = !elite && milestoneActive('nightfall', this.rampTier(area)) && this.rand() < NIGHTFALL_SHROUD_CHANCE ? 'shrouded' : elite ? this.omen?.affix : undefined;
    const [x, z] = at();
    const band = [this.spawnEnemy(id, area, x, z, elite, true, shroud)];
    if (pack) {
      const size = Math.min(room, pack[0] + Math.floor(this.rand() * (pack[1] - pack[0] + 1)));
      while (band.length < size) {
        const [px, pz] = at();
        band.push(this.spawnEnemy(id, area, px, pz, false, true));
      }
    }
    return band;
  }

  // --- Grave Surges ---

  /**
   * While anyone fights in an open, unsafe area the surge clock runs; when it
   * lapses a crypt cracks open at a breach and pours three rapid waves over
   * 20s. Clearing ≥80% of what it spawned before it closes is a win.
   */
  private updateSurge(dt: number) {
    const s = this.surge;
    if (s) {
      const age = this.time - s.startedAt;
      while (s.wavesSpawned < SURGE.waveAtS.length && age >= SURGE.waveAtS[s.wavesSpawned]) {
        s.wavesSpawned++;
        this.spawnSurgeWave(s);
      }
      const allOut = s.wavesSpawned >= SURGE.waveAtS.length;
      if (allOut && s.spawned > 0 && s.killed >= s.spawned * SURGE.clearFrac) {
        this.emit({ t: 'surgeCleared', area: s.area, x: s.x, z: s.z });
        this.endSurge();
      } else if (this.time >= s.endsAt) {
        this.emit({ t: 'surgeFailed', area: s.area, x: s.x, z: s.z });
        this.endSurge();
      }
      return;
    }
    const eligible = AREA_ORDER.filter(
      (id) =>
        !AREAS[id].safe &&
        AREAS[id].breaches.length > 0 &&
        this.nav.isUnlocked(id) &&
        this.playersIn(id).length > 0 &&
        !(id === BOSSES[this.bossId].area && this.boss.state.active),
    );
    if (!eligible.length) return;
    this.surgeIn -= dt;
    if (this.surgeIn > 0) return;
    this.startSurge(eligible[Math.floor(this.rand() * eligible.length)]);
  }

  setCrypts(crypts: { area: AreaId; x: number; z: number }[]) {
    this.crypts = crypts.map(({ area, x, z }) => ({ area, x, z }));
  }

  /** Open a surge now (also the DEV/QA entry point). */
  startSurge(area: AreaId) {
    if (this.surge || AREAS[area].safe || !AREAS[area].breaches.length) return;
    // A crypt cracks open when one sits at a fair distance from everyone; otherwise a breach.
    const players = this.playersIn(area);
    const crypts = this.crypts.filter(
      (c) => c.area === area && players.every((p) => Math.hypot(p.x - c.x, p.z - c.z) >= SPAWN_MIN_DIST && Math.hypot(p.x - c.x, p.z - c.z) <= SPAWN_MAX_DIST),
    );
    const crypt = crypts.length > 0;
    const pool: [number, number][] = crypt ? crypts.map((c) => [c.x, c.z]) : this.fairBreaches(area);
    const [x, z] = pool[Math.floor(this.rand() * pool.length)];
    this.surge = {
      area,
      x,
      z,
      startedAt: this.time,
      endsAt: this.time + SURGE.durationS,
      wavesSpawned: 0,
      ids: new Set(),
      spawned: 0,
      killed: 0,
    };
    this.emit({ t: 'surge', area, x, z, durationMs: SURGE.durationS * 1000, ...(crypt ? { crypt: true } : {}) });
  }

  private spawnSurgeWave(s: SurgeState) {
    const def = AREAS[s.area];
    const room = GLOBAL_ENEMY_CAP - this.enemies.size;
    const count = Math.min(room, Math.round(def.waveSize * SURGE.waveSizeMult * waveModifiers(this.rampTier(s.area)).sizeMult));
    if (count <= 0) return;
    let spawned = 0;
    while (spawned < count) {
      const band = this.spawnAtBreach(s.area, s.x, s.z, false, undefined, undefined, count - spawned);
      if (!band.length) break;
      for (const e of band) {
        s.ids.add(e.id);
        s.spawned++;
        spawned++;
      }
    }
    this.emit({ t: 'wave', area: s.area, count: spawned, x: s.x, z: s.z });
  }

  private endSurge() {
    this.surge = null;
    const restless = milestoneActive('restless', this.waveTier) ? RESTLESS_SURGE_MULT : 1;
    this.surgeIn = (SURGE.minIntervalS + this.rand() * (SURGE.maxIntervalS - SURGE.minIntervalS)) * restless;
  }

  /**
   * The dead only stay up while someone is there to haunt: an area with no living player for
   * VACANT_CRUMBLE_S sinks back into its graves (no loot, no corpses) and greets the next arrival afresh.
   * Without it a death at high Wave Speed was a spiral: you walked back in, thrall-less, into the
   * whole mob that killed you.
   */
  private crumbleVacant(dt: number) {
    for (const id of AREA_ORDER) {
      if (AREAS[id].safe) continue;
      if (this.playersIn(id).length) {
        this.vacantS.delete(id);
        continue;
      }
      const v = (this.vacantS.get(id) ?? 0) + dt;
      this.vacantS.set(id, v);
      if (v < VACANT_CRUMBLE_S) continue;
      for (const e of [...this.enemies.values()]) if (e.area === id) this.enemies.delete(e.id);
      if (this.surge?.area === id) this.surge = null;
      // Coming back is a fresh arrival: the greeting wave opens the area again.
      this.waveTimers.delete(id);
    }
  }

  /**
   * Wave Speed builds over the first RAMP_S seconds of a visit: the arrival wave is a plain greeting and the dial
   * reaches its full pressure only once the legion has had time to rise. (At tier 8 the second wave used to land
   * about four seconds in, on a caster with no thralls and no corpses: first deaths came at 6-8 s.)
   * Milestone affixes arrive as the ramp passes their tier.
   */
  private rampTier(area: AreaId) {
    const since = this.time - (this.arrivedAt.get(area) ?? -Infinity);
    return this.waveTier * Math.max(0, Math.min(1, since / RAMP_S));
  }

  private updateWaves(dt: number) {
    this.crumbleVacant(dt);
    for (const id of AREA_ORDER) {
      const def = AREAS[id];
      // The Catacomb Depths run their own waves (updateDepths).
      if (def.safe || def.instance || !this.nav.isUnlocked(id)) continue;
      if (!this.playersIn(id).length) continue;
      if (id === BOSSES[this.bossId].area && this.boss.state.active) continue;
      let t = this.waveTimers.get(id);
      if (t === undefined) {
        // First visit: open with a heavier wave so the area feels inhabited.
        this.arrivedAt.set(id, this.time);
        this.spawnWave(id, true);
        this.waveTimers.set(id, (def.waveIntervalMs / 1000) * waveModifiers(this.rampTier(id)).intervalMult);
        continue;
      }
      t -= dt;
      if (t <= 0) {
        this.spawnWave(id);
        t = (def.waveIntervalMs / 1000) * waveModifiers(this.rampTier(id)).intervalMult;
      }
      this.waveTimers.set(id, t);
    }
  }

  // --- The Catacomb Depths (content/depths.ts, gameplay/depthsFloor.ts) ---

  /**
   * Begin a run: open the instance's ground to walkers and build floor `depth` (1 unless a test or the harness says otherwise).
   * The caller (the scene) puts the hero on `floor.start` and calls recallThralls there; nothing else is moved.
   */
  startDepths(owner: string, seed: number, depth = 1, hold = false): DepthsFloor {
    this.nav.openInstance('depths');
    // Wave Speed builds over the first seconds of a visit (rampTier): once per run, not per floor, so every floor runs at the dial the hero set.
    this.arrivedAt.set('depths', this.time - RAMP_S);
    this.depths = {
      owner, seed, depth, need: floorKills(depth), kills: 0, stairOpen: false, floorT: 0, waveT: 0, waved: false, hold,
      peak: depth, floors: 0, totalKills: 0,
    };
    return this.loadDepthsFloor();
  }

  /** Go down one floor (the stair was taken): the old floor and everything on it is cleared, a new one is built. */
  descendDepths(): DepthsFloor | null {
    const run = this.depths;
    if (!run) return null;
    if (!run.hold) run.depth++;
    run.peak = Math.max(run.peak, run.depth);
    run.kills = 0;
    run.stairOpen = false;
    return this.loadDepthsFloor();
  }

  /** The run is over (left, died or the scene closed): the ground closes and the floor's dead sink away. */
  endDepths(): DepthsRun | null {
    const run = this.depths;
    if (!run) return null;
    this.wipeDepthsGround();
    this.nav.clearDepthsFloor();
    this.nav.closeInstance('depths');
    this.depths = null;
    return run;
  }

  private loadDepthsFloor(): DepthsFloor {
    const run = this.depths!;
    this.wipeDepthsGround();
    const floor = generateFloor(floorSeed(run.seed, run.depth), run.depth, { chestEvery: DEPTHS.chestEvery });
    this.nav.loadDepthsFloor(floor);
    run.need = floorKills(run.depth);
    run.floorT = 0;
    run.waveT = 0;
    run.waved = false;
    this.vacantS.delete('depths');
    this.emit({ t: 'depthsFloor', depth: run.depth, need: run.need, chest: floor.chest !== null });
    return floor;
  }

  /** Everything that lives on the Depths ground goes: its dead (no loot, no corpses), corpses, zones, walls and brands. Thralls stay with their owner. */
  private wipeDepthsGround() {
    for (const e of [...this.enemies.values()]) if (e.area === 'depths') this.enemies.delete(e.id);
    for (const c of [...this.corpses.values()]) if (c.area === 'depths') this.removeCorpse(c, 'expired');
    const r = AREAS.depths.rect;
    for (const z of [...this.zones.values()]) {
      if (z.x < r.x0 || z.x > r.x1 || z.z < r.z0 || z.z > r.z1) continue;
      this.zones.delete(z.id);
      this.emit({ t: 'zoneGone', id: z.id });
    }
    for (const [id, w] of [...this.walls]) if (w.x0 >= r.x0 && w.x0 <= r.x1 && w.z0 >= r.z0 && w.z0 <= r.z1) this.walls.delete(id);
    for (const [id, b] of [...this.brands]) if (b.area === 'depths') this.brands.delete(id);
    this.unbinds = this.unbinds.filter((u) => u.area !== 'depths');
  }

  /** Quota bookkeeping on each death (collectDead): the stair down opens when the floor's kills are in. */
  private depthsKill(e: Enemy) {
    const run = this.depths;
    if (!run || e.area !== 'depths') return;
    run.kills++;
    run.totalKills++;
    if (run.stairOpen || run.kills < run.need) return;
    run.stairOpen = true;
    run.floors++;
    const f = this.nav.depthsFloor;
    this.emit({ t: 'depthsClear', depth: run.depth, x: f?.stairDown.x ?? 0, z: f?.stairDown.z ?? 0 });
  }

  /**
   * The floor's own waves. Only as many of the dead climb out as the quota still needs (kills so far + the living < quota), a wave at a
   * time and never more than DEPTHS.cap alive, so a floor is exactly N kills of work: no endless pressure while you look for the stair.
   * Breaches are the floor's spawn points, never in the hero's own chamber.
   */
  private updateDepths(dt: number) {
    const run = this.depths;
    if (!run) return;
    const floor = this.nav.depthsFloor;
    const players = this.playersIn('depths');
    if (!floor || !players.length) return;
    run.floorT += dt;
    if (run.stairOpen || run.floorT < DEPTHS.firstWaveDelayS) return;
    const alive = this.aliveIn('depths');
    const wanted = run.need - run.kills - alive;
    if (wanted <= 0) return;
    run.waveT -= dt;
    if (run.waveT > 0) return;
    const room = Math.min(DEPTHS.cap - alive, GLOBAL_ENEMY_CAP - this.enemies.size);
    if (room <= 0) {
      run.waveT = 0.5;
      return;
    }
    const size = depthWaveSize(run.depth);
    const count = Math.min(wanted, room, run.waved ? size : Math.max(size, 8));
    // The dead climb out of the nearest chambers that are not the hero's own (by doorways, not by distance through a wall): they reach the hero
    // within a few seconds, not after a walk across the whole floor.
    const inRooms = new Set(players.map((p) => roomAt(floor, p.x, p.z)));
    const hops = (room: number) => Math.min(...[...inRooms].map((r) => floorHops(floor, r, room)).map((h) => (h < 0 ? 99 : h)));
    let pool = floor.breaches.filter((b) => !inRooms.has(b.room) && players.every((p) => Math.hypot(p.x - b.x, p.z - b.z) >= SPAWN_MIN_DIST));
    if (!pool.length) pool = floor.breaches.filter((b) => !inRooms.has(b.room));
    if (!pool.length) pool = floor.breaches;
    const nearest = Math.min(...pool.map((b) => hops(b.room)));
    pool = pool.filter((b) => hops(b.room) <= nearest + 1);
    const roster = depthRoster(run.depth);
    let spawned = 0;
    const picks = Math.min(pool.length, count > 6 ? 3 : count > 3 ? 2 : 1);
    const chosen: { x: number; z: number }[] = [];
    for (let i = 0; i < picks; i++) chosen.push(pool.splice(Math.floor(this.rand() * pool.length), 1)[0]);
    for (let i = 0; spawned < count; i++) {
      const b = chosen[i % chosen.length];
      const band = this.spawnAtBreach('depths', b.x, b.z, false, roster, undefined, count - spawned);
      if (!band.length) break;
      spawned += band.length;
    }
    run.waved = true;
    run.waveT = depthWaveGapS(run.depth);
    if (spawned) for (const b of chosen) this.emit({ t: 'wave', area: 'depths', count: spawned, x: b.x, z: b.z });
  }

  // --- Gathering nodes (roadmap §7: shared depletion, per-player rewards) ---

  setNodes(placements: { id: string; type: string; area: AreaId; x: number; z: number; rich?: boolean }[]) {
    this.nodes.clear();
    for (const p of placements) {
      const def = NODES[p.type];
      if (!def) continue;
      this.nodes.set(p.id, { id: p.id, type: p.type, area: p.area, x: p.x, z: p.z, rich: !!p.rich, remaining: this.rollYield(def, !!p.rich), respawnAt: 0 });
    }
  }

  private rollYield(def: NodeDef, rich: boolean) {
    const [lo, hi] = def.yields;
    const n = lo + Math.floor(this.rand() * (hi - lo + 1));
    return Math.max(1, Math.round(n * (rich ? RICH_YIELD : 1)));
  }

  /** Depleted nodes and the seconds until each returns (snapshot + mirror). */
  depletedNodes(): [string, number][] {
    const out: [string, number][] = [];
    for (const n of this.nodes.values()) if (n.remaining <= 0) out.push([n.id, Math.max(0, Math.round((n.respawnAt - this.time) * 10) / 10)]);
    return out;
  }

  private applyGather(g: Extract<Intent, { t: 'gather' }>) {
    const n = this.nodes.get(g.nodeId);
    if (!n || n.remaining <= 0) return;
    // The gatherer must be standing at the node (reach + a little slack for latency).
    const p = this.players.get(g.by);
    if (p && Math.hypot(p.x - n.x, p.z - n.z) > NODE_REACH[NODES[n.type].kind] + 2) return;
    n.remaining -= Math.min(3, Math.max(1, Math.floor(g.successes)));
    if (n.remaining > 0) return;
    n.remaining = 0;
    const respawnS = NODES[n.type].respawnS * (n.rich ? RICH_RESPAWN : 1);
    n.respawnAt = this.time + respawnS;
    this.emit({ t: 'nodeGone', id: n.id, by: g.by, respawnS });
  }

  private updateNodes() {
    for (const n of this.nodes.values()) {
      if (n.remaining > 0 || this.time < n.respawnAt) continue;
      n.remaining = this.rollYield(NODES[n.type], n.rich);
      this.emit({ t: 'nodeBack', id: n.id });
    }
  }

  // --- Step ---

  step(dt: number): SimEvent[] {
    this.time += dt;
    this.updateWaves(dt);
    this.updateDepths(dt);
    this.updateSurge(dt);
    this.tickPendingLitanies();
    this.updateZones(dt);
    if (this.anyPlague) this.updatePlague();
    this.updateWalls();
    this.updateEnemies(dt);
    this.updateThralls(dt);
    this.separate();
    this.boss.update(dt);
    this.updateCorpses();
    this.updateNodes();
    this.collectDead();
    return this.drain();
  }

  private updateZones(dt: number) {
    for (const z of [...this.zones.values()]) {
      if (this.time >= z.until) {
        this.zones.delete(z.id);
        this.plagueZones.delete(z.id);
        this.emit({ t: 'zoneGone', id: z.id });
        continue;
      }
      z.tick -= dt;
      const pulse = z.tick <= 0;
      if (pulse) z.tick = 1;
      if (z.creep && z.kind === 'miasma') this.creepZone(z, dt);
      if (z.kind === 'dirge') {
        this.tickDirge(z, pulse);
        continue;
      }
      if (z.kind === 'witch_charm') {
        const p = [...this.players.values()].find((player) => player.alive && Math.hypot(player.x - z.x, player.z - z.z) <= z.r + PLAYER_RADIUS);
        if (p) {
          this.emit({ t: 'newBlood', by: z.owner, kind: 'heal', ok: true, x: p.x, z: p.z, amount: 0.05, player: p.id });
          this.zones.delete(z.id); this.emit({ t: 'zoneGone', id: z.id });
        }
        continue;
      }
      if (z.kind === 'warden_ward') {
        for (const e of this.enemies.values()) if (e.state !== 'dead' && Math.hypot(e.x - z.x, e.z - z.z) <= z.r + e.radius) e.wardSlowT = Math.max(e.wardSlowT ?? 0, 0.3);
        continue;
      }
      if (z.kind === 'warden_fire' || z.kind === 'witch_crows' || z.kind === 'veil_rift') {
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || Math.hypot(e.x - z.x, e.z - z.z) > z.r + e.radius) continue;
          if (z.kind === 'veil_rift') {
            const [nx, nz] = this.nav.resolveInArea(e.area, e.x + (z.x - e.x) * Math.min(1, dt * 2), e.z + (z.z - e.z) * Math.min(1, dt * 2), e.radius);
            e.x = nx; e.z = nz;
          }
          if (pulse) this.damageEnemy(e, z.dps, z.owner);
        }
        continue;
      }
      if (z.kind === 'flower') this.tickBloomSpread(z, dt);
      if (!z.hostile) {
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || Math.hypot(e.x - z.x, e.z - z.z) > z.r + e.radius) continue;
          e.slowT = 0.3;
          if (pulse) {
            e.withered = Math.min(z.witheredCap, e.withered + 1);
            e.witheredT = 5;
            e.witheredDps = Math.max(e.witheredDps, z.dps);
            e.witheredOwner = z.owner;
            if (z.contagion) e.contagious = true;
          }
        }
        const b = this.boss.state;
        if (b.active && pulse && Math.hypot(b.x - z.x, b.z - z.z) < z.r + BOSS_RADIUS) {
          b.withered = Math.min(z.witheredCap, b.withered + 1);
          b.witheredT = 5;
          b.witheredDps = Math.max(b.witheredDps, z.dps);
        }
        if (z.bloom) {
          for (const c of [...this.corpses.values()]) {
            if (this.bloomed.has(c.id) || Math.hypot(c.x - z.x, c.z - z.z) > z.r) continue;
            this.bloomed.add(c.id);
            this.removeCorpse(c, 'burst', z.owner);
            this.burst('bloom', c.x, c.z, 2.6, z.dps * 4, z.owner, z.witheredCap);
          }
        }
      } else if (pulse) {
        for (const p of this.players.values()) {
          if (p.alive && Math.hypot(p.x - z.x, p.z - z.z) < z.r + PLAYER_RADIUS) {
            this.emit({ t: 'hurt', player: p.id, dmg: z.dps, from: z.kind === 'ember' ? 'burn' : 'toxic', x: z.x, z: z.z });
          }
        }
        for (const t of this.thralls.values()) {
          if (Math.hypot(t.x - z.x, t.z - z.z) < z.r) this.hurtThrall(t, z.dps);
        }
      }
    }
  }

  /** Creeping Rot rune: the circle drifts toward the nearest enemy within reach, staying inside its hall. */
  private creepZone(z: Zone, dt: number) {
    let best: Enemy | null = null;
    let bestD: number = RUNE_TUNING.creepingRot.seekReach;
    for (const e of this.enemies.values()) {
      if (e.state === 'dead' || e.state === 'rising' || e.state === 'burrow') continue;
      const d = Math.hypot(e.x - z.x, e.z - z.z);
      if (d < bestD) {
        bestD = d;
        best = e;
      }
    }
    if (!best || bestD < 0.6) return;
    const step = Math.min((z.creep ?? 0) * dt, bestD);
    const nx = z.x + ((best.x - z.x) / bestD) * step;
    const nz = z.z + ((best.z - z.z) / bestD) * step;
    // A ground effect: it slides over props and bodies, but never out of the hall it was cast in (no crossing a sealed door or wall).
    const area = this.nav.areaAt(z.x, z.z);
    if (area && this.nav.areaAt(nx, nz) !== area) return;
    z.x = nx;
    z.z = nz;
  }

  /** Contagion rune: a dying enemy that a Contagion circle withered hands its stacks (minus one) to its nearest neighbours. */
  private spreadContagion(e: Enemy) {
    const C = RUNE_TUNING.contagion;
    if (!e.contagious || e.withered < C.minStacks) return;
    const stacks = e.withered - 1;
    const neighbours = [...this.enemies.values()]
      .filter((o) => o !== e && o.state !== 'dead' && o.hp > 0 && o.area === e.area && Math.hypot(o.x - e.x, o.z - e.z) <= C.reach)
      .sort((a, b) => Math.hypot(a.x - e.x, a.z - e.z) - Math.hypot(b.x - e.x, b.z - e.z))
      .slice(0, C.neighbours);
    for (const o of neighbours) {
      o.withered = Math.max(o.withered, stacks);
      o.witheredT = Math.max(o.witheredT, 5);
      o.witheredDps = Math.max(o.witheredDps, e.witheredDps);
      o.witheredOwner = e.witheredOwner;
      o.contagious = true;
      this.emit({ t: 'contagion', x: e.x, z: e.z, tx: o.x, tz: o.z, stacks });
    }
  }

  burst(kind: 'bloom' | 'toxic', x: number, z: number, r: number, dmg: number, by: string, witheredCap = 5) {
    this.emit({ t: 'burst', kind, x, z, r });
    for (const e of this.enemies.values()) {
      if (e.state === 'dead' || Math.hypot(e.x - x, e.z - z) > r + e.radius) continue;
      this.damageEnemy(e, dmg, by);
      if (kind === 'bloom') {
        e.withered = Math.min(witheredCap, e.withered + 1);
        e.witheredT = 5;
      }
    }
  }

  private clearSeed(c: Corpse) {
    if (!c.seedOwner) return;
    c.seedOwner = undefined;
    c.seedDmg = undefined;
    c.seedCap = undefined;
    c.seedArmedAt = undefined;
    c.seedExpires = undefined;
    this.emit({ t: 'seedGone', corpseId: c.id });
  }

  /** Armed seeds burst when a living enemy steps within reach; unarmed ones wither after their life. */
  private updateSeeds() {
    for (const c of [...this.corpses.values()]) {
      if (!c.seedOwner) continue;
      if (this.time >= (c.seedExpires ?? 0)) {
        this.clearSeed(c);
        continue;
      }
      if (this.time < (c.seedArmedAt ?? Infinity)) continue;
      let near = false;
      for (const e of this.enemies.values()) {
        if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow')) continue;
        if (Math.hypot(e.x - c.x, e.z - c.z) <= CARRION_SEED.triggerR + e.radius) {
          near = true;
          break;
        }
      }
      if (!near) continue;
      const by = c.seedOwner;
      const dmg = Math.min(1e5, c.seedDmg ?? 0);
      const cap = c.seedCap ?? CARRION_SEED.witheredCap;
      this.removeCorpse(c, 'burst', by);
      let targets = 0;
      for (const e of this.enemies.values()) {
        if (e.state === 'dead' || Math.hypot(e.x - c.x, e.z - c.z) > CARRION_SEED.burstR + e.radius) continue;
        this.damageEnemy(e, dmg, by);
        this.wither(e, CARRION_SEED.withered, cap, dmg * WITHERED.dpsPerStack, by);
        targets++;
      }
      const b = this.boss.state;
      if (b.active && Math.hypot(b.x - c.x, b.z - c.z) <= CARRION_SEED.burstR + BOSS_RADIUS) this.boss.damage(dmg, by, 0);
      this.emit({ t: 'seedBurst', by, x: c.x, z: c.z, r: CARRION_SEED.burstR, targets });
    }
  }

  private updateCorpses() {
    this.updateSeeds();
    for (const c of [...this.corpses.values()]) {
      if (this.time >= c.ruptureAt) {
        this.removeCorpse(c, 'burst');
        const level = this.areaLevel(c.area);
        const zone: Zone = {
          id: this.id(),
          kind: 'toxic',
          owner: '',
          x: c.x,
          z: c.z,
          r: 2.4 * c.scale,
          until: this.time + 5,
          bornAt: this.time,
          tick: 0.4,
          dps: 6 * enemyDamageScale(level),
          slow: 1,
          witheredCap: 0,
          bloom: false,
          hostile: true,
        };
        this.zones.set(zone.id, zone);
        this.emit({ t: 'zone', zone });
        this.emit({ t: 'burst', kind: 'toxic', x: c.x, z: c.z, r: zone.r });
      } else if (this.time >= c.expiresAt) {
        this.removeCorpse(c, 'expired');
      }
    }
  }

  private collectDead() {
    for (const e of [...this.enemies.values()]) {
      if (e.hp > 0 || e.state === 'dead') continue;
      e.state = 'dead';
      this.enemies.delete(e.id);
      this.dotAccum.delete(e.id);
      if (this.surge?.ids.delete(e.id)) this.surge.killed++;
      this.depthsKill(e);
      const def = ENEMIES[e.def];
      if (e.withered > 0 && this.legends.size) this.spreadWithered(e);
      this.emit({
        t: 'death',
        id: e.id,
        def: e.def,
        x: e.x,
        z: e.z,
        elite: e.elite,
        area: e.area,
        level: e.level,
        killer: e.lastHitBy,
      });
      this.addCorpse(e.x, e.z, def.corpse, e.def, e.elite, e.facing, e.scale, e.area);
      if (def.corpse !== 'none' && [...this.players.values()].some((p) => p.alive && p.area === e.area && p.family === 'veil')) {
        const echo = this.addCorpse(e.x + 0.45, e.z + 0.45, 'normal', e.def, false, e.facing, 0.65, e.area);
        if (echo) { echo.echoOwner = '*'; echo.expiresAt = this.time + 20; }
      }
      this.spreadContagion(e);
      if ((e.hexT ?? 0) > 0 && e.hexOwner) {
        const neighbours = [...this.enemies.values()].filter((other) => other.state !== 'dead' && other.area === e.area
          && Math.hypot(other.x - e.x, other.z - e.z) <= 6)
          .sort((a, b) => Math.hypot(a.x - e.x, a.z - e.z) - Math.hypot(b.x - e.x, b.z - e.z)).slice(0, 2);
        for (const other of neighbours) { other.hexT = Math.max(other.hexT ?? 0, 8); other.hexOwner = e.hexOwner; }
      }
      // A Bone Golem falls apart into the skeletons it was fused from (ringed around it).
      for (let k = 1; k < (def.deathCorpses ?? 1); k++) {
        const a = e.facing + (k / (def.deathCorpses! - 1)) * Math.PI * 2;
        const [cx, cz] = this.nav.resolveInArea(e.area, e.x + Math.sin(a) * 1.6, e.z + Math.cos(a) * 1.6, 0.4);
        this.addCorpse(cx, cz, def.corpse, 'risen', false, a, 1, e.area);
      }
      if (this.hasAffix(e, 'vengeful')) this.vengeance(e);
      // Cinder Husk: the embers it dies in stay behind as burning ground.
      if (def.emberDeath) {
        this.emberPool(e.x, e.z, EMBER_DEATH.radius, EMBER_DEATH.poolS, e.damage * EMBER_DEATH.poolDpsMult);
        this.emit({ t: 'burst', kind: 'ember', x: e.x, z: e.z, r: EMBER_DEATH.radius });
      }
    }
  }

  /**
   * Plague Choir 4 (Contagion): an enemy dying inside its stacker's own Miasma passes its Withered stacks to up to
   * LEGEND.spreadMax living enemies within LEGEND.spreadR (nearest first). One hop per death; the neighbours that die in the
   * cloud pass it on again, which is the point and is bounded by the enemies alive.
   */
  private spreadWithered(dead: Enemy) {
    const owner = dead.witheredOwner;
    if (!owner || !this.legends.get(owner)?.miasmaSpreadsWithered) return;
    let cap = 0;
    for (const z of this.zones.values()) {
      if (z.hostile || z.kind !== 'miasma' || z.owner !== owner) continue;
      if (Math.hypot(dead.x - z.x, dead.z - z.z) <= z.r + dead.radius) cap = Math.max(cap, z.witheredCap);
    }
    if (cap <= 0) return;
    const near = [...this.enemies.values()]
      .filter((o) => o.id !== dead.id && o.hp > 0 && o.state !== 'dead' && o.state !== 'burrow' && o.area === dead.area && Math.hypot(o.x - dead.x, o.z - dead.z) <= LEGEND.spreadR)
      .sort((a, b) => Math.hypot(a.x - dead.x, a.z - dead.z) - Math.hypot(b.x - dead.x, b.z - dead.z))
      .slice(0, LEGEND.spreadMax);
    if (!near.length) return;
    for (const o of near) {
      o.withered = Math.min(cap, Math.max(o.withered, 0) + dead.withered);
      o.witheredT = Math.max(o.witheredT, WITHERED.durationMs / 1000);
      o.witheredDps = Math.max(o.witheredDps, dead.witheredDps);
      o.witheredOwner = owner;
    }
    this.emit({ t: 'legend', kind: 'spread', by: owner, x: dead.x, z: dead.z, r: LEGEND.spreadR });
  }

  /**
   * Plague Choir 5 (Chain Plague): an enemy whose Withered stacks reach the owner's witheredBurstAt loses them and a fresh Miasma
   * (the owner's last cast: same size, damage and duration) opens on it. 1 s cooldown per enemy; at most LEGEND.burstClouds of
   * these clouds stand at once, so a dense pack cannot run away with it.
   */
  private updatePlague() {
    for (const e of this.enemies.values()) {
      if (e.withered <= 0 || e.state === 'dead' || e.hp <= 0) continue;
      const owner = e.witheredOwner;
      const at = owner ? (this.legends.get(owner)?.witheredBurstAt ?? 0) : 0;
      if (at <= 0 || e.withered < at || this.time < (e.plagueAt ?? 0)) continue;
      if (this.plagueZones.size >= LEGEND.burstClouds) return;
      const last = this.lastMiasma.get(owner);
      const r = last?.r ?? ABILITIES.miasma.radius;
      const dps = last?.dps ?? e.witheredDps / WITHERED.dpsPerStack;
      e.plagueAt = this.time + LEGEND.burstCdS;
      e.withered = 0;
      e.witheredT = 0;
      e.witheredDps = 0;
      const zone: Zone = {
        id: this.id(), kind: 'miasma', owner, x: e.x, z: e.z, r,
        until: this.time + (last?.durationMs ?? 6000) / 1000, bornAt: this.time, tick: 0, dps,
        slow: MIASMA_SLOW, witheredCap: Math.max(last?.cap ?? 5, at), bloom: last?.bloom ?? false, hostile: false,
      };
      this.zones.set(zone.id, zone);
      this.plagueZones.add(zone.id);
      this.emit({ t: 'zone', zone });
      this.emit({ t: 'legend', kind: 'plague', by: owner, x: e.x, z: e.z, r });
    }
  }

  /** Censer Bearer: each second the incense Incenses every living dead within reach (itself too). */
  private censerPulse(e: Enemy, dt: number) {
    e.auraCd = (e.auraCd ?? 0) - dt;
    if (e.auraCd > 0) return;
    e.auraCd = 1;
    for (const o of this.enemies.values()) {
      if (o.state === 'dead' || o.area !== e.area || Math.hypot(o.x - e.x, o.z - e.z) > CENSER.radius) continue;
      o.incenseT = Math.max(o.incenseT ?? 0, CENSER.hasteS);
    }
  }

  // --- Elite affixes ---

  /** Does the elite carry this affix (as its first or as one of the Depths' extras)? */
  hasAffix(e: Enemy, a: EliteAffix) {
    return e.affix === a || !!e.extra?.some((x) => x.affix === a);
  }

  /** A Lantern Cone / Last Light strips Shrouded, from the first slot or an extra one. */
  private stripShroud(e: Enemy) {
    if (e.affix === 'shrouded') e.affix = undefined;
    if (e.extra) e.extra = e.extra.filter((x) => x.affix !== 'shrouded');
  }

  private tickAffix(e: Enemy, dt: number) {
    this.tickAffixKind(e, e.affix, e, dt);
    // Extras keep their own clocks (and run only on elites the Depths dressed).
    if (e.extra) for (const x of e.extra) this.tickAffixKind(e, x.affix, x, dt);
  }

  private tickAffixKind(e: Enemy, kind: EliteAffix | undefined, st: { affixCd?: number; tollAt?: { t: number; x: number; z: number } }, dt: number) {
    switch (kind) {
      case 'bellTolled': {
        const T = AFFIX_TUNING.bellTolled;
        if (st.tollAt) {
          if (this.time >= st.tollAt.t) {
            const { x, z } = st.tollAt;
            st.tollAt = undefined;
            this.soundToll(e, x, z);
          }
          return;
        }
        st.affixCd = (st.affixCd ?? T.intervalS) - dt;
        if (st.affixCd > 0) return;
        st.affixCd = T.intervalS;
        // The ring is anchored where it was rung — walking out of it is the answer.
        st.tollAt = { t: this.time + T.windupS, x: e.x, z: e.z };
        this.emit({ t: 'telegraph', id: e.id, kind: 'toll', x: e.x, z: e.z, tx: e.x, tz: e.z, ms: T.windupS * 1000, r: T.r });
        return;
      }
      case 'hungering': {
        const T = AFFIX_TUNING.hungering;
        st.affixCd = (st.affixCd ?? T.intervalS) - dt;
        if (st.affixCd > 0) return;
        const c = e.hp < e.maxHp ? this.nearestCorpse(e.x, e.z, T.reach) : null;
        if (!c) {
          st.affixCd = 0.5; // look again shortly
          return;
        }
        st.affixCd = T.intervalS;
        const heal = Math.min(e.maxHp - e.hp, e.maxHp * T.healFrac);
        e.hp += heal;
        this.emit({ t: 'affix', id: e.id, affix: 'hungering', x: e.x, z: e.z, tx: c.x, tz: c.z, amount: Math.round(heal) });
        this.removeCorpse(c, 'devoured');
        return;
      }
    }
  }

  private soundToll(e: Enemy, x: number, z: number) {
    const T = AFFIX_TUNING.bellTolled;
    const dmg = this.blow(e) * T.damageMult;
    for (const p of this.players.values()) {
      // Centre inside the drawn bronze ring, like every other ground telegraph (it used to reach a body's width past it).
      if (p.alive && Math.hypot(p.x - x, p.z - z) <= T.r) {
        this.emit({ t: 'hurt', player: p.id, dmg, from: 'toll', x, z });
      }
    }
    for (const t of [...this.thralls.values()]) if (Math.hypot(t.x - x, t.z - z) <= T.r) this.hurtThrall(t, dmg);
    this.emit({ t: 'affix', id: e.id, affix: 'bellTolled', x, z, r: T.r });
  }

  /** Vengeful elites burst into Risen where they fall. */
  private vengeance(e: Enemy) {
    const n = AFFIX_TUNING.vengeful.risen;
    this.emit({ t: 'affix', id: e.id, affix: 'vengeful', x: e.x, z: e.z, r: 1.8 });
    const spin = this.rand() * Math.PI * 2;
    for (let i = 0; i < n; i++) {
      const ang = spin + (i / n) * Math.PI * 2;
      const [x, z] = this.nav.resolveInArea(e.area, e.x + Math.cos(ang) * 1.4, e.z + Math.sin(ang) * 1.4, 0.45);
      this.spawnEnemy('risen', e.area, x, z, false);
    }
  }

  // --- Enemy AI ---

  private pickTarget(e: Enemy): { x: number; z: number; player?: PlayerBody; thrall?: Thrall } | null {
    let best: { x: number; z: number; player?: PlayerBody; thrall?: Thrall } | null = null;
    // A Depths floor is a few small rooms: the dead of any chamber know where the hero is, and walk the doorways to get there.
    let bestD = e.area === 'depths' ? DEPTHS_AGGRO : AGGRO_RANGE;
    for (const p of this.players.values()) {
      if (!p.alive || p.area !== e.area) continue;
      const d = Math.hypot(p.x - e.x, p.z - e.z);
      if (d < bestD) {
        bestD = d;
        best = { x: p.x, z: p.z, player: p };
      }
    }
    for (const t of this.thralls.values()) {
      if (t.state === 'dead' || t.state === 'rising') continue;
      // Shieldbearers draw aggression (Bone Ward).
      const d = Math.hypot(t.x - e.x, t.z - e.z) * (t.kind === 'shieldbearer' ? 0.55 : 1.1);
      if (d < bestD) {
        bestD = d;
        best = { x: t.x, z: t.z, thrall: t };
      }
    }
    return best;
  }

  /** The most wounded unblessed non-Deacon ally within reach. */
  private sanctifyTarget(e: Enemy): Enemy | null {
    let best: Enemy | null = null;
    let bestFrac = 0.999;
    for (const o of this.enemies.values()) {
      if (o === e || o.def === 'deacon' || o.state === 'dead' || (o.state === 'rising' || o.state === 'burrow') || (o.sanctT ?? 0) > 0) continue;
      if (Math.hypot(o.x - e.x, o.z - e.z) > SANCTIFIED.range) continue;
      const frac = o.hp / o.maxHp;
      if (frac < bestFrac) {
        bestFrac = frac;
        best = o;
      }
    }
    return best;
  }

  private moveEnemy(e: Enemy, tx: number, tz: number, dt: number, speedMult = 1) {
    // Grave Brand roots the feet only — a rooted body still turns and swings.
    if ((e.rootT ?? 0) > 0) {
      e.facing = Math.atan2(tx - e.x, tz - e.z);
      return;
    }
    // On a Depths floor the dead walk through the doorways (nav.depthsHop), not at the wall between them and the hero.
    if (e.area === 'depths') {
      const hop = this.nav.depthsHop(e.x, e.z, tx, tz);
      if (hop) {
        tx = hop.x;
        tz = hop.z;
      }
    }
    const dx = tx - e.x;
    const dz = tz - e.z;
    const d = Math.hypot(dx, dz);
    if (d < 0.05) return;
    const slow = Math.min(e.slowT > 0 ? MIASMA_SLOW : 1, (e.wardSlowT ?? 0) > 0 ? WATCHMANS_WARD_SLOW : 1)
      * ((e.chillT ?? 0) > 0 ? CHILL.moveMult : 1) * ((e.incenseT ?? 0) > 0 ? CENSER.moveMult : 1) * (this.frenzied(e) ? FRENZY.moveMult : 1);
    const step = Math.min(d, e.speed * speedMult * slow * dt);
    const px = e.x;
    const pz = e.z;
    [e.x, e.z] = this.nav.resolveInArea(e.area, e.x + (dx / d) * step, e.z + (dz / d) * step, e.radius);
    if (this.walls.size) [e.x, e.z] = this.pushOffWalls(px, pz, e.x, e.z, e.radius);
    // Depths: lined up on a pillar the push-out sends a body straight back; swing a little to either side to get round it.
    if (e.area === 'depths' && step > 1e-3 && ((e.x - px) * dx + (e.z - pz) * dz) / d < step * 0.3) {
      const [sx, sz] = this.sidestep(px, pz, dx / d, dz / d, step, e.radius, (x, z) => this.nav.resolveInArea(e.area, x, z, e.radius));
      e.x = sx;
      e.z = sz;
    }
    e.facing = Math.atan2(dx, dz);
    e.moving = true;
    e.gait += step * 2.4;
  }

  /** The best of two headings 50 degrees either side of the blocked one (the one that makes more way toward the goal), or where the body stood. */
  private sidestep(px: number, pz: number, ux: number, uz: number, step: number, _r: number, resolve: (x: number, z: number) => [number, number]): [number, number] {
    let best: [number, number] = [px, pz];
    let bestGain = 0;
    for (const a of [0.87, -0.87]) {
      const c = Math.cos(a);
      const s = Math.sin(a);
      const [nx, nz] = resolve(px + (ux * c - uz * s) * step, pz + (ux * s + uz * c) * step);
      const gain = (nx - px) * ux + (nz - pz) * uz + Math.hypot(nx - px, nz - pz) * 0.5;
      if (gain > bestGain) {
        bestGain = gain;
        best = [nx, nz];
      }
    }
    return best;
  }

  /** Where a Bog Hag lays her hex: the centre of the thrall standing in the thickest knot within reach; the target itself if none. */
  private hexAim(e: Enemy, target: { x: number; z: number }): [number, number] {
    const reach = ENEMIES[e.def].attackRange;
    let best: Thrall | null = null;
    let bestN = 0;
    for (const t of this.thralls.values()) {
      if (t.state === 'dead' || t.state === 'rising' || Math.hypot(t.x - e.x, t.z - e.z) > reach) continue;
      let n = 0;
      for (const o of this.thralls.values()) if (o.state !== 'dead' && Math.hypot(o.x - t.x, o.z - t.z) <= HAG_HEX.radius) n++;
      if (n > bestN) {
        bestN = n;
        best = t;
      }
    }
    return best ? [best.x, best.z] : [target.x, target.z];
  }

  private hurtThrall(t: Thrall, dmg: number) {
    t.hp -= dmg;
    t.flash = 1;
    if (t.hp <= 0) this.killThrall(t, 'killed');
  }

  /** A hostile burning pool (Pyre Priest coals, a Husk's last embers, a Slag Brute's slam). */
  emberPool(x: number, z: number, r: number, seconds: number, dps: number) {
    const zone: Zone = {
      id: this.id(), kind: 'ember', owner: '', x, z, r,
      until: this.time + seconds, bornAt: this.time, tick: 1, dps,
      slow: 1, witheredCap: 0, bloom: false, hostile: true,
    };
    this.zones.set(zone.id, zone);
    this.emit({ t: 'zone', zone });
    return zone;
  }

  private strike(e: Enemy, kind: 'melee' | 'cone' | 'curse' | 'slam' | 'scream' | 'dust' | 'flask' | 'ember' | 'hex' | 'pulse' | 'hook', slamR?: number) {
    const def = ENEMIES[e.def];
    if (kind === 'hex') {
      // Bog Hag: players in the ring are mired (a short chill) and nicked; thralls in it are hexed, dealing less for a few seconds.
      for (const p of this.players.values()) {
        if (p.alive && Math.hypot(p.x - e.aimX, p.z - e.aimZ) <= HAG_HEX.radius) {
          this.emit({ t: 'hurt', player: p.id, dmg: this.blow(e) * HAG_HEX.blowMult, from: 'curse', x: e.x, z: e.z, chillMs: HAG_HEX.chillMs });
        }
      }
      for (const t of [...this.thralls.values()]) {
        if (Math.hypot(t.x - e.aimX, t.z - e.aimZ) > HAG_HEX.radius) continue;
        this.hurtThrall(t, this.blow(e) * HAG_HEX.blowMult);
        if (t.hp > 0) t.cursedT = HAG_HEX.durationS;
      }
      return;
    }
    if (kind === 'pulse') {
      // Fen Wisp: a ring of marsh-cold where the target stood; it chills (slows) whoever is in it.
      for (const p of this.players.values()) {
        if (p.alive && Math.hypot(p.x - e.aimX, p.z - e.aimZ) <= WISP_PULSE.radius) {
          this.emit({ t: 'hurt', player: p.id, dmg: this.blow(e), from: 'dust', x: e.x, z: e.z, chillMs: WISP_PULSE.chillMs });
        }
      }
      for (const t of [...this.thralls.values()]) if (Math.hypot(t.x - e.aimX, t.z - e.aimZ) <= WISP_PULSE.radius) this.hurtThrall(t, this.blow(e));
      return;
    }
    if (kind === 'hook') {
      // Drowned Sexton: everything on the chain's line (from him toward the aim, out to its range) is struck, and players are dragged in.
      const dx = e.aimX - e.x;
      const dz = e.aimZ - e.z;
      const len = Math.hypot(dx, dz) || 1;
      const ux = dx / len;
      const uz = dz / len;
      const onLine = (x: number, z: number) => {
        const along = (x - e.x) * ux + (z - e.z) * uz;
        if (along < 0 || along > SEXTON_HOOK.range + 0.6) return false;
        return Math.abs((x - e.x) * uz - (z - e.z) * ux) <= SEXTON_HOOK.halfWidth + 0.3 && !this.wallBetween(e.x, e.z, x, z);
      };
      for (const p of this.players.values()) {
        if (p.alive && onLine(p.x, p.z)) {
          this.emit({ t: 'hurt', player: p.id, dmg: this.blow(e) * SEXTON_HOOK.blowMult, from: 'melee', x: e.x, z: e.z, pull: { x: e.x, z: e.z, m: SEXTON_HOOK.pullM, rootMs: SEXTON_HOOK.rootMs } });
        }
      }
      for (const t of [...this.thralls.values()]) if (onLine(t.x, t.z)) this.hurtThrall(t, this.blow(e) * SEXTON_HOOK.blowMult);
      this.emit({ t: 'melee', id: e.id, x: e.x, z: e.z, tx: e.aimX, tz: e.aimZ });
      return;
    }
    if (kind === 'ember') {
      // Pyre Priest: the coal bursts where the target stood, then leaves burning ground.
      for (const p of this.players.values()) {
        if (p.alive && Math.hypot(p.x - e.aimX, p.z - e.aimZ) <= EMBER_BOLT.radius) {
          this.emit({ t: 'hurt', player: p.id, dmg: this.blow(e), from: 'ember', x: e.x, z: e.z });
        }
      }
      for (const t of [...this.thralls.values()]) if (Math.hypot(t.x - e.aimX, t.z - e.aimZ) <= EMBER_BOLT.radius) this.hurtThrall(t, this.blow(e));
      this.emberPool(e.aimX, e.aimZ, EMBER_BOLT.radius, EMBER_BOLT.poolS, this.blow(e) * EMBER_BOLT.poolDpsMult);
      return;
    }
    if (kind === 'flask') {
      // Plague Doctor: the flask bursts where the target stood, then leaves a rot pool (a hostile toxic zone).
      for (const p of this.players.values()) {
        if (p.alive && Math.hypot(p.x - e.aimX, p.z - e.aimZ) <= PLAGUE_FLASK.radius) {
          this.emit({ t: 'hurt', player: p.id, dmg: this.blow(e), from: 'toxic', x: e.x, z: e.z });
        }
      }
      for (const t of [...this.thralls.values()]) if (Math.hypot(t.x - e.aimX, t.z - e.aimZ) <= PLAGUE_FLASK.radius) this.hurtThrall(t, this.blow(e));
      const zone: Zone = {
        id: this.id(), kind: 'toxic', owner: '', x: e.aimX, z: e.aimZ, r: PLAGUE_FLASK.radius,
        until: this.time + PLAGUE_FLASK.poolS, bornAt: this.time, tick: 1, dps: this.blow(e) * PLAGUE_FLASK.poolDpsMult,
        slow: 1, witheredCap: 0, bloom: false, hostile: true,
      };
      this.zones.set(zone.id, zone);
      this.emit({ t: 'zone', zone });
      this.emit({ t: 'burst', kind: 'toxic', x: e.aimX, z: e.aimZ, r: PLAGUE_FLASK.radius });
      return;
    }
    if (kind === 'dust') {
      // Shroud Moth: the burst chokes whoever is in the ring, then the dust hangs there (a hostile zone).
      for (const p of this.players.values()) {
        if (p.alive && Math.hypot(p.x - e.aimX, p.z - e.aimZ) <= DUST.radius) {
          this.emit({ t: 'hurt', player: p.id, dmg: this.blow(e), from: 'dust', x: e.x, z: e.z });
        }
      }
      for (const t of [...this.thralls.values()]) if (Math.hypot(t.x - e.aimX, t.z - e.aimZ) <= DUST.radius) this.hurtThrall(t, this.blow(e));
      const zone: Zone = {
        id: this.id(),
        kind: 'dust',
        owner: '',
        x: e.aimX,
        z: e.aimZ,
        r: DUST.radius,
        until: this.time + DUST.cloudS,
        bornAt: this.time,
        tick: 1,
        dps: this.blow(e) * DUST.cloudDpsMult,
        slow: 1,
        witheredCap: 0,
        bloom: false,
        hostile: true,
      };
      this.zones.set(zone.id, zone);
      this.emit({ t: 'zone', zone });
      return;
    }
    if (kind === 'scream') {
      // Choir Wraith: the hymn breaks on the ring it sang onto the ground (step out in time).
      for (const p of this.players.values()) {
        if (p.alive && Math.hypot(p.x - e.aimX, p.z - e.aimZ) <= SCREAM.radius) {
          this.emit({ t: 'hurt', player: p.id, dmg: this.blow(e), from: 'scream', x: e.x, z: e.z });
        }
      }
      for (const t of [...this.thralls.values()]) if (Math.hypot(t.x - e.aimX, t.z - e.aimZ) <= SCREAM.radius) this.hurtThrall(t, this.blow(e));
      return;
    }
    if (kind === 'cone') {
      const dirX = e.aimX - e.x;
      const dirZ = e.aimZ - e.z;
      const len = Math.hypot(dirX, dirZ) || 1;
      const hits = (x: number, z: number) => {
        const vx = x - e.x;
        const vz = z - e.z;
        const d = Math.hypot(vx, vz);
        if (d > def.attackRange + CONE_REACH_PAD) return false;
        if (this.wallBetween(e.x, e.z, x, z)) return false; // the cone breaks on an Ossuary Wall
        return (vx * dirX + vz * dirZ) / (d * len || 1) > Math.cos((30 * Math.PI) / 180);
      };
      for (const p of this.players.values()) {
        if (p.alive && hits(p.x, p.z)) this.emit({ t: 'hurt', player: p.id, dmg: this.blow(e), from: 'cone', x: e.x, z: e.z });
      }
      for (const t of [...this.thralls.values()]) if (hits(t.x, t.z)) this.hurtThrall(t, this.blow(e));
      return;
    }
    const reach = kind === 'slam' ? (slamR ?? def.slamRadius ?? 1.9) : def.attackRange * 1.35 + 0.4;
    const cx = kind === 'slam' ? e.aimX : e.x;
    const cz = kind === 'slam' ? e.aimZ : e.z;
    const p = e.targetPlayer ? this.players.get(e.targetPlayer) : undefined;
    if (p && p.alive && Math.hypot(p.x - cx, p.z - cz) <= reach) {
      this.emit({ t: 'hurt', player: p.id, dmg: this.blow(e), from: kind === 'curse' ? 'curse' : def.rotBite ? 'toxic' : 'melee', x: e.x, z: e.z });
    }
    const t = e.targetThrall !== null ? this.thralls.get(e.targetThrall) : undefined;
    if (t && Math.hypot(t.x - cx, t.z - cz) <= reach) this.hurtThrall(t, this.blow(e));
    if (kind === 'slam') {
      for (const other of this.players.values()) {
        if (other !== p && other.alive && Math.hypot(other.x - cx, other.z - cz) <= reach) {
          this.emit({ t: 'hurt', player: other.id, dmg: this.blow(e), from: 'melee', x: e.x, z: e.z });
        }
      }
    }
    this.emit({ t: 'melee', id: e.id, x: e.x, z: e.z, tx: cx, tz: cz });
  }

  private tickStatuses(e: Enemy, dt: number) {
    if ((e.knellBeats ?? 0) > 0 && this.time >= (e.knellNext ?? Infinity)) {
      e.knellNext = this.time + 1.2;
      e.knellBeats!--;
      this.damageEnemy(e, Math.max(1, e.knellDamage ?? 1), e.knellOwner ?? '');
    }
    e.flash = Math.max(0, e.flash - dt * 8);
    if ((e.markT ?? 0) > 0) e.markT! -= dt;
    if (e.slowT > 0) e.slowT -= dt;
    if ((e.wardSlowT ?? 0) > 0) e.wardSlowT! -= dt;
    if (e.fractureT > 0) {
      e.fractureT -= dt;
      if (e.fractureT <= 0) e.fracture = 0;
    }
    if ((e.chillT ?? 0) > 0) e.chillT! -= dt;
    if ((e.sanctT ?? 0) > 0) e.sanctT! -= dt;
    if ((e.hexT ?? 0) > 0) e.hexT! -= dt;
    if ((e.silenceT ?? 0) > 0) e.silenceT! -= dt;
    if ((e.stunT ?? 0) > 0) e.stunT! -= dt;
    if ((e.rootT ?? 0) > 0) e.rootT! -= dt;
    if ((e.incenseT ?? 0) > 0) e.incenseT! -= dt;
    if ((e.unbindCd ?? 0) > 0) e.unbindCd! -= dt;
    if ((e.bleedT ?? 0) > 0 && (e.bleedDps ?? 0) > 0) {
      e.bleedT! -= dt;
      const dmg = e.bleedDps! * dt * this.damageTakenMult(e);
      e.hp -= dmg;
      e.lastHitBy = e.bleedOwner || e.lastHitBy;
      const acc = (this.dotAccum.get(e.id) ?? 0) + dmg;
      if (acc >= Math.max(4, e.maxHp * 0.06)) {
        this.emit({ t: 'dmg', x: e.x, z: e.z, amount: Math.round(acc), kind: 'dot', by: e.bleedOwner ?? '' });
        this.dotAccum.set(e.id, 0);
      } else this.dotAccum.set(e.id, acc);
      if (e.bleedT! <= 0) e.bleedDps = 0;
    }
    if (e.witheredT > 0 && e.withered > 0) {
      e.witheredT -= dt;
      const dmg = e.withered * e.witheredDps * dt * this.damageTakenMult(e);
      e.hp -= dmg;
      e.lastHitBy = e.witheredOwner || e.lastHitBy;
      const acc = (this.dotAccum.get(e.id) ?? 0) + dmg;
      if (acc >= Math.max(4, e.maxHp * 0.06)) {
        this.emit({ t: 'dmg', x: e.x, z: e.z, amount: Math.round(acc), kind: 'dot', by: e.witheredOwner });
        this.dotAccum.set(e.id, 0);
      } else this.dotAccum.set(e.id, acc);
      if (e.witheredT <= 0) {
        e.withered = 0;
        e.witheredDps = 0;
      }
    }
  }

  private updateEnemies(dt: number) {
    const activeAreas = new Set<AreaId>();
    for (const p of this.players.values()) if (p.alive && p.area) activeAreas.add(p.area);
    this.tickUnbinds();
    for (const e of this.enemies.values()) {
      e.moving = false;
      this.tickStatuses(e, dt);
      e.stateT += dt;
      if (e.state === 'rising') {
        if (e.stateT >= RISE_TIME) {
          e.state = 'move';
          e.stateT = 0;
        }
        continue;
      }
      if (!activeAreas.has(e.area)) continue; // dormant: nobody here to hunt
      if (e.state === 'burrow') {
        this.tickBurrow(e, dt);
        continue;
      }
      if (ENEMIES[e.def].inert) continue; // a skull niche only stands there to be broken
      // Shield Bash: stunned bodies neither act nor move, and a stun cancels a
      // windup or channel outright (this is the interrupt the Knight pays for).
      if ((e.stunT ?? 0) > 0) {
        if (e.state === 'windup' || e.state === 'channel') {
          e.state = 'recover';
          e.stateT = 0;
          e.channelCorpse = null;
          if (e.diving) this.endDive(e);
          // A stun can't reach a ghoul still underground: it just keeps tunnelling.
          if (e.erupting != null) {
            e.erupting = null;
            e.state = 'burrow';
          }
        }
        continue;
      }
      if (e.affix) this.tickAffix(e, dt);
      if ((e.hookCd ?? 0) > 0) e.hookCd! -= dt;
      e.attackCd -= dt * ((e.chillT ?? 0) > 0 ? CHILL.attackRateMult : 1) * ((e.incenseT ?? 0) > 0 ? CENSER.attackRateMult : 1) * (this.frenzied(e) ? FRENZY.attackRateMult : 1);
      const def = ENEMIES[e.def];
      // Elites wind up 15% faster (the windup branch below): a telegraph must fill in the time the blow really takes.
      const wms = def.windupMs * (e.elite ? 0.85 : 1);
      if (def.aura) this.censerPulse(e, dt);

      if (e.state === 'windup' || e.state === 'channel') {
        const windup = e.erupting != null && e.state === 'windup' ? this.eruptMs(e) / 1000 : (e.state === 'channel' ? 1.5 : def.windupMs / 1000) * (e.elite ? 0.85 : 1);
        // Belfry Gargoyle: it hangs over the mark for the first half, then drops onto it in a straight line.
        if (e.diving) {
          const k = Math.max(0, Math.min(1, (e.stateT - windup * 0.5) / (windup * 0.5)));
          const ease = k * k;
          e.x = (e.diveX ?? e.x) + (e.aimX - (e.diveX ?? e.x)) * ease;
          e.z = (e.diveZ ?? e.z) + (e.aimZ - (e.diveZ ?? e.z)) * ease;
        }
        if (e.stateT >= windup) this.release(e);
        continue;
      }
      if (e.state === 'recover') {
        // A landed gargoyle sits grounded (groundT) before it takes off again.
        if (e.stateT >= 0.3 + (e.groundT ?? 0)) {
          e.state = 'move';
          e.stateT = 0;
          e.groundT = 0;
          // Barrow Ghoul finished digging: back underground for one more tunnel.
          if (e.digPending) {
            e.digPending = false;
            e.state = 'burrow';
            e.burrowLeft = BURROW.travelM;
            // Digging in shrugs off bleeds, rot and holds: it must not die or stick fast underground.
            e.bleedT = 0;
            e.bleedDps = 0;
            e.withered = 0;
            e.witheredT = 0;
            e.rootT = 0;
            e.slowT = 0;
            e.chillT = 0;
          }
        }
        continue;
      }

      // Deacons harvest any unclaimed corpse in reach, hunting or not — that
      // corpse competition is why they're the priority kill.
      const silenced = (e.silenceT ?? 0) > 0;
      if (def.ward && e.attackCd <= 0 && !silenced) this.seraphWard(e);
      if (def.behavior === 'support' && !def.ward && e.attackCd <= 0 && !silenced) {
        const corpse = this.nearestCorpse(e.x, e.z, 8);
        if (corpse) {
          e.state = 'channel';
          e.stateT = 0;
          e.channelCorpse = corpse.id;
          e.aimX = corpse.x;
          e.aimZ = corpse.z;
          this.emit({ t: 'telegraph', id: e.id, kind: 'raise', x: e.x, z: e.z, tx: corpse.x, tz: corpse.z, ms: 1500 * (e.elite ? 0.85 : 1) });
          continue;
        }
        // No corpse to steal: bless the nearest wounded ally instead (Sanctified).
        const ally = this.sanctifyTarget(e);
        if (ally) {
          ally.sanctT = SANCTIFIED.durationS;
          e.attackCd = (def.cooldownMs / 1000) * SANCTIFIED.cooldownMult;
          this.emit({ t: 'sanctify', id: e.id, target: ally.id, x: e.x, z: e.z, tx: ally.x, tz: ally.z });
        }
      }

      const target = this.pickTarget(e);
      e.targetPlayer = target?.player?.id ?? null;
      e.targetThrall = target?.thrall?.id ?? null;
      if (!target) {
        // Shamble toward the nearest breach-side wander point.
        if (this.rand() < dt * 0.3) e.facing += (this.rand() - 0.5) * 2;
        this.moveEnemy(e, e.x + Math.sin(e.facing), e.z + Math.cos(e.facing), dt, 0.3);
        continue;
      }
      const dist = Math.hypot(target.x - e.x, target.z - e.z);
      // Depths: a target in another chamber is walked to through the doorways (moveEnemy steers); nothing attacks through a wall.
      if (e.area === 'depths' && this.nav.depthsHop(e.x, e.z, target.x, target.z)) {
        this.moveEnemy(e, target.x, target.z, dt);
        continue;
      }

      switch (def.behavior) {
        case 'melee':
        case 'hazard':
        case 'flank': {
          if ((e.fleeT ?? 0) > 0) {
            // Tithe Bat: flit away (and a little sideways) after a bite, then come back.
            e.fleeT! -= dt;
            const px = -(target.z - e.z) / (dist || 1);
            const pz = (target.x - e.x) / (dist || 1);
            this.moveEnemy(e, e.x * 2 - target.x + px * 2 * e.flankSide, e.z * 2 - target.z + pz * 2 * e.flankSide, dt);
            break;
          }
          // Drowned Sexton: from range he throws the grave-hook along a line (a telegraphed line), then drags whoever it caught.
          if (def.hook && target.player && e.attackCd <= 0 && (e.hookCd ?? 0) <= 0 && dist >= SEXTON_HOOK.minRange && dist <= SEXTON_HOOK.range && !this.wallBetween(e.x, e.z, target.x, target.z)) {
            e.state = 'windup';
            e.stateT = 0;
            e.hooking = true;
            e.hookCd = SEXTON_HOOK.cooldownS;
            e.aimX = target.x;
            e.aimZ = target.z;
            e.facing = Math.atan2(target.x - e.x, target.z - e.z);
            this.emit({ t: 'telegraph', id: e.id, kind: 'hook', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms, r: SEXTON_HOOK.range });
            break;
          }
          if (def.dive && e.attackCd <= 0 && dist >= def.dive.minRange && dist <= def.dive.range && !this.wallBetween(e.x, e.z, target.x, target.z)) {
            e.state = 'windup';
            e.stateT = 0;
            e.diving = true;
            e.diveX = e.x;
            e.diveZ = e.z;
            e.aimX = target.x;
            e.aimZ = target.z;
            e.facing = Math.atan2(target.x - e.x, target.z - e.z);
            this.emit({ t: 'telegraph', id: e.id, kind: 'dive', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms, r: def.dive.radius });
            break;
          }
          if (dist <= def.attackRange + 0.35 && e.attackCd <= 0) {
            e.state = 'windup';
            e.stateT = 0;
            e.aimX = target.x;
            e.aimZ = target.z;
            e.facing = Math.atan2(target.x - e.x, target.z - e.z);
            if (def.behavior === 'hazard') {
              this.emit({ t: 'telegraph', id: e.id, kind: 'slam', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms, ...(def.slamRadius ? { r: def.slamRadius } : {}) });
            }
          } else if (dist > def.attackRange * 0.8) {
            let tx = target.x;
            let tz = target.z;
            if (def.behavior === 'flank' && dist > 2.5) {
              // Curve around the target's side.
              const px = -(target.z - e.z) / dist;
              const pz = (target.x - e.x) / dist;
              const off = Math.min(3, dist * 0.45) * e.flankSide;
              tx += px * off;
              tz += pz * off;
            }
            this.moveEnemy(e, tx, tz, dt);
          }
          break;
        }
        case 'caster': {
          if (dist <= def.attackRange - 0.5 && e.attackCd <= 0 && !silenced) {
            e.state = 'windup';
            e.stateT = 0;
            e.aimX = target.x;
            e.aimZ = target.z;
            e.facing = Math.atan2(target.x - e.x, target.z - e.z);
            if (def.attack === 'hex') {
              // Bog Hag: the ring is laid on the thickest knot of thralls in reach (your legion is the point of her curse).
              const [hx, hz] = this.hexAim(e, target);
              e.aimX = hx;
              e.aimZ = hz;
              e.facing = Math.atan2(hx - e.x, hz - e.z);
              this.emit({ t: 'telegraph', id: e.id, kind: 'hex', x: e.x, z: e.z, tx: hx, tz: hz, ms: wms, r: HAG_HEX.radius });
            } else if (def.attack === 'pulse') {
              this.emit({ t: 'telegraph', id: e.id, kind: 'pulse', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms, r: WISP_PULSE.radius });
            } else if (def.attack === 'scream') {
              this.emit({ t: 'telegraph', id: e.id, kind: 'scream', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms, r: SCREAM.radius });
            } else if (def.attack === 'dust') {
              this.emit({ t: 'telegraph', id: e.id, kind: 'dust', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms, r: DUST.radius });
            } else if (def.attack === 'flask') {
              this.emit({ t: 'telegraph', id: e.id, kind: 'flask', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms, r: PLAGUE_FLASK.radius });
            } else if (def.attack === 'ember') {
              this.emit({ t: 'telegraph', id: e.id, kind: 'ember', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms, r: EMBER_BOLT.radius });
            } else if (def.attack === 'curse') {
              this.emit({ t: 'telegraph', id: e.id, kind: 'curse', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms });
            } else this.emit({ t: 'telegraph', id: e.id, kind: 'cone', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms });
          } else if (dist > def.attackRange - 1.5) this.moveEnemy(e, target.x, target.z, dt);
          else if (dist < 3.5) {
            let rx = e.x * 2 - target.x;
            let rz = e.z * 2 - target.z;
            if (def.lure) {
              // Fen Wisp: it backs away, but bends its retreat toward the open water (where you would wade after it).
              const ax = (e.x - target.x) / (dist || 1);
              const az = (e.z - target.z) / (dist || 1);
              const lx = FEN_LURE.x - e.x;
              const lz = FEN_LURE.z - e.z;
              const ll = Math.hypot(lx, lz) || 1;
              rx = e.x + (ax * 0.55 + (lx / ll) * 0.45) * 3;
              rz = e.z + (az * 0.55 + (lz / ll) * 0.45) * 3;
            }
            this.moveEnemy(e, rx, rz, dt, 0.8);
          } else e.facing = Math.atan2(target.x - e.x, target.z - e.z);
          break;
        }
        case 'support': {
          if (e.attackCd <= 0 && !silenced) {
            const corpse = def.ward ? null : this.nearestCorpse(e.x, e.z, 8);
            if (corpse) {
              e.state = 'channel';
              e.stateT = 0;
              e.channelCorpse = corpse.id;
              e.aimX = corpse.x;
              e.aimZ = corpse.z;
              this.emit({ t: 'telegraph', id: e.id, kind: 'raise', x: e.x, z: e.z, tx: corpse.x, tz: corpse.z, ms: 1500 * (e.elite ? 0.85 : 1) });
              break;
            }
            if (dist <= def.attackRange) {
              e.state = 'windup';
              e.stateT = 0;
              e.aimX = target.x;
              e.aimZ = target.z;
              this.emit({ t: 'telegraph', id: e.id, kind: 'curse', x: e.x, z: e.z, tx: target.x, tz: target.z, ms: wms });
              break;
            }
          }
          if (dist > def.attackRange - 0.5) this.moveEnemy(e, target.x, target.z, dt);
          else if (dist < 4) this.moveEnemy(e, e.x * 2 - target.x, e.z * 2 - target.z, dt, 0.7);
          break;
        }
      }
    }
  }

  private nearestCorpse(x: number, z: number, r: number) {
    let best: Corpse | null = null;
    let bestD = r;
    for (const c of this.corpses.values()) {
      const d = Math.hypot(c.x - x, c.z - z);
      if (d < bestD) {
        bestD = d;
        best = c;
      }
    }
    return best;
  }

  private release(e: Enemy) {
    const def = ENEMIES[e.def];
    e.attackCd = (def.cooldownMs / 1000) * (e.elite ? 0.8 : 1);
    e.state = 'recover';
    e.stateT = 0;
    if (e.channelCorpse !== null) {
      const c = this.corpses.get(e.channelCorpse);
      e.channelCorpse = null;
      if (c) {
        this.removeCorpse(c, 'raised');
        this.spawnEnemy('risen', e.area, c.x, c.z, false);
      }
      return;
    }
    if (e.erupting != null) {
      // Barrow Ghoul surfaces in the middle of its ring and hits everything inside it once.
      e.erupting = null;
      [e.x, e.z] = this.nav.resolveInArea(e.area, e.aimX, e.aimZ, e.radius);
      const dmg = this.blow(e) * (e.area === 'graves' ? BURROW.eruptMultGraves : BURROW.eruptMult);
      for (const p of this.players.values()) {
        if (p.alive && Math.hypot(p.x - e.aimX, p.z - e.aimZ) <= BURROW.eruptR) this.emit({ t: 'hurt', player: p.id, dmg, from: 'erupt', x: e.x, z: e.z });
      }
      for (const t of [...this.thralls.values()]) if (Math.hypot(t.x - e.aimX, t.z - e.aimZ) <= BURROW.eruptR) this.hurtThrall(t, dmg);
      this.emit({ t: 'erupt', id: e.id, x: e.aimX, z: e.aimZ, r: BURROW.eruptR });
      return;
    }
    if (e.hooking) {
      e.hooking = false;
      return this.strike(e, 'hook');
    }
    if (e.diving && def.dive) {
      this.endDive(e);
      e.groundT = def.dive.groundedS;
      return this.strike(e, 'slam', def.dive.radius);
    }
    switch (def.behavior) {
      case 'caster':
        return this.strike(e, def.attack ?? 'cone');
      case 'support':
        return this.strike(e, 'curse');
      case 'hazard':
        this.strike(e, 'slam');
        // Slag Brute: the ring it cracked keeps burning.
        if (def.slamPool) this.emberPool(e.aimX, e.aimZ, def.slamRadius ?? 1.9, SLAG_POOL.poolS, this.blow(e) * SLAG_POOL.poolDpsMult);
        return;
      default:
        this.strike(e, 'melee');
        if (def.hitRun) e.fleeT = def.hitRun;
    }
  }

  /** Flagellant: frenzied below half health. */
  private frenzied(e: Enemy) {
    return !!ENEMIES[e.def].frenzy && e.hp < e.maxHp * FRENZY.atFrac;
  }

  /** A dive ends (landed or stunned out of the air): settle onto walkable ground. */
  private endDive(e: Enemy) {
    e.diving = false;
    [e.x, e.z] = this.nav.resolveInArea(e.area, e.x, e.z, e.radius);
  }

  /** Weeping Seraph: Sanctify every ally in reach at once, if at least one other body is there to bless. */
  private seraphWard(e: Enemy) {
    const allies: Enemy[] = [];
    for (const o of this.enemies.values()) {
      if (o === e || o.state === 'dead' || (o.state === 'rising' || o.state === 'burrow') || (o.sanctT ?? 0) > 0) continue;
      if (Math.hypot(o.x - e.x, o.z - e.z) <= WARD.range) allies.push(o);
    }
    if (!allies.length) return;
    allies.sort((a, b) => a.hp / a.maxHp - b.hp / b.maxHp);
    for (const o of allies.slice(0, WARD.maxTargets)) {
      o.sanctT = SANCTIFIED.durationS;
      this.emit({ t: 'sanctify', id: e.id, target: o.id, x: e.x, z: e.z, tx: o.x, tz: o.z });
    }
    e.attackCd = ENEMIES[e.def].cooldownMs / 1000;
  }

  // --- Thrall AI ---

  private updateThralls(dt: number) {
    for (const t of [...this.thralls.values()]) {
      if (t.echoUntil !== undefined && this.time >= t.echoUntil) { this.killThrall(t, 'crumbled'); continue; }
      t.moving = false;
      t.flash = Math.max(0, t.flash - dt * 5);
      t.stateT += dt;
      const rallied = (t.rallyT ?? 0) > 0;
      if (rallied) t.rallyT = Math.max(0, (t.rallyT ?? 0) - dt);
      if ((t.cursedT ?? 0) > 0) t.cursedT = Math.max(0, t.cursedT! - dt);
      // Rallied thralls swing faster (the cooldown drains quicker) and hit harder (below).
      t.attackCd -= dt * (rallied ? RALLY.attackSpeedMult : 1);
      const owner = this.players.get(t.owner);
      if (!owner || !owner.alive) {
        this.killThrall(t, 'crumbled');
        continue;
      }
      if (t.state === 'rising') {
        if (t.stateT >= THRALL_RISE_TIME) {
          t.state = 'idle';
          t.stateT = 0;
        }
        continue;
      }
      const ownerDist = Math.hypot(owner.x - t.x, owner.z - t.z);
      if (ownerDist > THRALL_TELEPORT) {
        t.x = owner.x + (this.rand() - 0.5) * 2;
        t.z = owner.z + (this.rand() - 0.5) * 2;
        t.target = null;
      }

      let target = t.target !== null ? this.enemies.get(t.target) : undefined;
      const bossTarget = this.boss.state.active && this.boss.state.state !== 'sunk' && Math.hypot(this.boss.state.x - owner.x, this.boss.state.z - owner.z) < 16;
      // A target that went underground (a digging ghoul), or stands in another hall, is not one to keep swinging at.
      if (!target || target.state === 'dead' || target.state === 'burrow' || (target.erupting != null && target.state === 'windup') || (owner.area !== null && target.area !== owner.area)
        || Math.hypot(target.x - owner.x, target.z - owner.z) > THRALL_LEASH) {
        target = undefined;
        t.target = null;
        let bestD = 10;
        for (const e of this.enemies.values()) {
          if (e.state === 'dead' || (e.state === 'rising' || e.state === 'burrow') || (e.erupting != null && e.state === 'windup') || (owner.area !== null && e.area !== owner.area)) continue;
          if (Math.hypot(e.x - owner.x, e.z - owner.z) > THRALL_LEASH - 2) continue;
          const d = Math.hypot(e.x - t.x, e.z - t.z);
          if (d < bestD) {
            bestD = d;
            target = e;
          }
        }
        if (target) t.target = target.id;
      }

      const engage = (tx: number, tz: number, radius: number, hit: () => void) => {
        const d = Math.hypot(tx - t.x, tz - t.z);
        if (d > t.range + radius || (this.nav.depthsFloor !== null && this.wallBetween(t.x, t.z, tx, tz))) {
          this.moveThrall(t, tx, tz, dt, 1);
          t.state = 'move';
        } else {
          t.facing = Math.atan2(tx - t.x, tz - t.z);
          if (t.attackCd <= 0) {
            t.attackCd = t.attackInterval;
            t.state = 'attack';
            t.stateT = 0;
            hit();
          } else if (t.state !== 'attack' || t.stateT > 0.5) t.state = 'idle';
        }
      };

      if (target) {
        const e = target;
        engage(e.x, e.z, e.radius, () => {
          const dealt = this.damageEnemy(e, t.damage * ((t.rallyT ?? 0) > 0 ? RALLY.damageMult : 1) * this.cursedMult(t) * this.rallyMult(t, e), t.owner, t);
          if (t.kind === 'wraith') {
            e.chillT = CHILL.durationS;
            this.bellHeal(t);
          }
          else if (t.kind === 'bonemage') e.hexT = BONE_HEX.durationS;
          // Bone Colossus: every blow also cleaves what stands around its target.
          else if (t.kind === 'colossus') this.colossusCleave(t, e);
          this.emit({ t: 'thrallHit', id: t.id, target: e.id, x: t.x, z: t.z, tx: e.x, tz: e.z, kind: t.kind, dmg: Math.round(dealt) });
        });
      } else if (bossTarget) {
        const b = this.boss.state;
        engage(b.x, b.z, BOSS_RADIUS, () => {
          const raw = t.damage * ((t.rallyT ?? 0) > 0 ? RALLY.damageMult : 1) * this.cursedMult(t) * this.rallyMult(t, null);
          // The number is what the blow is worth against a Fractured boss, rally and all (it used to show the thrall's bare hit).
          const worth = raw * (1 + FRACTURE.perStack * b.fracture);
          this.boss.damage(raw, t.owner, 0);
          this.emit({ t: 'thrallHit', id: t.id, target: -1, x: t.x, z: t.z, tx: b.x, tz: b.z, kind: t.kind, dmg: Math.round(worth) });
        });
      } else {
        // Formation ring around the owner.
        // Seats are dealt by rank among the living (slot numbers have gaps once thralls fall, and a gap folded two onto one spot).
        const mine = this.ownedThralls(t.owner).sort((a, b) => a.slot - b.slot);
        const count = Math.max(3, mine.length);
        const ang = (Math.max(0, mine.indexOf(t)) / count) * Math.PI * 2 + Math.PI;
        const fx = owner.x + Math.sin(ang) * 1.9;
        const fz = owner.z + Math.cos(ang) * 1.9;
        const d = Math.hypot(fx - t.x, fz - t.z);
        if (d > 0.5) {
          this.moveThrall(t, fx, fz, dt, d > 6 ? 1.35 : 1);
          t.state = 'move';
        } else if (t.state === 'move') t.state = 'idle';
      }
    }
  }

  private colossusCleave(t: Thrall, main: Enemy) {
    const C = RUNE_TUNING.colossus;
    const dmg = t.damage * ((t.rallyT ?? 0) > 0 ? RALLY.damageMult : 1) * this.cursedMult(t) * C.cleaveFrac;
    for (const o of this.enemies.values()) {
      if (o === main || o.state === 'dead' || o.state === 'burrow' || Math.hypot(o.x - main.x, o.z - main.z) > C.cleaveRadius + o.radius) continue;
      this.damageEnemy(o, dmg, t.owner, t);
    }
  }

  /** Mourning Bell: a wraith's hit mends every living ally near it (each client scales the heal to its own max health). */
  private bellHeal(t: Thrall) {
    if (!t.allyHeal) return;
    const r = NECRO_WEAPON_TUNING.mourning_bell.allyHealRange;
    for (const p of this.players.values()) {
      if (p.alive && Math.hypot(p.x - t.x, p.z - t.z) <= r) this.emit({ t: 'heal', player: p.id, amount: 0, x: p.x, z: p.z, frac: t.allyHeal });
    }
  }

  private moveThrall(t: Thrall, tx: number, tz: number, dt: number, mult: number) {
    const hop = this.nav.depthsHop(t.x, t.z, tx, tz);
    if (hop) {
      tx = hop.x;
      tz = hop.z;
    }
    // A way round a prop it was wedged on (found below), followed for a few seconds.
    const way = t.detour;
    if (way?.length && this.time < (t.detourUntil ?? 0)) {
      while (way.length && Math.hypot(way[0].x - t.x, way[0].z - t.z) < 0.5) way.shift();
      if (way.length) {
        tx = way[0].x;
        tz = way[0].z;
      }
    } else if (way) t.detour = undefined;
    const dx = tx - t.x;
    const dz = tz - t.z;
    const d = Math.hypot(dx, dz);
    if (d < 0.05) return;
    const step = Math.min(d, t.speed * mult * dt);
    const px = t.x;
    const pz = t.z;
    [t.x, t.z] = this.nav.resolve(t.x + (dx / d) * step, t.z + (dz / d) * step, 0.4);
    const gained = ((t.x - px) * dx + (t.z - pz) * dz) / d;
    // Lined up on a prop or a pillar the push-out sends a body straight back: swing a little to either side to get round it (Depths floors and the open grounds alike).
    if (step > 1e-3 && gained < step * 0.3) {
      [t.x, t.z] = this.sidestep(px, pz, dx / d, dz / d, step, 0.4, (x, z) => this.nav.resolve(x, z, 0.4));
      // Wedged between two props a body cannot squeeze through: ask the grid for a way round (rarely, and only after it has really stalled).
      t.stallT = (t.stallT ?? 0) + dt;
      if (t.stallT > 0.5 && this.time >= (t.nextPathAt ?? 0) && !this.nav.depthsFloor) {
        t.nextPathAt = this.time + 1.5;
        t.stallT = 0;
        const path = this.nav.findPath(t.x, t.z, tx, tz, 0.4);
        if (path.length > 1) {
          t.detour = path.slice(0, -1);
          t.detourUntil = this.time + 3;
        }
      }
    } else if (t.stallT) t.stallT = 0;
    t.facing = Math.atan2(dx, dz);
    t.moving = true;
    t.gait += step * 2.4;
  }

  /** Soft body separation: enemies ↔ enemies/thralls/players, thralls ↔ thralls. */
  private separate() {
    const bodies: { x: number; z: number; r: number; w: number; e?: Enemy; t?: Thrall }[] = [];
    for (const e of this.enemies.values()) if ((e.state !== 'rising' && e.state !== 'burrow')) bodies.push({ x: e.x, z: e.z, r: e.radius, w: ENEMIES[e.def].inert ? 0 : 1, e });
    for (const t of this.thralls.values()) bodies.push({ x: t.x, z: t.z, r: 0.4, w: 0.6, t });
    for (const p of this.players.values()) if (p.alive) bodies.push({ x: p.x, z: p.z, r: PLAYER_RADIUS, w: 0 });
    for (let i = 0; i < bodies.length; i++) {
      const a = bodies[i];
      for (let j = i + 1; j < bodies.length; j++) {
        const b = bodies[j];
        const dx = b.x - a.x;
        const dz = b.z - a.z;
        const min = a.r + b.r;
        if (Math.abs(dx) > min || Math.abs(dz) > min) continue;
        const d = Math.hypot(dx, dz);
        if (d >= min || d < 1e-4) continue;
        const push = (min - d) * 0.5;
        const nx = dx / d;
        const nz = dz / d;
        const total = a.w + b.w || 1;
        const pa = (a.w / total) * push * 2;
        const pb = (b.w / total) * push * 2;
        a.x -= nx * pa;
        a.z -= nz * pa;
        b.x += nx * pb;
        b.z += nz * pb;
      }
    }
    for (const b of bodies) {
      if (b.e) [b.e.x, b.e.z] = this.nav.resolveInArea(b.e.area, b.x, b.z, b.e.radius);
      else if (b.t) [b.t.x, b.t.z] = this.nav.resolve(b.x, b.z, 0.4);
    }
  }

  /** Treat an area as already visited (host migration: no opening wave). */
  markVisited(area: AreaId) {
    if (!this.waveTimers.has(area)) this.waveTimers.set(area, (AREAS[area].waveIntervalMs / 1000) * waveModifiers(this.waveTier).intervalMult);
  }

  /** Development helper: clear an area and reset its wave timer. */
  clearArea(area: AreaId) {
    for (const e of [...this.enemies.values()]) if (e.area === area) this.enemies.delete(e.id);
    this.waveTimers.delete(area);
    if (this.surge?.area === area) this.surge = null;
  }

  arenaCenter() {
    return BOSSES[this.bossId].arena;
  }
}
