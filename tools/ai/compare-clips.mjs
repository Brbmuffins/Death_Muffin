/**
 * compare-clips.mjs — joint-by-joint forward-kinematics diff of the same clip in two GLBs (same skeleton names).
 *   node tools/ai/compare-clips.mjs a.glb [clipA] b.glb [clipB]
 * Prints max / mean world-position difference per joint over all frames, in body heights, after removing hip
 * translation (so root-motion differences are reported separately).
 */
import { clipChannels, clipDuration, loadGlb, poseAt, restPose, skinnedVerts, bbox, worldPos } from './glb-fk.mjs';

const [fa, ca, fb, cb] = process.argv.slice(2);
const A = await loadGlb(fa), B = await loadGlb(fb);
const pick = (g, name) => (name ? g.root.listAnimations().find((a) => a.getName() === name) : g.root.listAnimations()[0]);
const ach = clipChannels(A, pick(A, ca)), bch = clipChannels(B, pick(B, cb));
restPose(A);
const H = bbox(skinnedVerts(A)).ext[1];
const dur = Math.min(clipDuration(ach), clipDuration(bch));
const names = A.joints.map((j) => j.name).filter((n) => B.byName.has(n));
const stat = Object.fromEntries(names.map((n) => [n, { max: 0, sum: 0 }]));
let rootMax = 0, frames = 0;
for (let t = 0; t <= dur + 1e-6; t += 1 / 30) {
  poseAt(A, ach, t); poseAt(B, bch, t);
  const ha = worldPos(A.byName.get('Hip')), hb = worldPos(B.byName.get('Hip'));
  rootMax = Math.max(rootMax, ha.distanceTo(hb) / H);
  for (const n of names) {
    const d = worldPos(A.byName.get(n)).sub(ha).distanceTo(worldPos(B.byName.get(n)).sub(hb)) / H;
    stat[n].max = Math.max(stat[n].max, d); stat[n].sum += d;
  }
  frames++;
}
const rows = names.map((n) => [n, stat[n].max, stat[n].sum / frames]).sort((x, y) => y[1] - x[1]);
console.log(`frames=${frames} hip-position max diff ${rootMax.toFixed(4)} h`);
console.log('worst joints (max / mean, body heights, hip-relative):');
for (const [n, mx, mn] of rows.slice(0, 6)) console.log(`  ${n.padEnd(16)} ${mx.toFixed(4)} / ${mn.toFixed(4)}`);
console.log(`overall max ${rows[0][1].toFixed(4)} h`);
