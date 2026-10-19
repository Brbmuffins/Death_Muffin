// Run: node --test server/death-muffin/team-gate.test.cjs
// team-gate.sh (the pre-release check: a team PC starts a build and quits it while loading before the build goes live) and its block in
// publish-godot-client.sh, against a fake backend on a loopback port and temp folders: no real backend, team-files folder, secret or PC is touched.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');

const HERE = __dirname;
const GATE = path.join(HERE, 'team-gate.sh');
const PUBLISH = path.join(HERE, 'publish-godot-client.sh');
const PRUNE = path.join(HERE, 'team-files-prune.sh');
const JOB_RUNNER = path.join(HERE, '../../teamapp/windows/JobRunner.cs');
const SECRET = 'runner-secret-0123456789-abcdef';
const DLL = 'libdmcore.windows.template_release.x86_64.dll';
const VERSION = '20261019.120000-abcdef1';
const REV = 'abcdef123456';
const GATE_DIR = /^gate-[0-9a-f]{24}$/;
const now = () => new Date().toISOString().replace(/\.\d+Z$/, '.000Z');
const ago = (s) => new Date(Date.now() - s * 1000).toISOString().replace(/\.\d+Z$/, '.000Z');
const pc = (pcId, over = {}) => ({ accountId: 1, username: 'acct', pcId, name: 'PC', version: '0.4.0', gpu: `GPU of ${pcId}`, mode: 'auto', state: {}, lastSeen: now(), ...over });
const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const okSteps = [{ step: 'install', ok: true, ms: 3080 }, { step: 'quit-loading', ok: true, ms: 3570 }];

/**
 * A fake backend: the runner's /internal/team routes with the secret check. `script` is the job's life, one entry per read of it after it is queued
 * (the last one repeats): { status, claimedPc?, result?, error? }. Records every call, and what the gate folder held when the job was queued.
 */
function fakeBackend({ pcs = [pc('pc-helix-0002')], running = [], script = [{ status: 'queued' }], createStatus = 200, teamRoot } = {}) {
  const calls = [];
  let reads = 0;
  let seenFolder = null;
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : undefined;
      calls.push({ method: req.method, url: req.url, secret: req.headers['x-team-secret'], body });
      const send = (status, obj) => { res.writeHead(status, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); };
      if (req.headers['x-team-secret'] !== SECRET) return send(404, { success: false, error: 'Not found' });
      if (req.method === 'GET' && req.url === '/internal/team/pcs') return send(200, { success: true, data: { pcs } });
      if (req.method === 'GET' && req.url === '/internal/team/jobs?status=running&limit=50') return send(200, { success: true, data: { jobs: running } });
      if (req.method === 'POST' && req.url === '/internal/team/jobs') {
        if (createStatus !== 200) return send(createStatus, { success: false, error: 'The server could not finish that.' });
        if (teamRoot) {
          const dirs = fs.readdirSync(teamRoot).filter((n) => GATE_DIR.test(n));
          seenFolder = dirs.length === 1 ? { name: dirs[0], files: fs.readdirSync(path.join(teamRoot, dirs[0])).sort() } : { dirs };
        }
        return send(200, { success: true, data: { id: 'gatejob00001' } });
      }
      if (req.method === 'GET' && req.url === '/internal/team/jobs/gatejob00001') {
        const step = script[Math.min(reads, script.length - 1)];
        reads += 1;
        return send(200, { success: true, data: { id: 'gatejob00001', kind: 'release', claimedPc: null, result: null, error: null, ...step } });
      }
      if (req.method === 'POST' && /^\/internal\/team\/jobs\/gatejob00001\/(cancel|reported)$/.test(req.url)) return send(200, { success: true, data: {} });
      return send(404, { success: false, error: 'Not found' });
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    calls, url: `http://127.0.0.1:${server.address().port}`, folder: () => seenFolder,
    created: () => calls.filter((c) => c.method === 'POST' && c.url === '/internal/team/jobs'),
    posted: (what) => calls.some((c) => c.method === 'POST' && c.url === `/internal/team/jobs/gatejob00001/${what}`),
    close: () => new Promise((r) => server.close(r)),
  })));
}

/** A stage folder with the build's files, a team-files folder and the runner's secret, in a temp folder. */
function world({ assets = true, dll = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-gate-test-'));
  const stage = path.join(root, 'stage');
  const teamFiles = path.join(root, 'team-files');
  fs.mkdirSync(stage);
  fs.mkdirSync(teamFiles);
  const content = { 'DeathMuffin.exe': Buffer.from('MZ-the-release-template'), 'DeathMuffin.pck': Buffer.from('the-pck'.repeat(50)), [DLL]: Buffer.from('the-combat-core'), 'DeathMuffin.assets.pck': Buffer.from('the-art-pack'.repeat(100)) };
  for (const [n, data] of Object.entries(content)) if ((n !== DLL || dll) && (n !== 'DeathMuffin.assets.pck' || assets)) fs.writeFileSync(path.join(stage, n), data);
  const secretFile = path.join(root, 'secret');
  fs.writeFileSync(secretFile, `${SECRET}\n`);
  return { root, stage, teamFiles, secretFile, content, gateDirs: () => fs.readdirSync(teamFiles).filter((n) => GATE_DIR.test(n)), cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

const envFor = (w, backend, over = {}) => ({
  PATH: process.env.PATH, HOME: w.root, DM_TEAM_ROOT: w.teamFiles, DM_TEAM_URL: 'https://example.invalid/death-muffin/team-files', DM_TEAM_API: backend.url,
  DM_TEAM_SECRET_FILE: w.secretFile, DM_GATE_POLL_S: '0.05', DM_GATE_CLAIM_S: '5', DM_GATE_RUN_S: '5', ...over,
});
const run = (cmd, args, env) => new Promise((resolve) => {
  const child = spawn(cmd, args, { env });
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  child.on('close', (code) => resolve({ code, out }));
});
const gate = (w, backend, over = {}) => run('bash', [GATE, w.stage, VERSION, REV], envFor(w, backend, over));

async function withWorld(opts, fn) {
  if (typeof opts === 'function') { fn = opts; opts = {}; }
  const w = world(opts.world);
  const backend = await fakeBackend({ teamRoot: w.teamFiles, ...opts.backend });
  try { await fn(w, backend); } finally { await backend.close(); w.cleanup(); }
}

test('a PC that runs the build to its first screen and quits it while loading passes it: one untargeted job, the build\'s own files, nothing left behind', async () => {
  await withWorld({ backend: { script: [{ status: 'queued' }, { status: 'running', claimedPc: 'pc-helix-0002' }, { status: 'done', claimedPc: 'pc-helix-0002', result: { steps: okSteps } }] } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /pre-release check: queued job gatejob00001 for GPU of pc-helix-0002/);
    assert.match(r.out, /pre-release check: taken by GPU of pc-helix-0002 after \d+ s/);
    assert.match(r.out, /pre-release check: passed on GPU of pc-helix-0002: the game started and quit while loading cleanly \(job gatejob00001, \d+ s\)/);
    const [created] = backend.created();
    const job = created.body;
    assert.deepStrictEqual([job.kind, job.title, job.weightS, job.ttlS, job.targetPc, job.supersede], ['release', `Pre-release check of ${VERSION}`, 60, 900, undefined, undefined], 'one job any team PC may take');
    assert.deepStrictEqual(job.payload.steps, ['install', 'quit-loading']);
    assert.deepStrictEqual([job.payload.version, job.payload.rev, job.payload.godotVersion, job.payload.args], [VERSION, REV, '4.7.2.stable', []]);
    assert.strictEqual(job.payload.builds.length, 1);
    const { label, files } = job.payload.builds[0];
    assert.strictEqual(label, 'release');
    const folder = backend.folder();
    assert.match(folder.name, GATE_DIR);
    assert.deepStrictEqual(folder.files, ['DeathMuffin.assets.pck', 'DeathMuffin.exe', 'DeathMuffin.pck', DLL], 'the files were in the gate folder when the job was queued');
    for (const f of files) {
      assert.strictEqual(f.url, `https://example.invalid/death-muffin/team-files/${folder.name}/${f.name}`);
      assert.deepStrictEqual([f.sha256, f.bytes], [sha256(w.content[f.name]), w.content[f.name].length], f.name);
    }
    const keys = Object.fromEntries(files.filter((f) => f.cacheKey).map((f) => [f.name, f.cacheKey]));
    assert.deepStrictEqual(keys, { 'DeathMuffin.exe': `godot-release-${sha256(w.content['DeathMuffin.exe']).slice(0, 16)}`, 'DeathMuffin.assets.pck': `assets-${sha256(w.content['DeathMuffin.assets.pck']).slice(0, 16)}` }, 'the same cache keys as the release checks');
    assert.deepStrictEqual(w.gateDirs(), [], 'the folder is removed');
    assert.ok(backend.posted('reported'), 'marked reported: it is never posted to #build-alerts');
    assert.ok(backend.calls.every((c) => c.secret === SECRET));
  });
});

test('the game failing on the PC stops the publish (exit 10) with the step\'s words and the graphics card; a download that failed is no verdict', async () => {
  const crash = { steps: [{ step: 'install', ok: false, error: 'The game stopped with code -1073740940 before its first screen.' }, { step: 'quit-loading', ok: true }] };
  await withWorld({ backend: { script: [{ status: 'running', claimedPc: 'pc-helix-0002' }, { status: 'done', claimedPc: 'pc-helix-0002', result: crash }] } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.strictEqual(r.code, 10, r.out);
    assert.match(r.out, /pre-release check: FAILED on GPU of pc-helix-0002: install: The game stopped with code -1073740940 before its first screen\. \(job gatejob00001\)/);
    assert.deepStrictEqual(w.gateDirs(), []);
  });
  const download = { steps: [{ step: 'install', ok: false, error: 'The release build could not be downloaded: The remote name could not be resolved.' }, { step: 'quit-loading', ok: false, error: 'The release build could not be downloaded: The remote name could not be resolved.' }] };
  await withWorld({ backend: { script: [{ status: 'done', claimedPc: 'pc-helix-0002', result: download }] } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /pre-release check: no verdict: the job gatejob00001 done; publishing without it/);
  });
  await withWorld({ backend: { script: [{ status: 'failed', claimedPc: 'pc-helix-0002', error: 'The player started Death Muffin.' }] } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /no verdict: the job gatejob00001 failed \(The player started Death Muffin\.\)/);
  });
});

test('a quit-while-loading crash report fails it too', async () => {
  const crash = { steps: [{ step: 'install', ok: true }, { step: 'quit-loading', ok: false, error: 'The game quit but left a crash report (crash_pending.json).' }] };
  await withWorld({ backend: { script: [{ status: 'done', claimedPc: 'pc-helix-0002', result: crash }] } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.strictEqual(r.code, 10, r.out);
    assert.match(r.out, /FAILED on GPU of pc-helix-0002: quit-loading: The game quit but left a crash report/);
  });
});

test('no PC that can take it now: nothing is queued or waited for, and the line says why', async () => {
  const pcs = [
    pc('pc-old-00001', { lastSeen: ago(600) }),
    pc('pc-paused-01', { state: { paused: true } }),
    pc('pc-gaming-01', { state: { gameRunning: true } }),
    pc('pc-laptop-01', { state: { onBattery: true } }),
    pc('pc-busy-0001'),
  ];
  const running = [{ id: 'j1', kind: 'release', title: 'Release checks of 20261019.110000-1234567', claimedPc: 'pc-busy-0001' }];
  await withWorld({ backend: { pcs, running } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /pre-release check: no team PC can take it now \(GPU of pc-old-00001 not seen lately, GPU of pc-paused-01 paused, GPU of pc-gaming-01 playing Death Muffin, GPU of pc-laptop-01 on battery, GPU of pc-busy-0001 busy with Release checks of 20261019\.110000-1234567\): skipped/);
    assert.deepStrictEqual(backend.created(), []);
    assert.deepStrictEqual(w.gateDirs(), []);
  });
  await withWorld({ backend: { pcs: [] } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.match(r.out, /pre-release check: no team PC can take it now: skipped/);
  });
  // a PC busy with a short job (a screenshots job) is still asked: it is free in a minute
  await withWorld({ backend: { pcs: [pc('pc-shots-001')], running: [{ id: 'j2', kind: 'shots', title: 'Screenshots', claimedPc: 'pc-shots-001' }], script: [{ status: 'done', claimedPc: 'pc-shots-001', result: { steps: okSteps } }] } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.match(r.out, /passed on GPU of pc-shots-001/);
  });
});

test('no PC takes it in time, or the PC does not finish in time: the job is cancelled, the folder removed, and the publish goes on', async () => {
  await withWorld({ backend: { script: [{ status: 'queued' }] } }, async (w, backend) => {
    const r = await gate(w, backend, { DM_GATE_CLAIM_S: '0.3' });
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /pre-release check: no verdict: no team PC took it within 0 s; publishing without it/);
    assert.ok(backend.posted('cancel'));
    assert.deepStrictEqual(w.gateDirs(), []);
  });
  await withWorld({ backend: { script: [{ status: 'running', claimedPc: 'pc-helix-0002' }] } }, async (w, backend) => {
    const r = await gate(w, backend, { DM_GATE_RUN_S: '0.3' });
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /no verdict: the PC did not finish within 0 s; publishing without it/);
    assert.ok(backend.posted('cancel'));
    assert.deepStrictEqual(w.gateDirs(), []);
  });
});

test('the gate\'s own trouble never stops a release: no secret, the backend down or refusing, a build without its DLL, a missing team folder', async () => {
  await withWorld(async (w, backend) => {
    fs.rmSync(w.secretFile);
    const r = await gate(w, backend);
    assert.deepStrictEqual([r.code, /cannot read the runner's secret .*: skipped/.test(r.out)], [0, true], r.out);
  });
  await withWorld(async (w, backend) => {
    const r = await gate(w, backend, { DM_TEAM_API: 'http://127.0.0.1:9' });
    assert.deepStrictEqual([r.code, /could not ask for the team PCs \(the backend could not be reached/.test(r.out)], [0, true], r.out);
  });
  await withWorld({ backend: { createStatus: 500 } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.deepStrictEqual([r.code, /could not queue it \(the backend answered 500: The server could not finish that\.\): skipped/.test(r.out), w.gateDirs().length], [0, true, 0], r.out);
  });
  await withWorld({ world: { dll: false } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.deepStrictEqual([r.code, /could not put the build's files in gate-[0-9a-f]{24} \(the build has no libdmcore/.test(r.out), w.gateDirs().length, backend.created().length], [0, true, 0, 0], r.out);
  });
  await withWorld(async (w, backend) => {
    const r = await gate(w, backend, { DM_TEAM_ROOT: path.join(w.root, 'nowhere') });
    assert.deepStrictEqual([r.code, /the team-files folder .* is missing: skipped/.test(r.out)], [0, true], r.out);
  });
  await withWorld({ world: { assets: false }, backend: { script: [{ status: 'done', claimedPc: 'pc-helix-0002', result: { steps: okSteps } }] } }, async (w, backend) => {
    const r = await gate(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.deepStrictEqual(backend.created()[0].body.payload.builds[0].files.map((f) => f.name), ['DeathMuffin.exe', 'DeathMuffin.pck', DLL], 'a build without an art pack sends the three files');
  });
});

test('a stop from the publish\'s timeout cancels the job and removes the folder, with no verdict', async () => {
  await withWorld({ backend: { script: [{ status: 'running', claimedPc: 'pc-helix-0002' }] } }, async (w, backend) => {
    const r = await run('timeout', ['2', 'bash', GATE, w.stage, VERSION, REV], envFor(w, backend, { DM_GATE_RUN_S: '60' }));
    assert.strictEqual(r.code, 124, r.out);   // timeout's own code: the publish carries on (only 10 stops it)
    assert.ok(backend.posted('cancel'), r.out);
    assert.deepStrictEqual(w.gateDirs(), []);
  });
});

test('every failure of the game in the app\'s boot steps begins "The game ", and its download failures do not', () => {
  const cs = fs.readFileSync(JOB_RUNNER, 'utf8');
  const a = cs.indexOf('async Task<StepOutcome> StepBootAsync(');
  const b = cs.indexOf('static void Fail(StepOutcome o', a);
  assert.ok(a > 0 && b > a, 'JobRunner.cs has StepBootAsync');
  const fails = [...cs.slice(a, b).matchAll(/Fail\(o, "([^"]*)"/g)].map((m) => m[1]);
  assert.ok(fails.length >= 6, `the boot step's failures were read (${fails.length})`);
  for (const f of fails) assert.ok(f.startsWith('The game '), f);
  const download = /"The " \+ label \+ " build could not be downloaded: "/;
  assert.match(cs, download, 'a download failure names the build, not the game');
});

// ── its block in publish-godot-client.sh ─────────────────────────────────────────────────────────────────────────────

const gateBlock = () => {
  const text = fs.readFileSync(PUBLISH, 'utf8');
  const a = text.indexOf('# --- pre-release check ---');
  const b = text.indexOf('# --- end pre-release check ---');
  assert.ok(a > 0 && b > a, 'the publish script has the gate block between its markers');
  return text.slice(a, b);
};

/** A git repository with two commits whose second has a stand-in team-gate.sh that exits with $FAKE_GATE_RC; the block runs in a worktree-like folder of it. */
function gateRepo(root) {
  const dir = path.join(root, 'repo');
  fs.mkdirSync(path.join(dir, 'server/death-muffin'), { recursive: true });
  const git = (...a) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', ...a], { encoding: 'utf8' }).trim();
  git('init', '-q');
  fs.writeFileSync(path.join(dir, 'README'), 'one');
  git('add', 'README');
  git('commit', '-q', '-m', 'one');
  const c1 = git('rev-parse', '--short=12', 'HEAD');
  fs.writeFileSync(path.join(dir, 'server/death-muffin/team-gate.sh'), '#!/usr/bin/env bash\necho "the gate ran with $1 $2 $3"\nexit "${FAKE_GATE_RC:-0}"\n');
  git('add', 'server/death-muffin/team-gate.sh');
  git('commit', '-q', '-m', 'two');
  const c2 = git('rev-parse', '--short=12', 'HEAD');
  return { dir, c1, c2 };
}

const runBlock = (g, vars, extra = {}) => run('bash', ['-c', `set -euo pipefail\nSTEP_T=$SECONDS; took() { echo "== $1: $(( SECONDS - STEP_T )) s"; STEP_T=$SECONDS; }\nREPO="$G_REPO"; WT="$G_WT"; SHA="$G_SHA"; VERSION=v1; STAGE=/stage; OUT_DIR="$G_OUT"; PREV_REV="$G_PREV"\n${gateBlock()}\necho "block finished"`], {
  PATH: process.env.PATH, G_REPO: g.dir, G_WT: vars.wt ?? g.dir, G_SHA: vars.sha, G_OUT: vars.out ?? '/var/www/death-muffin/client', G_PREV: vars.prev ?? '', ...extra,
});

test('the publish: only exit 10 stops it; the live folder runs the gate, the test channel, TEAM_GATE=off, a rollback and an older revision do not', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-gate-block-'));
  try {
    const g = gateRepo(root);
    const pass = await runBlock(g, { sha: g.c2, prev: g.c1 });
    assert.deepStrictEqual([pass.code, pass.out.includes(`the gate ran with /stage v1 ${g.c2}`), /== pre-release check: \d+ s\nblock finished/.test(pass.out)], [0, true, true], pass.out);
    const failed = await runBlock(g, { sha: g.c2, prev: g.c1 }, { FAKE_GATE_RC: '10' });
    assert.strictEqual(failed.code, 1, failed.out);
    assert.match(failed.out, new RegExp(`Refusing to publish ${g.c2}: the game failed on a team PC \\(the line above\\)\\. TEAM_GATE=off publishes it anyway\\.`));
    assert.ok(!failed.out.includes('block finished'));
    for (const rc of ['1', '2', '124', '137']) {
      const other = await runBlock(g, { sha: g.c2, prev: g.c1 }, { FAKE_GATE_RC: rc });
      assert.deepStrictEqual([other.code, other.out.trim().endsWith('block finished')], [0, true], `exit ${rc} lets the publish go on`);
    }
    const quiet = [
      [{ sha: g.c2, prev: g.c1, out: '/var/www/death-muffin/client-test' }, {}],
      [{ sha: g.c2, prev: g.c1 }, { TEAM_GATE: 'off' }],
      [{ sha: g.c1, prev: g.c2 }, {}],
    ];
    for (const [vars, extra] of quiet) {
      const r = await runBlock(g, vars, { FAKE_GATE_RC: '10', ...extra });
      assert.deepStrictEqual([r.code, r.out.includes('the gate ran')], [0, false], JSON.stringify([vars, extra, r.out]));
    }
    const rollback = await runBlock(g, { sha: g.c1, prev: g.c2 });
    assert.match(rollback.out, /pre-release check: .* is not newer than the build that was live \(.*\): skipped \(rollback\?\)/);
    const forced = await runBlock(g, { sha: g.c2, prev: g.c1, out: '/tmp/a-test-folder' }, { TEAM_GATE: '1' });
    assert.ok(forced.out.includes('the gate ran'), 'TEAM_GATE=1 forces it for another folder');
    const first = await runBlock(g, { sha: g.c2, prev: '' });
    assert.ok(first.out.includes('the gate ran'), 'a first publish');
    const older = await runBlock(g, { sha: g.c1, prev: '', wt: root }, { FAKE_GATE_RC: '10' });
    assert.deepStrictEqual([older.code, older.out.trim()], [0, 'block finished'], 'a revision from before the gate (its worktree has no team-gate.sh) publishes as before');
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the publish runs the gate after the boot smoke and before the switch, and the clean-up rule covers a gate folder a killed gate left', () => {
  const text = fs.readFileSync(PUBLISH, 'utf8');
  const at = text.indexOf('# --- pre-release check ---');
  assert.ok(at > text.indexOf('bash "$SMOKE"') && at > text.indexOf('PREV_REV=$('), 'after the boot smoke and after the live revision is read');
  assert.ok(at < text.indexOf('mv -f "$OUT_DIR/manifest.json.tmp" "$OUT_DIR/manifest.json"') && at < text.indexOf('DEST="$OUT_DIR/$VERSION"'), 'before anything is copied or switched');
  assert.ok(text.includes('TEAM_GATE TEAM_RELEASE'));
  const prune = fs.readFileSync(PRUNE, 'utf8');
  assert.match(prune, /\(release\|bench\|gate\)-\[0-9a-f\]\{24\}/);
  execFileSync('bash', ['-n', GATE]);
  execFileSync('bash', ['-n', PUBLISH]);
});
