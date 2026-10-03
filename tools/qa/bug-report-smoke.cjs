// Offline UI check for Settings → Report a bug: the button opens the form, Send stays disabled until the text is long enough,
// a report is sent (offline mock) and appears under "Your reports", Back restores Settings, and typing in the box never fires a
// game hotkey. Screenshots go to DM_QA_ARTIFACT_DIR.
//   npx vite --host 127.0.0.1 --port 5419 --strictPort
//   DM_QA_URL=http://127.0.0.1:5419/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_QA_ARTIFACT_DIR=/tmp/bugreport node tools/qa/bug-report-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { watchErrors, shot } = require('./lib/qa-common.cjs');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-bugreport';
  mkdirSync(out, { recursive: true });
  try {
    const page = await (await browser.newContext({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 })).newPage();
    const { errors } = watchErrors(page);
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5419/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `bug_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'bug@example.invalid');
    await page.fill('#cw-pass', 'TestingBugs1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });

    await page.locator('.hud-mi[data-open="settings"]').click();
    await page.locator('[data-bugreport]').click();
    await page.waitForSelector('.cw-bugreport textarea');
    const send = page.locator('.cw-bugreport [data-send]');
    assert.ok(await send.isDisabled(), 'Send is disabled while empty');
    // Hotkeys must not fire while typing: "i" would open the Reliquary, "k" the Codex.
    await page.locator('.cw-bugreport textarea').pressSequentially('ik short');
    assert.equal(await page.locator('.cw-bag-grid').count(), 0, 'typing i did not open the Reliquary');
    assert.ok(await send.isDisabled(), 'Send is disabled under 10 characters');
    await page.locator('.cw-bugreport textarea').fill('My thralls stopped following me after I took the Graves waystone.');
    await page.locator('.cw-bugreport [data-cat]').selectOption('combat');
    assert.ok(!(await send.isDisabled()), 'Send enables');
    await shot(page, `${out}/bugreport-form.png`);
    await send.click();
    await page.waitForFunction(() => document.querySelector('.cw-bugreport [data-result]')?.textContent?.includes('Thank you'));
    await page.waitForFunction(() => document.querySelectorAll('.cw-bugreport-list li b').length === 1);
    assert.match(await page.locator('.cw-bugreport-list').innerText(), /thralls stopped following/);
    assert.equal(await page.locator('.cw-bugreport textarea').inputValue(), '', 'the box clears after sending');
    await shot(page, `${out}/bugreport-sent.png`);
    await page.locator('.cw-bugreport [data-back]').click();
    await page.waitForSelector('.cw-settings [data-diff]');
    assert.equal(errors.length, 0, `no page errors: ${errors.join(' | ')}`);
    console.log('bug report smoke: ok');
  } finally {
    await browser.close();
  }
}
main().catch((err) => { console.error(err); process.exit(1); });
