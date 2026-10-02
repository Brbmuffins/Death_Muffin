/**
 * make-wing-textures.mjs — warm, de-purpled variants of the Chapterhouse flagstone and stone wall for the Alchemist's Wing
 * (the originals carry painted violet blotches that a multiply tint cannot remove). No generation spend: pure pixel maths.
 *   node tools/make-wing-textures.mjs
 * Output: public/art/textures/wing_floor.webp, wing_wall.webp
 */
import sharp from 'sharp';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'public', 'art', 'textures');

// flat: contrast kept around the mean (<1 calms the painted dark blotches). keep: share of the original colour that survives; warm: per-channel multiplier on the luminance; gain: brightness.
const JOBS = {
  wing_floor: { src: 'flagstone.webp', keep: 0.1, warm: [1.0, 0.8, 0.58], gain: 1.55, lift: 12, flat: 0.6 },
  wing_wall: { src: 'stone_wall.webp', keep: 0.1, warm: [1.0, 0.82, 0.62], gain: 1.45, lift: 8, flat: 0.75 },
};

for (const [name, j] of Object.entries(JOBS)) {
  const { data, info } = await sharp(join(DIR, j.src)).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const out = Buffer.alloc(data.length);
  let mean = 0;
  for (let i = 0; i < data.length; i += 3) mean += 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
  mean /= data.length / 3;
  for (let i = 0; i < data.length; i += 3) {
    const r = data[i], g = data[i + 1], b = data[i + 2];
    const lum0 = 0.299 * r + 0.587 * g + 0.114 * b;
    const lum = mean + (lum0 - mean) * j.flat;
    const px = [r, g, b];
    for (let c = 0; c < 3; c++) {
      const warm = (lum * j.gain + j.lift) * j.warm[c];
      out[i + c] = Math.max(0, Math.min(255, Math.round(warm * (1 - j.keep) + px[c] * j.keep * j.gain)));
    }
  }
  await sharp(out, { raw: { width: info.width, height: info.height, channels: 3 } }).webp({ quality: 86 }).toFile(join(DIR, `${name}.webp`));
  console.log(name, info.width, info.height);
}
