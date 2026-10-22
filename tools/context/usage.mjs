#!/usr/bin/env node
// What Claude sessions on this game spend their context on, from Claude Code's own transcripts (tools/context/README.md).
// Every API call's usage is in the transcript, so this needs no live instrumentation: it reads ~/.claude/projects/*/*.jsonl,
// keeps the sessions that worked mostly in a Death Muffin checkout (and their subagents), and reports per audience what the calls in a
// date window read: the context each call carried, the session-start context every call re-reads (system prompt, tools, appended rules
// and the first message), how big the context grows, and which files and tools filled it.
//
// The window is UTC dates, both ends included: --since D counts from D 00:00:00Z, --until D up to (not including) the next day 00:00:00Z.
// Calls and tool results are counted by their own timestamps, so a session that started before the window counts only its calls inside it.
// --cohort instead takes whole sessions whose first call falls in the window (for comparing sessions started after a change).
//
//   node tools/context/usage.mjs [--since 2026-10-14] [--until 2026-10-20] [--cohort] [--who agent|session|subagent|all] [--json out.json] [--top 15] [--tokens-only]
//   node tools/context/usage.mjs --dir <projects dir>      (another transcript folder; tests use a throwaway one)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { claudeView } from './sync-instructions.mjs';

// List prices in dollars per million tokens: input and output from the claude-api skill's model table (cached 2026-09-25); cache reads
// as that table states them (Opus 5.5, Sonnet 5.5, Fable 5.1), otherwise a tenth of input; cache writes 1.25x input for the 5-minute
// cache and 2x for the 1-hour one. A model not listed here is reported as unpriced, never guessed. These are list-price equivalents:
// sessions on a subscription pay in plan usage, which a transcript does not record per call.
export const PRICE_SOURCE = 'list prices from the claude-api skill model table (cached 2026-09-25); cache writes 1.25x (5 min) / 2x (1 h) input';
export const PRICES = {
  'claude-sonnet-5-5': { in: 2, out: 10, read: 0.2 },
  'claude-sonnet-5': { in: 2, out: 10, read: 0.2 },
  'claude-opus-5-5': { in: 4, out: 20, read: 0.2 },
  'claude-opus-5': { in: 5, out: 25, read: 0.5 },
  'claude-fable-5-1': { in: 10, out: 50, read: 0.25 },
  'claude-haiku-4-5': { in: 1, out: 5, read: 0.1 },
};
export const priceOf = (model) => PRICES[String(model || '').replace(/-\d{8}$/, '')] || null;

// One call's list-price cost from its own model and cache-duration breakdown; null when the model has no price.
export function costOf(model, u) {
  const p = priceOf(model);
  if (!p) return null;
  return (u.input * p.in + u.write5m * p.in * 1.25 + u.write1h * p.in * 2 + u.read * p.read + u.output * p.out) / 1e6;
}

// A checkout's root from a working directory: the shared checkout (game), a worktree (wt/<name>), or a Discord job (wt/discord-<job>[-<round>]).
export function classify(cwd) {
  const m = /\/DeathMuffin\/(game|wt\/([^/]+))(\/|$)/.exec(cwd || '');
  if (!m) return null;
  const root = cwd.slice(0, m.index) + '/DeathMuffin/' + m[1];
  const job = m[2] && /^discord-([0-9a-f]{6})(?:-(\d+))?$/.exec(m[2]);
  if (job) return { who: 'agent', root, job: job[1], round: Number(job[2] || 1) };
  return { who: 'session', root, job: null, round: null };
}

const emptyUsage = () => ({ input: 0, write5m: 0, write1h: 0, read: 0, output: 0 });
const ctxOf = (u) => u.input + u.write5m + u.write1h + u.read;
// A shell command's family for the report: the program, plus the script or subcommand for git/node/npm/bash ("git diff", "bash run-client-tests.sh").
export function commandFamily(cmd) {
  const words = String(cmd || '').replace(/^\s*(cd [^;&|]+(&&|;)\s*)+/, '').replace(/^(\w+=\S*\s+)+/, '').trim().split(/\s+/);
  const prog = path.basename(words[0] || '');
  if (['git', 'npm', 'npx', 'node', 'bash', 'sh', 'python3', 'sudo', 'nice', 'timeout'].includes(prog)) {
    const rest = words.slice(1);
    for (let i = 0; i < rest.length; i++) if (prog === 'git' && (rest[i] === '-C' || rest[i] === '-c')) rest.splice(i, 2, '-'); // git -C <dir>, -c <k=v>
    const next = rest.find((w) => !w.startsWith('-') && !/^\d+$/.test(w)) || '';
    return `${prog} ${path.basename(next)}`.trim();
  }
  return prog;
}
const textLen = (c) => (typeof c === 'string' ? c.length : Array.isArray(c) ? c.reduce((n, b) => n + (b.type === 'text' ? (b.text || '').length : b.type === 'image' ? 0 : JSON.stringify(b).length), 0) : 0);

// One transcript file -> one session record, or null when it did not run in a Death Muffin checkout.
export function parseTranscript(lines) {
  const calls = new Map(); // message id -> {model, usage}: a reply split into several blocks repeats the same usage
  const tools = new Map(); // tool_use id -> {name, target}
  const out = { sessionId: null, cwd: null, cwds: {}, start: null, end: null, prompt: null, instructions: [], instructionRecords: [], calls: [], toolResults: [], handoffNote: false };
  for (const line of lines) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch { continue; }
    if (o.cwd) { if (!out.cwd) out.cwd = o.cwd; out.cwds[o.cwd] = (out.cwds[o.cwd] || 0) + 1; }
    if (o.sessionId && !out.sessionId) out.sessionId = o.sessionId;
    if (o.timestamp) { out.start = out.start && out.start < o.timestamp ? out.start : o.timestamp; out.end = out.end && out.end > o.timestamp ? out.end : o.timestamp; }
    if (o.type === 'attachment' && o.attachment?.type === 'prompt_snapshot' && !out.prompt) {
      const parts = (o.attachment.systemPrompt || []).map((s) => String(s));
      out.prompt = { parts: parts.length, chars: parts.reduce((n, s) => n + s.length, 0), appendedChars: parts.length ? parts[parts.length - 1].length : 0 };
    }
    // Instruction files Claude Code injected: the ones found at the start (`instructions`, one entry per file, an imported file included)
    // and the ones it loads later, once the session works in that folder (`nested_memory`, an imported file naming its `parent`). Both carry
    // the delivered text when the record has it (probes 2026-10-21; Claude Code 2.1.284), which is what says whether the rules arrived.
    const addInstr = (p, c, parent) => { out.instructions.push(String(p)); out.instructionRecords.push({ path: String(p), content: typeof c === 'string' ? c : null, parent: parent ? String(parent) : null }); };
    if (o.type === 'attachment' && o.attachment?.type === 'instructions') for (const f of o.attachment.files || []) if (f?.path) addInstr(f.path, f.content, f.parent);
    if (o.type === 'attachment' && o.attachment?.type === 'nested_memory' && o.attachment.path) { const c = o.attachment.content; addInstr(o.attachment.path, typeof c === 'string' ? c : c?.content, c?.parent); }
    if (o.type === 'assistant' && o.message?.usage) {
      const m = o.message; const u = m.usage;
      const cc = u.cache_creation || {};
      const w1h = cc.ephemeral_1h_input_tokens ?? 0;
      const w5m = cc.ephemeral_5m_input_tokens ?? Math.max(0, (u.cache_creation_input_tokens || 0) - w1h);
      calls.set(m.id || o.uuid, { model: m.model, ts: o.timestamp, usage: { input: u.input_tokens || 0, write5m: w5m, write1h: w1h, read: u.cache_read_input_tokens || 0, output: u.output_tokens || 0 } });
      for (const b of m.content || []) {
        if (b.type !== 'tool_use') continue;
        const i = b.input || {};
        const target = i.file_path || i.path || i.pattern || i.command || i.url || i.query || '';
        tools.set(b.id, { name: b.name, target: String(target) });
        if (b.name === 'Write' && /\.dm-handoff\.md$/.test(String(i.file_path || ''))) out.handoffNote = true;
      }
    }
    if (o.type === 'user' && Array.isArray(o.message?.content)) {
      for (const b of o.message.content) {
        if (b.type !== 'tool_result') continue;
        const t = tools.get(b.tool_use_id) || { name: '?', target: '' };
        out.toolResults.push({ name: t.name, target: t.target, chars: textLen(b.content), ts: o.timestamp });
      }
    }
  }
  out.calls = [...calls.values()].filter((c) => c.model !== '<synthetic>').sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
  return out;
}

// The window as epoch milliseconds [from, to): --since D at D 00:00:00Z, --until D up to the next day's 00:00:00Z (the whole day included).
export function windowOf({ since, until } = {}) {
  const day = (d) => { const t = Date.parse(`${d}T00:00:00Z`); if (Number.isNaN(t)) throw new Error(`not a date (YYYY-MM-DD): ${d}`); return t; };
  return { from: since ? day(since) : -Infinity, to: until ? day(until) + 86400000 : Infinity };
}
const within = (w, ts) => { const t = Date.parse(ts); return !Number.isNaN(t) && t >= w.from && t < w.to; };

// Where a session worked: a Discord job by its start directory; anyone else by where most of its records ran (an interactive session
// often starts in the home directory and moves into a checkout). Subagents are counted apart from the session that started them.
export function placeOf(s, { subagent = false } = {}) {
  const first = classify(s.cwd);
  if (first?.who === 'agent') return first;
  let inDm = 0, all = 0; const roots = {};
  for (const [cwd, n] of Object.entries(s.cwds || {})) { all += n; const c = classify(cwd); if (c) { inDm += n; roots[c.root] = (roots[c.root] || 0) + n; } }
  if (!all || inDm * 2 < all) return null;
  const root = Object.entries(roots).sort((a, b) => b[1] - a[1])[0][0];
  return { who: subagent ? 'subagent' : 'session', root, job: null, round: null };
}

// One session's calls in the window (opts.since/until; opts.cohort: the whole session when its first call is in the window), or null.
export function summarizeSession(s, opts = {}) {
  const where = placeOf(s, opts);
  if (!where || !s.calls.length) return null;
  const w = windowOf(opts);
  const startedInWindow = within(w, s.calls[0].ts);
  if (opts.cohort && !startedInWindow) return null;
  const inWindow = s.calls.map((c) => opts.cohort || within(w, c.ts));
  const calls = s.calls.filter((c, i) => inWindow[i]);
  if (!calls.length) return null;
  const toolResults = opts.cohort ? s.toolResults : s.toolResults.filter((r) => within(w, r.ts));
  const tot = emptyUsage();
  let peak = 0, cost = 0, unpricedCalls = 0;
  const byModel = {}; // model -> {calls, usage, cost (null when unpriced)}
  for (const c of calls) {
    for (const k of Object.keys(tot)) tot[k] += c.usage[k];
    peak = Math.max(peak, ctxOf(c.usage));
    const m = c.model || '(no model)';
    const b = (byModel[m] = byModel[m] || { calls: 0, usage: emptyUsage(), cost: 0 });
    b.calls += 1; for (const k of Object.keys(tot)) b.usage[k] += c.usage[k];
    const callCost = costOf(c.model, c.usage);
    if (callCost == null) { unpricedCalls += 1; b.cost = null; } else { cost += callCost; if (b.cost != null) b.cost += callCost; }
  }
  // The session's real start, wherever the window begins: its first call's context is what every later call re-reads as its prefix.
  const startContext = ctxOf(s.calls[0].usage);
  // Repo-relative for any Death Muffin checkout; everything else (scratch files, saved tool output) is one bucket, so a report names no private path.
  const rel = (p) => { const m = /\/DeathMuffin\/(?:game|wt\/[^/]+)\/(.+)$/.exec(p); return m ? m[1] : p.startsWith('/') || p.startsWith('~') ? '(outside the repo)' : p; };
  const reads = {};
  const byTool = {};
  for (const r of toolResults) {
    byTool[r.name] = byTool[r.name] || { calls: 0, chars: 0 };
    byTool[r.name].calls += 1; byTool[r.name].chars += r.chars;
    if (r.name === 'Bash') { const f = 'Bash: ' + commandFamily(r.target); byTool[f] = byTool[f] || { calls: 0, chars: 0 }; byTool[f].calls += 1; byTool[f].chars += r.chars; }
    if (r.name === 'Read') { const p = rel(r.target); reads[p] = reads[p] || { reads: 0, chars: 0 }; reads[p].reads += 1; reads[p].chars += r.chars; }
  }
  return {
    ...where, sessionId: s.sessionId, start: s.calls[0].ts, startedInWindow,
    calls: calls.length, startContext, peakContext: peak,
    // How much of the window's context is the session-start context, re-read by every call in it.
    fixedShare: ctxOf(tot) ? (startContext * calls.length) / ctxOf(tot) : 0,
    // Every call of the session and which ones are in the window: whatIfCap replays the whole session and counts the window's calls.
    contexts: s.calls.map((c) => ctxOf(c.usage)), inWindow, callModels: s.calls.map((c) => c.model),
    // Which of the repo's instruction files were injected into the session; files outside a checkout are not named.
    instructionFiles: [...new Set(s.instructions.map(rel).filter((f) => f !== '(outside the repo)'))].sort(),
    instructionEvidence: instructionEvidence((s.instructionRecords || []).map((r) => ({ ...r, rel: rel(r.path) }))),
    usage: tot, cost, unpricedCalls, byModel, prompt: s.prompt, handoffNote: s.handoffNote, reads, byTool,
  };
}

// Whether the repo's rules reached a session (tools/context/README.md "Usage"). AGENTS.md is the rules' source and CLAUDE.md only imports it,
// so an injected CLAUDE.md alone proves nothing. entryObserved: a record named the root CLAUDE.md; sourceObserved: a record named the root
// AGENTS.md (the import); rulesLoaded: "confirmed" when AGENTS.md was injected, or when an injected CLAUDE.md record's own text held rules
// (any CLAUDE.md from before the switch, judged by its content, never by its date); "unknown" when only an import stub, or a CLAUDE.md
// record without its text, was seen; "none" when neither file was injected.
export function instructionEvidence(records) {
  const entry = records.filter((r) => r.rel === 'CLAUDE.md'), source = records.filter((r) => r.rel === 'AGENTS.md');
  const ruleText = (c) => c != null && claudeView(c).text.split('\n').some((l) => l.trim() && !/^@\S+$/.test(l.trim()));
  const rulesLoaded = source.length || entry.some((r) => ruleText(r.content)) ? 'confirmed' : entry.length ? 'unknown' : 'none';
  return { entryObserved: entry.length > 0, sourceObserved: source.length > 0, rulesLoaded };
}

// Every transcript: <project>/<session>.jsonl, and <project>/<session>/subagents/<agent>.jsonl for the subagents it started.
export function* transcriptFiles(dir) {
  const ls = (d) => { try { return fs.readdirSync(d, { withFileTypes: true }); } catch { return []; } };
  for (const p of ls(dir)) {
    if (!p.isDirectory()) continue;
    const full = path.join(dir, p.name);
    for (const e of ls(full)) {
      if (e.isFile() && e.name.endsWith('.jsonl')) yield { file: path.join(full, e.name), subagent: false };
      else if (e.isDirectory()) for (const a of ls(path.join(full, e.name, 'subagents'))) if (a.isFile() && a.name.endsWith('.jsonl')) yield { file: path.join(full, e.name, 'subagents', a.name), subagent: true };
    }
  }
}

// Every transcript is read (file dates say nothing reliable about a copied transcript's calls); the window filters by each call's timestamp.
export function collect({ dir, since, until, who, cohort = false }) {
  const sessions = [];
  for (const { file: f, subagent } of transcriptFiles(dir)) {
    const s = summarizeSession(parseTranscript(fs.readFileSync(f, 'utf8').split('\n')), { subagent, since, until, cohort });
    if (!s) continue;
    if (who && who !== 'all' && s.who !== who) continue;
    s.file = f;
    sessions.push(s);
  }
  return sessions.sort((a, b) => String(a.start).localeCompare(String(b.start)));
}

// A hypothetical: what the window's calls would have read if the session were compacted whenever its context passed `cap` tokens. After a
// compaction the context restarts at the session-start context plus a summary of `summary` tokens (written to the cache once) and grows as
// it did. It leaves out the cost of writing the summary and the work redone after a compaction (files read again, lost detail), so it is
// an upper bound on a saving, not evidence of one. The whole session is replayed, so a compaction before the window carries into it.
export function whatIfCap(s, cap, summary = 20000) {
  const base = s.startContext + summary;
  const counted = s.inWindow || s.contexts.map(() => true);
  let offset = 0, compactions = 0, read = 0, actual = 0, saved = 0, unpriced = 0, prev = 0;
  s.contexts.forEach((c, i) => {
    if (c < prev) offset = 0; // the session compacted (or cleared) for real: from here it is as small as the real one
    prev = c;
    let now = Math.min(c, c - offset);
    let compacted = false;
    if (now > cap) { offset = c - base; now = base; compacted = true; }
    if (!counted[i]) return;
    if (compacted) compactions += 1;
    read += now; actual += c;
    // priced at this call's own model: reading less, and writing the restarted context to the 1-hour cache at a compaction
    const p = priceOf(s.callModels?.[i]);
    if (!p) { unpriced += 1; return; }
    saved += ((c - now) * p.read - (compacted ? base * p.in * 2 : 0)) / 1e6;
  });
  return { cap, compactions, savedTokens: actual - read, saved, unpricedCalls: unpriced };
}

const median = (xs) => { if (!xs.length) return 0; const v = [...xs].sort((a, b) => a - b); const m = v.length >> 1; return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2; };

// tokensOnly: no dollars (the committed baseline in this public repo carries tokens and calls only).
export function report(sessions, { top = 15, tokensOnly = false } = {}) {
  const groups = {};
  for (const s of sessions) (groups[s.who] = groups[s.who] || []).push(s);
  const result = { generated: new Date().toISOString(), groups: {} };
  for (const [who, list] of Object.entries(groups)) {
    const tot = emptyUsage(); const reads = {}; const byTool = {};
    let cost = 0, calls = 0, fixed = 0, unpricedCalls = 0; const models = {};
    const carriedIn = list.filter((s) => !s.startedInWindow).length;
    for (const s of list) {
      for (const [m, b] of Object.entries(s.byModel)) {
        const t = (models[m] = models[m] || { calls: 0, contextTokens: 0, output: 0, cost: 0 });
        t.calls += b.calls; t.contextTokens += ctxOf(b.usage); t.output += b.usage.output;
        t.cost = t.cost == null || b.cost == null ? null : t.cost + b.cost;
      }
      for (const k of Object.keys(tot)) tot[k] += s.usage[k];
      cost += s.cost; unpricedCalls += s.unpricedCalls; calls += s.calls; fixed += s.startContext * s.calls;
      for (const [p, r] of Object.entries(s.reads)) { reads[p] = reads[p] || { reads: 0, chars: 0, sessions: 0 }; reads[p].reads += r.reads; reads[p].chars += r.chars; reads[p].sessions += 1; }
      for (const [t, r] of Object.entries(s.byTool)) { byTool[t] = byTool[t] || { calls: 0, chars: 0 }; byTool[t].calls += r.calls; byTool[t].chars += r.chars; }
    }
    const ctx = ctxOf(tot);
    result.groups[who] = {
      sessions: list.length, carriedIn, jobs: new Set(list.map((s) => s.job).filter(Boolean)).size, calls,
      // cost covers priced calls only: complete is false when some calls ran on a model with no price (unpricedCalls)
      cost: +cost.toFixed(2), costComplete: unpricedCalls === 0, unpricedCalls, priceSource: PRICE_SOURCE,
      models: Object.fromEntries(Object.entries(models).map(([m, t]) => [m, { ...t, cost: t.cost == null ? null : +t.cost.toFixed(2) }])), usage: tot, contextTokens: ctx, cacheReadShare: ctx ? tot.read / ctx : 0,
      startContext: { median: median(list.map((s) => s.startContext)), min: Math.min(...list.map((s) => s.startContext)), max: Math.max(...list.map((s) => s.startContext)) },
      peakContext: { median: median(list.map((s) => s.peakContext)), max: Math.max(...list.map((s) => s.peakContext)) },
      callsPerSession: { median: median(list.map((s) => s.calls)), max: Math.max(...list.map((s) => s.calls)) },
      fixedShare: ctx ? fixed / ctx : 0,
      appendedPromptChars: { median: median(list.filter((s) => s.prompt).map((s) => s.prompt.appendedChars)) },
      handoffs: list.filter((s) => s.handoffNote).length,
      // claudeMdLoaded: kept for comparisons with earlier reports; it means "a record named the root CLAUDE.md" (entryObserved), not that
      // the rules arrived (rulesConfirmed says that).
      claudeMdLoaded: list.filter((s) => s.instructionFiles.includes('CLAUDE.md')).length,
      instructions: {
        entryObserved: list.filter((s) => s.instructionEvidence?.entryObserved).length,
        sourceObserved: list.filter((s) => s.instructionEvidence?.sourceObserved).length,
        rulesConfirmed: list.filter((s) => s.instructionEvidence?.rulesLoaded === 'confirmed').length,
        rulesUnknown: list.filter((s) => s.instructionEvidence?.rulesLoaded === 'unknown').length,
      },
      topReads: Object.entries(reads).sort((a, b) => b[1].chars - a[1].chars).slice(0, top).map(([p, r]) => ({ path: p, ...r })),
      byTool: Object.fromEntries(Object.entries(byTool).sort((a, b) => b[1].chars - a[1].chars)),
      whatIf: [150000, 250000, 400000].map((cap) => { const w = list.map((s) => whatIfCap(s, cap)); return { cap, compactions: w.reduce((a, x) => a + x.compactions, 0), savedTokens: w.reduce((a, x) => a + x.savedTokens, 0), saved: +w.reduce((a, x) => a + x.saved, 0).toFixed(2), unpricedCalls: w.reduce((a, x) => a + x.unpricedCalls, 0) }; }),
      costliest: [...list].sort((a, b) => b.cost - a.cost).slice(0, 5).map((s) => ({ job: s.job, round: s.round, start: s.start, calls: s.calls, peak: s.peakContext, cost: +s.cost.toFixed(2) })),
    };
  }
  if (tokensOnly) {
    for (const g of Object.values(result.groups)) {
      delete g.cost; delete g.costComplete; delete g.unpricedCalls; delete g.priceSource;
      for (const t of Object.values(g.models)) delete t.cost;
      for (const w of g.whatIf) { delete w.saved; delete w.unpricedCalls; }
      for (const c of g.costliest) delete c.cost;
      g.largest = g.costliest; delete g.costliest;
    }
  }
  return result;
}

const k = (n) => (n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'K' : String(Math.round(n)));
const pct = (x) => (x * 100).toFixed(0) + '%';

export function formatReport(r) {
  const lines = [];
  for (const [who, g] of Object.entries(r.groups)) {
    const dollars = g.cost == null ? '' : `, about $${g.cost} at list price${g.costComplete ? '' : ` (INCOMPLETE: ${g.unpricedCalls} calls on unpriced models left out)`}`;
    lines.push(`== ${who}: ${g.sessions} sessions${g.carriedIn ? ` (${g.carriedIn} started before the window)` : ''}${g.jobs ? `, ${g.jobs} jobs` : ''}, ${g.calls} calls${dollars}`);
    lines.push(`   by model: ${Object.entries(g.models).map(([m, t]) => `${m} ${t.calls} calls, ${k(t.contextTokens)} read${t.cost === undefined ? '' : t.cost == null ? ', unpriced' : `, $${t.cost}`}`).join('; ')}`);
    lines.push(`   context read ${k(g.contextTokens)} tokens (cache reads ${pct(g.cacheReadShare)}), written ${k(g.usage.output)} output`);
    lines.push(`   session-start context ${k(g.startContext.median)} tokens (median; ${k(g.startContext.min)}-${k(g.startContext.max)}); re-read by every call, it is ${pct(g.fixedShare)} of all context read`);
    lines.push(`   context peaks at ${k(g.peakContext.median)} (median), ${k(g.peakContext.max)} (max); ${g.callsPerSession.median} calls a session (median), ${g.callsPerSession.max} max; ${g.handoffs} handoff notes`);
    lines.push(`   repo instructions (at the start or once it worked in a checkout): rules confirmed in ${g.instructions.rulesConfirmed}, unknown in ${g.instructions.rulesUnknown} of ${g.sessions} sessions (CLAUDE.md seen ${g.instructions.entryObserved}, AGENTS.md seen ${g.instructions.sourceObserved})`);
    if (g.appendedPromptChars.median) lines.push(`   appended rules: ${k(g.appendedPromptChars.median)} characters (median)`);
    lines.push('   files read, by characters returned (reads, sessions):');
    for (const t of g.topReads) lines.push(`     ${k(t.chars).padStart(7)}  ${t.path} (${t.reads}, ${t.sessions})`);
    lines.push('   tool results, by characters returned (calls):');
    for (const [t, v] of Object.entries(g.byTool).slice(0, 14)) lines.push(`     ${k(v.chars).padStart(7)}  ${t} (${v.calls})`);
    lines.push(`   hypothetical compaction at a lower point (upper bound, not a measured saving): ${g.whatIf.map((w) => `${k(w.cap)} saves ${k(w.savedTokens)} tokens read${w.saved != null ? ` ~$${w.saved}` : ''} (${w.compactions} compactions)`).join('; ')}`);
    lines.push(g.costliest ? '   costliest sessions:' : '   largest sessions:');
    for (const c of g.costliest || g.largest) lines.push(`     ${c.cost != null ? `$${c.cost}  ` : ''}${c.job ? `job ${c.job} round ${c.round}` : 'session'} ${String(c.start).slice(0, 16)} ${c.calls} calls, peak ${k(c.peak)}`);
  }
  return lines.join('\n');
}

function main(argv) {
  const opt = { dir: path.join(os.homedir(), '.claude', 'projects'), who: 'all', top: 15 };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dir') opt.dir = argv[++i];
    else if (a === '--since') opt.since = argv[++i];
    else if (a === '--until') opt.until = argv[++i];
    else if (a === '--who') opt.who = argv[++i];
    else if (a === '--json') opt.json = argv[++i];
    else if (a === '--top') opt.top = Number(argv[++i]);
    else if (a === '--tokens-only') opt.tokensOnly = true;
    else if (a === '--cohort') opt.cohort = true;
    else { console.error(`unknown argument ${a}`); process.exit(2); }
  }
  const r = report(collect(opt), opt);
  r.window = { since: opt.since || null, until: opt.until || null, ends: 'UTC dates, both included', counted: opt.cohort ? 'whole sessions whose first call is in the window' : 'calls and tool results by their own timestamps' };
  if (opt.json) fs.writeFileSync(opt.json, JSON.stringify(r, null, 2) + '\n');
  if (Object.keys(r.groups).length && !opt.tokensOnly) console.log(`(dollars: ${PRICE_SOURCE}; list-price equivalents, not plan usage)`);
  console.log(Object.keys(r.groups).length ? formatReport(r) : 'no Death Muffin sessions in that window');
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
