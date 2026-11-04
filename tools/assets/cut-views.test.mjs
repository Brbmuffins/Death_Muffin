// tools/assets/cut-views.mjs: a turnaround sheet cut into square views on black (npm run test:server).
import test from 'node:test';
import assert from 'node:assert';
import { mkdtempSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { cutViews } from './cut-views.mjs';

const GREY = [200, 200, 200];

// A sheet on flat grey: rects [x, y, w, h, [r, g, b]].
async function sheet(file, w, h, rects) {
  const px = Buffer.alloc(w * h * 3);
  for (let i = 0; i < w * h; i++) px.set(GREY, i * 3);
  for (const [x0, y0, rw, rh, col] of rects) {
    for (let y = y0; y < y0 + rh; y++) for (let x = x0; x < x0 + rw; x++) px.set(col, (y * w + x) * 3);
  }
  await sharp(px, { raw: { width: w, height: h, channels: 3 } }).png().toFile(file);
}

async function lit(file) {
  const { data, info } = await sharp(file).raw().toBuffer({ resolveWithObject: true });
  let x0 = info.width;
  let y0 = info.height;
  let x1 = 0;
  let y1 = 0;
  for (let y = 0; y < info.height; y++) {
    for (let x = 0; x < info.width; x++) {
      const i = (y * info.width + x) * info.channels;
      if (data[i] + data[i + 1] + data[i + 2] > 30) {
        x0 = Math.min(x0, x);
        y0 = Math.min(y0, y);
        x1 = Math.max(x1, x + 1);
        y1 = Math.max(y1, y + 1);
      }
    }
  }
  return { size: [info.width, info.height], box: [x0, y0, x1 - x0, y1 - y0], corner: [...data.subarray(0, 3)] };
}

test('figures that share columns are cut apart, each square on black at one scale with one floor', async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'cut-views-'));
  try {
    const src = path.join(dir, 'sheet.png');
    // A: a tall body with a cape reaching right under B's outstretched arm; B: shorter, its arm reaching left over A's cape.
    // A grey plate inside A (the background's own colour, not joined to it) must stay; a loose hand beside B joins B.
    await sheet(src, 400, 200, [
      [20, 20, 60, 160, [90, 40, 120]],
      [80, 120, 50, 60, [60, 30, 80]],
      [40, 60, 20, 20, GREY],
      [180, 60, 60, 120, [120, 90, 60]],
      [110, 70, 70, 10, [120, 90, 60]],
      [250, 100, 6, 6, [120, 90, 60]],
    ]);
    const out = path.join(dir, 'views');
    const views = await cutViews(src, out, { names: ['a', 'b'], size: 220, fill: 1.1 });
    assert.deepStrictEqual(views.map((v) => [v.name, v.box]), [
      ['a', [20, 20, 110, 160]],
      ['b', [110, 60, 146, 120]],
    ]);
    const a = await lit(path.join(out, 'a.png'));
    const b = await lit(path.join(out, 'b.png'));
    assert.deepStrictEqual(a.size, [220, 220]);
    assert.deepStrictEqual(a.corner, [0, 0, 0]);
    // the tallest extent (A, 160) spans 220 / 1.1 = 200 px; B (120 tall) at the same scale is 150, and both stand on the same row
    assert.ok(Math.abs(a.box[3] - 200) <= 1, `A is ${a.box[3]} px tall`);
    assert.ok(Math.abs(b.box[3] - 150) <= 1, `B is ${b.box[3]} px tall`);
    assert.ok(Math.abs(a.box[1] + a.box[3] - (b.box[1] + b.box[3])) <= 1, 'the feet sit on one row');
    // B's own picture holds none of A's cape: its lit width is B with its arm and loose hand (146 at 200/160)
    assert.ok(Math.abs(b.box[2] - 146 * 1.25) <= 2, `B is ${b.box[2]} px wide`);
    // the grey plate inside A stays grey, not black
    const { data, info } = await sharp(path.join(out, 'a.png')).raw().toBuffer({ resolveWithObject: true });
    const cx = Math.round(a.box[0] + (50 - 20) * 1.25);
    const cy = Math.round(a.box[1] + (70 - 20) * 1.25);
    assert.ok(data[(cy * info.width + cx) * info.channels] > 150, 'the plate inside the figure keeps its grey');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a sheet with fewer figures than names is refused', async () => {
  const dir = mkdtempSync(path.join(os.tmpdir(), 'cut-views-'));
  try {
    const src = path.join(dir, 'sheet.png');
    await sheet(src, 200, 100, [[20, 20, 40, 60, [90, 40, 120]]]);
    await assert.rejects(cutViews(src, path.join(dir, 'v'), { names: ['front', 'back'] }), /found 1 figure\(s\) on the sheet, expected 2/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
