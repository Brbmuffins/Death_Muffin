/**
 * cut-views.mjs — a turnaround sheet (concept_<id>_views: the figures in one row on a plain background) cut into one picture a view, as
 * model-gen.sh's several views take them (ASSET_PIPELINE.md "Several views"): square .pngs, the subject on black, every view at the same
 * scale with the feet at the same height, the widest view spanning 1/fill of the frame.
 *
 * Usage:
 *   node tools/assets/cut-views.mjs <sheet.png> <out dir> [--names front,left,back,right] [--size 1024] [--fill 1.1]
 *   writes <out dir>/<name>.png for each figure, left to right, and prints where each was found
 *
 * The background is what joins the sheet's corners (flood fill), so grey inside a figure (a lit iron plate) stays. The figures are the
 * biggest joined patches of subject (findFigures), so a cape reaching under the next figure's hand stays with its own figure.
 */
import sharp from 'sharp';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const BG_TOL = 18; // a background pixel differs from the corners' colour by at most this in every channel
const EDGE_TOL = 48; // a subject pixel next to the background closer than this is an edge, faded to black by its difference

/** The background mask (1 = background) of an RGB image: everything within BG_TOL of the corners' colour that joins a border. */
export function backgroundMask(rgb, w, h) {
  const corner = [0, 1, 2].map((c) => {
    const v = [];
    for (const [x0, y0] of [[0, 0], [w - 8, 0], [0, h - 8], [w - 8, h - 8]]) {
      for (let y = y0; y < y0 + 8; y++) for (let x = x0; x < x0 + 8; x++) v.push(rgb[(y * w + x) * 3 + c]);
    }
    v.sort((a, b) => a - b);
    return v[v.length >> 1];
  });
  const diff = new Uint8Array(w * h);
  for (let i = 0; i < w * h; i++) {
    diff[i] = Math.max(Math.abs(rgb[i * 3] - corner[0]), Math.abs(rgb[i * 3 + 1] - corner[1]), Math.abs(rgb[i * 3 + 2] - corner[2]));
  }
  const bg = new Uint8Array(w * h);
  const stack = new Int32Array(w * h);
  let top = 0;
  const push = (i) => {
    if (!bg[i] && diff[i] <= BG_TOL) {
      bg[i] = 1;
      stack[top++] = i;
    }
  };
  for (let x = 0; x < w; x++) {
    push(x);
    push((h - 1) * w + x);
  }
  for (let y = 0; y < h; y++) {
    push(y * w);
    push(y * w + w - 1);
  }
  while (top) {
    const i = stack[--top];
    const x = i % w;
    if (x > 0) push(i - 1);
    if (x < w - 1) push(i + 1);
    if (i >= w) push(i - w);
    if (i < w * (h - 1)) push(i + w);
  }
  return { bg, diff };
}

/**
 * The figures in a background mask, left to right, `count` of them: every patch of subject joined side to side is a piece; the `count`
 * biggest are the figures and every other piece of some size (a hand or a tatter cut off by background) goes to the figure whose box is
 * nearest. Figures may share columns (a cape under the next one's hand), so each keeps its own pieces. Returns the piece label of each
 * pixel (0 = background or a speck) and per figure its box [x, y, w, h] and the labels it owns.
 */
export function findFigures(bg, w, h, count) {
  const label = new Int32Array(w * h);
  const stack = new Int32Array(w * h);
  const pieces = [null];
  for (let s = 0; s < w * h; s++) {
    if (bg[s] || label[s]) continue;
    const id = pieces.length;
    const p = { id, px: 0, x0: w, y0: h, x1: 0, y1: 0 };
    let top = 0;
    label[s] = id;
    stack[top++] = s;
    while (top) {
      const i = stack[--top];
      const x = i % w;
      const y = (i - x) / w;
      p.px++;
      if (x < p.x0) p.x0 = x;
      if (x >= p.x1) p.x1 = x + 1;
      if (y < p.y0) p.y0 = y;
      if (y >= p.y1) p.y1 = y + 1;
      for (const j of [x > 0 ? i - 1 : -1, x < w - 1 ? i + 1 : -1, i - w, i + w]) {
        if (j >= 0 && j < w * h && !bg[j] && !label[j]) {
          label[j] = id;
          stack[top++] = j;
        }
      }
    }
    pieces.push(p);
  }
  const bySize = pieces.slice(1).sort((a, b) => b.px - a.px);
  if (bySize.length < count) throw new Error(`found ${bySize.length} figure(s) on the sheet, expected ${count}`);
  const figs = bySize.slice(0, count).map((p) => ({ labels: new Set([p.id]), x0: p.x0, y0: p.y0, x1: p.x1, y1: p.y1 }));
  const keep = new Uint8Array(pieces.length);
  for (const f of figs) for (const id of f.labels) keep[id] = 1;
  const gap = (p, f) => Math.max(0, f.x0 - p.x1, p.x0 - f.x1) + Math.max(0, f.y0 - p.y1, p.y0 - f.y1);
  for (const p of bySize.slice(count)) {
    if (p.px < bySize[count - 1].px * 0.0005) continue;
    const f = figs.reduce((a, b) => (gap(p, b) < gap(p, a) ? b : a));
    f.labels.add(p.id);
    keep[p.id] = 1;
    f.x0 = Math.min(f.x0, p.x0);
    f.y0 = Math.min(f.y0, p.y0);
    f.x1 = Math.max(f.x1, p.x1);
    f.y1 = Math.max(f.y1, p.y1);
  }
  for (let i = 0; i < w * h; i++) if (!keep[label[i]]) label[i] = 0;
  figs.sort((a, b) => a.x0 + a.x1 - b.x0 - b.x1);
  return { label, figures: figs.map((f) => ({ box: [f.x0, f.y0, f.x1 - f.x0, f.y1 - f.y0], labels: f.labels })) };
}

/** Cut a sheet into `names.length` square pictures on black; returns [{ name, file, box: [x, y, w, h] }]. */
export async function cutViews(sheet, outDir, { names = ['front', 'left', 'back', 'right'], size = 1024, fill = 1.1 } = {}) {
  const { data, info } = await sharp(sheet).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const { width: w, height: h } = info;
  const { bg, diff } = backgroundMask(data, w, h);
  const { label, figures } = findFigures(bg, w, h, names.length);
  const boxes = figures.map((f) => f.box);
  // one scale and one floor for all: the biggest extent fills 1/fill of the frame, the sheet's lowest foot sits at the same row in each
  const top = Math.min(...boxes.map((b) => b[1]));
  const bottom = Math.max(...boxes.map((b) => b[1] + b[3]));
  const scale = size / fill / Math.max(bottom - top, ...boxes.map((b) => b[2]));
  const floor = Math.round((size + (bottom - top) * scale) / 2);
  // the subject on black, the edge fringe faded by how far it is from the background colour
  const shade = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) {
    if (!label[i]) continue;
    const x = i % w;
    const nearBg = (x > 0 && bg[i - 1]) || (x < w - 1 && bg[i + 1]) || (i >= w && bg[i - w]) || (i < w * (h - 1) && bg[i + w]);
    shade[i] = nearBg ? Math.min(1, diff[i] / EDGE_TOL) : 1;
  }
  mkdirSync(outDir, { recursive: true });
  const result = [];
  for (const [k, [x, y, bw, bh]] of boxes.entries()) {
    const rw = Math.max(1, Math.round(bw * scale));
    const rh = Math.max(1, Math.round(bh * scale));
    const own = figures[k].labels;
    const cut = Buffer.alloc(bw * bh * 3);
    for (let yy = 0; yy < bh; yy++) {
      for (let xx = 0; xx < bw; xx++) {
        const i = (y + yy) * w + x + xx;
        if (!own.has(label[i])) continue;
        for (let c = 0; c < 3; c++) cut[(yy * bw + xx) * 3 + c] = Math.round(data[i * 3 + c] * shade[i]);
      }
    }
    const part = await sharp(cut, { raw: { width: bw, height: bh, channels: 3 } })
      .resize(rw, rh, { kernel: 'lanczos3' })
      .png()
      .toBuffer();
    const file = join(outDir, `${names[k]}.png`);
    await sharp({ create: { width: size, height: size, channels: 3, background: '#000000' } })
      .composite([{ input: part, left: Math.round((size - rw) / 2), top: floor - Math.round((bottom - y) * scale) }])
      .png()
      .toFile(file);
    result.push({ name: names[k], file, box: [x, y, bw, bh] });
  }
  return result;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const args = process.argv.slice(2);
  const opt = (n, d) => (args.includes(n) ? args.splice(args.indexOf(n), 2)[1] : d);
  const names = opt('--names', 'front,left,back,right').split(',');
  const size = Number(opt('--size', 1024));
  const fill = Number(opt('--fill', 1.1));
  if (args.length !== 2) {
    console.error('usage: node tools/assets/cut-views.mjs <sheet.png> <out dir> [--names front,left,back,right] [--size 1024] [--fill 1.1]');
    process.exit(2);
  }
  for (const r of await cutViews(args[0], args[1], { names, size, fill })) console.log(`${r.name}: ${r.file} (sheet box ${r.box.join(' ')})`);
}
