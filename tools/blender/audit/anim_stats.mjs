// Read-only: per-GLB animation data breakdown (channels per path, keys, bytes, fps) -> stdout. node anim_stats.mjs <glb...>
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
for (const f of process.argv.slice(2)) {
  const d = await io.read(f); const tot = { translation: 0, rotation: 0, scale: 0, weights: 0 }; const bytes = { translation: 0, rotation: 0, scale: 0, times: 0 };
  const rows = [];
  for (const a of d.getRoot().listAnimations()) {
    let keys = 0, ch = a.listChannels().length, dur = 0; const seen = new Set();
    for (const c of a.listChannels()) { tot[c.getTargetPath()]++; const s = c.getSampler(); const out = s.getOutput(); bytes[c.getTargetPath()] += out.getArray().byteLength; const inp = s.getInput(); if (!seen.has(inp)) { seen.add(inp); bytes.times += inp.getArray().byteLength; } keys = Math.max(keys, inp.getCount()); dur = Math.max(dur, inp.getMax([])[0]); }
    rows.push(`${a.getName()}:${ch}ch/${keys}k/${dur.toFixed(2)}s(${(keys / Math.max(dur, 1e-6)).toFixed(0)}fps)`);
  }
  console.log(f.split('/').slice(-2).join('/'), JSON.stringify(tot), JSON.stringify(bytes)); console.log('   ', rows.join('  '));
}
