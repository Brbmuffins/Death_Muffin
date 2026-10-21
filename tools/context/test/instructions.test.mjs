// Tests for the repository's instructions for both terminal tools: AGENTS.md is CLAUDE.md's exact copy (sync-instructions.mjs), and the
// rule check keeps every shared protected rule in both entry files for both audiences (node --test tools/context/test/*.test.mjs).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { REPO, checkRules } from '../measure.mjs';
import { checkMirrors, writeMirrors } from '../sync-instructions.mjs';

const SYNC = path.join(REPO, 'tools/context/sync-instructions.mjs');

// A throwaway repo holding what the checks read: the entry files, the agent's prompt, the inventory, its lock and the files rules name.
function scratchRepo() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-instructions-'));
  const { rules } = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/rules.json'), 'utf8'));
  const files = new Set(['CLAUDE.md', 'AGENTS.md', 'tools/context/rules.json', 'tools/context/surfaces.json', 'tools/context/protected.json']);
  for (const r of rules) for (const f of [...(r.enforced || []), ...r.homes.map((h) => h.file)]) files.add(f);
  const surfaces = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/surfaces.json'), 'utf8'));
  for (const a of Object.values(surfaces.audiences)) for (const f of [...a.always, ...(a.guides || [])]) files.add(f);
  for (const f of files) { fs.mkdirSync(path.join(dir, path.dirname(f)), { recursive: true }); fs.copyFileSync(path.join(REPO, f), path.join(dir, f)); }
  return dir;
}
const editRules = (dir, fn) => { const f = path.join(dir, 'tools/context/rules.json'); const j = JSON.parse(fs.readFileSync(f, 'utf8')); fn(j.rules); fs.writeFileSync(f, JSON.stringify(j)); };
const editText = (dir, file, fn) => { const f = path.join(dir, file); fs.writeFileSync(f, fn(fs.readFileSync(f, 'utf8'))); };
const reported = (p, prefix) => assert.ok(p.some((x) => x.startsWith(prefix)), `expected "${prefix}..." in:\n${p.join('\n')}`);
const SHARED_PROTECTED = ['no-push-or-deploy-unasked', 'push-waits-for-agent-ship', 'explicit-staging', 'no-secrets', 'ci-gate', 'deploy-only-through-scripts',
  'migrations-additive', 'shared-vps-one-render', 'backend-owns-value', 'old-clients-keep-running', 'propose-then-approve', 'spend-limits-from-owner',
  'never-patch-installed', 'never-weaken-tests'];

test('the repo\'s AGENTS.md is CLAUDE.md byte for byte', () => {
  assert.deepEqual(checkMirrors(REPO), []);
  assert.ok(fs.readFileSync(path.join(REPO, 'AGENTS.md')).equals(fs.readFileSync(path.join(REPO, 'CLAUDE.md'))));
});

test('a stale, missing or empty copy fails the check, and --check never repairs it', () => {
  let dir = scratchRepo();
  editText(dir, 'CLAUDE.md', (t) => t + '\nA new line in the source only.\n');
  reported(checkMirrors(dir), 'AGENTS.md differs from CLAUDE.md');
  const before = fs.readFileSync(path.join(dir, 'AGENTS.md'));
  fs.copyFileSync(SYNC, path.join(dir, 'tools/context/sync-instructions.mjs'));
  assert.throws(() => execFileSync(process.execPath, [path.join(dir, 'tools/context/sync-instructions.mjs'), '--check'], { stdio: 'pipe' }));
  assert.ok(fs.readFileSync(path.join(dir, 'AGENTS.md')).equals(before), '--check left the stale copy as it was');
  execFileSync(process.execPath, [path.join(dir, 'tools/context/sync-instructions.mjs')], { stdio: 'pipe' });
  assert.deepEqual(checkMirrors(dir), [], 'the write mode makes the copy');
  dir = scratchRepo(); fs.rmSync(path.join(dir, 'AGENTS.md'));
  reported(checkMirrors(dir), 'AGENTS.md is missing');
  dir = scratchRepo(); fs.writeFileSync(path.join(dir, 'AGENTS.md'), ' \n');
  reported(checkMirrors(dir), 'AGENTS.md is empty');
  dir = scratchRepo(); fs.writeFileSync(path.join(dir, 'CLAUDE.md'), '');
  reported(checkMirrors(dir), 'CLAUDE.md is missing or empty');
  assert.throws(() => writeMirrors(dir), /missing or empty/);
  // an edit to the copy alone is as stale as an edit to the source alone
  dir = scratchRepo(); editText(dir, 'AGENTS.md', (t) => t.replace('Never push or deploy unless the task says so.', 'Push when it seems useful.'));
  reported(checkMirrors(dir), 'AGENTS.md differs from CLAUDE.md');
});

test('every shared protected rule is for both terminal tools, written in both entry files with the same clauses', () => {
  const { rules } = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/rules.json'), 'utf8'));
  const lock = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/protected.json'), 'utf8')).rules;
  for (const id of SHARED_PROTECTED) {
    const r = rules.find((x) => x.id === id);
    assert.ok(r.protected && r.audience.includes('session') && r.audience.includes('codex'), `${id} is protected for session and codex`);
    const c = r.homes.find((h) => h.file === 'CLAUDE.md'), a = r.homes.find((h) => h.file === 'AGENTS.md');
    assert.ok(c && a, `${id} has a CLAUDE.md and an AGENTS.md home`);
    assert.deepEqual(a.clauses, c.clauses, `${id}: the same clauses in both`);
    assert.ok(lock[id].audience.includes('codex'), `${id}: the lock names codex, so dropping it fails`);
    assert.ok(!(r.gaps || []).some((g) => g.audience === 'session' || g.audience === 'codex'), `${id}: no terminal gap`);
  }
  // every rule written in CLAUDE.md is in AGENTS.md too, for the codex audience
  for (const r of rules.filter((x) => x.homes.some((h) => h.file === 'CLAUDE.md'))) {
    assert.ok(r.audience.includes('codex') && r.homes.some((h) => h.file === 'AGENTS.md'), `${r.id} reaches Codex`);
  }
});

test('never weaken a test: one sentence in the shared instructions, no terminal gap left', () => {
  const t = fs.readFileSync(path.join(REPO, 'CLAUDE.md'), 'utf8');
  assert.match(t, /Never weaken, skip or delete a test to make it pass\./);
  const r = JSON.parse(fs.readFileSync(path.join(REPO, 'tools/context/rules.json'), 'utf8')).rules.find((x) => x.id === 'never-weaken-tests');
  assert.deepEqual(r.gaps || [], []);
  const dir = scratchRepo();
  editText(dir, 'AGENTS.md', (s) => s.replace('Never weaken, skip or delete a test to make it pass.', ''));
  reported(checkRules(dir).problems, 'never-weaken-tests: clause not found in AGENTS.md');
});

test('the rule check rejects losing Codex: a changed clause in AGENTS.md, a dropped audience, a guide as its only home, a new gap', () => {
  let dir = scratchRepo();
  assert.deepEqual(checkRules(dir).problems, []);
  editText(dir, 'AGENTS.md', (t) => t.replace(/Gold, items, loot rolls, progression and the kill ledger are server-side \(D1\); a client or host\s+never mints them\./, 'Value is shared.'));
  let p = checkRules(dir).problems;
  reported(p, 'backend-owns-value: clause not found in AGENTS.md');
  reported(p, 'backend-owns-value: protected rule has no always-loaded home for codex');
  dir = scratchRepo();
  editRules(dir, (rules) => { const r = rules.find((x) => x.id === 'ci-gate'); r.audience = r.audience.filter((a) => a !== 'codex'); r.homes = r.homes.filter((h) => h.file !== 'AGENTS.md'); });
  reported(checkRules(dir).problems, 'ci-gate: protected rule lost audience codex');
  dir = scratchRepo();
  editRules(dir, (rules) => { const r = rules.find((x) => x.id === 'no-secrets'); r.homes = r.homes.map((h) => (h.file === 'AGENTS.md' ? { file: 'README.md', clauses: ['Players get the game through the Windows launcher'] } : h)); });
  reported(checkRules(dir).problems, 'no-secrets: protected rule has no always-loaded home for codex');
  dir = scratchRepo();
  editRules(dir, (rules) => { const r = rules.find((x) => x.id === 'propose-then-approve'); r.homes = r.homes.filter((h) => h.file !== 'AGENTS.md'); r.gaps = [{ audience: 'codex', note: 'Codex only reviews so it does not need it' }]; });
  p = checkRules(dir).problems;
  reported(p, 'propose-then-approve: protected clauses changed');
  reported(p, 'propose-then-approve: new exception: a gap for codex that protected.json does not accept');
});
