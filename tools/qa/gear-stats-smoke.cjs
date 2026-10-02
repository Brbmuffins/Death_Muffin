// Offline UI check for "Gear you can read": plain-language stat lines, the equip comparison and the Character sheet (J).
//   npm run dev -- --host 127.0.0.1 --port 5322 --strictPort
//   DM_QA_URL=http://127.0.0.1:5322/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_QA_ARTIFACT_DIR=/tmp/gear-stats node tools/qa/gear-stats-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

/** Counsel queues behind earlier tips; click each one away until the wanted one shows. */
async function dismissUntilTip(page, title) {
  for (let i = 0; i < 12; i++) {
    if (await page.locator('.cw-tip', { hasText: title }).count()) return;
    const tip = page.locator('.cw-tip').first();
    if (await tip.count()) await tip.click({ force: true }).catch(() => {});
    await page.waitForTimeout(900);
  }
  assert.fail(`counsel "${title}" never appeared`);
}

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-gear-stats';
  mkdirSync(out, { recursive: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    // Tips stay ON so the first-equip and first-sheet counsel can be asserted.
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: true, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5322/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `gear_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'gear@example.invalid');
    await page.fill('#cw-pass', 'TestingGearStats1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });

    await page.evaluate(async () => {
      const d = window.__cwDebug;
      for (const id of ['helm_copper', 'chest_iron', 'helm_iron', 'staff_gold', 'scythe_bone', 'grimoire_gold', 'ring_copper']) d.inventory.add({ item_id: id, quantity: 1 });
      await d.inventory.flush();
      d.advance(1);
    });
    const bagOf = (id) => page.evaluate((i) => window.__cwDebug.inventory.all.find((s) => s.item_id === i)?.slot_index, id);
    const cell = (idx) => page.locator('.cw-bag-grid .cw-slot').nth(idx);

    // Wear the copper helm and iron chest through the real UI (double-click), then open the Reliquary.
    await page.keyboard.press('i');
    await page.waitForSelector('.cw-bag-grid');
    for (const id of ['helm_copper', 'chest_iron', 'grimoire_gold']) await cell(await bagOf(id)).dblclick();
    await page.waitForFunction(() => window.__cwDebug.inventory.all.filter((s) => s.equipped).length === 3);
    await dismissUntilTip(page, 'Gear you can read');

    // Select a better helm: stat lines speak in effects and the comparison is shown.
    await cell(await bagOf('helm_iron')).click();
    const detail = page.locator('[data-detail]');
    await detail.locator('.gs-cmp').waitFor();
    const text = await detail.innerText();
    assert.match(text, /\+5 VIT/);
    assert.match(text, /Upgrade for your Ossuary: \+\d+% \(more /, 'verdict line leads the detail');
    assert.ok(await cell(await bagOf('helm_iron')).locator('.gs-badge.upgrade').count(), 'green arrow on the better helm');
    assert.ok(await cell(await bagOf('ring_copper')).locator('.gs-badge.upgrade').count(), 'empty ring slot is always an upgrade');
    assert.match(text, /health/);
    assert.match(text, /Instead of copper_helm|Instead of Copper Helm/);
    assert.ok(await detail.locator('.gs-cmp .r.up').count(), 'a gain is marked green');
    await page.screenshot({ path: `${out}/reliquary-compare-helm.png` });

    // A two-handed staff displaces the worn grimoire too, and the left-click change is spelled out.
    await cell(await bagOf('scythe_bone')).click();
    await detail.locator('.gs-cmp').waitFor();
    const two = await detail.innerText();
    assert.match(two, /Worse than your|Upgrade for your|About the same as your/, 'two-hander verdict');
    assert.match(two, /Left click becomes a reaping arc/);
    assert.match(two, /Rites recover 10% sooner/, 'losing the grimoire passive is named');
    assert.match(two, /and/, 'both displaced pieces are named');
    assert.ok(await detail.locator('.gs-cmp .down').count(), 'a loss is marked red');
    await page.mouse.move(5, 5);
    await page.waitForTimeout(200);
    await page.screenshot({ path: `${out}/reliquary-compare-twohanded.png` });

    // Hover tooltip shows the compact comparison.
    await cell(await bagOf('staff_gold')).hover();
    await page.locator('.cw-tooltip .gs-cmp-mini').waitFor();
    await page.screenshot({ path: `${out}/reliquary-tooltip.png` });

    // Character sheet from the Reliquary button, then the J key.
    await page.locator('.cw-equip-sheet').click();
    await page.locator('.gs-sheet').waitFor();
    assert.equal(await page.locator('.cw-panel-float.wide').count(), 0, 'sheet replaces the reliquary');
    const sheet = await page.locator('.gs-sheet').innerText();
    assert.match(sheet, /what you're looking for/i, 'priority block');
    assert.match(sheet, /VIT > INT > STR > AGI/, 'Ossuary priority');
    assert.match(sheet, /weakest slots/i);
    assert.match(sheet, /empty\. Any .+ is an upgrade/);
    for (const w of ['VIT: health', 'Health', 'Spell power', 'Max essence', 'Essence/s', 'Move speed', 'Thrall health', 'Thrall damage', 'Damage upgrade']) assert.ok(sheet.includes(w), w);
    const shown = await page.evaluate(() => window.__cwDebug.player.stats.maxHp);
    assert.ok(sheet.includes(String(shown)), 'sheet health equals the player stat');
    await page.screenshot({ path: `${out}/character-sheet.png` });
    await page.locator('[data-line="spellPower"]').click();
    await page.screenshot({ path: `${out}/character-sheet-breakdown.png` });
    await dismissUntilTip(page, 'Your Character sheet');
    await page.keyboard.press('j');
    assert.equal(await page.locator('.gs-sheet').count(), 0, 'J closes the sheet');
    await page.keyboard.press('j');
    await page.locator('.gs-sheet').waitFor();

    // Codex Stats tab.
    await page.keyboard.press('Escape');
    await page.keyboard.press('k');
    await page.locator('[data-tab="stats"]').click();
    assert.match(await page.locator('[role="dialog"][aria-label="Codex"]').innerText(), /\+8 health/);
    await page.screenshot({ path: `${out}/codex-stats.png` });

    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ effectLines: true, comparison: true, twoHanded: true, sheet: true, codex: true, errors }));
  } finally { await browser.close(); }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
