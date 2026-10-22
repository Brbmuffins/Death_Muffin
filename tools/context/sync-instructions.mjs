#!/usr/bin/env node
// AGENTS.md is the one written source of the repository's instructions: Codex reads it directly (as bytes, no imports), and Claude Code
// reads CLAUDE.md, which only imports it (`@AGENTS.md`; tools/context/README.md "The audiences"). This script keeps that shape.
//
//   node tools/context/sync-instructions.mjs            validate AGENTS.md, then write or repair the CLAUDE.md import (what regen-godot.sh runs)
//   node tools/context/sync-instructions.mjs --check    read-only: exit 1 when AGENTS.md or CLAUDE.md is not in that shape (CI)
//
// The no-argument mode writes CLAUDE.md only when it is missing or is still the old full copy of AGENTS.md (byte for byte, so nothing is
// lost); any other text in CLAUDE.md fails without writing, because it would reach Claude only. It never writes AGENTS.md.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(HERE, '..', '..');
export const SOURCE = 'AGENTS.md';
export const ENTRY = 'CLAUDE.md';
export const STUB = '<!-- Claude Code reads this file; the project rules live in AGENTS.md, which Codex reads directly. Edit AGENTS.md only. -->\n@AGENTS.md\n';
// Codex's default byte budget for project instructions (Codex CLI 0.163.0): a repository ceiling, not a setting this script reads.
export const CODEX_MAX_BYTES = 32 * 1024;

// The Markdown that instruction loaders treat specially (Claude Code: code.claude.com/docs/en/memory; probes 2026-10-21, reviews/
// shared-instructions-probes.log): fenced blocks and indented code are code; HTML comments outside code are removed before Claude sees the
// text (block comments are documented and probed; inline ones are removed here too, the stricter reading); an `@path` outside code spans,
// code and comments is an import. Returns the text Claude Code would deliver and the imports it would follow.
export function claudeView(text) {
  const lines = String(text).replace(/\r\n/g, '\n').split('\n');
  const out = [];
  const imports = [];
  let fence = null, inComment = false, prevBlank = true, prevIndentedCode = false;
  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    if (!inComment) {
      const f = /^\s{0,3}(```+|~~~+)/.exec(line);
      if (fence) { out.push(line); if (f && f[1][0] === fence[0] && f[1].length >= fence.length) fence = null; prevBlank = false; continue; }
      if (f) { fence = f[1]; out.push(line); prevBlank = false; continue; }
      const indented = /^( {4}|\t)/.test(line) && line.trim() !== '' && (prevBlank || prevIndentedCode);
      if (indented) { out.push(line); prevIndentedCode = true; prevBlank = false; continue; }
      prevIndentedCode = false;
    }
    // comments, possibly spanning lines
    let kept = '';
    let rest = line;
    while (rest.length) {
      if (inComment) { const e = rest.indexOf('-->'); if (e < 0) { rest = ''; break; } inComment = false; rest = rest.slice(e + 3); continue; }
      const s = rest.indexOf('<!--');
      if (s < 0) { kept += rest; break; }
      kept += rest.slice(0, s); inComment = true; rest = rest.slice(s + 4);
    }
    const wasComment = kept.trim() === '' && line.trim() !== '';
    if (wasComment) continue;   // a line that held only a comment is gone, as Claude Code delivers it
    const noSpans = kept.replace(/(`+)[\s\S]*?\1/g, (m) => ' '.repeat(m.length));
    for (const m of noSpans.matchAll(/(^|\s)@([^\s`]+)/g)) imports.push({ path: m[2], line: i + 1, alone: kept.trim() === '@' + m[2] && !/^\s/.test(kept) });
    out.push(kept);
    prevBlank = kept.trim() === '';
  }
  return { text: out.join('\n'), imports };
}

const readBuf = (root, f) => { try { return fs.readFileSync(path.join(root, f)); } catch { return null; } };

// Problems with the source (AGENTS.md) alone: what the no-argument mode checks before it writes anything.
export function checkSource(root = REPO) {
  const b = readBuf(root, SOURCE);
  if (b == null) return [`${SOURCE} is missing: it is the one written source of the instructions`];
  const t = b.toString('utf8');
  const p = [];
  if (!t.trim()) p.push(`${SOURCE} is empty`);
  if (b.length > CODEX_MAX_BYTES) p.push(`${SOURCE} is ${b.length} bytes, over the ${CODEX_MAX_BYTES} Codex reads by default: move task detail to a guide`);
  for (const im of claudeView(t).imports) p.push(`${SOURCE}:${im.line}: "@${im.path}" is an import; Codex does not follow imports, so ${SOURCE} must hold its text itself`);
  return p;
}

// Problems with CLAUDE.md: it must deliver exactly one import of AGENTS.md and nothing else (comments allowed, they are not delivered).
export function checkEntry(root = REPO) {
  const b = readBuf(root, ENTRY);
  if (b == null) return [`${ENTRY} is missing: it must import ${SOURCE} (node tools/context/sync-instructions.mjs writes it)`];
  const v = claudeView(b.toString('utf8'));
  const p = [];
  const delivered = v.text.split('\n').filter((l) => l.trim() !== '');
  const ok = v.imports.length === 1 && v.imports[0].path === SOURCE && v.imports[0].alone && delivered.length === 1;
  if (!ok) {
    if (!v.imports.some((im) => im.path === SOURCE && im.alone)) p.push(`${ENTRY} does not import ${SOURCE}: it must hold one line "@${SOURCE}" outside code and comments`);
    if (v.imports.length > 1 || v.imports.some((im) => im.path !== SOURCE)) p.push(`${ENTRY} imports something else as well (${v.imports.map((im) => '@' + im.path).join(', ')}): only "@${SOURCE}"`);
    // Count delivered lines, not distinct texts: an indented copy of the import is code (delivered, not imported) and trims to the same text.
    const active = v.imports.filter((im) => im.path === SOURCE && im.alone).length;
    if (delivered.length > Math.min(active, 1)) p.push(`${ENTRY} holds text besides the import, which only Claude would see: move it into ${SOURCE}`);
    // Every shape that is not the stub gets a reason, even one no rule above names.
    if (!p.length) p.push(`${ENTRY} is not the import stub: it must hold only one line "@${SOURCE}" (and comments)`);
  }
  if (readBuf(root, SOURCE) == null) p.push(`${ENTRY} imports ${SOURCE}, which is missing`);
  return p;
}

export function checkInstructions(root = REPO) { return [...checkSource(root), ...checkEntry(root)]; }

// The no-argument mode: validate the source first; write the stub only over a missing CLAUDE.md or the old full copy; never AGENTS.md.
// Returns { wrote: bool, problems: [] }.
export function writeStub(root = REPO) {
  const src = checkSource(root);
  if (src.length) return { wrote: false, problems: src };
  if (!checkEntry(root).length) return { wrote: false, problems: [] };
  const entry = readBuf(root, ENTRY);
  const source = readBuf(root, SOURCE);
  if (entry == null || entry.equals(source)) { fs.writeFileSync(path.join(root, ENTRY), STUB); return { wrote: true, problems: [] }; }
  return { wrote: false, problems: checkEntry(root) };
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const arg = process.argv[2];
  if (arg === '--check') {
    const p = checkInstructions();
    for (const x of p) console.error(`PROBLEM ${x}`);
    if (!p.length) console.log(`${ENTRY} imports ${SOURCE}; ${SOURCE} is self-contained`);
    process.exit(p.length ? 1 : 0);
  }
  if (arg) { console.error(`unknown argument ${arg}`); process.exit(2); }
  const r = writeStub();
  for (const x of r.problems) console.error(`PROBLEM ${x}`);
  if (r.problems.length) { console.error('nothing was written'); process.exit(1); }
  console.log(r.wrote ? `repaired ${ENTRY}: now the @${SOURCE} import` : `${ENTRY} already imports ${SOURCE}`);
}
