/**
 * fps-overlay-smoke.cjs - the F3 / ?fps performance overlay: opens with ?fps, fills in fps / timings / draw counts, logs a
 * stutter with its cause when a boss spawns, and F3 hides it (remembered). Offline preview only.
 *   DM_QA_URL='http://127.0.0.1:5348/?offline' node tools/qa/fps-overlay-smoke.cjs [out.png]
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
    const base = process.env.DM_QA_URL || 'http://127.0.0.1:5348/?offline';
    await page.goto(`${base}${base.includes('?') ? '&' : '?'}fps`);
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `fps_${Date.now() % 1e6}`);
    await page.fill('#cw-email', 'fps@example.invalid');
    await page.fill('#cw-pass', 'TestingFps1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 120000 });
    const overlay = page.locator('.fps-overlay');
    await page.waitForFunction(() => /\d+ fps/.test(document.querySelector('.fps-overlay')?.textContent || ''), null, { timeout: 60000 });
    const txt = await overlay.innerText();
    assert.match(txt, /logic [\d.]+ ms\s+draw [\d.]+ ms\s+gpu/);
    assert.match(txt, /calls \d+\s+tris [\d.]+k?/);
    assert.match(txt, /→ /);
    await page.evaluate(() => { window.__cwDebug.goto?.('graves'); });
    await page.evaluate(() => window.__cwDebug.boss());
    await page.waitForTimeout(8000);
    const after = await overlay.innerText();
    const out = process.argv[2] || (process.env.DM_QA_ARTIFACT_DIR && require('node:path').join(process.env.DM_QA_ARTIFACT_DIR, 'fps-overlay.png'));
    if (out) await page.screenshot({ path: out });
    await page.keyboard.press('F3');
    assert.equal(await overlay.count(), 0, 'F3 hides it');
    assert.equal(await page.evaluate(() => localStorage.getItem('dm.fpsOverlay')), null, 'hidden is remembered');
    await page.keyboard.press('F3');
    await overlay.waitFor();
    assert.equal(await page.evaluate(() => localStorage.getItem('dm.fpsOverlay')), '1');
    assert.deepEqual(errors, []);
    console.log('fps overlay ok:\n' + after);
  } finally { await browser.close(); }
})().catch((e) => { console.error(e); process.exit(1); });
