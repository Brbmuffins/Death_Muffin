// Read-only: how much animation data is byte-identical across models (candidate for a shared clip library).
// node anim_dupes.mjs  -> per clip name: models carrying it, distinct payloads, bytes duplicated
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import crypto from 'crypto'; import fs from 'fs'; import path from 'path';
import { fileURLToPath } from 'url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../public/models');
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const seen = new Map(); let total = 0, dup = 0; const perClip = {};
for (const dir of fs.readdirSync(root)) {
  const f = path.join(root, dir, 'character.glb'); if (!fs.existsSync(f)) continue;
  const d = await io.read(f);
  for (const a of d.getRoot().listAnimations()) {
    const h = crypto.createHash('sha1'); let bytes = 0;
    for (const c of a.listChannels()) { h.update(c.getTargetNode()?.getName() + c.getTargetPath()); const s = c.getSampler(); for (const acc of [s.getInput(), s.getOutput()]) { const arr = acc.getArray(); h.update(Buffer.from(arr.buffer, arr.byteOffset, arr.byteLength)); bytes += arr.byteLength; } }
    const k = h.digest('hex'); total += bytes; const pc = (perClip[a.getName()] ||= { n: 0, distinct: new Set(), bytes: 0, dupBytes: 0 }); pc.n++; pc.distinct.add(k); pc.bytes += bytes;
    if (seen.has(k)) { dup += bytes; pc.dupBytes += bytes; } else seen.set(k, dir);
  }
}
console.log('total anim bytes', total, 'byte-identical duplicates', dup, ((dup / total) * 100).toFixed(1) + '%');
for (const [n, v] of Object.entries(perClip).sort((a, b) => b[1].bytes - a[1].bytes).slice(0, 20)) console.log(n.padEnd(10), 'models', v.n, 'distinct', v.distinct.size, 'MB', (v.bytes / 1e6).toFixed(2), 'dupMB', (v.dupBytes / 1e6).toFixed(2));
