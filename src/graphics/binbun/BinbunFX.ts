/**
 * Plays the converted BinbunVFX effects (public/fx/binbun/*.json, docs/BINBUN-VFX-PORT.md).
 * Owned by Effects as `effects.binbun` and stepped from Effects.update.
 *
 * - Fetch + cache, non-blocking and fail-open: `spawn` returns a handle at once; the
 *   effect appears when its JSON arrives, and a missing/broken file is a silent no-op.
 *   Nothing in the game awaits it.
 * - One InstancedMesh per GPUParticles3D node (CPU-simulated), a plain Mesh per
 *   MeshInstance3D, and a small track player for the animated properties.
 * - OmniLight3D nodes go through Effects.lightFlash — never a PointLight of its own.
 * - Capped (24 one-shots, 32 loopers), pooled per effect id, loopers culled when far
 *   or off-screen.
 */
import * as THREE from 'three';
import type { Handle } from '../Effects';
import { curveAt, effectTemplate, trackAt, type BinbunEffectFile, type EffectTemplate, type MeshShape, type NodeTemplate, type TextureRef } from './godot';
import { bakeTexture } from './textures';
import { buildMaterial, linear, setColors } from './shaders';
import type { BinbunId } from './catalog';

export interface BinbunSpawn {
  x: number;
  y?: number;
  z: number;
  scale?: number;
  /** Yaw in radians. */
  rot?: number;
  /** [primary, secondary?, tertiary?]; missing entries darken from the primary. */
  colors?: readonly THREE.ColorRepresentation[];
  /** Track a moving anchor; returning null ends the effect. */
  follow?: () => { x: number; y?: number; z: number } | null;
  /** Seconds before the effect fades out (loopers otherwise run until killed). */
  duration?: number;
  /** One-off impact: fire the one-shot particles and end after the longest lifetime. */
  once?: boolean;
  /** Overall opacity (e.g. a quiet idle beacon). */
  alpha?: number;
}

export interface BinbunHandle extends Handle {
  move(x: number, y: number | undefined, z: number): void;
  setAlpha(a: number): void;
}

type LightFlash = (x: number, y: number, z: number, color: THREE.Color, intensity: number, life: number) => void;

const BASE = 'fx/binbun/';
const MAX_ONESHOTS = 24;
const MAX_LOOPERS = 32;
const CULL_DISTANCE = 40;
const FADE_OUT = 0.3;

// App-lifetime caches, like fxImages: the JSON, textures and geometries are shared by every Effects instance.
const files = new Map<string, Promise<EffectTemplate | null>>();
const ready = new Map<string, EffectTemplate | null>();
const warmed = new Set<string>();
const textures = new Map<string, THREE.Texture>();
const geometries = new Map<string, THREE.BufferGeometry>();
let blank: THREE.DataTexture | null = null;
let loader: THREE.TextureLoader | null = null;

/** Start (or reuse) the fetch of one effect. Resolves null on any failure. */
export function loadBinbun(id: string): Promise<EffectTemplate | null> {
  let p = files.get(id);
  if (!p) {
    p = fetch(`${BASE}${id}.json`)
      .then((r) => (r.ok ? r.json() : null))
      .then((j: BinbunEffectFile | null) => (j && j.documents ? effectTemplate(j, BASE) : null))
      .catch(() => null)
      .then((t) => {
        ready.set(id, t);
        return t;
      });
    files.set(id, p);
  }
  return p;
}

export function preloadBinbun(ids: readonly string[]) {
  // Spread the optional High-quality work across idle turns so entering the
  // world does not parse every effect and bake every texture in one frame.
  void (async () => {
    for (const id of ids) {
      if (warmed.has(id)) continue;
      warmed.add(id);
      const template = await loadBinbun(id);
      if (template) {
        for (const node of template.nodes) {
          const material = node.material;
          if (!material) continue;
          if (material.texture) textureFor(material.texture);
          for (const ref of Object.values(material.samplers)) textureFor(ref);
        }
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 80));
    }
  })();
}

function blankTexture() {
  // Black = mask 0 = fully transparent until the real texture arrives (never a visible box).
  blank ??= Object.assign(new THREE.DataTexture(new Uint8Array([0, 0, 0, 0]), 1, 1), { needsUpdate: true });
  return blank;
}

function textureFor(ref: TextureRef | null | undefined): THREE.Texture {
  if (!ref) return blankTexture();
  const key = ref.kind === 'png' ? ref.url : ref.key;
  let tex = textures.get(key);
  if (tex) return tex;
  if (ref.kind === 'png') {
    loader ??= new THREE.TextureLoader();
    tex = loader.load(ref.url, undefined, undefined, () => undefined);
    tex.flipY = false;
  } else {
    const baked = bakeTexture(ref);
    if (!baked) return blankTexture();
    tex = new THREE.DataTexture(baked.data, baked.width, baked.height);
    tex.needsUpdate = true;
    tex.magFilter = THREE.LinearFilter;
    tex.minFilter = THREE.LinearFilter;
  }
  tex.colorSpace = THREE.NoColorSpace;
  const clamp = ref.kind === 'gradient' && ref.repeat === 0;
  tex.wrapS = tex.wrapT = clamp ? THREE.ClampToEdgeWrapping : THREE.RepeatWrapping;
  textures.set(key, tex);
  return tex;
}

function geometryFor(shape: MeshShape): THREE.BufferGeometry {
  const key = JSON.stringify(shape);
  let g = geometries.get(key);
  if (g) return g;
  switch (shape.kind) {
    case 'quad':
      g = new THREE.PlaneGeometry(shape.w, shape.h);
      // QuadMesh orientation: 0 faces +X, 1 faces +Y, 2 faces +Z.
      if (shape.orientation === 1) g.rotateX(-Math.PI / 2);
      else if (shape.orientation === 0) g.rotateY(Math.PI / 2);
      break;
    case 'plane':
      g = new THREE.PlaneGeometry(shape.w, shape.h).rotateX(-Math.PI / 2);
      break;
    case 'sphere':
      g = new THREE.SphereGeometry(shape.radius, 24, shape.hemisphere ? 8 : 16, 0, Math.PI * 2, 0, shape.hemisphere ? Math.PI / 2 : Math.PI);
      if (shape.height !== shape.radius * 2 && shape.radius > 0) g.scale(1, (shape.hemisphere ? shape.height : shape.height / 2) / shape.radius, 1);
      break;
    case 'cylinder':
      g = new THREE.CylinderGeometry(shape.top, shape.bottom, shape.height, 24, 1, true);
      break;
    case 'torus':
      g = new THREE.TorusGeometry((shape.inner + shape.outer) / 2, Math.max(0.01, (shape.outer - shape.inner) / 2), 10, 32).rotateX(Math.PI / 2);
      break;
  }
  geometries.set(key, g);
  return g;
}

const tmpM = new THREE.Matrix4();
const tmpV = new THREE.Vector3();
const tmpD = new THREE.Vector3();
const tmpQ = new THREE.Quaternion();
const tmpS = new THREE.Vector3();
const UP = new THREE.Vector3(0, 1, 0);
const Z = new THREE.Vector3(0, 0, 1);
const rand = (a: number, b: number) => a + Math.random() * (b - a);

interface MeshPart {
  kind: 'mesh';
  node: NodeTemplate;
  mesh: THREE.Mesh;
  mat: THREE.ShaderMaterial;
}

class ParticlePart {
  readonly kind = 'particles';
  readonly mesh: THREE.InstancedMesh;
  readonly mat: THREE.ShaderMaterial;
  readonly n: number;
  readonly world: boolean;
  readonly billboard: boolean;
  private age: Float32Array;
  private life: Float32Array;
  private alive: Uint8Array;
  private pos: Float32Array;
  private vel: Float32Array;
  private size: Float32Array;
  private ang: Float32Array;
  private seed: Float32Array;
  private color: THREE.InstancedBufferAttribute;
  private custom: THREE.InstancedBufferAttribute;
  emitting = false;
  private emitT = 0;
  private prevT = -1e-6;
  private once = false;
  private nodeMatrix = new THREE.Matrix4();

  constructor(readonly node: NodeTemplate) {
    this.n = node.amount ?? 8;
    this.world = !node.localCoords;
    this.billboard = node.align === 1 || node.align === 3 || !!node.material?.billboard || (node.shape?.kind === 'quad' && node.shape.orientation === 2 && !node.process?.alignY);
    this.mat = buildMaterial(node.material, node.shape, textureFor);
    this.mat.uniforms.uBillboard.value = this.billboard ? 1 : 0;
    const geo = geometryFor(node.shape ?? { kind: 'quad', w: 1, h: 1, orientation: 2 });
    this.mesh = new THREE.InstancedMesh(geo, this.mat, this.n);
    this.mesh.frustumCulled = false;
    this.mesh.count = 0;
    this.mesh.renderOrder = 6;
    this.color = new THREE.InstancedBufferAttribute(new Float32Array(this.n * 4), 4).setUsage(THREE.DynamicDrawUsage);
    this.custom = new THREE.InstancedBufferAttribute(new Float32Array(this.n * 4), 4).setUsage(THREE.DynamicDrawUsage);
    // Attributes live on the instanced mesh's own geometry clone would duplicate buffers; a shared geometry
    // can't carry per-effect attributes, so each part gets a thin geometry view over the shared buffers.
    const own = new THREE.InstancedBufferGeometry();
    own.index = geo.index;
    for (const [k, a] of Object.entries(geo.attributes)) own.setAttribute(k, a);
    own.setAttribute('aColor', this.color);
    own.setAttribute('aCustom', this.custom);
    this.mesh.geometry = own;
    this.age = new Float32Array(this.n);
    this.life = new Float32Array(this.n);
    this.alive = new Uint8Array(this.n);
    this.pos = new Float32Array(this.n * 3);
    this.vel = new Float32Array(this.n * 3);
    this.size = new Float32Array(this.n);
    this.ang = new Float32Array(this.n);
    this.seed = new Float32Array(this.n);
    this.nodeMatrix.fromArray(node.matrix);
    if (!this.world) this.mesh.matrix.copy(this.nodeMatrix), (this.mesh.matrixAutoUpdate = false);
  }

  reset(once: boolean) {
    this.alive.fill(0);
    this.mesh.count = 0;
    this.once = once;
    this.setEmitting(this.node.emitting !== false);
  }

  setEmitting(on: boolean) {
    if (on && !this.emitting) {
      this.emitT = 0;
      this.prevT = -1e-6;
    }
    this.emitting = on;
  }

  get busy() {
    return this.emitting || this.mesh.count > 0;
  }

  private spawn(i: number, root: THREE.Matrix4, rootScale: number) {
    const p = this.node.process!;
    // Emission shape (node-local).
    let x = 0, y = 0, z = 0;
    const dir = () => {
      const u = Math.random() * 2 - 1;
      const t = Math.random() * Math.PI * 2;
      const s = Math.sqrt(1 - u * u);
      return [s * Math.cos(t), u, s * Math.sin(t)];
    };
    if (p.shape === 1 || p.shape === 2) {
      const d = dir();
      const r = p.sphereRadius * (p.shape === 1 ? Math.cbrt(Math.random()) : 1);
      [x, y, z] = [d[0] * r, d[1] * r, d[2] * r];
    } else if (p.shape === 3) {
      [x, y, z] = [rand(-1, 1) * p.box[0], rand(-1, 1) * p.box[1], rand(-1, 1) * p.box[2]];
    } else if (p.shape === 6) {
      const a = Math.random() * Math.PI * 2;
      const r = rand(p.ringInner, p.ringRadius);
      const h = rand(-0.5, 0.5) * p.ringHeight;
      tmpD.set(p.ringAxis[0], p.ringAxis[1], p.ringAxis[2]).normalize();
      tmpQ.setFromUnitVectors(Z, tmpD.lengthSq() ? tmpD : Z);
      tmpV.set(Math.cos(a) * r, Math.sin(a) * r, h).applyQuaternion(tmpQ);
      [x, y, z] = [tmpV.x, tmpV.y, tmpV.z];
    }
    x = x * p.shapeScale[0] + p.offset[0];
    y = y * p.shapeScale[1] + p.offset[1];
    z = z * p.shapeScale[2] + p.offset[2];
    // Direction inside the spread cone.
    tmpD.set(p.direction[0], p.direction[1], p.direction[2]);
    if (tmpD.lengthSq() < 1e-6) tmpD.set(1, 0, 0);
    tmpD.normalize();
    const spread = THREE.MathUtils.degToRad(Math.min(180, Math.max(0, p.spread)));
    const cosT = 1 - Math.random() * (1 - Math.cos(spread));
    const sinT = Math.sqrt(Math.max(0, 1 - cosT * cosT));
    const phi = Math.random() * Math.PI * 2;
    tmpQ.setFromUnitVectors(Z, tmpD);
    tmpV.set(Math.cos(phi) * sinT, Math.sin(phi) * sinT, cosT).applyQuaternion(tmpQ).multiplyScalar(rand(p.velMin, p.velMax));
    const radial = rand(p.radialMin, p.radialMax);
    if (radial) {
      tmpD.set(x - p.offset[0], y - p.offset[1], z - p.offset[2]);
      if (tmpD.lengthSq() > 1e-8) tmpV.addScaledVector(tmpD.normalize(), radial);
    }
    let s = rand(p.scaleMin, p.scaleMax);
    const o = i * 3;
    if (this.world) {
      tmpM.multiplyMatrices(root, this.nodeMatrix);
      const at = new THREE.Vector3(x, y, z).applyMatrix4(tmpM);
      tmpV.transformDirection(tmpM).multiplyScalar(tmpV.length() * rootScale || 0);
      [x, y, z] = [at.x, at.y, at.z];
      s *= rootScale;
    }
    this.pos[o] = x;
    this.pos[o + 1] = y;
    this.pos[o + 2] = z;
    this.vel[o] = tmpV.x;
    this.vel[o + 1] = tmpV.y;
    this.vel[o + 2] = tmpV.z;
    this.size[i] = s;
    this.ang[i] = THREE.MathUtils.degToRad(rand(p.angleMin, p.angleMax));
    this.seed[i] = Math.random();
    this.age[i] = 0;
    this.life[i] = this.node.lifetime ?? 1;
    this.alive[i] = 1;
  }

  update(dt: number, root: THREE.Matrix4, rootScale: number, camera: THREE.Camera) {
    const node = this.node;
    const p = node.process!;
    const L = node.lifetime ?? 1;
    if (this.emitting) {
      this.emitT += dt;
      const spacing = L * (1 - Math.min(1, Math.max(0, node.explosiveness ?? 0)));
      const oneShot = this.once || !!node.oneShot;
      for (let i = 0; i < this.n; i++) {
        const off = (i / this.n) * spacing;
        const a = Math.floor((this.prevT - off) / L);
        const b = Math.floor((this.emitT - off) / L);
        if (b > a && this.emitT >= off && (!oneShot || b === 0)) this.spawn(i, root, rootScale);
      }
      this.prevT = this.emitT;
      if (oneShot && this.emitT >= L) this.emitting = false;
    }
    const gScale = this.world ? rootScale : 1;
    const damp = (p.dampMin + p.dampMax) / 2;
    const col = this.color.array as Float32Array;
    const cus = this.custom.array as Float32Array;
    let n = 0;
    const view = camera.matrixWorldInverse;
    for (let i = 0; i < this.n; i++) {
      if (!this.alive[i]) continue;
      this.age[i] += dt;
      if (this.age[i] >= this.life[i]) {
        this.alive[i] = 0;
        continue;
      }
      const o = i * 3;
      let vx = this.vel[o], vy = this.vel[o + 1], vz = this.vel[o + 2];
      if (damp > 0) {
        const sp = Math.hypot(vx, vy, vz);
        if (sp > 1e-6) {
          const k = Math.max(0, sp - damp * gScale * dt) / sp;
          vx *= k, vy *= k, vz *= k;
        }
      }
      vx += p.gravity[0] * gScale * dt;
      vy += p.gravity[1] * gScale * dt;
      vz += p.gravity[2] * gScale * dt;
      this.vel[o] = vx, this.vel[o + 1] = vy, this.vel[o + 2] = vz;
      this.pos[o] += vx * dt;
      this.pos[o + 1] += vy * dt;
      this.pos[o + 2] += vz * dt;
      const k = this.age[i] / this.life[i];
      const s = Math.max(1e-4, this.size[i] * curveAt(p.scaleCurve, k));
      tmpV.set(this.pos[o], this.pos[o + 1], this.pos[o + 2]);
      let angle = this.ang[i];
      if (this.billboard) {
        tmpQ.identity();
        if (node.align === 3 || p.alignY) {
          // Y to velocity, in screen space.
          tmpD.set(vx, vy, vz).transformDirection(view);
          if (Math.abs(tmpD.x) + Math.abs(tmpD.y) > 1e-5) angle = Math.atan2(tmpD.y, tmpD.x) - Math.PI / 2;
        }
      } else if ((p.alignY || node.align === 2) && vx * vx + vy * vy + vz * vz > 1e-8) {
        tmpQ.setFromUnitVectors(UP, tmpD.set(vx, vy, vz).normalize());
      } else tmpQ.setFromAxisAngle(p.rotateY ? UP : Z, angle);
      tmpM.compose(tmpV, tmpQ, tmpS.set(s, s, s));
      this.mesh.setMatrixAt(n, tmpM);
      col[n * 4] = this.seed[i];
      col[n * 4 + 1] = 1;
      col[n * 4 + 2] = 1;
      col[n * 4 + 3] = p.alpha * curveAt(p.alphaCurve, k);
      cus[n * 4] = angle;
      cus[n * 4 + 1] = k;
      n++;
    }
    this.mesh.count = n;
    this.mesh.instanceMatrix.needsUpdate = true;
    this.color.needsUpdate = true;
    this.custom.needsUpdate = true;
  }

  dispose() {
    this.mat.dispose();
    // The index/position buffers belong to the shared geometry; only drop our own attributes.
    this.mesh.geometry.deleteAttribute('aColor');
    this.mesh.geometry.deleteAttribute('aCustom');
    this.mesh.dispose();
  }
}

type Part = MeshPart | ParticlePart;

/** A built effect (pooled per id). */
class Instance {
  readonly root = new THREE.Group();
  readonly parts: Part[] = [];
  readonly byName = new Map<string, Part[]>();
  readonly lights: NodeTemplate[] = [];
  readonly longest: number;

  constructor(readonly tpl: EffectTemplate) {
    this.root.matrixAutoUpdate = true;
    let longest = 0;
    for (const node of tpl.nodes) {
      let part: Part | null = null;
      if (node.type === 'particles') {
        const pp = new ParticlePart(node);
        if (!pp.world) this.root.add(pp.mesh);
        part = pp;
        longest = Math.max(longest, (node.lifetime ?? 1) * (node.oneShot ? 1 : 1));
      } else if (node.type === 'mesh' && node.shape) {
        // The converted toxic glow's overlay masks can light its square UV
        // corners even though the source shape is a round puddle.
        const mat = buildMaterial(node.material, node.shape, textureFor, tpl.id === 'toxic_puddle' && node.name === 'Glow');
        const mesh = new THREE.Mesh(geometryFor(node.shape), mat);
        mesh.matrixAutoUpdate = false;
        mesh.matrix.fromArray(node.matrix);
        mesh.frustumCulled = false;
        mesh.renderOrder = 6;
        mesh.visible = node.visible;
        this.root.add(mesh);
        part = { kind: 'mesh', node, mesh, mat };
      } else if (node.type === 'light') this.lights.push(node);
      if (part) {
        this.parts.push(part);
        const leaf = node.name.split('/').pop()!;
        for (const key of new Set([node.name, leaf])) {
          const list = this.byName.get(key) ?? [];
          list.push(part);
          this.byName.set(key, list);
        }
      }
    }
    this.longest = longest;
  }

  materials() {
    return this.parts.map((p) => p.mat);
  }

  dispose() {
    for (const p of this.parts) {
      if (p.kind === 'particles') p.dispose();
      else p.mat.dispose();
    }
    this.root.removeFromParent();
  }
}

class Live implements BinbunHandle {
  inst: Instance | null = null;
  t = 0;
  end = Infinity;
  fading = -1;
  dead = false;
  looping = false;
  culled = false;
  alphaMul = 1;
  readonly born: number;
  x: number;
  y: number;
  z: number;

  constructor(readonly owner: BinbunFX, readonly id: string, readonly o: BinbunSpawn, born: number) {
    this.born = born;
    this.x = o.x;
    this.y = o.y ?? 0;
    this.z = o.z;
    this.alphaMul = o.alpha ?? 1;
  }

  get alive() {
    return !this.dead;
  }

  kill() {
    if (this.dead) return;
    if (!this.inst) this.dead = true;
    else if (this.fading < 0) this.fading = 0;
  }

  move(x: number, y: number | undefined, z: number) {
    this.x = x;
    if (y !== undefined) this.y = y;
    this.z = z;
  }

  setAlpha(a: number) {
    this.alphaMul = a;
  }
}

export class BinbunFX {
  private live: Live[] = [];
  private pool = new Map<string, Instance[]>();
  private clock = 0;
  private frustum = new THREE.Frustum();
  private sphere = new THREE.Sphere();
  /** Effects built from this owner (pooled or live), disposed together. */
  private built = new Set<Instance>();
  enabled = true;

  constructor(private group: THREE.Group, private flash: LightFlash) {}

  /** Play an effect. Never throws and never waits: an unknown or failed id is a dead handle. */
  spawn(id: BinbunId, o: BinbunSpawn): BinbunHandle {
    const live = new Live(this, id, o, this.clock);
    if (!this.enabled) {
      live.dead = true;
      return live;
    }
    void loadBinbun(id);
    const t = ready.get(id);
    if (t === null) {
      live.dead = true;
      return live;
    }
    this.live.push(live);
    if (t) this.materialize(live, t);
    return live;
  }

  /** How many effects are playing (QA). */
  get count() {
    return this.live.filter((l) => !l.dead).length;
  }

  private isLooping(t: EffectTemplate, o: BinbunSpawn) {
    if (o.once) return false;
    if (t.animation && !t.animation.loop) return false;
    if (!t.animation && t.duration > 0 && t.nodes.every((n) => n.type !== 'particles' || n.oneShot)) return false;
    return !(t.animation?.name === 'oneshot');
  }

  private materialize(live: Live, t: EffectTemplate) {
    const looping = this.isLooping(t, live.o);
    // Late arrivals: a one-shot whose moment has passed is dropped rather than played stale.
    if (!looping && this.clock - live.born > 0.35) {
      live.dead = true;
      return;
    }
    const kind = this.live.filter((l) => l.inst && !l.dead && l.looping === looping);
    if (kind.length >= (looping ? MAX_LOOPERS : MAX_ONESHOTS)) {
      if (looping) {
        live.dead = true;
        return;
      }
      this.release(kind[0]);
    }
    const inst = this.pool.get(live.id)?.pop() ?? new Instance(t);
    this.built.add(inst);
    live.inst = inst;
    live.looping = looping;
    const o = live.o;
    const once = !!o.once;
    const animLen = t.animation?.length ?? 0;
    if (o.duration !== undefined) live.end = o.duration;
    else if (!looping) live.end = Math.max(once ? 0 : animLen, t.duration || 0, inst.longest + (once ? 0 : 0.05)) + 0.05;
    // Colours: spawn colours win, else the root's, else each material keeps its own.
    const colors = this.palette(o.colors ?? (t.colors.length ? t.colors : undefined));
    for (const part of inst.parts) {
      const d = part.mat.userData.defaults as Record<string, number>;
      for (const [k, v] of Object.entries(d)) part.mat.uniforms[k].value = v;
      part.mat.uniforms.uFade.value = live.alphaMul;
      if (colors) setColors(part.mat, colors);
      if (part.kind === 'particles') {
        part.reset(once);
        if (part.world) this.group.add(part.mesh);
      } else part.mesh.visible = part.node.visible;
    }
    inst.root.position.set(live.x, live.y, live.z);
    inst.root.rotation.set(0, o.rot ?? 0, 0);
    inst.root.scale.setScalar(o.scale ?? 1);
    inst.root.updateMatrixWorld(true);
    this.group.add(inst.root);
    // Lights: one flash through Effects (never a PointLight here). Loopers stay unlit.
    if (!looping) {
      for (const l of inst.lights) {
        const track = t.animation?.tracks.find((tr) => tr.prop === 'light' && inst.lights.length && (tr.node === l.name.split('/').pop() || tr.node === l.name));
        const peak = track ? Math.max(0, ...track.values.filter((v): v is number => typeof v === 'number')) || 1 : 1;
        const c = colors?.[0] ?? linear(l.lightColor);
        tmpV.fromArray(l.matrix, 12).multiplyScalar(o.scale ?? 1);
        this.flash(live.x + tmpV.x, live.y + tmpV.y + 0.6, live.z + tmpV.z, c, Math.min(8, (l.lightEnergy ?? 1) * peak * 1.2), Math.min(0.9, Math.max(0.25, animLen * 0.6 || 0.4)));
        break;
      }
    }
  }

  private palette(src: readonly (THREE.ColorRepresentation | number[])[] | undefined): THREE.Color[] | null {
    if (!src || !src.length) return null;
    const out = src.slice(0, 3).map((c) => (Array.isArray(c) ? linear(c) : new THREE.Color(c as THREE.ColorRepresentation)));
    while (out.length < 3) out.push(out[out.length - 1].clone().multiplyScalar(0.55));
    return out;
  }

  private release(live: Live) {
    live.dead = true;
    const inst = live.inst;
    live.inst = null;
    if (!inst) return;
    inst.root.removeFromParent();
    for (const p of inst.parts) if (p.kind === 'particles') p.mesh.removeFromParent();
    const list = this.pool.get(live.id) ?? [];
    if (list.length < 4) {
      list.push(inst);
      this.pool.set(live.id, list);
    } else {
      inst.dispose();
      this.built.delete(inst);
    }
  }

  update(dt: number, camera: THREE.Camera) {
    this.clock += dt;
    if (!this.live.length) return;
    this.frustum.setFromProjectionMatrix(tmpM.multiplyMatrices(camera.projectionMatrix, camera.matrixWorldInverse));
    const camPos = camera.getWorldPosition(tmpS);
    const camX = camPos.x;
    const camZ = camPos.z;
    for (let i = this.live.length - 1; i >= 0; i--) {
      const live = this.live[i];
      if (!live.dead && !live.inst) {
        const t = ready.get(live.id);
        if (t === null) live.dead = true;
        else if (t) this.materialize(live, t);
      }
      if (live.dead) {
        if (live.inst) this.release(live);
        this.live.splice(i, 1);
        continue;
      }
      const inst = live.inst;
      if (!inst) continue;
      if (live.o.follow) {
        const at = live.o.follow();
        if (!at) live.kill();
        else live.move(at.x, at.y, at.z);
      }
      live.t += dt;
      inst.root.position.set(live.x, live.y, live.z);
      inst.root.updateMatrixWorld(true);
      const scale = live.o.scale ?? 1;
      // Loopers far away or off-screen stop drawing and simulating.
      if (live.looping) {
        this.sphere.set(inst.root.position, 4 * scale);
        const far = Math.hypot(live.x - camX, live.z - camZ) > CULL_DISTANCE + Math.abs(camPos.y);
        live.culled = far || !this.frustum.intersectsSphere(this.sphere);
        inst.root.visible = !live.culled;
        for (const p of inst.parts) if (p.kind === 'particles' && p.world) p.mesh.visible = !live.culled;
        if (live.culled) continue;
      }
      if (live.t >= live.end && live.fading < 0) live.fading = live.looping || live.o.duration !== undefined ? 0 : FADE_OUT;
      let fade = live.alphaMul;
      if (live.fading >= 0) {
        live.fading += dt;
        fade *= Math.max(0, 1 - live.fading / FADE_OUT);
        for (const p of inst.parts) if (p.kind === 'particles') p.setEmitting(false);
      }
      this.animate(live, inst, fade);
      let busy = false;
      for (const p of inst.parts) {
        p.mat.uniforms.uTime.value = live.t;
        if (p.kind === 'particles') {
          p.update(dt, inst.root.matrixWorld, scale, camera);
          busy ||= p.busy;
        }
      }
      if (live.fading >= FADE_OUT && (!busy || live.fading > FADE_OUT + 2)) this.release(live), this.live.splice(i, 1);
      else if (!live.looping && live.t >= live.end + 0.05 && !busy) this.release(live), this.live.splice(i, 1);
    }
  }

  private animate(live: Live, inst: Instance, fade: number) {
    const a = inst.tpl.animation;
    let scriptFade = 1;
    let open = 1;
    if (a) {
      const t = a.loop && a.length > 0 ? live.t % a.length : live.t;
      for (const tr of a.tracks) {
        const v = trackAt(tr, t);
        if (v === undefined) continue;
        if (tr.prop === 'script') {
          if (typeof v === 'number') {
            if (tr.key === 'fade_mult') scriptFade = v;
            else if (tr.key === 'open_amount') open = v;
          }
          continue;
        }
        const parts = inst.byName.get(tr.node);
        if (!parts) continue;
        for (const p of parts) {
          if (tr.prop === 'emitting' && p.kind === 'particles' && typeof v === 'boolean') {
            // A one-shot track re-arms its emitter each loop; `once` never re-arms after the first cycle.
            if (v && !p.emitting && (!live.o.once || live.t < a.length)) p.setEmitting(true);
            else if (!v && p.emitting && !p.node.oneShot && !live.o.once) p.setEmitting(false);
          } else if (tr.prop === 'param' && typeof v === 'number') {
            const u = p.mat.uniforms[tr.key];
            if (u && typeof u.value === 'number') u.value = v;
          }
        }
      }
    }
    for (const p of inst.parts) p.mat.uniforms.uFade.value = fade * scriptFade;
    if (open !== 1) inst.root.scale.setScalar((live.o.scale ?? 1) * Math.max(0.001, open));
  }

  /** Stop everything (area change / scene teardown keeps the pools). */
  clear() {
    for (const l of this.live) this.release(l);
    this.live.length = 0;
  }

  dispose() {
    this.clear();
    for (const inst of this.built) inst.dispose();
    this.built.clear();
    this.pool.clear();
  }
}
