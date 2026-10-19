// Run: node --test server/death-muffin/team-bench.test.cjs
// team-bench.sh (the team PCs' benchmark of a new release), team-files-prune.sh and the hook block of publish-godot-client.sh, against a fake backend on a
// loopback port and temp folders: no real manifest, team-files folder, secret, backend or Godot is touched.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');

const HERE = __dirname;
const BENCH = path.join(HERE, 'team-bench.sh');
const PRUNE = path.join(HERE, 'team-files-prune.sh');
const PUBLISH = path.join(HERE, 'publish-godot-client.sh');
const SECRET = 'runner-secret-0123456789-abcdef';
const DLL = 'libdmcore.windows.template_release.x86_64.dll';
const REV = 'abcdef123456';
const VERSION = '20261019.120000-abcdef1';
const HEX32 = /^[0-9a-f]{32}$/;
const BENCH_DIR = /^bench-[0-9a-f]{24}$/;   // a release's folder in team-files (a preview build's is 32 hex)
const PC_W = 'pc-war-0003';
const PC_H = 'pc-helix-0002';
const PC_M = 'pc-muffins-0001';

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const pcRow = (pcId, accountId = 1) => ({ accountId, username: `acct${accountId}`, pcId, name: 'PC', version: '0.2.0', gpu: 'GPU', mode: 'ask', state: {}, lastSeen: '2026-10-19T12:00:00.000Z' });

/** A fake backend: the runner's /internal/team routes, with the secret check, recording every call. */
function fakeBackend({ pcs = [pcRow(PC_W), pcRow(PC_H, 2)], failJobs = 0, jobStatus = 200 } = {}) {
  const calls = [];
  let n = 0;
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : undefined;
      calls.push({ method: req.method, url: req.url, secret: req.headers['x-team-secret'], body });
      const send = (status, obj) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
      if (req.headers['x-team-secret'] !== SECRET) return send(404, { success: false, error: 'Not found' });
      if (req.method === 'GET' && req.url.startsWith('/internal/team/pcs?days=')) return send(200, { success: true, data: { pcs } });
      if (req.method === 'POST' && req.url === '/internal/team/jobs') {
        n += 1;
        if (n <= failJobs || jobStatus !== 200) return send(jobStatus !== 200 ? jobStatus : 500, { success: false, code: 'server_error', error: 'The server could not finish that.' });
        return send(200, { success: true, data: { id: `job${String(n).padStart(9, '0')}` } });
      }
      return send(404, { success: false, error: 'Not found' });
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    calls, url: `http://127.0.0.1:${server.address().port}`, jobs: () => calls.filter((c) => c.method === 'POST'), close: () => new Promise((r) => server.close(r)),
  })));
}

/** The live client's folder (manifest + the version folder), a team-files folder and the runner's secret, in a temp folder. */
function world({ assets = true, dll = true, exe = true, teamRoot, version = VERSION, rev = REV, manifestOver = (m) => m } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-bench-test-'));
  const client = path.join(root, 'client');
  const build = path.join(client, version);
  fs.mkdirSync(build, { recursive: true });
  const content = { 'DeathMuffin.exe': Buffer.from('MZ-the-release-template'), 'DeathMuffin.pck': Buffer.from('the-pck-of-this-build'.repeat(50)), [DLL]: Buffer.from('the-combat-core'), 'DeathMuffin.assets.pck': Buffer.from('the-art-pack'.repeat(100)) };
  const names = ['DeathMuffin.exe', 'DeathMuffin.pck', DLL, 'DeathMuffin.assets.pck'].filter((n) => (n !== 'DeathMuffin.assets.pck' || assets) && (n !== DLL || dll) && (n !== 'DeathMuffin.exe' || exe));
  for (const n of names) fs.writeFileSync(path.join(build, n), content[n]);
  const files = names.slice().sort().map((n) => ({ path: n, size: content[n].length, sha256: sha256(content[n]), url: `https://example.invalid/death-muffin/client/${version}/${n}` }));
  fs.writeFileSync(path.join(client, 'manifest.json'), JSON.stringify(manifestOver({ version, built_at: '2026-10-19T12:00:00Z', rev, files, online: { enabled: true, staff: false, message: '' } })));
  const teamFiles = teamRoot || path.join(root, 'team-files');
  fs.mkdirSync(teamFiles, { recursive: true });
  const secretFile = path.join(root, 'secret');
  fs.writeFileSync(secretFile, `${SECRET}\n`);
  return { root, client, build, teamFiles, secretFile, content, names, manifest: path.join(client, 'manifest.json'), cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

const envFor = (w, backend, over = {}) => ({
  PATH: process.env.PATH, HOME: w.root, DM_TEAM_MANIFEST: w.manifest, DM_TEAM_ROOT: w.teamFiles, DM_TEAM_URL: 'https://example.invalid/death-muffin/team-files',
  DM_TEAM_API: backend.url, DM_TEAM_SECRET_FILE: w.secretFile, ...over,
});

const run = (cmd, args, env, opts = {}) => new Promise((resolve) => {
  const child = spawn(cmd, args, { env, ...opts });
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  child.on('close', (code) => resolve({ code, out }));
});
const bench = (w, backend, arg = VERSION, over = {}) => run('bash', [BENCH, arg], envFor(w, backend, over));
const folders = (w) => fs.readdirSync(w.teamFiles).filter((n) => BENCH_DIR.test(n));

/** Run `fn` with a fake backend and a world, cleaning both up. */
async function withWorld(opts, fn) {
  if (typeof opts === 'function') { fn = opts; opts = {}; }
  const backend = await fakeBackend(opts.backend);
  const w = world(opts.world);
  try { await fn(w, backend); } finally { await backend.close(); w.cleanup(); }
}

// ── team-bench.sh ────────────────────────────────────────────────────────────────────────────────────────────────────────

test('a release gets one bench job per team PC seen in the last 14 days, targeted at it, with the files hard-linked into team-files', async () => {
  await withWorld(async (w, backend) => {
    const r = await bench(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /team bench: 20261019\.120000-abcdef1 \(abcdef123456\): benchmark queued for 2 team PCs/);
    assert.match(folders(w)[0], BENCH_DIR, 'the release\'s folder is bench-<24 hex> directly under team-files');
    // the PCs came from the runner's route, 14 days, with the secret
    assert.deepStrictEqual(backend.calls[0], { method: 'GET', url: '/internal/team/pcs?days=14', secret: SECRET, body: undefined });
    const jobs = backend.jobs();
    assert.strictEqual(jobs.length, 2);
    assert.deepStrictEqual(jobs.map((j) => j.body.targetPc), [PC_W, PC_H]);
    assert.ok(jobs.every((j) => j.secret === SECRET));
    const [dir] = folders(w);
    assert.strictEqual(folders(w).length, 1, 'one folder for the release, shared by every PC\'s job');
    for (const { body } of jobs) {
      assert.deepStrictEqual(Object.keys(body).sort(), ['kind', 'payload', 'supersede', 'targetPc', 'title', 'ttlS', 'weightS']);
      assert.strictEqual(body.supersede, true, 'a PC is only ever offered the newest release\'s benchmark');
      assert.deepStrictEqual([body.kind, body.title, body.weightS, body.ttlS], ['bench', 'Benchmark of the new release, about 6 minutes', 360, 3 * 86400]);
      const p = body.payload;
      assert.deepStrictEqual(Object.keys(p).sort(), ['args', 'files', 'rev', 'setups', 'version']);
      assert.deepStrictEqual([p.version, p.rev, p.args], [VERSION, REV, []]);
      assert.deepStrictEqual(p.setups, [
        { preset: 'low', room: 'graves', class: 2, size: 'full_party', length: 'full' },
        { preset: 'medium', room: 'graves', class: 2, size: 'full_party', length: 'full' },
      ]);
      assert.deepStrictEqual(p.files.map((f) => f.name), ['DeathMuffin.exe', 'DeathMuffin.pck', DLL, 'DeathMuffin.assets.pck']);
      for (const f of p.files) {
        assert.strictEqual(f.url, `https://example.invalid/death-muffin/team-files/${dir}/${f.name}`);
        assert.match(f.url, /^https:\/\/example\.invalid\/death-muffin\/team-files\/bench-[0-9a-f]{24}\/[A-Za-z0-9._-]+$/, 'one safe path segment under team-files: what the app\'s address check takes');
        assert.ok(f.url.length < 400);
        assert.strictEqual(f.sha256, sha256(w.content[f.name]), `${f.name}: the manifest's hash`);
        assert.strictEqual(f.bytes, w.content[f.name].length);
      }
      const key = Object.fromEntries(p.files.map((f) => [f.name, f.cacheKey]));
      assert.deepStrictEqual(key, { 'DeathMuffin.exe': `godot-release-${sha256(w.content['DeathMuffin.exe']).slice(0, 16)}`, 'DeathMuffin.pck': undefined, [DLL]: undefined, 'DeathMuffin.assets.pck': `assets-${sha256(w.content['DeathMuffin.assets.pck']).slice(0, 16)}` });
    }
    // the files are the live build's own (hard links: no copy of the 500 MB pack), readable by the web server
    assert.deepStrictEqual(fs.readdirSync(path.join(w.teamFiles, dir)).sort(), w.names.slice().sort());
    for (const n of w.names) {
      const src = fs.statSync(path.join(w.build, n));
      const dst = fs.statSync(path.join(w.teamFiles, dir, n));
      assert.strictEqual(dst.ino, src.ino, `${n} is a hard link`);
      assert.ok((dst.mode & 0o044) === 0o044, `${n} is world-readable`);
    }
    assert.strictEqual(fs.statSync(path.join(w.teamFiles, dir)).mode & 0o777, 0o755);
    assert.ok(!r.out.includes(SECRET), 'the secret is never printed');
  });
});

test('the build may be named by its revision (12 or 40 hex characters, or 7) as well as by its version; any other build is skipped without a request', async () => {
  for (const arg of [REV, `${REV}00112233445566778899aabbccdd`.slice(0, 40), REV.slice(0, 7), VERSION]) {
    await withWorld(async (w, backend) => {
      const r = await bench(w, backend, arg);
      assert.strictEqual(r.code, 0, `${arg}: ${r.out}`);
      assert.strictEqual(backend.jobs().length, 2, arg);
    });
  }
  for (const arg of ['20261019.130000-0000000', '123456789abc', 'abcdef', 'abcdef9']) {
    await withWorld(async (w, backend) => {
      const r = await bench(w, backend, arg);
      assert.strictEqual(r.code, 0, r.out);
      assert.match(r.out, /the live build is 20261019\.120000-abcdef1 \(abcdef123456\), not /);
      assert.deepStrictEqual([backend.calls.length, folders(w).length], [0, 0], `${arg}: nothing asked, nothing linked`);
    });
  }
});

test('no team PC seen means no job and no folder; one PC under two accounts gets one job', async () => {
  await withWorld({ backend: { pcs: [] } }, async (w, backend) => {
    const r = await bench(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /no team PC was seen in the last 14 days: no benchmark jobs/);
    assert.deepStrictEqual([backend.jobs().length, folders(w).length], [0, 0]);
  });
  await withWorld({ backend: { pcs: [pcRow(PC_M, 1), pcRow(PC_M, 2), pcRow('bad id!', 3), { pcId: 7 }, pcRow(PC_W, 4)] } }, async (w, backend) => {
    const r = await bench(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.deepStrictEqual(backend.jobs().map((j) => j.body.targetPc), [PC_M, PC_W], 'one job per PC id, an id the server would refuse is left out');
  });
});

test('DM_TEAM_DAYS changes how far back PCs count', async () => {
  await withWorld(async (w, backend) => {
    await bench(w, backend, VERSION, { DM_TEAM_DAYS: '30' });
    assert.strictEqual(backend.calls[0].url, '/internal/team/pcs?days=30');
  });
});

test('a build without the art pack is benchmarked with three files; one without the exe, the pck or the core is skipped', async () => {
  await withWorld({ world: { assets: false } }, async (w, backend) => {
    const r = await bench(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.deepStrictEqual(backend.jobs()[0].body.payload.files.map((f) => f.name), ['DeathMuffin.exe', 'DeathMuffin.pck', DLL]);
    assert.ok(!fs.existsSync(path.join(w.teamFiles, folders(w)[0], 'DeathMuffin.assets.pck')));
  });
  for (const [over, name] of [[{ dll: false }, DLL], [{ exe: false }, 'DeathMuffin.exe']]) {
    await withWorld({ world: over }, async (w, backend) => {
      const r = await bench(w, backend);
      assert.strictEqual(r.code, 0, r.out);
      assert.ok(r.out.includes(`has no ${name}: skipped`), r.out);
      assert.deepStrictEqual([backend.calls.length, folders(w).length], [0, 0]);
    });
  }
});

test('failures print one line, exit 1 and leave no folder behind: the manifest, a file, the secret, the backend', async () => {
  await withWorld(async (w, backend) => {   // a file that is not what the manifest says
    fs.writeFileSync(path.join(w.build, 'DeathMuffin.pck'), 'short');
    const r = await bench(w, backend);
    assert.strictEqual(r.code, 1);
    assert.match(r.out, /team bench: .*DeathMuffin\.pck is not the file the manifest describes/);
    assert.deepStrictEqual([backend.calls.length, folders(w).length], [0, 0]);
  });
  await withWorld(async (w, backend) => {   // a manifest that is not there
    fs.rmSync(w.manifest);
    const r = await bench(w, backend);
    assert.deepStrictEqual([r.code, /team bench: cannot read the live manifest/.test(r.out)], [1, true]);
  });
  await withWorld(async (w, backend) => {   // no secret
    fs.rmSync(w.secretFile);
    const r = await bench(w, backend);
    assert.deepStrictEqual([r.code, /cannot read the runner's secret/.test(r.out), backend.calls.length, folders(w).length], [1, true, 0, 0]);
  });
  await withWorld(async (w, backend) => {   // the wrong secret: the backend answers 404
    fs.writeFileSync(w.secretFile, 'another-secret-0123456789-abcdef');
    const r = await bench(w, backend);
    assert.deepStrictEqual([r.code, /could not list the team PCs: the backend answered 404/.test(r.out), folders(w).length], [1, true, 0]);
  });
  await withWorld(async (w, backend) => {   // the backend is not there
    const r = await bench(w, backend, VERSION, { DM_TEAM_API: 'http://127.0.0.1:9' });
    assert.deepStrictEqual([r.code, /could not list the team PCs: the backend could not be reached/.test(r.out), folders(w).length], [1, true, 0]);
  });
  await withWorld(async (w, backend) => {   // a team-files folder that is missing
    fs.rmSync(w.teamFiles, { recursive: true });
    const r = await bench(w, backend);
    assert.deepStrictEqual([r.code, /the team-files folder .* is missing/.test(r.out), backend.jobs().length], [1, true, 0]);
  });
  await withWorld({ backend: { jobStatus: 500 } }, async (w, backend) => {   // every job refused: the files are removed again
    const r = await bench(w, backend);
    assert.strictEqual(r.code, 1);
    assert.strictEqual((r.out.match(/could not queue the benchmark for/g) || []).length, 2);
    assert.match(r.out, /the backend answered 500: The server could not finish that\./);
    assert.strictEqual(folders(w).length, 0, 'nothing will download them');
  });
});

test('one job refused keeps the folder for the other, still prints what failed and exits 1', async () => {
  await withWorld({ backend: { failJobs: 1 } }, async (w, backend) => {
    const r = await bench(w, backend);
    assert.strictEqual(r.code, 1);
    assert.match(r.out, /could not queue the benchmark for pc-war-0003/);
    assert.match(r.out, /benchmark queued for 1 team PC \(pc-helix-0002 job job000000002\)/);
    assert.strictEqual(folders(w).length, 1);
  });
});

test('the folder clean-up removes bench folders older than 4 days and keeps the newest 6 preview folders, each rule on its own names', async () => {
  await withWorld(async (w, backend) => {
    const DAY = 86400;
    const make = (name, ageDays) => {
      const dir = path.join(w.teamFiles, name);
      fs.mkdirSync(dir);
      fs.writeFileSync(path.join(dir, 'DeathMuffin.pck'), 'x');
      const t = Date.now() / 1000 - ageDays * DAY;
      fs.utimesSync(dir, t, t);
      return dir;
    };
    const benchOld = [make(`bench-${crypto.randomBytes(12).toString('hex')}`, 5), make(`bench-${crypto.randomBytes(12).toString('hex')}`, 30)];
    const benchKept = [make(`bench-${crypto.randomBytes(12).toString('hex')}`, 3.5), make(`bench-${crypto.randomBytes(12).toString('hex')}`, 0.1)];
    const previews = Array.from({ length: 8 }, (_, i) => make(crypto.randomBytes(16).toString('hex'), 20 - i));   // i = 7 is the newest; all are weeks old
    fs.mkdirSync(path.join(w.teamFiles, 'not-a-build-folder'));
    fs.writeFileSync(path.join(w.teamFiles, 'notes.txt'), 'keep');
    const r = await bench(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.deepStrictEqual(benchOld.map((d) => fs.existsSync(d)), [false, false], 'a bench folder older than 4 days goes');
    assert.deepStrictEqual(benchKept.map((d) => fs.existsSync(d)), [true, true], 'younger ones stay, a day past the jobs\' 3-day life is the margin');
    assert.strictEqual(folders(w).length, 3, 'the two kept and this release\'s');
    assert.deepStrictEqual(previews.filter((d) => fs.existsSync(d)), previews.slice(2), 'previews: the newest 6 stay, however old, and this release\'s folder does not count among them');
    assert.ok(fs.existsSync(path.join(w.teamFiles, 'not-a-build-folder')) && fs.existsSync(path.join(w.teamFiles, 'notes.txt')));
    for (const n of w.names) assert.ok(fs.existsSync(path.join(w.build, n)), 'the client folder\'s own files are untouched (a link was removed, not the file)');
    // DM_TEAM_BENCH_DAYS and DM_TEAM_KEEP reach the clean-up
    const strict = await bench(w, backend, VERSION, { DM_TEAM_BENCH_DAYS: '2', DM_TEAM_KEEP: '3' });
    assert.strictEqual(strict.code, 0, strict.out);
    assert.deepStrictEqual(benchKept.map((d) => fs.existsSync(d)), [false, true], '2 days: the 3.5-day-old one goes too');
    assert.strictEqual(previews.filter((d) => fs.existsSync(d)).length, 3);
  });
});

test('a burst of previews never takes a waiting benchmark\'s files: only age removes a bench folder', async () => {
  await withWorld(async (w, backend) => {
    await bench(w, backend);
    const [dir] = folders(w);
    for (let i = 0; i < 12; i++) {   // twelve preview builds come after it
      const d = path.join(w.teamFiles, crypto.randomBytes(16).toString('hex'));
      fs.mkdirSync(d);
      fs.utimesSync(d, Date.now() / 1000 + 10 + i, Date.now() / 1000 + 10 + i);
    }
    const r = await run('bash', [PRUNE, w.teamFiles], { PATH: process.env.PATH });   // what preview-godot.sh would run once it uses the script
    assert.strictEqual(r.code, 0, r.out);
    assert.ok(fs.existsSync(path.join(w.teamFiles, dir, 'DeathMuffin.exe')));
    assert.strictEqual(fs.readdirSync(w.teamFiles).filter((n) => HEX32.test(n)).length, 6);
  });
});

test('where a hard link is not possible (another file system) the files are copied', async (t) => {
  const shm = '/dev/shm';
  if (!fs.existsSync(shm) || fs.statSync(shm).dev === fs.statSync(os.tmpdir()).dev) return t.skip('no second file system here');
  const teamRoot = fs.mkdtempSync(path.join(shm, 'team-bench-test-'));
  try {
    await withWorld({ world: { teamRoot } }, async (w, backend) => {
      const r = await bench(w, backend);
      assert.strictEqual(r.code, 0, r.out);
      const [dir] = folders(w);
      for (const n of w.names) {
        const dst = path.join(teamRoot, dir, n);
        assert.deepStrictEqual(fs.readFileSync(dst), w.content[n], `${n} was copied whole`);
        assert.notStrictEqual(fs.statSync(dst).ino, fs.statSync(path.join(w.build, n)).ino);
        assert.strictEqual(fs.statSync(dst).mode & 0o644, 0o644);
      }
    });
  } finally {
    fs.rmSync(teamRoot, { recursive: true, force: true });
  }
});

test('team-bench.sh needs an argument', async () => {
  const r = await run('bash', [BENCH], { PATH: process.env.PATH });
  assert.deepStrictEqual([r.code, /usage:/.test(r.out)], [2, true]);
});

// ── the setups, held to the game's own lists ────────────────────────────────────────────────────────────────────────────

const REPO_ROOT = path.join(HERE, '..', '..');
/** What the game's benchmark (client/next/perf/dm_benchmark.gd) and graphics presets (client/game/dm_graphics_preset.gd) know, read from the source. */
function gameLists() {
  const gd = fs.readFileSync(path.join(REPO_ROOT, 'client/next/perf/dm_benchmark.gd'), 'utf8');
  const dict = (name) => [...(gd.match(new RegExp(`^const ${name} := \\{(.*?)\\}(?:\\s|$)`, 'm'))?.[1] ?? '').matchAll(/"([a-z_]+)":/g)].map((m) => m[1]);
  const rooms = [...(gd.match(/^const ROOMS := \[(.*?)\]/m)?.[1] ?? '').matchAll(/"([a-z_]+)"/g)].map((m) => m[1]);
  const presetGd = fs.readFileSync(path.join(REPO_ROOT, 'client/game/dm_graphics_preset.gd'), 'utf8');
  const presets = [...(presetGd.match(/^const IDS: Array\[String\] = \[(.*?)\]/m)?.[1] ?? '').matchAll(/"([a-z]+)"/g)].map((m) => m[1]);
  const disciplines = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'client/data/content/disciplines.json'), 'utf8')).PLAYABLE_DISCIPLINES;
  const classes = disciplines.filter((d) => d.family === 'necromancer' || d.family === 'reaper').map((d) => d.classIndex);   // DmCharacterBuild.is_playable
  return { rooms, sizes: dict('SIZES'), lengths: dict('LENGTHS'), presets, classes };
}

test('the game\'s own lists are read (a changed source cannot make the check below pass by finding nothing)', () => {
  const g = gameLists();
  assert.deepStrictEqual(g.lengths, ['quick', 'full'], 'the benchmark knows two lengths: "standard" is a size, and an unknown length silently becomes full');
  assert.deepStrictEqual(g.sizes, ['light', 'standard', 'heavy', 'full_party']);
  assert.deepStrictEqual(g.presets, ['low', 'medium', 'high', 'ultra']);
  assert.ok(g.rooms.includes('graves') && g.rooms.length === 9, g.rooms.join(','));
  assert.ok(g.classes.includes(2) && g.classes.includes(11) && !g.classes.includes(5), g.classes.join(','));
});

test('every setup the hook sends is something the game\'s benchmark can run, with exactly the values its own lists have (no unknown length that silently becomes Full)', async () => {
  const g = gameLists();
  const { parseRun } = require('./backend/benchmarks.cjs');
  await withWorld(async (w, backend) => {
    assert.strictEqual((await bench(w, backend)).code, 0);
    const setups = backend.jobs()[0].body.payload.setups;
    assert.ok(setups.length >= 1 && setups.length <= 6, 'the app takes 1 to 6 setups');
    const seen = new Set();
    for (const st of setups) {
      assert.deepStrictEqual(Object.keys(st).sort(), ['class', 'length', 'preset', 'room', 'size']);
      assert.ok(g.presets.includes(st.preset), `preset ${st.preset}`);
      assert.ok(g.rooms.includes(st.room), `room ${st.room}`);
      assert.ok(g.sizes.includes(st.size), `size ${st.size}`);
      assert.ok(g.lengths.includes(st.length), `length ${st.length} is not one of ${g.lengths}`);
      assert.ok(Number.isInteger(st.class) && g.classes.includes(st.class), `class ${st.class}`);
      assert.ok(!seen.has(JSON.stringify(st)), 'no setup twice');
      seen.add(JSON.stringify(st));
      // the flags the app builds from it are tokens its argument check takes (client/main/main.gd reads them by these names)
      for (const arg of [`--bench-room=${st.room}`, `--bench-class=${st.class}`, `--bench-size=${st.size}`, `--bench-length=${st.length}`, `--bench-preset=${st.preset}`]) assert.match(arg, /^--([a-z][a-z0-9-]{0,30})(=[A-Za-z0-9_.,-]{1,40})?$/);
    }
    assert.strictEqual(setups[0].length, 'full', 'the Full length, the setup the budgets are measured on');
  });
  // and the server stores what the game can send: every game size, length and preset is accepted by the history, "standard" as a length is not
  const run = (over) => parseRun({ clientRunId: 'game-list-run-01', preset: 'low', room: 'graves', discipline: 2, size: 'full_party', length: 'full', metrics: { avg_fps: 60 }, ...over });
  for (const preset of g.presets) assert.ok(!run({ preset }).error, `preset ${preset}`);
  for (const size of g.sizes) assert.ok(!run({ size }).error, `size ${size}`);
  for (const length of g.lengths) assert.ok(!run({ length }).error, `length ${length}`);
  assert.ok(run({ length: 'standard' }).error, 'the history refuses the length the first draft of the contract named');
});

// ── team-files-prune.sh ──────────────────────────────────────────────────────────────────────────────────────────────────

test('team-files-prune.sh keeps the newest N preview folders by modification time, removes bench folders older than the days given, and touches nothing else', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-prune-test-'));
  try {
    const dirs = [];
    for (let i = 0; i < 10; i++) {
      const d = path.join(root, crypto.randomBytes(16).toString('hex'));
      fs.mkdirSync(d);
      fs.utimesSync(d, 1_700_000_000 + i * 100, 1_700_000_000 + i * 100);
      dirs.push(d);
    }
    const upper = path.join(root, 'A'.repeat(32));   // not lower-case hex
    const short = path.join(root, 'abc123');
    fs.mkdirSync(upper); fs.mkdirSync(short);
    fs.writeFileSync(path.join(root, 'f'.repeat(32)), 'a file with a build folder\'s name');
    const benchDir = (ageDays, name = `bench-${crypto.randomBytes(12).toString('hex')}`) => {
      const d = path.join(root, name);
      fs.mkdirSync(d);
      const t = Date.now() / 1000 - ageDays * 86400;
      fs.utimesSync(d, t, t);
      return d;
    };
    const b5 = benchDir(5); const b4ish = benchDir(3.9); const b1 = benchDir(1); const bFresh = benchDir(0);
    const badNames = [benchDir(9, 'bench-ABCDEF'), benchDir(9, `bench-${'a'.repeat(23)}`), benchDir(9, `bench-${'a'.repeat(25)}`), benchDir(9, `xbench-${'a'.repeat(24)}`), benchDir(9, `bench-${'g'.repeat(24)}`)];
    const benchFile = path.join(root, `bench-${'b'.repeat(24)}`);
    fs.writeFileSync(benchFile, 'a file, not a folder');
    fs.utimesSync(benchFile, 1_700_000_000, 1_700_000_000);
    const r = await run('bash', [PRUNE, root], { PATH: process.env.PATH });
    assert.deepStrictEqual([r.code, r.out], [0, ''], 'it prints nothing');
    assert.deepStrictEqual(dirs.filter((d) => fs.existsSync(d)), dirs.slice(4), 'previews: the newest 6');
    assert.deepStrictEqual([b5, b4ish, b1, bFresh].map((d) => fs.existsSync(d)), [false, true, true, true], 'bench folders: older than 4 days go');
    assert.ok([upper, short, path.join(root, 'f'.repeat(32)), benchFile, ...badNames].every((d) => fs.existsSync(d)), 'names that are neither kind, and files, stay');
    assert.strictEqual((await run('bash', [PRUNE, root, '2', '1'], { PATH: process.env.PATH })).code, 0);
    assert.deepStrictEqual(dirs.filter((d) => fs.existsSync(d)), dirs.slice(8), 'keep 2');
    assert.deepStrictEqual([b4ish, b1, bFresh].map((d) => fs.existsSync(d)), [false, false, true], 'bench-days 1: older than a day goes (the one-day-old one is just past it)');
    assert.strictEqual((await run('bash', [PRUNE, root, '0', '0'], { PATH: process.env.PATH })).code, 0);
    assert.deepStrictEqual(dirs.filter((d) => fs.existsSync(d)), [], 'keep 0 removes every preview folder');
    assert.ok(fs.existsSync(upper) && fs.existsSync(benchFile) && badNames.every((d) => fs.existsSync(d)));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('team-files-prune.sh refuses a missing or symlinked root and a bad count, with exit 2 and nothing removed', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-prune-test-'));
  try {
    const real = path.join(root, 'real');
    const victim = path.join(real, 'a'.repeat(32));
    fs.mkdirSync(victim, { recursive: true });
    fs.symlinkSync(real, path.join(root, 'link'));
    for (const args of [[], [path.join(root, 'nope')], [path.join(root, 'link')], [real, 'many'], [real, '-1'], [real, '6', 'x'], [real, '6', '-2']]) {
      const r = await run('bash', [PRUNE, ...args], { PATH: process.env.PATH });
      assert.strictEqual(r.code, 2, JSON.stringify(args));
    }
    assert.ok(fs.existsSync(victim));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

// ── the hook block of publish-godot-client.sh ───────────────────────────────────────────────────────────────────────────

/** The hook block, as the publish script has it between its two marker lines. */
const hookBlock = () => {
  const text = fs.readFileSync(PUBLISH, 'utf8');
  const a = text.indexOf('# --- team bench hook ---');
  const b = text.indexOf('# --- end team bench hook ---');
  assert.ok(a > 0 && b > a, 'the publish script has the hook block between its markers');
  assert.strictEqual(text.indexOf('# --- team bench hook ---', a + 1), -1);
  return text.slice(a, b);
};

/** A git repository with three commits: one without the scripts, one with them, one after. Returns { dir, c1, c2, c3 }. */
function repo(root) {
  const dir = path.join(root, 'repo');
  fs.mkdirSync(path.join(dir, 'server/death-muffin'), { recursive: true });
  const git = (...a) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', ...a], { encoding: 'utf8' }).trim();
  git('init', '-q');
  fs.writeFileSync(path.join(dir, 'README'), 'one');
  git('add', 'README');
  git('commit', '-q', '-m', 'one');
  const c1 = git('rev-parse', '--short=12', 'HEAD');
  for (const f of ['team-bench.sh', 'team-files-prune.sh']) fs.copyFileSync(path.join(HERE, f), path.join(dir, 'server/death-muffin', f));
  git('add', 'server/death-muffin/team-bench.sh', 'server/death-muffin/team-files-prune.sh');
  git('commit', '-q', '-m', 'two');
  const c2 = git('rev-parse', '--short=12', 'HEAD');
  fs.writeFileSync(path.join(dir, 'README'), 'three');
  git('add', 'README');
  git('commit', '-q', '-m', 'three');
  const c3 = git('rev-parse', '--short=12', 'HEAD');
  return { dir, c1, c2, c3 };
}

/** Run the hook block as the publish script would (set -euo pipefail, the variables it has by then). */
const runHook = (w, backend, g, vars, extra = {}) => run('bash', ['-c', `set -euo pipefail\nREPO="$G_REPO"; SHA="$G_SHA"; VERSION="$G_VERSION"; OUT_DIR="$G_OUT"; PREV_REV="$G_PREV"\n${hookBlock()}\necho "block finished"`], {
  ...envFor(w, backend), G_REPO: g.dir, G_SHA: vars.sha, G_VERSION: VERSION, G_OUT: vars.out ?? '/var/www/death-muffin/client', G_PREV: vars.prev ?? '', ...extra,
});

test('the publish hook: a forward release of the live folder queues the benchmark, from the published revision\'s own scripts, and the publish goes on', async () => {
  await withWorld(async (w, backend) => {
    const g = repo(w.root);
    const r = await runHook(w, backend, g, { sha: g.c3, prev: g.c2 });
    assert.match(r.out, /team bench: 20261019\.120000-abcdef1 \(abcdef123456\): benchmark queued for 2 team PCs/);
    assert.ok(r.out.trim().endsWith('block finished'));
    assert.strictEqual(r.code, 0);
    assert.strictEqual(backend.jobs().length, 2);
    assert.strictEqual(folders(w).length, 1);
  });
});

test('the publish hook: a first publish, the same revision again and a test folder with TEAM_BENCH=1 run it; the test channel\'s folder, NO_TEAM_BENCH and a rollback do not', async () => {
  await withWorld(async (w, backend) => {
    const g = repo(w.root);
    const ran = (r) => /benchmark queued/.test(r.out);
    assert.ok(ran(await runHook(w, backend, g, { sha: g.c3, prev: '' })), 'a first publish (no live revision before)');
    assert.ok(ran(await runHook(w, backend, g, { sha: g.c3, prev: g.c3 })), 'the same revision again');
    assert.ok(ran(await runHook(w, backend, g, { sha: g.c3, prev: 'deadbeef12345' })), 'a previous revision this checkout does not know');
    assert.ok(ran(await runHook(w, backend, g, { sha: g.c3, prev: g.c2, out: '/tmp/some-test-folder' }, { TEAM_BENCH: '1' })), 'TEAM_BENCH=1 forces it');
    const before = backend.calls.length;
    const quiet = [
      [{ sha: g.c3, prev: g.c2, out: '/var/www/death-muffin/client-test' }, {}, /^$/],                    // the test channel's folder
      [{ sha: g.c3, prev: g.c2, out: '/tmp/some-test-folder' }, {}, /^$/],                                 // a test's folder
      [{ sha: g.c3, prev: g.c2 }, { NO_TEAM_BENCH: '1' }, /^$/],
      [{ sha: g.c2, prev: g.c3 }, {}, /team bench: .* is not newer than the build that was live \(.*\): skipped \(rollback\?\)/],
    ];
    for (const [vars, extra, said] of quiet) {
      const r = await runHook(w, backend, g, vars, extra);
      assert.strictEqual(r.code, 0, JSON.stringify(vars));
      assert.ok(!ran(r), JSON.stringify(vars));
      assert.match(r.out.replace('block finished', '').trim(), said, JSON.stringify(vars));
    }
    assert.strictEqual(backend.calls.length, before, 'a skipped hook asks the backend nothing');
  });
});

test('the publish hook: a revision without the scripts is skipped with a line, and a failing hook never fails the publish', async () => {
  await withWorld(async (w, backend) => {
    const g = repo(w.root);
    const r = await runHook(w, backend, g, { sha: g.c1, prev: '' });
    assert.deepStrictEqual([r.code, /team bench: .* has no team-bench\.sh \(older revision\): skipped/.test(r.out), r.out.trim().endsWith('block finished')], [0, true, true]);
    assert.strictEqual(backend.calls.length, 0);
    fs.rmSync(w.secretFile);   // the hook itself fails (exit 1): the block still finishes
    const failed = await runHook(w, backend, g, { sha: g.c3, prev: g.c2 });
    assert.deepStrictEqual([failed.code, /cannot read the runner's secret/.test(failed.out), /team bench: failed \(the publish itself is fine\)/.test(failed.out), failed.out.trim().endsWith('block finished')], [0, true, true, true]);
    const down = await runHook(w, backend, g, { sha: g.c3, prev: g.c2 }, { DM_TEAM_API: 'http://127.0.0.1:9' });
    assert.strictEqual(down.code, 0);
  });
});

test('the publish script runs the hook after announcing the release, remembers the live revision before the manifest is replaced, and says so in its header', () => {
  const text = fs.readFileSync(PUBLISH, 'utf8');
  assert.ok(text.indexOf('PREV_REV=$(') > 0 && text.indexOf('PREV_REV=$(') < text.indexOf('mv -f "$OUT_DIR/manifest.json.tmp" "$OUT_DIR/manifest.json"'), 'PREV_REV is read before the switch');
  assert.ok(text.indexOf('# --- team bench hook ---') > text.indexOf('announce-release.sh" "$SHA"') || text.indexOf('# --- team bench hook ---') > text.indexOf('ANN=$(mktemp)'), 'the hook comes after the announcement');
  assert.ok(text.indexOf('# --- end team bench hook ---') > text.length - 200, 'it is the last thing the publish does');
  assert.match(text, /^# 6\. team-bench\.sh:/m);
  assert.ok(text.includes('TEAM_BENCH NO_TEAM_BENCH'));
  execFileSync('bash', ['-n', PUBLISH]);
  execFileSync('bash', ['-n', BENCH]);
  execFileSync('bash', ['-n', PRUNE]);
});
