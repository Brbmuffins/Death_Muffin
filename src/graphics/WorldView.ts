import * as THREE from 'three';
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import { AREAS, AREA_ORDER, DOORS, type AreaId, type DoorDef, type Theme } from '../content/areas';
import { PROPS, type Placement, type PropId, type WorldLayout } from '../content/layout';
import type { Nav } from '../gameplay/nav';
import { mulberry32 } from '../gameplay/rng';
import { assets } from './AssetCache';
import { fx } from './fxTextures';
import { PROP_URL } from './modelPaths';
import type { Effects } from './Effects';
import { applyOcclusion } from './occlusion';

const FLOOR_TEX: Record<Theme, { url: string; tile: number; color: number; rough: number }> = {
  chapter: { url: 'art/textures/flagstone.webp', tile: 7, color: 0x9a92a8, rough: 0.62 },
  graveyard: { url: 'art/textures/grave_soil.webp', tile: 6, color: 0xb8aab8, rough: 0.95 },
  ossuary: { url: 'art/textures/ossuary_floor.webp', tile: 6, color: 0xb0a4ae, rough: 0.9 },
  nave: { url: 'art/textures/flagstone.webp', tile: 8, color: 0x8c86a8, rough: 0.45 },
  sanctum: { url: 'art/textures/flagstone.webp', tile: 7, color: 0x9a86aa, rough: 0.5 },
};

export interface LightSource {
  x: number;
  y: number;
  z: number;
  color: number;
  intensity: number;
  distance: number;
  group?: string;
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
  }
  const merged = mergeGeometries(g.map((x) => (x.index ? x.toNonIndexed() : x)), false)!;
  merged.computeVertexNormals();
  return { geo: merged, color };
}

/**
 * Instanced batch of one prop kind. Starts with the code-built stand-in and
 * swaps to the generated GLB (every mesh instanced with the same transforms)
 * once it loads.
 */
class PropBatch {
  readonly group = new THREE.Group();
  constructor(
    private id: PropId,
    private placements: Placement[],
    private tall: boolean,
  ) {
    const { geo, color } = fallbackGeometry(id);
    const mat = new THREE.MeshStandardMaterial({ color, roughness: 0.9, metalness: 0.05 });
    this.build([{ geometry: geo, material: mat, local: new THREE.Matrix4() }], 1);
    void assets.model(PROP_URL(id), PROPS[id].height).then((t) => {
      if (!t) return;
      t.scene.updateMatrixWorld(true);
      const bounds = new THREE.Box3().setFromObject(t.scene);
      const center = bounds.getCenter(new THREE.Vector3());
      const norm = new THREE.Matrix4()
        .makeTranslation(-center.x * t.scale, t.groundOffset, -center.z * t.scale)
        .multiply(new THREE.Matrix4().makeScale(t.scale, t.scale, t.scale));
      const parts: { geometry: THREE.BufferGeometry; material: THREE.Material; local: THREE.Matrix4 }[] = [];
      t.scene.traverse((o) => {
        const m = o as THREE.Mesh;
        if (m.isMesh) parts.push({ geometry: m.geometry, material: m.material as THREE.Material, local: norm.clone().multiply(m.matrixWorld) });
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
    for (const part of parts) {
      if (this.tall) applyOcclusion(part.material);
      const inst = new THREE.InstancedMesh(part.geometry, part.material, this.placements.length);
      this.placements.forEach((pl, i) => {
        e.set(pl.tilt ?? 0, pl.rot, (pl.tilt ?? 0) * 0.6);
        q.setFromEuler(e);
        s.setScalar(pl.scale);
        p.set(pl.x, 0, pl.z);
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

/** Box geometry with world-space UVs so one repeating material fits any size. */
function worldUvBox(w: number, h: number, d: number, tile: number) {
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
    this.buildWindows();
    this.buildDecals();
    this.buildGates();
    this.buildFlames();
    this.buildMist();
    for (let i = 0; i < 5; i++) {
      const l = new THREE.PointLight(0xffb46b, 0, 8, 1.8);
      this.group.add(l);
      this.pointLights.push(l);
    }
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
    const byTex = new Map<string, THREE.BufferGeometry[]>();
    for (const w of this.layout.walls) {
      const horizontal = Math.abs(w.z1 - w.z0) < 1e-3;
      const len = horizontal ? w.x1 - w.x0 : w.z1 - w.z0;
      const geo = horizontal ? worldUvBox(len, w.height, w.thickness, 4) : worldUvBox(w.thickness, w.height, len, 4);
      geo.translate((w.x0 + w.x1) / 2, w.height / 2, (w.z0 + w.z1) / 2);
      const list = byTex.get(w.texture) ?? [];
      list.push(geo);
      byTex.set(w.texture, list);
      // Interior partitions block movement (edge walls sit outside the walkable rect).
      const hw = horizontal ? len / 2 : w.thickness / 2;
      const hd = horizontal ? w.thickness / 2 : len / 2;
      nav.addObstacle({ kind: 'box', x0: (w.x0 + w.x1) / 2 - hw, z0: (w.z0 + w.z1) / 2 - hd, x1: (w.x0 + w.x1) / 2 + hw, z1: (w.z0 + w.z1) / 2 + hd });
    }
    for (const [tex, geos] of byTex) {
      const merged = mergeGeometries(geos, false);
      if (!merged) continue;
      const mesh = new THREE.Mesh(
        merged,
        new THREE.MeshStandardMaterial({
          map: assets.texture(`art/textures/${tex}.webp`, { repeat: 1 }),
          bumpMap: assets.texture(`art/textures/${tex}.webp`, { repeat: 1 }),
          bumpScale: 3,
          color: tex === 'skull_wall' ? 0xc2b8ae : 0x9a92a4,
          roughness: 0.92,
        }),
      );
      mesh.castShadow = true;
      mesh.receiveShadow = true;
      applyOcclusion(mesh.material as THREE.Material);
      this.group.add(mesh);
    }
  }

  private buildProps(nav: Nav) {
    const byProp = new Map<PropId, Placement[]>();
    for (const p of this.layout.props) {
      const list = byProp.get(p.prop) ?? [];
      list.push(p);
      byProp.set(p.prop, list);
      const spec = PROPS[p.prop];
      const c = spec.collider;
      if (c?.kind === 'circle') nav.addObstacle({ kind: 'circle', x: p.x, z: p.z, r: c.r * p.scale });
      else if (c?.kind === 'box') {
        // Axis-aligned approximation of the rotated footprint.
        const cos = Math.abs(Math.cos(p.rot));
        const sin = Math.abs(Math.sin(p.rot));
        const hw = (c.hw * cos + c.hd * sin) * p.scale;
        const hd = (c.hw * sin + c.hd * cos) * p.scale;
        nav.addObstacle({ kind: 'box', x0: p.x - hw, z0: p.z - hd, x1: p.x + hw, z1: p.z + hd });
      }
      if (spec.light) {
        const src: LightSource = {
          x: p.x,
          y: spec.light.y * p.scale,
          z: p.z,
          color: spec.light.color,
          intensity: spec.light.intensity,
          distance: spec.light.distance,
          group: p.group,
          lit: true,
          brazier: p.prop === 'brazier',
        };
        this.lightSources.push(src);
        if (src.brazier) this.braziers.push(src);
      }
    }
    for (const [id, list] of byProp) {
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
      this.effects.decal({ tex: fx.glow(), color: 0x5a3bb8, x: shaft.position.x, z: shaft.position.z, r: w.w, duration: 1e9, opacity: 0.35, fadeIn: 0.01 });
    }
  }

  private buildDecals() {
    for (const d of this.layout.decals) {
      const tex = d.kind === 'sigil' ? fx.sigil() : fx.cracks();
      this.effects.decal({ tex, color: d.color, x: d.x, z: d.z, r: d.r, rot: d.rot, duration: 1e9, opacity: d.opacity, fadeIn: 0.01, y: 0.02, spin: d.kind === 'sigil' ? 0.03 : 0 });
    }
    // Light pools under every flame source: fake bounce light, zero per-pixel cost.
    for (const s of this.lightSources) {
      this.effects.decal({
        tex: fx.lightPool(),
        color: s.brazier ? 0x7a4fd6 : 0xc9864a,
        x: s.x,
        z: s.z,
        r: s.distance * 0.42,
        duration: 1e9,
        opacity: s.brazier ? 0.5 : 0.32,
        fadeIn: 0.01,
        y: 0.015,
      });
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

  update(dt: number, focusX: number, focusZ: number, camera: THREE.PerspectiveCamera, viewportHeight: number) {
    this.time += dt;
    const scale = (viewportHeight * 0.5) / Math.tan(THREE.MathUtils.degToRad(camera.fov) / 2);
    const fm = this.flames.material as THREE.ShaderMaterial;
    fm.uniforms.uTime.value = this.time;
    fm.uniforms.uScale.value = scale;
    (this.mist.material as THREE.ShaderMaterial).uniforms.uScale.value = scale;

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
      if (Math.random() < dt * 16) {
        this.effects.emit({ x: b.x, y: b.y, z: b.z, count: 1, color: Math.random() < 0.7 ? 0x8a5cf0 : 0xc6a4ff, spread: 0.18, speed: 0.1, up: 1, life: 0.5, size: 0.3, gravity: -0.8 });
      }
      if (Math.random() < dt * 2) {
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
