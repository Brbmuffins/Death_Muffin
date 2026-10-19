// Run: node --test server/death-muffin/team-release.test.cjs
// team-release.sh (the team PCs' release checks of a new release), team-files-prune.sh and the hook block of publish-godot-client.sh, against a fake backend on a
// loopback port, a stand-in preview-godot.sh in a temp git repository and temp folders: no real manifest, team-files folder, secret, backend or Godot is touched.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const crypto = require('node:crypto');
const { spawn, execFileSync } = require('node:child_process');

const HERE = __dirname;
const RELEASE = path.join(HERE, 'team-release.sh');
const PRUNE = path.join(HERE, 'team-files-prune.sh');
const PUBLISH = path.join(HERE, 'publish-godot-client.sh');
const SECRET = 'runner-secret-0123456789-abcdef';
const DLL = 'libdmcore.windows.template_release.x86_64.dll';
const VERSION = '20261019.120000-abcdef1';
const HEX32 = /^[0-9a-f]{32}$/;
const RELEASE_DIR = /^release-[0-9a-f]{24}$/;   // a release's folder in team-files (a preview build's is 32 hex)
const PC_W = 'pc-war-0003';
const PC_H = 'pc-helix-0002';
const PC_M = 'pc-muffins-0001';
const DEBUG_NAMES = ['DeathMuffinDebug.exe', 'DeathMuffinDebug.pck', DLL, 'DeathMuffin.assets.pck'];

const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const pcRow = (pcId, accountId = 1) => ({ accountId, username: `acct${accountId}`, pcId, name: 'PC', version: '0.2.0', gpu: 'GPU', mode: 'ask', state: {}, lastSeen: '2026-10-19T12:00:00.000Z' });

/** A stand-in for preview-godot.sh --team: it makes what the real one makes (a 32-hex folder in the team root) and prints what it prints, or fails the way FAKE_MODE says. */
const FAKE_PREVIEW = [
  '#!/usr/bin/env bash',
  'set -euo pipefail',
  'JOB=${1:-}',
  '[[ "$JOB" =~ ^[0-9a-f]{6}$ ]] || { echo "bad job id"; exit 2; }',
  '[ "${2:-}" = --team ] || { echo "this stand-in only knows --team"; exit 2; }',
  'TOP=$(git rev-parse --show-toplevel)',
  '[ -z "${FAKE_LOG:-}" ] || printf "%s %s %s %s %s %s\\n" "$TOP" "$(git rev-parse --short=12 HEAD)" "$(nice)" "$DM_TEAM_ROOT" "$DM_TEAM_URL" "$CLIENT_MANIFEST" > "$FAKE_LOG"',
  'case "${FAKE_MODE:-ok}" in',
  '  fail) echo "godot export failed"; exit 1;;',
  '  slow) sleep 300 & echo "$!" > "$FAKE_PID"; wait;;',
  '  noline) echo "all done, but no list"; exit 0;;',
  '  garbage) echo "TEAMFILES: {not json"; exit 0;;',
  'esac',
  'DIR=$(head -c16 /dev/urandom | od -An -tx1 | tr -d " \\n")',
  'mkdir -m 755 "$DM_TEAM_ROOT/$DIR"',
  'python3 - "$DM_TEAM_ROOT/$DIR" "$DM_TEAM_URL/$DIR" "${FAKE_MODE:-ok}" "$CLIENT_MANIFEST" <<\'PY\'',
  'import hashlib, json, os, sys',
  'dest, base, mode, manifest = sys.argv[1:5]',
  'names = ["DeathMuffinDebug.exe", "DeathMuffinDebug.pck", "libdmcore.windows.template_release.x86_64.dll", "DeathMuffin.assets.pck"]',
  'if mode == "partial":',
  '    names = [n for n in names if not n.endswith(".dll")]',
  'if mode == "switch":   # another publish goes live while the build runs',
  '    m = json.load(open(manifest)); m["version"] = "20261019.130000-fffffff"; json.dump(m, open(manifest, "w"))',
  'out = []',
  'for n in names:',
  '    data = (n + " of the debug build").encode()',
  '    if not (mode == "missingfile" and n == "DeathMuffinDebug.pck"):',
  '        open(os.path.join(dest, n), "wb").write(data)',
  '    sha = hashlib.sha256(data).hexdigest()',
  '    e = {"name": n, "url": base + "/" + n, "sha256": sha, "bytes": len(data)}',
  '    if n == "DeathMuffinDebug.exe": e["cacheKey"] = "godot-debug-" + sha[:16]',
  '    if n == "DeathMuffin.assets.pck": e["cacheKey"] = "assets-" + sha[:16]',
  '    out.append(e)',
  'print("TEAMFILES: " + json.dumps(out, separators=(",", ":")))',
  'PY',
].join('\n') + '\n';
/** What a revision from before preview-godot.sh knew --team does: it would write a preview zip (the hook must never run it). */
const OLD_PREVIEW = '#!/usr/bin/env bash\necho "this old script writes a zip and knows no team build"\ntouch "$FAKE_OLD_RAN"\n';

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

const git = (dir, ...a) => execFileSync('git', ['-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', '-c', 'commit.gpgsign=false', ...a], { encoding: 'utf8' }).trim();

/**
 * A git repository with three commits: one without the scripts, one with them (team-release.sh, team-files-prune.sh and a preview-godot.sh of the kind `preview` says:
 * 'fake' knows --team, 'old' does not, 'none' has none), one after. Returns { dir, c1, c2, c3 } (12-character revisions).
 */
function repo(root, preview = 'fake') {
  const dir = path.join(root, 'repo');
  fs.mkdirSync(path.join(dir, 'server/death-muffin/discord-agent'), { recursive: true });
  git(dir, 'init', '-q');
  fs.writeFileSync(path.join(dir, 'README'), 'one');
  git(dir, 'add', 'README');
  git(dir, 'commit', '-q', '-m', 'one');
  const c1 = git(dir, 'rev-parse', '--short=12', 'HEAD');
  const add = ['server/death-muffin/team-release.sh', 'server/death-muffin/team-files-prune.sh'];
  for (const f of add) fs.copyFileSync(path.join(HERE, path.basename(f)), path.join(dir, f));
  fs.mkdirSync(path.join(dir, 'tools/check'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'tools/check/prep.sh'), '#!/usr/bin/env bash\n');   // the revision's setup script (its path is handed to the build)
  add.push('tools/check/prep.sh');
  if (preview !== 'none') {
    fs.writeFileSync(path.join(dir, 'server/death-muffin/discord-agent/preview-godot.sh'), preview === 'old' ? OLD_PREVIEW : FAKE_PREVIEW);
    add.push('server/death-muffin/discord-agent/preview-godot.sh');
  }
  git(dir, 'add', ...add);
  git(dir, 'commit', '-q', '-m', 'two');
  const c2 = git(dir, 'rev-parse', '--short=12', 'HEAD');
  fs.writeFileSync(path.join(dir, 'README'), 'three');
  git(dir, 'add', 'README');
  git(dir, 'commit', '-q', '-m', 'three');
  const c3 = git(dir, 'rev-parse', '--short=12', 'HEAD');
  return { dir, c1, c2, c3 };
}

/** The live client's folder (manifest + the version folder), a team-files folder, the runner's secret and the checkout the debug build is made from, in a temp folder. */
function world({ assets = true, dll = true, exe = true, teamRoot, version = VERSION, preview = 'fake', revOf = 'c3', manifestOver = (m) => m } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-release-test-'));
  const g = repo(root, preview);
  const rev = g[revOf];
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
  const work = path.join(root, 'work');
  fs.mkdirSync(work);
  const secretFile = path.join(root, 'secret');
  fs.writeFileSync(secretFile, `${SECRET}\n`);
  return {
    root, client, build, teamFiles, work, secretFile, content, names, repo: g, rev, manifest: path.join(client, 'manifest.json'), fakeLog: path.join(root, 'fake.log'), fakePid: path.join(root, 'fake.pid'),
    cleanup: () => fs.rmSync(root, { recursive: true, force: true }),
  };
}

const envFor = (w, backend, over = {}) => ({
  PATH: process.env.PATH, HOME: w.root, DM_TEAM_MANIFEST: w.manifest, DM_TEAM_ROOT: w.teamFiles, DM_TEAM_URL: 'https://example.invalid/death-muffin/team-files',
  DM_TEAM_API: backend.url, DM_TEAM_SECRET_FILE: w.secretFile, DM_TEAM_REPO: w.repo.dir, DM_TEAM_WORK: w.work, DM_TEAM_BUILD_TIMEOUT: '60', FAKE_LOG: w.fakeLog, FAKE_PID: w.fakePid,
  FAKE_OLD_RAN: path.join(w.root, 'old-script-ran'), ...over,
});

const run = (cmd, args, env, opts = {}) => new Promise((resolve) => {
  const child = spawn(cmd, args, { env, ...opts });
  let out = '';
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { out += d; });
  child.on('close', (code) => resolve({ code, out }));
});
const release = (w, backend, arg = VERSION, over = {}) => run('bash', [RELEASE, arg], envFor(w, backend, over));
const folders = (w) => fs.readdirSync(w.teamFiles).filter((n) => RELEASE_DIR.test(n));
const previews = (w) => fs.readdirSync(w.teamFiles).filter((n) => HEX32.test(n));
const scratch = (w) => fs.readdirSync(w.work).filter((n) => n.startsWith('team-release-wt-'));
const worktrees = (w) => git(w.repo.dir, 'worktree', 'list', '--porcelain').split('\n').filter((l) => l.startsWith('worktree ')).length;
const niceNow = () => Number(execFileSync('nice', { encoding: 'utf8' }).trim());
/** Nothing of a build is left behind: no scratch worktree (folder or git's record), no stray preview folder. */
const assertClean = (w, what = '') => {
  assert.deepStrictEqual([scratch(w), worktrees(w), previews(w)], [[], 1, []], `${what}: no scratch worktree and no stray preview folder is left`);
};

/** Run `fn` with a fake backend and a world, cleaning both up. */
async function withWorld(opts, fn) {
  if (typeof opts === 'function') { fn = opts; opts = {}; }
  const backend = await fakeBackend(opts.backend);
  const w = world(opts.world);
  try { await fn(w, backend); } finally { await backend.close(); w.cleanup(); }
}

/** The standard shot plan is in the format client/main/qa_ui_shots.gd parses: its window ids, item ids, areas and limits, read from the source. */
function assertShotPlan(plan) {
  const gd = fs.readFileSync(path.join(REPO_ROOT, 'client/main/qa_ui_shots.gd'), 'utf8');
  const windows = [...(gd.match(/^const WINDOWS := \{(.*?)^\}/ms)?.[1] ?? '').matchAll(/"([a-z]+)":/g)].map((m) => m[1]);
  const maxWait = Number(/^const MAX_WAIT_MS := (\d+)/m.exec(gd)?.[1]);
  const bagItems = [...(gd.match(/^const DEMO_BAG := \[(.*?)^\]/ms)?.[1] ?? '').matchAll(/\["([a-z_]+)", \d+/g)].map((m) => m[1]);
  const areas = Object.keys(JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'client/data/content/areas.json'), 'utf8')).AREAS);
  assert.ok(windows.includes('bag') && windows.includes('vault') && windows.includes('spellbook') && bagItems.includes('staff_moon') && areas.includes('graves') && maxWait >= 4000, 'the plan format\'s own lists were read');
  assert.deepStrictEqual(Object.keys(plan).sort(), ['discipline', 'shots']);
  assert.deepStrictEqual(plan.shots.map((s) => s.name), ['bag-tooltip', 'character-sheet', 'spellbook', 'vault', 'map', 'hud-fight'], 'the standard shots: the bag with an item card, the character sheet, the spellbook, the vault, the map and the HUD in a fight');
  const known = new Set(['name', 'open', 'hover', 'area', 'wait_ms', 'clip', 'view', 'turn', 'anim', 'fight']);
  for (const s of plan.shots) {
    assert.ok(Object.keys(s).every((k) => known.has(k)), `${s.name}: only keys the plan format has`);
    assert.match(s.name, /^[a-z0-9-]{1,40}$/);
    for (const w of s.open || []) assert.ok(windows.includes(w), `${s.name}: window ${w}`);
    if (s.hover) assert.match(s.hover, /^(item:[a-z_]+|worn:[a-z_]+|belt:[a-z_]+|\d+)$/);
    if (s.hover && s.hover.startsWith('item:')) assert.ok(bagItems.includes(s.hover.slice(5)), `${s.name}: ${s.hover} is in the demo bag`);
    if (s.area) assert.ok(areas.includes(s.area), `${s.name}: area ${s.area}`);
    if (s.wait_ms !== undefined) assert.ok(s.wait_ms >= 0 && s.wait_ms <= maxWait);
  }
  assert.strictEqual(plan.shots.find((s) => s.name === 'vault').area, 'chapterhouse', 'the vault opens only in the Chapterhouse');
}

// ── team-release.sh ──────────────────────────────────────────────────────────────────────────────────────────────────────

test('a release gets one release job per team PC seen in the last 14 days, targeted at it, with the release files hard-linked and the debug build moved into team-files', async () => {
  await withWorld(async (w, backend) => {
    const r = await release(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, new RegExp(`team release: building the debug export of ${w.rev} \\(preview-godot\\.sh --team, nice 10, at most 60 s\\)`));
    assert.match(r.out, /team release: the debug export is ready \(\d+ s\)/);
    assert.match(r.out, new RegExp(`team release: 20261019\\.120000-abcdef1 \\(${w.rev}\\): release checks queued for 2 team PCs \\(pc-war-0003 job job000000001, pc-helix-0002 job job000000002; with the debug build\\); files in team-files/release-[0-9a-f]{24}; done in \\d+ s`));
    assert.match(folders(w)[0], RELEASE_DIR, 'the release\'s folder is release-<24 hex> directly under team-files');
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
      assert.strictEqual(body.supersede, true, 'a PC is only ever offered the newest release\'s checks');
      assert.deepStrictEqual([body.kind, body.title, body.weightS, body.ttlS], ['release', `Release checks of ${VERSION}`, 2400, 3 * 86400]);
      const p = body.payload;
      // the shape teamapp/windows/JobPlan.cs ParseRelease reads
      assert.deepStrictEqual(Object.keys(p), ['version', 'rev', 'godotVersion', 'builds', 'steps', 'setups', 'screens', 'soak', 'args']);
      assert.deepStrictEqual([p.version, p.rev, p.godotVersion, p.args, p.soak], [VERSION, w.rev, '4.7.2.stable', [], { minutes: 30 }]);
      assert.deepStrictEqual(p.builds.map((b) => [b.label, Object.keys(b)]), [['release', ['label', 'files']], ['debug', ['label', 'files']]]);
      assert.deepStrictEqual(Object.keys(p.screens), ['plan', 'resolutions', 'preset']);
      assert.deepStrictEqual([p.screens.resolutions, p.screens.preset], [['1920x1080', '2560x1440', '3840x2160', '3440x1440'], 'high']);
      assertShotPlan(p.screens.plan);
      const releaseFiles = p.builds[0].files;
      const debugFiles = p.builds[1].files;
      assert.deepStrictEqual(p.steps, ['install', 'quit-loading', 'screens', 'stutter', 'bench', 'soak']);
      assert.deepStrictEqual(p.setups, [
        { preset: 'low', room: 'graves', class: 2, size: 'full_party', length: 'full' },
        { preset: 'medium', room: 'graves', class: 2, size: 'full_party', length: 'full' },
      ]);
      assert.deepStrictEqual(releaseFiles.map((f) => f.name), ['DeathMuffin.exe', 'DeathMuffin.pck', DLL, 'DeathMuffin.assets.pck']);
      for (const f of releaseFiles) {
        assert.strictEqual(f.url, `https://example.invalid/death-muffin/team-files/${dir}/${f.name}`);
        assert.match(f.url, /^https:\/\/example\.invalid\/death-muffin\/team-files\/release-[0-9a-f]{24}\/[A-Za-z0-9._-]+$/, 'a safe path below team-files: what the app\'s address check takes');
        assert.ok(f.url.length < 400);
        assert.strictEqual(f.sha256, sha256(w.content[f.name]), `${f.name}: the manifest's hash`);
        assert.strictEqual(f.bytes, w.content[f.name].length);
      }
      const key = Object.fromEntries(releaseFiles.map((f) => [f.name, f.cacheKey]));
      assert.deepStrictEqual(key, { 'DeathMuffin.exe': `godot-release-${sha256(w.content['DeathMuffin.exe']).slice(0, 16)}`, 'DeathMuffin.pck': undefined, [DLL]: undefined, 'DeathMuffin.assets.pck': `assets-${sha256(w.content['DeathMuffin.assets.pck']).slice(0, 16)}` });
      // the debug build: its own list, addresses inside the release folder
      assert.deepStrictEqual(debugFiles.map((f) => f.name), DEBUG_NAMES);
      for (const f of debugFiles) {
        const data = Buffer.from(`${f.name} of the debug build`);
        assert.strictEqual(f.url, `https://example.invalid/death-muffin/team-files/${dir}/debug/${f.name}`);
        assert.ok(f.url.length < 400);
        assert.deepStrictEqual([f.sha256, f.bytes], [sha256(data), data.length]);
        assert.deepStrictEqual(fs.readFileSync(path.join(w.teamFiles, dir, 'debug', f.name)), data, `${f.name} is where its address says`);
      }
      assert.strictEqual(debugFiles[0].cacheKey, `godot-debug-${sha256(Buffer.from('DeathMuffinDebug.exe of the debug build')).slice(0, 16)}`, 'the build\'s own cache keys carry over');
      assert.strictEqual(debugFiles[3].cacheKey, `assets-${sha256(Buffer.from('DeathMuffin.assets.pck of the debug build')).slice(0, 16)}`);
      const keyed = new Map();   // the app refuses one cache name for two different files across the builds
      for (const f of [...releaseFiles, ...debugFiles]) if (f.cacheKey) { assert.ok(!keyed.has(f.cacheKey) || keyed.get(f.cacheKey) === f.sha256, `cache name ${f.cacheKey} names one file`); keyed.set(f.cacheKey, f.sha256); }
    }
    // the release files are the live build's own (hard links: no copy of the 500 MB pack), readable by the web server
    assert.deepStrictEqual(fs.readdirSync(path.join(w.teamFiles, dir)).sort(), [...w.names, 'debug'].sort());
    for (const n of w.names) {
      const src = fs.statSync(path.join(w.build, n));
      const dst = fs.statSync(path.join(w.teamFiles, dir, n));
      assert.strictEqual(dst.ino, src.ino, `${n} is a hard link`);
      assert.ok((dst.mode & 0o044) === 0o044, `${n} is world-readable`);
    }
    assert.strictEqual(fs.statSync(path.join(w.teamFiles, dir)).mode & 0o777, 0o755);
    assert.strictEqual(fs.statSync(path.join(w.teamFiles, dir, 'debug')).mode & 0o777, 0o755);
    assert.ok(!r.out.includes(SECRET), 'the secret is never printed');
    // the debug build was made from a scratch worktree of the published revision, under nice, with the team folder and the live manifest named; the worktree is gone again
    const [top, rev, nice, teamRoot, url, manifest] = fs.readFileSync(w.fakeLog, 'utf8').trim().split(' ');
    assert.ok(top.startsWith(path.join(w.work, 'team-release-wt-')), top);
    assert.deepStrictEqual([rev, teamRoot, url, manifest], [w.rev, w.teamFiles, 'https://example.invalid/death-muffin/team-files', w.manifest]);
    assert.strictEqual(Number(nice), Math.min(19, niceNow() + 10), 'the build runs under nice -n 10');
    assertClean(w, 'after the build');
  });
});

test('the build may be named by its revision (12 or 40 hex characters, or 7) as well as by its version; any other build is skipped without a request or a build', async () => {
  for (const form of [(rev) => rev, (rev) => `${rev}00112233445566778899aabbccdd`.slice(0, 40), (rev) => rev.slice(0, 7), () => VERSION]) {
    await withWorld(async (w, backend) => {
      const arg = form(w.rev);
      const r = await release(w, backend, arg);
      assert.strictEqual(r.code, 0, `${arg}: ${r.out}`);
      assert.strictEqual(backend.jobs().length, 2, arg);
    });
  }
  for (const arg of ['20261019.130000-0000000', '123456789abc', 'abcdef', 'abcdef9']) {
    await withWorld(async (w, backend) => {
      const r = await release(w, backend, arg);
      assert.strictEqual(r.code, 0, r.out);
      assert.match(r.out, new RegExp(`the live build is 20261019\\.120000-abcdef1 \\(${w.rev}\\), not `));
      assert.deepStrictEqual([backend.calls.length, folders(w).length, fs.existsSync(w.fakeLog)], [0, 0, false], `${arg}: nothing asked, nothing linked, nothing built`);
    });
  }
});

test('no team PC seen means no job, no folder and no debug build; one PC under two accounts gets one job', async () => {
  await withWorld({ backend: { pcs: [] } }, async (w, backend) => {
    const r = await release(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /no team PC was seen in the last 14 days: no release checks/);
    assert.deepStrictEqual([backend.jobs().length, folders(w).length, fs.existsSync(w.fakeLog), scratch(w)], [0, 0, false, []]);
  });
  await withWorld({ backend: { pcs: [pcRow(PC_M, 1), pcRow(PC_M, 2), pcRow('bad id!', 3), { pcId: 7 }, pcRow(PC_W, 4)] } }, async (w, backend) => {
    const r = await release(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.deepStrictEqual(backend.jobs().map((j) => j.body.targetPc), [PC_M, PC_W], 'one job per PC id, an id the server would refuse is left out');
    assert.strictEqual(fs.readFileSync(w.fakeLog, 'utf8').trim().split('\n').length, 1, 'one debug build for all of them');
  });
});

test('DM_TEAM_DAYS changes how far back PCs count', async () => {
  await withWorld(async (w, backend) => {
    await release(w, backend, VERSION, { DM_TEAM_DAYS: '30' });
    assert.strictEqual(backend.calls[0].url, '/internal/team/pcs?days=30');
  });
});

test('a build without the art pack is checked with three release files; one without the exe, the pck or the core is skipped', async () => {
  await withWorld({ world: { assets: false } }, async (w, backend) => {
    const r = await release(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.deepStrictEqual(backend.jobs()[0].body.payload.builds[0].files.map((f) => f.name), ['DeathMuffin.exe', 'DeathMuffin.pck', DLL]);
    assert.ok(!fs.existsSync(path.join(w.teamFiles, folders(w)[0], 'DeathMuffin.assets.pck')));
  });
  for (const [over, name] of [[{ dll: false }, DLL], [{ exe: false }, 'DeathMuffin.exe']]) {
    await withWorld({ world: over }, async (w, backend) => {
      const r = await release(w, backend);
      assert.strictEqual(r.code, 0, r.out);
      assert.ok(r.out.includes(`has no ${name}: skipped`), r.out);
      assert.deepStrictEqual([backend.calls.length, folders(w).length, fs.existsSync(w.fakeLog)], [0, 0, false]);
    });
  }
});

test('failures print one line, exit 1 and leave no folder behind: the manifest, a file, the secret, the backend', async () => {
  await withWorld(async (w, backend) => {   // a file that is not what the manifest says
    fs.writeFileSync(path.join(w.build, 'DeathMuffin.pck'), 'short');
    const r = await release(w, backend);
    assert.strictEqual(r.code, 1);
    assert.match(r.out, /team release: .*DeathMuffin\.pck is not the file the manifest describes/);
    assert.deepStrictEqual([backend.calls.length, folders(w).length], [0, 0]);
  });
  await withWorld(async (w, backend) => {   // a manifest that is not there
    fs.rmSync(w.manifest);
    const r = await release(w, backend);
    assert.deepStrictEqual([r.code, /team release: cannot read the live manifest/.test(r.out)], [1, true]);
  });
  await withWorld(async (w, backend) => {   // no secret
    fs.rmSync(w.secretFile);
    const r = await release(w, backend);
    assert.deepStrictEqual([r.code, /cannot read the runner's secret/.test(r.out), backend.calls.length, folders(w).length], [1, true, 0, 0]);
  });
  await withWorld(async (w, backend) => {   // the wrong secret: the backend answers 404
    fs.writeFileSync(w.secretFile, 'another-secret-0123456789-abcdef');
    const r = await release(w, backend);
    assert.deepStrictEqual([r.code, /could not list the team PCs: the backend answered 404/.test(r.out), folders(w).length, fs.existsSync(w.fakeLog)], [1, true, 0, false]);
  });
  await withWorld(async (w, backend) => {   // the backend is not there
    const r = await release(w, backend, VERSION, { DM_TEAM_API: 'http://127.0.0.1:9' });
    assert.deepStrictEqual([r.code, /could not list the team PCs: the backend could not be reached/.test(r.out), folders(w).length], [1, true, 0]);
  });
  await withWorld(async (w, backend) => {   // a team-files folder that is missing
    fs.rmSync(w.teamFiles, { recursive: true });
    const r = await release(w, backend);
    assert.deepStrictEqual([r.code, /the team-files folder .* is missing/.test(r.out), backend.jobs().length, fs.existsSync(w.fakeLog)], [1, true, 0, false]);
  });
  await withWorld({ backend: { jobStatus: 500 } }, async (w, backend) => {   // every job refused: the files, the debug build included, are removed again
    const r = await release(w, backend);
    assert.strictEqual(r.code, 1);
    assert.strictEqual((r.out.match(/could not queue the release checks for/g) || []).length, 2);
    assert.match(r.out, /the backend answered 500: The server could not finish that\./);
    assert.match(r.out, /team release: stopped after \d+ s/);
    assert.deepStrictEqual([folders(w).length, previews(w).length], [0, 0], 'nothing will download them');
    assertClean(w, 'after the refusal');
  });
});

test('one job refused keeps the folder for the other, still prints what failed and exits 1', async () => {
  await withWorld({ backend: { failJobs: 1 } }, async (w, backend) => {
    const r = await release(w, backend);
    assert.strictEqual(r.code, 1);
    assert.match(r.out, /could not queue the release checks for pc-war-0003/);
    assert.match(r.out, /release checks queued for 1 team PC \(pc-helix-0002 job job000000002; with the debug build\)/);
    assert.strictEqual(folders(w).length, 1);
    assert.ok(fs.existsSync(path.join(w.teamFiles, folders(w)[0], 'debug', 'DeathMuffinDebug.exe')));
  });
});

test('a debug build that fails, is stopped, lies or is not possible does not stop the checks that need none: install, quit while loading and bench still go, with a lighter weight', async () => {
  const cases = [
    ['fail', {}, /no debug build \(the build failed \(exit 1\): godot export failed\)/],
    ['noline', {}, /no debug build \(the build failed \(exit 0\): all done, but no list\)/],
    ['garbage', {}, /no debug build \(the build failed \(exit 0\)/],
    ['partial', {}, new RegExp(`no debug build \\(the build has no ${DLL.replace(/\./g, '\\.')}\\)`)],
    ['missingfile', {}, /no debug build \(the build's file list does not match its folder \(DeathMuffinDebug\.pck\)\)/],
    ['slow', { DM_TEAM_BUILD_TIMEOUT: '2' }, /no debug build \(the build took longer than 2 s and was stopped\)/],
  ];
  for (const [mode, extra, said] of cases) {
    await withWorld(async (w, backend) => {
      const r = await release(w, backend, VERSION, { FAKE_MODE: mode, ...extra });
      assert.strictEqual(r.code, 0, `${mode}: ${r.out}`);
      assert.match(r.out, said, mode);
      assert.match(r.out, /the release checks go without screens, stutter, soak/);
      assert.match(r.out, /release checks queued for 2 team PCs .*; without the debug build\)/);
      for (const { body } of backend.jobs()) {
        assert.deepStrictEqual([body.title, body.weightS], [`Release checks of ${VERSION}`, 600], mode);
        assert.deepStrictEqual(body.payload.steps, ['install', 'quit-loading', 'bench'], mode);
        assert.deepStrictEqual(body.payload.builds.map((b) => b.label), ['release'], `${mode}: no debug build is promised`);
        assert.deepStrictEqual(body.payload.builds[0].files.map((f) => f.name), w.names, mode);
        assert.deepStrictEqual(Object.keys(body.payload), ['version', 'rev', 'godotVersion', 'builds', 'steps', 'setups', 'args'], `${mode}: no screens or soak settings for steps that are not queued`);
      }
      assert.deepStrictEqual(fs.readdirSync(path.join(w.teamFiles, folders(w)[0])).sort(), w.names.slice().sort(), `${mode}: no debug folder`);
      assertClean(w, mode);
      if (mode === 'slow') {
        const pid = Number(fs.readFileSync(w.fakePid, 'utf8'));
        assert.throws(() => process.kill(pid, 0), /ESRCH/, 'what the build started is stopped with it, not left running');
      }
    });
  }
  // this revision's preview-godot.sh is the old kind (no --team: it would write a zip) or there is none, or the checkout does not know the revision, or the first revision of all
  for (const [opts, over, said] of [[{ preview: 'old' }, {}, /this revision's preview-godot\.sh has no --team/], [{ preview: 'none' }, {}, /this revision's preview-godot\.sh has no --team/],
    [{ revOf: 'c1' }, {}, /this revision's preview-godot\.sh has no --team/], [{}, { DM_TEAM_REPO: '/nonexistent/checkout' }, /no debug build \(the checkout \/nonexistent\/checkout does not have revision /]]) {
    await withWorld({ world: opts }, async (w, backend) => {
      const r = await release(w, backend, VERSION, over);
      assert.strictEqual(r.code, 0, `${JSON.stringify(opts)}: ${r.out}`);
      assert.match(r.out, said);
      assert.strictEqual(backend.jobs().length, 2);
      assert.deepStrictEqual(backend.jobs()[0].body.payload.steps, ['install', 'quit-loading', 'bench']);
      assert.ok(!fs.existsSync(w.fakeLog) && !fs.existsSync(path.join(w.root, 'old-script-ran')), 'no preview script ran');
      if (!over.DM_TEAM_REPO) assertClean(w, JSON.stringify(opts));
    });
  }
});

test('DM_TEAM_PREVIEW names another preview-godot.sh than the revision\'s own', async () => {
  await withWorld({ world: { preview: 'none' } }, async (w, backend) => {
    const own = path.join(w.root, 'own-preview.sh');
    fs.writeFileSync(own, FAKE_PREVIEW);
    const r = await release(w, backend, VERSION, { DM_TEAM_PREVIEW: own });
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /with the debug build/);
    assertClean(w, 'override');
  });
});

test('the debug build is handed the revision\'s own setup script (DM_PREP: tools/check/prep.sh of the worktree, not beside preview-godot.sh)', async () => {
  await withWorld({ world: { preview: 'none' } }, async (w, backend) => {
    const own = path.join(w.root, 'own-preview.sh');
    const seen = path.join(w.root, 'prep-seen');
    fs.writeFileSync(own, FAKE_PREVIEW.replace('TOP=$(git rev-parse --show-toplevel)', 'TOP=$(git rev-parse --show-toplevel)\n[ -f "${DM_PREP:-}" ] && echo "$DM_PREP" > ' + JSON.stringify(seen)));
    const r = await release(w, backend, VERSION, { DM_TEAM_PREVIEW: own });
    assert.strictEqual(r.code, 0, r.out);
    assert.match(fs.readFileSync(seen, 'utf8').trim(), /\/tools\/check\/prep\.sh$/, 'an existing prep.sh of the worktree');
    assertClean(w, 'prep');
  });
});

test('a publish that went live during the debug build queues its own checks: this one queues nothing and leaves no folder', async () => {
  await withWorld(async (w, backend) => {
    const r = await release(w, backend, VERSION, { FAKE_MODE: 'switch' });
    assert.strictEqual(r.code, 0, r.out);
    assert.match(r.out, /the live build is now 20261019\.130000-fffffff, not 20261019\.120000-abcdef1: no release checks for it/);
    assert.deepStrictEqual([backend.jobs().length, folders(w).length], [0, 0]);
    assertClean(w, 'after a switch');
  });
});

test('the publish\'s timeout (SIGTERM) in the middle of the build stops the build and everything it started, removes the folder and the worktree, and queues nothing', async () => {
  await withWorld(async (w, backend) => {
    const child = spawn('bash', [RELEASE, VERSION], { env: envFor(w, backend, { FAKE_MODE: 'slow' }) });
    let out = '';
    child.stdout.on('data', (d) => { out += d; });
    child.stderr.on('data', (d) => { out += d; });
    const closed = new Promise((resolve) => child.on('close', (code, signal) => resolve({ code, signal })));
    for (let i = 0; i < 200 && !fs.existsSync(w.fakePid); i++) await new Promise((r) => setTimeout(r, 50));
    assert.ok(fs.existsSync(w.fakePid), `the build started: ${out}`);
    const sleeper = Number(fs.readFileSync(w.fakePid, 'utf8'));
    child.kill('SIGTERM');
    const end = await closed;
    assert.strictEqual(end.code, 143, out);
    assert.throws(() => process.kill(sleeper, 0), /ESRCH/, 'the build\'s own process is gone');
    assert.deepStrictEqual([backend.jobs().length, folders(w).length], [0, 0]);
    assertClean(w, 'after SIGTERM');
  });
});

test('the folder clean-up removes release folders (and the first hook\'s bench folders) older than 4 days and keeps the newest 6 preview folders, each rule on its own names', async () => {
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
    const hex = () => crypto.randomBytes(12).toString('hex');
    const releaseOld = [make(`release-${hex()}`, 5), make(`bench-${hex()}`, 30)];
    const releaseKept = [make(`release-${hex()}`, 3.5), make(`bench-${hex()}`, 0.1)];
    const prev = Array.from({ length: 8 }, (_, i) => make(crypto.randomBytes(16).toString('hex'), 20 - i));   // i = 7 is the newest; all are weeks old
    fs.mkdirSync(path.join(w.teamFiles, 'not-a-build-folder'));
    fs.writeFileSync(path.join(w.teamFiles, 'notes.txt'), 'keep');
    const r = await release(w, backend);
    assert.strictEqual(r.code, 0, r.out);
    assert.deepStrictEqual(releaseOld.map((d) => fs.existsSync(d)), [false, false], 'a release (or bench) folder older than 4 days goes');
    assert.deepStrictEqual(releaseKept.map((d) => fs.existsSync(d)), [true, true], 'younger ones stay, a day past the jobs\' 3-day life is the margin');
    assert.strictEqual(folders(w).length, 2, 'the younger release folder and this release\'s');
    assert.deepStrictEqual(prev.filter((d) => fs.existsSync(d)), prev.slice(2), 'previews: the newest 6 stay, however old, and this release\'s folder does not count among them');
    assert.ok(fs.existsSync(path.join(w.teamFiles, 'not-a-build-folder')) && fs.existsSync(path.join(w.teamFiles, 'notes.txt')));
    for (const n of w.names) assert.ok(fs.existsSync(path.join(w.build, n)), 'the client folder\'s own files are untouched (a link was removed, not the file)');
    // DM_TEAM_RELEASE_DAYS and DM_TEAM_KEEP reach the clean-up
    const strict = await release(w, backend, VERSION, { DM_TEAM_RELEASE_DAYS: '2', DM_TEAM_KEEP: '3' });
    assert.strictEqual(strict.code, 0, strict.out);
    assert.deepStrictEqual(releaseKept.map((d) => fs.existsSync(d)), [false, true], '2 days: the 3.5-day-old one goes too');
    assert.strictEqual(prev.filter((d) => fs.existsSync(d)).length, 3);
  });
});

test('a burst of previews never takes a waiting release\'s files, its debug build included: only age removes a release folder', async () => {
  await withWorld(async (w, backend) => {
    await release(w, backend);
    const [dir] = folders(w);
    for (let i = 0; i < 12; i++) {   // twelve preview builds come after it
      const d = path.join(w.teamFiles, crypto.randomBytes(16).toString('hex'));
      fs.mkdirSync(d);
      fs.utimesSync(d, Date.now() / 1000 + 10 + i, Date.now() / 1000 + 10 + i);
    }
    const r = await run('bash', [PRUNE, w.teamFiles], { PATH: process.env.PATH });   // what preview-godot.sh would run once it uses the script
    assert.strictEqual(r.code, 0, r.out);
    assert.ok(fs.existsSync(path.join(w.teamFiles, dir, 'DeathMuffin.exe')));
    assert.ok(fs.existsSync(path.join(w.teamFiles, dir, 'debug', 'DeathMuffinDebug.exe')));
    assert.strictEqual(fs.readdirSync(w.teamFiles).filter((n) => HEX32.test(n)).length, 6);
  });
});

test('where a hard link is not possible (another file system) the release files are copied', async (t) => {
  const shm = '/dev/shm';
  if (!fs.existsSync(shm) || fs.statSync(shm).dev === fs.statSync(os.tmpdir()).dev) return t.skip('no second file system here');
  const teamRoot = fs.mkdtempSync(path.join(shm, 'team-release-test-'));
  try {
    await withWorld({ world: { teamRoot } }, async (w, backend) => {
      const r = await release(w, backend);
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

test('team-release.sh needs an argument', async () => {
  const r = await run('bash', [RELEASE], { PATH: process.env.PATH });
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
    assert.strictEqual((await release(w, backend)).code, 0);
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

test('team-files-prune.sh keeps the newest N preview folders by modification time, removes release folders older than the days given, and touches nothing else', async () => {
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
    const releaseDir = (ageDays, name = `release-${crypto.randomBytes(12).toString('hex')}`) => {
      const d = path.join(root, name);
      fs.mkdirSync(d);
      const t = Date.now() / 1000 - ageDays * 86400;
      fs.utimesSync(d, t, t);
      return d;
    };
    const b5 = releaseDir(5); const b4ish = releaseDir(3.9); const b1 = releaseDir(1); const bFresh = releaseDir(0);
    const legacy = releaseDir(6, `bench-${crypto.randomBytes(12).toString('hex')}`);   // the name the first hook gave a release's folder
    const badNames = [releaseDir(9, 'release-ABCDEF'), releaseDir(9, `release-${'a'.repeat(23)}`), releaseDir(9, `release-${'a'.repeat(25)}`), releaseDir(9, `xrelease-${'a'.repeat(24)}`),
      releaseDir(9, `release-${'g'.repeat(24)}`), releaseDir(9, `other-${'a'.repeat(24)}`)];
    const releaseFile = path.join(root, `release-${'b'.repeat(24)}`);
    fs.writeFileSync(releaseFile, 'a file, not a folder');
    fs.utimesSync(releaseFile, 1_700_000_000, 1_700_000_000);
    const r = await run('bash', [PRUNE, root], { PATH: process.env.PATH });
    assert.deepStrictEqual([r.code, r.out], [0, ''], 'it prints nothing');
    assert.deepStrictEqual(dirs.filter((d) => fs.existsSync(d)), dirs.slice(4), 'previews: the newest 6');
    assert.deepStrictEqual([b5, legacy, b4ish, b1, bFresh].map((d) => fs.existsSync(d)), [false, false, true, true, true], 'release folders: older than 4 days go');
    assert.ok([upper, short, path.join(root, 'f'.repeat(32)), releaseFile, ...badNames].every((d) => fs.existsSync(d)), 'names that are neither kind, and files, stay');
    assert.strictEqual((await run('bash', [PRUNE, root, '2', '1'], { PATH: process.env.PATH })).code, 0);
    assert.deepStrictEqual(dirs.filter((d) => fs.existsSync(d)), dirs.slice(8), 'keep 2');
    assert.deepStrictEqual([b4ish, b1, bFresh].map((d) => fs.existsSync(d)), [false, false, true], 'release-days 1: older than a day goes (the one-day-old one is just past it)');
    assert.strictEqual((await run('bash', [PRUNE, root, '0', '0'], { PATH: process.env.PATH })).code, 0);
    assert.deepStrictEqual(dirs.filter((d) => fs.existsSync(d)), [], 'keep 0 removes every preview folder');
    assert.ok(fs.existsSync(upper) && fs.existsSync(releaseFile) && badNames.every((d) => fs.existsSync(d)));
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
  const a = text.indexOf('# --- team release hook ---');
  const b = text.indexOf('# --- end team release hook ---');
  assert.ok(a > 0 && b > a, 'the publish script has the hook block between its markers');
  assert.strictEqual(text.indexOf('# --- team release hook ---', a + 1), -1);
  return text.slice(a, b);
};

/** Run the hook block as the publish script would (set -euo pipefail, the variables it has by then, the publish lock held on fd 9). */
const runHook = (w, backend, vars, extra = {}) => run('bash', ['-c', `set -euo pipefail\nREPO="$G_REPO"; SHA="$G_SHA"; VERSION="$G_VERSION"; OUT_DIR="$G_OUT"; PREV_REV="$G_PREV"; WORK="$G_WORK"\nexec 9>"$G_LOCK"; flock -n 9\n${hookBlock()}\necho "block finished"`], {
  ...envFor(w, backend), G_REPO: vars.repo ?? w.repo.dir, G_SHA: vars.sha, G_VERSION: VERSION, G_OUT: vars.out ?? '/var/www/death-muffin/client', G_PREV: vars.prev ?? '', G_WORK: w.work, G_LOCK: path.join(w.root, 'publish.lock'), ...extra,
});

test('the publish hook: a forward release of the live folder queues the checks, from the published revision\'s own scripts, says how long it took, and the publish goes on', async () => {
  await withWorld(async (w, backend) => {
    const r = await runHook(w, backend, { sha: w.repo.c3, prev: w.repo.c2 });
    assert.match(r.out, new RegExp(`team release: 20261019\\.120000-abcdef1 \\(${w.rev}\\): release checks queued for 2 team PCs`));
    assert.match(r.out, /team release: the hook took \d+ s\nblock finished\n$/);
    assert.strictEqual(r.code, 0);
    assert.strictEqual(backend.jobs().length, 2);
    assert.strictEqual(folders(w).length, 1);
    assert.strictEqual(backend.jobs()[0].body.payload.builds.length, 2, 'the debug build was made from the checkout the publish named (REPO)');
    assertClean(w, 'after the hook');
  });
});

test('the publish hook: a first publish, the same revision again and a test folder with TEAM_RELEASE=1 run it; the test channel\'s folder, NO_TEAM_RELEASE and a rollback do not', async () => {
  await withWorld(async (w, backend) => {
    const g = w.repo;
    const ran = (r) => /release checks queued/.test(r.out);
    assert.ok(ran(await runHook(w, backend, { sha: g.c3, prev: '' })), 'a first publish (no live revision before)');
    assert.ok(ran(await runHook(w, backend, { sha: g.c3, prev: g.c3 })), 'the same revision again');
    assert.ok(ran(await runHook(w, backend, { sha: g.c3, prev: 'deadbeef12345' })), 'a previous revision this checkout does not know');
    assert.ok(ran(await runHook(w, backend, { sha: g.c3, prev: g.c2, out: '/tmp/some-test-folder' }, { TEAM_RELEASE: '1' })), 'TEAM_RELEASE=1 forces it');
    const before = backend.calls.length;
    const quiet = [
      [{ sha: g.c3, prev: g.c2, out: '/var/www/death-muffin/client-test' }, {}, /^$/],                    // the test channel's folder
      [{ sha: g.c3, prev: g.c2, out: '/tmp/some-test-folder' }, {}, /^$/],                                 // a test's folder
      [{ sha: g.c3, prev: g.c2 }, { NO_TEAM_RELEASE: '1' }, /^$/],
      [{ sha: g.c2, prev: g.c3 }, {}, /team release: .* is not newer than the build that was live \(.*\): skipped \(rollback\?\)/],
    ];
    for (const [vars, extra, said] of quiet) {
      const r = await runHook(w, backend, vars, extra);
      assert.strictEqual(r.code, 0, JSON.stringify(vars));
      assert.ok(!ran(r), JSON.stringify(vars));
      assert.match(r.out.replace('block finished', '').trim(), said, JSON.stringify(vars));
    }
    assert.strictEqual(backend.calls.length, before, 'a skipped hook asks the backend nothing');
  });
});

test('the publish hook: a revision without the scripts is skipped with a line, and a failing hook never fails the publish', async () => {
  await withWorld(async (w, backend) => {
    const g = w.repo;
    const r = await runHook(w, backend, { sha: g.c1, prev: '' });
    assert.deepStrictEqual([r.code, /team release: .* has no team-release\.sh \(older revision\): skipped/.test(r.out), r.out.trim().endsWith('block finished')], [0, true, true]);
    assert.strictEqual(backend.calls.length, 0);
    fs.rmSync(w.secretFile);   // the hook itself fails (exit 1): the block still finishes
    const failed = await runHook(w, backend, { sha: g.c3, prev: g.c2 });
    assert.deepStrictEqual([failed.code, /cannot read the runner's secret/.test(failed.out), /team release: failed \(the publish itself is fine\)/.test(failed.out), /team release: the hook took \d+ s/.test(failed.out), failed.out.trim().endsWith('block finished')], [0, true, true, true, true]);
    const down = await runHook(w, backend, { sha: g.c3, prev: g.c2 }, { DM_TEAM_API: 'http://127.0.0.1:9' });
    assert.strictEqual(down.code, 0);
  });
});

test('the publish hook lets go of the publish lock before the long part, so a rollback publish never waits for the debug build', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'team-hook-lock-'));
  try {
    const dir = path.join(root, 'repo');
    fs.mkdirSync(path.join(dir, 'server/death-muffin'), { recursive: true });
    git(dir, 'init', '-q');
    // a stand-in team-release.sh that asks, from another process, whether the lock is free while it runs
    fs.writeFileSync(path.join(dir, 'server/death-muffin/team-release.sh'), '#!/usr/bin/env bash\nflock -n "$G_LOCK" true && echo "the lock is free during the hook" || echo "the lock is still held"\n');
    fs.writeFileSync(path.join(dir, 'server/death-muffin/team-files-prune.sh'), '#!/usr/bin/env bash\nexit 0\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'stub');
    const sha = git(dir, 'rev-parse', '--short=12', 'HEAD');
    const lock = path.join(root, 'publish.lock');
    const r = await run('bash', ['-c', `set -euo pipefail\nREPO="$G_REPO"; SHA="$G_SHA"; VERSION=v1; OUT_DIR=/var/www/death-muffin/client; PREV_REV=""; WORK=""\nexec 9>"$G_LOCK"; flock -n 9\nif flock -n "$G_LOCK" true; then echo "BUG: the lock was not held before the hook"; fi\n${hookBlock()}\necho finished`],
      { PATH: process.env.PATH, G_REPO: dir, G_SHA: sha, G_LOCK: lock });
    assert.strictEqual(r.code, 0, r.out);
    assert.ok(r.out.includes('the lock is free during the hook'), r.out);
    assert.ok(!r.out.includes('BUG') && !r.out.includes('still held'), r.out);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('the publish script runs the hook after announcing the release, remembers the live revision before the manifest is replaced, and says so in its header', () => {
  const text = fs.readFileSync(PUBLISH, 'utf8');
  assert.ok(text.indexOf('PREV_REV=$(') > 0 && text.indexOf('PREV_REV=$(') < text.indexOf('mv -f "$OUT_DIR/manifest.json.tmp" "$OUT_DIR/manifest.json"'), 'PREV_REV is read before the switch');
  assert.ok(text.indexOf('# --- team release hook ---') > text.indexOf('announce-release.sh" "$SHA"') || text.indexOf('# --- team release hook ---') > text.indexOf('ANN=$(mktemp)'), 'the hook comes after the announcement');
  assert.ok(text.indexOf('# --- end team release hook ---') > text.length - 200, 'it is the last thing the publish does');
  assert.match(text, /^# 6\. team-release\.sh:/m);
  assert.ok(text.includes('TEAM_RELEASE NO_TEAM_RELEASE'));
  execFileSync('bash', ['-n', PUBLISH]);
  execFileSync('bash', ['-n', RELEASE]);
  execFileSync('bash', ['-n', PRUNE]);
});
