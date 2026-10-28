#!/usr/bin/env node
/**
 * make.mjs - a game model from a ComfyUI run (ASSET_PIPELINE.md "Image to model"): the run's detailed model through the Blender steps its record lists.
 *
 *   node tools/blender/make.mjs build <id> [--from N]          do the record's steps on art-src/comfy/<id>/<run.file>, write the record's game file
 *   node tools/blender/make.mjs fit <id> --ref <model.glb> [--tilt-min 15] [--max-tilt 180]
 *                                                              find the game placement by fitting the detailed model onto an older model of the same
 *                                                              subject (a Tripo or live one: similarity ICP from 8 turns); written as the record's frame
 *   node tools/blender/make.mjs fit <id> --stand [--yaw 0] [--height 0] [--max-tilt 60]
 *                                                              a new subject: stood on the side it rests on, turned yaw degrees, height metres tall
 *                                                              (either way the placed model is written to work/fit.glb, to look at)
 *   node tools/blender/make.mjs kinds                          what each step does and takes (tools/blender/comfy/kinds.json)
 *
 * The record art-manifest/comfy/<id>.json: {id, concept?, picture, run: {label, model, faces, texture, seed, settings?, file, ...}, frame?: {matrix},
 * steps: [{kind, ...params}] (1 to 8), game: "game.glb", tris?}. Steps that work in the game placement (bend, finish's boxes, place) need the frame.
 * Each step's output is kept in art-src/comfy/<id>/work/ (build --from N starts at step N from the last good one); a step's report is beside it.
 * Blender: $BLENDER or /home/ubuntu/tools/blender/blender (tools/blender.mjs findBlender); the xatlas packer beside it (tools/blender/comfy/setup.sh).
 */
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runBlender } from '../blender.mjs';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const KINDS = JSON.parse(readFileSync(join(ROOT, 'tools', 'blender', 'comfy', 'kinds.json'), 'utf8')).kinds;
const ID = /^[a-z0-9_]{3,40}$/;
const FILE = /^[a-z0-9][a-z0-9._-]{0,60}\.glb$/;
const RECORD_FIELDS = ['id', 'concept', 'picture', 'run', 'frame', 'steps', 'game', 'tris', 'note'];
const BIPED_TEMPLATE = 'client/assets/slice/models/hero_gravecaller/character.glb';   // the heroes' skeleton: names, parents, each bone's axes

export const recordPath = (id) => join(ROOT, 'art-manifest', 'comfy', `${id}.json`);
export const rawDir = (id) => join(ROOT, 'art-src', 'comfy', id);

function typeOk(p, v) {
  const num = (x) => typeof x === 'number' && Number.isFinite(x) && (p.min === undefined || x >= p.min) && (p.max === undefined || x <= p.max);
  switch (p.type) {
    case 'int': return Number.isInteger(v) && num(v);
    case 'number': return num(v);
    case 'bool': return typeof v === 'boolean';
    case 'enum': return p.values.includes(v);
    case 'vec': return Array.isArray(v) && v.length === p.len && v.every(num);
    case 'boxes': return Array.isArray(v) && v.length >= 1 && v.length <= 8 && v.every((b) => Array.isArray(b) && b.length === 6 && b.every((x) => typeof x === 'number' && x >= 0 && x <= 1) && b[0] < b[3] && b[1] < b[4] && b[2] < b[5]);
    case 'map': return !!v && typeof v === 'object' && !Array.isArray(v) && fieldErrors(p.fields, v, '').length === 0;
    default: return false;
  }
}

const want = (p) => p.type === 'enum' ? `one of ${p.values.join(', ')}` : p.type === 'vec' ? `${p.len} numbers` : p.type === 'map' ? `{${Object.keys(p.fields).join(', ')}}` : p.type;

function fieldErrors(params, obj, at) {
  const e = [];
  for (const [k, v] of Object.entries(obj)) {
    if (k === 'kind' && at) continue;
    const p = params[k];
    if (!p) e.push(`${at}takes no ${k} (takes: ${Object.keys(params).join(', ') || 'nothing'})`);
    else if (!typeOk(p, v)) e.push(`${at}${k} must be ${want(p)}${p.min !== undefined ? ` from ${p.min}` : ''}${p.max !== undefined ? ` up to ${p.max}` : ''}`);
  }
  for (const [k, p] of Object.entries(params)) if (p.req && obj[k] === undefined) e.push(`${at}needs ${k}`);
  return e;
}

/** What is wrong with a record (empty: nothing). */
export function validateRecord(rec, id) {
  const e = [];
  if (!rec || typeof rec !== 'object' || Array.isArray(rec)) return ['the record must be a JSON object'];
  for (const k of Object.keys(rec)) if (!RECORD_FIELDS.includes(k)) e.push(`unknown field ${k}`);
  if (rec.id !== id || !ID.test(String(id))) e.push(`id must be "${id}" ([a-z0-9_], 3 to 40, the file's name)`);
  if (!rec.run || typeof rec.run !== 'object' || !FILE.test(String(rec.run.file))) e.push('run.file must be the run\'s model file name (<label>.glb)');
  if (!FILE.test(String(rec.game))) e.push('game must be a .glb file name (game.glb)');
  if (rec.game === rec.run?.file) e.push('game must not be the run\'s own file');
  const m = rec.frame?.matrix;
  if (rec.frame !== undefined && !(Array.isArray(m) && m.length === 4 && m.every((r) => Array.isArray(r) && r.length === 4 && r.every(Number.isFinite)))) e.push('frame.matrix must be 4 rows of 4 numbers');
  if (!Array.isArray(rec.steps) || rec.steps.length < 1 || rec.steps.length > 8) { e.push('steps must be a list of 1 to 8 steps'); return e; }
  const kinds = rec.steps.map((s) => s?.kind);
  rec.steps.forEach((s, i) => {
    const at = `step ${i + 1}`;
    const kind = s && KINDS[s.kind];
    if (!kind) { e.push(`${at}: unknown kind ${s?.kind} (kinds: ${Object.keys(KINDS).join(', ')})`); return; }
    e.push(...fieldErrors(kind.params, s, `${at}: ${s.kind} `));
    if (['bend', 'place'].includes(s.kind) && !rec.frame) e.push(`${at}: ${s.kind} works in the game placement: find the frame first (make.mjs fit)`);
    if (s.kind === 'finish' && (s.keep || s.metalRegions) && !rec.frame) e.push(`${at}: finish's boxes are in the game placement: find the frame first (make.mjs fit)`);
    if (s.kind === 'rig' && i !== rec.steps.length - 1) e.push(`${at}: rig must be the last step`);
    if (['grime', 'rig'].includes(s.kind) && !kinds.slice(0, i).includes('place')) e.push(`${at}: ${s.kind} needs the game placement: a place step before it`);
    if (s.kind === 'bend' && kinds.indexOf('finish') !== -1 && kinds.indexOf('finish') < i) e.push(`${at}: bend works on the detailed model: before finish`);
  });
  if (kinds.filter((k) => k === 'finish').length !== 1) e.push('steps need exactly one finish (the game mesh)');
  return e;
}

export function readRecord(id) {
  if (!ID.test(String(id))) throw new Error(`bad id ${id}`);
  const p = recordPath(id);
  if (!existsSync(p)) throw new Error(`no record art-manifest/comfy/${id}.json`);
  const rec = JSON.parse(readFileSync(p, 'utf8'));
  return rec;
}

const writeRecord = (rec) => writeFileSync(recordPath(rec.id), JSON.stringify(rec, null, 2) + '\n');

/** The arguments a step's script takes after the input and output files. */
function stepArgs(step, frameFile, work, n) {
  const report = join(work, `${n}-${step.kind}.json`);
  if (step.kind === 'bend') {
    const cfg = join(work, `${n}-bend.cfg.json`);
    writeFileSync(cfg, JSON.stringify({ frame: frameFile, pivot: step.pivot, axis: step.axis, angle: step.angle, blend: step.blend, ...(step.above !== undefined ? { above: step.above } : {}) }));
    return [cfg];
  }
  if (step.kind === 'finish') {
    const a = [String(step.triangles), '--tex', String(step.texture), '--metal', step.metal, '--report', report];
    for (const [k, f] of [['cells', '--cells'], ['angle', '--angle'], ['calm', '--calm'], ['reach', '--reach']]) if (step[k] !== undefined) a.push(f, String(step[k]));
    if (step.hard) a.push('--hard');
    if (step.keep) { const f = join(work, `${n}-keep.json`); writeFileSync(f, JSON.stringify({ ...step.keep, frame: frameFile })); a.push('--keep-regions', f); }
    if (step.metalRegions) { const f = join(work, `${n}-metal.json`); writeFileSync(f, JSON.stringify(step.metalRegions)); a.push('--metal-regions', f); }
    return a;
  }
  if (step.kind === 'place') return [frameFile];
  if (step.kind === 'grime') {
    const a = ['--report', report];
    for (const k of ['amount', 'film', 'crevice', 'stain', 'ground', 'top', 'age', 'seed']) if (step[k] !== undefined) a.push(`--${k}`, String(step[k]));
    return a;
  }
  if (step.kind === 'rig') {
    if (step.body === 'quad') return ['--report', report, ...(step.legTop !== undefined ? ['--leg-top', String(step.legTop)] : [])];
    if (step.body === 'legs') return ['--report', report];
    return ['--report', report];
  }
  throw new Error(`no arguments for ${step.kind}`);
}

export const RIG_SCRIPT = { quad: 'build_quad.py', legs: 'build_legs.py', biped: 'build_rig.py' };

/** Do the record's steps (from step `from`, 1-based) and write its game file. */
export function build(id, { from = 1, log = console.log } = {}) {
  const rec = readRecord(id);
  const bad = validateRecord(rec, id);
  if (bad.length) throw new Error(`art-manifest/comfy/${id}.json: ${bad.join('; ')}`);
  const dir = rawDir(id), work = join(dir, 'work');
  const src = join(dir, rec.run.file);
  if (!existsSync(src)) throw new Error(`no art-src/comfy/${id}/${rec.run.file}: the run's model is not here (model-gen.sh puts it there)`);
  mkdirSync(work, { recursive: true });
  let frameFile = null;
  if (rec.frame) { frameFile = join(work, 'frame.json'); writeFileSync(frameFile, JSON.stringify(rec.frame)); }
  const out = (i) => join(work, `${i}-${rec.steps[i - 1].kind}.glb`);
  if (from > 1 && !existsSync(out(from - 1))) throw new Error(`no output of step ${from - 1} in work/: build from 1`);
  let input = from > 1 ? out(from - 1) : src;
  for (let i = from; i <= rec.steps.length; i++) {
    const step = rec.steps[i - 1];
    const t0 = Date.now();
    const script = step.kind === 'rig' ? RIG_SCRIPT[step.body] : KINDS[step.kind].script;
    const args = stepArgs(step, frameFile, work, i);
    const files = step.kind === 'rig' && step.body === 'biped' ? [input, join(ROOT, BIPED_TEMPLATE), out(i)] : [input, out(i)];
    runBlender(join('comfy', script), [...files, ...args]);
    if (!existsSync(out(i))) throw new Error(`step ${i} (${step.kind}) wrote nothing`);
    log(`STEP ${i}/${rec.steps.length} ${step.kind} ${((Date.now() - t0) / 1000).toFixed(0)} s`);
    input = out(i);
  }
  const fin = rec.steps.findIndex((s) => s.kind === 'finish') + 1;
  const rep = JSON.parse(readFileSync(join(work, `${fin}-finish.json`), 'utf8'));
  if (rep.tris !== undefined && rec.tris !== rep.tris) { rec.tris = rep.tris; writeRecord(rec); }
  copyFileSync(input, join(dir, rec.game));   // after the record: build-art.sh takes a game file newer than its record as up to date
  log(`BUILT art-src/comfy/${id}/${rec.game} (${rep.tris ?? '?'} triangles)`);
  return rec;
}

/** Find the game placement and write it as the record's frame. */
export function fit(id, flags) {
  const rec = readRecord(id);
  const dir = rawDir(id), work = join(dir, 'work');
  const src = join(dir, rec.run?.file ?? '');
  if (!existsSync(src)) throw new Error(`no art-src/comfy/${id}/${rec.run?.file}`);
  mkdirSync(work, { recursive: true });
  const frame = join(work, 'frame.json');
  if (flags.ref) {
    const ref = resolve(flags.ref);
    if (!existsSync(ref)) throw new Error(`no ${flags.ref}`);
    process.env.ALIGN_MAX_TILT = String(flags['max-tilt'] ?? 180);
    runBlender('comfy/align.py', [ref, src, join(work, 'fit.glb'), String(flags['tilt-min'] ?? 15), frame]);
  } else if (flags.stand) {
    runBlender('comfy/stand.py', [src, frame, '--yaw', String(flags.yaw ?? 0), '--height', String(flags.height ?? 0), '--max-tilt', String(flags['max-tilt'] ?? 60)]);
    runBlender('comfy/place.py', [src, join(work, 'fit.glb'), frame]);
  } else throw new Error('fit needs --ref <model.glb> or --stand');
  rec.frame = JSON.parse(readFileSync(frame, 'utf8'));
  writeRecord(rec);
  console.log(`FRAME written to art-manifest/comfy/${id}.json; the model placed by it: art-src/comfy/${id}/work/fit.glb`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [cmd, id, ...rest] = process.argv.slice(2);
  const flags = {};
  for (let i = 0; i < rest.length; i++) if (rest[i].startsWith('--')) flags[rest[i].slice(2)] = ['--stand'].includes(rest[i]) ? true : (() => { const v = rest[++i]; return /^-?[\d.]+$/.test(v) ? Number(v) : v; })();
  try {
    if (cmd === 'build' && id) build(id, { from: flags.from ?? 1 });
    else if (cmd === 'fit' && id) fit(id, flags);
    else if (cmd === 'kinds') for (const [k, v] of Object.entries(KINDS)) console.log(`${k} {${Object.entries(v.params).map(([p, s]) => `${p}${s.req ? '' : '?'}: ${want(s)}`).join(', ')}}\n  ${v.what}`);
    else { console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('*/')[0].replace(/^[\s\S]*?\/\*\*/, '')); process.exit(cmd ? 2 : 0); }
  } catch (e) {
    console.error(`FAILED: ${e.message}`);
    process.exit(1);
  }
}
