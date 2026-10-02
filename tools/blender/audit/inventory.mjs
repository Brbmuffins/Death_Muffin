// Read-only: per-GLB inventory (tris, verts, prims, materials, bones, clips, textures). Usage: node inventory.mjs > inventory.json
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import fs from 'fs'; import path from 'path';
import { fileURLToPath } from 'url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../../public/models');
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const files = [];
(function walk(d){ for (const e of fs.readdirSync(d,{withFileTypes:true})) { const p=path.join(d,e.name); if(e.isDirectory()) walk(p); else if(p.endsWith('.glb')) files.push(p);} })(root);
const out = [];
for (const f of files.sort()) {
  const doc = await io.read(f); const r = doc.getRoot();
  let tris=0, verts=0, prims=0, skinnedPrims=0;
  for (const m of r.listMeshes()) for (const p of m.listPrimitives()) {
    prims++; const pos=p.getAttribute('POSITION'); verts+=pos.getCount();
    const idx=p.getIndices(); tris += (idx?idx.getCount():pos.getCount())/3;
    if (p.getAttribute('JOINTS_0')) skinnedPrims++;
  }
  // count per node instance (a mesh used by several nodes counts per node)
  let nodeTris=0, nodePrims=0;
  for (const n of r.listNodes()) { const m=n.getMesh(); if(!m) continue; for(const p of m.listPrimitives()){ nodePrims++; const idx=p.getIndices(); nodeTris+=(idx?idx.getCount():p.getAttribute('POSITION').getCount())/3; } }
  const texs = r.listTextures().map(t=>({ mime:t.getMimeType(), size:t.getSize(), bytes:t.getImage()?.byteLength }));
  let animBytes=0; for (const a of r.listAnimations()) for (const s of a.listSamplers()) { animBytes += (s.getInput()?.getArray()?.byteLength||0)+(s.getOutput()?.getArray()?.byteLength||0); }
  const joints = r.listSkins().reduce((n,s)=>n+s.listJoints().length,0);
  out.push({ file: path.relative(root,f), bytes: fs.statSync(f).size, tris: nodeTris, verts, prims: nodePrims, skinnedPrims, materials: r.listMaterials().length,
    bones: joints, skins: r.listSkins().length, clips: r.listAnimations().length, clipNames: r.listAnimations().map(a=>a.getName()), animBytes,
    textures: texs, texBytes: texs.reduce((n,t)=>n+(t.bytes||0),0), ext: r.listExtensionsUsed().map(e=>e.extensionName) });
}
console.log(JSON.stringify(out));
