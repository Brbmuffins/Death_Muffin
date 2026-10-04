/**
 * set-summary-smoke.cjs - the Reliquary's set summary under the paper doll: equips three pieces of a first-collection set
 * and checks the pips, the active 2-piece line and the "Need N more" hint for the next tier. Offline preview only.
 *   DM_QA_URL='http://127.0.0.1:5348/?offline' node tools/qa/set-summary-smoke.cjs [out.png]
 */
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5348/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `setsum_${Date.now() % 1e6}`);
    await page.fill('#cw-email', 'set@example.invalid');
    await page.fill('#cw-pass', 'TestingSets1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 120000 });
    const parts = ['head', 'chest', 'hands'];
    await page.evaluate(async (parts) => {
      const inv = window.__cwDebug.inventory;
      for (const p of parts) inv.add({ item_id: `set_gravecaller_${p}`, quantity: 1 });
      await inv.flush();
    }, parts);
    await page.keyboard.press('i');
    for (const part of parts) {
      await page.locator('.cw-bag-grid .cw-slot').filter({ has: page.locator(`img[src*="set_gravecaller_${part}.svg"]`) }).click();
      await page.locator('.cw-bag-detail [data-act]').click();
      await page.locator(`.cw-equip img[src*="set_gravecaller_${part}.svg"]`).waitFor();
    }
    const box = page.locator('.cw-setsum');
    await box.waitFor();
    const txt = await box.innerText();
    assert.match(txt, /Gravecall/);
    assert.equal(await box.locator('.pips i.on').count(), 3, 'three pieces worn');
    assert.ok(await box.locator('.on').filter({ hasText: /harder/ }).count() >= 1, '2-piece line is on');
    assert.match(await box.locator('.nx em').innerText(), /Need 1 more/);
    assert.deepEqual(errors, []);
    if (process.argv[2]) await page.locator('.cw-equip-col').screenshot({ path: process.argv[2] });
    console.log('set summary ok:', txt.replace(/\n+/g, ' | '));
  } finally { await browser.close(); }
})().catch((e) => { console.error(e); process.exit(1); });
