#!/usr/bin/env node
/**
 * jobs.mjs - Blender jobs on the game's shipped models (DECISIONS B74, docs/BLENDER-PIPELINE.md "Jobs"). The Discord agent runs it through
 * server/death-muffin/discord-agent/blender-job.sh (sandbox: no network, no keys, only the worktree writable); sessions run it directly.
 *
 *   node tools/blender/jobs.mjs run <job.json> [--shots <dir>]   do the job's steps, record them, update the model's rows, write a preview
 *   node tools/blender/jobs.mjs replay <model>                   redo the recorded steps after the model was rebuilt from its raw files
 *   node tools/blender/jobs.mjs kinds                            what each kind does and takes (tools/blender/kinds.json)
 *
 * A job: {"model": "<id>", "steps": [{"kind": "...", ...params}, ...]} (1 to 8 steps, applied in order). <id> is a folder of
 * client/assets/slice/models/ (its character.glb) or prop_<name> (props/<name>.glb). Steps work on the shipped file, so no raw source
 * (art-src/) is needed; what Blender makes is merged back by merge.mjs, which keeps materials, textures and the other clips as they are.
 * Every step that changed the model is appended to art-manifest/blender/<id>.json (the record; replay redoes it). The model's rows
 * (client/game/view_models.json and the copies in client/data/slice/*.json) get the new clip list, the walk/run strides and the strike
 * timings. Then the model check runs; a failure leaves every file as it was.
 */
import { NodeIO } from '@gltf-transform/core';
import { ALL_EXTENSIONS } from '@gltf-transform/extensions';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';
import { runBlender } from '../blender.mjs';
import { bindHeight, measureFile, strideOfClip } from '../measure-clips.mjs';
import { clipLength, dropClip, onlyClip, pruneAccessors, transplantClip, transplantGeometry, jointNames } from './merge.mjs';
import { packFile } from './pack.mjs';
import { check, kindOf, readGlb } from '../assets/check-models.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const HERE = join(ROOT, 'tools', 'blender');
export const KINDS = JSON.parse(readFileSync(join(HERE, 'kinds.json'), 'utf8')).kinds;
const MODELS = 'client/assets/slice/models';
const RECORDS = 'art-manifest/blender';
const ROW_FILES = ['client/game/view_models.json', 'client/data/slice/enemies.json', 'client/data/slice/npcs.json', 'client/data/slice/hero.json'];
const BIPED_MAP = join(HERE, 'maps', 'ual-to-tripo-biped.json');
const LOOPS = new Set(['idle', 'walk', 'run']);
const STRIKE = /^(attack|cast)\d*$/;   // clips whose row carries [length, second the blow lands]
const ID = /^[a-z0-9_]{3,40}$/;
const CLIP = /^[a-z][a-z0-9_]{0,39}$/;
const BONE = /^[A-Za-z0-9_:.\- ]{1,64}$/;
const LISTING = new Set(['inspect', 'library']);   // kinds that change nothing
const io = new NodeIO().registerExtensions(ALL_EXTENSIONS);

/** The free library (CC0, docs/ANIMATION-SOURCES.md): raw assets stay out of git, so it is read from the shared checkout's art-src/. */
export function libraryFile() {
  if (process.env.DM_BLENDER_LIBRARY) return process.env.DM_BLENDER_LIBRARY;
  const rel = 'art-src/vendor/quaternius-ual/UAL1_Standard.glb';
  try {
    const common = execFileSync('git', ['-C', ROOT, 'rev-parse', '--path-format=absolute', '--git-common-dir'], { encoding: 'utf8' }).trim();
    const shared = join(dirname(common), rel);
    if (existsSync(shared)) return shared;
  } catch { /* not a git checkout */ }
  return join(ROOT, rel);
}

export function modelPath(id) {
  if (!ID.test(id)) throw new Error(`bad model id ${id}`);
  return id.startsWith('prop_') ? `${MODELS}/props/${id.slice(5)}.glb` : `${MODELS}/${id}/character.glb`;
}

function typeOk(spec, v) {
  const n = (x) => typeof x === 'number' && Number.isFinite(x);
  const range = (x) => (spec.min === undefined || x >= spec.min) && (spec.max === undefined || x <= spec.max);
  switch (spec.type) {
    case 'int': return Number.isInteger(v) && range(v);
    case 'number': return n(v) && range(v);
    case 'bool': return typeof v === 'boolean';
    case 'string': return typeof v === 'string' && v.length > 0 && v.length <= (spec.max ?? 64);
    case 'strings': return Array.isArray(v) && v.every((x) => typeof x === 'string' && x.length > 0 && x.length <= 64) && range(v.length);
    case 'map': return v !== null && typeof v === 'object' && !Array.isArray(v) && range(Object.keys(v).length);
    default: return false;
  }
}

/** Every reason the job cannot run (empty = fine). Shape only; what the model holds (bones, clips) is checked by the steps. */
export function validateJob(job, kinds = KINDS) {
  const e = [];
  if (!job || typeof job !== 'object' || Array.isArray(job)) return ['the job must be a JSON object {"model", "steps"}'];
  for (const k of Object.keys(job)) if (!['model', 'steps', 'note'].includes(k)) e.push(`unknown field ${k}`);
  if (typeof job.model !== 'string' || !ID.test(job.model)) e.push('model must be a model id ([a-z0-9_], 3 to 40)');
  if (!Array.isArray(job.steps) || job.steps.length < 1 || job.steps.length > 8) { e.push('steps must be a list of 1 to 8 steps'); return e; }
  const target = typeof job.model === 'string' && job.model.startsWith('prop_') ? 'prop' : 'character';
  job.steps.forEach((s, i) => {
    const at = `step ${i + 1}`;
    const kind = s && kinds[s.kind];
    if (!kind) { e.push(`${at}: unknown kind ${s?.kind} (kinds: ${Object.keys(kinds).join(', ')})`); return; }
    if (!kind.targets.includes(target)) e.push(`${at}: ${s.kind} does not apply to a ${target}`);
    for (const [k, v] of Object.entries(s)) {
      if (k === 'kind') continue;
      const p = kind.params[k];
      if (!p) e.push(`${at}: ${s.kind} takes no ${k} (takes: ${Object.keys(kind.params).join(', ') || 'nothing'})`);
      else if (!typeOk(p, v)) e.push(`${at}: ${k} must be ${p.type}${p.min !== undefined ? ` from ${p.min}` : ''}${p.max !== undefined ? ` up to ${p.max}` : ''}`);
    }
    for (const [k, p] of Object.entries(kind.params)) if (p.req && s[k] === undefined) e.push(`${at}: ${s.kind} needs ${k}`);
  });
  return e;
}

const hex = (s) => /^#[0-9a-fA-F]{6}$/.test(s) ? [1, 3, 5].map((i) => parseInt(s.slice(i, i + 2), 16)) : null;

/** Recolour RGBA pixels in place: sharp's modulate result `mod` blended over `px` by how close each texel is to `only.color`. */
export function maskBlend(px, mod, only) {
  const c = hex(only.color), within = only.within ?? 0.25;
  if (!c || !(within >= 0.05 && within <= 1)) throw new Error('only needs {"color": "#rrggbb", "within": 0.05 to 1}');
  const out = Buffer.from(px);
  for (let i = 0; i < px.length; i += 4) {
    const d = Math.hypot(px[i] - c[0], px[i + 1] - c[1], px[i + 2] - c[2]) / 441.7;
    const w = d <= within * 0.7 ? 1 : d >= within ? 0 : (within - d) / (within * 0.3);
    if (w > 0) for (let k = 0; k < 3; k++) out[i + k] = Math.round(px[i + k] + (mod[i + k] - px[i + k]) * w);
  }
  return out;
}

/** The model rows (objects with this slug and a clip list) in one parsed data file. */
export function rowsOf(data, slug) {
  const out = [];
  const walk = (o) => {
    if (!o || typeof o !== 'object') return;
    if (!Array.isArray(o) && o.slug === slug && Array.isArray(o.clips)) out.push(o);
    for (const v of Object.values(o)) walk(v);
  };
  walk(data);
  return out;
}

/** Bring one row in line: `clips` the model's clip names (old order kept, new ones last), stride and timings for what changed. */
export function updateRow(row, { clips, renamed = {}, stride = {}, timings = {} }) {
  const order = row.clips.map((c) => renamed[c] ?? c).filter((c) => clips.includes(c));
  for (const c of clips) if (!order.includes(c)) order.push(c);
  row.clips = order;
  for (const key of ['stride', 'timings']) {
    const src = row[key] && typeof row[key] === 'object' ? row[key] : {};
    const next = {};
    for (const [k, v] of Object.entries(src)) { const nk = renamed[k] ?? k; if (clips.includes(nk)) next[nk] = v; }
    Object.assign(next, key === 'stride' ? stride : timings);
    row[key] = next;
  }
  return row;
}

/** Write JSON in the file's own shape (one line or indented), so an unchanged row leaves the file byte for byte. */
function writeJsonLike(file, text, data) {
  const indent = /^\{\n( +)/.exec(text)?.[1]?.length;
  const out = (indent ? JSON.stringify(data, null, indent) : JSON.stringify(data)) + (text.endsWith('\n') ? '\n' : '');
  if (out !== text) writeFileSync(file, out);
  return out !== text;
}

async function measureRows(file, id, touched) {
  const stride = {}, timings = {}, notes = [];
  const recipe = join(HERE, 'recipes', `${id}.json`);
  const feet = existsSync(recipe) ? Object.values(JSON.parse(readFileSync(recipe, 'utf8')).legs ?? {}).map((l) => l.paw) : null;
  const h = await bindHeight(file);
  for (const c of touched) {
    if (LOOPS.has(c) && c !== 'idle') {
      const r = await strideOfClip(file, c, feet?.length ? { feet } : {});
      if (r && r.speed > 0 && h > 0) stride[c] = +(r.speed / h).toFixed(3);
      else notes.push(`${c}: no planted feet found, its stride is left as it was`);
    }
  }
  const strikes = touched.filter((c) => STRIKE.test(c));
  if (strikes.length) {
    try {
      for (const m of await measureFile(file)) if (strikes.includes(m.name)) timings[m.name] = [m.dur, m.peakAt];
    } catch { notes.push(`strike timing not measured (${strikes.join(', ')}): this skeleton has no hands the measure knows`); }
  }
  return { stride, timings, notes };
}

async function readClips(file) {
  const doc = await io.read(file);
  return doc.getRoot().listAnimations().map((a) => ({ name: a.getName(), seconds: +clipLength(a).toFixed(2) }));
}

// ---------- the kinds ----------
// Each takes (ctx, step) and returns { touched: [clip names made or changed], geometry: bool, texture: bool, report }.
export const KIND_RUN = {
  async inspect(ctx) {
    const r = runBlender('edit.py', ['inspect', ctx.cur]);
    r.clips = await readClips(ctx.cur);
    if (!ctx.prop) r.bindHeight = +(await bindHeight(ctx.cur)).toFixed(3);
    const recipe = join(HERE, 'recipes', `${ctx.id}.json`);
    r.recipe = existsSync(recipe) ? relative(ROOT, recipe) : 'none yet';
    const { bones = [], clips, ...top } = r;
    console.log(Object.entries(top).map(([k, v]) => `${k}: ${JSON.stringify(v)}`).join('\n'));
    console.log(`clips: ${clips.map((c) => `${c.name} ${c.seconds}s`).join(', ') || 'none'}`);
    if (bones.length) console.log('bones (name < parent  head xyz in Blender armature space, Z up  vertices it moves most  lowest z):');
    for (const b of bones) console.log(`  ${b.name} < ${b.parent ?? '-'}  [${b.head.join(', ')}]  ${b.vertices}${b.lowest !== undefined ? `  ${b.lowest}` : ''}`);
    return { touched: [], report: `inspected (${r.triangles} triangles, ${r.clips.length} clips, ${r.bones?.length ?? 0} bones)` };
  },

  async library() {
    const f = libraryFile();
    if (!existsSync(f)) throw new Error(`the animation library is not on this machine (${f})`);
    const doc = await io.read(f);
    console.log(doc.getRoot().listAnimations().map((a) => `${a.getName()} ${clipLength(a).toFixed(2)}s`).join('\n'));
    return { touched: [], report: 'listed the library' };
  },

  async motion(ctx, step) {
    const recipe = join(HERE, 'recipes', `${ctx.id}.json`);
    if (!existsSync(recipe)) throw new Error(`no recipe tools/blender/recipes/${ctx.id}.json: write it first (inspect lists the bones; docs/BLENDER-PIPELINE.md "procedural and recipes")`);
    // Blender reads the rig and any overlay's base clip (recipe overlays.<name>.base = anim_<game clip>.glb) from one folder.
    const rig = join(ctx.scratch, 'rig');
    mkdirSync(rig, { recursive: true });
    copyFileSync(ctx.cur, join(rig, 'rig.glb'));
    const doc = await io.read(ctx.cur);
    for (const a of doc.getRoot().listAnimations()) await io.write(join(rig, `anim_${a.getName()}.glb`), onlyClip(doc, a.getName()));
    const out = join(ctx.scratch, 'motion');
    mkdirSync(out, { recursive: true });
    const res = runBlender('procedural.py', [join(rig, 'rig.glb'), recipe, out, ...(step.clips ?? [])]) ?? [];
    if (!res.length) throw new Error(`the recipe makes none of ${step.clips?.join(', ') || 'its clips'}`);
    const names = [];
    for (const r of res) {
      if (!CLIP.test(r.clip)) throw new Error(`recipe clip name ${r.clip} is not a game clip name`);
      await packFile(r.file, r.clip);
      transplantClip(doc, await io.read(r.file), r.clip);
      names.push(r.clip);
    }
    await pruneAccessors(doc);
    await io.write(ctx.cur, doc);
    return { touched: names, report: `made ${res.map((r) => `${r.clip} (${r.duration ?? r.seconds}s${r.stanceSpeed ? `, ground ${r.stanceSpeed}/s` : ''})`).join(', ')}` };
  },

  async rigfix(ctx) {
    const recipe = join(HERE, 'recipes', `${ctx.id}.json`);
    if (!existsSync(recipe) || !JSON.parse(readFileSync(recipe, 'utf8')).rigfix) throw new Error(`tools/blender/recipes/${ctx.id}.json has no "rigfix" section`);
    const doc = await io.read(ctx.cur);
    const have = new Set(jointNames(doc));
    const twice = JSON.parse(readFileSync(recipe, 'utf8')).rigfix.legs.flatMap((l) => l.names).filter((n) => have.has(n));
    if (twice.length) throw new Error(`the model already has ${twice.join(', ')}: its rigfix is done`);
    const out = join(ctx.scratch, 'rigfixed.glb');
    const res = runBlender('rigfix.py', [ctx.cur, recipe, out]);
    const g = transplantGeometry(doc, await io.read(out));
    await pruneAccessors(doc);
    await io.write(ctx.cur, doc);
    return { touched: [], geometry: true, report: `added bones ${g.addedBones.join(', ') || '(none new)'}; re-weighted ${res.map((r) => `${r.leg} ${r.vertices}`).join(', ')}` };
  },

  async retarget(ctx, step) {
    const map = JSON.parse(readFileSync(BIPED_MAP, 'utf8'));
    const doc = await io.read(ctx.cur);
    const joints = new Set(jointNames(doc));
    const missing = map.bones.map((b) => b.dst).filter((b) => !joints.has(b));
    if (missing.length) throw new Error(`retarget needs the shared Tripo biped skeleton; this model lacks ${missing.slice(0, 6).join(', ')}`);
    const clips = {};
    for (const [src, spec] of Object.entries(step.clips)) {
      const ok = spec && typeof spec === 'object' && CLIP.test(spec.name ?? '') &&
        Object.keys(spec).every((k) => ['name', 'loop', 'sequence', 'inPlace', 'trim', 'speed'].includes(k)) &&
        (spec.loop === undefined || typeof spec.loop === 'boolean') && (spec.inPlace === undefined || typeof spec.inPlace === 'boolean') &&
        (spec.sequence === undefined || (Array.isArray(spec.sequence) && spec.sequence.length <= 4 && spec.sequence.every((x) => typeof x === 'string'))) &&
        (spec.trim === undefined || (Array.isArray(spec.trim) && spec.trim.length === 2 && spec.trim.every((x) => typeof x === 'number' && x >= 0 && x < 60))) &&
        (spec.speed === undefined || (typeof spec.speed === 'number' && spec.speed >= 0.25 && spec.speed <= 4));
      if (!ok) throw new Error(`clip ${src}: give {"name": game clip name, "loop"?, "sequence"?, "inPlace"?, "trim"? [from s, to s], "speed"? 0.25-4}`);
      clips[src] = spec;
    }
    map.clips = clips;
    const mapFile = join(ctx.scratch, 'map.json');
    writeFileSync(mapFile, JSON.stringify(map));
    const lib = libraryFile();
    if (!existsSync(lib)) throw new Error(`the animation library is not on this machine (${lib})`);
    const out = join(ctx.scratch, 'retarget');
    mkdirSync(out, { recursive: true });
    const res = runBlender('retarget.py', [lib, ctx.cur, mapFile, out]) ?? [];
    if (res.length !== Object.keys(clips).length) throw new Error('the library lacks one of those clips (the library kind lists them)');
    for (const r of res) {
      await packFile(r.file, r.clip);
      transplantClip(doc, await io.read(r.file), r.clip);
    }
    await pruneAccessors(doc);
    await io.write(ctx.cur, doc);
    return { touched: res.map((r) => r.clip), report: `retargeted ${res.map((r) => `${r.source} -> ${r.clip} (${r.seconds}s)`).join(', ')}` };
  },

  async cleanup(ctx, step) {
    if (!CLIP.test(step.clip)) throw new Error(`bad clip name ${step.clip}`);
    const doc = await io.read(ctx.cur);
    if (!doc.getRoot().listAnimations().some((a) => a.getName() === step.clip)) throw new Error(`the model has no clip ${step.clip}`);
    if (!step.loop && !step.drift && !step.footLock) throw new Error('cleanup needs at least one of loop, drift, footLock');
    // Blender gets a file holding only this clip, so it cannot fix the wrong one.
    const one = join(ctx.scratch, `one_${step.clip}.glb`), out = join(ctx.scratch, `clean_${step.clip}.glb`);
    await io.write(one, onlyClip(doc, step.clip));
    const args = [one, step.clip, out];
    if (step.loop) args.push('--loop');
    if (step.drift) args.push('--drift');
    if (step.footLock) {
      args.push('--foot-lock');
      const recipe = join(HERE, 'recipes', `${ctx.id}.json`);
      if (existsSync(recipe)) args.push('--recipe', recipe);
    }
    const res = runBlender('cleanup.py', args);
    await packFile(out, step.clip);
    transplantClip(doc, await io.read(out), step.clip);
    await pruneAccessors(doc);
    await io.write(ctx.cur, doc);
    return { touched: [step.clip], report: `cleaned ${step.clip}: seam ${res.seamBefore} -> ${res.seamAfter}${res.driftRemoved ? `, drift removed ${res.driftRemoved.join('/')}` : ''}` };
  },

  async clips(ctx, step) {
    const doc = await io.read(ctx.cur);
    const have = () => doc.getRoot().listAnimations().map((a) => a.getName());
    const done = [];
    for (const d of step.drop ?? []) {
      if (!have().includes(d)) throw new Error(`the model has no clip ${d}`);
      dropClip(doc, d); done.push(`dropped ${d}`);
    }
    for (const [from, to] of Object.entries(step.rename ?? {})) {
      if (!have().includes(from)) throw new Error(`the model has no clip ${from}`);
      if (typeof to !== 'string' || !CLIP.test(to)) throw new Error(`rename ${from}: ${to} is not a game clip name`);
      if (have().includes(to)) throw new Error(`rename ${from}: the model already has ${to} (drop it first)`);
      doc.getRoot().listAnimations().find((a) => a.getName() === from).setName(to);
      ctx.renamed[from] = to; done.push(`${from} -> ${to}`);
    }
    if (!done.length) throw new Error('clips needs rename or drop');
    await pruneAccessors(doc);
    await io.write(ctx.cur, doc);
    return { touched: Object.values(step.rename ?? {}), report: done.join(', ') };
  },

  async recolor(ctx, step) {
    if (step.hue === undefined && step.saturation === undefined && step.brightness === undefined) throw new Error('recolor needs hue, saturation or brightness');
    const doc = await io.read(ctx.cur);
    const texs = [...new Set(doc.getRoot().listMaterials().map((m) => m.getBaseColorTexture()).filter(Boolean))];
    if (!texs.length) throw new Error('the model has no colour texture');
    for (const t of texs) {
      const img = sharp(Buffer.from(t.getImage()));
      const { data, info } = await img.clone().ensureAlpha().raw().toBuffer({ resolveWithObject: true });
      const mod = await sharp(data, { raw: info }).modulate({ hue: step.hue ?? 0, saturation: step.saturation ?? 1, brightness: step.brightness ?? 1 }).raw().toBuffer();
      const px = step.only ? maskBlend(data, mod, step.only) : mod;
      const webp = await sharp(px, { raw: info }).webp({ quality: 86 }).toBuffer();
      // A new image name: Godot extracts textures by name (character_<name>.webp), so the old extracted file goes and a fresh one is imported.
      const old = t.getName();
      ctx.retiredTextures.push(old);
      t.setImage(new Uint8Array(webp)).setMimeType('image/webp').setName(`${old.split('_')[0] || 'Color'}_${createHash('sha256').update(webp).digest('hex').slice(0, 12)}`);
    }
    await io.write(ctx.cur, doc);
    return { touched: [], texture: true, report: `recoloured ${texs.length} texture(s) (hue ${step.hue ?? 0}, saturation x${step.saturation ?? 1}, brightness x${step.brightness ?? 1}${step.only ? `, near ${step.only.color}` : ''})` };
  },

  async decimate(ctx, step) { return geometryEdit(ctx, ['decimate', String(step.triangles)], (r) => `decimated ${r.triangles[0]} -> ${r.triangles[1]} triangles`); },
  async reshape(ctx, step) {
    if (!BONE.test(step.bone)) throw new Error(`bad bone name ${step.bone}`);
    return geometryEdit(ctx, ['reshape', step.bone, String(step.scale), step.children === false ? '0' : '1'], (r) => `scaled ${r.vertices} vertices x${step.scale} around ${step.bone}`);
  },
  async remove(ctx, step) {
    for (const b of step.bones) if (!BONE.test(b)) throw new Error(`bad bone name ${b}`);
    return geometryEdit(ctx, ['remove', step.children === false ? '0' : '1', ...step.bones], (r) => `removed ${r.faces[0] - r.faces[1]} faces (${r.bones.join(', ')})`);
  },
};

async function geometryEdit(ctx, args, say) {
  if (ctx.prop && args[0] !== 'decimate') throw new Error(`${args[0]} needs a rigged model`);
  const out = join(ctx.scratch, `${args[0]}.glb`);
  const [op, ...rest] = args;
  const r = runBlender('edit.py', [op, ctx.cur, out, ...rest]);
  const doc = await io.read(ctx.cur);
  const src = await io.read(out);
  if (ctx.prop) replacePropGeometry(doc, src);
  else transplantGeometry(doc, src);
  await pruneAccessors(doc);
  await io.write(ctx.cur, doc);
  return { touched: [], geometry: true, report: say(r) };
}

/** A prop (one unskinned mesh): its primitives' vertex data and indices from Blender, materials kept. */
function replacePropGeometry(dst, src) {
  const dm = dst.getRoot().listMeshes(), sm = src.getRoot().listMeshes();
  if (dm.length !== 1 || sm.length !== 1) throw new Error('a prop edit needs one mesh');
  const dp = dm[0].listPrimitives(), sp = sm[0].listPrimitives();
  if (dp.length !== sp.length) throw new Error(`the prop has ${dp.length} parts, Blender's ${sp.length}`);
  const buffer = dst.getRoot().listBuffers()[0];
  dp.forEach((p, k) => {
    for (const sem of p.listSemantics()) if (!sp[k].getAttribute(sem)) p.setAttribute(sem, null);
    for (const sem of sp[k].listSemantics()) { const a = sp[k].getAttribute(sem); p.setAttribute(sem, dst.createAccessor().setType(a.getType()).setArray(a.getArray().slice()).setBuffer(buffer)); }
    const si = sp[k].getIndices();
    p.setIndices(si ? dst.createAccessor().setType('SCALAR').setArray(si.getArray().slice()).setBuffer(buffer) : null);
  });
  // Blender's node transform is baked differently for an unskinned mesh: the edit keeps Blender's vertices in the original node's space
  // only when that node has no transform of its own.
  const n = dst.getRoot().listNodes().find((x) => x.getMesh() === dm[0]);
  const t = n.getTranslation(), r = n.getRotation(), s = n.getScale();
  if (t.some((v) => Math.abs(v) > 1e-6) || Math.abs(r[3] - 1) > 1e-6 || s.some((v) => Math.abs(v - 1) > 1e-6)) throw new Error('this prop\'s mesh node has its own transform; a decimate would misplace it');
}

/** The model rules of tools/assets/check-models.mjs, on the job's result under the shipped file's name (which decides its kind). */
function checkModel(rel, file) {
  const model = readGlb(readFileSync(file));
  const refFile = join(ROOT, MODELS, 'hero_gravecaller/character.glb');
  const ref = existsSync(refFile) ? readGlb(readFileSync(refFile)).joints : null;
  return check(rel, model, kindOf(rel, new Set()).kind, ref);
}

// ---------- the preview sheet ----------
async function sheet(rows, title, out) {
  // rows: [{ label, files: [png] }]; one row each, the label on a strip above it
  const imgs = await Promise.all(rows.map(async (r) => Promise.all(r.files.map(async (f) => ({ f, m: await sharp(f).metadata() })))));
  const w = Math.max(...imgs.map((r) => r.reduce((n, x) => n + x.m.width, 0)));
  const head = 30;
  const h = imgs.reduce((n, r) => n + head + Math.max(...r.map((x) => x.m.height)), 0);
  const parts = [];
  let y = 0;
  const esc = (s) => String(s).replace(/[<>&"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', '"': '&quot;' })[c]);
  imgs.forEach((r, i) => {
    const text = `${title}   ${rows[i].label}`;
    parts.push({ input: Buffer.from(`<svg width="${w}" height="${head}"><text x="${w - 10}" y="21" text-anchor="end" font-family="DejaVu Sans" font-weight="bold" font-size="17" fill="#e6dcff">${esc(text)}</text></svg>`), left: 0, top: y });
    let x = 0;
    for (const im of r) { parts.push({ input: im.f, left: x, top: y + head }); x += im.m.width; }
    y += head + Math.max(...r.map((q) => q.m.height));
  });
  await sharp({ create: { width: w, height: h, channels: 3, background: { r: 24, g: 22, b: 28 } } }).composite(parts).png().toFile(out);
}

async function preview(ctx, before, touched, changedLook, shots) {
  const dir = join(ctx.scratch, 'preview');
  const name = `blender-${ctx.id.replace(/_/g, '-')}`.slice(0, 39);
  const out = join(shots, `${name}.png`);
  mkdirSync(shots, { recursive: true });
  if (touched.length && !ctx.prop) {
    const clips = [...new Set(touched)].slice(0, 4);
    const frames = 6;
    runBlender('preview.py', ['clips', dir, ctx.cur, String(frames), ...clips]);
    await sheet(clips.map((c, n) => ({ label: `${c}: ${frames} moments`, files: Array.from({ length: frames }, (_, i) => join(dir, `clip_${n}_${i}.png`)) })), ctx.id, out);
  } else if (changedLook) {
    runBlender('preview.py', ['views', dir, before, ctx.cur]);
    await sheet(['before', 'after'].map((l) => ({ label: `${l}: front · side · back`, files: ['front', 'side', 'back'].map((v) => join(dir, `${l}_${v}.png`)) })), ctx.id, out);
  } else return null;
  return out;
}

// ---------- running a job ----------
export async function runJob(job, { shots = null, record = true, quiet = false } = {}) {
  const errors = validateJob(job);
  if (errors.length) throw new Error(errors.join('\n'));
  const rel = modelPath(job.model);
  const file = join(ROOT, rel);
  if (!existsSync(file) || lstatSync(file).isSymbolicLink()) throw new Error(`no model ${job.model} at ${rel}`);
  const scratch = mkdtempSync(join(process.env.DM_BLENDER_SCRATCH || tmpdir(), 'dmblender-'));
  const ctx = { id: job.model, prop: job.model.startsWith('prop_'), cur: join(scratch, 'model.glb'), scratch, renamed: {}, retiredTextures: [] };
  const before = join(scratch, 'before.glb');
  copyFileSync(file, ctx.cur);
  copyFileSync(file, before);
  const touched = [], done = [];
  let geometry = false, texture = false;
  try {
    for (const [i, step] of job.steps.entries()) {
      const r = await KIND_RUN[step.kind](ctx, step);
      touched.push(...r.touched);
      geometry ||= !!r.geometry; texture ||= !!r.texture;
      if (!quiet) console.log(`STEP ${i + 1} ${step.kind}: ${r.report}`);
      if (!LISTING.has(step.kind)) done.push(step);
    }
    if (!done.length) return { changed: false };
    // the model check before anything is written back
    const verdict = checkModel(rel, ctx.cur);
    if (verdict.errors.length) throw new Error(`the result breaks the model rules, nothing was written: ${verdict.errors.join('; ')}`);
    if (!quiet) for (const w of verdict.warnings) console.log(`WARN ${w}`);
    // measured and pictured on the result, before anything is written back
    const clipNames = (await readClips(ctx.cur)).map((c) => c.name);
    const live = [...new Set(touched.filter((c) => clipNames.includes(c)))];
    const m = ctx.prop || !live.length ? { stride: {}, timings: {}, notes: [] } : await measureRows(ctx.cur, ctx.id, live);
    let pic = null;
    if (shots) {
      try { pic = await preview(ctx, before, live, geometry || texture, shots); } catch (e) { m.notes.push(`no preview picture (${e.message.split('\n')[0]}): the job itself is done`); }
    }
    const changed = [rel];
    copyFileSync(ctx.cur, file);
    for (const old of ctx.retiredTextures) {
      for (const f of [`${basename(rel, '.glb')}_${old}.webp`, `${basename(rel, '.glb')}_${old}.webp.import`]) {
        const p = join(dirname(file), f);
        if (existsSync(p)) { rmSync(p); changed.push(relative(ROOT, p) + ' (deleted; Godot extracts the new texture)'); }
      }
    }
    // the model's rows
    let rows = 0;
    if (!ctx.prop) {
      for (const f of ROW_FILES) {
        const p = join(ROOT, f);
        if (!existsSync(p)) continue;
        const text = readFileSync(p, 'utf8');
        const data = JSON.parse(text);
        const found = rowsOf(data, ctx.id);
        if (!found.length) continue;
        for (const row of found) updateRow(row, { clips: clipNames, renamed: ctx.renamed, stride: m.stride, timings: m.timings });
        rows += found.length;
        if (writeJsonLike(p, text, data)) changed.push(f);
      }
    }
    if (record) {
      const rp = join(ROOT, RECORDS, `${ctx.id}.json`);
      const rec = existsSync(rp) ? JSON.parse(readFileSync(rp, 'utf8')) : { model: ctx.id, file: rel, steps: [] };
      const date = new Date().toISOString().slice(0, 10);
      for (const s of done) rec.steps.push({ ...s, date });
      mkdirSync(dirname(rp), { recursive: true });
      writeFileSync(rp, JSON.stringify(rec, null, 2) + '\n');
      changed.push(relative(ROOT, rp));
    }
    if (!quiet) {
      console.log(`CLIPS ${clipNames.join(', ')}`);
      if (Object.keys(m.stride).length) console.log(`STRIDE ${JSON.stringify(m.stride)} (body heights per second at normal speed)`);
      if (Object.keys(m.timings).length) console.log(`TIMINGS ${JSON.stringify(m.timings)} ([length s, blow lands s])`);
      for (const n of m.notes) console.log(`NOTE ${n}`);
      if (!ctx.prop && !rows && live.length) console.log(`NOTE ${ctx.id} has no model row yet: when you add it, give it these clips${Object.keys(m.stride).length ? ' and strides' : ''}`);
      console.log(`CHANGED ${changed.join(', ')}`);
    }
    if (pic && !quiet) console.log(`PREVIEW ${pic}`);
    return { changed: true, files: changed, preview: pic };
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
}

/** Redo a model's recorded steps (after tools/build-characters.mjs rebuilt it from its raw files, which drops them). */
export async function replay(id) {
  const rp = join(ROOT, RECORDS, `${id}.json`);
  if (!existsSync(rp)) { console.log(`no record for ${id}: nothing to replay`); return; }
  const rec = JSON.parse(readFileSync(rp, 'utf8'));
  for (const [i, s] of rec.steps.entries()) {
    const { date, ...step } = s;
    await runJob({ model: id, steps: [step] }, { record: false, quiet: true });
    console.log(`REPLAYED ${i + 1}/${rec.steps.length} ${step.kind} (${date})`);
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [cmd, arg, ...rest] = process.argv.slice(2);
  try {
    if (cmd === 'run' && arg) {
      const si = rest.indexOf('--shots');
      const job = JSON.parse(readFileSync(resolve(arg), 'utf8'));
      const r = await runJob(job, { shots: si >= 0 ? resolve(rest[si + 1]) : null });
      if (!r.changed) console.log('DONE (nothing changed)');
      else console.log(`DONE: commit the changed files${r.preview ? '; the preview is posted after your turn' : ''}`);
    } else if (cmd === 'replay' && arg) await replay(arg);
    else if (cmd === 'kinds') for (const [k, v] of Object.entries(KINDS)) console.log(`${k} {${Object.entries(v.params).map(([p, s]) => `${p}${s.req ? '' : '?'}: ${s.type}`).join(', ')}}\n  ${v.what}`);
    else { console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('*/')[0].replace(/^[\s\S]*?\/\*\*/, '')); process.exit(cmd ? 2 : 0); }
  } catch (e) {
    console.error(`FAILED: ${e.message}`);
    process.exit(1);
  }
}
