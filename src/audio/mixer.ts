/**
 * Pure mixing rules for the audio engine: which bus a sound belongs to, how
 * important it is, how loud it should be given distance / repetition, and how
 * many voices a bus may hold. No WebAudio in here, so it is unit-tested.
 */
import type { Sfx } from './Audio';

export type BusId = 'combat' | 'enemies' | 'thralls' | 'ui' | 'ambience';
export const BUS_IDS: readonly BusId[] = ['combat', 'enemies', 'thralls', 'ui', 'ambience'];

/** Concurrent sounds (not nodes) each bus may hold at its highest priority. */
export const BUS_CAP: Record<BusId, number> = { combat: 14, enemies: 9, thralls: 5, ui: 8, ambience: 10 };
/** Fixed trim per bus, applied under the user's slider. */
export const BUS_TRIM: Record<BusId, number> = { combat: 1, enemies: 0.8, thralls: 0.5, ui: 0.9, ambience: 1 };
/** Extra headroom (voices) for the highest-priority sounds. */
export const PRIORITY_RESERVE = 3;
export const GLOBAL_CAP = 34;

export type Priority = number; // 0 (background) .. 10 (player hurt)

export interface Duck {
  /** Fraction removed from thralls + enemies (0.4 = -40%). */
  depth: number;
  hold: number; // seconds at full depth
  release: number; // seconds time constant back to 1
}

export interface Profile {
  bus: BusId;
  priority: Priority;
  /** Approximate audible length, for voice accounting. */
  dur: number;
  /** At most `max` of this sound per `window` seconds (thrall thinning). */
  thin?: { window: number; max: number };
  /** Ducks thralls and enemies while this plays. */
  duck?: Duck;
}

const P = (bus: BusId, priority: Priority, dur: number, extra: Partial<Profile> = {}): Profile => ({ bus, priority, dur, ...extra });
const PLAYER = 9;
const BOSS = 8;

export const PROFILES: Record<Sfx, Profile> = {
  // The necromancer's own casts: always heard.
  needleCast: P('combat', PLAYER, 0.3),
  needleHit: P('combat', 6, 0.3),
  spear: P('combat', PLAYER, 0.9),
  exhume: P('combat', PLAYER, 1.2),
  thrallRise: P('combat', 7, 0.7),
  miasma: P('combat', PLAYER, 1.2),
  litany: P('combat', PLAYER, 3),
  wail: P('combat', PLAYER, 1.1),
  bloodStep: P('combat', PLAYER, 0.9),
  frost: P('combat', PLAYER, 0.7),
  mantle: P('combat', PLAYER, 0.9),
  flail: P('combat', PLAYER, 0.3),
  lantern: P('combat', PLAYER, 0.6),
  chain: P('combat', PLAYER, 0.4),
  pyre: P('combat', PLAYER, 0.9),
  ward: P('combat', PLAYER, 0.9),
  palm: P('combat', PLAYER, 0.6),
  choir: P('combat', PLAYER, 1.3),
  crow: P('combat', PLAYER, 0.4),
  bloodRite: P('combat', PLAYER, 0.7),
  veilRite: P('combat', PLAYER, 0.9),
  spiritBolt: P('combat', PLAYER, 0.4),
  burst: P('combat', 7, 1.1),
  raise: P('combat', 6, 1.3),
  curse: P('combat', 5, 0.5),
  boneHit: P('combat', 5, 0.35),
  // Player state.
  hurt: P('combat', 10, 0.5, { duck: { depth: 0.4, hold: 0.3, release: 0.35 } }),
  playerDeath: P('combat', 10, 3.5, { duck: { depth: 0.6, hold: 1.5, release: 1.2 } }),
  // Bosses: tells and slams outrank everything but the player.
  bossToll: P('combat', BOSS, 4.5, { duck: { depth: 0.3, hold: 0.7, release: 0.7 } }),
  bossSlam: P('combat', BOSS, 1.5, { duck: { depth: 0.35, hold: 0.4, release: 0.6 } }),
  bossAwaken: P('combat', BOSS, 6, { duck: { depth: 0.4, hold: 2, release: 1.2 } }),
  bossDefeat: P('combat', BOSS, 7, { duck: { depth: 0.4, hold: 1.5, release: 1.2 } }),
  // Enemies.
  eliteDeath: P('enemies', 7, 1.4),
  enemyDeath: P('enemies', 5, 0.5),
  emberBurst: P('enemies', 5, 0.4),
  emberThrow: P('enemies', 4, 0.4),
  slagSlam: P('enemies', 6, 1),
  toll: P('enemies', 5, 2.4),
  tollSmall: P('enemies', 3, 1.2),
  // Thralls are deliberately quiet and thinned.
  thrallMelee: P('thralls', 3, 0.3, { thin: { window: 0.1, max: 3 } }),
  thrallShot: P('thralls', 3, 0.3, { thin: { window: 0.1, max: 3 } }),
  thrallMagic: P('thralls', 3, 0.5, { thin: { window: 0.1, max: 3 } }),
  // Interface.
  coin: P('ui', 3, 0.3),
  shard: P('ui', 3, 0.7),
  item: P('ui', 3, 0.9),
  levelUp: P('ui', 6, 1.8),
  skillUp: P('ui', 5, 1.5),
  click: P('ui', 2, 0.1),
  buy: P('ui', 3, 1.2),
  error: P('ui', 3, 0.2),
  chainTier: P('ui', 4, 1),
  chainBreak: P('ui', 4, 0.6),
  // Second pass: more rites (all the player's own casts).
  siphon: P('combat', PLAYER, 1.5),
  prison: P('combat', PLAYER, 1.1),
  hands: P('combat', PLAYER, 1.1),
  storm: P('combat', PLAYER, 1.7),
  soulRelease: P('combat', PLAYER, 1.4),
  sigWall: P('combat', PLAYER, 1),
  sigRend: P('combat', PLAYER, 0.9),
  sigDirge: P('combat', PLAYER, 2.2),
  sigBloom: P('combat', PLAYER, 1),
  // Interface additions.
  panelOpen: P('ui', 2, 0.2),
  panelClose: P('ui', 2, 0.2),
  equip: P('ui', 3, 0.35),
  lootRare: P('ui', 4, 0.7),
  lootEpic: P('ui', 5, 1.6),
  vaultOpen: P('ui', 3, 1.2),
  vaultClose: P('ui', 3, 1),
  // World / ambience.
  gate: P('ambience', 6, 2.5),
  wave: P('ambience', 5, 1.2),
  step: P('ambience', 1, 0.25),
  chop: P('ambience', 2, 0.2),
  pick: P('ambience', 2, 0.25),
  splash: P('ambience', 2, 0.4),
  shovel: P('ambience', 2, 0.3),
  reel: P('ambience', 2, 1),
  sawpit: P('ambience', 2, 1.4),
  kiln: P('ambience', 2, 1.9),
  cook: P('ambience', 2, 1.2),
  grind: P('ambience', 2, 1.4),
  craft: P('ambience', 3, 0.4),
  distantBell: P('ambience', 0, 2.7),
  bogBubble: P('ambience', 0, 0.9),
  crowCaw: P('ambience', 0, 0.4),
  windGust: P('ambience', 0, 3.6),
  crowdMoan: P('ambience', 0, 3.6),
  dustFall: P('ambience', 0, 0.6),
  graveCreak: P('ambience', 0, 0.8),
  waterDrip: P('ambience', 0, 0.3),
  emberCrackle: P('ambience', 0, 0.3),
};
export const DEFAULT_PROFILE: Profile = P('combat', 4, 0.6);
export function profileOf(name: Sfx): Profile {
  return PROFILES[name] ?? DEFAULT_PROFILE;
}

// --- bus gain math ----------------------------------------------------------

/** Slider (0..1) to linear gain. A gentle power curve feels more even than linear. */
export function sliderGain(v: number): number {
  const x = Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 1;
  return Math.pow(x, 1.5);
}

export interface VolumeSettings {
  volume: number;
  combatVolume: number;
  ambienceVolume: number;
  interfaceVolume: number;
}

/** Which user slider governs a bus. */
export function busSlider(bus: BusId, s: VolumeSettings): number {
  switch (bus) {
    case 'ui':
      return s.interfaceVolume;
    case 'ambience':
      return s.ambienceVolume;
    default:
      return s.combatVolume;
  }
}

/** Linear gain of one bus node (excluding master). */
export function busGain(bus: BusId, s: VolumeSettings): number {
  return sliderGain(busSlider(bus, s)) * BUS_TRIM[bus];
}

export function masterGain(s: VolumeSettings): number {
  return sliderGain(s.volume) * 0.9;
}

// --- distance ---------------------------------------------------------------

/** Distance (world units) beyond which crowd sounds are skipped outright. */
export const CULL_DISTANCE: Record<BusId, number> = { combat: 60, enemies: 34, thralls: 26, ui: Infinity, ambience: 60 };

/** Falloff relative to the listener. Crowd buses fall off faster than the player's own casts. */
export function distanceGain(distance: number, bus: BusId): number {
  const half = bus === 'thralls' ? 6 : bus === 'enemies' ? 7.5 : 9;
  return 1 / (1 + (distance / half) ** 2);
}

/** True when a positional sound is too far away to be worth scheduling. */
export function culled(distance: number, bus: BusId, priority: Priority): boolean {
  if (priority >= BOSS) return false;
  return distance > CULL_DISTANCE[bus] || distanceGain(distance, bus) < 0.02;
}

export function panFor(dx: number): number {
  return Math.max(-0.85, Math.min(0.85, dx / 14));
}

// --- repeat attenuation -----------------------------------------------------

export const REPEAT_WINDOW = 0.15;
const REPEAT_GAINS = [1, 0.78, 0.6, 0.46, 0.36, 0.28];
/** `n` = how many identical sounds already started inside REPEAT_WINDOW. */
export function repeatGain(n: number): number {
  return REPEAT_GAINS[Math.min(Math.max(0, n), REPEAT_GAINS.length - 1)];
}
/** Identical sounds beyond this many in the window are dropped (never for top-priority sounds). */
export const REPEAT_DROP = 6;
export function repeatDropped(n: number, priority: Priority): boolean {
  return priority < PLAYER && n >= REPEAT_DROP;
}

/** Sliding-window counter of recent events, keyed by string. */
export class WindowCounter {
  private hits = new Map<string, number[]>();
  count(key: string, now: number, window: number): number {
    const list = this.hits.get(key);
    if (!list) return 0;
    while (list.length && now - list[0] >= window) list.shift();
    return list.length;
  }
  add(key: string, now: number) {
    const list = this.hits.get(key);
    if (list) list.push(now);
    else this.hits.set(key, [now]);
  }
}

// --- voice caps and priority ------------------------------------------------

/** Voices a bus will accept for a sound of this priority (lower priority hits the ceiling first). */
export function effectiveCap(bus: BusId, priority: Priority): number {
  const base = BUS_CAP[bus];
  const frac = 0.55 + 0.45 * (Math.min(10, Math.max(0, priority)) / 10);
  const cap = Math.round(base * frac);
  return priority >= BOSS ? cap + PRIORITY_RESERVE : cap;
}

interface Voice {
  bus: BusId;
  priority: Priority;
  end: number;
}

export type AdmitResult = { ok: true } | { ok: false; reason: 'bus' | 'global' };

/** Tracks live sounds per bus and decides whether a new one is admitted. */
export class VoiceLimiter {
  private voices: Voice[] = [];
  dropped = 0;
  droppedByBus: Record<BusId, number> = { combat: 0, enemies: 0, thralls: 0, ui: 0, ambience: 0 };
  peak: Record<BusId, number> = { combat: 0, enemies: 0, thralls: 0, ui: 0, ambience: 0 };

  private prune(now: number) {
    if (this.voices.length) this.voices = this.voices.filter((v) => v.end > now);
  }

  active(bus: BusId, now: number): number {
    this.prune(now);
    return this.voices.reduce((n, v) => n + (v.bus === bus ? 1 : 0), 0);
  }

  total(now: number): number {
    this.prune(now);
    return this.voices.length;
  }

  /** Admit and register a sound, or refuse it. */
  request(bus: BusId, priority: Priority, now: number, dur: number): AdmitResult {
    this.prune(now);
    const inBus = this.voices.reduce((n, v) => n + (v.bus === bus ? 1 : 0), 0);
    let reason: 'bus' | 'global' | null = null;
    if (inBus >= effectiveCap(bus, priority)) reason = 'bus';
    else if (this.voices.length >= GLOBAL_CAP && priority < PLAYER) reason = 'global';
    if (reason) {
      this.dropped++;
      this.droppedByBus[bus]++;
      return { ok: false, reason };
    }
    this.voices.push({ bus, priority, end: now + dur });
    this.peak[bus] = Math.max(this.peak[bus], inBus + 1);
    return { ok: true };
  }
}

/** Pick a variant index, avoiding the previous pick when there is a choice. */
export function pickVariant(count: number, last: number, rnd: number): number {
  if (count <= 1) return 0;
  const i = Math.min(count - 2, Math.floor(rnd * (count - 1)));
  return i >= last && last >= 0 ? i + 1 : i;
}

// --- combat activity: ambience steps back while a fight is on ----------------

/** Weight one started sound adds to the combat-activity meter. */
export function activityWeight(bus: BusId, priority: Priority): number {
  if (bus === 'combat') return 0.06 + 0.012 * priority;
  if (bus === 'enemies') return 0.04;
  if (bus === 'thralls') return 0.015;
  return 0;
}

/** Leaky meter of recent combat sounds: 0 in a quiet zone, 1 in a heavy fight. */
export class CombatActivity {
  static readonly HALF_LIFE = 2.5;
  private value = 0;
  private at = 0;
  level(now: number): number {
    return this.value * Math.pow(0.5, Math.max(0, now - this.at) / CombatActivity.HALF_LIFE);
  }
  bump(now: number, weight: number) {
    this.value = Math.min(1.5, this.level(now) + weight);
    this.at = now;
  }
  reset() {
    this.value = 0;
    this.at = 0;
  }
}

/** Zone-bed gain multiplier at a given combat level (the boss drum is not ducked). */
export const BED_DUCK_DEPTH = 0.5;
export function bedDuckGain(level: number): number {
  return 1 - BED_DUCK_DEPTH * Math.min(1, Math.max(0, level));
}
/** Sparse ambient details wait until the fight has died down. */
export function accentsAllowed(level: number): boolean {
  return level < 0.2;
}

/** Highest rarity picked up this frame decides the loot sound; common and uncommon share the plain one. */
export function lootSfx(rarities: readonly string[]): Sfx {
  if (rarities.includes('epic') || rarities.includes('legendary')) return 'lootEpic';
  if (rarities.includes('rare')) return 'lootRare';
  return 'item';
}
