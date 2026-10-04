// Co-op parties + the Depths (regression for "two logged-in players are auto-partied and cannot enter a dungeon"):
//  1. two players online together are NOT partied (each in their own solo world);
//  2. A makes a party, B joins its code: they see each other;
//  3. B (a party member) takes the Depths stair: it is NOT blocked, B steps out of the party, descends alone, and A sees B leave;
//  4. B climbs out: B rejoins the same party automatically and they see each other again; A (the world's keeper) never lost the world.
// Needs a dev server whose client talks to the port below:
//   VITE_WS_BASE=http://127.0.0.1:5397 npx vite --host 127.0.0.1 --port 5396 --strictPort
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5396/?offline&coop' node tools/qa/party-depths-smoke.cjs
// Env: DM_QA_RT_PORT (5397)  DM_QA_DOWN_MS (3000, how long the service stays down)  DM_QA_REJOIN_MS (20000)
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5396/?offline&coop';
const PORT = process.env.DM_QA_RT_PORT || '5397';
const DOWN = +(process.env.DM_QA_DOWN_MS || 3000);
const REJOIN = +(process.env.DM_QA_REJOIN_MS || 20000);
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
const origin = new globalThis.URL(URL).origin;

function startRealtime() {
  const child = spawn(process.execPath, [path.join(__dirname, '../../server/realtime/server.js')], {
    env: { ...process.env, REALTIME_PORT: PORT, REALTIME_HOST: '127.0.0.1', DEV_TRUST_TOKENS: '1', CORS_ORIGIN: origin, NODE_ENV: 'development' },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  return new Promise((resolve, reject) => {
    child.stdout.on('data', (d) => { if (String(d).includes('listening')) resolve(child); });
    child.once('exit', (c) => reject(new Error(`realtime exited ${c}`)));
    setTimeout(() => reject(new Error('realtime start timeout')), 10000);
  });
}

async function login(browser, name) {
  const ctx = await browser.newContext({ viewport: { width: 1024, height: 700 } });
  const page = await ctx.newPage();
  page.setDefaultTimeout(300000);
  const errors = [];
  page.on('pageerror', (e) => { errors.push(e.message); console.log('pageerror', e.message); });
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', name);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${name}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 420000 });
  return { page, errors };
}
const net = (p) => p.evaluate(() => { const d = window.__cwDebug; return { ...d.net(), remotes: d.counts().remotes }; });

(async () => {
  const rt = await startRealtime();
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const n = Date.now() % 1000000;
    const A = await login(browser, `pdA_${n}`);
    await A.page.waitForFunction(() => window.__cwDebug.net().connected);
    const B = await login(browser, `pdB_${n}`);
    await B.page.waitForFunction(() => window.__cwDebug.net().connected);
    await wait(1500);
    let a = await net(A.page), b = await net(B.page);
    assert.notEqual(a.instance, b.instance, 'logged in together is not a party');
    assert.equal(a.remotes + b.remotes, 0, 'nobody auto-partied');
    assert.equal(await A.page.evaluate(() => window.__cwDebug.party.code()), null);
    console.log('1. online together, still solo');

    await A.page.evaluate(() => window.__cwDebug.party.create());
    await A.page.waitForFunction(() => window.__cwDebug.party.code() && window.__cwDebug.net().connected);
    const code = await A.page.evaluate(() => window.__cwDebug.party.code());
    await B.page.evaluate((c) => window.__cwDebug.party.join(c), code);
    await A.page.waitForFunction(() => window.__cwDebug.counts().remotes === 1);
    await B.page.waitForFunction(() => window.__cwDebug.counts().remotes === 1);
    assert.equal(await B.page.evaluate(() => window.__cwDebug.party.code()), code);
    console.log('2. partied via code', code);

    // B (a guest: it mirrors A's world) takes the stair.
    assert.equal((await net(B.page)).host, false, 'B is a guest');
    const entered = await B.page.evaluate(() => window.__cwDebug.depths.enter(1234, 1));
    assert.equal(entered, true, 'a party member can enter the Depths');
    await B.page.waitForFunction(() => window.__cwDebug.party.paused() && !window.__cwDebug.net().connected);
    const st = await B.page.evaluate(() => window.__cwDebug.depths.state());
    assert.ok(st.run && st.floor, 'B is on a Depths floor');
    await A.page.waitForFunction(() => window.__cwDebug.counts().remotes === 0, null, { timeout: 10000 });
    assert.equal((await net(A.page)).connected, true, 'A keeps the party world');
    console.log('3. B stepped out of the party and descended; A still in the world');

    // B climbs out (the exit asks twice) and rejoins the same party by itself.
    await B.page.evaluate(() => window.__cwDebug.depths.leave());
    await B.page.waitForFunction((c) => { const d = window.__cwDebug; return d.net().connected && d.net().instance === c && d.counts().remotes === 1 && !d.party.paused(); }, code, { timeout: REJOIN });
    await A.page.waitForFunction(() => window.__cwDebug.counts().remotes === 1, null, { timeout: 10000 });
    assert.equal(await B.page.evaluate(() => window.__cwDebug.depths.state().run), null, 'run closed');
    console.log('4. B rejoined the party after the run');

    // The host (A) can go down too, and comes back as well.
    assert.equal(await A.page.evaluate(() => window.__cwDebug.depths.enter(99, 1)), true);
    await A.page.waitForFunction(() => window.__cwDebug.party.paused());
    await A.page.evaluate(() => window.__cwDebug.depths.leave());
    await A.page.waitForFunction((c) => { const d = window.__cwDebug; return d.net().connected && d.net().instance === c && d.counts().remotes === 1; }, code, { timeout: REJOIN });
    console.log('5. the keeper can descend and return too');
    assert.equal(A.errors.length + B.errors.length, 0, `page errors: ${[...A.errors, ...B.errors].join(' | ')}`);
    console.log('PASS party-depths-smoke');
  } finally {
    await browser.close();
    try { rt.removeAllListeners('exit'); rt.kill('SIGKILL'); } catch {}
  }
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
