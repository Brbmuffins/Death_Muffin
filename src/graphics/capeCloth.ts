import * as THREE from 'three';

/**
 * Cape cloth (docs/GEAR-VISUALS-PLAN.md, Phase 5): the cape's cloth meshes (body, hem, collar and clasp) are moved vertex by vertex from a
 * short verlet chain, then pushed out of capsules taken from the hero's bones (torso, chest, thighs, calves), so the hem no longer
 * cuts through the legs. No new shader, material or draw call: the same geometries are rewritten in place, and the whole step
 * allocates nothing (typed-array scratch only).
 *
 * The chain has CHAIN_SEGMENTS + 1 nodes hung from the shoulders. Each node is pulled toward a target between "along the spine"
 * (the old rigid cape) and "straight down" (a cape hangs), keeps its segment length, and drags behind the body through its own
 * inertia. Every cloth vertex sits on its ring: node position plus the rest offset of that vertex around the spine axis, carried
 * by the spine's rotation.
 */

export const CHAIN_SEGMENTS = 4;
const NODES = CHAIN_SEGMENTS + 1;
/** Share of the target that hangs straight down instead of following the spine's lean. */
const HANG = 0.7;
const CLEARANCE = 0.014;
/** More than this far between two steps is a teleport (or a hidden cape returning): the chain snaps instead of whipping. */
const SNAP_DIST = 1.2;
const MAX_DT = 1 / 30;

export interface ClothData {
  body: THREE.Mesh;
  hem: THREE.Mesh;
  collar: THREE.Mesh;
  clasp: THREE.Mesh;
  /** Cloth height on the spine axis, metres of the cape's own (pre-scale) units. */
  height: number;
}

/** Capsule bones: [name a, name b, share-of-length radius key]. Index order is the collision order. */
const CAPS: [string, string][] = [
  ['Hip', 'Spine02'], ['Spine02', 'Head'],
  ['L_Thigh', 'L_Calf'], ['R_Thigh', 'R_Calf'], ['L_Calf', 'L_Foot'], ['R_Calf', 'R_Foot'],
  ['L_Upperarm', 'L_Forearm'], ['R_Upperarm', 'R_Forearm'],
];
const CAP_BONES = /^(Hip|Pelvis|Waist|Spine01|Spine02)$|^(Spine02|NeckTwist0\d)$|^L_(Thigh|ThighTwist)|^R_(Thigh|ThighTwist)|^L_(Calf|CalfTwist)|^R_(Calf|CalfTwist)|^[LR]_Upperarm/;
const CAP_OWNERS: RegExp[] = [
  /^(Hip|Pelvis|Waist|Spine01|Spine02)$/, /^(Spine02|NeckTwist0\d)$/,
  /^L_(Thigh|ThighTwist)/, /^R_(Thigh|ThighTwist)/, /^L_(Calf|CalfTwist)/, /^R_(Calf|CalfTwist)/,
  /^L_Upperarm/, /^R_Upperarm/,
];

/** Radius / segment length per capsule, measured once per skinned geometry (bind pose; cached). */
const fractionCache = new WeakMap<THREE.BufferGeometry, Float32Array>();

function bindFractions(mesh: THREE.SkinnedMesh): Float32Array | null {
  const cached = fractionCache.get(mesh.geometry);
  if (cached) return cached;
  const bones = mesh.skeleton.bones;
  const index = new Map<string, number>();
  bones.forEach((b, i) => index.set(b.name, i));
  const bindPos = (name: string): THREE.Vector3 | null => {
    const i = index.get(name);
    if (i === undefined) return null;
    return new THREE.Vector3().setFromMatrixPosition(new THREE.Matrix4().copy(mesh.skeleton.boneInverses[i]).invert());
  };
  const ends = CAPS.map(([a, b]) => [bindPos(a), bindPos(b)] as const);
  if (ends.some(([a, b]) => !a || !b)) return null;
  const si = mesh.geometry.getAttribute('skinIndex');
  const sw = mesh.geometry.getAttribute('skinWeight');
  const pos = mesh.geometry.getAttribute('position');
  if (!si || !sw || !pos) return null;
  const dist: number[][] = CAPS.map(() => []);
  const v = new THREE.Vector3();
  const ab = new THREE.Vector3();
  const ap = new THREE.Vector3();
  for (let i = 0; i < pos.count; i += 2) {
    let best = 0;
    let bw = -1;
    for (let k = 0; k < 4; k++) {
      const w = sw.getComponent(i, k);
      if (w > bw) { bw = w; best = si.getComponent(i, k); }
    }
    const name = bones[best]?.name ?? '';
    if (!CAP_BONES.test(name)) continue;
    v.fromBufferAttribute(pos, i).applyMatrix4(mesh.bindMatrix);
    for (let c = 0; c < CAPS.length; c++) {
      if (!CAP_OWNERS[c].test(name)) continue;
      const [a, b] = ends[c];
      ab.subVectors(b!, a!);
      ap.subVectors(v, a!);
      const t = Math.max(0, Math.min(1, ap.dot(ab) / Math.max(1e-9, ab.lengthSq())));
      dist[c].push(v.distanceTo(ap.copy(a!).addScaledVector(ab, t)));
    }
  }
  const out = new Float32Array(CAPS.length + HEAD_SLOTS);
  for (let c = 0; c < CAPS.length; c++) {
    const s = dist[c].sort((x, y) => x - y);
    const len = ends[c][0]!.distanceTo(ends[c][1]!);
    out[c] = s.length && len > 1e-6 ? s[Math.floor((s.length - 1) * 0.2)] / len : 0.2;
  }
  headFit(mesh, bones, index, out);
  fractionCache.set(mesh.geometry, out);
  return out;
}

const HEAD_SLOTS = 7;

/**
 * The head as a short capsule on the bone's own up axis, as the clip harness measures it: from 40% to 75% of the way up to
 * the crown, radius a low percentile of the skull's horizontal spread. Written after the body fractions:
 * [up x, y, z (bone-local), c0, c1, radius, Spine02-to-Head length], all in bind units.
 */
function headFit(mesh: THREE.SkinnedMesh, bones: THREE.Bone[], index: Map<string, number>, out: Float32Array) {
  const hi = index.get('Head');
  const si = mesh.geometry.getAttribute('skinIndex');
  const sw = mesh.geometry.getAttribute('skinWeight');
  const pos = mesh.geometry.getAttribute('position');
  const pts: THREE.Vector3[] = [];
  for (let i = 0; i < pos.count; i += 2) {
    let best = 0;
    let bw = -1;
    for (let k = 0; k < 4; k++) {
      const w = sw.getComponent(i, k);
      if (w > bw) { bw = w; best = si.getComponent(i, k); }
    }
    if (best === hi) pts.push(new THREE.Vector3().fromBufferAttribute(pos, i).applyMatrix4(mesh.bindMatrix));
  }
  const o = CAPS.length;
  const headInv = hi === undefined ? null : mesh.skeleton.boneInverses[hi];
  const spineInv = mesh.skeleton.boneInverses[index.get('Spine02') ?? 0];
  if (!headInv || !pts.length || !spineInv) return;
  const base = new THREE.Vector3().setFromMatrixPosition(new THREE.Matrix4().copy(headInv).invert());
  const centroid = new THREE.Vector3();
  pts.forEach((p) => centroid.add(p));
  centroid.divideScalar(pts.length);
  const upW = centroid.clone().sub(base).normalize();
  const up = upW.clone().transformDirection(headInv); // the bind-world direction in the bone's frame
  const crown = Math.max(...pts.map((p) => p.clone().sub(base).dot(upW)));
  const spread = pts.map((p) => { const d = p.clone().sub(base); return d.addScaledVector(upW, -d.dot(upW)).length(); }).sort((a, b) => a - b);
  out[o] = up.x; out[o + 1] = up.y; out[o + 2] = up.z;
  out[o + 3] = crown * 0.4;
  out[o + 4] = crown * 0.75;
  out[o + 5] = spread[Math.floor((spread.length - 1) * 0.3)];
  out[o + 6] = base.distanceTo(new THREE.Vector3().setFromMatrixPosition(new THREE.Matrix4().copy(spineInv).invert()));
  void bones;
}

interface ClothMesh {
  geo: THREE.BufferGeometry;
  pos: Float32Array;
  rest: Float32Array;
  /** Per vertex: node index (lower), blend toward the next node, and the rest offset from the spine axis (x, z). */
  node: Uint8Array;
  frac: Float32Array;
  off: Float32Array;
  count: number;
}

function clothMesh(mesh: THREE.Mesh, height: number): ClothMesh {
  const geo = mesh.geometry;
  const attr = geo.getAttribute('position') as THREE.BufferAttribute;
  const n = attr.count;
  const pos = attr.array as Float32Array;
  const rest = new Float32Array(pos);
  const node = new Uint8Array(n);
  const frac = new Float32Array(n);
  const off = new Float32Array(n * 2);
  for (let i = 0; i < n; i++) {
    const u = Math.max(0, Math.min(CHAIN_SEGMENTS, (-rest[i * 3 + 1] / height) * CHAIN_SEGMENTS));
    const k = Math.min(CHAIN_SEGMENTS - 1, Math.floor(u));
    node[i] = k;
    frac[i] = u - k;
    off[i * 2] = rest[i * 3];
    off[i * 2 + 1] = rest[i * 3 + 2];
  }
  mesh.frustumCulled = false; // the cloth moves well outside its rest bounds
  return { geo, pos, rest, node, frac, off, count: n };
}

export class CapeCloth {
  /** True once the chain has moved the geometry off its rest shape. */
  deformed = false;
  private readonly group: THREE.Object3D;
  private readonly spine: THREE.Object3D;
  private readonly world: THREE.Object3D[] = [];
  private readonly capA: THREE.Object3D[] = [];
  private readonly capB: THREE.Object3D[] = [];
  private readonly fractions: Float32Array;
  private readonly meshes: ClothMesh[];
  private readonly height: number;
  private readonly inv = new THREE.Matrix4();
  private readonly m = new THREE.Matrix4();
  /** Node world positions, previous positions and targets (x, y, z per node). */
  private readonly p = new Float32Array(NODES * 3);
  private readonly q = new Float32Array(NODES * 3);
  private readonly t = new Float32Array(NODES * 3);
  /** Capsule endpoints (a, b) and radius. */
  private readonly cap = new Float32Array((CAPS.length + 1) * 7);
  private readonly headBone: THREE.Object3D;
  private primed = false;
  private readonly last = new Float64Array(3);

  private constructor(group: THREE.Object3D, spine: THREE.Object3D, bones: THREE.Object3D[][], fractions: Float32Array, data: ClothData) {
    this.group = group;
    this.spine = spine;
    for (const [a, b] of bones) { this.capA.push(a); this.capB.push(b); }
    this.world = [bones[1][1], bones[4][1], bones[5][1], bones[6][1], bones[7][1]];
    this.fractions = fractions;
    this.headBone = bones[1][1];
    this.height = data.height;
    this.meshes = [data.body, data.hem, data.collar, data.clasp].map((m) => clothMesh(m, data.height));
  }

  /** Build the cloth for a cape group on a loaded hero; null when the rig lacks the bones (the baked sway is used instead). */
  static create(cape: THREE.Object3D, root: THREE.Object3D): CapeCloth | null {
    const data = cape.userData.cloth as ClothData | undefined;
    if (!data) return null;
    let skinned: THREE.SkinnedMesh | null = null;
    root.traverse((o) => { if (!skinned && (o as THREE.SkinnedMesh).isSkinnedMesh) skinned = o as THREE.SkinnedMesh; });
    const spine = root.getObjectByName('Spine02');
    if (!skinned || !spine) return null;
    const bones: THREE.Object3D[][] = [];
    for (const [a, b] of CAPS) {
      const A = root.getObjectByName(a);
      const B = root.getObjectByName(b);
      if (!A || !B) return null;
      bones.push([A, B]);
    }
    const fractions = bindFractions(skinned);
    if (!fractions) return null;
    return new CapeCloth(cape, spine, bones, fractions, data);
  }

  /** Put the cloth back in its rest shape (the baked sway takes over). */
  rest() {
    if (!this.deformed) return;
    this.deformed = false;
    for (const c of this.meshes) {
      c.pos.set(c.rest);
      (c.geo.getAttribute('position') as THREE.BufferAttribute).needsUpdate = true;
    }
  }

  /** The chain snaps to its target on the next step (after the cape was hidden or moved far). */
  reset() {
    this.primed = false;
  }

  /**
   * Advance the cloth by `dt` seconds. `breath` is the idle sway phase, `moving` whether the hero is travelling.
   * Reads the pose from the bones' local transforms (the skeleton's world matrices are refreshed here, for the chain from
   * the feet and the head up).
   */
  step(dt: number, breath: number, moving: boolean) {
    if (dt <= 0) return;
    if (dt > MAX_DT) dt = MAX_DT;
    for (const o of this.world) o.updateWorldMatrix(true, false);
    const g = this.group;
    g.updateMatrix();
    const m = this.m.multiplyMatrices(this.spine.matrixWorld, g.matrix);
    const e = m.elements;
    const sc = Math.sqrt(e[4] * e[4] + e[5] * e[5] + e[6] * e[6]);
    const segW = (this.height / CHAIN_SEGMENTS) * sc;
    const { p, q, t } = this;

    // Targets: between the spine axis and straight down, with a breath of sway along the back.
    const sway = (moving ? 0.03 : 0.012) * Math.sin(breath) * sc;
    for (let i = 0; i < NODES; i++) {
      const d = i * (this.height / CHAIN_SEGMENTS);
      const k = i / CHAIN_SEGMENTS;
      const o = i * 3;
      t[o] = (e[12] - e[4] * d) * (1 - HANG) + e[12] * HANG + e[8] * sway * k;
      t[o + 1] = (e[13] - e[5] * d) * (1 - HANG) + (e[13] - i * segW) * HANG;
      t[o + 2] = (e[14] - e[6] * d) * (1 - HANG) + e[14] * HANG + e[10] * sway * k;
    }

    const ax = e[12];
    const ay = e[13];
    const az = e[14];
    const last = this.last;
    const jump = (ax - last[0]) ** 2 + (ay - last[1]) ** 2 + (az - last[2]) ** 2;
    last[0] = ax; last[1] = ay; last[2] = az;
    if (!this.primed || jump > SNAP_DIST * SNAP_DIST) {
      this.primed = true;
      for (let i = 0; i < NODES * 3; i++) { p[i] = t[i]; q[i] = t[i]; }
    }

    this.capsules(sc);

    // Verlet: inertia plus a spring toward the target; node 0 is the shoulder, pinned.
    const df = Math.pow(0.9, dt * 60);
    const kf = Math.min(0.5, 0.1 * dt * 60);
    p[0] = t[0]; p[1] = t[1]; p[2] = t[2];
    for (let i = 1; i < NODES; i++) {
      const o = i * 3;
      for (let a = 0; a < 3; a++) {
        const cur = p[o + a];
        const next = cur + (cur - q[o + a]) * df + (t[o + a] - cur) * kf;
        q[o + a] = cur;
        p[o + a] = next;
      }
    }
    // Keep the segment lengths (two passes).
    for (let pass = 0; pass < 2; pass++) {
      for (let i = 1; i < NODES; i++) {
        const o = i * 3;
        let dx = p[o] - p[o - 3];
        let dy = p[o + 1] - p[o - 2];
        let dz = p[o + 2] - p[o - 1];
        const l = Math.sqrt(dx * dx + dy * dy + dz * dz) || 1e-6;
        const s = segW / l;
        dx *= s; dy *= s; dz *= s;
        p[o] = p[o - 3] + dx;
        p[o + 1] = p[o - 2] + dy;
        p[o + 2] = p[o - 1] + dz;
      }
    }

    // Vertices: node (interpolated) plus the rest offset in the spine's frame, pushed out of the body, back into cape space.
    const inv = this.inv.copy(m).invert();
    const ie = inv.elements;
    const v = this.v;
    for (const c of this.meshes) {
      const { pos, node, frac, off, count } = c;
      for (let i = 0; i < count; i++) {
        const k = node[i] * 3;
        const f = frac[i];
        const ox = off[i * 2];
        const oz = off[i * 2 + 1];
        const wx = p[k] + (p[k + 3] - p[k]) * f + e[0] * ox + e[8] * oz;
        const wy = p[k + 1] + (p[k + 4] - p[k + 1]) * f + e[1] * ox + e[9] * oz;
        const wz = p[k + 2] + (p[k + 5] - p[k + 2]) * f + e[2] * ox + e[10] * oz;
        this.v[0] = wx; this.v[1] = wy; this.v[2] = wz;
        this.pushVertex(CLEARANCE, e[8], e[9], e[10]);
        const o = i * 3;
        pos[o] = ie[0] * v[0] + ie[4] * v[1] + ie[8] * v[2] + ie[12];
        pos[o + 1] = ie[1] * v[0] + ie[5] * v[1] + ie[9] * v[2] + ie[13];
        pos[o + 2] = ie[2] * v[0] + ie[6] * v[1] + ie[10] * v[2] + ie[14];
      }
      (c.geo.getAttribute('position') as THREE.BufferAttribute).needsUpdate = true;
    }
    this.deformed = true;
  }

  /** The vertex being pushed (x, y, z). */
  private readonly v = new Float64Array(3);

  /** Capsules from the bones' world matrices (their translation column), radius = measured share of the segment length. */
  private capsules(scale: number) {
    const cap = this.cap;
    for (let c = 0; c < CAPS.length; c++) {
      const a = this.capA[c].matrixWorld.elements;
      const b = this.capB[c].matrixWorld.elements;
      const o = c * 7;
      cap[o] = a[12]; cap[o + 1] = a[13]; cap[o + 2] = a[14];
      cap[o + 3] = b[12]; cap[o + 4] = b[13]; cap[o + 5] = b[14];
      const len = Math.sqrt((b[12] - a[12]) ** 2 + (b[13] - a[13]) ** 2 + (b[14] - a[14]) ** 2);
      cap[o + 6] = Math.max(0.02 * scale, Math.min(0.2 * scale, this.fractions[c] * len));
    }
    // The head: bind-unit fit, scaled by how far the neck has stretched relative to bind.
    const f = this.fractions;
    const h = CAPS.length;
    const he = this.headBone.matrixWorld.elements;
    const sp = this.capA[1].matrixWorld.elements;
    const unit = f[h + 6] > 1e-6 ? Math.sqrt((he[12] - sp[12]) ** 2 + (he[13] - sp[13]) ** 2 + (he[14] - sp[14]) ** 2) / f[h + 6] : 1;
    let ux = he[0] * f[h] + he[4] * f[h + 1] + he[8] * f[h + 2];
    let uy = he[1] * f[h] + he[5] * f[h + 1] + he[9] * f[h + 2];
    let uz = he[2] * f[h] + he[6] * f[h + 1] + he[10] * f[h + 2];
    const ul = Math.sqrt(ux * ux + uy * uy + uz * uz) || 1;
    ux /= ul; uy /= ul; uz /= ul;
    const o = h * 7;
    cap[o] = he[12] + ux * f[h + 3] * unit; cap[o + 1] = he[13] + uy * f[h + 3] * unit; cap[o + 2] = he[14] + uz * f[h + 3] * unit;
    cap[o + 3] = he[12] + ux * f[h + 4] * unit; cap[o + 4] = he[13] + uy * f[h + 4] * unit; cap[o + 5] = he[14] + uz * f[h + 4] * unit;
    cap[o + 6] = Math.max(0.03 * scale, Math.min(0.2 * scale, f[h + 5] * unit));
  }

  /**
   * Move the vertex in `this.v` out of every capsule (plus `clear`). The first two sweeps push out of one capsule at a time; a
   * vertex that two capsules keep trading between (the crease of hip and thigh) is then moved by the sum of all its penetrations
   * at once, which leads out along the crease's bisector. Stops as soon as a sweep finds nothing to push.
   * A vertex exactly on a capsule axis is pushed along (bx, by, bz), the cape's back.
   */
  private pushVertex(clear: number, bx: number, by: number, bz: number) {
    const cap = this.cap;
    const v = this.v;
    let x = v[0];
    let y = v[1];
    let z = v[2];
    for (let pass = 0; pass < 8; pass++) {
      const joint = pass >= 2;
      let sx = 0, sy = 0, sz = 0;
      let moved = false;
      for (let c = 0; c <= CAPS.length; c++) {
        const o = c * 7;
        const ax = cap[o], ay = cap[o + 1], az = cap[o + 2];
        const abx = cap[o + 3] - ax, aby = cap[o + 4] - ay, abz = cap[o + 5] - az;
        const l2 = abx * abx + aby * aby + abz * abz;
        let u = l2 > 1e-9 ? ((x - ax) * abx + (y - ay) * aby + (z - az) * abz) / l2 : 0;
        u = u < 0 ? 0 : u > 1 ? 1 : u;
        const cx = ax + abx * u, cy = ay + aby * u, cz = az + abz * u;
        let dx = x - cx, dy = y - cy, dz = z - cz;
        const d2 = dx * dx + dy * dy + dz * dz;
        const r = cap[o + 6] + clear;
        if (d2 >= r * r) continue;
        const d = Math.sqrt(d2);
        if (d < 1e-5) { dx = bx; dy = by; dz = bz; } else { dx /= d; dy /= d; dz /= d; }
        moved = true;
        if (joint) {
          const depth = (r - d) * 1.25;
          sx += dx * depth; sy += dy * depth; sz += dz * depth;
        } else {
          x = cx + dx * r; y = cy + dy * r; z = cz + dz * r;
        }
      }
      if (!moved) break;
      if (joint) { x += sx; y += sy; z += sz; }
    }
    v[0] = x; v[1] = y; v[2] = z;
  }
}
