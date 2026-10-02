// Connection alerts on a phone: losing the network shows "Connection lost" once, getting it back shows "Back online" once;
// the viewport cannot be zoomed (double tap / pinch are the game's, not the page's).
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL=http://127.0.0.1:5374/ node tools/qa/connection-smoke.cjs
// Uses the real (non-?offline) client path, so the offline-edition guard does not hide the alerts; the dev mock is still used for login.
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { VIRTUAL_TIMERS, newCharacter, step } = require('./lib/first-hour-lib.cjs');

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  await page.addInitScript(VIRTUAL_TIMERS);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ tips: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5374/?offline');
  await newCharacter(page, 'Ossuary', `cn${Date.now() % 10000}`);
  await step(page, 1);
  const toasts = () => page.evaluate(() => [...document.querySelectorAll('.hud-toast')].map((t) => t.textContent));
  const meta = await page.evaluate(() => document.querySelector('meta[name=viewport]').content);
  assert.match(meta, /maximum-scale=1/);
  assert.equal(await page.evaluate(() => getComputedStyle(document.body).touchAction), 'manipulation');
  await ctx.setOffline(true);
  await step(page, 1);
  const off = await toasts();
  assert.ok(off.some((t) => /Connection lost/.test(t)), "offline alert");
  console.log('offline toasts', off);
  await ctx.setOffline(false);
  await step(page, 1);
  const on = await toasts();
  assert.ok(on.some((t) => /Back online/.test(t)), "back online alert");
  console.log('online toasts', on);
  await browser.close();
  return { off, on };
})().catch((e) => { console.error(e); process.exit(1); });
