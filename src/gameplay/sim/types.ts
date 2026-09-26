import type { AreaId } from '../../content/areas';
import type { ThrallKind } from '../../content/disciplines';
import type { CorpseKind, EnemyId } from '../../content/enemies';

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

export type ZoneKind = 'miasma' | 'toxic' | 'bell';

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
  | { t: 'hit'; by: string; ids: number[]; dmg: number; fracture?: number; boss?: boolean }
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
  | { t: 'recallThralls'; by: string; x: number; z: number };

// --- Events: host → everyone (drive VFX, loot, XP, and damage to players) ---

export type SimEvent =
  | { t: 'spawn'; id: number; def: EnemyId; x: number; z: number; elite: boolean }
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
  | { t: 'corpseGone'; id: number; reason: 'consumed' | 'expired' | 'raised' | 'burst' | 'litany'; by?: string }
  | { t: 'thrall'; id: number; owner: string; kind: ThrallKind; x: number; z: number; empowered: boolean }
  | { t: 'thrallGone'; id: number; owner: string; x: number; z: number; reason: 'killed' | 'sacrificed' | 'crumbled' }
  | { t: 'telegraph'; id: number; kind: 'cone' | 'raise' | 'curse' | 'slam'; x: number; z: number; tx: number; tz: number; ms: number }
  | { t: 'melee'; id: number; x: number; z: number; tx: number; tz: number }
  | { t: 'hurt'; player: string; dmg: number; from: 'melee' | 'cone' | 'curse' | 'toxic' | 'boss'; x: number; z: number }
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
  | { t: 'wave'; area: AreaId; count: number; x: number; z: number }
  | { t: 'dmg'; x: number; z: number; amount: number; kind: 'dot' | 'thrall' | 'burst' | 'litany' | 'hit'; by: string }
  | { t: 'boss'; kind: 'awaken' | 'phase' | 'toll' | 'slam' | 'rain' | 'summon' | 'defeated'; x: number; z: number; phase: BossPhase; targets?: [number, number][]; ms?: number; r?: number; killer?: string };
