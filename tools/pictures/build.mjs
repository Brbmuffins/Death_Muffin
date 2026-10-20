/**
 * build.mjs — turns a generated picture (a Gemini concept, or any image in the checkout) into one of the game's flat pictures, as one of the
 * kinds in tools/pictures/kinds.json (ability icon, item icon, portrait, loading art, floor texture ...). ASSET_PIPELINE.md "Pictures".
 *
 * Usage (from the checkout root):
 *   node tools/pictures/build.mjs <kind> <name> <source> [--replace]
 *     kind     a key of tools/pictures/kinds.json
 *     name     the file name without extension ([a-z0-9][a-z0-9_-]*): writes <kind.dir>/<name>.webp
 *     source   a concept id (art-src/concepts/<id>.png) or the path of a PNG, JPEG or WebP inside the checkout
 *     --replace  overwrite an existing picture (an edit of it); without it an existing file is never touched
 *
 * Steps: a light frame the image model drew around the picture is cut off (not for tiling kinds) -> cover-crop to the kind's size -> tiling kinds
 * are made seamless -> WebP, lowering the quality until it fits the kind's size limit -> the file, a Godot .import for a new file (Lossless for UI
 * art, VRAM Compressed with mipmaps for 3D textures; Godot fills in the rest on its next import) -> its record in art-manifest/images.json
 * (the source, its hash and the concept's prompt). The Discord agent runs it through server/death-muffin/discord-agent/build-picture.sh.
 */
import sharp from 'sharp';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const KINDS_FILE = 'tools/pictures/kinds.json';
export const MANIFEST = 'art-manifest/images.json';
export const NAME_RE = /^[a-z0-9][a-z0-9_-]{1,47}$/;
export const CONCEPT_RE = /^[a-z0-9_]{3,40}$/;
export const ASPECTS = ['1:1', '3:4', '4:3', '2:3', '3:2', '9:16', '16:9'];
const KIND_KEYS = ['label', 'dir', 'size', 'aspect', 'genSize', 'maxKB', 'use', 'tile', 'style', 'recipe'];
const QUALITIES = [88, 80, 72, 64];
const FRAME_LUMA = 150;      // a border row/column this bright on average is a frame, not the near-black picture
const FRAME_MAX = 0.12;      // never cut more than this share of a side

const sha256 = (buf) => `sha256:${createHash('sha256').update(buf).digest('hex')}`;
const isObj = (x) => x && typeof x === 'object' && !Array.isArray(x);

/** The aspect a size asks the image model for: the nearest one it offers. */
export function aspectOf(kind) {
  if (kind.aspect) return kind.aspect;
  const want = kind.size[0] / kind.size[1];
  const off = (a) => { const [w, h] = a.split(':').map(Number); return Math.abs(w / h - want); };
  return ASPECTS.reduce((best, a) => (off(a) < off(best) ? a : best), '1:1');
}

/** Problems with one kind entry (an empty list when it is fine). `exists(rel)` says whether a checkout path exists. */
export function kindProblems(id, k, exists = () => true) {
  const p = [];
  if (!/^[a-z0-9_]{3,40}$/.test(id)) p.push(`kind id "${id}" must match [a-z0-9_]{3,40}`);
  if (!isObj(k)) return [...p, `${id}: must be an object`];
  for (const key of Object.keys(k)) if (!KIND_KEYS.includes(key)) p.push(`${id}: field "${key}" is not known`);
  if (typeof k.label !== 'string' || !k.label) p.push(`${id}: label is required`);
  if (typeof k.dir !== 'string' || !/^client\/assets\/[a-z0-9_/]+$/.test(k.dir)) p.push(`${id}: dir must be a folder under client/assets/`);
  else if (!exists(k.dir)) p.push(`${id}: dir ${k.dir} does not exist`);
  if (!(Array.isArray(k.size) && k.size.length === 2 && k.size.every((n) => Number.isInteger(n) && n >= 32 && n <= 2048))) p.push(`${id}: size must be [w, h], each 32 to 2048`);
  if (k.aspect !== undefined && !ASPECTS.includes(k.aspect)) p.push(`${id}: aspect must be one of ${ASPECTS.join(', ')}`);
  if (k.genSize !== undefined && !['1K', '2K'].includes(k.genSize)) p.push(`${id}: genSize must be "1K" or "2K"`);
  if (!(Number.isInteger(k.maxKB) && k.maxKB >= 4 && k.maxKB <= 1024)) p.push(`${id}: maxKB must be 4 to 1024`);
  if (!['ui', '3d'].includes(k.use)) p.push(`${id}: use must be "ui" (Lossless) or "3d" (VRAM Compressed)`);
  if (k.tile !== undefined && typeof k.tile !== 'boolean') p.push(`${id}: tile must be true or false`);
  if (!(Array.isArray(k.style) && k.style.length >= 1 && k.style.length <= 2)) p.push(`${id}: style must list 1 or 2 existing pictures`);
  else for (const s of k.style) if (typeof s !== 'string' || !s.startsWith(`${k.dir}/`) || !/\.(webp|png)$/.test(s) || !exists(s)) p.push(`${id}: style ${s} must be an existing picture in ${k.dir}`);
  if (typeof k.recipe !== 'string' || k.recipe.length < 20 || k.recipe.length > 600) p.push(`${id}: recipe must be 20 to 600 characters`);
  return p;
}

export function loadKinds(root = ROOT) {
  const kinds = JSON.parse(readFileSync(join(root, KINDS_FILE), 'utf8'));
  const problems = Object.entries(kinds).flatMap(([id, k]) => kindProblems(id, k, (rel) => existsSync(join(root, rel))));
  if (problems.length) throw new Error(`${KINDS_FILE}: ${problems.join('; ')}`);
  return kinds;
}

/**
 * The box inside a light frame: walks in from each side while the row or column is bright on average (Gemini sometimes paints a paper or
 * white border around an icon). Returns {left, top, width, height}, the whole image when there is no frame.
 */
export function frameBox(grey, w, h) {
  const rowMean = (y) => { let s = 0; for (let x = 0; x < w; x++) s += grey[y * w + x]; return s / w; };
  const colMean = (x) => { let s = 0; for (let y = 0; y < h; y++) s += grey[y * w + x]; return s / h; };
  const maxY = Math.floor(h * FRAME_MAX), maxX = Math.floor(w * FRAME_MAX);
  let top = 0, bottom = 0, left = 0, right = 0;
  while (top < maxY && rowMean(top) >= FRAME_LUMA) top++;
  while (bottom < maxY && rowMean(h - 1 - bottom) >= FRAME_LUMA) bottom++;
  while (left < maxX && colMean(left) >= FRAME_LUMA) left++;
  while (right < maxX && colMean(w - 1 - right) >= FRAME_LUMA) right++;
  if (top + bottom + left + right === 0) return { left: 0, top: 0, width: w, height: h };
  // a frame's inner edge is soft: cut a little further so no light seam is left
  const pad = Math.round(Math.min(w, h) * 0.01);
  const L = left ? left + pad : 0, T = top ? top + pad : 0, R = right ? right + pad : 0, B = bottom ? bottom + pad : 0;
  return { left: L, top: T, width: w - L - R, height: h - T - B };
}

/**
 * Makes a raw RGB(A) image tile without seams: a blend of the picture and three copies shifted by half its width, half its height and both.
 * Near a left/right border the x-shifted copies take over (they run on across that border), near top/bottom the y-shifted ones; each copy's
 * own seam lies on a centre line where its weight is zero, so no seam is left anywhere (a plain two-way blend left one in the middle of each edge).
 */
export function seamless(data, w, h, c, feather = 0.22) {
  const res = Buffer.alloc(data.length);
  const edge = (t) => { const d = Math.min(t, 1 - t) / feather; if (d >= 1) return 0; const s = 1 - d; return s * s * (3 - 2 * s); };
  const hx = w >> 1, hy = h >> 1;
  for (let y = 0; y < h; y++) {
    const ay = edge(y / (h - 1)), sy = (y + hy) % h;
    for (let x = 0; x < w; x++) {
      const ax = edge(x / (w - 1)), sx = (x + hx) % w;
      const wO = (1 - ax) * (1 - ay), wX = ax * (1 - ay), wY = (1 - ax) * ay, wXY = ax * ay;
      const o = (y * w + x) * c, X = (y * w + sx) * c, Y = (sy * w + x) * c, XY = (sy * w + sx) * c;
      for (let k = 0; k < c; k++) res[o + k] = Math.round(data[o + k] * wO + data[X + k] * wX + data[Y + k] * wY + data[XY + k] * wXY);
    }
  }
  return res;
}

/** The .import Godot reads for a new picture: the [params] of a sibling of the same use when there is one, else the game's defaults. */
export function importStub(use, siblingImport) {
  const params = siblingImport && /\n\[params\]\n([\s\S]*)$/.exec(siblingImport);
  const body = params ? params[1].trimEnd() : [
    `compress/mode=${use === '3d' ? 2 : 0}`, `compress/high_quality=${use === '3d'}`, 'compress/lossy_quality=0.7', 'compress/hdr_compression=1',
    'compress/normal_map=0', 'compress/channel_pack=0', `mipmaps/generate=${use === '3d'}`, 'mipmaps/limit=-1', 'roughness/mode=0',
    'process/fix_alpha_border=true', 'process/premult_alpha=false', 'process/size_limit=0', 'detect_3d/compress_to=1'].join('\n');
  return `[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n[params]\n\n${body.replace(/^\n+/, '')}\n`;
}

function insideRoot(root, rel) {
  const abs = resolve(root, rel);
  if (abs !== root && !abs.startsWith(root + sep)) throw new Error(`${rel} is outside the checkout`);
  let cur = root;
  for (const part of relative(root, abs).split(sep)) {
    cur = join(cur, part);
    try { if (lstatSync(cur).isSymbolicLink()) throw new Error(`${rel} goes through a symlink`); } catch (e) { if (e.code !== 'ENOENT') throw e; }
  }
  return abs;
}

/** Builds one picture. Returns { out, width, height, bytes, quality, frame, replaced, importWritten }. */
export async function build({ root = ROOT, kindId, name, source, replace = false, now = () => new Date() }) {
  const kinds = loadKinds(root);
  const kind = kinds[kindId];
  if (!kind) throw new Error(`no picture kind "${kindId}" (kinds: ${Object.keys(kinds).join(', ')})`);
  if (!NAME_RE.test(String(name))) throw new Error(`name "${name}" must match ${NAME_RE} (no extension)`);
  const srcRel = CONCEPT_RE.test(source) && !source.includes('.') ? `art-src/concepts/${source}.png` : source;
  const srcAbs = insideRoot(root, srcRel);
  if (!existsSync(srcAbs)) throw new Error(`${srcRel} does not exist${srcRel.startsWith('art-src/concepts/') ? ' (concepts come from the concept request)' : ''}`);
  const outRel = `${kind.dir}/${name}.webp`;
  const outAbs = insideRoot(root, outRel);
  const replaced = existsSync(outAbs);
  if (replaced && !replace) throw new Error(`${outRel} already exists; pass --replace to change it`);

  const srcBuf = readFileSync(srcAbs);
  const [W, H] = kind.size;
  let img = sharp(srcBuf).removeAlpha();
  const meta = await img.metadata();
  let frame = null;
  if (!kind.tile) {
    const { data, info } = await sharp(srcBuf).removeAlpha().greyscale().raw().toBuffer({ resolveWithObject: true });
    const box = frameBox(data, info.width, info.height);
    if (box.width !== info.width || box.height !== info.height) { frame = box; img = sharp(srcBuf).removeAlpha().extract(box); }
  }
  const px = await img.resize(W, H, { fit: 'cover' }).raw().toBuffer({ resolveWithObject: true });
  const raw = { width: px.info.width, height: px.info.height, channels: px.info.channels };   // not the whole info: its premultiplied flag would recolour the picture
  const data = kind.tile ? seamless(px.data, raw.width, raw.height, raw.channels) : px.data;
  let out = null, quality = null;
  for (const q of QUALITIES) {
    const b = await sharp(data, { raw }).webp({ quality: q, effort: 6 }).toBuffer();
    if (b.length <= kind.maxKB * 1024) { out = b; quality = q; break; }
  }
  if (!out) throw new Error(`${outRel} does not fit the ${kind.maxKB} KB limit of ${kindId} even at quality ${QUALITIES.at(-1)}; ask for a simpler picture`);
  writeFileSync(outAbs, out);

  let importWritten = false;
  if (!existsSync(`${outAbs}.import`)) {
    const sib = readdirSync(join(root, kind.dir)).filter((f) => f.endsWith('.webp.import')).sort()[0];
    const sibText = sib ? readFileSync(join(root, kind.dir, sib), 'utf8') : null;
    writeFileSync(`${outAbs}.import`, importStub(kind.use, sibText && sibText.includes('importer="texture"') ? sibText : null));
    importWritten = true;
  }

  const manifestAbs = insideRoot(root, MANIFEST);
  const manifest = existsSync(manifestAbs) ? JSON.parse(readFileSync(manifestAbs, 'utf8')) : {};
  const conceptId = srcRel.startsWith('art-src/concepts/') ? `concept_${srcRel.slice(17, -4)}` : null;
  const concept = conceptId && manifest[conceptId];
  manifest[`picture_${kindId}_${name}`] = {
    generator: 'picture-build',
    kind: kindId,
    from: srcRel,
    ...(concept ? { concept: conceptId, model: concept.model, prompt: concept.prompt, refs: concept.refs ?? [] } : {}),
    sourceHash: sha256(srcBuf),
    ...(frame ? { frameCut: frame } : {}),
    tile: !!kind.tile,
    out: outRel,
    size: [W, H],
    quality,
    outHash: sha256(out),
    builtAt: now().toISOString(),
  };
  writeFileSync(manifestAbs, JSON.stringify(manifest, null, 2) + '\n');
  return { out: outRel, width: W, height: H, bytes: out.length, quality, frame, source: srcRel, sourceSize: [meta.width, meta.height], replaced, importWritten };
}

async function main() {
  const args = process.argv.slice(2);
  const replace = args.includes('--replace');
  const [kindId, name, source, ...extra] = args.filter((a) => a !== '--replace');
  if (!kindId || !name || !source || extra.length) {
    console.error('usage: node tools/pictures/build.mjs <kind> <name> <concept id | image path> [--replace]');
    try { for (const [id, k] of Object.entries(loadKinds())) console.error(`  ${id.padEnd(14)} ${k.size.join('x')}  ${k.label}`); } catch { /* kinds unreadable */ }
    process.exit(2);
  }
  try {
    const r = await build({ kindId, name, source, replace });
    console.log(`${r.replaced ? 'replaced' : 'built'} ${r.out} (${r.width}x${r.height}, ${(r.bytes / 1024).toFixed(1)} KB, WebP quality ${r.quality}) from ${r.source}` +
      (r.frame ? `; cut a light frame (kept ${r.frame.width}x${r.frame.height} of ${r.sourceSize.join('x')})` : ''));
    if (r.importWritten) console.log(`wrote ${r.out}.import; Godot completes it on its next import (godot --headless --path client --import)`);
  } catch (e) {
    console.error(`build-picture: ${e.message}`);
    process.exit(1);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
