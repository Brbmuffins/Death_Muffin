#!/usr/bin/env node
// Copies exactly the GLBs/textures the Godot world uses (godot/data/slice/assets_used.json, a committed list of every creature, boss,
// NPC and hero model, every prop and gathering-node model the layout places, the floor/wall textures) from public/ into godot/assets/slice/
// (same relative paths; the folder keeps its wave-1 "slice" name so no track's res:// paths move).
// GLBs are DEQUANTIZED on the way (the web build ships KHR_mesh_quantization, which Godot's glTF importer rejects).
// Run: node tools/godot/sync-slice-assets.mjs (the TS exporter that wrote assets_used.json was deleted 2026-10-09; the list is edited by hand now)
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dequantize } from '@gltf-transform/functions';
import { mkdirSync, copyFileSync, readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '../..');
const list = JSON.parse(readFileSync(join(ROOT, 'godot/data/slice/assets_used.json'), 'utf8'));
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
let total = 0;
for (const rel of [...list.models, ...list.textures]) {
  const src = join(ROOT, 'public', rel);
  const dst = join(ROOT, 'godot/assets/slice', rel);
  mkdirSync(dirname(dst), { recursive: true });
  if (rel.endsWith('.glb')) {
    const doc = await io.read(src);
    await doc.transform(dequantize());
    // KHR_mesh_quantization is no longer needed; drop the extension declaration.
    for (const ext of doc.getRoot().listExtensionsUsed()) if (ext.extensionName === 'KHR_mesh_quantization') ext.dispose();
    await io.write(dst, doc);
  } else copyFileSync(src, dst);
  total += statSync(dst).size;
}
console.log(`synced ${list.models.length + list.textures.length} files, ${(total / 1048576).toFixed(1)} MB -> godot/assets/slice/`);
