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
  // Tripo's 'hurt' preset is a 14s lying-injured clip, not a flinch: kept out of play (2026-09-28).
  hurt: 'hurt_down',
  dig: 'dig',
  fall: 'death',
  // Variety clips (2026-09-28): Creature picks between a clip and its numbered variants at random.
  // (defeat_02 stays standing and chop is an alias of slash: see the grave_robber spec's `catalogued`.)
  defeat_03: 'death2',
  hit_to_body_01: 'hurt',
  hit_to_head: 'hurt2',
  hit_to_side: 'hurt3',
  box_01: 'attack2',
  front_kick_01: 'attack2',
};

/** Per-slug texture budget (px). Hero and boss get more; horde enemies less. */
const TEXTURE_SIZE = { boss_plague_saint: 1024, boss_cinder_regent: 1024, slag_brute: 1024, tithe_bat: 256, prop_mantle_rib: 256, prop_mantle_vertebra: 256, prop_mantle_skullchip: 256, prop_grave_hand: 256, necromancer: 1024, prelate: 1024, bone_golem: 1024, boss_gravedigger_king: 1024, boss_bone_abbess: 1024, boss_drowned_congregation: 1024, prop_mausoleum: 1024, prop_bell_altar: 1024 };
const DEFAULT_TEXTURE = 512;

/**
 * Necro combat clips (docs/ALCHEMY-AND-WORLDS-PLAN.md N2, measured with tools/measure-clips.mjs). Tripo presets carry
 * seconds of idle lead-in/out, so each one is trimmed to its action window: `start`/`end` are source seconds and
 * `release` is the source time of the blow / cast release (hand peak speed). Hip position is stored relative to
 * the source clip's first frame (the standing pose), so the runtime keeps the crouch/leap but drops the drift.
 * Only the four necromancer discipline heroes get them. `release` ends up in clips.json as a 0..1 fraction.
 */
const NECRO_HEROES = new Set(['hero_gravecaller', 'hero_ossuary', 'hero_mourner', 'hero_rotweaver']);
const COMBAT_TRIMS = {
  slam: { preset: 'slash', start: 1.3, end: 3.3, release: 2.1 },
  sweep: { preset: 'box_03', start: 0.3, end: 1.7, release: 0.7 },
  flick: { preset: 'pitch_baseball', start: 1.25, end: 2.3, release: 1.9 },
  channel: { preset: 'sing_01', start: 5.9, end: 7.5, release: 7.0 },
  summon: { preset: 'basketball_shot', start: 1.4, end: 3.0, release: 2.2 },
};
/** Presets that exist only as a source for a trimmed combat clip (never shipped whole). */
const TRIM_ONLY = new Set(['pitch_baseball', 'sing_01', 'basketball_shot', 'box_03']);

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

/** Copy a trimmed window of the source animation: times shifted to 0, Hip translation made relative to frame 0. */
function copyTrimmed(srcDoc, dstDoc, clipName, { start, end }) {
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
    const times = s.getInput().getArray();
    const vals = s.getOutput().getArray();
    const stride = vals.length / times.length;
    const keep = [];
    for (let i = 0; i < times.length; i++) if (times[i] >= start - 1e-4 && times[i] <= end + 1e-4) keep.push(i);
    if (keep.length < 2) continue;
    const isHip = target.getName() === 'Hip' && ch.getTargetPath() === 'translation';
    const t = new Float32Array(keep.length);
    const v = new Float32Array(keep.length * stride);
    keep.forEach((i, k) => {
      t[k] = times[i] - times[keep[0]];
      for (let c = 0; c < stride; c++) v[k * stride + c] = vals[i * stride + c] - (isHip ? vals[c] : 0);
    });
    const input = dstDoc.createAccessor().setType('SCALAR').setArray(t).setBuffer(buffer);
    const output = dstDoc.createAccessor().setType(s.getOutput().getType()).setArray(v).setBuffer(buffer);
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
    if (names.includes(name) || name === 'hurt_down' || TRIM_ONLY.has(c.preset)) continue;
    const srcDoc = await io.read(c.file);
    if (copyAnimation(srcDoc, doc, name)) names.push(name);
  }
  const release = {};
  if (NECRO_HEROES.has(slug)) {
    for (const [name, trim] of Object.entries(COMBAT_TRIMS)) {
      const c = clips.find((x) => x.preset === trim.preset);
      if (!c) continue;
      if (copyTrimmed(await io.read(c.file), doc, name, trim)) {
        names.push(name);
        release[name] = +((trim.release - trim.start) / (trim.end - trim.start)).toFixed(3);
      }
    }
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
  if (!isProp) writeFileSync(join(outDir, 'clips.json'), JSON.stringify({ clips: names, tris, ...(Object.keys(release).length ? { release } : {}) }, null, 2) + '\n');
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
