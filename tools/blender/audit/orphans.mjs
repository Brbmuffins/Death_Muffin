// Read-only: accessors / data that nothing references (dead weight in a shipped GLB), and what prune() would remove. node orphans.mjs <glb...>
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { prune } from '@gltf-transform/functions';
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
for (const f of process.argv.slice(2)) {
  const d = await io.read(f); const r = d.getRoot();
  const orphan = r.listAccessors().filter((a) => a.listParents().every((p) => p === r || p.propertyType === 'Root'));
  const before = await io.writeBinary(d); await d.transform(prune()); const after = await io.writeBinary(d);
  console.log(f.split('/').slice(-2).join('/'), 'orphan accessors', orphan.length, 'bytes', orphan.reduce((n, a) => n + a.getArray().byteLength, 0), '| re-serialised', before.byteLength, '->', after.byteLength);
}
