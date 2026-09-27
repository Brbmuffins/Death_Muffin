import type { AreaId } from '../../content/areas';
import type { ThrallKind } from '../../content/disciplines';
import type { CorpseKind, EliteAffix, EnemyId } from '../../content/enemies';

/**
 * Authoritative world-simulation types. The room host (or the solo player)
 * runs WorldSim; other clients mirror its snapshots. Player bodies are always
 * simulated by their own client and reported to the host.
 */

export type EnemyState = 'rising' | 'move' | 'windup' | 'recover' | 'channel' | 'dead';

export interface Enemy {
  id: number;
  def: EnemyId;
  area: AreaId;
  level: number;
  elite: boolean;
  x: number;
  z: number;
  facing: number;
  hp: number;
  maxHp: number;
  damage: number;
  speed: number;
  radius: number;
  scale: number;
  state: EnemyState;
  stateT: number;
  attackCd: number;
  targetPlayer: string | null;
  targetThrall: number | null;
  /** Where a windup/channel is aimed (cone direction, raise target, etc.). */
  aimX: number;
  aimZ: number;
  channelCorpse: number | null;
  flankSide: number;
  fracture: number;
  fractureT: number;
  withered: number;
  witheredT: number;
  witheredDps: number;
  witheredOwner: string;
  slowT: number;
  lastHitBy: string;
  /** Render-only: hit flash 0..1 and gait phase. */
  flash: number;
  gait: number;
  moving: boolean;
  /** Hemorrhage: bleed per second, seconds left, and who gets the kill. */
  bleedT?: number;
  bleedDps?: number;
  bleedOwner?: string;
  /** Chill (Mourner wraith hits) and Sanctified (Deacon blessing) seconds left. */
  chillT?: number;
  sanctT?: number;
  /** Bone Hex (bone-mage thralls): this enemy's blows land softer. */
  hexT?: number;
  /** Silenced by a Mourner's Dirge: casters can't start a spell. */
  silenceT?: number;
  /** Incensed by a Censer Bearer's aura: faster feet and faster blows. */
  incenseT?: number;
  /** Host-only: a Censer Bearer's next aura pulse. */
  auraCd?: number;
  /** Elites roll one affix on spawn (replicated in snapshots). */
  affix?: EliteAffix;
  /** Host-only affix clock: seconds until the next toll / feeding. */
  affixCd?: number;
  /** Host-only: a telegraphed Bell-Tolled ring waiting to sound. */
  tollAt?: { t: number; x: number; z: number };
}

export type ThrallState = 'rising' | 'idle' | 'move' | 'attack' | 'dead';

export interface Thrall {
  id: number;
  owner: string;
  kind: ThrallKind;
  x: number;
  z: number;
  facing: number;
  hp: number;
  maxHp: number;
  damage: number;
  attackInterval: number;
  range: number;
  speed: number;
  state: ThrallState;
  stateT: number;
  attackCd: number;
  target: number | null;
  slot: number;
  bornAt: number;
  empowered: boolean;
  flash: number;
  gait: number;
  moving: boolean;
}

export interface Corpse {
  id: number;
  x: number;
  z: number;
  kind: CorpseKind;
  enemy: EnemyId;
  elite: boolean;
  facing: number;
  scale: number;
  area: AreaId;
  bornAt: number;
  expiresAt: number;
  /** Toxic corpses rupture at this time unless consumed. */
  ruptureAt: number;
}

/** 'rot' = the friendly pool a detonated toxic corpse leaves behind. */
export type ZoneKind = 'miasma' | 'toxic' | 'bell' | 'rot' | 'dirge' | 'flower';

export type CorpseGoneReason = 'consumed' | 'expired' | 'raised' | 'burst' | 'litany' | 'devoured';

/** An active Grave Surge (host-only bookkeeping). */
export interface SurgeState {
  area: AreaId;
  x: number;
  z: number;
  startedAt: number;
  endsAt: number;
  wavesSpawned: number;
  ids: Set<number>;
  spawned: number;
  killed: number;
}

export interface Zone {
  id: number;
  kind: ZoneKind;
  owner: string;
  x: number;
  z: number;
  r: number;
  until: number;
  bornAt: number;
  tick: number;
  dps: number;
  slow: number;
  witheredCap: number;
  bloom: boolean;
  /** Hostile zones damage players and thralls; friendly ones damage enemies. */
  hostile: boolean;
  /** Plague Bloom: generation in the chain and seconds until it seeds the next corpse. */
  gen?: number;
  spreadT?: number;
}

export interface PlayerBody {
  id: string;
  x: number;
  z: number;
  alive: boolean;
  area: AreaId | null;
}

export type BossPhase = 1 | 2 | 3;

export interface BossState {
  active: boolean;
  x: number;
  z: number;
  facing: number;
  hp: number;
  maxHp: number;
  phase: BossPhase;
  state: 'idle' | 'move' | 'toll' | 'slam' | 'rain' | 'summon' | 'dead';
  stateT: number;
  flash: number;
  fracture: number;
  fractureT: number;
  withered: number;
  witheredT: number;
  witheredDps: number;
  level: number;
}

// --- Intents: client → host requests (the host validates and applies) ---

export type Intent =
  | {
      t: 'hit';
      by: string;
      ids: number[];
      dmg: number;
      fracture?: number;
      boss?: boolean;
      /** Hemorrhage bleed per second (clamped by the host). */
      bleed?: number;
      /** Grave Frost: Chill the targets (the host owns the duration). */
      chill?: boolean;
    }
  | {
      t: 'miasma';
      by: string;
      x: number;
      z: number;
      r: number;
      dps: number;
      durationMs: number;
      witheredCap: number;
      bloom: boolean;
    }
  | {
      t: 'exhume';
      by: string;
      x: number;
      z: number;
      r: number;
      kind: ThrallKind;
      cap: number;
      hp: number;
      damage: number;
      attackSpeedMult: number;
    }
  | {
      t: 'litany';
      by: string;
      x: number;
      z: number;
      r: number;
      spellPower: number;
      leaveCorpses: boolean;
    }
  | { t: 'summonBoss'; by: string }
  | { t: 'recallThralls'; by: string; x: number; z: number }
  /** Host-shaped rites (discipline signatures + Bone Mantle): aim point, aim direction and the caster's spell power. */
  | { t: 'signature'; by: string; sig: 'wall' | 'rend' | 'dirge' | 'bloom' | 'mantle'; x: number; z: number; dx: number; dz: number; sp: number }
  /** Corpse Explosion: `dmg` is the caster's spellPower × power (clamped by the sim). */
  | { t: 'detonate'; by: string; corpseId: number; dmg: number };

// --- Events: host → everyone (drive VFX, loot, XP, and damage to players) ---

export type SimEvent =
  | { t: 'spawn'; id: number; def: EnemyId; x: number; z: number; elite: boolean; affix?: EliteAffix }
  | {
      t: 'death';
      id: number;
      def: EnemyId;
      x: number;
      z: number;
      elite: boolean;
      area: AreaId;
      level: number;
      killer: string;
    }
  | { t: 'corpse'; corpse: Corpse }
  | { t: 'corpseGone'; id: number; reason: CorpseGoneReason; by?: string }
  | { t: 'thrall'; id: number; owner: string; kind: ThrallKind; x: number; z: number; empowered: boolean }
  | { t: 'thrallGone'; id: number; owner: string; x: number; z: number; reason: 'killed' | 'sacrificed' | 'crumbled' }
  | { t: 'telegraph'; id: number; kind: 'cone' | 'raise' | 'curse' | 'slam' | 'toll' | 'scream'; x: number; z: number; tx: number; tz: number; ms: number; r?: number }
  | { t: 'melee'; id: number; x: number; z: number; tx: number; tz: number }
  | { t: 'hurt'; player: string; dmg: number; from: 'melee' | 'cone' | 'curse' | 'toxic' | 'boss' | 'toll' | 'scream'; x: number; z: number }
  | { t: 'thrallHit'; id: number; target: number; x: number; z: number; tx: number; tz: number; kind: ThrallKind; dmg: number }
  | { t: 'zone'; zone: Zone }
  | { t: 'zoneGone'; id: number }
  | { t: 'burst'; kind: 'toxic' | 'bloom'; x: number; z: number; r: number }
  | { t: 'exhumed'; by: string; ok: boolean; corpseKind?: CorpseKind; x: number; z: number; crumbled?: number }
  | {
      t: 'litanyResult';
      by: string;
      x: number;
      z: number;
      r: number;
      corpses: number;
      resonant: number;
      thralls: number;
      targets: number;
      tethers: [number, number][];
    }
  | {
      t: 'detonated';
      by: string;
      ok: boolean;
      corpseId: number;
      x: number;
      z: number;
      r: number;
      corpseKind?: CorpseKind;
      elite?: boolean;
      targets?: number;
      dmg?: number;
    }
  /** Elite affix moments: a Bell-Tolled ring sounding, a Hungering feed, a Vengeful burst. */
  | { t: 'affix'; id: number; affix: EliteAffix; x: number; z: number; r?: number; tx?: number; tz?: number; amount?: number }
  /** Ossuary Wall raised / crumbled. */
  | { t: 'wall'; id: number; owner: string; x0: number; z0: number; x1: number; z1: number; ms: number }
  | { t: 'wallGone'; id: number }
  /** Command: Rend — each leap [fromX, fromZ, toX, toZ]; `hits` enemies cleaved. */
  | { t: 'rend'; by: string; x: number; z: number; leaps: [number, number, number, number][]; hits: number }
  /** Bone Mantle: corpses drawn in around the caster (each [x, z] is where one lay). */
  | { t: 'mantle'; by: string; x: number; z: number; r: number; corpses: number; tethers: [number, number][] }
  /** A friendly zone mending a player (Dirge). */
  | { t: 'heal'; player: string; amount: number; x: number; z: number }
  /** A Crypt Deacon blesses an ally (Sanctified). */
  | { t: 'sanctify'; id: number; target: number; x: number; z: number; tx: number; tz: number }
  | { t: 'surge'; area: AreaId; x: number; z: number; durationMs: number; crypt?: boolean }
  | { t: 'surgeCleared'; area: AreaId; x: number; z: number }
  | { t: 'surgeFailed'; area: AreaId; x: number; z: number }
  /** `theme`: a procession (content/enemies WAVE_THEMES) rather than the usual mix. */
  | { t: 'wave'; area: AreaId; count: number; x: number; z: number; theme?: string }
  | { t: 'dmg'; x: number; z: number; amount: number; kind: 'dot' | 'thrall' | 'burst' | 'litany' | 'hit'; by: string }
  | { t: 'boss'; kind: 'awaken' | 'phase' | 'toll' | 'slam' | 'rain' | 'summon' | 'defeated'; x: number; z: number; phase: BossPhase; targets?: [number, number][]; ms?: number; r?: number; killer?: string };
