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

/** Combat clips store Hip position relative to their standing first frame (build-characters COMBAT_TRIMS). */
const RELATIVE_HIP = new Set(['slam', 'sweep', 'flick', 'channel', 'summon']);

export async function measureFile(file) {
  const doc = await io.read(file);
  const { top, byName, map } = buildTree(doc);
  const need = ['Hip', 'R_Hand', 'L_Hand', 'Head', 'L_Foot', 'L_ToeBase'];
  for (const n of need) if (!byName.has(n)) throw new Error(`${file}: no ${n}`);
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
      const toe = w('L_ToeBase'), foot = w('L_Foot');
      const fwd = toe.sub(foot).setY(0).normalize();
      const hip = w('Hip'), head = w('Head'), rh = w('R_Hand'), lh = w('L_Hand');
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
