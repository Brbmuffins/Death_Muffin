import * as THREE from 'three';
import type { Effects } from './Effects';

/**
 * DEV/QA only (imported dynamically by tools/qa/vfx-cost.cjs, never by the game): measures what the effect layer costs
 * the GPU and how many materials it owns.
 *
 *  - `fillStats`: transparent overdraw. The scene's opaque geometry is rendered for depth, then every transparent
 *    material under `Effects.group` is patched to write a constant 1 with ONE/ONE blending into a half-float target, so
 *    each pixel counts how many effect fragments were rasterised onto it (alpha-discarded and empty-texel ones included:
 *    that is the fill the GPU really pays for). `layers` is total fragment-layers divided by screen pixels.
 *  - `fxMaterials`: every distinct material the Effects instance (and its Binbun pool) holds.
 */

type Mat = THREE.Material & { onBeforeCompile?: (s: { fragmentShader: string }, r: unknown) => void; customProgramCacheKey?: () => string };

let target: THREE.WebGLRenderTarget | null = null;
let small: THREE.WebGLRenderTarget | null = null;

function half(h: number) {
  const s = (h & 0x8000) >> 15;
  const e = (h & 0x7c00) >> 10;
  const f = h & 0x03ff;
  if (e === 0) return (s ? -1 : 1) * Math.pow(2, -14) * (f / 1024);
  if (e === 31) return f ? NaN : (s ? -1 : 1) * Infinity;
  return (s ? -1 : 1) * Math.pow(2, e - 15) * (1 + f / 1024);
}

function rtFor(w: number, h: number, shrink: number) {
  const W = Math.max(8, Math.round(w / shrink));
  const H = Math.max(8, Math.round(h / shrink));
  const slot = shrink === 1 ? target : small;
  if (slot && slot.width === W && slot.height === H) return slot;
  slot?.dispose();
  const t = new THREE.WebGLRenderTarget(W, H, { type: THREE.HalfFloatType, format: THREE.RGBAFormat, depthBuffer: true, stencilBuffer: false, samples: 0 });
  if (shrink === 1) target = t;
  else small = t;
  return t;
}

interface Saved {
  m: Mat;
  onBeforeCompile: Mat['onBeforeCompile'];
  key: Mat['customProgramCacheKey'];
  blending: THREE.Blending;
  src: THREE.BlendingDstFactor | THREE.BlendingSrcFactor;
  dst: THREE.BlendingDstFactor;
  eq: THREE.BlendingEquation;
  srcA: number | null;
  dstA: number | null;
  eqA: number | null;
  premul: boolean;
}

function patch(m: Mat): Saved {
  const s: Saved = { m, onBeforeCompile: m.onBeforeCompile, key: m.customProgramCacheKey, blending: m.blending, src: m.blendSrc, dst: m.blendDst, eq: m.blendEquation, srcA: m.blendSrcAlpha, dstA: m.blendDstAlpha, eqA: m.blendEquationAlpha, premul: m.premultipliedAlpha };
  const origCompile = m.onBeforeCompile;
  const origKey = m.customProgramCacheKey;
  m.onBeforeCompile = (shader, r) => {
    (origCompile as unknown as (s: unknown, r: unknown) => void)?.call(m, shader, r);
    // Count every rasterised fragment, alpha-discarded ones too: they still pay for the shader and the texture fetch.
    // R counts the fragment; G counts it only when it would visibly change the pixel (colour x alpha above 1/255).
    const fs = shader.fragmentShader.replace(/\bdiscard\s*;/g, '{ gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0); return; }');
    const i = fs.lastIndexOf('}');
    shader.fragmentShader = `${fs.slice(0, i)}\n { vec4 fxc = gl_FragColor; float fxv = max(max(fxc.r, fxc.g), fxc.b) * fxc.a; gl_FragColor = vec4(1.0, fxv > 0.004 ? 1.0 : 0.0, 0.0, 1.0); }\n}${fs.slice(i + 1)}`;
  };
  m.customProgramCacheKey = () => `${origKey ? origKey.call(m) : ''}|fxprobe`;
  m.blending = THREE.CustomBlending;
  m.blendEquation = THREE.AddEquation;
  m.blendSrc = THREE.OneFactor;
  m.blendDst = THREE.OneFactor;
  m.blendEquationAlpha = THREE.AddEquation;
  m.blendSrcAlpha = THREE.OneFactor;
  m.blendDstAlpha = THREE.OneFactor;
  m.premultipliedAlpha = false;
  m.needsUpdate = true;
  return s;
}

function restore(s: Saved) {
  const { m } = s;
  m.onBeforeCompile = s.onBeforeCompile as Mat['onBeforeCompile'];
  m.customProgramCacheKey = s.key as Mat['customProgramCacheKey'];
  m.blending = s.blending;
  m.blendSrc = s.src as THREE.BlendingDstFactor;
  m.blendDst = s.dst;
  m.blendEquation = s.eq;
  m.blendSrcAlpha = s.srcA as never;
  m.blendDstAlpha = s.dstA as never;
  m.blendEquationAlpha = s.eqA as never;
  m.premultipliedAlpha = s.premul;
  m.needsUpdate = true;
}

const matsOf = (o: THREE.Object3D): Mat[] => {
  const m = (o as THREE.Mesh).material as Mat | Mat[] | undefined;
  return !m ? [] : Array.isArray(m) ? m : [m];
};

function isFxTransparent(o: THREE.Object3D) {
  return o.visible && matsOf(o).some((m) => m.transparent);
}

function allVisible(o: THREE.Object3D) {
  for (let p: THREE.Object3D | null = o; p; p = p.parent) if (!p.visible) return false;
  return true;
}

function fxObjects(group: THREE.Object3D) {
  const out: THREE.Object3D[] = [];
  group.traverse((o) => {
    if (o !== group && (o as THREE.Mesh).material && allVisible(o) && isFxTransparent(o)) out.push(o);
  });
  return out;
}

export interface FillStats {
  /** Effect fragment-layers per screen pixel (1 = the whole screen covered once). */
  layers: number;
  /** The part of `layers` that visibly changes a pixel (colour x alpha above 1/255): the rest is rasterised for nothing. */
  visible: number;
  /** Share of the screen touched by any effect fragment. */
  covered: number;
  /** Deepest stack on a single pixel. */
  max: number;
  /** Visible transparent effect objects (≈ draw calls). */
  objects: number;
}

function readLayers(r: THREE.WebGLRenderer, rt: THREE.WebGLRenderTarget) {
  const buf = new Uint16Array(rt.width * rt.height * 4);
  r.readRenderTargetPixels(rt, 0, 0, rt.width, rt.height, buf as unknown as Uint8Array);
  let sum = 0;
  let vis = 0;
  let cov = 0;
  let max = 0;
  for (let i = 0; i < buf.length; i += 4) {
    const v = half(buf[i]);
    if (v > 0.5) {
      sum += v;
      vis += half(buf[i + 1]);
      cov++;
      if (v > max) max = v;
    }
  }
  return { sum, vis, cov, max, px: rt.width * rt.height };
}

/** Renders opaque depth then `only` (or every transparent effect object) as constant-1 layers; returns the stack stats. */
function layerPass(r: THREE.WebGLRenderer, scene: THREE.Scene, camera: THREE.Camera, group: THREE.Object3D, only: THREE.Object3D[] | null, shrink: number) {
  const size = r.getDrawingBufferSize(new THREE.Vector2());
  const rt = rtFor(size.x, size.y, shrink);
  const fxs = only ?? fxObjects(group);
  const saved: Saved[] = [];
  const seen = new Set<Mat>();
  for (const o of fxs) for (const m of matsOf(o)) if (m.transparent && !seen.has(m)) (seen.add(m), saved.push(patch(m)));
  // Pass 1: depth from the opaque world (effect objects hidden). Pass 2: only the effect objects.
  const hidden: THREE.Object3D[] = [];
  for (const o of fxObjects(group)) (o.visible = false), hidden.push(o);
  const prevTarget = r.getRenderTarget();
  const prevAuto = r.autoClear;
  const prevShadow = r.shadowMap.autoUpdate;
  r.shadowMap.autoUpdate = false;
  r.setRenderTarget(rt);
  r.setClearColor(0x000000, 0);
  r.autoClear = true;
  r.render(scene, camera);
  for (const o of hidden) o.visible = true;
  r.autoClear = false;
  r.clearColor();
  const kids = scene.children.filter((c) => c !== group && c.visible);
  for (const c of kids) c.visible = false;
  const opaques: THREE.Object3D[] = [];
  group.traverse((o) => {
    if (o !== group && (o as THREE.Mesh).material && o.visible && !fxs.includes(o)) (o.visible = false), opaques.push(o);
  });
  r.render(scene, camera);
  for (const o of opaques) o.visible = true;
  for (const c of kids) c.visible = true;
  r.setRenderTarget(prevTarget);
  r.autoClear = prevAuto;
  r.shadowMap.autoUpdate = prevShadow;
  const res = readLayers(r, rt);
  for (const s of saved) restore(s);
  return { ...res, objects: fxs.length };
}

export function fillStats(r: THREE.WebGLRenderer, scene: THREE.Scene, camera: THREE.Camera, fx: Effects): FillStats {
  const res = layerPass(r, scene, camera, fx.group, null, 1);
  return { layers: res.sum / res.px, visible: res.vis / res.px, covered: res.cov / res.px, max: res.max, objects: res.objects };
}

/** Which effect objects burn the most fill (one full-resolution render each: point sizes are in pixels, so a smaller target would inflate them); labels from Binbun parts / decal layers / particle rings. */
export function fillBreakdown(r: THREE.WebGLRenderer, scene: THREE.Scene, camera: THREE.Camera, fx: Effects, top = 8) {
  const label = new Map<THREE.Object3D, string>();
  const f = fx as unknown as { additive: { points: THREE.Object3D }; smoke: { points: THREE.Object3D }; decalLayers: Map<string, { mesh: THREE.Object3D; items: unknown[] }> };
  label.set(f.additive.points, 'particles:additive');
  label.set(f.smoke.points, 'particles:smoke');
  for (const [k, l] of f.decalLayers) label.set(l.mesh, `decals:${k.split('|')[1] === '2' ? 'add' : 'norm'}:${(l.mesh as THREE.InstancedMesh).count}x`);
  const live = (fx.binbun as unknown as { live: { id: string; inst: { parts: { node: { name: string }; mesh: THREE.Object3D }[] } | null }[] }).live;
  for (const l of live) for (const p of l.inst?.parts ?? []) label.set(p.mesh, `bb:${l.id}/${p.node.name.split('/').pop()}`);
  const objs = fxObjects(fx.group);
  const rows: { label: string; layers: number; vis: number; count: number }[] = [];
  const merged = new Map<string, { layers: number; vis: number; count: number }>();
  for (const o of objs) {
    const res = layerPass(r, scene, camera, fx.group, [o], 1);
    const name = label.get(o) ?? ((o as THREE.Sprite).isSprite ? 'sprite' : o.type);
    const cur = merged.get(name) ?? { layers: 0, vis: 0, count: 0 };
    cur.layers += res.sum / res.px;
    cur.vis += res.vis / res.px;
    cur.count += (o as THREE.InstancedMesh).isInstancedMesh ? (o as THREE.InstancedMesh).count : 1;
    merged.set(name, cur);
  }
  for (const [k, v] of merged) rows.push({ label: k, ...v });
  return rows.sort((a, b) => b.layers - a.layers).slice(0, top);
}

/** Every distinct material the Effects instance holds (scene children, pools, Binbun pool + live parts). */
export function fxMaterials(fx: Effects) {
  const set = new Set<THREE.Material>();
  const add = (o: THREE.Object3D) => matsOf(o).forEach((m) => set.add(m));
  fx.group.traverse(add);
  const f = fx as unknown as Record<string, unknown>;
  for (const k of ['spritePool', 'beamPool', 'needlePool', 'orbPool', 'spriteShotPool']) for (const o of (f[k] as THREE.Object3D[]) ?? []) add(o);
  const built = (fx.binbun as unknown as { built: Set<{ parts: { mat: THREE.Material }[] }> }).built;
  for (const inst of built) for (const p of inst.parts) set.add(p.mat);
  return set.size;
}

/**
 * DEV: do the instanced layers draw the same pixels as the pooled Sprite / Mesh objects they replaced? Renders the same
 * hand-placed set both ways (old objects in one scene, `Effects` in another) with the game's fog, and returns the mean and the
 * largest per-channel difference (0-255) for each kind. Zero means identical; a few counts is 8-bit rounding.
 */
export async function parity(r: THREE.WebGLRenderer) {
  const { Effects: E } = await import('./Effects');
  const { fx } = await import('./fxTextures');
  const W = 512;
  const H = 384;
  const rt = new THREE.WebGLRenderTarget(W, H, { type: THREE.UnsignedByteType, depthBuffer: true });
  const cam = new THREE.PerspectiveCamera(45, W / H, 0.1, 100);
  cam.position.set(0, 9, 9);
  cam.lookAt(0, 0.5, 0);
  cam.updateMatrixWorld();
  const mkScene = () => {
    const s = new THREE.Scene();
    s.background = new THREE.Color(0x06050a);
    s.fog = new THREE.FogExp2(0x0b0810, 0.014);
    return s;
  };
  const grab = (scene: THREE.Scene) => {
    r.setRenderTarget(rt);
    r.setClearColor(0x06050a, 1);
    r.clear();
    r.render(scene, cam);
    const buf = new Uint8Array(W * H * 4);
    r.readRenderTargetPixels(rt, 0, 0, W, H, buf);
    r.setRenderTarget(null);
    return buf;
  };
  const diff = (a: Uint8Array, b: Uint8Array) => {
    let sum = 0;
    let max = 0;
    let lit = 0;
    let at = 0;
    let over = 0;
    for (let i = 0; i < a.length; i += 4) {
      const d = Math.max(Math.abs(a[i] - b[i]), Math.abs(a[i + 1] - b[i + 1]), Math.abs(a[i + 2] - b[i + 2]));
      sum += d;
      if (d > 8) over++;
      if (d > max) (max = d), (at = i);
      if (a[i] + a[i + 1] + a[i + 2] > 60) lit++;
    }
    return { meanAbs: +(sum / (a.length / 4)).toFixed(4), maxAbs: max, litPixels: lit, over8: over, worst: `px(${(at / 4) % W},${Math.floor(at / 4 / W)}) old ${a[at]},${a[at + 1]},${a[at + 2]} new ${b[at]},${b[at + 1]},${b[at + 2]}` };
  };
  const out: Record<string, { meanAbs: number; maxAbs: number; litPixels: number; over8: number; worst: string }> = {};
  const noopCam = new THREE.PerspectiveCamera();

  // Sprites (glow = the round footprint; the wisp-like path uses a quad, covered by `sprite quad` with the cracks texture).
  for (const [name, tex] of [['sprite glow', fx.glow()], ['sprite quad', fx.spark()]] as const) {
    const items = [[-4, 1, -2, 1.6, 0.3, 0xff5599, 1], [-1, 1.4, 1, 0.9, 1.2, 0x55ddff, 0.7], [2, 0.8, -1, 2.2, 2.6, 0xa6ff55, 0.9], [4, 1.8, 2, 1.3, 0, 0xffffff, 0.45], [0, 2.4, -3, 3, 5, 0xffaa22, 1]] as const;
    const A = mkScene();
    for (const [x, y, z, size, rot, color, op] of items) {
      const m = new THREE.SpriteMaterial({ map: tex, color, rotation: rot, opacity: op, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending });
      const sp = new THREE.Sprite(m);
      sp.position.set(x, y, z);
      sp.scale.set(size, size, size);
      sp.renderOrder = 6;
      A.add(sp);
    }
    const B = mkScene();
    const eff = new E(B);
    // Effects.flash fades by life; opacity/size are what we place, so read them back from the instances and overwrite.
    const layers = (eff as unknown as { spriteLayers: Map<string, { items: { x: number; y: number; z: number; size: number; rot: number; opacity: number }[]; flush(): void }> }).spriteLayers;
    for (const [x, y, z, size, , color] of items) eff.flash({ x, y, z, color, size, duration: 1e9, tex });
    const layer = layers.get(tex.uuid)!;
    items.forEach(([, , , size, rot, , op], i) => Object.assign(layer.items[i], { size, rot, opacity: op }));
    layer.flush();
    out[name] = diff(grab(A), grab(B));
    eff.dispose();
  }

  // Beams.
  {
    const items = [[-5, 0.6, -2, 4, 1.6, 2, 0x99ffcc, 0.05, 1], [-2, 1.2, 0, 1, 2.2, -3, 0xff77aa, 0.12, 0.8], [0, 0.3, 2, 3, 2, 0, 0x77aaff, 0.2, 0.6], [3, 2, -2, 3, 0.2, 2, 0xffee88, 0.07, 1], [-1, 0.2, -3, -1, 3, -3, 0xffffff, 0.15, 0.5]] as const;
    const A = mkScene();
    const geo = new THREE.CylinderGeometry(1, 1, 1, 6, 1, true).rotateX(Math.PI / 2);
    for (const [x0, y0, z0, x1, y1, z1, color, w, op] of items) {
      const m = new THREE.Mesh(geo, new THREE.MeshBasicMaterial({ color, opacity: op, transparent: true, depthWrite: false, blending: THREE.AdditiveBlending }));
      const pa = new THREE.Vector3(x0, y0, z0);
      const pb = new THREE.Vector3(x1, y1, z1);
      m.position.copy(pa).lerp(pb, 0.5);
      m.lookAt(pb);
      m.scale.set(w, w, pa.distanceTo(pb));
      m.renderOrder = 6;
      A.add(m);
    }
    const B = mkScene();
    const eff = new E(B);
    for (const [x0, y0, z0, x1, y1, z1, color, w] of items) eff.beam({ x: x0, y: y0, z: z0 }, () => ({ x: x1, y: y1, z: z1 }), color, w, 1e9);
    const layer = (eff as unknown as { beamLayer: { items: { width: number; opacity: number; x: number; y: number; z: number; tx: number; ty: number; tz: number; length: number }[]; flush(): void } }).beamLayer;
    items.forEach(([x0, y0, z0, x1, y1, z1, , w, op], i) => Object.assign(layer.items[i], { x: (x0 + x1) / 2, y: (y0 + y1) / 2, z: (z0 + z1) / 2, tx: x1, ty: y1, tz: z1, width: w, opacity: op, length: Math.hypot(x1 - x0, y1 - y0, z1 - z0) }));
    layer.flush();
    out.beam = diff(grab(A), grab(B));
    eff.dispose();
  }

  // Ground decals: one layer per texture; compare against the quad each used to draw.
  for (const [name, tex] of [['decal disc', fx.disc()], ['decal ring', fx.ring()], ['decal sigil', fx.sigil()], ['decal cracks', fx.cracks()], ['decal glow', fx.glow()]] as const) {
    const items = [[-3, -2, 2.2, 0, 0xff5599, 0.9], [2, -1, 1.4, 1.1, 0x55ddff, 0.7], [0, 2, 3, 2.3, 0xa6ff55, 1], [-4, 2.5, 1.1, 0.4, 0xffaa22, 0.5]] as const;
    const A = mkScene();
    const plane = new THREE.PlaneGeometry(1, 1).rotateX(-Math.PI / 2);
    for (const [x, z, rad, rot, color, op] of items) {
      const m = new THREE.Mesh(plane, new THREE.MeshBasicMaterial({ map: tex, color, opacity: op, transparent: true, depthWrite: false, side: THREE.DoubleSide, blending: THREE.AdditiveBlending }));
      m.position.set(x, 0.04, z);
      m.rotation.y = rot;
      m.scale.set(rad * 2, 1, rad * 2);
      m.renderOrder = 2;
      A.add(m);
    }
    const B = mkScene();
    const eff = new E(B);
    for (const [x, z, rad, rot, color, op] of items) eff.decal({ tex, color, x, z, r: rad, rot, duration: 1e9, opacity: op, fadeIn: 1e-6, fadeOut: 1e-6 });
    eff.update(0.01, noopCam, 700);
    const ga = grab(A);
    const gb = grab(B);
    out[name] = diff(ga, gb);
    // The footprint crop alone: the same decals through the same instanced layer, once on a square (before) and once on the footprint mesh (after).
    const Cs = mkScene();
    const effC = new E(Cs);
    (effC as unknown as { footprintOf: () => string }).footprintOf = () => 'quad';
    for (const [x, z, rad, rot, color, op] of items) effC.decal({ tex, color, x, z, r: rad, rot, duration: 1e9, opacity: op, fadeIn: 1e-6, fadeOut: 1e-6 });
    effC.update(0.01, noopCam, 700);
    out[`${name} crop only`] = diff(grab(Cs), gb);
    effC.dispose();
    (globalThis as unknown as { __parityBufs?: Record<string, number[][]> }).__parityBufs ??= {};
    (globalThis as unknown as { __parityBufs: Record<string, number[][]> }).__parityBufs[name] = [Array.from(ga), Array.from(gb)];
    eff.dispose();
  }
  rt.dispose();
  return out;
}
