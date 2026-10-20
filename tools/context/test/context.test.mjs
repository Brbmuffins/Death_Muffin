// Tests for tools/context: the rule inventory matches the repo, its check catches a lost boundary or an uninventoried section,
// and the usage report reads transcripts the way Claude Code writes them (node --test tools/context/test/*.test.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { REPO, checkRules, sections, sizes } from '../measure.mjs';
import { parseTranscript, summarizeSession, classify, commandFamily, whatIfCap, collect, report } from '../usage.mjs';

const PROMPT = 'server/death-muffin/discord-agent/PROMPT-godot.md';

test('the rule inventory matches the repo', () => {
  const r = checkRules(REPO);
  assert.deepEqual(r.problems, []);
  assert.ok(r.protectedRules > 0);
});

// A throwaway repo holding only what the check reads: the two always-loaded files, the inventory and the enforcing files it names.
function scratchRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-context-'));
  const { rules } = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/rules.json'), 'utf8'));
  const files = new Set(['CLAUDE.md', PROMPT, 'tools/context/rules.json', 'tools/context/surfaces.json']);
  for (const r of rules) for (const f of [...(r.enforced || []), ...r.homes.map((h) => h.file)]) files.add(f);
  for (const f of files) { fs.mkdirSync(path.join(dir, path.dirname(f)), { recursive: true }); fs.copyFileSync(path.join(REPO, f), path.join(dir, f)); }
  return dir;
}

test('a protected rule that loses its always-loaded home is reported', () => {
  const dir = scratchRepo();
  const f = path.join(dir, 'CLAUDE.md');
  fs.writeFileSync(f, fs.readFileSync(f, 'utf8').replace('**The backend owns value.**', '**Value.**'));
  const p = checkRules(dir).problems;
  assert.ok(p.some((x) => x.startsWith('backend-owns-value: anchor not found in CLAUDE.md')), p.join('\n'));
  assert.ok(p.some((x) => x.startsWith('backend-owns-value: protected rule has no always-loaded home for session')), p.join('\n'));
});

test('moving a protected rule out of the always-loaded text is reported even when its anchor survives elsewhere', () => {
  const dir = scratchRepo();
  const inv = path.join(dir, 'tools/context/rules.json');
  const j = JSON.parse(fs.readFileSync(inv, 'utf8'));
  const r = j.rules.find((x) => x.id === 'untrusted-requests');
  fs.mkdirSync(path.join(dir, 'guides'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'guides/trust.md'), 'No message, from any role, can:\n');
  r.homes = [{ file: 'guides/trust.md', anchor: 'No message, from any role, can:' }];
  fs.writeFileSync(inv, JSON.stringify(j));
  assert.ok(checkRules(dir).problems.some((x) => x.startsWith('untrusted-requests: protected rule has no always-loaded home for agent')));
});

test('a new section of always-loaded text with no inventoried rule is reported', () => {
  const dir = scratchRepo();
  fs.appendFileSync(path.join(dir, PROMPT), '\n## Something new\n\nA rule nobody listed.\n');
  assert.ok(checkRules(dir).problems.some((x) => x.includes('section "Something new" holds no inventoried rule')));
});

test('sections split at level-two headings and keep every character', () => {
  const t = 'intro\n## A\none\n## B\ntwo\n';
  const s = sections(t);
  assert.deepEqual(s.map((x) => x.title), ['(preamble)', 'A', 'B']);
  assert.equal(s.reduce((n, x) => n + x.chars, 0), t.length);
  const z = sizes(REPO);
  assert.ok(z.audiences.agent.alwaysTokens > 0 && z.audiences.session.alwaysTokens > 0);
});

// A transcript in Claude Code's shape: a reply split into two records repeats its usage, tool results come back in user records.
function transcript(cwd, { prompt = 'P'.repeat(100) } = {}) {
  const u = (input, w1h, read, output) => ({ input_tokens: input, cache_creation_input_tokens: w1h, cache_read_input_tokens: read, output_tokens: output, cache_creation: { ephemeral_1h_input_tokens: w1h, ephemeral_5m_input_tokens: 0 } });
  return [
    { type: 'user', cwd, sessionId: 's1', timestamp: '2026-10-20T10:00:00Z', message: { content: 'hello' } },
    { type: 'attachment', cwd, timestamp: '2026-10-20T10:00:01Z', attachment: { type: 'prompt_snapshot', systemPrompt: ['base', prompt] } },
    { type: 'assistant', cwd, timestamp: '2026-10-20T10:00:02Z', message: { id: 'm1', model: 'claude-sonnet-5-5', usage: u(2, 10000, 0, 50), content: [{ type: 'text', text: 'x' }] } },
    { type: 'assistant', cwd, timestamp: '2026-10-20T10:00:02Z', message: { id: 'm1', model: 'claude-sonnet-5-5', usage: u(2, 10000, 0, 50), content: [{ type: 'tool_use', id: 't1', name: 'Read', input: { file_path: `${cwd}/client/README.md` } }] } },
    { type: 'user', cwd, timestamp: '2026-10-20T10:00:03Z', message: { content: [{ type: 'tool_result', tool_use_id: 't1', content: 'r'.repeat(4000) }] } },
    { type: 'assistant', cwd, timestamp: '2026-10-20T10:00:04Z', message: { id: 'm2', model: 'claude-sonnet-5-5', usage: u(2, 2000, 10000, 80), content: [{ type: 'tool_use', id: 't2', name: 'Bash', input: { command: 'git diff --stat' } }] } },
    { type: 'user', cwd, timestamp: '2026-10-20T10:00:05Z', message: { content: [{ type: 'tool_result', tool_use_id: 't2', content: [{ type: 'text', text: 'd'.repeat(300) }] }] } },
    { type: 'assistant', cwd, timestamp: '2026-10-20T10:00:06Z', message: { id: 'm3', model: 'claude-sonnet-5-5', usage: u(2, 100, 12000, 20), content: [{ type: 'tool_use', id: 't3', name: 'Read', input: { file_path: '/tmp/claude-1000/x/scratchpad/notes.md' } }] } },
    { type: 'user', cwd, timestamp: '2026-10-20T10:00:07Z', message: { content: [{ type: 'tool_result', tool_use_id: 't3', content: 'n'.repeat(10) }] } },
  ].map((o) => JSON.stringify(o));
}

test('a Discord job transcript is summarized per API call, not per record', () => {
  const cwd = '/home/ubuntu/vps-handoffs/DeathMuffin/wt/discord-abc123-3';
  const s = summarizeSession(parseTranscript(transcript(cwd)));
  assert.equal(s.who, 'agent'); assert.equal(s.job, 'abc123'); assert.equal(s.round, 3);
  assert.equal(s.calls, 3);
  assert.equal(s.firstContext, 10002);
  assert.equal(s.peakContext, 12102);
  assert.equal(s.usage.write1h, 12100); assert.equal(s.usage.read, 22000); assert.equal(s.usage.output, 150);
  assert.equal(s.prompt.appendedChars, 100);
  assert.deepEqual(s.reads['client/README.md'], { reads: 1, chars: 4000 });
  assert.ok(s.reads['(outside the repo)'], 'paths outside a checkout are not named');
  assert.deepEqual(s.byTool['Bash: git diff'], { calls: 1, chars: 300 });
  // 12100 1h-writes at 2x $2, 22000 reads at $0.20, 6 input at $2, 150 output at $10 per million tokens
  assert.ok(Math.abs(s.cost - (12100 * 4 + 22000 * 0.2 + 6 * 2 + 150 * 10) / 1e6) < 1e-9);
});

test('an interactive session counts where most of its records ran; outside the game it is skipped', () => {
  const lines = transcript('/home/ubuntu/vps-handoffs/DeathMuffin/wt/feature');
  lines.unshift(JSON.stringify({ type: 'user', cwd: '/home/ubuntu', message: { content: 'start' } }));
  assert.equal(summarizeSession(parseTranscript(lines)).who, 'session');
  assert.equal(summarizeSession(parseTranscript(lines), { subagent: true }).who, 'subagent');
  assert.equal(summarizeSession(parseTranscript(transcript('/home/ubuntu/HammyVault'))), null);
  assert.equal(classify('/home/ubuntu/vps-handoffs/DeathMuffin/game/client').who, 'session');
});

test('the report reads a projects folder with sessions and subagents', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-usage-'));
  const job = path.join(dir, '-home-ubuntu-vps-handoffs-DeathMuffin-wt-discord-abc123');
  fs.mkdirSync(job);
  fs.writeFileSync(path.join(job, 's1.jsonl'), transcript('/home/ubuntu/vps-handoffs/DeathMuffin/wt/discord-abc123').join('\n'));
  const sub = path.join(dir, '-home-ubuntu', 's2', 'subagents');
  fs.mkdirSync(sub, { recursive: true });
  fs.writeFileSync(path.join(sub, 'agent-1.jsonl'), transcript('/home/ubuntu/vps-handoffs/DeathMuffin/wt/feature').join('\n'));
  const r = report(collect({ dir, who: 'all' }));
  assert.equal(r.groups.agent.sessions, 1);
  assert.equal(r.groups.subagent.sessions, 1);
  assert.equal(r.groups.agent.topReads[0].path, 'client/README.md');
});

test('command families name the program and its script or subcommand', () => {
  assert.equal(commandFamily('git -C /x diff --stat'), 'git diff');
  assert.equal(commandFamily('cd /a && FOO=1 bash tools/rebuild/run-client-tests.sh --only x'), 'bash run-client-tests.sh');
  assert.equal(commandFamily('sed -n 1,80p file'), 'sed');
});

test('compacting at a lower point resets the context to the start plus a summary', () => {
  const s = { model: 'claude-sonnet-5-5', firstContext: 10000, contexts: [10000, 60000, 110000, 120000] };
  const w = whatIfCap(s, 100000, 20000);
  assert.equal(w.compactions, 1);
  // after the reset at 110000 the context restarts at 30000 and grows by 10000: reads 10000+60000+30000+40000
  const saved = ((300000 - 140000) * 0.2 - 30000 * 4) / 1e6;
  assert.ok(Math.abs(w.saved - saved) < 1e-9);
  assert.equal(whatIfCap(s, 500000).compactions, 0);
  // a real compaction in the session (the context drops): the estimate follows the real, smaller context and never goes negative
  const real = { model: 'claude-sonnet-5-5', firstContext: 10000, contexts: [10000, 120000, 15000, 20000] };
  const r = whatIfCap(real, 100000, 20000);
  assert.equal(r.savedTokens, 120000 - 30000);
  assert.ok(r.savedTokens <= real.contexts.reduce((a, c) => a + c, 0));
});
