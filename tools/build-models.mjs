/**
 * build-models.mjs — converts raw Tripo character outputs (art-src/tripo/, gitignored)
 * into shippable web assets under public/models/<slug>/.
 *
 *   rig.glb     — skinned mesh, textures resized to 1K WebP, pruned/deduped
 *   <anim>.glb  — animation clip only (geometry/materials stripped), tiny
 *
 * Repeatable: re-run after regenerating any character with the Tripo pipeline.
 * Usage: node tools/build-models.mjs [slug ...]   (default: all)
 */
import { NodeIO } from '@gltf-transform/core';
import { prune, dedup, resample, textureCompress, weld, simplify, quantize } from '@gltf-transform/functions';
import { MeshoptSimplifier } from 'meshoptimizer';
import sharp from 'sharp';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, statSync, rmSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const RAW = join(ROOT, 'art-src', 'tripo');
const OUT = join(ROOT, 'public', 'models');
const FBX2GLTF = join(ROOT, 'node_modules', 'fbx2gltf', 'bin', 'Windows_NT', 'FBX2glTF.exe');

/** slug -> { anims: [dir names under art-src/tripo/<slug>/] } ; rig dir is always "rig" (or a bare pbr glb for static models) */
const CHARACTERS = {
  brandolf: { anims: ['idle', 'walk', 'run', 'hurt'] },
  bogar:    { anims: ['idle', 'walk', 'run', 'hurt', 'slash'] },
  guardian: { anims: ['idle', 'walk', 'run', 'hurt', 'slash'] },
  arcanist: { anims: ['idle', 'walk', 'run', 'hurt', 'shoot'] },
  slime:    { anims: [] }, // static PBR model at art-src/tripo/slime/*.glb
};

const io = new NodeIO();
const mb = (p) => (statSync(p).size / 1e6).toFixed(1) + 'MB';
const findFile = (dir, suffix) => {
  const f = readdirSync(dir).find((n) => n.endsWith(suffix));
  if (!f) throw new Error(`no *${suffix} in ${dir}`);
  return join(dir, f);
};

async function optimizeRig(srcGlb, dstGlb) {
  const doc = await io.read(srcGlb);
  // Drop any baked animation — clips ship separately.
  for (const anim of doc.getRoot().listAnimations()) anim.dispose();
  await doc.transform(
    dedup(),
    weld(),
    // Tripo rigs ship ~1.5M triangles; ~75k is plenty for a stylized web hero.
    simplify({ simplifier: MeshoptSimplifier, ratio: 0.05, error: 0.001 }),
    textureCompress({ encoder: sharp, targetFormat: 'webp', resize: [1024, 1024] }),
    quantize(),
    prune(),
  );
  await io.write(dstGlb, doc);
  console.log(`  rig  ${mb(srcGlb)} -> ${mb(dstGlb)}`);
}

/**
 * Character mesh source: the idle-retarget FBX, NOT Tripo's GLB rig bake.
 * Tripo v1.0 humanoid retargets are FBX-native — the GLB rig's twist-bone rest
 * space differs from the FBX clips, which pitches the character prone when
 * FBX-derived clips play on the GLB rig. Deriving the mesh from the same FBX
 * family as the clips keeps skeleton + rest pose consistent (verified fix).
 */
function fbxToGlb(srcFbx, dstGlb) {
  execFileSync(FBX2GLTF, ['--binary', '--input', srcFbx, '--output', dstGlb], { stdio: 'pipe' });
}

async function buildAnim(srcFbx, dstGlb, tmpDir) {
  // 1) FBX -> GLB (fbx2gltf), 2) strip geometry/materials, keep skeleton + clip
  mkdirSync(tmpDir, { recursive: true });
  const tmpGlb = join(tmpDir, 'anim.glb');
  execFileSync(FBX2GLTF, ['--binary', '--input', srcFbx, '--output', tmpGlb], { stdio: 'pipe' });

  const doc = await io.read(tmpGlb);
  const root = doc.getRoot();
  for (const node of root.listNodes()) node.setMesh(null);
  for (const mesh of root.listMeshes()) mesh.dispose();
  for (const skin of root.listSkins()) skin.dispose();
  for (const mat of root.listMaterials()) mat.dispose();
  for (const tex of root.listTextures()) tex.dispose();
  await doc.transform(resample(), prune());

  const clips = root.listAnimations().map((a) => a.getName());
  await io.write(dstGlb, doc);
  rmSync(tmpDir, { recursive: true, force: true });
  console.log(`  anim ${mb(srcFbx)} -> ${mb(dstGlb)}  clips=[${clips.join(', ')}]`);
}

const only = process.argv.slice(2);
for (const [slug, cfg] of Object.entries(CHARACTERS)) {
  if (only.length && !only.includes(slug)) continue;
  const rawDir = join(RAW, slug);
  if (!existsSync(rawDir)) { console.warn(`skip ${slug}: ${rawDir} missing`); continue; }
  const outDir = join(OUT, slug);
  mkdirSync(outDir, { recursive: true });
  console.log(slug);

  if (cfg.anims.length > 0) {
    // Animated character: mesh comes from the idle FBX (same family as clips).
    const tmp = join(outDir, '.tmp');
    mkdirSync(tmp, { recursive: true });
    const tmpRig = join(tmp, 'rig-src.glb');
    fbxToGlb(findFile(join(rawDir, cfg.anims[0]), '-model.fbx'), tmpRig);
    await optimizeRig(tmpRig, join(outDir, 'rig.glb'));
    rmSync(tmp, { recursive: true, force: true });
  } else {
    // Static model (slime): optimize the Tripo PBR GLB directly.
    await optimizeRig(findFile(rawDir, '.glb'), join(outDir, 'rig.glb'));
  }

  for (const anim of cfg.anims) {
    const srcFbx = findFile(join(rawDir, anim), '-model.fbx');
    await buildAnim(srcFbx, join(outDir, `${anim}.glb`), join(outDir, '.tmp'));
  }
}
console.log('done');
