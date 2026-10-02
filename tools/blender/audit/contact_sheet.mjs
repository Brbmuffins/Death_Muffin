// node contact_sheet.mjs <out.webp> <label-bg #hex> <img1> <img2> ... [--row2 <img...>]   — rows of 256px tiles (sharp)
import sharp from 'sharp';
const [out, bg, ...rest] = process.argv.slice(2);
const i2 = rest.indexOf('--row2'); const r1 = i2 < 0 ? rest : rest.slice(0, i2); const r2 = i2 < 0 ? [] : rest.slice(i2 + 1);
const T = 256, rows = r2.length ? 2 : 1, cols = Math.max(r1.length, r2.length);
const comps = [];
for (const [ri, row] of [r1, r2].entries()) for (const [ci, f] of row.entries()) comps.push({ input: await sharp(f, { density: 300 }).resize(T, T, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } }).png().toBuffer(), left: ci * T, top: ri * T });
await sharp({ create: { width: cols * T, height: rows * T, channels: 4, background: bg } }).composite(comps).webp({ quality: 82 }).toFile(out);
