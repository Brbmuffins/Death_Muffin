// Run: node --test server/realtime/server.test.js   (DEV_TRUST_TOKENS set below)
process.env.DEV_TRUST_TOKENS = '1';
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert');
const { validIntent, pickWorld, worlds } = require('./server');

test('rejects unknown or malformed intents', () => {
  assert.equal(validIntent(null), null);
  assert.equal(validIntent({ t: 'teleportEveryone' }), null);
  assert.equal(validIntent({ t: 'hit', ids: 'all', dmg: 5 }), null);
  assert.equal(validIntent({ t: 'hit', ids: [1.5], dmg: 5 }), null);
  assert.equal(validIntent({ t: 'miasma', x: 1e9, z: 0 }), null, 'out-of-world coordinates');
});

test('clamps numeric abuse instead of trusting it', () => {
  const hit = validIntent({ t: 'hit', ids: [1, 2], dmg: 1e12, fracture: 99 });
  assert.equal(hit.dmg, 100000);
  assert.equal(hit.fracture, 3);
  const m = validIntent({ t: 'miasma', x: 1, z: 2, r: 500, dps: -5, durationMs: 1e9, witheredCap: 50 });
  assert.equal(m.r, 8);
  assert.equal(m.dps, 0);
  assert.equal(m.durationMs, 10000);
  assert.equal(m.witheredCap, 10);
  const ex = validIntent({ t: 'exhume', x: 0, z: 0, cap: 100, hp: 1e12 });
  assert.equal(ex.cap, 8);
  assert.equal(ex.hp, 1e6);
});

test('detonate names an integer corpse and clamps its damage', () => {
  const d = validIntent({ t: 'detonate', by: 'spoofed', corpseId: 42, dmg: 1e12 });
  assert.equal(d.t, 'detonate');
  assert.equal(d.corpseId, 42);
  assert.equal(d.dmg, 100000);
  assert.equal(validIntent({ t: 'detonate', corpseId: 7, dmg: -50 }).dmg, 0);
  assert.equal(validIntent({ t: 'detonate', corpseId: 7, dmg: 'lots' }).dmg, 0);
  assert.equal(validIntent({ t: 'detonate', corpseId: 1.5, dmg: 10 }), null, 'fractional corpse id');
  assert.equal(validIntent({ t: 'detonate', corpseId: '3', dmg: 10 }), null, 'string corpse id');
  assert.equal(validIntent({ t: 'detonate', corpseId: -1, dmg: 10 }), null, 'negative corpse id');
  assert.equal(validIntent({ t: 'detonate', dmg: 10 }), null, 'missing corpse id');
});

test('an empowered litany fits the radius clamp', () => {
  assert.equal(validIntent({ t: 'litany', x: 0, z: 0, r: 10.5, spellPower: 10 }).r, 10.5);
  assert.equal(validIntent({ t: 'litany', x: 0, z: 0, r: 99, spellPower: 10 }).r, 11);
});

test('oversized intents are dropped', () => {
  assert.equal(validIntent({ t: 'hit', ids: Array.from({ length: 65 }, (_, i) => i), dmg: 1 }), null);
  assert.equal(validIntent({ t: 'summonBoss', junk: 'x'.repeat(5000) }), null);
});

test('matchmaking fills public worlds and isolates invite codes', () => {
  worlds.clear();
  const a = pickWorld();
  worlds.get(a).players.set('p1', {});
  assert.equal(pickWorld(), a, 'joins the public world with space');
  for (let i = 2; i <= 9; i++) worlds.get(a).players.set(`p${i}`, {});
  assert.equal(pickWorld(), a, 'the tenth player joins the same world');
  worlds.get(a).players.set('p10', {});
  const b = pickWorld();
  assert.notEqual(b, a, 'a full world spawns a new instance');
  const party = pickWorld('Crypt-42');
  assert.equal(party, 'w:crypt-42');
  assert.equal(worlds.get(party).public, false, 'invite worlds are never auto-filled');
  assert.notEqual(pickWorld(), party);
});

test('hit bleed (Hemorrhage) is clamped to a quarter of the hit', () => {
  assert.equal(validIntent({ t: 'hit', ids: [1], dmg: 100, bleed: 1e9 }).bleed, 25);
  assert.equal(validIntent({ t: 'hit', ids: [1], dmg: 100, bleed: -5 }).bleed, 0);
  assert.equal(validIntent({ t: 'hit', ids: [1], dmg: 100, bleed: 'x' }).bleed, 0);
  assert.equal(validIntent({ t: 'hit', ids: [1], dmg: 100, bleed: 12 }).bleed, 12);
  assert.equal('bleed' in validIntent({ t: 'hit', ids: [1], dmg: 100 }), false);
});

test('signature rites name a known rite, a point in the world, and clamp spell power', () => {
  const ok = validIntent({ t: 'signature', by: 'x', sig: 'wall', x: 1, z: -20, dx: 1, dz: 0, sp: 1e9 });
  assert.equal(ok.sig, 'wall');
  assert.equal(ok.sp, 1e5);
  assert.equal(validIntent({ t: 'signature', sig: 'meteor', x: 0, z: 0, dx: 0, dz: 0, sp: 1 }), null, 'unknown rite');
  assert.equal(validIntent({ t: 'signature', sig: 'bloom', x: 1e9, z: 0, dx: 0, dz: 0, sp: 1 }), null, 'off-world');
  assert.equal(validIntent({ t: 'signature', sig: 'dirge', x: 0, z: 0, dx: 'a', dz: null, sp: -5 }).sp, 0);
  // Bone Mantle (a Grimoire rite) rides the same host-shaped channel.
  assert.equal(validIntent({ t: 'signature', sig: 'mantle', x: 0, z: -16, dx: 0, dz: 0, sp: 30 }).sig, 'mantle');
});

test('hit chill (Grave Frost) is a flag only', () => {
  assert.equal(validIntent({ t: 'hit', ids: [1], dmg: 10, chill: 'yes please' }).chill, true);
  assert.equal(validIntent({ t: 'hit', ids: [1], dmg: 10, chill: 0 }).chill, false);
  assert.equal('chill' in validIntent({ t: 'hit', ids: [1], dmg: 10 }), false);
});

test('gather names a node id and clamps the successes it reports', () => {
  const g = validIntent({ t: 'gather', by: 'x', nodeId: 'acre_12', successes: 40 });
  assert.equal(g.nodeId, 'acre_12');
  assert.equal(g.successes, 3);
  assert.equal(validIntent({ t: 'gather', nodeId: 'acre_1', successes: -2 }).successes, 1);
  assert.equal(validIntent({ t: 'gather', nodeId: '../etc', successes: 1 }), null);
  assert.equal(validIntent({ t: 'gather', nodeId: 7, successes: 1 }), null);
});
