// Screenshots the bag (I) and the spell bar with real item/ability icons, for before/after image-format checks.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5396/?offline' DM_QA_ARTIFACT_DIR=/tmp/icons node tools/qa/icons-shot.cjs
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/icons-shot';
  mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(90000);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5396/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `ic_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('ic@example.invalid');
  await page.fill('#cw-pass', 'TestingIcons1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(async () => {
    const d = window.__cwDebug; d.god(true); d.unlockAll();
    for (const id of ['helm_copper', 'chest_iron', 'helm_iron', 'staff_gold', 'scythe_bone', 'grimoire_gold', 'ring_copper', 'staff_bone', 'wand_bone']) d.inventory.add({ item_id: id, quantity: 1 });
    await d.inventory.flush(); d.advance(1);
  });
  await page.waitForTimeout(1500);
  await page.screenshot({ path: `${out}/spellbar.png` });
  await page.keyboard.press('i');
  await page.waitForSelector('.cw-bag-grid');
  await page.waitForTimeout(1500);
  await page.screenshot({ path: `${out}/bag.png` });
  const broken = await page.evaluate(() => [...document.images].filter((i) => i.complete && !i.naturalWidth).map((i) => i.src));
  console.log('broken images:', JSON.stringify(broken), 'images:', document => 0);
  await browser.close();
})();
