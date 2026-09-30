import type { AreaId } from '../../content/areas';
import type { ThrallKind } from '../../content/disciplines';
import type { CorpseKind, EliteAffix, EnemyId } from '../../content/enemies';
import type { BossId } from '../../content/bosses';

/**
 * Authoritative world-simulation types. The room host (or the solo player)
 * runs WorldSim; other clients mirror its snapshots. Player bodies are always
 * simulated by their own client and reported to the host.
 */

/** 'burrow' (Barrow Ghoul): underground, immune and untargetable. */
export type EnemyState = 'rising' | 'move' | 'windup' | 'recover' | 'channel' | 'dead' | 'burrow';

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
  /** Watchman's Ward slows movement by 25%, independently of Miasma. */
  wardSlowT?: number;
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
  /** Stunned by a Hollow Knight's Shield Bash: cannot act or move. */
  stunT?: number;
  /** Rooted by a Hollow Knight's Grave Brand: cannot move, can still swing. */
  rootT?: number;
  /** Incensed by a Censer Bearer's aura: faster feet and faster blows. */
  incenseT?: number;
  /** Release 0.3: Knell beats remaining, Witch curse and damage penalty. */
  knellBeats?: number;
  knellNext?: number;
  knellOwner?: string;
  knellDamage?: number;
  hexOwner?: string;
  /** Belfry Gargoyle: mid-dive (snapshot flag bit 19), where the dive started, and seconds grounded after landing. */
  diving?: boolean;
  diveX?: number;
  diveZ?: number;
  groundT?: number;
  /** Tithe Bat (host-only): seconds left flitting away after a bite. */
  fleeT?: number;
  /** Barrow Ghoul (host-only): winding up an eruption on this target; has dug back in once; metres left to tunnel. */
  erupting?: number | string | null;
  dugIn?: boolean;
  digPending?: boolean;
  burrowLeft?: number;
  /** Lich Acolyte (host-only): seconds until it may unbind again. Risen it raised carry `unboundBy`. */
  unbindCd?: number;
  unboundBy?: number;
  /** Bell Templar (host-only): throttles the shield-block tell. */
  blockFxAt?: number;
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
  /** Rally the Dead: seconds of +damage/+attack speed left (snapshot flag bit 2 of the empowered field). */
  rallyT?: number;
  /** Veilwalker Echo expires on the host after ten seconds. */
  echoUntil?: number;
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
  /** Carrion Seed: who planted it, burst damage/Withered cap, when it arms and withers (rides in snapshots). */
  seedOwner?: string;
  seedDmg?: number;
  seedCap?: number;
  seedArmedAt?: number;
  seedExpires?: number;
  /** Echo corpses may be spent only by their Veilwalker owner. */
  echoOwner?: string;
}

/** 'rot' = the friendly pool a detonated toxic corpse leaves behind. */
export type ZoneKind = 'miasma' | 'toxic' | 'bell' | 'rot' | 'dirge' | 'flower' | 'warden_fire' | 'warden_ward' | 'witch_crows' | 'witch_charm' | 'veil_rift' | 'dust';

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

/** A gathering node's live state (host-only; placements come from the shared layout). */
export interface SimNode {
  id: string;
  type: string;
  area: AreaId;
  x: number;
  z: number;
  rich: boolean;
  /** Successes left before it depletes. */
  remaining: number;
  /** Sim time it comes back (only meaningful while remaining is 0). */
  respawnAt: number;
}

export interface PlayerBody {
  id: string;
  x: number;
  z: number;
  alive: boolean;
  area: AreaId | null;
  family?: import('../../content/disciplines').ClassFamily;
  /** Character level (level-scaled areas match the highest player in them). */
  level?: number;
}

export type BossPhase = 1 | 2 | 3;

export interface BossState {
  /** Which boss this is (older snapshots have none → the Prelate). */
  id?: BossId;
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
      /** Rot Lance: Withered stacks to add (0..1, host-clamped) up to `witheredCap` (1..12). */
      withered?: number;
      witheredCap?: number;
      /** Bone Prison: root the targets (the host owns the duration). */
      root?: boolean;
      /** Grave Hands: slow the targets briefly (Miasma's slow; the host owns the duration). */
      slow?: boolean;
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
  /** `boss` (area bosses, 2026-09-28); missing = the Prelate, for older clients. */
  | { t: 'summonBoss'; by: string; boss?: BossId }
  | { t: 'recallThralls'; by: string; x: number; z: number }
  /** Host-shaped rites (discipline signatures + Bone Mantle): aim point, aim direction and the caster's spell power. */
  | {
      t: 'signature';
      by: string;
      sig: 'wall' | 'rend' | 'dirge' | 'bloom' | 'mantle' | 'offering' | 'rally' | 'seed' | 'bash' | 'vigil' | 'brand'
        | 'lantern_cone' | 'chain_pull' | 'burn_the_dead' | 'watchmans_ward' | 'cremate' | 'last_light'
        | 'toll' | 'resonant_step' | 'knell' | 'sound_the_corpse' | 'great_toll'
        | 'hook_throw' | 'harvest' | 'crow_swarm' | 'hook_pull' | 'hex_charm' | 'butcher' | 'murder_of_crows'
        | 'echo' | 'veil_tear' | 'crossing' | 'lay_to_rest';
      x: number;
      z: number;
      dx: number;
      dz: number;
      sp: number;
      /** Carrion Seed: Withered cap (1..12, host-clamped). */
      cap?: number;
      /** Rally the Dead: seconds (host-clamped to 6..8). */
      dur?: number;
    }
  /** Corpse Explosion: `dmg` is the caster's spellPower × power (clamped by the sim). */
  | { t: 'detonate'; by: string; corpseId: number; dmg: number }
  /** Gathering: `successes` work cycles landed on a node (depletion only; rewards come from the REST API). */
  | { t: 'gather'; by: string; nodeId: string; successes: number };

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
  | { t: 'telegraph'; id: number; kind: 'cone' | 'raise' | 'curse' | 'slam' | 'toll' | 'scream' | 'dust' | 'dive' | 'erupt' | 'flask'; x: number; z: number; tx: number; tz: number; ms: number; r?: number }
  | { t: 'melee'; id: number; x: number; z: number; tx: number; tz: number }
  | { t: 'hurt'; player: string; dmg: number; from: 'melee' | 'cone' | 'curse' | 'toxic' | 'boss' | 'toll' | 'scream' | 'dust' | 'erupt'; x: number; z: number; chillMs?: number }
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
  /** Grave Offering: the host consumed (ok) or found no corpse; the caster turns it into essence + health. */
  | { t: 'offering'; by: string; ok: boolean; x: number; z: number; corpseKind?: CorpseKind; elite?: boolean }
  /** Hollow Knight — Shield Bash: the body the charge caught (none if it hit air). */
  | { t: 'bash'; by: string; x: number; z: number; id: number | null }
  /** Hollow Knight — Corpse Vigil: the body spent keeping vigil. */
  | { t: 'vigil'; by: string; ok: boolean; x: number; z: number }
  /** Hollow Knight — Grave Brand: `sprung` false when armed, true when it roots. */
  | { t: 'brand'; by: string; ok: boolean; sprung: boolean; x: number; z: number }
  /** Host resolution for the four New Blood families. */
  | { t: 'newBlood'; by: string; kind: string; ok: boolean; x: number; z: number; amount?: number; targetId?: number; tx?: number; tz?: number; player?: string }
  /** Rally the Dead: these thralls are rallied, focused on the enemy nearest (x, z). */
  | { t: 'rally'; by: string; x: number; z: number; ids: number[] }
  /** Carrion Seed planted / withered away / burst. */
  | { t: 'seeded'; by: string; corpseId: number; x: number; z: number; armMs: number }
  | { t: 'seedGone'; corpseId: number }
  | { t: 'seedBurst'; by: string; x: number; z: number; r: number; targets: number }
  /** A friendly zone mending a player (Dirge). */
  | { t: 'heal'; player: string; amount: number; x: number; z: number }
  /** A Crypt Deacon blesses an ally (Sanctified). */
  | { t: 'sanctify'; id: number; target: number; x: number; z: number; tx: number; tz: number }
  /** Barrow Ghoul: surfaced in its ring, or started digging back in. */
  | { t: 'erupt'; id: number; x: number; z: number; r: number }
  | { t: 'digIn'; id: number; x: number; z: number }
  /** Lich Acolyte reaches for a dying thrall (its Risen climbs out UNBIND.delayS later). */
  | { t: 'unbind'; id: number; x: number; z: number; tx: number; tz: number }
  /** A summon the host refused because another boss is awake: the caller gets its shards back. */
  | { t: 'bossBusy'; by: string; boss: BossId; awake: BossId }
  /** Bell Templar's shield turned a blow. */
  | { t: 'shieldBlock'; id: number; x: number; z: number }
  /** A gathering node depleted (felled, mined out, the spot drifted, the grave dug) and when it returns. */
  | { t: 'nodeGone'; id: string; by: string; respawnS: number }
  | { t: 'nodeBack'; id: string }
  | { t: 'surge'; area: AreaId; x: number; z: number; durationMs: number; crypt?: boolean }
  | { t: 'surgeCleared'; area: AreaId; x: number; z: number }
  | { t: 'surgeFailed'; area: AreaId; x: number; z: number }
  /** `theme`: a procession (content/enemies WAVE_THEMES) rather than the usual mix. */
  | { t: 'wave'; area: AreaId; count: number; x: number; z: number; theme?: string }
  | { t: 'dmg'; x: number; z: number; amount: number; kind: 'dot' | 'thrall' | 'burst' | 'litany' | 'hit'; by: string }
  | {
      t: 'boss';
      kind: 'awaken' | 'phase' | 'toll' | 'slam' | 'rain' | 'summon' | 'defeated'
        // Area bosses: Gravedigger (sweep, bury, pits), Abbess (lance, chorus, grasp, communion, nicheBreak), Congregation (hymn, grasp, maul).
        | 'sweep' | 'bury' | 'pits' | 'lance' | 'chorus' | 'grasp' | 'communion' | 'nicheBreak' | 'hymn' | 'maul'
        // Plague Saint.
        | 'rotRain' | 'swing' | 'blessed' | 'link';
      x: number;
      z: number;
      phase: BossPhase;
      targets?: [number, number][];
      ms?: number;
      r?: number;
      killer?: string;
      boss?: BossId;
      /** Facing for cones, lines and spokes. */
      dir?: number;
      /** Players caught (Burial / Drowning Grasp root them for `root` seconds on their own client). */
      players?: string[];
      root?: number;
    };
