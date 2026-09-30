import * as THREE from 'three';
import { clone as cloneSkinned } from 'three/examples/jsm/utils/SkeletonUtils.js';
import { assets } from './AssetCache';
import { CREATURE_MODELS, type CreatureSlug } from './modelPaths';
import { hipAnchor, inPlaceHeroClip, stripRootTravel } from './inPlaceAnimation';
import { applyWingFlap, type WingOpts } from './wingFlap';
import { applyGearTint, GEAR_REGIONS, makeGearTintState, type GearRegion } from './gearTint';

export type CreatureAnim = 'idle' | 'walk' | 'run' | 'attack' | 'cast' | 'hurt' | 'death' | 'dig' | 'dive';

const FALLBACK: Record<CreatureAnim, CreatureAnim[]> = {
  idle: ['idle', 'walk'],
  walk: ['walk', 'run', 'idle'],
  run: ['run', 'walk', 'idle'],
  attack: ['attack', 'cast', 'hurt'],
  cast: ['cast', 'attack', 'hurt'],
  hurt: ['hurt'],
  death: ['death'],
  dig: ['dig', 'cast', 'attack'],
  dive: ['dive', 'attack', 'cast'],
};

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
}

const FLASH_COLOR = new THREE.Color(0xfff0dc);
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
  private pendingAttach: [string, THREE.Object3D, THREE.Vector3 | undefined, number | undefined][] = [];
  private calibrate: { obj: THREE.Object3D; dir: THREE.Vector3; frames: number }[] = [];
  /** Calibrated attachments, re-checked while idle so a bad first pose self-heals. */
  private attached: { obj: THREE.Object3D; dir: THREE.Vector3; follow?: number; baseQ?: THREE.Quaternion }[] = [];
  private settledT = 0;
  private recheckT = 0;
  private disposed = false;
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
    let usedFallback = false;
    this.ready = assets
      .model(def.url, def.height * (opts.scale ?? 1))
      .then((t) => {
        if (t) return t;
        usedFallback = true;
        return fb ? assets.model(fb.url, fb.height * (opts.scale ?? 1)) : null;
      })
      .then((t) => {
      if (!t || this.disposed) return;
      const model = t.skinned ? cloneSkinned(t.scene) : t.scene.clone(true);
      model.scale.multiplyScalar(t.scale);
      model.position.y = t.groundOffset;
      model.rotation.y += opts.modelYaw ?? 0;
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
        mesh.material = mat;
        this.mats.push(mat);
      });
      if (this.mats[0]) {
        this.baseEmissive.copy(this.mats[0].emissive);
        this.baseEmissiveIntensity = this.mats[0].emissiveIntensity;
      }
      this.model = model;
      this.root.add(model);
      this.mixer = new THREE.AnimationMixer(model);
      const anchor = hipAnchor(t.clips.get('idle'));
      for (const [name, clip] of t.clips) {
        this.actions.set(name, this.mixer.clipAction(opts.inPlace ? inPlaceHeroClip(clip) : stripRootTravel(clip, anchor)));
      }
      this.mixer.addEventListener('finished', (e) => {
        if (e.action === this.oneShot) {
          this.oneShot = null;
          if (!e.action.getClip().name.startsWith('death')) this.startLoop(true);
        }
      });
      this.loaded = true;
      for (const [bone, obj, dir, follow] of this.pendingAttach) this.attach(bone, obj, dir, follow);
      this.pendingAttach = [];
      this.startLoop(false);
    });
  }

  has(anim: CreatureAnim) {
    return this.actions.has(anim);
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

  private startLoop(fade: boolean) {
    const next = this.resolve(this.loop);
    if (!next) return;
    next.setLoop(THREE.LoopRepeat, Infinity);
    next.clampWhenFinished = false;
    next.timeScale = this.loopSpeed;
    if (next === this.current && !this.oneShot) return;
    next.enabled = true;
    if (fade && this.current) {
      next.reset().setEffectiveWeight(1).fadeIn(0.18).play();
      if (this.current !== next) this.current.fadeOut(0.18);
    } else {
      next.reset().setEffectiveWeight(1).play();
      if (this.current && this.current !== next) this.current.stop();
    }
    this.current = next;
  }

  /** Base looping state (idle/walk/run). `speed` scales playback. */
  setLoop(anim: CreatureAnim, speed = 1) {
    this.loopSpeed = speed;
    if (this.current && this.loop === anim) {
      if (!this.oneShot) this.current.timeScale = speed;
      return;
    }
    this.loop = anim;
    if (!this.oneShot) this.startLoop(true);
  }

  /** One-shot overlay (attack/cast/hurt/death/dig); returns to the loop after. */
  playOnce(anim: CreatureAnim, speed = 1, durationSeconds?: number): boolean {
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
    // Recasting the same action must not fade its only pose down to bind pose.
    if (repeating) a.stopFading();
    else a.fadeIn(0.08);
    a.play();
    if (this.current && this.current !== a) this.current.fadeOut(0.12);
    if (this.oneShot && this.oneShot !== a) this.oneShot.fadeOut(0.08);
    this.oneShot = a;
    this.current = a;
    return true;
  }

  /** Let locomotion blend out a hero gesture as soon as walking resumes. */
  releaseGesture() {
    if (!this.opts.inPlace || !this.oneShot || /^(death|hurt)\d?$/.test(this.oneShot.getClip().name)) return;
    this.oneShot = null;
    this.startLoop(true);
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
  attach(boneName: string, obj: THREE.Object3D, dir?: THREE.Vector3, follow?: number) {
    if (!this.model) {
      this.pendingAttach.push([boneName, obj, dir, follow]);
      return;
    }
    if (dir) {
      const d = dir.clone().normalize();
      this.calibrate.push({ obj, dir: d, frames: 4 });
      this.attached.push({ obj, dir: d, follow });
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

  update(dt: number) {
    this.mixer?.update(dt);
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
