/**
 * Which body gesture each necromancer rite plays: (weapon kind | 'none', ability) -> clip.
 *
 * The four necromantic hero GLBs carry five combat clips beyond the old `cast` / `attack` / `dig`
 * (docs/ALCHEMY-AND-WORLDS-PLAN.md N2): slam (overhead two-hand), sweep (two-hand hook), flick (one-hand throw),
 * channel (arms raised, pushed out) and summon (crouch, then arms overhead). A weapon changes the gesture, so a
 * scythe Gravecaller swings and a wand Mourner flicks. Anything not listed here (other families, weapon kinds
 * without an entry, a model that lacks the clip) keeps today's `cast` / `attack` / `dig` call untouched.
 *
 * `releaseAt` is the 0..1 point in the (trimmed) clip where the cast leaves the hand, measured by
 * tools/measure-clips.mjs and written to each necro hero clips.json by tools/build-characters.mjs; a unit test keeps
 * the two in sync. `planGesture` turns it into a start offset + playback speed so that frame lands on the
 * frame the rite spawns (abilities spawn instantly: we adjust the clip to the ability, never the reverse).
 */
import type { AbilityId } from './abilities';
import type { WeaponKind } from './gear';

export type CombatClip = 'slam' | 'sweep' | 'flick' | 'channel' | 'summon';

/** Release point of each combat clip (fraction of its duration). Mirrors `release` in each necro hero clips.json. */
export const CLIP_RELEASE: Record<CombatClip, number> = {
  slam: 0.4,
  sweep: 0.286,
  flick: 0.619,
  channel: 0.687,
  summon: 0.5,
};

/** Shortest a gesture may play (seconds): heavy clips need to read even when the rite's own gesture is 0.3 s. */
const MIN_SECONDS: Record<CombatClip, number> = { slam: 0.55, sweep: 0.42, flick: 0.26, channel: 0.9, summon: 0.7 };

export type CastRole = 'primary' | 'bolt' | 'big' | 'channel' | 'summon';

/** What each necromancer rite is, for gesture purposes. */
export const ABILITY_ROLE: Partial<Record<AbilityId, CastRole>> = {
  bone_needle: 'primary',
  marrow_spear: 'bolt',
  rot_lance: 'bolt',
  wailing_skull: 'bolt',
  grave_frost: 'bolt',
  bone_fan: 'bolt',
  soul_siphon: 'bolt',
  ivory_cleave: 'bolt',
  grave_step: 'bolt',
  veil_step: 'bolt',
  miasma: 'bolt',
  corpse_explosion: 'big',
  bone_storm: 'big',
  command_rend: 'big',
  ossuary_wall: 'big',
  plague_bloom: 'big',
  bone_prison: 'big',
  black_litany: 'channel',
  dirge: 'channel',
  bone_mantle: 'channel',
  grave_offering: 'channel',
  exhume: 'summon',
  grave_hands: 'summon',
  rally_dead: 'summon',
  carrion_seed: 'summon',
};

export type GestureKey = WeaponKind | 'none';

/**
 * Role -> clip per weapon. `null` = keep today's gesture. No weapon means the necromancer's default skull staff
 * is in hand, so `none` plays like a staff.
 */
const STAFF_STYLE: Record<CastRole, CombatClip | null> = { primary: null, bolt: null, big: 'slam', channel: 'channel', summon: 'summon' };
const ONE_HAND: Record<CastRole, CombatClip | null> = { primary: 'flick', bolt: 'flick', big: null, channel: 'channel', summon: 'summon' };

export const WEAPON_CLIPS: Partial<Record<GestureKey, Record<CastRole, CombatClip | null>>> = {
  none: STAFF_STYLE,
  staff: STAFF_STYLE,
  scythe: { primary: 'sweep', bolt: null, big: 'slam', channel: 'channel', summon: 'summon' },
  wand: ONE_HAND,
  sickle: ONE_HAND,
};

export interface CastClipChoice {
  clip: CombatClip;
  releaseAt: number;
  minSeconds: number;
}

/** The combat clip for this weapon and rite, or null to keep today's cast/attack/dig. */
export function castClipFor(weapon: GestureKey, ability: AbilityId): CastClipChoice | null {
  const role = ABILITY_ROLE[ability];
  if (!role) return null;
  const clip = WEAPON_CLIPS[weapon]?.[role];
  return clip ? { clip, releaseAt: CLIP_RELEASE[clip], minSeconds: MIN_SECONDS[clip] } : null;
}

/** Seconds of lead between the gesture's first visible frame and the release (the spell spawns at t = 0). */
export const RELEASE_LEAD_S = 0.08;
const MAX_SPEED = 3.2;
const MIN_SPEED = 0.7;

/**
 * Playback plan: `startAt` (clip seconds) skips the part of the wind-up the rite has no time for and `speed`
 * squeezes the rest into `max(gestureSeconds, minSeconds)`, so the release frame lands RELEASE_LEAD_S after the
 * rite fires (exactly at 0 is unreadable: the pose must be seen a beat before the burst).
 */
export function planGesture(choice: CastClipChoice, gestureSeconds: number, clipDuration: number): { startAt: number; speed: number; releaseDelayS: number } {
  const total = Math.max(gestureSeconds, choice.minSeconds);
  const releaseT = choice.releaseAt * clipDuration;
  const tail = Math.max(0.05, total - RELEASE_LEAD_S);
  const speed = Math.min(MAX_SPEED, Math.max(MIN_SPEED, (clipDuration - releaseT) / tail));
  const startAt = Math.max(0, releaseT - RELEASE_LEAD_S * speed);
  // When the clip's own wind-up is shorter than the lead, the release comes later than the lead; report it.
  const releaseDelayS = (releaseT - startAt) / speed;
  return { startAt, speed, releaseDelayS };
}
