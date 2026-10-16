#!/usr/bin/env node
// Copies the assets the rebuilt client needs from godot/assets/ into client/assets/ (same relative paths), driven by client/assets.list.
//
//   node tools/rebuild/sync-assets.mjs [--list <file>] [--dry-run] [--quiet]
//
// - client/assets.list: one path or glob per line, relative to godot/assets/ (# starts a comment). `*` matches within a folder, `**` any
//   depth, `?` one character; a path that names a folder (or ends in `/`) copies the folder's files recursively.
// - Asset files only: Godot's `*.import`, `*.uid` and `*.unwrap_cache` files are never copied (the client project imports with its own settings).
// - Idempotent: a file is copied only when it is missing or its bytes differ. The report lists what was added and changed, flags list
//   lines that match nothing (exit 1) and lists files in client/assets that no list line names any more (never deleted).
// - A line starting with `@` names project art that lives next to the code in godot/ instead of godot/assets (ui/fonts, ui/hud/art, front/art,
//   world_fx/assets): the path is relative to godot/ and the file lands at the same path in client/ (for example `@ui/fonts`).
// - New 3D textures get a seed `.import` (VRAM compressed, mipmaps, normal maps flagged) so the client's first import already uses its own
//   settings; an existing `.import` is never touched. Godot completes the seed and, from then on, owns the file (commit it).
// - Licensed flipbook sheets (fx/sheets/) are not in git: they are read from the private source $FX_SHEETS (default
//   ~/death-muffin/private/fx-sheets, like tools/godot/fx-sheets-sync.sh) and client/.gitignore keeps them out of the repository. The tool
//   refuses to copy them unless git ignores the destination.
import { execFileSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const opt = (n, d) => (args.includes(n) ? args[args.indexOf(n) + 1] : d);

const listFile = path.resolve(root, opt('--list', 'client/assets.list'));
const godotRoot = path.join(root, 'godot');
const clientRoot = path.join(root, 'client');
const srcRoot = path.join(godotRoot, 'assets');
const dstRoot = path.join(clientRoot, 'assets');
const sheetsSrc = process.env.FX_SHEETS || path.join(os.homedir(), 'death-muffin', 'private', 'fx-sheets');
const SHEETS = 'fx/sheets/';
const listName = path.relative(root, listFile).startsWith('..') ? listFile : path.relative(root, listFile);
const dry = flag('--dry-run');
const quiet = flag('--quiet');

// Code and data files go through sync-code.mjs; `@` lines take only the art beside them.
const CODE = /\.(gd|gd\.uid|gdshader|gdshader\.uid|gdshaderinc|tscn|tres|json|cfg|csv|txt)$/;
// Godot's own files: imports, uids and the lightmap-unwrap caches it writes next to models imported with lightmap UV2 (committed, so UV2 stays the same on every machine).
const skipFile = (f) => f.endsWith('.import') || f.endsWith('.uid') || f.endsWith('.unwrap_cache');

// Folders (relative to assets/, or to client/ for `@` art) whose textures are drawn in 3D: desktop BPTC + phone ASTC/ETC2 formats with mipmaps, like the live game's
// hygiene rule (tools/hygiene/check.mjs). Godot's own detection never fires for glTF-extracted images or headless imports.
const TEX3D = ['slice/models/', 'slice/art/textures/', 'fx/art/', 'fx/tex/', 'fx/binbun/tex/', 'fx/models/', 'world_fx/assets/'];
const isTexture = (f) => /\.(png|webp|jpe?g)$/i.test(f);
function seedImport(rel, dstAbs) {
  if (!isTexture(rel) || !TEX3D.some((d) => rel.startsWith(d))) return false;
  const imp = dstAbs + '.import';
  if (existsSync(imp)) return false;
  const normal = /(NormalGL|_n\.|normal)/i.test(rel);
  if (!dry) {
    writeFileSync(imp, `[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n\n[params]\n\ncompress/mode=2\ncompress/high_quality=true\ncompress/normal_map=${normal ? 1 : 0}\nmipmaps/generate=true\n`);
  }
  return true;
}

// Glob -> RegExp over '/'-separated relative paths.
function globToRe(g) {
  let re = '';
  for (let i = 0; i < g.length; i++) {
    const c = g[i];
    if (c === '*') {
      if (g[i + 1] === '*') { re += '.*'; i++; if (g[i + 1] === '/') i++; } else re += '[^/]*';
    } else if (c === '?') re += '[^/]';
    else re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + re + '$');
}

function walk(dir, rel = '') {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...walk(path.join(dir, e.name), r));
    else if (e.isFile()) out.push(r);
  }
  return out;
}

if (!existsSync(listFile)) { console.error(`sync-assets: ${listName} not found`); process.exit(2); }
const entries = readFileSync(listFile, 'utf8').split('\n')
  .map((l, i) => ({ text: l.replace(/#.*$/, '').trim(), line: i + 1 }))
  .filter((e) => e.text);

// Every file under godot/assets (committed assets) and under the private sheets folder (as fx/sheets/<name>); for `@` lines, every
// non-code file under godot/ (project art next to the code).
const publicFiles = walk(srcRoot).filter((f) => !f.startsWith(SHEETS));
const sheetFiles = walk(sheetsSrc).map((f) => SHEETS + f);
let projectFilesCache = null;
const projectFiles = () => (projectFilesCache ||= walk(godotRoot).filter((f) => !f.startsWith('assets/') && !f.startsWith('tests/') && !CODE.test(f)));
const sheetsDestIgnored = (() => {
  try { execFileSync('git', ['check-ignore', '-q', path.join(dstRoot, 'fx', 'sheets', 'x.png')], { cwd: root }); return true; } catch { return false; }
})();

const wanted = new Map();   // path relative to client/assets -> true
const wantedProject = new Map();   // path relative to client/ (art next to the code) -> true
const projectBases = new Set();   // the folders `@` lines name, for the "not in the list" report
const unmatched = [];
for (const e of entries) {
  const project = e.text.startsWith('@');
  let pat = e.text.replace(/^@/, '').replace(/^\/+/, '');
  const base = project ? godotRoot : srcRoot;
  const asFolder = pat.endsWith('/') || (!/[*?]/.test(pat) && existsSync(path.join(base, pat)) && statSync(path.join(base, pat)).isDirectory());
  if (asFolder) pat = pat.replace(/\/+$/, '') + '/**';
  const re = globToRe(pat);
  if (project) {
    const hits = projectFiles().filter((f) => re.test(f) && !skipFile(f));
    if (!hits.length) unmatched.push(e);
    projectBases.add(pat.split('/').filter((x) => !/[*?]/.test(x)).join('/'));
    for (const f of hits) wantedProject.set(f, true);
    continue;
  }
  const pool = pat.startsWith(SHEETS) || pat.startsWith('**') || pat.startsWith('fx/**') ? publicFiles.concat(sheetFiles) : publicFiles;
  const hits = pool.filter((f) => re.test(f) && !skipFile(f));
  if (!hits.length) unmatched.push(e);
  for (const f of hits) wanted.set(f, true);
}

const added = [];
const changed = [];
let seeded = 0;
let same = 0;
let bytes = 0;
const sheetProblems = [];
const copyOne = (rel, from, to, label) => {   // rel: the path the 3D-texture rule reads; label: the path shown in the report
  bytes += statSync(from).size;
  if (existsSync(to)) {
    if (readFileSync(from).equals(readFileSync(to))) { same++; if (seedImport(rel, to)) seeded++; return; }
    changed.push(label);
  } else added.push(label);
  if (!dry) {
    mkdirSync(path.dirname(to), { recursive: true });
    copyFileSync(from, to);
  }
  if (seedImport(rel, to)) seeded++;
};
for (const rel of [...wanted.keys()].sort()) {
  const isSheet = rel.startsWith(SHEETS);
  const from = isSheet ? path.join(sheetsSrc, rel.slice(SHEETS.length)) : path.join(srcRoot, rel);
  if (isSheet && !sheetsDestIgnored) { bytes += statSync(from).size; sheetProblems.push(rel); continue; }
  copyOne(rel, from, path.join(dstRoot, rel), rel);
}
for (const rel of [...wantedProject.keys()].sort()) copyOne(rel, path.join(godotRoot, rel), path.join(clientRoot, rel), '@' + rel);

// Files under client/assets that no list line names (generated `.import`/`.uid` files and .gitkeep excluded). Reported, never deleted.
const stale = walk(dstRoot).filter((f) => !skipFile(f) && !f.endsWith('.gitkeep') && !f.startsWith('crowd/baked/') && !wanted.has(f))   // crowd/baked: the crowd's generated bakes
  .concat([...projectBases].flatMap((b) => walk(path.join(clientRoot, b)).map((f) => path.posix.join(b, f))).filter((f) => !skipFile(f) && !CODE.test(f) && !wantedProject.has(f)).map((f) => '@' + f));

const show = (title, arr) => {
  if (!arr.length) return;
  console.log(`${title} (${arr.length}):`);
  const max = quiet ? 0 : 40;
  for (const f of arr.slice(0, max)) console.log(`  ${f}`);
  if (arr.length > max) console.log(`  ... ${arr.length - max} more`);
};
show(dry ? 'would add' : 'added', added);
show(dry ? 'would change' : 'changed', changed);
if (stale.length) show('in client/assets but not in the list (kept; delete by hand if unwanted)', stale);
let failed = false;
if (unmatched.length) {
  failed = true;
  console.log(`NO MATCH (${unmatched.length}): these list lines name nothing under godot/assets (or godot/ for @ lines)${existsSync(sheetsSrc) ? '' : ` (sheets source ${sheetsSrc} is missing)`}:`);
  for (const e of unmatched) console.log(`  ${listName}:${e.line}: ${e.text}`);
}
if (sheetProblems.length) {
  failed = true;
  console.log(`REFUSED (${sheetProblems.length}): licensed sheets must stay out of git, but git does not ignore client/assets/fx/sheets/ (add it to client/.gitignore):`);
  for (const f of sheetProblems.slice(0, 5)) console.log(`  ${f}`);
}
console.log(`sync-assets: ${wanted.size + wantedProject.size} files (${(bytes / 1048576).toFixed(1)} MB) from ${entries.length} list lines: ${added.length} ${dry ? 'to add' : 'added'}, ${changed.length} ${dry ? 'to change' : 'changed'}, ${same} unchanged${seeded ? `, ${seeded} texture import seeds written` : ''}${stale.length ? `, ${stale.length} not in the list` : ''}`);
process.exit(failed ? 1 : 0);
