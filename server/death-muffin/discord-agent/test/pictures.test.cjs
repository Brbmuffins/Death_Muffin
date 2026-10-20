'use strict';
// Pictures (DECISIONS B70): a concept that names a kind of tools/pictures/kinds.json gets the kind's look and shape, refs may be game pictures,
// a picture concept is never built into a model, and concepts a thread was shown come back in its later rounds. Nothing calls Gemini (test/fake-art).
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs'), os = require('os'), path = require('path');
const A = require('../runner/lib/art.cjs');
const { IDS, makeWorld, makeDiscord, until } = require('./harness.cjs');
const BOT = `<@${IDS.BOT}>`;

const RECIPE = 'Dark fantasy ARPG ability icon, square, painterly, near-black background.';
const KINDS = { ability_icon: { label: 'Ability icon', dir: 'client/assets/ui_art/art/abilities', size: [256, 256], maxKB: 48, use: 'ui', style: ['client/assets/ui_art/art/abilities/necro-spear.webp'], recipe: RECIPE },
  portrait: { label: 'Portrait', dir: 'client/assets/ui_art/art/portraits', size: [480, 640], aspect: '3:4', maxKB: 96, use: 'ui', style: ['client/assets/ui_art/art/portraits/reaper.webp'], recipe: 'Dark fantasy portrait, painterly, dark misty background.' },
  loading_art: { label: 'Loading', dir: 'client/assets/ui_art/loading', size: [1600, 900], genSize: '2K', maxKB: 260, use: 'ui', style: ['client/assets/ui_art/loading/keyart.webp'], recipe: 'Dark fantasy key art, wide cinematic painting.' } };
const WEBP = Buffer.from('RIFF\0\0\0\0WEBPVP8 fake');
const INFO = { rootPngs: new Set(), existing: new Set(), history: A.DEFAULT_COSTS };
function wt(jobs) {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-pic-'));
  const w = (f, c) => { fs.mkdirSync(path.dirname(path.join(d, f)), { recursive: true }); fs.writeFileSync(path.join(d, f), typeof c === 'string' || Buffer.isBuffer(c) ? c : JSON.stringify(c)); };
  w('tools/pictures/kinds.json', KINDS);
  for (const k of Object.values(KINDS)) w(k.style[0], WEBP);
  w('client/assets/ui_art/art/abilities/necro-soul-siphon.webp', WEBP);
  for (const [id, job] of Object.entries(jobs)) w(`art-manifest/gemini-jobs/${id}.json`, job);
  return { d, w, done: () => fs.rmSync(d, { recursive: true, force: true }) };
}
const pic = (id, over = {}) => [{ id: `concept_${id}`, kind: 'ability_icon', prompt: 'A bone scythe sweeping a green arc, acid green and bone.', out: `art-src/concepts/${id}.png`, ...over }];
const concepts = (s, ids) => A.validateConcepts({ wt: s.d, request: { ids }, info: INFO });

test('a picture concept gets its kind\'s recipe, style picture and shape; the job only says what to draw', () => {
  const s = wt({ icon_a: pic('icon_a'), por_a: pic('por_a', { kind: 'portrait' }), load_a: pic('load_a', { kind: 'loading_art' }) });
  try {
    const v = concepts(s, ['icon_a', 'por_a', 'load_a']);
    assert.ok(v.ok, v.errors.join('; '));
    const [icon, por, load] = v.items.map((i) => i.gemini);
    assert.equal(icon.kind, 'ability_icon');
    assert.ok(icon.prompt.startsWith(RECIPE), 'the recipe leads');
    assert.match(icon.prompt, /Match the painting style, framing and finish of the reference image\.\n\nA bone scythe/);
    assert.deepEqual(icon.refs, ['client/assets/ui_art/art/abilities/necro-spear.webp']);
    assert.equal(icon.aspect, '1:1'); assert.equal(icon.size, undefined);
    assert.equal(por.aspect, '3:4');
    assert.equal(load.aspect, '16:9'); assert.equal(load.size, '2K', 'a kind may ask for the bigger image');
  } finally { s.done(); }
});

test('the runner\'s written-back job validates again unchanged (no doubled recipe), and an edit can start from a game picture', () => {
  const s = wt({ icon_a: pic('icon_a', { refs: ['client/assets/ui_art/art/abilities/necro-soul-siphon.webp'] }) });
  try {
    const first = concepts(s, ['icon_a']); assert.ok(first.ok, first.errors.join('; '));
    const g = first.items[0].gemini;
    assert.deepEqual(g.refs, ['client/assets/ui_art/art/abilities/necro-spear.webp', 'client/assets/ui_art/art/abilities/necro-soul-siphon.webp'], 'the style picture first, then the picture to edit');
    s.w('art-manifest/gemini-jobs/icon_a.json', [g]);   // what runConcepts writes back
    const again = concepts(s, ['icon_a']); assert.ok(again.ok, again.errors.join('; '));
    assert.deepEqual(again.items[0].gemini, g);
    assert.equal(again.items[0].gemini.prompt.split(RECIPE).length, 2, 'the recipe appears once');
  } finally { s.done(); }
});

test('a picture concept with a problem is refused: unknown kind, a shape of its own, refs outside the game\'s pictures, a symlinked ref', () => {
  const s = wt({ k: pic('icon_k', { kind: 'banner' }), sh: pic('icon_sh', { aspect: '16:9' }), po: pic('icon_po', { post: { resize: [256, 256] } }),
    r: pic('icon_r', { refs: ['client/data/combat/abilities.json'] }), up: pic('icon_up', { refs: ['client/assets/../../etc/passwd.png'] }), ln: pic('icon_ln', { refs: ['client/assets/ui_art/art/abilities/link.webp'] }) });
  try {
    fs.symlinkSync('/etc/hostname', path.join(s.d, 'client/assets/ui_art/art/abilities/link.webp'));
    const err = (id) => concepts(s, [id]).errors.join('; ');
    assert.match(err('k'), /kind must be one of ability_icon, portrait, loading_art/);
    assert.match(err('sh'), /takes its shape from the kind/);
    assert.match(err('po'), /takes its shape from the kind/);
    assert.match(err('r'), /is not allowed/);
    assert.match(err('up'), /is not allowed/);
    assert.match(err('ln'), /symlink/);
  } finally { s.done(); }
});

test('a picture concept is never turned into a model', () => {
  const s = wt({ prop_icon: pic('prop_icon') });
  try {
    s.w('art-manifest/tripo-specs/prop_icon.json', { id: 'prop_icon', input: 'art-src/concepts/prop_icon.png', generation: { model: 'P1-20260311', face_limit: 2000, texture_quality: 'standard' } });
    const v = A.validate({ wt: s.d, request: { id: 'prop_icon' }, info: INFO });
    assert.equal(v.ok, false); assert.match(v.errors.join(), /is a picture concept \(kind ability_icon\): pictures are built with build-picture\.sh/);
  } finally { s.done(); }
});

const texts = (thread) => thread.sent.map((s) => s.payload.content || '').filter(Boolean);
test('flow: picture concepts are posted as pictures, kept outside the worktree, and back in the next round of the thread', async () => {
  const w = makeWorld(); fs.writeFileSync(w.budgetFile, JSON.stringify({ [IDS.HELIX]: 1000 })); const d = makeDiscord(w.runner);
  await d.say(d.main, IDS.HELIX, `${BOT} new Reaper icons GD-PICTURE ids=icon_reaper_reap,icon_reaper_sweep`);
  const thread = await until(() => d.world.threads[d.world.threads.length - 1], d.ad);
  const posted = await until(() => thread.sent.find((s) => /Concept art/.test(s.payload.content || '')), d.ad);
  assert.match(posted.payload.content, /Nothing is in the game yet\. .*say which ones to use: I put them in the game/);
  assert.doesNotMatch(posted.payload.content, /3D|model credits/);
  const job = Object.values(w.runner.jobs())[0];
  const shown = fs.readFileSync(path.join(job.worktree, 'art-src/concepts/icon_reaper_reap.png'));
  const gem = JSON.parse(fs.readFileSync(path.join(job.worktree, 'art-manifest/gemini-jobs/icon_reaper_reap.json'), 'utf8'))[0];
  assert.equal(gem.kind, 'ability_icon'); assert.ok(gem.prompt.startsWith('Dark fantasy ARPG ability icon'));
  assert.deepEqual(gem.refs, ['client/assets/ui_art/art/abilities/necro-spear.webp']);
  const kept = path.join(w.cfg.stateDir, 'concepts', job.id);
  assert.deepEqual(fs.readdirSync(kept).sort(), ['icon_reaper_reap.png', 'icon_reaper_sweep.png']);
  assert.equal(job.concepts.icon_reaper_reap.kind, 'ability_icon');
  // the round ends (here: discarded; a ship removes the worktree the same way) and the images go with its worktree
  const first = job.worktree;
  const bang = await d.say(thread, IDS.HELIX, '!discard'); await until(() => job.status === 'discarded', d.ad); void bang;
  assert.ok(!fs.existsSync(first));
  await d.say(thread, IDS.HELIX, 'use 1 please CONCEPTS-BACK?');
  await until(() => texts(thread).some((t) => /CONCEPTS-BACK-SEEN|no concepts mentioned/.test(t)), d.ad);
  assert.equal(job.round, 2); assert.notEqual(job.worktree, first);
  assert.ok(texts(thread).some((t) => /CONCEPTS-BACK-SEEN/.test(t)), 'the new round\'s note told the agent the concepts are back, as pictures');
  assert.ok(fs.readFileSync(path.join(job.worktree, 'art-src/concepts/icon_reaper_reap.png')).equals(shown), 'the same image that was shown');
  assert.ok(fs.existsSync(path.join(job.worktree, 'art-src/concepts/icon_reaper_sweep.png')));
  assert.match(fs.readFileSync(path.join(w.cfg.stateDir, 'audit.jsonl'), 'utf8'), /"event":"round".*"concepts":2/);
  // a kept image that no longer matches what was shown never comes back
  fs.writeFileSync(path.join(kept, 'icon_reaper_sweep.png'), 'swapped');
  await d.say(thread, IDS.HELIX, '!discard'); await until(() => job.status === 'discarded', d.ad);
  await d.say(thread, IDS.HELIX, 'again CONCEPTS-BACK?');
  await until(() => job.round === 3 && texts(thread).filter((t) => /CONCEPTS-BACK-SEEN|no concepts mentioned/.test(t)).length === 2, d.ad);
  assert.ok(fs.existsSync(path.join(job.worktree, 'art-src/concepts/icon_reaper_reap.png')));
  assert.ok(!fs.existsSync(path.join(job.worktree, 'art-src/concepts/icon_reaper_sweep.png')), 'the swapped copy stayed out');
});

test('sweep: a thread\'s kept concepts are dropped once it has been quiet for conceptKeepDays', async () => {
  const w = makeWorld({ conceptKeepDays: 0 }); fs.writeFileSync(w.budgetFile, JSON.stringify({ [IDS.HELIX]: 1000 })); const d = makeDiscord(w.runner);
  await d.say(d.main, IDS.HELIX, `${BOT} an icon GD-PICTURE ids=icon_reaper_reap`);
  const thread = await until(() => d.world.threads[d.world.threads.length - 1], d.ad);
  await until(() => thread.sent.find((s) => /Concept art/.test(s.payload.content || '')), d.ad);
  const job = Object.values(w.runner.jobs())[0];
  const kept = path.join(w.cfg.stateDir, 'concepts', job.id);
  await until(() => !job.running, d.ad);
  await w.runner.sweep();
  assert.ok(!fs.existsSync(kept), 'dropped after 0 quiet days');
  assert.match(fs.readFileSync(path.join(w.cfg.stateDir, 'audit.jsonl'), 'utf8'), /"event":"concepts-dropped"/);
});
