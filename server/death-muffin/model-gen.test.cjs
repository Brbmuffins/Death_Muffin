// Run: node --test server/death-muffin/model-gen.test.cjs
// model-gen.sh (3D models from a picture on a team PC) against a fake backend on a loopback port and temp folders: no real team-files, secret, backend or PC is touched.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const GEN = path.join(__dirname, 'model-gen.sh');
const SECRET = 'runner-secret-0123456789-abcdef';
const MODEL_DIR = /^model-[0-9a-f]{24}$/;
const PC_H = 'pc-helix-0002';
const PC_W = 'pc-war-0003';
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const pcRow = (pcId, state, over = {}) => ({ accountId: 1, username: pcId === PC_H ? 'Helix' : 'warbogar', pcId, name: pcId === PC_H ? 'HELIX-PC' : 'WAR-PC', version: '0.5.0', gpu: `GPU of ${pcId}`, state, ...over });
const ABLE = { models: true, vramMb: 12282 };
const SMALL = { models: false, vramMb: 4096 };
const PNG_1x1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');
const GLB = (label) => Buffer.concat([Buffer.from('glTF'), Buffer.from(` model ${label}`)]);

/** A temp world: team-files, results, the out folder, the secret and two pictures. */
function world() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'model-gen-test-'));
  const dirs = {};
  for (const k of ['team-files', 'results', 'pictures']) { dirs[k] = path.join(root, k); fs.mkdirSync(dirs[k]); }
  const secretFile = path.join(root, 'secret');
  fs.writeFileSync(secretFile, `${SECRET}\n`);
  const hound = path.join(dirs.pictures, 'Hound Concept.png');
  const brazier = path.join(dirs.pictures, 'brazier.JPEG');
  fs.writeFileSync(hound, PNG_1x1);
  fs.writeFileSync(brazier, Buffer.from('not really a jpeg, but a picture file'));
  return { root, teamFiles: dirs['team-files'], results: dirs.results, out: path.join(root, 'out'), secretFile, hound, brazier,
    modelDirs: () => fs.readdirSync(dirs['team-files']).filter((n) => MODEL_DIR.test(n)),
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

/**
 * A fake backend: the /internal/team routes model-gen.sh calls, with the secret check. Each created job follows `script` (a status per read, the last repeating); a
 * finished job carries the models `made(runs)` names (default: one per run) as files in <results>/<id>/ and the PC's log.
 */
function fakeBackend(w, { pcs = [pcRow(PC_H, ABLE)], script = ['queued', 'running', 'done'], made = (runs) => runs.map((r) => r.label), error = '' } = {}) {
  const calls = [];
  const jobs = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString() || 'null') : undefined;
      calls.push({ method: req.method, url: req.url, body });
      const send = (status, obj) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
      if (req.headers['x-team-secret'] !== SECRET) return send(404, { success: false, error: 'Not found' });
      if (req.method === 'GET' && req.url === '/internal/team/pcs?days=14') return send(200, { success: true, data: { pcs } });
      if (req.method === 'POST' && req.url === '/internal/team/jobs') {
        const id = `job${String(jobs.length + 1).padStart(9, '0')}`;
        // What the PC would download: the files as they sit in the job's folder while it runs.
        const seen = Object.fromEntries((body.payload.files || []).map((f) => {
          const local = path.join(w.teamFiles, f.url.split('/').slice(-2).join('/'));
          return [f.name, fs.existsSync(local) ? fs.readFileSync(local) : null];
        }));
        jobs.push({ id, body, reads: 0, seen });
        return send(200, { success: true, data: { id } });
      }
      const m = /^\/internal\/team\/jobs\/(job\d{9})(\/(cancel|reported))?$/.exec(req.url);
      const j = m && jobs.find((x) => x.id === m[1]);
      if (j && req.method === 'POST') return send(200, { success: true, data: {} });
      if (j && req.method === 'GET') {
        const status = script[Math.min(j.reads, script.length - 1)];
        j.reads += 1;
        const row = { id: j.id, kind: 'model', status, payload: j.body.payload, error: status === 'done' ? null : error || null, result: null, files: [] };
        if (status === 'done' || status === 'failed') {
          const folder = path.join(w.results, j.id);
          fs.mkdirSync(folder, { recursive: true });
          const names = status === 'done' ? made(j.body.payload.runs).map((l) => `${l}.glb`) : [];
          for (const n of names) fs.writeFileSync(path.join(folder, n), GLB(n));
          row.result = { log: `model job ${j.id}: ${j.body.payload.runs.length} run(s)\n` };
          row.files = names.map((name) => ({ name, path: path.join(folder, name) }));
        }
        return send(200, { success: true, data: row });
      }
      return send(404, { success: false, error: 'Not found' });
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    calls, jobs, url: `http://127.0.0.1:${server.address().port}`,
    posted: (id, what) => calls.some((c) => c.method === 'POST' && c.url === `/internal/team/jobs/${id}/${what}`),
    created: () => calls.filter((c) => c.method === 'POST' && c.url === '/internal/team/jobs').length,
    close: () => new Promise((r) => server.close(r)),
  })));
}

const gen = (w, backend, args) => new Promise((resolve) => {
  const env = { PATH: process.env.PATH, HOME: process.env.HOME, DM_TEAM_ROOT: w.teamFiles, DM_TEAM_URL: 'https://example.invalid/team-files', DM_TEAM_API: backend.url,
    DM_TEAM_SECRET_FILE: w.secretFile, DM_TEAM_POLL_S: '0.02' };
  const child = spawn('bash', [GEN, ...args], { env });
  let out = '';
  let err = '';
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { err += d; });
  child.on('close', (code) => resolve({ code, out, err, all: out + err }));
});

async function withWorld(opts, fn) {
  if (typeof opts === 'function') { fn = opts; opts = {}; }
  const w = world();
  const backend = await fakeBackend(w, opts);
  try { await fn(w, backend); } finally { await backend.close(); w.cleanup(); }
}

test('one picture: one model job for any PC that runs them, the picture served from its own folder, the model and the log copied, the folder removed', async () => {
  await withWorld(async (w, backend) => {
    const r = await gen(w, backend, [w.out, w.hound]);
    assert.strictEqual(r.code, 0, r.all);
    assert.strictEqual(backend.jobs.length, 1);
    const { id, body, seen } = backend.jobs[0];
    assert.strictEqual(body.kind, 'model');
    assert.strictEqual(body.targetPc, undefined, 'no --pc: any PC that runs model jobs');
    assert.match(body.title, /^3D models from a picture: 1 run, about \d+ minutes$/);
    assert.ok(body.weightS > 0 && body.ttlS >= 3600, JSON.stringify(body));
    const [file] = body.payload.files;
    assert.strictEqual(file.name, 'hound-concept.png', 'the file name made safe');
    assert.match(file.url, /^https:\/\/example\.invalid\/team-files\/model-[0-9a-f]{24}\/hound-concept\.png$/);
    assert.strictEqual(file.sha256, sha256(PNG_1x1));
    assert.strictEqual(file.bytes, PNG_1x1.length);
    assert.deepStrictEqual(seen[file.name], PNG_1x1, 'the picture is in its folder while the job runs');
    assert.deepStrictEqual(body.payload.runs, [{ label: 'hound-concept-pixal3d', image: 'hound-concept.png', model: 'pixal3d', faces: 5000, texture: 1024, seed: 0 }]);
    assert.deepStrictEqual(fs.readFileSync(path.join(w.out, 'hound-concept-pixal3d.glb')), GLB('hound-concept-pixal3d.glb'));
    assert.match(fs.readFileSync(path.join(w.out, `${id}.log`), 'utf8'), /1 run\(s\)/);
    assert.ok(backend.posted(id, 'reported'));
    assert.ok(!backend.posted(id, 'cancel'));
    assert.deepStrictEqual(w.modelDirs(), [], 'the pictures\' folder is removed');
  });
});

test('both models and two seeds make one run each, labelled by picture, model and seed; --pc names the PC by its user', async () => {
  await withWorld({ pcs: [pcRow(PC_W, SMALL), pcRow(PC_H, ABLE)] }, async (w, backend) => {
    const r = await gen(w, backend, ['--pc', 'helix', '--model', 'both', '--seeds', '0,7', '--faces', '8000', '--texture', '2048', w.out, w.hound]);
    assert.strictEqual(r.code, 0, r.all);
    const { body } = backend.jobs[0];
    assert.strictEqual(body.targetPc, PC_H);
    assert.deepStrictEqual(body.payload.runs.map((x) => [x.label, x.model, x.seed, x.faces, x.texture]), [
      ['hound-concept-pixal3d-s0', 'pixal3d', 0, 8000, 2048], ['hound-concept-pixal3d-s7', 'pixal3d', 7, 8000, 2048],
      ['hound-concep-trellis2-s0', 'trellis2', 0, 8000, 2048], ['hound-concep-trellis2-s7', 'trellis2', 7, 8000, 2048],
    ], 'the picture\'s part is cut so a label fits the app\'s 24 characters');
    assert.match(body.title, /: 4 runs, about/);
    for (const x of body.payload.runs) assert.ok(fs.existsSync(path.join(w.out, `${x.label}.glb`)), x.label);
  });
});

test('a runs file names the pictures by their given names; a .jpeg is sent as .jpg', async () => {
  await withWorld(async (w, backend) => {
    const runsFile = path.join(w.root, 'runs.json');
    fs.writeFileSync(runsFile, JSON.stringify([
      { label: 'brazier-low', image: 'brazier.JPEG', model: 'trellis2', faces: 1500, texture: 512 },
      { label: 'hound-hi', image: 'Hound Concept.png', model: 'pixal3d', faces: 20000, texture: 1024, seed: 3 },
    ]));
    const r = await gen(w, backend, ['--runs', runsFile, w.out, w.hound, w.brazier]);
    assert.strictEqual(r.code, 0, r.all);
    const { body } = backend.jobs[0];
    assert.deepStrictEqual(body.payload.files.map((f) => f.name).sort(), ['brazier.jpg', 'hound-concept.png']);
    assert.deepStrictEqual(body.payload.runs, [
      { label: 'brazier-low', image: 'brazier.jpg', model: 'trellis2', faces: 1500, texture: 512, seed: 0 },
      { label: 'hound-hi', image: 'hound-concept.png', model: 'pixal3d', faces: 20000, texture: 1024, seed: 3 },
    ]);
  });
});

test('some runs without a model still exit 0 and say how many came back', async () => {
  await withWorld({ made: (runs) => [runs[0].label] }, async (w, backend) => {
    const r = await gen(w, backend, ['--model', 'both', w.out, w.hound]);
    assert.strictEqual(r.code, 0, r.all);
    assert.match(r.out, /1 of 2 runs made a model/);
    assert.deepStrictEqual(fs.readdirSync(w.out).filter((n) => n.endsWith('.glb')), ['hound-concept-pixal3d.glb']);
  });
});

test('a failed job or one that made nothing exits 1, still writes the log and marks it reported', async () => {
  await withWorld({ script: ['running', 'failed'], error: 'ComfyUI is not running and could not be started.' }, async (w, backend) => {
    const r = await gen(w, backend, [w.out, w.hound]);
    assert.strictEqual(r.code, 1, r.all);
    assert.match(r.err, /the job failed \(ComfyUI is not running and could not be started\.\)/);
    const { id } = backend.jobs[0];
    assert.ok(fs.existsSync(path.join(w.out, `${id}.log`)));
    assert.ok(backend.posted(id, 'reported'));
    assert.deepStrictEqual(w.modelDirs(), []);
  });
  await withWorld({ made: () => [] }, async (w, backend) => {
    const r = await gen(w, backend, [w.out, w.hound]);
    assert.strictEqual(r.code, 1, r.all);
    assert.match(r.err, /finished without models/);
  });
});

test('a job not finished in time is cancelled and exits 1', async () => {
  await withWorld({ script: ['queued'] }, async (w, backend) => {
    const r = await gen(w, backend, ['--wait', '0.005', w.out, w.hound]);
    assert.strictEqual(r.code, 1, r.all);
    assert.match(r.err, /did not finish in time/);
    assert.ok(backend.posted(backend.jobs[0].id, 'cancel'));
    assert.deepStrictEqual(w.modelDirs(), []);
  });
});

test('no PC that runs model jobs, or a named PC that does not: exit 1 with the PCs seen, nothing queued', async () => {
  await withWorld({ pcs: [pcRow(PC_W, SMALL)] }, async (w, backend) => {
    const r = await gen(w, backend, [w.out, w.hound]);
    assert.strictEqual(r.code, 1, r.all);
    assert.match(r.err, /no team PC runs model jobs.*12 GB.*WAR-PC \(warbogar, GPU of pc-war-0003, 4\.0 GB, app 0\.5\.0\)/);
    const named = await gen(w, backend, ['--pc', 'WAR-PC', w.out, w.hound]);
    assert.strictEqual(named.code, 1, named.all);
    assert.match(named.err, /WAR-PC runs no model jobs/);
    const unknown = await gen(w, backend, ['--pc', 'nobody', w.out, w.hound]);
    assert.strictEqual(unknown.code, 1, unknown.all);
    assert.match(unknown.err, /no team PC called nobody/);
    assert.strictEqual(backend.created(), 0);
    assert.deepStrictEqual(w.modelDirs(), []);
  });
  await withWorld({ pcs: [pcRow(PC_H, { vramMb: 12282 })] }, async (w, backend) => {
    const r = await gen(w, backend, [w.out, w.hound]);
    assert.strictEqual(r.code, 1, 'an older app that sends no models flag runs none');
  });
  // team app 0.5.1 says why it runs none: the message carries it
  await withWorld({ pcs: [pcRow(PC_H, { models: false, modelsWhy: 'ComfyUI Desktop is not set up on this PC', vramMb: 12282 }, { version: '0.5.1' })] }, async (w, backend) => {
    const r = await gen(w, backend, ['--pc', 'helix', w.out, w.hound]);
    assert.strictEqual(r.code, 1, r.all);
    assert.match(r.err, /HELIX-PC \(Helix, GPU of pc-[^,]+, 12\.0 GB, app 0\.5\.1: ComfyUI Desktop is not set up on this PC\)/);
  });
});

test('usage and picture problems exit 2 before the backend is asked', async () => {
  await withWorld(async (w, backend) => {
    const txt = path.join(w.root, 'notes.txt');
    fs.writeFileSync(txt, 'x');
    const empty = path.join(w.root, 'empty.png');
    fs.writeFileSync(empty, '');
    const link = path.join(w.root, 'link.png');
    fs.symlinkSync(w.hound, link);
    const twin = path.join(w.root, 'hound_concept.png');
    fs.writeFileSync(twin, PNG_1x1);
    const badRuns = path.join(w.root, 'bad.json');
    const cases = [
      [[w.out, txt], /a real \.png, \.jpg or \.webp/],
      [[w.out, empty], /a real \.png/],
      [[w.out, link], /a real \.png/],
      [[w.out, path.join(w.root, 'missing.png')], /a real \.png/],
      [[w.out, w.hound, twin], /both be called hound-concept\.png/],
      [['--seeds', '0,1,2,3,4', '--model', 'both', w.out, w.hound], /1 to 8 runs \(this one would have 10\)/],
      [['--seeds', 'x', w.out, w.hound], /--seeds is a list/],
      [['--faces', '100', w.out, w.hound], /faces from 500 to 200000/],
      [['--seeds', '2000000', w.out, w.hound], /seed from 0 to 1000000/],
      [['--runs', badRuns, w.out, w.hound], /not JSON/, 'nope'],
      [['--runs', badRuns, w.out, w.hound], /names a picture that was not given/, JSON.stringify([{ label: 'a', image: 'other.png', model: 'pixal3d', faces: 5000, texture: 1024 }])],
      [['--runs', badRuns, w.out, w.hound], /label 'A b'/, JSON.stringify([{ label: 'A b', image: 'Hound Concept.png', model: 'pixal3d', faces: 5000, texture: 1024 }])],
      [['--runs', badRuns, w.out, w.hound], /each once/, JSON.stringify([1, 2].map(() => ({ label: 'a', image: 'Hound Concept.png', model: 'pixal3d', faces: 5000, texture: 1024 })))],
      [['--runs', badRuns, w.out, w.hound], /pixal3d or trellis2/, JSON.stringify([{ label: 'a', image: 'Hound Concept.png', model: 'tripo', faces: 5000, texture: 1024 }])],
      [['--runs', badRuns, w.out, w.hound], /texture is one of/, JSON.stringify([{ label: 'a', image: 'Hound Concept.png', model: 'pixal3d', faces: 5000, texture: 999 }])],
    ];
    for (const [args, want, runs] of cases) {
      if (runs !== undefined) fs.writeFileSync(badRuns, runs);
      const r = await gen(w, backend, args);
      assert.strictEqual(r.code, 2, `${args.join(' ')}: ${r.all}`);
      assert.match(r.err, want, args.join(' '));
    }
    const usage = await gen(w, backend, [w.out]);
    assert.strictEqual(usage.code, 2, 'no picture');
    assert.strictEqual(backend.calls.length, 0, 'the backend is never asked');
    assert.deepStrictEqual(w.modelDirs(), []);
  });
});
