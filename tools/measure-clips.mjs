/**
 * measure-clips.mjs — numbers for a Tripo retarget GLB before you trust the preset
 * (the `hurt` preset was a 14 s lying clip; "measure hip height before trusting a preset").
 *
 *   node tools/measure-clips.mjs <file.glb|dir> [...]          table per clip
 *   node tools/measure-clips.mjs --json <file.glb> ...           machine-readable
 *
 * Forward-kinematics at 30 fps. Reports duration, hip height (as a fraction of the clip's own
 * first-frame standing height: < 0.6 means it lies/crouches), hip ground travel (root motion),
 * peak hand speed (the release/impact frame) and peak hand reach in front of the body, each as
 * seconds and as a fraction of the clip, plus a hip-height sparkline.
 */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import * as THREE from 'three';

const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);

function buildTree(doc) {
  const map = new Map();
  for (const n of doc.getRoot().listNodes()) {
    const o = new THREE.Object3D();
    o.name = n.getName();
    o.position.fromArray(n.getTranslation());
    o.quaternion.fromArray(n.getRotation());
    o.scale.fromArray(n.getScale());
    map.set(n, o);
  }
  const top = new THREE.Group();
  for (const [n, o] of map) (map.get(n.getParentNode()) ?? top).add(o);
  const byName = new Map();
  for (const o of map.values()) byName.set(o.name, o);
  return { top, byName, map };
}

function sample(arr, times, t, stride, out, isQuat) {
  let i = 0;
  while (i < times.length - 2 && times[i + 1] <= t) i++;
  const t0 = times[i], t1 = times[Math.min(i + 1, times.length - 1)];
  const k = t1 > t0 ? Math.min(1, Math.max(0, (t - t0) / (t1 - t0))) : 0;
  const a = i * stride, b = Math.min(i + 1, times.length - 1) * stride;
  if (isQuat) {
    const q0 = new THREE.Quaternion().fromArray(arr, a), q1 = new THREE.Quaternion().fromArray(arr, b);
    out.copy(q0.slerp(q1, k));
  } else {
    const v0 = new THREE.Vector3().fromArray(arr, a), v1 = new THREE.Vector3().fromArray(arr, b);
    out.copy(v0.lerp(v1, k));
  }
}

/**
 * Bone names per rig. The biped heroes and enemies share one skeleton (Hip, R_Hand, ...); the quadrupeds (bone hound,
 * skull rat, cinderhound) are a different Tripo rig: their root is `tripo::Root`, the head leads the bite, and there is
 * no hand or toe bone, so the head stands in for the striking hand and the body's forward is hip-to-head.
 */
export function rigNames(byName, file = '') {
  if (byName.has('Hip')) {
    for (const n of ['R_Hand', 'L_Hand', 'Head', 'L_Foot', 'L_ToeBase']) if (!byName.has(n)) throw new Error(`${file}: no ${n}`);
    return { quad: false, hip: 'Hip', head: 'Head', rHand: 'R_Hand', lHand: 'L_Hand', lFoot: 'L_Foot', lToe: 'L_ToeBase' };
  }
  const head = ['tripo::Head_1', 'tripo::Head_0'].find((n) => byName.has(n));
  if (!byName.has('tripo::Root') || !head) throw new Error(`${file}: no Hip and not a known quadruped rig`);
  return { quad: true, hip: 'tripo::Root', head, rHand: head, lHand: head, lFoot: null, lToe: null };
}

/**
 * Ground speed a looping locomotion clip implies, in model units per second: the median horizontal speed of the planted
 * feet relative to the body (so authored root motion, which the game strips, does not matter). Biped rigs use both feet;
 * quadruped rigs use the four lowest limb tips. Returns { speed, feet, lift } or null for a clip with no foot motion.
 */
export async function strideOfClip(file, clipName) {
  const doc = await io.read(file);
  const { top, byName, map } = buildTree(doc);
  const rig = rigNames(byName, file);
  const anim = doc.getRoot().listAnimations().find((a) => a.getName() === clipName);
  if (!anim) return null;
  const chans = anim.listChannels().map((c) => ({
    obj: map.get(c.getTargetNode()), path: c.getTargetPath(), times: c.getSampler().getInput().getArray(), vals: c.getSampler().getOutput().getArray(),
  }));
  const dur = Math.max(...chans.map((c) => c.times[c.times.length - 1]));
  const dt = 1 / 30;
  const p = new THREE.Vector3(), q = new THREE.Quaternion();
  const pose = (t) => {
    for (const c of chans) {
      if (c.path === 'rotation') { sample(c.vals, c.times, t, 4, q, true); c.obj.quaternion.copy(q); }
      else if (c.path === 'translation') { sample(c.vals, c.times, t, 3, p, false); c.obj.position.copy(p); }
    }
    top.updateMatrixWorld(true);
  };
  let feet;
  if (!rig.quad) feet = ['L_Foot', 'R_Foot'];
  else {
    // Leaf bones (limb tips) that sit lowest on average, ignoring head and tail.
    const leaves = [...byName.values()].filter((o) => o.children.length === 0 && /Limb|bone_/.test(o.name) && !/Head|Tail/.test(o.name));
    pose(0);
    const ys = leaves.map((o) => o.getWorldPosition(new THREE.Vector3()).y);
    const order = leaves.map((_, i) => i).sort((a, b) => ys[a] - ys[b]);
    feet = order.slice(0, 4).map((i) => leaves[i].name);
  }
  const series = feet.map(() => []);
  for (let t = 0; t < dur - 1e-6; t += dt) {
    pose(t);
    const hip = byName.get(rig.hip).getWorldPosition(new THREE.Vector3());
    feet.forEach((n, i) => {
      const f = byName.get(n).getWorldPosition(new THREE.Vector3());
      series[i].push({ x: f.x - hip.x, z: f.z - hip.z, y: f.y });
    });
  }
  const median = (a) => { const s = [...a].sort((x, y) => x - y); return s.length ? s[Math.floor(s.length / 2)] : 0; };
  const speeds = [];
  let lift = 0;
  for (const s of series) {
    const n = s.length;
    const ymin = Math.min(...s.map((r) => r.y)), ymax = Math.max(...s.map((r) => r.y));
    lift = Math.max(lift, ymax - ymin);
    const cut = ymin + 0.22 * (ymax - ymin);
    const v = [];
    for (let i = 0; i < n; i++) {
      if (s[i].y > cut) continue;
      const a = s[(i + n - 1) % n], b = s[(i + 1) % n];
      v.push(Math.hypot(b.x - a.x, b.z - a.z) / (2 * dt));
    }
    if (v.length) speeds.push(median(v));
  }
  if (!speeds.length) return null;
  return { speed: +median(speeds).toFixed(3), feet, lift: +lift.toFixed(3), duration: +dur.toFixed(2) };
}

/**
 * Rest-pose height of the skinned mesh, glTF units: the same number AssetCache measures (Box3 of the skinned model) and
 * scales to the model's target height. Vertices are skinned by hand (joint world matrix x inverse bind matrix), because
 * the quantised POSITION accessors are normalised to +-1 and only the skin brings them back to the skeleton's size.
 */
export async function bindHeight(file) {
  const doc = await io.read(file);
  const { top, map } = buildTree(doc);
  top.updateMatrixWorld(true);
  let lo = Infinity, hi = -Infinity;
  const v = new THREE.Vector3(), acc = new THREE.Vector3(), m = new THREE.Matrix4();
  for (const n of doc.getRoot().listNodes()) {
    const mesh = n.getMesh();
    if (!mesh) continue;
    const skin = n.getSkin();
    const joints = skin?.listJoints().map((j) => map.get(j));
    const ibm = skin?.getInverseBindMatrices()?.getArray();
    const mats = joints?.map((j, i) => new THREE.Matrix4().multiplyMatrices(j.matrixWorld, new THREE.Matrix4().fromArray(ibm, i * 16)));
    for (const prim of mesh.listPrimitives()) {
      const pos = prim.getAttribute('POSITION');
      const jnt = prim.getAttribute('JOINTS_0'), wgt = prim.getAttribute('WEIGHTS_0');
      const norm = (_a, x) => x; // getElement already de-normalises
      const el = [], jel = [], wel = [];
      for (let i = 0; i < pos.getCount(); i++) {
        pos.getElement(i, el);
        v.set(norm(pos, el[0]), norm(pos, el[1]), norm(pos, el[2]));
        if (mats && jnt && wgt) {
          jnt.getElement(i, jel);
          wgt.getElement(i, wel);
          acc.set(0, 0, 0);
          let wsum = 0;
          for (let k = 0; k < 4; k++) {
            const w = norm(wgt, wel[k]);
            if (w <= 0) continue;
            acc.addScaledVector(v.clone().applyMatrix4(mats[jel[k]]), w);
            wsum += w;
          }
          if (wsum > 0) v.copy(acc).divideScalar(wsum);
        } else v.applyMatrix4(map.get(n).matrixWorld);
        lo = Math.min(lo, v.y);
        hi = Math.max(hi, v.y);
      }
    }
  }
  void m;
  return hi - lo;
}

/**
 * Stride by the mesh instead of by bones: the skinned vertices touching the ground (the lowest 4% of the body's height
 * in each frame) are the planted parts, and their horizontal speed relative to the hip is the speed the ground must
 * slide under the body for them to stay put. Needs no knowledge of the rig's bone names, so it also measures the
 * quadrupeds, whose "foot" bones are not where their names say (a leaf bone that never moves is not a foot).
 * Returns { speed, height } in glTF units, or null when the clip has no body.
 */
export async function contactStrideOfClip(file, clipName, { contact = 0.04 } = {}) {
  const doc = await io.read(file);
  const { top, byName, map } = buildTree(doc);
  const rig = rigNames(byName, file);
  const anim = doc.getRoot().listAnimations().find((a) => a.getName() === clipName);
  if (!anim) return null;
  const chans = anim.listChannels().map((c) => ({
    obj: map.get(c.getTargetNode()), path: c.getTargetPath(), times: c.getSampler().getInput().getArray(), vals: c.getSampler().getOutput().getArray(),
  }));
  const dur = Math.max(...chans.map((c) => c.times[c.times.length - 1]));
  const dt = 1 / 30;
  const p = new THREE.Vector3(), q = new THREE.Quaternion();
  const pose = (t) => {
    for (const c of chans) {
      if (c.path === 'rotation') { sample(c.vals, c.times, t, 4, q, true); c.obj.quaternion.copy(q); }
      else if (c.path === 'translation') { sample(c.vals, c.times, t, 3, p, false); c.obj.position.copy(p); }
    }
    top.updateMatrixWorld(true);
  };
  // Skinned prims: bind positions, joints and weights.
  const prims = [];
  for (const n of doc.getRoot().listNodes()) {
    const mesh = n.getMesh(), skin = n.getSkin();
    if (!mesh || !skin) continue;
    const joints = skin.listJoints().map((j) => map.get(j));
    const ibm = skin.getInverseBindMatrices().getArray();
    for (const prim of mesh.listPrimitives()) {
      const pos = prim.getAttribute('POSITION'), jnt = prim.getAttribute('JOINTS_0'), wgt = prim.getAttribute('WEIGHTS_0');
      if (!pos || !jnt || !wgt) continue;
      const count = pos.getCount();
      const bind = new Float32Array(count * 3), ji = new Uint16Array(count * 4), jw = new Float32Array(count * 4);
      const el = [];
      for (let i = 0; i < count; i++) {
        pos.getElement(i, el); bind.set(el.slice(0, 3), i * 3);
        jnt.getElement(i, el); ji.set(el.slice(0, 4), i * 4);
        wgt.getElement(i, el); jw.set(el.slice(0, 4), i * 4);
      }
      prims.push({ joints, ibm, bind, ji, jw, count });
    }
  }
  if (!prims.length) return null;
  const total = prims.reduce((n, pr) => n + pr.count, 0);
  const frames = [];
  const m = new THREE.Matrix4(), v = new THREE.Vector3(), acc = new THREE.Vector3();
  for (let t = 0; t < dur - 1e-6; t += dt) {
    pose(t);
    const out = new Float32Array(total * 3);
    let o = 0;
    for (const pr of prims) {
      const mats = pr.joints.map((j, k) => new THREE.Matrix4().multiplyMatrices(j.matrixWorld, m.fromArray(pr.ibm, k * 16)));
      for (let i = 0; i < pr.count; i++) {
        v.fromArray(pr.bind, i * 3);
        acc.set(0, 0, 0);
        let ws = 0;
        for (let k = 0; k < 4; k++) {
          const w = pr.jw[i * 4 + k];
          if (w <= 0) continue;
          acc.addScaledVector(v.clone().applyMatrix4(mats[pr.ji[i * 4 + k]]), w);
          ws += w;
        }
        if (ws > 0) acc.divideScalar(ws);
        out[o++] = acc.x; out[o++] = acc.y; out[o++] = acc.z;
      }
    }
    const hip = byName.get(rig.hip).getWorldPosition(new THREE.Vector3());
    frames.push({ pos: out, hx: hip.x, hz: hip.z });
  }
  let lo = Infinity, hi = -Infinity;
  for (const f of frames) for (let i = 1; i < f.pos.length; i += 3) { lo = Math.min(lo, f.pos[i]); hi = Math.max(hi, f.pos[i]); }
  const height = hi - lo;
  const n = frames.length;
  const speeds = [];
  for (let f = 0; f < n; f++) {
    const a = frames[(f + n - 1) % n], b = frames[(f + 1) % n], c = frames[f];
    let ymin = Infinity;
    for (let i = 1; i < c.pos.length; i += 3) ymin = Math.min(ymin, c.pos[i]);
    const cut = ymin + contact * height;
    for (let i = 0; i < total; i++) {
      if (c.pos[i * 3 + 1] > cut) continue;
      const dx = (b.pos[i * 3] - b.hx) - (a.pos[i * 3] - a.hx), dz = (b.pos[i * 3 + 2] - b.hz) - (a.pos[i * 3 + 2] - a.hz);
      speeds.push(Math.hypot(dx, dz) / (2 * dt));
    }
  }
  speeds.sort((x, y) => x - y);
  return { speed: speeds.length ? +speeds[Math.floor(speeds.length / 2)].toFixed(3) : 0, height: +height.toFixed(3), samples: speeds.length };
}

/** Combat clips store Hip position relative to their standing first frame (build-characters COMBAT_TRIMS). */
const RELATIVE_HIP = new Set(['slam', 'sweep', 'flick', 'channel', 'summon']);

export async function measureFile(file) {
  const doc = await io.read(file);
  const { top, byName, map } = buildTree(doc);
  const rig = rigNames(byName, file);
  const results = [];
  const idleHip = doc.getRoot().listAnimations().find((a) => a.getName() === 'idle')
    ?.listChannels().find((c) => c.getTargetNode()?.getName() === 'Hip' && c.getTargetPath() === 'translation')
    ?.getSampler().getOutput().getArray().slice(0, 3);
  for (const anim of doc.getRoot().listAnimations()) {
    const rel = RELATIVE_HIP.has(anim.getName()) && idleHip;
    const chans = anim.listChannels().map((c) => {
      let vals = c.getSampler().getOutput().getArray();
      if (rel && c.getTargetNode().getName() === 'Hip' && c.getTargetPath() === 'translation') {
        vals = vals.map((v, i) => v + idleHip[i % 3]);
      }
      return { obj: map.get(c.getTargetNode()), path: c.getTargetPath(), times: c.getSampler().getInput().getArray(), vals };
    });
    const dur = Math.max(...chans.map((c) => c.times[c.times.length - 1]));
    const dt = 1 / 30;
    const rows = [];
    const p = new THREE.Vector3(), q = new THREE.Quaternion();
    for (let t = 0; t <= dur + 1e-6; t += dt) {
      for (const c of chans) {
        if (c.path === 'rotation') { sample(c.vals, c.times, t, 4, q, true); c.obj.quaternion.copy(q); }
        else if (c.path === 'translation') { sample(c.vals, c.times, t, 3, p, false); c.obj.position.copy(p); }
      }
      top.updateMatrixWorld(true);
      const w = (n) => byName.get(n).getWorldPosition(new THREE.Vector3());
      const hip = w(rig.hip), head = w(rig.head), rh = w(rig.rHand), lh = w(rig.lHand);
      const fwd = rig.lToe ? w(rig.lToe).sub(w(rig.lFoot)).setY(0).normalize() : head.clone().sub(hip).setY(0).normalize();
      rows.push({ t, hip, head, rh, lh, fwd });
    }
    const f0 = rows[0];
    const stand = f0.hip.y;
    const sp = (key) => rows.map((r, i) => (i ? r[key].distanceTo(rows[i - 1][key]) / dt : 0));
    const rs = sp('rh'), ls = sp('lh');
    const argmax = (a) => a.reduce((bi, v, i) => (v > a[bi] ? i : bi), 0);
    const reach = rows.map((r) => r.rh.clone().sub(r.hip).setY(0).dot(f0.fwd));
    const reachL = rows.map((r) => r.lh.clone().sub(r.hip).setY(0).dot(f0.fwd));
    const both = rs.map((v, i) => Math.max(v, ls[i]));
    const hipH = rows.map((r) => r.hip.y / stand);
    const travel = Math.max(...rows.map((r) => Math.hypot(r.hip.x - f0.hip.x, r.hip.z - f0.hip.z)));
    const handHigh = Math.max(...rows.map((r) => Math.max(r.rh.y, r.lh.y) - r.head.y));
    const spark = (vals, lo, hi, n = 32) => Array.from({ length: n }, (_, i) => {
      const v = vals[Math.min(vals.length - 1, Math.floor((i / n) * vals.length))];
      return ' .:-=+*#%@'[Math.max(0, Math.min(9, Math.round(((v - lo) / (hi - lo || 1)) * 9)))];
    }).join('');
    const ip = argmax(both);
    results.push({
      name: anim.getName(),
      dur: +dur.toFixed(2),
      standHip: +stand.toFixed(3),
      hipMin: +Math.min(...hipH).toFixed(2),
      hipEnd: +hipH[hipH.length - 1].toFixed(2),
      travel: +travel.toFixed(2),
      peakSpeed: +both[ip].toFixed(2),
      peakAt: +rows[ip].t.toFixed(2),
      peakFrac: +(rows[ip].t / dur).toFixed(2),
      reachMax: +Math.max(...reach, ...reachL).toFixed(2),
      reachAt: +rows[argmax(reach.map((v, i) => Math.max(v, reachL[i])))].t.toFixed(2),
      handAboveHead: +handHigh.toFixed(2),
      speedSpark: spark(both, 0, both[ip]),
      hipSpark: spark(hipH, 0, 1.2),
    });
  }
  return results;
}

if (process.argv[1].endsWith('measure-clips.mjs')) {
  const args = process.argv.slice(2);
  const json = args.includes('--json');
  const files = [];
  for (const a of args.filter((x) => !x.startsWith('--'))) {
    if (statSync(a).isDirectory()) for (const f of readdirSync(a).filter((x) => /^(anim|cand)_.*\.glb$/.test(x))) files.push(join(a, f));
    else files.push(a);
  }
  const all = {};
  for (const f of files) {
    const r = await measureFile(f);
    all[f] = r;
    if (!json) {
      for (const c of r) {
        console.log(`${f.split('/').slice(-2).join('/')}  dur ${c.dur}s  hip(min ${c.hipMin}, end ${c.hipEnd})  travel ${c.travel}  peakHand ${c.peakSpeed}m/s@${c.peakAt}s(${c.peakFrac})  reach ${c.reachMax}@${c.reachAt}  above-head ${c.handAboveHead}`);
        console.log(`   hip  [${c.hipSpark}]\n   hand [${c.speedSpark}]`);
      }
    }
  }
  if (json) console.log(JSON.stringify(all, null, 1));
}
