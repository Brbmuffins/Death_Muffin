/**
 * glb-fk.mjs — shared forward-kinematics helpers for validate-rig.mjs / validate-animation.mjs.
 * Reads a GLB with gltf-transform, builds a three.js Object3D tree, poses it from an animation at any time, and skins
 * vertices by hand (joint world x inverse bind), so quantised and raw Tripo files are both handled.
 */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import * as THREE from 'three';

const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);

export async function loadGlb(file) {
  const doc = await io.read(file);
  const root = doc.getRoot();
  const map = new Map();
  for (const n of root.listNodes()) {
    const o = new THREE.Object3D();
    o.name = n.getName();
    o.position.fromArray(n.getTranslation());
    o.quaternion.fromArray(n.getRotation());
    o.scale.fromArray(n.getScale());
    map.set(n, o);
  }
  const top = new THREE.Group();
  for (const [n, o] of map) (map.get(n.getParentNode()) ?? top).add(o);
  top.updateMatrixWorld(true);
  const byName = new Map();
  for (const o of map.values()) byName.set(o.name, o);
  const skinNode = root.listNodes().find((n) => n.getSkin() && n.getMesh());
  const skin = skinNode?.getSkin() ?? root.listSkins()[0] ?? null;
  const joints = skin ? skin.listJoints().map((j) => map.get(j)) : [];
  const rest = new Map(); // object -> {p,q,s} snapshot of the rest pose
  for (const o of map.values()) rest.set(o, { p: o.position.clone(), q: o.quaternion.clone(), s: o.scale.clone() });
  return { doc, root, map, top, byName, skin, skinNode, joints, rest };
}

export function restPose(g) {
  for (const [o, r] of g.rest) { o.position.copy(r.p); o.quaternion.copy(r.q); o.scale.copy(r.s); }
  g.top.updateMatrixWorld(true);
}

function sampleInto(vals, times, t, stride, isQuat, out) {
  let i = 0;
  while (i < times.length - 2 && times[i + 1] <= t) i++;
  const j = Math.min(i + 1, times.length - 1);
  const k = times[j] > times[i] ? Math.min(1, Math.max(0, (t - times[i]) / (times[j] - times[i]))) : 0;
  if (isQuat) {
    out.fromArray(vals, i * stride).slerp(new THREE.Quaternion().fromArray(vals, j * stride), k);
  } else {
    out.fromArray(vals, i * stride).lerp(new THREE.Vector3().fromArray(vals, j * stride), k);
  }
}

export function clipChannels(g, anim) {
  return anim.listChannels().map((c) => ({
    obj: g.map.get(c.getTargetNode()), path: c.getTargetPath(),
    times: c.getSampler().getInput().getArray(), vals: c.getSampler().getOutput().getArray(),
  })).filter((c) => c.obj);
}

export function clipDuration(chans) {
  return chans.length ? Math.max(...chans.map((c) => c.times[c.times.length - 1])) : 0;
}

export function poseAt(g, chans, t) {
  restPose(g);
  const v = new THREE.Vector3(), q = new THREE.Quaternion();
  for (const c of chans) {
    if (c.path === 'rotation') { sampleInto(c.vals, c.times, t, 4, true, q); c.obj.quaternion.copy(q); }
    else if (c.path === 'translation') { sampleInto(c.vals, c.times, t, 3, false, v); c.obj.position.copy(v); }
    else if (c.path === 'scale') { sampleInto(c.vals, c.times, t, 3, false, v); c.obj.scale.copy(v); }
  }
  g.top.updateMatrixWorld(true);
}

/** Skinned vertices (every `step`th) in the current pose. Returns Float32Array xyz. */
export function skinnedVerts(g, step = 6) {
  const out = [];
  const v = new THREE.Vector3(), acc = new THREE.Vector3();
  const ibm = g.skin.getInverseBindMatrices().getArray();
  const mats = g.joints.map((j, i) => new THREE.Matrix4().multiplyMatrices(j.matrixWorld, new THREE.Matrix4().fromArray(ibm, i * 16)));
  const jointIndex = new Map(g.skin.listJoints().map((j, i) => [j, i]));
  void jointIndex;
  for (const n of g.root.listNodes()) {
    const mesh = n.getMesh();
    if (!mesh || n.getSkin() !== g.skin) continue;
    for (const prim of mesh.listPrimitives()) {
      const pos = prim.getAttribute('POSITION'), jn = prim.getAttribute('JOINTS_0'), wg = prim.getAttribute('WEIGHTS_0');
      if (!pos || !jn || !wg) continue;
      const e = [], je = [], we = [];
      for (let i = 0; i < pos.getCount(); i += step) {
        pos.getElement(i, e); jn.getElement(i, je); wg.getElement(i, we);
        v.set(e[0], e[1], e[2]); acc.set(0, 0, 0);
        let ws = 0;
        for (let k = 0; k < 4; k++) {
          if (we[k] <= 0) continue;
          acc.addScaledVector(v.clone().applyMatrix4(mats[je[k]]), we[k]); ws += we[k];
        }
        if (ws > 0) { acc.divideScalar(ws); out.push(acc.x, acc.y, acc.z); }
      }
    }
  }
  return Float32Array.from(out);
}

export function bbox(verts) {
  const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity];
  for (let i = 0; i < verts.length; i += 3) for (let a = 0; a < 3; a++) { lo[a] = Math.min(lo[a], verts[i + a]); hi[a] = Math.max(hi[a], verts[i + a]); }
  return { lo, hi, ext: hi.map((h, a) => h - lo[a]) };
}

export const worldPos = (o) => o.getWorldPosition(new THREE.Vector3());
