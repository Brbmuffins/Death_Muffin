// node --test tools/godot/test/affected-suites.test.mjs
import test from 'node:test';
import assert from 'node:assert/strict';
import { affected, SMOKE, dataPatterns, centralReason } from '../affected-suites.mjs';

const suites = ['data', 'status', 'session_report', 'next', 'next_front', 'enemies', 'loot_view', 'gear', 'hud', 'fx', 'world', 'sim', 'thralls', 'rites', 'ui', 'game'];
// tests: [suite-file, text]; src: [file, text]; classes: file -> class_name
function mk({ tests = [], src = [], classes = {} } = {}) {
  const hit = (list, p) => list.filter(([, t]) => p.fixed.some((x) => t.includes(x)) || p.words.some((w) => new RegExp(`\\b${w}\\b`).test(t))).map(([f]) => f);
  return { suites, testsOnly: (p) => hit(tests, p), srcOnly: (p) => hit(src, p), classNameOf: (f) => classes[f] || null };
}
const sel = (r) => { assert.equal(r.all, false, r.why); return r.selectors; };

test('docs-only and non-godot changes need no suites', () => {
  assert.deepEqual(sel(affected(['README.md', 'docs/x.md', 'godot/next/README.md'], mk())), []);
  assert.deepEqual(sel(affected(['server/death-muffin/auth/x.ts'], mk())), []);
  assert.deepEqual(sel(affected(['godot/foo.gd.uid'], mk())), []);
});
test('central files fall back to ALL', () => {
  for (const f of ['godot/project.godot', 'godot/export_presets.cfg', 'godot/main/main.gd', 'godot/audio/audio_director.gd', 'godot/fx/dm_fx.gd',
    'godot/rules/core/dm_db.gd', 'godot/net/x.gd', 'godot/session/s.gd', 'godot/tests/common/dm_test_ports.gd', 'tools/godot/run-all-tests.sh']) {
    assert.equal(affected([f, 'godot/enemies/a.gd'], mk()).all, true, f);
  }
  assert.equal(centralReason('godot/enemies/a.gd'), null);
});
test('a changed suite file selects its dir plus smoke', () => {
  assert.deepEqual(sel(affected(['godot/tests/enemies/kinds_run.gd'], mk())), [...new Set([...SMOKE, 'enemies'])].sort());
});
test('a script is found by res:// path and by class_name in tests', () => {
  const ctx = mk({
    tests: [['godot/tests/hud/run.gd', 'preload("res://hud/bar.gd")'], ['godot/tests/gear/run.gd', 'var x := DmGear.new()'], ['godot/tests/world/run.gd', 'DmGearish.x']],
    classes: { 'godot/gear/gear.gd': 'DmGear' },
  });
  const s = sel(affected(['godot/hud/bar.gd', 'godot/gear/gear.gd'], ctx));
  assert.ok(s.includes('hud') && s.includes('gear') && !s.includes('world'), s.join());
  for (const m of SMOKE) assert.ok(s.includes(m));
});
test('one level of dependents is followed', () => {
  const ctx = mk({
    src: [['godot/hud/panel.gd', 'DmBar.draw()']],
    tests: [['godot/tests/hud/run.gd', 'preload("res://hud/panel.gd")']],
    classes: { 'godot/hud/bar.gd': 'DmBar' },
  });
  assert.ok(sel(affected(['godot/hud/bar.gd'], ctx)).includes('hud'));
});
test('data files map to their readers', () => {
  assert.ok(dataPatterns('godot/data/content/items.json').includes('content("items"'));
  assert.ok(dataPatterns('godot/data/combat/enemies.json').includes('combat("enemies"'));
  assert.equal(dataPatterns('godot/hud/x.gd'), null);
  const ctx = mk({
    src: [['godot/enemies/kinds.gd', 'DmDb.combat("enemies")']],
    tests: [['godot/tests/enemies/kinds_run.gd', 'preload("res://enemies/kinds.gd")']],
  });
  const s = sel(affected(['godot/data/combat/enemies.json'], ctx));
  assert.ok(s.includes('enemies') && s.includes('data'));
  // a literal res:// path in a test counts too
  const s2 = sel(affected(['godot/data/sim/world.json'], mk({ tests: [['godot/tests/sim/run.gd', 'load_json("res://data/sim/world.json")']] })));
  assert.ok(s2.includes('sim'));
});
test('the content manifest is central', () => assert.equal(affected(['godot/data/content/manifest.json'], mk()).all, true));
test('too many .gd files, or too wide a target, fall back to ALL', () => {
  const many = Array.from({ length: 41 }, (_, i) => `godot/hud/f${i}.gd`);
  assert.equal(affected(many, mk()).all, true);
  const wide = suites.map((s) => `godot/tests/${s}/run.gd`);
  assert.equal(affected(wide, mk()).all, true);
});
test('an unreferenced asset still gets the smoke set', () => {
  assert.deepEqual(sel(affected(['godot/assets/slice/a.png'], mk())), [...SMOKE].sort());
});
