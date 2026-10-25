#!/usr/bin/env node
// Checks the game's 3D models against their budgets and rig rules, so a model that is too heavy, has extra materials, the wrong skeleton or
// missing combat clips cannot ship (ROADMAP Phase 1, the checks for War's content; the full budget table comes with Phase 2's tech art page).
//   node tools/assets/check-models.mjs                   every model of the live game (client/assets/slice/models): CI
//   node tools/assets/check-models.mjs --changed <base>  the models changed since <base>, in client/ (the Discord agent's check)
//   node tools/assets/check-models.mjs <glb ...>         only these files (repository paths, or absolute)
// Exit 1 when a model breaks a rule (a hard cap, a material count, a skeleton, missing clips); a model over its target but under its cap is a
// warning. Crowd creatures are left to the crowd baker, which enforces their 5,000-triangle budget (client/tests/crowd_bake.gd).
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const LIVE_DIR = 'client/assets/slice/models';
// target = what Tripo is asked for (ASSET_PIPELINE.md), cap = the most allowed (DECISIONS B71 for heroes and bosses)
export const RULES = {
  hero: { target: 12000, cap: 20000, materials: 1, rig: 'biped', clips: true },
  gear: { target: 3500, cap: 4000, materials: 1, rig: 'none' },
  prop: { target: 3500, cap: 6000, materials: 1, rig: 'any' },
  character: { target: 14000, cap: 20000, materials: 1, rig: 'any' },
};
// The clips every hero body carries (tools/build-characters.mjs gives them to every hero body): the rites' swings, the hit reaction, the death
// and the movement; the second hurt and death and the dig are extras (a warning when missing: the Reaper's body has no second hurt).
export const HERO_CLIPS = ['attack', 'cast', 'channel', 'death', 'flick', 'hurt', 'idle', 'run', 'slam', 'summon', 'sweep', 'walk'];
export const HERO_EXTRA_CLIPS = ['death2', 'dig', 'hurt2'];
const REFERENCE_HERO = 'client/assets/slice/models/hero_gravecaller/character.glb';
// The heroes whose right arm is re-baked around the held staff and the clips each carries as `<clip>_staff` (tools/blender.mjs staff):
// read from its recipe, so a rebuild from art-src, which has no staff clips, fails here instead of quietly losing them.
const STAFF_RECIPE = 'tools/blender/recipes/staff.json';

export function staffClips(name, recipe) {
  return recipe && (recipe.heroes || []).includes(name) ? Object.keys(recipe.clips || {}).map((c) => `${c}_staff`) : [];
}

export function readGlb(buf) {
  if (buf.length < 20 || buf.toString('latin1', 0, 4) !== 'glTF') throw new Error('not a binary glTF');
  const len = buf.readUInt32LE(12);
  const json = JSON.parse(buf.toString('utf8', 20, 20 + len));
  const acc = json.accessors || [];
  let tris = 0;
  for (const m of json.meshes || []) {
    for (const p of m.primitives || []) {
      const a = p.indices != null ? acc[p.indices] : acc[(p.attributes || {}).POSITION];
      tris += Math.floor(((a && a.count) || 0) / 3);
    }
  }
  const joints = [];
  for (const s of json.skins || []) for (const i of s.joints || []) joints.push(((json.nodes || [])[i] || {}).name || '');
  return { tris, materials: (json.materials || []).length, joints, clips: (json.animations || []).map((a) => a.name || '') };
}

export function kindOf(rel, crowdModels) {
  const name = rel.endsWith('/character.glb') ? path.basename(path.dirname(rel)) : path.basename(rel, '.glb');
  if (rel.endsWith('/character.glb')) {
    if (name.startsWith('hero_')) return { kind: 'hero', name };
    if (crowdModels.has(name)) return { kind: 'crowd', name };
    return { kind: 'character', name };
  }
  if (/\/props\//.test(rel)) return { kind: /^(necro_(wpn|helm|mantle)_|gear_)/.test(name) ? 'gear' : 'prop', name };
  return { kind: 'prop', name };
}

export function check(rel, model, kind, refJoints, staff = []) {
  const r = RULES[kind];
  const errors = [];
  const warnings = [];
  if (!r) return { errors, warnings };
  if (model.tris > r.cap) errors.push(`${model.tris} triangles, over the ${kind} cap of ${r.cap}`);
  else if (model.tris > r.target) warnings.push(`${model.tris} triangles, over the ${kind} target of ${r.target} (cap ${r.cap})`);
  if (model.materials > r.materials) errors.push(`${model.materials} materials (a ${kind} uses ${r.materials}: one draw call)`);
  if (r.rig === 'none' && model.joints.length) errors.push(`has a skeleton (${model.joints.length} bones): a ${kind} is unrigged and rides a hand, the head or the back`);
  if (r.rig === 'biped' && refJoints && refJoints.length) {
    const want = refJoints.join('|');
    if (model.joints.join('|') !== want) errors.push(`its skeleton is not the shared biped (${model.joints.length} bones, the heroes use ${refJoints.length}: Tripo's biped rig)`);
  }
  if (r.clips) {
    const missing = HERO_CLIPS.filter((c) => !model.clips.includes(c));
    if (missing.length) errors.push(`missing the clips ${missing.join(', ')} (tools/build-characters.mjs gives every hero body its combat clips)`);
    const extras = HERO_EXTRA_CLIPS.filter((c) => !model.clips.includes(c));
    if (extras.length) warnings.push(`missing the extra clips ${extras.join(', ')}`);
  }
  const lost = staff.filter((c) => !model.clips.includes(c));
  if (lost.length) errors.push(`missing the staff clips ${lost.join(', ')} (a Blender job step {"kind": "staff"} makes them: tools/blender/jobs.mjs; after a rebuild, jobs.mjs replay <slug>)`);
  return { errors, warnings };
}

function crowdModelNames() {
  const f = path.join(ROOT, 'client/crowd/crowd_looks.json');
  const out = new Set();
  if (!existsSync(f)) return out;
  const d = JSON.parse(readFileSync(f, 'utf8'));
  const walk = (v) => {
    if (typeof v === 'string') out.add(v);
    else if (Array.isArray(v)) v.forEach(walk);
    else if (v && typeof v === 'object') Object.values(v).forEach(walk);
  };
  walk(d.enemy_model || {});
  walk(d.enemy_fallback || '');
  return out;
}

function liveModels() {
  const out = [];
  const walk = (dir) => {
    for (const n of readdirSync(path.join(ROOT, dir))) {
      const rel = `${dir}/${n}`;
      if (statSync(path.join(ROOT, rel)).isDirectory()) walk(rel);
      else if (n.endsWith('.glb')) out.push(rel);
    }
  };
  if (existsSync(path.join(ROOT, LIVE_DIR))) walk(LIVE_DIR);
  return out;
}

// Added or edited since <base>: committed, uncommitted, and new files not yet added.
function changedModels(base) {
  const git = (...a) => execFileSync('git', ['-C', ROOT, ...a], { encoding: 'utf8' }).split('\n');
  const files = [...git('diff', '--name-only', '--diff-filter=AM', base, '--', '*.glb'), ...git('ls-files', '--others', '--exclude-standard', '--', '*.glb')];
  return [...new Set(files)].filter((f) => /^client\/assets\//.test(f));
}

function main() {
  const args = process.argv.slice(2);
  const files = args[0] === '--changed' ? changedModels(args[1] || 'origin/main') : args.length ? args.filter((a) => a.endsWith('.glb')) : liveModels();
  const crowd = crowdModelNames();
  const ref = existsSync(path.join(ROOT, REFERENCE_HERO)) ? readGlb(readFileSync(path.join(ROOT, REFERENCE_HERO))).joints : null;
  const staff = existsSync(path.join(ROOT, STAFF_RECIPE)) ? JSON.parse(readFileSync(path.join(ROOT, STAFF_RECIPE), 'utf8')) : null;
  let bad = 0;
  let warn = 0;
  for (const rel of files) {
    const abs = path.resolve(ROOT, rel);
    if (!existsSync(abs)) continue;
    let model;
    try { model = readGlb(readFileSync(abs)); } catch (e) { console.log(`MODEL FAIL ${rel}: ${e.message}`); bad++; continue; }
    const { kind, name } = kindOf(rel, crowd);
    const { errors, warnings } = check(rel, model, kind, ref, kind === 'hero' ? staffClips(name, staff) : []);
    for (const e of errors) console.log(`MODEL FAIL ${rel}: ${e}`);
    for (const w of warnings) console.log(`MODEL WARN ${rel}: ${w}`);
    bad += errors.length ? 1 : 0;
    warn += warnings.length ? 1 : 0;
  }
  console.log(`models: ${files.length} checked, ${bad} failing, ${warn} over target`);
  process.exit(bad ? 1 : 0);
}

if (import.meta.url === `file://${process.argv[1]}`) main();
