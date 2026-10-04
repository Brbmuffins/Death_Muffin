import * as THREE from 'three';
import { BinbunFX } from './binbun/BinbunFX';
import { fx } from './fxTextures';
import { assets } from './AssetCache';
import { settings } from '../app/settings';
import { hitstop } from './hitstop';
import { BeamLayer, SpriteLayer, footprintGeometry, type BeamInstance, type SpriteInstance } from './fxLayers';

type Vec3 = { x: number; y: number; z: number };

/** Share of each particle burst drawn on Graphics: Low. */
const LOW_PARTICLE_SCALE = 0.75;
/** Shared transient point lights for big casts. Fixed at runtime: a change of light count recompiles every lit material. */
const FLASH_LIGHTS = 1;

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
    // A particle the fragment stage would discard (alpha < 0.004) is clipped here instead: it used to be rasterised at its last
    // size and shaded for nothing, a few screens' worth of fill once a fight had filled the ring.
    if (aAlpha < 0.004) {
      gl_Position = vec4(2.0, 2.0, 2.0, 1.0);
      gl_PointSize = 0.0;
      return;
    }
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
      if (this.life[i] <= 0) {
        this.active--;
        // Dead: zero size and alpha so the last upload leaves nothing for the vertex stage to keep (see PARTICLE_VS).
        this.alpha[i] = 0;
        this.size[i] = 0;
        continue;
      }
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
  /** A ground marker that hurts the player (windup ring, cone, hostile pool): drawn above every friendly decal, never faded. Also set for everything made inside `Effects.danger()`. */
  danger?: boolean;
  /** The hero's own ground marker: above friendly decals, below danger ones. */
  hero?: boolean;
  /** Draw as another player's decal (faint, outline-only) even outside their events: their thralls' rings. */
  other?: boolean;
}

/** How a decal reads on the floor (see `Effects.decal`). */
export type DecalRole = 'self' | 'other';

/** Render order of the decal layers: friendly ground effects, then the hero marker, then danger telegraphs (particles are 5). */
export const DECAL_ORDER = { friendly: 2, hero: 3, danger: 4 } as const;
/** Own long-lasting areas keep their full look this long, then ease to an outline over FADE_S. */
export const OUTLINE_AFTER_S = 0.6;
export const OUTLINE_FADE_S = 0.7;
/** A disc's outline is the ring texture drawn this much larger (ring peaks at 0.71 of its half-width, the disc's rim at 0.94). */
const RING_FOR_DISC = 1.32;
/** Only decals that last longer than this go outline-only. */
export const LONG_DECAL_S = 1.5;
/** Another player's decals: opacity multiplier (fills are dropped entirely, outline only). */
export const OTHER_DECAL_ALPHA = 0.28;
/** Another player's Binbun effects: alpha and scale. */
export const OTHER_BINBUN_ALPHA = 0.35;
export const OTHER_BINBUN_SCALE = 0.75;
/**
 * Per-texture outline profile: radius (0..1 of the texture) from which the texture is its "edge"; the interior left
 * behind keeps `floor` of its opacity (0 = outline only). Textures with no edge (glow, cracks) just dim to `floor`.
 */
interface OutlineProfile {
  edge: number;
  floor: number;
}

interface Transient {
  /** Pooled scene object, or none for an instance in a decal layer (`release` frees that). */
  mesh?: THREE.Mesh | THREE.Sprite;
  t: number;
  duration: number;
  update: (t: number, k: number, dt: number) => void;
  pool?: THREE.Object3D[];
  release?: () => void;
  persistent?: boolean;
}

/** One live decal's per-frame state, written by its transient and flushed into its layer's instance buffers. */
interface DecalInstance {
  x: number;
  y: number;
  z: number;
  rotY: number;
  sx: number;
  sz: number;
  color: THREE.Color;
  opacity: number;
  /** 0 = the full texture, 1 = outline only (see OutlineProfile). */
  rim: number;
}

/**
 * Every live decal with one texture + blend mode, drawn as one InstancedMesh (per-instance colour and opacity).
 * Decals used to be a mesh and material each: ~160 of a fight's ~280 draw calls were two-triangle ground decals.
 */
class DecalLayer {
  readonly items: DecalInstance[] = [];
  /** Seconds the layer has had nothing to draw; long-idle layers are freed (one-off textures must not pile up). */
  idleS = 0;
  mesh: THREE.InstancedMesh;
  private readonly material: THREE.MeshBasicMaterial;
  private opacity!: THREE.InstancedBufferAttribute;
  private rimAttr!: THREE.InstancedBufferAttribute;
  private static readonly geometry = new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2);
  private static discGeometry: THREE.BufferGeometry | null = null;
  private static ringGeometry: THREE.BufferGeometry | null = null;
  private static readonly m = new THREE.Matrix4();
  private static readonly q = new THREE.Quaternion();
  private static readonly p = new THREE.Vector3();
  private static readonly s = new THREE.Vector3();
  private static readonly up = new THREE.Vector3(0, 1, 0);

  /** `shape`: radial textures (disc / glow / sigil / cracks) draw on a 16-gon, the ring texture on its annulus: same lit pixels, a fraction of the fill. */
  constructor(private readonly parent: THREE.Group, map: THREE.Texture, blending: THREE.Blending, private readonly shape: 'quad' | 'disc' | 'ring' = 'quad', order: number = DECAL_ORDER.friendly, private readonly outline: OutlineProfile | null = null, private capacity = 32) {
    this.order = order;
    this.material = new THREE.MeshBasicMaterial({ map, transparent: true, depthWrite: false, side: THREE.DoubleSide, blending });
    // Per-instance opacity (instanceColor already carries the tint) and, on the radial textures, a per-instance outline amount.
    const edge = outline?.edge ?? 2;
    const floor = outline?.floor ?? 1;
    this.material.onBeforeCompile = (shader) => {
      // The edge radius and interior floor are per-layer uniforms, so every decal layer shares ONE shader program.
      shader.uniforms.uRimEdge = { value: edge };
      shader.uniforms.uRimFloor = { value: floor };
      shader.vertexShader = shader.vertexShader
        .replace('#include <common>', '#include <common>\nattribute float aDecalOpacity;\nattribute float aDecalRim;\nvarying float vDecalOpacity;\nvarying float vDecalRim;')
        .replace('#include <begin_vertex>', '#include <begin_vertex>\nvDecalOpacity = aDecalOpacity;\nvDecalRim = aDecalRim;');
      shader.fragmentShader = shader.fragmentShader
        .replace('#include <common>', '#include <common>\nvarying float vDecalOpacity;\nvarying float vDecalRim;\nuniform float uRimEdge;\nuniform float uRimFloor;')
        .replace('#include <map_fragment>', `#include <map_fragment>
diffuseColor.a *= vDecalOpacity;
if (vDecalRim > 0.0) {
  float rr = length(vMapUv - 0.5) * 2.0;
  float inner = 1.0 - smoothstep(uRimEdge - 0.06, uRimEdge + 0.03, rr);
  diffuseColor.a *= 1.0 - vDecalRim * inner * (1.0 - uRimFloor);
  if (diffuseColor.a < 0.004) discard;
}`);
    };
    this.material.customProgramCacheKey = () => 'dm-decal-layer-rim';
    this.mesh = this.make();
  }

  private readonly order: number;

  private make() {
    const base = this.shape === 'disc' ? (DecalLayer.discGeometry ??= footprintGeometry('disc', 'xz')) : this.shape === 'ring' ? (DecalLayer.ringGeometry ??= footprintGeometry('ring', 'xz')) : DecalLayer.geometry;
    const geo = base.clone();
    this.opacity = new THREE.InstancedBufferAttribute(new Float32Array(this.capacity), 1);
    this.opacity.setUsage(THREE.DynamicDrawUsage);
    geo.setAttribute('aDecalOpacity', this.opacity);
    this.rimAttr = new THREE.InstancedBufferAttribute(new Float32Array(this.capacity), 1);
    this.rimAttr.setUsage(THREE.DynamicDrawUsage);
    geo.setAttribute('aDecalRim', this.rimAttr);
    const mesh = new THREE.InstancedMesh(geo, this.material, this.capacity);
    mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    mesh.setColorAt(0, new THREE.Color());
    mesh.instanceColor!.setUsage(THREE.DynamicDrawUsage);
    mesh.count = 0;
    // A few hundred triangles spread around the player: cheaper to draw than to bound every frame.
    mesh.frustumCulled = false;
    mesh.renderOrder = this.order;
    this.parent.add(mesh);
    return mesh;
  }

  add(d: DecalInstance) {
    this.items.push(d);
    if (this.items.length > this.capacity) {
      this.capacity *= 2;
      this.parent.remove(this.mesh);
      this.mesh.geometry.dispose();
      this.mesh.dispose();
      this.mesh = this.make();
    }
  }

  remove(d: DecalInstance) {
    const i = this.items.indexOf(d);
    if (i >= 0) this.items.splice(i, 1);
  }

  flush() {
    const { m, q, p, s, up } = DecalLayer;
    const mesh = this.mesh;
    let n = 0;
    for (const d of this.items) {
      if (d.opacity <= 0) continue;
      q.setFromAxisAngle(up, d.rotY);
      m.compose(p.set(d.x, d.y, d.z), q, s.set(d.sx, 1, d.sz));
      mesh.setMatrixAt(n, m);
      mesh.setColorAt(n, d.color);
      this.opacity.setX(n, d.opacity);
      this.rimAttr.setX(n, d.rim);
      n++;
    }
    mesh.count = n;
    mesh.visible = n > 0;
    if (n) {
      mesh.instanceMatrix.needsUpdate = true;
      mesh.instanceColor!.needsUpdate = true;
      this.opacity.needsUpdate = true;
      this.rimAttr.needsUpdate = true;
    }
  }

  dispose() {
    this.parent.remove(this.mesh);
    this.mesh.geometry.dispose();
    this.mesh.dispose();
    this.material.dispose();
  }
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
  /** Live decals, one instanced layer per texture + blend mode. */
  private decalLayers = new Map<string, DecalLayer>();
  /** Live flash / orbit billboards, one instanced layer per texture; live tethers in one instanced layer. */
  private spriteLayers = new Map<string, SpriteLayer>();
  private beamLayer: BeamLayer | null = null;
  /** The glow sprite layer is never idle-freed (see the constructor). */
  private glowLayer: SpriteLayer | null = null;
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
    // The instanced billboard / beam layers' shader programs compile with the first frame (an empty layer still goes
    // through setProgram) instead of in the middle of the first fight. These two stay alive for the session: a program is
    // destroyed when its last material is disposed, and flashes and tethers are in nearly every fight.
    this.beamLayer = new BeamLayer(this.group);
    this.glowLayer = this.spriteLayer(fx.glow());
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
    for (let i = 0; i < FLASH_LIGHTS; i++) {
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

  /**
   * Share of each burst's particles that is drawn (1 = all, never below one per burst). The scene lowers it while it plays
   * another player's cast: the same effect, the same colours, fewer motes: we already draw our own casts on top of it.
   */
  particleScale = 1;

  /**
   * Whose ground effects are being drawn: our own read in full, another player's faint and outline-only (their hue is kept so
   * an ally's circle still reads). WorldScene sets it around a remote player's events, like `particleScale`.
   */
  role: DecalRole = 'self';
  private dangerDepth = 0;

  /** Everything decal()-ed inside `fn` is a danger telegraph: drawn above all friendly ground effects and never faded. */
  danger<T>(fn: () => T, when = true): T {
    if (!when) return fn();
    this.dangerDepth++;
    try {
      return fn();
    } finally {
      this.dangerDepth--;
    }
  }

  /** Another player's Binbun effect: same hue, ~0.35 alpha and 3/4 scale, unless it is a danger telegraph. */
  get dimsBinbun(): boolean {
    return this.role === 'other' && this.dangerDepth === 0;
  }

  /** `o` as a partner's Binbun spawn: dimmed and smaller while a partner's event is handled, untouched otherwise (our own casts). */
  partnerBinbun<T extends { alpha?: number; scale?: number }>(o: T): T {
    return this.dimsBinbun ? { ...o, alpha: (o.alpha ?? 1) * OTHER_BINBUN_ALPHA, scale: (o.scale ?? 1) * OTHER_BINBUN_SCALE } : o;
  }

  /** The long-lasting "fill" textures that go outline-only (edge radius, interior opacity left); ring and cone are already edges. */
  private outlineOf(tex: THREE.Texture): OutlineProfile | null {
    if (tex === fx.disc()) return { edge: 0.86, floor: 0 };
    if (tex === fx.sigil()) return { edge: 0.8, floor: 0 };
    if (tex === fx.cracks()) return { edge: 2, floor: 0.25 };
    if (tex === fx.glow()) return { edge: 2, floor: 0.12 };
    return null;
  }

  private scaled(o: EmitOptions): EmitOptions {
    // Graphics: Low keeps three quarters of every burst (it has no Binbun layer or motifs, so these motes are its whole look).
    const k = this.particleScale * (settings.quality === 'low' ? LOW_PARTICLE_SCALE : 1);
    if (k >= 1 || o.count <= 0) return o;
    return { ...o, count: Math.max(1, Math.round(o.count * k)) };
  }

  emit(o: EmitOptions) {
    o = this.scaled(o);
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
    o = this.scaled(o);
    this.emitted += o.count;
    this.smoke.emit(o);
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
      this.retire(old);
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

  /** Return a finished transient's mesh to its pool, or its instance to its decal layer. */
  private retire(tr: Transient) {
    tr.release?.();
    if (!tr.mesh) return;
    tr.mesh.visible = false;
    this.group.remove(tr.mesh);
    tr.pool?.push(tr.mesh);
  }

  /** The procedural radial sprites are zero outside their circle (ring: inside its hole too), so they need not rasterise a square. */
  private footprintOf(tex: THREE.Texture): 'quad' | 'disc' | 'ring' {
    if (tex === fx.ring()) return 'ring';
    return tex === fx.disc() || tex === fx.glow() || tex === fx.sigil() || tex === fx.cracks() ? 'disc' : 'quad';
  }

  /** Our own long-lasting areas still in their full-strength window, so a newer cast on top of one can send it to outline early. */
  private ownAreas: { tex: THREE.Texture; x: number; z: number; r: number; alive: boolean; force: () => void }[] = [];

  decal(o: DecalOptions): Handle {
    const tex = o.tex ?? fx.disc();
    const blending = o.blending ?? THREE.AdditiveBlending;
    const danger = !!o.danger || this.dangerDepth > 0;
    const hero = !danger && !!o.hero;
    // The hero's additive ring joins the friendly ring layer (additive blending is order-free: no extra draw call); only its dark
    // contact shadow (normal blending) is its own layer, above friendly decals and below the telegraphs.
    const order = danger ? DECAL_ORDER.danger : hero && blending !== THREE.AdditiveBlending ? DECAL_ORDER.hero : DECAL_ORDER.friendly;
    const outline = this.outlineOf(tex);
    const layerFor = (t: THREE.Texture) => {
      const prof = t === tex ? outline : null;
      const key = `${t.uuid}|${blending}|${order}`;
      let l = this.decalLayers.get(key);
      if (!l) this.decalLayers.set(key, (l = new DecalLayer(this.group, t, blending, this.footprintOf(t), order, prof)));
      return l;
    };
    // Another player's ground effects (never a danger telegraph, never scenery): faint, outline only. `o.other` marks their thralls.
    const other = (this.role === 'other' || !!o.other) && !danger && !o.persistent && !hero;
    // The disc's outline is the ring texture drawn a little larger (the existing ring layer, whose annulus geometry rasterises only
    // the ring: no extra draw call, ~60 % less fill); the sigil keeps its runes and fades in its own shader; glow and cracks just dim.
    const viaRing = !!outline && tex === fx.disc();
    const layer = viaRing && other ? layerFor(fx.ring()) : layerFor(tex);
    const d: DecalInstance = { x: 0, y: 0, z: 0, rotY: o.rot ?? 0, sx: 0, sz: 0, color: new THREE.Color(o.color), opacity: 0, rim: 0 };
    layer.add(d);
    if (other) {
      // Near-white highlights (a Litany's pale ring) bloom hot even when dim: keep the hue, cap the lightness.
      const hsl = { h: 0, s: 0, l: 0 };
      d.color.getHSL(hsl);
      if (hsl.s > 0.08 && hsl.l > 0.55) d.color.setHSL(hsl.h, Math.max(hsl.s, 0.6), 0.5);
    }
    // Disc crossfade partner: the ring-textured outline that takes over as the disc's interior fades.
    let ring: DecalInstance | null = null;
    let ringLayer: DecalLayer | null = null;
    const settles = !danger && !other && !o.persistent && !hero && !!outline && o.duration > LONG_DECAL_S;
    const base = (o.opacity ?? 1) * (other ? OTHER_DECAL_ALPHA : 1);
    const fadeIn = o.fadeIn ?? 0.12;
    const fadeOut = o.fadeOut ?? 0.25;
    const anchor = o.anchor ?? 0;
    let hidden = false;
    let outlineAt = OUTLINE_AFTER_S;
    let outlineFade = OUTLINE_FADE_S;
    let tNow = 0;
    let ended = false;
    const place = () => {
      const f = o.follow?.();
      hidden = !!o.follow && !f;
      const x = f ? f.x : o.x;
      const z = f ? f.z : o.z;
      d.x = x + Math.sin(o.rot ?? 0) * anchor * o.r;
      d.y = o.y ?? 0.04;
      d.z = z + Math.cos(o.rot ?? 0) * anchor * o.r;
    };
    place();
    if (settles) {
      // Repeated casts on the same spot: only the newest stays at full strength, the older overlapping ones go to outline now.
      this.ownAreas = this.ownAreas.filter((a) => a.alive);
      for (const a of this.ownAreas) if (a.tex === tex && Math.hypot(a.x - d.x, a.z - d.z) < Math.max(a.r, o.r)) a.force();
      this.ownAreas.push({ tex, x: d.x, z: d.z, r: o.r, alive: true, force: () => { outlineAt = Math.min(outlineAt, tNow); outlineFade = Math.min(outlineFade, 0.4); } });
    }
    const entry = settles ? this.ownAreas[this.ownAreas.length - 1] : null;
    const delay = o.delay ?? 0;
    return this.add({
      t: -delay,
      duration: o.duration,
      release: () => {
        ended = true;
        if (entry) entry.alive = false;
        layer.remove(d);
        if (ring) ringLayer!.remove(ring);
      },
      persistent: o.persistent,
      update: (t, k) => {
        if (t < 0) {
          d.opacity = 0;
          return;
        }
        tNow = t;
        if (ended) return;
        if (o.follow) place();
        const grow = o.growFrom !== undefined ? o.growFrom + (1 - o.growFrom) * Math.min(1, k * 1.2) : 1;
        const s = o.r * 2 * grow;
        d.sx = s * (o.sx ?? 1);
        d.sz = s * (o.sz ?? 1);
        // The ring texture peaks at 0.71 of its half-width, the disc's rim at 0.94.
        const rs = viaRing && other ? RING_FOR_DISC : 1;
        if (rs !== 1) { d.sx *= rs; d.sz *= rs; }
        if (o.spin) d.rotY = (o.rot ?? 0) + o.spin * t;
        const inA = Math.min(1, t / fadeIn);
        const outA = Math.min(1, (o.duration - t) / fadeOut);
        let pulse = o.pulse ? 0.75 + 0.25 * Math.sin(t * o.pulse) : 1;
        let op = hidden ? 0 : base * Math.max(0, Math.min(inA, outA)) * pulse;
        if (other && outline) d.rim = 1;
        else if (settles) {
          const rim = Math.max(0, Math.min(1, (t - outlineAt) / outlineFade));
          d.rim = rim;
          if (!o.pulse && rim > 0) pulse *= 1 - 0.18 * rim * (0.5 + 0.5 * Math.sin(t * 2.2 + o.x));
          op = hidden ? 0 : base * Math.max(0, Math.min(inA, outA)) * pulse;
          if (rim > 0 && viaRing) {
            if (!ring) {
              ringLayer = layerFor(fx.ring());
              ring = { x: d.x, y: d.y, z: d.z, rotY: 0, sx: 0, sz: 0, color: d.color, opacity: 0, rim: 0 };
              ringLayer.add(ring);
            }
            ring.x = d.x; ring.y = d.y; ring.z = d.z;
            ring.sx = d.sx * RING_FOR_DISC;
            ring.sz = d.sz * RING_FOR_DISC;
            ring.opacity = op * rim;
            d.opacity = op * (1 - rim);
            return;
          }
        }
        d.opacity = op;
      },
    });
  }

  private spriteLayer(tex: THREE.Texture) {
    let layer = this.spriteLayers.get(tex.uuid);
    if (!layer) this.spriteLayers.set(tex.uuid, (layer = new SpriteLayer(this.group, tex, 32, tex === fx.glow())));
    return layer;
  }

  /** A short-lived tinted billboard; `rise` lifts it that many units over its life (skull and spirit wisps). */
  flash(o: { x: number; y: number; z: number; color: THREE.ColorRepresentation; size: number; duration: number; tex?: THREE.Texture; rise?: number; opacity?: number }) {
    const layer = this.spriteLayer(o.tex ?? fx.glow());
    const s: SpriteInstance = { x: o.x, y: o.y, z: o.z, size: 0, rot: 0, color: new THREE.Color(o.color), opacity: 0 };
    layer.add(s);
    return this.add({
      t: 0,
      duration: o.duration,
      release: () => layer.remove(s),
      update: (_t, k) => {
        s.size = o.size * (0.35 + 0.65 * Math.sin(Math.min(1, k * 1.4) * Math.PI * 0.5));
        if (o.rise) s.y = o.y + o.rise * k;
        s.opacity = (o.opacity ?? 1) * (k < 0.3 ? 1 : 1 - (k - 0.3) / 0.7);
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
    const layer = this.spriteLayer(o.tex);
    for (let i = 0; i < o.count; i++) {
      const s: SpriteInstance = { x: cx, y: o.y, z: cz, size: o.size, rot: 0, color: new THREE.Color(o.color), opacity: 0 };
      layer.add(s);
      const phase = (i / o.count) * Math.PI * 2;
      const lift = (i % 3) * 0.28;
      handles.push(this.add({
        t: 0,
        duration: o.duration,
        release: () => layer.remove(s),
        update: (t) => {
          const f = o.follow();
          if (f) [cx, cz] = [f.x, f.z];
          const a = phase + t * o.speed;
          const r = o.radius * Math.min(1, 0.25 + t * 3);
          s.x = cx + Math.cos(a) * r;
          s.y = o.y + lift + Math.sin(t * 3.1 + phase) * 0.12;
          s.z = cz + Math.sin(a) * r;
          s.rot = a * 1.7;
          s.opacity = Math.max(0, Math.min(1, t / 0.15, (o.duration - t) / 0.35));
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
  beam(a: Vec3 | (() => Vec3 | null), b2: () => Vec3 | null, color: THREE.ColorRepresentation, width: number, duration: number) {
    const layer = (this.beamLayer ??= new BeamLayer(this.group));
    const b: BeamInstance = { x: 0, y: 0, z: 0, tx: 0, ty: 0, tz: 1, width: width, length: 1, color: new THREE.Color(color), opacity: 0 };
    layer.add(b);
    return this.add({
      t: 0,
      duration,
      release: () => layer.remove(b),
      update: (t, k) => {
        const end = b2();
        const start = typeof a === 'function' ? a() : a;
        if (!end || !start) {
          b.opacity = 0;
          return;
        }
        b.x = (start.x + end.x) / 2;
        b.y = (start.y + end.y) / 2;
        b.z = (start.z + end.z) / 2;
        b.tx = end.x;
        b.ty = end.y;
        b.tz = end.z;
        b.length = Math.hypot(end.x - start.x, end.y - start.y, end.z - start.z);
        b.width = width * (0.7 + 0.3 * Math.sin(t * 30));
        b.opacity = Math.min(1, (1 - k) * 2);
      },
    });
  }

  /** Transient coloured light for big casts. */
  lightFlash(x: number, y: number, z: number, color: THREE.ColorRepresentation, intensity: number, life = 0.35) {
    // One shared flash light (every lit material loops over all point lights): a new flash takes it over unless a clearly brighter one is still burning.
    const slot = this.lights.reduce((a, b) => (a.life <= 0 ? a : b.life <= 0 ? b : a.t / a.life >= b.t / b.life ? a : b));
    if (slot.life > 0 && slot.light.intensity > intensity * 1.25) return;
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

  update(dtReal: number, camera: THREE.PerspectiveCamera, viewportHeight: number) {
    // Particles hang in the air during a hitstop.
    const dt = dtReal * hitstop.scale;
    this.time += dt;
    const scale = (viewportHeight * 0.5) / Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2);
    this.additive.update(dt, scale);
    this.smoke.update(dt, scale);
    this.binbun.update(dt, camera);

    for (let i = this.transients.length - 1; i >= 0; i--) {
      const tr = this.transients[i];
      tr.t += dt;
      if (tr.t >= tr.duration) {
        this.retire(tr);
        this.transients.splice(i, 1);
        if (!tr.persistent) this.combatTransients--;
        continue;
      }
      tr.update(tr.t, tr.t / tr.duration, dt);
    }
    for (const [key, layer] of this.decalLayers) {
      layer.flush();
      layer.idleS = layer.items.length ? 0 : layer.idleS + dtReal;
      if (layer.idleS > 5) {
        layer.dispose();
        this.decalLayers.delete(key);
      }
    }
    for (const [key, layer] of this.spriteLayers) {
      layer.flush();
      layer.idleS = layer.items.length ? 0 : layer.idleS + dtReal;
      if (layer.idleS > 5 && layer !== this.glowLayer) {
        layer.dispose();
        this.spriteLayers.delete(key);
      }
    }
    this.beamLayer?.flush();

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
    for (const layer of this.decalLayers.values()) layer.dispose();
    this.decalLayers.clear();
    for (const layer of this.spriteLayers.values()) layer.dispose();
    this.spriteLayers.clear();
    this.beamLayer?.dispose();
    this.beamLayer = null;
    this.glowLayer = null;
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
    for (const pool of [this.needlePool, this.orbPool, this.spriteShotPool]) {
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
