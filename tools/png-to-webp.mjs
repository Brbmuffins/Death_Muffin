/**
 * png-to-webp.mjs — converts every public/art/**.png to a sibling .webp (and deletes the PNG when the WebP is written).
 *   node tools/png-to-webp.mjs [--keep] [--dir public/art]
 * Icons/UI: q90 with full-quality alpha. fx/ (additive glow gradients, banding-prone): near-lossless.
 * Prints bytes before/after. References in archive/legacy-web:src/ are `.webp` (art/items/<id>.webp etc.).
 */
import sharp from 'sharp';
import { readdirSync, statSync, unlinkSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const KEEP = args.includes('--keep');
const di = args.indexOf('--dir');
const DIR = di >= 0 ? args[di + 1] : join(ROOT, 'public', 'art');
const walk = (d) => readdirSync(d, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : e.name.endsWith('.png') ? [join(d, e.name)] : []));
let b = 0, a = 0;
for (const png of walk(DIR).sort()) {
  const rel = relative(DIR, png);
  const opts = rel.startsWith('fx') ? { nearLossless: true, quality: 85, alphaQuality: 100, effort: 6 } : { quality: 90, alphaQuality: 100, effort: 6 };
  const out = png.replace(/\.png$/, '.webp');
  await sharp(png).webp(opts).toFile(out);
  b += statSync(png).size;
  a += statSync(out).size;
  if (!KEEP) unlinkSync(png);
}
console.log(`${(b / 1e6).toFixed(2)} MB PNG -> ${(a / 1e6).toFixed(2)} MB WebP`);
