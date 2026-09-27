/**
 * Pure (DOM-free, three-free) reading of the converted BinbunVFX effects in
 * public/fx/binbun/*.json (tools/binbun-port.mjs). Each file keeps the parsed
 * Godot resource sections of a scene and everything it references; this
 * module resolves them into small templates the Three.js runtime can play:
 * particle emitters, meshes, lights and animation tracks.
 *
 * Only what the effects actually use is read (docs/BINBUN-VFX-PORT.md §3); an
 * unknown value never throws, it just falls back to Godot's default.
 */

export interface GodotSection {
  kind: string;
  attributes: Record<string, unknown>;
  properties: Record<string, unknown>;
  bakedSamples?: number[];
  bakedTexture?: string;
}
export interface GodotDocument {
  source: string;
  sections: GodotSection[];
}
export interface BinbunEffectFile {
  id: string;
  animation: string;
  duration: number;
  defaultColors?: number[][];
  root: string;
  documents: Record<string, GodotDocument>;
  assets: Record<string, { kind: string; output?: string }>;
}

type Typed = { $type: string; args: unknown[] };
const isTyped = (v: unknown): v is Typed => !!v && typeof v === 'object' && '$type' in (v as object);
const num = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d);

export function vec(v: unknown, d: number[]): number[] {
  return isTyped(v) && Array.isArray(v.args) && v.args.every((x) => typeof x === 'number') ? (v.args as number[]) : d;
}
export const color = (v: unknown, d: number[] = [1, 1, 1, 1]) => vec(v, d);

/** Godot Transform3D (basis columns x, y, z then origin) → column-major 4×4. */
export function transform(v: unknown): number[] {
  const a = vec(v, [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]);
  if (a.length < 12) return [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  // Godot writes Transform3D(xx, xy, xz, yx, yy, yz, zx, zy, zz, ox, oy, oz) with xx.. being basis rows.
  const [xx, xy, xz, yx, yy, yz, zx, zy, zz, ox, oy, oz] = a;
  return [xx, yx, zx, 0, xy, yy, zy, 0, xz, yz, zz, 0, ox, oy, oz, 1];
}

/** Godot's Curve evaluation (cubic Bézier per segment from tangents), n samples over x ∈ [0, 1]. */
export function sampleCurve(data: unknown, n = 32): number[] {
  const d = Array.isArray(data) ? data : [];
  const pts: { x: number; y: number; lt: number; rt: number }[] = [];
  for (let i = 0; i + 4 < d.length + 1; i += 5) {
    const p = vec(d[i], [NaN, NaN]);
    if (!Number.isFinite(p[0])) break;
    pts.push({ x: p[0], y: p[1], lt: num(d[i + 1], 0), rt: num(d[i + 2], 0) });
  }
  if (!pts.length) return Array.from({ length: n }, () => 1);
  const out: number[] = [];
  for (let s = 0; s < n; s++) {
    const x = n === 1 ? 0 : s / (n - 1);
    if (x <= pts[0].x) {
      out.push(pts[0].y);
      continue;
    }
    if (x >= pts[pts.length - 1].x) {
      out.push(pts[pts.length - 1].y);
      continue;
    }
    let i = 0;
    while (i < pts.length - 2 && x > pts[i + 1].x) i++;
    const a = pts[i];
    const b = pts[i + 1];
    const span = Math.max(1e-6, b.x - a.x);
    const t = (x - a.x) / span;
    const dd = span / 3;
    const yac = a.y + dd * a.rt;
    const ybc = b.y - dd * b.lt;
    const mt = 1 - t;
    out.push(mt * mt * mt * a.y + 3 * mt * mt * t * yac + 3 * mt * t * t * ybc + t * t * t * b.y);
  }
  return out;
}

/** Linear lookup into a sampled curve. */
export function curveAt(samples: number[] | null, t: number) {
  if (!samples || !samples.length) return 1;
  const f = Math.max(0, Math.min(1, t)) * (samples.length - 1);
  const i = Math.floor(f);
  const k = f - i;
  return samples[i] + ((samples[Math.min(samples.length - 1, i + 1)] ?? samples[i]) - samples[i]) * k;
}

export type TextureRef =
  | { kind: 'png'; url: string }
  | { kind: 'noise'; key: string; size: number[]; seed: number; frequency: number; octaves: number; gain: number; fractal: number; invert: boolean; cellular: boolean; ramp: GradientStop[] | null }
  | { kind: 'gradient'; key: string; size: number[]; stops: GradientStop[]; constant: boolean; fill: number; from: number[]; to: number[]; repeat: number; oneD: boolean };
export type GradientStop = { t: number; c: number[] };

/** Resolves ExtResource / SubResource references across the documents of one effect file. */
export class Resolver {
  private subs = new Map<string, Map<string, GodotSection>>();
  private exts = new Map<string, Map<string, string>>();

  constructor(readonly file: BinbunEffectFile, readonly base = 'fx/binbun/') {
    for (const [key, doc] of Object.entries(file.documents)) {
      const subs = new Map<string, GodotSection>();
      const exts = new Map<string, string>();
      const pack = key.split('/')[0];
      for (const s of doc.sections) {
        const id = String(s.attributes.id ?? '');
        if (s.kind === 'sub_resource') subs.set(id, s);
        else if (s.kind === 'ext_resource') {
          const p = String(s.attributes.path ?? '');
          exts.set(id, p.startsWith('res://') ? `${pack}/${p.slice('res://'.length)}` : p);
        }
      }
      this.subs.set(key, subs);
      this.exts.set(key, exts);
    }
  }

  /** The section a SubResource/ExtResource names (an external .tres resolves to its root `resource`). */
  section(ref: unknown, docKey: string): { section: GodotSection; doc: string; type: string } | null {
    if (!isTyped(ref)) return null;
    const id = String(ref.args?.[0] ?? '');
    if (ref.$type === 'SubResource') {
      const s = this.subs.get(docKey)?.get(id);
      return s ? { section: s, doc: docKey, type: String(s.attributes.type ?? '') } : null;
    }
    if (ref.$type === 'ExtResource') {
      const path = this.exts.get(docKey)?.get(id);
      const doc = path ? this.file.documents[path] : undefined;
      if (!doc) return null;
      const head = doc.sections.find((s) => s.kind === 'gd_resource');
      const root = doc.sections.find((s) => s.kind === 'resource');
      return root ? { section: root, doc: path!, type: String(head?.attributes.type ?? '') } : null;
    }
    return null;
  }

  /** An ExtResource's source path key (e.g. `PoisonVFX/assets/BinbunVFX/shared/shader/particle.gdshader`). */
  assetPath(ref: unknown, docKey: string): string | null {
    if (!isTyped(ref) || ref.$type !== 'ExtResource') return null;
    return this.exts.get(docKey)?.get(String(ref.args?.[0] ?? '')) ?? null;
  }

  /** An ExtResource asset (shader / texture) → public URL, if the converter copied it. */
  assetUrl(ref: unknown, docKey: string): string | null {
    if (!isTyped(ref) || ref.$type !== 'ExtResource') return null;
    const path = this.exts.get(docKey)?.get(String(ref.args?.[0] ?? ''));
    const out = path ? this.file.assets[path]?.output : undefined;
    return out ? this.base + out : null;
  }

  curve(ref: unknown, docKey: string): number[] | null {
    const r = this.section(ref, docKey);
    if (!r) return null;
    // CurveTexture / CurveXYZTexture → the (first) curve; a Curve itself carries samples.
    const inner = r.type === 'Curve' ? r : this.section(r.section.properties.curve ?? r.section.properties.curve_x, r.doc);
    if (!inner) return null;
    return inner.section.bakedSamples ?? sampleCurve(inner.section.properties._data);
  }

  texture(ref: unknown, docKey: string): TextureRef | null {
    const url = this.assetUrl(ref, docKey);
    if (url) return /\.(png|webp|jpg)$/i.test(url) ? { kind: 'png', url } : null;
    const r = this.section(ref, docKey);
    if (!r) return null;
    if (r.section.bakedTexture) return { kind: 'png', url: this.base + r.section.bakedTexture };
    const p = r.section.properties;
    const key = `${r.doc}#${String(r.section.attributes.id ?? 'root')}`;
    const gradient = (ref: unknown, doc: string) => {
      const g = this.section(ref, doc)?.section.properties;
      if (!g) return null;
      const offsets = vec(g.offsets, [0, 1]);
      const cols = vec(g.colors, [0, 0, 0, 1, 1, 1, 1, 1]);
      return { stops: offsets.map((t, i) => ({ t, c: cols.slice(i * 4, i * 4 + 4) })), constant: num(g.interpolation_mode, 0) === 1 };
    };
    if (r.type === 'NoiseTexture2D') {
      const n = this.section(p.noise, r.doc)?.section.properties ?? {};
      return {
        kind: 'noise',
        key,
        size: [num(p.width, 512), num(p.height, 512)],
        seed: num(n.seed, 0),
        frequency: num(n.frequency, 0.01),
        octaves: num(n.fractal_type, 1) === 0 ? 1 : num(n.fractal_octaves, 5),
        gain: num(n.fractal_gain, 0.5),
        fractal: num(n.fractal_type, 1),
        invert: p.invert === true,
        cellular: num(n.noise_type, 1) === 2,
        ramp: gradient(p.color_ramp, r.doc)?.stops ?? null,
      };
    }
    if (r.type === 'GradientTexture2D' || r.type === 'GradientTexture1D') {
      const g = gradient(p.gradient, r.doc) ?? { stops: [{ t: 0, c: [0, 0, 0, 1] }, { t: 1, c: [1, 1, 1, 1] }], constant: false };
      const oneD = r.type === 'GradientTexture1D';
      return { kind: 'gradient', key, size: oneD ? [num(p.width, 256), 1] : [num(p.width, 64), num(p.height, 64)], stops: g.stops, constant: g.constant, fill: num(p.fill, 0), from: vec(p.fill_from, [0, 0]), to: vec(p.fill_to, [1, 0]), repeat: num(p.repeat, 0), oneD };
    }
    return null;
  }
}

/** Which GLSL port draws a material (BINBUN-VFX-PORT §3): the shared shaders are ported exactly, the rest approximate. */
export type ShaderProgram = 'transparent' | 'particle' | 'glow_fresnel' | 'generic';
export type ParamValue = number | boolean | number[];

export interface MaterialTemplate {
  program: ShaderProgram;
  shaderPath: string | null;
  /** Plain (non-texture) shader parameters, colours as RGBA arrays. */
  params: Record<string, ParamValue>;
  /** Every sampler parameter that resolved. */
  samplers: Record<string, TextureRef>;
  /** The generic port's main mask (first of a priority list). */
  texture: TextureRef | null;
  colors: number[][];
  alpha: number;
  emission: number;
  billboard: boolean;
  additive: boolean;
  unshaded: boolean;
  /** `cull_disabled` shaders draw both faces. */
  doubleSide: boolean;
  /** Smoke-style shaders darken instead of glowing. */
  smoke: boolean;
}

const TEXTURE_PARAMS = ['mask1_texture', 'mask_texture', 'texture_albedo', 'main_texture', 'noise_texture', 'mask2_texture', 'texture', 'albedo_texture', 'gradient_texture', 'shape_texture', 'particle_texture', 'fresnel_gradient'];
/** Shaders written `blend_add` / `unshaded` (the rest are `blend_mix`, lit). */
const ADDITIVE_SHADERS = /glow_tube|glow_core/;
const DOUBLE_SIDED_SHADERS = /explosion_core_particle|muzzle_flash\/shader\/base|explostion_ring|glow_tube|shader\/basic\.gdshader|beam_core|impact_streaks/;
const UNSHADED_SHADERS = /glow_fresnel|glow_tube|glow_core|billboard_flare|particle_star|beam_|glow_particle|basic\.gdshader|basic_billboard|impact_explosions\/src\/shader\/glow/;

function programOf(path: string | null): ShaderProgram {
  if (!path) return 'generic';
  if (/shared\/shader\/transparent\.gdshader$/.test(path)) return 'transparent';
  if (/shared\/shader\/particle\.gdshader$/.test(path)) return 'particle';
  if (/shared\/shader\/glow_fresnel\.gdshader$/.test(path)) return 'glow_fresnel';
  return 'generic';
}

export function materialTemplate(res: Resolver, ref: unknown, docKey: string): MaterialTemplate | null {
  const r = res.section(ref, docKey);
  if (!r) return null;
  const p = r.section.properties;
  const params: Record<string, ParamValue> = {};
  const samplers: Record<string, TextureRef> = {};
  for (const [k, v] of Object.entries(p)) {
    if (!k.startsWith('shader_parameter/')) continue;
    const name = k.slice('shader_parameter/'.length);
    if (typeof v === 'number' || typeof v === 'boolean') params[name] = v;
    else if (isTyped(v) && /^(Color|Vector[234]i?)$/.test(v.$type)) params[name] = vec(v, []);
    else if (isTyped(v)) {
      const t = res.texture(v, r.doc);
      if (t) samplers[name] = t;
    }
  }
  if (r.type === 'StandardMaterial3D') {
    const c = color(p.albedo_color);
    const tex = res.texture(p.albedo_texture, r.doc);
    return { program: 'generic', shaderPath: null, params, samplers: tex ? { albedo_texture: tex } : {}, texture: tex, colors: [c, c, c], alpha: 1, emission: 1, billboard: num(p.billboard_mode, 0) > 0, additive: false, unshaded: true, doubleSide: num(p.cull_mode, 0) === 2, smoke: false };
  }
  let texture: TextureRef | null = null;
  for (const k of TEXTURE_PARAMS) if (!texture && samplers[k]) texture = samplers[k];
  texture ??= Object.values(samplers)[0] ?? null;
  const pc = (k: string) => (Array.isArray(params[k]) ? (params[k] as number[]) : undefined);
  const primary = color(undefined, pc('primary_color') ?? pc('main_color') ?? pc('base_color') ?? pc('surface_color') ?? [1, 1, 1, 1]);
  const secondary = pc('secondary_color') ?? pc('smoke_color') ?? primary;
  const tertiary = pc('tertiary_color') ?? secondary;
  const shaderPath = res.assetPath(p.shader, r.doc);
  const n = (k: string) => (typeof params[k] === 'number' ? (params[k] as number) : undefined);
  return {
    program: programOf(shaderPath),
    shaderPath,
    params,
    samplers,
    texture,
    colors: [primary, secondary, tertiary],
    alpha: n('alpha_multiplier') ?? 1,
    emission: n('emission_strength') ?? n('emission') ?? n('emission_amount') ?? 2,
    billboard: params.billboard === true,
    additive: !!shaderPath && ADDITIVE_SHADERS.test(shaderPath),
    unshaded: !!shaderPath && UNSHADED_SHADERS.test(shaderPath),
    doubleSide: !!shaderPath && DOUBLE_SIDED_SHADERS.test(shaderPath),
    smoke: params.smoke_color !== undefined || (!!shaderPath && /smoke/.test(shaderPath)),
  };
}

export type MeshShape =
  | { kind: 'quad'; w: number; h: number; orientation: number }
  | { kind: 'plane'; w: number; h: number }
  | { kind: 'sphere'; radius: number; height: number; hemisphere: boolean }
  | { kind: 'cylinder'; top: number; bottom: number; height: number }
  | { kind: 'torus'; inner: number; outer: number };

export function meshShape(res: Resolver, ref: unknown, docKey: string): { shape: MeshShape; material: unknown } | null {
  const r = res.section(ref, docKey);
  if (!r) return null;
  const p = r.section.properties;
  const material = p.material;
  switch (r.type) {
    case 'QuadMesh': {
      const s = vec(p.size, [1, 1]);
      return { shape: { kind: 'quad', w: s[0], h: s[1], orientation: num(p.orientation, 2) }, material };
    }
    case 'PointMesh':
      return { shape: { kind: 'quad', w: 0.2, h: 0.2, orientation: 2 }, material };
    case 'PlaneMesh': {
      const s = vec(p.size, [2, 2]);
      return { shape: { kind: 'plane', w: s[0], h: s[1] }, material };
    }
    case 'SphereMesh':
      return { shape: { kind: 'sphere', radius: num(p.radius, 0.5), height: num(p.height, 1), hemisphere: p.is_hemisphere === true }, material };
    case 'CylinderMesh':
    case 'TubeTrailMesh':
      return { shape: { kind: 'cylinder', top: num(p.top_radius, num(p.radius, 0.5)), bottom: num(p.bottom_radius, num(p.radius, 0.5)), height: num(p.height, num(p.section_length, 0.2) * num(p.sections, 5)) }, material };
    case 'TorusMesh':
      return { shape: { kind: 'torus', inner: num(p.inner_radius, 0.5), outer: num(p.outer_radius, 1) }, material };
  }
  return null;
}

export interface ProcessTemplate {
  direction: number[];
  spread: number;
  velMin: number;
  velMax: number;
  gravity: number[];
  scaleMin: number;
  scaleMax: number;
  scaleCurve: number[] | null;
  alphaCurve: number[] | null;
  angleMin: number;
  angleMax: number;
  shape: number;
  sphereRadius: number;
  box: number[];
  ringRadius: number;
  ringInner: number;
  offset: number[];
  dampMin: number;
  dampMax: number;
  alignY: boolean;
  rotateY: boolean;
  ringAxis: number[];
  ringHeight: number;
  shapeScale: number[];
  radialMin: number;
  radialMax: number;
  alpha: number;
}

export function processTemplate(res: Resolver, ref: unknown, docKey: string): ProcessTemplate {
  const r = res.section(ref, docKey);
  const p = r?.section.properties ?? {};
  const d = r?.doc ?? docKey;
  return {
    direction: vec(p.direction, [1, 0, 0]),
    spread: num(p.spread, 45),
    velMin: num(p.initial_velocity_min, 0),
    velMax: num(p.initial_velocity_max, num(p.initial_velocity_min, 0)),
    gravity: vec(p.gravity, [0, -9.8, 0]),
    scaleMin: num(p.scale_min, 1),
    scaleMax: num(p.scale_max, num(p.scale_min, 1)),
    scaleCurve: res.curve(p.scale_curve, d),
    alphaCurve: res.curve(p.alpha_curve, d),
    angleMin: num(p.angle_min, 0),
    angleMax: num(p.angle_max, num(p.angle_min, 0)),
    shape: num(p.emission_shape, 0),
    sphereRadius: num(p.emission_sphere_radius, 1),
    box: vec(p.emission_box_extents, [1, 1, 1]),
    ringRadius: num(p.emission_ring_radius, 1),
    ringInner: num(p.emission_ring_inner_radius, 0),
    offset: vec(p.emission_shape_offset, [0, 0, 0]),
    dampMin: num(p.damping_min, 0),
    dampMax: num(p.damping_max, num(p.damping_min, 0)),
    alignY: p.particle_flag_align_y === true,
    rotateY: p.particle_flag_rotate_y === true,
    ringAxis: vec(p.emission_ring_axis, [0, 0, 1]),
    ringHeight: num(p.emission_ring_height, 1),
    shapeScale: vec(p.emission_shape_scale, [1, 1, 1]),
    radialMin: num(p.radial_velocity_min, 0),
    radialMax: num(p.radial_velocity_max, num(p.radial_velocity_min, 0)),
    alpha: color(p.color)[3],
  };
}

export interface Track {
  node: string;
  /** emitting (particles), param (a shader uniform, `key` = its name), light (light_multiplier), script (a root script prop). */
  prop: 'emitting' | 'param' | 'light' | 'script' | 'other';
  key: string;
  times: number[];
  values: unknown[];
  discrete: boolean;
}
export interface AnimationTemplate {
  name: string;
  length: number;
  loop: boolean;
  tracks: Track[];
}

export function animation(res: Resolver, docKey: string, library: unknown, name: string): AnimationTemplate | null {
  const lib = res.section(library, docKey);
  const data = (lib?.section.properties._data ?? {}) as Record<string, unknown>;
  const pick = data[name] ?? data.main ?? data.oneshot;
  const a = res.section(pick, lib?.doc ?? docKey);
  if (!a) return null;
  const p = a.section.properties;
  const tracks: Track[] = [];
  for (let i = 0; p[`tracks/${i}/type`] !== undefined; i++) {
    if (p[`tracks/${i}/type`] !== 'value') continue;
    const raw = p[`tracks/${i}/path`];
    const path = String(isTyped(raw) ? raw.args?.[0] ?? '' : raw ?? '');
    const [node, ...rest] = path.split(':');
    const prop = rest.join(':');
    const keys = (p[`tracks/${i}/keys`] ?? {}) as { times?: unknown; values?: unknown[]; update?: number };
    tracks.push({
      node,
      prop: prop === 'emitting' ? 'emitting' : prop.includes('shader_parameter/') ? 'param' : prop === 'light_multiplier' || prop === 'light_energy' ? 'light' : /^(open_amount|shrink_amount|fade_mult|depth_mult)$/.test(prop) ? 'script' : 'other',
      key: prop.includes('shader_parameter/') ? prop.slice(prop.indexOf('shader_parameter/') + 'shader_parameter/'.length) : prop,
      times: vec(keys.times, [0]),
      values: Array.isArray(keys.values) ? keys.values : [],
      discrete: keys.update === 1 || prop === 'emitting',
    });
  }
  return { name: String(p.resource_name ?? name), length: num(p.length, 1), loop: num(p.loop_mode, 0) > 0, tracks };
}

/** Value of a track at time t (discrete: last key at or before t; else linear). */
export function trackAt(tr: Track, t: number): unknown {
  if (!tr.times.length) return undefined;
  let i = 0;
  while (i < tr.times.length - 1 && t >= tr.times[i + 1]) i++;
  const v0 = tr.values[i];
  if (tr.discrete || i >= tr.times.length - 1 || typeof v0 !== 'number' || t <= tr.times[0]) return t < tr.times[0] ? (tr.discrete ? undefined : v0) : v0;
  const v1 = tr.values[i + 1];
  if (typeof v1 !== 'number') return v0;
  const k = (t - tr.times[i]) / Math.max(1e-6, tr.times[i + 1] - tr.times[i]);
  return v0 + (v1 - v0) * k;
}

export interface NodeTemplate {
  name: string;
  type: 'particles' | 'mesh' | 'light';
  matrix: number[];
  shape?: MeshShape;
  material?: MaterialTemplate | null;
  process?: ProcessTemplate;
  amount?: number;
  lifetime?: number;
  oneShot?: boolean;
  explosiveness?: number;
  /** GPUParticles3D transform_align: 1 Z-billboard, 2 Y to velocity, 3 both. */
  align?: number;
  emitting?: boolean;
  localCoords?: boolean;
  lightColor?: number[];
  lightEnergy?: number;
  visible: boolean;
}

export interface EffectTemplate {
  id: string;
  nodes: NodeTemplate[];
  animation: AnimationTemplate | null;
  duration: number;
  colors: number[][];
}

function mul(a: number[], b: number[]) {
  const o = new Array(16).fill(0);
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++) for (let k = 0; k < 4; k++) o[c * 4 + r] += a[k * 4 + r] * b[c * 4 + k];
  return o;
}

/** Build the playable template of one converted effect. */
export function effectTemplate(file: BinbunEffectFile, base?: string): EffectTemplate {
  const res = new Resolver(file, base);
  const doc = file.documents[file.root];
  const nodes: NodeTemplate[] = [];
  const worldOf = new Map<string, number[]>();
  const identity = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  let anim: AnimationTemplate | null = null;
  for (const s of doc?.sections ?? []) {
    if (s.kind !== 'node') continue;
    const name = String(s.attributes.name ?? '');
    const parent = s.attributes.parent === undefined ? null : String(s.attributes.parent);
    const path = parent === null ? '.' : parent === '.' ? name : `${parent}/${name}`;
    const local = s.properties.transform ? transform(s.properties.transform) : identity;
    const world = parent === null ? identity : mul(worldOf.get(parent) ?? identity, local);
    worldOf.set(path, world);
    const p = s.properties;
    const type = String(s.attributes.type ?? '');
    const visible = p.visible !== false;
    if (type === 'AnimationPlayer') {
      const libs = (p.libraries ?? {}) as Record<string, unknown>;
      const lib = libs[''] ?? Object.values(libs)[0];
      anim = animation(res, file.root, lib, file.animation);
    } else if (type === 'GPUParticles3D') {
      const mesh = meshShape(res, p.draw_pass_1, file.root);
      nodes.push({
        name: path,
        type: 'particles',
        matrix: world,
        shape: mesh?.shape ?? { kind: 'quad', w: 1, h: 1, orientation: 2 },
        material: materialTemplate(res, p.material_override ?? mesh?.material, file.root),
        process: processTemplate(res, p.process_material, file.root),
        amount: Math.min(256, Math.max(1, Math.floor(num(p.amount, 8)))),
        lifetime: Math.max(0.05, num(p.lifetime, 1)),
        oneShot: p.one_shot === true,
        explosiveness: num(p.explosiveness, 0),
        align: num(p.transform_align, 0),
        emitting: p.emitting !== false,
        localCoords: p.local_coords === true,
        visible,
      });
    } else if (type === 'MeshInstance3D') {
      const mesh = meshShape(res, p.mesh, file.root);
      if (!mesh) continue;
      nodes.push({ name: path, type: 'mesh', matrix: world, shape: mesh.shape, material: materialTemplate(res, p.material_override ?? p['surface_material_override/0'] ?? mesh.material, file.root), visible });
    } else if (type === 'OmniLight3D') {
      nodes.push({ name: path, type: 'light', matrix: world, lightColor: color(p.light_color), lightEnergy: num(p.light_energy, 1), visible });
    }
  }
  const colors = (file.defaultColors ?? []).map((c) => c.slice(0, 4));
  return { id: file.id, nodes, animation: anim, duration: num(file.duration, anim?.length ?? 1), colors };
}
