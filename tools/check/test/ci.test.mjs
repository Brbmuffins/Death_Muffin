// tools/check/ci.sh, the CI gate (tools/check/README.md "CI is the gate"), against a stand-in GitHub API on this machine: a verdict follows the
// files (a run of another commit with the same tree counts), the four answers, waiting, the failed suites, the failure log, and conditional requests.
// Run: node --test tools/check/test/*.test.mjs (also in CI).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const CI = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../ci.sh');

async function world() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-ci-'));
  const repo = path.join(root, 'repo'); fs.mkdirSync(repo);
  const git = (...a) => execFileSync('git', ['-C', repo, ...a], { encoding: 'utf8' }).trim();
  git('init', '-q'); git('config', 'user.name', 't'); git('config', 'user.email', 't@t');
  fs.writeFileSync(path.join(repo, 'a.txt'), 'one\n'); git('add', '-A'); git('commit', '-qm', 'one');
  const one = git('rev-parse', 'HEAD');
  git('commit', '-q', '--allow-empty', '-m', 'same files');   // another commit, the same tree
  const same = git('rev-parse', 'HEAD');
  fs.writeFileSync(path.join(repo, 'a.txt'), 'two\n'); git('commit', '-qam', 'two');
  const two = git('rev-parse', 'HEAD');
  const state = { runs: [], checkRuns: {}, annotations: {}, logs: {}, hits: [], auths: [], etag: 'v1', goodToken: 'good-token' };
  const server = http.createServer((req, res) => {
    state.hits.push(`${req.method} ${req.url} ${req.headers['if-none-match'] || ''}`);
    const u = new URL(req.url, 'http://x');
    state.auths.push(req.headers.authorization || '');
    const send = (code, body, headers = {}) => { res.writeHead(code, { 'content-type': 'application/json', ...headers }); res.end(body === undefined ? '' : JSON.stringify(body)); };
    // A token that is not the good one is refused the way GitHub refuses an expired or revoked one.
    if (req.headers.authorization && req.headers.authorization !== `Bearer ${state.goodToken}`) return send(401, { message: 'Bad credentials' });
    if (u.pathname === '/repos/o/r/actions/runs') {
      const sha = u.searchParams.get('head_sha');
      if (sha) return send(200, { workflow_runs: state.runs.filter((r) => r.head_sha === sha) });
      if (state.limited) return send(403, { message: 'API rate limit exceeded' }, { 'x-ratelimit-remaining': '0', 'x-ratelimit-reset': String(Math.floor(Date.now() / 1000) + 3600) });
      if (req.headers['if-none-match'] === state.etag) return send(304);
      return send(200, { workflow_runs: state.runs }, { etag: state.etag });
    }
    let m = /^\/repos\/o\/r\/commits\/([0-9a-f]+)\/check-runs$/.exec(u.pathname);
    if (m) return send(200, { check_runs: state.checkRuns[m[1]] || [] });
    m = /^\/repos\/o\/r\/check-runs\/(\d+)\/annotations$/.exec(u.pathname);
    if (m) return send(200, state.annotations[m[1]] || []);
    // a job's log: plain text, served only with a token (GitHub's answer without one is a 403)
    m = /^\/repos\/o\/r\/actions\/jobs\/(\d+)\/logs$/.exec(u.pathname);
    if (m) { if (!req.headers.authorization) return send(403, { message: 'Must have admin rights to Repository.' }); res.writeHead(200, { 'content-type': 'text/plain' }); return res.end(state.logs[m[1]] || ''); }
    send(404, { message: 'Not Found' });
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const cache = path.join(root, 'cache');
  const env = { ...process.env, DM_GITHUB_API: `http://127.0.0.1:${server.address().port}`, DM_GITHUB_REPO: 'o/r', DM_CI_CACHE: cache,
    DM_GITHUB_TOKEN_FILE: path.join(root, 'token'), DM_CI_EVERY: '0', DM_CI_POLL: '0.2', DM_CI_NONE_TRIES: '3' };
  const tokenFile = path.join(root, 'token');
  const useToken = (t) => fs.writeFileSync(tokenFile, t + '\n');
  const ci = (...args) => new Promise((resolve) => {
    const p = spawn('bash', [CI, ...args], { cwd: repo, env });
    let out = ''; p.stdout.on('data', (d) => { out += d; }); p.stderr.on('data', (d) => { out += d; });
    p.on('close', (code) => resolve({ code, out: out.trim() }));
  });
  const run = (id, sha, status, conclusion) => ({ id, name: 'CI', head_sha: sha, status, conclusion, html_url: `https://github.test/runs/${id}` });
  return { root, repo, cache, tokenFile, useToken, env, one, same, two, state, ci, run, api: env.DM_GITHUB_API, cleanup: () => { server.close(); fs.rmSync(root, { recursive: true, force: true }); } };
}

test('a verdict belongs to the files: a passed run of another commit with the same tree passes this one; different files do not', async () => {
  const W = await world(); try {
    W.state.runs = [W.run(1, W.one, 'completed', 'success')];
    assert.equal((await W.ci('status', W.same)).out, 'passed https://github.test/runs/1');
    assert.equal((await W.ci('status', W.two)).out, 'none -');
    assert.equal((await W.ci('wait', W.same, '1')).code, 0);
  } finally { W.cleanup(); }
});

test('pending, failed and cancelled; a passed run wins over an older failed one of the same files; only the CI workflow counts', async () => {
  const W = await world(); try {
    W.state.runs = [W.run(2, W.two, 'in_progress', null), { ...W.run(9, W.two, 'completed', 'success'), name: 'Windows launcher' }];
    assert.match((await W.ci('status', W.two)).out, /^pending /);
    W.state.runs = [W.run(2, W.two, 'completed', 'failure')]; W.state.etag = 'v2';
    assert.match((await W.ci('status', W.two)).out, /^failed https:\/\/github\.test\/runs\/2$/);
    assert.equal((await W.ci('wait', W.two, '1')).code, 1);
    W.state.runs = [W.run(3, W.two, 'completed', 'cancelled')]; W.state.etag = 'v3';
    assert.match((await W.ci('status', W.two)).out, /^cancelled /);
    W.state.runs = [W.run(2, W.two, 'completed', 'failure'), W.run(4, W.two, 'completed', 'success')]; W.state.etag = 'v4';
    assert.match((await W.ci('status', W.two)).out, /^passed .*runs\/4$/);
  } finally { W.cleanup(); }
});

test('wait follows a run to its end, and gives up with exit 2 when no run comes', async () => {
  const W = await world(); try {
    W.state.runs = [W.run(5, W.two, 'queued', null)];
    const waiting = W.ci('wait', W.two, '1');
    await new Promise((r) => setTimeout(r, 600));
    W.state.runs = [W.run(5, W.two, 'completed', 'success')]; W.state.etag = 'v5';
    const r = await waiting;
    assert.equal(r.code, 0, r.out); assert.match(r.out, /^passed /);
    W.state.runs = []; W.state.etag = 'v6';
    const n = await W.ci('wait', W.one, '1');
    assert.equal(n.code, 2); assert.match(n.out, /no CI run for this revision/);
  } finally { W.cleanup(); }
});

test('failed names the game suites from the annotations of the failing jobs, each once', async () => {
  const W = await world(); try {
    W.state.checkRuns[W.two] = [{ id: 11, conclusion: 'failure' }, { id: 12, conclusion: 'success' }, { id: 13, conclusion: 'failure' }];
    W.state.annotations[11] = [{ title: 'client suite rites failed', message: 'FAIL rites' }, { title: 'client suite relay/udp failed', message: 'x' }, { title: '', message: 'Process completed with exit code 1.' }];
    W.state.annotations[13] = [{ title: 'client suite rites failed', message: 'again' }];
    W.state.annotations[12] = [{ title: 'client suite hud failed', message: 'from a passing job: ignored' }];
    assert.deepEqual((await W.ci('failed', W.two)).out.split('\n'), ['rites', 'relay/udp']);
  } finally { W.cleanup(); }
});

test('log prints each failed job\'s failing step and its last lines, and nothing without a token', async () => {
  const W = await world(); try {
    W.state.checkRuns[W.two] = [{ id: 21, name: 'Backend + lobby tests', conclusion: 'failure' }, { id: 22, name: 'Godot suites', conclusion: 'success' }];
    const t = (l) => `2026-10-28T12:00:00.0000000Z ${l}`;
    W.state.logs[21] = ['\ufeff' + t('##[group]Run npm ci'), t('added 10 packages'), t('##[endgroup]'), t('##[group]Run npm run test:server'),
      t('##[endgroup]'), t('ok 1 - the save route'), t('not ok 2 - the save route refuses a bad position'), t('##[error]Process completed with exit code 1.'),
      t('##[group]Run cleanup'), t('##[error]a later error')].join('\n');
    W.state.logs[22] = t('##[error]a passing job is not read');
    assert.equal((await W.ci('log', W.two)).out, '', 'no token: nothing');
    W.useToken('good-token');
    assert.equal((await W.ci('log', W.two)).out, ['== Backend + lobby tests: npm run test:server', 'ok 1 - the save route',
      'not ok 2 - the save route refuses a bad position', 'Process completed with exit code 1.'].join('\n'));
    assert.ok(!W.state.hits.some((h) => h.includes('/actions/jobs/22/')), 'a passing job is not read');
  } finally { W.cleanup(); }
});

test('the recent runs are one shared copy, refreshed with a conditional request (an unchanged answer is a 304)', async () => {
  const W = await world(); try {
    W.state.runs = [W.run(1, W.one, 'completed', 'success')];
    await W.ci('status', W.one); await W.ci('status', W.same);
    const lists = W.state.hits.filter((h) => h.startsWith('GET /repos/o/r/actions/runs?per_page'));
    assert.equal(lists.length, 2); assert.match(lists[1], / v1$/, 'the second refresh asks only whether it changed');
    assert.equal((await W.ci('status', W.one)).out, 'passed https://github.test/runs/1', 'the kept copy still answers after a 304');
  } finally { W.cleanup(); }
});

test('with the GitHub API limit used up it says until when, keeps answering from the last copy, and does not ask again before the reset', async () => {
  const W = await world(); try {
    W.state.runs = [W.run(1, W.one, 'completed', 'success')];
    assert.equal((await W.ci('status', W.one)).out, 'passed https://github.test/runs/1');
    W.state.limited = true; W.state.etag = 'v9';
    const r = await W.ci('status', W.one);
    assert.match(r.out, /API limit is used up until \d\d:\d\d UTC/); assert.match(r.out, /passed https:\/\/github\.test\/runs\/1$/);
    const before = W.state.hits.length;
    await W.ci('status', W.one); await W.ci('status', W.same);
    assert.equal(W.state.hits.filter((h, i) => i >= before && h.includes('per_page')).length, 0, 'no list request until the reset');
  } finally { W.cleanup(); }
});

test('a red run of another commit with the same files waits for this commit\'s own run (a re-push to retry a flake), and stands when none comes', async () => {
  const W = await world(); try {
    W.state.runs = [W.run(7, W.one, 'completed', 'failure')];
    const waiting = W.ci('wait', W.same, '1');   // `same` has the same tree as `one`, pushed again to retry
    await new Promise((r) => setTimeout(r, 700));
    W.state.runs = [W.run(7, W.one, 'completed', 'failure'), W.run(8, W.same, 'completed', 'success')]; W.state.etag = 'v7';
    const r = await waiting;
    assert.equal(r.code, 0, r.out); assert.match(r.out, /^passed .*runs\/8$/);
    W.state.runs = [W.run(7, W.one, 'completed', 'failure')]; W.state.etag = 'v8';
    const t0 = Date.now();
    const n = await new Promise((resolve) => {
      const p = spawn('bash', [CI, 'wait', W.same, '1'], { cwd: W.repo, env: { ...process.env, DM_GITHUB_API: W.api, DM_GITHUB_REPO: 'o/r', DM_CI_CACHE: path.join(W.root, 'cache2'), DM_GITHUB_TOKEN_FILE: path.join(W.root, 'none'), DM_CI_EVERY: '0', DM_CI_POLL: '0.2', DM_CI_OWN_WAIT: '2' } });
      let out = ''; p.stdout.on('data', (d) => { out += d; }); p.on('close', (code) => resolve({ code, out: out.trim() }));
    });
    assert.equal(n.code, 1); assert.match(n.out, /another commit with these files/); assert.ok(Date.now() - t0 >= 1000, 'it gave the own run its time first');
  } finally { W.cleanup(); }
});

test('a token GitHub accepts is sent on every call and leaves no marker', async () => {
  const W = await world(); try {
    W.useToken('good-token');
    W.state.runs = [W.run(1, W.one, 'completed', 'success')];
    const r = await W.ci('status', W.one);
    assert.equal(r.out, 'passed https://github.test/runs/1');
    assert.ok(W.state.auths.length > 0 && W.state.auths.every((a) => a === 'Bearer good-token'));
    assert.equal(fs.existsSync(path.join(W.cache, 'token-bad')), false);
  } finally { W.cleanup(); }
});

test('a refused token (401) falls back to no token: the answer still comes, a token-bad marker is written, one note says so, and the token is not sent for an hour', async () => {
  const W = await world(); try {
    W.useToken('expired-token');
    W.state.runs = [W.run(1, W.one, 'completed', 'success')];
    const r = await W.ci('status', W.one);
    assert.match(r.out, /ci\.sh: GitHub refused the API token in .*token \(expired or revoked\?\); checking without it, 60 calls an hour/);
    assert.match(r.out, /passed https:\/\/github\.test\/runs\/1$/);
    assert.equal(r.out.split('\n').filter((l) => l.includes('refused the API token')).length, 1);
    assert.match(fs.readFileSync(path.join(W.cache, 'token-bad'), 'utf8'), /^\d{4}-\d\d-\d\dT/);
    assert.deepEqual(W.state.auths, ['Bearer expired-token', ''], 'the refused call, then the same call without the token');
    // while the marker is under an hour old: no token, no second note, no wasted 401
    W.state.auths.length = 0; W.state.etag = 'v2';
    const again = await W.ci('status', W.one);
    assert.equal(again.out, 'passed https://github.test/runs/1');
    assert.ok(W.state.auths.length > 0 && W.state.auths.every((a) => a === ''));
    // the lookup of a revision older than the recent runs and the failed-suites list fall back too
    W.state.checkRuns[W.two] = [{ id: 11, conclusion: 'failure' }];
    W.state.annotations[11] = [{ title: 'client suite rites failed', message: 'x' }];
    assert.equal((await W.ci('failed', W.two)).out, 'rites');
  } finally { W.cleanup(); }
});

test('after an hour the refused token is tried again: a replaced token works and clears the marker, a still-bad one gets a fresh marker and note', async () => {
  const W = await world(); try {
    W.useToken('expired-token');
    W.state.runs = [W.run(1, W.one, 'completed', 'success')];
    await W.ci('status', W.one);
    const marker = path.join(W.cache, 'token-bad');
    const old = new Date(Date.now() - 3700 * 1000);
    fs.utimesSync(marker, old, old);
    W.state.auths.length = 0; W.state.etag = 'v2';
    const bad = await W.ci('status', W.one);   // still the same dead token: tried once, refused, note again
    assert.equal(W.state.auths[0], 'Bearer expired-token');
    assert.match(bad.out, /refused the API token/);
    assert.ok(Date.now() - fs.statSync(marker).mtimeMs < 60000, 'a fresh marker');
    fs.utimesSync(marker, old, old);
    W.useToken('good-token'); W.state.auths.length = 0; W.state.etag = 'v3';
    const good = await W.ci('status', W.one);
    assert.equal(good.out, 'passed https://github.test/runs/1');
    assert.ok(W.state.auths.every((a) => a === 'Bearer good-token'));
    assert.equal(fs.existsSync(marker), false, 'an accepted token clears the marker');
  } finally { W.cleanup(); }
});
