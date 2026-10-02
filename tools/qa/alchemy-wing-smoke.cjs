// Alchemist's Wing smoke: walk from the Chapterhouse into the Wing, open the cauldron, brew a Grave-Dust Tonic, check the
// Reagent Shelf, and screenshot wide / close / panel views at 1280x800. Run against the offline dev server:
//   npm run dev -- --host 127.0.0.1 --port 5340 --strictPort ; DM_QA_URL=http://127.0.0.1:5340/?offline node tools/qa/alchemy-wing-smoke.cjs
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const out = process.env.DM_QA_ARTIFACT_DIR || 'docs/screenshots/alchemist-wing/room';
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5340/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', 'wing_review');
    await page.fill('#cw-email', 'wing@example.invalid');
    await page.fill('#cw-pass', 'TestingWing1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    const view = () => import('/src/app/GameRuntime.ts').then((m) => m.getRuntime().view);
    const settle = async (s = 2) => { await page.waitForTimeout(1500); await page.evaluate((t) => window.__cwDebug.advance(t), s); };
    const stats = () => page.evaluate(async () => { const r = (await import('/src/app/GameRuntime.ts')).getRuntime(); const i = r.renderer.info.render; return { calls: i.calls, tris: i.triangles }; });
    await page.evaluate(async () => {
      const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
      scene.inventory.add({ item_id: 'reagent_grave_dust', quantity: 9 });
      scene.inventory.add({ item_id: 'herb_mourning_moss', quantity: 3 });
      await scene.inventory.flush();
    });

    // Chapterhouse baseline for the perf comparison, then walk east through the door.
    await page.evaluate(() => { window.__cwDebug.teleport(0, 24); window.__cwDebug.advance(1); });
    await settle();
    const chapter = await stats();
    await page.evaluate(() => { window.__cwDebug.teleport(8, 20); window.__cwDebug.advance(1); });
    await settle();
    await page.screenshot({ path: `${out}/01-chapterhouse-east-door.png` });
    // Real walking through the east door: route to a point inside the Wing and step the sim until we get there.
    await page.evaluate(async () => { (await import('/src/app/GameRuntime.ts')).getRuntime().view.player.moveTo(27, 20); });
    let area = '';
    for (let i = 0; i < 60 && area !== 'alchemist_wing'; i++) {
      await page.evaluate(() => window.__cwDebug.advance(0.5));
      area = await page.evaluate(async () => (await import('/src/app/GameRuntime.ts')).getRuntime().view.player.area);
    }
    assert.equal(area, 'alchemist_wing', 'player is inside the Wing');
    await page.evaluate(() => { window.__cwDebug.teleport(33, 24.5); window.__cwDebug.advance(2); });
    await settle();
    await page.screenshot({ path: `${out}/02-wing-wide.png` });
    const wing = await stats();
    // Close view of the cauldron.
    await page.evaluate(() => { window.__cwDebug.teleport(33, 22); window.__cwDebug.zoom(0.7); window.__cwDebug.advance(2); });
    await settle();
    await page.screenshot({ path: `${out}/03-cauldron-close.png` });
    await page.evaluate(() => window.__cwDebug.zoom(1));

    // Open the cauldron (same path as a click on it) and brew.
    await page.evaluate(() => window.__cwDebug.station?.('cauldron'));
    await page.waitForSelector('.cw-recipe', { timeout: 10000 });
    const title = await page.locator('.cw-panel-float .cw-title').first().textContent();
    assert.match(title, /Great Cauldron/);
    const hint = await page.locator('[data-wing-hint]').textContent();
    assert.match(hint, /Brew of the day/);
    await page.screenshot({ path: `${out}/04-cauldron-panel.png` });
    const before = await page.evaluate(async () => (await import('/src/app/GameRuntime.ts')).getRuntime().view.inventory.count('tonic_grave_dust'));
    await page.locator('.cw-recipe', { hasText: 'Grave-Dust Tonic' }).locator('[data-craft]').click();
    for (let i = 0; i < 40; i++) {
      const n = await page.evaluate(async () => (await import('/src/app/GameRuntime.ts')).getRuntime().view.inventory.count('tonic_grave_dust'));
      if (n > before) break;
      await page.waitForTimeout(250);
    }
    const after = await page.evaluate(async () => (await import('/src/app/GameRuntime.ts')).getRuntime().view.inventory.count('tonic_grave_dust'));
    assert.ok(after >= before + 2, `brewed Grave-Dust Tonic x2 (${before} -> ${after})`);
    await page.screenshot({ path: `${out}/05-after-brew.png` });
    await page.locator('.cw-panel-float [data-close]').first().click();

    // Reagent shelf.
    await page.evaluate(() => window.__cwDebug.station?.('reagents'));
    await page.waitForSelector('.cw-shelf-item');
    const found = await page.$$eval('.cw-shelf-item.found .nm', (els) => els.map((e) => e.textContent.trim()));
    assert.ok(found.includes('Grave Dust') && found.includes('Mourning Moss'), `shelf shows found reagents: ${found}`);
    const unknown = await page.$$eval('.cw-shelf-item:not(.found) .nm', (els) => els.length);
    assert.ok(unknown > 0, 'unfound reagents stay hidden');
    await page.screenshot({ path: `${out}/06-reagent-shelf.png` });
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ area, chapter, wing, before, after, found, errors }));
  } finally { await browser.close(); }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
