/**
 * clip-sheet.mjs — stick-figure contact sheet of a retarget GLB (side view, relative to the body's
 * own forward) so a preset can be judged before it is accepted or paid for on more heroes.
 *   node tools/clip-sheet.mjs <out.png> <file.glb> [start end] [frames]
 * R hand red, L hand blue, hip green. Each cell is one frame; times are printed under it.
 */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import sharp from 'sharp';
import * as THREE from 'three';

const [out, file, a, b, n] = process.argv.slice(2);
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const doc = await io.read(file);
const map = new Map();
for (const nd of doc.getRoot().listNodes()) {
  const o = new THREE.Object3D();
  o.name = nd.getName();
  o.position.fromArray(nd.getTranslation()); o.quaternion.fromArray(nd.getRotation()); o.scale.fromArray(nd.getScale());
  map.set(nd, o);
}
const top = new THREE.Group();
for (const [nd, o] of map) (map.get(nd.getParentNode()) ?? top).add(o);
const byName = new Map([...map.values()].map((o) => [o.name, o]));
const anim = doc.getRoot().listAnimations()[0];
const chans = anim.listChannels().map((c) => ({ o: map.get(c.getTargetNode()), p: c.getTargetPath(), t: c.getSampler().getInput().getArray(), v: c.getSampler().getOutput().getArray() }));
const dur = Math.max(...chans.map((c) => c.t[c.t.length - 1]));
const t0 = a ? +a : 0, t1 = b ? +b : dur, frames = n ? +n : 8;
function pose(t) {
  for (const c of chans) {
    let i = 0;
    while (i < c.t.length - 2 && c.t[i + 1] <= t) i++;
    const j = Math.min(i + 1, c.t.length - 1);
    const k = c.t[j] > c.t[i] ? Math.min(1, Math.max(0, (t - c.t[i]) / (c.t[j] - c.t[i]))) : 0;
    if (c.p === 'rotation') c.o.quaternion.copy(new THREE.Quaternion().fromArray(c.v, i * 4).slerp(new THREE.Quaternion().fromArray(c.v, j * 4), k));
    else if (c.p === 'translation') c.o.position.copy(new THREE.Vector3().fromArray(c.v, i * 3).lerp(new THREE.Vector3().fromArray(c.v, j * 3), k));
  }
  top.updateMatrixWorld(true);
}
pose(0);
const w = (nm) => byName.get(nm).getWorldPosition(new THREE.Vector3());
let fwd = w('L_ToeBase').sub(w('L_Foot')).setY(0).normalize();
// VIEW=front looks along the body's forward axis (shows sideways sweeps).
if (process.env.VIEW === 'front') fwd = new THREE.Vector3(0, 1, 0).cross(fwd).normalize();
const W = 260, H = 330;
let svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W * frames}" height="${H + 24}"><rect width="100%" height="100%" fill="#16121d"/>`;
const hip0 = w('Hip');
for (let f = 0; f < frames; f++) {
  const t = t0 + ((t1 - t0) * f) / Math.max(1, frames - 1);
  pose(t);
  const hip = w('Hip');
  const P = (v) => [f * W + W / 2 + v.clone().sub(hip0).setY(0).dot(fwd) * 180 - hip.clone().sub(hip0).setY(0).dot(fwd) * 0, H - 30 - v.y * 180];
  // Keep the pelvis' horizontal position fixed so in-place stripping is what you see.
  const Q = (v) => [f * W + W / 2 + (v.clone().sub(hip).setY(0).dot(fwd)) * 180, H - 30 - v.y * 180];
  for (const [nd, o] of map) {
    const pr = nd.getParentNode();
    if (!pr) continue;
    const [x1, y1] = Q(o.getWorldPosition(new THREE.Vector3()));
    const [x2, y2] = Q(map.get(pr).getWorldPosition(new THREE.Vector3()));
    svg += `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="#a79bc9" stroke-width="2"/>`;
  }
  const dot = (nm, col) => { const [x, y] = Q(w(nm)); svg += `<circle cx="${x}" cy="${y}" r="5" fill="${col}"/>`; };
  dot('R_Hand', '#ff5a5a'); dot('L_Hand', '#5aa0ff'); dot('Hip', '#6bdc8a'); dot('Head', '#ffd36b');
  svg += `<line x1="${f * W}" y1="${H - 30}" x2="${f * W + W}" y2="${H - 30}" stroke="#444"/><text x="${f * W + 6}" y="${H + 16}" fill="#ccc" font-size="14" font-family="monospace">${t.toFixed(2)}s</text>`;
}
svg += '</svg>';
await sharp(Buffer.from(svg)).png().toFile(out);
console.log('wrote', out, `dur ${dur.toFixed(2)}`);
