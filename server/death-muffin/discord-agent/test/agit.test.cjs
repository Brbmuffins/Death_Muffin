'use strict';
// agit, the agent's git: rm deletes committed and new paths alike (git rm / git clean), never ignored files, never outside the worktree; mv renames;
// flags, globs and `.` are refused for rm and mv as for add.
const test = require('node:test'); const assert = require('node:assert');
const fs = require('fs'); const os = require('os'); const path = require('path'); const { spawnSync, execFileSync } = require('child_process');
const AGIT = path.join(__dirname, '..', 'agit');

test('agit rm and mv: explicit paths inside the worktree only', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'agit-')); const r = path.join(root, 'r');
  try {
    fs.mkdirSync(path.join(r, 'd'), { recursive: true });
    const git = (...a) => execFileSync('git', a, { cwd: r, stdio: 'pipe' }).toString();
    git('init', '-q'); git('config', 'user.email', 't@t'); git('config', 'user.name', 't');
    for (const [f, c] of [['a.txt', 'a'], ['d/b.txt', 'b'], ['.gitignore', '*.log\n'], ['kept.log', 'ignored']]) fs.writeFileSync(path.join(r, f), c);
    git('add', 'a.txt', 'd', '.gitignore'); git('commit', '-qm', 'x');
    fs.writeFileSync(path.join(r, 'junk.txt'), 'junk'); fs.mkdirSync(path.join(r, 'jd')); fs.writeFileSync(path.join(r, 'jd', 'j.txt'), 'j');
    fs.writeFileSync(path.join(root, 'outside.txt'), 'keep');
    const agit = (...a) => spawnSync('bash', [AGIT, ...a], { cwd: r, encoding: 'utf8' });   // through bash: the repo keeps agit without its executable bit (install-runner.sh sets it)
    assert.equal(agit('rm', 'a.txt', 'junk.txt', 'jd', 'kept.log').status, 0);
    assert.ok(!fs.existsSync(path.join(r, 'a.txt')) && !fs.existsSync(path.join(r, 'junk.txt')) && !fs.existsSync(path.join(r, 'jd')), 'committed and new paths are gone');
    assert.ok(fs.existsSync(path.join(r, 'kept.log')), 'an ignored file is never deleted');
    assert.match(git('status', '--short'), /^D  a\.txt$/m, 'the committed one is staged as deleted');
    assert.notEqual(agit('rm', '../outside.txt').status, 0); assert.ok(fs.existsSync(path.join(root, 'outside.txt')), 'outside the worktree is refused');
    for (const bad of [['rm', '.'], ['rm', '-rf', 'd'], ['rm', 'd/*'], ['rm'], ['mv', '-f', 'd/b.txt', 'x']]) {
      const x = agit(...bad); assert.equal(x.status, 2, bad.join(' ')); assert.match(x.stderr, /agit: not allowed/);
    }
    assert.ok(fs.existsSync(path.join(r, 'd', 'b.txt')));
    assert.equal(agit('mv', 'd/b.txt', 'd/c.txt').status, 0); assert.match(git('status', '--short'), /^R  d\/b\.txt -> d\/c\.txt$/m);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
