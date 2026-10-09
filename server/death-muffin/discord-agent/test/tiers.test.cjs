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
  assert.equal(classifyDiff(d('server/rules/content/items.ts', ["  name: 'Rusty Nail',"], ["  name: 'Old Nail',"]), cfg).tier, 'casual');
  assert.equal(classifyDiff(d('server/rules/content/items.ts', ["  id: 'nail',"], ["  id: 'nail2',"]), cfg).tier, 'gameplay');
});
test('tier: balance numbers within 25% casual, beyond gameplay', () => {
  assert.equal(classifyDiff(d('server/rules/content/enemies.ts', ['  hp: 200,'], ['  hp: 240,']), cfg).tier, 'casual');
  assert.equal(classifyDiff(d('server/rules/content/enemies.ts', ['  hp: 200,'], ['  hp: 300,']), cfg).tier, 'gameplay');
  assert.equal(classifyDiff(dnew('server/rules/content/enemies.ts', ['  hp: 200,']), cfg).tier, 'gameplay', 'new content file is not a number tweak');
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

// ---- generated (derived) files ----
const { GENERATED } = require('../runner/lib/generated.cjs');
const gen = 'server/vps-handoff/necro-progress/necro-rules.cjs';
test('derived generated files are tier-neutral and not forbidden; undeclared ones still escalate', () => {
  const diff = d('src/gameplay/a.ts', ['speed=1'], ['speed=9']) + d(gen, ['SPEED=1'], ['SPEED=9']) + d('server/death-muffin/deploy-release.sh', ['a'], ['b']);
  const plain = classifyDiff(diff, cfg);
  assert.equal(plain.tier, 'sensitive'); assert.deepEqual(plain.forbidden, ['server/death-muffin/deploy-release.sh']);
  const c = classifyDiff(diff, cfg, [gen, 'server/death-muffin/deploy-release.sh']);
  assert.equal(c.tier, 'gameplay'); assert.deepEqual(c.forbidden, []);
  assert.deepEqual(c.perFile.map((f) => f.tier), ['gameplay', 'derived', 'derived']);
  // an unverified generated file (not in `derived`) still counts
  assert.equal(classifyDiff(diff, cfg, [gen]).tier, 'sensitive');
  // only derived files: nothing real to judge -> sensitive
  assert.equal(classifyDiff(d(gen, ['a'], ['b']), cfg, [gen]).tier, 'sensitive');
  // casual source + derived stays casual
  assert.equal(classifyDiff(d('src/ui/ui.css', ['a'], ['b']) + d('docs/LOOT-TABLES.md', ['a'], ['b']), cfg, ['docs/LOOT-TABLES.md']).tier, 'casual');
});
test('GENERATED lists exactly the outputs of tools/build-server-rules.mjs plus the loot doc', () => {
  const fs = require('fs'), path = require('path');
  const root = path.resolve(__dirname, '../../../..');
  const f = path.join(root, 'tools/build-server-rules.mjs');
  if (!fs.existsSync(f)) return;   // installed copy without the repo
  const outs = [...fs.readFileSync(f, 'utf8').matchAll(/out: join\(root, '([^']+)'\)/g)].map((m) => m[1]);
  assert.ok(outs.length >= 15);
  assert.deepEqual([...GENERATED].sort(), [...outs, 'docs/LOOT-TABLES.md'].sort());
});

// ---------- godot mode tiers (cfg.tiers = godotTiers) ----------
const gcfg = (() => { const f = require('path').join(require('fs').mkdtempSync(require('path').join(require('os').tmpdir(), 'dm-gt-')), 'c.json'); require('fs').writeFileSync(f, JSON.stringify({ mode: 'godot', baseBranch: 'godot-port' })); const c = loadConfig(f); c.ownerIds = ['111111111111111111']; c.project = cfg.project; return c; })();
const gtier = (file, status = 'modify') => classifyDiff(status === 'add' ? dnew(file, ['x']) : d(file, ['a'], ['b']), gcfg).perFile[0].tier;
test('godot tiers: gameplay is everything else under godot/', () => {
  for (const f of ['godot/game/dm_game_combat.gd', 'godot/rules/combat/dm_damage.gd', 'godot/ui/panels_a/dm_vault.gd', 'godot/world/dm_fx.gd', 'godot/data/content/items.json', 'godot/data/loot/content.json', 'godot/audio/audio_music.gd', 'godot/tests/game/run.gd', 'godot/tests/rules-loot/run.gd', 'godot/sim/bosses/x.gd', 'godot/game_ui/dm_ui_settings.gd', 'godot/game/dm_settings.gd'])
    assert.equal(gtier(f), 'gameplay', f);
});
test('godot tiers: the offline backend, saves, login and net code of the real godot-port tree are all sensitive', () => {
  const real = ['godot/net/dm_api.gd', 'godot/net/dm_mock_backend.gd', 'godot/net/dm_account_prefs.gd', 'godot/net/dm_http_transport.gd', 'godot/net/dm_config.gd', 'godot/net/dm_kill_reporter.gd',
    'godot/net/offline/dm_offline_loadout.gd', 'godot/net/realtime/dm_rt_client.gd', 'godot/net/realtime/dm_rt_rejoin_store.gd', 'godot/net/relay/dm_relay_peer.gd', 'godot/net/relay/dm_lobby_client.gd',
    'godot/front/dm_login_screen.gd', 'godot/front/dm_char_select_screen.gd', 'godot/front/dm_front_flow.gd',
    'godot/game/dm_offline.gd', 'godot/game/dm_progress_sync.gd', 'godot/game/dm_game_coop.gd', 'godot/game/dm_gather_session.gd', 'godot/main/main.gd',
    'godot/data/content/gameplay_authorityRules.json', 'godot/project.godot', 'godot/export_presets.cfg', 'godot/addons/x/plugin.gd', 'godot/backend/x.gd', 'godot/anything/my_online_mode.gd', 'godot/x/save_slots.gd',
    'godot/rules/progression/progression.gd', 'godot/rules/progression/kill_chain.gd', 'godot/rules/progression/milestones.gd', 'godot/data/progression/content.json', 'godot/data/combat/progression.json',
    'godot/data/content/gameplay_killCredit.json', 'godot/data/content/gameplay_goldSinkRules.json', 'godot/data/content/gameplay_vaultRules.json', 'godot/data/content/gameplay_laborRules.json', 'godot/data/content/gameplay_legionRules.json',
    'godot/data/content/gameplay_milestones.json', 'godot/data/content/tradeGoods.json', 'godot/rules/gathering/gold_sink_rules.gd', 'godot/rules/inventory/vault_rules.gd', 'godot/rules/gathering/labor_rules.gd',
    'godot/game/dm_game_rewards.gd', 'godot/rules/loot/depths_rewards.gd', 'godot/ui/panels_b/dm_acre_ledger.gd', 'godot/x/economy_rules.gd', 'godot/x/spend_gold.gd', 'godot/x/unlock_gate.gd', 'godot/x/seal_state.gd', 'godot/tests/rules-progression/run.gd',
    'godot/tests/net/run.gd', 'godot/tests/relay/run.gd', 'godot/tests/offline/run.gd', 'godot/tests/realtime/run.gd', 'godot/tests/online_local/run.gd', 'godot/tests/front/run.gd', 'godot/bin/native.gdextension', 'godot/x/lib.dll', 'godot/x/b.pck'];
  for (const f of real) assert.equal(gtier(f), 'sensitive', f);
});
test('godot tiers: server, launcher, tools, CI, scripts, deploy and config files are sensitive; so is anything unmatched (the frozen web src/, root files)', () => {
  for (const f of ['server/death-muffin/backend/server.js', 'launcher/src/main.ts', 'tools/godot/run-all-tests.sh', 'tools/godot/fixtures-loot.ts', '.github/workflows/ci.yml', 'godot/shoot.sh', 'godot/tests/x/run.sh', 'scripts/deploy-x', 'CLAUDE.md', '.claude/settings.json', '.env', 'godot/.env.local', '.gitignore',
    'src/gameplay/a.ts', 'package.json', 'ROADMAP.md.txt', 'vite.config.ts', 'Inspiration ART/x.png'])
    assert.equal(gtier(f), 'sensitive', f);
});
test('godot tiers: docs, markdown and patch notes are casual (any content), but never inside a sensitive area', () => {
  for (const f of ['docs/GRIND-LOOP.md', 'docs/anything.txt', 'README.md', 'ROADMAP.md', 'godot/README.md', 'godot/ui/onboarding/README.md', 'PATCH_NOTES.json'])
    assert.equal(gtier(f), 'casual', f);
  assert.equal(gtier('docs/new.md', 'add'), 'casual');
  for (const f of ['server/README.md', 'tools/godot/README.md', 'godot/net/REALTIME.md', '.github/pull_request_template.md', 'godot/front/NOTES.md', 'godot/docs/save-format.md'])
    assert.equal(gtier(f), 'sensitive', f);
  // a mixed diff is as strict as its strictest file; docs + gameplay = gameplay, + net = sensitive
  assert.equal(classifyDiff(d('godot/README.md', ['a'], ['b']) + d('godot/game/dm_game.gd', ['a'], ['b']), gcfg).tier, 'gameplay');
  assert.equal(classifyDiff(d('godot/game/dm_game.gd', ['a'], ['b']) + d('godot/net/dm_api.gd', ['a'], ['b']), gcfg).tier, 'sensitive');
  assert.equal(classifyDiff(d('godot/README.md', ['a'], ['b']), gcfg).tier, 'casual');
});
test('godot tiers: forbidden paths keep the agent/bug-agent/deploy/.env/.claude rules and add godot/export_presets.cfg; web mode is unaffected by godotTiers', () => {
  const f = classifyDiff(d('godot/export_presets.cfg', ['a'], ['b']) + d('server/death-muffin/discord-agent/ship.sh', ['a'], ['b']) + d('godot/ok.gd', ['a'], ['b']) + d('.claude/x.json', ['a'], ['b']) + d('tools/deploy-x.sh', ['a'], ['b']), gcfg);
  assert.deepEqual(f.forbidden.sort(), ['.claude/x.json', 'godot/export_presets.cfg', 'server/death-muffin/discord-agent/ship.sh', 'tools/deploy-x.sh']);
  assert.equal(classifyDiff(d('godot/game/dm_game.gd', ['a'], ['b']), cfg).perFile[0].tier, 'sensitive', 'web tiers: godot/ is unmatched, so sensitive');
  assert.equal(classifyDiff(d('src/gameplay/a.ts', ['a'], ['b']), cfg).perFile[0].tier, 'gameplay');
  assert.deepEqual(loadConfig(null).forbiddenPaths.slice(0, 5), ['server/death-muffin/discord-agent/**', 'server/death-muffin/bug-agent/**', '**/deploy*.sh', '**/.env*', '.claude/**']);
});
