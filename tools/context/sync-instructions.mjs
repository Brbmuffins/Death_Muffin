#!/usr/bin/env node
// CLAUDE.md is the one written source of the repository's instructions; AGENTS.md is its exact copy, because Codex loads AGENTS.md (from
// the project root down to the folder it starts in) and Claude Code loads CLAUDE.md (tools/context/README.md "The audiences"). Edit
// CLAUDE.md, then run this to write the copy; CI runs --check, which never repairs anything: a missing, empty or stale copy fails.
//
//   node tools/context/sync-instructions.mjs            write AGENTS.md from CLAUDE.md
//   node tools/context/sync-instructions.mjs --check    exit 1 when AGENTS.md is missing, empty or differs from CLAUDE.md

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(HERE, '..', '..');
export const SOURCE = 'CLAUDE.md';
export const MIRRORS = ['AGENTS.md'];

const read = (f) => { try { return fs.readFileSync(f); } catch { return null; } };

// Problems with the copies, as text; [] when every copy is byte for byte the source.
export function checkMirrors(root = REPO) {
  const src = read(path.join(root, SOURCE));
  if (!src || !src.toString('utf8').trim()) return [`${SOURCE} is missing or empty: it is the source of ${MIRRORS.join(', ')}`];
  const problems = [];
  for (const m of MIRRORS) {
    const b = read(path.join(root, m));
    if (b == null) problems.push(`${m} is missing: run node tools/context/sync-instructions.mjs`);
    else if (!b.toString('utf8').trim()) problems.push(`${m} is empty: run node tools/context/sync-instructions.mjs`);
    else if (!b.equals(src)) problems.push(`${m} differs from ${SOURCE}: edit ${SOURCE} only, then run node tools/context/sync-instructions.mjs`);
  }
  return problems;
}

export function writeMirrors(root = REPO) {
  const src = read(path.join(root, SOURCE));
  if (!src || !src.toString('utf8').trim()) throw new Error(`${SOURCE} is missing or empty`);
  const changed = [];
  for (const m of MIRRORS) {
    const f = path.join(root, m);
    const b = read(f);
    if (b && b.equals(src)) continue;
    fs.writeFileSync(f, src);
    changed.push(m);
  }
  return changed;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  if (process.argv[2] === '--check') {
    const p = checkMirrors();
    for (const x of p) console.error(`PROBLEM ${x}`);
    if (!p.length) console.log(`${MIRRORS.join(', ')}: the same as ${SOURCE}`);
    process.exit(p.length ? 1 : 0);
  } else if (process.argv[2]) { console.error(`unknown argument ${process.argv[2]}`); process.exit(2); }
  const c = writeMirrors();
  console.log(c.length ? `wrote ${c.join(', ')} from ${SOURCE}` : `${MIRRORS.join(', ')} already the same as ${SOURCE}`);
}
