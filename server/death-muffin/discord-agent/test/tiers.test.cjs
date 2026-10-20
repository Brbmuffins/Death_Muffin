'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { loadConfig } = require('../runner/lib/config.cjs');
const { parseDiff, classifyDiff, tierLabel } = require('../runner/lib/tiers.cjs');
const { matches } = require('../runner/lib/glob.cjs');

const cfg = loadConfig(null);
cfg.ownerIds = ['111111111111111111']; cfg.project = { requesters: [], approvers: { casual: ['111111111111111111', '142812688358178816'], gameplay: ['111111111111111111'], sensitive: ['111111111111111111'] } };
cfg.names = { '142812688358178816': 'Helix' };

// helper: build a -U0 diff for one file
const d = (file, removed, added, extra = '') => `diff --git a/${file} b/${file}\n${extra}--- a/${file}\n+++ b/${file}\n@@ -1,${removed.length} +1,${added.length} @@\n${removed.map((l) => '-' + l).join('\n')}${removed.length ? '\n' : ''}${added.map((l) => '+' + l).join('\n')}\n`;
const dnew = (file, lines) => `diff --git a/${file} b/${file}\nnew file mode 100644\n--- /dev/null\n+++ b/${file}\n@@ -0,0 +1,${lines.length} @@\n${lines.map((l) => '+' + l).join('\n')}\n`;

test('glob', () => {
  assert.ok(matches('client/**/*.md', 'client/ui/onboarding/README.md')); assert.ok(matches('**/*.gd', 'a.gd'));
  assert.ok(matches('server/**', 'server/death-muffin/backend/server.js')); assert.ok(!matches('server/**', 'client/server.gd'));
  assert.ok(matches('*.md', 'README.md')); assert.ok(!matches('*.md', 'docs/a.md'));
  assert.ok(matches('**/migrations/**', 'server/x/migrations/030.sql'));
});
test('labels', () => {
  assert.equal(tierLabel('casual', cfg), 'Casual — Helix or owner can ✅');
  assert.match(tierLabel('sensitive', cfg), /^⚠ Sensitive — owner can ✅$/);
});
test('parseDiff reads files, statuses and hunks', () => {
  const f = parseDiff(dnew('a.md', ['x']) + d('b.gd', ['1', '2'], ['3']));
  assert.equal(f[0].status, 'add'); assert.deepEqual(f[1].hunks[0], { removed: ['1', '2'], added: ['3'] });
});

// ---------- the tier rules (cfg.tiers): the game is client/ ----------
test('tiers: unknown / empty / binary-in-docs are never casual; a mixed diff is as strict as its strictest file', () => {
  assert.equal(classifyDiff('', cfg).tier, 'sensitive');
  assert.equal(classifyDiff(d('random.dat', ['a'], ['b']), cfg).tier, 'sensitive');
  assert.equal(classifyDiff('diff --git a/docs/logo.png b/docs/logo.png\nBinary files a/docs/logo.png and b/docs/logo.png differ\n', cfg).tier, 'sensitive', 'a binary under docs/ is not a document edit');
  assert.equal(classifyDiff('diff --git a/client/ui/logo.png b/client/ui/logo.png\nBinary files a/client/ui/logo.png and b/client/ui/logo.png differ\n', cfg).tier, 'gameplay');
  assert.equal(classifyDiff(d('PATCH_NOTES.json', ['a'], ['b']) + d('server/death-muffin/backend/server.js', ['a'], ['b']), cfg).tier, 'sensitive');
});
test('forbidden paths are reported', () => {
  assert.deepEqual(classifyDiff(d('server/death-muffin/discord-agent/PROMPT-godot.md', ['a'], ['b']), cfg).forbidden, ['server/death-muffin/discord-agent/PROMPT-godot.md']);
  assert.deepEqual(classifyDiff(d('server/death-muffin/deploy-release.sh', ['a'], ['b']), cfg).forbidden.length, 1);
  assert.equal(classifyDiff(d('server/death-muffin/backend/server.js', ['a'], ['b']), cfg).forbidden.length, 0);
});
const gtier = (file, status = 'modify') => classifyDiff(status === 'add' ? dnew(file, ['x']) : d(file, ['a'], ['b']), cfg).perFile[0].tier;
test('tiers: gameplay is everything else under client/', () => {
  for (const f of ['client/game/dm_game_combat.gd', 'client/rules/combat/dm_damage.gd', 'client/ui/panels_a/dm_vault.gd', 'client/world/dm_fx.gd', 'client/data/content/items.json', 'client/data/loot/content.json', 'client/audio/audio_music.gd', 'client/tests/game/run.gd', 'client/tests/rules_loot/run.gd', 'client/sim/bosses/x.gd', 'client/game_ui/dm_ui_settings.gd', 'client/game/dm_settings.gd'])
    assert.equal(gtier(f), 'gameplay', f);
});
test('tiers: the offline backend, saves, login and net code of the game are all sensitive', () => {
  const real = ['client/net/dm_api.gd', 'client/net/dm_mock_backend.gd', 'client/net/dm_account_prefs.gd', 'client/net/dm_http_transport.gd', 'client/net/dm_config.gd', 'client/net/dm_kill_reporter.gd',
    'client/net/offline/dm_offline_loadout.gd', 'client/net/realtime/dm_rt_client.gd', 'client/net/realtime/dm_rt_rejoin_store.gd', 'client/net/relay/dm_relay_peer.gd', 'client/net/relay/dm_lobby_client.gd',
    'client/front/dm_login_screen.gd', 'client/front/dm_char_select_screen.gd', 'client/front/dm_front_flow.gd',
    'client/game/dm_offline.gd', 'client/game/dm_progress_sync.gd', 'client/game/dm_game_coop.gd', 'client/game/dm_gather_session.gd', 'client/main/main.gd',
    'client/data/content/gameplay_authorityRules.json', 'client/project.godot', 'client/export_presets.cfg', 'client/addons/x/plugin.gd', 'client/backend/x.gd', 'client/anything/my_online_mode.gd', 'client/x/save_slots.gd',
    'client/rules/progression/progression.gd', 'client/rules/progression/kill_chain.gd', 'client/rules/progression/milestones.gd', 'client/data/progression/content.json', 'client/data/combat/progression.json',
    'client/data/content/gameplay_killCredit.json', 'client/data/content/gameplay_goldSinkRules.json', 'client/data/content/gameplay_vaultRules.json', 'client/data/content/gameplay_laborRules.json', 'client/data/content/gameplay_legionRules.json',
    'client/data/content/gameplay_milestones.json', 'client/data/content/tradeGoods.json', 'client/rules/gathering/gold_sink_rules.gd', 'client/rules/inventory/vault_rules.gd', 'client/rules/gathering/labor_rules.gd',
    'client/game/dm_game_rewards.gd', 'client/rules/loot/depths_rewards.gd', 'client/ui/panels_b/dm_acre_ledger.gd', 'client/x/economy_rules.gd', 'client/x/spend_gold.gd', 'client/x/unlock_gate.gd', 'client/x/seal_state.gd', 'client/tests/rules_progression/run.gd',
    'client/tests/backend/run.gd', 'client/tests/backend/net_part.gd', 'client/tests/relay/run.gd', 'client/tests/realtime/run.gd', 'client/bin/native.gdextension', 'client/x/lib.dll', 'client/x/b.pck'];
  for (const f of real) assert.equal(gtier(f), 'sensitive', f);
});
test('tiers: server, launcher, tools, CI, scripts, deploy and config files are sensitive; so is anything unmatched (root files, old paths)', () => {
  for (const f of ['server/death-muffin/backend/server.js', 'launcher/src/main.ts', 'tools/godot/run-all-tests.sh', 'tools/godot/fixtures-loot.ts', '.github/workflows/ci.yml', 'client/shoot.sh', 'client/tests/x/run.sh', 'scripts/deploy-x', 'CLAUDE.md', '.claude/settings.json', '.env', 'client/.env.local', '.gitignore',
    'src/gameplay/a.ts', 'package.json', 'ROADMAP.md.txt', 'vite.config.ts', 'Inspiration ART/x.png'])
    assert.equal(gtier(f), 'sensitive', f);
});
test('tiers: the combat core and the files the art pack is fingerprinted by are sensitive', () => {
  for (const f of ['native/src/core/world.cpp', 'native/SConstruct', 'native/README.md.bak', 'client/core/dm_core_host.gd', 'client/crowd/crowd_baker.gd', 'client/crowd/crowd_looks.json',
    'client/tools/bake_crowd.gd', 'client/game/view_models.json', 'client/game/dm_creature.gd', 'client/game/dm_gear_props.gd', 'client/world/dm_models.gd', 'client/world/dm_animator.gd',
    'client/main/qa_driver.gd', 'client/session/s.gd'])
    assert.equal(gtier(f), 'sensitive', f);
  assert.equal(gtier('native/README.md'), 'sensitive', 'a document inside a sensitive area is sensitive too');
});
test('tiers: docs, markdown and patch notes are casual (any content), but never inside a sensitive area', () => {
  for (const f of ['docs/GRIND-LOOP.md', 'docs/anything.txt', 'README.md', 'ROADMAP.md', 'client/README.md', 'client/ui/onboarding/README.md', 'PATCH_NOTES.json'])
    assert.equal(gtier(f), 'casual', f);
  assert.equal(gtier('docs/new.md', 'add'), 'casual');
  for (const f of ['server/README.md', 'tools/godot/README.md', 'client/net/REALTIME.md', '.github/pull_request_template.md', 'client/front/NOTES.md', 'client/docs/save-format.md'])
    assert.equal(gtier(f), 'sensitive', f);
  // a mixed diff is as strict as its strictest file; docs + gameplay = gameplay, + net = sensitive
  assert.equal(classifyDiff(d('client/README.md', ['a'], ['b']) + d('client/game/dm_game.gd', ['a'], ['b']), cfg).tier, 'gameplay');
  assert.equal(classifyDiff(d('client/game/dm_game.gd', ['a'], ['b']) + d('client/net/dm_api.gd', ['a'], ['b']), cfg).tier, 'sensitive');
  assert.equal(classifyDiff(d('client/README.md', ['a'], ['b']), cfg).tier, 'casual');
});
test('tiers: forbidden paths keep the agent/deploy/.env/.claude rules and add client/export_presets.cfg', () => {
  const f = classifyDiff(d('client/export_presets.cfg', ['a'], ['b']) + d('server/death-muffin/discord-agent/ship.sh', ['a'], ['b']) + d('client/ok.gd', ['a'], ['b']) + d('.claude/x.json', ['a'], ['b']) + d('tools/deploy-x.sh', ['a'], ['b']), cfg);
  assert.deepEqual(f.forbidden.sort(), ['.claude/x.json', 'client/export_presets.cfg', 'server/death-muffin/discord-agent/ship.sh', 'tools/deploy-x.sh']);
  assert.deepEqual(loadConfig(null).forbiddenPaths.slice(0, 4), ['server/death-muffin/discord-agent/**', '**/deploy*.sh', '**/.env*', '.claude/**']);
});
