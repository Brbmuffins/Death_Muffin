// Run: node --test server/realtime/server.test.js   (DEV_TRUST_TOKENS set below)
process.env.DEV_TRUST_TOKENS = '1';
process.env.NODE_ENV = 'test';
const test = require('node:test');
const assert = require('node:assert');
const { validIntent, pickWorld, worlds, cleanGear } = require('./server');

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

test('summonBoss names a known boss; unknown or missing means the Prelate', () => {
  assert.equal(validIntent({ t: 'summonBoss', by: 'p1', boss: 'abbess' }).boss, 'abbess');
  assert.equal(validIntent({ t: 'summonBoss', by: 'p1', boss: 'lich-king' }).boss, 'prelate');
  assert.equal(validIntent({ t: 'summonBoss', by: 'p1' }).boss, 'prelate');
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

test('Hollow Knight signature kinds pass validation and stay clamped', () => {
  for (const sig of ['bash', 'vigil', 'brand']) {
    const ok = validIntent({ t: 'signature', by: 'k', sig, x: 3, z: -4, dx: 1, dz: 0, sp: 40 });
    assert.equal(ok.sig, sig, `${sig} should be accepted`);
    assert.equal(ok.sp, 40);
  }
  // Spell power and aim are clamped exactly as for the necromancer rites, and
  // the client cannot smuggle a stun duration or a corpse id through.
  assert.equal(validIntent({ t: 'signature', sig: 'bash', x: 0, z: 0, dx: 1e9, dz: 0, sp: 1e9 }).sp, 1e5);
  assert.equal(validIntent({ t: 'signature', sig: 'bash', x: 0, z: 0, dx: 1e9, dz: 0, sp: 1 }).dx, 1e3);
  assert.equal(validIntent({ t: 'signature', sig: 'vigil', x: 1e9, z: 0, dx: 0, dz: 0, sp: 1 }), null, 'off-world');
  assert.equal(validIntent({ t: 'signature', sig: 'brand', x: 0, z: 0, dx: 0, dz: 0, sp: -5 }).sp, 0);
  // validIntent is a shallow sanitised copy, so unknown keys survive it (true of
  // every intent type, bounded by LIMITS.intentBytes). What protects the Knight
  // is that WorldSim re-derives the body struck, the corpse spent and every
  // duration from its own state and never reads a client-supplied one — so a
  // smuggled field is inert rather than stripped. Worth hardening to a
  // whitelist one day; asserting the real invariant here rather than a false one.
  const smuggled = validIntent({ t: 'signature', sig: 'bash', x: 0, z: 0, dx: 0, dz: 0, sp: 1, stunS: 99 });
  assert.equal(smuggled.sig, 'bash');
  assert.equal(smuggled.sp, 1, 'only the fields the host reads are clamped');
});

test('spell variety: new signature kinds pass, and withered / cap / dur are clamped', () => {
  for (const sig of ['offering', 'rally', 'seed']) assert.equal(validIntent({ t: 'signature', sig, x: 1, z: 2, dx: 0, dz: 0, sp: 10 }).sig, sig);
  const hit = validIntent({ t: 'hit', ids: [1], dmg: 10, withered: 9, witheredCap: 99 });
  assert.equal(hit.withered, 1);
  assert.equal(hit.witheredCap, 12);
  assert.equal(validIntent({ t: 'hit', ids: [1], dmg: 10, withered: -3 }).withered, 0);
  const seed = validIntent({ t: 'signature', sig: 'seed', x: 0, z: 0, dx: 0, dz: 0, sp: 1, cap: 40 });
  assert.equal(seed.cap, 12);
  assert.equal(validIntent({ t: 'signature', sig: 'rally', x: 0, z: 0, dx: 0, dz: 0, sp: 1, dur: 1e9 }).dur, 10);
});

test('visible gear keeps only known slots and plain item ids', () => {
  assert.deepEqual(cleanGear(null), {});
  assert.deepEqual(cleanGear({ main_hand: 'sword_iron', head: 'helm_gold', ring: 'ring_copper', off_hand: 'Bad Id!', chest: 42 }), { main_hand: 'sword_iron', head: 'helm_gold' });
  assert.equal(Object.keys(cleanGear({ legs: 'x'.repeat(80) })).length, 0, 'over-long ids are dropped');
  assert.deepEqual(cleanGear({ cape: 'cape_mining', pet: 'pet_grave_rat', ring: 'x' }), { cape: 'cape_mining', pet: 'pet_grave_rat' }, 'capes and pets ride along with the gear');
});

test('Relic rune fields: every one is clamped (Impale, Creeping Rot, Contagion, Mass Grave, Bone Colossus, Hollow Choir, Requiem)', () => {
  const hit = (extra) => validIntent({ t: 'hit', ids: [1], dmg: 5, root: true, ...extra });
  assert.equal(hit({ rootS: 99 }).rootS, 1.5);
  assert.equal(hit({ rootS: -3 }).rootS, 0);
  assert.equal(hit({}).rootS, undefined, 'a plain Bone Prison claim carries no length');
  const m = validIntent({ t: 'miasma', x: 0, z: 0, r: 3, dps: 1, durationMs: 6000, creep: 50, contagion: 1 });
  assert.equal(m.creep, 1.5);
  assert.equal(m.contagion, true);
  assert.equal(validIntent({ t: 'miasma', x: 0, z: 0, r: 3, dps: 1, durationMs: 6000, creep: -4 }).creep, 0);
  const col = validIntent({ t: 'exhume', x: 0, z: 0, r: 99, count: 50, colossus: true });
  assert.equal(col.r, 6, 'the colossus looks 6 m for company');
  assert.equal(col.count, 3);
  assert.equal(col.colossus, true);
  const plain = validIntent({ t: 'exhume', x: 0, z: 0, r: 99 });
  assert.equal(plain.r, 4);
  assert.equal(plain.colossus, false);
  assert.equal(plain.count, undefined);
  assert.equal(validIntent({ t: 'exhume', x: 0, z: 0, r: 1, count: -4 }).count, 1);
  const choir = validIntent({ t: 'litany', x: 0, z: 0, r: 99, spellPower: 5, spare: 1 });
  assert.equal(choir.r, 11, 'without a delay the radius stays within the Soul Harvest maximum');
  assert.equal(choir.spare, true);
  const req = validIntent({ t: 'litany', x: 0, z: 0, r: 99, spellPower: 5, delayMs: 99999 });
  assert.equal(req.r, 22, 'Requiem doubles even a Soul Harvest litany (21 m)');
  assert.equal(req.delayMs, 2000);
  const none = validIntent({ t: 'litany', x: 0, z: 0, r: 14, spellPower: 5, delayMs: -5 });
  assert.equal(none.delayMs, 0);
  assert.equal(none.r, 11, 'a zero delay is no Requiem');
});
