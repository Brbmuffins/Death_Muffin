import * as THREE from 'three';
import { PROPS, type Placement } from '../content/layout';
import type { DepthsFloor } from '../gameplay/depthsFloor';
import { PropBatch, buildWallMeshes, type LightSource } from './WorldView';
import { StairView } from './StairView';
import { fx } from './fxTextures';

/**
 * What a Depths floor looks like: its partitions, its dressing (the Warren's chamber kit, instanced by prop kind), the light pools under
 * its lanterns and candles, and the stairs and chest. The floor itself is the rectangle WorldView already draws for the area, so loading a
 * floor builds a few merged meshes and a few instanced batches (a handful of draw calls) and clearing one throws them away.
 * Colliders and sight blockers are the nav's business (Nav.loadDepthsFloor); this is only the picture.
 */
export class DepthsView {
  private group: THREE.Group | null = null;
  private lights: LightSource[] = [];
  private poolMat: THREE.MeshBasicMaterial | null = null;
  private poolGeos: THREE.BufferGeometry[] = [];
  private instanced: THREE.InstancedMesh[] = [];
  private stairs: { up: StairView; down: StairView; chest: StairView | null } | null = null;
  private stairLights: { down: LightSource; chest: LightSource | null } | null = null;

  constructor(
    private scene: THREE.Scene,
    /** WorldView.lightSources: lights pushed here are picked up by its pooled dynamic point lights. */
    private lightSources: LightSource[],
  ) {}

  get loaded() {
    return this.group !== null;
  }

  load(floor: DepthsFloor) {
    this.clear();
    const group = new THREE.Group();
    this.group = group;
    for (const mesh of buildWallMeshes(floor.walls)) group.add(mesh);
    // Props: one instanced batch per kind.
    const byProp = new Map<string, Placement[]>();
    for (const p of floor.props) {
      const list = byProp.get(p.prop) ?? [];
      list.push(p);
      byProp.set(p.prop, list);
      const spec = PROPS[p.prop];
      if (spec.light) {
        this.lights.push({ x: p.x, y: spec.light.y * p.scale, z: p.z, color: spec.light.color, intensity: spec.light.intensity, distance: spec.light.distance, pool: spec.light.pool, lit: true, brazier: false });
      }
    }
    for (const list of byProp.values()) {
      const batch = new PropBatch(list[0].prop, list, PROPS[list[0].prop].height > 1.5);
      group.add(batch.group);
    }
    // The stairs and the chest; their glow is a light too.
    const up = new StairView('up', floor.stairUp.x, floor.stairUp.z);
    const down = new StairView('down', floor.stairDown.x, floor.stairDown.z);
    const chest = floor.chest ? new StairView('chest', floor.chest.x, floor.chest.z) : null;
    group.add(up.group, down.group);
    if (chest) group.add(chest.group);
    this.stairs = { up, down, chest };
    const lightFor = (s: { x: number; z: number }, v: StairView): LightSource => {
      const l = v.light();
      const src: LightSource = { x: s.x, y: 1.4, z: s.z, color: l.color, intensity: l.intensity, distance: 9, lit: true, brazier: false };
      this.lights.push(src);
      return src;
    };
    lightFor(floor.stairUp, up);
    this.stairLights = { down: lightFor(floor.stairDown, down), chest: floor.chest && chest ? lightFor(floor.chest, chest) : null };
    // One baked mesh of light pools under every flame (the same trick WorldView uses): no draw call per candle.
    this.buildPools(group);
    for (const l of this.lights) this.lightSources.push(l);
    this.scene.add(group);
    // Instanced meshes need their buffers freed on clear.
    group.traverse((o) => {
      if ((o as THREE.InstancedMesh).isInstancedMesh) this.instanced.push(o as THREE.InstancedMesh);
    });
  }

  private buildPools(group: THREE.Group) {
    const pos: number[] = [];
    const uv: number[] = [];
    const col: number[] = [];
    const idx: number[] = [];
    const tint = new THREE.Color();
    for (const s of this.lights) {
      const r = s.distance * 0.42;
      tint.set(s.pool ?? 0xc9864a).multiplyScalar(0.32);
      const o = pos.length / 3;
      for (const [dx, dz, u, v] of [[-1, -1, 0, 1], [1, -1, 1, 1], [1, 1, 1, 0], [-1, 1, 0, 0]] as const) {
        pos.push(s.x + dx * r, 0.015, s.z + dz * r);
        uv.push(u, v);
        col.push(tint.r, tint.g, tint.b);
      }
      idx.push(o, o + 2, o + 1, o, o + 3, o + 2);
    }
    if (!idx.length) return;
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    g.setAttribute('color', new THREE.Float32BufferAttribute(col, 3));
    g.setIndex(idx);
    g.computeBoundingSphere();
    this.poolMat = new THREE.MeshBasicMaterial({ map: fx.lightPool(), vertexColors: true, transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide });
    this.poolGeos.push(g);
    const m = new THREE.Mesh(g, this.poolMat);
    m.renderOrder = 2;
    group.add(m);
  }

  /** The stair down is open (the quota is met) or sealed again. */
  setStairOpen(open: boolean) {
    if (!this.stairs || !this.stairLights) return;
    this.stairs.down.setState(open ? 'open' : 'sealed');
    const l = this.stairs.down.light();
    this.stairLights.down.color = l.color;
    this.stairLights.down.intensity = l.intensity;
  }

  setChestOpened(opened: boolean) {
    const c = this.stairs?.chest;
    if (!c || !this.stairLights?.chest) return;
    c.setState(opened ? 'opened' : 'sealed');
    this.stairLights.chest.intensity = c.light().intensity;
  }

  update(dt: number) {
    if (!this.stairs) return;
    this.stairs.up.update(dt);
    this.stairs.down.update(dt);
    this.stairs.chest?.update(dt);
  }

  clear() {
    if (!this.group) return;
    for (const l of this.lights) {
      const i = this.lightSources.indexOf(l);
      if (i >= 0) this.lightSources.splice(i, 1);
    }
    this.lights = [];
    for (const m of this.instanced) m.dispose();
    this.instanced = [];
    this.stairs?.up.dispose();
    this.stairs?.down.dispose();
    this.stairs?.chest?.dispose();
    this.stairs = null;
    this.stairLights = null;
    this.group.traverse((o) => {
      const m = o as THREE.Mesh;
      // Merged walls and the pool mesh own their geometry; instanced props share cached model geometry, which stays.
      if (m.isMesh && !(m as unknown as THREE.InstancedMesh).isInstancedMesh) {
        const mat = m.material as THREE.Material | undefined;
        if (mat && 'map' in mat && (mat as THREE.MeshStandardMaterial).bumpMap) {
          m.geometry.dispose();
          mat.dispose();
        }
      }
    });
    for (const g of this.poolGeos) g.dispose();
    this.poolGeos = [];
    this.poolMat?.dispose();
    this.poolMat = null;
    this.group.removeFromParent();
    this.group = null;
  }

  dispose() {
    this.clear();
  }
}
