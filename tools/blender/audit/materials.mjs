// Read-only: print material channels, textures and vertex attributes for GLBs. node tools/blender/audit/materials.mjs <glb...>
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
for (const f of process.argv.slice(2)) { const d = await io.read(f); for (const m of d.getRoot().listMaterials()) console.log(f.split('/').slice(-2).join('/'), m.getName(), 'base', !!m.getBaseColorTexture(), 'norm', !!m.getNormalTexture(), 'mr', !!m.getMetallicRoughnessTexture(), 'em', !!m.getEmissiveTexture(), 'occ', !!m.getOcclusionTexture(), 'metal', m.getMetallicFactor(), 'rough', m.getRoughnessFactor(), 'alpha', m.getAlphaMode(), 'ds', m.getDoubleSided());
 for (const t of d.getRoot().listTextures()) console.log('  tex', t.getMimeType(), t.getSize(), t.getImage().byteLength);
 const p=d.getRoot().listMeshes()[0].listPrimitives()[0]; console.log('  attrs', p.listSemantics().join(','), 'idxType', p.getIndices()?.getComponentType()); }
