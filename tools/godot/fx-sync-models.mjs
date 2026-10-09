#!/usr/bin/env node
// Copies the four prop GLBs DmFx instances (Bone Mantle shards, Grave Hands) into godot/assets/fx/models/, dequantized
// (Godot's glTF importer rejects KHR_mesh_quantization). Run: node tools/godot/fx-sync-models.mjs
// (the TS exporter export-fx.ts was deleted 2026-10-09). Textures, if needed:
//   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock node tools/godot/fx-textures.mjs
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dequantize } from '@gltf-transform/functions';
import { mkdirSync } from 'node:fs';

const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
mkdirSync('godot/assets/fx/models', { recursive: true });
for (const n of ['mantle_rib', 'mantle_vertebra', 'mantle_skullchip', 'grave_hand']) {
  const doc = await io.read(`public/models/props/${n}.glb`);
  await doc.transform(dequantize());
  for (const ext of doc.getRoot().listExtensionsUsed()) if (ext.extensionName === 'KHR_mesh_quantization') ext.dispose();
  await io.write(`godot/assets/fx/models/${n}.glb`, doc);
}
console.log('fx-sync-models: 4 GLBs');
