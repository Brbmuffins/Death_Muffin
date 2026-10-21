// Tests for tools/context/usage-codex.mjs on small synthetic rollouts shaped like the records Codex CLI 0.163 writes (no copies of real
// conversations): per-response records, cumulative snapshots, copies from resumed or forked rollouts, windows, models, the session's place,
// instruction evidence and tool output (node --test tools/context/test/*.test.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { parseRollout, responsesOf, summarizeRollout, collect, report, formatReport, commandsOf, readsOf } from '../usage-codex.mjs';

const DM = '/home/ubuntu/vps-handoffs/DeathMuffin/wt/feature';
const u = (input, cached = 0, output = 10, reasoning = 0) => ({ input_tokens: input, cached_input_tokens: cached, cache_write_input_tokens: 0, output_tokens: output, reasoning_output_tokens: reasoning, total_tokens: input + output });
const sum = (a, b) => Object.fromEntries(Object.keys(a).map((k) => [k, a[k] + b[k]]));

// A rollout builder: meta, turns, per-response records (with their running thread total), snapshots, tool calls and their output.
function rollout({ id = 'sess-1', cwd = '/home/ubuntu', source = 'cli', start = '2026-10-19T10:00:00.000Z' } = {}) {
  const lines = [];
  let thread = u(0, 0, 0);
  let clock = Date.parse(start);
  const at = () => new Date((clock += 1000)).toISOString();
  const r = {
    lines,
    meta() { lines.push({ timestamp: at(), type: 'session_meta', payload: { id, cwd, cli_version: '0.163.0', source, originator: 'codex-tui', base_instructions: { text: 'base' }, creator_account_id: 'acct-secret' } }); return r; },
    turn(turnId, model, dir = cwd) { lines.push({ timestamp: at(), type: 'turn_context', payload: { turn_id: turnId, cwd: dir, model } }); return r; },
    record(respId, turnId, usage, ts) { thread = sum(thread, usage); lines.push({ timestamp: ts || at(), type: 'token_usage_record', payload: { response_id: respId, turn_id: turnId, session_id: id, usage, turn_token_usage: thread, thread_token_usage: thread } }); return r; },
    snapshot(total, last, ts) { lines.push({ timestamp: ts || at(), type: 'event_msg', payload: { type: 'token_count', info: { total_token_usage: total, last_token_usage: last }, rate_limits: { plan_type: 'secret-plan', primary: { used_percent: 12 } } } }); return r; },
    world(agents) { lines.push({ timestamp: at(), type: 'world_state', payload: { full: true, state: { agents_md: agents || {} } } }); return r; },
    userText(text) { lines.push({ timestamp: at(), type: 'response_item', payload: { type: 'message', role: 'user', content: [{ type: 'input_text', text }] } }); return r; },
    exec(callId, code, output, ts) {
      const t = ts || at();
      lines.push({ timestamp: t, type: 'response_item', payload: { type: 'custom_tool_call', call_id: callId, name: 'exec', input: code } });
      lines.push({ timestamp: t, type: 'response_item', payload: { type: 'custom_tool_call_output', call_id: callId, output: [{ type: 'input_text', text: output }] } });
      return r;
    },
    raw(line) { lines.push(line); return r; },
    text() { return lines.map((l) => (typeof l === 'string' ? l : JSON.stringify(l))); },
  };
  return r;
}
const cmd = (c) => `text(await tools.exec_command({cmd:${JSON.stringify(c)},max_output_tokens:12000}));`;
const parse = (b) => parseRollout(b.text());

test('per-response records count once each; input includes the cached part, output includes reasoning', () => {
  const b = rollout().meta().turn('t1', 'gpt-6-sol').record('r1', 't1', u(10000, 8000, 50, 20)).record('r2', 't1', u(12000, 11000, 30, 0));
  const s = summarizeRollout(parse(b), { sessions: new Set(['sess-1']) });
  assert.equal(s.responses, 2); assert.equal(s.uncertainResponses, 0);
  assert.deepEqual(s.usage, { input: 22000, cached: 19000, cacheWrite: 0, output: 80, reasoning: 20 });
  assert.equal(s.firstResponseInput, 10000); assert.equal(s.peakInput, 12000);
  assert.deepEqual(s.warnings, []);
  const g = report({ sessions: [s] }).groups['terminal/selected'];
  assert.equal(g.usage.noncached, 3000, 'not cached = input minus its cached part, never input plus cached');
  assert.ok(Math.abs(g.cachedShare - 19000 / 22000) < 1e-12);
});

test('snapshots never add to per-response records; their cumulative counters are not summed', () => {
  const b = rollout().meta().turn('t1', 'gpt-6-sol')
    .record('r1', 't1', u(1000)).snapshot(u(1000), u(1000))
    .record('r2', 't1', u(2000)).snapshot(u(3000, 0, 20), u(2000)).snapshot(u(3000, 0, 20), u(2000));
  const s = summarizeRollout(parse(b), { sessions: new Set(['sess-1']) });
  assert.equal(s.format, 'records'); assert.equal(s.responses, 2); assert.equal(s.usage.input, 3000);
});

test('a copied record (resumed or forked rollout) counts once, in the older file; distinct parallel ids both count', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-codex-'));
  const a = rollout({ id: 'orig', start: '2026-10-19T10:00:00.000Z' }).meta().turn('t1', 'gpt-6-sol').record('r1', 't1', u(1000)).exec('c1', cmd(`cat ${DM}/README.md`), 'x');
  const forked = rollout({ id: 'fork', start: '2026-10-19T11:00:00.000Z' }).meta().turn('t1', 'gpt-6-sol')
    .record('r1', 't1', u(1000), '2026-10-19T10:00:02.000Z').record('r2', 't2', u(5000)).record('r3', 't2', u(6000)).exec('c2', cmd(`git -C ${DM} log`), 'y');
  fs.writeFileSync(path.join(dir, 'b-fork.jsonl'), forked.text().join('\n'));
  fs.writeFileSync(path.join(dir, 'a-orig.jsonl'), a.text().join('\n'));
  const c = collect({ dirs: [dir], keepIds: true });
  const byId = Object.fromEntries(c.sessions.map((s) => [s.id, s]));
  assert.equal(byId.orig.responses, 1); assert.equal(byId.orig.startKind, 'genuine');
  assert.equal(byId.fork.responses, 2, 'r2 and r3 are different responses; r1 is the copy');
  assert.equal(byId.fork.startKind, 'inherited'); assert.equal(byId.fork.firstResponseInput, null, 'a forked session has no genuine first response');
  assert.ok(byId.fork.warnings.some((w) => /already counted/.test(w)));
  const g = report(c).groups['terminal/mixed'];
  assert.equal(g.responses, 3); assert.equal(g.startNotGenuine, 1); assert.equal(g.firstResponseInput.sessions, 1);
});

test('cumulative-only rollouts: repeated snapshots add nothing, a reset restarts the count, uncertain changes are labelled', () => {
  const b = rollout().meta().turn('t1', 'gpt-5.6-sol')
    .snapshot(u(1000, 0, 10), u(1000, 0, 10))
    .snapshot(u(1000, 0, 10), u(1000, 0, 10))            // repeated
    .snapshot(u(4000, 0, 30), u(2000, 0, 10))            // +3000 / +20: more than its last response, so two responses or more
    .snapshot(u(500, 0, 5), u(500, 0, 5));               // reset: a new segment from zero
  const r = responsesOf(parse(b));
  assert.equal(r.format, 'cumulative');
  assert.deepEqual(r.responses.map((x) => [x.usage.input, x.certain]), [[1000, true], [3000, false], [500, true]]);
  assert.ok(r.warnings.some((w) => /repeated cumulative/.test(w)));
  assert.ok(r.warnings.some((w) => /reset/.test(w)));
  const s = summarizeRollout(parse(b), { sessions: new Set(['sess-1']) });
  assert.equal(s.uncertainResponses, 1); assert.equal(s.usage.input, 4500);
  assert.equal(s.peakInput, 1000, 'an uncertain change is never taken as one response\'s context');
});

test('a mixed rollout uses snapshots only before its first per-response record', () => {
  const b = rollout().meta().turn('t1', 'gpt-6-sol')
    .snapshot(u(1000), u(1000)).snapshot(u(3000, 0, 20), u(2000))
    .record('r1', 't2', u(4000)).snapshot(u(7000, 0, 30), u(4000));
  const r = responsesOf(parse(b));
  assert.equal(r.format, 'mixed');
  assert.deepEqual(r.responses.map((x) => x.usage.input), [1000, 2000, 4000]);
});

test('a rollout whose counted usage falls short of its last cumulative total says part of it is not covered', () => {
  const b = rollout().meta().turn('t1', 'gpt-6-sol').record('r1', 't1', u(1000));
  b.lines.push({ timestamp: '2026-10-19T10:00:09.000Z', type: 'token_usage_record', payload: { response_id: 'r2', turn_id: 't1', usage: u(500), thread_token_usage: u(9000) } });
  assert.ok(responsesOf(parse(b)).warnings.some((w) => /not covered/.test(w)));
});

test('missing and truncated records: unavailable is not zero, and a bad line is reported', () => {
  const none = rollout().meta().turn('t1', 'gpt-6-sol').exec('c1', cmd(`cat ${DM}/README.md`), 'x'.repeat(50));
  const s = summarizeRollout(parse(none), {});
  assert.equal(s.format, 'none'); assert.equal(s.responses, 0);
  assert.ok(s.warnings.includes('no usage recorded: unavailable, not zero'));
  const cut = rollout().meta().turn('t1', 'gpt-6-sol').record('r1', 't1', u(1000)).raw('{"timestamp":"2026-10-19T10:00:09Z","type":"token_usage_re');
  const p = parse(cut);
  assert.equal(p.badLines, 1);
  assert.ok(responsesOf(p).warnings.some((w) => /unreadable line/.test(w)));
  const noMeta = rollout({ cwd: DM }).turn('t1', 'gpt-6-sol').record('r1', 't1', u(1000));   // a partial rollout: no session_meta
  const n = summarizeRollout(parse(noMeta), {});
  assert.equal(n.startKind, 'unknown'); assert.equal(n.firstResponseInput, null);
});

test('the window counts responses by their own time, both end dates included; cohort takes whole sessions', () => {
  const b = rollout({ start: '2026-10-17T23:59:00.000Z' }).meta().turn('t1', 'gpt-6-sol')
    .record('a', 't1', u(100), '2026-10-17T23:59:59.999Z').record('b', 't1', u(200), '2026-10-18T00:00:00.000Z')
    .record('c', 't1', u(300), '2026-10-20T23:59:59.999Z').record('d', 't1', u(400), '2026-10-21T00:00:00.000Z');
  const sel = { sessions: new Set(['sess-1']) };
  const s = summarizeRollout(parse(b), { ...sel, since: '2026-10-18', until: '2026-10-20' });
  assert.equal(s.responses, 2); assert.equal(s.usage.input, 500); assert.equal(s.startedInWindow, false);
  assert.equal(s.firstResponseInput, 100, 'the genuine first response, before the window'); assert.equal(s.firstInWindowInput, 200);
  assert.equal(summarizeRollout(parse(b), { ...sel, since: '2026-10-18', until: '2026-10-20', cohort: true }), null);
  assert.equal(summarizeRollout(parse(b), { ...sel, since: '2026-10-22' }), null);
});

test('each response is attributed to its turn\'s model; a switch splits the totals, and no model stays unknown', () => {
  const b = rollout().meta().turn('t1', 'gpt-6-sol').record('r1', 't1', u(1000)).turn('t2', 'gpt-6-astra').record('r2', 't2', u(2000));
  const s = summarizeRollout(parse(b), { sessions: new Set(['sess-1']) });
  assert.equal(s.byModel['gpt-6-sol'].input, 1000); assert.equal(s.byModel['gpt-6-astra'].input, 2000);
  const bare = rollout().meta().record('r1', 'tX', u(1000));
  assert.equal(Object.keys(summarizeRollout(parse(bare), { sessions: new Set(['sess-1']) }).byModel)[0], 'unknown');
});

test('a session counts for the game by its folders or its commands, never by text a command returned', () => {
  const inside = rollout({ cwd: `${DM}/client` }).meta().turn('t1', 'm').record('r1', 't1', u(1));
  assert.equal(summarizeRollout(parse(inside), {}).scope, 'dm');
  const home = rollout().meta().turn('t1', 'm').record('r1', 't1', u(1)).exec('c1', cmd('git -C /home/ubuntu/vps-handoffs/DeathMuffin/game status'), 'ok');
  assert.equal(summarizeRollout(parse(home), {}).scope, 'mixed');
  const other = rollout({ cwd: '/home/ubuntu/HammyVault' }).meta().turn('t1', 'm').record('r1', 't1', u(1)).exec('c1', cmd('cat notes.md'), `see ${DM}/README.md`);
  assert.equal(summarizeRollout(parse(other), {}), null, 'a Death Muffin path in returned text does not count');
  assert.equal(summarizeRollout(parse(other), { sessions: new Set(['sess-1']) }).scope, 'selected');
  assert.equal(summarizeRollout(parse(home), { scope: 'dm' }), null);
  const child = rollout({ cwd: DM, source: { subagent: { other: 'guardian' } } }).meta().turn('t1', 'm').record('r1', 't1', u(1));
  assert.equal(summarizeRollout(parse(child), {}).kind, 'child');
  const exec = rollout({ cwd: DM, source: 'exec' }).meta().turn('t1', 'm').record('r1', 't1', u(1));
  assert.equal(summarizeRollout(parse(exec), {}).kind, 'exec');
});

test('instruction evidence: an injected AGENTS.md is told apart from a command reading it, and nothing recorded is unknown', () => {
  const sel = { sessions: new Set(['sess-1']) };
  const injected = rollout({ cwd: DM }).meta().world({ directory: DM, text: '# Death Muffin: agent rules\n...' }).turn('t1', 'm').record('r1', 't1', u(1));
  assert.equal(summarizeRollout(parse(injected), sel).instructionEvidence, 'injected (Death Muffin AGENTS.md)');
  const older = rollout({ cwd: DM }).meta().userText(`# AGENTS.md instructions for ${DM}\n\n<INSTRUCTIONS>\nrules\n</INSTRUCTIONS>`).turn('t1', 'm').record('r1', 't1', u(1));
  assert.equal(summarizeRollout(parse(older), sel).instructionEvidence, 'injected (Death Muffin AGENTS.md)');
  const elsewhere = rollout().meta().world({ directory: '/home/ubuntu/muffindevelopment', text: 'x' }).turn('t1', 'm').record('r1', 't1', u(1));
  assert.equal(summarizeRollout(parse(elsewhere), sel).instructionEvidence, "injected (another folder's AGENTS.md)");
  const quoted = rollout().meta().world({}).userText('Read AGENTS.md and CLAUDE.md first.').turn('t1', 'm').record('r1', 't1', u(1)).exec('c1', cmd(`cat ${DM}/AGENTS.md`), 'rules');
  const q = summarizeRollout(parse(quoted), sel);
  assert.equal(q.instructionEvidence, 'recorded as none', 'a person naming the file is not an injection');
  assert.equal(q.explicitInstructionRead, true);
  const silent = rollout().meta().turn('t1', 'm').record('r1', 't1', u(1));
  assert.equal(summarizeRollout(parse(silent), sel).instructionEvidence, 'unknown (not recorded)');
});

test('tool output: one recognised read names its file; batched and code-mode output is unattributed; truncation and images are counted', () => {
  const b = rollout({ cwd: DM }).meta().turn('t1', 'm').record('r1', 't1', u(1))
    .exec('c1', cmd(`sed -n '1,80p' ${DM}/client/README.md`), 'a'.repeat(100))
    .exec('c2', cmd(`cat ${DM}/client/README.md`), 'b'.repeat(50))
    .exec('c3', cmd('git status') + cmd('git log'), 'c'.repeat(30))
    .exec('c4', 'const x = await tools.web_search({q: "godot"}); text(x);', 'Warning: truncated output (original token count: 99)\n' + 'd'.repeat(20))
    .exec('c5', cmd(`cat ${DM}/README.md ${DM}/CLAUDE.md`), 'e'.repeat(40))
    .exec('c6', cmd(`cat ${DM}/client/README.md | head`), 'f'.repeat(10));
  b.lines.push({ timestamp: '2026-10-19T10:01:00.000Z', type: 'response_item', payload: { type: 'function_call', call_id: 'c7', name: 'view_image', arguments: '{"path":"/x.png"}' } });
  b.lines.push({ timestamp: '2026-10-19T10:01:00.000Z', type: 'response_item', payload: { type: 'function_call_output', call_id: 'c7', output: [{ type: 'input_image', image_url: 'data:' }] } });
  const s = summarizeRollout(parse(b), {});
  assert.deepEqual(s.reads['client/README.md'], { reads: 2, chars: 150 });
  assert.deepEqual(s.reads['README.md'], { reads: 1, chars: 0 }, 'a two-file read is evidence of the read, its characters stay unattributed');
  assert.equal(s.byTool['exec: batched commands'].chars, 30);
  assert.equal(s.byTool['exec: code-mode, no command'].calls, 1);
  assert.equal(s.unattributedChars, 30 + 'Warning: truncated output (original token count: 99)\n'.length + 20 + 40);
  assert.equal(s.truncatedOutputs, 1); assert.equal(s.imageOutputs, 1);
  assert.equal(s.byTool['shell: cat'].calls, 3, 'the piped read still counts by command family');
  const g = report({ sessions: [s] }).groups['terminal/dm'];
  assert.equal(g.repeatReads, 1);
});

test('commands are read from code-mode and function calls without running them; only simple reads name files', () => {
  assert.deepEqual(commandsOf('exec', 'await tools.exec_command({cmd:"cat a \\"b\\""}); await tools.exec_command({ cmd: \'ls\' })'), ['cat a "b"', 'ls']);
  assert.deepEqual(commandsOf('exec_command', '{"cmd":"git status"}'), ['git status']);
  assert.deepEqual(commandsOf('shell', '{"command":["bash","-lc","ls"]}'), ['bash -lc ls']);
  assert.deepEqual(commandsOf('exec', 'not code'), []);
  assert.deepEqual(readsOf("sed -n '1,40p' a.md"), ['a.md']);
  assert.deepEqual(readsOf('head -n 20 a.md b.md'), ['a.md', 'b.md']);
  assert.deepEqual(readsOf('cat a.md && cat b.md'), []);
  assert.deepEqual(readsOf('rg foo'), []);
});

test('the report holds aggregates only: no session ids, account, plan, rate limits or prompts', () => {
  const b = rollout({ cwd: DM, id: 'secret-session-id' }).meta().turn('t1', 'gpt-6-sol').record('r1', 't1', u(1000)).snapshot(u(1000), u(1000)).userText('a private prompt');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-codex-'));
  fs.writeFileSync(path.join(dir, 'a.jsonl'), b.text().join('\n'));
  const r = report(collect({ dirs: [dir] }));
  const j = JSON.stringify(r) + formatReport(r);
  for (const bad of ['secret-session-id', 'acct-secret', 'secret-plan', 'used_percent', 'a private prompt', dir]) assert.ok(!j.includes(bad), `${bad} is not in the report`);
  assert.equal(r.groups['terminal/dm'].sessions, 1);
});
