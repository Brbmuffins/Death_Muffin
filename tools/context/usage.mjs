#!/usr/bin/env node
// What Claude sessions on this game spend their context on, from Claude Code's own transcripts (tools/context/README.md).
// Every API call's usage is in the transcript, so this needs no live instrumentation: it reads ~/.claude/projects/*/*.jsonl,
// keeps the sessions that worked mostly in a Death Muffin checkout (and their subagents), and reports per session and in total what the fixed start costs
// (the system prompt, tools and appended rules the first call already carries), how big the context grows, and which files
// and tools filled it.
//
//   node tools/context/usage.mjs [--since 2026-10-14] [--until 2026-10-20] [--who agent|session|subagent|all] [--json out.json] [--top 15] [--tokens-only]
//   node tools/context/usage.mjs --dir <projects dir>      (another transcript folder; tests use a throwaway one)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// List prices in dollars per million tokens (claude-api skill table, cached 2026-09-25). Cache writes are 1.25x input for the
// 5-minute cache and 2x for the 1-hour one. Sessions on a subscription pay in plan usage, not dollars; the dollars are a common unit.
export const PRICES = {
  'claude-sonnet-5-5': { in: 2, out: 10, read: 0.2 },
  'claude-sonnet-5': { in: 2, out: 10, read: 0.2 },
  'claude-opus-5-5': { in: 4, out: 20, read: 0.2 },
  'claude-opus-5': { in: 5, out: 25, read: 0.5 },
  'claude-fable-5-1': { in: 10, out: 50, read: 0.25 },
  'claude-haiku-4-5': { in: 1, out: 5, read: 0.1 },
};
const priceOf = (model) => PRICES[String(model || '').replace(/-\d{8}$/, '')] || PRICES['claude-sonnet-5-5'];

export function costOf(model, u) {
  const p = priceOf(model);
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
  const out = { sessionId: null, cwd: null, cwds: {}, start: null, end: null, model: null, prompt: null, calls: [], toolResults: [], handoffNote: false };
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
    if (o.type === 'assistant' && o.message?.usage) {
      const m = o.message; const u = m.usage;
      const cc = u.cache_creation || {};
      const w1h = cc.ephemeral_1h_input_tokens ?? 0;
      const w5m = cc.ephemeral_5m_input_tokens ?? Math.max(0, (u.cache_creation_input_tokens || 0) - w1h);
      calls.set(m.id || o.uuid, { model: m.model, ts: o.timestamp, usage: { input: u.input_tokens || 0, write5m: w5m, write1h: w1h, read: u.cache_read_input_tokens || 0, output: u.output_tokens || 0 } });
      if (m.model && m.model !== '<synthetic>') out.model = m.model;
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
        out.toolResults.push({ name: t.name, target: t.target, chars: textLen(b.content) });
      }
    }
  }
  out.calls = [...calls.values()].filter((c) => c.model !== '<synthetic>').sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
  return out;
}

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

export function summarizeSession(s, opts) {
  const where = placeOf(s, opts);
  if (!where || !s.calls.length) return null;
  const tot = emptyUsage();
  let peak = 0;
  for (const c of s.calls) { for (const k of Object.keys(tot)) tot[k] += c.usage[k]; peak = Math.max(peak, ctxOf(c.usage)); }
  const first = ctxOf(s.calls[0].usage);
  // Repo-relative for any Death Muffin checkout; everything else (scratch files, saved tool output) is one bucket, so a report names no private path.
  const rel = (p) => { const m = /\/DeathMuffin\/(?:game|wt\/[^/]+)\/(.+)$/.exec(p); return m ? m[1] : p.startsWith('/') || p.startsWith('~') ? '(outside the repo)' : p; };
  const reads = {};
  const byTool = {};
  for (const r of s.toolResults) {
    byTool[r.name] = byTool[r.name] || { calls: 0, chars: 0 };
    byTool[r.name].calls += 1; byTool[r.name].chars += r.chars;
    if (r.name === 'Bash') { const f = 'Bash: ' + commandFamily(r.target); byTool[f] = byTool[f] || { calls: 0, chars: 0 }; byTool[f].calls += 1; byTool[f].chars += r.chars; }
    if (r.name === 'Read') { const p = rel(r.target); reads[p] = reads[p] || { reads: 0, chars: 0 }; reads[p].reads += 1; reads[p].chars += r.chars; }
  }
  return {
    ...where, sessionId: s.sessionId, start: s.start, end: s.end, model: s.model,
    calls: s.calls.length, firstContext: first, peakContext: peak,
    // What the fixed start costs over the session: every call re-reads it.
    fixedShare: tot.input + tot.write5m + tot.write1h + tot.read ? (first * s.calls.length) / (tot.input + tot.write5m + tot.write1h + tot.read) : 0,
    contexts: s.calls.map((c) => ctxOf(c.usage)),
    usage: tot, cost: costOf(s.model, tot), prompt: s.prompt, handoffNote: s.handoffNote, reads, byTool,
  };
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

export function collect({ dir, since, until, who }) {
  const sessions = [];
  for (const { file: f, subagent } of transcriptFiles(dir)) {
    if (since) { try { if (fs.statSync(f).mtime.toISOString().slice(0, 10) < since) continue; } catch { continue; } }
    const s = summarizeSession(parseTranscript(fs.readFileSync(f, 'utf8').split('\n')), { subagent });
    if (!s) continue;
    if (who && who !== 'all' && s.who !== who) continue;
    if (since && String(s.start).slice(0, 10) < since) continue;
    if (until && String(s.start).slice(0, 10) > until) continue;
    s.file = f;
    sessions.push(s);
  }
  return sessions.sort((a, b) => String(a.start).localeCompare(String(b.start)));
}

// What a session's context would have cost read back if it were compacted whenever it passed `cap` tokens: after a compaction the context
// restarts at the session's first call plus a summary of `summary` tokens (written to the cache once) and grows as it did. A rough upper
// bound on the saving: work redone after a compaction (files read again) is not counted.
export function whatIfCap(s, cap, summary = 20000) {
  const p = priceOf(s.model);
  const base = s.firstContext + summary;
  let offset = 0, compactions = 0, read = 0, written = 0, prev = 0;
  for (const c of s.contexts) {
    if (c < prev) offset = 0; // the session compacted (or cleared) for real: from here it is as small as the real one
    prev = c;
    let now = Math.min(c, c - offset);
    if (now > cap) { offset = c - base; now = base; compactions += 1; written += base; }
    read += now;
  }
  const actual = s.contexts.reduce((a, c) => a + c, 0);
  return { cap, compactions, savedTokens: actual - read, saved: ((actual - read) * p.read - written * p.in * 2) / 1e6 };
}

const median = (xs) => { if (!xs.length) return 0; const v = [...xs].sort((a, b) => a - b); const m = v.length >> 1; return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2; };

// tokensOnly: no dollars (the committed baseline in this public repo carries tokens and calls only).
export function report(sessions, { top = 15, tokensOnly = false } = {}) {
  const groups = {};
  for (const s of sessions) (groups[s.who] = groups[s.who] || []).push(s);
  const result = { generated: new Date().toISOString(), groups: {} };
  for (const [who, list] of Object.entries(groups)) {
    const tot = emptyUsage(); const reads = {}; const byTool = {};
    let cost = 0, calls = 0, fixed = 0; const models = {};
    for (const s of list) {
      models[s.model] = (models[s.model] || 0) + s.cost;
      for (const k of Object.keys(tot)) tot[k] += s.usage[k];
      cost += s.cost; calls += s.calls; fixed += s.firstContext * s.calls;
      for (const [p, r] of Object.entries(s.reads)) { reads[p] = reads[p] || { reads: 0, chars: 0, sessions: 0 }; reads[p].reads += r.reads; reads[p].chars += r.chars; reads[p].sessions += 1; }
      for (const [t, r] of Object.entries(s.byTool)) { byTool[t] = byTool[t] || { calls: 0, chars: 0 }; byTool[t].calls += r.calls; byTool[t].chars += r.chars; }
    }
    const ctx = ctxOf(tot);
    result.groups[who] = {
      sessions: list.length, jobs: new Set(list.map((s) => s.job).filter(Boolean)).size, calls, cost: +cost.toFixed(2),
      models: Object.fromEntries(Object.entries(models).map(([m, c]) => [m, +c.toFixed(2)])), usage: tot, contextTokens: ctx, cacheReadShare: ctx ? tot.read / ctx : 0,
      firstContext: { median: median(list.map((s) => s.firstContext)), min: Math.min(...list.map((s) => s.firstContext)), max: Math.max(...list.map((s) => s.firstContext)) },
      peakContext: { median: median(list.map((s) => s.peakContext)), max: Math.max(...list.map((s) => s.peakContext)) },
      callsPerSession: { median: median(list.map((s) => s.calls)), max: Math.max(...list.map((s) => s.calls)) },
      fixedShare: ctx ? fixed / ctx : 0,
      appendedPromptChars: { median: median(list.filter((s) => s.prompt).map((s) => s.prompt.appendedChars)) },
      handoffs: list.filter((s) => s.handoffNote).length,
      topReads: Object.entries(reads).sort((a, b) => b[1].chars - a[1].chars).slice(0, top).map(([p, r]) => ({ path: p, ...r })),
      byTool: Object.fromEntries(Object.entries(byTool).sort((a, b) => b[1].chars - a[1].chars)),
      whatIf: [150000, 250000, 400000].map((cap) => { const w = list.map((s) => whatIfCap(s, cap)); return { cap, compactions: w.reduce((a, x) => a + x.compactions, 0), savedTokens: w.reduce((a, x) => a + x.savedTokens, 0), saved: +w.reduce((a, x) => a + x.saved, 0).toFixed(2) }; }),
      costliest: [...list].sort((a, b) => b.cost - a.cost).slice(0, 5).map((s) => ({ job: s.job, round: s.round, start: s.start, calls: s.calls, peak: s.peakContext, cost: +s.cost.toFixed(2) })),
    };
  }
  if (tokensOnly) {
    for (const g of Object.values(result.groups)) {
      delete g.cost; delete g.models;
      for (const w of g.whatIf) delete w.saved;
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
    lines.push(`== ${who}: ${g.sessions} sessions${g.jobs ? ` (${g.jobs} jobs)` : ''}, ${g.calls} calls${g.cost != null ? `, about $${g.cost} at list price` : ''}`);
    if (g.models) lines.push(`   by model: ${Object.entries(g.models).map(([m, c]) => `${m} $${c}`).join(', ')}`);
    lines.push(`   context read ${k(g.contextTokens)} tokens (cache reads ${pct(g.cacheReadShare)}), written ${k(g.usage.output)} output`);
    lines.push(`   first call carries ${k(g.firstContext.median)} tokens (median; ${k(g.firstContext.min)}-${k(g.firstContext.max)}); the fixed start is ${pct(g.fixedShare)} of all context read`);
    lines.push(`   context peaks at ${k(g.peakContext.median)} (median), ${k(g.peakContext.max)} (max); ${g.callsPerSession.median} calls a session (median), ${g.callsPerSession.max} max; ${g.handoffs} handoff notes`);
    if (g.appendedPromptChars.median) lines.push(`   appended rules: ${k(g.appendedPromptChars.median)} characters (median)`);
    lines.push('   files read, by characters returned (reads, sessions):');
    for (const t of g.topReads) lines.push(`     ${k(t.chars).padStart(7)}  ${t.path} (${t.reads}, ${t.sessions})`);
    lines.push('   tool results, by characters returned (calls):');
    for (const [t, v] of Object.entries(g.byTool).slice(0, 14)) lines.push(`     ${k(v.chars).padStart(7)}  ${t} (${v.calls})`);
    lines.push(`   compacting at a lower point (estimate): ${g.whatIf.map((w) => `${k(w.cap)} saves ${k(w.savedTokens)} tokens read${w.saved != null ? ` ~$${w.saved}` : ''} (${w.compactions} compactions)`).join('; ')}`);
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
    else { console.error(`unknown argument ${a}`); process.exit(2); }
  }
  const r = report(collect(opt), opt);
  r.window = { since: opt.since || null, until: opt.until || null };
  if (opt.json) fs.writeFileSync(opt.json, JSON.stringify(r, null, 2) + '\n');
  console.log(Object.keys(r.groups).length ? formatReport(r) : 'no Death Muffin sessions in that window');
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
