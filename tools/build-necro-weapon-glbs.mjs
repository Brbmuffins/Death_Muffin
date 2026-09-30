/**
 * build-necro-weapon-glbs.mjs: raw Tripo output (art-src/necro-weapons/tripo/prop_gear_necro_<kind>/model.glb, gitignored)
 * -> public/models/props/gear_<kind>.glb, posed for hand props: +Y long axis, the grip axis on the origin (grip height
 * from NECRO_MODEL), uniform scale to the model's world length, optional yaw about Y so a blade sweeps forward. Geometry is
 * baked (no node transforms), then deduped, WebP-compressed, quantized and pruned like every other shipped prop.
 *   node tools/build-necro-weapon-glbs.mjs [kind ...]   (default: all seven)
 *   node tools/build-necro-weapon-glbs.mjs --inspect     (print each raw model's bounds and where its mass sits)
 * Tier colour is NOT baked: the runtime tints one mesh five ways (graphics/gearProps.ts).
 */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { dedup, prune, quantize, textureCompress } from '@gltf-transform/functions';
import { build } from 'esbuild';
import sharp from 'sharp';
import { existsSync, mkdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const RAW = join(root, 'art-src', 'necro-weapons', 'tripo');
const OUT = join(root, 'public', 'models', 'props');
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);

const res = await build({ entryPoints: [join(root, 'src/content/necroWeapons.ts')], bundle: true, platform: 'node', format: 'esm', write: false });
const { NECRO_MODEL } = await import('data:text/javascript;base64,' + Buffer.from(res.outputFiles[0].text).toString('base64'));

function positions(doc) {
  const out = [];
  for (const mesh of doc.getRoot().listMeshes()) for (const prim of mesh.listPrimitives()) {
    const acc = prim.getAttribute('POSITION');
    if (acc && !out.includes(acc)) out.push(acc);
  }
  return out;
}

function collect(doc) {
  const pts = [];
  for (const acc of positions(doc)) {
    const a = acc.getArray();
    for (let i = 0; i < a.length; i += 3) pts.push([a[i], a[i + 1], a[i + 2]]);
  }
  return pts;
}

const bandMean = (pts, lo, hi) => {
  const sel = pts.filter((p) => p[1] >= lo && p[1] <= hi);
  const n = sel.length || 1;
  return [sel.reduce((s, p) => s + p[0], 0) / n, sel.reduce((s, p) => s + p[2], 0) / n, sel.length];
};

async function bake(kind, inspect) {
  const src = join(RAW, `prop_gear_necro_${kind}`, 'model.glb');
  if (!existsSync(src)) throw new Error(`missing ${src}`);
  const doc = await io.read(src);
  for (const n of doc.getRoot().listNodes()) {
    const t = n.getTranslation(), r = n.getRotation(), s = n.getScale();
    if (t.some((v) => v !== 0) || r[3] !== 1 || s.some((v) => v !== 1)) throw new Error(`${kind}: node "${n.getName()}" has a transform; flatten it first`);
  }
  const pts = collect(doc);
  const ys = pts.map((p) => p[1]);
  const y0 = Math.min(...ys), y1 = Math.max(...ys);
  const h = y1 - y0;
  const cfg = NECRO_MODEL[kind];
  if (inspect) {
    const xs = pts.map((p) => p[0]), zs = pts.map((p) => p[2]);
    const bot = bandMean(pts, y0, y0 + h * 0.12), top = bandMean(pts, y1 - h * 0.12, y1), upper = bandMean(pts, y0 + h * 0.7, y1);
    console.log(`${kind}: y ${y0.toFixed(2)}..${y1.toFixed(2)} x ${Math.min(...xs).toFixed(2)}..${Math.max(...xs).toFixed(2)} z ${Math.min(...zs).toFixed(2)}..${Math.max(...zs).toFixed(2)} verts ${pts.length}`);
    console.log(`   bottom axis (${bot[0].toFixed(2)}, ${bot[1].toFixed(2)}) top axis (${top[0].toFixed(2)}, ${top[1].toFixed(2)}) upper mass (${upper[0].toFixed(2)}, ${upper[1].toFixed(2)})`);
    return;
  }
  const axis = cfg.anchor === 'bottom' ? bandMean(pts, y0, y0 + h * 0.12)
    : cfg.anchor === 'top' ? bandMean(pts, y1 - h * 0.12, y1)
      : [(Math.min(...pts.map((p) => p[0])) + Math.max(...pts.map((p) => p[0]))) / 2, (Math.min(...pts.map((p) => p[2])) + Math.max(...pts.map((p) => p[2]))) / 2];
  const yaw = (cfg.yaw * Math.PI) / 180, c = Math.cos(yaw), s = Math.sin(yaw);
  const k = cfg.length / h;
  const dy = -y0 * k - cfg.grip * cfg.length;
  const rot = (x, z) => [x * c + z * s, -x * s + z * c];
  for (const acc of positions(doc)) {
    const a = acc.getArray();
    for (let i = 0; i < a.length; i += 3) {
      const [rx, rz] = rot(a[i] - axis[0], a[i + 2] - axis[1]);
      a[i] = rx * k; a[i + 1] = a[i + 1] * k + dy; a[i + 2] = rz * k;
    }
    acc.setArray(a);
  }
  for (const mesh of doc.getRoot().listMeshes()) for (const prim of mesh.listPrimitives()) {
    const nrm = prim.getAttribute('NORMAL');
    if (nrm) {
      const a = nrm.getArray();
      for (let i = 0; i < a.length; i += 3) { const [rx, rz] = rot(a[i], a[i + 2]); a[i] = rx; a[i + 2] = rz; }
      nrm.setArray(a);
    }
    const tan = prim.getAttribute('TANGENT');
    if (tan) {
      const a = tan.getArray();
      for (let i = 0; i < a.length; i += 4) { const [rx, rz] = rot(a[i], a[i + 2]); a[i] = rx; a[i + 2] = rz; }
      tan.setArray(a);
    }
  }
  await doc.transform(
    dedup(),
    textureCompress({ encoder: sharp, targetFormat: 'webp', resize: [512, 512], quality: 86 }),
    quantize({ quantizeNormal: 10, quantizeTexcoord: 12, quantizePosition: 14 }),
    prune(),
  );
  mkdirSync(OUT, { recursive: true });
  const out = join(OUT, `gear_${kind}.glb`);
  await io.write(out, doc);
  const tris = doc.getRoot().listMeshes().flatMap((m) => m.listPrimitives()).reduce((n, p) => n + (p.getIndices()?.getCount() ?? 0) / 3, 0);
  console.log(`${kind}: ${(statSync(out).size / 1e6).toFixed(2)}MB, ${tris} tris, length ${cfg.length} m, grip ${cfg.grip}, yaw ${cfg.yaw}`);
}

const args = process.argv.slice(2);
const inspect = args.includes('--inspect');
const kinds = args.filter((a) => !a.startsWith('--'));
for (const kind of kinds.length ? kinds : Object.keys(NECRO_MODEL)) await bake(kind, inspect);
