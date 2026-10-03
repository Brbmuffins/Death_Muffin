// Offline UI check for the Gear Atlas (the . key / Menu): opens from key and button, every view renders rows, upgrade arrows and fit
// badges show, detail pane lists sources and recipes, search works, nothing errors; screenshots go to DM_QA_ARTIFACT_DIR.
//   npx vite --host 127.0.0.1 --port 5418 --strictPort
//   DM_QA_URL=http://127.0.0.1:5418/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_QA_ARTIFACT_DIR=/tmp/atlas node tools/qa/atlas-smoke.cjs
// DM_QA_W / DM_QA_H set the viewport (default 1280x800); DM_QA_TOUCH=1 emulates a phone (touch, mobile UA); DM_QA_DISC picks the discipline.
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { watchErrors } = require('./lib/qa-common.cjs');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-atlas';
  mkdirSync(out, { recursive: true });
  const touch = process.env.DM_QA_TOUCH === '1';
  const tag = process.env.DM_QA_TAG || `${process.env.DM_QA_W || 1280}x${process.env.DM_QA_H || 800}${touch ? '-touch' : ''}`;
  const disc = process.env.DM_QA_DISC || 'Gravecaller';
  try {
    const ctx = await browser.newContext({ viewport: { width: Number(process.env.DM_QA_W || 1280), height: Number(process.env.DM_QA_H || 800) }, hasTouch: touch, isMobile: touch, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    const { errors } = watchErrors(page);
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5418/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `atlas_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'atlas@example.invalid');
    await page.fill('#cw-pass', 'TestingAtlas1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: disc }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    await page.evaluate(async () => {
      const d = window.__cwDebug;
      for (const id of ['helm_copper', 'plate_copper', 'ring_copper', 'staff_bone', 'set_gravecaller_head']) d.inventory.add({ item_id: id, quantity: 1 });
      await d.inventory.flush();
      d.advance(1);
    });
    // Wear the copper helm and the bone staff so arrows have something to beat.
    await page.keyboard.press('i');
    await page.waitForSelector('.cw-bag-grid');
    const idx = (id) => page.evaluate((i) => window.__cwDebug.inventory.all.find((s) => s.item_id === i)?.slot_index, id);
    for (const id of ['helm_copper', 'staff_bone']) await page.locator('.cw-bag-grid .cw-slot').nth(await idx(id)).dblclick();
    await page.waitForFunction(() => window.__cwDebug.inventory.all.filter((s) => s.equipped).length >= 2);
    await page.keyboard.press('Escape');
    await page.waitForTimeout(200);

    // Open from the key (desktop) or the Menu tile (phone). Hot path: the chunk is fetched on first open.
    if (touch) {
      await page.locator('.hud-menubtn').click();
      await page.locator('.hud-menusheet [data-open="atlas"]').click();
    } else {
      assert.ok(await page.locator('.hud-mi[data-open="atlas"]').count(), 'Atlas button in the menu row');
      await page.keyboard.press('.');
    }
    await page.waitForSelector('.cw-atlas .at-row', { timeout: 30000 });
    const rowCount = async () => page.locator('.cw-atlas .at-row').count();
    assert.ok(await rowCount() > 3, 'Best for me lists upgrades');
    assert.ok(await page.locator('.cw-atlas .at-arrow.up').count(), 'upgrade arrows show');
    await page.waitForTimeout(400);
    await page.screenshot({ path: `${out}/atlas-best-${tag}.png` });

    // By slot (chest): fit badges and arrows, best first.
    await page.locator('.cw-atlas [data-view="slot"]').click();
    await page.locator('.cw-atlas [data-slot="chest"]').click();
    assert.ok(await rowCount() >= 20, 'chest slot has many rows');
    assert.ok(await page.locator('.cw-atlas .at-fit').count(), 'fit badges show');
    await page.locator('.cw-atlas .at-row').first().click();
    await page.waitForSelector('.cw-atlas .at-detail .at-dname');
    const detail = await page.locator('.cw-atlas .at-detail').innerText();
    assert.match(detail, /Where it drops/);
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${out}/atlas-slot-detail-${tag}.png` });

    // Craftable item: recipe tree one level deep, ingredients link on.
    await page.locator('.cw-atlas [data-view="slot"]').click();
    await page.locator('.cw-atlas [data-slot="main_hand"]').click();
    await page.locator('.cw-atlas .at-row', { hasText: 'Reliquary Staff' }).first().click();
    await page.waitForSelector('.cw-atlas .at-recipe');
    assert.match(await page.locator('.cw-atlas .at-detail').innerText(), /How to make it/);
    await page.locator('.cw-atlas .at-recipe button[data-go]').first().click();
    assert.ok(await page.locator('.cw-atlas .at-back').count(), 'a back control exists');

    // By area & boss.
    await page.locator('.cw-atlas [data-view="where"]').click();
    await page.selectOption('.cw-atlas [data-where]', 'abbess');
    assert.ok(await rowCount() > 10, 'boss lists its spoils');
    assert.match(await page.locator('.cw-atlas .at-list').innerText(), /Abbess Ichor/);
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${out}/atlas-where-${tag}.png` });

    // By set.
    await page.locator('.cw-atlas [data-view="set"]').click();
    assert.ok(await page.locator('.cw-atlas .at-set .at-bonus').count() >= 3, 'set bonuses show');
    await page.screenshot({ path: `${out}/atlas-set-${tag}.png` });

    // Materials.
    await page.locator('.cw-atlas [data-view="mats"]').click();
    assert.ok(await rowCount() > 20, 'materials list');

    // Search.
    await page.fill('.cw-atlas [data-q]', 'moon');
    assert.ok(await rowCount() > 3, 'search finds Moon items');
    await page.fill('.cw-atlas [data-q]', 'zzzzzz');
    assert.match(await page.locator('.cw-atlas .at-list').innerText(), /Nothing by that name/);
    await page.fill('.cw-atlas [data-q]', '');

    // Close: nothing of it remains in the DOM (no ticking panel when shut).
    await page.locator('.cw-atlas [data-close]').click();
    assert.equal(await page.locator('.cw-atlas').count(), 0);
    assert.deepEqual(errors, [], `page errors: ${errors.join(' | ')}`);
    console.log(`atlas smoke ok (${tag})`);
  } finally {
    await browser.close();
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
