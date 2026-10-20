#!/usr/bin/env node
// How much rule text each audience carries, and whether the rule inventory still matches it (tools/context/README.md).
// Sizes: the always-loaded text of each audience in surfaces.json (CLAUDE.md for sessions, the agent's prompt), split by `## ` section,
// and the files each is told to read first. Tokens are estimated from characters (surfaces.json charsPerToken, measured on the agent's
// own calls: its first-call context grew about one token per 2.7 characters of prompt). The rule check (rules.json): every anchor is
// still in its file, every protected rule keeps an always-loaded home for each audience it names (or says why not), every
// enforcing file exists, and every section of the always-loaded text holds at least one inventoried rule.
//
//   node tools/context/measure.mjs [--json out.json]      exit 1 when the rule check finds a problem

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.resolve(HERE, '..', '..');

const readJson = (root, f) => JSON.parse(fs.readFileSync(path.join(root, f), 'utf8'));
const readText = (root, f) => { try { return fs.readFileSync(path.join(root, f), 'utf8'); } catch { return null; } };

// A Markdown file's `## ` sections: [{title, start, end, chars}]; the text before the first heading is the preamble.
export function sections(text) {
  const out = [];
  const re = /^## (.+)$/gm;
  let m, last = { title: '(preamble)', start: 0 };
  while ((m = re.exec(text))) { out.push({ ...last, end: m.index }); last = { title: m[1].trim(), start: m.index }; }
  out.push({ ...last, end: text.length });
  return out.map((s) => ({ ...s, chars: s.end - s.start })).filter((s) => s.chars > 0);
}

export function sizes(root = REPO) {
  const surfaces = readJson(root, 'tools/context/surfaces.json');
  const cpt = surfaces.charsPerToken;
  const tok = (chars) => Math.round(chars / cpt);
  const result = { charsPerToken: cpt, audiences: {} };
  for (const [name, a] of Object.entries(surfaces.audiences)) {
    const always = a.always.map((f) => {
      const t = readText(root, f) ?? '';
      return { file: f, chars: t.length, tokens: tok(t.length), sections: sections(t).map((s) => ({ title: s.title, chars: s.chars, tokens: tok(s.chars) })) };
    });
    const readFirst = a.readFirst.map((f) => { const t = readText(root, f) ?? ''; return { file: f, chars: t.length, tokens: tok(t.length) }; });
    result.audiences[name] = {
      what: a.what, always, readFirst,
      alwaysTokens: always.reduce((n, f) => n + f.tokens, 0), readFirstTokens: readFirst.reduce((n, f) => n + f.tokens, 0),
    };
  }
  return result;
}

export function checkRules(root = REPO) {
  const surfaces = readJson(root, 'tools/context/surfaces.json');
  const { rules } = readJson(root, 'tools/context/rules.json');
  const problems = [];
  const texts = {};
  const text = (f) => (f in texts ? texts[f] : (texts[f] = readText(root, f)));
  const ids = new Set();
  const covered = {}; // always-loaded file -> set of section titles holding an anchor
  for (const r of rules) {
    if (ids.has(r.id)) problems.push(`${r.id}: duplicate id`);
    ids.add(r.id);
    for (const k of ['kind', 'audience', 'homes', 'summary', 'when']) if (r[k] == null) problems.push(`${r.id}: missing ${k}`);
    for (const h of r.homes || []) {
      const t = text(h.file);
      if (t == null) { problems.push(`${r.id}: home ${h.file} does not exist`); continue; }
      const at = h.anchor ? t.indexOf(h.anchor) : -1;
      if (at < 0) { problems.push(`${r.id}: anchor not found in ${h.file}: ${JSON.stringify(h.anchor)}`); continue; }
      const sec = sections(t).find((s) => at >= s.start && at < s.end);
      (covered[h.file] = covered[h.file] || new Set()).add(sec.title);
    }
    for (const f of r.enforced || []) if (!fs.existsSync(path.join(root, f))) problems.push(`${r.id}: enforcing file ${f} does not exist`);
    if (r.protected) {
      for (const who of r.audience) {
        const always = surfaces.audiences[who]?.always || [];
        const home = (r.homes || []).some((h) => always.includes(h.file) && text(h.file)?.includes(h.anchor));
        const gap = (r.gaps || []).some((g) => g.audience === who);
        if (!home && !gap) problems.push(`${r.id}: protected rule has no always-loaded home for ${who} (${always.join(', ')}) and no gap note`);
      }
    }
  }
  for (const a of Object.values(surfaces.audiences)) {
    for (const f of a.always) {
      const t = text(f);
      if (t == null) { problems.push(`surfaces.json: ${f} does not exist`); continue; }
      for (const s of sections(t)) {
        if (s.title === '(preamble)' || covered[f]?.has(s.title)) continue;
        problems.push(`${f}: section "${s.title}" holds no inventoried rule: add its rules to tools/context/rules.json`);
      }
    }
  }
  return { rules: rules.length, protectedRules: rules.filter((r) => r.protected).length, gaps: rules.flatMap((r) => (r.gaps || []).map((g) => ({ id: r.id, ...g }))), problems };
}

function main(argv) {
  const json = argv[0] === '--json' ? argv[1] : null;
  const s = sizes();
  const c = checkRules();
  for (const [name, a] of Object.entries(s.audiences)) {
    console.log(`== ${name}: ${a.what}`);
    for (const f of a.always) {
      console.log(`   always loaded: ${f.file} ${f.chars} chars, ~${f.tokens} tokens`);
      for (const sec of f.sections) console.log(`     ${String(sec.tokens).padStart(6)}  ${sec.title}`);
    }
    console.log(`   told to read first: ~${a.readFirstTokens} tokens (${a.readFirst.map((f) => `${f.file} ~${f.tokens}`).join(', ')})`);
  }
  console.log(`== rules: ${c.rules} inventoried (${c.protectedRules} protected), ${c.gaps.length} gap notes`);
  for (const g of c.gaps) console.log(`   gap ${g.id} (${g.audience}): ${g.note}`);
  for (const p of c.problems) console.log(`   PROBLEM ${p}`);
  if (json) fs.writeFileSync(json, JSON.stringify({ sizes: s, rules: c }, null, 2) + '\n');
  process.exit(c.problems.length ? 1 : 0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
