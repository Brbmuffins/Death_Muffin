import type { AreaId } from '../../content/areas';
import type { ThrallKind } from '../../content/disciplines';
import type { SimLegend } from '../legendary';
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
  /** Contagion rune (host-only): a Contagion circle withered this enemy, so its Withered stacks jump to neighbours when it dies. */
  contagious?: boolean;
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
  /** Drowned Sexton (host-only): winding up the grave-hook, and its cooldown. */
  hooking?: boolean;
  hookCd?: number;
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
  /** Host-only, legendary Marrow Spear rally: seconds left, the extra damage thralls deal to it, and whose legion it is. */
  markT?: number;
  markBonus?: number;
  markBy?: string;
  /** Host-only, Chain Plague: scene time before this enemy may burst again. */
  plagueAt?: number;
  /** The Catacomb Depths give elites more affixes than their first (host-only, solo). Each extra keeps its own clock. */
  extra?: { affix: EliteAffix; affixCd?: number; tollAt?: { t: number; x: number; z: number } }[];
}

/** A run of the Catacomb Depths (host-only: the Depths are solo for now). Floors are generated from `seed` and the depth. */
export interface DepthsRun {
  owner: string;
  seed: number;
  depth: number;
  /** Kills the floor asks for, and the ones landed so far. */
  need: number;
  kills: number;
  /** The stair down is open (the quota is met). */
  stairOpen: boolean;
  /** Seconds on this floor, and until the next wave climbs out. */
  floorT: number;
  waveT: number;
  waved: boolean;
  /** Balance harness / tests: re-roll the same depth instead of going down when a floor is cleared. */
  hold: boolean;
  /** The deepest floor reached, floors cleared and kills this run. */
  peak: number;
  floors: number;
  totalKills: number;
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
  /** Legion Champion (legendary set): 2x health and damage, a bigger model (snapshot flag bit 3 of the empowered field). */
  champion?: boolean;
  /** Veilwalker Echo expires on the host after ten seconds. */
  echoUntil?: number;
  /** Mourning Bell: the share of max health each of this wraith's hits heals allies for. */
  allyHeal?: number;
  /** A Bog Hag's hex: seconds left dealing less damage (snapshot flag bit 2 of the empowered field, value 4). */
  cursedT?: number;
  /** Host-only: how long it has pushed against a prop without getting anywhere, and the way round it found (see WorldSim.moveThrall). */
  stallT?: number;
  detour?: { x: number; z: number }[];
  detourUntil?: number;
  nextPathAt?: number;
  /** Host-only: where its formation seat was last tick, to know how fast the seat moves. */
  seatX?: number;
  seatZ?: number;
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
export type ZoneKind = 'miasma' | 'toxic' | 'bell' | 'rot' | 'dirge' | 'flower' | 'warden_fire' | 'warden_ward' | 'witch_crows' | 'witch_charm' | 'veil_rift' | 'dust' | 'ember';

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
  /** Creeping Rot rune: metres per second this Miasma circle drifts toward the nearest enemy (host-clamped). Its position rides every snapshot. */
  creep?: number;
  /** Contagion rune: enemies this circle withers pass their stacks on when they die. */
  contagion?: boolean;
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
  /** 'sunk': the Mire Mother under the water (untargetable, hidden). */
  state: 'idle' | 'move' | 'toll' | 'slam' | 'rain' | 'summon' | 'dead' | 'sunk';
  stateT: number;
  flash: number;
  fracture: number;
  fractureT: number;
  withered: number;
  witheredT: number;
  witheredDps: number;
  level: number;
  /** Called with a Covenant Seal (goldSinkRules EMPOWER): higher level and more health. Older snapshots have none. */
  empowered?: boolean;
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
      /** Impale rune: root for this many seconds instead (host-clamped to the rune's 1.5 s). */
      rootS?: number;
      /** Grave Hands: slow the targets briefly (Miasma's slow; the host owns the duration). */
      slow?: boolean;
      /** Marrow Spear: a legendary rally may mark the nearest target (the host checks the caster's mods). */
      spear?: boolean;
    }
  /** The caster's legendary-set mods the shared sim needs (host-clamped; resent on change and every few seconds). */
  | { t: 'legend'; by: string; mods: Partial<SimLegend> }
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
      /** Creeping Rot rune: drift speed in m/s (host-clamped). */
      creep?: number;
      /** Contagion rune. */
      contagion?: boolean;
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
      /** Mourning Bell: each wraith hit heals allies by this share of their max health (host-clamped, 0..0.03). */
      allyHeal?: number;
      /** Mass Grave rune: raise up to this many corpses at once (host-clamped to 3) at the rune's share of the thrall's stats. */
      count?: number;
      /** Bone Colossus rune: consume up to five corpses within the radius (at least three) and raise one giant thrall. */
      colossus?: boolean;
      /** Bonded Dead boon: raise one thrall from nothing at (x, z), but only if the owner has none standing. */
      bond?: boolean;
    }
  | {
      t: 'litany';
      by: string;
      x: number;
      z: number;
      r: number;
      spellPower: number;
      leaveCorpses: boolean;
      /** Hollow Choir rune: nothing is sacrificed; thralls in range only lend their voices. */
      spare?: boolean;
      /** Requiem rune: the burst lands this many ms later (host-clamped to 2000). */
      delayMs?: number;
    }
  /** `boss` (area bosses, 2026-09-28); missing = the Prelate, for older clients. */
  | { t: 'summonBoss'; by: string; boss?: BossId; empowered?: boolean }
  | { t: 'recallThralls'; by: string; x: number; z: number }
  /**
   * Buying a Damage tier or a Legion tier: a one-time bump for every thrall the owner has standing. The multipliers are new / old of the
   * owner's thrall health, damage and attack speed (host-clamped to 1..THRALL_REFRESH_MAX); health scales with its fraction kept, never a heal.
   */
  | { t: 'refreshThralls'; by: string; hpMult: number; damageMult: number; speedMult: number }
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
  // The Catacomb Depths: a floor began / its quota was met and the stair down opened (x, z = the stair).
  | { t: 'depthsFloor'; depth: number; need: number; chest: boolean }
  | { t: 'depthsClear'; depth: number; x: number; z: number }
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
  | { t: 'telegraph'; id: number; kind: 'cone' | 'raise' | 'curse' | 'slam' | 'toll' | 'scream' | 'dust' | 'dive' | 'erupt' | 'flask' | 'ember' | 'hex' | 'pulse' | 'hook'; x: number; z: number; tx: number; tz: number; ms: number; r?: number }
  | { t: 'melee'; id: number; x: number; z: number; tx: number; tz: number }
  | { t: 'hurt'; player: string; dmg: number; from: 'melee' | 'cone' | 'curse' | 'toxic' | 'boss' | 'toll' | 'scream' | 'dust' | 'erupt' | 'ember' | 'burn'; x: number; z: number; chillMs?: number;
      /** Drowned Sexton: drag the player `m` metres toward (x, z), rooted for `rootMs` (players are client-simulated, so the client moves them). */
      pull?: { x: number; z: number; m: number; rootMs: number } }
  | { t: 'thrallHit'; id: number; target: number; x: number; z: number; tx: number; tz: number; kind: ThrallKind; dmg: number }
  | { t: 'zone'; zone: Zone }
  | { t: 'zoneGone'; id: number }
  | { t: 'burst'; kind: 'toxic' | 'bloom' | 'ember'; x: number; z: number; r: number }
  | { t: 'exhumed'; by: string; ok: boolean; corpseKind?: CorpseKind; x: number; z: number; crumbled?: number; why?: 'few' }
  /** Contagion rune: Withered stacks jump from a dying enemy to a neighbour. */
  | { t: 'contagion'; x: number; z: number; tx: number; tz: number; stacks: number }
  /** Requiem rune: a Black Litany has been marked and bursts `ms` from now. */
  | { t: 'requiem'; by: string; x: number; z: number; r: number; ms: number }
  | {
      t: 'litanyResult';
      by: string;
      x: number;
      z: number;
      r: number;
      corpses: number;
      resonant: number;
      thralls: number;
      /** Hollow Choir rune: thralls that lent their voice and were spared. */
      spared?: number;
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
  | { t: 'heal'; player: string; amount: number; x: number; z: number; frac?: number }
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
  /** Legendary set moments, VFX only: a thrall's death burst, a spear rally mark, Contagion spreading, a Chain Plague burst. */
  | { t: 'legend'; kind: 'deathBurst' | 'rally' | 'spread' | 'plague'; by: string; x: number; z: number; r?: number; id?: number }
  | { t: 'dmg'; x: number; z: number; amount: number; kind: 'dot' | 'thrall' | 'burst' | 'litany' | 'hit'; by: string }
  | {
      t: 'boss';
      kind: 'awaken' | 'phase' | 'toll' | 'slam' | 'rain' | 'summon' | 'defeated'
        // Area bosses: Gravedigger (sweep, bury, pits), Abbess (lance, chorus, grasp, communion, nicheBreak), Congregation (hymn, grasp, maul).
        | 'sweep' | 'bury' | 'pits' | 'lance' | 'chorus' | 'grasp' | 'communion' | 'nicheBreak' | 'hymn' | 'maul'
        // Plague Saint.
        | 'rotRain' | 'swing' | 'blessed' | 'link'
        // Cinder Regent.
        | 'coals' | 'cleave' | 'conflagration'
        // Mire Mother: surface (ripple ring, then the burst), hands, rite (phase 3), flood (phase 2/3 change).
        | 'surface' | 'hands' | 'rite' | 'flood';
      x: number;
      z: number;
      phase: BossPhase;
      targets?: [number, number][];
      ms?: number;
      r?: number;
      killer?: string;
      boss?: BossId;
      /** On 'awaken' and 'defeated': this was an Empowered (Covenant Seal) fight. */
      empowered?: boolean;
      /** Facing for cones, lines and spokes. */
      dir?: number;
      /** Players caught (Burial / Drowning Grasp root them for `root` seconds on their own client). */
      players?: string[];
      root?: number;
    };
