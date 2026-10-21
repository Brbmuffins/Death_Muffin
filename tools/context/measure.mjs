#!/usr/bin/env node
// How much rule text each audience carries, and whether the rule inventory still matches it (tools/context/README.md).
// Sizes: the always-loaded text of each audience in surfaces.json (CLAUDE.md for Claude sessions, AGENTS.md for Codex, the agent's prompt),
// split by `## ` section, the guides it reads when a task needs one (the agent's media how-tos, runner/lib/guides.cjs), the small entry points
// it starts a task from (`discovery`: a file, or one section of it), and the reference guides a task may open (`references`, never added to startup). Task routes (tasks.json): what each representative task reads before and after the
// documentation map. Tokens are estimated from characters (surfaces.json charsPerToken, measured on the agent's
// own calls: its first-call context grew about one token per 2.7 characters of prompt); they are estimates of text size, not API usage
// (usage.mjs reports that). The rule check (rules.json, protected.json): the inventory's shape, every clause still in its file, protected
// clauses that are instructions rather than headings, an always-loaded home for each audience of a protected rule (or a gap with a note),
// the lock on protected rules, enforcing files that exist, no section of always-loaded text without an inventoried rule, and every guide an
// existing file that holds an inventoried rule (a guide is never an always-loaded home). Size warnings (surfaces.json `ceilings`): a file or
// section above its ceiling is printed for review and never fails; a missing, invalid or stale ceiling is a problem like the others.
//
//   node tools/context/measure.mjs [--json out.json]      exit 1 when the rule check finds a problem (a size warning alone does not)
//   node tools/context/measure.mjs --tasks [--json out]    the task routes, before (needs the `before` revision in the history) and after
//   node tools/context/measure.mjs --print-lock           the protected.json entries the inventory has now (copy only what you mean to change)

import { execFileSync } from 'node:child_process';
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

// A heading's section: from the heading whose text is `name` (or starts with `name (`) to the next heading of its level or above; null if none.
export function sectionText(text, name) {
  const lines = text.split('\n');
  let start = -1, level = 0, fence = false;
  for (let i = 0; i < lines.length; i++) {
    if (/^\s*(```|~~~)/.test(lines[i])) fence = !fence;
    const m = !fence && /^(#{1,6}) +(.+?) *$/.exec(lines[i]);
    if (!m) continue;
    if (start >= 0 && m[1].length <= level) return lines.slice(start, i).join('\n');
    if (start < 0 && (m[2] === name || m[2].startsWith(name + ' ('))) { start = i; level = m[1].length; }
  }
  return start >= 0 ? lines.slice(start).join('\n') : null;
}
// One discovery or route entry's text: a file, or one of its sections.
const entryText = (text, e) => (text == null ? null : e.section ? sectionText(text, e.section) : text);
const entryName = (e) => (e.section ? `${e.file} "${e.section}"` : e.file);

// Each measured file or section carries its warning ceiling from surfaces.json `ceilings` (null when none is set: ceilingCheck reports that).
export function sizes(root = REPO) {
  const surfaces = readJson(root, 'tools/context/surfaces.json');
  const cpt = surfaces.charsPerToken;
  const tok = (chars) => Math.round(chars / cpt);
  const c = surfaces.ceilings && typeof surfaces.ceilings === 'object' ? surfaces.ceilings : {};
  const ceiling = (table, key) => (table && typeof table === 'object' && Number.isInteger(table[key]) && table[key] > 0 ? table[key] : null);
  const result = { charsPerToken: cpt, audiences: {} };
  for (const [name, a] of Object.entries(surfaces.audiences)) {
    const always = a.always.map((f) => {
      const t = readText(root, f) ?? '';
      return { file: f, chars: t.length, tokens: tok(t.length), ceiling: ceiling(c.always, name), sections: sections(t).map((s) => ({ title: s.title, chars: s.chars, tokens: tok(s.chars) })) };
    });
    const size = (f) => { const t = readText(root, f) ?? ''; return { file: f, chars: t.length, tokens: tok(t.length), ceiling: ceiling(c.guides, name) }; };
    const guides = (a.guides || []).map(size);
    const discovery = (a.discovery || []).map((e) => { const t = entryText(readText(root, e.file), e) ?? ''; return { entry: entryName(e), chars: t.length, tokens: tok(t.length), ceiling: ceiling(c.discovery, entryName(e)) }; });
    const sum = (xs) => xs.reduce((n, f) => n + f.tokens, 0);
    result.audiences[name] = {
      what: a.what, always, guides, discovery,
      alwaysTokens: sum(always), guideTokens: sum(guides), discoveryTokens: sum(discovery),
    };
  }
  const refCeiling = Number.isInteger(c.references) && c.references > 0 ? c.references : null;
  result.references = (surfaces.references || []).map((f) => { const t = readText(root, f) ?? ''; return { file: f, chars: t.length, tokens: tok(t.length), ceiling: refCeiling }; });
  return result;
}

// Size warnings (tools/context/README.md "Size warnings"): every always-loaded file, guide, discovery entry and reference guide in
// surfaces.json has a ceiling in estimated tokens, and one above it is a warning, a prompt to explain the growth or move task detail to
// its guide in review, never a failure and never a reason to cut a safety rule. The configuration itself must be whole: a surface with no
// valid ceiling, a ceiling for a surface that is not listed, or an unknown field is a problem, so the warnings cannot quietly stop covering
// a file. Returns { warnings: [{ kind, entry, audiences, tokens, ceiling }], problems: [text] }.
const CEILING_KEYS = ['about', 'always', 'guides', 'discovery', 'references'];
export function ceilingCheck(root = REPO) {
  const surfaces = readJson(root, 'tools/context/surfaces.json');
  const c = surfaces.ceilings;
  if (!c || typeof c !== 'object' || Array.isArray(c)) return { warnings: [], problems: ['surfaces.json: "ceilings" is missing: every measured surface needs a warning ceiling (tools/context/README.md "Size warnings")'] };
  const s = sizes(root);
  const problems = [];
  const bad = (where) => problems.push(`surfaces.json: ceilings ${where} must be a positive whole number of estimated tokens`);
  for (const k of Object.keys(c)) if (!CEILING_KEYS.includes(k)) problems.push(`surfaces.json: ceilings has an unknown field "${k}"`);
  // One entry per surface: the discovery entries are shared by every audience, so each is measured and named once.
  const seen = new Map();
  const add = (kind, entry, who, x) => {
    const key = `${kind}\0${entry}`;
    if (seen.has(key)) { seen.get(key).audiences.push(who); return; }
    seen.set(key, { kind, entry, audiences: who ? [who] : [], tokens: x.tokens, ceiling: x.ceiling });
  };
  for (const kind of ['always', 'guides']) {
    const table = c[kind];
    if (table !== undefined && (typeof table !== 'object' || table === null || Array.isArray(table))) { problems.push(`surfaces.json: ceilings.${kind} must map each audience to its ceiling`); continue; }
    for (const k of Object.keys(table || {})) if (!(surfaces.audiences[k]?.[kind] || []).length) problems.push(`surfaces.json: ceilings.${kind} names "${k}", which has no ${kind === 'always' ? 'always-loaded files' : 'guides'}`);
    for (const [name, a] of Object.entries(s.audiences)) {
      if (!a[kind].length) continue;
      if (a[kind][0].ceiling == null) { bad(`.${kind}.${name}`); continue; }
      for (const f of a[kind]) add(kind, f.file, name, f);
    }
  }
  const disc = c.discovery && typeof c.discovery === 'object' && !Array.isArray(c.discovery) ? c.discovery : {};
  if (c.discovery !== undefined && disc !== c.discovery) problems.push('surfaces.json: ceilings.discovery must map each discovery entry to its ceiling');
  const entries = new Set(Object.values(s.audiences).flatMap((a) => a.discovery.map((d) => d.entry)));
  for (const k of Object.keys(disc)) if (!entries.has(k)) problems.push(`surfaces.json: ceilings.discovery names ${k}, which is no audience's discovery entry`);
  const unset = new Set();
  for (const [name, a] of Object.entries(s.audiences)) for (const d of a.discovery) (d.ceiling == null ? unset.add(d.entry) : add('discovery', d.entry, name, d));
  for (const e of unset) bad(`.discovery[${JSON.stringify(e)}]`);
  if (s.references.length && s.references[0].ceiling == null) bad('.references');
  else for (const f of s.references) add('references', f.file, null, f);
  const warnings = [...seen.values()].filter((w) => w.tokens > w.ceiling);
  return { warnings, problems };
}
const KIND_LABEL = { always: 'always loaded', guides: 'guide', discovery: 'discovery entry', references: 'reference guide' };
export const formatSizeWarning = (w) => `${w.entry} is ~${w.tokens} estimated tokens, above its ceiling of ${w.ceiling} (${KIND_LABEL[w.kind]}${w.audiences.length ? `, ${w.audiences.join(', ')}` : ''}): say why in review or move task detail to its guide; never cut a safety rule or raise the ceiling to hide this`;

// What each representative task reads (tasks.json): the before route at the `before` revision (null when that revision is not in this
// checkout's history, as in a shallow CI clone) and the after route in this tree; whether each holds the task's answer.
export function taskRoutes(root = REPO) {
  const cpt = readJson(root, 'tools/context/surfaces.json').charsPerToken;
  const spec = readJson(root, 'tools/context/tasks.json');
  const atRev = (f) => { try { return execFileSync('git', ['-C', root, 'show', `${spec.before}:${f}`], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 1 << 26 }); } catch { return null; } };
  const route = (entries, read) => {
    const parts = entries.map((e) => { const t = entryText(read(e.file), e); return { entry: entryName(e), chars: t == null ? null : t.length, tokens: t == null ? null : Math.round(t.length / cpt), text: t }; });
    if (parts.some((p) => p.text == null)) return { parts: parts.map(({ text, ...p }) => p), missing: parts.filter((p) => p.text == null).map((p) => p.entry) };
    return { parts: parts.map(({ text, ...p }) => p), chars: parts.reduce((n, p) => n + p.chars, 0), tokens: Math.round(parts.reduce((n, p) => n + p.chars, 0) / cpt), hasFact: (fact) => parts.some((p) => norm(p.text).includes(norm(fact))) };
  };
  return spec.tasks.map((t) => {
    const after = route(t.after, (f) => readText(root, f));
    const before = route(t.before, atRev);
    const guide = t.agentGuide ? readText(root, t.agentGuide) : null;
    const out = { id: t.id, question: t.question, fact: t.fact, rev: spec.before };
    for (const [k, r] of [['before', before], ['after', after]]) {
      out[k] = r.missing ? { unavailable: r.missing } : { parts: r.parts, chars: r.chars, tokens: r.tokens, answers: r.hasFact(t.fact) };
    }
    if (t.agentGuide) out.agentGuide = { file: t.agentGuide, tokens: guide == null ? null : Math.round(guide.length / cpt) };
    return out;
  });
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
  // Discovery entries, reference guides and the after side of the task routes exist (a section by its heading), and each route holds its
  // task's answer: a move that drops a route's file, section or answer fails here.
  for (const [name, a] of Object.entries(surfaces.audiences || {})) {
    for (const e of a.discovery || []) {
      if (typeof e?.file !== 'string') { problems.push(`surfaces.json: a discovery entry of ${name} has no file`); continue; }
      if (entryText(text(e.file), e) == null) problems.push(`surfaces.json: discovery ${entryName(e)} (${name}) does not exist`);
    }
  }
  for (const f of surfaces.references || []) if (text(f) == null) problems.push(`surfaces.json: reference ${f} does not exist`);
  const tasks = readText(root, 'tools/context/tasks.json');
  for (const t of tasks ? JSON.parse(tasks).tasks : []) {
    const parts = t.after.map((e) => entryText(text(e.file), e));
    t.after.forEach((e, i) => { if (parts[i] == null) problems.push(`tasks.json: ${t.id}: ${entryName(e)} does not exist`); });
    if (parts.every((p) => p != null) && !parts.some((p) => norm(p).includes(norm(t.fact)))) problems.push(`tasks.json: ${t.id}: its route no longer holds the answer ${JSON.stringify(t.fact)}`);
    if (t.agentGuide && text(t.agentGuide) == null) problems.push(`tasks.json: ${t.id}: agent guide ${t.agentGuide} does not exist`);
  }
  // Guides are read when a task needs one: each exists, is not also always loaded, and holds at least one inventoried rule.
  for (const [name, a] of Object.entries(surfaces.audiences || {})) {
    for (const f of a.guides || []) {
      if (text(f) == null) { problems.push(`surfaces.json: guide ${f} (${name}) does not exist`); continue; }
      if ((a.always || []).includes(f)) problems.push(`surfaces.json: ${f} is both always loaded and a guide for ${name}`);
      if (!rules.some((r) => Array.isArray(r?.homes) && r.homes.some((h) => h?.file === f && Array.isArray(h.clauses) && h.clauses.length && h.clauses.every((c) => has(f, c))))) problems.push(`${f}: guide holds no inventoried rule: add its rules to tools/context/rules.json`);
    }
  }
  // The size ceilings' configuration (ceilingCheck): a size above its ceiling is only a warning, but a missing or invalid ceiling fails.
  problems.push(...ceilingCheck(root).problems);
  return {
    rules: rules.length, protectedRules: rules.filter((r) => r?.protected === true).length,
    gaps: rules.flatMap((r) => (Array.isArray(r?.gaps) ? r.gaps : []).map((g) => ({ id: r.id, protected: r.protected === true, accepted: r.protected === true ? !!lock[r.id]?.acceptedGaps?.includes(g?.audience) : null, ...g }))),
    problems,
  };
}

function main(argv) {
  if (argv[0] === '--print-lock') { console.log(JSON.stringify(lockFor(readJson(REPO, 'tools/context/rules.json').rules), null, 2)); return; }
  if (argv[0] === '--tasks') {
    const r = taskRoutes();
    for (const t of r) {
      const side = (x) => (x.unavailable ? `unavailable (${x.unavailable.join(', ')} not at ${t.rev})` : `~${x.tokens} tokens, answer ${x.answers ? 'found' : 'MISSING'} (${x.parts.map((p) => `${p.entry} ~${p.tokens}`).join(' + ')})`);
      console.log(`== ${t.id}: ${t.question}\n   before (${t.rev}): ${side(t.before)}\n   after: ${side(t.after)}${t.agentGuide ? `\n   the Discord agent also reads ${t.agentGuide.file} ~${t.agentGuide.tokens}` : ''}`);
    }
    if (argv[1] === '--json') fs.writeFileSync(argv[2], JSON.stringify(r, null, 2) + '\n');
    return;
  }
  const json = argv[0] === '--json' ? argv[1] : null;
  const s = sizes();
  const c = checkRules();
  const w = ceilingCheck().warnings;
  const cap = (f) => (f.ceiling == null ? '' : ` / ${f.ceiling}`);
  for (const [name, a] of Object.entries(s.audiences)) {
    console.log(`== ${name}: ${a.what}`);
    for (const f of a.always) {
      console.log(`   always loaded: ${f.file} ${f.chars} chars, ~${f.tokens}${cap(f)} tokens`);
      for (const sec of f.sections) console.log(`     ${String(sec.tokens).padStart(6)}  ${sec.title}`);
    }
    if (a.guides.length) console.log(`   guides, read when a task needs one: ~${a.guideTokens} tokens (${a.guides.map((f) => `${path.basename(f.file, '.md')} ~${f.tokens}${cap(f)}`).join(', ')})`);
    if (a.discovery.length) console.log(`   starts a task from: ~${a.discoveryTokens} tokens (${a.discovery.map((f) => `${f.entry} ~${f.tokens}${cap(f)}`).join(', ')})`);
  }
  if (s.references.length) console.log(`== reference guides, opened only by the task that needs one: ${s.references.length} files, ~${s.references.reduce((n, f) => n + f.tokens, 0)} tokens together, the largest ${[...s.references].sort((a, b) => b.tokens - a.tokens).slice(0, 3).map((f) => `${f.file} ~${f.tokens}${cap(f)}`).join(', ')}`);
  console.log(`== sizes: ${w.length} above their warning ceiling (estimated tokens, size / ceiling above)`);
  for (const x of w) console.log(`   WARNING ${formatSizeWarning(x)}`);
  console.log(`== rules: ${c.rules} inventoried (${c.protectedRules} protected), ${c.gaps.length} gap notes`);
  for (const g of c.gaps) console.log(`   gap ${g.id} (${g.audience}${g.protected ? (g.accepted ? ', protected, accepted in protected.json' : ', protected, NOT accepted') : ''}): ${g.note}`);
  for (const p of c.problems) console.log(`   PROBLEM ${p}`);
  if (json) fs.writeFileSync(json, JSON.stringify({ sizes: s, sizeWarnings: w, rules: c }, null, 2) + '\n');
  process.exit(c.problems.length ? 1 : 0);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
