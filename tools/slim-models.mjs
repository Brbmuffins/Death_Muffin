/**
 * slim-models.mjs — in-place, idempotent size pass over the shipped GLBs in public/models.
 *
 *   node tools/slim-models.mjs [--dry] [--no-trim] [--dir public/models] [--only <slug-or-path-substring> ...]
 *
 * 1. prune()  — drops accessors/materials/textures nothing references (quantize() in build-characters.mjs
 *               leaves the pre-quantize float accessors behind, ~170 KB per character).
 * 2. dedup()  — merges identical accessors/materials/textures.
 * 3. Hero clip trim — `cast` and `dig` on the player-avatar rigs (hero_* and `necromancer`, the only models built with
 *               Creature `inPlace`) are cut to the window src/graphics/inPlaceAnimation.ts plays (cast 1.1 s, dig 1.3 s)
 *               plus a margin. Every other model keeps its full clips: enemies, bosses and thralls play `cast`/`dig`
 *               whole (laborers loop `dig`; burrowing enemies play it for BURROW.digS).
 *
 * Prints before/after bytes per file. Re-running is a no-op (files are only written when smaller).
 */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dedup, prune } from '@gltf-transform/functions';
import { readdirSync, statSync, existsSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const DRY = args.includes('--dry');
const NO_TRIM = args.includes('--no-trim');
const di = args.indexOf('--dir');
const DIR = di >= 0 ? args[di + 1] : join(ROOT, 'public', 'models');
const only = [];
const oi = args.indexOf('--only');
if (oi >= 0) for (const a of args.slice(oi + 1)) if (!a.startsWith('--')) only.push(a);

/** Seconds to keep per clip, on rigs whose clips run through inPlaceHeroClip (played windows 1.1 s / 1.3 s). */
const HERO_TRIM = { cast: 1.4, dig: 1.6 };
const isPlayerRig = (rel) => /^(hero_[^/]+|necromancer)\/character\.glb$/.test(rel);

const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);
const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : e.name.endsWith('.glb') ? [join(d, e.name)] : []));

/** Cut an animation to exactly [0, keep] seconds: later keys are dropped and the first key past `keep` is replaced by the
 *  value interpolated at `keep` (static tracks are often just two keys spanning the whole clip). Samplers can share one
 *  input accessor, so every cut is planned from the untouched times before anything is rewritten. */
function trimAnimation(anim, keep) {
  const plans = [];
  const inputs = new Map();
  for (const s of anim.listSamplers()) {
    const input = s.getInput();
    if (!inputs.has(input)) inputs.set(input, input.getArray());
    const orig = inputs.get(input);
    const i = orig.findIndex((t) => t > keep + 1e-6);
    if (i < 0) continue;
    plans.push({ s, input, orig, i });
  }
  const done = new Set();
  for (const { s, input, orig, i } of plans) {
    const output = s.getOutput();
    const stride = output.getElementSize();
    const vals = output.getArray();
    const n = i + 1;
    const out = vals.slice(0, n * stride);
    if (i > 0 && s.getInterpolation() === 'LINEAR') {
      const f = (keep - orig[i - 1]) / (orig[i] - orig[i - 1]);
      let len = 0;
      for (let c = 0; c < stride; c++) {
        const a = vals[(i - 1) * stride + c], b = vals[i * stride + c];
        out[i * stride + c] = a + (b - a) * f;
        len += out[i * stride + c] ** 2;
      }
      if (stride === 4 && s.getOutput().getType() === 'VEC4') {
        len = Math.sqrt(len) || 1;
        for (let c = 0; c < 4; c++) out[i * stride + c] /= len;
      }
    } else if (i > 0) {
      for (let c = 0; c < stride; c++) out[i * stride + c] = vals[(i - 1) * stride + c];
    }
    output.setArray(out);
    if (!done.has(input)) {
      const t = orig.slice(0, n);
      t[i] = keep;
      input.setArray(t);
      done.add(input);
    }
  }
}

let before = 0, after = 0, n = 0;
for (const file of walk(DIR).sort()) {
  const rel = relative(DIR, file).split('\\').join('/');
  if (only.length && !only.some((o) => rel.includes(o))) continue;
  const size0 = statSync(file).size;
  const doc = await io.read(file);
  if (!NO_TRIM && isPlayerRig(rel)) {
    for (const anim of doc.getRoot().listAnimations()) {
      const keep = HERO_TRIM[anim.getName()];
      if (keep) trimAnimation(anim, keep);
    }
  }
  await doc.transform(dedup(), prune());
  const bytes = await io.writeBinary(doc);
  const size1 = bytes.byteLength;
  before += size0;
  n++;
  if (size1 < size0) {
    after += size1;
    if (!DRY) await io.write(file, doc);
    console.log(`${rel.padEnd(52)} ${(size0 / 1e3).toFixed(0).padStart(6)} KB -> ${(size1 / 1e3).toFixed(0).padStart(6)} KB`);
  } else {
    after += size0;
  }
}
console.log(`\n${n} files  ${(before / 1e6).toFixed(2)} MB -> ${(after / 1e6).toFixed(2)} MB  (${((1 - after / before) * 100).toFixed(1)}% smaller)${DRY ? '  [dry run]' : ''}`);
