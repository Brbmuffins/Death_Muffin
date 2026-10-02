// Brew engine smoke: drink an elixir + tonic from the belt keys, check the HUD tray, damage multiplier and replace text.
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const out = process.env.DM_QA_ARTIFACT_DIR || 'docs/screenshots/brew';
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: true, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5302/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', 'brew_review');
    await page.fill('#cw-email', 'brew@example.invalid');
    await page.fill('#cw-pass', 'TestingBrew1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    await page.evaluate(async () => {
      const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
      scene.inventory.add({ item_id: 'elixir_moonlight', quantity: 3 });
      scene.inventory.add({ item_id: 'flask_damage', quantity: 2 });
      scene.inventory.add({ item_id: 'flask_speed', quantity: 2 });
      await scene.inventory.flush();
    });
    const sp = () => page.evaluate(async () => (await import('/src/app/GameRuntime.ts')).getRuntime().view.abilities.sp);
    const base = await sp();
    await page.screenshot({ path: `${out}/01-belt-idle.png` });
    await page.keyboard.press('z');
    await page.keyboard.press('x');
    await page.waitForSelector('.brew-chip.on');
    const first = await sp();
    assert.ok(Math.abs(first / base - 1.15) < 0.001, `belt auto-fills Forge-tempered: +15% (got ${first / base})`);
    await page.waitForTimeout(700);
    await page.screenshot({ path: `${out}/02-tray-active.png` });
    const chips = await page.$$eval('.brew-chip', (els) => els.map((e) => e.textContent.replace(/\s+/g, ' ').trim()));
    assert.equal(chips.length, 3, "belt always shows Heal, Elixir, Tonic");
    // Inventory: tooltip line + belt button.
    await page.keyboard.press('i');
    await page.locator('.cw-bag-grid .cw-slot').filter({ has: page.locator('img[src*="elixir_moonlight"]') }).first().click();
    const detail = await page.locator('.cw-bag-detail').textContent();
    assert.match(detail, /Elixir · \+25% spell damage · 60s/);
    await page.locator('.cw-bag-detail [data-belt]').click();
    await page.screenshot({ path: `${out}/03-inventory-belt.png` });
    await page.keyboard.press('i');
    await page.keyboard.press('z'); // belted Moonlit replaces Forge-tempered
    await page.waitForTimeout(300);
    const second = await sp();
    assert.ok(Math.abs(second / base - 1.25) < 0.001, `Moonlit should replace Forge-tempered at +25% (got ${second / base})`);
    const tonic = await page.evaluate(async () => (await import('/src/app/GameRuntime.ts')).getRuntime().view.player.brews.tonic?.id);
    assert.equal(tonic, 'flask_speed', 'tonic survives an elixir swap');
    await page.screenshot({ path: `${out}/04-elixir-replaced.png` });
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ base, first, second, chips, errors }));
  } finally { await browser.close(); }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
