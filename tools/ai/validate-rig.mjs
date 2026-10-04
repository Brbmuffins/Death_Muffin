/**
 * validate-rig.mjs — structural sanity check of a rigged GLB (our own implementation; idea from the third-party
 * threejs-3d-generator skill's validate-rig). Bind-pose only.
 *
 *   node tools/ai/validate-rig.mjs <file.glb> [...]   (exit 1 when any hard error)
 *
 * Checks: exactly one skin, joint count in a sane band, single skeleton root, no NaN/Inf in node TRS or inverse bind
 * matrices, uniform positive scale, bone lengths (parent->child, min/max/outlier), every joint reachable in the
 * hierarchy, skin weights normalised (sum ~1), joints that carry no weight (dead bones), vertices with no weight.
 */
import { loadGlb, restPose, worldPos } from './glb-fk.mjs';

export async function validateRig(file) {
  const g = await loadGlb(file);
  const err = [], warn = [], info = {};
  const skins = g.root.listSkins();
  if (skins.length !== 1) (skins.length ? warn : err).push(`${skins.length} skins (expected 1)`);
  if (!g.skin) { err.push('no skin'); return { file, err, warn, info }; }
  const J = g.joints.length;
  info.joints = J;
  if (J < 15 || J > 120) warn.push(`joint count ${J} outside 15..120`);
  const set = new Set(g.joints);
  const roots = g.joints.filter((j) => !set.has(j.parent));
  info.skeletonRoots = roots.map((r) => r.name);
  if (roots.length !== 1) warn.push(`${roots.length} skeleton roots: ${roots.map((r) => r.name).join(',')}`);
  for (const [n, o] of g.map) {
    const bad = [...o.position.toArray(), ...o.quaternion.toArray(), ...o.scale.toArray()].some((x) => !Number.isFinite(x));
    if (bad) err.push(`non-finite TRS on ${n.getName()}`);
    const s = o.scale;
    if (s.x <= 0 || s.y <= 0 || s.z <= 0) err.push(`non-positive scale on ${n.getName()}`);
    else if (Math.max(s.x, s.y, s.z) / Math.min(s.x, s.y, s.z) > 1.05) warn.push(`non-uniform scale on ${n.getName()} ${s.toArray().map((x) => +x.toFixed(3))}`);
  }
  const ibm = g.skin.getInverseBindMatrices()?.getArray();
  if (!ibm) err.push('no inverse bind matrices');
  else if (ibm.some((x) => !Number.isFinite(x))) err.push('non-finite inverse bind matrix');
  restPose(g);
  // Bone lengths between each joint and its skeleton parent.
  const lens = [];
  for (const j of g.joints) if (set.has(j.parent)) lens.push({ name: j.name, len: worldPos(j).distanceTo(worldPos(j.parent)) });
  const nz = lens.filter((l) => l.len > 1e-6).map((l) => l.len).sort((a, b) => a - b);
  if (nz.length) {
    const med = nz[nz.length >> 1];
    info.boneLen = { min: +nz[0].toPrecision(3), median: +med.toPrecision(3), max: +nz[nz.length - 1].toPrecision(3) };
    const huge = lens.filter((l) => l.len > med * 12);
    if (huge.length) warn.push(`bones >12x median length: ${huge.map((l) => l.name).join(',')}`);
  }
  info.zeroLengthBones = lens.filter((l) => l.len <= 1e-6).map((l) => l.name);
  // Skin weights.
  const used = new Array(J).fill(0);
  let verts = 0, unweighted = 0, badSum = 0;
  for (const n of g.root.listNodes()) {
    if (!n.getMesh() || n.getSkin() !== g.skin) continue;
    for (const prim of n.getMesh().listPrimitives()) {
      const jn = prim.getAttribute('JOINTS_0'), wg = prim.getAttribute('WEIGHTS_0');
      if (!jn || !wg) { err.push('skinned primitive without JOINTS_0/WEIGHTS_0'); continue; }
      const je = [], we = [];
      for (let i = 0; i < jn.getCount(); i++) {
        jn.getElement(i, je); wg.getElement(i, we);
        const s = we[0] + we[1] + we[2] + we[3];
        verts++;
        if (s < 1e-6) unweighted++; else if (Math.abs(s - 1) > 0.02) badSum++;
        for (let k = 0; k < 4; k++) if (we[k] > 0) used[je[k]] += we[k];
      }
    }
  }
  info.vertices = verts;
  if (unweighted) err.push(`${unweighted} vertices with zero total weight`);
  if (badSum) warn.push(`${badSum} vertices whose weights do not sum to 1`);
  const total = used.reduce((a, b) => a + b, 0) || 1;
  info.weightShare = Object.fromEntries(g.joints.map((j, i) => [j.name, +(used[i] / total).toFixed(4)]).filter(([, v]) => v > 0.04));
  const dead = g.joints.filter((_, i) => used[i] < 1e-6).map((j) => j.name);
  info.deadBones = dead;
  if (dead.length > J * 0.4) warn.push(`${dead.length}/${J} joints carry no weight`);
  return { file, err, warn, info };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const files = process.argv.slice(2);
  if (!files.length) { console.error('usage: validate-rig.mjs <file.glb> ...'); process.exit(2); }
  let bad = 0;
  for (const f of files) {
    const r = await validateRig(f);
    console.log(`${r.err.length ? 'FAIL' : r.warn.length ? 'WARN' : 'ok  '} ${f}  joints=${r.info.joints} verts=${r.info.vertices} boneLen=${JSON.stringify(r.info.boneLen)} dead=${r.info.deadBones?.length ?? '?'}`);
    for (const e of r.err) console.log('   ERROR', e);
    for (const w of r.warn) console.log('   warn ', w);
    if (r.err.length) bad++;
  }
  process.exit(bad ? 1 : 0);
}
