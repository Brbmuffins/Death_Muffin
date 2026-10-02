import * as THREE from 'three';
import { clone as cloneSkinned } from 'three/examples/jsm/utils/SkeletonUtils.js';
import { assets } from './AssetCache';
import { warmModel } from './warmModel';
import { buildBudget } from './buildBudget';
import { CREATURE_MODELS, type CreatureSlug } from './modelPaths';
import { hitstop, pictureDt } from './hitstop';
import CLIP_TIMINGS_JSON from '../content/clipTimings.json';

/**
 * Playback for a timed strike: the clip's impact frame (`impact`, clip seconds; 35% of the clip when unmeasured)
 * must be reached `impactIn` real seconds from now. Speed stays within 0.7–2.2×; a longer wind-up than that allows
 * is skipped by starting part-way in. The one-shot ends `followThrough` real seconds after the impact.
 */
export function strikeTiming(duration: number, impact: number | undefined, impactIn: number, followThrough = 0.3) {
  const peak = Math.min(duration, impact ?? duration * 0.35);
  const lead = Math.max(0.08, impactIn);
  const speed = Math.min(2.2, Math.max(0.7, peak / lead));
  const startAt = Math.max(0, peak - lead * speed);
  return { speed, startAt, endAt: Math.min(duration, peak + followThrough * speed), impactAfter: (peak - startAt) / speed };
}

/**
 * Keeps a looping clip inside [start, end): a time before `start` jumps to it, a time at or past `end` wraps back
 * into the range. Lets one long clip (the thralls' 6.6 s `chop`) repeat just its working stroke. Pure.
 */
export function wrapRange(t: number, start: number, end: number): number {
  if (!(end > start)) return t;
  if (t < start) return start;
  return t >= end ? start + ((t - start) % (end - start)) : t;
}

/** Measured [duration, impact] seconds per model and clip (tools/build-clip-timings.mjs). */
const CLIP_TIMINGS = CLIP_TIMINGS_JSON as Record<string, Record<string, number[]>>;
import { hipAnchor, inPlaceHeroClip, landingTime, stripRootTravel } from './inPlaceAnimation';
import { planLocomotion, STRIDES, type LocomotionPlan } from './locomotion';
import { applyWingFlap, type WingOpts } from './wingFlap';
import { applyFriendRim, type FriendRim } from './friendRim';
import { applyGearTint, GEAR_REGIONS, makeGearTintState, type GearRegion } from './gearTint';

export type CreatureAnim = 'idle' | 'walk' | 'run' | 'attack' | 'cast' | 'hurt' | 'death' | 'dig' | 'chop' | 'dive' | 'talk' | 'talk2' | CombatAnim;
/** Necromancer combat gestures (content/castClips.ts); only the four necro heroes carry them. */
export type CombatAnim = 'slam' | 'sweep' | 'flick' | 'channel' | 'summon';

const FALLBACK: Record<CreatureAnim, CreatureAnim[]> = {
  idle: ['idle', 'walk'],
  walk: ['walk', 'run', 'idle'],
  run: ['run', 'walk', 'idle'],
  attack: ['attack', 'cast', 'hurt'],
  cast: ['cast', 'attack', 'hurt'],
  hurt: ['hurt'],
  death: ['death'],
  dig: ['dig', 'cast', 'attack'],
  chop: ['chop', 'attack', 'dig'],
  dive: ['dive', 'attack', 'cast'],
  talk: ['talk', 'idle'],
  talk2: ['talk2', 'talk', 'idle'],
  slam: ['slam', 'attack', 'cast'],
  sweep: ['sweep', 'attack', 'cast'],
  flick: ['flick', 'cast', 'attack'],
  channel: ['channel', 'cast', 'attack'],
  summon: ['summon', 'dig', 'cast'],
};

/**
 * How a held prop sits in the hand beyond "its +Y along `dir`": a shift in the character's frame at the calibration pose
 * (metres: x to the character's left, y up, z forward; the caller mirrors it for the right hand) and a roll about the
 * prop's own long axis, so a book or blade can face the right way and clear the body.
 */
export interface GripFit {
  offset?: THREE.Vector3;
  roll?: number;
}

export interface CreatureOptions {
  /** Heroes only: let equipped body gear recolour chest/legs/hands/feet (see gearTint.ts). */
  gearTint?: boolean;
  /** Anchor generated hero root motion to the gameplay position and heading. */
  inPlace?: boolean;
  /** Align an asset's authored forward axis with gameplay's +Z forward. */
  modelYaw?: number;
  /** Multiplies base colour (e.g. darken enemies, pale thralls). */
  tint?: THREE.ColorRepresentation;
  emissive?: THREE.ColorRepresentation;
  emissiveIntensity?: number;
  /** Ghostly translucent look (Mourner wraiths). */
  spectral?: boolean;
  scale?: number;
  castShadow?: boolean;
  /** Load this model instead if the requested one is missing. */
  fallback?: CreatureSlug;
  /** Flying creatures: flap the wings in the vertex shader (see wingFlap.ts). */
  wings?: WingOpts;
  /** Thralls: a soft fresnel rim so friendly dead read at a glance against the horde (see friendRim.ts). */
  rim?: FriendRim;
  /** Struck enemies only: freeze with a hitstop. The hero, thralls and everything else keep animating through it. */
  hitstop?: boolean;
  /** Crossfade seconds for idle/walk/run changes (default 0.28; the hero uses a quicker blend so the body answers the stick). */
  locomotionFade?: number;
}

const FLASH_COLOR = new THREE.Color(0xfff0dc);
/** Crossfade seconds: locomotion eases (idle / walk / run), a return from a swing a little quicker, a swing itself snaps. */
const FADE_LOCOMOTION = 0.28;
const FADE_RETURN = 0.2;
/** The tripo biped rig faces +X in its GLB; gameplay headings use +Z. */
const BIPED_YAW = -Math.PI / 2;
/** Quadruped rigs have no Hip bone; measured head-versus-tail at heading 0 (2026-10-02). The skull rat already faces +Z. */
const RIG_YAW: Partial<Record<string, number>> = { bone_hound: Math.PI, cinderhound: Math.PI };
/** Playback of a walk-only rig (the quadrupeds) standing in for idle: a slow shuffle instead of trotting on the spot. */
const IDLE_STAND_IN = 0.2;
/** Seconds of the hurt clip an additive flinch uses, and how fast it plays. */
const FLINCH_SECONDS = 0.5;
const FLINCH_SPEED = 1.35;
/** One-shots that may have numbered variety clips (tools/build-characters.mjs CLIP_NAMES). */
const VARIANTS = new Set<CreatureAnim>(['attack', 'hurt', 'death']);

/**
 * One animated instance of a generated character. The template GLB loads once
 * (AssetCache); each Creature clones it with its own skeleton, mixer and
 * materials (materials are per-instance so hit flashes don't leak).
 */
export class Creature {
  readonly root = new THREE.Group();
  /** Resolves after the model has been cloned and attached (or its load failed). */
  readonly ready: Promise<void>;
  loaded = false;
  private model: THREE.Object3D | null = null;
  private shadowOn: boolean;
  private mixer: THREE.AnimationMixer | null = null;
  private actions = new Map<string, THREE.AnimationAction>();
  private mats: THREE.MeshStandardMaterial[] = [];
  private baseEmissive = new THREE.Color(0);
  private baseEmissiveIntensity = 0;
  private loop: CreatureAnim = 'idle';
  private loopSpeed = 1;
  private current: THREE.AnimationAction | null = null;
  private oneShot: THREE.AnimationAction | null = null;
  /** Shared uniform state for body-gear tints; only patched into materials when `gearTint` is set. */
  private readonly gearTint = makeGearTintState();
  private pendingAttach: [string, THREE.Object3D, THREE.Vector3 | undefined, number | undefined, GripFit | undefined][] = [];
  private calibrate: { obj: THREE.Object3D; dir: THREE.Vector3; frames: number }[] = [];
  /** Calibrated attachments, re-checked while idle so a bad first pose self-heals. */
  private attached: { obj: THREE.Object3D; dir: THREE.Vector3; follow?: number; baseQ?: THREE.Quaternion; fit?: GripFit }[] = [];
  private settledT = 0;
  private recheckT = 0;
  private disposed = false;
  /** Slug whose measured strides apply (the requested model, or its stand-in when that one failed to load). */
  private rigSlug: string;
  /** World height of the loaded model (def height x scale option), before the owner's root scale. */
  private baseHeight: number;
  private locoRun = false;
  /** Additive hit-react laid over whatever is playing (see flinch). */
  private flinchAct: THREE.AnimationAction | null = null;
  private flinchStrength = 0;
  private flashV = 0;
  /** Set by the owner when the model has no death clip (tip over instead). */
  toppled = 0;

  constructor(
    readonly slug: CreatureSlug,
    private opts: CreatureOptions = {},
  ) {
    this.shadowOn = opts.castShadow ?? true;
    const def = CREATURE_MODELS[slug];
    const fb = opts.fallback ? CREATURE_MODELS[opts.fallback] : null;
    this.rigSlug = slug;
    this.baseHeight = def.height * (opts.scale ?? 1);
    let usedFallback = false;
    this.ready = assets
      .model(def.url, def.height * (opts.scale ?? 1))
      .then((t) => {
        if (t) return t;
        usedFallback = true;
        this.rigSlug = opts.fallback ?? slug;
        this.baseHeight = (fb?.height ?? def.height) * (opts.scale ?? 1);
        return fb ? assets.model(fb.url, fb.height * (opts.scale ?? 1)) : null;
      })
      .then(async (t) => {
      if (!t || this.disposed) return;
      // Clone + material variants: one budgeted chunk, so a wave's bodies spread over a few frames.
      const model = await buildBudget.run(() => {
      const model = t.skinned ? cloneSkinned(t.scene) : t.scene.clone(true);
      model.scale.multiplyScalar(t.scale);
      model.position.y = t.groundOffset;
      // Biped rigs (anything with a Hip bone) face +X in the GLB. Heroes pass their own yaw; every other biped gets the
      // same one, so enemies, thralls and bosses face (and swing their legs) along their heading instead of sideways.
      model.rotation.y += opts.modelYaw ?? RIG_YAW[this.rigSlug] ?? (model.getObjectByName('Hip') ? BIPED_YAW : 0);
      const wingPhase = Math.random() * Math.PI * 2;
      model.traverse((o) => {
        const mesh = o as THREE.Mesh;
        if (!mesh.isMesh) return;
        mesh.castShadow = this.shadowOn;
        const src = mesh.material as THREE.MeshStandardMaterial;
        const mat = src.clone();
        if (opts.tint) mat.color.multiply(new THREE.Color(opts.tint));
        if (opts.emissive) {
          mat.emissive = new THREE.Color(opts.emissive);
          mat.emissiveIntensity = opts.emissiveIntensity ?? 0.3;
        }
        if (opts.spectral) {
          mat.transparent = true;
          mat.opacity = 0.55;
          mat.depthWrite = false;
          mat.emissive = new THREE.Color(opts.emissive ?? 0x8f9ed1);
          mat.emissiveIntensity = opts.emissiveIntensity ?? 0.9;
          mesh.castShadow = false;
        }
        // Only the requested model flaps; a fallback stand-in (older deploy) keeps still.
        if (opts.wings && !usedFallback) applyWingFlap(mesh, mat, opts.wings, wingPhase);
        if (opts.gearTint) applyGearTint(mesh, mat, this.gearTint);
        if (opts.rim) applyFriendRim(mat, opts.rim);
        mesh.material = mat;
        this.mats.push(mat);
      });
      if (this.mats[0]) {
        this.baseEmissive.copy(this.mats[0].emissive);
        this.baseEmissiveIntensity = this.mats[0].emissiveIntensity;
      }
      return model;
      });
      // First draw of a new body compiles shaders and uploads textures; do both off the frame, then attach.
      await warmModel(model, this.mats, t, `${!!opts.spectral}${!!opts.wings && !usedFallback}${!!opts.gearTint}${!!opts.rim}`);
      if (this.disposed) {
        this.mats.forEach((m) => m.dispose());
        return;
      }
      // Mixer + one action per clip: a second budgeted chunk (visual only; logic never waits on `loaded`).
      await buildBudget.run(() => {
      if (this.disposed) {
        this.mats.forEach((m) => m.dispose());
        return;
      }
      this.model = model;
      this.root.add(model);
      this.mixer = new THREE.AnimationMixer(model);
      const anchor = hipAnchor(t.clips.get('idle'));
      for (const [name, clip] of t.clips) {
        this.actions.set(name, this.mixer.clipAction(opts.inPlace ? inPlaceHeroClip(clip, anchor) : stripRootTravel(clip, anchor)));
      }
      this.mixer.addEventListener('finished', (e) => {
        if (e.action === this.oneShot) {
          this.oneShot = null;
          this.oneShotEnd = null;
          if (!e.action.getClip().name.startsWith('death')) this.startLoop(true, FADE_RETURN);
        }
      });
      this.loaded = true;
      for (const [bone, obj, dir, follow, fit] of this.pendingAttach) this.attach(bone, obj, dir, follow, fit);
      this.pendingAttach = [];
      this.startLoop(false);
      });
    });
  }

  has(anim: CreatureAnim) {
    return this.actions.has(anim);
  }

  /** Length in seconds of a clip this model carries (after in-place processing), or 0. */
  clipDuration(anim: CreatureAnim): number {
    return this.actions.get(anim)?.getClip().duration ?? 0;
  }

  private resolve(anim: CreatureAnim): THREE.AnimationAction | null {
    for (const name of FALLBACK[anim]) {
      const a = this.actions.get(name);
      if (!a) continue;
      // Variety clips ('death2', 'attack3', …): one-shots pick at random so a horde doesn't move in lockstep.
      if (anim === name && VARIANTS.has(anim)) {
        const pool = [a];
        for (let i = 2; i <= 3; i++) {
          const v = this.actions.get(`${name}${i}`);
          if (v) pool.push(v);
        }
        return pool[Math.floor(Math.random() * pool.length)];
      }
      return a;
    }
    return null;
  }

  /** True when the loop being asked for has no clip of its own and borrows another (the quadrupeds' idle is their walk). */
  private standIn(next: THREE.AnimationAction | null) {
    return this.loop === 'idle' && !!next && next !== this.actions.get('idle');
  }

  private startLoop(fade: boolean, fadeS = this.opts.locomotionFade ?? FADE_LOCOMOTION) {
    const next = this.resolve(this.loop);
    if (!next) return;
    next.setLoop(THREE.LoopRepeat, Infinity);
    next.clampWhenFinished = false;
    next.timeScale = this.standIn(next) ? IDLE_STAND_IN : this.loopSpeed;
    if (next === this.current && !this.oneShot) return;
    next.enabled = true;
    const prev = this.current;
    if (fade && prev) {
      next.reset().setEffectiveWeight(1);
      // Walk and run share a step cycle: land the new clip in the same phase so the legs do not scramble mid-blend.
      if (prev !== next && this.isStride(prev) && this.isStride(next)) next.time = (prev.time / prev.getClip().duration) * next.getClip().duration;
      next.fadeIn(fadeS).play();
      if (prev !== next) prev.fadeOut(fadeS);
    } else {
      next.reset().setEffectiveWeight(1).play();
      if (prev && prev !== next) prev.stop();
    }
    this.current = next;
  }

  private isStride(a: THREE.AnimationAction) {
    return a === this.actions.get('walk') || a === this.actions.get('run');
  }

  /** Loop only the [start, end) seconds of a clip (see wrapRange); any later setLoop to another clip clears it. */
  private range: { anim: CreatureAnim; start: number; end: number } | null = null;

  /** Like setLoop, but repeats just a segment of the clip (e.g. one chop stroke). Falls back to the whole clip if missing. */
  loopRange(anim: CreatureAnim, start: number, end: number, speed = 1) {
    this.setLoop(anim, speed);
    this.range = { anim, start, end };
  }

  /** Playhead (clip seconds) of the running action, for timing effects to a beat; 0 before the model loads. */
  playhead(): number {
    return this.current?.time ?? 0;
  }

  /** Base looping state (idle/walk/run). `speed` scales playback. */
  setLoop(anim: CreatureAnim, speed = 1) {
    this.loopSpeed = speed;
    if (this.range && this.range.anim !== anim) this.range = null;
    if (this.current && this.loop === anim) {
      if (!this.oneShot) this.current.timeScale = this.standIn(this.current) ? IDLE_STAND_IN : speed;
      return;
    }
    this.loop = anim;
    if (!this.oneShot) this.startLoop(true);
  }

  /** The last locomotion plan (QA and tests read it; null until setGroundSpeed has run). */
  lastPlan: LocomotionPlan | null = null;

  /** World height of this body right now: the model's height, the scale option and the owner's root scale. */
  worldHeight(): number {
    return this.baseHeight * this.root.scale.x;
  }

  /**
   * Walk or run at the pace that matches `ground` (units per second of real movement), with this model's measured
   * stride (src/content/strideSpeeds.json) so the feet stay planted. Call it every frame the body moves; it only
   * touches the mixer when the clip or its speed changes.
   */
  setGroundSpeed(ground: number): LocomotionPlan {
    const plan = planLocomotion(STRIDES[this.rigSlug], this.worldHeight(), ground, this.actions.has('run'), this.locoRun);
    this.locoRun = plan.clip === 'run';
    this.lastPlan = plan;
    this.setLoop(plan.clip, plan.timeScale);
    return plan;
  }

  /** Clip time at which the current one-shot hands back to the loop (a strike's follow-through end). */
  private oneShotEnd: number | null = null;

  /**
   * A timed strike: plays an attack/cast one-shot so its measured impact frame (src/content/clipTimings.json,
   * tools/build-clip-timings.mjs) lands `impactIn` seconds from now, the moment the sim applies the hit. Long
   * wind-ups are skipped rather than played at a frantic speed, and the clip hands back to walk/idle a short
   * follow-through after the impact instead of running its full length (a 6.6 s clip used to freeze a walking
   * enemy in its attack pose). Rigs without a measured clip assume the impact at 35% of the clip.
   */
  playStrike(anim: CreatureAnim, impactIn: number, followThrough = 0.3): boolean {
    if (!this.playOnce(anim)) return false;
    const a = this.oneShot;
    if (!a || a.getClip().name.startsWith('death')) return true;
    const clip = a.getClip();
    const timing = CLIP_TIMINGS[this.slug]?.[clip.name];
    const t = strikeTiming(clip.duration, timing?.[1], impactIn, followThrough);
    a.timeScale = t.speed;
    a.time = t.startAt;
    this.oneShotEnd = t.endAt;
    return true;
  }

  /** One-shot overlay (attack/cast/hurt/death/dig); returns to the loop after. */
  playOnce(anim: CreatureAnim, speed = 1, durationSeconds?: number, startAt = 0): boolean {
    // A hit-react is laid over whatever is playing (walking, swinging, casting) instead of replacing it.
    if (anim === 'hurt' && this.actions.has('hurt')) return this.flinch();
    if (anim === 'death') this.flinchAct?.stop();
    const a = this.resolve(anim);
    if (!a) return false;
    // Don't let a hurt flinch cancel an attack or a death.
    if (this.oneShot && anim === 'hurt') return true;
    if (this.oneShot?.getClip().name.startsWith('death')) return true;
    a.setLoop(THREE.LoopOnce, 1);
    a.clampWhenFinished = true;
    a.timeScale = durationSeconds ? a.getClip().duration / Math.max(0.12, durationSeconds) : speed;
    a.enabled = true;
    const repeating = this.current === a;
    a.reset().setEffectiveWeight(1);
    // Start part-way in to skip a wind-up the ability has no time for (release frame = spell spawn).
    if (startAt > 0) a.time = Math.min(startAt, a.getClip().duration);
    // Recasting the same action must not fade its only pose down to bind pose.
    if (repeating) a.stopFading();
    else a.fadeIn(0.08);
    a.play();
    if (this.current && this.current !== a) this.current.fadeOut(0.12);
    if (this.oneShot && this.oneShot !== a) this.oneShot.fadeOut(0.08);
    this.oneShot = a;
    this.current = a;
    this.oneShotEnd = null;
    return true;
  }

  /**
   * A short additive flinch: the first half-second of the `hurt` clip, as a difference from its first frame, added on
   * top of the running animation. The body jolts and recovers without losing its stride or cutting a swing. Weaker while
   * a one-shot (a swing or a cast) is playing. Returns false for a rig with no hurt clip.
   */
  flinch(strength = 0.85): boolean {
    if (!this.mixer) return false;
    if (!this.flinchAct) {
      const src = this.actions.get('hurt');
      if (!src) return false;
      const base = src.getClip();
      const sub = THREE.AnimationUtils.subclip(base, 'flinch', 0, Math.max(2, Math.round(Math.min(base.duration, FLINCH_SECONDS * FLINCH_SPEED) * 30)), 30);
      THREE.AnimationUtils.makeClipAdditive(sub, 0, sub.clone(), 30);
      const a = this.mixer.clipAction(sub);
      a.blendMode = THREE.AdditiveAnimationBlendMode;
      a.setLoop(THREE.LoopOnce, 1);
      a.clampWhenFinished = false;
      this.flinchAct = a;
    }
    if (this.oneShot?.getClip().name.startsWith('death')) return true;
    const a = this.flinchAct;
    this.flinchStrength = strength * (this.oneShot ? 0.5 : 1);
    a.enabled = true;
    a.timeScale = FLINCH_SPEED;
    a.reset().setEffectiveWeight(0).play();
    return true;
  }

  /** Let locomotion blend out a hero gesture as soon as walking resumes. */
  releaseGesture() {
    if (!this.opts.inPlace || !this.oneShot || /^(death|hurt)\d?$/.test(this.oneShot.getClip().name)) return;
    this.oneShot = null;
    this.oneShotEnd = null;
    this.startLoop(true, FADE_RETURN);
  }

  /** Jump a clip to its last frame (corpses of late joiners, etc.). */
  holdLastFrame(anim: CreatureAnim) {
    const a = this.resolve(anim);
    if (!a) return false;
    a.setLoop(THREE.LoopOnce, 1);
    a.clampWhenFinished = true;
    a.reset().play();
    a.time = a.getClip().duration;
    this.oneShot = a;
    this.current?.stop();
    this.current = a;
    return true;
  }

  /**
   * Parent `obj` to a bone. With `dir` (character-local, e.g. straight up),
   * the object's +Y is auto-aligned to that direction after the first animated
   * frames — bone axes differ per rig, so we calibrate instead of guessing.
   * `follow` (0..1) keeps a held staff steady: every frame its +Y is pulled back
   * toward `dir` by (1 - follow), so it rides the hand without flailing when the
   * wrist swings through a run cycle. Omit it for weapons that should swing freely.
   */
  attach(boneName: string, obj: THREE.Object3D, dir?: THREE.Vector3, follow?: number, fit?: GripFit) {
    if (!this.model) {
      this.pendingAttach.push([boneName, obj, dir, follow, fit]);
      return;
    }
    if (dir) {
      const d = dir.clone().normalize();
      this.calibrate.push({ obj, dir: d, frames: 4 });
      this.attached.push({ obj, dir: d, follow, fit });
    }
    let bone: THREE.Object3D | undefined;
    this.model.traverse((o) => {
      if (!bone && o.name === boneName) bone = o;
    });
    // Attachments are authored in world units; cancel the bone chain's scale.
    const s = new THREE.Vector3();
    (bone ?? this.model).getWorldScale(s);
    const rootScale = new THREE.Vector3();
    this.root.getWorldScale(rootScale);
    obj.scale.multiplyScalar(rootScale.x / (s.x || 1));
    (bone ?? this.root).add(obj);
  }

  /** Recolour one body region (null clears it). Takes effect on the next frame; safe before the model loads. */
  setRegionTint(region: GearRegion, tint: { color: number; glow?: number; strength?: number } | null) {
    const i = GEAR_REGIONS.indexOf(region);
    const t = this.gearTint.tint[i];
    const g = this.gearTint.glow[i];
    if (!tint) {
      t.set(1, 1, 1, 0);
      g.set(0, 0, 0);
      return;
    }
    const c = new THREE.Color(tint.color);
    t.set(c.r, c.g, c.b, tint.strength ?? 0.7);
    if (tint.glow) {
      const gc = new THREE.Color(tint.glow);
      g.set(gc.r, gc.g, gc.b).multiplyScalar(0.6);
    } else g.set(0, 0, 0);
  }

  /** Remove an attached prop (equipment swaps). Does not dispose it. */
  detach(obj: THREE.Object3D) {
    this.pendingAttach = this.pendingAttach.filter(([, o]) => o !== obj);
    this.calibrate = this.calibrate.filter((c) => c.obj !== obj);
    this.attached = this.attached.filter((a) => a.obj !== obj);
    obj.removeFromParent();
  }

  set flash(v: number) {
    if (Math.abs(v - this.flashV) < 0.02) return;
    this.flashV = v;
    for (const m of this.mats) {
      if (v > 0.01) {
        m.emissive.copy(this.baseEmissive).lerp(FLASH_COLOR, Math.min(1, v));
        // PBR Tripo materials are largely metallic: keep the pulse faint or it whites out.
        m.emissiveIntensity = this.baseEmissiveIntensity + v * 0.16;
      } else {
        m.emissive.copy(this.baseEmissive);
        m.emissiveIntensity = this.baseEmissiveIntensity;
      }
    }
  }

  /** Toggle moon shadows for every mesh (shadow LOD); remembered until the model loads. */
  setCastShadow(on: boolean) {
    if (this.shadowOn === on) return;
    this.shadowOn = on;
    this.model?.traverse((o) => {
      if ((o as THREE.Mesh).isMesh) o.castShadow = on && !this.opts.spectral;
    });
  }

  setOpacity(o: number) {
    for (const m of this.mats) {
      m.transparent = o < 1 || !!this.opts.spectral;
      m.opacity = (this.opts.spectral ? 0.55 : 1) * o;
      m.depthWrite = o >= 1 && !this.opts.spectral;
    }
  }

  /** True once a dying body has come to rest (its death clip's landing moment, or the tip-over for models without one). */
  hasLanded(): boolean {
    if (this.toppled) return this.toppled >= 0.8;
    const a = this.oneShot;
    if (!a || !a.getClip().name.startsWith('death')) return false;
    return a.time >= landingTime(a.getClip());
  }

  update(dtReal: number) {
    // A hitstop freezes a struck enemy's picture (this clock only, never the sim's); the hero and thralls are exempt.
    const dt = pictureDt(dtReal, !!this.opts.hitstop, hitstop.scale);
    const f = this.flinchAct;
    if (f && f.isRunning()) {
      // Ease the flinch in over ~50 ms and out over the last ~180 ms so it never pops.
      const edge = FLINCH_SPEED;
      f.setEffectiveWeight(this.flinchStrength * Math.max(0, Math.min(1, f.time / (0.05 * edge), (f.getClip().duration - f.time) / (0.18 * edge))));
    }
    this.mixer?.update(dt);
    const r = this.range;
    if (r && this.current && !this.oneShot && this.current === this.resolve(r.anim)) {
      const t = wrapRange(this.current.time, r.start, r.end);
      if (t !== this.current.time) this.current.time = t;
    }
    if (this.oneShot && this.oneShotEnd !== null && this.oneShot.time >= this.oneShotEnd) {
      this.oneShot = null;
      this.oneShotEnd = null;
      this.startLoop(true, FADE_RETURN);
    }
    if (!this.model) return;
    const idle = this.actions.get('idle');
    const settled = !this.oneShot && (!idle || (this.current === idle && idle.getEffectiveWeight() > 0.99));
    this.settledT = settled ? this.settledT + dt : 0;
    if (this.calibrate.length) this.runCalibration();
    else if (this.attached.some((a) => a.baseQ)) this.steadyAttachments();
    if (!this.calibrate.length && this.attached.length && this.settledT > 0.6 && (this.recheckT -= dt) <= 0) {
      this.recheckT = 2;
      this.recheckAttachments();
    }
  }

  /** Pull each `follow` attachment's +Y back toward its aim direction, keeping the bone's roll. */
  private steadyAttachments() {
    this.root.updateMatrixWorld(true);
    const rootQ = this.root.getWorldQuaternion(new THREE.Quaternion());
    const parentQ = new THREE.Quaternion();
    const driven = new THREE.Quaternion();
    const locked = new THREE.Quaternion();
    const up = new THREE.Vector3();
    for (const a of this.attached) {
      const parent = a.obj.parent;
      if (!a.baseQ || !parent) continue;
      parent.getWorldQuaternion(parentQ);
      driven.copy(parentQ).multiply(a.baseQ);
      up.set(0, 1, 0).applyQuaternion(driven);
      const want = a.dir.clone().applyQuaternion(rootQ);
      locked.setFromUnitVectors(up, want).multiply(driven);
      driven.slerp(locked, 1 - (a.follow ?? 1));
      a.obj.quaternion.copy(parentQ.invert().multiply(driven));
    }
  }

  /** Re-align any attachment whose +Y has drifted >25° from its intended direction. */
  private recheckAttachments() {
    this.root.updateMatrixWorld(true);
    const rootQ = new THREE.Quaternion();
    this.root.getWorldQuaternion(rootQ);
    const worldUp = new THREE.Vector3();
    const q = new THREE.Quaternion();
    for (const a of this.attached) {
      a.obj.getWorldQuaternion(q);
      worldUp.set(0, 1, 0).applyQuaternion(q);
      const want = a.dir.clone().applyQuaternion(rootQ);
      if (worldUp.angleTo(want) > (25 * Math.PI) / 180) this.calibrate.push({ obj: a.obj, dir: a.dir, frames: 1 });
    }
    if (this.calibrate.length) this.runCalibration();
  }

  private runCalibration() {
    this.root.updateMatrixWorld(true);
    const rootQ = new THREE.Quaternion();
    this.root.getWorldQuaternion(rootQ);
    // Only calibrate against a settled idle pose (not bind pose, not a one-shot).
    const settled = this.settledT > 0.25;
    for (let i = this.calibrate.length - 1; i >= 0; i--) {
      const c = this.calibrate[i];
      if (!settled || --c.frames > 0) continue;
      const parent = c.obj.parent;
      if (!parent) continue;
      const parentQ = new THREE.Quaternion();
      parent.getWorldQuaternion(parentQ);
      const want = c.dir.clone().applyQuaternion(rootQ).applyQuaternion(parentQ.invert());
      c.obj.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), want.normalize());
      const rec = this.attached.find((a) => a.obj === c.obj);
      const fit = rec?.fit;
      if (fit?.roll) c.obj.quaternion.multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 1, 0), fit.roll));
      if (fit?.offset) {
        // Character-frame metres -> the bone's local frame (undo its orientation and its inherited scale).
        const s = parent.getWorldScale(new THREE.Vector3()).x || 1;
        c.obj.position.copy(fit.offset).applyQuaternion(rootQ).applyQuaternion(parentQ).divideScalar(s);
      }
      if (rec && rec.follow !== undefined) rec.baseQ = c.obj.quaternion.clone();
      this.calibrate.splice(i, 1);
    }
  }

  dispose() {
    this.disposed = true;
    this.mixer?.stopAllAction();
    this.mats.forEach((m) => m.dispose());
    this.root.removeFromParent();
    this.root.clear();
    this.mixer = null;
  }
}
