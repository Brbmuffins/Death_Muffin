import * as THREE from 'three';
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import { AREAS, AREA_ORDER, DOORS, type AreaId, type DoorDef, type Theme } from '../../server/rules/content/areas';
import { NODE_COLLIDER, PROPS, WING_FLOOR, placementObstacle, wallObstacle, type Placement, type PropId, type Silhouette, type WallSegment, type WorldLayout } from '../content/layout';
import type { Nav } from '../gameplay/nav';
import { NODES } from '../../server/rules/gameplay/gatheringRules';
import { mulberry32 } from '../gameplay/rng';
import { assets } from './AssetCache';
import { fx } from './fxTextures';
import { PROP_URL } from './modelPaths';
import type { Effects } from './Effects';
import { applyOcclusion } from './occlusion';
import { Water } from './Water';
import { Atmosphere } from './Atmosphere';
import { FEN_HUMMOCKS } from '../../server/rules/content/fen';
import { footprintReach, footprintRect } from './viewFootprint';
import { BuildQueue, buildOrder, loadProgress, rectDistance, requiredAreas, visibleAreas } from './areaStreaming';
import { UploadQueue, materialTextures } from './warmModel';

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
  /** The area this light belongs to (hidden areas' lights are skipped); Depths lights carry none. */
  area?: AreaId;
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

/** Pooled flame lights (nearest lit sources). Fixed at runtime: every lit material loops over all point lights; baked pool decals carry the rest of the glow. */
const WORLD_POINT_LIGHTS = 3;

/**
 * Instanced batch of one prop kind. Starts with the code-built stand-in and
 * swaps to the generated GLB (every mesh instanced with the same transforms)
 * once it loads.
 */
/** Colour multiplier (can exceed 1) for props that read too dark at the game camera: the Wing's hanging herbs and drying rack. */
const PROP_LIFT: Partial<Record<PropId, number>> = { alch_herb_bundle: 3.2, alch_drying_rack: 1.9 };
/** Side (m) of the culling cells a prop batch is split into; well under the 60 m shadow camera and the view footprint. */
const PROP_CELL = 12;
/** Props further than this from the hero (cell edge) stop casting moon shadows: the view reaches ~30 m sideways at the widest zoom, ~20 m ahead. */
const SHADOW_RANGE = 32;

export class PropBatch {
  readonly group = new THREE.Group();
  /** Resolves once the generated GLB (if any) has replaced the stand-in, so a warm-up can compile the real materials. Never rejects. */
  readonly ready: Promise<void>;
  /** The culling cells' meshes with the sphere that bounds them, so shadow casting can follow the player (updateShadows). */
  private cells: { mesh: THREE.InstancedMesh; x: number; z: number; r: number }[] = [];
  private shadowFocus: { x: number; z: number; range: number } | null = null;
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
    this.ready = exists.then((ok) => (ok ? assets.model(url, PROPS[id].height) : null)).then((t) => {
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
    }).catch(() => undefined);
  }

  /**
   * One geometry per distinct material among this batch's cells, for warming the moon-shadow depth programs (WorldView.warmShadows). Only tall
   * props ever cast, and a depth program is chosen by the material (its map, side, instancing), so one probe per material covers every cell.
   */
  shadowProbes(): { geometry: THREE.BufferGeometry; material: THREE.Material }[] {
    if (!this.tall) return [];
    const out = new Map<string, { geometry: THREE.BufferGeometry; material: THREE.Material }>();
    for (const c of this.cells) {
      const material = c.mesh.material as THREE.Material;
      if (!out.has(material.uuid)) out.set(material.uuid, { geometry: c.mesh.geometry, material });
    }
    return [...out.values()];
  }

  private castsAt(x: number, z: number, r: number) {
    const f = this.shadowFocus;
    return !f || Math.hypot(x - f.x, z - f.z) - r <= f.range;
  }

  /** Only the cells within `range` m of the focus cast shadows: beyond that they are off screen, but still cost the moon's shadow pass. */
  updateShadows(x: number, z: number, range: number) {
    this.shadowFocus = { x, z, range };
    if (!this.tall) return;
    for (const c of this.cells) {
      const on = this.castsAt(c.x, c.z, c.r);
      if (c.mesh.castShadow !== on) c.mesh.castShadow = on;
    }
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
    this.cells = [];
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
        inst.receiveShadow = true;
        inst.userData.tallProp = this.tall; // QA (tools/qa/culling-diff.cjs) forces these to cast regardless of distance
        inst.computeBoundingSphere();
        const bs = inst.boundingSphere!;
        this.cells.push({ mesh: inst, x: bs.center.x, z: bs.center.z, r: bs.radius });
        // Tall props only (low clutter never casts); and only near the player once a focus is known (updateShadows).
        inst.castShadow = this.tall && this.castsAt(bs.center.x, bs.center.z, bs.radius);
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

interface Chunk {
  id: AreaId;
  group: THREE.Group;
  /** Build steps still to run. */
  left: number;
  built: boolean;
  batches: PropBatch[];
  warm: Promise<void> | null;
}

/**
 * Everything static in the world: floors, walls, props, windows, gates, candle
 * flames, light pools and ground mist. Registers colliders with the Nav.
 */
export class WorldView {
  readonly group = new THREE.Group();
  readonly lightSources: LightSource[] = [];
  private gates: Gate[] = [];
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

  /** Streaming state: one group per area, built a few steps at a time and shown only near the player (graphics/areaStreaming.ts). */
  private chunks = new Map<AreaId, Chunk>();
  private queue = new BuildQueue();
  /** Always drawn: the ground beyond the walls, door floors, paths, gates, silhouettes, markers. */
  private fixed = new THREE.Group();
  private wanted = new Set<AreaId>();
  private wantedKey = '';
  private prioArea: AreaId | null = null;
  private shadowAt: { x: number; z: number } | null = null;
  private shadowRange = 0;
  private shadowDirty = true;
  private primeStats = { buildMs: 0, totalMs: 0 };
  private warmCtx: { renderer: THREE.WebGLRenderer; camera: THREE.Camera; target?: () => THREE.WebGLRenderTarget | null } | null = null;
  private uploads: UploadQueue | null = null;
  private floorMats = new Map<Theme, THREE.MeshStandardMaterial>();
  private flameData = new Map<AreaId, { pos: number[]; phase: number[]; groups: (string | undefined)[] }>();
  private flameMat!: THREE.ShaderMaterial;
  private flamePoints: { points: THREE.Points; groups: (string | undefined)[] }[] = [];
  private candleOff = new Set<string>();
  private floodTarget = 1;
  private poolLists = new Map<string, LightSource[]>();
  private propLists = new Map<AreaId, Map<string, Placement[]>>();

  constructor(
    scene: THREE.Scene,
    private layout: WorldLayout,
    nav: Nav,
    private effects: Effects,
  ) {
    this.scene = scene;
    scene.add(this.group);
    this.group.add(this.fixed);
    this.buildFixedFloors();
    this.registerWalls(nav);
    this.registerProps(nav);
    // Reuse the pooled dynamic lights for a warm workshop beacon.
    const sawpit = AREAS.acre.interactables.find(it => it.kind === 'sawpit')!;
    this.lightSources.push({ x: sawpit.x, y: 1.6, z: sawpit.z, color: 0xffd29a, intensity: 3, distance: 7, lit: true, brazier: false, area: 'acre' });
    this.effects.decal({ tex: fx.ring(), color: 0xeac58b, x: sawpit.x, z: sawpit.z, r: 1.4, duration: 1e9, persistent: true, opacity: 0.3, fadeIn: 0.01 });
    this.buildDecals();
    this.buildInteractableMarkers();
    this.buildGates();
    this.buildFlameData();
    this.buildMist();
    this.buildSilhouettes();
    this.water = new Water([...layout.water, ...layout.bog, ...layout.ponds], layout.puddles);
    this.fixed.add(this.water.mesh, this.atmosphere.points);
    for (let i = 0; i < WORLD_POINT_LIGHTS; i++) {
      const l = new THREE.PointLight(0xffb46b, 0, 8, 1.8);
      this.group.add(l);
      this.pointLights.push(l);
    }
    this.initChunks();
    this.focusPriority('acre');
  }

  private scene: THREE.Scene;

  // -------------------------------------------------------------------------
  // Streaming: build and show only the areas near the player
  // -------------------------------------------------------------------------

  /** The renderer the idle warm-up compiles shaders and uploads textures on (set once the scene is lit). */
  attachRenderer(renderer: THREE.WebGLRenderer, camera: THREE.Camera, target?: () => THREE.WebGLRenderTarget | null) {
    this.warmCtx = { renderer, camera, target };
    this.uploads = new UploadQueue((t) => renderer.initTexture(t));
  }

  private initChunks() {
    for (const id of AREA_ORDER) {
      const group = new THREE.Group();
      group.name = `area:${id}`;
      group.visible = false;
      group.matrixWorldAutoUpdate = false;
      this.group.add(group);
      const chunk: Chunk = { id, group, left: 0, built: false, batches: [], warm: null };
      this.chunks.set(id, chunk);
      const steps: (() => void)[] = [];
      const r = AREAS[id].rect;
      steps.push(() => this.buildFloor(chunk, r.x0 - 0.8, r.z0 - 0.8, r.x1 + 0.8, r.z1 + 0.8, AREAS[id].theme));
      for (const [key, list] of this.propLists.get(id) ?? []) {
        steps.push(() => {
          const batch = new PropBatch(list[0].prop, list, PROPS[list[0].prop].height > 1.5);
          chunk.batches.push(batch);
          group.add(batch.group);
        });
      }
      const windows = this.layout.windows.filter((w) => this.windowArea(w.x, w.z) === id);
      if (windows.length) steps.push(() => this.buildWindows(chunk, windows));
      if (this.poolLists.get(id)?.length) steps.push(() => this.buildPools(chunk, this.poolLists.get(id)!, id));
      if (this.flameData.get(id)) steps.push(() => this.buildFlames(chunk, this.flameData.get(id)!));
      if (id === 'alchemist_wing') steps.push(() => this.buildWingFloor(group));
      if (id === 'fen') steps.push(() => this.buildHummocks(group));
      chunk.left = steps.length;
      steps.forEach((run, i) => {
        this.queue.add({
          prio: 1e6 + i,
          tag: id,
          run: () => {
            run();
            if (--chunk.left === 0) this.finishChunk(chunk);
          },
        });
      });
    }
  }

  /** The area a wall-mounted window belongs to: the nearest area rectangle. */
  private windowArea(x: number, z: number): AreaId {
    let best: AreaId = AREA_ORDER[0];
    let bd = Infinity;
    for (const id of AREA_ORDER) {
      const d = rectDistance(AREAS[id].rect, x, z);
      if (d < bd) (bd = d, (best = id));
    }
    return best;
  }

  private finishChunk(chunk: Chunk) {
    chunk.built = true;
    // Static from here on: freeze local matrices so a drawn area costs no per-frame matrix work, a hidden one none at all.
    chunk.group.traverse((o) => {
      o.updateMatrix();
      o.matrixAutoUpdate = false;
    });
    chunk.group.updateMatrixWorld(true);
    this.applyShown(chunk);
    void this.chunkReady(chunk);
  }

  private applyShown(chunk: Chunk) {
    const show = chunk.built && this.wanted.has(chunk.id);
    chunk.group.visible = show;
    chunk.group.matrixWorldAutoUpdate = show;
  }

  /** Orders the remaining build steps nearest-first around `area` (door graph). */
  private focusPriority(area: AreaId) {
    if (this.prioArea === area) return;
    this.prioArea = area;
    const rank = new Map(buildOrder(area).map((id, i) => [id, i] as const));
    let step = 0;
    this.queue.reprioritise((t) => (rank.get(t.tag as AreaId) ?? 99) * 1000 + step++);
  }

  /** Builds an area's remaining steps right now (it is about to be on screen). */
  private ensureBuilt(id: AreaId) {
    const chunk = this.chunks.get(id)!;
    if (!chunk.built) this.queue.runWhere((t) => t.tag === id);
  }

  private chunkReady(chunk: Chunk): Promise<void> {
    if (!chunk.warm) {
      chunk.warm = Promise.all(chunk.batches.map((b) => b.ready))
        .then(() => {
          // The real materials are in: queue the shadow-depth warm (it needs no compile wait, see warmShadows).
          this.shadowPending.push(chunk);
          return this.compileChunk(chunk);
        })
        .catch((err) => console.warn('[graphics] area warm failed', err));
    }
    return chunk.warm;
  }

  /** Compiles the shader programs and uploads the textures an area's real materials need, so showing it later costs no first-draw stall. */
  private async compileChunk(chunk: Chunk) {
    const ctx = this.warmCtx;
    if (!ctx || (typeof document !== 'undefined' && document.hidden)) return;
    const mats = new Set<THREE.Material>();
    chunk.group.traverse((o) => {
      const m = (o as THREE.Mesh).material as THREE.Material | THREE.Material[] | undefined;
      if (Array.isArray(m)) m.forEach((x) => mats.add(x));
      else if (m) mats.add(m);
    });
    // compile() only looks at visible objects: show the group for the synchronous traversal, then put it back.
    const was = chunk.group.visible;
    chunk.group.visible = true;
    let compiled: Promise<unknown> = Promise.resolve();
    try {
      // For the target real frames draw into (the composer on High): programs are keyed on it, so a screen compile would be redone at first show.
      const rt = ctx.target?.() ?? null;
      if (rt) ctx.renderer.setRenderTarget(rt);
      compiled = ctx.renderer.compileAsync(chunk.group, ctx.camera, this.scene);
    } finally {
      if (ctx.target?.()) ctx.renderer.setRenderTarget(null);
      chunk.group.visible = was;
    }
    const q = this.uploads;
    await Promise.all([compiled, ...(q ? [...materialTextures(mats)].map((t) => q.enqueue(t)) : [])]);
  }

  /**
   * Builds and warms the starting area and its door neighbours, then resolves (capped at `capMs`: a slow network never traps the player).
   * `onProgress` gets 0..1. The rest of the world keeps building a little each frame afterwards (update()).
   */
  async prime(start: AreaId, at: { x: number; z: number }, onProgress?: (f: number) => void, capMs = 8000): Promise<void> {
    // The start area, its door neighbours, and anything else already on screen from the spawn point.
    const ids = [...new Set([...requiredAreas(start), ...visibleAreas(at.x, at.z, start)])];
    const need = ids.map((id) => this.chunks.get(id)!);
    const rank = new Map(ids.map((id, i) => [id as string, i]));
    let step = 0;
    this.queue.reprioritise((t) => (rank.get(t.tag!) ?? 50) * 1000 + step++);
    this.prioArea = null;
    const t0 = performance.now();
    const total = () => need.reduce((n, c) => n + c.left, 0);
    const startLeft = total() + need.length;
    while (need.some((c) => !c.built) && performance.now() - t0 < capMs) {
      this.queue.runSlice(8);
      onProgress?.(loadProgress(startLeft - need.length - total(), startLeft));
      await new Promise((r) => setTimeout(r, 0));
    }
    this.primeStats.buildMs = Math.round(performance.now() - t0);
    // Built; now wait for their GLBs to land and their shaders and textures to warm.
    let warmed = 0;
    for (const c of need) void this.chunkReady(c).then(() => warmed++);
    while (warmed < need.length && performance.now() - t0 < capMs) {
      onProgress?.(loadProgress(startLeft - need.length + warmed, startLeft));
      await new Promise((r) => setTimeout(r, 30));
    }
    // Their moon-shadow depth programs too (a synchronous compile: do it behind the veil, not when the first prop switches on).
    for (const c of need) this.warmShadows(c);
    this.warmShadowKinds();
    this.primeStats.totalMs = Math.round(performance.now() - t0);
    onProgress?.(1);
  }

  /** Called every frame: draw the areas around the player, keep the rest hidden, and keep building in the background. */
  private stream(area: AreaId | null, x: number, z: number, camera: THREE.PerspectiveCamera) {
    if (area) this.focusPriority(area);
    // What the camera really sees (its ground footprint) decides, not only distance from the hero: a wide window or the widest zoom reaches past 45 m at the screen corners.
    const v = visibleAreas(x, z, area, undefined, footprintRect(camera));
    const key = [...v].join();
    if (key !== this.wantedKey) {
      this.wantedKey = key;
      this.wanted = v;
      // Never show a hole: an area that is about to be drawn and is not built yet is built now.
      for (const id of v) this.ensureBuilt(id);
      for (const c of this.chunks.values()) this.applyShown(c);
      this.shadowDirty = true;
    }
    // Shadow casting follows the player (moves 2 m, or an area just came into view).
    // Props cast while their shadow can land on screen: at least SHADOW_RANGE, more when the footprint reaches further (the shadow pass frustum-culls what the moon camera cannot see anyway).
    const range = Math.max(SHADOW_RANGE, footprintReach(camera, x, z) + 4);
    if (this.shadowDirty || !this.shadowAt || Math.hypot(x - this.shadowAt.x, z - this.shadowAt.z) > 2 || Math.abs(range - this.shadowRange) > 3) {
      this.shadowDirty = false;
      this.shadowAt = { x, z };
      this.shadowRange = range;
      for (const c of this.chunks.values()) if (c.group.visible) for (const b of c.batches) b.updateShadows(x, z, range);
    }
    if (this.queue.size) this.queue.runSlice(1.5);
    else if (this.shadowPending.length) this.dripShadowWarm();
  }

  /** Chunks whose models are in and whose shadow-depth programs are not warmed yet. */
  private shadowPending: Chunk[] = [];
  private shadowWarmAt = 0;

  /** One chunk's shadow warm every half second once the build queue is empty, drawn-or-near areas first. */
  private dripShadowWarm() {
    const t = performance.now();
    if (t - this.shadowWarmAt < 500) return;
    this.shadowWarmAt = t;
    let i = this.shadowPending.findIndex((c) => this.wanted.has(c.id));
    if (i < 0) i = 0;
    const [chunk] = this.shadowPending.splice(i, 1);
    this.warmShadows(chunk);
  }

  /** Depth-program flavours (side / map / alpha-cut) already warmed this session: programs are shared by key, so each flavour is probed once. */
  private shadowWarmed = new Set<string>();

  /**
   * Compiles the moon-shadow depth programs of an area's tall props before the player walks in range. compileAsync only builds each material's
   * colour program; the depth variant (instanced, textured, double-sided...) is made the first time a prop actually casts, which is the moment
   * the player crosses an arch and the next room's props switch on (updateShadows): a first-use compile in the middle of a frame. So draw one
   * invisible one-instance probe per flavour, casting, once, into the same tiny target the other warm-ups use. The rest of the world is hidden
   * for that draw so it costs a shadow pass of a few probes, not a second frame.
   *
   * Order matters: WebGLShadowMap shares ONE depth material and only re-picks its program when the object kind changes (plain <-> instanced <->
   * skinned), reading the side / map it holds at that moment. A probe therefore compiles only if it follows a plain mesh: each one is preceded by a
   * tiny non-instanced caster, exactly the transition the first real draw of that flavour makes.
   */
  private warmShadows(chunk: Chunk) {
    const ctx = this.warmCtx;
    if (!ctx || !ctx.renderer.shadowMap.enabled || (typeof document !== 'undefined' && document.hidden)) return;
    const probes: { geometry: THREE.BufferGeometry; material: THREE.Material }[] = [];
    for (const b of chunk.batches) {
      for (const p of b.shadowProbes()) {
        const m = p.material as THREE.MeshStandardMaterial;
        const flavour = `${m.side}|${m.map ? 1 : 0}|${m.alphaTest > 0 ? 1 : 0}|${m.alphaMap ? 1 : 0}`;
        if (this.shadowWarmed.has(flavour)) continue;
        this.shadowWarmed.add(flavour);
        probes.push(p);
      }
    }
    if (!probes.length) return;
    const r = ctx.renderer;
    const group = new THREE.Group();
    group.name = 'warm-shadow-probes';
    const at = new THREE.Matrix4().makeScale(1e-3, 1e-3, 1e-3);
    if (this.shadowAt) at.setPosition(this.shadowAt.x, 0, this.shadowAt.z);
    const meshes: THREE.InstancedMesh[] = [];
    const plainGeo = new THREE.BoxGeometry(1e-3, 1e-3, 1e-3);
    const plainMat = new THREE.MeshBasicMaterial();
    for (const p of probes) {
      const plain = new THREE.Mesh(plainGeo, plainMat);
      plain.castShadow = true;
      plain.frustumCulled = false;
      const m = new THREE.InstancedMesh(p.geometry, p.material, 1);
      m.setMatrixAt(0, at);
      m.castShadow = true;
      m.frustumCulled = false;
      group.add(plain, m);
      meshes.push(m);
    }
    const hidden: THREE.Object3D[] = [];
    for (const c of this.chunks.values()) if (c.group.visible) hidden.push(c.group);
    if (this.fixed.visible) hidden.push(this.fixed);
    for (const o of hidden) o.visible = false;
    this.scene.add(group);
    const rt = ctx.target?.() ?? null;
    try {
      r.shadowMap.needsUpdate = true;
      if (rt) {
        r.setRenderTarget(rt);
        r.render(this.scene, ctx.camera);
      } else {
        r.setScissorTest(true);
        r.setScissor(0, 0, 1, 1);
        r.render(this.scene, ctx.camera);
      }
    } catch (err) {
      console.warn('[graphics] shadow warm failed', err);
    } finally {
      if (rt) r.setRenderTarget(null);
      else r.setScissorTest(false);
      this.scene.remove(group);
      for (const o of hidden) o.visible = true;
      for (const m of meshes) m.dispose();
      plainGeo.dispose();
      plainMat.dispose();
    }
  }

  private shadowKindsDone = false;

  /**
   * The depth programs the bodies need (see warmShadows for why order matters): skinned and plain meshes, with and without a map, front-sided
   * and double-sided. The creature stage draws every body in one pass, so only the first transition of each kind compiles; a body that first
   * casts later (an NPC or thrall stepping into the shadow range as the hero crosses an arch) then compiled its flavour mid-frame. One tiny
   * probe per kind and flavour, each after a different kind, makes every transition happen once, behind the veil.
   */
  private warmShadowKinds() {
    const ctx = this.warmCtx;
    if (this.shadowKindsDone || !ctx || !ctx.renderer.shadowMap.enabled || (typeof document !== 'undefined' && document.hidden)) return;
    this.shadowKindsDone = true;
    const r = ctx.renderer;
    const tex = new THREE.DataTexture(new Uint8Array([255, 255, 255, 255]), 1, 1);
    tex.needsUpdate = true;
    const geo = new THREE.BoxGeometry(1e-3, 1e-3, 1e-3);
    const skinned = geo.clone();
    const n = skinned.attributes.position.count;
    skinned.setAttribute('skinIndex', new THREE.Uint16BufferAttribute(new Uint16Array(n * 4), 4));
    skinned.setAttribute('skinWeight', new THREE.Float32BufferAttribute(new Float32Array(n * 4).map((_, i) => (i % 4 === 0 ? 1 : 0)), 4));
    const mats: THREE.Material[] = [];
    const group = new THREE.Group();
    group.name = 'warm-shadow-kinds';
    const kinds = ['plain', 'instanced', 'skinned'] as const;
    const make = (kind: (typeof kinds)[number], mat: THREE.Material): THREE.Mesh => {
      let m: THREE.Mesh;
      if (kind === 'instanced') {
        const im = new THREE.InstancedMesh(geo, mat, 1);
        im.setMatrixAt(0, new THREE.Matrix4().makeScale(1, 1, 1));
        m = im;
      } else if (kind === 'skinned') {
        const bone = new THREE.Bone();
        const sm = new THREE.SkinnedMesh(skinned, mat);
        sm.add(bone);
        sm.bind(new THREE.Skeleton([bone]));
        m = sm;
      } else m = new THREE.Mesh(geo, mat);
      m.castShadow = true;
      m.frustumCulled = false;
      return m;
    };
    kinds.forEach((kind, ki) => {
      for (const withMap of [false, true]) {
        for (const side of [THREE.FrontSide, THREE.DoubleSide]) {
          const mat = new THREE.MeshStandardMaterial({ side, map: withMap ? tex : null });
          mats.push(mat);
          // A different kind first, so the shared depth material re-picks its program for this one.
          group.add(make(kinds[(ki + 1) % kinds.length], mat), make(kind, mat));
        }
      }
    });
    const hidden: THREE.Object3D[] = [];
    for (const c of this.chunks.values()) if (c.group.visible) hidden.push(c.group);
    if (this.fixed.visible) hidden.push(this.fixed);
    for (const o of hidden) o.visible = false;
    this.scene.add(group);
    const rt = ctx.target?.() ?? null;
    try {
      r.shadowMap.needsUpdate = true;
      if (rt) {
        r.setRenderTarget(rt);
        r.render(this.scene, ctx.camera);
      } else {
        r.setScissorTest(true);
        r.setScissor(0, 0, 1, 1);
        r.render(this.scene, ctx.camera);
      }
    } catch (err) {
      console.warn('[graphics] shadow kinds warm failed', err);
    } finally {
      if (rt) r.setRenderTarget(null);
      else r.setScissorTest(false);
      this.scene.remove(group);
      for (const o of hidden) o.visible = true;
      group.traverse((o) => {
        const sm = o as THREE.SkinnedMesh;
        if (sm.isSkinnedMesh) sm.skeleton.dispose();
        if ((o as THREE.InstancedMesh).isInstancedMesh) (o as THREE.InstancedMesh).dispose();
      });
      for (const m of mats) m.dispose();
      geo.dispose();
      skinned.dispose();
      tex.dispose();
    }
  }

  /** QA: which areas are built and drawn. */
  streamStats() {
    const built: string[] = [];
    const shown: string[] = [];
    for (const c of this.chunks.values()) {
      if (c.built) built.push(c.id);
      if (c.group.visible) shown.push(c.id);
    }
    return { built, shown, pending: this.queue.size, prime: this.primeStats };
  }

  /** The Mourning Fen's dry ground (content/fen.ts FEN_HUMMOCKS): low peat mounds with a pale teal rim, two draw calls. */
  private buildHummocks(group: THREE.Group) {
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
    this.hummocks = { mound, rim, cur: 1, target: this.floodTarget };
    this.layoutHummocks(1);
    group.add(mound, rim);
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
    this.floodTarget = k;
    if (this.hummocks) this.hummocks.target = k;
  }
  /** Current eased flood scale (for QA). */
  fenFlood() {
    return this.hummocks?.cur ?? 1;
  }

  private matFor(theme: Theme) {
    let m = this.floorMats.get(theme);
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
      this.floorMats.set(theme, m);
    }
    return m;
  }

  private floorPlane(x0: number, z0: number, x1: number, z1: number, theme: Theme, y = 0) {
    const w = x1 - x0;
    const d = z1 - z0;
    const geo = new THREE.PlaneGeometry(w, d).rotateX(-Math.PI / 2);
    const uv = geo.attributes.uv as THREE.BufferAttribute;
    const tile = FLOOR_TEX[theme].tile;
    for (let i = 0; i < uv.count; i++) uv.setXY(i, (x0 + uv.getX(i) * w) / tile, (z0 + uv.getY(i) * d) / tile);
    const mesh = new THREE.Mesh(geo, this.matFor(theme));
    mesh.position.set((x0 + x1) / 2, y, (z0 + z1) / 2);
    mesh.receiveShadow = true;
    return mesh;
  }

  private buildFloor(chunk: Chunk, x0: number, z0: number, x1: number, z1: number, theme: Theme) {
    chunk.group.add(this.floorPlane(x0, z0, x1, z1, theme));
  }

  /** The always-drawn ground: beyond the walls, the door thresholds and the paths (a few flat quads). */
  private buildFixedFloors() {
    // Beyond the walls: dark earth swallowed by fog.
    const outside = new THREE.Mesh(
      new THREE.PlaneGeometry(420, 420).rotateX(-Math.PI / 2),
      new THREE.MeshStandardMaterial({ map: assets.texture('art/textures/grave_soil.webp', { repeat: 60 }), color: 0x3a3440, roughness: 1 }),
    );
    outside.position.set(20, -0.06, -60);
    outside.receiveShadow = true;
    this.fixed.add(outside);
    for (const d of DOORS) this.fixed.add(this.floorPlane(d.rect.x0, d.rect.z0, d.rect.x1, d.rect.z1, 'chapter', 0.005));
    for (const p of this.layout.paths) this.fixed.add(this.floorPlane(p.x0, p.z0, p.x1, p.z1, 'nave', 0.008));
  }

  private registerWalls(nav: Nav) {
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
    // Walls stay one merged mesh per texture, always drawn: a few hundred boxes, and splitting them per area only added draw calls on screen.
    for (const mesh of buildWallMeshes(this.layout.walls)) this.fixed.add(mesh);
  }

  /** Colliders and light sources are pure data: registered for the whole world at once. Only the pictures are built lazily (initChunks). */
  private registerProps(nav: Nav) {
    // One batch per prop kind *per area*: world-wide batches have world-sized bounding spheres,
    // so the camera and the moon's shadow pass could never cull a single far-off tombstone.
    for (const p of this.layout.props) {
      let byProp = this.propLists.get(p.area);
      if (!byProp) this.propLists.set(p.area, (byProp = new Map()));
      const list = byProp.get(p.prop) ?? [];
      list.push(p);
      byProp.set(p.prop, list);
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
          area: p.area,
        };
        this.lightSources.push(src);
        if (src.brazier) this.braziers.push(src);
      }
    }
  }

  private buildWindows(chunk: Chunk, windows: WorldLayout['windows']) {
    const tex = assets.texture('art/textures/stained_glass.webp');
    for (const w of windows) {
      const mat = new THREE.MeshBasicMaterial({ map: tex, color: 0xcfb8ff, transparent: true, depthWrite: false, toneMapped: false });
      const mesh = new THREE.Mesh(new THREE.PlaneGeometry(w.w, w.h), mat);
      mesh.position.set(w.x, w.y, w.z);
      mesh.rotation.y = w.facing;
      mesh.translateZ(0.5);
      chunk.group.add(mesh);
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
      chunk.group.add(shaft);
    }
  }

  /** The Alchemist's Wing's rugs and spills: thin canvas-textured planes just above the flagstones (drawn once, lit by the pools). */
  private buildWingFloor(parent: THREE.Object3D) {
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
      parent.add(mesh);
    });
  }

  private buildDecals() {
    // The windows' floor glow is a decal (one shared instanced layer), so it stays eager; the panes and shafts are built per area.
    for (const w of this.layout.windows) {
      this.effects.decal({ tex: fx.glow(), color: 0x5a3bb8, x: w.x + Math.sin(w.facing) * 5, z: w.z + Math.cos(w.facing) * 5, r: w.w, duration: 1e9, persistent: true, opacity: 0.35, fadeIn: 0.01 });
    }
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
    this.poolMat = new THREE.MeshBasicMaterial({ map: fx.lightPool(), vertexColors: true, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide });
    this.poolLists = byArea;
    const other = byArea.get('other');
    if (other) this.fixed.add(this.poolMesh(other, 'other'));
  }

  private buildPools(chunk: Chunk, list: LightSource[], area: string) {
    chunk.group.add(this.poolMesh(list, area));
  }

  private poolMesh(list: LightSource[], area: string) {
    const poolMat = this.poolMat!;
    const tint = new THREE.Color();
    {
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
      return m;
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
      this.fixed.add(markers);
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
      this.fixed.add(root);
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

  /** The candle flames' positions for the whole world (one seeded pass, so they look exactly as before), bucketed by area; the Points are built per area. */
  private buildFlameData() {
    const rand = mulberry32(99);
    for (const p of this.layout.props) {
      const spec = PROPS[p.prop].light;
      if (!spec || !spec.flames) continue;
      let d = this.flameData.get(p.area);
      if (!d) this.flameData.set(p.area, (d = { pos: [], phase: [], groups: [] }));
      for (let i = 0; i < spec.flames; i++) {
        const a = rand() * Math.PI * 2;
        const r = rand() * spec.spread * p.scale;
        d.pos.push(p.x + Math.cos(a) * r, (0.35 + rand() * 0.45) * p.scale + 0.12, p.z + Math.sin(a) * r);
        d.phase.push(rand() * 10);
        d.groups.push(p.group);
      }
    }
    this.flameMat = new THREE.ShaderMaterial({
      vertexShader: FLAME_VS,
      fragmentShader: FLAME_FS,
      uniforms: { uTime: { value: 0 }, uScale: { value: 400 }, uMap: { value: fx.glow() } },
      transparent: true,
      depthWrite: false,
      blending: THREE.AdditiveBlending,
    });
  }

  private buildFlames(chunk: Chunk, d: { pos: number[]; phase: number[]; groups: (string | undefined)[] }) {
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.Float32BufferAttribute(d.pos, 3));
    geo.setAttribute('aPhase', new THREE.Float32BufferAttribute(d.phase, 1));
    geo.setAttribute('aLit', new THREE.Float32BufferAttribute(d.groups.map((g) => (g && this.candleOff.has(g) ? 0 : 1)), 1));
    const points = new THREE.Points(geo, this.flameMat);
    // Culled per area (one sphere, padded for the flicker): the world-wide Points it replaces was drawn whole whenever anything was in view.
    geo.computeBoundingSphere();
    geo.boundingSphere!.radius += 3;
    this.flamePoints.push({ points, groups: d.groups });
    chunk.group.add(points);
  }

  /** Sanctum candle groups gutter out as the Prelate advances through phases. */
  setCandleGroup(group: string, litOn: boolean) {
    if (litOn) this.candleOff.delete(group);
    else this.candleOff.add(group);
    for (const f of this.flamePoints) {
      const attr = f.points.geometry.attributes.aLit as THREE.BufferAttribute;
      f.groups.forEach((g, i) => {
        if (g === group) attr.setX(i, litOn ? 1 : 0);
      });
      attr.needsUpdate = true;
    }
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
    this.fixed.add(this.mist);
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
    this.fixed.add(new THREE.Mesh(merged, mat));
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
    const fm = this.flameMat;
    fm.uniforms.uTime.value = this.time;
    fm.uniforms.uScale.value = scale;
    (this.mist.material as THREE.ShaderMaterial).uniforms.uScale.value = scale;

    const area = this.areaAt(focusX, focusZ);
    this.stream(area, focusX, focusZ, camera);
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
        .filter((s) => s.lit && (!s.area || this.wanted.has(s.area)))
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
