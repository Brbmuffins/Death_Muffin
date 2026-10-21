// Run: node --test server/death-muffin/ops/drift-leftovers.test.cjs
// drift-report.sh's wt/ check (check_wt_dirs) in isolation: the function is cut out of the script and run against a throwaway repo with a
// registered worktree and leftover folders in a temp folder. The real checkout, its worktrees and Discord are never touched.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const SCRIPT = fs.readFileSync(path.join(__dirname, 'drift-report.sh'), 'utf8');
const FN = SCRIPT.slice(SCRIPT.indexOf('check_wt_dirs() {'), SCRIPT.indexOf('\n}\n', SCRIPT.indexOf('check_wt_dirs() {')) + 3);

function world() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-drift-wt-'));
  const repo = path.join(dir, 'game');
  const env = { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' };
  const git = (...a) => execFileSync('git', ['-C', repo, ...a], { env, stdio: 'pipe' });
  fs.mkdirSync(path.join(dir, 'wt'));
  execFileSync('git', ['init', '-q', '-b', 'main', repo], { env });
  git('commit', '-q', '--allow-empty', '-m', 'init');
  const run = () => {
    const prog = `REPO="${repo}"; g() { git -C "$REPO" "$@"; }; drift() { echo "DRIFT $1"; }\n${FN}\ncheck_wt_dirs`;
    const r = spawnSync('bash', ['-c', prog], { encoding: 'utf8' });
    return (r.stdout + r.stderr).trim().split('\n').filter(Boolean).map((l) => l.replace(dir, '<dir>'));
  };
  return { dir, git, run, cleanup: () => fs.rmSync(dir, { recursive: true, force: true }) };
}

test('the check is in the script and runs from it', () => {
  assert.ok(FN.startsWith('check_wt_dirs() {') && FN.endsWith('\n}\n'));
  assert.match(SCRIPT, /^check_wt_dirs$/m);
});

test('a registered worktree is not drift; a folder git does not list is', () => {
  const W = world(); try {
    W.git('worktree', 'add', '-q', '-b', 'discord/abc', path.join(W.dir, 'wt', 'discord-abc'));
    assert.deepEqual(W.run(), []);
    fs.mkdirSync(path.join(W.dir, 'wt', 'dm-sbx-test-x1'));
    assert.deepEqual(W.run(), ['DRIFT directory in wt/ that is not a registered worktree: <dir>/wt/dm-sbx-test-x1']);
  } finally { W.cleanup(); }
});

test('a leftover folder whose name starts another worktree\'s name is still drift', () => {
  const W = world(); try {
    W.git('worktree', 'add', '-q', '-b', 'discord/f00d42-13', path.join(W.dir, 'wt', 'discord-f00d42-13'));
    fs.mkdirSync(path.join(W.dir, 'wt', 'discord-f00d42'));
    fs.mkdirSync(path.join(W.dir, 'wt', 'discord-f00d42-1'));
    assert.deepEqual(W.run().sort(), [
      'DRIFT directory in wt/ that is not a registered worktree: <dir>/wt/discord-f00d42',
      'DRIFT directory in wt/ that is not a registered worktree: <dir>/wt/discord-f00d42-1',
    ]);
  } finally { W.cleanup(); }
});
