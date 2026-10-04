// Progressive HUD + merged panels + NEW cues (offline):
//   npx vite --host 127.0.0.1 --port 5363 --strictPort
//   DM_QA_URL=http://127.0.0.1:5363/?offline DM_PLAYWRIGHT_MODULE=... DM_CHROMIUM_PATH=... DM_QA_ARTIFACT_DIR=/tmp/hp node tools/qa/hud-progressive-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { watchErrors, shot } = require('./lib/qa-common.cjs');

const visible = (page, sel) => page.evaluate((s) => { const n = document.querySelector(s); return !!n && getComputedStyle(n).display !== 'none' && !n.hidden && n.getClientRects().length > 0; }, sel);

async function main() {
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-hud-progressive';
  mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const page = await (await browser.newContext({ viewport: { width: 1600, height: 900 }, deviceScaleFactor: 1 })).newPage();
    const { errors } = watchErrors(page);
    await page.addInitScript(() => { if (!localStorage.getItem('dm_settings_v1')) localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })); });
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5363/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `hp_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'hp@example.invalid');
    await page.fill('#cw-pass', 'TestingHp1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    await page.waitForTimeout(800);

    // Fresh character: no upgrade plate, no omen (the Acre is safe), no Spells/Acre/Atlas buttons, no shards counter.
    assert.equal(await visible(page, '.hud-upgrades'), false, 'upgrade plate hidden at level 1');
    assert.equal(await visible(page, '[data-omen]'), false, 'omen hidden in a safe area');
    assert.equal(await visible(page, '[data-grimbtn]'), false, 'swap spells hidden');
    assert.equal(await visible(page, '[data-open="grimoire"]'), false);
    assert.equal(await visible(page, '[data-open="atlas"]'), false);
    assert.equal(await visible(page, '[data-open="professions"]'), false);
    assert.equal(await visible(page, '[data-reveal="hud.shards"]'), false);
    assert.equal(await visible(page, '[data-open="inventory"]'), true);
    await shot(page, `${out}/1-fresh.png`);

    // The keys work before the buttons show: P opens the Acre ledger.
    await page.keyboard.press('p');
    await page.waitForSelector('.cw-tabwin-acre .cw-skills-panel');
    assert.deepEqual(await page.locator('.cw-tabwin-acre .cw-tabwin-tab:visible > span:first-child').allTextContents(), ['Skills', 'Garden', 'Laborers', 'Contracts']);
    await shot(page, `${out}/4-acre-skills.png`);
    await page.keyboard.press('u');
    await page.waitForSelector('.cw-tabwin-acre .cw-garden');
    assert.equal(await page.locator('.cw-tabwin-acre .cw-skills-panel').count(), 0, 'switching tabs closes the old panel');
    await page.keyboard.press('h');
    await page.waitForSelector('.cw-tabwin-acre .cw-labor');
    await page.keyboard.press('o');
    await page.waitForSelector('.cw-tabwin-acre .cw-contracts');
    await shot(page, `${out}/4b-acre-contracts.png`);
    await page.keyboard.press('o');
    await page.waitForSelector('.cw-tabwin-acre', { state: 'detached' });

    // Character window with Capes & Pets.
    await page.keyboard.press('j');
    await page.waitForSelector('.cw-tabwin-sheet .gs-sheet');
    await page.keyboard.press('n');
    await page.waitForSelector('.cw-tabwin-sheet .cw-cosmetics');
    assert.equal(await page.locator('.cw-tabwin-sheet .gs-sheet').count(), 0);
    await shot(page, `${out}/5-character-pets.png`);
    await page.keyboard.press('Escape');
    await page.waitForSelector('.cw-tabwin-sheet', { state: 'detached' });

    // Grimoire + Legion.
    await page.keyboard.press('l');
    await page.waitForSelector('.cw-tabwin-grim .cw-grimoire');
    await page.keyboard.press('y');
    await page.waitForSelector('.cw-tabwin-grim .lg-panel');
    await shot(page, `${out}/6-grimoire-legion.png`);
    await page.keyboard.press('Escape');
    await page.waitForSelector('.cw-tabwin-grim', { state: 'detached' });
    // Skills got XP-free opening: still hidden button, so no skill reveal yet.
    assert.equal(await visible(page, '[data-open="professions"]'), false);

    // Hunting ground: the omen shows (with NEW), the plate still waits for gold.
    await page.evaluate(() => window.__cwDebug.goto('graves'));
    await page.evaluate(() => window.__cwDebug.advance(1.5));
    await page.waitForTimeout(400);
    assert.equal(await visible(page, '[data-omen]'), true, 'omen shows in the graves');
    assert.equal(await visible(page, '.hud-upgrades'), false, 'plate waits for gold');
    await shot(page, `${out}/3-hunting-omen.png`);
    // First gold in a hunting ground reveals the plate with a NEW cue and a single toast.
    await page.evaluate(() => window.__cwDebug.gold(25));
    await page.evaluate(() => window.__cwDebug.advance(0.5));
    await page.waitForSelector('.hud-upgrades.dm-glow', { timeout: 10000 });
    assert.equal(await visible(page, '[data-new="hud.upgrades"]'), true, 'NEW pip on the plate');
    await page.waitForSelector('.hud-toast.new-cue');
    assert.equal(await page.locator('.hud-toast.new-cue').count(), 1, 'one cue toast at a time');
    await shot(page, `${out}/2-first-gold-new.png`);
    // Using it (hover) clears the cue; it stays revealed.
    await page.locator('.hud-upgrades').hover();
    await page.waitForFunction(() => !document.querySelector('.hud-upgrades.dm-glow'));
    // Back in a safe area the omen goes again but the plate stays.
    await page.evaluate(() => window.__cwDebug.goto('chapterhouse'));
    await page.evaluate(() => window.__cwDebug.advance(1.5));
    await page.waitForTimeout(300);
    assert.equal(await visible(page, '[data-omen]'), false, 'omen hides in the Chapterhouse');
    assert.equal(await visible(page, '.hud-upgrades'), true, 'plate stays once revealed');

    // Reveals persist across a reload.
    await page.evaluate(() => window.__cwDebug.inventory.flush());
    await page.reload();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    await page.waitForTimeout(600);
    assert.equal(await visible(page, '.hud-upgrades'), true, 'plate still shown after reload');
    assert.equal(await page.locator('.hud-upgrades.dm-glow').count(), 0);

    // A veteran (level 6, no stored HUD state) keeps their HUD and is told where the panels went.
    await page.evaluate(() => { window.__cwDebug.xp(4000); });
    await page.evaluate(() => window.__cwDebug.advance(1));
    await page.evaluate(() => { for (const k of Object.keys(localStorage)) if (k.includes('dm_hud_reveal_v1_')) localStorage.removeItem(k); });
    await page.evaluate(() => window.__cwDebug.inventory.flush());
    await page.reload();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    await page.waitForTimeout(800);
    const level = await page.evaluate(() => Number(document.querySelector('[data-level]').textContent));
    assert.ok(level >= 3, `veteran level ${level}`);
    assert.equal(await visible(page, '.hud-upgrades'), true, 'veteran keeps the plate');
    assert.equal(await page.locator('.hud-upgrades.dm-glow').count(), 0, 'veteran reveal is silent');
    assert.equal(await visible(page, '[data-open="professions"]'), true, 'veteran has the Acre button');
    assert.equal(await page.locator('[data-open="professions"] .dm-pip:visible').count(), 1, 'Acre button carries NEW for existing players');
    await page.waitForSelector('.hud-toast.new-cue', { timeout: 60000 });
    await shot(page, `${out}/7-veteran-cue.png`);
    // Opening the Acre ledger clears the menu pip; the Garden tab keeps its own until visited.
    await page.locator('[data-open="professions"]').click();
    await page.waitForSelector('.cw-tabwin-acre');
    assert.equal(await page.locator('[data-open="professions"] .dm-pip:visible').count(), 0);
    assert.equal(await page.locator('.cw-tabwin-tab [data-new="tab.acre.garden"]:visible').count(), 1);
    await page.locator('.cw-tabwin-tab[data-tab="garden"]').click();
    assert.equal(await page.locator('.cw-tabwin-tab [data-new="tab.acre.garden"]:visible').count(), 0);
    assert.deepEqual(errors, []);
    console.log('ok');
  } finally { await browser.close(); }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
