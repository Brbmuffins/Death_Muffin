#!/usr/bin/env node
// What Codex terminal sessions on this game spend their context on, from the rollouts Codex saves (tools/context/README.md "Codex usage").
// The Claude reader (usage.mjs) reads Claude Code transcripts; this one reads ~/.codex/sessions/**/rollout-*.jsonl (and archived_sessions)
// without starting anything or adding instrumentation. Tokens only: no dollars, and no account, rate-limit or thread fields in the output.
//
// How usage is counted (the record shapes are in the README):
// - Per response: `token_usage_record` records, deduplicated by response_id across every file (a resumed or forked rollout copies earlier
//   records). Their cumulative turn/thread counters are never summed.
// - A rollout with no such records (older CLIs): `event_msg` token_count snapshots carry a cumulative total; a response is derived as a
//   positive change of that total. A repeated snapshot adds nothing, a smaller total starts a new segment (a reset), and the calls derived
//   this way are labelled uncertain: one change can hold several responses.
// - Mixed rollouts: records where they exist; snapshots only before the first record. A final cumulative total that disagrees with what
//   was counted is a coverage warning, never silently added.
// - input_tokens counts once; cached_input_tokens is the part of it read from the cache (a subset, not extra context); reasoning_output_tokens
//   is part of output_tokens. cache_write_input_tokens is reported as recorded.
//
// Which sessions count (Codex reviews often start in the home folder and read the game by absolute paths, so a launch folder is not enough):
// - dm: launched in, or mostly working in, a Death Muffin checkout (cwd of the session and its turns);
// - mixed: launched elsewhere, with commands that name a Death Muffin path (the game, a worktree or its review folder); reported apart and
//   never credited to the game as a whole;
// - selected: named with --session <id> or --sessions-file <file> (a private list kept outside the repo).
// A command's returned text never decides where a session worked. Terminal (cli, vscode), exec (codex exec) and child (a subagent or a
// guardian) sessions are reported apart.
//
//   node tools/context/usage-codex.mjs [--since D] [--until D] [--cohort] [--scope dm|mixed|all] [--session <id>]... [--sessions-file f]
//                                      [--dir <sessions dir>]... [--json out.json] [--top 15] [--list]
//   --list prints each matching session with its id and why it was included (private: do not commit that output).

import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { classify, windowOf } from './usage.mjs';

export const READER_VERSION = 2;
const DM_PATH = /\/vps-handoffs\/DeathMuffin\//;
const USAGE_KEYS = ['input', 'cached', 'cacheWrite', 'output', 'reasoning'];
const emptyUsage = () => ({ input: 0, cached: 0, cacheWrite: 0, output: 0, reasoning: 0 });
const usageOf = (u) => ({ input: u?.input_tokens || 0, cached: u?.cached_input_tokens || 0, cacheWrite: u?.cache_write_input_tokens || 0, output: u?.output_tokens || 0, reasoning: u?.reasoning_output_tokens || 0 });
const addTo = (t, u) => { for (const k of USAGE_KEYS) t[k] += u[k]; return t; };
const within = (w, ts) => { const t = Date.parse(ts); return !Number.isNaN(t) && t >= w.from && t < w.to; };

// A path a command named, resolved without touching the disk: absolute as it is, relative against the command's working directory (its
// own `workdir`, else the folder the turn or session ran in), `..` folded. null when the folder is unknown or the path is a ~ path.
export function resolvePath(p, workdir, cwd) {
  if (!p || p.startsWith('~')) return null;
  if (p.startsWith('/')) return path.posix.normalize(p);
  const base = workdir ? (workdir.startsWith('/') ? workdir : cwd ? path.posix.join(cwd, workdir) : null) : cwd;
  return base && base.startsWith('/') ? path.posix.normalize(path.posix.join(base, p)) : null;
}
// What the report may name: a path inside a Death Muffin checkout, relative to it; anything else is a bucket, so no private path leaves.
export function rel(abs) {
  if (abs == null) return '(unknown folder)';
  const m = /\/vps-handoffs\/DeathMuffin\/(?:game|wt\/[^/]+)\/(.+)$/.exec(abs);
  return m ? m[1] : '(outside the repo)';
}
// A command's program for the report: leading variable assignments dropped (their values never shown), the program's base name, and
// "(other)" for anything that does not look like a plain program name.
export function familyOf(cmd) {
  const w = String(cmd || '').trim().replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)+/, '').split(/\s+/)[0] || '';
  const b = path.posix.basename(w);
  return /^[A-Za-z0-9][\w.+-]{0,39}$/.test(b) ? b : '(other)';
}

// A string literal of the JavaScript a code-mode call carries, and the end of it.
function literalAt(src, i) {
  const q = src[i]; if (!'"\'`'.includes(q)) return null;
  for (let j = i + 1; j < src.length; j++) {
    if (src[j] === '\\') { j++; continue; }
    if (src[j] === q) {
      const raw = src.slice(i, j + 1);
      let v; try { v = q === '"' ? JSON.parse(raw) : raw.slice(1, -1).replace(/\\(.)/g, '$1'); } catch { v = raw.slice(1, -1); }
      return { v, end: j + 1 };
    }
  }
  return null;
}
// The shell commands one tool call ran, without running anything, each with its own working directory if it gave one: a function call
// carries {cmd|command, workdir}; Codex's code-mode `exec` tool carries JavaScript whose tools.exec_command({cmd: "...", workdir: "..."})
// objects name them. Unrecognised input gives no commands.
export function commandsOf(name, input) {
  if (typeof input !== 'string') return [];
  if (name === 'exec') {
    const out = [];
    const re = /exec_command\(\s*\{/g;
    let m;
    while ((m = re.exec(input))) {
      const fields = {}; let i = re.lastIndex;
      // the object literal's string fields, up to its closing brace
      while (i < input.length && input[i] !== '}') {
        const k = /^\s*,?\s*([A-Za-z_]+)\s*:\s*/.exec(input.slice(i, i + 200));
        if (!k) { i++; continue; }
        i += k[0].length;
        const lit = literalAt(input, i);
        if (lit) { fields[k[1]] = lit.v; i = lit.end; } else { while (i < input.length && !',}'.includes(input[i])) i++; }
      }
      if (typeof fields.cmd === 'string') out.push({ cmd: fields.cmd, workdir: typeof fields.workdir === 'string' ? fields.workdir : null });
    }
    return out;
  }
  try {
    const a = JSON.parse(input);
    const c = a.cmd ?? a.command;
    const cmd = typeof c === 'string' ? c : Array.isArray(c) ? c.join(' ') : null;
    return cmd == null ? [] : [{ cmd, workdir: typeof a.workdir === 'string' ? a.workdir : null }];
  } catch { return []; }
}

// Files a simple read command names (cat, sed -n, head, tail, nl, less, wc); a pipeline, chain or anything else is not a recognised read.
export function readsOf(cmd) {
  const c = String(cmd).trim();
  if (/[;&|`$()<>]/.test(c.replace(/'[^']*'/g, "''"))) return [];
  const w = c.split(/\s+/);
  if (!['cat', 'sed', 'head', 'tail', 'nl', 'less', 'wc'].includes(w[0])) return [];
  const files = [];
  for (let i = 1; i < w.length; i++) {
    const x = w[i];
    if (x.startsWith('-')) { if (/^-[nc]$/.test(x)) i++; continue; }
    if (w[0] === 'sed' && files.length === 0 && /^['"]?[\d,$]*p['"]?$/.test(x)) continue;
    files.push(x.replace(/^['"]|['"]$/g, ''));
  }
  return files;
}

const outputText = (o) => (typeof o === 'string' ? o : Array.isArray(o) ? o.map((b) => (b?.type === 'input_image' ? '' : String(b?.text ?? ''))).join('') : o == null ? '' : JSON.stringify(o));
const hasImage = (o) => Array.isArray(o) && o.some((b) => b?.type === 'input_image');

// One rollout file -> its records, in order. Never throws on a bad line (a truncated last line is common in a live rollout).
export function parseRollout(lines) {
  const out = { meta: null, metas: 0, turns: {}, records: [], snapshots: [], calls: new Map(), outputs: [], instructions: [], worldStates: 0, cwds: {}, badLines: 0, first: null, last: null };
  let lastModel = null;   // the model in effect at this point of the file (turn contexts and thread settings, in order); none yet = unknown
  let lastCwd = null;     // the folder in effect (session_meta, then each turn_context)
  for (const line of lines) {
    if (!line.trim()) continue;
    let o; try { o = JSON.parse(line); } catch { out.badLines += 1; continue; }
    const p = o.payload && typeof o.payload === 'object' ? o.payload : {};
    const ts = o.timestamp || null;
    if (ts) { if (!out.first || ts < out.first) out.first = ts; if (!out.last || ts > out.last) out.last = ts; }
    if (o.type === 'session_meta') {
      out.metas += 1;
      if (!out.meta) out.meta = { id: p.id || p.session_id || null, cwd: p.cwd || null, cli: p.cli_version || null, source: p.source ?? null, originator: p.originator || null, baseChars: String(p.base_instructions?.text || '').length };
      if (p.cwd) { out.cwds[p.cwd] = (out.cwds[p.cwd] || 0) + 1; lastCwd = lastCwd || p.cwd; }
    } else if (o.type === 'turn_context') {
      if (p.turn_id) out.turns[p.turn_id] = { model: p.model || null, cwd: p.cwd || null };
      if (p.model) lastModel = p.model;
      if (p.cwd) { out.cwds[p.cwd] = (out.cwds[p.cwd] || 0) + 1; lastCwd = p.cwd; }
    } else if (o.type === 'world_state') {
      out.worldStates += 1;
      const a = p.state?.agents_md;
      if (a && typeof a === 'object' && a.text) out.instructions.push({ how: 'world_state', dir: String(a.directory || ''), chars: String(a.text).length, ts });
    } else if (o.type === 'token_usage_record') {
      const turn = out.turns[p.turn_id];
      out.records.push({ id: p.response_id || null, turn: p.turn_id || null, owners: [p.session_id, p.thread_id].filter(Boolean), ts, model: turn?.model || lastModel, usage: usageOf(p.usage), thread: p.thread_token_usage ? usageOf(p.thread_token_usage) : null });
    } else if (o.type === 'event_msg' && p.type === 'token_count') {
      if (p.info?.total_token_usage) out.snapshots.push({ ts, total: usageOf(p.info.total_token_usage), last: p.info.last_token_usage ? usageOf(p.info.last_token_usage) : null, model: lastModel });
    } else if (o.type === 'event_msg' && p.type === 'thread_settings_applied') {
      if (p.thread_settings?.model) lastModel = p.thread_settings.model;
    } else if (o.type === 'response_item' && ['custom_tool_call', 'function_call'].includes(p.type)) {
      const turnCwd = out.turns[p.internal_chat_message_metadata_passthrough?.turn_id]?.cwd;
      if (p.call_id) out.calls.set(p.call_id, { name: p.name || '?', input: p.input ?? p.arguments ?? '', ts, cwd: turnCwd || lastCwd });
    } else if (o.type === 'response_item' && ['custom_tool_call_output', 'function_call_output'].includes(p.type)) {
      const text = outputText(p.output);
      // its identity across rollouts: the call and the text, so a resumed or forked copy matches it and a new chunk or call does not
      const key = 'o:' + (p.call_id || '') + ':' + crypto.createHash('sha1').update(text).digest('hex');
      out.outputs.push({ call: p.call_id || null, key, ts, chars: text.length, truncated: /truncated output/i.test(text.slice(0, 400)), image: hasImage(p.output) });
    } else if (o.type === 'response_item' && p.type === 'message' && p.role === 'user') {
      // Older CLIs inject AGENTS.md as a user message that starts with this header; a person quoting the file name elsewhere is not one.
      for (const c of p.content || []) {
        const m = /^# AGENTS\.md instructions for (\S+)\n/.exec(String(c?.text || ''));
        if (m) out.instructions.push({ how: 'message', dir: m[1], chars: String(c.text).length, ts });
      }
    }
  }
  return out;
}

const kindOf = (meta) => {
  const s = meta?.source;
  if (s && typeof s === 'object' && s.subagent) return 'child';
  if (s === 'exec') return 'exec';
  return 'terminal';
};

// Where a session worked: dm (its folders are mostly a checkout), mixed (it started elsewhere and its commands name a Death Muffin
// path), or null (other work). Commands, not their output, decide.
export function scopeOf(r) {
  let inDm = 0, all = 0;
  for (const [cwd, n] of Object.entries(r.cwds)) { all += n; if (classify(cwd)) inDm += n; }
  if (all && inDm * 2 >= all) return { scope: 'dm', reason: 'worked in a Death Muffin checkout' };
  for (const c of r.calls.values()) for (const x of commandsOf(c.name, c.input)) if (DM_PATH.test(x.cmd) || (x.workdir && DM_PATH.test(x.workdir + '/'))) return { scope: 'mixed', reason: 'started outside a checkout; its commands name or run in Death Muffin paths' };
  return null;
}

// The responses one rollout recorded, deduplicated against `seen` (response ids and snapshot keys of files already read).
export function responsesOf(r, seen = new Set()) {
  const warnings = [];
  const out = [];
  const firstRecordTs = r.records.length ? r.records.map((x) => x.ts).sort()[0] : null;
  // earliest: the file's first response, copied or not, with whether it shows the thread's start (nothing counted before it)
  let dupes = 0, earliest = null;
  const note = (ts, copied, isStart) => { if (ts && (!earliest || ts < earliest.ts)) earliest = { ts, copied, isStart }; };
  const own = r.meta?.id;
  const local = emptyUsage();   // everything this file holds as responses, copies included: what its cumulative totals should add up to
  for (const x of r.records) {
    // a copy: already counted from an older rollout, or recorded for another session or thread than this rollout's
    const copied = (!!x.id && seen.has('r:' + x.id)) || (!!own && x.owners.length > 0 && !x.owners.includes(own));
    note(x.ts, copied, !!x.thread && USAGE_KEYS.every((k) => x.thread[k] === x.usage[k]));
    addTo(local, x.usage);
    if (copied) { dupes += 1; continue; }
    if (x.id) seen.add('r:' + x.id);
    out.push({ ts: x.ts, model: x.model || null, usage: x.usage, certain: true });
  }
  // Snapshots: only those before the first per-response record (all of them when there is none).
  const snaps = r.snapshots.filter((s) => !firstRecordTs || (s.ts && s.ts < firstRecordTs));
  let prev = null, resets = 0, repeats = 0;
  for (const s of snaps) {
    const key = `s:${r.meta?.id || ''}:${s.ts}:${JSON.stringify(s.total)}`;
    const dup = seen.has(key); seen.add(key);
    if (prev && USAGE_KEYS.every((k) => s.total[k] === prev[k])) { repeats += 1; continue; }
    let delta;
    if (prev && s.total.input < prev.input) { resets += 1; delta = { ...s.total }; }
    else delta = Object.fromEntries(USAGE_KEYS.map((k) => [k, s.total[k] - (prev ? prev[k] : 0)]));
    const firstOfThread = !prev && s.last && USAGE_KEYS.every((k) => s.last[k] === s.total[k]);
    prev = s.total;
    note(s.ts, dup, !!firstOfThread);
    if (USAGE_KEYS.some((k) => delta[k] < 0)) { warnings.push('a snapshot went down in one field and up in another: skipped'); continue; }
    addTo(local, delta);
    if (dup) { dupes += 1; continue; }
    // A change equal to the snapshot's own last-response usage is one response; anything else may hold several.
    const one = s.last && USAGE_KEYS.every((k) => s.last[k] === delta[k]);
    out.push({ ts: s.ts, model: s.model || null, usage: delta, certain: !!one, contextKnown: !!one });
  }
  if (repeats) warnings.push(`${repeats} repeated cumulative snapshot(s) ignored`);
  if (resets) warnings.push(`${resets} cumulative reset(s): counting restarted from zero`);
  if (dupes) warnings.push(`${dupes} response(s) already counted from another rollout (resumed or forked)`);
  if (r.badLines) warnings.push(`${r.badLines} unreadable line(s) (truncated rollout?)`);
  // Coverage: the usage the file's cumulative counters vouch for, against the responses it holds (copies included, so a copy is neither
  // counted twice nor reported missing). Each series (the records' thread totals, the token_count snapshots) is cut where it falls (a
  // reset) and its segments' last values are added; the larger series is the evidence. Snapshots usually lag the records, so they only
  // matter where they show more, as a newer snapshot after the last record does. What the evidence shows beyond the responses is
  // reported as uncovered: never added to the counted usage, never silently dropped.
  const evidence = (series) => {
    const tot = emptyUsage(); let prevS = null;
    for (const v of series) { if (prevS && v.input < prevS.input) addTo(tot, prevS); prevS = v; }
    if (prevS) addTo(tot, prevS);
    return tot;
  };
  const evR = evidence(r.records.map((x) => x.thread).filter(Boolean)), evS = evidence(r.snapshots.map((x) => x.total));
  const uncovered = Object.fromEntries(USAGE_KEYS.map((k) => [k, Math.max(0, Math.max(evR[k], evS[k]) - local[k])]));
  if (uncovered.input || uncovered.output) warnings.push(`${uncovered.input} input / ${uncovered.output} output in the rollout's cumulative totals but in no response: reported as uncovered, not counted`);
  const format = r.records.length ? (snaps.length ? 'mixed' : 'records') : r.snapshots.length ? 'cumulative' : 'none';
  if (format === 'none') warnings.push('no usage recorded: unavailable, not zero');
  return { responses: out.sort((a, b) => String(a.ts).localeCompare(String(b.ts))), format, warnings, start: !r.meta ? 'unknown' : !earliest ? 'unknown' : earliest.copied ? 'inherited' : earliest.isStart ? 'genuine' : 'unknown', uncovered };
}

// One session's responses in the window, or null when it is not selected or none of its responses fall inside.
export function summarizeRollout(r, opts = {}, seen = new Set()) {
  const id = r.meta?.id || null;
  // An explicit selection is the whole selection: any other rollout is left out here, before its responses can enter `seen` (so an
  // unselected original never takes the response ids of a selected copy).
  if (opts.sessions?.size && !opts.sessions.has(id)) return null;
  const picked = !!opts.sessions?.size;
  const where = picked ? { scope: 'selected', reason: 'named by --session/--sessions-file' } : scopeOf(r);
  if (!where) return null;
  if (opts.scope && opts.scope !== 'all' && !picked && where.scope !== opts.scope) return null;
  const { responses, format, warnings, start, uncovered } = responsesOf(r, seen);
  const w = windowOf(opts);
  const startedInWindow = responses.length ? within(w, responses[0].ts) : false;
  if (opts.cohort && !startedInWindow) return null;
  const inWin = responses.filter((x) => opts.cohort || within(w, x.ts));
  if (!inWin.length && format !== 'none') return null;
  if (format === 'none' && !(opts.cohort || within(w, r.first))) return null;
  const tot = emptyUsage(); const byModel = {};
  let peak = 0;
  for (const x of inWin) {
    addTo(tot, x.usage);
    if (x.certain) peak = Math.max(peak, x.usage.input);
    const m = x.model || 'unknown';
    const b = (byModel[m] = byModel[m] || { responses: 0, ...emptyUsage() });
    b.responses += 1; addTo(b, x.usage);
  }
  // The session's real start, only where the rollout shows it: a session_meta, and an earliest response that is not a copy and is its
  // thread's first (its thread total is its own usage). A copied earliest response is an inherited start (a fork or resume); a first
  // response with history before it (a partial rollout) or with no thread total is unknown. Only genuine starts give a first-response input.
  const startKind = start;
  const first = responses[0];
  const firstResponseInput = startKind === 'genuine' && first?.certain ? first.usage.input : null;
  // Tool output: paired with its call; recognised single-file reads are named, the rest is per command family or unattributed.
  const reads = {}; const byTool = {}; let unattributed = 0, truncated = 0, images = 0, unpaired = 0, copiedOutputs = 0;
  for (const o of r.outputs) {
    // an output an older selected rollout already holds (resumed or forked history) is counted there, wherever the window is
    if (seen.has(o.key)) { copiedOutputs += 1; continue; }
    seen.add(o.key);
    if (!(opts.cohort || within(w, o.ts))) continue;
    if (o.truncated) truncated += 1;
    if (o.image) images += 1;
    const c = r.calls.get(o.call);
    if (!c) { unpaired += 1; unattributed += o.chars; continue; }
    const cmds = commandsOf(c.name, c.input);
    if (cmds.length !== 1) { unattributed += o.chars; const k = c.name === 'exec' ? (cmds.length ? 'exec: batched commands' : 'exec: code-mode, no command') : c.name; byTool[k] = byTool[k] || { calls: 0, chars: 0 }; byTool[k].calls += 1; byTool[k].chars += o.chars; continue; }
    const fam = 'shell: ' + familyOf(cmds[0].cmd);
    byTool[fam] = byTool[fam] || { calls: 0, chars: 0 }; byTool[fam].calls += 1; byTool[fam].chars += o.chars;
    const files = readsOf(cmds[0].cmd).map((f) => rel(resolvePath(f, cmds[0].workdir, c.cwd)));
    if (files.length === 1) { const p = files[0]; reads[p] = reads[p] || { reads: 0, chars: 0 }; reads[p].reads += 1; reads[p].chars += o.chars; }
    else if (files.length > 1) { for (const p of files) { reads[p] = reads[p] || { reads: 0, chars: 0 }; reads[p].reads += 1; } unattributed += o.chars; }
  }
  // Instructions: what Codex recorded injecting (an AGENTS.md block), apart from files a command read; nothing recorded is unknown.
  const injected = r.instructions.map((i) => ({ how: i.how, checkout: classify(i.dir) ? 'death-muffin' : 'other', chars: i.chars }));
  const readsAgents = 'AGENTS.md' in reads || 'CLAUDE.md' in reads;   // a checkout's own instruction file, resolved, not any file of that name
  const instructionEvidence = injected.some((i) => i.checkout === 'death-muffin') ? 'injected (Death Muffin AGENTS.md)'
    : injected.length ? 'injected (another folder\'s AGENTS.md)'
    : r.worldStates ? 'recorded as none' : 'unknown (not recorded)';
  return {
    id, file: opts.keepIds ? r.file : undefined, kind: kindOf(r.meta), ...where, cli: r.meta?.cli || null, start: first?.ts || r.first, startedInWindow, format, warnings,
    responses: inWin.length, uncertainResponses: inWin.filter((x) => !x.certain).length, usage: tot, uncovered, byModel, peakInput: peak,
    startKind, firstResponseInput, firstInWindowInput: inWin[0]?.certain ? inWin[0].usage.input : null,
    instructionEvidence, explicitInstructionRead: readsAgents, reads, byTool, unattributedChars: unattributed, truncatedOutputs: truncated, imageOutputs: images, unpairedOutputs: unpaired, copiedOutputs,
  };
}

// Every rollout under the given folders (sessions and archived_sessions by default).
export function* rolloutFiles(dirs) {
  const walk = function* (d) {
    let es; try { es = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of es.sort((a, b) => a.name.localeCompare(b.name))) {
      const f = path.join(d, e.name);
      if (e.isDirectory()) yield* walk(f);
      else if (e.isFile() && e.name.endsWith('.jsonl')) yield f;
    }
  };
  for (const d of dirs) yield* walk(d);
}

export function collect({ dirs, since, until, cohort = false, scope = 'all', sessions = null, keepIds = false }) {
  const seen = new Set();
  const out = [];
  const files = [...rolloutFiles(dirs)].map((f) => ({ f, r: parseRollout(fs.readFileSync(f, 'utf8').split('\n')) }));
  // Oldest first, so the original of a copied record is the one counted and the copy is the duplicate.
  files.sort((a, b) => String(a.r.first).localeCompare(String(b.r.first)));
  let other = 0;
  for (const { f, r } of files) {
    r.file = f;
    const s = summarizeRollout(r, { since, until, cohort, scope, sessions, keepIds }, seen);
    if (s) out.push(s); else other += 1;
  }
  return { sessions: out, skipped: other, files: files.length };
}

const median = (xs) => { if (!xs.length) return null; const v = [...xs].sort((a, b) => a - b); const m = v.length >> 1; return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2; };

// Aggregates per group (kind/scope). No ids, file paths, prompts or tool arguments.
export function report({ sessions, skipped = 0, files = 0 }, { top = 15 } = {}) {
  const groups = {};
  for (const s of sessions) (groups[`${s.kind}/${s.scope}`] = groups[`${s.kind}/${s.scope}`] || []).push(s);
  const result = { reader: `usage-codex.mjs v${READER_VERSION}`, files, sessionsOutside: skipped, groups: {} };
  for (const [g, list] of Object.entries(groups)) {
    const tot = emptyUsage(); const gap = emptyUsage(); const models = {}; const reads = {}; const byTool = {}; const formats = {}; const evidence = {}; const warnings = {};
    let unattributed = 0, truncated = 0, images = 0;
    for (const s of list) {
      addTo(tot, s.usage); addTo(gap, s.uncovered);
      for (const [m, b] of Object.entries(s.byModel)) { const t = (models[m] = models[m] || { responses: 0, ...emptyUsage() }); t.responses += b.responses; addTo(t, b); }
      for (const [p, r] of Object.entries(s.reads)) { reads[p] = reads[p] || { reads: 0, chars: 0, sessions: 0 }; reads[p].reads += r.reads; reads[p].chars += r.chars; reads[p].sessions += 1; }
      for (const [t, r] of Object.entries(s.byTool)) { byTool[t] = byTool[t] || { calls: 0, chars: 0 }; byTool[t].calls += r.calls; byTool[t].chars += r.chars; }
      formats[s.format] = (formats[s.format] || 0) + 1;
      evidence[s.instructionEvidence] = (evidence[s.instructionEvidence] || 0) + 1;
      for (const w of s.warnings) { const k = w.replace(/\d+/g, 'N'); warnings[k] = (warnings[k] || 0) + 1; }
      unattributed += s.unattributedChars; truncated += s.truncatedOutputs; images += s.imageOutputs;
    }
    const firsts = list.map((s) => s.firstResponseInput).filter((x) => x != null);
    result.groups[g] = {
      sessions: list.length, carriedIn: list.filter((s) => !s.startedInWindow).length,
      responses: list.reduce((n, s) => n + s.responses, 0), uncertainResponses: list.reduce((n, s) => n + s.uncertainResponses, 0),
      usage: { ...tot, noncached: tot.input - tot.cached }, cachedShare: tot.input ? tot.cached / tot.input : 0, models,
      // in the sessions' cumulative totals but in no response (whole rollouts, not split by the window): not part of usage
      uncovered: { ...gap, sessions: list.filter((s) => s.uncovered.input || s.uncovered.output).length },
      firstResponseInput: { sessions: firsts.length, median: median(firsts), min: firsts.length ? Math.min(...firsts) : null, max: firsts.length ? Math.max(...firsts) : null },
      startNotGenuine: list.filter((s) => s.startKind !== 'genuine').length,
      starts: list.reduce((o, s) => ({ ...o, [s.startKind]: (o[s.startKind] || 0) + 1 }), {}),
      firstInWindowInput: { median: median(list.map((s) => s.firstInWindowInput).filter((x) => x != null)) },
      peakInput: { median: median(list.map((s) => s.peakInput)), max: Math.max(0, ...list.map((s) => s.peakInput)) },
      formats, instructionEvidence: evidence, explicitInstructionReads: list.filter((s) => s.explicitInstructionRead).length, warnings,
      topReads: Object.entries(reads).sort((a, b) => b[1].chars - a[1].chars || b[1].reads - a[1].reads).slice(0, top).map(([p, r]) => ({ path: p, ...r })),
      repeatReads: Object.values(reads).reduce((n, r) => n + Math.max(0, r.reads - r.sessions), 0),
      byTool: Object.fromEntries(Object.entries(byTool).sort((a, b) => b[1].chars - a[1].chars).slice(0, top)),
      unattributedChars: unattributed, truncatedOutputs: truncated, imageOutputs: images,
    };
  }
  return result;
}

const k = (n) => (n == null ? '?' : n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'K' : String(Math.round(n)));
const pct = (x) => (x * 100).toFixed(0) + '%';

export function formatReport(r) {
  const lines = [`(${r.reader}; tokens as Codex recorded them, no dollars; ${r.files} rollouts read, ${r.sessionsOutside} outside the selection or window)`];
  for (const [g, x] of Object.entries(r.groups)) {
    lines.push(`== codex ${g}: ${x.sessions} sessions${x.carriedIn ? ` (${x.carriedIn} started before the window)` : ''}, ${x.responses} responses${x.uncertainResponses ? ` (${x.uncertainResponses} derived from cumulative totals, may each hold several)` : ''}`);
    lines.push(`   input ${k(x.usage.input)} (cached ${k(x.usage.cached)} = ${pct(x.cachedShare)}, not cached ${k(x.usage.noncached)}${x.usage.cacheWrite ? `, cache writes ${k(x.usage.cacheWrite)}` : ''}), output ${k(x.usage.output)} (reasoning ${k(x.usage.reasoning)} of it)`);
    if (x.uncovered.sessions) lines.push(`   UNCOVERED in ${x.uncovered.sessions} sessions: ${k(x.uncovered.input)} input / ${k(x.uncovered.output)} output their cumulative totals show but no response holds (not in the totals above)`);
    lines.push(`   by model: ${Object.entries(x.models).map(([m, t]) => `${m} ${t.responses} responses, ${k(t.input)} input`).join('; ')}`);
    lines.push(`   first response input ${k(x.firstResponseInput.median)} (median of ${x.firstResponseInput.sessions} genuine starts; ${k(x.firstResponseInput.min)}-${k(x.firstResponseInput.max)})${x.startNotGenuine ? `; starts: ${Object.entries(x.starts).map(([kk, n]) => `${kk} ${n}`).join(', ')}` : ''}; first in window ${k(x.firstInWindowInput.median)} (median)`);
    lines.push(`   peak input ${k(x.peakInput.median)} (median), ${k(x.peakInput.max)} (max)`);
    lines.push(`   formats: ${Object.entries(x.formats).map(([f, n]) => `${f} ${n}`).join(', ')}; AGENTS.md: ${Object.entries(x.instructionEvidence).map(([f, n]) => `${f} ${n}`).join(', ')}; read AGENTS.md/CLAUDE.md by a command in ${x.explicitInstructionReads}`);
    for (const [w, n] of Object.entries(x.warnings)) lines.push(`   warning (${n} sessions): ${w}`);
    lines.push(`   files read by a single-file command, by characters returned (reads, sessions); ${x.repeatReads} repeat reads:`);
    for (const t of x.topReads) lines.push(`     ${k(t.chars).padStart(7)}  ${t.path} (${t.reads}, ${t.sessions})`);
    lines.push(`   tool output by command (calls); ${k(x.unattributedChars)} characters unattributed (batched or code-mode), ${x.truncatedOutputs} truncated, ${x.imageOutputs} with images:`);
    for (const [t, v] of Object.entries(x.byTool)) lines.push(`     ${k(v.chars).padStart(7)}  ${t} (${v.calls})`);
  }
  if (!Object.keys(r.groups).length) lines.push('no Codex sessions on Death Muffin in that window');
  return lines.join('\n');
}

function main(argv) {
  const home = path.join(os.homedir(), '.codex');
  const opt = { dirs: [], top: 15, scope: 'all', sessions: new Set() };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dir') opt.dirs.push(argv[++i]);
    else if (a === '--since') opt.since = argv[++i];
    else if (a === '--until') opt.until = argv[++i];
    else if (a === '--cohort') opt.cohort = true;
    else if (a === '--scope') opt.scope = argv[++i];
    else if (a === '--session') opt.sessions.add(argv[++i]);
    else if (a === '--sessions-file') for (const l of fs.readFileSync(argv[++i], 'utf8').split('\n')) { const id = l.replace(/#.*/, '').trim(); if (id) opt.sessions.add(id); }
    else if (a === '--json') opt.json = argv[++i];
    else if (a === '--top') opt.top = Number(argv[++i]);
    else if (a === '--list') opt.list = true;
    else { console.error(`unknown argument ${a}`); process.exit(2); }
  }
  if (!['dm', 'mixed', 'all'].includes(opt.scope)) { console.error('--scope is dm, mixed or all'); process.exit(2); }
  if (!opt.dirs.length) opt.dirs = [path.join(home, 'sessions'), path.join(home, 'archived_sessions')];
  const c = collect({ ...opt, keepIds: opt.list });
  if (opt.list) {
    for (const s of c.sessions) console.log(`${s.id}  ${s.kind}/${s.scope}  ${String(s.start).slice(0, 16)}  ${s.responses} responses  ${s.format}  ${s.reason}`);
    return;
  }
  const r = report(c, opt);
  r.window = { since: opt.since || null, until: opt.until || null, ends: 'UTC dates, both included', counted: opt.cohort ? 'whole sessions whose first response is in the window' : 'responses and tool output by their own timestamps' };
  r.selection = { scope: opt.scope, namedSessions: opt.sessions.size };
  if (opt.json) fs.writeFileSync(opt.json, JSON.stringify(r, null, 2) + '\n');
  console.log(formatReport(r));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main(process.argv.slice(2));
