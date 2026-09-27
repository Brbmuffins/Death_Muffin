#!/usr/bin/env node

/**
 * BinbunVFX workstation converter.
 *
 * The raw Godot packs are intentionally gitignored. This tool turns the
 * selected scenes into a portable JSON resource graph, bakes procedural
 * gradients/noise/curves, copies binary textures, and extracts shader source.
 * A later Three.js runtime can work entirely from public/fx/binbun/.
 */
import { createHash } from 'node:crypto';
import { mkdir, readFile, stat, unlink, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import sharp from 'sharp';

const ROOT = process.cwd();
const RAW_ROOT = path.join(ROOT, 'art-src', 'vendor', 'binbun');
const SELECTION_FILE = path.join(ROOT, 'art-manifest', 'binbun-effects.json');
const OUT_ROOT = path.join(ROOT, 'public', 'fx', 'binbun');
const TEX_ROOT = path.join(OUT_ROOT, 'tex');
const SHADER_ROOT = path.join(OUT_ROOT, 'shaders');

const TEXT_RESOURCE_EXTS = new Set(['.tres', '.tscn']);
const SHADER_EXTS = new Set(['.gdshader', '.gdshaderinc']);
const IMAGE_EXTS = new Set(['.png', '.webp', '.jpg', '.jpeg', '.svg']);

function portable(file) {
  return path.relative(ROOT, file).replaceAll('\\', '/');
}

function digest(value, length = 16) {
  return createHash('sha256').update(typeof value === 'string' ? value : JSON.stringify(value)).digest('hex').slice(0, length);
}

function headerAttributes(text) {
  const out = {};
  const re = /([A-Za-z_][\w/]*)=("(?:\\.|[^"])*"|[^\s]+)(?=\s|$)/g;
  for (const match of text.matchAll(re)) {
    const raw = match[2];
    out[match[1]] = raw.startsWith('"') ? JSON.parse(raw) : /^-?\d+(?:\.\d+)?$/.test(raw) ? Number(raw) : raw;
  }
  return out;
}

function balanced(text) {
  let depth = 0;
  let quoted = false;
  let escaped = false;
  for (const ch of text) {
    if (quoted) {
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') quoted = false;
      continue;
    }
    if (ch === '"') quoted = true;
    else if (ch === '(' || ch === '[' || ch === '{') depth++;
    else if (ch === ')' || ch === ']' || ch === '}') depth--;
  }
  return depth <= 0 && !quoted;
}

function tokenize(text) {
  const tokens = [];
  let i = 0;
  while (i < text.length) {
    const ch = text[i];
    if (/\s/.test(ch)) {
      i++;
      continue;
    }
    if ('()[]{},:&'.includes(ch)) {
      tokens.push({ type: ch, value: ch });
      i++;
      continue;
    }
    if (ch === '"') {
      let raw = '"';
      i++;
      while (i < text.length) {
        raw += text[i];
        if (text[i] === '"' && text[i - 1] !== '\\') {
          i++;
          break;
        }
        i++;
      }
      tokens.push({ type: 'string', value: JSON.parse(raw) });
      continue;
    }
    const number = text.slice(i).match(/^[+-]?(?:\d+\.?\d*|\.\d+)(?:e[+-]?\d+)?/i);
    if (number) {
      tokens.push({ type: 'number', value: Number(number[0]) });
      i += number[0].length;
      continue;
    }
    const ident = text.slice(i).match(/^[A-Za-z_][\w.]*/);
    if (ident) {
      tokens.push({ type: 'ident', value: ident[0] });
      i += ident[0].length;
      continue;
    }
    tokens.push({ type: 'raw', value: ch });
    i++;
  }
  return tokens;
}

function parseGodotValue(text) {
  const tokens = tokenize(text);
  let at = 0;
  const peek = () => tokens[at];
  const take = (type) => {
    const token = tokens[at++];
    if (!token || (type && token.type !== type)) throw new Error(`Expected ${type ?? 'value'} in ${text.slice(0, 100)}`);
    return token;
  };
  const parse = () => {
    const token = take();
    if (token.type === 'number' || token.type === 'string') return token.value;
    if (token.type === '&') return { $stringName: take('string').value };
    if (token.type === '[') {
      const values = [];
      while (peek() && peek().type !== ']') {
        values.push(parse());
        if (peek()?.type === ',') take(',');
      }
      take(']');
      return values;
    }
    if (token.type === '{') {
      const value = {};
      while (peek() && peek().type !== '}') {
        const keyValue = parse();
        const key = typeof keyValue === 'string' ? keyValue : keyValue?.$stringName ?? String(keyValue);
        take(':');
        value[key] = parse();
        if (peek()?.type === ',') take(',');
      }
      take('}');
      return value;
    }
    if (token.type === 'ident') {
      if (token.value === 'true') return true;
      if (token.value === 'false') return false;
      if (token.value === 'null') return null;
      if (peek()?.type === '(') {
        take('(');
        const args = [];
        while (peek() && peek().type !== ')') {
          args.push(parse());
          if (peek()?.type === ',') take(',');
        }
        take(')');
        return { $type: token.value, args };
      }
      return { $ident: token.value };
    }
    return token.value;
  };
  try {
    return parse();
  } catch {
    return { $raw: text };
  }
}

export function parseGodotText(text, source = '<memory>') {
  const sections = [];
  let current = null;
  const lines = text.replaceAll('\r\n', '\n').split('\n');
  for (let lineNo = 0; lineNo < lines.length; lineNo++) {
    const line = lines[lineNo].trim();
    if (!line || line.startsWith(';')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      const inside = line.slice(1, -1);
      const kind = inside.match(/^\S+/)?.[0] ?? inside;
      current = { kind, attributes: headerAttributes(inside.slice(kind.length)), properties: {} };
      sections.push(current);
      continue;
    }
    if (!current) continue;
    const equals = line.indexOf('=');
    if (equals < 0) continue;
    const key = line.slice(0, equals).trim();
    let raw = line.slice(equals + 1).trim();
    while (!balanced(raw) && lineNo + 1 < lines.length) raw += `\n${lines[++lineNo].trim()}`;
    current.properties[key] = parseGodotValue(raw);
  }
  return { source, sections };
}

function call(value, type) {
  return value && value.$type === type ? value.args : null;
}

function subResourceId(value) {
  return call(value, 'SubResource')?.[0] ?? null;
}

function propsBySubId(document) {
  return new Map(document.sections.filter((section) => section.kind === 'sub_resource').map((section) => [section.attributes.id, section]));
}

export function curveSamples(section, samples = 64) {
  const data = section?.properties?._data;
  if (!Array.isArray(data)) return null;
  const points = [];
  for (let i = 0; i + 4 < data.length; i += 5) {
    const xy = call(data[i], 'Vector2');
    if (!xy) continue;
    points.push({ x: xy[0], y: xy[1], left: Number(data[i + 1]), right: Number(data[i + 2]) });
  }
  if (!points.length) return null;
  points.sort((a, b) => a.x - b.x);
  const bezier = (a, b, c, d, t) => {
    const u = 1 - t;
    return u * u * u * a + 3 * u * u * t * b + 3 * u * t * t * c + t * t * t * d;
  };
  return Array.from({ length: samples }, (_, index) => {
    const x = index / (samples - 1);
    let b = points.findIndex((point) => point.x >= x);
    if (b <= 0) return points[Math.max(0, b)].y;
    if (b < 0) return points.at(-1).y;
    const a = points[b - 1];
    const end = points[b];
    const width = end.x - a.x;
    const t = width > 0 ? (x - a.x) / width : 0;
    const d = width / 3;
    return bezier(a.y, a.y + d * a.right, end.y - d * end.left, end.y, t);
  });
}

function gradientStops(section) {
  const colorsCall = call(section?.properties?.colors, 'PackedColorArray');
  if (!colorsCall?.length) return [{ at: 0, color: [0, 0, 0, 1] }, { at: 1, color: [1, 1, 1, 1] }];
  const colors = [];
  for (let i = 0; i < colorsCall.length; i += 4) colors.push(colorsCall.slice(i, i + 4).map(Number));
  const offsets = call(section.properties.offsets, 'PackedFloat32Array')?.map(Number) ?? colors.map((_, i) => i / Math.max(1, colors.length - 1));
  return colors.map((color, i) => ({ at: offsets[i] ?? i / Math.max(1, colors.length - 1), color }));
}

function sampleGradient(stops, t, interpolation = 0) {
  t = Math.max(0, Math.min(1, t));
  let index = stops.findIndex((stop) => stop.at >= t);
  if (index <= 0) return stops[Math.max(0, index)].color;
  if (index < 0) return stops.at(-1).color;
  const a = stops[index - 1];
  const b = stops[index];
  if (interpolation === 1) return a.color;
  let k = (t - a.at) / Math.max(1e-6, b.at - a.at);
  if (interpolation === 2) k = k * k * (3 - 2 * k);
  return a.color.map((value, channel) => value + (b.color[channel] - value) * k);
}

function hashNoise(x, y, seed) {
  let n = Math.imul(x | 0, 374761393) + Math.imul(y | 0, 668265263) + Math.imul(seed | 0, 69069);
  n = Math.imul(n ^ (n >>> 13), 1274126177);
  return ((n ^ (n >>> 16)) >>> 0) / 0xffffffff;
}

function smoothNoise(x, y, seed) {
  const x0 = Math.floor(x);
  const y0 = Math.floor(y);
  const tx = x - x0;
  const ty = y - y0;
  const sx = tx * tx * (3 - 2 * tx);
  const sy = ty * ty * (3 - 2 * ty);
  const a = hashNoise(x0, y0, seed);
  const b = hashNoise(x0 + 1, y0, seed);
  const c = hashNoise(x0, y0 + 1, seed);
  const d = hashNoise(x0 + 1, y0 + 1, seed);
  return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy;
}

function noiseSampler(section) {
  const p = section?.properties ?? {};
  const seed = Number(p.seed ?? 0);
  const frequency = Number(p.frequency ?? 0.01);
  const octaves = Math.max(1, Math.min(9, Number(p.fractal_octaves ?? 5)));
  const lacunarity = Number(p.fractal_lacunarity ?? 2);
  const gain = Number(p.fractal_gain ?? 0.5);
  const fractal = Number(p.fractal_type ?? 1);
  return (x, y) => {
    let sum = 0;
    let amp = 1;
    let norm = 0;
    let freq = frequency;
    const count = fractal === 0 ? 1 : octaves;
    for (let octave = 0; octave < count; octave++) {
      let value = smoothNoise(x * freq, y * freq, seed + octave * 1013) * 2 - 1;
      if (fractal === 2) value = 1 - Math.abs(value);
      else if (fractal === 3) value = 1 - Math.abs(((value + 1) % 2) - 1);
      sum += value * amp;
      norm += amp;
      amp *= gain;
      freq *= lacunarity;
    }
    return sum / Math.max(1e-6, norm) * 0.5 + 0.5;
  };
}

async function bakeProcedural(document, outputs) {
  const resources = propsBySubId(document);
  for (const section of document.sections) {
    if (section.kind !== 'sub_resource') continue;
    const type = section.attributes.type;
    if (type === 'Curve') {
      section.bakedSamples = curveSamples(section);
      continue;
    }
    if (!['GradientTexture1D', 'GradientTexture2D', 'NoiseTexture2D'].includes(type)) continue;
    let width = 64;
    let height = type === 'GradientTexture1D' ? 1 : 64;
    let channels = 4;
    let pixels;
    if (type.startsWith('GradientTexture')) {
      const gradient = resources.get(subResourceId(section.properties.gradient));
      const stops = gradientStops(gradient);
      const interpolation = Number(gradient?.properties?.interpolation_mode ?? 0);
      pixels = Buffer.alloc(width * height * channels);
      const from = call(section.properties.fill_from, 'Vector2') ?? [0, 0];
      const to = call(section.properties.fill_to, 'Vector2') ?? [1, 0];
      const fill = Number(section.properties.fill ?? 0);
      const repeat = Number(section.properties.repeat ?? 0);
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const u = width === 1 ? 0 : x / (width - 1);
        const v = height === 1 ? 0 : y / (height - 1);
        const dx = to[0] - from[0];
        const dy = to[1] - from[1];
        let t = fill === 1 ? Math.hypot(u - from[0], v - from[1]) / Math.max(1e-6, Math.hypot(dx, dy)) : fill === 2 ? Math.max(Math.abs(u - from[0]), Math.abs(v - from[1])) / Math.max(1e-6, Math.max(Math.abs(dx), Math.abs(dy))) : ((u - from[0]) * dx + (v - from[1]) * dy) / Math.max(1e-6, dx * dx + dy * dy);
        if (repeat === 1) t -= Math.floor(t);
        else if (repeat === 2) t = 1 - Math.abs((t % 2 + 2) % 2 - 1);
        const color = sampleGradient(stops, t, interpolation);
        const at = (y * width + x) * channels;
        for (let c = 0; c < 4; c++) pixels[at + c] = Math.round(Math.max(0, Math.min(1, color[c] ?? (c === 3 ? 1 : 0))) * 255);
      }
    } else {
      width = Math.max(1, Math.min(512, Number(section.properties.width ?? 512)));
      height = Math.max(1, Math.min(512, Number(section.properties.height ?? 512)));
      channels = 1;
      pixels = Buffer.alloc(width * height);
      const noise = resources.get(subResourceId(section.properties.noise));
      const sample = noiseSampler(noise);
      let min = Infinity;
      let max = -Infinity;
      const values = new Float32Array(width * height);
      for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
        const value = sample(x, y);
        values[y * width + x] = value;
        min = Math.min(min, value);
        max = Math.max(max, value);
      }
      const normalize = section.properties.normalize !== false;
      const invert = section.properties.invert === true;
      for (let i = 0; i < values.length; i++) {
        let value = normalize ? (values[i] - min) / Math.max(1e-6, max - min) : values[i];
        if (invert) value = 1 - value;
        pixels[i] = Math.round(Math.max(0, Math.min(1, value)) * 255);
      }
      section.bakeNotes = ['FastNoiseLite definitions are preserved in JSON; PNG uses the converter\'s deterministic value-noise approximation.'];
    }
    const encoded = await sharp(pixels, { raw: { width, height, channels } }).png({ compressionLevel: 9 }).toBuffer();
    const output = path.join(TEX_ROOT, `${digest(encoded)}.png`);
    await writeFile(output, encoded);
    section.bakedTexture = `tex/${path.basename(output)}`;
    outputs.add(portable(output));
  }
}

function resolveGodotPath(resourcePath, packRoot, ownerFile) {
  if (resourcePath.startsWith('res://assets/BinbunVFX/')) return path.join(packRoot, 'assets', 'BinbunVFX', resourcePath.slice('res://assets/BinbunVFX/'.length));
  if (resourcePath.startsWith('res://')) return path.join(packRoot, resourcePath.slice('res://'.length));
  return path.resolve(path.dirname(ownerFile), resourcePath);
}

async function exists(file) {
  try {
    return (await stat(file)).isFile();
  } catch {
    return false;
  }
}

async function inlineShader(file, packRoot, seen = new Set()) {
  if (seen.has(file)) return `// include cycle skipped: ${portable(file)}`;
  seen.add(file);
  const source = await readFile(file, 'utf8');
  const lines = [];
  for (const line of source.replaceAll('\r\n', '\n').split('\n')) {
    const include = line.match(/^\s*#include\s+"([^"]+)"/);
    if (!include) {
      lines.push(line);
      continue;
    }
    const target = resolveGodotPath(include[1], packRoot, file);
    lines.push(`// begin ${include[1]}`, await inlineShader(target, packRoot, seen), `// end ${include[1]}`);
  }
  return `${lines.map((line) => line.replace(/[ \t]+$/u, '')).join('\n').trimEnd()}\n`;
}

async function convertEffect(entry, outputs, sharedAssets) {
  const sourceFile = path.join(RAW_ROOT, ...entry.source.split('/'));
  if (!(await exists(sourceFile))) throw new Error(`Missing selected source: ${portable(sourceFile)}`);
  const pack = entry.source.split('/')[0];
  const packRoot = path.join(RAW_ROOT, pack);
  const documents = {};
  const assets = {};
  const unsupported = new Set();

  const visit = async (file) => {
    const key = portable(file).replace(/^art-src\/vendor\/binbun\//, '');
    if (documents[key] || assets[key]) return;
    const extension = path.extname(file).toLowerCase();
    if (TEXT_RESOURCE_EXTS.has(extension)) {
      const document = parseGodotText(await readFile(file, 'utf8'), key);
      documents[key] = document;
      await bakeProcedural(document, outputs);
      for (const section of document.sections.filter((candidate) => candidate.kind === 'ext_resource')) {
        const resourcePath = section.attributes.path;
        if (typeof resourcePath !== 'string') continue;
        const target = resolveGodotPath(resourcePath, packRoot, file);
        if (await exists(target)) await visit(target);
        else unsupported.add(`missing:${resourcePath}`);
      }
      return;
    }
    if (SHADER_EXTS.has(extension)) {
      const source = await inlineShader(file, packRoot);
      const hash = digest(source);
      const output = path.join(SHADER_ROOT, `${hash}${extension}`);
      if (!sharedAssets.has(output)) {
        await writeFile(output, source);
        sharedAssets.add(output);
      }
      assets[key] = { kind: 'shader', output: `shaders/${path.basename(output)}`, sha256: digest(source, 64) };
      outputs.add(portable(output));
      return;
    }
    if (IMAGE_EXTS.has(extension)) {
      const data = await readFile(file);
      const hash = digest(data);
      const output = path.join(TEX_ROOT, `${hash}${extension}`);
      if (!sharedAssets.has(output)) {
        await writeFile(output, data);
        sharedAssets.add(output);
      }
      assets[key] = { kind: 'texture', output: `tex/${path.basename(output)}`, sha256: digest(data, 64) };
      outputs.add(portable(output));
      return;
    }
    assets[key] = { kind: 'ignored', extension };
  };

  await visit(sourceFile);
  const rootKey = entry.source;
  const root = documents[rootKey];
  const animation = root.sections.find((section) => section.kind === 'sub_resource' && section.attributes.type === 'Animation' && section.properties.resource_name === entry.anim);
  const colors = root.sections.find((section) => section.kind === 'node' && section.attributes.parent === undefined)?.properties ?? {};
  const summary = {
    particles: root.sections.filter((section) => section.kind === 'node' && section.attributes.type === 'GPUParticles3D').length,
    meshes: root.sections.filter((section) => section.kind === 'node' && section.attributes.type === 'MeshInstance3D').length,
    decals: root.sections.filter((section) => section.kind === 'node' && section.attributes.type === 'Decal').length,
    lights: root.sections.filter((section) => section.kind === 'node' && section.attributes.type === 'OmniLight3D').length,
  };
  const bundle = {
    format: 1,
    id: entry.id,
    source: entry.source,
    animation: entry.anim,
    note: entry.note,
    duration: Number(animation?.properties?.length ?? (entry.anim === 'main' ? 0 : 1)),
    defaultColors: ['primary_color', 'secondary_color', 'tertiary_color'].map((name) => call(colors[name], 'Color')).filter(Boolean),
    summary,
    root: rootKey,
    documents,
    assets,
    unsupported: [...unsupported].sort(),
  };
  const output = path.join(OUT_ROOT, `${entry.id}.json`);
  await writeFile(output, `${JSON.stringify(bundle)}\n`);
  outputs.add(portable(output));
  return { id: entry.id, file: `${entry.id}.json`, ...summary, animation: entry.anim, duration: bundle.duration, unsupported: bundle.unsupported };
}

export async function convert() {
  const selection = JSON.parse(await readFile(SELECTION_FILE, 'utf8'));
  if (!Array.isArray(selection.effects) || !selection.effects.length) throw new Error('binbun-effects.json has no effects');
  await mkdir(TEX_ROOT, { recursive: true });
  await mkdir(SHADER_ROOT, { recursive: true });
  let previousFiles = [];
  try {
    previousFiles = JSON.parse(await readFile(path.join(OUT_ROOT, 'index.json'), 'utf8')).files ?? [];
  } catch {
    /* First conversion. */
  }
  const ids = new Set();
  for (const effect of selection.effects) {
    if (!/^[a-z0-9_]+$/.test(effect.id)) throw new Error(`Invalid effect id: ${effect.id}`);
    if (ids.has(effect.id)) throw new Error(`Duplicate effect id: ${effect.id}`);
    ids.add(effect.id);
  }
  const outputs = new Set();
  const sharedAssets = new Set();
  const effects = [];
  for (const entry of selection.effects) {
    process.stdout.write(`convert ${entry.id}\n`);
    effects.push(await convertEffect(entry, outputs, sharedAssets));
  }
  const index = {
    format: 1,
    source: 'art-manifest/binbun-effects.json',
    effects,
    files: [...outputs].sort(),
    notes: [
      'Portable intermediate generated from workstation-only Godot sources.',
      'Shaders have includes expanded but remain Godot shader language; the Three.js runtime/transpilation is a follow-up.',
      'Procedural resource definitions and sampled curves remain embedded in each effect JSON.',
    ],
  };
  const indexFile = path.join(OUT_ROOT, 'index.json');
  await writeFile(indexFile, `${JSON.stringify(index, null, 2)}\n`);
  for (const stale of previousFiles.filter((file) => !outputs.has(file))) {
    const target = path.resolve(ROOT, stale);
    if (!target.startsWith(`${path.resolve(OUT_ROOT)}${path.sep}`)) throw new Error(`Refusing to remove output outside ${portable(OUT_ROOT)}: ${stale}`);
    try {
      await unlink(target);
    } catch (error) {
      if (error?.code !== 'ENOENT') throw error;
    }
  }
  process.stdout.write(`wrote ${effects.length} effects, ${outputs.size + 1} files to ${portable(OUT_ROOT)}\n`);
  return index;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname.replace(/^\/(\w:)/, '$1'))) {
  convert().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
