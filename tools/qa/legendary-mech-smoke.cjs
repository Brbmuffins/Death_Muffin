/**
 * Legendary-set mechanics smoke (offline preview, High quality). Forces each DisciplineMods field on through the DEV-only
 * `__cwDebug.forceMods` and asserts the observable effect, then a perf read with everything on vs off and a screenshot.
 *   npx vite --host 127.0.0.1 --port 5382 --strictPort &
 *   DM_QA_URL='http://127.0.0.1:5382/?offline' DM_PLAYWRIGHT_MODULE=... node tools/qa/legendary-mech-smoke.cjs
 * Screenshots: DM_QA_ARTIFACT_DIR (default the system temp dir).
 */
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { SWIFTSHADER_ARGS, watchErrors, preloadModules, shot: shotFile } = require('./lib/qa-common.cjs');

const OUT = process.env.DM_QA_ARTIFACT_DIR || os.tmpdir();
const ALL = {
  thrallDeathBurst: 0.6, championEvery: 5, spearRally: 0.75, wardReflect: 0.4, colossusGuard: 0.25, litanyShatter: 3, corpseWisp: 8,
  soulHarvestRateMult: 2, wraithNova: 0.8, miasmaSpreadsWithered: 1, witheredBurstAt: 10, wardPerThrall: 0.1, thrallCap: 7,
};

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: SWIFTSHADER_ARGS });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(120000);
  const { errors } = watchErrors(page);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5382/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const user = `lgqa_${Date.now() % 100000}`;
  await page.fill('#cw-user', user);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${user}@example.invalid`);
  await page.fill('#cw-pass', 'TestingLegend1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await preloadModules(page);
  const shot = (name) => shotFile(page, path.join(OUT, `qa-legendary-${name}.png`));

  // Shared in-page helpers (re-declared per evaluate; evaluates share window).
  await page.evaluate((ALL) => {
    const d = window.__cwDebug;
    const scene = window.__qaMods.runtime.getRuntime().view;
    const sim = () => d.sim();
    window.__lg = {
      ALL, scene, d,
      reset() {
        d.forceMods(null);
        d.god(true);
        d.goto('graves');
        d.advance(0.3);
        d.clear();
        sim().zones.clear();
        for (const t of [...sim().thralls.values()]) sim().killThrall(t, 'crumbled');
        scene.player.barrier = 0; scene.player.barrierPeak = 0; scene.player.hp = scene.player.stats.maxHp;
        d.advance(0.1);
      },
      foe(dx, dz, hp = 1e7) {
        const p = d.player;
        const e = sim().spawnEnemy('robber', 'graves', p.x + dx, p.z + dz, false, false);
        e.hp = e.maxHp = hp;
        e.stunT = 1e6;
        return e;
      },
      raise(n, dx = 0, dz = -2) {
        for (let i = 0; i < n; i++) d.raise('robber', dx + (i % 5) * 0.9 - 1.8, dz - Math.floor(i / 5) * 0.9);
        d.advance(1.3);
        return [...sim().thralls.values()];
      },
    };
  }, ALL);

  const r = {};
  // 1. Thrall Death Burst
  r.deathBurst = await page.evaluate(() => {
    const L = window.__lg; L.reset();
    L.d.forceMods({ thrallDeathBurst: 0.6 });
    const [t] = L.raise(1);
    const near = L.foe(t.x - L.d.player.x + 1.5, t.z - L.d.player.z);
    const far = L.foe(t.x - L.d.player.x + 8, t.z - L.d.player.z);
    const hpBefore = near.hp, maxHp = t.maxHp;
    L.d.sim().killThrall(t, 'killed');
    L.d.advance(0.1);
    const burst = hpBefore - near.hp;
    // Sacrificed / crumbled do not burst; with the mod off a kill does not either.
    const [t2, ] = L.raise(1); const hp2 = near.hp; L.d.sim().killThrall(t2, 'sacrificed'); L.d.advance(0.05);
    const sacrificed = hp2 - near.hp;
    L.d.forceMods({ thrallDeathBurst: 0 });
    const [t3] = L.raise(1); const hp3 = near.hp; L.d.sim().killThrall(t3, 'killed'); L.d.advance(0.05);
    return { burst, expect: 0.6 * maxHp, farLoss: far.maxHp - far.hp, sacrificed, off: hp3 - near.hp };
  });
  console.log('deathBurst', JSON.stringify(r.deathBurst));
  assert.ok(Math.abs(r.deathBurst.burst - r.deathBurst.expect) < 1, 'burst = 0.6 x thrall max HP');
  assert.equal(r.deathBurst.farLoss, 0, 'far enemy untouched');
  assert.equal(r.deathBurst.sacrificed, 0, 'sacrificed thrall does not burst');
  assert.equal(r.deathBurst.off, 0, 'mod off: no burst');

  // 2. Champions
  r.champion = await page.evaluate(() => {
    const L = window.__lg; L.reset();
    L.d.forceMods({ championEvery: 5 });
    const ts = L.raise(10, 0, -3);
    return { n: ts.length, champions: ts.filter((t) => t.champion).length, ratio: ts.find((t) => t.champion).maxHp / ts.find((t) => !t.champion).maxHp, state: L.d.legendState() };
  });
  console.log('champion', JSON.stringify(r.champion));
  assert.equal(r.champion.champions, 2, 'two Champions among ten');
  assert.ok(Math.abs(r.champion.ratio - 2) < 0.05, 'Champion has double health');
  await shot('champions');

  // 3. Spear rally
  r.rally = await page.evaluate(() => {
    const L = window.__lg; L.reset();
    L.d.forceMods({ spearRally: 0.75 });
    const ts = L.raise(3);
    const a = L.foe(6, 0), b = L.foe(9, 1);
    const p = L.d.player; p.essence = p.resource.max; p.cooldowns.clear(); p.castUntil = 0;
    const res = L.scene.abilities.cast('marrow_spear', { x: a.x, z: a.z, enemyId: a.id }, L.scene.now);
    L.d.advance(0.6);
    return { res, markT: a.markT ?? 0, bMark: b.markT ?? 0, targets: ts.map((t) => L.d.sim().thralls.get(t.id)?.target) , id: a.id };
  });
  console.log('rally', JSON.stringify(r.rally));
  assert.equal(r.rally.res, 'ok');
  assert.ok(r.rally.markT > 2.5, 'target marked ~4 s');
  assert.ok(r.rally.targets.every((t) => t === r.rally.id), 'every thrall retargeted');
  await shot('rally-mark');

  // 4. Ward reflect + 5. Colossus guard + 6. Litany shatter (through the real onHurt path, god off, big HP)
  r.defence = await page.evaluate(() => {
    const L = window.__lg; L.reset();
    const { scene, d } = L;
    const p = d.player;
    d.god(false);
    p.stats.maxHp = 100000; p.hp = 100000;
    const out = {};
    // forceMods re-derives the stats (and max HP), so top the body up after each call.
    const fm = (m) => { d.forceMods(m); p.stats.maxHp = 100000; p.hp = 100000; };
    // Ward reflect: 3 thralls x 0.1 ward = 30% prevented; 40% of it is dealt back to the attacker standing at the blow's origin.
    L.raise(3);
    fm({ wardPerThrall: 0.1, wardReflect: 0.4 });
    const atk = L.foe(2, 0);
    let hp0 = atk.hp;
    scene.onHurt(100, 'melee', atk.x, atk.z); // the hit intent lands synchronously (no frame step: thralls would chip it too)
    out.reflect = { dealt: hp0 - atk.hp, expect: 100 * 0.3 * 0.4 };
    fm({ wardReflect: 0 });
    hp0 = atk.hp; scene.onHurt(100, 'melee', atk.x, atk.z);
    out.reflectOff = hp0 - atk.hp;
    // Colossus: with 3+ thralls an extra 25% on top of the ward (multiplicative), under the 75% cap; with 2 thralls nothing.
    fm({ wardPerThrall: 0.2, colossusGuard: 0.25 });
    p.hp = 100000; scene.onHurt(1000, 'melee', 99, 99);
    out.guard3 = 100000 - p.hp; // ward 0.6 (capped) -> 0.4 * 0.75 = 300
    const two = [...d.sim().thralls.values()]; d.sim().killThrall(two[0], 'crumbled'); d.advance(0.05);
    p.hp = 100000; scene.onHurt(1000, 'melee', 99, 99);
    out.guard2 = 100000 - p.hp; // ward 0.4 -> 600, no guard
    fm({ colossusGuard: 0.9, wardPerThrall: 0.6 });
    L.raise(1);
    p.hp = 100000; scene.onHurt(1000, 'melee', 99, 99);
    out.capped = 100000 - p.hp; // never below 25% of the blow
    // Litany shatter: a 500-point Litany barrier broken by one big blow bursts for 3x its size around the player.
    fm({ colossusGuard: 0, wardPerThrall: 0, litanyShatter: 3 });
    const near = L.foe(2.5, 0);
    p.barrier = 500; p.barrierPeak = 500; hp0 = near.hp;
    scene.onHurt(900, 'melee', 99, 99);
    d.advance(0.05);
    out.shatter = { dealt: hp0 - near.hp, expect: 1500 };
    // Decay is not damage: a barrier that melts away does not shatter.
    p.barrier = 100; p.barrierPeak = 100; hp0 = near.hp; p.barrier = 0; scene.onHurt(1, 'melee', 99, 99); d.advance(0.05);
    out.noShatter = hp0 - near.hp;
    d.god(true);
    return out;
  });
  console.log('defence', JSON.stringify(r.defence));
  const D = r.defence;
  assert.ok(Math.abs(D.reflect.dealt - D.reflect.expect) < 0.5, 'reflect = 40% of what the ward prevented');
  assert.equal(D.reflectOff, 0, 'reflect off: nothing');
  assert.ok(Math.abs(D.guard3 - 300) < 1, 'ward 60% x guard 25% => 70% reduction');
  assert.ok(Math.abs(D.guard2 - 600) < 1, 'under 3 thralls: no guard');
  assert.ok(D.capped >= 250 - 1, 'total reduction capped at 75%');
  assert.ok(Math.abs(D.shatter.dealt - D.shatter.expect) < 1, 'shatter = 3 x barrier');
  assert.equal(D.noShatter, 0, 'decay does not shatter');
  await shot('shatter');

  // 7. Wisps + 8. Soul rate + 9. Wraith nova
  r.requiem = await page.evaluate(() => {
    const L = window.__lg; L.reset();
    const { scene, d } = L;
    const p = d.player;
    const out = {};
    d.forceMods({ corpseWisp: 8 });
    for (let i = 0; i < 5; i++) scene.abilities.onCorpseConsumed();
    out.wisps = d.legendState().wisps;
    d.god(false); p.stats.maxHp = 1000; p.hp = 100;
    d.advance(1.1);
    out.healed = p.hp - 100; // 3 wisps x 2% x 1000 = 60/s (plus the ordinary regen)
    d.god(true);
    d.advance(9);
    out.wispsAfter = d.legendState().wisps;
    // Soul Harvest rate
    d.forceMods({ soulHarvestRateMult: 2 });
    p.souls = 0;
    for (let i = 0; i < 5; i++) p.addSouls(1);
    out.souls2x = p.souls;
    d.forceMods({ soulHarvestRateMult: 1 });
    p.souls = 0;
    for (let i = 0; i < 5; i++) p.addSouls(1);
    out.souls1x = p.souls;
    // Nova
    d.forceMods({ wraithNova: 0.8, corpseWisp: 8, thrallKind: 'wraith' });
    L.raise(2, 0, -2);
    const nearW = [...d.sim().thralls.values()][0];
    const e = L.foe(nearW.x - p.x + 1.2, nearW.z - p.z);
    const f = L.foe(20, 20);
    scene.abilities.onCorpseConsumed();
    p.essence = p.resource.max; p.cooldowns.clear(); p.castUntil = 0;
    p.souls = p.soulsMax;
    const hp0 = e.hp;
    out.novaCast = scene.abilities.cast('miasma', { x: p.x + 8, z: p.z }, scene.now);
    d.advance(0.1);
    out.nova = { dealt: hp0 - e.hp, atLeast: 0.8 * p.stats.spellPower, farLoss: f.maxHp - f.hp };
    out.souls = p.souls;
    return out;
  });
  console.log('requiem', JSON.stringify(r.requiem));
  const Q = r.requiem;
  assert.equal(Q.wisps, 3, 'wisps capped at 3');
  assert.ok(Q.healed >= 55, 'wisps heal 2% max HP per second each');
  assert.equal(Q.wispsAfter, 0, 'wisps expire');
  assert.equal(Q.souls2x, 10, '2x soul fill');
  assert.equal(Q.souls1x, 5, '1x soul fill unchanged');
  assert.equal(Q.novaCast, 'ok');
  assert.ok(Q.nova.dealt >= Q.nova.atLeast - 0.01, 'a wraith/wisp nova struck the enemy beside it');
  assert.equal(Q.nova.farLoss, 0, 'far enemy untouched');
  // The meter started full (soulsMax); stray kills from the nova may add a few souls back, so only require that it was spent.
  assert.ok(Q.souls < 25, 'the meter was spent');

  // 10. Contagion + 11. Chain Plague
  r.plague = await page.evaluate(() => {
    const L = window.__lg; L.reset();
    const { scene, d } = L;
    const sim = d.sim();
    const p = d.player;
    const out = {};
    d.forceMods({ miasmaSpreadsWithered: 1, witheredBurstAt: 10 });
    p.essence = p.resource.max; p.cooldowns.clear(); p.castUntil = 0;
    const target = L.foe(8, 0);
    out.cast = scene.abilities.cast('miasma', { x: target.x, z: target.z, enemyId: target.id }, scene.now);
    d.advance(1.4);
    sim.enemies.delete(target.id); // it only aimed the cast; keep it out of the spread count
    const clouds = () => [...sim.zones.values()].filter((z) => z.kind === 'miasma' && !z.hostile);
    out.cloudsBefore = clouds().length;
    const zone = clouds()[0];
    // Contagion: a dying enemy in the cloud passes its stacks on to three of four neighbours within 4 m.
    const a = L.foe(zone.x - p.x, zone.z - p.z, 1e7);
    const ns = [[3.2, 0], [0, 3.2], [-3.2, 0], [0, -3.7]].map(([dx, dz]) => L.foe(zone.x - p.x + dx, zone.z - p.z + dz));
    Object.assign(a, { withered: 4, witheredT: 5, witheredDps: 2, witheredOwner: d.self() });
    a.hp = 0;
    d.advance(0.1);
    out.spread = ns.filter((n) => n.withered >= 4).length;
    // Chain Plague: ten stacks consume themselves into a fresh Miasma centred on the enemy.
    const c = L.foe(zone.x - p.x + 14, zone.z - p.z);
    Object.assign(c, { withered: 10, witheredT: 5, witheredDps: 2, witheredOwner: d.self() });
    d.advance(0.1);
    out.plagueStacks = c.withered;
    out.cloudsAfter = clouds().length;
    out.cloudAtEnemy = clouds().some((z) => Math.hypot(z.x - c.x, z.z - c.z) < 0.5);
        // The cast leaves two clouds here (3.8 and 5.7); the burst copies the owner's last cast.
    const castRs = clouds().filter((z) => Math.hypot(z.x - zone.x, z.z - zone.z) < 0.5).map((z) => z.r);
    out.sameSize = clouds().filter((z) => Math.hypot(z.x - c.x, z.z - c.z) < 0.5).every((z) => castRs.some((r) => Math.abs(r - z.r) < 1e-6));
    return out;
  });
  console.log('plague', JSON.stringify(r.plague));
  assert.equal(r.plague.cast, 'ok');
  assert.equal(r.plague.spread, 3, 'Contagion spreads to exactly 3');
  // The fresh cloud re-withers its centre by one stack in the same tick; ten were consumed.
  assert.ok(r.plague.plagueStacks <= 1, 'Chain Plague consumed the stacks');
  assert.ok(r.plague.cloudAtEnemy && r.plague.cloudsAfter > r.plague.cloudsBefore, 'a fresh Miasma opened on the enemy');
  assert.ok(r.plague.sameSize, 'normal Miasma size');

  // 12. Everything on: a fight, and a screenshot.
  await page.evaluate(() => {
    const L = window.__lg; L.reset();
    const { scene, d } = L;
    d.forceMods({ ...L.ALL, thrallKind: 'warrior' });
    d.zoom(0.62);
    L.raise(7, 0, -2.5);
    for (let i = 0; i < 12; i++) {
      const e = L.foe(4 + (i % 4) * 1.4, -3 + Math.floor(i / 4) * 2.2, 4000);
      e.stunT = 0; e.speed = 0;
      Object.assign(e, { withered: 3 + (i % 5), witheredT: 4, witheredDps: 1, witheredOwner: d.self() });
    }
    for (let i = 0; i < 3; i++) scene.abilities.onCorpseConsumed();
    const p = d.player; p.essence = p.resource.max; p.cooldowns.clear(); p.castUntil = 0;
    const t = [...d.sim().enemies.values()][0];
    scene.abilities.cast('marrow_spear', { x: t.x, z: t.z, enemyId: t.id }, scene.now);
    d.advance(0.45);
    for (const th of [...d.sim().thralls.values()].slice(0, 2)) d.sim().killThrall(th, 'killed');
    p.cooldowns.clear(); p.castUntil = 0; p.essence = p.resource.max;
    scene.abilities.cast('miasma', { x: t.x, z: t.z, enemyId: t.id }, scene.now);
    d.advance(0.5);
  });
  await shot('all-on');

  // 13. Perf: the same fixed scene, mods off vs everything on (CPU update ms, draw calls, sim step cost).
  const perf = await page.evaluate(() => {
    const L = window.__lg;
    const { scene, d } = L;
    const sim = d.sim();
    const scenario = (on) => {
      L.reset();
      d.forceMods(on ? { ...L.ALL, thrallKind: 'warrior' } : null);
      d.zoom(0.8);
      L.raise(7, 0, -3);
      for (let i = 0; i < 30; i++) {
        const e = L.foe(Math.sin(i) * (4 + (i % 5)), Math.cos(i) * (4 + (i % 5)), 1e7);
        Object.assign(e, { withered: i % 9, witheredT: 1e3, witheredDps: 0, witheredOwner: d.self() });
      }
      if (on) for (let i = 0; i < 3; i++) scene.abilities.onCorpseConsumed();
      d.advance(1);
      const t0 = performance.now();
      for (let i = 0; i < 600; i++) sim.step(0.05);
      const simMs = (performance.now() - t0) / 600;
      const reads = [];
      for (let i = 0; i < 3; i++) { const r = d.perf(120); reads.push({ updateMs: r.updateMs, calls: r.calls, triangles: r.triangles }); }
      reads.sort((a, b) => a.updateMs - b.updateMs);
      return { simStepMs: +simMs.toFixed(4), ...reads[1], updateMs: +reads[1].updateMs.toFixed(3), wisps: d.legendState().wisps, zones: sim.zones.size };
    };
    return { off: scenario(false), on: scenario(true) };
  });
  console.log('perf', JSON.stringify(perf));

  await page.evaluate(() => window.__cwDebug.forceMods(null));
  const bad = errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e));
  assert.deepEqual(bad, [], 'page errors');
  await browser.close();
  console.log('ok — screenshots in', OUT);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
