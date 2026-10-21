#!/usr/bin/env node
// How much rule text each audience carries, and whether the rule inventory still matches it (tools/context/README.md).
// Sizes: the always-loaded text of each audience in surfaces.json (CLAUDE.md for sessions, the agent's prompt), split by `## ` section,
// and the files each is told to read first. Tokens are estimated from characters (surfaces.json charsPerToken, measured on the agent's
// own calls: its first-call context grew about one token per 2.7 characters of prompt); they are estimates of text size, not API usage
// (usage.mjs reports that). The rule check (rules.json, protected.json): the inventory's shape, every clause still in its file, protected
// clauses that are instructions rather than headings, an always-loaded home for each audience of a protected rule (or a gap with a note),
// the lock on protected rules, enforcing files that exist, and no section of always-loaded text without an inventoried rule.
//
//   node tools/context/measure.mjs [--json out.json]      exit 1 when the rule check finds a problem
//   node tools/context/measure.mjs --print-lock           the protected.json entries the inventory has now (copy only what you mean to change)

import crypto from 'node:crypto';
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

const KINDS = ['boundary', 'principle', 'convention', 'protocol', 'playbook'];
const RULE_KEYS = ['id', 'kind', 'protected', 'audience', 'when', 'summary', 'homes', 'enforced', 'gaps'];
// Whitespace never matters in a clause: rewrapping a line keeps it, deleting or rewording its words does not.
export const norm = (t) => String(t).replace(/\s+/g, ' ').trim();
const words = (t) => norm(t).split(' ').filter(Boolean).length;
// A protected clause must be an instruction, not a label: no heading, no bold-only phrase, at least six words.
function weakClause(c) {
  const t = norm(c);
  if (t.startsWith('#')) return 'is a heading';
  if (/^\*\*[^*]+\*\*[.:]?$/.test(t)) return 'is only a bold label';
  if (words(t) < 6) return 'has fewer than six words';
  return null;
}
// What protected.json locks for a rule: its audiences and its clauses (file by file, whitespace-normalized), hashed.
export function clauseDigest(rule) {
  const homes = (rule.homes || []).map((h) => [h.file, (h.clauses || []).map(norm).sort()]).sort((a, b) => (a[0] + a[1].join('\n')).localeCompare(b[0] + b[1].join('\n')));
  return 'sha256:' + crypto.createHash('sha256').update(JSON.stringify(homes)).digest('hex');
}
export function lockFor(rules) {
  const out = {};
  for (const r of rules) if (r.protected === true) out[r.id] = { audience: [...r.audience].sort(), clauses: clauseDigest(r), acceptedGaps: (r.gaps || []).map((g) => g.audience).sort() };
  return out;
}

export function checkRules(root = REPO) {
  const surfaces = readJson(root, 'tools/context/surfaces.json');
  const inv = readJson(root, 'tools/context/rules.json');
  const lock = readJson(root, 'tools/context/protected.json').rules || {};
  const rules = Array.isArray(inv.rules) ? inv.rules : [];
  const problems = [];
  if (!Array.isArray(inv.rules)) problems.push('rules.json: "rules" must be a list');
  const audiences = Object.keys(surfaces.audiences || {});
  const texts = {};
  const text = (f) => (f in texts ? texts[f] : (texts[f] = readText(root, f)));
  const has = (f, clause) => { const t = text(f); return t != null && norm(t).includes(norm(clause)); };
  const ids = new Set();
  for (const [i, r] of rules.entries()) {
    const id = typeof r?.id === 'string' && /^[a-z0-9-]+$/.test(r.id) ? r.id : `rules[${i}]`;
    if (id !== r?.id) problems.push(`${id}: id must be lower-case words joined by dashes`);
    if (ids.has(id)) problems.push(`${id}: duplicate id`);
    ids.add(id);
    for (const k of Object.keys(r || {})) if (!RULE_KEYS.includes(k)) problems.push(`${id}: unknown field "${k}"`);
    if (!KINDS.includes(r.kind)) problems.push(`${id}: kind must be one of ${KINDS.join(', ')}`);
    if (typeof r.protected !== 'boolean') problems.push(`${id}: protected must be true or false`);
    if (r.protected === true && r.kind !== 'boundary') problems.push(`${id}: a protected rule is a boundary`);
    for (const k of ['when', 'summary']) if (typeof r[k] !== 'string' || !norm(r[k])) problems.push(`${id}: ${k} must be a non-empty text`);
    const aud = Array.isArray(r.audience) ? r.audience : [];
    if (!aud.length) problems.push(`${id}: audience must name at least one audience`);
    for (const a of aud) if (!audiences.includes(a)) problems.push(`${id}: unknown audience "${a}" (surfaces.json has ${audiences.join(', ')})`);
    if (new Set(aud).size !== aud.length) problems.push(`${id}: audience lists one twice`);
    const homes = Array.isArray(r.homes) ? r.homes : [];
    if (!homes.length) problems.push(`${id}: homes must name at least one place the rule is written`);
    for (const h of homes) {
      if (typeof h?.file !== 'string' || !h.file) { problems.push(`${id}: a home has no file`); continue; }
      if (!Array.isArray(h.clauses) || !h.clauses.length || h.clauses.some((c) => typeof c !== 'string' || !norm(c))) { problems.push(`${id}: home ${h.file} needs a non-empty list of clauses`); continue; }
      if (text(h.file) == null) { problems.push(`${id}: home ${h.file} does not exist`); continue; }
      for (const c of h.clauses) {
        if (!has(h.file, c)) problems.push(`${id}: clause not found in ${h.file}: ${JSON.stringify(c)}`);
        const weak = r.protected === true && weakClause(c);
        if (weak) problems.push(`${id}: protected clause ${JSON.stringify(c)} ${weak}: name the instruction itself`);
      }
    }
    if (!Array.isArray(r.enforced)) problems.push(`${id}: enforced must be a list (empty when only the text holds the rule)`);
    for (const f of r.enforced || []) if (typeof f !== 'string' || !fs.existsSync(path.join(root, f))) problems.push(`${id}: enforcing file ${f} does not exist`);
    if (r.gaps !== undefined && !Array.isArray(r.gaps)) problems.push(`${id}: gaps must be a list`);
    for (const g of r.gaps || []) {
      if (!aud.includes(g?.audience)) problems.push(`${id}: a gap names "${g?.audience}", which is not one of the rule's audiences`);
      if (typeof g?.note !== 'string' || words(g.note) < 4) problems.push(`${id}: the gap for ${g?.audience} needs a note saying why (at least four words)`);
      for (const k of Object.keys(g || {})) if (!['audience', 'note'].includes(k)) problems.push(`${id}: unknown gap field "${k}"`);
    }
    if (r.protected === true) {
      for (const who of aud) {
        const always = surfaces.audiences[who]?.always || [];
        const home = homes.some((h) => always.includes(h.file) && Array.isArray(h.clauses) && h.clauses.length && h.clauses.every((c) => has(h.file, c)));
        const gap = (r.gaps || []).some((g) => g?.audience === who);
        if (!home && !gap) problems.push(`${id}: protected rule has no always-loaded home for ${who} (${always.join(', ')}) and no gap`);
      }
    }
  }
  // The lock: a protected rule cannot disappear, stop being protected, lose an audience, change its clauses or gain a gap unless
  // protected.json changes with it, which shows in the change's diff. CI cannot tell whether anyone reviewed that diff, nor whether
  // reworded text still means the same.
  const now = lockFor(rules.filter((r) => typeof r?.id === 'string'));
  for (const [id, want] of Object.entries(lock)) {
    const r = rules.find((x) => x?.id === id);
    const have = now[id];
    if (!r) { problems.push(`${id}: protected rule removed from rules.json (protected.json still locks it)`); continue; }
    if (!have) { problems.push(`${id}: no longer protected (protected.json locks it as protected)`); continue; }
    const lost = want.audience.filter((a) => !have.audience.includes(a));
    if (lost.length) problems.push(`${id}: protected rule lost audience ${lost.join(', ')} (protected.json locks it)`);
    if (want.clauses !== have.clauses) problems.push(`${id}: protected clauses changed (now ${have.clauses}); update its entry in protected.json in the same change`);
    for (const a of have.acceptedGaps) if (!want.acceptedGaps.includes(a)) problems.push(`${id}: new exception: a gap for ${a} that protected.json does not accept`);
    for (const a of want.acceptedGaps) if (!have.acceptedGaps.includes(a)) problems.push(`${id}: protected.json accepts a gap for ${a} that rules.json no longer has; remove it from protected.json`);
  }
  for (const id of Object.keys(now)) if (!lock[id]) problems.push(`${id}: new protected rule: add it to protected.json (node tools/context/measure.mjs --print-lock prints the entries)`);
  // Every section of always-loaded text holds at least one inventoried rule, so a new section cannot slip in unlisted.
  for (const a of Object.values(surfaces.audiences || {})) {
    for (const f of a.always) {
      const t = text(f);
      if (t == null) { problems.push(`surfaces.json: ${f} does not exist`); continue; }
      const clauses = rules.flatMap((r) => (Array.isArray(r?.homes) ? r.homes : []).filter((h) => h?.file === f).flatMap((h) => (Array.isArray(h.clauses) ? h.clauses : [])));
      for (const s of sections(t)) {
        if (s.title === '(preamble)') continue;
        const body = norm(t.slice(s.start, s.end));
        if (clauses.some((c) => typeof c === 'string' && norm(c) && body.includes(norm(c)))) continue;
        problems.push(`${f}: section "${s.title}" holds no inventoried rule: add its rules to tools/context/rules.json`);
      }
    }
  }
  return {
    rules: rules.length, protectedRules: rules.filter((r) => r?.protected === true).length,
    gaps: rules.flatMap((r) => (Array.isArray(r?.gaps) ? r.gaps : []).map((g) => ({ id: r.id, protected: r.protected === true, accepted: r.protected === true ? !!lock[r.id]?.acceptedGaps?.includes(g?.audience) : null, ...g }))),
    problems,
  };
}

function main(argv) {
  if (argv[0] === '--print-lock') { console.log(JSON.stringify(lockFor(readJson(REPO, 'tools/context/rules.json').rules), null, 2)); return; }
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
  for (const g of c.gaps) console.log(`   gap ${g.id} (${g.audience}${g.protected ? (g.accepted ? ', protected, accepted in protected.json' : ', protected, NOT accepted') : ''}): ${g.note}`);
  for (const p of c.problems) console.log(`   PROBLEM ${p}`);
  if (json) fs.writeFileSync(json, JSON.stringify({ sizes: s, rules: c }, null, 2) + '\n');
  process.exit(c.problems.length ? 1 : 0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
