// Run: node --test server/death-muffin/ops/team-report.test.cjs
// team-report.sh (the release checks' report to #build-alerts) against a fake backend (the runner's /internal/team routes, with the secret check) and a fake webhook, both
// local HTTP servers, with results in temp folders: the real backend, Discord, the webhook file and the results folder are never touched.
const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { spawn, execFileSync } = require('node:child_process');

const SCRIPT = path.join(__dirname, 'team-report.sh');
const SECRET = 'runner-secret-0123456789-abcdef';
const TOKEN = 'TOKEN-abc123-webhook-secret-part';
const HOUR = 3600 * 1000;
const T0 = Date.UTC(2026, 9, 19, 12, 0, 0);   // the first job of the release was queued
const V = '20261019.120000-abcdef1';
const PC_A = 'pc-alien-0001';
const PC_H = 'pc-helix-0002';
const PC_M = 'pc-muffin-0003';
const PCS = [
  { accountId: 3, username: 'warbogar', pcId: PC_A, name: 'ALIENWARE', gpu: 'NVIDIA GeForce GTX 970' },
  { accountId: 2, username: 'helix', pcId: PC_H, name: 'HELIX-DESKTOP', gpu: 'NVIDIA GeForce RTX 4080' },
  { accountId: 1, username: 'brbmuffins', pcId: PC_M, name: 'MUFFIN-PC', gpu: 'AMD Radeon RX 6800' },
];
const STEPS = ['install', 'quit-loading', 'screens', 'stutter', 'bench', 'soak'];
const RESOLUTIONS = [[1920, 1080], [2560, 1440], [3840, 2160], [3440, 1440]];
const SHOTS = ['bag', 'character', 'spellbook', 'vault', 'map', 'hud'];
const iso = (ms) => new Date(ms).toISOString();
// Pillow may live in the user's own site-packages (the VPS does): the tests run with a temp HOME, so name where it is. Without Pillow (CI's runner may have none) the tests
// that look at a sheet skip, and the others expect the report's note that there are no sheets.
const PY_USER = process.env.PYTHONUSERBASE || path.join(os.homedir(), '.local');
const HAS_PIL = (() => { try { execFileSync('python3', ['-c', 'import PIL.Image, PIL.ImageDraw, PIL.ImageFont'], { env: { PATH: process.env.PATH, PYTHONUSERBASE: PY_USER }, stdio: 'ignore' }); return true; } catch { return false; } })();
const SHEETS_NOTE = '\nPillow is not installed: no contact sheets.';

/** A PNG of one colour (RGB), small: the reporter scales it to its cell by the resolution in its name. */
function png(w, h, [r, g, b]) {
  const row = w * 3 + 1;
  const raw = Buffer.alloc(row * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { raw[y * row + 1 + x * 3] = r; raw[y * row + 2 + x * 3] = g; raw[y * row + 3 + x * 3] = b; }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(td) >>> 0);
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
/** A colour for a (PC, scale, shot) that no other cell has, so a sheet shows which cell is which. */
const colourOf = (pcIndex, scaled, shotIndex) => [40 + pcIndex * 80, scaled ? 200 : 60, 30 + shotIndex * 35];

/** The fake backend: the runner's routes over `state.jobs`, recording every call. */
function fakeBackend(state) {
  const calls = [];
  const server = http.createServer((req, res) => {
    calls.push({ method: req.method, url: req.url, secret: req.headers['x-team-secret'] });
    const send = (status, obj) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
    if (req.headers['x-team-secret'] !== SECRET) return send(404, { success: false, error: 'Not found' });
    const u = new URL(req.url, 'http://x');
    if (req.method === 'GET' && u.pathname === '/internal/team/jobs') {
      if (state.listStatus) return send(state.listStatus, { success: false, error: 'no' });
      const q = u.searchParams;
      const groups = { finished: ['done', 'failed'], open: ['queued', 'running'] };
      let rows = state.jobs.filter((j) => (!q.get('kind') || j.kind === q.get('kind')) && (!q.get('status') || (groups[q.get('status')] || [q.get('status')]).includes(j.status)) && (q.get('unreported') !== '1' || !j.reportedAt));
      rows = rows.slice(0, Number(q.get('limit') || 50));
      return send(200, { success: true, data: { jobs: rows } });
    }
    if (req.method === 'GET' && u.pathname === '/internal/team/pcs') return send(200, { success: true, data: { pcs: state.pcs } });
    const m = /^\/internal\/team\/jobs\/([0-9a-f]{12})\/reported$/.exec(u.pathname);
    if (req.method === 'POST' && m) {
      if (state.reportedStatus) return send(state.reportedStatus, { success: false, error: 'boom' });
      const j = state.jobs.find((x) => x.id === m[1]);
      if (!j) return send(404, { success: false, error: 'no such job' });
      if (!['done', 'failed', 'cancelled', 'expired'].includes(j.status)) return send(409, { success: false, error: 'not finished' });
      j.reportedAt = j.reportedAt || iso(Date.now());
      return send(200, { success: true, data: { id: j.id, reportedAt: j.reportedAt } });
    }
    return send(404, { success: false, error: 'Not found' });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ calls, url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((r) => server.close(r)) })));
}

/** The fake webhook: records every post (JSON, or multipart with files), answers `state.status`. */
function fakeWebhook(state) {
  const posts = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      const type = req.headers['content-type'] || '';
      const post = { url: req.url, userAgent: req.headers['user-agent'], type, files: [], json: null };
      if (type.startsWith('multipart/form-data')) {
        const boundary = Buffer.from('--' + type.split('boundary=')[1]);
        let at = body.indexOf(boundary);
        while (at >= 0) {
          const next = body.indexOf(boundary, at + boundary.length);
          if (next < 0) break;
          const part = body.subarray(at + boundary.length + 2, next - 2);
          const split = part.indexOf('\r\n\r\n');
          const head = part.subarray(0, split).toString();
          const data = part.subarray(split + 4);
          if (/name="payload_json"/.test(head)) post.json = JSON.parse(data.toString());
          else post.files.push({ name: /name="([^"]+)"/.exec(head)[1], filename: /filename="([^"]+)"/.exec(head)[1], type: /Content-Type: (.+)/.exec(head)[1].trim(), data });
          at = next;
        }
      } else post.json = JSON.parse(body.toString());
      if (state.status < 300) posts.push(post);
      res.writeHead(state.status); res.end();
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({ posts, state, url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise((r) => server.close(r)) })));
}

/** A world: backend, webhook, results folder, state folder, secret and webhook files. */
async function setup(t, { backend = {}, hook = {} } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-team-report-'));
  const state = { jobs: [], pcs: PCS.map((p) => ({ ...p, version: '0.4.0', mode: 'ask', state: {}, lastSeen: iso(T0) })), ...backend };
  const be = await fakeBackend(state);
  const wh = await fakeWebhook({ status: 204, ...hook });
  const results = path.join(dir, 'team-results');
  fs.mkdirSync(results);
  fs.writeFileSync(path.join(dir, 'secret'), `${SECRET}\n`);
  fs.mkdirSync(path.join(dir, 'private'));
  fs.writeFileSync(path.join(dir, 'private/hook.url'), `${wh.url}/api/webhooks/1234567890/${TOKEN}\n`);
  t.after(async () => { await be.close(); await wh.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  const ctx = { dir, state, be, wh, results, statePath: path.join(dir, 'ops/state/team-report.json'), nextId: 1 };
  ctx.env = (extra = {}) => ({
    PATH: process.env.PATH, HOME: dir, RUNTIME: dir, HOOK_FILE: path.join(dir, 'private/hook.url'), STATE: ctx.statePath, DM_TEAM_API: be.url, DM_TEAM_SECRET_FILE: path.join(dir, 'secret'),
    DM_TEAM_RESULTS: results, NOW_MS: String(T0 + 2 * HOUR), PYTHONUSERBASE: PY_USER, ...extra,
  });
  ctx.run = (extra = {}, args = []) => new Promise((resolve) => {
    const child = spawn('bash', [SCRIPT, ...args], { env: ctx.env(extra) });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    child.on('close', (code) => resolve({ code, out }));
  });
  return ctx;
}

/**
 * Add a release job to the fake backend (and its result files to the results folder). spec: pc, version, status (done|failed|queued|running), created (ms), steps (what the job asked for),
 * sent ([{step, ok, error?, ms?}] the PC sent), json ({<step>: object} written as <step>.json), shots (true: every standard shot at 4 resolutions and 2 UI scales), files ({name: Buffer}), error.
 */
function addJob(ctx, spec = {}) {
  const id = String(ctx.nextId++).padStart(12, '0').replace(/[^0-9a-f]/g, '0');
  const pcIndex = PCS.findIndex((p) => p.pcId === (spec.pc || PC_A));
  const dir = path.join(ctx.results, id);
  const files = [];
  const put = (name, data) => { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, name), data); files.push({ name, bytes: data.length, path: path.join(dir, name) }); };
  for (const [step, obj] of Object.entries(spec.json || {})) put(`${step}.json`, Buffer.from(JSON.stringify(obj)));
  if (spec.shots) {
    for (const [w, h] of spec.resolutions || RESOLUTIONS) for (const scaled of [false, true]) SHOTS.forEach((shot, si) => put(`${w}x${h}${scaled ? '_s1-5' : ''}_${shot}.png`, png(32, 18, colourOf(pcIndex, scaled, si))));
  }
  for (const [name, data] of Object.entries(spec.files || {})) put(name, data);
  const status = spec.status || 'done';
  const done = status === 'done' || status === 'failed';
  const job = {
    id, kind: 'release', title: `Release checks of ${spec.version || V}`, weightS: 2400, status, tries: 0, targetPc: spec.pc || PC_A,
    payload: { version: spec.version || V, rev: 'abcdef123456', files: [], steps: spec.steps || STEPS, setups: [], soak: { minutes: 30 }, args: [] },
    createdAt: iso(spec.created ?? T0), expiresAt: iso((spec.created ?? T0) + 3 * 24 * HOUR), claimedAccount: done || status === 'running' ? 1 : null, claimedPc: done || status === 'running' ? (spec.pc || PC_A) : null,
    finishedAt: done ? iso((spec.created ?? T0) + HOUR) : null, reportedAt: null, error: spec.error ?? null,
    result: done ? { steps: spec.sent || [], files: files.map((f) => ({ name: f.name, bytes: f.bytes })), log: '', timings: {} } : null, files,
  };
  ctx.state.jobs.push(job);
  return job;
}

/** The checks of a PC that passed everything, with numbers in every step's file. */
const PASSING = {
  sent: STEPS.map((step) => ({ step, ok: true })),
  json: {
    install: { step: 'install', exitCode: 0, seconds: 4.3, timedOut: false, downloadS: 12.5, bootMs: 4210, files: [{ name: 'DeathMuffin.exe', bytes: 100 }], ok: true },   // what the app writes
    'quit-loading': { step: 'quit-loading', exitCode: 0, seconds: 3.1, timedOut: false, crashReport: false, crashFiles: [], ok: true },
    stutter: { rites: [{ discipline: 3, rite: 'dirge', worst_ms: 12, compilations: 0 }, { discipline: 4, rite: 'contagion', worst_ms: 94.2, compilations: 2 }, { discipline: 1, rite: 'bone_spear', worst_ms: 71, compilations: 0 },
      { discipline: 2, rite: 'raise_thrall', worst_ms: 60.5, compilations: 1 }], p50: 6.9, p99: 14.2 },
    bench: { step: 'bench', ok: true, summary: [{ preset: 'medium', room: 'graves', size: 'full_party', length: 'full', gpu: 'GPU', avg_fps: 121.4, p99_ms: 11.2, worst_ms: 30 }, { preset: 'low', room: 'graves', size: 'full_party', length: 'full', gpu: 'GPU', avg_fps: 188.7, p99_ms: 8.1 }],
      runs: [{ preset: 'medium', metrics: { avg_fps: 121.4, p99_ms: 11.2 } }, { preset: 'low', metrics: { avg_fps: 188.7, p99_ms: 8.1 } }] },
    soak: { minutes: Array.from({ length: 30 }, (_, i) => ({ minute: i + 1, p50: 6.8 })), growth: { static_mb: 12.34, objects: 40, video_mb: -1 } },
  },
  shots: true,
};
const passing = (over = {}) => ({ ...PASSING, ...over });

const calls = (ctx, method, re) => ctx.be.calls.filter((c) => c.method === method && re.test(c.url));
const reportedIds = (ctx) => calls(ctx, 'POST', /\/reported$/).map((c) => /jobs\/([0-9a-f]{12})\//.exec(c.url)[1]);
const pngSize = (buf) => ({ w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) });

// ── nothing to do ────────────────────────────────────────────────────────────────────────────────────────────────────────

test('nothing finished: silent, exit 0, one list call with the exact filters and the runner\'s secret, nothing posted, no state written', async (t) => {
  const ctx = await setup(t);
  const r = await ctx.run();
  assert.deepStrictEqual([r.code, r.out], [0, '']);
  assert.deepStrictEqual(ctx.be.calls, [{ method: 'GET', url: '/internal/team/jobs?kind=release&status=finished&unreported=1&limit=100', secret: SECRET }]);
  assert.deepStrictEqual([ctx.wh.posts.length, fs.existsSync(ctx.statePath)], [0, false]);
});

test('a backend without the route (404) or without the table (503) is quiet; one that is down says so in one line and is tried again next run; the wrong secret is a 404 too', async (t) => {
  for (const status of [404, 503]) {
    const ctx = await setup(t, { backend: { listStatus: status } });
    assert.deepStrictEqual(await ctx.run(), { code: 0, out: '' }, String(status));
  }
  const ctx = await setup(t);
  const down = await ctx.run({ DM_TEAM_API: 'http://127.0.0.1:9' });
  assert.strictEqual(down.code, 0);
  assert.match(down.out, /^team report: could not list the finished release checks: the backend could not be reached/);
  fs.writeFileSync(path.join(ctx.dir, 'secret'), 'another-secret-0123456789-abcdef');
  assert.deepStrictEqual(await ctx.run(), { code: 0, out: '' });
  fs.rmSync(path.join(ctx.dir, 'secret'));
  const none = await ctx.run();
  assert.deepStrictEqual([none.code, /cannot read the runner's secret/.test(none.out)], [1, true]);
  const broken = await setup(t, { backend: { listStatus: 500 } });
  const e500 = await broken.run();
  assert.deepStrictEqual([e500.code, /the backend answered 500/.test(e500.out)], [1, true]);
});

// ── waiting for every PC, and the 24 hours ───────────────────────────────────────────────────────────────────────────────

test('a release is posted only when every targeted PC has finished: one PC done and another still running means no post and no mark; when the last finishes, one message holds both', async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_A }));
  const waiting = addJob(ctx, { pc: PC_H, status: 'running' });
  const r1 = await ctx.run();
  assert.deepStrictEqual([r1.code, r1.out, ctx.wh.posts.length, reportedIds(ctx).length], [0, '', 0, 0]);
  assert.ok(calls(ctx, 'GET', /status=open/).length === 1, 'the open jobs were asked for');
  waiting.status = 'done'; waiting.finishedAt = iso(T0 + HOUR); waiting.result = { steps: [], files: [], log: '' };
  const r2 = await ctx.run();
  assert.strictEqual(r2.code, 0, r2.out);
  assert.strictEqual(ctx.wh.posts.length, 1, 'one message for the release');
  assert.strictEqual(ctx.wh.posts[0].json.embeds[0].fields.length, 2);
  assert.deepStrictEqual(reportedIds(ctx).sort(), ctx.state.jobs.map((j) => j.id).sort(), 'every job of the release is marked reported');
  assert.match(r2.out, new RegExp(`^team report: posted the release checks of ${V}: 2 PCs, 6 ok, 0 failed, 6 not run, ${HAS_PIL ? 4 : 0} contact sheets; 2 jobs marked reported\\n$`));
  const r3 = await ctx.run();
  assert.deepStrictEqual([r3.code, r3.out, ctx.wh.posts.length], [0, '', 1], 'nothing is posted twice');
});

test('after 24 hours since the first was queued the release is posted with the PCs that finished, the others named as waiting; their results follow as late results, once', async (t) => {
  const ctx = await setup(t);
  const a = addJob(ctx, passing({ pc: PC_A }));
  const slow = addJob(ctx, { pc: PC_M, status: 'queued' });
  const before = await ctx.run({ NOW_MS: String(T0 + 23 * HOUR) });
  assert.deepStrictEqual([before.out, ctx.wh.posts.length], ['', 0], '23 hours: still waiting');
  const r = await ctx.run({ NOW_MS: String(T0 + 25 * HOUR) });
  assert.strictEqual(r.code, 0, r.out);
  assert.strictEqual(ctx.wh.posts.length, 1);
  const e = ctx.wh.posts[0].json.embeds[0];
  assert.match(e.description, /⏳ Still waiting after 24 hours: MUFFIN-PC \(brbmuffins\) \(queued\)\. Their results follow when they finish\./);
  assert.strictEqual(e.title, `Release checks of ${V}`);
  assert.strictEqual(e.color, 0xF1C40F, 'amber: waiting');
  assert.deepStrictEqual(reportedIds(ctx), [a.id], 'only the PC that finished is marked; the waiting job stays open');
  // the slow PC finishes later: a follow-up message for the same release, marked "late results"
  slow.status = 'done'; slow.finishedAt = iso(T0 + 30 * HOUR); slow.result = { steps: PASSING.sent, files: [], log: '' };
  const late = await ctx.run({ NOW_MS: String(T0 + 31 * HOUR) });
  assert.strictEqual(late.code, 0, late.out);
  assert.strictEqual(ctx.wh.posts.length, 2);
  assert.strictEqual(ctx.wh.posts[1].json.embeds[0].title, `Release checks of ${V} (late results)`);
  assert.deepStrictEqual(reportedIds(ctx), [a.id, slow.id]);
  assert.deepStrictEqual((await ctx.run({ NOW_MS: String(T0 + 32 * HOUR) })).out, '');
});

test('when the open jobs cannot be listed, a release waits for the 24 hours and says in the message that it may be incomplete', async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_A }));
  ctx.be.calls.length = 0;
  const orig = ctx.state.jobs;
  // the open list fails: the fake answers 400 for status=open
  const blocking = http.createServer((req, res) => res.end());
  blocking.close();
  const failingOpen = await (async () => {   // wrap: a second fake backend that refuses status=open and forwards the rest
    const srv = http.createServer((req, res) => {
      if (req.url.includes('status=open')) { res.writeHead(400, { 'content-type': 'application/json' }); return res.end(JSON.stringify({ success: false, error: 'nope' })); }
      const fwd = http.request(ctx.be.url + req.url, { method: req.method, headers: req.headers }, (up) => { res.writeHead(up.statusCode, up.headers); up.pipe(res); });
      req.pipe(fwd);
    });
    await new Promise((r) => srv.listen(0, '127.0.0.1', r));
    return srv;
  })();
  t.after(() => failingOpen.close());
  const api = `http://127.0.0.1:${failingOpen.address().port}`;
  const quiet = await ctx.run({ DM_TEAM_API: api });
  assert.match(quiet.out, /could not list the release checks still open \(the backend answered 400\): reports wait for the 24 hours/);
  assert.strictEqual(ctx.wh.posts.length, 0);
  const late = await ctx.run({ DM_TEAM_API: api, NOW_MS: String(T0 + 25 * HOUR) });
  assert.strictEqual(late.code, 0, late.out);
  assert.match(ctx.wh.posts[0].json.embeds[0].description, /The jobs still open could not be listed, so this may not be every PC\./);
  assert.strictEqual(orig.length, 1);
});

// ── the message ──────────────────────────────────────────────────────────────────────────────────────────────────────────

test('the message: a field per PC with its graphics card, the cards sorted, a line per step with ✓/✗ and the numbers, the counts in the description, the colour, no mentions', async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_H }));
  addJob(ctx, passing({
    pc: PC_A,
    sent: PASSING.sent.map((s) => (s.step === 'install' ? { step: 'install', ok: false, error: 'No first screen within 60 s' } : s.step === 'stutter' ? { step: 'stutter', ok: false, error: 'Frame over 200 ms' } : s)),
    json: { ...PASSING.json, install: { ok: false, error: 'ignored: the PC\'s own step line wins' } },
  }));
  const r = await ctx.run();
  assert.strictEqual(r.code, 0, r.out);
  const post = ctx.wh.posts[0];
  assert.match(post.url, new RegExp(`^/api/webhooks/1234567890/${TOKEN}$`), 'posted to the webhook file\'s address');
  assert.strictEqual(post.userAgent, 'death-muffin-team-report', 'Discord refuses urllib\'s own agent');
  const { json } = post;
  assert.deepStrictEqual(json.allowed_mentions, { parse: [] });
  assert.strictEqual(json.username, 'Death Muffin Release Checks');
  const e = json.embeds[0];
  assert.strictEqual(e.title, `Release checks of ${V}`);
  assert.deepStrictEqual(e.footer, { text: 'rev abcdef123456' });
  assert.strictEqual(e.color, 0xE74C3C);
  assert.strictEqual(e.description, '**2 of 12 checks failed** on 1 of 2 team PCs.' + (HAS_PIL ? '\nContact sheets of the screens (1920x1080, 2560x1440, 3440x1440, 3840x2160) are attached.' : SHEETS_NOTE));
  assert.deepStrictEqual(e.fields.map((f) => f.name), ['ALIENWARE (warbogar) · NVIDIA GeForce GTX 970', 'HELIX-DESKTOP (helix) · NVIDIA GeForce RTX 4080'], 'the cards in order');
  assert.strictEqual(e.fields[1].value, [
    '✓ install: first screen after 4,210 ms',
    '✓ quit while loading: exits cleanly in 3.1 s',
    '✓ screens: 48 pictures at 4 resolutions',
    '✓ stutter: worst contagion (Rotweaver) 94.2 ms, bone spear (Ossuary) 71 ms, raise thrall (Gravecaller) 60.5 ms; 3 pipeline compiles; p50 6.9 / p99 14.2 ms',
    '✓ bench: Low 189 fps (p99 8.1 ms) · Medium 121 fps (p99 11.2 ms)',
    '✓ soak: 30 min, growth (last 5 min vs first 5): static mb +12.34, objects +40, video mb -1',
  ].join('\n'));
  assert.strictEqual(e.fields[0].value.split('\n')[0], '✗ install: No first screen within 60 s');
  assert.strictEqual(e.fields[0].value.split('\n')[3].slice(0, 22), '✗ stutter: Frame over ');
  assert.ok(e.fields.every((f) => f.value.length <= 1024 && f.name.length <= 256 && f.inline === false));
  assert.ok(!r.out.includes(TOKEN) && !r.out.includes(ctx.wh.url), 'the webhook address is never printed');
});

test('a PC\'s name and graphics card cannot mention anyone or start formatting; control characters go; a PC the backend does not know is named by its id', async (t) => {
  const ctx = await setup(t, { backend: { pcs: [{ accountId: 1, username: 'x', pcId: PC_A, name: '@everyone **bold** `code`\u0007', gpu: '[evil](http://example.invalid) _x_' }] } });
  addJob(ctx, passing({ pc: PC_A }));
  addJob(ctx, passing({ pc: PC_H }));
  const r = await ctx.run();
  assert.strictEqual(r.code, 0, r.out);
  const names = ctx.wh.posts[0].json.embeds[0].fields.map((f) => f.name);
  assert.ok(names.includes('\\@everyone \\*\\*bold\\*\\* \\`code\\` (x) · [evil](http://example.invalid) \\_x\\_'.replace('[evil]', '[evil]')), names.join('|'));
  assert.ok(names.includes(`${PC_H} · unknown graphics card`), names.join('|'));
  assert.deepStrictEqual(ctx.wh.posts[0].json.allowed_mentions, { parse: [] });
});

test('the shapes the team app writes read right: bootMs, seconds, the bench summary (or only the runs), the screens note and the soak\'s PC notes', async (t) => {
  const ctx = await setup(t);
  const bench = (rows) => ({ step: 'bench', ok: true, ...rows });
  addJob(ctx, passing({
    pc: PC_A,
    json: { ...PASSING.json, bench: bench({ summary: [{ preset: 'ultra', avg_fps: 99.95, p99_ms: 15 }, { preset: 'low', avg_fps: 240.2 }] }),   // the app drops the runs when the file would be too big
      screens: { step: 'screens', ok: true, preset: 'high', runs: [], uiScales: ['default'], note: 'default UI scale only: the job names no other UI scale' },
      'soak-notes': { step: 'soak', minutes: 30, notes: ['minute 3: the keyboard or mouse was used', 'minute 9: other programs used the CPU'] } },
  }));
  addJob(ctx, passing({ pc: PC_H, json: { ...PASSING.json, bench: bench({ runs: [{ preset: 'high', metrics: { avg_fps: 144.6, p99_ms: 9.5 } }] }) } }));
  const r = await ctx.run();
  assert.strictEqual(r.code, 0, r.out);
  const [a, h] = ctx.wh.posts[0].json.embeds[0].fields.map((f) => f.value.split('\n'));
  assert.strictEqual(a[2], '✓ screens: 48 pictures at 4 resolutions; default UI scale only: the job names no other UI scale');
  assert.strictEqual(a[4], '✓ bench: Low 240 fps · Ultra 100 fps (p99 15 ms)');
  assert.ok(a[5].endsWith('; PC notes (2): minute 3: the keyboard or mouse was used'), a[5]);
  assert.strictEqual(h[4], '✓ bench: High 145 fps (p99 9.5 ms)');
});

test('a failed job shows why, and what it did before it stopped; steps that were never reached say so; a release with no debug build says the three steps were not queued', async (t) => {
  const ctx = await setup(t);
  addJob(ctx, {
    pc: PC_A, status: 'failed', error: 'The team PC went quiet', steps: ['install', 'quit-loading', 'bench'], sent: [{ step: 'install', ok: true, ms: 4000 }],
    json: { install: { ok: true, ms: 4000 } },
  });
  const r = await ctx.run();
  assert.strictEqual(r.code, 0, r.out);
  const e = ctx.wh.posts[0].json.embeds[0];
  assert.strictEqual(e.fields[0].value, ['✗ the job failed: The team PC went quiet', '✓ install: first screen after 4,000 ms', '– quit while loading: not reached', '– bench: not reached'].join('\n'));
  assert.strictEqual(e.description, '**1 of 2 checks failed** on 1 of 1 team PC.\n2 steps did not run or sent no result.\nNo debug build was made for this release, so screens, stutter, soak were not queued.');
  assert.strictEqual(ctx.wh.posts[0].files.length, 0, 'no screens, no sheets');
  assert.strictEqual(ctx.wh.posts[0].type, 'application/json', 'no attachments: a plain JSON post');
  assert.deepStrictEqual(reportedIds(ctx), [ctx.state.jobs[0].id], 'a failed job is reported too');
});

test('unreadable results do not stop the report: bad JSON, a file outside the job\'s folder, a link, an oversized file and odd shapes all read as no result or a plain line', async (t) => {
  const ctx = await setup(t);
  const outside = path.join(ctx.dir, 'outside.json');
  fs.writeFileSync(outside, JSON.stringify({ ok: true, ms: 1 }));
  const job = addJob(ctx, {
    pc: PC_A, sent: STEPS.map((step) => ({ step, ok: true })), files: { 'stutter.json': Buffer.from('{not json'), 'bench.json': Buffer.from(JSON.stringify({ runs: 'many' })), 'soak.json': Buffer.from(JSON.stringify([1, 2])) },
  });
  const dir = path.join(ctx.results, job.id);
  job.files.push({ name: 'install.json', bytes: 12, path: outside });                                   // listed, but not inside the job's folder
  fs.symlinkSync(outside, path.join(dir, 'quit-loading.json'));                                          // a link in the folder
  job.files.push({ name: 'quit-loading.json', bytes: 12, path: path.join(dir, 'quit-loading.json') });
  fs.writeFileSync(path.join(dir, 'screens.json'), Buffer.alloc(1024 * 1024 + 10, 32));                  // over the 1 MB cap
  job.files.push({ name: 'screens.json', bytes: 1024 * 1024 + 10, path: path.join(dir, 'screens.json') });
  job.payload.steps = STEPS;
  const r = await ctx.run();
  assert.strictEqual(r.code, 0, r.out);
  const lines = ctx.wh.posts[0].json.embeds[0].fields[0].value.split('\n');
  assert.deepStrictEqual(lines, ['✓ install: booted', '✓ quit while loading: exits cleanly', '✓ screens: ok', '✓ stutter: ok', '✓ bench: ok', '✓ soak: 30 min']);
});

test('two releases in one run are two messages, the older first, each with its own jobs', async (t) => {
  const ctx = await setup(t);
  const newer = addJob(ctx, passing({ pc: PC_A, version: '20261020.090000-bbbbbbb', created: T0 + 20 * HOUR }));
  const older = addJob(ctx, passing({ pc: PC_A, version: V }));
  const r = await ctx.run({ NOW_MS: String(T0 + 22 * HOUR) });
  assert.strictEqual(r.code, 0, r.out);
  assert.deepStrictEqual(ctx.wh.posts.map((p) => p.json.embeds[0].title), [`Release checks of ${V}`, 'Release checks of 20261020.090000-bbbbbbb']);
  assert.deepStrictEqual(reportedIds(ctx), [older.id, newer.id]);
});

// ── the contact sheets ───────────────────────────────────────────────────────────────────────────────────────────────────

test('a contact sheet per resolution, at most 4, under the size cap: right size, right cell for each PC, UI scale and shot (rows by card, columns by shot)', { skip: !HAS_PIL }, async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_H }));
  addJob(ctx, passing({ pc: PC_A }));
  const r = await ctx.run();
  assert.strictEqual(r.code, 0, r.out);
  const post = ctx.wh.posts[0];
  assert.match(post.type, /^multipart\/form-data; boundary=/);
  assert.deepStrictEqual(post.files.map((f) => f.filename), ['screens-1920x1080.png', 'screens-3440x1440.png', 'screens-2560x1440.png', 'screens-3840x2160.png'].sort((a, b) => {
    const px = (n) => { const [w, h] = /(\d+)x(\d+)/.exec(n).slice(1).map(Number); return w * h; };
    return px(a) - px(b);
  }), 'ordered by size');
  assert.deepStrictEqual(post.json.attachments, post.files.map((f, i) => ({ id: i, filename: f.filename })));
  assert.ok(post.files.every((f) => f.type === 'image/png' && f.data.length < 5 * 1024 * 1024 && f.data.length < 8 * 1024 * 1024));
  // the layout (reporter constants: 360 px cells, 8 px padding, a 260 px label column, a 56 px head): 2 PCs x 2 UI scales = 4 rows, 6 shot columns
  const extract = (file) => {
    const script = 'import sys; from PIL import Image; im = Image.open(sys.argv[1]).convert("RGB"); pts = [tuple(map(int, a.split(","))) for a in sys.argv[2:]]; print(";".join("%d,%d,%d" % im.getpixel(p) for p in pts))';
    return script;
  };
  const sheet = post.files.find((f) => f.filename === 'screens-1920x1080.png');
  const tmp = path.join(ctx.dir, 'sheet.png');
  fs.writeFileSync(tmp, sheet.data);
  const th = Math.round(360 * 1080 / 1920);
  const { w, h } = pngSize(sheet.data);
  assert.deepStrictEqual([w, h], [260 + 6 * (360 + 8) + 8, 56 + 4 * (th + 8) + 8]);
  // rows: cards sorted (GTX 970 = PC_A index 0 before RTX 4080 = PC_H index 1), each at the default scale then 1.5; columns in the shots' order
  const wantRows = [[0, false], [0, true], [1, false], [1, true]];
  const points = []; const wanted = [];
  wantRows.forEach(([pcIndex, scaled], ri) => SHOTS.forEach((shot, ci) => {
    points.push(`${260 + ci * (360 + 8) + 8 + 180},${56 + ri * (th + 8) + 100}`);
    wanted.push(colourOf(pcIndex, scaled, ci).join(','));
  }));
  const got = execFileSync('python3', ['-c', extract(), tmp, ...points], { encoding: 'utf8' }).trim().split(';');
  assert.deepStrictEqual(got, wanted, 'every cell shows its own PC\'s picture');
  assert.ok(!r.out.includes(TOKEN));
});

test('more than four resolutions: only the four with most pictures get a sheet; a job with no pictures needs none; a missing cell is blank, not a crash', { skip: !HAS_PIL }, async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_A, files: { '1280x720_bag.png': png(32, 18, [200, 0, 0]) } }));   // the standard four, and one picture at a fifth resolution
  addJob(ctx, { pc: PC_H, sent: [{ step: 'screens', ok: true }], steps: ['screens'], files: { '1280x720_hud.png': png(32, 18, [0, 200, 0]) } });
  const r = await ctx.run();
  assert.strictEqual(r.code, 0, r.out);
  const names = ctx.wh.posts[0].files.map((f) => f.filename);
  assert.strictEqual(names.length, 4);
  assert.ok(!names.includes('screens-1280x720.png'), 'the resolution with fewest pictures is left out');
  const ctx2 = await setup(t);
  addJob(ctx2, { pc: PC_A, sent: [{ step: 'screens', ok: true }], steps: ['screens'], files: { '1920x1080_bag.png': png(32, 18, [1, 2, 3]) } });
  addJob(ctx2, { pc: PC_H, sent: [{ step: 'screens', ok: true }], steps: ['screens'], files: { '1920x1080_hud.png': png(32, 18, [3, 2, 1]), 'junk.png': png(32, 18, [9, 9, 9]), '1920x1080_.png': Buffer.from('not a png') } });
  const r2 = await ctx2.run();
  assert.strictEqual(r2.code, 0, r2.out);
  assert.deepStrictEqual(ctx2.wh.posts[0].files.map((f) => f.filename), ['screens-1920x1080.png']);
});

test('a sheet over the size cap is saved smaller as a JPEG, and one that cannot be made small enough is left out with a note; the message still goes', { skip: !HAS_PIL }, async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_A, resolutions: [[1920, 1080]] }));
  const roomy = await ctx.run();
  assert.strictEqual(roomy.code, 0, roomy.out);
  const full = ctx.wh.posts[0].files[0];
  assert.strictEqual(full.filename, 'screens-1920x1080.png');
  ctx.state.jobs[0].reportedAt = null;
  fs.rmSync(path.dirname(ctx.statePath), { recursive: true });
  const small = await ctx.run({ SHEET_MAX_BYTES: String(full.data.length - 1000) });   // a sheet a little too large: smaller cells or a JPEG
  assert.strictEqual(small.code, 0, small.out);
  const f = ctx.wh.posts[1].files[0];
  assert.ok(f && f.data.length <= full.data.length - 1000, f && String(f.data.length));
  assert.ok(/^screens-1920x1080\.(png|jpg)$/.test(f.filename));
  assert.strictEqual(f.type, f.filename.endsWith('.jpg') ? 'image/jpeg' : 'image/png');
  const ctx2 = await setup(t);
  addJob(ctx2, passing({ pc: PC_A, resolutions: [[1920, 1080]] }));
  const tiny = await ctx2.run({ SHEET_MAX_BYTES: '10' });
  assert.strictEqual(tiny.code, 0, tiny.out);
  assert.strictEqual(ctx2.wh.posts[0].files.length, 0);
  assert.match(ctx2.wh.posts[0].json.embeds[0].description, /The 1920x1080 sheet was too large to attach\./);
});

test('without Pillow the message still goes, with a note, and no sheets', async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_A, resolutions: [[1920, 1080]] }));
  const fake = path.join(ctx.dir, 'nopil');
  fs.mkdirSync(path.join(fake, 'PIL'), { recursive: true });
  fs.writeFileSync(path.join(fake, 'PIL/__init__.py'), 'raise ImportError("no Pillow here")\n');
  const r = await ctx.run({ PYTHONPATH: fake });
  assert.strictEqual(r.code, 0, r.out);
  assert.strictEqual(ctx.wh.posts[0].files.length, 0);
  assert.match(ctx.wh.posts[0].json.embeds[0].description, /Pillow is not installed: no contact sheets\./);
});

// ── marking, the state and the webhook ───────────────────────────────────────────────────────────────────────────────────

test('every job of a posted release is marked reported through POST /internal/team/jobs/<id>/reported with the secret; a failed mark is retried without posting again', async (t) => {
  const ctx = await setup(t, { backend: { reportedStatus: 500 } });
  const a = addJob(ctx, passing({ pc: PC_A }));
  const h = addJob(ctx, passing({ pc: PC_H }));
  const r1 = await ctx.run();
  assert.strictEqual(r1.code, 1);
  assert.strictEqual(ctx.wh.posts.length, 1);
  assert.match(r1.out, /could not mark job 0+1 reported: the backend answered 500/);
  assert.ok(calls(ctx, 'POST', /\/reported$/).every((c) => c.secret === SECRET));
  assert.deepStrictEqual(Object.keys(JSON.parse(fs.readFileSync(ctx.statePath, 'utf8')).jobs).sort(), [a.id, h.id].sort(), 'the state remembers what was posted');
  ctx.state.reportedStatus = 0;
  const r2 = await ctx.run();
  assert.deepStrictEqual([r2.code, ctx.wh.posts.length], [0, 1], 'marked now, not posted again');
  assert.ok(a.reportedAt && h.reportedAt);
  assert.deepStrictEqual((await ctx.run()).out, '');
});

test('a failing webhook marks nothing and writes no state; the next run posts it', async (t) => {
  const ctx = await setup(t, { hook: { status: 500 } });
  addJob(ctx, passing({ pc: PC_A }));
  const r1 = await ctx.run();
  assert.strictEqual(r1.code, 1);
  assert.match(r1.out, new RegExp(`the #build-alerts post for ${V} failed \\(HTTP 500\\); trying again next run`));
  assert.deepStrictEqual([reportedIds(ctx).length, fs.existsSync(ctx.statePath)], [0, false]);
  assert.ok(!r1.out.includes(TOKEN) && !r1.out.includes(ctx.wh.url));
  ctx.wh.state.status = 204;
  const r2 = await ctx.run();
  assert.strictEqual(r2.code, 0, r2.out);
  assert.strictEqual(ctx.wh.posts.length, 1);
  assert.strictEqual(reportedIds(ctx).length, 1);
});

test('the webhook file is never printed: not when the post works, fails, the address is not an address, the file is missing or the webhook is not there', async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_A }));
  const hookFile = path.join(ctx.dir, 'private/hook.url');
  fs.writeFileSync(hookFile, `not a web address ${TOKEN}\n`);
  const bad = await ctx.run();
  assert.strictEqual(bad.code, 1);
  assert.match(bad.out, /the webhook address is not a valid web address/);
  fs.writeFileSync(hookFile, `http://127.0.0.1:9/api/webhooks/1/${TOKEN}\n`);   // nothing listens there
  const down = await ctx.run();
  assert.strictEqual(down.code, 1);
  assert.match(down.out, /no answer \(/);
  fs.rmSync(hookFile);
  const none = await ctx.run();
  assert.deepStrictEqual([none.code, none.out.trim()], [1, 'team report: no webhook file: nothing was posted']);
  for (const out of [bad.out, down.out, none.out]) assert.ok(!out.includes(TOKEN) && !out.includes('127.0.0.1:9') && !out.includes('not a web address'), out);
  assert.deepStrictEqual([ctx.wh.posts.length, reportedIds(ctx).length], [0, 0]);
});

test('--dry-run prints the message and changes nothing: no post, no mark, no state', async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_A }));
  const r = await ctx.run({}, ['--dry-run']);
  assert.strictEqual(r.code, 0, r.out);
  assert.match(r.out, new RegExp(`== Release checks of ${V}\\n\\*\\*All 6 checks passed\\*\\* on 1 team PC\\.`));
  assert.match(r.out, /-- ALIENWARE \(warbogar\) · NVIDIA GeForce GTX 970\n✓ install: first screen after 4,210 ms/);
  if (HAS_PIL) assert.match(r.out, /\[attached screens-1920x1080\.png, \d+ bytes\]/);
  assert.deepStrictEqual([ctx.wh.posts.length, reportedIds(ctx).length, fs.existsSync(ctx.statePath), fs.existsSync(path.dirname(ctx.statePath))], [0, 0, false, false]);
  assert.ok(!r.out.includes(TOKEN));
});

test('a second run while one is posting does nothing (the state lock)', async (t) => {
  const ctx = await setup(t);
  addJob(ctx, passing({ pc: PC_A }));
  fs.mkdirSync(path.dirname(ctx.statePath), { recursive: true });
  const holder = spawn('flock', ['-x', ctx.statePath + '.lock', 'sleep', '5']);
  t.after(() => holder.kill());
  await new Promise((r) => setTimeout(r, 400));
  const r = await ctx.run();
  assert.deepStrictEqual([r.code, r.out, ctx.wh.posts.length], [0, '', 0]);
});

test('the state file keeps only the newest jobs and releases, and survives garbage', async (t) => {
  const ctx = await setup(t);
  fs.mkdirSync(path.dirname(ctx.statePath), { recursive: true });
  fs.writeFileSync(ctx.statePath, '{broken');
  addJob(ctx, passing({ pc: PC_A }));
  const r = await ctx.run();
  assert.strictEqual(r.code, 0, r.out);
  const state = JSON.parse(fs.readFileSync(ctx.statePath, 'utf8'));
  assert.deepStrictEqual([Object.keys(state.jobs).length, Object.keys(state.versions)], [1, [V]]);
  assert.ok(!fs.existsSync(ctx.statePath + '.tmp'));
});

test('the script is valid bash and python, and names the exact routes the backend has', () => {
  execFileSync('bash', ['-n', SCRIPT]);
  const text = fs.readFileSync(SCRIPT, 'utf8');
  for (const needle of ['kind=release&status=finished&unreported=1', 'kind=release&status=open', '/internal/team/jobs/%s/reported', '/internal/team/pcs?days=60', 'discord-build-alerts-webhook.url']) assert.ok(text.includes(needle), needle);
});
