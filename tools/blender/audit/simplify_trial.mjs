// Read-only trial: meshoptimizer simplify (attribute-aware, via glTF-Transform) on a copy of a shipped GLB -> out path (use /tmp).
// node simplify_trial.mjs <in.glb> <ratio> <error> <out.glb>   prints {"tris_before","tris_after","bytes_before","bytes_after"}
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { weld, simplify, prune } from '@gltf-transform/functions';
import { MeshoptSimplifier } from 'meshoptimizer';
import fs from 'fs';
const [, , inp, ratio, error, out] = process.argv;
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const tris = (d) => d.getRoot().listMeshes().flatMap((m) => m.listPrimitives()).reduce((n, p) => n + (p.getIndices()?.getCount() ?? p.getAttribute('POSITION').getCount()) / 3, 0);
const doc = await io.read(inp); const before = tris(doc);
await MeshoptSimplifier.ready;
await doc.transform(weld({ tolerance: 1e-4 }), simplify({ simplifier: MeshoptSimplifier, ratio: +ratio, error: +error, lockBorder: false }), prune());
await io.write(out, doc);
console.log(JSON.stringify({ tris_before: before, tris_after: tris(doc), bytes_before: fs.statSync(inp).size, bytes_after: fs.statSync(out).size }));
