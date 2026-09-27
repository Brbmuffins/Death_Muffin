/**
 * tint-variants.mjs — recolour a built prop GLB into per-material variants without new
 * Tripo spend. Pixels whose hue falls inside `from` (the concept's vein colour) are moved
 * to the target hue / saturation / brightness; everything else (rock, bone, tombstone) is
 * untouched. Output: public/models/props/<base>_<variant>.glb next to the source.
 *
 *   node tools/tint-variants.mjs            (runs every job below)
 *   node tools/tint-variants.mjs prop_node_ore_seam
 *
 * Used for gathering ore seams (docs/PROFESSIONS-ROADMAP.md §4): one seam model, one tinted
 * GLB per ore. Re-run after rebuilding the base prop.
 */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import sharp from 'sharp';
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const PROPS = join(ROOT, 'public', 'models', 'props');
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);

/**
 * `from`: hue window [min, max] in degrees (wraps if min > max), minimum saturation and optional
 * minimum brightness (`minVal`, e.g. only the bright crystals of a geode, not its shell) of the source
 * pixels. Each variant: target hue (deg), saturation multiplier (or `setSat`: an absolute
 * saturation, for near-white sources), value multiplier.
 */
const JOBS = {
  prop_node_ore_seam: {
    from: { hue: [95, 200], minSat: 0.22 },
    variants: {
      copper: null, // the concept's green-veined copper, as generated
      tin: { hue: 45, sat: 0.12, val: 0.72 }, // dull warm grey
      iron: { hue: 12, sat: 0.9, val: 0.62 }, // dark rust
      bronze: { hue: 30, sat: 1.0, val: 1.15 }, // bright orange-bronze
      silver: { hue: 210, sat: 0.06, val: 1.5 }, // bright near-white
      gold: { hue: 44, sat: 1.1, val: 1.25 },
      steel: { hue: 212, sat: 0.6, val: 0.9 }, // steel blue
    },
  },
  prop_node_ore_geode: {
    from: { hue: [170, 260], minSat: 0.04, minVal: 0.55 },
    variants: {
      moon: null, // silver-blue moon-metal, as generated
      hell: { hue: 16, setSat: 0.88, val: 1.0 }, // ember crystals in the same black shell
    },
  },
};

const rgb2hsv = (r, g, b) => {
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const d = max - min;
  let h = 0;
  if (d) {
    if (max === r) h = ((g - b) / d) % 6;
    else if (max === g) h = (b - r) / d + 2;
    else h = (r - g) / d + 4;
    h *= 60;
    if (h < 0) h += 360;
  }
  return [h, max ? d / max : 0, max];
};
const hsv2rgb = (h, s, v) => {
  const c = v * s;
  const x = c * (1 - Math.abs(((h / 60) % 2) - 1));
  const m = v - c;
  const [r, g, b] = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x] : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x];
  return [r + m, g + m, b + m];
};
const inWindow = (h, [a, b]) => (a <= b ? h >= a && h <= b : h >= a || h <= b);

async function recolour(image, mime, from, to) {
  const { data, info } = await sharp(Buffer.from(image)).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  for (let i = 0; i < data.length; i += 4) {
    const [h, s, v] = rgb2hsv(data[i] / 255, data[i + 1] / 255, data[i + 2] / 255);
    if (s < from.minSat || v < (from.minVal ?? 0) || !inWindow(h, from.hue)) continue;
    // Soft edge: pixels just inside the saturation floor blend, so veins don't get hard rims.
    const k = Math.min(1, (s - from.minSat) / 0.12);
    const [r, g, b] = hsv2rgb(to.hue, to.setSat ?? Math.min(1, s * to.sat), Math.min(1, v * to.val));
    data[i] = Math.round(data[i] * (1 - k) + r * 255 * k);
    data[i + 1] = Math.round(data[i + 1] * (1 - k) + g * 255 * k);
    data[i + 2] = Math.round(data[i + 2] * (1 - k) + b * 255 * k);
  }
  const img = sharp(data, { raw: info });
  return new Uint8Array(await (mime === 'image/png' ? img.png() : img.webp({ quality: 88 })).toBuffer());
}

async function run(base, job) {
  const src = join(PROPS, `${base}.glb`);
  for (const [name, to] of Object.entries(job.variants)) {
    const out = join(PROPS, `${base}_${name}.glb`);
    if (!to) {
      writeFileSync(out, readFileSync(src));
      console.log(`  ${base}_${name}: copy (the generated colour)`);
      continue;
    }
    const doc = await io.read(src);
    // Only base-colour maps carry the vein colour; normal/roughness maps stay as they are.
    const baseMaps = new Set(doc.getRoot().listMaterials().map((m) => m.getBaseColorTexture()).filter(Boolean));
    for (const tex of baseMaps) tex.setImage(await recolour(tex.getImage(), tex.getMimeType(), job.from, to));
    await io.write(out, doc);
    console.log(`  ${base}_${name}: hue ${to.hue}°`);
  }
}

const only = process.argv.slice(2);
for (const [base, job] of Object.entries(JOBS)) {
  if (only.length && !only.includes(base)) continue;
  console.log(`== ${base}`);
  await run(base, job);
}
