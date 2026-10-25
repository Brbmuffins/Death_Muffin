/**
 * merge.mjs - put what a Blender job made back into a shipped model without touching anything else (tools/blender/jobs.mjs, DECISIONS B74).
 * Blender re-exports materials, textures and clips in its own way, so a job never ships Blender's whole file: a new clip is copied onto the
 * shipped skeleton by joint name (as tools/build-characters.mjs does for Tripo's clips), and edited geometry (a decimated, reshaped or
 * re-rigged mesh) replaces only the skinned mesh's vertex data, its indices and, for new bones, the skin. Materials, textures, node names,
 * the other clips and every extra stay byte for byte. Pure functions on glTF-Transform Documents, unit tested without Blender.
 */
import { PropertyType } from '@gltf-transform/core';
import { cloneDocument, prune } from '@gltf-transform/functions';

const nodesByName = (doc) => new Map(doc.getRoot().listNodes().map((n) => [n.getName(), n]));
const bufferOf = (doc) => doc.getRoot().listBuffers()[0] ?? doc.createBuffer();

/** Remove accessors nothing uses any more (only accessors: a broader prune would drop empty leaf bones). */
export async function pruneAccessors(doc) {
  await doc.transform(prune({ propertyTypes: [PropertyType.ACCESSOR], keepAttributes: true, keepLeaves: true }));
}

export function clipLength(anim) {
  let t = 0;
  for (const s of anim.listSamplers()) { const a = s.getInput().getArray(); if (a.length) t = Math.max(t, a[a.length - 1]); }
  return t;
}

export function dropClip(doc, name) {
  for (const a of doc.getRoot().listAnimations()) {
    if (a.getName() !== name) continue;
    for (const s of a.listSamplers()) s.dispose();
    a.dispose();
  }
}

/**
 * Copy the animation `fromName` (default: the first one) of `src` into `dst` as `name`, matching target nodes by name; an animation of that
 * name in `dst` is replaced. Channels for nodes `dst` lacks are skipped. Returns { channels, skipped, seconds }; throws when nothing matched.
 */
export function transplantClip(dst, src, name, fromName = null) {
  const anims = src.getRoot().listAnimations();
  const from = fromName ? anims.find((a) => a.getName() === fromName) : anims[0];
  if (!from) throw new Error(`no clip ${fromName ?? ''} in the Blender output`);
  const byName = nodesByName(dst);
  const buffer = bufferOf(dst);
  const made = [];
  let skipped = 0;
  for (const ch of from.listChannels()) {
    const target = byName.get(ch.getTargetNode()?.getName());
    if (!target) { skipped++; continue; }
    const s = ch.getSampler();
    const input = dst.createAccessor().setType('SCALAR').setArray(s.getInput().getArray().slice()).setBuffer(buffer);
    const output = dst.createAccessor().setType(s.getOutput().getType()).setArray(s.getOutput().getArray().slice()).setBuffer(buffer);
    made.push({ target, path: ch.getTargetPath(), input, output, interp: s.getInterpolation() });
  }
  if (!made.length) throw new Error(`clip ${name}: no channel matches a bone of the model (another skeleton?)`);
  dropClip(dst, name);
  const anim = dst.createAnimation(name);
  for (const m of made) {
    const sampler = dst.createAnimationSampler().setInput(m.input).setOutput(m.output).setInterpolation(m.interp);
    anim.addSampler(sampler);
    anim.addChannel(dst.createAnimationChannel().setTargetNode(m.target).setTargetPath(m.path).setSampler(sampler));
  }
  return { channels: made.length, skipped, seconds: +clipLength(anim).toFixed(3) };
}

/** Copy one clip of `doc` into a new document holding the same scene and only that clip (the overlay base files Blender reads). */
export function onlyClip(doc, name) {
  const keep = cloneDocument(doc);
  for (const a of keep.getRoot().listAnimations()) if (a.getName() !== name) { for (const s of a.listSamplers()) s.dispose(); a.dispose(); }
  return keep;
}

function skinnedNode(doc, what) {
  const nodes = doc.getRoot().listNodes().filter((n) => n.getMesh() && n.getSkin());
  if (nodes.length !== 1) throw new Error(`${what}: expected one skinned mesh, found ${nodes.length}`);
  return nodes[0];
}

const close = (a, b, eps) => a.length === b.length && a.every((v, i) => Math.abs(v - b[i]) <= eps);
const mat = (arr, i) => Array.from(arr.slice(i * 16, i * 16 + 16));

// 4x4 matrices, column-major as glTF stores them (element row r, column c at c * 4 + r)
export function mul(a, b) {
  const o = new Array(16).fill(0);
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) for (let k = 0; k < 4; k++) o[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k];
  return o;
}
/** Inverse of an affine matrix (bottom row 0 0 0 1). */
export function invAffine(m) {
  const [a, b, c, d, e, f, g, h, i] = [m[0], m[4], m[8], m[1], m[5], m[9], m[2], m[6], m[10]];
  const det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g);
  if (Math.abs(det) < 1e-12) throw new Error('a bind matrix cannot be inverted');
  const r = [(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det, (f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det, (d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det];
  const t = [m[12], m[13], m[14]];
  const out = [r[0], r[3], r[6], 0, r[1], r[4], r[7], 0, r[2], r[5], r[8], 0, 0, 0, 0, 1];
  for (let row = 0; row < 3; row++) out[12 + row] = -(r[row * 3] * t[0] + r[row * 3 + 1] * t[1] + r[row * 3 + 2] * t[2]);
  return out;
}

/**
 * Replace the skinned mesh of `dst` (the shipped model) with the one of `src` (Blender's static export after an edit). Bones `src` added
 * (rigfix) are created under their parents with Blender's rest transform and appended to the skin; bones both have must keep their bind
 * (inverse bind matrices within `eps`), else the job is refused: the clips would no longer fit. Every primitive keeps its material.
 * Returns { triangles: [before, after], addedBones }.
 */
export function transplantGeometry(dst, src, { eps = 2e-3 } = {}) {
  const dn = skinnedNode(dst, 'model'), sn = skinnedNode(src, 'Blender output');
  const dSkin = dn.getSkin(), sSkin = sn.getSkin();
  const dJoints = dSkin.listJoints(), sJoints = sSkin.listJoints();
  const dIbm = dSkin.getInverseBindMatrices()?.getArray(), sIbm = sSkin.getInverseBindMatrices()?.getArray();
  if (!dIbm || !sIbm) throw new Error('a skin without inverse bind matrices');
  const dIndex = new Map(dJoints.map((j, i) => [j.getName(), i]));
  const byName = nodesByName(dst);
  // Blender writes the bind in its own normalised space (Tripo's skins carry a scale), so the two binds may differ by one transform D for
  // the whole mesh: IBM_dst = IBM_src * D^-1 for every bone both have. Blender's vertices are moved by D into the model's space; a bone whose
  // bind does not follow D moved in Blender, and the job is refused (the model's clips would no longer fit).
  const common = sJoints.map((j, i) => ({ i, k: dIndex.get(j.getName()), name: j.getName() })).filter((x) => x.k !== undefined);
  if (!common.length) throw new Error('the Blender output shares no bone with the model');
  const D = mul(invAffine(mat(dIbm, common[0].k)), mat(sIbm, common[0].i));
  const Dinv = invAffine(D);
  const scale = Math.cbrt(Math.abs(D[0] * (D[5] * D[10] - D[9] * D[6]) - D[4] * (D[1] * D[10] - D[9] * D[2]) + D[8] * (D[1] * D[6] - D[5] * D[2])));
  for (const x of common) {
    if (!close(mul(mat(sIbm, x.i), Dinv), mat(dIbm, x.k), eps * Math.max(1, ...mat(dIbm, x.k).map(Math.abs)))) throw new Error(`bone ${x.name} moved in Blender: the model's clips would no longer fit, refused`);
  }
  // new bones: parents first (repeat until every new bone found its parent)
  let pending = sJoints.map((j, i) => ({ j, i })).filter(({ j }) => !dIndex.has(j.getName()));
  const added = [];
  const ibm = Array.from(dIbm);
  while (pending.length) {
    const next = [];
    for (const p of pending) {
      const parentName = p.j.getParentNode()?.getName();
      const parent = parentName ? byName.get(parentName) : null;
      if (!parent) { next.push(p); continue; }
      const node = dst.createNode(p.j.getName()).setTranslation(p.j.getTranslation()).setRotation(p.j.getRotation()).setScale(p.j.getScale());
      parent.addChild(node);
      byName.set(node.getName(), node);
      dSkin.addJoint(node);
      dIndex.set(node.getName(), dSkin.listJoints().length - 1);
      ibm.push(...mul(mat(sIbm, p.i), Dinv));
      added.push(node.getName());
    }
    if (next.length === pending.length) throw new Error(`new bones without a parent in the model: ${next.map((p) => p.j.getName()).join(', ')}`);
    pending = next;
  }
  const buffer = bufferOf(dst);
  if (added.length) dSkin.setInverseBindMatrices(dst.createAccessor().setType('MAT4').setArray(new Float32Array(ibm)).setBuffer(buffer));
  const remap = sJoints.map((j) => dIndex.get(j.getName()));
  const dPrims = dn.getMesh().listPrimitives(), sPrims = sn.getMesh().listPrimitives();
  if (dPrims.length !== sPrims.length) throw new Error(`the mesh has ${dPrims.length} parts, Blender's ${sPrims.length}`);
  const tris = (prims) => prims.reduce((n, p) => n + (p.getIndices()?.getCount() ?? p.getAttribute('POSITION').getCount()) / 3, 0);
  const before = tris(dPrims);
  dPrims.forEach((dp, k) => {
    const sp = sPrims[k];
    if (dp.listTargets().length) throw new Error('the mesh has morph targets: geometry edits do not support them');
    for (const sem of dp.listSemantics()) if (!sp.getAttribute(sem)) dp.setAttribute(sem, null);   // e.g. TANGENT: Godot makes its own (ensure_tangents)
    for (const sem of sp.listSemantics()) {
      const a = sp.getAttribute(sem);
      let arr = a.getArray().slice();
      if (sem === 'POSITION') {
        for (let v = 0; v < arr.length; v += 3) {
          const [x, y, z] = [arr[v], arr[v + 1], arr[v + 2]];
          for (let r = 0; r < 3; r++) arr[v + r] = D[r] * x + D[4 + r] * y + D[8 + r] * z + D[12 + r];
        }
      } else if (sem === 'NORMAL' || sem === 'TANGENT') {
        const n = a.getElementSize();
        for (let v = 0; v < arr.length; v += n) {
          const [x, y, z] = [arr[v], arr[v + 1], arr[v + 2]];
          const o = [0, 1, 2].map((r) => (D[r] * x + D[4 + r] * y + D[8 + r] * z) / scale);
          const len = Math.hypot(...o) || 1;
          for (let r = 0; r < 3; r++) arr[v + r] = o[r] / len;
        }
      } else if (sem.startsWith('JOINTS_')) {
        const out = new Uint16Array(arr.length);
        for (let i = 0; i < arr.length; i++) out[i] = remap[arr[i]];
        arr = out;
      }
      dp.setAttribute(sem, dst.createAccessor().setType(a.getType()).setArray(arr).setNormalized(a.getNormalized()).setBuffer(buffer));
    }
    const si = sp.getIndices();
    dp.setIndices(si ? dst.createAccessor().setType('SCALAR').setArray(si.getArray().slice()).setBuffer(buffer) : null);
  });
  return { triangles: [before, tris(dPrims)], addedBones: added };
}

/** Joint names of the model's skin, for checks and reports. */
export function jointNames(doc) {
  return doc.getRoot().listSkins().flatMap((s) => s.listJoints().map((j) => j.getName()));
}
