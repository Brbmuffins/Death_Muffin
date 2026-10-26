// Run: node --test server/death-muffin/team-check.test.cjs
// team-check.sh (a team PC's checks of a revision before it goes live), team-files-prune.sh and publish-godot-client.sh's EXPORT_ONLY mode, against a fake backend on a
// loopback port, stand-ins for the publish and preview-godot.sh in a temp git repository, and temp folders: no real manifest, team-files, secret, backend or Godot is touched.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn, execFileSync, spawnSync } = require('node:child_process');

const HERE = __dirname;
const REPO_ROOT = path.join(HERE, '..', '..');
const CHECK = path.join(HERE, 'team-check.sh');
const PRUNE = path.join(HERE, 'team-files-prune.sh');
const PUBLISH = path.join(HERE, 'publish-godot-client.sh');
const SECRET = 'runner-secret-0123456789-abcdef';
const DLL = 'libdmcore.windows.template_release.x86_64.dll';
const VERSION = '20261019.120000-abcdef1';
const CHECK_DIR = /^check-[0-9a-f]{24}$/;
const HEX32 = /^[0-9a-f]{32}$/;
const PC_H = 'pc-helix-0002';
const PC_W = 'pc-war-0003';
const HAS_PIL = spawnSync('python3', ['-c', 'import PIL']).status === 0;
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const iso = (agoS = 0) => new Date(Date.now() - agoS * 1000).toISOString().replace(/\.\d+Z$/, '.000Z');
const pcRow = (pcId, over = {}) => ({ accountId: 1, username: pcId === PC_H ? 'Helix' : 'warbogar', pcId, name: 'PC', version: '0.4.1', gpu: `GPU of ${pcId}`, mode: 'auto', state: {}, lastSeen: iso(), ...over });
const RELEASE_NAMES = ['DeathMuffin.exe', 'DeathMuffin.pck', DLL, 'DeathMuffin.assets.pck'];

/** A stand-in for preview-godot.sh --team: a 32-hex folder in the team root and the TEAMFILES line, appending what it was run with to FAKE_LOG. */
const FAKE_PREVIEW = [
  '#!/usr/bin/env bash',
  'set -euo pipefail',
  '[[ "${1:-}" =~ ^[0-9a-f]{6}$ ]] && [ "${2:-}" = --team ] || { echo "bad call"; exit 2; }',
  'echo "preview $(git rev-parse --short=12 HEAD) $(nice) ${DM_PREP:-none}" >> "$FAKE_LOG"',
  '[ "${FAKE_PREVIEW:-ok}" = ok ] || { echo "godot export failed"; exit 1; }',
  'DIR=$(head -c16 /dev/urandom | od -An -tx1 | tr -d " \\n")',
  'mkdir -m 755 "$DM_TEAM_ROOT/$DIR"',
  'python3 - "$DM_TEAM_ROOT/$DIR" "$DM_TEAM_URL/$DIR" "$(git rev-parse --short=12 HEAD)" <<\'PY\'',
  'import hashlib, json, os, sys',
  'dest, base, rev = sys.argv[1:4]',
  'out = []',
  'for n in ["DeathMuffinDebug.exe", "DeathMuffinDebug.pck", "libdmcore.windows.template_release.x86_64.dll", "DeathMuffin.assets.pck"]:',
  '    data = (n + " debug of " + rev).encode()',
  '    open(os.path.join(dest, n), "wb").write(data)',
  '    out.append({"name": n, "url": base + "/" + n, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})',
  'print("TEAMFILES: " + json.dumps(out))',
  'PY',
].join('\n') + '\n';

/** A stand-in for publish-godot-client.sh: only its EXPORT_ONLY mode, writing the release files of the revision into $EXPORT_ONLY. */
const FAKE_PUBLISH = [
  '#!/usr/bin/env bash',
  'set -euo pipefail',
  '[ -n "${EXPORT_ONLY:-}" ] || { echo "not an export"; exit 3; }',
  'echo "publish $1 $(nice) $REPO" >> "$FAKE_LOG"',
  'case "${FAKE_PUBLISH:-ok}" in fail) echo "the boot smoke failed"; exit 1;; partial) mkdir -p "$EXPORT_ONLY"; echo x > "$EXPORT_ONLY/DeathMuffin.exe"; exit 0;; esac',
  'mkdir -p "$EXPORT_ONLY"',
  `for n in ${RELEASE_NAMES.join(' ')}; do printf '%s of %s' "$n" "$1" > "$EXPORT_ONLY/$n"; done`,
].join('\n') + '\n';

const git = (dir, ...a) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', ...a], { encoding: 'utf8' }).trim();

/** A temp world: a repository (c1 without the scripts, c2 = the live build's revision, c3 = the change), the live client's folder, team-files, results and the secret. */
function world({ preview = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-check-test-'));
  const dir = path.join(root, 'repo');
  fs.mkdirSync(path.join(dir, 'server/death-muffin/discord-agent'), { recursive: true });
  git(dir, 'init', '-q');
  fs.writeFileSync(path.join(dir, 'README'), 'one');
  git(dir, 'add', 'README');
  git(dir, 'commit', '-q', '-m', 'one');
  const c1 = git(dir, 'rev-parse', 'HEAD');
  fs.mkdirSync(path.join(dir, 'tools/check'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'tools/check/prep.sh'), '#!/usr/bin/env bash\n');
  const add = ['tools/check/prep.sh'];
  if (preview) { fs.writeFileSync(path.join(dir, 'server/death-muffin/discord-agent/preview-godot.sh'), FAKE_PREVIEW); add.push('server/death-muffin/discord-agent/preview-godot.sh'); }
  git(dir, 'add', ...add);
  git(dir, 'commit', '-q', '-m', 'two');
  const c2 = git(dir, 'rev-parse', 'HEAD');
  fs.writeFileSync(path.join(dir, 'README'), 'three');
  git(dir, 'add', 'README');
  git(dir, 'commit', '-q', '-m', 'three');
  const c3 = git(dir, 'rev-parse', 'HEAD');
  const client = path.join(root, 'client');
  const build = path.join(client, VERSION);
  fs.mkdirSync(build, { recursive: true });
  const live = {};
  for (const n of RELEASE_NAMES) { live[n] = Buffer.from(`${n} of the live build`); fs.writeFileSync(path.join(build, n), live[n]); }
  fs.writeFileSync(path.join(client, 'manifest.json'), JSON.stringify({ version: VERSION, rev: c2.slice(0, 12), files: [] }));
  const dirs = {};
  for (const k of ['team-files', 'results', 'work', 'checks']) { dirs[k] = path.join(root, k); fs.mkdirSync(dirs[k]); }
  const secretFile = path.join(root, 'secret');
  fs.writeFileSync(secretFile, `${SECRET}\n`);
  const publish = path.join(root, 'publish.sh');
  fs.writeFileSync(publish, FAKE_PUBLISH);
  return { root, repo: dir, c1, c2, c3, client, build, live, ...dirs, teamFiles: dirs['team-files'], secretFile, publish, log: path.join(root, 'fake.log'),
    logLines: () => (fs.existsSync(path.join(root, 'fake.log')) ? fs.readFileSync(path.join(root, 'fake.log'), 'utf8').trim().split('\n') : []),
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

const PNG_1x1 = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');   // a valid 1x1 PNG

/**
 * A fake backend: the runner's /internal/team routes with the secret check. Each created job follows `script` (a list of statuses, one per read, the last repeating);
 * when it reads 'done' the job carries `results(job, index)`: { steps, files: { name: Buffer|object } } written to <results>/<id>/.
 */
function fakeBackend(w, { pcs = [pcRow(PC_H)], running = [], script = ['running', 'done'], results = defaultResults, createStatus = 200, error = '' } = {}) {
  const calls = [];
  const jobs = [];
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString() || 'null') : undefined;
      calls.push({ method: req.method, url: req.url, secret: req.headers['x-team-secret'], body });
      const send = (status, obj) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
      if (req.headers['x-team-secret'] !== SECRET) return send(404, { success: false, error: 'Not found' });
      if (req.method === 'GET' && req.url === '/internal/team/pcs?days=14') return send(200, { success: true, data: { pcs } });
      if (req.method === 'GET' && req.url === '/internal/team/jobs?status=running&limit=50') return send(200, { success: true, data: { jobs: running } });
      if (req.method === 'POST' && req.url === '/internal/team/jobs') {
        if (createStatus !== 200) return send(createStatus, { success: false, error: 'The server could not finish that.' });
        const id = `job${String(jobs.length + 1).padStart(9, '0')}`;
        jobs.push({ id, body, reads: 0, folderSeen: fs.readdirSync(w.teamFiles).filter((n) => CHECK_DIR.test(n)) });
        return send(200, { success: true, data: { id } });
      }
      const m = /^\/internal\/team\/jobs\/(job\d{9})(\/(cancel|reported))?$/.exec(req.url);
      const j = m && jobs.find((x) => x.id === m[1]);
      if (j && req.method === 'POST') return send(200, { success: true, data: {} });
      if (j && req.method === 'GET') {
        const status = script[Math.min(j.reads, script.length - 1)];
        j.reads += 1;
        const row = { id: j.id, kind: 'release', status, payload: j.body.payload, claimedPc: j.body.targetPc, error: status === 'done' ? null : error || null, result: null, files: [] };
        if (status === 'done' || (status === 'failed' && results)) {
          const r = results(j, jobs.indexOf(j)) || { steps: [], files: {} };
          const folder = path.join(w.results, j.id);
          fs.mkdirSync(folder, { recursive: true });
          for (const [name, data] of Object.entries(r.files)) fs.writeFileSync(path.join(folder, name), Buffer.isBuffer(data) ? data : JSON.stringify(data));
          row.result = { steps: r.steps };
          row.files = Object.keys(r.files).map((name) => ({ name, path: path.join(folder, name) }));
        }
        return send(200, { success: true, data: row });
      }
      return send(404, { success: false, error: 'Not found' });
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    calls, jobs, url: `http://127.0.0.1:${server.address().port}`, posted: (id, what) => calls.some((c) => c.method === 'POST' && c.url === `/internal/team/jobs/${id}/${what}`),
    close: () => new Promise((r) => server.close(r)),
  })));
}

/** What a PC that passed every step it was given uploads (numbers differ per job: the live build first). */
function defaultResults(j, i) {
  const steps = j.body.payload.steps;
  const files = {};
  const sent = steps.map((step) => ({ step, ok: true }));
  if (steps.includes('install')) files['install.json'] = { step: 'install', exitCode: 0, bootMs: 3000 + i * 100, ok: true };
  if (steps.includes('quit-loading')) files['quit-loading.json'] = { step: 'quit-loading', exitCode: 0, seconds: 3.5, ok: true };
  if (steps.includes('stutter')) files['stutter.json'] = { scenario: 'stutter', p50_ms: 1.4, p99_ms: 2.4 + i, rows: [{ discipline: 'ossuary', rite: 'soul_siphon', worst_ms: 3.9 + i, compilations: 18, kinds: { canvas: 0, mesh: 0, surface: 2, draw: 0, specialization: 16 } }] };
  if (steps.includes('bench')) files['bench.json'] = { step: 'bench', ok: true, summary: [{ preset: 'low', avg_fps: 690 - i * 10, p99_ms: 2.9 }, { preset: 'medium', avg_fps: 640 - i * 10, p99_ms: 3.1 }] };
  if (steps.includes('screens')) {
    files['screens.json'] = { step: 'screens', ok: true };
    for (const shot of ['bag-tooltip', 'map']) files[`1920x1080_${shot}.png`] = PNG_1x1;
  }
  return { steps: sent, files };
}

const envFor = (w, backend, over = {}) => ({
  PATH: process.env.PATH, HOME: process.env.HOME, DM_TEAM_MANIFEST: path.join(w.client, 'manifest.json'), DM_TEAM_ROOT: w.teamFiles, DM_TEAM_URL: 'https://example.invalid/team-files',
  DM_TEAM_API: backend.url, DM_TEAM_SECRET_FILE: w.secretFile, DM_TEAM_RESULTS: w.results, DM_TEAM_REPO: w.repo, DM_TEAM_WORK: w.work, DM_TEAM_CHECKS: w.checks,
  DM_TEAM_PUBLISH: w.publish, DM_TEAM_POLL_S: '0.05', DM_TEAM_BUILD_TIMEOUT: '60', FAKE_LOG: w.log, ...over,
});
const run = (cmd, args, env) => new Promise((resolve) => {
  const child = spawn(cmd, args, { env });
  let out = '';
  let err = '';
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { err += d; });
  child.on('close', (code) => resolve({ code, out, err, all: out + err }));
});
const check = (w, backend, args, over = {}) => run('bash', [CHECK, ...args], envFor(w, backend, over));
const verdict = (r) => { const line = r.out.trim().split('\n').reverse().find((l) => l.startsWith('TEAMCHECK: ')); return line ? JSON.parse(line.slice(11)) : null; };
const niceNow = () => Number(execFileSync('nice', { encoding: 'utf8' }).trim());
const checkDirs = (w) => fs.readdirSync(w.teamFiles).filter((n) => CHECK_DIR.test(n));

async function withWorld(opts, fn) {
  if (typeof opts === 'function') { fn = opts; opts = {}; }
  const w = world(opts.world);
  const backend = await fakeBackend(w, opts.backend);
  try { await fn(w, backend); } finally { await backend.close(); w.cleanup(); }
}

// ── the check ────────────────────────────────────────────────────────────────────────────────────────────────────────────

test('the default checks build only the release export, queue one job at the free PC with the build\'s own files, and write the summary', async () => {
  await withWorld(async (w, backend) => {
    const r = await check(w, backend, [w.c3.slice(0, 7)]);
    assert.strictEqual(r.code, 0, r.all);
    const v = verdict(r);
    assert.strictEqual(v.status, 'done', r.all);
    assert.deepStrictEqual(w.logLines().map((l) => l.split(' ').slice(0, 3).join(' ')), [`publish ${w.c3} ${Math.min(19, niceNow() + 10)}`], 'one release export of the full revision, 10 nicer than this, and no debug build');
    assert.strictEqual(backend.jobs.length, 1);
    const job = backend.jobs[0].body;
    assert.deepStrictEqual([job.kind, job.title, job.targetPc, job.weightS, job.ttlS, job.supersede], ['release', `Checks of ${w.c3.slice(0, 7)}`, PC_H, 60, 14400, undefined]);
    const p = job.payload;
    assert.deepStrictEqual([p.version, p.rev, p.godotVersion, p.steps, p.args, 'setups' in p, 'screens' in p, 'soak' in p], [w.c3.slice(0, 12), w.c3.slice(0, 12), '4.7.2.stable', ['install', 'quit-loading'], [], false, false, false]);
    assert.deepStrictEqual(p.builds.map((b) => b.label), ['release']);
    const folder = backend.jobs[0].folderSeen[0];
    assert.match(folder, CHECK_DIR, 'the files were in team-files when the job was queued');
    for (const f of p.builds[0].files) {
      const data = Buffer.from(`${f.name} of ${w.c3}`);
      assert.deepStrictEqual([f.url, f.sha256, f.bytes], [`https://example.invalid/team-files/${folder}/change/${f.name}`, sha256(data), data.length], f.name);
    }
    assert.deepStrictEqual(p.builds[0].files.filter((f) => f.cacheKey).map((f) => f.cacheKey.split('-').slice(0, -1).join('-')), ['godot-release', 'assets'], 'the exe and the art pack carry cache keys');
    assert.deepStrictEqual(v.lines, [`**Team PC checks of ${w.c3.slice(0, 7)}** on Helix's PC (GPU of ${PC_H})`, 'install: ✓ first screen after 3,000 ms', 'quit while loading: ✓ exits cleanly in 3.5 s']);
    assert.strictEqual(fs.readFileSync(v.summary, 'utf8'), v.lines.join('\n') + '\n');
    assert.ok(v.out.startsWith(w.checks + path.sep) && fs.existsSync(path.join(v.out, 'result.json')));
    assert.deepStrictEqual([v.pc, v.gpu, v.jobs], [PC_H, `GPU of ${PC_H}`, [{ label: 'change', id: 'job000000001' }]]);
    assert.deepStrictEqual(checkDirs(w), [], 'the files\' folder is removed');
    assert.ok(backend.posted('job000000001', 'cancel') && backend.posted('job000000001', 'reported'));
    assert.ok(backend.calls.every((c) => c.secret === SECRET));
  });
});

test('--compare runs the same checks on the live build first, on the same PC: live files from the live client, both debug builds, and live -> change lines and contact sheets', async () => {
  await withWorld(async (w, backend) => {
    const r = await check(w, backend, [w.c3, '--checks', 'bench,stutter,screens', '--compare']);
    assert.strictEqual(r.code, 0, r.all);
    const v = verdict(r);
    const log = w.logLines().map((l) => l.split(' ').slice(0, 2).join(' '));
    assert.deepStrictEqual(log, [`preview ${w.c2.slice(0, 12)}`, `publish ${w.c3}`, `preview ${w.c3.slice(0, 12)}`], 'the live revision\'s debug build, then the change\'s release and debug builds');
    assert.strictEqual(backend.jobs.length, 2);
    const [live, change] = backend.jobs.map((j) => j.body);
    assert.deepStrictEqual([live.title, change.title], [`Checks of the live build ${VERSION}`, `Checks of ${w.c3.slice(0, 7)}`], 'the live build first');
    assert.deepStrictEqual([live.targetPc, change.targetPc], [PC_H, PC_H], 'both on the same PC');
    assert.deepStrictEqual(change.payload.steps, ['screens', 'stutter', 'bench'], 'the steps in the order they run');
    assert.strictEqual(change.weightS, 600);
    assert.deepStrictEqual([live.payload.version, live.payload.rev], [VERSION, w.c2.slice(0, 12)]);
    const liveRelease = live.payload.builds.find((b) => b.label === 'release').files;
    for (const f of liveRelease) assert.strictEqual(f.sha256, sha256(w.live[f.name]), `${f.name}: the live client's own file`);
    assert.ok(live.payload.builds.find((b) => b.label === 'debug').files.every((f) => f.url.includes('/live/debug/')));
    assert.ok(change.payload.builds.find((b) => b.label === 'debug').files.every((f) => f.url.includes('/change/debug/')));
    for (const n of RELEASE_NAMES) assert.strictEqual(fs.readFileSync(path.join(w.build, n)).toString(), w.live[n].toString(), 'the live client folder is untouched');
    assertShotPlan(change.payload.screens.plan);
    assert.deepStrictEqual(change.payload.screens.resolutions, ['1920x1080', '2560x1440', '3840x2160', '3440x1440']);
    const c7 = w.c3.slice(0, 7);
    const lines = v.lines.slice(1);
    if (!HAS_PIL) assert.strictEqual(lines.pop(), '(no contact sheets: Pillow is not installed)', 'without Pillow the summary says so');
    assert.deepStrictEqual(lines, [
      `screens · live build ${VERSION}: ✓ 2 pictures at 1 resolution`, `screens · this change ${c7}: ✓ 2 pictures at 1 resolution`,
      `stutter · live build ${VERSION}: ✓ worst soul siphon (Ossuary) 3.9 ms; 18 pipeline compiles (16 in the background); p50 1.4 / p99 2.4 ms`,
      `stutter · this change ${c7}: ✓ worst soul siphon (Ossuary) 4.9 ms; 18 pipeline compiles (16 in the background); p50 1.4 / p99 3.4 ms`,
      `bench · live build ${VERSION}: ✓ Low 690 fps (p99 2.9 ms) · Medium 640 fps (p99 3.1 ms)`, `bench · this change ${c7}: ✓ Low 680 fps (p99 2.9 ms) · Medium 630 fps (p99 3.1 ms)`,
    ]);
    assert.match(v.lines[0], new RegExp(`, the live build ${VERSION.replace(/\./g, '\\.')} first$`));
    if (HAS_PIL) {
      assert.deepStrictEqual(v.sheets.map((s) => path.basename(s)), ['screens-1920x1080.png']);
      assert.ok(fs.statSync(v.sheets[0]).size > 100);
    }
    assert.deepStrictEqual(checkDirs(w), []);
    assert.strictEqual(fs.readdirSync(w.teamFiles).filter((n) => HEX32.test(n)).length, 0, 'the debug builds\' preview folders were moved into the check\'s folder and went with it');
    assert.strictEqual(fs.readdirSync(w.work).filter((n) => n.startsWith('team-check-wt-')).length, 0, 'no scratch worktree is left');
  });
});

test('the PC: --pc names it; otherwise a free one, else the one seen last; none seen is no-pc with exit 1 and nothing built', async () => {
  const busy = [{ id: 'j1', kind: 'release', title: 'Checks of abc', claimedPc: PC_H }];
  await withWorld({ backend: { pcs: [pcRow(PC_H), pcRow(PC_W, { lastSeen: iso(30) })], running: busy } }, async (w, backend) => {
    const r = await check(w, backend, [w.c3]);
    assert.strictEqual(backend.jobs[0].body.targetPc, PC_W, 'Helix\'s PC is busy with a release job: War\'s free one');
    assert.strictEqual(verdict(r).status, 'done');
  });
  await withWorld({ backend: { pcs: [pcRow(PC_H, { state: { paused: true } }), pcRow(PC_W, { lastSeen: iso(3600) })] } }, async (w, backend) => {
    await check(w, backend, [w.c3]);
    assert.strictEqual(backend.jobs[0].body.targetPc, PC_H, 'nobody free: the PC seen most recently takes it when it can');
  });
  await withWorld({ backend: { pcs: [pcRow(PC_H), pcRow(PC_W)] } }, async (w, backend) => {
    await check(w, backend, [w.c3, '--pc', PC_W]);
    assert.strictEqual(backend.jobs[0].body.targetPc, PC_W);
    const r = await check(w, backend, [w.c3, '--pc', 'pc-nobody-01']);
    assert.deepStrictEqual([r.code, verdict(r).status], [1, 'no-pc']);
  });
  await withWorld({ backend: { pcs: [] } }, async (w, backend) => {
    const r = await check(w, backend, [w.c3, '--checks', 'bench']);
    assert.deepStrictEqual([r.code, verdict(r).status, verdict(r).why], [1, 'no-pc', 'no team PC was seen in the last 14 days']);
    assert.deepStrictEqual([w.logLines(), backend.jobs.length, checkDirs(w)], [[], 0, []], 'nothing built, queued or left');
  });
});

test('failures say why, exit 1 and leave nothing behind: a build that fails, a job nobody takes, a job the PC gave up, the backend refusing', async () => {
  await withWorld(async (w, backend) => {
    const r = await check(w, backend, [w.c3], { FAKE_PUBLISH: 'fail' });
    assert.deepStrictEqual([r.code, verdict(r).status], [1, 'error']);
    assert.match(verdict(r).why, /the release export of [0-9a-f]{12} failed \(exit 1\): the boot smoke failed/);
    assert.deepStrictEqual([backend.jobs.length, checkDirs(w)], [0, []]);
    const partial = await check(w, backend, [w.c3], { FAKE_PUBLISH: 'partial' });
    assert.match(verdict(partial).why, /the release export of .* failed \(exit 0\)/, 'files missing after the export');
    const dbg = await check(w, backend, [w.c3, '--checks', 'stutter'], { FAKE_PREVIEW: 'fail' });
    assert.match(verdict(dbg).why, /the debug export of [0-9a-f]{12} failed \(exit 1\): godot export failed/);
    assert.deepStrictEqual(fs.readdirSync(w.work).filter((n) => n.startsWith('team-check-wt-')), []);
  });
  await withWorld({ backend: { script: ['queued'] } }, async (w, backend) => {
    const r = await check(w, backend, [w.c3, '--max-wait', '0.01']);
    assert.deepStrictEqual([r.code, verdict(r).status], [1, 'timeout']);
    assert.match(verdict(r).why, /no team PC took the checks in time/);
    assert.ok(backend.posted('job000000001', 'cancel'), 'the job is cancelled');
    assert.deepStrictEqual(checkDirs(w), []);
  });
  await withWorld({ backend: { script: ['running', 'failed'], error: 'The player started Death Muffin.', results: null } }, async (w, backend) => {
    const r = await check(w, backend, [w.c3]);
    assert.deepStrictEqual([r.code, verdict(r).status], [1, 'failed']);
    assert.match(verdict(r).why, /The player started Death Muffin\./);
  });
  await withWorld({ backend: { createStatus: 500 } }, async (w, backend) => {
    const r = await check(w, backend, [w.c3]);
    assert.deepStrictEqual([r.code, verdict(r).status], [1, 'error']);
    assert.match(verdict(r).why, /could not queue the checks: the backend answered 500/);
    assert.deepStrictEqual(checkDirs(w), []);
  });
  await withWorld(async (w, backend) => {
    fs.rmSync(w.secretFile);
    const r = await check(w, backend, [w.c3]);
    assert.deepStrictEqual([r.code, verdict(r).status], [1, 'error']);
  });
});

test('a failed step is in the summary (exit 0), and one never reached says so', async () => {
  const results = (j) => ({ steps: [{ step: 'install', ok: false, error: 'The game stopped with code -1073740940 before its first screen.' }], files: {} });
  await withWorld({ backend: { results } }, async (w, backend) => {
    const r = await check(w, backend, [w.c3]);
    assert.strictEqual(r.code, 0, r.all);
    assert.deepStrictEqual(verdict(r).lines.slice(1), ['install: ✗ The game stopped with code -1073740940 before its first screen.', 'quit while loading: – no result']);
  });
});

test('--screen-plan: the screens step renders a plan of the caller\'s (pictures of a change for the team) at 1920x1080 unless --resolutions says, on --preset', async () => {
  await withWorld(async (w, backend) => {
    const plan = { discipline: 'ossuary', shots: [{ name: 'thralls-kit', area: 'graves', view: 'game' }, { name: 'fen_water', area: 'fen', view: 'game' }] };
    const file = path.join(w.checks, '..', 'plan.json');
    fs.writeFileSync(file, JSON.stringify(plan));
    let r = await check(w, backend, [w.c3, '--checks', 'screens', '--screen-plan', file, '--preset', 'ultra']);
    assert.strictEqual(r.code, 0, r.all);
    assert.deepStrictEqual(backend.jobs.at(-1).body.payload.screens, { plan, resolutions: ['1920x1080'], preset: 'ultra' });
    r = await check(w, backend, [w.c3, '--checks', 'screens', '--screen-plan', file, '--resolutions', '1920x1080,2560x1440']);
    assert.strictEqual(r.code, 0, r.all);
    assert.deepStrictEqual(backend.jobs.at(-1).body.payload.screens, { plan, resolutions: ['1920x1080', '2560x1440'], preset: 'high' });
    const n = backend.calls.length;
    const bad = path.join(w.checks, '..', 'bad.json');
    for (const [content, args] of [
      [null, ['--checks', 'install', '--screen-plan', file]],                                   // not the screens check
      [{ shots: [] }, ['--checks', 'screens', '--screen-plan', bad]],                            // no shot
      [{ shots: [{ name: 'A b' }] }, ['--checks', 'screens', '--screen-plan', bad]],             // a name the results cannot carry
      [{ shots: [{ name: 'x' }, { name: 'x' }] }, ['--checks', 'screens', '--screen-plan', bad]], // the same name twice
      [{ shots: Array.from({ length: 13 }, (_, i) => ({ name: `s${i}` })) }, ['--checks', 'screens', '--screen-plan', bad]],   // too many
      [null, ['--checks', 'screens', '--screen-plan', file, '--resolutions', '800x600']],        // a size the team app does not render
      [null, ['--checks', 'screens', '--preset', 'insane']],
    ]) {
      if (content) fs.writeFileSync(bad, JSON.stringify(content));
      r = await check(w, backend, [w.c3, ...args]);
      assert.strictEqual(r.code, 2, JSON.stringify(args) + r.all);
    }
    assert.strictEqual(backend.calls.length, n, 'a usage error asks the backend nothing');
  });
});

test('usage errors exit 2 with nothing done: no revision, an unknown one, an unknown check, a check twice, a soak too long, a bad PC id', async () => {
  await withWorld(async (w, backend) => {
    for (const args of [[], ['nope'], [w.c3, '--checks', 'install,dance'], [w.c3, '--checks', 'bench,bench'], [w.c3, '--checks', 'soak', '--soak-minutes', '500'], [w.c3, '--pc', '../x']]) {
      const r = await check(w, backend, args);
      assert.strictEqual(r.code, 2, JSON.stringify(args) + r.all);
    }
    assert.deepStrictEqual([backend.calls.length, w.logLines()], [0, []]);
  });
});

test('a revision without preview-godot.sh --team cannot run the debug steps, and says so', async () => {
  await withWorld({ world: { preview: false } }, async (w, backend) => {
    const r = await check(w, backend, [w.c3, '--checks', 'stutter']);
    assert.deepStrictEqual([r.code, verdict(r).status], [1, 'error']);
    assert.match(verdict(r).why, /has no --team/);
  });
});

test('the results folders keep the newest 20', async () => {
  await withWorld(async (w, backend) => {
    for (let i = 0; i < 25; i++) fs.mkdirSync(path.join(w.checks, `0000000000${String(i).padStart(2, '0')}-20261019T0000${String(i).padStart(2, '0')}Z`));
    const r = await check(w, backend, [w.c3]);
    assert.strictEqual(r.code, 0, r.all);
    const left = fs.readdirSync(w.checks);
    assert.strictEqual(left.length, 20);
    assert.ok(left.includes(path.basename(verdict(r).out)), 'this run\'s results stay');
  });
});

// ── the payload's values are the game's own ──────────────────────────────────────────────────────────────────────────────

/** The standard shot plan is in the format client/main/qa_ui_shots.gd parses: its window ids, item ids, areas and limits, read from the source. */
function assertShotPlan(plan) {
  const gd = fs.readFileSync(path.join(REPO_ROOT, 'client/main/qa_ui_shots.gd'), 'utf8');
  const windows = [...(gd.match(/^const WINDOWS := \{(.*?)^\}/ms)?.[1] ?? '').matchAll(/"([a-z]+)":/g)].map((m) => m[1]);
  const maxWait = Number(/^const MAX_WAIT_MS := (\d+)/m.exec(gd)?.[1]);
  const bagItems = [...(gd.match(/^const DEMO_BAG := \[(.*?)^\]/ms)?.[1] ?? '').matchAll(/\["([a-z_]+)", \d+/g)].map((m) => m[1]);
  const areas = Object.keys(JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'client/data/content/areas.json'), 'utf8')).AREAS);
  assert.ok(windows.includes('bag') && windows.includes('vault') && windows.includes('spellbook') && bagItems.includes('staff_moon') && areas.includes('graves') && maxWait > 0, 'the plan format\'s own lists were read');
  assert.deepStrictEqual(Object.keys(plan).sort(), ['discipline', 'shots']);
  const names = plan.shots.map((s) => s.name);
  assert.strictEqual(new Set(names).size, names.length, 'every shot has its own name');
  for (const name of ['bag-tooltip', 'character-sheet', 'spellbook', 'vault', 'map', 'hud-fight']) assert.ok(names.includes(name), `the standard shots include ${name}: the bag with an item card, the character sheet, the spellbook, the vault, the map and the HUD in a fight`);
  const known = new Set(['name', 'open', 'hover', 'area', 'wait_ms', 'clip', 'view', 'turn', 'anim', 'fight']);
  for (const s of plan.shots) {
    assert.ok(Object.keys(s).every((k) => known.has(k)), `${s.name}: only keys the plan format has`);
    assert.match(s.name, /^[a-z0-9-]{1,40}$/);
    for (const win of s.open || []) assert.ok(windows.includes(win), `${s.name}: window ${win}`);
    if (s.hover && s.hover.startsWith('item:')) assert.ok(bagItems.includes(s.hover.slice(5)), `${s.name}: ${s.hover} is in the demo bag`);
    if (s.area) assert.ok(areas.includes(s.area), `${s.name}: area ${s.area}`);
    if (s.wait_ms !== undefined) assert.ok(s.wait_ms >= 0 && s.wait_ms <= maxWait);
  }
  assert.strictEqual(plan.shots.find((s) => s.name === 'vault').area, 'chapterhouse', 'the vault opens only in the Chapterhouse');
}

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
  // each list is read (not empty) and has the entries the check's own setups use; "standard" is a size, so it must not turn up as a length (an unknown length silently becomes full)
  assert.ok(g.lengths.includes('full') && !g.lengths.includes('standard'), g.lengths.join(','));
  assert.ok(g.sizes.includes('full_party') && g.sizes.includes('standard'), g.sizes.join(','));
  assert.ok(g.presets.includes('low') && g.presets.includes('medium'), g.presets.join(','));
  assert.ok(g.rooms.includes('graves'), g.rooms.join(','));
  assert.ok(g.classes.includes(2) && g.classes.includes(11) && !g.classes.includes(5), g.classes.join(','));
});

test('every bench setup is something the game\'s benchmark can run, with exactly the values its own lists have (no unknown length that silently becomes Full)', async () => {
  const g = gameLists();
  const { parseRun } = require('./backend/benchmarks.cjs');
  await withWorld(async (w, backend) => {
    assert.strictEqual((await check(w, backend, [w.c3, '--checks', 'bench'])).code, 0);
    const setups = backend.jobs[0].body.payload.setups;
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
    }
    assert.strictEqual(setups[0].length, 'full', 'the Full length, the setup the budgets are measured on');
  });
  const one = (over) => parseRun({ clientRunId: 'game-list-run-01', preset: 'low', room: 'graves', discipline: 2, size: 'full_party', length: 'full', metrics: { avg_fps: 60 }, ...over });
  for (const preset of g.presets) assert.ok(!one({ preset }).error, `preset ${preset}`);
  for (const size of g.sizes) assert.ok(!one({ size }).error, `size ${size}`);
  for (const length of g.lengths) assert.ok(!one({ length }).error, `length ${length}`);
});

// ── publish-godot-client.sh EXPORT_ONLY ──────────────────────────────────────────────────────────────────────────────────

test('the publish\'s EXPORT_ONLY mode skips the CI gate and the lobby check, and ends after the boot smoke, before the pre-release check and anything published', () => {
  const text = fs.readFileSync(PUBLISH, 'utf8');
  const exit = text.indexOf('if [ -n "${EXPORT_ONLY:-}" ]; then');
  assert.ok(exit > text.indexOf('bash "$SMOKE"'), 'after the boot smoke');
  assert.ok(exit < text.indexOf('# --- pre-release check ---') && exit < text.indexOf('DEST="$OUT_DIR/$VERSION"') && exit < text.indexOf('mv -f "$OUT_DIR/manifest.json.tmp"'), 'before the gate, the copy and the switch');
  assert.match(text, /if \[ -z "\$\{EXPORT_ONLY:-\}" \] && \[ "\$OUT_DIR" = \/var\/www\/death-muffin\/client \] && \[ -f "\$WT\/tools\/check\/ci\.sh" \]; then/, 'no CI gate for an export');
  assert.match(text, /if \[ -z "\$\{EXPORT_ONLY:-\}" \] && \[ -d "\$LOBBY_DIR\/src" \]/, 'no lobby check for an export');
  assert.ok(!text.includes('# --- team release hook ---'), 'no release checks after a publish (B62; the retired names are hygiene terms)');
  execFileSync('bash', ['-n', PUBLISH]);
  execFileSync('bash', ['-n', CHECK]);
});

// ── team-files-prune.sh ──────────────────────────────────────────────────────────────────────────────────────────────────

test('team-files-prune.sh keeps the newest N preview folders, removes check-, gate-, view-, model-, release- and bench- folders older than the days given, and touches nothing else', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-prune-test-'));
  try {
    const dirs = [];
    for (let i = 0; i < 10; i++) {
      const d = path.join(root, crypto.randomBytes(16).toString('hex'));
      fs.mkdirSync(d);
      fs.utimesSync(d, 1_700_000_000 + i * 100, 1_700_000_000 + i * 100);
      dirs.push(d);
    }
    const upper = path.join(root, 'A'.repeat(32));
    fs.mkdirSync(upper);
    const aged = (ageDays, name) => {
      const d = path.join(root, name);
      fs.mkdirSync(d);
      const t = Date.now() / 1000 - ageDays * 86400;
      fs.utimesSync(d, t, t);
      return d;
    };
    const hex = () => crypto.randomBytes(12).toString('hex');
    const kinds = ['check', 'gate', 'view', 'model', 'release', 'bench'];
    const old = kinds.map((k) => aged(5, `${k}-${hex()}`));
    const young = kinds.map((k) => aged(1, `${k}-${hex()}`));
    const badNames = [aged(9, 'check-ABCDEF'), aged(9, `check-${'a'.repeat(23)}`), aged(9, `xcheck-${'a'.repeat(24)}`), aged(9, `other-${'a'.repeat(24)}`)];
    const r = await run('bash', [PRUNE, root], { PATH: process.env.PATH });
    assert.deepStrictEqual([r.code, r.all], [0, ''], 'it prints nothing');
    assert.deepStrictEqual(dirs.filter((d) => fs.existsSync(d)), dirs.slice(4), 'previews: the newest 6');
    assert.deepStrictEqual(old.map((d) => fs.existsSync(d)), kinds.map(() => false), 'older than 4 days: gone');
    assert.deepStrictEqual(young.map((d) => fs.existsSync(d)), kinds.map(() => true));
    assert.ok([upper, ...badNames].every((d) => fs.existsSync(d)), 'other names stay');
    assert.strictEqual((await run('bash', [PRUNE, root, '2', '0'], { PATH: process.env.PATH })).code, 0);
    assert.deepStrictEqual([dirs.filter((d) => fs.existsSync(d)).length, young.some((d) => fs.existsSync(d))], [2, false], 'keep 2, and release-days 0');
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
    for (const args of [[], [path.join(root, 'nope')], [path.join(root, 'link')], [real, 'many'], [real, '-1'], [real, '6', 'x']]) {
      const r = await run('bash', [PRUNE, ...args], { PATH: process.env.PATH });
      assert.strictEqual(r.code, 2, JSON.stringify(args));
    }
    assert.ok(fs.existsSync(victim));
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
