/**
 * make-seamless.mjs — guarantees a texture tiles without seams.
 * Blends the image with a copy offset by half its size, weighted toward the
 * copy near the borders. The offset copy is continuous across tile edges and
 * the original is continuous in the middle, so the blend is seamless on both.
 *
 * Usage: node tools/make-seamless.mjs <in> [out] [--feather 0.18]
 */
import sharp from 'sharp';

const [input, outArg, ...rest] = process.argv.slice(2);
if (!input) {
  console.error('usage: node tools/make-seamless.mjs <in> [out] [--feather 0.18]');
  process.exit(1);
}
const fi = rest.indexOf('--feather');
const feather = fi >= 0 ? Number(rest[fi + 1]) : 0.22;
const out = outArg && !outArg.startsWith('--') ? outArg : input;

const { readFileSync, writeFileSync } = await import('node:fs');
const { data, info } = await sharp(readFileSync(input)).removeAlpha().raw().toBuffer({ resolveWithObject: true });
const { width: w, height: h, channels: c } = info;
const res = Buffer.alloc(data.length);
const edgeWeight = (t) => {
  // 1 at the border, 0 once `feather` of the way in; smoothstep between.
  const d = Math.min(t, 1 - t) / feather;
  if (d >= 1) return 0;
  const s = 1 - d;
  return s * s * (3 - 2 * s);
};
for (let y = 0; y < h; y++) {
  const wy = edgeWeight(y / (h - 1));
  const sy = (y + (h >> 1)) % h;
  for (let x = 0; x < w; x++) {
    const wx = edgeWeight(x / (w - 1));
    const m = Math.max(wx, wy);
    const sx = (x + (w >> 1)) % w;
    const i = (y * w + x) * c;
    const j = (sy * w + sx) * c;
    for (let k = 0; k < c; k++) res[i + k] = Math.round(data[i + k] * (1 - m) + data[j + k] * m);
  }
}
let img = sharp(res, { raw: { width: w, height: h, channels: c } });
img = out.endsWith('.webp') ? img.webp({ quality: 88 }) : img.png();
writeFileSync(out, await img.toBuffer());
console.log(`seamless: ${out} (${w}x${h}, feather ${feather})`);
