// Run: node --test server/death-muffin/ops/drift-token.test.cjs
// drift-report.sh's GitHub token check (check_github_token) in isolation: the function is cut out of the script and run against a fake GitHub (a local HTTP
// server) with a fake token file in a temp folder. The real script, Discord, GitHub and the real token file are never touched.
const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');

const SCRIPT = fs.readFileSync(path.join(__dirname, 'drift-report.sh'), 'utf8');
const FN = SCRIPT.slice(SCRIPT.indexOf('GH_TOKEN_HOWTO='), SCRIPT.indexOf('\n}\n', SCRIPT.indexOf('check_github_token()')) + 3);
const GOOD = 'fake-good-token-for-tests';

async function world(handler) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-drift-token-'));
  const seen = [];
  const server = http.createServer((req, res) => { seen.push({ url: req.url, auth: req.headers.authorization }); handler(req, res); });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const file = path.join(dir, 'token');
  const run = () => new Promise((resolve) => {
    const prog = `TMP="${dir}"; GH_TOKEN_FILE="${file}"; GH_API="http://127.0.0.1:${server.address().port}"\n` +
      `drift() { echo "DRIFT $1"; }; info() { echo "INFO $1"; }\n${FN}\ncheck_github_token`;
    const p = spawn('bash', ['-c', prog]);
    let out = ''; p.stdout.on('data', (d) => { out += d; }); p.stderr.on('data', (d) => { out += d; });
    p.on('close', () => resolve(out.trim()));
  });
  return { dir, file, seen, run, cleanup: () => { server.close(); fs.rmSync(dir, { recursive: true, force: true }); } };
}
const ok = (expiry) => (req, res) => {
  if (req.headers.authorization !== `Bearer ${GOOD}`) { res.writeHead(401); return res.end('{}'); }
  res.writeHead(200, expiry ? { 'github-authentication-token-expiration': expiry } : {}); res.end('{}');
};
const utc = (days) => new Date(Date.now() + days * 86400e3).toISOString().replace('T', ' ').replace(/\.\d+Z$/, ' UTC');

test('a missing token file is drift, in plain words with how to get a new one', async () => {
  const W = await world(ok()); try {
    const out = await W.run();
    assert.match(out, /^DRIFT the GitHub token file is missing/);
    assert.match(out, /Muffins \(brbmuffins, the repo owner\) makes a new one on github\.com -> Settings -> Developer settings -> Fine-grained tokens/);
    assert.match(out, /Public repositories \(read-only\)/); assert.match(out, /DMs it to Muffin Core/);
    assert.equal(W.seen.length, 0);
  } finally { W.cleanup(); }
});

test('a refused token (401) is drift', async () => {
  const W = await world(ok('')); try {
    fs.writeFileSync(W.file, 'ghp_revoked\n');
    const out = await W.run();
    assert.match(out, /^DRIFT GitHub refuses the CI token \(expired or revoked\)/); assert.match(out, /DMs it to Muffin Core/);
    assert.equal(W.seen[0].url, '/rate_limit'); assert.equal(W.seen[0].auth, 'Bearer ghp_revoked');
  } finally { W.cleanup(); }
});

test('a token that expires in under 14 days is drift; one with more time, or no expiry, is not', async () => {
  let W = await world(ok(utc(5))); try {
    fs.writeFileSync(W.file, GOOD + '\n');
    assert.match(await W.run(), /^DRIFT the GitHub token for CI checks runs out in [45] day\(s\)/);
  } finally { W.cleanup(); }
  W = await world(ok(utc(60))); try {
    fs.writeFileSync(W.file, GOOD + '\n');
    assert.match(await W.run(), /^INFO GitHub token works, expires in (59|60) days$/);
  } finally { W.cleanup(); }
  W = await world(ok()); try {
    fs.writeFileSync(W.file, GOOD + '\n');
    assert.equal(await W.run(), 'INFO GitHub token works (no expiry date)');
  } finally { W.cleanup(); }
});

test('GitHub unreachable or answering something else is not drift (the check is not guessed)', async () => {
  const W = await world((req, res) => { res.writeHead(503); res.end(); }); try {
    fs.writeFileSync(W.file, GOOD + '\n');
    assert.match(await W.run(), /^INFO GitHub token not checked: GitHub answered 503/);
  } finally { W.cleanup(); }
});
