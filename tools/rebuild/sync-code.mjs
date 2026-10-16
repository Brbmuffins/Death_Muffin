#!/usr/bin/env node
// Keeps the rebuilt client's copies of today's scripts, scenes and data identical to godot/ (DECISIONS B43), driven by client/code.list.
//
//   node tools/rebuild/sync-code.mjs [--dry-run] [--check] [--quiet]
//   node tools/rebuild/sync-code.mjs --port <path relative to godot/> ...
//
// - client/code.list: one glob per line, relative to godot/ (# starts a comment); `!glob` leaves files out (the per-creature systems the core
//   replaces). `*` stays inside a folder, `**` crosses folders, a folder name takes it whole. Code files only (CODE below): assets go through
//   sync-assets.mjs, READMEs stay in godot/ (one home per fact).
// - Copies keep their paths (godot/<p> -> client/<p>), so res:// paths, class names and script uids keep working. A copy is never edited in
//   client/: change godot/ and sync, or port the file.
// - Ported files are edited in client/ to run on the core. `--port <p>` marks one (or records again that its live original's current version is
//   carried over); sync never touches it, and reports it when its original in godot/ has changed since, so a live fix can be carried over.
// - client/code.lock.json records every copy (with the git blob id of its content) and every port (with the blob id of the original it was ported
//   from). Only files the lock lists as copies are ever replaced or deleted: the client's own files are never touched, and a copy that would land
//   on one is refused. The hygiene check (tools/hygiene/check.mjs) fails when a copy no longer matches its lock entry (edited by hand).
// - Default: copy what is missing or changed, delete copies whose original is gone or no longer listed, rewrite the lock. Exit 1 when a ported
//   file's original moved on, a list line matches nothing, or a copy would overwrite a client file.
// - --check: change nothing; exit 1 when anything is out of date (the test build publish refuses to ship stale copies).
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const args = process.argv.slice(2);
const flag = (n) => args.includes(n);
const dry = flag('--dry-run') || flag('--check');
const check = flag('--check');
const quiet = flag('--quiet');
const srcRoot = path.join(root, 'godot');
const dstRoot = path.join(root, 'client');
const listFile = path.join(dstRoot, 'code.list');
const lockFile = path.join(dstRoot, 'code.lock.json');

// Scripts and their uids, scenes and resources, shaders, data. Not: assets, *.import, READMEs, the project file, tests (the client has its own).
const CODE = /\.(gd|gd\.uid|gdshader|gdshader\.uid|gdshaderinc|tscn|tres|json|cfg|csv|txt)$/;
const NEVER = ['project.godot', 'export_presets.cfg', 'tests/**', 'assets/**', '.godot/**', '**/*.md'];

// git's blob id, so the lock can be compared with `git hash-object`.
const blobId = (buf) => createHash('sha1').update(`blob ${buf.length}\0`).update(buf).digest('hex');

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
    if (e.name === '.godot' || e.name === 'node_modules') continue;
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...walk(path.join(dir, e.name), r));
    else if (e.isFile()) out.push(r);
  }
  return out;
}

const readLock = () => (existsSync(lockFile) ? JSON.parse(readFileSync(lockFile, 'utf8')) : { copied: {}, ported: {} });
const writeLock = (lock) => {
  const sorted = (o) => Object.fromEntries(Object.keys(o).sort().map((k) => [k, o[k]]));
  writeFileSync(lockFile, JSON.stringify({ copied: sorted(lock.copied), ported: sorted(lock.ported) }, null, 1) + '\n');
};
const srcBlob = (rel) => blobId(readFileSync(path.join(srcRoot, rel)));

const lock = readLock();
lock.copied ||= {};
lock.ported ||= {};

// --port: record the original's current version for each named file (the copy, if any, becomes the port's starting point).
if (flag('--port')) {
  const names = args.filter((a) => !a.startsWith('--'));
  let bad = false;
  for (const rel of names) {
    if (!existsSync(path.join(srcRoot, rel))) { console.log(`no godot/${rel}`); bad = true; continue; }
    if (!existsSync(path.join(dstRoot, rel))) {
      mkdirSync(path.dirname(path.join(dstRoot, rel)), { recursive: true });
      copyFileSync(path.join(srcRoot, rel), path.join(dstRoot, rel));
    }
    delete lock.copied[rel];
    lock.ported[rel] = srcBlob(rel);
    console.log(`ported: client/${rel} (from godot/${rel} ${lock.ported[rel].slice(0, 8)})`);
  }
  writeLock(lock);
  process.exit(bad ? 1 : 0);
}

if (!existsSync(listFile)) { console.error('sync-code: client/code.list not found'); process.exit(2); }
const entries = readFileSync(listFile, 'utf8').split('\n')
  .map((l, i) => ({ text: l.replace(/#.*$/, '').trim(), line: i + 1 }))
  .filter((e) => e.text);
const pool = walk(srcRoot).filter((f) => CODE.test(f));
const never = NEVER.map(globToRe);
const wanted = new Set();
const unmatched = [];
for (const e of entries) {
  const out = e.text.startsWith('!');
  let pat = e.text.replace(/^!/, '').replace(/^\/+/, '');
  const asFolder = pat.endsWith('/') || (!/[*?]/.test(pat) && existsSync(path.join(srcRoot, pat)) && statSync(path.join(srcRoot, pat)).isDirectory());
  if (asFolder) pat = pat.replace(/\/+$/, '') + '/**';
  const re = globToRe(pat);
  const hits = pool.filter((f) => re.test(f) && !never.some((n) => n.test(f)));
  if (!hits.length) unmatched.push(e);
  for (const f of hits) (out ? wanted.delete(f) : wanted.add(f));
}

const added = [];
const changed = [];
const removed = [];
const refused = [];
const portsBehind = [];
let same = 0;
for (const rel of [...wanted].sort()) {
  if (lock.ported[rel]) continue;
  const to = path.join(dstRoot, rel);
  const buf = readFileSync(path.join(srcRoot, rel));
  const id = blobId(buf);
  if (existsSync(to)) {
    if (!lock.copied[rel]) { refused.push(rel); continue; }   // a client file of its own lives there
    if (lock.copied[rel] === id && blobId(readFileSync(to)) === id) { same++; continue; }
    changed.push(rel);
  } else added.push(rel);
  if (!dry) {
    mkdirSync(path.dirname(to), { recursive: true });
    copyFileSync(path.join(srcRoot, rel), to);
  }
  lock.copied[rel] = id;
}
for (const rel of Object.keys(lock.copied)) {
  if (wanted.has(rel) && existsSync(path.join(srcRoot, rel))) continue;
  removed.push(rel);
  if (!dry) {
    rmSync(path.join(dstRoot, rel), { force: true });
    for (let d = path.dirname(path.join(dstRoot, rel)); d !== dstRoot && existsSync(d) && !readdirSync(d).length; d = path.dirname(d)) rmSync(d, { recursive: true });
  }
  delete lock.copied[rel];
}
for (const [rel, id] of Object.entries(lock.ported)) {
  const src = path.join(srcRoot, rel);
  if (!existsSync(src)) portsBehind.push(`${rel} (its original was deleted)`);
  else if (srcBlob(rel) !== id) portsBehind.push(`${rel}   (what changed: git diff ${id.slice(0, 12)} ${srcBlob(rel).slice(0, 12)})`);
}
if (!dry) writeLock(lock);

const show = (title, arr) => {
  if (!arr.length) return;
  console.log(`${title} (${arr.length}):`);
  const max = quiet ? 0 : 40;
  for (const f of arr.slice(0, max)) console.log(`  ${f}`);
  if (arr.length > max) console.log(`  ... ${arr.length - max} more`);
};
show(dry ? 'would add' : 'added', added);
show(dry ? 'would change' : 'changed', changed);
show(dry ? 'would remove' : 'removed', removed);
let failed = false;
if (refused.length) {
  failed = true;
  console.log(`REFUSED (${refused.length}): client/ has its own file where a copy would go (rename one, or leave it out with !path):`);
  for (const f of refused) console.log(`  ${f}`);
}
if (portsBehind.length) {
  failed = true;
  console.log(`PORTS BEHIND (${portsBehind.length}): the live original changed since the port; carry the change into client/, then --port it:`);
  for (const f of portsBehind) console.log(`  ${f}`);
}
if (unmatched.length) {
  failed = true;
  console.log(`NO MATCH (${unmatched.length}): these list lines name nothing under godot/:`);
  for (const e of unmatched) console.log(`  client/code.list:${e.line}: ${e.text}`);
}
const stale = added.length + changed.length + removed.length;
if (check && stale) failed = true;
console.log(`sync-code: ${wanted.size} files from ${entries.length} list lines, ${Object.keys(lock.ported).length} ported: ${added.length} ${dry ? 'to add' : 'added'}, ${changed.length} ${dry ? 'to change' : 'changed'}, ${removed.length} ${dry ? 'to remove' : 'removed'}, ${same} unchanged`);
process.exit(failed ? 1 : 0);
