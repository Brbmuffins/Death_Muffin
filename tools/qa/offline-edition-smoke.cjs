/** Production offline PWA: local profile, full download, disconnected reload. */
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: 'allow' });
  const page = await context.newPage();
  const errors = [];
  const api = [];
  page.on('pageerror', (error) => errors.push(error.message));
  page.on('console', (message) => { if (message.type() === 'error') errors.push(message.text()); });
  page.on('response', (response) => { if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`); });
  page.on('request', (request) => { if (/\/death-muffin\/api\//.test(request.url())) api.push(request.url()); });
  const url = process.env.DM_OFFLINE_URL || 'http://127.0.0.1:5313/death-muffin/offline/';
  try {
    await page.goto(url);
    console.log(JSON.stringify({ url: page.url(), title: await page.title(), body: (await page.locator('body').innerText()).slice(0, 300) }));
    await page.getByRole('button', { name: 'Create a local player' }).waitFor({ timeout: 15000 }).catch((error) => {
      throw new Error(`Login UI did not render: ${errors.join(' | ') || error.message}`);
    });
    await page.getByRole('button', { name: 'Create a local player' }).click();
    assert.equal(await page.locator('#cw-pass').count(), 0, 'local profiles do not imply password security');
    await page.fill('#cw-user', 'offline_probe');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.locator('.hud').waitFor({ timeout: 45000 });
    await page.locator('[data-open="settings"]').click();
    assert.equal(await page.locator('[data-diff]').inputValue(), 'medium');
    assert.equal(await page.locator('[data-auto]:visible').count(), 0, 'local profiles cannot impersonate Brbmuffins');
    assert.equal(await page.locator('[data-autogather]').count(), 1);
    await page.keyboard.press('Escape');
    await page.locator('[data-offline-download]').click();
    await page.getByText('Ready to play without a network.', { exact: false }).waitFor({ timeout: 180000 });
    await context.setOffline(true);
    await page.reload({ waitUntil: 'domcontentloaded' });
    await page.locator('.hud').waitFor({ timeout: 45000 });
    assert.deepEqual(api, [], 'offline edition made no online API request');
    assert.deepEqual(errors, [], 'no page errors');
    await context.setOffline(false);
    let upload = null;
    await page.route('**/death-muffin/api/login', (route) => route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ token: 'test-online-token' }) }));
    await page.route('**/death-muffin/api/api/offline/sync-stats', async (route) => {
      upload = route.request().postDataJSON();
      assert.equal(route.request().headers().authorization, 'Bearer test-online-token');
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ level: upload.level, experience: upload.experience, improved: true }) });
    });
    await page.locator('.dm-offline-sync summary').click();
    await page.locator('.dm-offline-sync [name="username"]').fill('online_probe');
    await page.locator('.dm-offline-sync [name="password"]').fill('private-test-password');
    await page.getByRole('button', { name: 'Upload stats' }).click();
    await page.getByText('Uploaded. Your online character is now level', { exact: false }).waitFor();
    assert.equal(upload.level, 1);
    assert.equal(upload.experience, 0);
    assert.equal(await page.locator('.dm-offline-sync [name="password"]').inputValue(), '');
    assert.deepEqual(errors, [], 'no page errors during upload');
    console.log(JSON.stringify({ offlineReload: true, localCharacter: true, mediumDefault: true, autoCombatHidden: true, autoGatherAvailable: true, statsUpload: upload, errors }));
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
