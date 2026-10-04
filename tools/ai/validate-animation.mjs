/**
 * validate-animation.mjs — per-clip sanity check of an animated GLB (our own implementation; idea from the third-party
 * threejs-3d-generator skill's validate-animation). Forward kinematics at 30 fps against the bind pose.
 *
 *   node tools/ai/validate-animation.mjs <file.glb> [...] [--json]   (exit 1 when any clip has a hard error)
 *
 * Per clip: duration, channel count / joint coverage, NaN/Inf, scale tracks that actually scale, bone-length drift
 * (every skeleton parent->child pair vs bind; stretching), root drift (hip travel, in body heights), skinned-mesh
 * bbox vs bind (limb collapse / explosion), hand-to-hip reach vs bind, crossed-arms fingerprint (a hand on the wrong
 * side of the pelvis for most of the clip), peak per-frame joint rotation (pops).
 */
import * as THREE from 'three';
import { bbox, clipChannels, clipDuration, loadGlb, poseAt, restPose, skinnedVerts, worldPos } from './glb-fk.mjs';

const DT = 1 / 30;

export async function validateAnimations(file) {
  const g = await loadGlb(file);
  const clips = [];
  if (!g.skin) return { file, clips, fatal: 'no skin' };
  const set = new Set(g.joints);
  restPose(g);
  const bindV = skinnedVerts(g);
  const bind = bbox(bindV);
  const height = bind.ext[1];
  // The skeleton root carries root motion (it legitimately moves relative to the hip), so its pair is excluded.
  const skelRoot = g.joints.find((j) => !set.has(j.parent));
  const pairs = g.joints.filter((j) => set.has(j.parent) && j.parent !== skelRoot).map((j) => ({ a: j.parent, b: j, len: worldPos(j).distanceTo(worldPos(j.parent)) })).filter((p) => p.len > 1e-3);
  const find = (re) => g.joints.find((j) => re.test(j.name));
  const hip = find(/^Hip$/) ?? find(/hip|pelvis|root/i);
  const lHand = find(/^L_Hand$/), rHand = find(/^R_Hand$/);
  const lLeg = find(/^L_Thigh$/), rLeg = find(/^R_Thigh$/);
  const bindReach = (h) => (h && hip ? worldPos(h).distanceTo(worldPos(hip)) : null);
  const bindLR = bindReach(lHand), bindRR = bindReach(rHand);
  for (const anim of g.root.listAnimations()) {
    const chans = clipChannels(g, anim);
    const err = [], warn = [];
    const m = { name: anim.getName(), duration: +clipDuration(chans).toFixed(3), channels: chans.length };
    const joints = new Set(chans.filter((c) => set.has(c.obj)).map((c) => c.obj));
    m.jointCoverage = +(joints.size / g.joints.length).toFixed(2);
    if (m.jointCoverage < 0.5) warn.push(`only ${joints.size}/${g.joints.length} joints animated`);
    if (m.duration <= 0.1) err.push(`duration ${m.duration}s`);
    if (m.duration > 6) warn.push(`long clip ${m.duration}s`);
    let nonFinite = 0, scaleDev = 0, maxRotStep = 0, maxRotJoint = '';
    for (const c of chans) {
      for (const x of c.vals) if (!Number.isFinite(x)) { nonFinite++; break; }
      if (c.path === 'scale') {
        const r = g.rest.get(c.obj).s;
        for (let i = 0; i < c.vals.length; i += 3) scaleDev = Math.max(scaleDev, Math.abs(c.vals[i] / r.x - 1), Math.abs(c.vals[i + 1] / r.y - 1), Math.abs(c.vals[i + 2] / r.z - 1));
      }
      if (c.path === 'rotation') {
        const a = new THREE.Quaternion(), b = new THREE.Quaternion();
        for (let i = 0; i + 1 < c.times.length; i++) {
          a.fromArray(c.vals, i * 4); b.fromArray(c.vals, (i + 1) * 4);
          const ang = 2 * Math.acos(Math.min(1, Math.abs(a.dot(b)))) * 180 / Math.PI;
          const perFrame = ang * DT / Math.max(c.times[i + 1] - c.times[i], 1e-4);
          if (perFrame > maxRotStep) { maxRotStep = perFrame; maxRotJoint = c.obj.name; }
        }
      }
    }
    if (nonFinite) err.push(`${nonFinite} tracks contain NaN/Inf`);
    m.scaleDeviation = +scaleDev.toFixed(3);
    if (scaleDev > 0.02) warn.push(`scale tracks deviate ${(scaleDev * 100).toFixed(0)}% from rest`);
    m.maxRotDegPerFrame = +maxRotStep.toFixed(1); m.maxRotJoint = maxRotJoint;
    if (maxRotStep > 60) warn.push(`rotation pop ${maxRotStep.toFixed(0)} deg/frame on ${maxRotJoint}`);
    // FK sweep.
    let lenDrift = 0, lenDriftPair = '', hipStart = null, hipMaxXZ = 0, hipMinY = Infinity, hipMaxY = -Infinity, hipEnd = null;
    let minDim = Infinity, maxDim = 0, minExt = [1, 1, 1], maxExt = [1, 1, 1], minReachL = 9, minReachR = 9, maxReachL = 0, maxReachR = 0;
    let crossedL = 0, crossedR = 0, frames = 0;
    const frameT = [];
    for (let t = 0; t < m.duration - 1e-6; t += DT) frameT.push(t);
    if (frameT.length) frameT.push(m.duration);
    frameT.forEach((t, fi) => {
      poseAt(g, chans, t);
      for (const p of pairs) {
        const d = Math.abs(worldPos(p.b).distanceTo(worldPos(p.a)) / p.len - 1);
        if (d > lenDrift) { lenDrift = d; lenDriftPair = `${p.a.name}>${p.b.name}`; }
      }
      if (hip) {
        const h = worldPos(hip);
        hipStart ??= h.clone();
        hipEnd = h;
        hipMaxXZ = Math.max(hipMaxXZ, Math.hypot(h.x - hipStart.x, h.z - hipStart.z));
        hipMinY = Math.min(hipMinY, h.y); hipMaxY = Math.max(hipMaxY, h.y);
      }
      if (lHand && hip && bindLR) { const r = worldPos(lHand).distanceTo(worldPos(hip)) / bindLR; minReachL = Math.min(minReachL, r); maxReachL = Math.max(maxReachL, r); }
      if (rHand && hip && bindRR) { const r = worldPos(rHand).distanceTo(worldPos(hip)) / bindRR; minReachR = Math.min(minReachR, r); maxReachR = Math.max(maxReachR, r); }
      if (lHand && rHand && lLeg && rLeg) {
        // Lateral axis of the pelvis this frame (right leg -> left leg), flattened to the ground plane.
        const axis = worldPos(lLeg).sub(worldPos(rLeg)); axis.y = 0; axis.normalize();
        const c = worldPos(lLeg).add(worldPos(rLeg)).multiplyScalar(0.5);
        const sl = worldPos(lHand).sub(c).dot(axis), sr = worldPos(rHand).sub(c).dot(axis);
        if (sl < 0) crossedL++;
        if (sr > 0) crossedR++;
        frames++;
      }
      if (fi % 3 === 0) {
        const e = bbox(skinnedVerts(g, 12)).ext;
        for (let a = 0; a < 3; a++) { const r = e[a] / bind.ext[a]; minExt[a] = Math.min(minExt[a], r); maxExt[a] = Math.max(maxExt[a], r); }
        minDim = Math.min(minDim, Math.max(...e)); maxDim = Math.max(maxDim, Math.max(...e));
      }
    });
    m.boneLengthDrift = +lenDrift.toFixed(4); m.boneLengthDriftPair = lenDriftPair;
    if (lenDrift > 0.05) warn.push(`bone ${lenDriftPair} length drifts ${(lenDrift * 100).toFixed(0)}% from bind`);
    if (hipStart) {
      m.rootDriftXZ = +(hipMaxXZ / height).toFixed(3); m.rootDriftEnd = +(Math.hypot(hipEnd.x - hipStart.x, hipEnd.z - hipStart.z) / height).toFixed(3);
      m.hipHeightRange = [+((hipMinY - bind.lo[1]) / height).toFixed(3), +((hipMaxY - bind.lo[1]) / height).toFixed(3)];
    }
    m.bboxExtentRatio = { min: minExt.map((x) => +x.toFixed(2)), max: maxExt.map((x) => +x.toFixed(2)) };
    // Largest bbox dimension vs the bind pose's largest: a lying body keeps ~1.0, a collapsed or shredded one does not.
    const bigBind = Math.max(...bind.ext);
    m.maxDimRatio = [+(minDim / bigBind).toFixed(2), +(maxDim / bigBind).toFixed(2)];
    if (minDim / bigBind < 0.5) warn.push(`skinned body collapses (largest dimension ${(minDim / bigBind * 100).toFixed(0)}% of bind)`);
    if (maxDim / bigBind > 1.6) warn.push(`skinned body explodes (largest dimension ${(maxDim / bigBind * 100).toFixed(0)}% of bind)`);
    if (lHand) m.handReach = { L: [+minReachL.toFixed(2), +maxReachL.toFixed(2)], R: [+minReachR.toFixed(2), +maxReachR.toFixed(2)] };
    if (frames) {
      m.crossedFraction = { L: +(crossedL / frames).toFixed(2), R: +(crossedR / frames).toFixed(2) };
      if (crossedL / frames > 0.5 && crossedR / frames > 0.5) warn.push('both hands on the wrong side of the pelvis most of the clip (mirrored/crossed limbs)');
    }
    m.err = err; m.warn = warn;
    clips.push(m);
  }
  return { file, clips };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const args = process.argv.slice(2);
  const json = args.includes('--json');
  const files = args.filter((a) => !a.startsWith('--'));
  if (!files.length) { console.error('usage: validate-animation.mjs <file.glb> ... [--json]'); process.exit(2); }
  let bad = 0;
  const all = [];
  for (const f of files) {
    const r = await validateAnimations(f);
    all.push(r);
    if (json) continue;
    console.log(`\n${f}${r.fatal ? '  ' + r.fatal : ''}`);
    for (const c of r.clips) {
      const st = c.err.length ? 'FAIL' : c.warn.length ? 'WARN' : 'ok  ';
      console.log(`${st} ${c.name.padEnd(9)} ${String(c.duration).padStart(5)}s ch=${c.channels} drift=${c.rootDriftXZ}h/${c.rootDriftEnd}h hipY=${c.hipHeightRange} len=${c.boneLengthDrift} dim=${c.maxDimRatio} reachL=${c.handReach?.L} reachR=${c.handReach?.R} crossed=${JSON.stringify(c.crossedFraction)} pop=${c.maxRotDegPerFrame}`);
      for (const e of c.err) console.log('     ERROR', e);
      for (const w of c.warn) console.log('     warn ', w);
      if (c.err.length) bad++;
    }
  }
  if (json) console.log(JSON.stringify(all, null, 1));
  process.exit(bad ? 1 : 0);
}
