import { settings } from '../app/settings';
import { fxImage } from './fxImages';
import { fx } from './fxTextures';
import type { Effects } from './Effects';

/**
 * Necromantic motifs layered over the rites: bone splinters, grave dirt and dust, soul-light motes, rot spores,
 * skull wisps, spectral hands, cracked ground. Small touches, never a flash: every call is
 *  - skipped on Graphics: Low and thinned (and without rising billboards or hands) under Settings -> Reduced motion,
 *  - drawn from a shared token budget so a full legion plus a rite rotation cannot flood the particle rings,
 *  - quieter when a thrall caused it (`origin: 'thrall'`), and
 *  - kept off the shared transient pool (decals/sprites, capped at 160 in Effects) when the pool is busy, so a boss
 *    ring or coal circle is never evicted by garnish.
 * Colours come from the caller (SPELL_FX), so every rite keeps its meaning hue.
 */
export type MotifOrigin = 'player' | 'thrall';

/** Bone / grave tones shared by the motifs (the spell hue is passed in; these are the matter). */
export const NECRO_MATTER = { bone: 0xe0d6c2, boneDeep: 0xb8ad94, dirt: 0x6e5841, dirtDeep: 0x3a2e22, dust: 0x9a8a72 } as const;

const PARTICLE_BURST = 240;
const PARTICLE_PER_S = 260;
const SPRITE_BURST = 14;
const SPRITE_PER_S = 9;
/** Above this many live decal/sprite transients the garnish stops asking for more. */
const TRANSIENT_CEILING = 100;
const THRALL_SCALE = 0.4;
const REDUCED_SCALE = 0.4;

/** What the motif layer actually drew (after the quality / reduced-motion / thrall / budget gates). QA reads it. */
export const motifStats = { particles: 0, billboards: 0, decals: 0, hands: 0, calls: 0, skipped: 0 };

let enabled = true;
/** DEV A/B switch (`__cwDebug.necroMotifs(false)`): the same build with the motif layer off, for before/after captures. */
export function setMotifsEnabled(on: boolean) {
  enabled = on;
}

let particleTokens = PARTICLE_BURST;
let spriteTokens = SPRITE_BURST;
let lastAt = 0;
let nowFn = () => (typeof performance !== 'undefined' ? performance.now() : Date.now());

/** Test hook: a deterministic clock and a refilled budget. */
export function resetMotifBudget(clock?: () => number) {
  if (clock) nowFn = clock;
  lastAt = nowFn();
  particleTokens = PARTICLE_BURST;
  spriteTokens = SPRITE_BURST;
}

function refill() {
  const t = nowFn();
  const dt = Math.max(0, Math.min(2, (t - lastAt) / 1000));
  lastAt = t;
  particleTokens = Math.min(PARTICLE_BURST, particleTokens + dt * PARTICLE_PER_S);
  spriteTokens = Math.min(SPRITE_BURST, spriteTokens + dt * SPRITE_PER_S);
}

/** 0 = off (Graphics: Low), otherwise the share of motif particles to draw. */
export function motifScale(origin: MotifOrigin = 'player'): number {
  if (!enabled || settings.quality === 'low') return 0;
  return (settings.reducedMotion ? REDUCED_SCALE : 1) * (origin === 'thrall' ? THRALL_SCALE : 1);
}

/** How many of `n` wanted particles may be drawn right now (0 when off or the budget is dry). */
function grant(n: number, origin: MotifOrigin): number {
  const s = motifScale(origin);
  if (s <= 0 || n <= 0) return 0;
  refill();
  const want = Math.max(origin === 'thrall' ? 0 : 1, Math.round(n * s));
  const got = Math.min(want, Math.floor(particleTokens));
  particleTokens -= got;
  motifStats.calls++;
  motifStats.particles += got;
  if (!got) motifStats.skipped++;
  return got;
}

function grantSprites(n: number, origin: MotifOrigin, e: Effects): number {
  // Billboards rise and drift: motion the reduced-motion setting asks us to drop. Thralls never raise them.
  if (motifScale(origin) <= 0 || settings.reducedMotion || origin === 'thrall' || n <= 0) return 0;
  if (e.transientLoad >= TRANSIENT_CEILING) return 0;
  refill();
  const got = Math.min(n, Math.floor(spriteTokens));
  spriteTokens -= got;
  motifStats.billboards += got;
  return got;
}

interface Base {
  origin?: MotifOrigin;
}

/** Ivory slivers that spit off a struck body and fall. */
export function boneSplinters(e: Effects, x: number, y: number, z: number, o: Base & { n?: number; speed?: number; color?: number } = {}) {
  const n = grant(o.n ?? 5, o.origin ?? 'player');
  if (!n) return;
  e.emit({ x, y, z, count: n, color: o.color ?? NECRO_MATTER.bone, spread: 0.08, speed: o.speed ?? 3.6, up: 1.9, life: 0.5, size: 0.075, gravity: 14, drag: 0.7 });
}

/** Grave dirt: dark clods thrown up (normal blending, so it reads as earth, not light) and a low dust puff. */
export function graveDirt(e: Effects, x: number, z: number, o: Base & { r?: number; n?: number; y?: number; up?: number } = {}) {
  const n = grant(o.n ?? 5, o.origin ?? 'player');
  if (!n) return;
  const r = o.r ?? 0.5;
  e.emitSmoke({ x, y: o.y ?? 0.15, z, count: n, color: NECRO_MATTER.dirt, spread: r, speed: 1.5, up: o.up ?? 2.4, life: 0.65, size: 0.3, gravity: 10, shrink: 0.6, drag: 0.8 });
  const puff = Math.ceil(n / 3);
  e.emitSmoke({ x, y: (o.y ?? 0.15) + 0.1, z, count: puff, color: NECRO_MATTER.dust, spread: r, speed: 0.7, up: 0.5, life: 0.9, size: 0.8, shrink: -0.5, drag: 1 });
}

/** Soul-light motes lifting off the ground. */
export function soulMotes(e: Effects, x: number, z: number, color: number, o: Base & { r?: number; n?: number; y?: number; up?: number } = {}) {
  const n = grant(o.n ?? 6, o.origin ?? 'player');
  if (!n) return;
  e.emit({ x, y: o.y ?? 0.25, z, count: n, color, spread: o.r ?? 0.5, speed: 0.22, up: o.up ?? 1.1, life: 1.5, size: 0.13, gravity: -0.35, drag: 0.6 });
}

/** Rot spores drifting up in a slow cloud (a darker smoke mote under them keeps them in the ground haze). */
export function rotSpores(e: Effects, x: number, z: number, color: number, o: Base & { r?: number; n?: number; y?: number } = {}) {
  const n = grant(o.n ?? 8, o.origin ?? 'player');
  if (!n) return;
  const r = o.r ?? 1;
  e.emit({ x, y: o.y ?? 0.3, z, count: n, color, spread: r, speed: 0.3, up: 0.45, life: 2.2, size: 0.1, gravity: -0.08, drag: 0.5 });
  if (n >= 4) e.emitSmoke({ x, y: (o.y ?? 0.3) + 0.2, z, count: Math.ceil(n / 4), color: 0x3d4a22, spread: r, speed: 0.2, up: 0.25, life: 2.2, size: 0.7, shrink: -0.6, drag: 0.5 });
}

/** A thin, low whisper of mist along the ground. */
export function mistWhisper(e: Effects, x: number, z: number, color: number, o: Base & { r?: number; n?: number } = {}) {
  const n = grant(o.n ?? 2, o.origin ?? 'player');
  if (!n) return;
  e.emitSmoke({ x, y: 0.35, z, count: n, color, spread: o.r ?? 1, speed: 0.25, up: 0.2, life: 1.7, size: 1.1, shrink: -0.7, drag: 0.7 });
}

/** Skull faces that bloom above a point and drift up, one billboard each (capped). */
export function skullWisps(e: Effects, x: number, z: number, color: number, o: Base & { n?: number; r?: number; y?: number; size?: number; rise?: number; duration?: number } = {}) {
  const n = grantSprites(o.n ?? 1, o.origin ?? 'player', e);
  for (let i = 0; i < n; i++) {
    const a = (i / Math.max(1, n)) * Math.PI * 2 + Math.random() * 0.4;
    const r = o.r ?? 0;
    e.flash({ x: x + Math.cos(a) * r, y: o.y ?? 0.7, z: z + Math.sin(a) * r, color, size: o.size ?? 0.6, duration: o.duration ?? 0.8, tex: fxImage('skull'), rise: o.rise ?? 0.8, opacity: 0.62 });
  }
}

/** A ring of skulls standing on a circle (Black Litany). */
export function skullRing(e: Effects, x: number, z: number, r: number, color: number, o: Base & { n?: number; size?: number } = {}) {
  skullWisps(e, x, z, color, { ...o, n: o.n ?? 8, r, y: 0.55, size: o.size ?? 0.7, rise: 0.9, duration: 0.9 });
}

/** Wisps (the pale spirit sprite) rising from a point. */
export function spiritWisps(e: Effects, x: number, z: number, color: number, o: Base & { n?: number; r?: number; y?: number; size?: number } = {}) {
  const n = grantSprites(o.n ?? 2, o.origin ?? 'player', e);
  for (let i = 0; i < n; i++) {
    const a = Math.random() * Math.PI * 2;
    const r = (o.r ?? 0.4) * Math.sqrt(Math.random());
    e.flash({ x: x + Math.cos(a) * r, y: o.y ?? 0.4, z: z + Math.sin(a) * r, color, size: o.size ?? 0.8, duration: 1.1, tex: fxImage('wisp'), rise: 1.3, opacity: 0.8 });
  }
}

/** Skeletal hands clawing out of the ground; at most a few fields live at once, none for thralls or when reduced. */
export function spectralHands(e: Effects, x: number, z: number, o: Base & { n?: number; r?: number; duration?: number } = {}) {
  if (motifScale(o.origin ?? 'player') <= 0 || settings.reducedMotion || (o.origin ?? 'player') === 'thrall') return;
  if (e.activeHandFields >= 3) return;
  motifStats.hands++;
  e.graveHands(x, z, o.r ?? 0.7, o.n ?? 3, o.duration ?? 1.1);
}

/** Cracked ground under a point: a faded sigil that lingers (decal, so only when the pool has room). */
export function crackedGround(e: Effects, x: number, z: number, r: number, color: number, o: Base & { duration?: number; opacity?: number; sx?: number; rot?: number } = {}) {
  if (motifScale(o.origin ?? 'player') <= 0 || e.transientLoad >= TRANSIENT_CEILING) return;
  motifStats.decals++;
  e.decal({ tex: fx.cracks(), color, x, z, r, rot: o.rot ?? Math.random() * 6, duration: o.duration ?? 1.4, opacity: (o.opacity ?? 0.5) * (o.origin === 'thrall' ? 0.6 : 1), growFrom: 0.5, sx: o.sx });
}

/** A spectral claw-mark across a target (the crescent sprite, laid on the ground for a moment). */
export function slashMark(e: Effects, x: number, z: number, color: number, o: Base & { rot?: number; r?: number; duration?: number } = {}) {
  const origin = o.origin ?? 'player';
  if (motifScale(origin) <= 0 || e.transientLoad >= TRANSIENT_CEILING) return;
  motifStats.decals++;
  e.decal({ tex: fxImage('crescent'), color, x, z, r: o.r ?? 1, rot: o.rot ?? Math.random() * 6, duration: o.duration ?? 0.4, opacity: origin === 'thrall' ? 0.55 : 0.85, growFrom: 0.6, fadeOut: 0.25 });
}
