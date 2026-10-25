'use strict';
// The clip request (.dm-clip.json) and the shot plan the agent leaves for a team PC: what the runner accepts before anything is sent.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs'), os = require('os'), path = require('path');
const C = require('../runner/lib/clips.cjs');

const wt = () => fs.mkdtempSync(path.join(os.tmpdir(), 'dm-clips-'));
const GOOD = () => ({
  plan: { discipline: 'reaper', clips: [{ name: 'wraith', area: 'graves', cast: 'haunting_wraith', at: 'pack', enemies: 6, seconds: 5, camera: 'follow' }] },
  variants: [{ label: 'slow', title: 'slow (speed 4)', tune: { 'combat/abilities': { haunting_wraith: { speed: 4, homing: true, tint: 'violet' } } } }, { label: 'now', title: 'as it is now', tune: {} }],
});
const read = (j, raw) => { const d = wt(); fs.writeFileSync(path.join(d, C.CLIP_FILE), raw != null ? raw : JSON.stringify(j)); return C.readClipRequest(d); };
const mutate = (f) => { const j = GOOD(); f(j); return j; };

test('clips: no file is no request; a good one is read as written', () => {
  assert.equal(C.readClipRequest(wt()), null);
  const r = read(GOOD());
  assert.equal(r.error, undefined); assert.equal(r.plan.discipline, 'reaper'); assert.equal(r.plan.clips[0].name, 'wraith');
  assert.deepEqual(r.variants.map((v) => v.label), ['slow', 'now']); assert.deepEqual(r.variants[1].tune, {});
  assert.equal(C.clipMinutes(r.plan, r.variants), 3, '2 options x (60 s start-up + 2 x 5 s) is a little over 2 minutes');
  assert.equal(C.clipMinutes({ clips: [{ seconds: 8 }, { seconds: 8 }, { seconds: 8 }, { seconds: 8 }] }, [1, 2, 3, 4]), 9);
});

test('clips: every refusal is a readable line naming the problem', () => {
  const bad = (f, re) => { const r = read(mutate(f)); assert.ok(r && r.error, 'refused'); assert.match(r.error, re); };
  bad((j) => { j.variants = []; }, /"variants" must be a list of 1 to 4 options/);
  bad((j) => { j.variants = [1, 2, 3, 4, 5].map((n) => ({ label: `v${n}`, title: `v${n}`, tune: {} })); }, /1 to 4 options/);
  bad((j) => { j.variants[0].label = 'Slow!'; }, /variant 1: "label" must be lowercase letters, digits and dashes/);
  bad((j) => { j.variants[1].label = 'slow'; }, /the label "slow" is used twice/);
  bad((j) => { j.variants[0].label = 'a'.repeat(25); }, /"label"/);
  bad((j) => { j.variants[0].title = ''; }, /"title" is what people read/);
  bad((j) => { j.variants[0].title = 'x'.repeat(61); }, /"title"/);
  bad((j) => { j.variants[0].extra = 1; }, /variant 1 has an unknown field "extra"/);
  bad((j) => { j.variants[0].tune = [1]; }, /"tune" must be an object/);
  bad((j) => { j.variants[0].tune = { 'combat/abilities': { haunting_wraith: { speed: null } } }; }, /combat\/abilities\.haunting_wraith\.speed must be a number, text or true\/false/);
  bad((j) => { j.variants[0].tune = { 'combat/abilities': { haunting_wraith: { tint: [1, 0, 0] } } }; }, /a list or null cannot be tuned/);
  bad((j) => { j.variants[0].tune = { 'combat/abilities': { speed: Infinity } }; }, /JSON|finite|must be/);
  bad((j) => { j.variants[0].tune = JSON.parse('{"__proto__": {"x": 1}}'); }, /"__proto__" is not a data key/);
  bad((j) => { j.variants[0].tune = { 'bad key!': { a: 1 } }; }, /"bad key!" is not a data key/);
  bad((j) => { j.variants[0].tune = { a: { b: { c: { d: { e: { f: { g: 1 } } } } } } }; }, /nests deeper than 6 levels/);
  bad((j) => { j.variants[0].tune = { a: Object.fromEntries(Array.from({ length: 65 }, (_, i) => [`k${i}`, i])) }; }, /sets 65 values \(at most 64\)/);
  bad((j) => { j.plan.discipline = 'warlock'; }, /plan\.discipline" must be one of ossuary, gravecaller, mourner, rotweaver, reaper/);
  bad((j) => { j.plan.clips = []; }, /1 to 4 clips/);
  bad((j) => { j.plan.clips = Array.from({ length: 5 }, (_, i) => ({ name: `c${i}`, area: 'graves', cast: 'x', seconds: 3 })); }, /1 to 4 clips/);
  bad((j) => { j.plan.clips[0].seconds = 9; }, /"seconds" must be a number above 0 and at most 8/);
  bad((j) => { j.plan.clips[0].seconds = 0; }, /"seconds"/);
  bad((j) => { j.plan.clips[0].name = 'a_b'; }, /"name" must be lowercase letters, digits and dashes/);
  bad((j) => { j.plan.clips.push({ ...j.plan.clips[0] }); }, /the name "wraith" is used twice/);
  bad((j) => { j.plan.clips[0].at = 'behind'; }, /"at" must be "pack" or "ahead"/);
  bad((j) => { j.plan.clips[0].camera = 'top'; }, /"camera" must be "follow", "wide" or "turntable"/);
  bad((j) => { j.plan.clips[0].enemies = 99; }, /"enemies" must be a whole number from 0 to 12/);
  bad((j) => { j.plan.clips[0].area = 'The Graves'; }, /"area" must be an area id/);
  bad((j) => { j.plan.clips[0].equip = []; }, /clip 1: "equip" must be a list of 1 to 12 item ids/);
  bad((j) => { j.plan.clips[0].equip = ['Iron Staff']; }, /"equip" must be a list of 1 to 12 item ids/);
  bad((j) => { j.plan.equip = Array.from({ length: 13 }, (_, i) => `item_${i}`); }, /"plan": "equip" must be a list of 1 to 12 item ids/);
  bad((j) => { j.plan.equip = ['staff_moon', 'staff_moon']; }, /"equip" names an item twice/);
  bad((j) => { j.plan.clips[0].cast = undefined; }, /"cast" must be a rite id.*only a "turntable" or model clip, one whose steps cast, or a scene of thralls or walks may leave it out/);
  bad((j) => { j.plan.clips[0].camera = 'orbit'; }, /"camera" must be "follow", "wide" or "turntable"/);
  bad((j) => { j.plan.clips[0].cast = 'Haunting Wraith'; }, /"cast" must be a rite id/);
  bad((j) => { j.plan.clips[0].exec = 'rm -rf'; }, /clip 1 has an unknown field "exec"/);
  bad((j) => { j.plan.hack = 1; }, /"plan" has an unknown field "hack"/);
  bad((j) => { j.other = 1; }, /\.dm-clip\.json has an unknown field "other"/);
  assert.match(read(null, 'not json').error, /not valid JSON/);
  assert.match(read(null, '[1]').error, /must be a JSON object/);
  assert.match(read(null, JSON.stringify({ plan: GOOD().plan, variants: [{ label: 'a', title: 'a', tune: { pad: 'x'.repeat(40000) } }] })).error, /at most 32 KB/);
  // many problems are cut off, not dumped
  const many = read(mutate((j) => { j.variants = [{}, {}, {}, {}]; j.plan.discipline = 'x'; })); assert.match(many.error, /and \d+ more/);
});

test('clips: a model preview is a turntable clip on a hero that wears items; area and seconds have defaults', () => {
  const ok = (j) => { const r = read(j); assert.equal(r.error, undefined, r.error); return r; };
  const turn = { plan: { discipline: 'gravecaller', equip: ['set_gravecaller_chest', 'staff_moon'], clips: [{ name: 'set', camera: 'turntable', seconds: 6 }, { name: 'weapon', camera: 'turntable', equip: ['staff_moon'] }] }, variants: [{ label: 'set', title: 'the set, turning', tune: {} }] };
  const r = ok(turn); assert.deepEqual(r.plan.equip, ['set_gravecaller_chest', 'staff_moon']); assert.deepEqual(r.plan.clips[1].equip, ['staff_moon']); assert.equal(r.plan.clips[0].cast, undefined);
  assert.equal(C.clipMinutes(r.plan, r.variants), 2, '(60 + 2 x (6 + 5 by default)) s for one option');
  ok(mutate((j) => { delete j.plan.clips[0].area; delete j.plan.clips[0].seconds; }));
  ok(mutate((j) => { j.plan.clips[0].camera = 'turntable'; delete j.plan.clips[0].cast; }));
});

test('clips: a model clip films one model alone: no cast, its own fields checked, and only on a model clip', () => {
  const r = read({ plan: { discipline: 'gravecaller', clips: [{ name: 'rat-walk', model: 'skull_rat', anim: 'walk', move: true }, { name: 'rat-turn', model: 'skull_rat', camera: 'turntable', turn: 0, height: 0.6 }] }, variants: [{ label: 'rat', title: 'the skull rat', tune: {} }] });
  assert.equal(r.error, undefined, r.error); assert.equal(r.plan.clips[0].cast, undefined); assert.equal(r.plan.clips[0].model, 'skull_rat');
  const bad = (f, re) => { const x = read(mutate(f)); assert.ok(x && x.error, 'refused'); assert.match(x.error, re); };
  bad((j) => { j.plan.clips[0].model = 'Skull Rat'; }, /"model" must be a model row id/);
  bad((j) => { j.plan.clips[0].model = 'skull_rat'; j.plan.clips[0].camera = 'wide'; }, /a model clip's "camera" is "follow"/);
  bad((j) => { j.plan.clips[0].model = 'skull_rat'; j.plan.clips[0].speed = 99; }, /"speed" must be a number from 0 to 15/);
  bad((j) => { j.plan.clips[0].model = 'skull_rat'; j.plan.clips[0].move = 'yes'; }, /"move" must be true or false/);
  bad((j) => { j.plan.clips[0].model = 'skull_rat'; j.plan.clips[0].anim = 'walk cycle'; }, /"anim" must be a clip name/);
  bad((j) => { j.plan.clips[0].anim = 'walk'; }, /are for a model clip/);
  bad((j) => { j.plan.clips[0].model_file = 'x.glb'; }, /unknown field "model_file"/);
});

test('clips: every example in the clips guide is accepted by the runner (the choice, the model preview, the scripted clip, the model clip)', () => {
  const section = fs.readFileSync(path.join(__dirname, '..', 'guides', 'clips.md'), 'utf8');
  const blocks = [...section.matchAll(/```json\n([\s\S]*?)\n```/g)].map((m) => m[1]);
  const words = fs.readFileSync(path.resolve(__dirname, '../../../../client/main/qa_clip_steps.json'), 'utf8');
  const parsed = blocks.map((b) => {   // each in a worktree with the game's word list, as a job's branch has it
    const d = wt(); fs.mkdirSync(path.join(d, 'client/main'), { recursive: true }); fs.writeFileSync(path.join(d, C.STEPS_FILE), words); fs.writeFileSync(path.join(d, C.CLIP_FILE), b);
    const r = C.readClipRequest(d); assert.equal(r.error, undefined, `${r.error} in ${b.slice(0, 80)}`); return r;
  });
  assert.ok(parsed.some((r) => r.variants.map((v) => v.label).join() === 'slow,now,fast'), 'the choice example: three options');
  assert.ok(parsed.some((r) => r.variants.length === 1 && r.plan.clips[0].camera === 'turntable'), 'the model preview example: one turntable clip');
  assert.ok(parsed.some((r) => Array.isArray(r.plan.clips[0].steps) && Array.isArray(r.plan.clips[0].setup)), 'the scripted example: setup and steps');
  assert.ok(parsed.some((r) => r.plan.clips.some((c) => c.model !== undefined)), 'the model clip example');
});

test('clips: shot plan screen sizes: from the four on the list, at most 4, each once; anything else is dropped with a note', () => {
  assert.deepEqual(C.checkResolutions(undefined), {}); assert.deepEqual(C.checkResolutions(['1920x1080', '3440x1440']), { list: ['1920x1080', '3440x1440'] });
  assert.deepEqual(C.RESOLUTIONS, ['1920x1080', '2560x1440', '3840x2160', '3440x1440']);
  for (const bad of [[], '1920x1080', ['800x600'], ['1920x1080', '1920x1080'], ['1920x1080', '2560x1440', '3840x2160', '3440x1440', '1600x900'], [1920], null]) assert.ok(C.checkResolutions(bad).error, JSON.stringify(bad));
  const s = wt(); const put = (o) => fs.writeFileSync(path.join(s, '.dm-shot.json'), JSON.stringify(o));
  put({ shots: [{ name: 'a' }], resolutions: ['2560x1440'] }); assert.deepEqual(C.readShotPlan(s), { plan: { shots: [{ name: 'a' }], resolutions: ['2560x1440'] }, notes: [], before: false, presets: ['ultra'] });
  put({ shots: [{ name: 'a' }], resolutions: ['640x480'] }); const r = C.readShotPlan(s);
  assert.deepEqual(r.plan, { shots: [{ name: 'a' }] }); assert.match(r.notes[0], /screen sizes asked for were not usable.*so the standard size was used/);
});

test('clips: shot plan BEFORE and presets: one AFTER on Ultra by default; asked-for presets lowest first; both are taken out of the plan; anything else falls back with a note', () => {
  assert.deepEqual(C.checkPresets(undefined), {}); assert.deepEqual(C.checkPresets(['ultra', 'low']), { list: ['low', 'ultra'] });
  for (const bad of [[], 'ultra', ['potato'], ['low', 'low'], ['low', 'medium', 'high', 'ultra', 'low'], [1], null]) assert.ok(C.checkPresets(bad).error, JSON.stringify(bad));
  const s = wt(); const put = (o) => fs.writeFileSync(path.join(s, '.dm-shot.json'), JSON.stringify(o));
  put({ shots: [{ name: 'a' }], before: true, presets: ['ultra', 'high'] });
  assert.deepEqual(C.readShotPlan(s), { plan: { shots: [{ name: 'a' }] }, notes: [], before: true, presets: ['high', 'ultra'] });
  put({ shots: [{ name: 'a' }], before: 'yes', presets: ['potato'] }); const r = C.readShotPlan(s);
  assert.deepEqual(r.plan, { shots: [{ name: 'a' }] }); assert.equal(r.before, false); assert.deepEqual(r.presets, ['ultra']);
  assert.match(r.notes.join(' '), /graphics presets asked for were not usable.*so Ultra was used.*"before" must be true or false/);
});

test('clips: a symlink or a directory is not a request; classes and the shot plan', () => {
  const d = wt(); fs.writeFileSync(path.join(d, 'x.json'), JSON.stringify(GOOD())); fs.symlinkSync(path.join(d, 'x.json'), path.join(d, C.CLIP_FILE));
  assert.match(C.readClipRequest(d).error, /regular file/);
  assert.equal(C.classOf('reaper'), 11); assert.equal(C.classOf('hero_gravecaller'), 2); assert.equal(C.classOf(4), 4); assert.equal(C.classOf(7), 0); assert.equal(C.classOf('nope'), 0); assert.equal(C.classOf(undefined), 0);
  const s = wt(); const put = (t) => fs.writeFileSync(path.join(s, '.dm-shot.json'), t);
  assert.equal(C.readShotPlan(s), null); put('{"shots":[{"name":"a"}]}'); assert.deepEqual(C.readShotPlan(s), { plan: { shots: [{ name: 'a' }] }, notes: [], before: false, presets: ['ultra'] });
  put('{"shots":[]}'); assert.equal(C.readShotPlan(s), null); put('[{"name":"a"}]'); assert.equal(C.readShotPlan(s), null); put('{"shots":["a"]}'); assert.equal(C.readShotPlan(s), null);
  put('nope'); assert.equal(C.readShotPlan(s), null); put(JSON.stringify({ shots: [{ name: 'a', pad: 'x'.repeat(40000) }] })); assert.equal(C.readShotPlan(s), null);
});

// ---- setup and steps: checked against the game's word list in the job's own branch (client/main/qa_clip_steps.json) ----
const STEPS = fs.readFileSync(path.resolve(__dirname, '../../../../client/main/qa_clip_steps.json'), 'utf8');
const readWith = (j, voc = STEPS) => {
  const d = wt();
  if (voc != null) { fs.mkdirSync(path.join(d, 'client/main'), { recursive: true }); fs.writeFileSync(path.join(d, C.STEPS_FILE), voc); }
  fs.writeFileSync(path.join(d, C.CLIP_FILE), JSON.stringify(j));
  return C.readClipRequest(d);
};
test('clips: setup and steps are checked against the branch\'s own word list, so a word the game adds needs no runner change', () => {
  const j = GOOD(); const c = j.plan.clips[0]; delete c.cast;
  c.setup = [{ do: 'hud', show: true }, { do: 'stand_ins', health: 1, harmless: false }, { do: 'souls', value: 0 }, { do: 'top_up', on: false }];
  c.steps = [{ at: 0.3, do: 'cast', rite: 'reap' }, { at: 2, do: 'cast', rite: 'haunting_wraith' }];
  const r = readWith(j);
  assert.equal(r.error, undefined, 'a clip whose steps cast needs no "cast"');
  assert.deepEqual(r.plan.clips[0].steps.map((s) => s.rite), ['reap', 'haunting_wraith']); assert.equal(r.plan.clips[0].setup.length, 4);
  const voc = JSON.parse(STEPS); voc.steps.zoom = { args: { value: { type: 'number', min: 0.5, max: 3, required: true } } };
  const k = GOOD(); k.plan.clips[0].steps = [{ at: 1, do: 'zoom', value: 2 }];
  assert.equal(readWith(k, JSON.stringify(voc)).error, undefined, 'a word the branch\'s list has is accepted');
  const bad = (f, re, v) => { const m = GOOD(); f(m.plan.clips[0]); const r2 = readWith(m, v); assert.ok(r2 && r2.error, 'refused'); assert.match(r2.error, re); };
  bad((x) => { x.setup = [{ do: 'fly' }]; }, new RegExp(`"do" must be one of ${Object.keys(JSON.parse(STEPS).setup).join(', ')}`));
  bad((x) => { x.setup = [{ do: 'hud' }]; }, /\(hud\) needs "show"/);
  bad((x) => { x.setup = [{ do: 'hud', show: 'yes' }]; }, /"show" must be true or false/);
  bad((x) => { x.setup = [{ do: 'stand_ins', health: -1 }]; }, /"health" must be from/);
  bad((x) => { x.setup = [{ do: 'hud', show: true, colour: 'red' }]; }, /unknown argument "colour"/);
  bad((x) => { x.steps = [{ do: 'cast', rite: 'reap' }]; }, /"at" must be a number of seconds/);
  bad((x) => { x.seconds = 2; x.steps = [{ at: 3, do: 'cast', rite: 'reap' }]; }, /"at" must be a number of seconds from 0 to the clip's 2/);
  bad((x) => { x.steps = [{ at: 1, do: 'cast', rite: 'Bad Rite' }]; }, /"rite" must be a rite id/);
  bad((x) => { x.setup = { do: 'hud' }; }, /"setup" must be a list/);
  bad((x) => { delete x.cast; x.setup = [{ do: 'hud', show: true }]; }, /"cast" must be a rite id .* whose steps cast/);
  bad((x) => { x.steps = [{ at: 1, do: 'cast', rite: 'reap' }]; }, /no list of setup and step words .* merge the latest main/, null);
  bad((x) => { x.steps = Array.from({ length: 25 }, (_, i) => ({ at: i / 10, do: 'cast', rite: 'reap' })); }, /"steps" has 25 entries \(at most 24\)/);
});

test('clips: the scene words (a Legion kit, a hero stood at a point, thralls, a zoom, a walk, the candles): a scene needs no "cast"', () => {
  const j = GOOD(); j.plan.legion = ['leg_requiem_wraiths_chest', 'staff_gold'];
  const c = j.plan.clips[0]; delete c.cast;
  c.setup = [{ do: 'stand_at', at: [0, -12] }, { do: 'zoom', value: 0.6 }, { do: 'thralls', owners: { mine: ['warrior', 'archer'], ossuary: ['warrior'] } }];
  c.steps = [{ at: 0.5, do: 'walk', to: [[1, -10], [2, -8]] }, { at: 2, do: 'candles', group: 'west' }, { at: 4, do: 'candles', group: 'west', out: false }];
  const r = readWith(j);
  assert.equal(r.error, undefined, r.error);
  assert.deepEqual(r.plan.legion, ['leg_requiem_wraiths_chest', 'staff_gold'], 'the kit reaches the game');
  const walkOnly = GOOD(); delete walkOnly.plan.clips[0].cast; walkOnly.plan.clips[0].steps = [{ at: 1, do: 'walk', to: [3, 4] }];
  assert.equal(readWith(walkOnly).error, undefined, 'a single point is a walk too');
  const bad = (f, re) => { const m = GOOD(); f(m.plan, m.plan.clips[0]); const r2 = readWith(m); assert.ok(r2 && r2.error, 'refused'); assert.match(r2.error, re); };
  bad((p) => { p.legion = ['a', 'b', 'c']; }, /"plan.legion" must be a list of 1 to 2 item ids/);
  bad((_p, x) => { x.setup = [{ do: 'stand_at', at: [1] }]; }, /"at" must be a point/);
  bad((_p, x) => { x.setup = [{ do: 'thralls', owners: { necromancer: ['warrior'] } }]; }, /owner that is not "mine" or a discipline/);
  bad((_p, x) => { x.setup = [{ do: 'thralls', owners: { mine: Array(41).fill('warrior') } }]; }, /raises 41 thralls \(at most 40\)/);
  bad((_p, x) => { x.steps = [{ at: 1, do: 'walk', to: Array(9).fill([0, 0]) }]; }, /"to" must be a point \[x, z\] or a list of 1 to 8/);
  bad((_p, x) => { x.steps = [{ at: 1, do: 'candles', group: 'West Side' }]; }, /"group" must be a candle group/);
  bad((_p, x) => { x.setup = [{ do: 'zoom', value: 0.1 }]; }, /"value" must be from 0.4 to 1.45/);
});
