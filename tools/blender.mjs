#!/usr/bin/env node
/**
 * blender.mjs - scripted Blender animation pipeline (docs/BLENDER-PIPELINE.md).
 *
 *   node tools/blender.mjs procedural <slug> [clip ...] [--recipe r.json] [--rig file.glb] [--out dir] [--install]
 *   node tools/blender.mjs rigfix     <slug> [--recipe r.json]
 *   node tools/blender.mjs cleanup    <in.glb> <clip> [--out out.glb] [--loop] [--drift] [--foot-lock] [--window 0.25] [--name n]
 *   node tools/blender.mjs retarget   <source.glb|fbx> <target-rig.glb> <clip-map.json> [--out dir] [--only clip,clip] [--install <slug>]
 *   node tools/blender.mjs install    <slug> [--from dir]      copy generated anim_*.glb into art-src/tripo/<slug>/ (originals kept in orig/)
 *   node tools/blender.mjs build      <slug ...>               build-characters + stride speeds + clip timings
 *   node tools/blender.mjs selftest                            check the kinematics against Blender itself
 *
 * Blender: $BLENDER or /home/ubuntu/tools/blender/blender or `blender` on PATH (headless, glTF addon on).
 * Every command reads/writes GLBs under art-src/ (gitignored raw assets). Generated per-clip files are named
 * anim_<clip>.glb, the form tools/build-characters.mjs already understands.
 */
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync } from 'node:fs';
import { basename, dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { packFile } from './blender/pack.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SCRIPTS = join(ROOT, 'tools', 'blender');
const TRIPO = join(ROOT, 'art-src', 'tripo');
const WORK = join(ROOT, 'art-src', 'blender');

export function findBlender() {
  for (const c of [process.env.BLENDER, '/home/ubuntu/tools/blender/blender']) if (c && existsSync(c)) return c;
  return 'blender';
}

/** Split argv into positionals and --flags (a flag takes a value unless it is in BOOLS). */
export function parseArgs(argv, bools = ['install', 'loop', 'drift', 'foot-lock', 'help']) {
  const pos = [], flags = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      if (bools.includes(k)) flags[k] = true;
      else flags[k] = argv[++i];
    } else pos.push(a);
  }
  return { pos, flags };
}

/** Run a Blender script headless and return the parsed `RESULT {json}` line (if any). Throws on a Python error. */
export function runBlender(script, args) {
  const r = spawnSync(findBlender(), ['-b', '--factory-startup', '--python', join(SCRIPTS, script), '--', ...args], { encoding: 'utf8', maxBuffer: 1 << 28 });
  const out = (r.stdout ?? '') + (r.stderr ?? '');
  if (r.status !== 0 || /Traceback \(most recent call last\)/.test(out)) {
    console.error(out.split('\n').filter((l) => !/^(Blender|Read|Info|\d\d:\d\d:\d\d \|)/.test(l)).slice(-40).join('\n'));
    throw new Error(`${script} failed`);
  }
  for (const l of out.split('\n')) if (/^(PROCEDURAL|CLEANUP|RETARGET|RIGFIX|SELFTEST)/.test(l)) console.log(l);
  const line = out.split('\n').reverse().find((l) => l.startsWith('RESULT '));
  return line ? JSON.parse(line.slice(7)) : null;
}

function recipeFor(slug, flags) {
  const p = flags.recipe ? resolve(flags.recipe) : join(SCRIPTS, 'recipes', `${slug}.json`);
  if (!existsSync(p)) throw new Error(`no recipe ${p}`);
  return { path: p, recipe: JSON.parse(readFileSync(p, 'utf8')) };
}

const inTripo = (slug, f) => (isAbsolute(f) ? f : join(TRIPO, slug, f));

async function packAll(dir, files) {
  for (const f of files) {
    const name = basename(f).replace(/^anim_/, '').replace(/\.glb$/, '');
    const r = await packFile(join(dir, f), name);
    console.log(`  packed ${f}: ${r.channels} channels (${r.dropped} rest-pose channels dropped)`);
  }
}

const commands = {
  async procedural({ pos, flags }) {
    const [slug, ...clips] = pos;
    const { path, recipe } = recipeFor(slug, flags);
    const rig = flags.rig ? resolve(flags.rig) : inTripo(slug, recipe.source ?? 'rig.glb');
    const out = flags.out ? resolve(flags.out) : join(WORK, slug);
    mkdirSync(out, { recursive: true });
    const res = runBlender('procedural.py', [rig, path, out, ...clips]);
    await packAll(out, res.map((r) => basename(r.file)));
    if (flags.install) commands.install({ pos: [slug], flags: { from: out } });
    return res;
  },

  async rigfix({ pos, flags }) {
    const [slug] = pos;
    const { path, recipe } = recipeFor(slug, flags);
    if (!recipe.rigfix) throw new Error(`${slug}: recipe has no "rigfix" section`);
    const src = inTripo(slug, recipe.rigfix.from ?? 'rig.glb');
    const dst = inTripo(slug, recipe.source);
    return runBlender('rigfix.py', [src, path, dst]);
  },

  async cleanup({ pos, flags }) {
    const [file, clip] = pos;
    const out = flags.out ? resolve(flags.out) : resolve(file).replace(/\.glb$/, '.clean.glb');
    const args = [resolve(file), clip, out];
    for (const k of ['loop', 'drift', 'foot-lock']) if (flags[k]) args.push(`--${k}`);
    for (const k of ['window', 'name', 'forward', 'recipe']) if (flags[k] !== undefined) args.push(`--${k}`, String(flags[k]));
    const res = runBlender('cleanup.py', args);
    await packFile(out, flags.name ?? clip);
    return res;
  },

  async retarget({ pos, flags }) {
    const [source, target, map] = pos;
    const out = flags.out ? resolve(flags.out) : join(WORK, 'retarget');
    mkdirSync(out, { recursive: true });
    const args = [resolve(source), resolve(target), resolve(map), out];
    if (flags.only) args.push('--only', flags.only);
    const res = runBlender('retarget.py', args);
    await packAll(out, res.map((r) => basename(r.file)));
    return res;
  },

  install({ pos, flags }) {
    const [slug] = pos;
    const from = flags.from ? resolve(flags.from) : join(WORK, slug);
    const dir = join(TRIPO, slug);
    mkdirSync(join(dir, 'orig'), { recursive: true });
    for (const f of readdirSync(from).filter((x) => /^anim_.+\.glb$/.test(x))) {
      const dst = join(dir, f), bak = join(dir, 'orig', f);
      if (existsSync(dst) && !existsSync(bak)) copyFileSync(dst, bak);
      copyFileSync(join(from, f), dst);
      console.log(`  installed ${f} -> ${dst}${existsSync(bak) ? '  (original kept in orig/)' : ''}`);
    }
  },

  selftest() {
    runBlender('selftest.py', []);
  },

  build({ pos }) {
    for (const cmd of [['tools/build-characters.mjs', ...pos]]) {
      const r = spawnSync('node', cmd, { cwd: ROOT, stdio: 'inherit' });
      if (r.status !== 0) throw new Error(`${cmd[0]} failed`);
    }
  },
};

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [cmd, ...rest] = process.argv.slice(2);
  if (!commands[cmd]) {
    console.log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('*/')[0].replace(/^[\s\S]*?\/\*\*/, ''));
    process.exit(cmd ? 1 : 0);
  }
  try {
    await commands[cmd](parseArgs(rest));
  } catch (e) {
    console.error(e.message);
    process.exit(1);
  }
}
