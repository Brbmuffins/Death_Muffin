#!/usr/bin/env node
// Which Godot test suites does a change affect? Used by the Discord dev agent's QUICK check (server/death-muffin/discord-agent/check-godot.sh).
// Prints selectors for `tools/godot/run-all-tests.sh --only` one per line (a test dir name under godot/tests/), or `ALL`, or nothing (docs-only).
//   node tools/godot/affected-suites.mjs [--base <ref>] [--files a,b,c | --files-from <file>] [--explain]
// Base default: merge-base of HEAD and origin/main. The changed set is committed + uncommitted + untracked since the base.
// Targeting: (a) a suite dir whose files changed; (b) suites whose .gd files reference a changed file by res:// path or class_name, also through
// ONE level of non-test dependents (A.gd changed, B.gd uses A, a suite uses B); (c) changed godot/data files -> the scripts that read that
// dataset through DmDb (or by res:// path) count as changed; (d) always the SMOKE set. Too central or too broad -> ALL (rules in centralReason).
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';

// Fast, broad suites run on every code change (about 100 s together on the shared VPS: data 7 s, status 7 s, session_report 6 s, next 32 s, next_front 37 s).
export const SMOKE = ['data', 'status', 'backend', 'next', 'next_front'];
export const MAX_GD_FILES = 40;
export const MAX_SHARE = 0.6;

const CENTRAL = [
  /^godot\/project\.godot$/, /^godot\/export_presets\.cfg$/, /^export_presets\.cfg$/,
  /^godot\/main\//, /^godot\/audio\/audio_director\.gd$/, /^godot\/fx\/dm_fx\.gd$/,
  /^godot\/rules\/core\//, /^godot\/net\//, /^godot\/session\//, /^godot\/tests\/common\//,
  /^tools\/godot\/(?!affected-suites\.mjs$|test\/)/, /^godot\/data\/content\/manifest\.json$/, /^godot\/ui\/theme\//,
];
export function centralReason(f) { return CENTRAL.some((re) => re.test(f)) ? f : null; }

const IGNORED = (f) => /\.(md|uid|import)$/.test(f) || !/^godot\//.test(f);   // docs, Godot bookkeeping, and everything outside godot/ (server/, docs/, ...)

// DmDb accessor patterns for godot/data/<domain>/<name>.json (the consumers of that dataset)
export function dataPatterns(rel) {
  const m = /^godot\/data\/([^/]+)\/([^/]+)\.json$/.exec(rel);
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

/** ctx: { suites: string[] (test dirs that have run files), testsOnly(pats:{fixed:[],words:[]}) -> files, srcOnly(...) -> files, classNameOf(file) -> string|null } */
export function affected(changed, ctx) {
  const files = [...new Set(changed)].filter(Boolean);
  const relevant = files.filter((f) => !IGNORED(f) || /^tools\/godot\//.test(f));
  if (!relevant.length) return { all: false, selectors: [], why: 'no Godot-affecting files changed' };
  for (const f of relevant) { const c = centralReason(f); if (c) return { all: true, why: `central file: ${c}` }; }
  const gd = relevant.filter((f) => f.endsWith('.gd'));
  if (gd.length > MAX_GD_FILES) return { all: true, why: `${gd.length} changed .gd files (> ${MAX_GD_FILES})` };

  const sel = new Set(SMOKE.filter((s) => ctx.suites.includes(s)));
  const direct = new Set();   // suites chosen because their own files changed
  const suiteOf = (f) => { const m = /^godot\/tests\/([^/]+)\//.exec(f); return m ? m[1] : null; };
  for (const f of relevant) { const s = suiteOf(f); if (s && ctx.suites.includes(s)) { sel.add(s); direct.add(s); } }

  // what the rest of the code base refers to: changed non-test files (scripts, scenes, resources, assets, data)
  const patsFor = (list) => {
    const fixed = new Set(), words = new Set();
    for (const f of list) {
      const dp = dataPatterns(f);
      if (dp) { dp.forEach((p) => fixed.add(p)); continue; }
      fixed.add('res://' + f.replace(/^godot\//, ''));
      const cn = f.endsWith('.gd') ? ctx.classNameOf(f) : null;
      if (cn) words.add(cn);
    }
    return { fixed: [...fixed], words: [...words] };
  };
  const nonTest = relevant.filter((f) => !f.startsWith('godot/tests/'));
  const p1 = patsFor(relevant);
  const addSuites = (testFiles) => { for (const t of testFiles) { const s = suiteOf(t); if (s && ctx.suites.includes(s)) sel.add(s); } };
  addSuites(ctx.testsOnly(p1));
  // one level of dependents: non-test scripts/scenes that refer to the changed files (data -> its readers; class -> its users)
  const deps = nonTest.length ? ctx.srcOnly(p1).filter((f) => !relevant.includes(f)) : [];
  if (deps.length) {
    const depList = deps.slice(0, 200);
    addSuites(ctx.testsOnly(patsFor(depList)));
  }
  const share = ctx.suites.length ? sel.size / ctx.suites.length : 0;
  if (share > MAX_SHARE) return { all: true, why: `targets ${sel.size} of ${ctx.suites.length} suites (> ${Math.round(MAX_SHARE * 100)}%)` };
  return { all: false, selectors: [...sel].sort(), why: `${sel.size} suites (${direct.size} changed, ${deps.length} dependent files)` };
}

// ---- CLI ------------------------------------------------------------------------------------------------------------------
function git(args, cwd, ok = false) {
  try { return execFileSync('git', args, { cwd, encoding: 'utf8', maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'ignore'] }); }
  catch (e) { if (ok || e.status === 1) return e.stdout || ''; throw e; }
}

function buildCtx(top) {
  const suites = [];
  const tdir = path.join(top, 'godot/tests');
  for (const d of fs.readdirSync(tdir, { withFileTypes: true })) {
    if (!d.isDirectory()) continue;
    const fs_ = fs.readdirSync(path.join(tdir, d.name));
    if (fs_.some((n) => n === 'run.gd' || n === 'adapter_run.gd' || /_run\.gd$/.test(n))) suites.push(d.name);
  }
  suites.sort();
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
    testsOnly: (p) => grep(p, ['godot/tests']).filter((f) => /\.(gd|tscn|tres)$/.test(f)),
    srcOnly: (p) => grep(p, ['godot', ':(exclude)godot/tests']).filter((f) => /\.(gd|tscn|tres)$/.test(f)),
    classNameOf: (f) => {
      if (cn.has(f)) return cn.get(f);
      let v = null;
      try { const m = /^class_name\s+(\w+)/m.exec(fs.readFileSync(path.join(top, f), 'utf8')); v = m ? m[1] : null; } catch { v = null; }
      if (!v) { const old = git(['show', `HEAD:${f}`], top, true); const m = /^class_name\s+(\w+)/m.exec(old); v = m ? m[1] : null; }   // deleted file
      cn.set(f, v); return v;
    },
  };
}

function changedFiles(top, base) {
  let b = base;
  if (!b) { try { b = git(['merge-base', 'HEAD', `origin/${process.env.BASE_BRANCH || 'main'}`], top).trim(); } catch { b = ''; } }
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
  const changed = o.files || changedFiles(top, o.base);
  if (!changed) { if (o.explain) console.error('no base found'); console.log('ALL'); return; }   // cannot tell what changed: be safe
  const r = affected(changed, buildCtx(top));
  if (o.explain) console.error('affected-suites: ' + r.why);
  if (r.all) console.log('ALL'); else for (const s of r.selectors) console.log(s);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) main(process.argv.slice(2));
