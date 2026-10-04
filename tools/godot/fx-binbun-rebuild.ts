/**
 * Rebuilds native Godot 4 scenes/resources from public/fx/binbun/*.json (tools/binbun-port.mjs output, which keeps the
 * parsed Godot resource sections of every effect). The effects are written back out as .tscn / .tres text with the
 * original sub-resources (ParticleProcessMaterial, ShaderMaterial, meshes, curves, FastNoiseLite/Gradient textures,
 * Animation libraries) untouched, so Godot plays them natively. Only these things change:
 *  - ext_resource paths are remapped into res://assets/fx/binbun/ (shaders/ and tex/ come from public/fx/binbun/),
 *  - the missing vendor scripts (vfx_controller.gd, vfx_light.gd, per-pack controllers) become res://fx/dm_fx_*.gd,
 *  - `uid`s are dropped (Godot regenerates them),
 *  - CompressedTexture2D sub-resources that only held a .ctex load_path become ext_resources of the copied PNG.
 *
 * Run: npx vite-node tools/godot/fx-binbun-rebuild.ts   (idempotent; writes godot/assets/fx/binbun/)
 */
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname } from 'node:path';

const SRC = 'public/fx/binbun';
const OUT = 'godot/assets/fx/binbun';
const RES = 'res://assets/fx/binbun';

interface Section {
  kind: string;
  attributes: Record<string, unknown>;
  properties: Record<string, unknown>;
  bakedTexture?: string;
}
interface Doc {
  sections: Section[];
}
interface EffectFile {
  id: string;
  root: string;
  documents: Record<string, Doc>;
  assets: Record<string, { kind: string; output?: string }>;
}

const SCRIPTS: Record<string, string> = {
  'vfx_light.gd': 'res://fx/dm_fx_light.gd',
  'transition_rect.gd': 'res://fx/dm_fx_rect.gd',
};
const scriptFor = (path: string) => SCRIPTS[path.split('/').pop()!] ?? 'res://fx/dm_fx_controller.gd';

/** Doc key (`Pack/assets/...`) → file under OUT/lib. */
const libPath = (key: string) => `lib/${key}`;

type Typed = { $type: string; args: unknown[] };
const isTyped = (v: unknown): v is Typed => !!v && typeof v === 'object' && '$type' in (v as object);
const num = (n: number) => (Number.isFinite(n) ? String(n) : '0');

export function ser(v: unknown, remap?: (t: Typed) => Typed): string {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'boolean') return v ? 'true' : 'false';
  if (typeof v === 'number') return num(v);
  if (typeof v === 'string') return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map((x) => ser(x, remap)).join(', ')}]`;
  if (typeof v === 'object') {
    const o = v as Record<string, unknown>;
    if ('$stringName' in o) return `&${JSON.stringify(o.$stringName)}`;
    if (isTyped(v)) {
      const t = remap ? remap(v) : v;
      if (t.$type === 'SubResource' || t.$type === 'ExtResource' || t.$type === 'NodePath') return `${t.$type}(${JSON.stringify(t.args[0])})`;
      return `${t.$type}(${(t.args as unknown[]).map((x) => ser(x, remap)).join(', ')})`;
    }
    const keys = Object.keys(o);
    if (!keys.length) return '{}';
    return `{\n${keys.map((k) => `${JSON.stringify(k)}: ${ser(o[k], remap)}`).join(',\n')}\n}`;
  }
  return 'null';
}

function attr(k: string, v: unknown): string {
  if (typeof v === 'number') return `${k}=${v}`;
  const s = String(v);
  if (/^(ExtResource|SubResource)\(/.test(s) || s.startsWith('[')) return `${k}=${s}`;
  return `${k}=${JSON.stringify(s)}`;
}

function convertDoc(key: string, doc: Doc, file: EffectFile, ids: { shaders: Set<string>; textures: Set<string> }): string {
  const pack = key.split('/')[0];
  const sections = doc.sections;
  const head = sections.find((s) => s.kind === 'gd_scene' || s.kind === 'gd_resource')!;
  // Sub-resources replaced by an ext_resource: CompressedTexture2D that only carries an imported .ctex path.
  const swapped = new Map<string, string>();
  const extra: string[] = [];
  for (const s of sections) {
    if (s.kind === 'sub_resource' && s.attributes.type === 'CompressedTexture2D') {
      const m = /imported\/(.+?)\.png-/.exec(String(s.properties.load_path ?? ''));
      const asset = m && [GLOBAL_TEX.get(`${m[1]}.png`)].map((o) => [m[1], { output: o }] as const)[0];
      const id = String(s.attributes.id);
      if (asset?.[1].output) {
        swapped.set(id, id);
        ids.textures.add(asset[1].output);
        extra.push(`[ext_resource type="Texture2D" path="${RES}/${asset[1].output}" id=${JSON.stringify(id)}]`);
      }
    }
  }
  // Shader of each ShaderMaterial section (ext id -> shader output) for float-uniform coercion.
  const shaderOut = new Map<string, string>();
  for (const s of sections) {
    if (s.kind !== 'ext_resource' || s.attributes.type !== 'Shader') continue;
    const o = file.assets[`${pack}/${String(s.attributes.path).slice('res://'.length)}`]?.output;
    if (o) shaderOut.set(String(s.attributes.id), o);
  }
  const remap = (t: Typed): Typed => (t.$type === 'SubResource' && swapped.has(String(t.args[0])) ? { $type: 'ExtResource', args: t.args } : t);
  const out: string[] = [];
  const out_push = (l: string) => out.push(l);
  const hAttrs = Object.entries(head.attributes).filter(([k]) => k !== 'uid' && k !== 'load_steps');
  out.push(`[${head.kind}${hAttrs.map(([k, v]) => ' ' + attr(k, v)).join('')}]`);
  out.push('');
  for (const s of sections) {
    if (s.kind === 'ext_resource') {
      const p = String(s.attributes.path);
      const type = String(s.attributes.type);
      const assetKey = `${pack}/${p.slice('res://'.length)}`;
      let path: string;
      if (type === 'Script') path = scriptFor(p);
      else if (file.documents[assetKey]) path = `${RES}/${libPath(assetKey)}`;
      else if (file.assets[assetKey]?.output) {
        path = `${RES}/${file.assets[assetKey].output}`;
        (type === 'Shader' ? ids.shaders : ids.textures).add(file.assets[assetKey].output!);
      } else throw new Error(`unresolved ext_resource ${p} in ${key}`);
      out.push(`[ext_resource type=${JSON.stringify(type)} path=${JSON.stringify(path)} id=${JSON.stringify(String(s.attributes.id))}]`);
    }
  }
  out.push(...extra);
  out.push('');
  for (const s of sections) {
    if (s.kind === 'ext_resource' || s.kind === 'gd_scene' || s.kind === 'gd_resource') continue;
    if (s.kind === 'sub_resource' && swapped.has(String(s.attributes.id))) continue;
    const attrs = Object.entries(s.attributes).filter(([k]) => k !== 'unique_id' && k !== 'uid');
    out.push(`[${s.kind}${attrs.map(([k, v]) => ' ' + attr(k, v)).join('')}]`);
    for (const [k, v] of Object.entries(s.properties)) {
      if (k === 'metadata/_custom_type_script') continue;
      if (k.startsWith('shader_parameter/') && typeof v === 'number') {
        const sh = s.properties.shader;
        const out = isTyped(sh) ? shaderOut.get(String(sh.args[0])) : undefined;
        if (out && uniformTypes(out)[k.slice('shader_parameter/'.length)] === 'float') {
          out_push(`${k} = ${fnum(v)}`);
          continue;
        }
      }
      if (s.attributes.type === 'Animation' && /^tracks\/\d+\/keys$/.test(k) && v && typeof v === 'object' && Array.isArray((v as { values?: unknown }).values)) {
        const kv = v as Record<string, unknown>;
        const trackPath = s.properties[k.replace('/keys', '/path')];
        const prop = isTyped(trackPath) ? String(trackPath.args[0]).split(':').slice(1).join(':') : '';
        if (prop !== 'emitting') {
          const body = Object.keys(kv).map((kk) => `${JSON.stringify(kk)}: ${kk === 'values' ? serFloats(kv[kk]) : ser(kv[kk], remap)}`).join(',\n');
          out_push(`${k} = {\n${body}\n}`);
          continue;
        }
      }
      if (k === '_data' && s.attributes.type === 'Curve' && Array.isArray(v)) {
        // JSON lost int/float: Curve wants float tangents (entries 1 and 2 of every point), ints for the two modes.
        out_push(`_data = [${v.map((x, i) => (typeof x === 'number' && i % 5 >= 1 && i % 5 <= 2 ? (Number.isInteger(x) ? x.toFixed(1) : String(x)) : ser(x, remap))).join(', ')}]`);
        continue;
      }
      if (k === 'script' && isTyped(v)) {
        out_push(`script = ${ser(v, remap)}`);
        continue;
      }
      out_push(`${k} = ${ser(v, remap)}`);
    }
    out.push('');
  }
  return out.join('\n');
}

/** basename.png -> copied tex/<hash>.png, across every effect file (a file may only name a texture by its imported .ctex). */
const GLOBAL_TEX = new Map<string, string>();

/**
 * Adds two hooks to every spatial shader that writes ALPHA: `dm_fade` (per-spawn opacity / end fade, multiplied into ALPHA) and
 * `dm_gain` (global brightness, multiplied into ALBEDO and EMISSION), appended to the end of fragment(). Nothing else changes.
 */
export function injectHooks(src: string): string {
  if (!/shader_type\s+spatial/.test(src)) return src;
  const at = src.search(/void\s+fragment\s*\(\s*\)/);
  if (at < 0) return src;
  const open = src.indexOf('{', at);
  let depth = 0;
  let close = -1;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}' && --depth === 0) {
      close = i;
      break;
    }
  }
  if (close < 0) return src;
  const body = src.slice(open, close);
  const writesAlpha = /\bALPHA\s*[-+*/]?=/.test(body);
  const hook = `\n\t// dm: gain/fade hooks (tools/godot/fx-binbun-rebuild.ts)\n\tALBEDO *= dm_gain;\n\tEMISSION *= dm_gain;\n${writesAlpha ? '\tALPHA *= dm_fade;\n' : ''}`;
  const uniforms = `uniform float dm_gain = 1.0;\n${writesAlpha ? 'uniform float dm_fade = 1.0;\n' : ''}`;
  return src.slice(0, at) + uniforms + src.slice(at, close) + hook + src.slice(close);
}

/** shader output path (shaders/<hash>.gdshader) -> {uniform name: GLSL type}. JSON lost int/float, and Godot reads an int Variant in a float uniform as 0. */
const UNIFORM_TYPES = new Map<string, Record<string, string>>();
function uniformTypes(out: string): Record<string, string> {
  let t = UNIFORM_TYPES.get(out);
  if (!t) {
    t = {};
    const src = readFileSync(`${SRC}/${out}`, 'utf8');
    for (const m of src.matchAll(/^\s*uniform\s+(?:lowp\s+|mediump\s+|highp\s+)?(\w+)\s+(\w+)/gm)) t[m[2]] = m[1];
    UNIFORM_TYPES.set(out, t);
  }
  return t;
}
const fnum = (x: number) => (Number.isInteger(x) ? x.toFixed(1) : String(x));
/** Same as ser() but every number inside is written as a float (Animation value-track keys). */
function serFloats(v: unknown): string {
  if (typeof v === 'number') return fnum(v);
  if (Array.isArray(v)) return `[${v.map(serFloats).join(', ')}]`;
  return ser(v);
}

const write = (path: string, text: string) => {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, text);
};

function main() {
  const index = JSON.parse(readFileSync(`${SRC}/index.json`, 'utf8')) as { effects: { id: string; file: string }[] };
  const ids = { shaders: new Set<string>(), textures: new Set<string>() };
  const manifest: { id: string; scene: string; root: string; kind: string }[] = [];
  let docs = 0;
  for (const e of index.effects) {
    const f = JSON.parse(readFileSync(`${SRC}/${e.file}`, 'utf8')) as EffectFile;
    for (const [k, a] of Object.entries(f.assets)) if (a.kind === 'texture' && a.output) GLOBAL_TEX.set(k.split('/').pop()!, a.output);
  }
  for (const e of index.effects) {
    const file = JSON.parse(readFileSync(`${SRC}/${e.file}`, 'utf8')) as EffectFile;
    for (const [key, doc] of Object.entries(file.documents)) {
      const text = convertDoc(key, doc, file, ids);
      const isRoot = key === file.root;
      const ext = key.endsWith('.tres') ? 'tres' : 'tscn';
      docs++;
      if (!isRoot) write(`${OUT}/${libPath(key)}`, text);
      if (isRoot) {
        write(`${OUT}/${file.id}.${ext}`, text);
        manifest.push({ id: file.id, scene: `${RES}/${file.id}.${ext}`, root: key, kind: ext });
      }
    }
  }
  for (const s of ids.shaders) {
    mkdirSync(`${OUT}/shaders`, { recursive: true });
    writeFileSync(`${OUT}/${s}`, injectHooks(readFileSync(`${SRC}/${s}`, 'utf8')));
  }
  for (const t of ids.textures) {
    mkdirSync(`${OUT}/tex`, { recursive: true });
    copyFileSync(`${SRC}/${t}`, `${OUT}/${t}`);
  }
  writeFileSync(`${OUT}/manifest.json`, JSON.stringify({ effects: manifest.map((m) => ({ id: m.id, scene: m.scene, kind: m.kind })) }, null, 1));
  console.log(`fx-binbun-rebuild: ${manifest.length} effects, ${docs} documents, ${ids.shaders.size} shaders, ${ids.textures.size} textures -> ${OUT}`);
}

main();
