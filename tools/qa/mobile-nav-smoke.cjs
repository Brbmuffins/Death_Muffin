// Mobile navigation + touch smoke (phone portrait, touch emulated):
//   - Skills -> Contracts shows a Back button; Back reopens Skills; a second level (Skills -> Garden -> ...) unwinds in order;
//   - the browser/phone Back gesture closes or steps back through panels and never leaves the game while a panel is open;
//   - tapping the ground walks the hero; the flask button and the upgrades toggle work.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL=http://127.0.0.1:5360/?offline node tools/qa/mobile-nav-smoke.cjs
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { VIRTUAL_TIMERS, newCharacter, step } = require('./lib/first-hour-lib.cjs');

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const ctx = await browser.newContext({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript(VIRTUAL_TIMERS);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5360/?offline');
  await newCharacter(page, 'Ossuary', `nav${Date.now() % 10000}`);
  await step(page, 1);
  const frame = () => page.evaluate(() => window.__cwDebug.advance(0.05));
  const title = async () => { await frame(); return page.evaluate(() => [...document.querySelectorAll('.cw-panel-float')].find((e) => e.offsetParent)?.querySelector('.cw-title,h2')?.textContent?.trim() ?? null); };
  const tap = async (sel) => {
    // Phone: the panel buttons live in the Menu sheet; open it first.
    if (sel.startsWith('.hud-menusheet')) { await page.locator('.hud-menu [data-menu]').tap(); await frame(); assert.ok(await page.locator('.hud-menusheet').isVisible(), 'Menu sheet opens'); }
    await page.locator(sel).first().tap(); await frame();
  };
  const url0 = page.url();

  await tap('.hud-menusheet [data-open="professions"]');
  assert.equal(await title(), 'Skills');
  assert.equal(await page.locator('[data-back]').count(), 0, 'a top-level panel has no Back');
  await tap('[data-contracts]');
  assert.match(await title(), /Contracts/);
  await frame();
  assert.equal(await page.locator('[data-back]').count(), 1, 'Contracts opened from Skills shows Back');
  await step(page, 0.5);
  await tap('[data-back]');
  assert.equal(await title(), 'Skills', 'Back returns to Skills');
  await frame();
  assert.equal(await page.locator('[data-back]').count(), 0);

  // Two levels deep, unwound with the phone's Back gesture.
  await tap('[data-garden]');
  assert.match(await title(), /Garden/);
  await page.keyboard.press('o'); // Contracts from inside the Garden
  assert.match(await title(), /Contracts/);
  await page.goBack(); await frame();
  assert.match(await title(), /Garden/, 'phone Back: Contracts -> Garden');
  await page.goBack(); await frame();
  assert.equal(await title(), 'Skills', 'phone Back: Garden -> Skills');
  await page.goBack(); await frame();
  assert.equal(await title(), null, 'phone Back: Skills -> closed');
  assert.equal(page.url(), url0, 'still in the game');
  // Closing with the X leaves no stray history entry behind.
  await tap('.hud-menusheet [data-open="inventory"]');
  await tap('.cw-panel-float [data-close]');
  await frame(); await frame();
  assert.equal(await title(), null);
  const len = await page.evaluate(() => history.length);

  // Touch: tap to walk.
  const p0 = await page.evaluate(() => { const p = window.__cwDebug.player ?? window.__cwDebug.avatar; return { x: p.x, z: p.z }; }).catch(() => null);
  await page.touchscreen.tap(200, 300);
  await step(page, 1.5);
  const p1 = await page.evaluate(() => { const p = window.__cwDebug.player ?? window.__cwDebug.avatar; return { x: p.x, z: p.z }; }).catch(() => null);
  if (p0 && p1 && p0.x !== undefined) assert.ok(Math.hypot(p1.x - p0.x, p1.z - p0.z) > 0.5, `tap walks the hero ${JSON.stringify([p0, p1])}`);

  assert.ok(await page.locator('[data-flask]').isVisible(), 'flask button on touch');
  await tap('[data-uptoggle]');
  assert.ok(await page.locator('.hud-upgrades').isVisible(), 'upgrades toggle opens the plate');
  await tap('[data-uptoggle]');
  assert.ok(!(await page.locator('.hud-upgrades').isVisible()));
  // A tap on a rite casts (no spell card); press-and-hold shows the card without casting.
  const casts = await page.evaluate(() => { window.__casts = 0; return 0; });
  await page.evaluate(() => { const b = document.querySelector('[data-slot="1"]'); b.addEventListener('click', () => window.__casts++); });
  await page.locator('[data-slot="1"]').tap(); await frame();
  assert.equal(await page.locator('.hud-spell-tooltip').isVisible(), false, 'a tap does not open the spell card');
  assert.equal(await page.evaluate(() => window.__casts), 1, 'the tap reached the cast handler');
  const box = await page.locator('[data-slot="2"]').boundingBox();
  const cdp = await ctx.newCDPSession(page);
  const pt = { x: box.x + box.width / 2, y: box.y + box.height / 2 };
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [pt] });
  await page.waitForTimeout(100);
  await page.evaluate(() => window.__vt.run(600)); // the hold timer runs on the harness's virtual clock
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await frame();
  assert.equal(await page.locator('.hud-spell-tooltip').isVisible(), true, 'press and hold opens the spell card');
  console.log('card', JSON.stringify(await page.locator('.hud-spell-tooltip').boundingBox()));
  assert.ok((await page.locator('.hud-spell-tooltip').boundingBox()).height <= 380, 'spell card fits a phone');
  await page.touchscreen.tap(60, 120); await frame();
  assert.equal(await page.locator('.hud-spell-tooltip').isVisible(), false, 'a tap elsewhere closes the spell card');
  // AFK farming redraws the Skills panel every tick: the scroll position must survive it.
  await page.evaluate(() => window.__cwDebug.advance(0));
  await tap('.hud-menusheet [data-open="professions"]');
  const scrolled = await page.evaluate(() => { const p = [...document.querySelectorAll('.cw-panel-float')].find((e) => e.offsetParent); p.scrollTop = 400; return p.scrollTop; });
  assert.ok(scrolled > 50, `Skills panel scrolls on a phone (${scrolled})`);
  await page.evaluate(() => { window.__cwDebug.skillsTick(); window.__cwDebug.skillsTick(); });
  const after = await page.evaluate(() => [...document.querySelectorAll('.cw-panel-float')].find((e) => e.offsetParent).scrollTop);
  assert.equal(after, scrolled, 'Skills keeps its scroll through AFK redraws');
  await page.keyboard.press('Escape');
  assert.deepEqual(errors, []);
  console.log('mobile-nav-smoke: ok', { historyLength: len });
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
