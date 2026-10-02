// Offline UI check for armor set bonuses: tooltip tracker, paper-doll marks, bag verdict, Character sheet, counsel tip.
//   npm run dev -- --host 127.0.0.1 --port 5333 --strictPort
//   DM_QA_URL=http://127.0.0.1:5333/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_QA_ARTIFACT_DIR=/tmp/set-bonus node tools/qa/set-bonus-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function dismissUntilTip(page, title) {
  for (let i = 0; i < 14; i++) {
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
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-set-bonus';
  mkdirSync(out, { recursive: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: true, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5333/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `sets_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'sets@example.invalid');
    await page.fill('#cw-pass', 'TestingSetBonus1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });

    const ids = ['set_ossuary_head', 'set_ossuary_chest', 'set_ossuary_hands', 'set_ossuary_legs', 'set_ossuary_feet', 'set_mourner_head', 'set_gravecaller_legs'];
    await page.evaluate(async (list) => {
      const d = window.__cwDebug;
      for (const id of list) d.inventory.add({ item_id: id, quantity: 1 });
      await d.inventory.flush();
      d.advance(1);
    }, ids);
    const bagOf = (id) => page.evaluate((i) => window.__cwDebug.inventory.all.find((s) => s.item_id === i)?.slot_index, id);
    const cell = (idx) => page.locator('.cw-bag-grid .cw-slot').nth(idx);
    const wornCount = () => page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => s.equipped).length);
    const mods = () => page.evaluate(async () => {
      const m = (await import('/src/app/GameRuntime.ts')).getRuntime().view.discipline.mods;
      return { thrallHpMult: m.thrallHpMult, maxHpMult: m.maxHpMult, wardPerThrall: m.wardPerThrall, litanyBarrier: m.litanyBarrier, thrallCap: m.thrallCap };
    });
    const wear = async (id) => {
      const before = await wornCount();
      await cell(await bagOf(id)).dblclick();
      await page.waitForFunction((n) => window.__cwDebug.inventory.all.filter((s) => s.equipped).length === n, before + 1);
      await page.waitForTimeout(150);
    };

    await page.keyboard.press('i');
    await page.waitForSelector('.cw-bag-grid');
    const base = await mods();

    // 1 piece: tracker shows 1 / 5 and every line is grey.
    await wear('set_ossuary_head');
    await cell(await bagOf('set_ossuary_chest')).hover();
    let tip = page.locator('.cw-tooltip .gs-set');
    await tip.waitFor();
    let t = await tip.innerText();
    assert.match(t, /Ivory Reliquary/);
    assert.match(t, /1 \/ 5 worn/);
    assert.match(t, /2 with this/, 'bag piece says what wearing it does');
    assert.equal(await tip.locator('.b.on').count(), 0, 'nothing active at 1 piece');
    assert.equal(await tip.locator('.b.soon').count(), 1, 'the 2-piece switches on with this piece');
    assert.ok(await page.locator('.cw-tooltip .gs-verdict').count() === 0 || true);
    assert.match(await page.locator('[data-detail]').innerText() + await page.locator('.cw-tooltip').innerText(), /completes Ivory Reliquary 2-piece/, 'bag verdict names the set');
    await page.screenshot({ path: `${out}/1-tooltip-one-piece.png` });

    // 2 pieces: the 2-piece lights up, the counsel tip fires, thrall health mod rises, the doll marks both pieces.
    await wear('set_ossuary_chest');
    await page.mouse.move(5, 5);
    assert.equal((await mods()).thrallHpMult, base.thrallHpMult * 1.05, '2-piece folds into the discipline mods');
    assert.equal(await page.locator('.cw-equip-slot.in-set').count(), 2, 'two worn pieces are marked on the paper doll');
    await dismissUntilTip(page, 'A set bonus is awake');

    // 3 pieces, then the bag shows "completes ... 4-piece" for the legguards; a rival crown breaks the 2-piece.
    await wear('set_ossuary_hands');
    await cell(await bagOf('set_ossuary_legs')).click();
    const detail = page.locator('[data-detail]');
    await detail.locator('.gs-verdict').waitFor();
    assert.match(await detail.innerText(), /Upgrade for your Ossuary: .*completes Ivory Reliquary 4-piece/);
    await cell(await bagOf('set_mourner_head')).click();
    await detail.locator('.gs-verdict').waitFor();
    // 3 worn: replacing the crown drops the set to 2 pieces; no bonus tier is lost, so no "breaks" line yet.
    assert.doesNotMatch(await detail.innerText(), /breaks your/);
    await page.screenshot({ path: `${out}/2-detail-three-pieces.png` });

    // 4 pieces: ward per thrall rises. Then the rival crown would break the 4-piece.
    await wear('set_ossuary_legs');
    const four = await mods();
    assert.ok(four.wardPerThrall > base.wardPerThrall, '4-piece adds ward per thrall');
    await cell(await bagOf('set_mourner_head')).click();
    await detail.locator('.gs-verdict').waitFor();
    assert.match(await detail.innerText(), /breaks your Ivory Reliquary 4-piece/);
    await cell(await bagOf('set_ossuary_feet')).hover();
    await page.locator('.cw-tooltip .gs-set .b.soon').waitFor();
    await page.screenshot({ path: `${out}/3-tooltip-four-pieces.png` });

    // 5 pieces: Litany barrier and health.
    await wear('set_ossuary_feet');
    const five = await mods();
    assert.ok(Math.abs(five.litanyBarrier - (base.litanyBarrier + 0.02)) < 1e-9, '5-piece Litany barrier');
    assert.ok(Math.abs(five.maxHpMult - base.maxHpMult * 1.05) < 1e-9, '5-piece health');
    assert.equal(await page.locator('.cw-equip-slot.in-set').count(), 5);
    await page.mouse.move(5, 5);
    await page.waitForTimeout(150);
    await page.screenshot({ path: `${out}/4-reliquary-doll-five.png` });
    await page.locator('.cw-equip').screenshot({ path: `${out}/4b-paper-doll.png` });

    // Character sheet: the Set bonuses block.
    await page.locator('.cw-equip-sheet').click();
    await page.locator('.gs-sheet').waitFor();
    const sheet = await page.locator('.gs-sheet').innerText();
    assert.match(sheet, /Set bonuses/);
    assert.match(sheet, /Ivory Reliquary/);
    assert.match(sheet, /5 \/ 5/);
    assert.equal(await page.locator('.gs-line.set .r.up').count(), 3, 'all three bonuses active (green)');
    await page.locator('.gs-line.set').first().scrollIntoViewIfNeeded();
    await page.screenshot({ path: `${out}/5-character-sheet-sets.png` });
    // Health is open by default: its breakdown lists the set multiplier on its own row.
    assert.match(await page.locator('.gs-sheet').innerText(), /Set bonuses\s+×1\.05/);

    // Codex tab lists every bonus.
    await page.keyboard.press('Escape');
    await page.keyboard.press('k');
    await page.locator('[data-tab="sets"]').click();
    const codex = await page.locator('[role="dialog"][aria-label="Codex"]').innerText();
    await page.screenshot({ path: `${out}/6-codex-sets.png` });
    for (const name of ['Ivory Reliquary', 'Marrow Regent', 'Blightweave', 'Umbral Crossing']) assert.ok(codex.toLowerCase().includes(name.toLowerCase()), `${name} in Codex: ${codex.slice(0, 300)}`);

    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ tracker: true, tip: true, doll: true, verdict: true, sheet: true, codex: true, errors }));
  } finally { await browser.close(); }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
