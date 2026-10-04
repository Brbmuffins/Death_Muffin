// HUD UX smoke (offline): Report a bug button above the chat, the labelled belt, the click-to-fill picker, drag-from-bag, the splash.
//   npx vite --host 127.0.0.1 --port 5349 --strictPort
//   DM_QA_URL=http://127.0.0.1:5349/?offline DM_PLAYWRIGHT_MODULE=... DM_CHROMIUM_PATH=... DM_QA_ARTIFACT_DIR=/tmp/hud-ux node tools/qa/hud-ux-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { watchErrors, shot } = require('./lib/qa-common.cjs');

async function main() {
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-hud-ux';
  mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    for (const [w, h] of [[1600, 900], [1280, 720]]) {
      const page = await (await browser.newContext({ viewport: { width: w, height: h }, deviceScaleFactor: 1 })).newPage();
      const { errors } = watchErrors(page);
      await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
      // Hold the game module back so the page splash (index.html alone) can be captured before a scene dismisses it.
      let release;
      const held = new Promise((r) => (release = r));
      await page.route(/\/src\/main\.ts/, async (route) => { await held; await route.continue(); });
      await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5349/?offline', { waitUntil: 'commit' });
      await page.waitForSelector('.dm-splash-art.in', { timeout: 30000 });
      await page.waitForTimeout(500);
      await shot(page, `${out}/splash-${w}.png`);
      release();
      await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
      await page.fill('#cw-user', `hux_${Date.now() % 100000}`);
      await page.fill('#cw-email', 'hux@example.invalid');
      await page.fill('#cw-pass', 'TestingHux1');
      await page.locator('#cw-login-btn').click();
      await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
      await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
      await page.waitForTimeout(600);
      // Empty belt: dashed slots with "+ add", the Belt header, the bug button above the chat.
      assert.equal(await page.locator('.belt-head').textContent(), 'Belt');
      assert.match(await page.locator('[data-brew="elixir"] .sub').textContent(), /add/);
      assert.ok(await page.locator('.hud-bugbtn').isVisible(), 'bug button visible');
      const bb = await page.locator('.hud-bugbtn').boundingBox();
      const inp = await page.locator('.cw-chat input').boundingBox();
      assert.ok(bb.y + bb.height <= inp.y, 'bug button sits above the chat input');
      await shot(page, `${out}/hud-empty-${w}.png`);
      // Empty picker explains where to brew.
      await page.locator('[data-brew="elixir"]').click();
      await page.waitForSelector('.belt-picker');
      assert.match(await page.locator('.belt-picker').textContent(), /No elixirs/);
      await page.keyboard.press('Escape');
      assert.equal(await page.locator('.belt-picker').count(), 0, 'Escape closes the picker (and does not open Settings)');
      assert.equal(await page.locator('.cw-settings').count(), 0);
      // Give two elixirs and a tonic: the slot already shows one; the picker lists both and picks the other.
      await page.evaluate(async () => {
        const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
        scene.inventory.add({ item_id: 'elixir_moonlight', quantity: 3 });
        scene.inventory.add({ item_id: 'flask_damage', quantity: 2 });
        scene.inventory.add({ item_id: 'flask_speed', quantity: 2 });
        await scene.inventory.flush();
      });
      await page.waitForTimeout(500);
      await page.locator('[data-brew="elixir"]').click();
      await page.waitForSelector('.belt-picker .bp-row');
      const rows = await page.locator('.belt-picker .bp-row').count();
      assert.ok(rows >= 2, `picker lists every elixir in the bag (got ${rows})`);
      await shot(page, `${out}/belt-picker-${w}.png`);
      await page.locator('.belt-picker .bp-row:not(.cur)').first().click();
      await page.waitForSelector('.belt-picker', { state: 'detached' });
      // Drag from the bag onto the Tonic slot.
      await page.keyboard.press('i');
      const src = page.locator('.cw-bag-grid .cw-slot').filter({ has: page.locator('img[src*="flask_speed"]') }).first();
      assert.equal(await src.getAttribute('draggable'), 'true');
      await src.dragTo(page.locator('[data-brew="tonic"]'));
      await page.waitForTimeout(300);
      await page.keyboard.press('Escape');
      // Report a bug opens the form.
      await page.locator('.hud-bugbtn').click();
      await page.waitForSelector('.cw-bugreport textarea');
      await page.keyboard.press('Escape');
      assert.deepEqual(errors, []);
      await page.close();
    }
    console.log('ok');
  } finally { await browser.close(); }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
