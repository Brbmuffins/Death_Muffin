// node --test tools/rebuild/test/affected-suites.test.mjs (npm run test:server)
import test from 'node:test';
import assert from 'node:assert/strict';
import { affected, SMOKE, dataPatterns, centralReason } from '../affected-suites.mjs';

const suites = ['code_load', 'core_smoke', 'game_scene', 'rules-core', 'front', 'enemies', 'loot_view', 'gear', 'hud', 'fx', 'world', 'sim', 'thralls', 'rites', 'ui', 'game', 'backend'];
// tests: [suite-file, text]; src: [file, text]; classes: file -> class_name
function mk({ tests = [], src = [], classes = {} } = {}) {
  const hit = (list, p) => list.filter(([, t]) => p.fixed.some((x) => t.includes(x)) || p.words.some((w) => new RegExp(`\\b${w}\\b`).test(t))).map(([f]) => f);
  return { suites, testsOnly: (p) => hit(tests, p), srcOnly: (p) => hit(src, p), classNameOf: (f) => classes[f] || null };
}
const sel = (r) => { assert.equal(r.all, false, r.why); return r.selectors; };

test('docs-only and other changes outside the game need no suites', () => {
  assert.deepEqual(sel(affected(['README.md', 'docs/x.md', 'client/next/README.md'], mk())), []);
  assert.deepEqual(sel(affected(['server/death-muffin/auth/x.ts'], mk())), []);
  assert.deepEqual(sel(affected(['client/foo.gd.uid'], mk())), []);
});
test('central files fall back to ALL', () => {
  for (const f of ['client/project.godot', 'client/export_presets.cfg', 'client/main/main.gd', 'client/audio/audio_director.gd', 'client/fx/dm_fx.gd',
    'client/rules/core/dm_db.gd', 'client/net/x.gd', 'client/session/s.gd', 'client/tests/common/dm_test_ports.gd', 'tools/rebuild/run-client-tests.sh',
    'client/core/dm_core_host.gd', 'native/src/core/world.cpp']) {
    assert.equal(affected([f, 'client/enemies/a.gd'], mk()).all, true, f);
  }
  assert.equal(centralReason('client/enemies/a.gd'), null);
});
test('a changed suite (its script, or a file of a folder suite) selects it plus smoke', () => {
  assert.deepEqual(sel(affected(['client/tests/enemies.gd'], mk())), [...new Set([...SMOKE, 'enemies'])].sort());
  assert.deepEqual(sel(affected(['client/tests/backend/test_routes.gd'], mk())), [...new Set([...SMOKE, 'backend'])].sort());
  assert.deepEqual(sel(affected(['client/tests/boss_base.gd'], mk())), [...SMOKE].sort(), 'a helper no suite is named after');
});
test('a folder with several runners: a file in it selects every runner of that folder', () => {
  const ctx = { ...mk(), suites: [...suites, 'next_lobby', 'next_lobby/ui_run', 'next_lobby/proc_run', 'relay/udp_run'] };
  assert.deepEqual(sel(affected(['client/tests/next_lobby/helpers.gd'], ctx)), [...new Set([...SMOKE, 'next_lobby', 'next_lobby/proc_run', 'next_lobby/ui_run'])].sort());
  assert.deepEqual(sel(affected(['client/tests/relay/udp_run.gd'], ctx)), [...new Set([...SMOKE, 'relay/udp_run'])].sort());
});
test('a script is found by res:// path and by class_name in tests', () => {
  const ctx = mk({
    tests: [['client/tests/hud/run.gd', 'preload("res://hud/bar.gd")'], ['client/tests/gear/run.gd', 'var x := DmGear.new()'], ['client/tests/world/run.gd', 'DmGearish.x']],
    classes: { 'client/gear/gear.gd': 'DmGear' },
  });
  const s = sel(affected(['client/hud/bar.gd', 'client/gear/gear.gd'], ctx));
  assert.ok(s.includes('hud') && s.includes('gear') && !s.includes('world'), s.join());
  for (const m of SMOKE) assert.ok(s.includes(m));
});
test('one level of dependents is followed', () => {
  const ctx = mk({
    src: [['client/hud/panel.gd', 'DmBar.draw()']],
    tests: [['client/tests/hud/run.gd', 'preload("res://hud/panel.gd")']],
    classes: { 'client/hud/bar.gd': 'DmBar' },
  });
  assert.ok(sel(affected(['client/hud/bar.gd'], ctx)).includes('hud'));
});
test('data files map to their readers', () => {
  assert.ok(dataPatterns('client/data/content/items.json').includes('content("items"'));
  assert.ok(dataPatterns('client/data/combat/enemies.json').includes('combat("enemies"'));
  assert.equal(dataPatterns('client/hud/x.gd'), null);
  const ctx = mk({
    src: [['client/enemies/kinds.gd', 'DmDb.combat("enemies")']],
    tests: [['client/tests/enemies/kinds_run.gd', 'preload("res://enemies/kinds.gd")']],
  });
  const s = sel(affected(['client/data/combat/enemies.json'], ctx));
  assert.ok(s.includes('enemies') && SMOKE.every((m) => s.includes(m)), s.join());
  // a literal res:// path in a test counts too
  const s2 = sel(affected(['client/data/sim/world.json'], mk({ tests: [['client/tests/sim/run.gd', 'load_json("res://data/sim/world.json")']] })));
  assert.ok(s2.includes('sim'));
});
test('the content manifest is central', () => assert.equal(affected(['client/data/content/manifest.json'], mk()).all, true));
test('too many .gd files, or too wide a target, fall back to ALL', () => {
  const many = Array.from({ length: 41 }, (_, i) => `client/hud/f${i}.gd`);
  assert.equal(affected(many, mk()).all, true);
  const wide = suites.map((s) => `client/tests/${s}/run.gd`);
  assert.equal(affected(wide, mk()).all, true);
});
test('an unreferenced asset still gets the smoke set', () => {
  assert.deepEqual(sel(affected(['client/assets/slice/a.png'], mk())), [...SMOKE].sort());
});
test('an add-only change to the API client or mock selects the users of the added functions and routes, not ALL', () => {
  const added = { 'client/net/dm_api.gd': ['func vault_withdraw_many(character_id: int, slots: Array) -> DmResult:', '\treturn await _post("/api/vault/withdraw-many", {})'],
    'client/net/dm_mock_backend.gd': ['\t\t"/api/vault/withdraw-many":', '\t\t\treturn _take(body)'] };
  const ctx = { ...mk({
    src: [['client/game_ui/panels.gd', 'DmApi.vault_withdraw_many(1, [])'], ['client/hud/other.gd', 'DmApi.login()']],
    tests: [['client/tests/ui/run.gd', 'preload("res://game_ui/panels.gd")'], ['client/tests/backend/test_routes.gd', '"/api/vault/withdraw-many"'], ['client/tests/hud/run.gd', 'DmApi.x()']],
    classes: { 'client/net/dm_api.gd': 'DmApi' },
  }), addedLines: (f) => added[f] || null };
  const s = sel(affected(['client/net/dm_api.gd', 'client/net/dm_mock_backend.gd'], ctx));
  assert.ok(s.includes('ui') && s.includes('backend') && !s.includes('hud'), s.join());
  // any removed or edited line (addedLines null), or another net file, stays central
  assert.equal(affected(['client/net/dm_api.gd'], { ...ctx, addedLines: () => null }).all, true);
  assert.equal(affected(['client/net/dm_config.gd'], ctx).all, true);
});
test('a content table change also runs rules-core (it checks the manifest counts)', () => {
  assert.ok(sel(affected(['client/data/content/audioMap.json'], mk())).includes('rules-core'));
  assert.ok(!sel(affected(['client/hud/x.gd'], mk())).includes('rules-core'));
});
