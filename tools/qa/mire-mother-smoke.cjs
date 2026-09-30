/**
 * Mire Mother smoke (offline preview, High quality): awake on her hummock, sinking under a ringed hummock and bursting out winded,
 * phase 2 (the marsh floods: hummocks shrink), phase 3 (the Drowned Rite over player-side corpses, then a starved rite).
 *   npm run dev -- --host 127.0.0.1 --port 5306 --strictPort
 *   DM_QA_URL=http://127.0.0.1:5306/?offline node tools/qa/mire-mother-smoke.cjs
 */
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const OUT = process.env.DM_QA_ARTIFACT_DIR || os.tmpdir();

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  const errors = [];
  const models = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  page.on('response', (r) => r.url().endsWith('.glb') && models.push([r.url().split('/').slice(-2).join('/'), r.status()]));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5306/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `mmqa_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('mmqa@example.invalid');
  await page.fill('#cw-pass', 'TestingMire1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 180000 });
  const shot = async (name) => {
    for (let i = 0; i < 4; i++) {
      try { return await page.screenshot({ path: path.join(OUT, `${name}.png`), timeout: 150000 }); } catch (e) { if (i === 3) throw e; }
    }
  };
  process.on('exit', () => errors.length && console.log('PAGE ERRORS', errors.slice(0, 5)));
  const settle = async () => { await page.waitForTimeout(2500); await page.evaluate(() => window.__cwDebug.advance(0.05)); };

  // --- Awake on her hummock.
  await page.evaluate(() => {
    const d = window.__cwDebug;
    d.god(true);
    d.unlockAll();
    d.goto('fen');
    d.advance(0.5);
    d.clear();
    d.player.x = -30; d.player.z = -79;
    d.boss('mire');
    d.zoom(0.75);
    for (let i = 0; i < 8; i++) d.advance(0.5);
  });
  await settle();
  await shot('mire-awake');
  assert.equal(await page.evaluate(() => window.__cwDebug.sim().bossState.id), 'mire');

  // --- Phase 1: the ripple ring, then the burst.
  const sink = await page.evaluate(() => {
    const d = window.__cwDebug;
    const b = d.sim().bosses.mire;
    for (let i = 0; i < 400; i++) {
      d.advance(0.1);
      if (b.pending.some((p) => p.kind === 'surface')) return { ok: true, state: d.sim().bossState.state };
    }
    return { ok: false };
  });
  console.log('sink', JSON.stringify(sink));
  assert.ok(sink.ok && sink.state === 'sunk', 'she never sank under a hummock');
  await page.evaluate(() => window.__cwDebug.advance(1.4));
  await settle();
  await shot('mire-ripple');
  const up = await page.evaluate(() => {
    const d = window.__cwDebug;
    const hp = d.sim().bossState.hp;
    d.sim().bosses.mire.damage(1000, d.self(), 0);
    const under = d.sim().bossState.hp === hp;
    for (let i = 0; i < 40; i++) d.advance(0.1);
    return { under, surfaced: d.sim().bossState.state !== 'sunk' };
  });
  console.log('surface', JSON.stringify(up));
  assert.ok(up.under && up.surfaced, 'untargetable while under, then surfaced');
  await settle();
  await shot('mire-winded');

  // --- Phase 2: the marsh floods.
  const flood = await page.evaluate(() => {
    const d = window.__cwDebug;
    const s = d.sim();
    s.bossState.hp = s.bossState.maxHp * 0.55;
    for (let i = 0; i < 30; i++) d.advance(0.1);
    return { phase: s.bossState.phase, flood: +d.fenFlood().toFixed(2), leeches: [...s.enemies.values()].filter((e) => e.def === 'mire_leech').length };
  });
  console.log('phase2', JSON.stringify(flood));
  assert.equal(flood.phase, 2);
  assert.ok(flood.flood < 0.85, 'hummocks should shrink');
  await settle();
  await shot('mire-flood');

  // --- Phase 3: the rite over player-side corpses.
  const rite = await page.evaluate(() => {
    const d = window.__cwDebug;
    const s = d.sim();
    s.bossState.hp = s.bossState.maxHp * 0.25;
    for (let i = 0; i < 10; i++) d.advance(0.1);
    for (let i = 0; i < 4; i++) s.addCorpse(-45 + i * 1.2, -80 + (i % 2), 'normal', 'robber', false, 0, 1, 'fen');
    const b = s.bosses.mire;
    let saw = false;
    for (let i = 0; i < 400 && !saw; i++) {
      d.advance(0.1);
      saw = b.pending.some((p) => p.kind === 'rite');
    }
    return { phase: s.bossState.phase, saw, flood: +d.fenFlood().toFixed(2), corpses: s.corpses.size };
  });
  console.log('phase3', JSON.stringify(rite));
  assert.ok(rite.phase === 3 && rite.saw, 'no Drowned Rite telegraphed');
  await page.evaluate(() => window.__cwDebug.advance(1.6));
  await settle();
  await shot('mire-rite');
  const after = await page.evaluate(() => {
    const d = window.__cwDebug;
    const s = d.sim();
    const risen0 = [...s.enemies.values()].filter((e) => e.def === 'risen').length;
    for (let i = 0; i < 30; i++) d.advance(0.1);
    return { risen0, risen: [...s.enemies.values()].filter((e) => e.def === 'risen').length, corpses: s.corpses.size };
  });
  console.log('rite result', JSON.stringify(after));
  assert.ok(after.risen > after.risen0 || after.corpses === 0, 'the rite did nothing');
  await settle();
  await shot('mire-drowned');
  assert.ok(models.every(([, s]) => s === 200 || s === 304), 'a model failed to load');
  assert.deepEqual(errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e)), [], 'page errors');
  await browser.close();
  console.log('ok — screenshots in', OUT);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
