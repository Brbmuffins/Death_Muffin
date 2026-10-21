#!/usr/bin/env node
// The navigation check for the documentation map and the client's guides (tools/context/README.md "Navigation check"). It proves the
// routes resolve; it cannot prove a guide is complete. Scope: README.md's documentation map, the instruction files, client/README.md and
// every guide the old manual's sections moved to (doc-moves.json), and every link or quoted section reference that points into them.
// - every old section of the manual has its anchor in client/README.md, on a row that links each of its new homes; each home exists
//   and holds its heading; each moved bold label is still in its file;
// - README.md has its "Documentation map" and every link in it resolves;
// - a Markdown link into a file in scope resolves, fragment included (GitHub's heading slugs, duplicates numbered, and explicit
//   <a id> anchors; fenced code is skipped);
// - a quoted section reference into a file in scope (`path.md "Label"`, `[x](path.md) "Label"`, `path.md ("Label")`) names a heading or
//   a bold label of that file, and none uses an old section of client/README.md except the few kept on purpose (doc-moves.json `kept`).
// npm run hygiene runs it over the tracked files (tools/hygiene/check.mjs).
//
//   node tools/context/navigation.mjs      exit 1 on a problem

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(HERE, '..', '..');
const SCAN = /\.(md|gd|cjs|mjs|js|ts|sh|json|gdshader|py|yml|h|cpp)$/;

// GitHub's slug of a heading: lower case, punctuation but - and _ dropped, spaces to -.
export const slug = (t) => t.trim().toLowerCase().replace(/<[^>]+>/g, '').replace(/[^\p{L}\p{N}\- _]/gu, '').replace(/ /g, '-');

// Blank out fenced code (keeping line numbers).
export function stripFences(text) {
  let fence = false;
  return text.split('\n').map((l) => { if (/^\s*(```|~~~)/.test(l)) { fence = !fence; return ''; } return fence ? '' : l; }).join('\n');
}

// What a document can be linked to: heading slugs (a repeated slug gets -1, -2, ...) and explicit anchors.
export function anchorsOf(text) {
  const out = new Set(); const seen = {};
  const t = stripFences(text);
  for (const m of t.matchAll(/^#{1,6} +(.+?) *#*$/gm)) {
    const s = slug(m[1].replace(/`/g, ''));
    const n = seen[s] || 0; seen[s] = n + 1;
    out.add(n ? `${s}-${n}` : s);
  }
  for (const m of t.matchAll(/<a\s+(?:id|name)="([^"]+)"/g)) out.add(m[1]);
  return out;
}

// What a quoted reference can name: a heading's text, or a bold label that starts a paragraph or a list item.
// A trailing parenthetical is optional: "Play reports (how a real session ran)" answers to "Play reports" too.
export function labelsOf(text) {
  const out = new Set();
  const add = (l) => { const x = l.replace(/`/g, '').replace(/[.:]$/, '').trim(); out.add(x); out.add(x.replace(/\s*\([^()]*\)$/, '')); };
  const t = stripFences(text);
  for (const m of t.matchAll(/^#{1,6} +(.+?) *#*$/gm)) add(m[1]);
  for (const m of t.matchAll(/(?:^|\n)\s*(?:[-*] |\| )?\*\*([^*\n]+?)\*\*/g)) add(m[1]);
  return out;
}

function trackedFiles(root) {
  try {
    return execFileSync('git', ['ls-files', '-z'], { cwd: root, maxBuffer: 1 << 28, stdio: ['ignore', 'pipe', 'ignore'] }).toString().split('\0').filter((f) => f && fs.existsSync(path.join(root, f)));
  } catch {
    const out = [];
    const walk = (d) => { for (const e of fs.readdirSync(path.join(root, d), { withFileTypes: true })) { const f = d ? `${d}/${e.name}` : e.name; if (e.isDirectory()) { if (e.name !== '.git' && e.name !== 'node_modules') walk(f); } else out.push(f); } };
    walk('');
    return out;
  }
}

const ROOT_PREFIXES = ['client/', 'native/', 'server/', 'tools/', 'launcher/', 'teamapp/', 'docs/', '.github/'];

export function checkNavigation(root = REPO, files = trackedFiles(root)) {
  const problems = [];
  const bad = (file, line, msg) => problems.push({ file, line, msg });
  const cache = {};
  const read = (f) => (f in cache ? cache[f] : (cache[f] = fs.existsSync(path.join(root, f)) && fs.statSync(path.join(root, f)).isFile() ? fs.readFileSync(path.join(root, f), 'utf8') : null));
  const lineOf = (text, i) => text.slice(0, i).split('\n').length;
  const movesFile = 'tools/context/doc-moves.json';
  const moves = JSON.parse(read(movesFile));
  const from = moves.from;
  const index = read(from);
  if (index == null) { bad(from, 1, 'the client index is missing'); return problems; }
  const scope = new Set(['README.md', 'CLAUDE.md', 'AGENTS.md', from]);
  const oldTitles = new Map();   // an old section's title -> its move
  for (const m of moves.moves) {
    oldTitles.set(m.title, m);
    const row = index.split('\n').find((l) => l.includes(`<a id="${m.fragment}"></a>`));
    if (!row) bad(from, 1, `the old link ${from}#${m.fragment} ("${m.title}") has no <a id="${m.fragment}"> anchor left in it`);
    for (const to of m.to) {
      const [file, frag] = to.split('#');
      scope.add(file);
      const t = read(file);
      if (t == null || !t.trim()) { bad(movesFile, 1, `"${m.title}" moved to ${file}, which is missing or empty`); continue; }
      if (frag && !anchorsOf(t).has(frag)) bad(file, 1, `"${m.title}" moved to ${to}, but ${file} has no heading for #${frag}`);
      const rel = path.posix.relative(path.posix.dirname(from), file);
      if (row && !row.includes(`](${rel}`)) bad(from, lineOf(index, index.indexOf(row)), `the row of the old link #${m.fragment} does not link ${rel}`);
    }
  }
  for (const [label, file] of Object.entries(moves.labels || {})) {
    scope.add(file);
    const t = read(file);
    if (t != null && !labelsOf(t).has(label)) bad(file, 1, `the label "${label}" (${movesFile}) is not in ${file}`);
  }
  const readme = read('README.md') || '';
  const map = /^## Documentation map\n([\s\S]*?)(?=^## )/m.exec(readme);
  if (!map) bad('README.md', 1, 'README.md has no "## Documentation map" section');
  else for (const l of map[1].matchAll(/\]\(([^)#\s]+)/g)) if (!/^[a-z]+:/.test(l[1]) && read(path.posix.normalize(l[1])) == null) bad('README.md', lineOf(readme, map.index + l.index), `the documentation map links ${l[1]}, which does not exist`);
  const kept = new Set((moves.kept || []).map((k) => k.file));
  const resolve = (doc, target) => path.posix.normalize(path.posix.join(path.posix.dirname(doc), target));
  for (const f of files) {
    if (!SCAN.test(f) || f === movesFile || f.startsWith('tools/context/test/') || f.split('/').includes('node_modules')) continue;   // the tests' strings are fixtures
    const raw = read(f);
    if (raw == null || !raw.includes('.md')) continue;
    const isMd = f.endsWith('.md');
    const text = isMd ? stripFences(raw) : raw;
    // Markdown links into the scope, with their fragments
    if (isMd) {
      for (const m of text.matchAll(/(?<!!)\[[^\]]*\]\(([^)\s]+)\)/g)) {
        const target = m[1];
        if (/^[a-z]+:/.test(target)) continue;
        const [p, frag] = target.split('#');
        const file = p ? resolve(f, p) : f;
        if (!scope.has(file)) continue;
        const t = read(file);
        if (t == null) { bad(f, lineOf(text, m.index), `link to ${target}: ${file} does not exist`); continue; }
        if (frag && !anchorsOf(t).has(frag)) bad(f, lineOf(text, m.index), `link to ${target}: ${file} has no heading or anchor #${frag}`);
      }
    }
    // Quoted section references into the scope
    const re = /(?:\]\(([^)\s#]+\.md)\)|((?:[\w.-]+\/)*[\w.-]+\.md))`?:? \(?\\?"([^"\\\n]{2,80})\\?"/g;
    for (const m of text.matchAll(re)) {
      const ref = m[1] ? resolve(f, m[1]) : (ROOT_PREFIXES.some((x) => m[2].startsWith(x)) || !m[2].includes('/') ? m[2] : resolve(f, m[2]));
      if (!scope.has(ref)) continue;
      const label = m[3];
      const t = read(ref);
      if (t == null) continue;
      if (ref === from && oldTitles.has(label) && !labelsOf(t).has(label)) {
        if (!kept.has(f)) bad(f, lineOf(text, m.index), `${from} "${label}" is an old section: point at ${oldTitles.get(label).to.join(' or ')}`);
        continue;
      }
      if (ref === from && kept.has(f)) continue;
      if (!labelsOf(t).has(label)) bad(f, lineOf(text, m.index), `${ref} has no heading or bold label "${label}"`);
    }
  }
  return problems;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const p = checkNavigation();
  for (const x of p) console.error(`${x.file}:${x.line}: ${x.msg}`);
  console.log(p.length ? `navigation: ${p.length} problem(s)` : 'navigation: OK');
  process.exit(p.length ? 1 : 0);
}
