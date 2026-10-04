'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig } = require('../runner/lib/config.cjs');
const { parseDiff, classifyDiff, tierLabel } = require('../runner/lib/tiers.cjs');
const { numericOnly, textOnly } = require('../runner/lib/numdelta.cjs');
const { matches } = require('../runner/lib/glob.cjs');

const cfg = loadConfig(null);
cfg.ownerIds = ['111111111111111111']; cfg.project = { requesters: [], approvers: { casual: ['111111111111111111', '142812688358178816'], gameplay: ['111111111111111111'], sensitive: ['111111111111111111'] } };
cfg.names = { '142812688358178816': 'Helix' };

// helper: build a -U0 diff for one file
const d = (file, removed, added, extra = '') => `diff --git a/${file} b/${file}\n${extra}--- a/${file}\n+++ b/${file}\n@@ -1,${removed.length} +1,${added.length} @@\n${removed.map((l) => '-' + l).join('\n')}${removed.length ? '\n' : ''}${added.map((l) => '+' + l).join('\n')}\n`;
const dnew = (file, lines) => `diff --git a/${file} b/${file}\nnew file mode 100644\n--- /dev/null\n+++ b/${file}\n@@ -0,0 +1,${lines.length} @@\n${lines.map((l) => '+' + l).join('\n')}\n`;

test('glob', () => {
  assert.ok(matches('**/*.css', 'src/ui/ui.css')); assert.ok(matches('**/*.css', 'a.css'));
  assert.ok(matches('server/**', 'server/death-muffin/backend/server.js')); assert.ok(!matches('server/**', 'src/server.ts'));
  assert.ok(matches('*.md', 'README.md')); assert.ok(!matches('*.md', 'docs/a.md'));
  assert.ok(matches('**/migrations/**', 'server/x/migrations/030.sql'));
});

test('numeric checker: within 25% passes, beyond fails', () => {
  assert.ok(numericOnly({ removed: ['  hp: 100,'], added: ['  hp: 125,'] }));
  assert.ok(numericOnly({ removed: ['  hp: 100,'], added: ['  hp: 75,'] }));
  assert.ok(!numericOnly({ removed: ['  hp: 100,'], added: ['  hp: 126,'] }));
  assert.ok(!numericOnly({ removed: ['  hp: 100,'], added: ['  hp: 74,'] }));
  assert.ok(numericOnly({ removed: ['  dmg: 2.0, speed: 10,'], added: ['  dmg: 2.4, speed: 9,'] }));
  assert.ok(!numericOnly({ removed: ['  dmg: 2.0, speed: 10,'], added: ['  dmg: 2.4, speed: 13,'] }), 'one number out of range fails the line');
});
test('numeric checker: not numeric-only changes fail', () => {
  assert.ok(!numericOnly({ removed: ['  hp: 100,'], added: ['  hp: 100, evil: true,'] }));
  assert.ok(!numericOnly({ removed: ['  hp: 100,'], added: ['  xp: 100,'] }));
  assert.ok(!numericOnly({ removed: [], added: ['  hp: 100,'] }), 'pure addition');
  assert.ok(!numericOnly({ removed: ['  hp: 0,'], added: ['  hp: 1,'] }), 'zero -> nonzero');
  assert.ok(!numericOnly({ removed: ['  hp: 5,'], added: ['  hp: -5,'] }), 'sign flip');
  assert.ok(!numericOnly({ removed: ['  hp: 100,'], added: ['  hp: 100,'] }), 'no change at all');
  assert.ok(!numericOnly({ removed: ['  flags: 0x10,'], added: ['  flags: 0x11,'] }), 'hex is code, not a number tweak');
  assert.ok(!numericOnly({ removed: ['a: 1,', 'b: 2,'], added: ['a: 1,'] }), 'line count mismatch');
});
test('text checker: only string contents, only allowed keys, no markup', () => {
  const keys = ['name', 'desc'];
  assert.ok(textOnly({ removed: ["  name: 'Old Bone',"], added: ["  name: 'Brittle Bone',"] }, keys));
  assert.ok(!textOnly({ removed: ["  id: 'bone',"], added: ["  id: 'bone2',"] }, keys), 'ids are not editable text');
  assert.ok(!textOnly({ removed: ["  name: 'a',"], added: ["  name: 'a', x: run(),"] }, keys));
  assert.ok(!textOnly({ removed: ["  desc: 'a',"], added: ["  desc: '<img src=x onerror=1>',"] }, keys));
  assert.ok(!textOnly({ removed: ['  desc: `a`,'], added: ['  desc: `a ${evil()}`,'] }, keys));
  assert.ok(textOnly({ removed: ["  'x y': 'Hello',"], added: ["  'x y': 'Hi',"] }, '*'));
});

test('tier: css/docs/patch notes are casual', () => {
  assert.equal(classifyDiff(d('src/ui/ui.css', ['a{color:red}'], ['a{color:blue}']), cfg).tier, 'casual');
  assert.equal(classifyDiff(d('README.md', ['x'], ['y']), cfg).tier, 'casual');
  assert.equal(classifyDiff(dnew('docs/new.md', ['hi']), cfg).tier, 'casual');
  assert.equal(classifyDiff(d('PATCH_NOTES.json', ['"a"'], ['"b"']), cfg).tier, 'casual');
});
test('tier: css pulling external resources is not casual', () => {
  assert.equal(classifyDiff(d('src/ui/ui.css', ['a{}'], ['@import url(https://evil.example/x.css);']), cfg).tier, 'gameplay');
});
test('tier: item names casual, item ids / logic gameplay', () => {
  assert.equal(classifyDiff(d('src/content/items.ts', ["  name: 'Rusty Nail',"], ["  name: 'Old Nail',"]), cfg).tier, 'casual');
  assert.equal(classifyDiff(d('src/content/items.ts', ["  id: 'nail',"], ["  id: 'nail2',"]), cfg).tier, 'gameplay');
});
test('tier: balance numbers within 25% casual, beyond gameplay', () => {
  assert.equal(classifyDiff(d('src/content/enemies.ts', ['  hp: 200,'], ['  hp: 240,']), cfg).tier, 'casual');
  assert.equal(classifyDiff(d('src/content/enemies.ts', ['  hp: 200,'], ['  hp: 300,']), cfg).tier, 'gameplay');
  assert.equal(classifyDiff(dnew('src/content/enemies.ts', ['  hp: 200,']), cfg).tier, 'gameplay', 'new content file is not a number tweak');
});
test('tier: other client code is gameplay', () => {
  for (const f of ['src/gameplay/AbilitySystem.ts', 'src/scenes/WorldScene.ts', 'src/graphics/Effects.ts']) assert.equal(classifyDiff(d(f, ['a'], ['b']), cfg).tier, 'gameplay', f);
});
test('tier: sensitive paths', () => {
  for (const f of ['server/death-muffin/backend/server.js', 'server/death-muffin/backend/migrations/030-x.sql', 'package.json', 'package-lock.json', '.github/workflows/ci.yml',
    'server/death-muffin/deploy-release.sh', 'CLAUDE.md', 'server/death-muffin/discord-agent/PROMPT.md', 'vite.config.ts', 'src/net/rest.ts', 'tools/x.mjs', 'src/gameplay/progression.ts']) {
    assert.equal(classifyDiff(d(f, ['a'], ['b']), cfg).tier, 'sensitive', f);
  }
});
test('tier: a diff mixing casual + sensitive is sensitive; mixing casual + gameplay is gameplay', () => {
  assert.equal(classifyDiff(d('src/ui/ui.css', ['a'], ['b']) + d('server/death-muffin/backend/server.js', ['a'], ['b']), cfg).tier, 'sensitive');
  assert.equal(classifyDiff(d('src/ui/ui.css', ['a'], ['b']) + d('src/gameplay/Player.ts', ['a'], ['b']), cfg).tier, 'gameplay');
  assert.equal(classifyDiff(d('README.md', ['a'], ['b']) + d('src/ui/ui.css', ['a'], ['b']), cfg).tier, 'casual');
});
test('tier: unknown / empty / binary never casual', () => {
  assert.equal(classifyDiff('', cfg).tier, 'sensitive');
  assert.equal(classifyDiff(d('random.dat', ['a'], ['b']), cfg).tier, 'sensitive');
  assert.equal(classifyDiff('diff --git a/src/ui/logo.png b/src/ui/logo.png\nBinary files a/src/ui/logo.png and b/src/ui/logo.png differ\n', cfg).tier, 'gameplay', 'binary under src is never casual');
});
test('forbidden paths are reported', () => {
  assert.deepEqual(classifyDiff(d('server/death-muffin/discord-agent/PROMPT.md', ['a'], ['b']), cfg).forbidden, ['server/death-muffin/discord-agent/PROMPT.md']);
  assert.deepEqual(classifyDiff(d('server/death-muffin/deploy-release.sh', ['a'], ['b']), cfg).forbidden.length, 1);
  assert.equal(classifyDiff(d('server/death-muffin/backend/server.js', ['a'], ['b']), cfg).forbidden.length, 0);
});
test('labels', () => {
  assert.equal(tierLabel('casual', cfg), 'Casual — Helix or owner can ✅');
  assert.match(tierLabel('sensitive', cfg), /^⚠ Sensitive — owner can ✅$/);
});
test('parseDiff reads files, statuses and hunks', () => {
  const f = parseDiff(dnew('a.css', ['x']) + d('b.ts', ['1', '2'], ['3']));
  assert.equal(f[0].status, 'add'); assert.deepEqual(f[1].hunks[0], { removed: ['1', '2'], added: ['3'] });
});
