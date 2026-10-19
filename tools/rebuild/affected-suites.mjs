#!/usr/bin/env node
// Which of the game's test suites does a change affect? Used by the Discord dev agent's QUICK check (server/death-muffin/discord-agent/check-godot.sh).
// Prints suite names for `tools/rebuild/run-client-tests.sh --only`, one per line (client/tests/<name>.gd or client/tests/<name>/run.gd), or `ALL`,
// or nothing (docs-only).
//   node tools/rebuild/affected-suites.mjs [--base <ref>] [--files a,b,c | --files-from <file>] [--explain]
// Base default: merge-base of HEAD and origin/main. The changed set is committed + uncommitted + untracked since the base.
// Targeting: (a) a suite whose own files changed; (b) suites whose .gd files reference a changed file by res:// path or class_name, also through
// ONE level of non-test dependents (A.gd changed, B.gd uses A, a suite uses B); (c) changed client/data files -> the scripts that read that
// dataset through DmDb (or by res:// path) count as changed; (d) always the SMOKE set. Too central or too broad -> ALL (rules in centralReason).
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

// Fast, broad suites run on every code change: every script parses and loads (code_load), the combat core answers (core_smoke), the game scene
// starts and plays a little (game_scene).
export const SMOKE = ['code_load', 'core_smoke', 'game_scene'];
export const MAX_GD_FILES = 40;
export const MAX_SHARE = 0.6;

const CENTRAL = [
  /^client\/project\.godot$/, /^client\/export_presets\.cfg$/, /^native\//, /^client\/bin\//,
  /^client\/main\//, /^client\/core\//, /^client\/audio\/audio_director\.gd$/, /^client\/fx\/dm_fx\.gd$/,
  /^client\/rules\/core\//, /^client\/net\//, /^client\/session\//, /^client\/tests\/common\//,
  /^tools\/rebuild\/(?!affected-suites\.mjs$|test\/)/, /^client\/data\/content\/manifest\.json$/, /^client\/ui\/theme\//,
];
export function centralReason(f) { return CENTRAL.some((re) => re.test(f)) ? f : null; }
// The API client and its offline mock grow by one function / route per backend feature. A change that only ADDS lines to them is not central:
// it selects the suites (and one level of scripts) that use the added functions or routes. Any removed or edited line keeps them central.
const ADDITIVE = [/^client\/net\/dm_api\.gd$/, /^client\/net\/dm_mock_backend\.gd$/];
/** The names an add-only change to an ADDITIVE file introduces: `func x(` names and "/api/..." route strings. null = not add-only. */
export function additiveNames(f, added) {
  if (!ADDITIVE.some((re) => re.test(f)) || !Array.isArray(added)) return null;
  const words = new Set(), fixed = new Set();
  for (const l of added) {
    for (const m of l.matchAll(/^\s*(?:static\s+)?func\s+(\w+)/g)) words.add(m[1]);
    for (const m of l.matchAll(/"(\/api\/[^"]+)"/g)) fixed.add(m[1]);
  }
  return { words: [...words], fixed: [...fixed] };
}

// Suites that read a whole folder or dataset through a loader no reference search can follow (DmCombatData.load_json("abilities"), the rites by the registry's list):
// a change under these paths selects the suite whatever the references say. `spells` casts every spell of every playable kit from the data.
export const FORCED = [
  [/^client\/next\/rites\//, 'spells'],
  [/^client\/data\/combat\//, 'spells'],
  [/^client\/game_ui\/dm_spell_tooltip\.gd$/, 'spells'],
];

const IGNORED = (f) => /\.(md|uid|import)$/.test(f) || !/^(client|native)\//.test(f);   // docs, Godot bookkeeping, and everything outside the game (server/, docs/, ...)

// DmDb accessor patterns for client/data/<domain>/<name>.json (the consumers of that dataset)
export function dataPatterns(rel) {
  const m = /^client\/data\/([^/]+)\/([^/]+)\.json$/.exec(rel);
  if (!m) return null;
  const [, dom, name] = m;
  const lit = [`res://data/${dom}/${name}.json`, `"${dom}/${name}"`];
  const acc = {
    content: [`content("${name}"`, `content_export("${name}"`, `"content/${name}"`],
    combat: [`combat("${name}"`],
    gathering: ['DmDb.gathering('], onboarding: ['DmDb.tips('], panels_a: [`panels_a("${name}"`],
    slice: [`slice("${name}"`], world_fx: ['DmDb.world_fx('], sim: ['DmDb.sim_world('], progression: ['progression_view('],
  }[dom] || [];
  // content/* also feeds the derived loot / progression projections
  if (dom === 'content' || dom === 'combat') acc.push('loot_view(', 'progression_view(');
  return [...lit, ...acc];
}

/** ctx: { suites: string[] (the runner's suite names), testsOnly(pats:{fixed:[],words:[]}) -> files, srcOnly(...) -> files, classNameOf(file) -> string|null,
 *  addedLines?(file) -> string[] | null (the lines a change adds when it removes none, else null) } */
export function affected(changed, ctx) {
  const files = [...new Set(changed)].filter(Boolean);
  const relevant = files.filter((f) => !IGNORED(f) || /^tools\/rebuild\//.test(f));
  if (!relevant.length) return { all: false, selectors: [], why: 'no file the game is made of changed' };
  const additive = new Map();   // ADDITIVE file -> the names it adds (its users are found by those, not by its class name)
  for (const f of relevant) {
    const c = centralReason(f); if (!c) continue;
    const a = additiveNames(f, ctx.addedLines ? ctx.addedLines(f) : null);
    if (!a) return { all: true, why: `central file: ${c}` };
    additive.set(f, a);
  }
  const gd = relevant.filter((f) => f.endsWith('.gd'));
  if (gd.length > MAX_GD_FILES) return { all: true, why: `${gd.length} changed .gd files (> ${MAX_GD_FILES})` };

  const sel = new Set(SMOKE.filter((s) => ctx.suites.includes(s)));
  // a content table change runs rules-core, which reads every content table and the manifest's list of them
  if (relevant.some((f) => /^client\/data\/content\/[^/]+\.json$/.test(f)) && ctx.suites.includes('rules-core')) sel.add('rules-core');
  for (const [re, suite] of FORCED) if (relevant.some((f) => re.test(f)) && ctx.suites.includes(suite)) sel.add(suite);
  const direct = new Set();   // suites chosen because their own files changed
  // client/tests/<name>.gd is a suite's script, client/tests/<name>/... a folder's files: they select the folder's suites (<name> and its runners
  // <name>/<runner>); helpers that no suite is named after select none
  const suitesOf = (f) => { const m = /^client\/tests\/([^/]+?)(?:\.gd|\/.*)$/.exec(f); return m ? ctx.suites.filter((s) => s === m[1] || s.startsWith(m[1] + '/')) : []; };
  for (const f of relevant) for (const s of suitesOf(f)) { sel.add(s); direct.add(s); }

  // what the rest of the code base refers to: changed non-test files (scripts, scenes, resources, assets, data)
  const patsFor = (list) => {
    const fixed = new Set(), words = new Set();
    for (const f of list) {
      const dp = dataPatterns(f);
      if (dp) { dp.forEach((p) => fixed.add(p)); continue; }
      fixed.add('res://' + f.replace(/^client\//, ''));
      const cn = f.endsWith('.gd') ? ctx.classNameOf(f) : null;
      if (cn) words.add(cn);
    }
    return { fixed: [...fixed], words: [...words] };
  };
  const nonTest = relevant.filter((f) => !f.startsWith('client/tests/'));
  const p1 = patsFor(relevant.filter((f) => !additive.has(f)));
  for (const a of additive.values()) { p1.fixed.push(...a.fixed); p1.words.push(...a.words); }
  const addSuites = (testFiles) => { for (const t of testFiles) for (const s of suitesOf(t)) sel.add(s); };
  addSuites(ctx.testsOnly(p1));
  // one level of dependents: non-test scripts/scenes that refer to the changed files (data -> its readers; class -> its users)
  const deps = nonTest.length ? ctx.srcOnly(p1).filter((f) => !relevant.includes(f)) : [];
  if (deps.length) {
    const depList = deps.slice(0, 200);
    addSuites(ctx.testsOnly(patsFor(depList)));
  }
  const share = ctx.suites.length ? sel.size / ctx.suites.length : 0;
  if (share > MAX_SHARE) return { all: true, why: `targets ${sel.size} of ${ctx.suites.length} suites (> ${Math.round(MAX_SHARE * 100)}%)` };
  const add = additive.size ? `, add-only: ${[...additive.keys()].map((f) => path.basename(f)).join(' ')}` : '';
  return { all: false, selectors: [...sel].sort(), why: `${sel.size} suites (${direct.size} changed, ${deps.length} dependent files${add})` };
}

// ---- CLI ------------------------------------------------------------------------------------------------------------------
function git(args, cwd, ok = false) {
  try { return execFileSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'ignore'] }); }
  catch (e) { if (ok || e.status === 1) return e.stdout || ''; throw e; }
}

function buildCtx(top, base) {
  // the runner's suite list (tools/rebuild/run-client-tests.sh SUITES)
  const runner = fs.readFileSync(path.join(top, 'tools/rebuild/run-client-tests.sh'), 'utf8');
  const m = /^SUITES="([^"]*)"/m.exec(runner);
  const suites = m ? m[1].split(/\s+/).filter(Boolean).sort() : [];
  const grep = (pats, spec) => {
    const out = new Set();
    const run = (list, extra) => {
      if (!list.length) return;
      const args = ['grep', '--untracked', '-l', ...extra]; for (const p of list) args.push('-e', p);
      args.push('--', ...spec);
      for (const l of git(args, top, true).split('\n')) if (l) out.add(l);
    };
    run(pats.fixed, ['-F']); run(pats.words, ['-F', '-w']);
    return [...out];
  };
  const cn = new Map();
  return {
    suites,
    addedLines: (f) => {
      if (!base) return null;
      const d = git(['diff', '--no-color', '-U0', base, '--', f], top, true);
      if (!d || /^deleted file|^new file/m.test(d)) return null;
      const lines = d.split('\n').filter((l) => !/^(\+\+\+|---) /.test(l));
      if (lines.some((l) => l.startsWith('-'))) return null;
      return lines.filter((l) => l.startsWith('+')).map((l) => l.slice(1));
    },
    testsOnly: (p) => grep(p, ['client/tests']).filter((f) => /\.(gd|tscn|tres)$/.test(f)),
    srcOnly: (p) => grep(p, ['client', ':(exclude)client/tests']).filter((f) => /\.(gd|tscn|tres)$/.test(f)),
    classNameOf: (f) => {
      if (cn.has(f)) return cn.get(f);
      let v = null;
      try { const m = /^class_name\s+(\w+)/m.exec(fs.readFileSync(path.join(top, f), 'utf8')); v = m ? m[1] : null; } catch { v = null; }
      if (!v) { const old = git(['show', `HEAD:${f}`], top, true); const m = /^class_name\s+(\w+)/m.exec(old); v = m ? m[1] : null; }   // deleted file
      cn.set(f, v); return v;
    },
  };
}

function baseOf(top, base) {
  if (base) return base;
  try { return git(['merge-base', 'HEAD', `origin/${process.env.BASE_BRANCH || 'main'}`], top).trim(); } catch { return ''; }
}

function changedFiles(top, b) {
  if (!b) return null;
  const a = git(['diff', '--name-only', b], top, true), u = git(['ls-files', '--others', '--exclude-standard'], top, true);
  return [...new Set((a + u).split('\n').filter((x) => x && x !== 'node_modules'))];
}

function main(argv) {
  const o = { base: '', files: null, explain: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--base') o.base = argv[++i];
    else if (a === '--files') o.files = argv[++i].split(',').filter(Boolean);
    else if (a === '--files-from') o.files = fs.readFileSync(argv[++i], 'utf8').split('\n').filter(Boolean);
    else if (a === '--explain') o.explain = true;
    else { console.error('usage: affected-suites.mjs [--base ref] [--files a,b | --files-from f] [--explain]'); process.exit(2); }
  }
  const top = git(['rev-parse', '--show-toplevel'], process.cwd()).trim();
  const base = baseOf(top, o.base);
  const changed = o.files || changedFiles(top, base);
  if (!changed) { if (o.explain) console.error('no base found'); console.log('ALL'); return; }   // cannot tell what changed: be safe
  const r = affected(changed, buildCtx(top, base));
  if (o.explain) console.error('affected-suites: ' + r.why);
  if (r.all) console.log('ALL'); else for (const s of r.selectors) console.log(s);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main(process.argv.slice(2));
