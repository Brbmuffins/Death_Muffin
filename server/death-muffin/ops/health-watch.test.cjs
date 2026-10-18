// Run: node --test server/death-muffin/ops/health-watch.test.cjs
// health-watch.mjs against stand-ins: a local HTTP server answers for the game server, the public API, the lobby and the client manifest and
// records the #build-alerts posts; a local UDP socket stands in for the relay (RELAY_UNIT empty skips its systemd check).
const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const dgram = require('node:dgram');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFile } = require('node:child_process');

const SCRIPT = path.join(__dirname, 'health-watch.mjs');
const MIN = 60000;

function harness() {
  const mode = { auth: 'ok', api: 'ok', lobby: 'ok', manifest: 'ok', hookStatus: 204 };
  const posts = [];
  const server = http.createServer((req, res) => {
    const send = (code, body) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(typeof body === 'string' ? body : JSON.stringify(body)); };
    if (req.method === 'POST' && req.url === '/hook') {
      let s = '';
      req.on('data', (d) => { s += d; }).on('end', () => {
        if (mode.hookStatus < 300) posts.push(JSON.parse(s));
        res.writeHead(mode.hookStatus); res.end();
      });
      return;
    }
    const m = mode[req.url.slice(1)];
    if (m === 'down') return send(502, 'bad gateway');
    if (m === 'baddb') return send(200, { status: 'ok', db: 'disconnected' });
    if (req.url === '/auth') return send(200, { status: 'ok', db: 'connected' });
    if (req.url === '/api') return send(200, { status: 'ok' });
    if (req.url === '/lobby') return send(200, { ok: true, sessions: 0 });
    if (req.url === '/manifest') return send(200, { version: '20261018.000000-abcdef0', files: [] });
    return send(404, {});
  });
  return { mode, posts, server };
}

async function setup(t) {
  const h = harness();
  await new Promise((r) => h.server.listen(0, '127.0.0.1', r));
  const relay = dgram.createSocket('udp4');
  await new Promise((r) => relay.bind(0, '127.0.0.1', r));
  const free = dgram.createSocket('udp4');
  await new Promise((r) => free.bind(0, '127.0.0.1', r));
  const freePort = free.address().port;
  await new Promise((r) => free.close(r));
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-health-'));
  const base = `http://127.0.0.1:${h.server.address().port}`;
  fs.writeFileSync(path.join(dir, 'hook.url'), `${base}/hook\n`);
  t.after(() => { h.server.close(); relay.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  let now = Date.UTC(2026, 9, 18, 20, 0, 0);
  const env = {
    ...process.env, RUNTIME: dir, HOOK_FILE: path.join(dir, 'hook.url'), STATE: path.join(dir, 'state.json'),
    AUTH_URL: `${base}/auth`, API_URL: `${base}/api`, LOBBY_URL: `${base}/lobby`, MANIFEST_URL: `${base}/manifest`,
    RELAY_UNIT: '', RELAY_PORT: String(relay.address().port),
  };
  const run = (extra = {}, args = []) => new Promise((resolve, reject) => {
    execFile(process.execPath, [SCRIPT, ...args], { env: { ...env, NOW_MS: String(now), ...extra } }, (err, stdout, stderr) => {
      if (err) reject(new Error(`${err.message}\n${stderr}`)); else resolve(stdout);
    });
  });
  const state = () => JSON.parse(fs.readFileSync(env.STATE, 'utf8'));
  return { ...h, run, state, freePort, tick: (ms = MIN) => { now += ms; } };
}

test('all services up: nothing is posted', async (t) => {
  const w = await setup(t);
  await w.run();
  assert.strictEqual(w.posts.length, 0);
  for (const id of ['auth', 'api', 'lobby', 'relay', 'downloads']) assert.strictEqual(w.state()[id].fails, 0, id);
});

test('one failure stays quiet; the second alerts once; no repeat until the reminder; then the recovery', async (t) => {
  const w = await setup(t);
  w.mode.auth = 'down';
  await w.run();
  assert.strictEqual(w.posts.length, 0, 'a single failed check posts nothing');
  w.tick(); await w.run();
  assert.strictEqual(w.posts.length, 1);
  assert.match(w.posts[0].content, /🔴 \*\*Game server/);
  assert.match(w.posts[0].content, /HTTP 502/);
  assert.match(w.posts[0].content, /systemctl status death-muffin-auth/);
  assert.deepStrictEqual(w.posts[0].allowed_mentions, { parse: [] }, 'nobody is mentioned');
  w.tick(); await w.run();
  w.tick(); await w.run();
  assert.strictEqual(w.posts.length, 1, 'no repeat while it stays down');
  w.tick(61 * MIN); await w.run();
  assert.strictEqual(w.posts.length, 2);
  assert.match(w.posts[1].content, /⏳ \*\*Game server[^*]*\*\* is still down after 64 min/);
  w.mode.auth = 'ok';
  w.tick(); await w.run();
  assert.strictEqual(w.posts.length, 3);
  assert.match(w.posts[2].content, /✅ \*\*Game server[^*]*\*\* is back, after 65 min down/);
  w.tick(); await w.run();
  assert.strictEqual(w.posts.length, 3, 'nothing more once it is back');
});

test('a database the game server cannot reach counts as down', async (t) => {
  const w = await setup(t);
  w.mode.auth = 'baddb';
  await w.run(); w.tick(); await w.run();
  assert.strictEqual(w.posts.length, 1);
  assert.match(w.posts[0].content, /database disconnected/);
});

test('several services failing together go out in one post; the relay is checked by its UDP port', async (t) => {
  const w = await setup(t);
  w.mode.lobby = 'down'; w.mode.manifest = 'down';
  await w.run({ RELAY_PORT: String(w.freePort) });
  w.tick(); await w.run({ RELAY_PORT: String(w.freePort) });
  assert.strictEqual(w.posts.length, 1);
  const c = w.posts[0].content;
  assert.match(c, /Lobby/); assert.match(c, /Co-op relay/); assert.match(c, /nothing listens on udp/); assert.match(c, /Game download/);
  assert.doesNotMatch(c, /Game server/);
});

test('a failed post is retried on the next run', async (t) => {
  const w = await setup(t);
  w.mode.api = 'down'; w.mode.hookStatus = 500;
  await w.run(); w.tick(); await w.run();
  assert.strictEqual(w.posts.length, 0);
  assert.strictEqual(w.state().api.alerted, false, 'not marked as alerted when the post failed');
  w.mode.hookStatus = 204;
  w.tick(); await w.run();
  assert.strictEqual(w.posts.length, 1);
  assert.match(w.posts[0].content, /Public API/);
});

test('--dry-run prints the message and changes nothing', async (t) => {
  const w = await setup(t);
  w.mode.auth = 'down';
  await w.run(); w.tick();
  const before = w.state();
  const out = await w.run({}, ['--dry-run']);
  assert.match(out, /🔴 \*\*Game server/);
  assert.strictEqual(w.posts.length, 0);
  assert.deepStrictEqual(w.state(), before);
});
