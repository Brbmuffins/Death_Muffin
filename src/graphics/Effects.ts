import * as THREE from 'three';
import { BinbunFX } from './binbun/BinbunFX';
import { fx } from './fxTextures';
import { assets } from './AssetCache';

type Vec3 = { x: number; y: number; z: number };

// ---------------------------------------------------------------------------
// Particles — one Points draw call per blend mode, CPU-simulated ring buffer.
// ---------------------------------------------------------------------------

const PARTICLE_VS = /* glsl */ `
  attribute float aSize;
  attribute float aAlpha;
  attribute vec3 aColor;
  varying float vAlpha;
  varying vec3 vColor;
  uniform float uScale;
  void main() {
    vec4 mv = modelViewMatrix * vec4(position, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = aSize * uScale / max(0.1, -mv.z);
    vAlpha = aAlpha;
    vColor = aColor;
  }
`;
const PARTICLE_FS = /* glsl */ `
  uniform sampler2D uMap;
  varying float vAlpha;
  varying vec3 vColor;
  void main() {
    vec4 t = texture2D(uMap, gl_PointCoord);
    if (t.a * vAlpha < 0.004) discard;
    gl_FragColor = vec4(vColor * t.rgb, t.a * vAlpha);
  }
`;

export interface EmitOptions {
  x: number;
  y: number;
  z: number;
  count: number;
  color: THREE.ColorRepresentation;
  /** Spawn jitter radius. */
  spread?: number;
  /** Radial speed. */
  speed?: number;
  /** Extra upward speed. */
  up?: number;
  life?: number;
  size?: number;
  gravity?: number;
  drag?: number;
  /** Shrink (1) or grow (-1) over life. */
  shrink?: number;
  /** Pull toward the emit point instead of bursting away (implosions). */
  inward?: boolean;
}

class ParticleSystem {
  readonly points: THREE.Points;
  private pos: Float32Array;
  private col: Float32Array;
  private size: Float32Array;
  private alpha: Float32Array;
  private vel: Float32Array;
  private life: Float32Array;
  private maxLife: Float32Array;
  private baseSize: Float32Array;
  private grav: Float32Array;
  private drag: Float32Array;
  private shrink: Float32Array;
  private cursor = 0;
  private active = 0;
  private material: THREE.ShaderMaterial;
  private tmp = new THREE.Color();

  constructor(private capacity: number, map: THREE.Texture, blending: THREE.Blending) {
    this.pos = new Float32Array(capacity * 3);
    this.col = new Float32Array(capacity * 3);
    this.size = new Float32Array(capacity);
    this.alpha = new Float32Array(capacity);
    this.vel = new Float32Array(capacity * 3);
    this.life = new Float32Array(capacity);
    this.maxLife = new Float32Array(capacity);
    this.baseSize = new Float32Array(capacity);
    this.grav = new Float32Array(capacity);
    this.drag = new Float32Array(capacity);
    this.shrink = new Float32Array(capacity);
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(this.pos, 3).setUsage(THREE.DynamicDrawUsage));
    geo.setAttribute('aColor', new THREE.BufferAttribute(this.col, 3).setUsage(THREE.DynamicDrawUsage));
    geo.setAttribute('aSize', new THREE.BufferAttribute(this.size, 1).setUsage(THREE.DynamicDrawUsage));
    geo.setAttribute('aAlpha', new THREE.BufferAttribute(this.alpha, 1).setUsage(THREE.DynamicDrawUsage));
    this.material = new THREE.ShaderMaterial({
      vertexShader: PARTICLE_VS,
      fragmentShader: PARTICLE_FS,
      uniforms: { uMap: { value: map }, uScale: { value: 400 } },
      transparent: true,
      depthWrite: false,
      blending,
    });
    this.points = new THREE.Points(geo, this.material);
    this.points.visible = false;
    this.points.frustumCulled = false;
    this.points.renderOrder = 5;
  }

  emit(o: EmitOptions) {
    if (o.count <= 0) return;
    this.tmp.set(o.color);
    for (let n = 0; n < o.count; n++) {
      const i = this.cursor;
      this.cursor = (this.cursor + 1) % this.capacity;
      if (this.life[i] <= 0) this.active++;
      const a = Math.random() * Math.PI * 2;
      const r = (o.spread ?? 0.2) * Math.sqrt(Math.random());
      this.pos[i * 3] = o.x + Math.cos(a) * r;
      this.pos[i * 3 + 1] = o.y + (Math.random() - 0.5) * (o.spread ?? 0.2) * 0.5;
      this.pos[i * 3 + 2] = o.z + Math.sin(a) * r;
      const sp = (o.speed ?? 1) * (0.4 + Math.random() * 0.8);
      const va = o.inward ? a + Math.PI : Math.random() * Math.PI * 2;
      this.vel[i * 3] = Math.cos(va) * sp;
      this.vel[i * 3 + 1] = (o.up ?? 0.5) * (0.5 + Math.random());
      this.vel[i * 3 + 2] = Math.sin(va) * sp;
      const l = (o.life ?? 0.8) * (0.7 + Math.random() * 0.6);
      this.life[i] = l;
      this.maxLife[i] = l;
      this.baseSize[i] = (o.size ?? 0.3) * (0.7 + Math.random() * 0.6);
      this.grav[i] = o.gravity ?? 0;
      this.drag[i] = o.drag ?? 1.5;
      this.shrink[i] = o.shrink ?? 1;
      this.col[i * 3] = this.tmp.r;
      this.col[i * 3 + 1] = this.tmp.g;
      this.col[i * 3 + 2] = this.tmp.b;
    }
    this.points.visible = true;
    (this.points.geometry.attributes.aColor as THREE.BufferAttribute).needsUpdate = true;
  }

  update(dt: number, scale: number) {
    this.material.uniforms.uScale.value = scale;
    if (this.active === 0) return;
    for (let i = 0; i < this.capacity; i++) {
      if (this.life[i] <= 0) {
        this.alpha[i] = 0;
        continue;
      }
      this.life[i] -= dt;
      if (this.life[i] <= 0) this.active--;
      const t = 1 - Math.max(0, this.life[i]) / this.maxLife[i];
      const k = Math.max(0, 1 - this.drag[i] * dt);
      this.vel[i * 3] *= k;
      this.vel[i * 3 + 1] = this.vel[i * 3 + 1] * k - this.grav[i] * dt;
      this.vel[i * 3 + 2] *= k;
      this.pos[i * 3] += this.vel[i * 3] * dt;
      this.pos[i * 3 + 1] += this.vel[i * 3 + 1] * dt;
      this.pos[i * 3 + 2] += this.vel[i * 3 + 2] * dt;
      this.alpha[i] = t < 0.15 ? t / 0.15 : 1 - (t - 0.15) / 0.85;
      const sh = this.shrink[i];
      this.size[i] = this.baseSize[i] * (sh >= 0 ? 1 - sh * t * 0.7 : 1 + -sh * t);
    }
    const g = this.points.geometry;
    this.points.visible = this.active > 0;
    (g.attributes.position as THREE.BufferAttribute).needsUpdate = true;
    (g.attributes.aSize as THREE.BufferAttribute).needsUpdate = true;
    (g.attributes.aAlpha as THREE.BufferAttribute).needsUpdate = true;
  }
}

// ---------------------------------------------------------------------------
// Pooled transient meshes (decals, billboards, beams)
// ---------------------------------------------------------------------------

export interface DecalOptions {
  tex?: THREE.Texture;
  color: THREE.ColorRepresentation;
  x: number;
  z: number;
  /** Half-extent in world units. */
  r: number;
  y?: number;
  rot?: number;
  duration: number;
  opacity?: number;
  fadeIn?: number;
  fadeOut?: number;
  /** Radius multiplier at start → 1 at end. */
  growFrom?: number;
  spin?: number;
  blending?: THREE.Blending;
  /** Rectangular decals (cones) — width/length multipliers. */
  sx?: number;
  sz?: number;
  /** Anchor offset along local +z (cones apex at origin). */
  anchor?: number;
  follow?: () => { x: number; z: number } | null;
  pulse?: number;
  /** Seconds before the decal appears (duration counts after the delay). */
  delay?: number;
  /** Scenery decals stay in place when combat fills the transient effect pool. */
  persistent?: boolean;
}

interface Transient {
  mesh: THREE.Mesh | THREE.Sprite;
  t: number;
  duration: number;
  update: (t: number, k: number, dt: number) => void;
  pool: THREE.Object3D[];
  persistent?: boolean;
}

export interface Handle {
  kill(): void;
  readonly alive: boolean;
}

interface Projectile {
  mesh: THREE.Object3D;
  /** Where the mesh returns when it lands. */
  pool: THREE.Object3D[];
  from: THREE.Vector3;
  to: () => Vec3 | null;
  lastTo: THREE.Vector3;
  speed: number;
  color: THREE.Color;
  trail: number;
  onArrive?: (p: THREE.Vector3) => void;
  onTrail?: (p: THREE.Vector3) => void;
  trailAt: number;
  arc: number;
  t: number;
  dist: number;
}

/** Bone Mantle: one ring of real bone fragments (instanced meshes), see boneOrbit(). */
interface BoneOrbit {
  count: number;
  radius: number;
  y: number;
  size: number;
  duration: number;
  speed: number;
  follow: () => { x: number; z: number } | null;
  t: number;
  cx: number;
  cz: number;
  seed: number;
  /** Bone Storm: stack the fragments into a widening funnel instead of a flat ring. */
  funnel?: boolean;
}

/** Grave Hands: skeletal hands clawing up out of a field (instanced Tripo prop). */
interface HandField {
  x: number;
  z: number;
  r: number;
  count: number;
  duration: number;
  t: number;
  seed: number;
}
const GRAVE_HAND_URL = 'models/props/grave_hand.glb';
const GRAVE_HAND_CAP = 64;

/** The three Tripo fragments (art-manifest/tripo-specs/prop_mantle_*.json), ~300 tris each. */
const BONE_SHARD_URLS = ['models/props/mantle_rib.glb', 'models/props/mantle_vertebra.glb', 'models/props/mantle_skullchip.glb'];
const BONE_SHARD_CAP = 96;

interface Spike {
  x: number;
  z: number;
  yaw: number;
  tilt: number;
  h: number;
  born: number;
  life: number;
}

/**
 * All transient visual effects, updated from the single runtime loop.
 */
export class Effects {
  readonly group = new THREE.Group();
  private additive: ParticleSystem;
  private smoke: ParticleSystem;
  private transients: Transient[] = [];
  /** How many entries in `transients` are combat visuals (not persistent scenery); capped at 160. */
  private combatTransients = 0;
  private decalPool: THREE.Object3D[] = [];
  private spritePool: THREE.Object3D[] = [];
  private beamPool: THREE.Object3D[] = [];
  private projectiles: Projectile[] = [];
  private needlePool: THREE.Mesh[] = [];
  private orbPool: THREE.Mesh[] = [];
  /** Textured billboard projectiles (the Wailing Skull). */
  private spriteShotPool: THREE.Sprite[] = [];
  private projectileDirection = new THREE.Vector3();
  private needleGeo = new THREE.ConeGeometry(0.085, 0.95, 5).rotateX(Math.PI / 2);
  private needleMat = new THREE.MeshStandardMaterial({
    color: 0xe8dfcc,
    emissive: 0xe9c98f,
    emissiveIntensity: 1.3,
    roughness: 0.5,
  });
  private orbGeo = new THREE.SphereGeometry(0.16, 10, 8);
  private spikes: Spike[] = [];
  private spikeMesh: THREE.InstancedMesh;
  private spikeDummy = new THREE.Object3D();
  /** Instanced bone fragments for Bone Mantle: three draw calls however many mantles are up. */
  private boneShards: THREE.InstancedMesh[] | null = null;
  private boneOrbits: BoneOrbit[] = [];
  private handMesh: THREE.InstancedMesh | null = null;
  private handFields: HandField[] = [];
  private time = 0;
  private lights: { light: THREE.PointLight; t: number; life: number; peak: number }[] = [];
  /** The converted BinbunVFX library (docs/BINBUN-VFX-PORT.md); fail-open, layered over the effects above. */
  readonly binbun: BinbunFX;

  constructor(scene: THREE.Scene) {
    this.additive = new ParticleSystem(3500, fx.glow(), THREE.AdditiveBlending);
    this.smoke = new ParticleSystem(900, fx.smoke(), THREE.NormalBlending);
    this.group.add(this.additive.points, this.smoke.points);
    const spikeGeo = new THREE.ConeGeometry(0.2, 1, 4).translate(0, 0.5, 0);
    this.spikeMesh = new THREE.InstancedMesh(
      spikeGeo,
      new THREE.MeshStandardMaterial({ color: 0xc9b99a, roughness: 0.85, metalness: 0, emissive: 0x3a0e10, emissiveIntensity: 0.5 }),
      320,
    );
    this.spikeMesh.count = 0;
    this.spikeMesh.castShadow = true;
    this.spikeMesh.frustumCulled = false;
    this.group.add(this.spikeMesh);
    // Fixed light count: toggling visibility would change NUM_POINT_LIGHTS and
    // force every lit material to recompile (visible hitches).
    for (let i = 0; i < 2; i++) {
      const light = new THREE.PointLight(0xa26bff, 0, 9, 1.6);
      this.group.add(light);
      this.lights.push({ light, t: 0, life: 0, peak: 0 });
    }
    scene.add(this.group);
    // Browser only (unit tests construct Effects under Node, where relative model URLs can't load).
    if (typeof document !== 'undefined') {
      void this.loadBoneShards();
      void this.loadGraveHands();
    }
    this.binbun = new BinbunFX(this.group, (x, y, z, color, intensity, life) => this.lightFlash(x, y, z, color, intensity, life));
  }

  /** Particles requested from the two rings since start (QA: how much of the load a layer is responsible for). */
  emitted = 0;

  emit(o: EmitOptions) {
    this.emitted += o.count;
    this.additive.emit(o);
  }

  /** Live decals/billboards/beams from combat (the pool is capped at 160; garnish backs off well before it). */
  get transientLoad() {
    return this.combatTransients;
  }

  /** Grave Hands fields currently clawing out of the ground. */
  get activeHandFields() {
    return this.handFields.length;
  }

  emitSmoke(o: EmitOptions) {
    this.emitted += o.count;
    this.smoke.emit(o);
  }

  private take<T extends THREE.Object3D>(pool: THREE.Object3D[], make: () => T): T {
    const m = (pool.pop() as T | undefined) ?? make();
    m.visible = true;
    this.group.add(m);
    return m;
  }

  private add(tr: Transient): Handle {
    // Scenery uses the same decal renderer but must not be evicted by a dense
    // fight. Bound only transient combat visuals; projectile callbacks are separate.
    // A running count keeps this off the hot path (no array walk per particle burst).
    if (!tr.persistent && this.combatTransients >= 160) {
      const oldest = this.transients.findIndex((item) => !item.persistent);
      const [old] = this.transients.splice(oldest, 1);
      this.combatTransients--;
      old.t = old.duration;
      old.mesh.visible = false;
      this.group.remove(old.mesh);
      old.pool.push(old.mesh);
    }
    tr.update(tr.t, tr.t / tr.duration, 0);
    this.transients.push(tr);
    if (!tr.persistent) this.combatTransients++;
    return {
      kill: () => {
        tr.t = tr.duration;
      },
      get alive() {
        return tr.t < tr.duration;
      },
    };
  }

  decal(o: DecalOptions): Handle {
    const mesh = this.take(this.decalPool, () => {
      const m = new THREE.Mesh(
        new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2),
        new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, side: THREE.DoubleSide }),
      );
      m.renderOrder = 2;
      return m;
    }) as THREE.Mesh;
    const mat = mesh.material as THREE.MeshBasicMaterial;
    mat.map = o.tex ?? fx.disc();
    mat.color.set(o.color);
    mat.blending = o.blending ?? THREE.AdditiveBlending;
    mat.needsUpdate = true;
    const base = o.opacity ?? 1;
    const fadeIn = o.fadeIn ?? 0.12;
    const fadeOut = o.fadeOut ?? 0.25;
    mesh.geometry.translate(0, 0, 0);
    const anchor = o.anchor ?? 0;
    let hidden = false;
    const place = () => {
      const f = o.follow?.();
      hidden = !!o.follow && !f;
      const x = f ? f.x : o.x;
      const z = f ? f.z : o.z;
      mesh.position.set(x + Math.sin(o.rot ?? 0) * anchor * o.r, o.y ?? 0.04, z + Math.cos(o.rot ?? 0) * anchor * o.r);
    };
    place();
    mesh.rotation.set(0, o.rot ?? 0, 0);
    const delay = o.delay ?? 0;
    if (delay) mat.opacity = 0;
    return this.add({
      mesh,
      t: -delay,
      duration: o.duration,
      pool: this.decalPool,
      persistent: o.persistent,
      update: (t, k) => {
        if (t < 0) {
          mat.opacity = 0;
          return;
        }
        if (o.follow) place();
        const grow = o.growFrom !== undefined ? o.growFrom + (1 - o.growFrom) * Math.min(1, k * 1.2) : 1;
        const s = o.r * 2 * grow;
        mesh.scale.set(s * (o.sx ?? 1), 1, s * (o.sz ?? 1));
        if (o.spin) mesh.rotation.y = (o.rot ?? 0) + o.spin * t;
        const inA = Math.min(1, t / fadeIn);
        const outA = Math.min(1, (o.duration - t) / fadeOut);
        const pulse = o.pulse ? 0.75 + 0.25 * Math.sin(t * o.pulse) : 1;
        mat.opacity = hidden ? 0 : base * Math.max(0, Math.min(inA, outA)) * pulse;
      },
    });
  }

  /** A short-lived tinted billboard; `rise` lifts it that many units over its life (skull and spirit wisps). */
  flash(o: { x: number; y: number; z: number; color: THREE.ColorRepresentation; size: number; duration: number; tex?: THREE.Texture; rise?: number; opacity?: number }) {
    const sprite = this.take(this.spritePool, () => {
      const s = new THREE.Sprite(
        new THREE.SpriteMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }),
      );
      s.renderOrder = 6;
      return s;
    }) as THREE.Sprite;
    const mat = sprite.material;
    mat.map = o.tex ?? fx.glow();
    mat.color.set(o.color);
    mat.rotation = 0;
    mat.needsUpdate = true;
    sprite.position.set(o.x, o.y, o.z);
    return this.add({
      mesh: sprite,
      t: 0,
      duration: o.duration,
      pool: this.spritePool,
      update: (_t, k) => {
        const s = o.size * (0.35 + 0.65 * Math.sin(Math.min(1, k * 1.4) * Math.PI * 0.5));
        sprite.scale.set(s, s, s);
        if (o.rise) sprite.position.y = o.y + o.rise * k;
        mat.opacity = (o.opacity ?? 1) * (k < 0.3 ? 1 : 1 - (k - 0.3) / 0.7);
      },
    });
  }

  /**
   * Tinted sprites circling a moving point (Bone Mantle's shards). They spiral out
   * from the centre, bob and spin; `follow` returning null freezes them where they were.
   */
  orbit(o: {
    tex: THREE.Texture;
    color: THREE.ColorRepresentation;
    count: number;
    radius: number;
    y: number;
    size: number;
    duration: number;
    /** Radians per second. */
    speed: number;
    follow: () => { x: number; z: number } | null;
  }): Handle {
    const handles: Handle[] = [];
    let cx = 0;
    let cz = 0;
    const first = o.follow();
    if (first) [cx, cz] = [first.x, first.z];
    for (let i = 0; i < o.count; i++) {
      const sprite = this.take(this.spritePool, () => {
        const s = new THREE.Sprite(
          new THREE.SpriteMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }),
        );
        s.renderOrder = 6;
        return s;
      }) as THREE.Sprite;
      const mat = sprite.material;
      mat.map = o.tex;
      mat.color.set(o.color);
      mat.needsUpdate = true;
      const phase = (i / o.count) * Math.PI * 2;
      const lift = (i % 3) * 0.28;
      handles.push(this.add({
        mesh: sprite,
        t: 0,
        duration: o.duration,
        pool: this.spritePool,
        update: (t) => {
          const f = o.follow();
          if (f) [cx, cz] = [f.x, f.z];
          const a = phase + t * o.speed;
          const r = o.radius * Math.min(1, 0.25 + t * 3);
          sprite.position.set(cx + Math.cos(a) * r, o.y + lift + Math.sin(t * 3.1 + phase) * 0.12, cz + Math.sin(a) * r);
          mat.rotation = a * 1.7;
          sprite.scale.set(o.size, o.size, o.size);
          mat.opacity = Math.max(0, Math.min(1, t / 0.15, (o.duration - t) / 0.35));
        },
      }));
    }
    return {
      kill: () => handles.forEach((h) => h.kill()),
      get alive() {
        return handles.some((h) => h.alive);
      },
    };
  }

  /**
   * One small Tripo prop as an InstancedMesh: node transform baked, fitted to a unit box (centred, or
   * with its base at y=0), matte (Tripo PBR comes out mostly metallic), faintly warm so it never glows.
   */
  private async instancedProp(url: string, cap: number, base = false): Promise<THREE.InstancedMesh | null> {
    const t = await assets.model(url, 1);
    if (!t) return null;
    let src: THREE.Mesh | null = null;
    t.scene.updateMatrixWorld(true);
    t.scene.traverse((o) => {
      if (!src && (o as THREE.Mesh).isMesh) src = o as THREE.Mesh;
    });
    if (!src) return null;
    const mesh = src as THREE.Mesh;
    const geo = mesh.geometry.clone().applyMatrix4(mesh.matrixWorld);
    geo.computeBoundingBox();
    const box = geo.boundingBox!;
    const c = box.getCenter(new THREE.Vector3());
    const size = box.getSize(new THREE.Vector3());
    geo.translate(-c.x, base ? -box.min.y : -c.y, -c.z);
    const k = 1 / Math.max(base ? size.y : Math.max(size.x, size.y, size.z), 1e-4);
    geo.scale(k, k, k);
    const mat = (mesh.material as THREE.MeshStandardMaterial).clone();
    mat.metalness = 0.02;
    mat.roughness = 0.85;
    mat.emissive = new THREE.Color(0x2a2118);
    mat.emissiveIntensity = 0.6;
    const im = new THREE.InstancedMesh(geo, mat, cap);
    im.count = 0;
    im.frustumCulled = false;
    im.castShadow = false;
    this.group.add(im);
    return im;
  }

  private async loadBoneShards() {
    const meshes = await Promise.all(BONE_SHARD_URLS.map((u) => this.instancedProp(u, BONE_SHARD_CAP)));
    if (meshes.every(Boolean)) this.boneShards = meshes as THREE.InstancedMesh[];
    else meshes.forEach((m) => m && this.group.remove(m)); // stays on the sprite fallback
  }

  private async loadGraveHands() {
    this.handMesh = await this.instancedProp(GRAVE_HAND_URL, GRAVE_HAND_CAP, true);
    // A little more lift than the shards: the hands stand on dark earth and must still read.
    const m = this.handMesh?.material as THREE.MeshStandardMaterial | undefined;
    if (m) m.emissiveIntensity = 1.1;
  }

  /** Bone Prison: a ring of bone spikes bursting up around a point, leaning inward like a cage. */
  spikeRing(x: number, z: number, r: number, count: number, life = 1.9) {
    for (let i = 0; i < count; i++) {
      const a = (i / count) * Math.PI * 2 + Math.random() * 0.2;
      this.spikes.push({
        x: x + Math.sin(a) * r,
        z: z + Math.cos(a) * r,
        yaw: a + Math.PI / 2,
        tilt: -0.35 - Math.random() * 0.15,
        h: 0.75 + Math.random() * 0.45,
        born: this.time + i * 0.012,
        life,
      });
    }
    if (this.spikes.length > 300) this.spikes.splice(0, this.spikes.length - 300);
  }

  /**
   * Grave Hands: skeletal hands claw up out of the field, grasp, and sink. One InstancedMesh (one draw
   * call) for every field; falls back to short bone spikes until the prop has loaded.
   */
  graveHands(x: number, z: number, r: number, count: number, duration: number): Handle {
    if (!this.handMesh) {
      for (let i = 0; i < Math.min(count, 12); i++) {
        const a = Math.random() * Math.PI * 2;
        const d = Math.sqrt(Math.random()) * r;
        this.spikes.push({ x: x + Math.sin(a) * d, z: z + Math.cos(a) * d, yaw: Math.random() * 3, tilt: (Math.random() - 0.5) * 0.5, h: 0.6, born: this.time + i * 0.05, life: duration });
      }
      return { kill: () => {}, alive: false };
    }
    const field: HandField = { x, z, r, count: Math.min(count, GRAVE_HAND_CAP), duration, t: 0, seed: Math.random() * 100 };
    this.handFields.push(field);
    return {
      kill: () => {
        field.t = Math.max(field.t, field.duration - 0.3);
      },
      get alive() {
        return field.t < field.duration;
      },
    };
  }

  private updateGraveHands(dt: number) {
    const im = this.handMesh;
    if (!im) return;
    let n = 0;
    const d = this.spikeDummy;
    for (let k = this.handFields.length - 1; k >= 0; k--) {
      const f = this.handFields[k];
      f.t += dt;
      if (f.t >= f.duration) {
        this.handFields.splice(k, 1);
        continue;
      }
      for (let i = 0; i < f.count && n < GRAVE_HAND_CAP; i++) {
        // Stable per-hand spot (golden-angle spiral) and a staggered rise.
        const a = i * 2.39996 + f.seed;
        const dist = f.r * Math.sqrt((i + 0.5) / f.count) * 0.92;
        const born = (i % 6) * 0.07;
        const age = f.t - born;
        if (age <= 0) continue;
        const rise = Math.min(1, age / 0.25) * Math.min(1, (f.duration - f.t) / 0.35);
        const grasp = Math.sin(age * 5 + i) * 0.18;
        d.position.set(f.x + Math.sin(a) * dist, -0.75 * (1 - rise), f.z + Math.cos(a) * dist);
        d.rotation.set(grasp + 0.12 * Math.sin(i), a * 1.7, grasp * 0.6);
        d.scale.setScalar(0.95 + (i % 3) * 0.12);
        d.updateMatrix();
        im.setMatrixAt(n++, d.matrix);
      }
    }
    if (im.count === 0 && n === 0) return;
    im.count = n;
    im.instanceMatrix.needsUpdate = true;
  }

  /**
   * Bone Mantle's orbit: real bone fragments (rib splinter, vertebra, skull chip)
   * tumbling around a moving point. Lit, opaque, no additive glow. Falls back
   * to the sprite orbit until the three tiny GLBs have loaded.
   */
  boneOrbit(o: { count: number; radius: number; y: number; size: number; duration: number; speed: number; follow: () => { x: number; z: number } | null; fallbackTex: THREE.Texture; fallbackColor: THREE.ColorRepresentation; funnel?: boolean }): Handle {
    if (!this.boneShards) return this.orbit({ ...o, tex: o.fallbackTex, color: o.fallbackColor });
    const first = o.follow();
    const orbit: BoneOrbit = { count: o.count, radius: o.radius, y: o.y, size: o.size, duration: o.duration, speed: o.speed, follow: o.follow, t: 0, cx: first?.x ?? 0, cz: first?.z ?? 0, seed: Math.random() * 100, funnel: o.funnel };
    this.boneOrbits.push(orbit);
    return {
      kill: () => {
        orbit.t = orbit.duration;
      },
      get alive() {
        return orbit.t < orbit.duration;
      },
    };
  }

  private updateBoneOrbits(dt: number) {
    const meshes = this.boneShards;
    if (!meshes) return;
    const n = [0, 0, 0];
    const d = this.spikeDummy;
    for (let k = this.boneOrbits.length - 1; k >= 0; k--) {
      const o = this.boneOrbits[k];
      o.t += dt;
      if (o.t >= o.duration) {
        this.boneOrbits.splice(k, 1);
        continue;
      }
      const f = o.follow();
      if (f) [o.cx, o.cz] = [f.x, f.z];
      const r = o.radius * Math.min(1, 0.25 + o.t * 3);
      // Scale in fast, out at the end (opaque meshes don't fade).
      const grow = Math.max(0, Math.min(1, o.t / 0.15, (o.duration - o.t) / 0.35));
      for (let i = 0; i < o.count; i++) {
        const type = i % 3;
        if (n[type] >= BONE_SHARD_CAP) continue;
        const phase = (i / o.count) * Math.PI * 2;
        const s = o.seed + i * 1.7;
        // Funnel (Bone Storm): five tiers, wider and slower toward the top.
        const tier = o.funnel ? (i % 5) / 4 : 0;
        const a = phase * (o.funnel ? 2.3 : 1) + o.t * o.speed * (o.funnel ? 1.4 - tier * 0.6 : 1);
        const rr = o.funnel ? r * (0.35 + tier * 0.75) : r;
        const y = o.funnel ? o.y + tier * 2.1 : o.y + (i % 3) * 0.28;
        d.position.set(o.cx + Math.cos(a) * rr, y + Math.sin(o.t * 3.1 + phase) * 0.12, o.cz + Math.sin(a) * rr);
        d.rotation.set(s + o.t * (1.3 + (i % 4) * 0.4), -a, s * 0.7 + o.t * 0.9);
        d.scale.setScalar(o.size * (type === 0 ? 1.15 : 0.8) * grow);
        d.updateMatrix();
        meshes[type].setMatrixAt(n[type]++, d.matrix);
      }
    }
    for (let i = 0; i < 3; i++) {
      if (meshes[i].count === 0 && n[i] === 0) continue;
      meshes[i].count = n[i];
      meshes[i].instanceMatrix.needsUpdate = true;
    }
  }

  /** Glowing tether from A to B (litany tethers, deacon raise beams). */
  /** `a` may also follow a moving anchor (Soul Siphon's caster end). */
  beam(a: Vec3 | (() => Vec3 | null), b: () => Vec3 | null, color: THREE.ColorRepresentation, width: number, duration: number) {
    const mesh = this.take(this.beamPool, () => {
      const m = new THREE.Mesh(
        new THREE.CylinderGeometry(1, 1, 1, 6, 1, true).rotateX(Math.PI / 2),
        new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }),
      );
      m.renderOrder = 6;
      return m;
    }) as THREE.Mesh;
    const mat = mesh.material as THREE.MeshBasicMaterial;
    mat.color.set(color);
    const pa = new THREE.Vector3();
    const pb = new THREE.Vector3();
    return this.add({
      mesh,
      t: 0,
      duration,
      pool: this.beamPool,
      update: (t, k) => {
        const end = b();
        const start = typeof a === 'function' ? a() : a;
        if (!end || !start) {
          mat.opacity = 0;
          return;
        }
        pa.set(start.x, start.y, start.z);
        pb.set(end.x, end.y, end.z);
        const len = pa.distanceTo(pb);
        mesh.position.copy(pa).lerp(pb, 0.5);
        mesh.lookAt(pb);
        const w = width * (0.7 + 0.3 * Math.sin(t * 30));
        mesh.scale.set(w, w, len);
        mat.opacity = Math.min(1, (1 - k) * 2);
      },
    });
  }

  /** Transient coloured light for big casts. */
  lightFlash(x: number, y: number, z: number, color: THREE.ColorRepresentation, intensity: number, life = 0.35) {
    const slot = this.lights.reduce((a, b) => (a.t / (a.life || 1) > b.t / (b.life || 1) ? a : b));
    slot.light.position.set(x, y, z);
    slot.light.color.set(color);
    slot.t = 0;
    slot.life = life;
    slot.peak = intensity;
  }

  projectile(o: {
    from: Vec3;
    to: () => Vec3 | null;
    speed: number;
    color: THREE.ColorRepresentation;
    /** 'sprite' flies a tinted billboard (`tex`, `size` world units wide). */
    kind: 'needle' | 'orb' | 'sprite';
    tex?: THREE.Texture;
    size?: number;
    arc?: number;
    onArrive?: (p: THREE.Vector3) => void;
    /** Called about every 70 ms in flight with the shot's position (a trail of motes behind it). */
    onTrail?: (p: THREE.Vector3) => void;
  }) {
    let mesh: THREE.Object3D;
    let pool: THREE.Object3D[];
    if (o.kind === 'sprite') {
      const s = this.spriteShotPool.pop() ?? new THREE.Sprite(
        new THREE.SpriteMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }),
      );
      s.renderOrder = 6;
      s.material.map = o.tex ?? fx.glow();
      s.material.color.set(o.color);
      s.material.needsUpdate = true;
      const size = o.size ?? 0.8;
      s.scale.set(size, size, size);
      mesh = s;
      pool = this.spriteShotPool;
    } else if (o.kind === 'needle') {
      mesh = this.needlePool.pop() ?? new THREE.Mesh(this.needleGeo, this.needleMat);
      pool = this.needlePool;
    } else {
      const orb = this.orbPool.pop() ?? new THREE.Mesh(
        this.orbGeo,
        new THREE.MeshBasicMaterial({ transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }),
      );
      (orb.material as THREE.MeshBasicMaterial).color.set(o.color);
      mesh = orb;
      pool = this.orbPool;
    }
    mesh.visible = true;
    mesh.position.set(o.from.x, o.from.y, o.from.z);
    this.group.add(mesh);
    const first = o.to();
    const lastTo = new THREE.Vector3(first?.x ?? o.from.x, first?.y ?? o.from.y, first?.z ?? o.from.z);
    const rec: Projectile = {
      mesh,
      pool,
      from: new THREE.Vector3(o.from.x, o.from.y, o.from.z),
      to: o.to,
      lastTo,
      speed: o.speed,
      color: new THREE.Color(o.color),
      trail: 0,
      onArrive: o.onArrive,
      onTrail: o.onTrail,
      trailAt: 0,
      arc: o.arc ?? 0,
      t: 0,
      dist: Math.max(0.1, lastTo.distanceTo(new THREE.Vector3(o.from.x, o.from.y, o.from.z))),
    };
    this.projectiles.push(rec);
    // Lets a layered effect (a Binbun core) ride the shot: `pos()` is null once it has landed.
    const flying = () => this.projectiles.includes(rec);
    return { pos: () => (flying() ? { x: rec.mesh.position.x, y: rec.mesh.position.y, z: rec.mesh.position.z } : null) };
  }

  /** A line of bone spikes erupting sequentially (Marrow Spear). */
  spikeLine(x: number, z: number, dirX: number, dirZ: number, length: number, width: number, sequential = true) {
    const yaw = Math.atan2(dirX, dirZ);
    const n = Math.round(length / 0.55);
    for (let i = 0; i < n; i++) {
      const d = 0.8 + i * 0.55;
      for (let j = 0; j < 2; j++) {
        const side = (Math.random() - 0.5) * width;
        this.spikes.push({
          x: x + dirX * d + Math.cos(yaw) * side,
          z: z + dirZ * d - Math.sin(yaw) * side,
          yaw: Math.random() * Math.PI,
          tilt: (Math.random() - 0.5) * 0.7,
          h: 0.8 + Math.random() * 0.9 + (i / n) * 0.4,
          born: this.time + (sequential ? i * 0.018 : 0),
          life: 0.7,
        });
      }
    }
    if (this.spikes.length > 300) this.spikes.splice(0, this.spikes.length - 300);
  }

  update(dt: number, camera: THREE.PerspectiveCamera, viewportHeight: number) {
    this.time += dt;
    const scale = (viewportHeight * 0.5) / Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2);
    this.additive.update(dt, scale);
    this.smoke.update(dt, scale);
    this.binbun.update(dt, camera);

    for (let i = this.transients.length - 1; i >= 0; i--) {
      const tr = this.transients[i];
      tr.t += dt;
      if (tr.t >= tr.duration) {
        tr.mesh.visible = false;
        this.group.remove(tr.mesh);
        tr.pool.push(tr.mesh);
        this.transients.splice(i, 1);
        if (!tr.persistent) this.combatTransients--;
        continue;
      }
      tr.update(tr.t, tr.t / tr.duration, dt);
    }

    for (let i = this.projectiles.length - 1; i >= 0; i--) {
      const p = this.projectiles[i];
      const target = p.to();
      if (target) p.lastTo.set(target.x, target.y, target.z);
      const pos = p.mesh.position;
      const toVec = this.projectileDirection.subVectors(p.lastTo, pos);
      const d = toVec.length();
      const step = p.speed * dt;
      p.t += dt;
      const arcProgress = Math.min(1, p.t * p.speed / p.dist);
      if ((p.arc ? arcProgress >= 1 : d <= step) || p.t > 3) {
        pos.copy(p.lastTo);
        this.group.remove(p.mesh);
        const mesh = p.mesh as THREE.Mesh;
        if (p.pool.length < 64) p.pool.push(mesh);
        else if (mesh.material !== this.needleMat) (mesh.material as THREE.Material).dispose();
        this.projectiles.splice(i, 1);
        p.onArrive?.(pos.clone());
        continue;
      }
      if (p.arc) {
        // Time-based travel keeps the arc from slowing itself down as its
        // raised visual position changes the remaining 3D distance.
        pos.copy(p.from).lerp(p.lastTo, arcProgress);
        pos.y += Math.sin(arcProgress * Math.PI) * p.arc * 0.1;
      } else pos.add(toVec.multiplyScalar(step / Math.max(0.001, d)));
      p.mesh.lookAt(p.lastTo);
      p.trail += dt;
      if (p.trail > 0.024) {
        p.trail = 0;
        this.additive.emit({ x: pos.x, y: pos.y, z: pos.z, count: 1, color: p.color, spread: 0.05, speed: 0.15, up: 0.1, life: 0.28, size: 0.32 });
      }
      if (p.onTrail && p.t - p.trailAt >= 0.07) {
        p.trailAt = p.t;
        p.onTrail(pos);
      }
    }

    // Spikes: rise fast, hold, sink.
    let n = 0;
    for (let i = this.spikes.length - 1; i >= 0; i--) {
      const s = this.spikes[i];
      const age = this.time - s.born;
      if (age > s.life) {
        this.spikes.splice(i, 1);
        continue;
      }
      if (age < 0) continue;
      const rise = age < 0.08 ? age / 0.08 : age > s.life - 0.25 ? (s.life - age) / 0.25 : 1;
      this.spikeDummy.position.set(s.x, -0.1, s.z);
      this.spikeDummy.rotation.set(s.tilt, s.yaw, s.tilt * 0.5);
      this.spikeDummy.scale.set(1, Math.max(0.01, s.h * rise), 1);
      this.spikeDummy.updateMatrix();
      this.spikeMesh.setMatrixAt(n++, this.spikeDummy.matrix);
    }
    this.spikeMesh.count = n;
    this.spikeMesh.instanceMatrix.needsUpdate = true;
    this.updateBoneOrbits(dt);
    this.updateGraveHands(dt);

    for (const l of this.lights) {
      if (l.life <= 0) continue;
      l.t += dt;
      const k = l.t / l.life;
      if (k >= 1) {
        l.life = 0;
        l.light.intensity = 0;
      } else l.light.intensity = l.peak * (1 - k) * (1 - k);
    }
  }

  dispose() {
    this.binbun.dispose();
    const geometries = new Set<THREE.BufferGeometry>();
    const materials = new Set<THREE.Material>();
    const collect = (o: THREE.Object3D) => {
      const m = o as THREE.Mesh;
      if (m.geometry) geometries.add(m.geometry);
      const mat = m.material as THREE.Material | THREE.Material[] | undefined;
      if (Array.isArray(mat)) mat.forEach((x) => materials.add(x));
      else if (mat) materials.add(mat);
    };
    this.group.traverse(collect);
    // Expired pooled meshes are no longer children of the scene group, but
    // their GPU resources still belong to this Effects instance.
    for (const pool of [this.decalPool, this.spritePool, this.beamPool, this.needlePool, this.orbPool, this.spriteShotPool]) {
      for (const mesh of pool) collect(mesh);
      pool.length = 0;
    }
    geometries.add(this.needleGeo);
    geometries.add(this.orbGeo);
    materials.add(this.needleMat);
    for (const geometry of geometries) geometry.dispose();
    for (const material of materials) material.dispose();
    this.projectiles.length = 0;
    this.transients.length = 0;
    this.group.removeFromParent();
  }
}
