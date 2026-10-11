'use strict';
// Sounds (ElevenLabs): spec validation, the request file, who may generate, the ledger, and the whole flow through the fake Discord layer.
// NOTHING here calls ElevenLabs: sound-run.mjs is pointed at a local fake server (cfg.soundApiBase) and the key is fake.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs'), os = require('os'), path = require('path'), http = require('http');
const S = require('../runner/lib/sound.cjs');
const { IDS, makeWorld, makeDiscord, until } = require('./harness.cjs');
const BOT = `<@${IDS.BOT}>`;
const KEY = 'sk_FakeElevenKeyForTestsOnly00000000000000';

function scratch(id, spec) {
  const wt = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-snd-'));
  if (spec !== null) { fs.mkdirSync(path.join(wt, S.SPEC_DIR), { recursive: true }); fs.writeFileSync(path.join(wt, S.SPEC_DIR, `${id}.json`), typeof spec === 'string' ? spec : JSON.stringify(spec)); }
  return wt;
}
const check = (id, spec) => { const wt = scratch(id, spec); try { return S.validate({ wt, request: { id } }); } finally { fs.rmSync(wt, { recursive: true, force: true }); } };
const sfx = (over = {}) => ({ id: 'banshee_wail', kind: 'sfx', prompt: 'A ghostly banshee wail, rising then fading, no music.', duration_seconds: 2.5, ...over });

test('validate: sfx and music pass with defaults filled in', () => {
  const a = check('banshee_wail', sfx({ variants: 3 }));
  assert.equal(a.ok, true, a.errors.join(' | '));
  assert.deepEqual(a.spec, { id: 'banshee_wail', kind: 'sfx', prompt: 'A ghostly banshee wail, rising then fading, no music.', duration_seconds: 2.5, variants: 3, loop: false, prompt_influence: 0.4 });
  const m = check('crypt_theme', { id: 'crypt_theme', kind: 'music', prompt: 'Slow dark choir and cello for a crypt.', duration_seconds: 60 });
  assert.equal(m.ok, true, m.errors.join(' | ')); assert.equal(m.spec.variants, 1); assert.equal(m.spec.loop, undefined);
});

test('validate: unknown fields, bad kinds, lengths, counts and ids are refused', () => {
  const bad = (name, spec, re, id = 'banshee_wail') => { const r = check(id, spec); assert.equal(r.ok, false, name); assert.match(r.errors.join(' | '), re, name); };
  bad('unknown field', sfx({ voice_id: 'x' }), /"voice_id" is not allowed/);
  bad('kind', sfx({ kind: 'speech' }), /kind must be/);
  bad('id mismatch', sfx({ id: 'other' }), /id must be "banshee_wail"/);
  bad('too long', sfx({ duration_seconds: 31 }), /duration_seconds/);
  bad('too short', sfx({ duration_seconds: 0.2 }), /duration_seconds/);
  bad('not a number', sfx({ duration_seconds: '2' }), /duration_seconds/);
  bad('too many takes', sfx({ variants: 5 }), /variants/);
  bad('music takes', { id: 'banshee_wail', kind: 'music', prompt: 'Slow dark choir for a crypt.', duration_seconds: 60, variants: 3 }, /variants/);
  bad('loop on music', { id: 'banshee_wail', kind: 'music', prompt: 'Slow dark choir for a crypt.', duration_seconds: 60, loop: true }, /"loop" is not allowed/);
  bad('short prompt', sfx({ prompt: 'wail' }), /prompt/);
  bad('control chars', sfx({ prompt: 'A ghostly wail\u0007 with a bell' }), /prompt/);
  bad('influence', sfx({ prompt_influence: 2 }), /prompt_influence/);
  bad('not json', '{nope', /not valid JSON/);
  const missing = check('banshee_wail', null); assert.match(missing.errors.join(' '), /does not exist/);
});

test('validate: symlinks in the spec or output paths are refused', () => {
  const wt = scratch('banshee_wail', sfx());
  try {
    fs.mkdirSync(path.join(wt, 'audio-src')); fs.symlinkSync('/tmp', path.join(wt, 'audio-src', 'eleven'));
    const r = S.validate({ wt, request: { id: 'banshee_wail' } }); assert.equal(r.ok, false); assert.match(r.errors.join(' '), /symlink/);
  } finally { fs.rmSync(wt, { recursive: true, force: true }); }
});

test('request file: read once and removed; extra fields and bad ids are errors', () => {
  const wt = fs.mkdtempSync(path.join(os.tmpdir(), 'dm-snd-'));
  try {
    const f = path.join(wt, S.REQUEST_FILE);
    assert.equal(S.readRequest(wt), null);
    fs.writeFileSync(f, JSON.stringify({ id: 'banshee_wail', note: 'dash\nsound' })); assert.deepEqual(S.readRequest(wt), { id: 'banshee_wail', note: 'dash sound' }); assert.equal(fs.existsSync(f), false);
    fs.writeFileSync(f, JSON.stringify({ id: 'banshee_wail', key: 'x' })); assert.match(S.readRequest(wt).error, /only hold/);
    fs.writeFileSync(f, JSON.stringify({ id: '../x' })); assert.match(S.readRequest(wt).error, /id must match/);
  } finally { fs.rmSync(wt, { recursive: true, force: true }); }
});

test('config: the owner is always a sound user; others only when listed', () => {
  const w = makeWorld({ godot: true, soundUsers: [IDS.HELIX] });
  try {
    const s = S.createSound(w.cfg); assert.equal(s.allowed(IDS.OWNER), true); assert.equal(s.allowed(IDS.HELIX), true); assert.equal(s.allowed(IDS.LIMITED), false);
  } finally { fs.rmSync(w.T, { recursive: true, force: true }); }
});

// ---------- fake ElevenLabs ----------
function fakeEleven({ fail = false } = {}) {
  const seen = [];
  const srv = http.createServer((req, res) => {
    let b = ''; req.on('data', (d) => { b += d; }).on('end', () => {
      seen.push({ url: req.url, key: req.headers['xi-api-key'], body: JSON.parse(b || '{}') });
      if (fail) { res.writeHead(401, { 'character-cost': '0' }); return res.end('{"detail":"quota_exceeded"}'); }
      res.writeHead(200, { 'content-type': 'audio/mpeg', 'character-cost': '25' }); res.end(Buffer.alloc(4096, 7));
    });
  });
  return new Promise((r) => srv.listen(0, '127.0.0.1', () => r({ srv, seen, base: `http://127.0.0.1:${srv.address().port}` })));
}
const texts = (thread) => thread.sent.map((s) => s.payload.content || '').filter(Boolean);
async function ask(d, userId, text) { await d.say(d.main, userId, `${BOT} ${text}`); return until(() => d.world.threads[d.world.threads.length - 1], d.ad); }
const ledger = (w) => { try { return JSON.parse(fs.readFileSync(path.join(w.T, 'eleven-ledger.json'), 'utf8')).entries; } catch { return []; } };

test('flow: a sound user gets the takes generated right away (no ✅), posted as mp3s, recorded in the ledger, and the agent then wires one in and proposes', async () => {
  const f = await fakeEleven();
  const w = makeWorld({ godot: true, soundUsers: [IDS.HELIX], soundApiBase: f.base }); const d = makeDiscord(w.runner);
  try {
    const thread = await ask(d, IDS.HELIX, 'GD-SOUND id=banshee_wail add a banshee wail to the dash');
    const done = await until(() => thread.sent.find((s) => /Done: 2 takes of "banshee_wail"/.test(s.payload.content || '')), d.ad);
    assert.match(done.payload.content, /50 ElevenLabs credits/);
    assert.deepEqual((done.payload.files || []).map((x) => x.name), ['banshee_wail-take1.mp3', 'banshee_wail-take2.mp3']);
    assert.equal(f.seen.length, 2); assert.equal(f.seen[0].key, KEY); assert.match(f.seen[0].url, /^\/v1\/sound-generation/);
    assert.deepEqual(f.seen[0].body, { text: 'A ghostly banshee wail, rising then fading, no music.', duration_seconds: 2, loop: false, prompt_influence: 0.4, model_id: 'eleven_text_to_sound_v2' });
    const l = ledger(w); assert.equal(l.length, 1); assert.equal(l[0].userId, IDS.HELIX); assert.equal(l[0].credits, 50); assert.equal(l[0].files, 2); assert.equal(l[0].result, 'ok');
    const p = await until(() => thread.sent.find((s) => s.payload && s.payload.embeds && /New sound: banshee_wail/.test(s.payload.embeds[0].title || '')), d.ad);
    assert.ok(p); assert.ok(texts(thread).some((t) => /BUILD-SOUND-SEEN/.test(t)), 'the follow-up told the agent to run build-sound.sh');
    assert.ok(!thread.sent.some((s) => s.payload && s.payload.embeds && /credits/.test(JSON.stringify(s.payload.embeds)) && /✅ spend/.test(JSON.stringify(s.payload.embeds))), 'no spend approval was asked for');
    const all = [JSON.stringify(thread.sent.map((s) => ({ ...s.payload, files: undefined }))), fs.readFileSync(path.join(w.cfg.stateDir, 'audit.jsonl'), 'utf8'), fs.readFileSync(path.join(w.cfg.stateDir, 'jobs.json'), 'utf8'), JSON.stringify(l)].join('\n');
    assert.ok(!all.includes(KEY), 'the key leaked');
    const r = await d.say(thread, IDS.HELIX, '!credits'); assert.match(JSON.stringify(r.replies), /Sounds \(ElevenLabs\): no limit, 50 credits used so far/);
  } finally { f.srv.close(); fs.rmSync(w.T, { recursive: true, force: true }); }
});

test('flow: someone who is not a sound user is refused and nothing is called', async () => {
  const f = await fakeEleven();
  const w = makeWorld({ godot: true, soundApiBase: f.base }); const d = makeDiscord(w.runner);
  try {
    const thread = await ask(d, IDS.HELIX, 'GD-SOUND id=banshee_wail add a banshee wail');
    await until(() => texts(thread).some((t) => /Sound generation is only open to the owner\. Nothing was generated/.test(t)), d.ad);
    assert.equal(f.seen.length, 0); assert.deepEqual(ledger(w), []);
  } finally { f.srv.close(); fs.rmSync(w.T, { recursive: true, force: true }); }
});

test('flow: an API error is reported (redacted), recorded, and nothing is handed to the agent', async () => {
  const f = await fakeEleven({ fail: true });
  const w = makeWorld({ godot: true, soundApiBase: f.base }); const d = makeDiscord(w.runner);
  try {
    const thread = await ask(d, IDS.OWNER, 'GD-SOUND id=banshee_wail add a banshee wail');
    await until(() => texts(thread).some((t) => /The sound did not generate \(failed\)/.test(t)), d.ad);
    assert.equal(f.seen.length, 1); const l = ledger(w); assert.equal(l.length, 1); assert.equal(l[0].result, 'failed'); assert.equal(l[0].files, 0);
    assert.ok(!texts(thread).some((t) => /BUILD-SOUND-SEEN/.test(t)));
  } finally { f.srv.close(); fs.rmSync(w.T, { recursive: true, force: true }); }
});

test('flow: a bad spec goes back to the agent and, still bad, is dropped without a call', async () => {
  const f = await fakeEleven();
  const w = makeWorld({ godot: true, soundApiBase: f.base }); const d = makeDiscord(w.runner);
  try {
    const thread = await ask(d, IDS.OWNER, 'GD-SOUND id=banshee_wail BADSOUND add a banshee wail');
    await until(() => texts(thread).some((t) => /The sound request (still has problems|was not fixed), so nothing was generated/.test(t)), d.ad);
    assert.equal(f.seen.length, 0);
  } finally { f.srv.close(); fs.rmSync(w.T, { recursive: true, force: true }); }
});

test('safety: the sandbox hides the ElevenLabs key file and the agent may only run build-sound.sh, not sound-run.mjs', () => {
  const lib = fs.readFileSync(path.join(__dirname, '..', 'sandbox-lib.sh'), 'utf8'); assert.match(lib, /death-muffin\/private\/elevenlabs-api-key/);
  const agent = fs.readFileSync(path.join(__dirname, '..', 'runner', 'lib', 'agent.cjs'), 'utf8'); assert.match(agent, /build-sound\.sh \*/); assert.ok(!/sound-run/.test(agent));
});
