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
  bad((j) => { j.plan.clips[0].cast = undefined; }, /"cast" must be a rite id.*only a "turntable" clip may leave it out/);
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

test('clips: the examples in the agent prompt are accepted by the runner', () => {
  const prompt = fs.readFileSync(path.join(__dirname, '..', 'PROMPT-godot.md'), 'utf8');
  const section = prompt.slice(prompt.indexOf('## Clips and choices'), prompt.indexOf('## Making new models'));
  const blocks = [...section.matchAll(/```json\n([\s\S]*?)\n```/g)].map((m) => m[1]);
  assert.equal(blocks.length, 2, 'the choice example and the model preview example');
  for (const b of blocks) { const r = read(null, b); assert.equal(r.error, undefined, `${r.error} in ${b.slice(0, 80)}`); }
  assert.deepEqual(read(null, blocks[0]).variants.map((v) => v.label), ['slow', 'now', 'fast']); assert.equal(read(null, blocks[1]).variants.length, 1);
});

test('clips: shot plan screen sizes: from the four on the list, at most 4, each once; anything else is dropped with a note', () => {
  assert.deepEqual(C.checkResolutions(undefined), {}); assert.deepEqual(C.checkResolutions(['1920x1080', '3440x1440']), { list: ['1920x1080', '3440x1440'] });
  assert.deepEqual(C.RESOLUTIONS, ['1920x1080', '2560x1440', '3840x2160', '3440x1440']);
  for (const bad of [[], '1920x1080', ['800x600'], ['1920x1080', '1920x1080'], ['1920x1080', '2560x1440', '3840x2160', '3440x1440', '1600x900'], [1920], null]) assert.ok(C.checkResolutions(bad).error, JSON.stringify(bad));
  const s = wt(); const put = (o) => fs.writeFileSync(path.join(s, '.dm-shot.json'), JSON.stringify(o));
  put({ shots: [{ name: 'a' }], resolutions: ['2560x1440'] }); assert.deepEqual(C.readShotPlan(s), { plan: { shots: [{ name: 'a' }], resolutions: ['2560x1440'] }, notes: [] });
  put({ shots: [{ name: 'a' }], resolutions: ['640x480'] }); const r = C.readShotPlan(s);
  assert.deepEqual(r.plan, { shots: [{ name: 'a' }] }); assert.match(r.notes[0], /screen sizes asked for were not usable.*so the standard size was used/);
});

test('clips: a symlink or a directory is not a request; classes and the shot plan', () => {
  const d = wt(); fs.writeFileSync(path.join(d, 'x.json'), JSON.stringify(GOOD())); fs.symlinkSync(path.join(d, 'x.json'), path.join(d, C.CLIP_FILE));
  assert.match(C.readClipRequest(d).error, /regular file/);
  assert.equal(C.classOf('reaper'), 11); assert.equal(C.classOf('hero_gravecaller'), 2); assert.equal(C.classOf(4), 4); assert.equal(C.classOf(7), 0); assert.equal(C.classOf('nope'), 0); assert.equal(C.classOf(undefined), 0);
  const s = wt(); const put = (t) => fs.writeFileSync(path.join(s, '.dm-shot.json'), t);
  assert.equal(C.readShotPlan(s), null); put('{"shots":[{"name":"a"}]}'); assert.deepEqual(C.readShotPlan(s), { plan: { shots: [{ name: 'a' }] }, notes: [] });
  put('{"shots":[]}'); assert.equal(C.readShotPlan(s), null); put('[{"name":"a"}]'); assert.equal(C.readShotPlan(s), null); put('{"shots":["a"]}'); assert.equal(C.readShotPlan(s), null);
  put('nope'); assert.equal(C.readShotPlan(s), null); put(JSON.stringify({ shots: [{ name: 'a', pad: 'x'.repeat(40000) }] })); assert.equal(C.readShotPlan(s), null);
});
