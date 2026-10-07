'use strict';
// The sandbox of EVERY script that runs untrusted code (check.sh, check-godot.sh, preview.sh, preview-godot.sh, shot.sh, regen.sh) goes through
// sandbox-lib.sh. These tests run the real scripts (real unshare) on a throwaway repo whose "tools" (tsc, vitest, npm scripts, vite, godot) are
// stand-ins that probe the filesystem from INSIDE the sandbox: the live paths ubuntu owns must not be writable, the worktree and a private /tmp must be.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs'), os = require('os'), path = require('path');
const { spawnSync, execFileSync } = require('child_process');
const DIR = path.resolve(__dirname, '..');
const WT_PARENT = fs.existsSync('/home/ubuntu/vps-handoffs/DeathMuffin/wt') ? '/home/ubuntu/vps-handoffs/DeathMuffin/wt' : os.homedir();   // a read-only-able place outside /tmp
// Paths ubuntu owns on the live box (only those that exist here are probed; at least three must).
const LIVE = ['/var/www/death-muffin/client', '/var/www/death-muffin/play', '/var/www/death-muffin/offline', '/var/www/death-muffin/preview', '/opt/crossworlds-bot', '/opt/crossworlds-auth', '/opt/muffincore', '/game', '/game-staging', '/home/ubuntu', '/var/log', '/etc', '/usr/local'];

const PROBE = `#!/usr/bin/env bash
# runs inside the sandbox, as root of the (nested) user namespace: first tries to break out, then records which writes succeed
out="$TOP/.probe-$1"; : > "$out"
atk() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ATTACK-SUCCEEDED $n" >> "$out"; fi; }
parent=$(findmnt -T /var/www -n -o TARGET 2>/dev/null || echo /)
atk remount-root mount -o remount,bind,rw /
atk remount-root-rw mount -o remount,rw /
atk remount-parent-of-var-www mount -o remount,bind,rw "$parent"
atk remount-home mount -o remount,bind,rw /home/ubuntu
atk umount-tmp umount /tmp
atk umount-tmp-lazy umount -l /tmp
atk umount-shm umount /dev/shm
atk umount-root umount -l /
atk nested-unshare-remount unshare -rm bash -c 'mount -o remount,bind,rw / && : > /var/www/death-muffin/client/.dm-sbx-x'
atk nested-unshare-remount2 unshare -Um --map-root-user bash -c 'mount -o remount,bind,rw /opt && : > /opt/crossworlds-bot/.dm-sbx-x'
atk mount-proc-sys-write bash -c ': > /proc/sys/kernel/hostname'
for p in ${LIVE.map((x) => `'${x}'`).join(' ')} "$SIBLING" "$HOME_PROBE"; do
  [ -n "$p" ] && [ -d "$p" ] || continue
  if ( : > "$p/.dm-sbx-probe" ) 2>/dev/null; then echo "WROTE $p" >> "$out"; rm -f "$p/.dm-sbx-probe"; else echo "blocked $p" >> "$out"; fi
done
( : > "$TOP/.dm-sbx-w" ) 2>/dev/null && echo "worktree-ok" >> "$out" && rm -f "$TOP/.dm-sbx-w"
echo inside > /tmp/dm-sbx-inside-$$ 2>/dev/null && echo "tmp-ok" >> "$out"
[ -e "$HOSTMARK" ] && echo "HOST-TMP-VISIBLE" >> "$out"
echo inside > /dev/shm/dm-sbx-inside-$$ 2>/dev/null && echo "shm-ok" >> "$out"
[ -e "$SHM_HOSTMARK" ] && echo "HOST-SHM-VISIBLE" >> "$out"
# last: a bind mount of a writable dir OVER a read-only path is allowed (it only hides it, here in a throwaway mount namespace); whatever is then written lands in the worktree dir,
# never in the real path (the test checks the real paths from outside afterwards)
mkdir -p "$TOP/.decoy" && for t in /var/www/death-muffin/client /opt/crossworlds-bot /game /home/ubuntu; do [ -d "$t" ] && unshare -m bash -c 'mount --bind "$1" "$2" && : > "$2/.dm-sbx-bound-write"' _ "$TOP/.decoy" "$t" 2>/dev/null; done   # own mount ns so the decoy cannot hide the worktree from later tools
exit 0
`;

function world() {
  const root = fs.mkdtempSync(path.join(WT_PARENT, 'dm-sbx-test-'));
  const top = path.join(root, 'top'), sibling = path.join(root, 'sibling-worktree');
  fs.mkdirSync(top); fs.mkdirSync(sibling);
  execFileSync('git', ['init', '-q', top]);
  const w = (f, c, mode) => { fs.mkdirSync(path.dirname(path.join(top, f)), { recursive: true }); fs.writeFileSync(path.join(top, f), c, mode ? { mode } : undefined); };
  w('.probe.sh', PROBE.replace(/^if \( : > "\$p_.*\n/m, ''), 0o755);
  const hostmark = path.join(os.tmpdir(), `dm-host-marker-${process.pid}-${Date.now()}`); fs.writeFileSync(hostmark, 'host');
  const shmmark = `/dev/shm/dm-host-marker-${process.pid}-${Date.now()}`; fs.writeFileSync(shmmark, 'host');
  const env = { ...process.env, SIBLING: sibling, HOME_PROBE: os.homedir(), HOSTMARK: hostmark, SHM_HOSTMARK: shmmark };
  const cleanup = () => { fs.rmSync(root, { recursive: true, force: true }); fs.rmSync(hostmark, { force: true }); fs.rmSync(shmmark, { force: true }); };
  return { root, top, sibling, w, env, cleanup, hostmark };
}
function verdict(W, name) {
  const lines = fs.readFileSync(path.join(W.top, `.probe-${name}`), 'utf8').split('\n').filter(Boolean);
  assert.deepEqual(lines.filter((l) => l.startsWith('WROTE')), [], `${name}: a live path was writable from the sandbox`);
  assert.deepEqual(lines.filter((l) => l.startsWith('ATTACK-SUCCEEDED')), [], `${name}: a breakout attempt worked`);
  assert.ok(lines.length > 15, `${name}: the probe did not run to the end`);
  // the real paths, seen from outside the sandbox, never got a file (bind-mounting a decoy over them only wrote into the decoy)
  for (const d of ['/var/www/death-muffin/client', '/opt/crossworlds-bot', '/game', '/home/ubuntu']) for (const f of ['.dm-sbx-bound-write', '.dm-sbx-x', '.dm-sbx-probe']) assert.ok(!fs.existsSync(path.join(d, f)), `${name}: ${d}/${f} exists on the host`);
  assert.deepEqual(lines.filter((l) => /VISIBLE/.test(l)), [], `${name}: host /tmp or /dev/shm leaked into the sandbox`);
  for (const ok of ['worktree-ok', 'tmp-ok', 'shm-ok']) assert.ok(lines.includes(ok), `${name}: ${ok} missing (${lines.join(' | ')})`);
  const blocked = lines.filter((l) => l.startsWith('blocked')).map((l) => l.slice(8));
  assert.ok(blocked.includes(W.sibling), `${name}: sibling worktree must be probed and blocked`);
  assert.ok(blocked.includes(os.homedir()), `${name}: home must be blocked`);
  assert.ok(blocked.length >= 5, `${name}: too few live paths exist to prove anything: ${blocked}`);
  for (const must of ['/var/www/death-muffin/client', '/opt/crossworlds-bot', '/game']) if (fs.existsSync(must)) assert.ok(blocked.includes(must), `${name}: ${must} must be blocked`);
  assert.ok(!fs.existsSync(path.join(W.sibling, '.dm-sbx-probe')));
  assert.ok(!fs.readdirSync(os.tmpdir()).some((n) => n.startsWith('dm-sbx-inside-')), `${name}: the sandbox wrote into the host /tmp`);
}
const run = (W, script, args, extraEnv = {}) => spawnSync('bash', [path.join(DIR, script), ...args], { cwd: W.top, env: { ...W.env, ...extraEnv }, encoding: 'utf8', timeout: 180000 });
const probeCmd = (name) => `bash "$TOP/.probe.sh" ${name}`;

test('sandbox: check.sh (tsc, vitest and npm scripts all run read-only except the worktree)', () => {
  const W = world(); try {
    const bin = (n, body) => W.w(`node_modules/.bin/${n}`, `#!/usr/bin/env bash\n${body}\n`, 0o755);
    bin('tsc', probeCmd('check-tsc')); bin('vitest', probeCmd('check-vitest'));
    W.w('package.json', JSON.stringify({ scripts: { 'test:server': `${probeCmd('check-server')}; echo '# tests 1'; echo '# pass 1'; echo '# fail 0'` } }));
    const r = run(W, 'check.sh', []); assert.equal(r.status, 0, r.stdout + r.stderr);
    for (const n of ['check-tsc', 'check-vitest', 'check-server']) verdict(W, n);
  } finally { W.cleanup(); }
});

test('sandbox: check-godot.sh', () => {
  const W = world(); try {
    W.w('tools/godot/gen-fixtures.sh', `${probeCmd('godot-gen')}\n`); W.w('tools/godot/run-all-tests.sh', `${probeCmd('godot-tests')}\nprintf "%-18s %-16s exit=%d  %s\\n" game run.gd 0 "1 passed"\n`);
    const r = run(W, 'check-godot.sh', []); assert.equal(r.status, 0, r.stdout + r.stderr);
    verdict(W, 'godot-gen'); verdict(W, 'godot-tests');
  } finally { W.cleanup(); }
});

test('sandbox: regen.sh', () => {
  const W = world(); try {
    W.w('package.json', JSON.stringify({ scripts: { 'build:server-rules': probeCmd('regen-rules'), 'gen:loot': 'true' } })); W.w('tools/embed-realtime.mjs', '');
    const r = run(W, 'regen.sh', []); assert.equal(r.status, 0, r.stdout + r.stderr);
    verdict(W, 'regen-rules');
  } finally { W.cleanup(); }
});

test('sandbox: preview.sh (vite build)', () => {
  const W = world(); try {
    const prev = path.join(W.root, 'preview'); fs.mkdirSync(prev);
    W.w('node_modules/.bin/vite', `#!/usr/bin/env bash\n${probeCmd('preview-vite')}\nmkdir -p .dm-preview && echo '<html><head></head><body></body></html>' > .dm-preview/index.html\n`, 0o755);
    const r = run(W, 'preview.sh', ['abc123'], { DM_PREVIEW_ROOT: prev, DM_PREVIEW_LINKDEST: '/nonexistent' }); assert.equal(r.status, 0, r.stdout + r.stderr);
    verdict(W, 'preview-vite');
  } finally { W.cleanup(); }
});

test('sandbox: preview-godot.sh (import + export)', () => {
  const W = world(); try {
    const prev = path.join(W.root, 'preview'); fs.mkdirSync(prev); W.w('godot/project.godot', 'x');
    W.w('.fake-godot', `#!/usr/bin/env bash\n${probeCmd('preview-godot')}\nfor a in "$@"; do out="$a"; done\ncase " $* " in *" --export-release "*) printf MZfake > "$out"; head -c 200000 /dev/zero > "\${out%.exe}.pck";; esac\n`, 0o755);
    const r = run(W, 'preview-godot.sh', ['abc123'], { DM_PREVIEW_ROOT: prev, GODOT: path.join(W.top, '.fake-godot'), GODOT_TEMPLATES: path.join(W.top, '.templates') }); assert.equal(r.status, 0, r.stdout + r.stderr);
    verdict(W, 'preview-godot');
  } finally { W.cleanup(); }
});

test('sandbox: shot.sh (dev server)', () => {
  const W = world(); try {
    W.w('.dm-shot.json', '{"shots":[]}');
    W.w('node_modules/.bin/vite', `#!/usr/bin/env bash\n${probeCmd('shot-vite')}\nexec python3 -m http.server 5188 --bind 127.0.0.1 >/dev/null 2>&1\n`, 0o755);
    // shoot.cjs fails fast without a browser; the probe has already run inside the sandbox by then
    run(W, 'shot.sh', [], { DM_BROWSER_LOCK: path.join(W.root, 'lock'), DM_PLAYWRIGHT_MODULE: '/nonexistent' });
    verdict(W, 'shot-vite');
    spawnSync('pkill', ['-f', '[h]ttp.server 5188']);   // the stand-in dev server outlives shot.sh's kill of its npx wrapper
  } finally { W.cleanup(); }
});

test('sandbox: the nested namespace locks the mounts (the verify step itself aborts when a mount could be remounted rw)', () => {
  // outer-namespace-only sandbox (no nesting) must be detected: verify run directly in the outer ns finds / remountable and exits 99
  const W = world(); try {
    const r = spawnSync('unshare', ['-rnm', 'bash', '-c', `. "${DIR}/sandbox-lib.sh"; dm_sandbox_setup; dm_sandbox_verify; echo SHOULD-NOT-RUN`], { cwd: W.top, env: { ...W.env, TOP: W.top }, encoding: 'utf8' });
    assert.equal(r.status, 99, r.stdout + r.stderr); assert.match(r.stderr, /can be remounted read-write|can be unmounted/); assert.ok(!/SHOULD-NOT-RUN/.test(r.stdout));
  } finally { W.cleanup(); }
});

test('sandbox: the helper fails closed (no TOP -> exit 99, nothing runs)', () => {
  const r = spawnSync('unshare', ['-rnm', 'bash', '-c', `. "${DIR}/sandbox-lib.sh"; TOP=/nonexistent dm_sandbox_setup; echo SHOULD-NOT-RUN`], { encoding: 'utf8' });
  assert.equal(r.status, 99); assert.ok(!/SHOULD-NOT-RUN/.test(r.stdout)); assert.match(r.stderr, /TOP is not a directory/);
});
