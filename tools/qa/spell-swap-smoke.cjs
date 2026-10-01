// Offline UI check for the five-slot Grimoire and the visible hotbar swap controls.
// DM_QA_URL=http://127.0.0.1:5311/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright node tools/qa/spell-swap-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-spell-swap';
  mkdirSync(out, { recursive: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5311/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `swap_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'swap@example.invalid');
    await page.fill('#cw-pass', 'TestingSpellSwap1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    assert.equal(await page.locator('[data-swap]').count(), 5, 'five visible swap controls');
    assert.deepEqual(await page.evaluate(() => window.__cwDebug.loadout()),
      ['marrow_spear', 'exhume', 'miasma', 'black_litany', 'corpse_explosion']);

    await page.locator('[data-swap="4"]').click();
    assert.equal(await page.locator('.cw-grim-socket.on').getAttribute('data-socket'), '4');
    assert.equal(await page.locator('.cw-grim-socket').count(), 6, 'LMB and five rite sockets');
    await page.screenshot({ path: `${out}/grimoire.png`, timeout: 60000 });
    assert.ok((await page.locator('[data-pick="grave_step"]').count()) === 0, 'locked rite cannot be placed');

    await page.keyboard.press('Escape');
    const levelAfterXp = await page.evaluate(() => { const d = window.__cwDebug; d.xp(1500); return d.player.stats.level; });
    assert.ok(levelAfterXp >= 5, 'new rite level reached');
    await page.locator('[data-swap="4"]').click();
    assert.equal(await page.locator('.cw-grim-socket.on').getAttribute('data-socket'), '4', 'explicit swap keeps its selected slot');
    await page.locator('[data-pick="grave_step"]').click();
    assert.equal((await page.evaluate(() => window.__cwDebug.loadout()))[4], 'grave_step');
    await page.keyboard.press('Escape');
    assert.match(await page.locator('[data-slot="5"]').getAttribute('aria-label'), /Grave Step/);

    await page.locator('[data-swap="0"]').click();
    await page.locator('[data-pick="grave_step"]').click();
    assert.deepEqual(await page.evaluate(() => window.__cwDebug.loadout()),
      ['grave_step', 'exhume', 'miasma', 'black_litany', 'marrow_spear'], 'equipped rite swaps slots');
    await page.keyboard.press('Escape');
    await page.reload();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    assert.deepEqual(await page.evaluate(() => window.__cwDebug.loadout()),
      ['grave_step', 'exhume', 'miasma', 'black_litany', 'marrow_spear'], 'loadout persists');
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ fiveSwapControls: true, lockedRiteProtected: true, swapAndPersistence: true, errors }));
  } finally { await browser.close(); }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
