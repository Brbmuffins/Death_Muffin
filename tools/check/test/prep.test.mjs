// tools/check/prep.sh, the game's one setup (tools/check/README.md), on a throwaway repository with stand-ins for Godot, the combat core's
// build, the crowd baker and npm: what is built, copied, kept and stored in each case, and that nothing a check must not trust gets stored.
// Run: node --test tools/check/test/*.test.mjs (also in CI).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const PREP = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../prep.sh');

function world() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-prep-'));
  const repo = path.join(root, 'repo');
  const w = (f, c, mode) => { const p = path.join(repo, f); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, c); if (mode) fs.chmodSync(p, mode); };
  const log = path.join(root, 'calls.log');
  fs.mkdirSync(repo);
  const git = (...a) => execFileSync('git', ['-C', repo, ...a], { encoding: 'utf8' }).trim();
  git('init', '-q'); git('config', 'user.name', 't'); git('config', 'user.email', 't@t');
  w('.gitignore', 'client/.godot/\nclient/bin/*.so\nclient/bin/*.dll\nclient/assets/crowd/baked/\nclient/assets/fx/sheets/\nnative/build/\nnative/thirdparty/\n.dm-native-cache/\nnode_modules/\n');
  w('client/project.godot', '[application]\n');
  w('client/assets/tree.txt', 'a tree\n');
  w('client/bin/dmcore.gdextension', '[configuration]\n');
  w('native/code/core.cpp', 'int core() { return 1; }\n');
  w('native/build.sh', `#!/usr/bin/env bash\ncd "$(dirname "$0")"\necho "native $1" >> ${log}\nmkdir -p ../client/bin build/symbols\nif [ "$1" != windows ]; then echo "so $(cat code/core.cpp)" > ../client/bin/libdmcore.linux.template_debug.x86_64.so; fi\nif [ "$1" = windows ] || [ "$1" = all ]; then echo dll > ../client/bin/libdmcore.windows.template_release.x86_64.dll; echo dbg > build/symbols/libdmcore.debug; fi\n`, 0o755);
  w('client/crowd/baker.gd', 'extends Node\n');
  w('client/tools/bake_crowd.sh', `#!/usr/bin/env bash\ncd "$(dirname "$0")/.."\necho bake >> ${log}\nmkdir -p assets/crowd/baked/robber\necho baked > assets/crowd/baked/robber/vat.bin\n`, 0o755);
  w('server/death-muffin/lobby/package.json', '{"name":"lobby"}\n');
  w('server/death-muffin/lobby/package-lock.json', '{"lockfileVersion":3}\n');
  git('add', '-A'); git('commit', '-qm', 'base');
  const bin = path.join(root, 'bin'); fs.mkdirSync(bin);
  const godot = path.join(bin, 'godot');
  fs.writeFileSync(godot, `#!/usr/bin/env bash\nif [ "$1" = --version ]; then echo 4.7.2.stable.fake; exit 0; fi\nP=; while [ $# -gt 0 ]; do [ "$1" = --path ] && P="$2"; shift; done\necho import >> ${log}\nmkdir -p "$P/.godot/imported"; date +%s%N > "$P/.godot/imported/stamp"\n`, { mode: 0o755 });
  fs.writeFileSync(path.join(bin, 'npm'), `#!/usr/bin/env bash\necho "npm $*" >> ${log}\nmkdir -p node_modules/ws; echo ws > node_modules/ws/index.js\n`, { mode: 0o755 });
  const cache = path.join(root, 'cache');
  const env = { ...process.env, GODOT: godot, DM_BUILD_CACHE: cache, PATH: `${bin}:${process.env.PATH}` };
  const prep = (args = [], extra = {}, cwd = repo) => {
    fs.writeFileSync(log, '');
    const r = spawnSync('bash', [PREP, ...args], { cwd, env: { ...env, ...extra }, encoding: 'utf8' });
    return { ...r, calls: fs.readFileSync(log, 'utf8').trim().split('\n').filter(Boolean), last: r.stdout.trim().split('\n').pop() };
  };
  const clone = (name) => { const d = path.join(root, name); git('worktree', 'add', '-q', '--detach', d, 'HEAD'); return d; };
  const kinds = () => (fs.existsSync(cache) ? fs.readdirSync(cache).filter((f) => !f.startsWith('.')).sort() : []);
  return { root, repo, w, git, prep, clone, cache, kinds, cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

test('a fresh checkout builds everything once and stores it; another checkout of the same tree copies it all; a second run keeps it', () => {
  const W = world(); try {
    const a = W.prep();
    assert.equal(a.status, 0, a.stdout + a.stderr);
    assert.match(a.last, /^PREP core=built win=- import=fresh bake=built lobby=installed stored=core,import,bake,lobby seconds=\d+$/);
    assert.deepEqual(a.calls.filter((c) => c !== 'import'), ['native linux', 'bake', 'npm ci --no-audit --no-fund']);
    assert.deepEqual(W.kinds().map((k) => k.split('-')[0]), ['bake', 'core', 'import', 'lobby']);
    const b = W.prep([], {}, W.clone('second'));
    assert.equal(b.status, 0, b.stdout + b.stderr);
    assert.match(b.last, /^PREP core=cached win=- import=cached bake=cached lobby=cached stored=- /);
    assert.deepEqual(b.calls, ['import'], 'nothing is built, one import pass brings the copy up to date');
    const wt = path.join(W.root, 'second');
    assert.equal(fs.readFileSync(path.join(wt, 'client/assets/crowd/baked/robber/vat.bin'), 'utf8'), 'baked\n');
    assert.ok(fs.existsSync(path.join(wt, 'client/bin/libdmcore.linux.template_debug.x86_64.so')));
    assert.ok(fs.existsSync(path.join(wt, 'server/death-muffin/lobby/node_modules/ws/index.js')));
    assert.equal(fs.readFileSync(path.join(wt, 'client/.godot/extension_list.cfg'), 'utf8'), 'res://bin/dmcore.gdextension\n', 'the extension is listed before the import');
    const c = W.prep();
    assert.match(c.last, /^PREP core=kept win=- import=kept bake=kept lobby=kept stored=- /);
    assert.deepEqual(c.calls, ['import']);
  } finally { W.cleanup(); }
});

test('a key follows what each piece is made of: an asset changes the import only, the core changes the core and the bake', () => {
  const W = world(); try {
    const keys = () => Object.fromEntries(W.prep(['--keys']).stdout.trim().split('\n').map((l) => l.split('=')));
    const k0 = keys();
    assert.deepEqual(Object.keys(k0), ['core', 'win', 'import', 'bake', 'lobby']);
    W.w('client/assets/tree.txt', 'a taller tree\n'); W.git('commit', '-qam', 'art');
    const k1 = keys();
    assert.notEqual(k1.import, k0.import); assert.equal(k1.core, k0.core); assert.equal(k1.bake, k0.bake);
    W.w('native/code/core.cpp', 'int core() { return 2; }\n'); W.git('commit', '-qam', 'core');
    const k2 = keys();
    assert.notEqual(k2.core, k1.core); assert.notEqual(k2.bake, k1.bake, 'the baker poses bodies through the core'); assert.equal(k2.import, k1.import);
    assert.equal(k2.win.slice(4), k2.core.slice(5), 'both cores share the key of native/');
  } finally { W.cleanup(); }
});

test('uncommitted changes are built and never stored; --read-only stores nothing at all', () => {
  const W = world(); try {
    assert.equal(W.prep().status, 0);
    const before = W.kinds();
    W.w('native/code/core.cpp', 'int core() { return 3; }\n');   // not committed
    const d = W.prep();
    assert.equal(d.status, 0, d.stdout + d.stderr);
    assert.match(d.last, /core=built .*bake=built .*stored=- /);
    assert.deepEqual(W.kinds(), before, 'a piece made from uncommitted files never reaches the cache');
    assert.ok(!fs.existsSync(path.join(W.repo, 'native/build/.prep-core')), 'and the checkout does not claim a key it does not hold');
    W.git('checkout', '-q', '--', 'native/code/core.cpp');
    W.w('native/code/core.cpp', 'int core() { return 4; }\n'); W.git('commit', '-qam', 'core 4');
    const r = W.prep(['--read-only'], {}, W.clone('job'));
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.last, /core=built .*stored=- /);
    assert.deepEqual(W.kinds(), before, '--read-only (the agent sandbox) stores nothing');
  } finally { W.cleanup(); }
});

test('--warm fills the cache for a revision from a scratch worktree, with that revision\'s files only, and then has nothing to do', () => {
  const W = world(); try {
    const base = W.git('rev-parse', 'HEAD');
    W.w('native/code/core.cpp', 'int core() { return 5; }\n');   // the caller's own uncommitted work must not matter
    const a = W.prep(['--warm', base]);
    assert.equal(a.status, 0, a.stdout + a.stderr);
    assert.match(a.last, /stored=core,import,bake,lobby/);
    const core = W.kinds().find((k) => k.startsWith('core-'));
    assert.equal(fs.readFileSync(path.join(W.cache, core, 'libdmcore.linux.template_debug.x86_64.so'), 'utf8'), 'so int core() { return 1; }\n', 'built from the revision, not the working copy');
    assert.equal(W.git('worktree', 'list').split('\n').length, 1, 'the scratch worktree is gone');
    const b = W.prep(['--warm', base]);
    assert.equal(b.status, 0); assert.match(b.last, /^PREP warm [0-9a-f]{12}: cached$/); assert.deepEqual(b.calls, []);
    // the checkout --warm runs from only provides the history (the shared main checkout may sit on an old layout)
    W.git('checkout', '-q', '--orphan', 'old-layout'); W.git('rm', '-rqf', '--cached', '.'); fs.rmSync(path.join(W.repo, 'client'), { recursive: true, force: true });
    const c = W.prep(['--warm', base]);
    assert.equal(c.status, 0, c.stdout + c.stderr); assert.match(c.last, /: cached$/);
  } finally { W.cleanup(); }
});

test('--windows adds the Windows core and its symbols, cached like the rest', () => {
  const W = world(); try {
    const a = W.prep(['--windows']);
    assert.equal(a.status, 0, a.stdout + a.stderr);
    assert.match(a.last, /win=built .*stored=core,win,/);
    const b = W.prep(['--windows'], {}, W.clone('pub'));
    assert.match(b.last, /win=cached/);
    assert.equal(fs.readFileSync(path.join(W.root, 'pub/native/build/symbols/libdmcore.debug'), 'utf8'), 'dbg\n', 'the symbols come with the cached library');
  } finally { W.cleanup(); }
});

test('an import made with the licensed flipbook sheets present is never stored', () => {
  const W = world(); try {
    W.w('client/assets/fx/sheets/hit.png', 'licensed\n');   // git-ignored, copied in by a publish
    const a = W.prep();
    assert.equal(a.status, 0, a.stdout + a.stderr);
    assert.doesNotMatch(a.last, /stored=[^ ]*import/);
    assert.ok(!W.kinds().some((k) => k.startsWith('import-')));
  } finally { W.cleanup(); }
});

test('DM_PREP_SLOTS (CI): one folder per kind holding its key; a checkout with the slots restored copies everything', () => {
  const W = world(); try {
    const slots = path.join(W.root, 'slots');
    const a = W.prep([], { DM_PREP_SLOTS: slots });
    assert.equal(a.status, 0, a.stdout + a.stderr);
    for (const k of ['core', 'import', 'bake', 'lobby']) assert.match(fs.readFileSync(path.join(slots, k, '.key'), 'utf8'), new RegExp(`^${k}-[0-9a-f]{16}\\n$`));
    assert.deepEqual(W.kinds(), [], 'the keyed cache is not used');
    const b = W.prep([], { DM_PREP_SLOTS: slots }, W.clone('ci'));
    assert.match(b.last, /^PREP core=cached win=- import=cached bake=cached lobby=cached stored=- /);
    W.w('client/assets/tree.txt', 'another tree\n'); W.git('commit', '-qam', 'art');
    const c = W.prep([], { DM_PREP_SLOTS: slots }, W.clone('ci2'));
    assert.match(c.last, /import=seeded .*stored=import /, 'another key seeds the import and replaces the slot');
  } finally { W.cleanup(); }
});

test('a failing step stops the setup with its log tail and a plain line', () => {
  const W = world(); try {
    W.w('native/build.sh', '#!/usr/bin/env bash\necho "scons: compile error in core.cpp"; exit 1\n', 0o755);
    W.git('commit', '-qam', 'broken build');
    const r = W.prep();
    assert.equal(r.status, 1);
    assert.match(r.stderr, /compile error in core\.cpp/);
    assert.match(r.stderr, /^prep: building the combat core failed$/m);
  } finally { W.cleanup(); }
});
