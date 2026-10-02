import * as THREE from 'three';
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import { AREAS, AREA_ORDER, DOORS, type AreaId, type DoorDef, type Theme } from '../content/areas';
import { NODE_COLLIDER, PROPS, WING_FLOOR, placementObstacle, wallObstacle, type Placement, type PropId, type Silhouette, type WallSegment, type WorldLayout } from '../content/layout';
import type { Nav } from '../gameplay/nav';
import { NODES } from '../gameplay/gatheringRules';
import { mulberry32 } from '../gameplay/rng';
import { assets } from './AssetCache';
import { fx } from './fxTextures';
import { PROP_URL } from './modelPaths';
import type { Effects } from './Effects';
import { applyOcclusion } from './occlusion';
import { Water } from './Water';
import { Atmosphere } from './Atmosphere';
import { FEN_HUMMOCKS } from '../content/fen';

/** `glow` (a colour): a self-lit share of the texture (emissive), for floors so dark they vanish even under bright lights. */
const FLOOR_TEX: Record<Theme, { url: string; tile: number; color: number; rough: number; glow?: number }> = {
  chapter: { url: 'art/textures/flagstone.webp', tile: 7, color: 0x9a92a8, rough: 0.62 },
  acre: { url: 'art/textures/grave_soil.webp', tile: 5, color: 0xe6f0d4, rough: 0.97, glow: 0x4a5a3c },
  graveyard: { url: 'art/textures/grave_soil.webp', tile: 6, color: 0xb8aab8, rough: 0.95 },
  ossuary: { url: 'art/textures/ossuary_floor.webp', tile: 6, color: 0xb0a4ae, rough: 0.9 },
  nave: { url: 'art/textures/flagstone.webp', tile: 8, color: 0x8c86a8, rough: 0.45 },
  sanctum: { url: 'art/textures/flagstone.webp', tile: 7, color: 0x9a86aa, rough: 0.5 },
  cloister: { url: 'art/textures/cloister_floor.webp', tile: 6, color: 0xa8b4a0, rough: 0.8 },
  warren: { url: 'art/textures/warren_floor.webp', tile: 6, color: 0xb8ac98, rough: 0.9 },
  // The Catacomb Depths: the Warren's floor, darker and cooler.
  depths: { url: 'art/textures/warren_floor.webp', tile: 6, color: 0x8a8070, rough: 0.9 },
  coliseum: { url: 'art/textures/coliseum_floor.webp', tile: 7, color: 0xc8bca8, rough: 0.9 },
  pyre: { url: 'art/textures/pyre_floor.webp', tile: 6, color: 0xd8b498, rough: 0.85 },
  fen: { url: 'art/textures/fen_floor.webp', tile: 6, color: 0xa8c0bc, rough: 0.8 },
  // The Alchemist's Wing: a de-purpled, warmed flagstone variant (tools/make-wing-textures.mjs).
  wing: { url: 'art/textures/wing_floor.webp', tile: 6, color: 0xe8dcc8, rough: 0.75 },
};

/**
 * Per-area tone of the floor light pools (1 = the raw 0.42 x light distance, fixed opacity). The Nave's eleven braziers and
 * candle rows overlap into one violet-gold smear under a busy fight, so its pools are smaller and fainter.
 */
const POOL_TONE: Partial<Record<string, { gain: number; scale: number }>> = {
  nave: { gain: 0.68, scale: 0.8 },
};

export interface LightSource {
  x: number;
  y: number;
  z: number;
  color: number;
  intensity: number;
  distance: number;
  group?: string;
  /** Floor light-pool tint override (the Alchemist's Wing's green glow). */
  pool?: number;
  lit: boolean;
  brazier: boolean;
}

// ---------------------------------------------------------------------------
// Code-built stand-ins: shown until (or if) the generated prop GLB loads.
// ---------------------------------------------------------------------------

function fallbackGeometry(id: PropId): { geo: THREE.BufferGeometry; color: number } {
  const g: THREE.BufferGeometry[] = [];
  const box = (w: number, h: number, d: number, x = 0, y = 0, z = 0) => g.push(new THREE.BoxGeometry(w, h, d).translate(x, y + h / 2, z));
  const cyl = (rt: number, rb: number, h: number, x = 0, y = 0, z = 0, seg = 8) =>
    g.push(new THREE.CylinderGeometry(rt, rb, h, seg).translate(x, y + h / 2, z));
  let color = 0x57515e;
  switch (id) {
    case 'tombstone_round':
      box(0.8, 0.85, 0.2);
      g.push(new THREE.CylinderGeometry(0.4, 0.4, 0.2, 12, 1, false, 0, Math.PI).rotateZ(Math.PI / 2).rotateY(Math.PI / 2).translate(0, 0.85, 0));
      box(1, 0.12, 0.45);
      break;
    case 'tombstone_cross':
      box(0.2, 1.5, 0.2);
      box(0.8, 0.2, 0.2, 0, 1.05);
      box(0.55, 0.2, 0.4);
      break;
    case 'mausoleum':
      box(3.8, 3.4, 4.8);
      g.push(new THREE.ConeGeometry(3.2, 1.8, 4).rotateY(Math.PI / 4).scale(1, 1, 1.25).translate(0, 4.3, 0));
      color = 0x46414f;
      break;
    case 'pillar':
      cyl(0.62, 0.7, 6);
      box(1.6, 0.4, 1.6);
      box(1.5, 0.5, 1.5, 0, 6);
      color = 0x4a4553;
      break;
    case 'arch':
      box(0.8, 4, 0.8, -3.2);
      box(0.8, 4, 0.8, 3.2);
      g.push(new THREE.TorusGeometry(3.2, 0.4, 6, 14, Math.PI).translate(0, 4, 0));
      color = 0x4a4553;
      break;
    case 'sarcophagus':
      box(1.2, 0.8, 2.4);
      box(1.3, 0.2, 2.5, 0, 0.8);
      color = 0x5b5561;
      break;
    case 'statue':
      box(1.3, 0.8, 1.3);
      cyl(0.25, 0.65, 1.9, 0, 0.8);
      g.push(new THREE.SphereGeometry(0.33, 10, 8).translate(0, 2.9, 0));
      color = 0x6a6570;
      break;
    case 'candles':
      for (let i = 0; i < 5; i++) {
        const a = (i / 5) * Math.PI * 2;
        cyl(0.07, 0.08, 0.25 + (i % 3) * 0.18, Math.cos(a) * 0.22, 0.1, Math.sin(a) * 0.22, 6);
      }
      cyl(0.4, 0.45, 0.12);
      color = 0xd8cfbd;
      break;
    case 'bone_pile':
      for (let i = 0; i < 7; i++) {
        const a = (i / 7) * Math.PI * 2;
        g.push(new THREE.SphereGeometry(0.17, 7, 6).translate(Math.cos(a) * 0.3, 0.17 + (i % 2) * 0.18, Math.sin(a) * 0.3));
      }
      color = 0xcfc3ad;
      break;
    case 'fence':
      for (let i = 0; i < 8; i++) cyl(0.03, 0.03, 1.5, -1.05 + i * 0.3, 0, 0, 5);
      box(2.3, 0.07, 0.07, 0, 1.2);
      box(2.3, 0.07, 0.07, 0, 0.35);
      color = 0x2c2a31;
      break;
    case 'dead_tree':
      cyl(0.12, 0.35, 3.5);
      cyl(0.04, 0.12, 2, 0.5, 3, 0);
      cyl(0.04, 0.1, 1.8, -0.6, 2.6, 0.2);
      color = 0x2a2420;
      break;
    case 'brazier':
      cyl(0.55, 0.3, 0.35, 0, 0.9);
      cyl(0.05, 0.05, 0.9, 0.2, 0, 0, 5);
      cyl(0.05, 0.05, 0.9, -0.2, 0, 0.1, 5);
      color = 0x2c2a31;
      break;
    case 'bell_altar': {
      box(4, 0.8, 3);
      const pts: THREE.Vector2[] = [];
      for (let i = 0; i <= 10; i++) {
        const t = i / 10;
        pts.push(new THREE.Vector2(0.5 + Math.pow(t, 2.2) * 1.3, 2.8 - t * 2.6));
      }
      g.push(new THREE.LatheGeometry(pts, 16).translate(0, 0.8, 0));
      color = 0x6b5436;
      break;
    }
    case 'reliquary':
      box(1.6, 0.9, 1);
      box(1.7, 0.25, 1.1, 0, 0.9);
      color = 0x3a2e2a;
      break;
    case 'workbench':
      box(2.6, 0.2, 1.4, 0, 1);
      box(0.2, 1, 0.2, -1.1, 0, -0.5);
      box(0.2, 1, 0.2, 1.1, 0, 0.5);
      box(0.2, 1, 0.2, -1.1, 0, 0.5);
      box(0.2, 1, 0.2, 1.1, 0, -0.5);
      color = 0x3a2e2a;
      break;
    case 'waystone':
      g.push(new THREE.CylinderGeometry(0.28, 0.5, 2.8, 4).rotateY(Math.PI / 4).translate(0, 1.4, 0));
      box(1.2, 0.2, 1.2);
      color = 0x4f4a58;
      break;
    case 'prop_node_bone_kiln':
      // A squat bone-brick kiln with a chimney; the ember light comes from PROPS.
      box(1.8, 1.1, 1.6);
      g.push(new THREE.CylinderGeometry(0.75, 0.9, 0.5, 8, 1, false, 0, Math.PI).rotateY(Math.PI / 2).translate(0, 1.1, 0));
      cyl(0.22, 0.28, 1.1, 0.5, 1.1, 0.35);
      color = 0x8a7c68;
      break;
    default:
      // Newer pipeline props: a plain block of the right height until the GLB arrives.
      box(1, PROPS[id].height * 0.8, 0.8);
      color = 0x4f4a58;
  }
  const merged = mergeGeometries(g.map((x) => (x.index ? x.toNonIndexed() : x)), false)!;
  merged.computeVertexNormals();
  return { geo: merged, color };
}

/** Far scenery, code-built: a broken cathedral spire, a dead tree, a fallen wall. */
function silhouetteGeometry(sil: Silhouette, rand: () => number): THREE.BufferGeometry {
  const g: THREE.BufferGeometry[] = [];
  const box = (w: number, h: number, d: number, x = 0, y = 0, z = 0, rz = 0) =>
    g.push(new THREE.BoxGeometry(w, h, d).translate(0, h / 2, 0).rotateZ(rz).translate(x, y, z));
  const cyl = (rt: number, rb: number, h: number, x: number, y: number, z: number, rx: number, rz: number) =>
    g.push(new THREE.CylinderGeometry(rt, rb, h, 5).translate(0, h / 2, 0).rotateX(rx).rotateZ(rz).translate(x, y, z));
  switch (sil.kind) {
    case 'spire': {
      box(4.2, 18, 4.2);
      box(3.4, 5, 3.4, 0, 18);
      g.push(new THREE.ConeGeometry(2.6, 13, 4).rotateY(Math.PI / 4).translate(0, 29.5, 0));
      // A shorter, broken twin and a flying buttress.
      box(3, 9 + rand() * 5, 3, 5.6, 0, 1.2);
      box(0.9, 9, 0.9, -3.4, 2, 0, -0.5);
      box(8, 1.1, 2.6, -2, 0, 0);
      break;
    }
    case 'tree': {
      cyl(0.12, 0.42, 5.2, 0, 0, 0, 0, (rand() - 0.5) * 0.15);
      for (let i = 0; i < 4; i++) {
        const a = rand() * Math.PI * 2;
        const y = 2.2 + rand() * 2.6;
        cyl(0.03, 0.12, 1.6 + rand() * 1.6, Math.cos(a) * 0.1, y, Math.sin(a) * 0.1, Math.sin(a) * 0.9, Math.cos(a) * 0.9);
      }
      break;
    }
    case 'ruin': {
      let x = -3;
      while (x < 3) {
        const w = 0.8 + rand() * 1.4;
        box(w, 1 + rand() * 4, 0.9, x + w / 2);
        x += w;
      }
      box(1.4, 0.7, 1.2, 1 + rand() * 3, 0, 1.4 + rand());
      break;
    }
  }
  const merged = mergeGeometries(g.map((x) => (x.index ? x.toNonIndexed() : x)), false)!;
  for (const x of g) x.dispose();
  merged.scale(sil.scale, sil.scale, sil.scale).rotateY(sil.rot).translate(sil.x, -0.1, sil.z);
  return merged;
}

/**
 * Instanced batch of one prop kind. Starts with the code-built stand-in and
 * swaps to the generated GLB (every mesh instanced with the same transforms)
 * once it loads.
 */
/** Colour multiplier (can exceed 1) for props that read too dark at the game camera: the Wing's hanging herbs and drying rack. */
const PROP_LIFT: Partial<Record<PropId, number>> = { alch_herb_bundle: 3.2, alch_drying_rack: 1.9 };
/** Side (m) of the culling cells a prop batch is split into; well under the 60 m shadow camera and the view footprint. */
const PROP_CELL = 12;

export class PropBatch {
  readonly group = new THREE.Group();
  constructor(
    private id: PropId,
    private placements: Placement[],
    private tall: boolean,
  ) {
    const { geo, color } = fallbackGeometry(id);
    const mat = new THREE.MeshStandardMaterial({ color, roughness: 0.9, metalness: 0.05 });
    this.build([{ geometry: geo, material: mat, local: new THREE.Matrix4() }], 1);
    // Pipeline props that may not exist yet (prop_node_*) are HEAD-checked first: no console noise.
    const url = PROP_URL(id);
    const exists = id.startsWith('prop_node_')
      ? fetch(url, { method: 'HEAD' }).then((r) => r.ok && !(r.headers.get('content-type') ?? '').includes('text/html')).catch(() => false)
      : Promise.resolve(true);
    void exists.then((ok) => (ok ? assets.model(url, PROPS[id].height) : null)).then((t) => {
      if (!t) return;
      t.scene.updateMatrixWorld(true);
      const bounds = new THREE.Box3().setFromObject(t.scene);
      const center = bounds.getCenter(new THREE.Vector3());
      const norm = new THREE.Matrix4()
        .makeTranslation(-center.x * t.scale, t.groundOffset, -center.z * t.scale)
        .multiply(new THREE.Matrix4().makeScale(t.scale, t.scale, t.scale));
      const parts: { geometry: THREE.BufferGeometry; material: THREE.Material; local: THREE.Matrix4 }[] = [];
      const lift = PROP_LIFT[id];
      t.scene.traverse((o) => {
        const m = o as THREE.Mesh;
        if (!m.isMesh) return;
        let material = m.material as THREE.Material;
        // Props the GLB pipeline leaves too dark for the camera get a private, brightened material (the cached one stays shared).
        if (lift && (material as THREE.MeshStandardMaterial).isMeshStandardMaterial) {
          material = material.clone();
          const std = material as THREE.MeshStandardMaterial;
          std.color.setRGB(lift, lift, lift * 0.92);
          if (std.map) { std.emissiveMap = std.map; std.emissive.setRGB(0.14, 0.14, 0.12); }
        }
        parts.push({ geometry: m.geometry, material, local: norm.clone().multiply(m.matrixWorld) });
      });
      if (parts.length) {
        this.group.clear();
        this.build(parts, 1);
      }
    });
  }

  private build(parts: { geometry: THREE.BufferGeometry; material: THREE.Material; local: THREE.Matrix4 }[], _v: number) {
    const m = new THREE.Matrix4();
    const q = new THREE.Quaternion();
    const e = new THREE.Euler();
    const s = new THREE.Vector3();
    const p = new THREE.Vector3();
    // One InstancedMesh per part *per cell*: culling is per mesh, so an area-wide batch was drawn
    // (and shadow-cast) whole whenever any one of its props was in view (~5x overdraw, BLENDER-AUDIT §1.2).
    const cells = new Map<string, Placement[]>();
    for (const pl of this.placements) {
      const key = `${Math.floor(pl.x / PROP_CELL)},${Math.floor(pl.z / PROP_CELL)}`;
      const list = cells.get(key);
      if (list) list.push(pl);
      else cells.set(key, [pl]);
    }
    for (const part of parts) {
      if (this.tall) applyOcclusion(part.material);
      for (const list of cells.values()) {
        const inst = new THREE.InstancedMesh(part.geometry, part.material, list.length);
        list.forEach((pl, i) => {
          e.set(pl.tilt ?? 0, pl.rot, (pl.tilt ?? 0) * 0.6);
          q.setFromEuler(e);
          s.setScalar(pl.scale);
          p.set(pl.x, pl.y ?? 0, pl.z);
          m.compose(p, q, s).multiply(part.local);
          inst.setMatrixAt(i, m);
        });
        inst.castShadow = this.tall;
        inst.receiveShadow = true;
        inst.computeBoundingSphere();
        this.group.add(inst);
      }
    }
  }
}

/** Box geometry with world-space UVs so one repeating material fits any size. */
export function worldUvBox(w: number, h: number, d: number, tile: number) {
  const geo = new THREE.BoxGeometry(w, h, d);
  const uv = geo.attributes.uv as THREE.BufferAttribute;
  const spans: [number, number][] = [
    [d, h],
    [d, h],
    [w, d],
    [w, d],
    [w, h],
    [w, h],
  ];
  for (let f = 0; f < 6; f++) {
    for (let v = 0; v < 4; v++) {
      const i = f * 4 + v;
      uv.setXY(i, (uv.getX(i) * spans[f][0]) / tile, (uv.getY(i) * spans[f][1]) / tile);
    }
  }
  return geo;
}

/** The wall segments as merged, textured meshes (one per texture): the world's walls and each Depths floor's partitions. */
export function buildWallMeshes(walls: WallSegment[]): THREE.Mesh[] {
  const byTex = new Map<string, THREE.BufferGeometry[]>();
  for (const w of walls) {
    const horizontal = Math.abs(w.z1 - w.z0) < 1e-3;
    const len = horizontal ? w.x1 - w.x0 : w.z1 - w.z0;
    const geo = horizontal ? worldUvBox(len, w.height, w.thickness, 4) : worldUvBox(w.thickness, w.height, len, 4);
    geo.translate((w.x0 + w.x1) / 2, w.height / 2, (w.z0 + w.z1) / 2);
    const list = byTex.get(w.texture) ?? [];
    list.push(geo);
    byTex.set(w.texture, list);
  }
  const out: THREE.Mesh[] = [];
  for (const [tex, geos] of byTex) {
    const merged = mergeGeometries(geos, false);
    if (!merged) continue;
    const mesh = new THREE.Mesh(
      merged,
      new THREE.MeshStandardMaterial({
        map: assets.texture(`art/textures/${tex}.webp`, { repeat: 1 }),
        bumpMap: assets.texture(`art/textures/${tex}.webp`, { repeat: 1 }),
        bumpScale: 3,
        color: tex === 'skull_wall' ? 0xc2b8ae : tex === 'wing_wall' ? 0xd8ccb8 : 0x9a92a4,
        roughness: 0.92,
      }),
    );
    mesh.castShadow = true;
    mesh.receiveShadow = true;
    applyOcclusion(mesh.material as THREE.Material);
    out.push(mesh);
  }
  return out;
}

interface Gate {
  door: DoorDef;
  bars: THREE.Group;
  seal: THREE.Mesh;
  open: boolean;
  lift: number;
}

const FLAME_VS = /* glsl */ `
  attribute float aPhase;
  attribute float aLit;
  uniform float uTime;
  uniform float uScale;
  varying float vA;
  void main() {
    vec3 p = position;
    float f = 0.82 + 0.18 * sin(uTime * 13.0 + aPhase * 7.0) * sin(uTime * 7.3 + aPhase * 3.0);
    p.y += 0.02 * sin(uTime * 9.0 + aPhase);
    vec4 mv = modelViewMatrix * vec4(p, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = 0.24 * f * aLit * uScale / max(0.1, -mv.z);
    vA = f * aLit;
  }
`;
const FLAME_FS = /* glsl */ `
  uniform sampler2D uMap;
  varying float vA;
  void main() {
    vec4 t = texture2D(uMap, gl_PointCoord);
    vec3 c = mix(vec3(1.0, 0.55, 0.25), vec3(1.0, 0.92, 0.75), t.r);
    gl_FragColor = vec4(c * 1.35, t.a * vA);
  }
`;

/**
 * Everything static in the world: floors, walls, props, windows, gates, candle
 * flames, light pools and ground mist. Registers colliders with the Nav.
 */
export class WorldView {
  readonly group = new THREE.Group();
  readonly lightSources: LightSource[] = [];
  private gates: Gate[] = [];
  private flames!: THREE.Points;
  private flameGroups: (string | undefined)[] = [];
  private pointLights: THREE.PointLight[] = [];
  private lightAssignT = 0;
  private time = 0;
  private mist!: THREE.Points;
  private mistVel: Float32Array = new Float32Array(0);
  private braziers: LightSource[] = [];
  private interactMarkers: THREE.InstancedMesh<THREE.RingGeometry, THREE.MeshBasicMaterial>[] = [];
  private water: Water;
  private atmosphere = new Atmosphere();
  private focusArea: AreaId | null = null;
  /** The Fen's dry hummocks: one instanced mound and one rim ring, rescaled while the Mire Mother floods the marsh. */
  private hummocks: { mound: THREE.InstancedMesh; rim: THREE.InstancedMesh; cur: number; target: number } | null = null;

  constructor(
    scene: THREE.Scene,
    private layout: WorldLayout,
    nav: Nav,
    private effects: Effects,
  ) {
    scene.add(this.group);
    this.buildFloors();
    this.buildWalls(nav);
    this.buildProps(nav);
    // Reuse the five existing dynamic lights for a warm workshop beacon.
    const sawpit = AREAS.acre.interactables.find(it => it.kind === 'sawpit')!;
    this.lightSources.push({ x: sawpit.x, y: 1.6, z: sawpit.z, color: 0xffd29a, intensity: 3, distance: 7, lit: true, brazier: false });
    this.effects.decal({ tex: fx.ring(), color: 0xeac58b, x: sawpit.x, z: sawpit.z, r: 1.4, duration: 1e9, persistent: true, opacity: 0.3, fadeIn: 0.01 });
    this.buildWindows();
    this.buildDecals();
    this.buildWingFloor();
    this.buildInteractableMarkers();
    this.buildGates();
    this.buildFlames();
    this.buildMist();
    this.buildSilhouettes();
    this.buildHummocks();
    this.water = new Water([...layout.water, ...layout.bog, ...layout.ponds], layout.puddles);
    this.group.add(this.water.mesh, this.atmosphere.points);
    for (let i = 0; i < 5; i++) {
      const l = new THREE.PointLight(0xffb46b, 0, 8, 1.8);
      this.group.add(l);
      this.pointLights.push(l);
    }
  }

  /** The Mourning Fen's dry ground (content/fen.ts FEN_HUMMOCKS): low peat mounds with a pale teal rim, two draw calls. */
  private buildHummocks() {
    const n = FEN_HUMMOCKS.length;
    const mound = new THREE.InstancedMesh(
      new THREE.CylinderGeometry(0.9, 1, 0.34, 18, 1).translate(0, 0.17, 0),
      new THREE.MeshStandardMaterial({ color: 0x46574a, roughness: 1, metalness: 0, flatShading: true, emissive: 0x0a2622, emissiveIntensity: 0.5 }),
      n,
    );
    mound.receiveShadow = true;
    const rim = new THREE.InstancedMesh(
      new THREE.RingGeometry(0.93, 1.07, 36).rotateX(-Math.PI / 2).translate(0, 0.36, 0),
      new THREE.MeshBasicMaterial({ color: 0x6fd6c4, transparent: true, opacity: 0.38, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide }),
      n,
    );
    rim.renderOrder = 3;
    this.hummocks = { mound, rim, cur: 1, target: 1 };
    this.layoutHummocks(1);
    this.group.add(mound, rim);
  }

  private layoutHummocks(k: number) {
    const h = this.hummocks!;
    const m = new THREE.Matrix4();
    FEN_HUMMOCKS.forEach((p, i) => {
      m.makeScale(p.r * k, 1, p.r * k).setPosition(p.x, 0, p.z);
      h.mound.setMatrixAt(i, m);
      h.rim.setMatrixAt(i, m);
    });
    h.mound.instanceMatrix.needsUpdate = true;
    h.rim.instanceMatrix.needsUpdate = true;
    h.mound.computeBoundingSphere();
    h.rim.computeBoundingSphere();
  }

  /** The marsh floods (Mire Mother phase 2/3): the dry radius eases to `k` times its calm size. Only moves while it changes. */
  setFenFlood(k: number) {
    if (this.hummocks) this.hummocks.target = k;
  }
  /** Current eased flood scale (for QA). */
  fenFlood() {
    return this.hummocks?.cur ?? 1;
  }

  private buildFloors() {
    // Beyond the walls: dark earth swallowed by fog.
    const outside = new THREE.Mesh(
      new THREE.PlaneGeometry(420, 420).rotateX(-Math.PI / 2),
      new THREE.MeshStandardMaterial({ map: assets.texture('art/textures/grave_soil.webp', { repeat: 60 }), color: 0x3a3440, roughness: 1 }),
    );
    outside.position.set(20, -0.06, -60);
    outside.receiveShadow = true;
    this.group.add(outside);

    const mats = new Map<Theme, THREE.MeshStandardMaterial>();
    const matFor = (theme: Theme) => {
      let m = mats.get(theme);
      if (!m) {
        const f = FLOOR_TEX[theme];
        const map = assets.texture(f.url, { repeat: 1 });
        m = new THREE.MeshStandardMaterial({ map, color: f.color, roughness: f.rough, metalness: 0.05, bumpMap: map, bumpScale: 2.2 });
        if (f.glow) {
          m.emissive.set(f.glow);
          m.emissiveMap = map;
        }
        // No roughnessMap: a per-tile gloss map clips point-light highlights to
        // square tile shapes that bloom into glowing squares. Uniform damp stone reads better.
        mats.set(theme, m);
      }
      return m;
    };
    const plane = (x0: number, z0: number, x1: number, z1: number, theme: Theme, y = 0) => {
      const w = x1 - x0;
      const d = z1 - z0;
      const geo = new THREE.PlaneGeometry(w, d).rotateX(-Math.PI / 2);
      const uv = geo.attributes.uv as THREE.BufferAttribute;
      const tile = FLOOR_TEX[theme].tile;
      for (let i = 0; i < uv.count; i++) uv.setXY(i, (x0 + uv.getX(i) * w) / tile, (z0 + uv.getY(i) * d) / tile);
      const mesh = new THREE.Mesh(geo, matFor(theme));
      mesh.position.set((x0 + x1) / 2, y, (z0 + z1) / 2);
      mesh.receiveShadow = true;
      this.group.add(mesh);
    };
    for (const id of AREA_ORDER) {
      const r = AREAS[id].rect;
      plane(r.x0 - 0.8, r.z0 - 0.8, r.x1 + 0.8, r.z1 + 0.8, AREAS[id].theme);
    }
    for (const d of DOORS) plane(d.rect.x0, d.rect.z0, d.rect.x1, d.rect.z1, 'chapter', 0.005);
    for (const p of this.layout.paths) plane(p.x0, p.z0, p.x1, p.z1, 'nave', 0.008);
  }

  private buildWalls(nav: Nav) {
    // Deep water (the Acre's pond) blocks feet; fishing spots sit on its shore.
    for (const p of this.layout.ponds) nav.addObstacle({ kind: 'box', x0: p.x0, z0: p.z0, x1: p.x1, z1: p.z1 });
    // Gathering nodes block like props (fishing spots sit on the water and block nothing).
    for (const n of this.layout.nodes) {
      const r = NODE_COLLIDER[NODES[n.type].kind];
      if (r) nav.addObstacle({ kind: 'circle', x: n.x, z: n.z, r });
    }
    for (const w of this.layout.walls) {
      // Interior partitions block movement (edge walls sit outside the walkable rect).
      const box = wallObstacle(w);
      nav.addObstacle(box);
      if (w.height >= 2.5) nav.addSightBlocker(box);
    }
    for (const mesh of buildWallMeshes(this.layout.walls)) this.group.add(mesh);
  }

  private buildProps(nav: Nav) {
    // One batch per prop kind *per area*: world-wide batches have world-sized bounding spheres,
    // so the camera and the moon's shadow pass could never cull a single far-off tombstone.
    const byProp = new Map<string, Placement[]>();
    for (const p of this.layout.props) {
      const key = `${p.prop}|${p.area}`;
      const list = byProp.get(key) ?? [];
      list.push(p);
      byProp.set(key, list);
      const spec = PROPS[p.prop];
      const obstacle = placementObstacle(p);
      if (obstacle) nav.addObstacle(obstacle);
      if (spec.light) {
        const src: LightSource = {
          x: p.x,
          y: spec.light.y * p.scale,
          z: p.z,
          color: spec.light.color,
          intensity: spec.light.intensity,
          distance: spec.light.distance,
          group: p.group,
          pool: spec.light.pool,
          lit: true,
          brazier: p.prop === 'brazier',
        };
        this.lightSources.push(src);
        if (src.brazier) this.braziers.push(src);
      }
    }
    for (const list of byProp.values()) {
      const id = list[0].prop;
      const tall = PROPS[id].height > 1.5;
      this.group.add(new PropBatch(id, list, tall).group);
    }
  }

  private buildWindows() {
    const tex = assets.texture('art/textures/stained_glass.webp');
    for (const w of this.layout.windows) {
      const mat = new THREE.MeshBasicMaterial({ map: tex, color: 0xcfb8ff, transparent: true, depthWrite: false, toneMapped: false });
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(w.w, w.h), mat);
      mesh.position.set(w.x, w.y, w.z);
      mesh.rotation.y = w.facing;
      mesh.translateZ(0.5);
      this.group.add(mesh);
      // A slanted shaft of coloured light down to the floor.
      const shaft = new THREE.Mesh(
        new THREE.PlaneGeometry(w.w * 0.9, 14),
        new THREE.MeshBasicMaterial({
          map: fx.glow(),
          color: 0x6d4bd6,
          transparent: true,
          opacity: 0.16,
          blending: THREE.AdditiveBlending,
          depthWrite: false,
          side: THREE.DoubleSide,
        }),
      );
      shaft.position.set(w.x, w.y * 0.45, w.z);
      shaft.rotation.y = w.facing;
      shaft.translateZ(5);
      shaft.rotateX(-0.55);
      this.group.add(shaft);
      this.effects.decal({ tex: fx.glow(), color: 0x5a3bb8, x: shaft.position.x, z: shaft.position.z, r: w.w, duration: 1e9, persistent: true, opacity: 0.35, fadeIn: 0.01 });
    }
  }

  /** The Alchemist's Wing's rugs and spills: thin canvas-textured planes just above the flagstones (drawn once, lit by the pools). */
  private buildWingFloor() {
    const rugTex = (color: number, alt: number) => {
      const cv = document.createElement('canvas');
      cv.width = 256;
      cv.height = 128;
      const g = cv.getContext('2d')!;
      const hex = (n: number, k = 1) => `rgb(${Math.min(255, ((n >> 16) & 255) * k) | 0},${Math.min(255, ((n >> 8) & 255) * k) | 0},${Math.min(255, (n & 255) * k) | 0})`;
      g.fillStyle = hex(color, 0.45);
      g.fillRect(0, 0, 256, 128);
      g.fillStyle = hex(color, 0.8);
      g.fillRect(14, 14, 228, 100);
      g.strokeStyle = hex(alt, 0.55);
      g.lineWidth = 4;
      g.strokeRect(8, 8, 240, 112);
      g.lineWidth = 2;
      g.strokeRect(20, 20, 216, 88);
      g.fillStyle = hex(alt, 0.5);
      for (let i = 0; i < 5; i++) {
        const cx = 36 + i * 46;
        g.beginPath();
        g.moveTo(cx, 64 - 26); g.lineTo(cx + 18, 64); g.lineTo(cx, 64 + 26); g.lineTo(cx - 18, 64);
        g.closePath();
        g.fill();
        g.fillStyle = hex(color, 0.55);
        g.beginPath();
        g.moveTo(cx, 64 - 11); g.lineTo(cx + 8, 64); g.lineTo(cx, 64 + 11); g.lineTo(cx - 8, 64);
        g.closePath();
        g.fill();
        g.fillStyle = hex(alt, 0.5);
      }
      // Wear and fray.
      const rnd = mulberry32(color);
      for (let i = 0; i < 1400; i++) {
        g.fillStyle = `rgba(20,12,8,${(0.08 + rnd() * 0.2).toFixed(2)})`;
        g.fillRect(rnd() * 256, rnd() * 128, 2 + rnd() * 6, 1 + rnd() * 3);
      }
      const t = new THREE.CanvasTexture(cv);
      t.colorSpace = THREE.SRGBColorSpace;
      t.anisotropy = 4;
      return t;
    };
    const stainTex = (() => {
      const cv = document.createElement('canvas');
      cv.width = cv.height = 128;
      const g = cv.getContext('2d')!;
      const rnd = mulberry32(77);
      for (let i = 0; i < 9; i++) {
        const cx = 64 + (rnd() - 0.5) * 50, cy = 64 + (rnd() - 0.5) * 50, r = 14 + rnd() * 26;
        const grad = g.createRadialGradient(cx, cy, 0, cx, cy, r);
        grad.addColorStop(0, 'rgba(255,255,255,0.55)');
        grad.addColorStop(0.7, 'rgba(255,255,255,0.3)');
        grad.addColorStop(1, 'rgba(255,255,255,0)');
        g.fillStyle = grad;
        g.fillRect(0, 0, 128, 128);
      }
      const t = new THREE.CanvasTexture(cv);
      t.colorSpace = THREE.SRGBColorSpace;
      return t;
    })();
    WING_FLOOR.forEach((f, i) => {
      const rug = f.kind === 'rug';
      const mat = new THREE.MeshStandardMaterial({
        map: rug ? rugTex(f.color, f.alt ?? 0xc9a25a) : stainTex,
        color: rug ? 0xb4a490 : f.color,
        roughness: 1,
        metalness: 0,
        transparent: !rug,
        opacity: rug ? 1 : 0.85,
        depthWrite: false,
        polygonOffset: true,
        polygonOffsetFactor: -2,
        polygonOffsetUnits: -2,
      });
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(f.w, f.d).rotateX(-Math.PI / 2), mat);
      mesh.position.set(f.x, rug ? 0.012 + i * 0.001 : 0.011, f.z);
      mesh.rotation.y = f.rot;
      mesh.receiveShadow = true;
      mesh.renderOrder = 1;
      this.group.add(mesh);
    });
  }

  private buildDecals() {
    for (const d of this.layout.decals) {
      const tex = d.kind === 'sigil' ? fx.sigil() : fx.cracks();
      this.effects.decal({ tex, color: d.color, x: d.x, z: d.z, r: d.r, rot: d.rot, duration: 1e9, persistent: true, opacity: d.opacity, fadeIn: 0.01, y: 0.02, spin: d.kind === 'sigil' ? 0.03 : 0 });
    }
    // Light pools under every flame source: fake bounce light, zero per-pixel cost. They are static and additive, so each
    // area's pools are baked into ONE quad-soup mesh (colour x opacity in the vertex colours) instead of one draw call per
    // candle: the Nave alone had ~14 overlapping pool decals.
    const byArea = new Map<string, LightSource[]>();
    for (const s of this.lightSources) {
      const area = AREA_ORDER.find((a) => {
        const r = AREAS[a].rect;
        return s.x >= r.x0 - 1 && s.x <= r.x1 + 1 && s.z >= r.z0 - 1 && s.z <= r.z1 + 1;
      }) ?? 'other';
      const list = byArea.get(area) ?? [];
      list.push(s);
      byArea.set(area, list);
    }
    const poolMat = new THREE.MeshBasicMaterial({ map: fx.lightPool(), vertexColors: true, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide });
    this.poolMat = poolMat;
    const tint = new THREE.Color();
    for (const [area, list] of byArea) {
      const tone = POOL_TONE[area] ?? { gain: 1, scale: 1 };
      const pos: number[] = [];
      const uv: number[] = [];
      const col: number[] = [];
      const idx: number[] = [];
      for (const s of list) {
        const r = s.distance * 0.42 * tone.scale;
        const k = s.brazier ? 0.5 : 0.32;
        tint.set(s.pool ?? (s.brazier ? 0x7a4fd6 : 0xc9864a)).multiplyScalar(k * tone.gain);
        const o = pos.length / 3;
        for (const [dx, dz, u, v] of [[-1, -1, 0, 1], [1, -1, 1, 1], [1, 1, 1, 0], [-1, 1, 0, 0]] as const) {
          pos.push(s.x + dx * r, 0.015, s.z + dz * r);
          uv.push(u, v);
          col.push(tint.r, tint.g, tint.b);
        }
        idx.push(o, o + 2, o + 1, o, o + 3, o + 2);
      }
      const g = new THREE.BufferGeometry();
      g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
      g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
      g.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
      g.setIndex(idx);
      g.computeBoundingSphere();
      const m = new THREE.Mesh(g, poolMat);
      m.renderOrder = 2;
      this.group.add(m);
    }
  }

  private poolMat: THREE.MeshBasicMaterial | null = null;

  /** Quiet ground rings make stations, waystones and summon sites readable before hover. */
  private buildInteractableMarkers() {
    const styles = [
      { key: 'service', color: 0xd6bc91, radius: 1.12, opacity: 0.44 },
      { key: 'waystone', color: 0x8dd6c9, radius: 1.23, opacity: 0.48 },
      { key: 'boss', color: 0xc59ce2, radius: 1.55, opacity: 0.5 },
    ] as const;
    const interactables = AREA_ORDER.flatMap((area) => AREAS[area].interactables);
    const dummy = new THREE.Object3D();
    for (const style of styles) {
      const spots = interactables.filter((it) =>
        style.key === 'service' ? it.kind !== 'waystone' && it.kind !== 'boss' && it.kind !== 'npc' && it.kind !== 'stair' : it.kind === style.key,
      );
      if (!spots.length) continue;
      const geometry = new THREE.RingGeometry(0.89, 1, 40).rotateX(-Math.PI / 2);
      const material = new THREE.MeshBasicMaterial({
        color: style.color,
        transparent: true,
        opacity: style.opacity,
        depthWrite: false,
        side: THREE.DoubleSide,
      });
      const markers = new THREE.InstancedMesh(geometry, material, spots.length);
      for (let i = 0; i < spots.length; i++) {
        const spot = spots[i];
        dummy.position.set(spot.x, 0.1, spot.z);
        dummy.scale.setScalar(style.radius);
        dummy.updateMatrix();
        markers.setMatrixAt(i, dummy.matrix);
      }
      // Water draws at order 1; spell decals draw at 2. The cues stay visible
      // over the Drowned Font without altering the water's colour or surface.
      markers.renderOrder = 3;
      markers.computeBoundingSphere();
      this.group.add(markers);
      this.interactMarkers.push(markers);
    }
  }

  private buildGates() {
    const barMat = new THREE.MeshStandardMaterial({ color: 0x24212a, roughness: 0.6, metalness: 0.6 });
    const postMat = new THREE.MeshStandardMaterial({ map: assets.texture('art/textures/stone_wall.webp', { repeat: 1 }), color: 0x8a8296, roughness: 0.9 });
    for (const door of DOORS) {
      if (door.id === 'chapter_graves') continue; // always open
      const c = { x: (door.rect.x0 + door.rect.x1) / 2, z: (door.rect.z0 + door.rect.z1) / 2 };
      const width = door.axis === 'z' ? door.rect.x1 - door.rect.x0 : door.rect.z1 - door.rect.z0;
      const root = new THREE.Group();
      root.position.set(c.x, 0, c.z);
      root.rotation.y = door.axis === 'z' ? 0 : Math.PI / 2;
      for (const s of [-1, 1]) {
        const post = new THREE.Mesh(new THREE.BoxGeometry(1, 5, 1), postMat);
        post.position.set((s * (width + 1)) / 2, 2.5, 0);
        post.castShadow = true;
        root.add(post);
      }
      const lintel = new THREE.Mesh(new THREE.BoxGeometry(width + 2, 0.9, 1), postMat);
      lintel.position.y = 5.2;
      root.add(lintel);
      const bars = new THREE.Group();
      const n = Math.round(width / 0.45);
      const parts: THREE.BufferGeometry[] = [];
      for (let i = 0; i <= n; i++) {
        parts.push(new THREE.CylinderGeometry(0.05, 0.05, 4.8, 5).toNonIndexed().translate(-width / 2 + (i * width) / n, 2.4, 0));
        parts.push(new THREE.ConeGeometry(0.09, 0.3, 5).toNonIndexed().translate(-width / 2 + (i * width) / n, 4.95, 0));
      }
      for (const y of [0.9, 3.2]) parts.push(new THREE.BoxGeometry(width, 0.08, 0.1).toNonIndexed().translate(0, y, 0));
      const grid = new THREE.Mesh(mergeGeometries(parts, false)!, barMat);
      grid.castShadow = true;
      bars.add(grid);
      root.add(bars);
      const seal = new THREE.Mesh(
        new THREE.PlaneGeometry(width * 0.9, width * 0.9),
        new THREE.MeshBasicMaterial({ map: fx.sigil(), color: 0x9b5cff, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide }),
      );
      seal.position.set(0, 2.5, 0.12);
      root.add(seal);
      this.group.add(root);
      this.gates.push({ door, bars, seal, open: false, lift: 0 });
    }
  }

  setDoorOpen(doorId: string, open: boolean, instant = false) {
    const g = this.gates.find((x) => x.door.id === doorId);
    if (!g || g.open === open) return;
    g.open = open;
    if (instant) g.lift = open ? 1 : 0;
    else if (open) {
      const c = { x: (g.door.rect.x0 + g.door.rect.x1) / 2, z: (g.door.rect.z0 + g.door.rect.z1) / 2 };
      this.effects.emit({ x: c.x, y: 2.5, z: c.z, count: 80, color: 0xb58cff, spread: 2.5, speed: 2.5, up: 1.5, life: 1.4, size: 0.4 });
      this.effects.lightFlash(c.x, 3, c.z, 0xa26bff, 40, 1.2);
    }
  }

  private buildFlames() {
    const pos: number[] = [];
    const phase: number[] = [];
    const lit: number[] = [];
    const rand = mulberry32(99);
    for (const p of this.layout.props) {
      const spec = PROPS[p.prop].light;
      if (!spec || !spec.flames) continue;
      for (let i = 0; i < spec.flames; i++) {
        const a = rand() * Math.PI * 2;
        const r = rand() * spec.spread * p.scale;
        pos.push(p.x + Math.cos(a) * r, (0.35 + rand() * 0.45) * p.scale + 0.12, p.z + Math.sin(a) * r);
        phase.push(rand() * 10);
        lit.push(1);
        this.flameGroups.push(p.group);
      }
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    geo.setAttribute('aPhase', new THREE.Float32BufferAttribute(phase, 1));
    geo.setAttribute('aLit', new THREE.Float32BufferAttribute(lit, 1));
    this.flames = new THREE.Points(
      geo,
      new THREE.ShaderMaterial({
        vertexShader: FLAME_VS,
        fragmentShader: FLAME_FS,
        uniforms: { uTime: { value: 0 }, uScale: { value: 400 }, uMap: { value: fx.glow() } },
        transparent: true,
        depthWrite: false,
        blending: THREE.AdditiveBlending,
      }),
    );
    this.flames.frustumCulled = false;
    this.group.add(this.flames);
  }

  /** Sanctum candle groups gutter out as the Prelate advances through phases. */
  setCandleGroup(group: string, litOn: boolean) {
    const attr = this.flames.geometry.attributes.aLit as THREE.BufferAttribute;
    this.flameGroups.forEach((g, i) => {
      if (g === group) attr.setX(i, litOn ? 1 : 0);
    });
    attr.needsUpdate = true;
    for (const s of this.lightSources) if (s.group === group) s.lit = litOn;
  }

  private buildMist() {
    const count = 220;
    const pos = new Float32Array(count * 3);
    const col = new Float32Array(count * 3);
    const size = new Float32Array(count);
    const alpha = new Float32Array(count);
    this.mistVel = new Float32Array(count * 2);
    const rand = mulberry32(5);
    const areas = AREA_ORDER.map((id) => AREAS[id].rect);
    const weights = areas.map((r) => (r.x1 - r.x0) * (r.z1 - r.z0));
    const total = weights.reduce((a, b) => a + b, 0);
    const c = new THREE.Color(0x3d3350);
    for (let i = 0; i < count; i++) {
      let roll = rand() * total;
      let r = areas[0];
      for (let k = 0; k < areas.length; k++) {
        if (roll < weights[k]) {
          r = areas[k];
          break;
        }
        roll -= weights[k];
      }
      pos[i * 3] = r.x0 + rand() * (r.x1 - r.x0);
      pos[i * 3 + 1] = 0.25 + rand() * 0.9;
      pos[i * 3 + 2] = r.z0 + rand() * (r.z1 - r.z0);
      col[i * 3] = c.r;
      col[i * 3 + 1] = c.g;
      col[i * 3 + 2] = c.b;
      size[i] = 5 + rand() * 6;
      alpha[i] = 0.05 + rand() * 0.06;
      this.mistVel[i * 2] = (rand() - 0.5) * 0.35;
      this.mistVel[i * 2 + 1] = (rand() - 0.5) * 0.35;
    }
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(pos, 3).setUsage(THREE.DynamicDrawUsage));
    geo.setAttribute('aColor', new THREE.BufferAttribute(col, 3));
    geo.setAttribute('aSize', new THREE.BufferAttribute(size, 1));
    geo.setAttribute('aAlpha', new THREE.BufferAttribute(alpha, 1));
    this.mist = new THREE.Points(
      geo,
      new THREE.ShaderMaterial({
        vertexShader: /* glsl */ `
          attribute float aSize; attribute float aAlpha; attribute vec3 aColor;
          varying float vA; varying vec3 vC; uniform float uScale;
          void main(){ vec4 mv = modelViewMatrix*vec4(position,1.0); gl_Position = projectionMatrix*mv;
            gl_PointSize = aSize*uScale/max(0.1,-mv.z); vA=aAlpha; vC=aColor; }`,
        fragmentShader: /* glsl */ `
          uniform sampler2D uMap; varying float vA; varying vec3 vC;
          void main(){ vec4 t = texture2D(uMap, gl_PointCoord); gl_FragColor = vec4(vC, t.a*vA*1.4); }`,
        uniforms: { uMap: { value: fx.smoke() }, uScale: { value: 400 } },
        transparent: true,
        depthWrite: false,
      }),
    );
    this.mist.frustumCulled = false;
    this.mist.renderOrder = 4;
    this.group.add(this.mist);
  }

  private buildSilhouettes() {
    const rand = mulberry32(4242);
    const parts = this.layout.silhouettes.map((sil) => silhouetteGeometry(sil, rand));
    if (!parts.length) return;
    const merged = mergeGeometries(parts, false);
    for (const p of parts) p.dispose();
    if (!merged) return;
    merged.computeVertexNormals();
    // Nearly the fog colour: they read as shapes in the murk, never as detail.
    const mat = new THREE.MeshLambertMaterial({ color: 0x2a2436, emissive: 0x0b0912 });
    applyOcclusion(mat);
    this.group.add(new THREE.Mesh(merged, mat));
  }

  /** Is this point standing in water (the nave's flood or a graveyard puddle)? */
  isWet(x: number, z: number) {
    return this.water.isWet(x, z);
  }

  /** A ripple ring spreading from (x, z); does nothing on dry ground. */
  addRipple(x: number, z: number, strength = 1) {
    this.water.addRipple(x, z, strength);
  }

  private areaAt(x: number, z: number): AreaId | null {
    for (const id of AREA_ORDER) {
      const r = AREAS[id].rect;
      if (x >= r.x0 && x <= r.x1 && z >= r.z0 && z <= r.z1) return id;
    }
    return null;
  }

  update(dt: number, focusX: number, focusZ: number, camera: THREE.PerspectiveCamera, viewportHeight: number) {
    this.time += dt;
    const scale = (viewportHeight * 0.5) / Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2);
    const fm = this.flames.material as THREE.ShaderMaterial;
    fm.uniforms.uTime.value = this.time;
    fm.uniforms.uScale.value = scale;
    (this.mist.material as THREE.ShaderMaterial).uniforms.uScale.value = scale;

    const area = this.areaAt(focusX, focusZ);
    if (area && area !== this.focusArea) {
      this.focusArea = area;
      this.water.setMoon(AREAS[area].ambient.moon);
      this.water.setPalette(area === 'fen');
    }
    if (this.hummocks && this.hummocks.cur !== this.hummocks.target) {
      const h = this.hummocks;
      h.cur += (h.target - h.cur) * Math.min(1, dt * 1.6);
      if (Math.abs(h.target - h.cur) < 0.004) h.cur = h.target;
      this.layoutHummocks(h.cur);
    }
    this.water.update(dt);
    this.atmosphere.update(dt, area, focusX, focusZ, scale);

    // Drift mist.
    const mp = this.mist.geometry.attributes.position as THREE.BufferAttribute;
    for (let i = 0; i < mp.count; i++) {
      mp.setX(i, mp.getX(i) + this.mistVel[i * 2] * dt);
      mp.setZ(i, mp.getZ(i) + this.mistVel[i * 2 + 1] * dt);
      if (Math.abs(mp.getX(i) - focusX) > 45) mp.setX(i, focusX - Math.sign(mp.getX(i) - focusX) * 44);
      if (Math.abs(mp.getZ(i) - focusZ) > 40) mp.setZ(i, focusZ - Math.sign(mp.getZ(i) - focusZ) * 39);
    }
    mp.needsUpdate = true;

    // Gates.
    for (const g of this.gates) {
      const target = g.open ? 1 : 0;
      g.lift += (target - g.lift) * Math.min(1, dt * 1.5);
      g.bars.position.y = g.lift * 4.6;
      (g.seal.material as THREE.MeshBasicMaterial).opacity = (1 - g.lift) * (0.65 + 0.2 * Math.sin(this.time * 2));
      g.seal.rotation.z += dt * 0.2;
      g.seal.visible = g.lift < 0.98;
    }

    // Brazier fire near the focus.
    for (const b of this.braziers) {
      if (!b.lit || Math.abs(b.x - focusX) > 30 || Math.abs(b.z - focusZ) > 28) continue;
      if (Math.random() < dt * 10) {
        this.effects.emit({ x: b.x, y: b.y, z: b.z, count: 1, color: Math.random() < 0.7 ? 0x8a5cf0 : 0xc6a4ff, spread: 0.18, speed: 0.1, up: 1, life: 0.5, size: 0.3, gravity: -0.8 });
      }
      if (Math.random() < dt * 1.5) {
        this.effects.emit({ x: b.x, y: b.y + 0.2, z: b.z, count: 1, color: 0xe9a86b, spread: 0.2, speed: 0.3, up: 1.6, life: 1.2, size: 0.08, drag: 0.3 });
      }
    }

    // Assign the dynamic light pool to the nearest lit sources.
    this.lightAssignT -= dt;
    if (this.lightAssignT <= 0) {
      this.lightAssignT = 0.3;
      const near = this.lightSources
        .filter((s) => s.lit)
        .map((s) => ({ s, d: (s.x - focusX) ** 2 + (s.z - focusZ) ** 2 }))
        .sort((a, b) => a.d - b.d)
        .slice(0, this.pointLights.length);
      this.pointLights.forEach((l, i) => {
        const n = near[i];
        l.userData.src = n && n.d < 34 * 34 ? n.s : null;
        if (l.userData.src) {
          const s = l.userData.src as LightSource;
          l.position.set(s.x, s.y + 0.4, s.z);
          l.color.set(s.color);
          l.distance = s.distance;
        }
      });
    }
    this.pointLights.forEach((l, i) => {
      const s = l.userData.src as LightSource | null;
      const flick = 0.85 + 0.15 * Math.sin(this.time * 11 + i * 3.1) * Math.sin(this.time * 5.7 + i);
      l.intensity = s ? s.intensity * flick : 0;
    });
  }

  dispose() {
    this.water.dispose();
    this.atmosphere.dispose();
    for (const marker of this.interactMarkers) marker.material.dispose();
    this.poolMat?.dispose();
    this.group.traverse((o) => {
      const m = o as THREE.Mesh;
      m.geometry?.dispose?.();
    });
    this.group.removeFromParent();
  }
}

export function areaTheme(id: AreaId): Theme {
  return AREAS[id].theme;
}
