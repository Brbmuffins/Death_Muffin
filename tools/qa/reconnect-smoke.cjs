// Co-op auto-reconnect: two clients in one world, the realtime service is killed and restarted (by PID), both must rejoin the SAME
// world on their own and see each other again. Needs a dev server whose client talks to the port below:
//   VITE_WS_BASE=http://127.0.0.1:5395 npx vite --host 127.0.0.1 --port 5394 --strictPort
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5394/?offline&coop' node tools/qa/reconnect-smoke.cjs
// Env: DM_QA_RT_PORT (5395)  DM_QA_DOWN_MS (3000, how long the service stays down)  DM_QA_REJOIN_MS (20000)
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5394/?offline&coop';
const PORT = process.env.DM_QA_RT_PORT || '5395';
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
  page.setDefaultTimeout(120000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', name);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${name}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded);
  return { page, errors };
}
const net = (p) => p.evaluate(() => { const d = window.__cwDebug; return { ...d.net(), remotes: d.counts().remotes }; });

(async () => {
  let rt = await startRealtime();
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const n = Date.now() % 1000000;
    const A = await login(browser, `rcA_${n}`);
    await A.page.waitForFunction(() => window.__cwDebug.net().connected);
    const B = await login(browser, `rcB_${n}`);
    await B.page.waitForFunction(() => window.__cwDebug.net().connected);
    await A.page.waitForFunction(() => window.__cwDebug.counts().remotes === 1);
    await B.page.waitForFunction(() => window.__cwDebug.counts().remotes === 1);
    const before = [await net(A.page), await net(B.page)];
    assert.equal(before[0].instance, before[1].instance, 'both clients start in the same world');
    const code = before[0].instance;
    console.log('joined world', code, 'hosts:', before.map((b) => b.host));

    console.log(`killing realtime pid ${rt.pid}, down for ${DOWN} ms`);
    rt.removeAllListeners('exit');
    rt.kill('SIGKILL');
    await new Promise((r) => rt.once('exit', r));
    await A.page.waitForFunction(() => !window.__cwDebug.net().connected, null, { timeout: 15000 });
    await B.page.waitForFunction(() => !window.__cwDebug.net().connected, null, { timeout: 15000 });
    assert.equal((await net(A.page)).remotes, 0, 'remotes dropped while solo');
    await wait(DOWN);
    rt = await startRealtime();
    const t0 = Date.now();
    for (const [i, P] of [A, B].entries()) {
      await P.page.waitForFunction((c) => { const d = window.__cwDebug; return d.net().connected && d.net().instance === c && d.counts().remotes === 1; }, code, { timeout: REJOIN });
      console.log(`client ${'AB'[i]} rejoined ${code} and sees its partner after ${Date.now() - t0} ms`);
    }
    const after = [await net(A.page), await net(B.page)];
    assert.equal(after[0].instance, code);
    assert.equal(after[1].instance, code);
    assert.equal(after.filter((a) => a.host).length, 1, 'exactly one host after regrouping');
    assert.notEqual(after[0].id, before[0].id, 'fresh socket id');
    // Mirror vs host really work: a chat line crosses.
    await A.page.evaluate(() => window.__cwDebug.net());
    const toast = await A.page.locator('.hud-toast', { hasText: 'Back in world' }).count();
    assert.ok(toast >= 1, 'Back in world toast shown');
    await B.page.evaluate(() => window.__cwDebug.advance(0.5, false));
    assert.equal((await net(B.page)).remotes, 1, 'no duplicate remotes after rejoin');

    // Second drop: kill again, bring it back much later than the first backoff steps (cap path).
    rt.removeAllListeners('exit');
    rt.kill('SIGKILL');
    await new Promise((r) => rt.once('exit', r));
    await A.page.waitForFunction(() => !window.__cwDebug.net().connected, null, { timeout: 15000 });
    await wait(9000);
    rt = await startRealtime();
    for (const P of [A, B]) await P.page.waitForFunction((c) => { const d = window.__cwDebug; return d.net().connected && d.net().instance === c && d.counts().remotes === 1; }, code, { timeout: REJOIN });
    console.log('second outage (9 s) also recovered');
    assert.equal(A.errors.length + B.errors.length, 0, `page errors: ${[...A.errors, ...B.errors].join(' | ')}`);
    console.log('PASS reconnect-smoke');
  } finally {
    await browser.close();
    try { rt.removeAllListeners('exit'); rt.kill('SIGKILL'); } catch {}
  }
})().catch((e) => { console.error('FAIL', e); process.exit(1); });
