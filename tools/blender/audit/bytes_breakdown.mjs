// Read-only: where do a GLB's bytes go? (accessor bytes by role, images, JSON overhead).  node bytes_breakdown.mjs <glb...>
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import fs from 'fs';
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const tot = {};
for (const f of process.argv.slice(2)) {
  const d = await io.read(f); const r = d.getRoot(); const role = new Map();
  for (const m of r.listMeshes()) for (const p of m.listPrimitives()) { for (const s of p.listSemantics()) role.set(p.getAttribute(s), 'vtx:' + s); if (p.getIndices()) role.set(p.getIndices(), 'indices'); for (const t of p.listTargets()) for (const s of t.listSemantics()) role.set(t.getAttribute(s), 'morph'); }
  for (const a of r.listAnimations()) for (const s of a.listSamplers()) { role.set(s.getInput(), 'anim:times'); role.set(s.getOutput(), 'anim:values'); }
  for (const s of r.listSkins()) if (s.getInverseBindMatrices()) role.set(s.getInverseBindMatrices(), 'ibm');
  const b = {}; for (const acc of r.listAccessors()) { const k = role.get(acc) || 'other'; b[k] = (b[k] || 0) + acc.getArray().byteLength; }
  b.images = r.listTextures().reduce((n, t) => n + t.getImage().byteLength, 0);
  b.file = fs.statSync(f).size;
  console.log(f.split('/').slice(-2).join('/'), JSON.stringify(b));
  for (const [k, v] of Object.entries(b)) tot[k] = (tot[k] || 0) + v;
}
if (process.argv.length > 3) console.log('TOTAL', JSON.stringify(tot));
