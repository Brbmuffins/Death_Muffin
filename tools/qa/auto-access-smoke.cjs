/** Offline browser check for account-specific difficulty and Auto Combat access. */
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  try {
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ difficulty: 'easy', autoCombat: true, tips: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5312/?offline');

    const register = async (username) => {
      await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
      await page.fill('#cw-user', username);
      await page.fill('#cw-email', `${username}@example.invalid`);
      await page.fill('#cw-pass', 'TestingAutoAccess');
      await page.locator('#cw-login-btn').click();
      await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
      await page.locator('.hud').waitFor({ timeout: 45000 });
      await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 45000 });
    };
    const openSettings = () => page.locator('[data-open="settings"]').click();
    const state = () => page.evaluate(async () => {
      const { settings } = await import('/src/app/settings.ts');
      return { difficulty: settings.difficulty, autoCombat: settings.autoCombat };
    });

    await register('ordinary_player');
    assert.deepEqual(await state(), { difficulty: 'medium', autoCombat: false });
    await page.locator('[data-auto]').waitFor({ state: 'hidden' });
    await openSettings();
    assert.equal(await page.locator('[data-auto]:visible').count(), 0);
    assert.equal(await page.locator('[data-autogather]').count(), 1);
    await page.locator('[data-diff]').selectOption('easy');
    assert.deepEqual(await state(), { difficulty: 'easy', autoCombat: false });
    await page.keyboard.press('Escape');
    await page.keyboard.press('g');
    assert.equal((await state()).autoCombat, false);
    await openSettings();
    await page.locator('[data-leave]').click();

    await register('brbmuffins');
    assert.deepEqual(await state(), { difficulty: 'medium', autoCombat: false });
    await openSettings();
    assert.equal(await page.locator('[data-auto]:visible').count(), 2);
    assert.equal(await page.locator('[data-autogather]').count(), 1);
    await page.locator('[data-diff]').selectOption('easy');
    assert.deepEqual(await state(), { difficulty: 'easy', autoCombat: true });
    console.log(JSON.stringify({ ordinary: 'Medium, manual, Auto hidden', brbmuffins: 'Medium initially; Auto enabled on Easy', afkProfessions: 'unchanged', errors }));
    assert.deepEqual(errors, []);
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
