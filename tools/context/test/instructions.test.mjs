// Tests for the repository's instructions for both terminal tools: AGENTS.md is the one written source (Codex reads it as bytes), CLAUDE.md
// only imports it for Claude Code (sync-instructions.mjs), and the rule check measures each audience on the text it actually receives
// (node --test tools/context/test/*.test.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { REPO, checkRules, delivered, sizes } from '../measure.mjs';
import { STUB, checkInstructions, claudeView, writeStub, CODEX_MAX_BYTES } from '../sync-instructions.mjs';

const SYNC = path.join(REPO, 'tools/context/sync-instructions.mjs');

// A throwaway repo holding what the checks read: the entry files, the agent's prompt, the inventory, its lock and the files rules name.
function scratchRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-instructions-'));
  const { rules } = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/rules.json'), 'utf8'));
  const files = new Set(['CLAUDE.md', 'AGENTS.md', 'tools/context/rules.json', 'tools/context/surfaces.json', 'tools/context/protected.json']);
  for (const r of rules) for (const f of [...(r.enforced || []), ...r.homes.map((h) => h.file)]) files.add(f);
  const surf = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/surfaces.json'), 'utf8'));
  for (const a of Object.values(surf.audiences)) for (const f of [...a.always, ...(a.guides || []), ...(a.discovery || []).map((e) => e.file)]) files.add(f);
  for (const f of surf.references || []) files.add(f);
  const tasks = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/tasks.json'), 'utf8'));
  files.add('tools/context/tasks.json');
  for (const t of tasks.tasks) for (const f of [...t.after.map((e) => e.file), ...(t.agentGuide ? [t.agentGuide] : [])]) files.add(f);
  for (const f of files) { fs.mkdirSync(path.join(dir, path.dirname(f)), { recursive: true }); fs.copyFileSync(path.join(REPO, f), path.join(dir, f)); }
  return dir;
}
const editRules = (dir, fn) => { const f = path.join(dir, 'tools/context/rules.json'); const j = JSON.parse(fs.readFileSync(f, 'utf8')); fn(j.rules); fs.writeFileSync(f, JSON.stringify(j)); };
const editText = (dir, file, fn) => { const f = path.join(dir, file); fs.writeFileSync(f, fn(fs.readFileSync(f, 'utf8'))); };
const reported = (p, prefix) => assert.ok(p.some((x) => x.startsWith(prefix)), `expected "${prefix}..." in:\n${p.join('\n')}`);
const SHARED_PROTECTED = ['no-push-or-deploy-unasked', 'push-waits-for-agent-ship', 'explicit-staging', 'no-secrets', 'ci-gate', 'deploy-only-through-scripts',
  'migrations-additive', 'shared-vps-one-render', 'backend-owns-value', 'old-clients-keep-running', 'propose-then-approve', 'spend-limits-from-owner',
  'never-patch-installed', 'never-weaken-tests'];
const VALUE = /Gold, items, loot rolls, progression and the kill ledger are server-side \(D1\); a client or host\s+never mints them\./;
// Runs the script inside a scratch repo the way regen-godot.sh does (its own copy, no argument) or with --check; returns status and output.
function runSync(dir, ...args) {
  fs.mkdirSync(path.join(dir, 'tools/context'), { recursive: true });
  fs.copyFileSync(SYNC, path.join(dir, 'tools/context/sync-instructions.mjs'));
  const r = spawnSync(process.execPath, [path.join(dir, 'tools/context/sync-instructions.mjs'), ...args], { encoding: 'utf8' });
  return { status: r.status, out: r.stdout + r.stderr };
}
const bytesOf = (dir) => Object.fromEntries(['CLAUDE.md', 'AGENTS.md'].map((f) => [f, fs.existsSync(path.join(dir, f)) ? fs.readFileSync(path.join(dir, f)) : null]));
const unchanged = (dir, before) => { const now = bytesOf(dir); for (const f of Object.keys(before)) assert.ok(before[f] == null ? now[f] == null : now[f]?.equals(before[f]), `${f} changed`); };

test('the repo\'s CLAUDE.md is the import stub and AGENTS.md is self-contained and within Codex\'s budget', () => {
  assert.deepEqual(checkInstructions(REPO), []);
  assert.equal(fs.readFileSync(path.join(REPO, 'CLAUDE.md'), 'utf8'), STUB);
  assert.deepEqual(claudeView(fs.readFileSync(path.join(REPO, 'AGENTS.md'), 'utf8')).imports, []);
  assert.ok(fs.statSync(path.join(REPO, 'AGENTS.md')).size <= CODEX_MAX_BYTES);
});

test('--check is read-only and fails for every broken shape', () => {
  const cases = [
    ['text added to CLAUDE.md', (d) => editText(d, 'CLAUDE.md', (t) => t + '\nNever do X.\n'), 'CLAUDE.md holds text besides the import'],
    ['the import removed', (d) => editText(d, 'CLAUDE.md', (t) => t.replace('@AGENTS.md\n', '')), 'CLAUDE.md does not import AGENTS.md'],
    ['the import in a code span', (d) => fs.writeFileSync(path.join(d, 'CLAUDE.md'), '`@AGENTS.md`\n'), 'CLAUDE.md does not import AGENTS.md'],
    ['the import in a fence', (d) => fs.writeFileSync(path.join(d, 'CLAUDE.md'), '```\n@AGENTS.md\n```\n'), 'CLAUDE.md does not import AGENTS.md'],
    ['the import as indented code', (d) => fs.writeFileSync(path.join(d, 'CLAUDE.md'), 'Rules:\n\n    @AGENTS.md\n'), 'CLAUDE.md does not import AGENTS.md'],
    // Codex P3 (2026-10-21): one active import plus a second, indented copy (code, so not an import) is two delivered lines, not the stub
    ['an active import plus an indented-code copy', (d) => fs.writeFileSync(path.join(d, 'CLAUDE.md'), '@AGENTS.md\n\n    @AGENTS.md\n'), 'CLAUDE.md holds text besides the import'],
    ['the import in an HTML comment', (d) => fs.writeFileSync(path.join(d, 'CLAUDE.md'), '<!-- @AGENTS.md -->\n'), 'CLAUDE.md does not import AGENTS.md'],
    ['two imports', (d) => fs.writeFileSync(path.join(d, 'CLAUDE.md'), '@AGENTS.md\n@README.md\n'), 'CLAUDE.md imports something else as well'],
    ['an import of another file', (d) => fs.writeFileSync(path.join(d, 'CLAUDE.md'), '@README.md\n'), 'CLAUDE.md does not import AGENTS.md'],
    ['AGENTS.md missing', (d) => fs.rmSync(path.join(d, 'AGENTS.md')), 'AGENTS.md is missing'],
    ['AGENTS.md empty', (d) => fs.writeFileSync(path.join(d, 'AGENTS.md'), ' \n'), 'AGENTS.md is empty'],
    ['AGENTS.md over budget in bytes (non-ASCII)', (d) => editText(d, 'AGENTS.md', (t) => t + '\n' + 'é'.repeat(CODEX_MAX_BYTES / 2) + '\n'), 'AGENTS.md is'],
    ['AGENTS.md carrying an import', (d) => editText(d, 'AGENTS.md', (t) => t + '\n@README.md\n'), 'AGENTS.md:'],
    ['CLAUDE.md missing', (d) => fs.rmSync(path.join(d, 'CLAUDE.md')), 'CLAUDE.md is missing'],
  ];
  for (const [name, edit, msg] of cases) {
    const dir = scratchRepo(); edit(dir);
    reported(checkInstructions(dir), msg);
    const before = bytesOf(dir);
    const r = runSync(dir, '--check');
    assert.equal(r.status, 1, `${name}: --check fails`); assert.match(r.out, /PROBLEM/);
    unchanged(dir, before);
  }
  // the budget is bytes, not characters: 'é' is 2 bytes, so half the budget in characters already exceeds it
  const dir = scratchRepo(); editText(dir, 'AGENTS.md', (t) => t + '\n' + 'é'.repeat(CODEX_MAX_BYTES / 2) + '\n');
  assert.ok(fs.readFileSync(path.join(dir, 'AGENTS.md'), 'utf8').length < CODEX_MAX_BYTES * 1.2 && fs.statSync(path.join(dir, 'AGENTS.md')).size > CODEX_MAX_BYTES);
});

test('the no-argument mode (regen\'s call) validates the source, then writes the stub only over a missing CLAUDE.md or the old copy', () => {
  let dir = scratchRepo(); let before = bytesOf(dir);
  let r = runSync(dir); assert.equal(r.status, 0); assert.match(r.out, /already imports/); unchanged(dir, before);
  dir = scratchRepo(); fs.rmSync(path.join(dir, 'CLAUDE.md'));
  r = runSync(dir); assert.equal(r.status, 0); assert.match(r.out, /repaired CLAUDE\.md/);
  assert.equal(fs.readFileSync(path.join(dir, 'CLAUDE.md'), 'utf8'), STUB);
  dir = scratchRepo(); fs.copyFileSync(path.join(dir, 'AGENTS.md'), path.join(dir, 'CLAUDE.md'));   // the old full copy
  const agents = fs.readFileSync(path.join(dir, 'AGENTS.md'));
  r = runSync(dir); assert.equal(r.status, 0); assert.match(r.out, /repaired CLAUDE\.md/);
  assert.equal(fs.readFileSync(path.join(dir, 'CLAUDE.md'), 'utf8'), STUB); assert.ok(fs.readFileSync(path.join(dir, 'AGENTS.md')).equals(agents), 'AGENTS.md never written');
  // text in CLAUDE.md that AGENTS.md lacks is refused, not overwritten
  dir = scratchRepo(); editText(dir, 'CLAUDE.md', (t) => t + '\nA rule only Claude would see.\n'); before = bytesOf(dir);
  r = runSync(dir); assert.equal(r.status, 1); assert.match(r.out, /nothing was written/); unchanged(dir, before);
  // an active import plus an indented-code copy is not the stub: refused with a diagnostic, nothing written (Codex P3)
  dir = scratchRepo(); fs.writeFileSync(path.join(dir, 'CLAUDE.md'), '@AGENTS.md\n\n    @AGENTS.md\n'); before = bytesOf(dir);
  r = runSync(dir); assert.equal(r.status, 1, r.out); assert.match(r.out, /PROBLEM CLAUDE\.md holds text besides the import/); assert.match(r.out, /nothing was written/); unchanged(dir, before);
  // an old copy that differs from the source (edited on one side only) is refused too
  dir = scratchRepo(); fs.copyFileSync(path.join(dir, 'AGENTS.md'), path.join(dir, 'CLAUDE.md')); editText(dir, 'CLAUDE.md', (t) => t + '\nEdited in the copy.\n'); before = bytesOf(dir);
  r = runSync(dir); assert.equal(r.status, 1); unchanged(dir, before);
  // an invalid source fails before anything is written, even with CLAUDE.md missing
  dir = scratchRepo(); editText(dir, 'AGENTS.md', (t) => t + '\n@README.md\n'); fs.rmSync(path.join(dir, 'CLAUDE.md')); before = bytesOf(dir);
  r = runSync(dir); assert.equal(r.status, 1); unchanged(dir, before);
  dir = scratchRepo(); fs.writeFileSync(path.join(dir, 'AGENTS.md'), ''); before = bytesOf(dir);
  assert.equal(writeStub(dir).wrote, false); unchanged(dir, before);
});

test('Claude is measured on what it receives: a clause hidden in a comment of AGENTS.md fails for the session, not for Codex', () => {
  const dir = scratchRepo();
  editText(dir, 'AGENTS.md', (t) => t.replace(VALUE, (m) => `<!-- ${m} -->`));
  const p = checkRules(dir).problems;
  reported(p, 'backend-owns-value: protected rule has no always-loaded home for session');
  assert.ok(!p.some((x) => x.startsWith('backend-owns-value: protected rule has no always-loaded home for codex')), 'Codex reads the bytes, comment included');
  assert.ok(!p.some((x) => x.startsWith('backend-owns-value: clause not found')), 'the clause is still in the file: provenance holds');
  // the comment adds no text for Claude but stays in Codex's size
  const s = sizes(dir);
  const sessionAgents = s.audiences.session.always.find((f) => f.file === 'AGENTS.md'), codexAgents = s.audiences.codex.always.find((f) => f.file === 'AGENTS.md');
  assert.ok(codexAgents.chars > sessionAgents.chars);
  assert.equal(sessionAgents.via, 'CLAUDE.md');
});

test('the import is what gives the session its rules: removing it, or hiding it in a comment, fails every protected rule for the session', () => {
  for (const stub of ['', '<!-- @AGENTS.md -->\n', '`@AGENTS.md`\n', 'Rules:\n\n    @AGENTS.md\n']) {
    const dir = scratchRepo(); fs.writeFileSync(path.join(dir, 'CLAUDE.md'), stub);
    const p = checkRules(dir).problems;
    for (const id of SHARED_PROTECTED) reported(p, `${id}: protected rule has no always-loaded home for session`);
    assert.ok(!p.some((x) => / home for codex/.test(x)), 'Codex is unaffected');
    assert.deepEqual(delivered(dir, 'session', JSON.parse(fs.readFileSync(path.join(dir, 'tools/context/surfaces.json'), 'utf8')).audiences.session).segments.map((g) => g.file), ['CLAUDE.md']);
  }
});

test('the agent\'s prompt is supplied as text: an import there is a problem and gives it no imported homes', () => {
  const dir = scratchRepo();
  editText(dir, 'server/death-muffin/discord-agent/PROMPT-godot.md', (t) => t + '\n@AGENTS.md\n');
  reported(checkRules(dir).problems, 'server/death-muffin/discord-agent/PROMPT-godot.md:');
  const surf = JSON.parse(fs.readFileSync(path.join(dir, 'tools/context/surfaces.json'), 'utf8'));
  assert.deepEqual(delivered(dir, 'agent', surf.audiences.agent).segments.map((g) => g.file), ['server/death-muffin/discord-agent/PROMPT-godot.md']);
  // an import in AGENTS.md is never followed by Codex
  const d2 = scratchRepo(); editText(d2, 'AGENTS.md', (t) => t + '\n@README.md\n');
  reported(checkRules(d2).problems, 'AGENTS.md:');
});

test('the import resolver: one line, inside the checkout, one level, and every failure reported', () => {
  const surfOf = (dir) => JSON.parse(fs.readFileSync(path.join(dir, 'tools/context/surfaces.json'), 'utf8'));
  const run = (files, always = ['sub/ENTRY.md']) => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-resolve-'));
    for (const [f, t] of Object.entries(files)) { fs.mkdirSync(path.join(dir, path.dirname(f)), { recursive: true }); fs.writeFileSync(path.join(dir, f), t); }
    return delivered(dir, 'session', { always, delivery: 'claude-code' });
  };
  let r = run({ 'sub/ENTRY.md': '@../AGENTS.md\n', 'AGENTS.md': '# Rules\nA rule.\n' });
  assert.deepEqual(r.problems, []); assert.deepEqual(r.segments.map((g) => [g.file, g.via]), [['sub/ENTRY.md', null], ['AGENTS.md', 'sub/ENTRY.md']]);
  r = run({ 'sub/ENTRY.md': '@../AGENTS.md\n@../AGENTS.md\n', 'AGENTS.md': 'x\n' }); reported(r.problems, 'sub/ENTRY.md:2: "@../AGENTS.md" is imported twice');
  r = run({ 'sub/ENTRY.md': '@ENTRY.md\n' }); reported(r.problems, 'sub/ENTRY.md:1: "@ENTRY.md" imports itself');
  r = run({ 'sub/ENTRY.md': '@../MISSING.md\n' }); reported(r.problems, 'sub/ENTRY.md:1: "@../MISSING.md" names a file that does not exist');
  r = run({ 'sub/ENTRY.md': '@../../outside.md\n' }); reported(r.problems, 'sub/ENTRY.md:1: "@../../outside.md" points outside the checkout');
  r = run({ 'sub/ENTRY.md': '@/etc/hostname\n' }); reported(r.problems, 'sub/ENTRY.md:1: "@/etc/hostname" points outside the checkout');
  r = run({ 'sub/ENTRY.md': '@../A.md\n', 'A.md': '@B.md\n', 'B.md': 'b\n' }); reported(r.problems, 'A.md:1: "@B.md": an imported file imports nothing itself');
  r = run({ 'sub/ENTRY.md': 'read @../AGENTS.md now\n', 'AGENTS.md': 'x\n' }); reported(r.problems, 'sub/ENTRY.md:1: "@../AGENTS.md" is not on a line of its own');
  r = run({ 'sub/ENTRY.md': '```\n@../AGENTS.md\n```\n`@x` <!-- @y -->\n', 'AGENTS.md': 'x\n' }); assert.deepEqual(r.problems, []); assert.equal(r.segments.length, 1, 'code and comments import nothing');
  assert.ok(surfOf(REPO).audiences.session.delivery === 'claude-code' && surfOf(REPO).audiences.codex.delivery === 'raw' && surfOf(REPO).audiences.agent.delivery === 'raw');
});

test('every shared protected rule is for both terminal tools, with its one home in AGENTS.md and no terminal gap', () => {
  const { rules } = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/rules.json'), 'utf8'));
  const lock = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/protected.json'), 'utf8')).rules;
  for (const id of SHARED_PROTECTED) {
    const r = rules.find((x) => x.id === id);
    assert.ok(r.protected && r.audience.includes('session') && r.audience.includes('codex'), `${id} is protected for session and codex`);
    assert.ok(r.homes.some((h) => h.file === 'AGENTS.md'), `${id} has an AGENTS.md home`);
    assert.ok(!r.homes.some((h) => h.file === 'CLAUDE.md'), `${id}: CLAUDE.md only imports, it is no home`);
    assert.ok(lock[id].audience.includes('codex') && lock[id].audience.includes('session'), `${id}: the lock names both`);
    assert.ok(!(r.gaps || []).some((g) => g.audience === 'session' || g.audience === 'codex'), `${id}: no terminal gap`);
  }
  for (const r of rules) assert.ok(!r.homes.some((h) => h.file === 'CLAUDE.md'), `${r.id}: no rule lives in CLAUDE.md`);
  for (const r of rules.filter((x) => x.homes.some((h) => h.file === 'AGENTS.md'))) assert.ok(r.audience.includes('codex') && r.audience.includes('session'), `${r.id} reaches both`);
});

test('never weaken a test: one sentence in the shared instructions, no terminal gap left', () => {
  const t = fs.readFileSync(path.join(REPO, 'AGENTS.md'), 'utf8');
  assert.match(t, /Never weaken, skip or delete a test to make it pass\./);
  const r = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/rules.json'), 'utf8')).rules.find((x) => x.id === 'never-weaken-tests');
  assert.deepEqual(r.gaps || [], []);
  const dir = scratchRepo();
  editText(dir, 'AGENTS.md', (s) => s.replace('Never weaken, skip or delete a test to make it pass.', ''));
  reported(checkRules(dir).problems, 'never-weaken-tests: clause not found in AGENTS.md');
});

test('the rule check rejects losing Codex: a changed clause, a dropped audience, a guide as its only home, a new gap', () => {
  let dir = scratchRepo();
  assert.deepEqual(checkRules(dir).problems, []);
  editText(dir, 'AGENTS.md', (t) => t.replace(VALUE, 'Value is shared.'));
  let p = checkRules(dir).problems;
  reported(p, 'backend-owns-value: clause not found in AGENTS.md');
  reported(p, 'backend-owns-value: protected rule has no always-loaded home for codex');
  reported(p, 'backend-owns-value: protected rule has no always-loaded home for session');
  dir = scratchRepo();
  editRules(dir, (rules) => { const r = rules.find((x) => x.id === 'ci-gate'); r.audience = r.audience.filter((a) => a !== 'codex'); });
  reported(checkRules(dir).problems, 'ci-gate: protected rule lost audience codex');
  dir = scratchRepo();
  editRules(dir, (rules) => { const r = rules.find((x) => x.id === 'no-secrets'); r.homes = r.homes.map((h) => (h.file === 'AGENTS.md' ? { file: 'README.md', clauses: ['Players get the game through the Windows launcher'] } : h)); });
  p = checkRules(dir).problems;
  reported(p, 'no-secrets: protected rule has no always-loaded home for codex');
  reported(p, 'no-secrets: protected rule has no always-loaded home for session');
  dir = scratchRepo();
  editRules(dir, (rules) => { const r = rules.find((x) => x.id === 'propose-then-approve'); r.homes = r.homes.filter((h) => h.file !== 'AGENTS.md'); r.gaps = [{ audience: 'codex', note: 'Codex only reviews so it does not need it' }]; });
  p = checkRules(dir).problems;
  reported(p, 'propose-then-approve: protected clauses changed');
  reported(p, 'propose-then-approve: new exception: a gap for codex that protected.json does not accept');
});

test('the old copy script still works inside a pre-switch checkout (it is that checkout\'s own script that regen runs)', () => {
  // the Stage-3 script, frozen at the last revision before the switch: CLAUDE.md is its source and AGENTS.md its copy
  const old = fs.readFileSync(path.join(REPO, 'tools/context/test/fixtures/sync-instructions-copy.mjs'), 'utf8');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-oldsync-'));
  fs.mkdirSync(path.join(dir, 'tools/context'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'tools/context/sync-instructions.mjs'), old);
  fs.writeFileSync(path.join(dir, 'CLAUDE.md'), '# rules\nA new rule.\n'); fs.writeFileSync(path.join(dir, 'AGENTS.md'), '# rules\n');
  execFileSync(process.execPath, [path.join(dir, 'tools/context/sync-instructions.mjs')], { stdio: 'pipe' });
  assert.equal(fs.readFileSync(path.join(dir, 'AGENTS.md'), 'utf8'), '# rules\nA new rule.\n', 'the old direction: CLAUDE.md copied to AGENTS.md');
});
