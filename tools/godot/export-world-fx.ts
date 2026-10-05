/**
 * Death Muffin -> Godot data export for the world-dressing track (godot/world_fx/).
 * Imports the REAL layout and reads the module-private tables straight out of the TS source text, so nothing is retyped:
 * windows, far silhouettes (as resolved primitives, same rand order as WorldView.silhouetteGeometry), candle flames
 * (WorldView.buildFlameData), the mist field (buildMist), the per-area Atmosphere profiles, the standing water (Water.ts inputs),
 * the bloom numbers, the flying pack's wing table and the occlusion/hover constants.
 * Run: npx vite-node tools/godot/export-world-fx.ts   ->   godot/data/world_fx/fx.json
 */
import { mkdirSync, writeFileSync, readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import * as THREE from 'three';
import { AREAS, AREA_ORDER } from '../../src/content/areas';
import { generateLayout, PROPS } from '../../src/content/layout';
import { mulberry32 } from '../../src/gameplay/rng';
import { updateOcclusion, occlusionUniforms } from '../../src/graphics/occlusion';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = resolve(ROOT, 'godot/data/world_fx');
mkdirSync(OUT, { recursive: true });
const src = (rel: string) => readFileSync(resolve(ROOT, rel), 'utf8');
function mirrorCheck(file: string, snippets: string[]) {
  const text = src(file);
  const bad = snippets.filter((s) => !text.includes(s));
  if (bad.length) throw new Error(`mirror drift in ${file}: ${bad.join(' | ')}`);
}

const layout = generateLayout();

// ---- silhouettes: the recorder mirrors WorldView.silhouetteGeometry call-for-call (same rand order); the source text is checked.
mirrorCheck('src/graphics/WorldView.ts', [
  'box(4.2, 18, 4.2);',
  'box(3.4, 5, 3.4, 0, 18);',
  'new THREE.ConeGeometry(2.6, 13, 4).rotateY(Math.PI / 4).translate(0, 29.5, 0)',
  'box(3, 9 + rand() * 5, 3, 5.6, 0, 1.2);',
  'box(0.9, 9, 0.9, -3.4, 2, 0, -0.5);',
  'box(8, 1.1, 2.6, -2, 0, 0);',
  'cyl(0.12, 0.42, 5.2, 0, 0, 0, 0, (rand() - 0.5) * 0.15);',
  'cyl(0.03, 0.12, 1.6 + rand() * 1.6, Math.cos(a) * 0.1, y, Math.sin(a) * 0.1, Math.sin(a) * 0.9, Math.cos(a) * 0.9);',
  'box(w, 1 + rand() * 4, 0.9, x + w / 2);',
  'box(1.4, 0.7, 1.2, 1 + rand() * 3, 0, 1.4 + rand());',
  'merged.scale(sil.scale, sil.scale, sil.scale).rotateY(sil.rot).translate(sil.x, -0.1, sil.z);',
  'const rand = mulberry32(4242);',
  'new THREE.CylinderGeometry(rt, rb, h, 5)',
]);
type Prim = { t: 'box' | 'cyl' | 'cone'; a: number[]; x: number; y: number; z: number; rx: number; rz: number };
function silPrims(kind: string, rand: () => number): Prim[] {
  const out: Prim[] = [];
  const box = (w: number, h: number, d: number, x = 0, y = 0, z = 0, rz = 0) => out.push({ t: 'box', a: [w, h, d], x, y, z, rx: 0, rz });
  const cyl = (rt: number, rb: number, h: number, x: number, y: number, z: number, rx: number, rz: number) => out.push({ t: 'cyl', a: [rt, rb, h], x, y, z, rx, rz });
  if (kind === 'spire') {
    box(4.2, 18, 4.2);
    box(3.4, 5, 3.4, 0, 18);
    out.push({ t: 'cone', a: [2.6, 13], x: 0, y: 29.5, z: 0, rx: 0, rz: 0 });
    box(3, 9 + rand() * 5, 3, 5.6, 0, 1.2);
    box(0.9, 9, 0.9, -3.4, 2, 0, -0.5);
    box(8, 1.1, 2.6, -2, 0, 0);
  } else if (kind === 'tree') {
    cyl(0.12, 0.42, 5.2, 0, 0, 0, 0, (rand() - 0.5) * 0.15);
    for (let i = 0; i < 4; i++) {
      const a = rand() * Math.PI * 2;
      const y = 2.2 + rand() * 2.6;
      cyl(0.03, 0.12, 1.6 + rand() * 1.6, Math.cos(a) * 0.1, y, Math.sin(a) * 0.1, Math.sin(a) * 0.9, Math.cos(a) * 0.9);
    }
  } else {
    let x = -3;
    while (x < 3) {
      const w = 0.8 + rand() * 1.4;
      box(w, 1 + rand() * 4, 0.9, x + w / 2);
      x += w;
    }
    box(1.4, 0.7, 1.2, 1 + rand() * 3, 0, 1.4 + rand());
  }
  return out;
}
/** The real three geometry of one silhouette (golden: triangle count + bounds for the Godot builder's test). */
function realGeo(sil: { kind: string; x: number; z: number; scale: number; rot: number }, prims: Prim[]) {
  const g: THREE.BufferGeometry[] = [];
  for (const p of prims) {
    if (p.t === 'box') g.push(new THREE.BoxGeometry(p.a[0], p.a[1], p.a[2]).translate(0, p.a[1] / 2, 0).rotateZ(p.rz).translate(p.x, p.y, p.z));
    else if (p.t === 'cyl') g.push(new THREE.CylinderGeometry(p.a[0], p.a[1], p.a[2], 5).translate(0, p.a[2] / 2, 0).rotateX(p.rx).rotateZ(p.rz).translate(p.x, p.y, p.z));
    else g.push(new THREE.ConeGeometry(2.6, 13, 4).rotateY(Math.PI / 4).translate(0, 29.5, 0));
  }
  let tris = 0;
  const box = new THREE.Box3();
  for (const x of g) {
    // zero-area triangles (a cone's collapsed apex row) draw nothing: the Godot builder skips them, so the golden does too.
    const ng = x.index ? x.toNonIndexed() : x;
    const pa = ng.attributes.position;
    for (let i = 0; i < pa.count; i += 3) {
      const a = new THREE.Vector3().fromBufferAttribute(pa, i);
      const b = new THREE.Vector3().fromBufferAttribute(pa, i + 1);
      const c = new THREE.Vector3().fromBufferAttribute(pa, i + 2);
      if (b.sub(a).cross(c.sub(a)).lengthSq() > 1e-12) tris++;
    }
    x.scale(sil.scale, sil.scale, sil.scale).rotateY(sil.rot).translate(sil.x, -0.1, sil.z);
    x.computeBoundingBox();
    box.union(x.boundingBox!);
  }
  return { tris, min: box.min.toArray(), max: box.max.toArray() };
}
const silRand = mulberry32(4242);
const silhouettes = layout.silhouettes.map((s) => {
  const prims = silPrims(s.kind, silRand);
  return { kind: s.kind, x: s.x, z: s.z, scale: s.scale, rot: s.rot, prims, golden: realGeo(s, prims) };
});

// ---- candle flames (WorldView.buildFlameData), grouped per area.
mirrorCheck('src/graphics/WorldView.ts', [
  'const rand = mulberry32(99);',
  'd.pos.push(p.x + Math.cos(a) * r, (0.35 + rand() * 0.45) * p.scale + 0.12, p.z + Math.sin(a) * r);',
  'const r = rand() * spec.spread * p.scale;',
  'gl_PointSize = 0.24 * f * aLit * uScale / max(0.1, -mv.z);',
  'float f = 0.82 + 0.18 * sin(uTime * 13.0 + aPhase * 7.0) * sin(uTime * 7.3 + aPhase * 3.0);',
  'p.y += 0.02 * sin(uTime * 9.0 + aPhase);',
  'gl_FragColor = vec4(c * 1.35, t.a * vA);',
]);
const flames: Record<string, { pos: number[]; phase: number[]; groups: (string | null)[] }> = {};
{
  const rand = mulberry32(99);
  for (const p of layout.props) {
    const spec = PROPS[p.prop].light;
    if (!spec || !spec.flames) continue;
    const d = (flames[p.area] ??= { pos: [], phase: [], groups: [] });
    for (let i = 0; i < spec.flames; i++) {
      const a = rand() * Math.PI * 2;
      const r = rand() * spec.spread * p.scale;
      d.pos.push(p.x + Math.cos(a) * r, (0.35 + rand() * 0.45) * p.scale + 0.12, p.z + Math.sin(a) * r);
      d.phase.push(rand() * 10);
      d.groups.push(p.group ?? null);
    }
  }
}

// ---- mist (WorldView.buildMist): same rand order, area-weighted placement.
mirrorCheck('src/graphics/WorldView.ts', [
  'const count = 220;',
  'const rand = mulberry32(5);',
  'const c = new THREE.Color(0x3d3350);',
  'size[i] = 5 + rand() * 6;',
  'alpha[i] = 0.05 + rand() * 0.06;',
  'this.mistVel[i * 2] = (rand() - 0.5) * 0.35;',
  'gl_FragColor = vec4(vC, t.a*vA*1.4);',
  'if (Math.abs(mp.getX(i) - focusX) > 45)',
  'if (Math.abs(mp.getZ(i) - focusZ) > 40)',
]);
const mist = (() => {
  const count = 220;
  const rand = mulberry32(5);
  const areas = AREA_ORDER.map((id) => AREAS[id].rect);
  const weights = areas.map((r) => (r.x1 - r.x0) * (r.z1 - r.z0));
  const total = weights.reduce((a, b) => a + b, 0);
  const o = { count, pos: [] as number[], vel: [] as number[], size: [] as number[], alpha: [] as number[], color: 0x3d3350 };
  for (let i = 0; i < count; i++) {
    let roll = rand() * total;
    let r = areas[0];
    for (let k = 0; k < areas.length; k++) {
      if (roll < weights[k]) {
        r = areas[k];
        break;
      }
      roll -= weights[k];
    }
    o.pos.push(r.x0 + rand() * (r.x1 - r.x0), 0.25 + rand() * 0.9, r.z0 + rand() * (r.z1 - r.z0));
    o.size.push(5 + rand() * 6);
    o.alpha.push(0.05 + rand() * 0.06);
    o.vel.push((rand() - 0.5) * 0.35, (rand() - 0.5) * 0.35);
  }
  return o;
})();

// ---- Atmosphere profiles: read the literal out of the source (hex numbers and plain arrays only).
const atmoText = src('src/graphics/Atmosphere.ts');
const profStart = atmoText.indexOf('const PROFILES: Record<AreaId, Kind[]> = {');
const profEnd = atmoText.indexOf('\n};', profStart);
if (profStart < 0 || profEnd < 0) throw new Error('mirror drift: Atmosphere PROFILES not found');
const profLit = atmoText.slice(profStart + 'const PROFILES: Record<AreaId, Kind[]> = '.length, profEnd + 3).replace(/\/\/.*$/gm, '');
const atmoProfiles = new Function(`return (${profLit.replace(/;\s*$/, '')});`)() as Record<string, unknown[]>;
const boxM = /const BOX = \{ x: (\d+), y: (\d+), z: (\d+) \};/.exec(atmoText);
if (!boxM) throw new Error('mirror drift: Atmosphere BOX');
mirrorCheck('src/graphics/Atmosphere.ts', [
  'const rand = mulberry32(area.length * 977 + area.charCodeAt(0));',
  'Math.ceil(k.count / 2)',
  'this.fade = Math.max(0, this.fade - dt * 1.6);',
  'this.fade = Math.min(1, this.fade + dt * 0.8);',
  'float tw = 0.75 + 0.25 * sin(t * 2.7 + aSeed.w * 21.0);',
  'vRot = aSeed.w * 6.2831 + t * (0.6 + aMotion.w * 1.8);',
  'p.x += sin(t * 0.9 + aSeed.w * 6.2831) * aMotion.w;',
  'this.seed.setXYZW(i, rand() * BOX.x * 2, rand() * BOX.y, rand() * BOX.z * 2, rand());',
  'this.motion.setXYZW(i, (rand() - 0.3) * k.drift[0], lerp(k.vy), (rand() - 0.5) * k.drift[1], k.sway * (0.5 + rand() * 0.5));',
]);

// ---- standing water: Water([...water, ...bog, ...ponds], puddles)
mirrorCheck('src/graphics/WorldView.ts', ['this.water = new Water([...layout.water, ...layout.bog, ...layout.ponds], layout.puddles);']);
mirrorCheck('src/graphics/Water.ts', [
  'const RIPPLES = 16;', 'const RIPPLE_LIFE = 2.2;', 'const DEPTH_INSET = 3.2;', 'const Y = 0.06;', 'const NAVE_SHEEN = 0.25;',
  'float x = dist - age * 1.5;', 'float glint = pow(max(dot(R, normalize(vec3(0.12, 0.42, -0.9))), 0.0), 220.0) * patchy;',
  "roughness: 0.16, metalness: 0.1", "color: 0x15142a", "color: 0x131228", "opacity: 0.72",
  'this.uniforms.uDeep.value.set(fen ? 0x02100e : 0x04040b);', 'this.uniforms.uRim.value.set(fen ? 0x2a7a72 : 0x2c3a7a);',
]);
const water = { rects: [...layout.water, ...layout.bog, ...layout.ponds], puddles: layout.puddles };

// ---- bloom / occlusion / wings / hover
const gr = src('src/app/GameRuntime.ts');
const ws = src('src/scenes/WorldScene.ts');
const bloomDefault = /const DEFAULT_BLOOM = \{ strength: ([\d.]+), radius: ([\d.]+), threshold: ([\d.]+) \};/.exec(gr);
const bloomWorld = /readonly bloom = \{ strength: ([\d.]+), radius: ([\d.]+), threshold: ([\d.]+) \};/.exec(ws);
if (!bloomDefault || !bloomWorld) throw new Error('mirror drift: bloom constants');
const bloom = { strength: +bloomWorld[1], radius: +bloomWorld[2], threshold: +bloomWorld[3], defaults: { strength: +bloomDefault[1], radius: +bloomDefault[2], threshold: +bloomDefault[3] } };
const ev = src('src/graphics/EntityViews.ts');
const wm = /const WINGS: Partial<Record<EnemyId, WingOpts>> = \{([\s\S]*?)\n\};/.exec(ev);
if (!wm) throw new Error('mirror drift: WINGS');
const wings: Record<string, { speed: number; amp: number; body: number }> = {};
for (const m of wm[1].replace(/\/\/.*$/gm, '').matchAll(/(\w+): \{ speed: ([\d.]+), amp: ([\d.]+), body: ([\d.]+) \}/g)) wings[m[1]] = { speed: +m[2], amp: +m[3], body: +m[4] };
const hm = /const HOVER = \{ (\w+): ([\d.]+) \} as Partial/.exec(ev);
if (!hm) throw new Error('mirror drift: HOVER');
mirrorCheck('src/graphics/EntityViews.ts', ['let lift = hover ? hover + Math.sin(performance.now() / 520 + id) * (def.flying ? 0.18 : 0.12) : 0;', 'wingClock.value = performance.now() / 1000;']);
mirrorCheck('src/graphics/occlusion.ts', ['uOccRadius: { value: 0.16 }', 'if (occFd < uOccDist - 1.2 && occR < uOccRadius)', 'if (bayer < edge * 0.72) discard;', 'THREE.MathUtils.clamp(Math.abs(head.y - feet.y) * 1.05, 0.1, 0.5)', 'setY(player.y + 1.6)']);
mirrorCheck('src/graphics/WorldView.ts', [
  "color: 0xcfb8ff, transparent: true, depthWrite: false, toneMapped: false", 'new THREE.PlaneGeometry(w.w * 0.9, 14)', 'color: 0x6d4bd6', 'opacity: 0.16',
  'shaft.translateZ(5);', 'shaft.rotateX(-0.55);', 'mesh.translateZ(0.5);',
  "const mat = new THREE.MeshLambertMaterial({ color: 0x2a2436, emissive: 0x0b0912 });",
]);


// ---- goldens (computed from the real TS / transcribed formulas, replayed by godot/tests/world_fx/run.gd)
type Kind = { count: number; shape: number; colors: number[]; size: [number, number]; alpha: [number, number]; vy: [number, number]; drift: [number, number]; sway: number; add: number };
const BOX = { x: +boxM[1], y: +boxM[2], z: +boxM[3] };
const atmoGolden: Record<string, { n: number; nLow: number; first: number[][] }> = {};
for (const [area, kinds] of Object.entries(atmoProfiles) as [string, Kind[]][]) {
  const rand = mulberry32(area.length * 977 + area.charCodeAt(0));
  const first: number[][] = [];
  let n = 0;
  let nLow = 0;
  for (const k of kinds) {
    nLow += Math.ceil(k.count / 2);
    for (let i = 0; i < k.count; i++, n++) {
      const lerp = (r: [number, number]) => r[0] + rand() * (r[1] - r[0]);
      const seed = [rand() * BOX.x * 2, rand() * BOX.y, rand() * BOX.z * 2, rand()];
      const motion = [(rand() - 0.3) * k.drift[0], lerp(k.vy), (rand() - 0.5) * k.drift[1], k.sway * (0.5 + rand() * 0.5)];
      const look = [lerp(k.size), k.shape, lerp(k.alpha), k.add];
      const ci = Math.floor(rand() * k.colors.length);
      if (n < 3 || n === 150) first.push([...seed, ...motion, ...look, k.colors[ci]]);
    }
  }
  atmoGolden[area] = { n, nLow, first };
}
const bendCases: number[][] = [];
{
  const r = mulberry32(17);
  for (let i = 0; i < 60; i++) {
    const speed = [8, 17, 3.2][i % 3];
    const amp = [0.55, 0.75, 0.22][i % 3];
    const bodyShare = [0.16, 0.22, 0.3][i % 3];
    const center = (r() - 0.5) * 0.4;
    const half = 0.3 + r();
    const body = half * bodyShare;
    const span = center + (r() * 2 - 1) * half * 1.1;
    const phase = r() * Math.PI * 2;
    const t = r() * 20;
    // wingFlap.ts vertex shader, line for line (GLSL smoothstep = hermite)
    const ws = span - center;
    const wd = Math.abs(ws) - body;
    let outSpan = span;
    let dy = 0;
    if (wd > 0) {
      const x = Math.min(1, Math.max(0, wd / Math.max(0.001, half - body)));
      const wf = x * x * (3 - 2 * x);
      const wa = amp * Math.sin(t * speed + phase) * (0.35 + 0.65 * wf);
      outSpan = center + Math.sign(ws) * (body + wd * Math.cos(wa));
      dy = wd * Math.sin(wa);
    }
    bendCases.push([span, center, speed, amp, body, half, phase, t, outSpan, dy]);
  }
}
mirrorCheck('src/graphics/wingFlap.ts', ['float wf = smoothstep(0.0, max(0.001, uWing.w - uWing.z), wd);', 'float wa = uWing.y * sin(uWingT * uWing.x + uWingRoot.y) * (0.35 + 0.65 * wf);', 'const body = half * (o.body ?? 0.3);']);
const wetCases: [number, number, boolean][] = [];
{
  const r = mulberry32(3);
  const inRect = (x: number, z: number) => water.rects.some((q) => x >= q.x0 && x <= q.x1 && z >= q.z0 && z <= q.z1);
  const inPud = (x: number, z: number) =>
    water.puddles.some((p) => {
      const dx = x - p.x;
      const dz = z - p.z;
      const c = Math.cos(p.rot);
      const s = Math.sin(p.rot);
      const lx = (dx * c + dz * s) / (p.r * p.sx);
      const lz = (-dx * s + dz * c) / p.r;
      return lx * lx + lz * lz <= 1;
    });
  for (let i = 0; i < 200; i++) {
    const x = -70 + r() * 170;
    const z = -165 + r() * 215;
    wetCases.push([x, z, inRect(x, z) || inPud(x, z)]);
  }
  for (const p of water.puddles) wetCases.push([p.x, p.z, true]);
  for (const q of water.rects) wetCases.push([(q.x0 + q.x1) / 2, (q.z0 + q.z1) / 2, true]);
}
const occCases: number[][] = [];
{
  const setups: [number, number, number, number, number, number, number, number, number][] = [
    // fov, aspect, camX, camY, camZ, playerX, playerY, playerZ, (unused)
    [40, 1.6, 0, 14, 10, 0, 1.1, 0, 0],
    [40, 1.6, 12, 12.5, -75, 12, 1.1, -82, 0],
    [40, 2.1, -30, 20, 30, -34, 1.1, 22, 0],
    [40, 0.75, 5, 9, -60, 3, 1.1, -66, 0],
    [40, 1.78, 0, 30, 25, 0, 1.1, 0, 0],
  ];
  for (const [fov, aspect, cx, cy, cz, px, py, pz] of setups) {
    const cam = new THREE.PerspectiveCamera(fov, aspect, 0.1, 400);
    cam.position.set(cx, cy, cz);
    cam.lookAt(px, 1.1, pz);
    cam.updateMatrixWorld(true);
    cam.updateProjectionMatrix();
    updateOcclusion(cam, new THREE.Vector3(px, py, pz));
    const u = occlusionUniforms;
    occCases.push([fov, aspect, cx, cy, cz, px, py, pz, u.uOccPlayer.value.x, u.uOccPlayer.value.y, u.uOccRadius.value, u.uOccDist.value]);
  }
}
const liftCases: number[][] = [];
for (let i = 0; i < 12; i++) liftCases.push([i * 37, i * 1234.5]);

const out = {
  windows: layout.windows,
  silhouettes,
  flames,
  mist,
  atmosphere: { profiles: atmoProfiles, box: { x: +boxM[1], y: +boxM[2], z: +boxM[3] } },
  water,
  bloom,
  wings,
  hover: { [hm[1]]: +hm[2] },
  golden: { atmosphere: atmoGolden, bend: bendCases, wet: wetCases, occlusion: occCases, lift: liftCases, waterTris: water.rects.length * 10 + water.puddles.length * 18 },
};
writeFileSync(resolve(OUT, 'fx.json'), JSON.stringify(out) + '\n');
console.log('world_fx: windows', out.windows.length, 'silhouettes', silhouettes.length, 'flame areas', Object.keys(flames).length, 'flames', Object.values(flames).reduce((s, f) => s + f.phase.length, 0), 'mist', mist.count, 'atmo areas', Object.keys(atmoProfiles).length, 'wings', Object.keys(wings).join(','));
