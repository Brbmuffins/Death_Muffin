// (Headless Chromium never hides a page, so CDP's frozen lifecycle state is a no-op here; Debugger.pause genuinely stops
// every timer and frame on the page, which is what a phone does on an app switch.)
// AFK must survive the phone's app switch. The page is FROZEN (CDP Page.setWebLifecycleState) while the wall clock jumps;
// on return the lost time must be caught up (capped at the server AFK window), the Ledger must show it, and nothing may stop AFK.
//   DM_PLAYWRIGHT_MODULE=... DM_CHROMIUM_PATH=... DM_QA_URL=http://127.0.0.1:5389/?offline node tools/qa/afk-resume-smoke.cjs
// AR_ONLY=phone|desktop limits the profiles.
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { SWIFTSHADER_ARGS, watchErrors, preloadModules } = require('./lib/qa-common.cjs');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5389/?offline&afkdebug';
const PROFILES = [
  { name: 'phone', opts: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }, touch: true },
  { name: 'desktop', opts: { viewport: { width: 1280, height: 800 } }, touch: false },
].filter((p) => !process.env.AR_ONLY || process.env.AR_ONLY === p.name);
const AWAY_S = 600; // ten minutes away: far more than the cap
const CAP_S = 90;
const out = [];

async function run(browser, P) {
  const ctx = await browser.newContext(P.opts); ctx.setDefaultTimeout(30000);
  const page = await ctx.newPage();
  const { errors } = watchErrors(page);
  if (process.env.AR_DEBUG) page.on('console', (m) => console.log('  [console]', m.text().slice(0, 220)));
  await page.addInitScript(() => {
    localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false, autoGather: false }));
    // Wall-clock control: the skew is applied the moment the page is frozen / hidden-for-real, like a phone sleeping.
    const real = Date.now.bind(Date);
    window.__skew = 0; window.__pending = 0; window.__armedAt = 0;
    // The jump is applied by the first Date.now() call after the thaw, so nothing can observe it before the page resumes.
    Date.now = () => { if (window.__pending && performance.now() - window.__armedAt > 300) { window.__skew += window.__pending; window.__pending = 0; } return real() + window.__skew; };
    window.addEventListener('pointerdown', () => { window.__tapDelay = performance.now() - window.__backAt; }, true);
    window.__rep = [];
    new MutationObserver((ms) => { for (const m of ms) { for (const n of m.addedNodes) if (n.classList?.contains('cw-gather-report')) window.__rep.push('+' + Math.round(performance.now())); for (const n of m.removedNodes) if (n.classList?.contains('cw-gather-report')) window.__rep.push('-' + Math.round(performance.now())); } }).observe(document, { childList: true, subtree: true });
    window.__setHidden = (h) => {
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => h });
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => (h ? 'hidden' : 'visible') });
      document.dispatchEvent(new Event('visibilitychange'));
      if (!h) { window.__backAt = performance.now(); window.dispatchEvent(new Event('pageshow')); }
    };
  });
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `ar_${P.name}${Date.now() % 10000}`); await page.fill('#cw-email', 't@example.invalid'); await page.fill('#cw-pass', 'TestingControls');
  await page.locator('#cw-login-btn').click(); await page.locator('.cw-disc').first().click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await preloadModules(page, { loot: '/src/gameplay/loot.ts' });
  const cdp = await ctx.newCDPSession(page);
  await cdp.send('Debugger.enable');
  // Phone app switch: hidden, the whole page stops (no timers, no frames) while the wall clock runs, then it comes back.
  const appSwitch = async (awayS, withTap = null) => {
    await page.evaluate((a) => { window.__armedAt = performance.now(); window.__pending = a * 1000; window.__setHidden(true); }, awayS);
    await cdp.send('Debugger.pause');
    await new Promise((r) => setTimeout(r, 450));
    await cdp.send('Debugger.resume');
    await page.evaluate((tap) => {
      window.__setHidden(false);
      // The stray touch that rides in with the return, in the same task as the visibility change.
      if (tap) document.querySelector('canvas').dispatchEvent(new PointerEvent('pointerdown', { pointerType: 'touch', pointerId: 9, isPrimary: true, button: 0, clientX: tap.x, clientY: tap.y, bubbles: true, cancelable: true }));
    }, withTap);
  };
  const logs = () => page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => s.item_id === 'log_oak').reduce((n, s) => n + s.quantity, 0));
  const g = () => page.evaluate(() => { const x = window.__cwDebug.gathering(); return { afk: x.afk, working: x.working, node: x.node, last: x.lastStopReason, log: x.stopLog.length }; });
  const reportOpen = () => page.locator('.cw-gather-report').count();

  const startAfk = async () => {
    await page.keyboard.press('p');
    await page.getByRole('button', { name: 'Start AFK Woodcutting', exact: true }).click();
    await page.waitForFunction(() => window.__cwDebug.gathering().afk);
    await page.waitForFunction(() => { window.__cwDebug.advance(0.2, false); return window.__cwDebug.gathering().working; }, null, { timeout: 30000, polling: 300 });
    await page.keyboard.press('Escape');
    await page.waitForFunction(() => !document.querySelector('.cw-panel-float'), null, { timeout: 5000 }).catch(() => {});
  };
  const closeReport = async () => { if (await reportOpen()) { await page.locator('.cw-gather-report [data-close]').first().click(); } };

  await startAfk();
  // Let a few real cycles land so there is a baseline (and the server ledger has moved on from the AFK start).
  await page.evaluate(() => window.__cwDebug.advance(8, false));
  await page.evaluate(() => window.__cwDebug.gathering());
  const before = await logs();

  // --- 1. Phone app switch: frozen, ten minutes pass, thaw ---
  await appSwitch(AWAY_S);
  // Real resume path: the runtime notices the gap (rAF or resume event) and catches up.
  await page.waitForFunction(() => document.querySelector('.cw-gather-report'), null, { timeout: 60000, polling: 250 }).catch(async (e) => {
    console.log('DIAG', JSON.stringify(await page.evaluate(() => ({ skew: window.__skew, pending: window.__pending, hidden: document.hidden, g: window.__cwDebug.gathering(), toasts: document.body.innerText.slice(0, 300) }))));
    throw e;
  });
  const skew = await page.evaluate(() => window.__skew);
  assert.ok(skew >= AWAY_S * 1000, `the freeze event applied the wall-clock jump (${skew})`);
  const after = await logs();
  const gained = after - before;
  const st = await g();
  assert.equal(st.afk, true, `AFK survived the app switch (last stop: ${st.last})`);
  assert.equal(st.last, null, 'no stop reason logged');
  assert.equal(st.log, 0, 'stop log empty');
  // 90 s / 2.4 s = ~37 cycles, 1-4 logs per success. Far above nothing, never above the cap.
  assert.ok(gained >= 15, `caught up the away time (+${gained} logs)`);
  assert.ok(gained <= 37 * 4 + 12, `catch-up honours the ${CAP_S}s cap (+${gained} logs)`);
  const reportText = await page.locator('.cw-gather-report').innerText();
  assert.match(reportText, /While you were away|Ledger/i);
  assert.match(reportText, /background/i);
  out.push({ profile: P.name, scenario: 'frozen-10min', gained, report: reportText.replace(/\s+/g, ' ').slice(0, 160) });
  await closeReport();

  // --- 2. Return tap right after resume must not read as the player taking over ---
  if (P.touch) {
    await appSwitch(120, { x: P.opts.viewport.width / 2, y: P.opts.viewport.height / 2 });
    await page.waitForFunction(() => document.querySelector('.cw-gather-report'), null, { timeout: 30000, polling: 250 }).catch(async (e) => {
      console.log('DIAG2', JSON.stringify(await page.evaluate(() => ({ rep: window.__rep, now: Math.round(performance.now()), back: Math.round(window.__backAt), tapDelay: window.__tapDelay, skew: window.__skew, hidden: document.hidden, g: window.__cwDebug.gathering(), panel: [...document.querySelectorAll('.cw-panel-float')].map((x) => x.className) }))));
      throw e;
    });
    const s2 = await g();
    const delay = await page.evaluate(() => window.__tapDelay);
    assert.equal(s2.afk, true, `the return tap (${Math.round(delay)} ms after the return) did not end AFK (${s2.last})`);
    await closeReport();
    out.push({ profile: P.name, scenario: 'return-tap', afk: s2.afk });
  }

  // --- 3. Hidden-tab interval (desktop-style background): counts real time once, no double count on return ---
  const hidden = (v) => page.evaluate((h) => {
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => h });
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => (h ? 'hidden' : 'visible') });
    document.dispatchEvent(new Event('visibilitychange'));
  }, v);
  const b3 = await logs();
  await hidden(true);
  await new Promise((r) => setTimeout(r, 9000)); // the 1 s interval runs on real time
  const mid = await logs();
  await hidden(false);
  await new Promise((r) => setTimeout(r, 1500));
  const a3 = await logs();
  const s3 = await g();
  if (!s3.afk) console.log('DIAG3', JSON.stringify(await page.evaluate(() => { const d = window.__cwDebug; const nodes = window.__cwDebug.gathering(); return { p: [d.player.x, d.player.z], hasPath: d.player.hasPath, area: d.player.area, stop: nodes.stopLog, status: nodes.status }; })));
  assert.equal(s3.afk, true, `hidden/visible toggle kept AFK (${s3.last})`);
  assert.ok(mid - b3 >= 1, `the hidden-tab interval still gathers (+${mid - b3})`);
  // ~9 s hidden is ~4 cycles (<= 16 logs); a double count on return would add a second batch of the same size or more.
  assert.ok(a3 - b3 <= 4 * 4 + 12, `no double counting on return (+${a3 - b3} logs over ~10.5 s)`);
  out.push({ profile: P.name, scenario: 'hidden-interval', hiddenGain: mid - b3, total: a3 - b3 });
  assert.equal(errors.length, 0, errors.join('\n'));
  await ctx.close();
}

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: SWIFTSHADER_ARGS });
  try { for (const P of PROFILES) await run(browser, P); console.log(JSON.stringify(out, null, 1)); }
  catch (e) { console.error(e); console.log(JSON.stringify(out)); process.exitCode = 1; }
  finally { await browser.close(); }
})();
