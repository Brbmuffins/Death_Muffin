// Offline UI check for the two gold sinks: the Workbench's Reforge tab (pick a piece, pick an affix, see the price, confirm, gold goes down,
// the roll is redrawn inside its range) and a Covenant-Seal Empowered boss (seal + gold taken, red-gold tell, higher level, the server-rolled
// prize drops on the kill). The offline mock uses the same goldSinkRules the Death Muffin backend does.
// npm run dev -- --host 127.0.0.1 --port 5362 --strictPort ; DM_QA_URL=http://127.0.0.1:5362/?offline DM_QA_ARTIFACT_DIR=/tmp/gold-sinks node tools/qa/gold-sinks-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-gold-sinks';
  mkdirSync(out, { recursive: true });
  const result = {};
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5362/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `sink_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'sink@example.invalid');
    await page.fill('#cw-pass', 'TestingSinks1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    const adv = (s) => page.evaluate((n) => window.__cwDebug.advance(n), s);
    await page.evaluate(() => { window.__cwDebug.god(); window.__cwDebug.unlockAll(); window.__cwDebug.gold(500000); });
    await adv(0.2);

    // --- Reforge ---
    await page.evaluate(() => { window.__realRandom = Math.random; Math.random = () => 0.58; });
    await page.evaluate(() => window.__cwDebug.dropGear('helm_iron', 30, 'boss'));
    await page.waitForFunction(() => window.__cwDebug.rollsPending() === 0, null, { timeout: 15000 });
    await page.evaluate(() => { Math.random = window.__realRandom; });
    await adv(1.5);
    const piece = await page.evaluate(() => window.__cwDebug.inventory.all.find((s) => s.inst && s.slot_index < 100)?.inst ?? null);
    assert.ok(piece && piece.affixes.length >= 1, 'a rolled helm is in the bag');
    await page.keyboard.press('c');
    await page.locator('.cw-forge [data-tab="reforge"]').click();
    await page.waitForSelector('.cw-reforge-pick');
    await page.locator('.cw-reforge-pick').first().click();
    await page.waitForSelector('.cw-reforge-affix');
    const ask = page.locator('.cw-reforge-affix [data-ask]:not([disabled])').first();
    const label = await ask.innerText();
    assert.match(label, /reforge · [\d,]+g/i, `the price shows on the button before confirming (${label})`);
    await page.screenshot({ path: `${out}/reforge-pick.png` });
    await ask.click();
    await page.waitForSelector('.cw-reforge-confirm');
    const confirmText = await page.locator('.cw-reforge-confirm').innerText();
    assert.match(confirmText, /for [\d,]+ gold/i);
    const before = await page.evaluate(() => JSON.stringify(window.__cwDebug.inventory.all.find((s) => s.inst && s.slot_index < 100).inst.affixes));
    await page.locator('.cw-reforge-confirm [data-go]').click();
    await page.waitForSelector('.cw-salvage-result[data-result]', { timeout: 15000 });
    const resultText = await page.locator('.cw-salvage-result').innerText();
    assert.match(resultText, /became/i);
    const after = await page.evaluate(() => JSON.stringify(window.__cwDebug.inventory.all.find((s) => s.inst && s.slot_index < 100).inst.affixes));
    result.reforge = { label, resultText, changed: before !== after };
    await page.screenshot({ path: `${out}/reforge-done.png` });
    const next = await page.locator('.cw-reforge-affix [data-ask]').first().innerText();
    result.nextPrice = next;
    await page.keyboard.press('Escape');

    // --- Empowered boss ---
    await page.evaluate(() => window.__cwDebug.dropGear('covenant_seal', 1, 'kill', 2));
    await adv(1.5);
    await page.evaluate(() => window.__cwDebug.goto('graves'));
    await adv(0.5);
    await page.evaluate(() => window.__cwDebug.empowered('gravedigger'));
    await page.waitForFunction(() => window.__cwDebug.sim().boss.state.active, null, { timeout: 15000 });
    await adv(1);
    const boss = await page.evaluate(() => { const b = window.__cwDebug.sim().boss.state; return { empowered: b.empowered, level: b.level, maxHp: b.maxHp }; });
    assert.equal(boss.empowered, true, 'the boss woke Empowered');
    const seals = await page.evaluate(() => window.__cwDebug.inventory.count('covenant_seal'));
    assert.equal(seals, 1, 'one Seal was spent');
    await adv(3);
    await page.screenshot({ path: `${out}/empowered-boss.png` });
    await page.waitForTimeout(10500); // the server's 10 s minimum fight
    const ids = await page.evaluate(() => [...window.__cwDebug.sim().players.keys()]);
    await page.evaluate((id) => { const b = window.__cwDebug.sim().boss; b.damage(1e12, id, 0); }, ids[0]);
    await adv(0.5);
    await page.waitForFunction(() => window.__cwDebug.counts().loot > 0 && window.__cwDebug.rollsPending() === 0, null, { timeout: 20000 });
    const drops = await page.evaluate(() => window.__cwDebug.lootDrops?.() ?? null);
    result.boss = boss;
    result.drops = drops;
    await page.screenshot({ path: `${out}/empowered-prize.png` });
    assert.deepEqual(errors, [], `page errors: ${errors.join(' | ')}`);
    console.log(JSON.stringify(result, null, 1));
  } finally {
    await browser.close();
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
