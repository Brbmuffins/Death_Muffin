// The game's flat pictures: the kinds list, the builder (tools/pictures/build.mjs) and that every ability has its own icon.
//   node --test tools/pictures/      (CI: "Pictures")
import { test } from 'node:test';
import assert from 'node:assert/strict';
import sharp from 'sharp';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { ROOT, aspectOf, build, frameBox, importStub, kindProblems, loadKinds, seamless } from './build.mjs';

const json = (rel) => JSON.parse(readFileSync(join(ROOT, rel), 'utf8'));

test('the kinds list is valid: every folder and style picture exists, and each style picture has the size of its kind', async () => {
  const kinds = loadKinds();
  assert.ok(Object.keys(kinds).length > 0);
  for (const [id, k] of Object.entries(kinds)) {
    for (const s of k.style) {
      const m = await sharp(join(ROOT, s)).metadata();
      assert.deepEqual([m.width, m.height], k.size, `${id}: style ${s} is ${m.width}x${m.height}, the kind makes ${k.size.join('x')}`);
    }
    assert.ok(['1:1', '3:4', '16:9'].includes(aspectOf(k)), `${id}: aspect ${aspectOf(k)}`);
  }
});

test('a kind entry with a problem is refused', () => {
  const good = { label: 'x icon', dir: 'client/assets/ui_art/art/abilities', size: [256, 256], maxKB: 48, use: 'ui', style: ['client/assets/ui_art/art/abilities/a.webp'], recipe: 'Dark fantasy icon, square, painterly.' };
  assert.deepEqual(kindProblems('x_icon', good), []);
  assert.match(kindProblems('x_icon', { ...good, colour: 'red' }).join(), /field "colour" is not known/);
  assert.match(kindProblems('x_icon', { ...good, dir: '/etc' }).join(), /dir must be a folder under client\/assets/);
  assert.match(kindProblems('x_icon', { ...good, use: 'gpu' }).join(), /use must be/);
  assert.match(kindProblems('x_icon', { ...good, style: ['client/assets/other/a.webp'] }).join(), /must be an existing picture in/);
  assert.match(kindProblems('x_icon', good, () => false).join(), /does not exist/);
});

test('frameBox cuts a light frame the image model drew, and leaves a picture without one whole', () => {
  const w = 100, h = 100, g = Buffer.alloc(w * h, 20);
  assert.deepEqual(frameBox(g, w, h), { left: 0, top: 0, width: 100, height: 100 });
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) if (x < 6 || y < 6 || x >= 94 || y >= 94) g[y * w + x] = 235;
  const box = frameBox(g, w, h);
  assert.ok(box.left >= 6 && box.top >= 6 && box.left + box.width <= 94 && box.top + box.height <= 94, JSON.stringify(box));
  // a bright subject touching one edge is not a frame unless the whole row is bright
  const s = Buffer.alloc(w * h, 20); for (let x = 30; x < 70; x++) s[x] = 250;
  assert.deepEqual(frameBox(s, w, h), { left: 0, top: 0, width: 100, height: 100 });
});

test('seamless makes the picture continue across its own edges, with no seam left inside it', () => {
  const w = 64, h = 64, c = 3, d = Buffer.alloc(w * h * c);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { const i = (y * w + x) * c; d[i] = x * 4; d[i + 1] = y * 4; d[i + 2] = 50; }
  const px = (b, x, y, k) => b[(((y + h) % h) * w + ((x + w) % w)) * c + k];
  // the biggest jump between neighbouring pixels anywhere, the tile's wrap-around included (red runs along x, green along y)
  const worst = (b) => { let m = 0; for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) m = Math.max(m, Math.abs(px(b, x + 1, y, 0) - px(b, x, y, 0)), Math.abs(px(b, x, y + 1, 1) - px(b, x, y, 1))); return m; };
  assert.ok(worst(d) > 200, 'the test picture has a seam to start with');
  assert.ok(worst(seamless(d, w, h, c)) < 40, `the biggest step is ${worst(seamless(d, w, h, c))}`);
});

test('a new picture gets an .import: Lossless for UI art, VRAM Compressed with mipmaps for 3D, else a sibling\'s settings', () => {
  assert.match(importStub('ui'), /compress\/mode=0[\s\S]*mipmaps\/generate=false/);
  assert.match(importStub('3d'), /compress\/mode=2[\s\S]*mipmaps\/generate=true/);
  const sib = '[remap]\n\nimporter="texture"\nuid="uid://x"\n\n[deps]\n\nsource_file="res://a.webp"\n\n[params]\n\ncompress/mode=0\nprocess/size_limit=0\n';
  const t = importStub('ui', sib);
  assert.match(t, /^\[remap\]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n\[params\]\n\ncompress\/mode=0\nprocess\/size_limit=0\n$/);
  assert.doesNotMatch(t, /uid|source_file/, 'the sibling\'s own uid and source never carry over');
});

// A throwaway checkout holding one kind, its folder and a concept with its record.
async function scratch({ maxKB = 48, tile = false } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'dm-pictures-'));
  const dir = 'client/assets/ui_art/art/abilities';
  mkdirSync(join(root, dir), { recursive: true }); mkdirSync(join(root, 'tools/pictures'), { recursive: true });
  mkdirSync(join(root, 'art-src/concepts'), { recursive: true }); mkdirSync(join(root, 'art-manifest'), { recursive: true });
  await sharp({ create: { width: 256, height: 256, channels: 3, background: '#111' } }).webp().toFile(join(root, dir, 'old.webp'));
  writeFileSync(join(root, 'tools/pictures/kinds.json'), JSON.stringify({ ability_icon: { label: 'Ability icon', dir, size: [256, 256], maxKB, use: 'ui', ...(tile ? { tile } : {}), style: [`${dir}/old.webp`], recipe: 'Dark fantasy ARPG ability icon, square.' } }));
  const noise = Buffer.alloc(1024 * 1024 * 3); let x = 2463534242; for (let i = 0; i < noise.length; i++) { x ^= x << 13; x ^= x >>> 17; x ^= x << 5; noise[i] = x & 255; }   // xorshift: noise that never compresses well
  await sharp({ create: { width: 1024, height: 1024, channels: 3, background: '#efe9dc' } })
    .composite([{ input: await sharp(noise, { raw: { width: 1024, height: 1024, channels: 3 } }).resize(900, 900).png().toBuffer(), left: 62, top: 62 }])
    .png().toFile(join(root, 'art-src/concepts/icon_test.png'));
  writeFileSync(join(root, 'art-manifest/images.json'), JSON.stringify({ concept_icon_test: { generator: 'gemini', model: 'gemini-3.1-flash-image', prompt: 'a test scythe', refs: [] } }));
  return { root, dir, done: () => rmSync(root, { recursive: true, force: true }) };
}

test('build: a concept becomes a picture at the kind\'s size, with its .import and record; an existing one is changed only with --replace', async () => {
  const s = await scratch({ maxKB: 200 });
  try {
    const r = await build({ root: s.root, kindId: 'ability_icon', name: 'reaper-test', source: 'icon_test', now: () => new Date('2026-10-20T00:00:00Z') });
    const out = join(s.root, s.dir, 'reaper-test.webp');
    const m = await sharp(out).metadata();
    assert.deepEqual([m.width, m.height, m.format], [256, 256, 'webp']);
    assert.ok(r.frame && r.frame.left >= 62, 'the light frame was cut');
    assert.ok(existsSync(`${out}.import`) && r.importWritten);
    const rec = JSON.parse(readFileSync(join(s.root, 'art-manifest/images.json'), 'utf8'))['picture_ability_icon_reaper-test'];
    assert.equal(rec.from, 'art-src/concepts/icon_test.png'); assert.equal(rec.concept, 'concept_icon_test'); assert.equal(rec.prompt, 'a test scythe');
    assert.equal(rec.out, `${s.dir}/reaper-test.webp`); assert.match(rec.outHash, /^sha256:[0-9a-f]{64}$/);
    await assert.rejects(build({ root: s.root, kindId: 'ability_icon', name: 'reaper-test', source: 'icon_test' }), /already exists; pass --replace/);
    const again = await build({ root: s.root, kindId: 'ability_icon', name: 'reaper-test', source: 'icon_test', replace: true });
    assert.ok(again.replaced && !again.importWritten, 'a replaced picture keeps its .import');
  } finally { s.done(); }
});

test('build refuses an unknown kind, a bad name, a missing concept and a picture over its size limit', async () => {
  const s = await scratch({ maxKB: 4 });
  try {
    await assert.rejects(build({ root: s.root, kindId: 'nope', name: 'x-y', source: 'icon_test' }), /no picture kind "nope"/);
    await assert.rejects(build({ root: s.root, kindId: 'ability_icon', name: '../x', source: 'icon_test' }), /must match/);
    await assert.rejects(build({ root: s.root, kindId: 'ability_icon', name: 'x-y', source: 'icon_none' }), /does not exist/);
    await assert.rejects(build({ root: s.root, kindId: 'ability_icon', name: 'x-y', source: 'icon_test' }), /does not fit the 4 KB limit/);
    assert.ok(!existsSync(join(s.root, s.dir, 'x-y.webp')), 'nothing is written when it does not fit');
  } finally { s.done(); }
});

// Abilities whose icon is still another ability's. Remove a line when its own icon lands; the test fails while a listed one no longer
// borrows, so the list only shrinks. Nothing may join it: a new ability gets its own icon (tools/pictures, ASSET_PIPELINE.md "Pictures").
const STILL_BORROWING = ['scythe_sweep', 'scythe_throw', 'reap', 'wraith_walk', 'haunting_wraith', 'soul_burst', 'unleash_souls', 'soul_harvest', 'harvest_spin', 'scythe_weave'];

test('every ability has its own icon, and both copies of the ability data name the same one', () => {
  const combat = json('client/data/combat/abilities.json').abilities;
  const content = json('client/data/content/abilities.json').ABILITIES;
  const byIcon = new Map();
  for (const [id, a] of Object.entries(combat)) {
    assert.ok(existsSync(join(ROOT, 'client/assets/ui_art', a.icon)), `${id}: icon ${a.icon} is not in client/assets/ui_art/`);
    if (content[id]) assert.equal(content[id].icon, a.icon, `${id}: client/data/content/abilities.json names another icon`);
    byIcon.set(a.icon, [...(byIcon.get(a.icon) || []), id]);
  }
  const shared = [...byIcon.values()].filter((ids) => ids.length > 1);
  for (const ids of shared) {
    const borrowers = ids.filter((id) => !STILL_BORROWING.includes(id));
    assert.ok(borrowers.length <= 1, `${ids.join(', ')} share one icon: give each its own`);
  }
  for (const id of STILL_BORROWING) {
    assert.ok(combat[id], `${id} is listed as borrowing but is not an ability`);
    assert.ok(shared.some((ids) => ids.includes(id)), `${id} has its own icon now: remove it from STILL_BORROWING`);
  }
});
