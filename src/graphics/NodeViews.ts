import * as THREE from 'three';
import { mergeGeometries } from 'three/examples/jsm/utils/BufferGeometryUtils.js';
import type { NodePlacement } from '../content/layout';
import { NODES, SKILLS, type NodeDef, type NodeKind } from '../gameplay/gatheringRules';
import { assets } from './AssetCache';
import { PROP_URL } from './modelPaths';

/**
 * Gathering nodes in the world (roadmap §7/§10). Each node type has a live and
 * a depleted look, drawn as one InstancedMesh per (type, state); swapping state
 * just moves an instance between the two. Code-built stand-ins show until the
 * pipeline GLB `models/props/prop_node_<model>.glb` exists (checked with a
 * HEAD request, so a missing model costs no console noise).
 *
 * Ore tint (ASSET_PIPELINE.md): one seam model serves every ore; the vein colour
 * comes from a small emissive crystal overlay, never a recoloured bake.
 */

/** Pipeline model names (art-manifest/tripo-specs/prop_node_*.json) per node, live and spent. */
const MODEL: Record<string, { live?: string; spent?: string; height: number; spentHeight: number }> = {
  coffin_oak: { live: 'prop_node_coffin_oak', spent: 'prop_node_stump', height: 4.4, spentHeight: 0.9 },
  hangman_elm: { live: 'prop_node_hangman_elm', spent: 'prop_node_stump', height: 5, spentHeight: 0.9 },
  bleeding_willow: { live: 'prop_node_bleeding_willow', spent: 'prop_node_stump', height: 4.8, spentHeight: 0.9 },
  churchyard_yew: { live: 'prop_node_churchyard_yew', spent: 'prop_node_stump', height: 5.4, spentHeight: 1 },
  blackthorn: { live: 'prop_node_blackthorn', spent: 'prop_node_stump', height: 4.6, spentHeight: 0.9 },
  ghostwood: { live: 'prop_node_ghostwood', spent: 'prop_node_stump', height: 5.2, spentHeight: 1 },
  bone_elder: { live: 'prop_node_bone_elder', spent: 'prop_node_stump', height: 6, spentHeight: 1.1 },
  geode_hell: { live: 'prop_node_ore_geode', spent: 'prop_node_ore_spent', height: 1.5, spentHeight: 0.6 },
  geode_moon: { live: 'prop_node_ore_geode', spent: 'prop_node_ore_spent', height: 1.6, spentHeight: 0.6 },
  // Higher gravedigging sites have their own models; the pauper's grave and mound use graveModel.
  grave_crypt: { live: 'prop_node_crypt_collapse', spent: 'prop_node_dug_grave', height: 1.2, spentHeight: 0.5 },
  grave_barrow_king: { live: 'prop_node_barrow_tomb', spent: 'prop_node_dug_grave', height: 2, spentHeight: 0.5 },
};
const seamModel = { live: 'prop_node_ore_seam', spent: 'prop_node_ore_spent', height: 1.2, spentHeight: 0.6 };
const graveModel = { live: 'prop_node_burial_mound', spent: 'prop_node_dug_grave', height: 0.6, spentHeight: 0.5 };
const modelFor = (def: NodeDef) => MODEL[def.id] ?? (def.kind === 'seam' ? seamModel : def.kind === 'grave' ? graveModel : { height: 1, spentHeight: 0.5 });

const present = new Map<string, Promise<boolean>>();
/** A GLB exists (and isn't the dev server's HTML fallback). */
function modelExists(url: string) {
  let p = present.get(url);
  if (!p) {
    p = fetch(url, { method: 'HEAD' })
      .then((r) => r.ok && !(r.headers.get('content-type') ?? '').includes('text/html'))
      .catch(() => false);
    present.set(url, p);
  }
  return p;
}

interface Part {
  geo: THREE.BufferGeometry;
  mat: THREE.Material;
}

function merged(parts: THREE.BufferGeometry[]) {
  const g = mergeGeometries(parts.map((x) => (x.index ? x.toNonIndexed() : x)), false)!;
  g.computeVertexNormals();
  return g;
}

const col = (hex: number, k = 1) => new THREE.Color(hex).multiplyScalar(k);
const INDICATOR_BONE = new THREE.Color(0xc8bea8);

/** Code-built look for a node kind (live or spent). */
function standIn(def: NodeDef, spent: boolean): Part[] {
  const out: Part[] = [];
  const mat = (color: number | THREE.Color, rough = 0.9, emissive?: THREE.Color, ei = 0) =>
    new THREE.MeshStandardMaterial({ color, roughness: rough, metalness: 0.05, emissive: emissive ?? new THREE.Color(0), emissiveIntensity: ei });
  const cyl = (rt: number, rb: number, h: number, x = 0, y = 0, z = 0, seg = 7) => new THREE.CylinderGeometry(rt, rb, h, seg).translate(x, y + h / 2, z);
  const blob = (r: number, x: number, y: number, z: number, sy = 1) => new THREE.IcosahedronGeometry(r, 0).scale(1, sy, 1).translate(x, y, z);
  const kind: NodeKind = def.kind;
  const s = modelFor(def).height;
  if (kind === 'tree') {
    if (spent) {
      out.push({ geo: merged([cyl(0.34, 0.42, 0.5), cyl(0.06, 0.12, 0.5, 0.3, 0, 0.1, 5).rotateZ(-0.6)]), mat: mat(0x4a3a2c) });
      return out;
    }
    const trunk = merged([cyl(0.14 * s * 0.25, 0.26 * s * 0.22, s * 0.62), cyl(0.04, 0.1, s * 0.3, 0.1, s * 0.42, 0, 5).rotateZ(-0.7)]);
    out.push({ geo: trunk, mat: mat(def.id === 'bone_elder' || def.id === 'ghostwood' ? 0xcfc6b2 : 0x3c2e24) });
    const crown = merged([
      blob(s * 0.24, 0, s * 0.72, 0, 0.8),
      blob(s * 0.18, s * 0.17, s * 0.62, s * 0.05, 0.8),
      blob(s * 0.17, -s * 0.15, s * 0.64, -s * 0.07, 0.8),
      blob(s * 0.14, 0.05, s * 0.9, 0.05, 0.9),
    ]);
    const glow = def.id === 'ghostwood' || def.id === 'bone_elder';
    out.push({ geo: crown, mat: mat(col(def.tint, 0.9), 0.95, glow ? col(def.tint, 0.4) : undefined, glow ? 0.15 : 0) });
    return out;
  }
  if (kind === 'seam' || kind === 'geode') {
    const big = kind === 'geode' ? 1.35 : 1;
    if (spent) {
      out.push({ geo: merged([blob(0.28, -0.25, 0.14, 0.1, 0.6), blob(0.22, 0.2, 0.12, -0.1, 0.6), blob(0.18, 0.05, 0.1, 0.28, 0.6)]), mat: mat(0x3e3a40) });
      return out;
    }
    out.push({ geo: merged([blob(0.62 * big, 0, 0.45 * big, 0, 0.85), blob(0.42 * big, 0.45 * big, 0.3 * big, 0.15, 0.8), blob(0.38 * big, -0.4 * big, 0.28 * big, -0.2, 0.8)]), mat: mat(0x4a4550) });
    const shard = (x: number, y: number, z: number, h: number, rx: number, rz: number) =>
      new THREE.ConeGeometry(0.08 * big, h * big, 4).translate(0, (h * big) / 2, 0).rotateX(rx).rotateZ(rz).translate(x * big, y * big, z * big);
    const veins = merged([shard(0.2, 0.5, 0.45, 0.4, 0.5, -0.3), shard(-0.25, 0.45, 0.42, 0.34, 0.6, 0.4), shard(0.45, 0.35, 0.3, 0.3, 0.3, -0.8), shard(-0.05, 0.75, 0.3, 0.36, 0.3, 0.1)]);
    out.push({ geo: veins, mat: mat(col(def.tint), 0.35, col(def.tint), kind === 'geode' ? 0.9 : 0.55) });
    return out;
  }
  if (kind === 'grave') {
    const lvl = def.level;
    if (spent) {
      out.push({ geo: new THREE.CircleGeometry(0.7, 12).rotateX(-Math.PI / 2).translate(0, 0.02, 0), mat: mat(0x0e0b0a, 1) });
      out.push({ geo: merged([blob(0.35, 0.8, 0.15, 0.1, 0.5), blob(0.25, 0.65, 0.12, -0.35, 0.5)]), mat: mat(0x4a3c2c) });
      return out;
    }
    const w = 0.55 + Math.min(0.5, lvl / 140);
    out.push({ geo: blob(w, 0, 0.12, 0, 0.35).scale(1, 1, 1.5), mat: mat(col(def.tint), 1) });
    const stone = lvl >= 70 ? new THREE.BoxGeometry(0.9, 1.1, 0.25).translate(0, 0.55, -0.9) : new THREE.BoxGeometry(0.5, 0.7, 0.14).translate(0, 0.35, -0.85);
    out.push({ geo: stone, mat: mat(lvl >= 40 ? 0x6a6470 : 0x55505a) });
    return out;
  }
  // Pool: a fishing spot on the water — ripples + bubbles, nothing when it has drifted away.
  if (spent) return out;
  const ring = merged([new THREE.RingGeometry(0.32, 0.37, 20), new THREE.RingGeometry(0.72, 0.77, 24)].map((g) => g.rotateX(-Math.PI / 2).translate(0, 0.05, 0)));
  out.push({ geo: ring, mat: new THREE.MeshBasicMaterial({ color: col(def.tint, 2), transparent: true, opacity: 0.28, depthWrite: false }) });
  return out;
}

class NodeBatch {
  readonly group = new THREE.Group();
  private meshes: THREE.InstancedMesh[] = [];
  private visible: boolean[];
  private dummy = new THREE.Object3D();

  constructor(
    private def: NodeDef,
    private spent: boolean,
    private placements: NodePlacement[],
  ) {
    this.visible = placements.map(() => !spent);
    this.group.visible = !spent;
    this.build(standIn(def, spent).map((p) => ({ ...p, local: new THREE.Matrix4() })));
    const m = modelFor(def);
    const name = spent ? m.spent : m.live;
    if (!name) return;
    const url = PROP_URL(name);
    void modelExists(url).then((ok) => {
      if (!ok) return;
      void assets.model(url, spent ? m.spentHeight : m.height).then((t) => {
        if (!t) return;
        t.scene.updateMatrixWorld(true);
        const bounds = new THREE.Box3().setFromObject(t.scene);
        const c = bounds.getCenter(new THREE.Vector3());
        const norm = new THREE.Matrix4().makeTranslation(-c.x * t.scale, t.groundOffset, -c.z * t.scale).multiply(new THREE.Matrix4().makeScale(t.scale, t.scale, t.scale));
        const parts: { geo: THREE.BufferGeometry; mat: THREE.Material; local: THREE.Matrix4 }[] = [];
        t.scene.traverse((o) => {
          const mesh = o as THREE.Mesh;
          if (mesh.isMesh) parts.push({ geo: mesh.geometry, mat: mesh.material as THREE.Material, local: norm.clone().multiply(mesh.matrixWorld) });
        });
        if (!parts.length) return;
        // Keep the code-built vein overlay on seams/geodes: it carries the ore colour.
        const keep = !spent && (def.kind === 'seam' || def.kind === 'geode') ? standIn(def, false).slice(1).map((p) => ({ ...p, local: new THREE.Matrix4() })) : [];
        for (const mesh of this.meshes) this.group.remove(mesh);
        this.meshes = [];
        this.build([...parts, ...keep]);
      });
    });
  }

  private build(parts: { geo: THREE.BufferGeometry; mat: THREE.Material; local: THREE.Matrix4 }[]) {
    for (const part of parts) {
      const inst = new THREE.InstancedMesh(part.geo, part.mat, this.placements.length);
      inst.userData.local = part.local;
      inst.castShadow = this.def.kind === 'tree' && !this.spent;
      inst.receiveShadow = true;
      this.meshes.push(inst);
      this.group.add(inst);
    }
    this.placements.forEach((_, i) => this.write(i));
    for (const m of this.meshes) m.computeBoundingSphere();
  }

  private write(i: number) {
    const p = this.placements[i];
    const d = this.dummy;
    d.position.set(p.x, 0, p.z);
    d.rotation.set(0, p.rot, 0);
    d.scale.setScalar(this.visible[i] ? (p.rich ? 1.12 : 1) : 0);
    d.updateMatrix();
    for (const m of this.meshes) {
      m.setMatrixAt(i, d.matrix.clone().multiply(m.userData.local as THREE.Matrix4));
      m.instanceMatrix.needsUpdate = true;
    }
  }

  set(i: number, on: boolean) {
    if (this.visible[i] === on) return;
    this.visible[i] = on;
    this.group.visible = this.visible.some(Boolean);
    this.write(i);
    for (const mesh of this.meshes) mesh.computeBoundingSphere();
  }
}

/** Every node's live/spent look, the hover ring and the gatherer's progress arc. */
export class NodeViews {
  readonly group = new THREE.Group();
  private index = new Map<string, { live: NodeBatch; spent: NodeBatch; i: number }>();
  private hoverRing: THREE.Mesh;
  private selectedRing: THREE.Mesh<THREE.RingGeometry, THREE.MeshBasicMaterial>;
  private arc: THREE.Mesh;
  private arcMat: THREE.MeshBasicMaterial;
  private richGlow: THREE.InstancedMesh | null = null;
  private time = 0;
  private pools: { materials: THREE.MeshBasicMaterial[]; phase: number }[] = [];

  constructor(scene: THREE.Scene, private placements: NodePlacement[]) {
    scene.add(this.group);
    // Keep bounds local to each area so distant gathering scenery is culled
    // during combat instead of sharing one world-spanning instance batch.
    const byType = new Map<string, NodePlacement[]>();
    for (const p of placements) {
      if (!NODES[p.type]) continue;
      const key = `${p.area}:${p.type}`;
      const list = byType.get(key) ?? [];
      list.push(p);
      byType.set(key, list);
    }
    for (const list of byType.values()) {
      const type = list[0].type;
      const def = NODES[type];
      const live = new NodeBatch(def, false, list);
      const spent = new NodeBatch(def, true, list);
      this.group.add(live.group, spent.group);
      list.forEach((p, i) => this.index.set(p.id, { live, spent, i }));
      if (def.kind === 'pool') this.pools.push({ materials: live.group.children.map(m => (m as THREE.Mesh).material as THREE.MeshBasicMaterial), phase: type.length });
    }
    // Rich nodes: a faint glow disc so fighters notice them.
    const rich = placements.filter((p) => p.rich);
    if (rich.length) {
      const g = new THREE.CircleGeometry(1.4, 24).rotateX(-Math.PI / 2).translate(0, 0.03, 0);
      const m = new THREE.MeshBasicMaterial({ color: 0xd9c27a, transparent: true, opacity: 0.16, depthWrite: false, blending: THREE.AdditiveBlending });
      this.richGlow = new THREE.InstancedMesh(g, m, rich.length);
      const d = new THREE.Object3D();
      rich.forEach((p, i) => {
        d.position.set(p.x, 0, p.z);
        d.updateMatrix();
        this.richGlow!.setMatrixAt(i, d.matrix);
      });
      this.group.add(this.richGlow);
    }
    this.hoverRing = new THREE.Mesh(
      new THREE.RingGeometry(1.05, 1.22, 40).rotateX(-Math.PI / 2),
      new THREE.MeshBasicMaterial({ color: 0xe8dcc0, transparent: true, opacity: 0.6, depthWrite: false }),
    );
    this.hoverRing.visible = false;
    this.hoverRing.renderOrder = 3;
    // Keep the interaction circle visible while Auto or AFK moves between nodes.
    this.selectedRing = new THREE.Mesh(
      new THREE.RingGeometry(0.9, 1.02, 40).rotateX(-Math.PI / 2),
      new THREE.MeshBasicMaterial({ color: 0xe8dcc0, transparent: true, opacity: 0.45, depthWrite: false }),
    );
    this.selectedRing.visible = false;
    this.selectedRing.renderOrder = 3;
    // Actual ring geometry cannot become an opaque square if a custom shader fails.
    this.arcMat = new THREE.MeshBasicMaterial({ color: 0xe8dcc0, transparent: true, opacity: 0.74, depthWrite: false });
    this.arc = new THREE.Mesh(new THREE.RingGeometry(0.62, 0.8, 48).rotateX(-Math.PI / 2), this.arcMat);
    this.arc.visible = false;
    this.arc.renderOrder = 3;
    this.group.add(this.hoverRing, this.selectedRing, this.arc);
  }

  /** Show a node live (true) or spent (false). */
  setLive(id: string, live: boolean) {
    const e = this.index.get(id);
    if (!e) return;
    e.live.set(e.i, live);
    e.spent.set(e.i, !live);
  }

  hover(node: NodePlacement | null, usable = true) {
    this.hoverRing.visible = !!node;
    if (!node) return;
    const def = NODES[node.type];
    const scale = def.kind === 'tree' ? 1 : def.kind === 'pool' ? 1.25 : 0.95;
    this.hoverRing.position.set(node.x, 0.04, node.z);
    this.hoverRing.scale.setScalar(scale);
    const color = (this.hoverRing.material as THREE.MeshBasicMaterial).color;
    color.set(usable ? SKILLS[def.skill].color : '#c0504d');
    if (usable) color.lerp(INDICATOR_BONE, 0.25);
  }

  /** The current gathering target, including walking and respawn waits. */
  selected(node: NodePlacement | null) {
    this.selectedRing.visible = !!node;
    if (!node) return;
    const def = NODES[node.type];
    this.selectedRing.position.set(node.x, 0.035, node.z);
    this.selectedRing.scale.setScalar(def.kind === 'pool' ? 1.25 : def.kind === 'tree' ? 1 : 0.95);
    this.selectedRing.material.color.set(SKILLS[def.skill].color).lerp(INDICATOR_BONE, 0.4);
  }

  /** The progress arc under the hero while a work cycle runs (0 hides it). */
  progress(x: number, z: number, t: number, skillColor: string) {
    this.arc.visible = t > 0;
    if (!this.arc.visible) return;
    this.arc.position.set(x, 0.05, z);
    this.arc.geometry.setDrawRange(0, Math.ceil(THREE.MathUtils.clamp(t, 0, 1) * 48) * 6);
    this.arcMat.color.set(skillColor).lerp(INDICATOR_BONE, 0.3);
  }

  update(dt: number) {
    this.time += dt;
    this.selectedRing.material.opacity = 0.42 + Math.sin(this.time * 1.8) * 0.06;
    // Fishing spots breathe: a slow pulse so the eye finds them on dark water.
    for (const p of this.pools) {
      const opacity = 0.28 + Math.sin(this.time * 1.2 + p.phase) * 0.05;
      for (const material of p.materials) material.opacity = opacity;
    }
  }

  dispose() {
    this.group.removeFromParent();
    this.group.traverse((o) => {
      const m = o as THREE.Mesh;
      if (m.isMesh) m.geometry.dispose();
    });
  }
}
