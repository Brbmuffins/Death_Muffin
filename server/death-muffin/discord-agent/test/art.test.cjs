'use strict';
// Model generation (Gemini concept -> Tripo): spec validation, pricing, budgets, the ledger, and the whole approval flow through the fake Discord layer.
// NOTHING here calls Gemini or Tripo: the tools are stand-ins (test/fake-art) with a fake balance, and the keys are fake. No credits are spent.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs'), os = require('os'), path = require('path');
const { spawnSync } = require('child_process');
const A = require('../runner/lib/art.cjs');
const { createRunner } = require('../runner/core.cjs');
const { IDS, makeWorld, makeDiscord, until, sh } = require('./harness.cjs');
const BOT = `<@${IDS.BOT}>`;
const KEYS = ['tsk_FakeTripoKeyForTestsOnly000000000000', 'AIzaFakeGeminiKeyForTestsOnly000000000000'];

// ---------- validation + pricing ----------
const goodSpec = (id, over = {}) => ({ id, input: `art-src/concepts/${id}.png`, generation: { model: 'P1-20260311', face_limit: 7000, texture_quality: 'detailed' },
  rig: { model: 'v1.0-20240301', rig_type: 'biped' }, animations: ['preset:biped:idle', 'preset:biped:walk'], animationMode: 'single', ...over });
const goodJob = (id, over = {}) => [{ id: `concept_${id}`, prompt: 'A gaunt undead warlock in a strict T-pose, empty hands, plain grey background.', out: `art-src/concepts/${id}.png`, aspect: '3:4', ...over }];
const INFO = { rootPngs: new Set(['necromancer-character-minions-reference.png']), existing: new Set(['bone_golem', 'prop_dead_tree', 'dead_tree']), history: { generate: 60, rig: 25, anim: 10 } };
function scratch(id, spec, job) {
  const wt = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-art-'));
  const w = (f, c) => { fs.mkdirSync(path.dirname(path.join(wt, f)), { recursive: true }); fs.writeFileSync(path.join(wt, f), typeof c === 'string' ? c : JSON.stringify(c)); };
  if (spec !== null) w(`art-manifest/tripo-specs/${id}.json`, spec); if (job !== null) w(`art-manifest/gemini-jobs/${id}.json`, job);
  return { wt, w };
}
const check = (id, spec, job, info = INFO) => { const s = scratch(id, spec, job); try { return A.validate({ wt: s.wt, request: { id }, info }); } finally { fs.rmSync(s.wt, { recursive: true, force: true }); } };

test('validate: a rigged character and a static prop pass; the canonical spec drops nothing it should keep', () => {
  const c = check('warlock', goodSpec('warlock'), goodJob('warlock'));
  assert.equal(c.ok, true, c.errors.join(' | ')); assert.equal(c.kind, 'character');
  assert.deepEqual(c.estimate, { total: 60 + 25 + 20, parts: [{ label: 'image to model', credits: 60 }, { label: 'rig', credits: 25 }, { label: '2 animations x 10', credits: 20 }] });
  assert.deepEqual(c.spec.animations, ['preset:biped:idle', 'preset:biped:walk']); assert.equal(c.spec.animationMode, 'single');
  const p = check('prop_candelabra', { id: 'prop_candelabra', input: 'art-src/concepts/prop_candelabra.png', generation: { model: 'P1-20260311', face_limit: 2500, texture_quality: 'standard' } }, goodJob('prop_candelabra'));
  assert.equal(p.ok, true, p.errors.join(' | ')); assert.equal(p.kind, 'prop'); assert.equal(p.estimate.total, 60); assert.equal(p.spec.rig, undefined);
  const q = check('wolf_shade', goodSpec('wolf_shade', { rig: { model: 'v2.5-20260210', rig_type: 'quadruped' }, animations: ['preset:quadruped:walk'] }), goodJob('wolf_shade'));
  assert.equal(q.ok, true, q.errors.join(' | ')); assert.equal(q.estimate.total, 95);
});

test('validate: strict allow-lists (unknown fields, ids, paths, models, counts, presets) are all refused', () => {
  const bad = (name, spec, job, re, id = 'warlock') => { const r = check(id, spec, job); assert.equal(r.ok, false, `${name} should be refused`); assert.match(r.errors.join(' | '), re, name); };
  bad('unknown spec field', goodSpec('warlock', { webhook: 'http://x' }), goodJob('warlock'), /"webhook" is not allowed/);
  bad('unknown generation field', goodSpec('warlock', { generation: { model: 'P1-20260311', face_limit: 7000, texture_quality: 'detailed', pbr: false } }), goodJob('warlock'), /"pbr" is not allowed/);
  bad('input elsewhere', goodSpec('warlock', { input: '../../etc/passwd' }), goodJob('warlock'), /input must be/);
  bad('input in another art dir', goodSpec('warlock', { input: 'art-src/fen/concepts/warlock.png' }), goodJob('warlock'), /input must be/);
  bad('spec id mismatch', goodSpec('warlock', { id: 'other' }), goodJob('warlock'), /id must be "warlock"/);
  bad('model', goodSpec('warlock', { generation: { model: 'P2-future', face_limit: 7000, texture_quality: 'detailed' } }), goodJob('warlock'), /generation\.model/);
  bad('faces high', goodSpec('warlock', { generation: { model: 'P1-20260311', face_limit: 500000, texture_quality: 'detailed' } }), goodJob('warlock'), /face_limit/);
  bad('faces float', goodSpec('warlock', { generation: { model: 'P1-20260311', face_limit: 7000.5, texture_quality: 'detailed' } }), goodJob('warlock'), /face_limit/);
  bad('texture', goodSpec('warlock', { generation: { model: 'P1-20260311', face_limit: 7000, texture_quality: 'ultra' } }), goodJob('warlock'), /texture_quality/);
  bad('rig model mismatch', goodSpec('warlock', { rig: { model: 'v2.5-20260210', rig_type: 'biped' } }), goodJob('warlock'), /rig\.model for biped/);
  bad('rig type', goodSpec('warlock', { rig: { model: 'v1.0-20240301', rig_type: 'avian' } }), goodJob('warlock'), /rig_type/);
  bad('too many animations', goodSpec('warlock', { animations: Array.from({ length: 11 }, (_, i) => ['idle', 'walk', 'run', 'slash', 'hurt', 'fall', 'dig', 'dive', 'jump', 'chop', 'box_01'][i]).map((a) => `preset:biped:${a}`) }), goodJob('warlock'), /at most 10/);
  bad('repeated animation', goodSpec('warlock', { animations: ['preset:biped:idle', 'preset:biped:idle'] }), goodJob('warlock'), /must not repeat/);
  bad('unknown preset', goodSpec('warlock', { animations: ['preset:biped:teleport'] }), goodJob('warlock'), /not an allowed biped preset/);
  bad('quadruped preset on biped', goodSpec('warlock', { animations: ['preset:quadruped:walk'] }), goodJob('warlock'), /not an allowed biped preset/);
  bad('batch mode', goodSpec('warlock', { animationMode: 'batch' }), goodJob('warlock'), /animationMode/);
  bad('character without rig needs prop_', goodSpec('warlock', { rig: undefined, animations: undefined, animationMode: undefined }), goodJob('warlock'), /must start with prop_/);
  bad('prop with a rig', goodSpec('prop_x_lamp'), goodJob('prop_x_lamp'), /static props: remove the rig/, 'prop_x_lamp');
  bad('existing model', goodSpec('bone_golem'), goodJob('bone_golem'), /already used by an existing model/, 'bone_golem');
  bad('bad gemini id', goodSpec('warlock'), goodJob('warlock', { id: 'x' }), /job id must be "concept_warlock"/);
  bad('gemini out elsewhere', goodSpec('warlock'), goodJob('warlock', { out: 'public/art/x.png' }), /out must be/);
  bad('gemini unknown field', goodSpec('warlock'), goodJob('warlock', { crop: { left: 0 } }), /"crop" is not allowed/);
  bad('gemini model', goodSpec('warlock'), goodJob('warlock', { model: 'gemini-evil' }), /model must be/);
  bad('gemini aspect', goodSpec('warlock'), goodJob('warlock', { aspect: '99:1' }), /aspect/);
  bad('gemini post lumaAlpha', goodSpec('warlock'), goodJob('warlock', { post: { lumaAlpha: true } }), /"lumaAlpha" is not allowed/);
  bad('short prompt', goodSpec('warlock'), goodJob('warlock', { prompt: 'x' }), /prompt must be/);
  bad('ref outside', goodSpec('warlock'), goodJob('warlock', { refs: ['/etc/passwd'] }), /is not allowed/);
  bad('ref traversal', goodSpec('warlock'), goodJob('warlock', { refs: ['art-src/concepts/../../../etc/hostname'] }), /is not allowed/);
  bad('ref that is not on the base branch', goodSpec('warlock'), goodJob('warlock', { refs: ['secret-sheet.png'] }), /is not allowed/);
  bad('two jobs', goodSpec('warlock'), [...goodJob('warlock'), ...goodJob('warlock')], /exactly one job/);
});

test('validate: a request whose estimate passes the per-request ceiling is refused, whatever the budget', () => {
  const r = check('warlock', goodSpec('warlock', { animations: ['idle', 'walk', 'run', 'slash', 'hurt', 'fall', 'dig', 'dive', 'jump', 'chop'].map((a) => `preset:biped:${a}`) }), goodJob('warlock'), { ...INFO, history: { generate: 200, rig: 100, anim: 50 } });
  assert.equal(r.ok, false); assert.match(r.errors.join(), /ceiling/);
});

test('validate: expensive history can only raise the estimate, and an allowed reference sheet passes', () => {
  const dear = { generate: 80, rig: 30, anim: 15 };
  const r = check('warlock', goodSpec('warlock'), goodJob('warlock', { refs: ['necromancer-character-minions-reference.png'] }), { ...INFO, history: dear });
  assert.equal(r.ok, true, r.errors.join(' | ')); assert.equal(r.estimate.total, 80 + 30 + 2 * 15);
  assert.deepEqual(r.gemini.refs, ['necromancer-character-minions-reference.png']);
  const cheap = A.estimate(r.spec, { generate: 1, rig: 1, anim: 1 });   // history below the measured floor is ignored
  assert.equal(cheap.total, 60 + 25 + 20);
  assert.equal(A.estimate({ generation: {} }, DEFAULT()).total, 60);
});
const DEFAULT = () => A.DEFAULT_COSTS;

test('validate: symlinks in art-src / art-manifest, a symlinked spec, and a non-image ref are refused (a write would leave the worktree)', () => {
  const s = scratch('warlock', goodSpec('warlock'), goodJob('warlock')); const victim = path.join(s.wt, '..', `victim-${process.pid}`); fs.writeFileSync(victim, 'keep');
  try {
    fs.mkdirSync(path.join(s.wt, 'art-src/concepts'), { recursive: true }); fs.symlinkSync(victim, path.join(s.wt, 'art-src/concepts/warlock.png'));
    let r = A.validate({ wt: s.wt, request: { id: 'warlock' }, info: INFO }); assert.equal(r.ok, false); assert.match(r.errors.join(), /symlink/);
    fs.unlinkSync(path.join(s.wt, 'art-src/concepts/warlock.png'));
    fs.mkdirSync(path.join(s.wt, 'art-src/tripo/warlock'), { recursive: true }); fs.symlinkSync(victim, path.join(s.wt, 'art-src/tripo/warlock/state.json'));
    r = A.validate({ wt: s.wt, request: { id: 'warlock' }, info: INFO }); assert.equal(r.ok, false); assert.match(r.errors.join(), /holds a symlink/);
    fs.rmSync(path.join(s.wt, 'art-src/tripo'), { recursive: true });
    fs.rmSync(path.join(s.wt, 'art-manifest/tripo-specs/warlock.json')); fs.symlinkSync(victim, path.join(s.wt, 'art-manifest/tripo-specs/warlock.json'));
    r = A.validate({ wt: s.wt, request: { id: 'warlock' }, info: INFO }); assert.equal(r.ok, false); assert.match(r.errors.join(), /symlink/);
    fs.unlinkSync(path.join(s.wt, 'art-manifest/tripo-specs/warlock.json')); s.w('art-manifest/tripo-specs/warlock.json', goodSpec('warlock'));
    fs.writeFileSync(path.join(s.wt, 'art-src/concepts/ref1.png'), 'not an image at all, just text'); s.w('art-manifest/gemini-jobs/warlock.json', goodJob('warlock', { refs: ['art-src/concepts/ref1.png'] }));
    r = A.validate({ wt: s.wt, request: { id: 'warlock' }, info: INFO }); assert.equal(r.ok, false); assert.match(r.errors.join(), /not a PNG or JPEG/);
    assert.equal(fs.readFileSync(victim, 'utf8'), 'keep');
  } finally { fs.rmSync(s.wt, { recursive: true, force: true }); fs.rmSync(victim, { force: true }); }
});

test('request file: read once and removed; extra fields, bad ids, symlinks and big files are errors', () => {
  const wt = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-art-req-'));
  try {
    assert.equal(A.readRequest(wt), null);
    fs.writeFileSync(path.join(wt, '.dm-art-request.json'), JSON.stringify({ id: 'warlock', note: 'x\u0007y'.repeat(200) }));
    const r = A.readRequest(wt); assert.equal(r.id, 'warlock'); assert.ok(r.note.length <= 300 && !/\u0007/.test(r.note)); assert.equal(fs.existsSync(path.join(wt, '.dm-art-request.json')), false);
    fs.writeFileSync(path.join(wt, '.dm-art-request.json'), JSON.stringify({ id: 'warlock', cost: 1 })); assert.match(A.readRequest(wt).error, /"cost" is not allowed/);
    fs.writeFileSync(path.join(wt, '.dm-art-request.json'), JSON.stringify({ id: '../x' })); assert.match(A.readRequest(wt).error, /id must match/);
    fs.writeFileSync(path.join(wt, '.dm-art-request.json'), 'x'.repeat(5000)); assert.match(A.readRequest(wt).error, /small regular file/);
    fs.writeFileSync(path.join(wt, 'real'), '{"id":"warlock"}'); fs.symlinkSync(path.join(wt, 'real'), path.join(wt, '.dm-art-request.json')); assert.match(A.readRequest(wt).error, /small regular file/);
  } finally { fs.rmSync(wt, { recursive: true, force: true }); }
});

// ---------- budgets + ledger ----------
function store() {
  const T = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-art-store-'));
  const cfg = { toolsDir: T, repo: T, artBudgetFile: path.join(T, 'budget.json'), artLedgerFile: path.join(T, 'ledger.json') };
  let t = Date.parse('2026-10-09T12:00:00Z'); const s = A.createStore(cfg, () => (t += 1000));
  return { T, s, cfg, budget: (o) => fs.writeFileSync(cfg.artBudgetFile, JSON.stringify(o)) };
}
test('budget math: unlisted / invalid users have 0, remaining = budget - actual spend, edits to the budget file apply at once', () => {
  const { T, s, budget } = store(); const U = '291020261074010113';
  try {
    assert.equal(s.budgetOf(U), 0, 'no file'); assert.equal(s.remaining(U), 0);
    budget({ [U]: 1000, '111': -5, '222': 'lots', '333': null }); assert.equal(s.budgetOf(U), 1000);
    for (const bad of ['111', '222', '333', '444']) assert.equal(s.budgetOf(bad), 0, bad);
    const a = s.begin({ userId: U, jobId: 'j1', specId: 'warlock', estimate: 175 });
    assert.equal(s.spentBy(U), 0, 'a started run has spent nothing yet'); assert.equal(s.open().length, 1);
    s.finish(a, { status: 'done', credits: 172.5 }); assert.equal(s.open().length, 0);
    assert.equal(s.spentBy(U), 172.5); assert.equal(s.remaining(U), 827.5);
    const b = s.begin({ userId: U, jobId: 'j2', specId: 'x', estimate: 60 }); s.finish(b, { status: 'failed', credits: 60 });
    s.begin({ userId: '999', jobId: 'j3', specId: 'y', estimate: 60 }); assert.equal(s.spentBy(U), 232.5);
    budget({ [U]: 200 }); assert.equal(s.remaining(U), 0, 'a lowered budget below what is spent leaves nothing, never negative');
    budget({ [U]: 500 }); assert.equal(s.remaining(U), 267.5);
    const e = s.entries().find((x) => x.id === a); assert.equal(e.userId, U); assert.equal(e.specId, 'warlock'); assert.match(e.ts, /^2026-10-09T12:00/); assert.ok(e.finishedAt);
    assert.equal(fs.statSync(s.paths.ledger).mode & 0o777, 0o600);
    fs.writeFileSync(s.paths.ledger, '{broken'); assert.equal(s.spentBy(U), 0, 'a damaged ledger reads as empty rather than throwing');
  } finally { fs.rmSync(T, { recursive: true, force: true }); }
});

// ---------- flow ----------
const calls = (w) => { try { return fs.readFileSync(path.join(w.artDir, 'calls.log'), 'utf8').split('\n').filter(Boolean); } catch { return []; } };
const balance = (w) => JSON.parse(fs.readFileSync(path.join(w.artDir, 'state.json'), 'utf8')).balance;
const setBalance = (w, n) => fs.writeFileSync(path.join(w.artDir, 'state.json'), JSON.stringify({ balance: n }));
const flag = (w, name, on = true) => (on ? fs.writeFileSync(path.join(w.artDir, name), '1') : fs.rmSync(path.join(w.artDir, name), { force: true }));
const ledger = (w) => { try { return JSON.parse(fs.readFileSync(w.ledgerFile, 'utf8')).entries; } catch { return []; } };
const texts = (thread) => thread.sent.map((s) => s.payload.content || '').filter(Boolean);
const offerOf = (thread) => thread.sent.find((s) => s.payload && s.payload.embeds && /^New (character|prop|creature)/.test(s.payload.embeds[0].title));
const offers = (thread) => thread.sent.filter((s) => s.payload && s.payload.embeds && /^New (character|prop|creature)/.test(s.payload.embeds[0].title));
const field = (msg, name) => msg.payload.embeds[0].fields.find((f) => f.name.startsWith(name)).value;
const artWorld = (budgets = { [IDS.HELIX]: 1000 }) => {
  const w = makeWorld({ godot: true }); fs.writeFileSync(w.budgetFile, JSON.stringify(budgets)); return { w, d: makeDiscord(w.runner) };
};
async function ask(d, userId, text) {
  await d.say(d.main, userId, `${BOT} ${text}`);
  const thread = await until(() => d.world.threads[d.world.threads.length - 1], d.ad);
  return thread;
}
const everything = (w, d) => [JSON.stringify(d.world.threads.map((t) => t.sent.map((s) => s.payload))), fs.readFileSync(path.join(w.cfg.stateDir, 'audit.jsonl'), 'utf8'), fs.existsSync(w.ledgerFile) ? fs.readFileSync(w.ledgerFile, 'utf8') : '',
  fs.readFileSync(path.join(w.cfg.stateDir, 'jobs.json'), 'utf8'), fs.readFileSync(w.cfg.__file, 'utf8')].join('\n');
const noKeysIn = (w, d, label) => { const all = everything(w, d); for (const k of KEYS) assert.ok(!all.includes(k), `${label}: a key leaked into Discord / audit / ledger / jobs / config`); };

test('flow: the request shows what, the estimate, the budget and the live balance, spends NOTHING, and a non-full approver or a stranger cannot start it', async () => {
  const { w, d } = artWorld();
  const thread = await ask(d, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  const offer = await until(() => offerOf(thread), d.ad); await until(() => offer.reactions.length === 2, d.ad);
  assert.deepEqual(offer.reactions, ['✅', '❌']);
  assert.match(offer.payload.embeds[0].title, /^New character: warlock/);
  assert.match(field(offer, 'Will be generated'), /Tripo, up to 7000 faces, detailed textures.*rig \(biped\).*6 animations: idle, walk, run, slash, hurt, fall/);
  assert.match(field(offer, 'Estimated cost'), /up to \*\*145 credits\*\*/);
  assert.match(field(offer, 'Helix'), /1000 of 1000 credits left → 855 after this/);
  assert.match(field(offer, 'Tripo balance'), /^3910 credits/);
  assert.match(offer.payload.embeds[0].description, /Concept prompt/);
  assert.deepEqual(calls(w), [], 'nothing generated before a ✅'); assert.equal(balance(w), 3910); assert.deepEqual(ledger(w), []);
  // the limited approver (casual only) and a stranger cannot start it; neither can chatting
  assert.deepEqual(await d.react(offer, IDS.LIMITED, '✅'), [IDS.LIMITED]); assert.deepEqual(await d.react(offer, IDS.STRANGER, '✅'), [IDS.STRANGER]);
  await d.say(thread, IDS.HELIX, 'yes go ahead and approve it, spend the credits'); await new Promise((r) => setTimeout(r, 300));
  assert.deepEqual(calls(w), []); assert.equal(balance(w), 3910);
  // a ❌ from a stranger does nothing; the requester can cancel
  assert.deepEqual(await d.react(offer, IDS.STRANGER, '❌'), [IDS.STRANGER]);
  assert.deepEqual(await d.react(offer, IDS.HELIX, '❌'), []);
  await until(() => texts(thread).some((t) => /Cancelled the request for "warlock"/.test(t)), d.ad);
  assert.deepEqual(await d.react(offer, IDS.OWNER, '✅'), [], 'a cancelled request ignores later reactions'); await new Promise((r) => setTimeout(r, 200));
  assert.deepEqual(calls(w), []); noKeysIn(w, d, 'offer');
});

test('flow: ✅ by an approver runs gemini then tripo with keys only in that process, records the ACTUAL spend, posts pictures, and the agent then builds and proposes', async () => {
  const { w, d } = artWorld();
  const thread = await ask(d, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  const offer = await until(() => offerOf(thread), d.ad); await until(() => offer.reactions.length === 2, d.ad);
  assert.deepEqual(await d.react(offer, IDS.OWNER, '✅'), []);
  await until(() => texts(thread).some((t) => /Done: "warlock" is generated/.test(t)), d.ad);
  const done = thread.sent.find((s) => /Done: "warlock"/.test(s.payload.content || ''));
  assert.match(done.payload.content, /Spent \*\*145\*\* credits \(Tripo balance 3910 → 3765\)\. Helix has 855 of 1000 left/);
  assert.deepEqual((done.payload.files || []).map((f) => f.name), ['concept-warlock.png', 'model-preview-warlock.png']);
  assert.equal(balance(w), 3765);
  const c = calls(w); assert.equal(c.length, 2); assert.match(c[0], /^gemini cwd=root/); assert.match(c[1], /^tripo run warlock anims=6 rig=biped root=.*discord-[0-9a-f]{6}$/);
  const l = ledger(w); assert.equal(l.length, 1);
  assert.equal(l[0].userId, IDS.HELIX); assert.equal(l[0].specId, 'warlock'); assert.equal(l[0].status, 'done'); assert.equal(l[0].credits, 145); assert.equal(l[0].balanceBefore, 3910); assert.equal(l[0].balanceAfter, 3765); assert.equal(l[0].approverId, IDS.OWNER); assert.equal(l[0].estimate, 145);
  const audit = fs.readFileSync(path.join(w.cfg.stateDir, 'audit.jsonl'), 'utf8'); for (const ev of ['art-offered', 'art-approve-attempt', 'art-approved', 'art-start', 'art-result']) assert.match(audit, new RegExp(`"event":"${ev}"`));
  // the specs the tool ran are the validated canonical ones, in the job's worktree
  const job = Object.values(w.runner.jobs())[0];
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(job.worktree, 'art-manifest/tripo-specs/warlock.json'), 'utf8')).animations.length, 6);
  // the agent continues: builds + commits the model, then the normal proposal appears
  const p = await until(() => thread.sent.find((s) => s.payload && s.payload.embeds && /New model: warlock/.test(s.payload.embeds[0].title || '')), d.ad);
  await until(() => p.reactions.length === 2, d.ad);
  assert.ok(texts(thread).some((t) => /BUILD-ART-SEEN/.test(t)), 'the follow-up prompt told the agent to run build-art.sh');
  assert.equal(Object.values(w.runner.jobs())[0].artRequest, null);
  noKeysIn(w, d, 'run');
  // !credits reflects the ledger
  const r = await d.say(thread, IDS.HELIX, '!credits');
  assert.match(JSON.stringify(r.replies), /Model credits for Helix: 855 left of 1000 \(145 spent\)/);
});

test('flow: unlisted requesters (no budget) are refused politely and nothing is offered or spent', async () => {
  const { w, d } = artWorld({ [IDS.HELIX]: 1000 });
  const thread = await ask(d, IDS.LIMITED, 'GD-ART id=warlock make me a warlock');
  await until(() => texts(thread).some((t) => /Limited has no model-generation budget.*Nothing was spent/.test(t)), d.ad);
  assert.equal(offerOf(thread), undefined); assert.deepEqual(calls(w), []); assert.deepEqual(ledger(w), []); assert.equal(balance(w), 3910);
  // the owner is not special either: a budget has to be written for the owner too
  const t2 = await ask(d, IDS.OWNER, 'GD-ART id=warlock2 make me a warlock');
  await until(() => texts(t2).some((t) => /the owner has no model-generation budget|owner has no model-generation budget/i.test(t)), d.ad);
  assert.deepEqual(calls(w), []);
});

test('flow: over-budget and over-balance requests are refused before any ✅ is possible', async () => {
  const { w, d } = artWorld({ [IDS.HELIX]: 100 });
  const t1 = await ask(d, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  await until(() => texts(t1).some((t) => /would cost about 145 credits, but Helix has 100 left of 100/.test(t)), d.ad);
  assert.equal(offerOf(t1), undefined);
  fs.writeFileSync(w.budgetFile, JSON.stringify({ [IDS.HELIX]: 1000 })); setBalance(w, 100);
  const t2 = await ask(d, IDS.HELIX, 'GD-ART id=warlock3 make me a warlock');
  await until(() => texts(t2).some((t) => /the Tripo account only holds 100/.test(t)), d.ad);
  assert.equal(offerOf(t2), undefined); assert.deepEqual(calls(w), []); assert.deepEqual(ledger(w), []);
  // an unreadable balance means no offer at all (never blind)
  setBalance(w, 3910); flag(w, 'balance-fail');
  const t3 = await ask(d, IDS.HELIX, 'GD-ART id=warlock4 make me a warlock');
  await until(() => texts(t3).some((t) => /cannot read the Tripo balance/.test(t)), d.ad);
  assert.equal(offerOf(t3), undefined); assert.deepEqual(calls(w), []);
});

test('flow: the budget and balance are re-checked at ✅ time, and a missing key file starts nothing', async () => {
  const { w, d } = artWorld();
  const thread = await ask(d, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  const offer = await until(() => offerOf(thread), d.ad); await until(() => offer.reactions.length === 2, d.ad);
  fs.writeFileSync(w.budgetFile, JSON.stringify({ [IDS.HELIX]: 120 }));   // the owner lowered it after the offer
  assert.deepEqual(await d.react(offer, IDS.OWNER, '✅'), []);
  await until(() => texts(thread).some((t) => /Not started: "warlock" is estimated at 145 credits but Helix only has 120 left/.test(t)), d.ad);
  assert.deepEqual(calls(w), []); assert.deepEqual(ledger(w), []);
  await until(() => Object.values(w.runner.jobs())[0].status === 'idle' && !Object.values(w.runner.jobs())[0].running, d.ad);
  fs.writeFileSync(w.budgetFile, JSON.stringify({ [IDS.HELIX]: 1000 })); fs.renameSync(w.cfg.artKeysFile, w.cfg.artKeysFile + '.gone');
  assert.deepEqual(await d.react(offer, IDS.OWNER, '✅'), []);
  await until(() => texts(thread).some((t) => /cannot read the Tripo balance right now, so nothing was started/.test(t)), d.ad);
  assert.deepEqual(calls(w), []); assert.deepEqual(ledger(w), []); assert.equal(balance(w), 3910);
});

test('flow: the approved spec is what runs, even if the agent rewrites the spec file after the offer', async () => {
  const { w, d } = artWorld();
  const thread = await ask(d, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  const offer = await until(() => offerOf(thread), d.ad); await until(() => offer.reactions.length === 2, d.ad);
  await until(() => Object.values(w.runner.jobs())[0].status === 'idle', d.ad);
  await d.say(thread, IDS.HELIX, 'GD-ART-SWAP id=warlock actually more clips');
  await until(() => texts(thread).some((t) => /Swapped\./.test(t)), d.ad);
  const job = Object.values(w.runner.jobs())[0];
  assert.equal(JSON.parse(fs.readFileSync(path.join(job.worktree, 'art-manifest/tripo-specs/warlock.json'), 'utf8')).animations.length, 9, 'the worktree copy was changed');
  await until(() => !Object.values(w.runner.jobs())[0].running, d.ad);
  assert.deepEqual(await d.react(offer, IDS.OWNER, '✅'), []);
  await until(() => texts(thread).some((t) => /Done: "warlock" is generated/.test(t)), d.ad);
  assert.match(calls(w)[1], /anims=6 /, 'tripo ran the 6-clip spec that was approved'); assert.equal(ledger(w)[0].credits, 145);
});

test('flow: a symlink planted after the offer stops the run before anything is spent or written', async () => {
  const { w, d } = artWorld();
  const thread = await ask(d, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  const offer = await until(() => offerOf(thread), d.ad); await until(() => offer.reactions.length === 2, d.ad);
  await until(() => !Object.values(w.runner.jobs())[0].running, d.ad);
  const job = Object.values(w.runner.jobs())[0]; const victim = path.join(w.T, 'victim.txt'); fs.writeFileSync(victim, 'keep');
  fs.mkdirSync(path.join(job.worktree, 'art-src'), { recursive: true }); fs.symlinkSync(w.T, path.join(job.worktree, 'art-src', 'concepts'));
  assert.deepEqual(await d.react(offer, IDS.OWNER, '✅'), []);
  await until(() => texts(thread).some((t) => /Not started: .*symlink.*Nothing was spent/.test(t)), d.ad);
  assert.deepEqual(calls(w), []); assert.deepEqual(ledger(w), []); assert.equal(fs.readFileSync(victim, 'utf8'), 'keep'); assert.ok(!fs.existsSync(path.join(w.T, 'warlock.png')));
});

test('flow: a bad request is sent back to the agent to fix (twice at most); a fixed one is offered, a hopeless one never is', async () => {
  const { w, d } = artWorld();
  const t1 = await ask(d, IDS.HELIX, 'GD-ART-BADFIX id=warlock make me a warlock');
  await until(() => texts(t1).some((t) => /rejected by the checker \(.*"api_key" is not allowed/.test(t)), d.ad);
  const offer = await until(() => offerOf(t1), d.ad); assert.match(offer.payload.embeds[0].title, /warlock/);
  const t2 = await ask(d, IDS.OWNER, 'GD-ART-BAD id=ghoul make me a ghoul');
  await until(() => texts(t2).some((t) => /still has problems, so nothing was offered for approval/.test(t)), d.ad);
  assert.equal(offerOf(t2), undefined); assert.deepEqual(calls(w), []);
  const t3 = await ask(d, IDS.HELIX, 'GD-ART-LINK id=wraith make me a wraith');
  await until(() => texts(t3).some((t) => /rejected by the checker \(.*symlink/.test(t) || /nothing was offered/.test(t)), d.ad);
  assert.equal(offerOf(t3), undefined);
});

test('flow: a run that fails midway records the real spend from the balance delta, redacts the output, and ✅ again resumes without paying twice', async () => {
  const { w, d } = artWorld();
  const thread = await ask(d, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  const offer = await until(() => offerOf(thread), d.ad); await until(() => offer.reactions.length === 2, d.ad);
  flag(w, 'fail-after-generate'); flag(w, 'leak-key');
  assert.deepEqual(await d.react(offer, IDS.HELIX, '✅'), [], 'the requester is a full approver and may approve their own spend');
  await until(() => texts(thread).some((t) => /The model run did not finish: Tripo stopped partway\. Spent \*\*60\*\* credits/.test(t)), d.ad);
  assert.equal(balance(w), 3850);
  let l = ledger(w); assert.equal(l.length, 1); assert.equal(l[0].status, 'failed'); assert.equal(l[0].credits, 60); assert.equal(l[0].result, 'tripo-failed');
  assert.ok(!texts(thread).some((t) => KEYS.some((k) => t.includes(k))), 'the key the tool printed was redacted');
  noKeysIn(w, d, 'failed run');
  const again = await until(() => offers(thread)[1], d.ad); await until(() => again.reactions.length === 2, d.ad);
  assert.match(field(again, 'Helix'), /940 of 1000 credits left/);
  flag(w, 'fail-after-generate', false); flag(w, 'leak-key', false);
  assert.deepEqual(await d.react(again, IDS.OWNER, '✅'), []);
  await until(() => texts(thread).some((t) => /Done: "warlock" is generated/.test(t)), d.ad);
  l = ledger(w); assert.equal(l.length, 2); assert.equal(l[1].credits, 85, 'only the unpaid remainder was charged'); assert.equal(l.reduce((n, e) => n + e.credits, 0), 145);
  assert.equal(balance(w), 3765); assert.match(texts(thread).find((t) => /Done: "warlock"/.test(t)), /Helix has 855 of 1000 left/);
});

test('flow: a gemini failure spends nothing and tripo is never called', async () => {
  const { w, d } = artWorld();
  const thread = await ask(d, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  const offer = await until(() => offerOf(thread), d.ad); await until(() => offer.reactions.length === 2, d.ad);
  flag(w, 'gemini-fail'); await d.react(offer, IDS.OWNER, '✅');
  await until(() => texts(thread).some((t) => /did not finish: Gemini did not return an image\. Spent \*\*0\*\* credits/.test(t)), d.ad);
  assert.deepEqual(calls(w), ['gemini cwd=root']); assert.equal(balance(w), 3910); assert.equal(ledger(w)[0].credits, 0);
});

test('flow: one run at a time (a second ✅ while one is generating is turned away), and the lock works across processes', async () => {
  const { w, d } = artWorld({ [IDS.HELIX]: 1000, [IDS.OWNER]: 1000 }); flag(w, 'slow');
  const t1 = await ask(d, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  const o1 = await until(() => offerOf(t1), d.ad); await until(() => o1.reactions.length === 2, d.ad);
  const t2 = await ask(d, IDS.OWNER, 'GD-ART-PROP id=prop_candelabra make a candelabra');
  const o2 = await until(() => offerOf(t2), d.ad); await until(() => o2.reactions.length === 2, d.ad);
  assert.deepEqual(await d.react(o1, IDS.OWNER, '✅'), []);
  await until(() => Object.values(w.runner.jobs()).some((j) => j.status === 'generating'), d.ad);
  assert.deepEqual(await d.react(o2, IDS.OWNER, '✅'), [IDS.OWNER], 'the second ✅ is removed');
  await until(() => texts(t2).some((t) => /Another model is being generated/.test(t)), d.ad);
  await until(() => texts(t1).some((t) => /Done: "warlock"/.test(t)), d.ad);
  assert.deepEqual(await d.react(o2, IDS.OWNER, '✅'), [], 'once the first is done the second may start');
  await until(() => texts(t2).some((t) => /Done: "prop_candelabra"/.test(t)), d.ad);
  assert.equal(balance(w), 3910 - 145 - 60); assert.equal(ledger(w).length, 2);
  // across processes: a second art-run.sh while the first holds the flock gives up as "busy" without touching the account
  flag(w, 'slow');
  const job = Object.values(w.runner.jobs())[0]; const env = { PATH: process.env.PATH, HOME: process.env.HOME, TRIPO_API_KEY: KEYS[0], GEMINI_API_KEY: KEYS[1], DM_ART_TOOLS: w.artDir, DM_ART_LOCK: w.cfg.artLockFile };
  const { spawn } = require('child_process');
  fs.mkdirSync(path.join(job.worktree, 'art-manifest/tripo-specs'), { recursive: true }); fs.mkdirSync(path.join(job.worktree, 'art-manifest/gemini-jobs'), { recursive: true });
  fs.writeFileSync(path.join(job.worktree, 'art-manifest/tripo-specs/zed.json'), JSON.stringify(goodSpec('zed'))); fs.writeFileSync(path.join(job.worktree, 'art-manifest/gemini-jobs/zed.json'), JSON.stringify(goodJob('zed')));
  const before = balance(w);
  const first = spawn('bash', [path.join(w.tools, 'art-run.sh'), 'zed'], { cwd: job.worktree, env: { ...env, DM_ART_LOCK_WAIT: '10' } });
  await until(() => calls(w).some((c) => /tripo run zed/.test(c)), d.ad);
  const second = spawnSync('bash', [path.join(w.tools, 'art-run.sh'), 'zed'], { cwd: job.worktree, env: { ...env, DM_ART_LOCK_WAIT: '1' }, encoding: 'utf8' });
  assert.match(second.stdout, /RESULT: busy/); assert.equal(second.status, 3);
  await new Promise((r) => first.on('close', r));
  assert.equal(before - balance(w), 105, 'only the first run charged (60 + 25 + 2 clips)');
});

test('flow: a runner that died mid-run settles the open ledger entry from the balance delta at startup', async () => {
  const { w } = artWorld();
  const e = { version: 1, entries: [{ id: 'dead01', ts: '2026-10-09T10:00:00.000Z', status: 'started', credits: 0, userId: IDS.HELIX, jobId: 'abc123', specId: 'warlock', estimate: 145, balanceBefore: 3910 }] };
  fs.writeFileSync(w.ledgerFile, JSON.stringify(e)); setBalance(w, 3800);
  createRunner(w.cfg);
  await until0(() => ledger(w)[0].status !== 'started');
  const l = ledger(w)[0]; assert.equal(l.status, 'interrupted'); assert.equal(l.credits, 110); assert.equal(l.balanceAfter, 3800); assert.match(l.note, /balance delta/);
  assert.equal(A.createStore(w.cfg).spentBy(IDS.HELIX), 110); assert.equal(A.createStore(w.cfg).remaining(IDS.HELIX), 890);
  // balance unreadable at startup: charge the estimate (the conservative side)
  fs.writeFileSync(w.ledgerFile, JSON.stringify({ version: 1, entries: [{ ...e.entries[0], id: 'dead02' }] })); flag(w, 'balance-fail');
  createRunner(w.cfg); await until0(() => ledger(w)[0].status !== 'started');
  assert.equal(ledger(w)[0].credits, 145); assert.match(ledger(w)[0].note, /charged the estimate/);
});
async function until0(fn, ms = 15000) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (fn()) return; } catch { /* retry */ } await new Promise((r) => setTimeout(r, 50)); } throw new Error('timeout'); }

test('safety: the agent environment and tool list hold no keys, the sandbox hides the key file, and web mode has no art at all', async () => {
  const savedT = process.env.TRIPO_API_KEY, savedG = process.env.GEMINI_API_KEY; process.env.TRIPO_API_KEY = KEYS[0]; process.env.GEMINI_API_KEY = KEYS[1];
  try {
    const { agentEnv, claudeArgs } = require('../runner/lib/agent.cjs'); const w = makeWorld({ godot: true });
    const env = agentEnv(); assert.deepEqual(Object.keys(env).filter((k) => /KEY|TOKEN|SECRET|TRIPO|GEMINI/i.test(k)), []);
    const a = claudeArgs(w.cfg, { worktree: '/tmp/x', branch: 'discord/abc123', model: 'sonnet' }); const rest = a.slice(a.indexOf('--allowedTools') + 1); const allowed = rest.slice(0, rest.findIndex((x) => x.startsWith('--'))).join('\n');
    assert.ok(!/art-run|tripo|gemini|node |curl/i.test(allowed), 'the agent may not run art-run.sh, node, or any API tool: ' + allowed); assert.match(allowed, /build-art\.sh/);
  } finally { if (savedT === undefined) delete process.env.TRIPO_API_KEY; else process.env.TRIPO_API_KEY = savedT; if (savedG === undefined) delete process.env.GEMINI_API_KEY; else process.env.GEMINI_API_KEY = savedG; }
  const sb = fs.readFileSync(path.join(__dirname, '..', 'sandbox-lib.sh'), 'utf8'); assert.match(sb, /\.ai-keys\.local/);
  const web = makeWorld(); const dw = makeDiscord(web.runner);
  const thread = await ask(dw, IDS.HELIX, 'GD-ART id=warlock make me a warlock');
  await until(() => Object.values(web.runner.jobs())[0].status === 'idle' && !Object.values(web.runner.jobs())[0].running, dw.ad);
  assert.equal(offerOf(thread), undefined); assert.deepEqual(calls(web), []);
});

test('install: the trusted art tools come from the committed revision, get their own sharp, and the budget file starts empty', () => {
  const REPO = path.resolve(__dirname, '../../../..'); const hasGit = spawnSync('git', ['-C', REPO, 'rev-parse', 'HEAD']).status === 0;
  const NM = [path.join(REPO, 'node_modules'), '/home/ubuntu/vps-handoffs/DeathMuffin/game/node_modules'].find((d) => fs.existsSync(path.join(d, 'sharp')));
  if (!hasGit || !NM) return;
  const DEST = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-install-')); const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-install-repo-'));
  try {
    // install from a throwaway clone with the working copy's files committed, so uncommitted edits in the real checkout do not matter
    sh(tmp, 'init', '-q'); fs.mkdirSync(path.join(tmp, 'server/death-muffin'), { recursive: true });
    fs.cpSync(path.join(REPO, 'server/death-muffin/discord-agent'), path.join(tmp, 'server/death-muffin/discord-agent'), { recursive: true, filter: (s) => !/node_modules|\/test\//.test(s) });
    fs.mkdirSync(path.join(tmp, 'tools/ai'), { recursive: true }); for (const f of ['common', 'gemini', 'tripo']) fs.copyFileSync(path.join(REPO, `tools/ai/${f}.mjs`), path.join(tmp, `tools/ai/${f}.mjs`));
    fs.symlinkSync(NM, path.join(tmp, 'node_modules'));
    sh(tmp, 'add', '-f', 'server', 'tools'); sh(tmp, 'commit', '-q', '-m', 'x');
    const r = spawnSync('bash', [path.join(tmp, 'server/death-muffin/discord-agent/install-runner.sh'), 'HEAD'], { env: { ...process.env, REPO: tmp, DEST, NO_SYSTEMD: '1', OWNER_ID: IDS.OWNER }, encoding: 'utf8' });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    for (const f of ['art-run.sh', 'build-art.sh']) assert.ok(fs.statSync(path.join(DEST, f)).mode & 0o100, f + ' is executable');
    for (const f of ['common', 'gemini', 'tripo']) assert.ok(fs.existsSync(path.join(DEST, 'art-tools/tools/ai', `${f}.mjs`)));
    assert.match(fs.readFileSync(path.join(DEST, 'art-tools/tools/ai/common.mjs'), 'utf8'), /DM_ART_ROOT/);
    assert.ok(fs.existsSync(path.join(DEST, 'art-tools/node_modules/sharp/package.json')) && !fs.lstatSync(path.join(DEST, 'art-tools/node_modules/sharp')).isSymbolicLink(), 'its own copy of sharp, not a link into a worktree-reachable tree');
    assert.equal(fs.readFileSync(path.join(DEST, 'tripo-budget.json'), 'utf8').trim(), '{}'); assert.equal(fs.statSync(path.join(DEST, 'tripo-budget.json')).mode & 0o777, 0o600);
    fs.writeFileSync(path.join(DEST, 'tripo-budget.json'), '{"1":5}'); // a reinstall never resets the owner's budgets
    assert.equal(spawnSync('bash', [path.join(tmp, 'server/death-muffin/discord-agent/install-runner.sh'), 'HEAD'], { env: { ...process.env, REPO: tmp, DEST, NO_SYSTEMD: '1' }, encoding: 'utf8' }).status, 0);
    assert.equal(fs.readFileSync(path.join(DEST, 'tripo-budget.json'), 'utf8'), '{"1":5}');
  } finally { fs.rmSync(DEST, { recursive: true, force: true }); fs.rmSync(tmp, { recursive: true, force: true }); }
});
