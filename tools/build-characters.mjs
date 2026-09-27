/**
 * build-characters.mjs — Tripo v3 outputs (art-src/tripo/<slug>/, gitignored)
 * → one shippable GLB per character: public/models/<slug>/character.glb
 *
 * v3 retarget GLBs each carry the full skinned mesh + one baked clip, all from
 * the same rig task, so they share a rest pose (the v1 FBX/GLB rest-space
 * mismatch documented in ASSET_PIPELINE.md does not apply). We keep the mesh
 * from the idle clip file and copy every other file's animation channels onto
 * it by joint name, so the runtime loads one file with named clips.
 *
 * Usage: node tools/build-characters.mjs [slug ...]   (default: every slug with a state.json)
 */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dedup, prune, resample, textureCompress, quantize } from '@gltf-transform/functions';
import sharp from 'sharp';
import { existsSync, mkdirSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const RAW = join(ROOT, 'art-src', 'tripo');
const OUT = join(ROOT, 'public', 'models');

/** Tripo preset suffix → runtime clip name. */
const CLIP_NAMES = {
  idle: 'idle',
  walk: 'walk',
  run: 'run',
  cast_a_spell: 'cast',
  slash: 'attack',
  shoot: 'attack',
  hurt: 'hurt',
  dig: 'dig',
  fall: 'death',
};

/** Per-slug texture budget (px). Hero and boss get more; horde enemies less. */
const TEXTURE_SIZE = { necromancer: 1024, prelate: 1024, bone_golem: 1024, boss_gravedigger_king: 1024, boss_bone_abbess: 1024, boss_drowned_congregation: 1024, prop_mausoleum: 1024, prop_bell_altar: 1024 };
const DEFAULT_TEXTURE = 512;

const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const mb = (p) => (statSync(p).size / 1e6).toFixed(2) + 'MB';

function copyAnimation(srcDoc, dstDoc, clipName) {
  const src = srcDoc.getRoot().listAnimations()[0];
  if (!src) return false;
  const byName = new Map(dstDoc.getRoot().listNodes().map((n) => [n.getName(), n]));
  const anim = dstDoc.createAnimation(clipName);
  const buffer = dstDoc.getRoot().listBuffers()[0];
  let channels = 0;
  for (const ch of src.listChannels()) {
    const target = byName.get(ch.getTargetNode()?.getName());
    if (!target) continue;
    const s = ch.getSampler();
    const input = dstDoc.createAccessor().setType('SCALAR').setArray(s.getInput().getArray().slice()).setBuffer(buffer);
    const output = dstDoc
      .createAccessor()
      .setType(s.getOutput().getType())
      .setArray(s.getOutput().getArray().slice())
      .setBuffer(buffer);
    const sampler = dstDoc.createAnimationSampler().setInput(input).setOutput(output).setInterpolation(s.getInterpolation());
    anim.addSampler(sampler);
    anim.addChannel(dstDoc.createAnimationChannel().setTargetNode(target).setTargetPath(ch.getTargetPath()).setSampler(sampler));
    channels++;
  }
  return channels > 0;
}

async function build(slug) {
  const dir = join(RAW, slug);
  const clips = readdirSync(dir)
    .filter((f) => /^anim_.+\.glb$/.test(f))
    .map((f) => ({ file: join(dir, f), preset: f.slice(5, -4) }));
  // Quadrupeds: the generic walk preset is named "walk" too.
  const base = clips.find((c) => c.preset === 'idle') ?? clips[0];
  const source = base ? base.file : join(dir, existsSync(join(dir, 'rig.glb')) ? 'rig.glb' : 'model.glb');
  console.log(`\n== ${slug}  (base: ${source.split(/[\\/]/).pop()}, ${clips.length} clip file(s))`);

  const doc = await io.read(source);
  for (const a of doc.getRoot().listAnimations()) a.dispose();
  const names = [];
  for (const c of clips) {
    const name = CLIP_NAMES[c.preset] ?? c.preset;
    if (names.includes(name)) continue;
    const srcDoc = await io.read(c.file);
    if (copyAnimation(srcDoc, doc, name)) names.push(name);
  }
  const size = TEXTURE_SIZE[slug] ?? (slug.startsWith('hero_') ? 1024 : DEFAULT_TEXTURE);
  await doc.transform(
    dedup(),
    resample({ tolerance: 1e-4 }),
    textureCompress({ encoder: sharp, targetFormat: 'webp', resize: [size, size], quality: 86 }),
    quantize({ quantizeNormal: 10, quantizeTexcoord: 12, quantizePosition: 14 }),
    prune(),
  );
  // Static props (no rig/clips) ship flat under models/props/.
  const isProp = clips.length === 0 && !existsSync(join(dir, 'rig.glb'));
  const outDir = isProp ? join(OUT, 'props') : join(OUT, slug);
  mkdirSync(outDir, { recursive: true });
  // Environment props drop the `prop_` prefix (layout ids like `tombstone_round`); gathering nodes
  // keep it, because the professions code loads `models/props/prop_node_<model>.glb` (NodeViews, layout).
  const outFile = join(outDir, isProp ? `${slug.replace(/^prop_(?!node_)/, '')}.glb` : 'character.glb');
  await io.write(outFile, doc);
  const tris = doc
    .getRoot()
    .listMeshes()
    .flatMap((m) => m.listPrimitives())
    .reduce((n, p) => n + (p.getIndices()?.getCount() ?? 0) / 3, 0);
  console.log(`  ${mb(source)} → ${mb(outFile)}  tris ${tris}  clips [${names.join(', ')}]  tex ${size}px`);
  if (!isProp) writeFileSync(join(outDir, 'clips.json'), JSON.stringify({ clips: names, tris }, null, 2) + '\n');
}

const slugs = process.argv.slice(2);
const all = readdirSync(RAW).filter((s) => existsSync(join(RAW, s, 'state.json')));
for (const slug of slugs.length ? slugs : all) {
  try {
    await build(slug);
  } catch (err) {
    console.error(`  FAILED ${slug}: ${err.message}`);
  }
}
