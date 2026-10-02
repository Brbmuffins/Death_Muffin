// Workbench craft-quantity + Sell-all-stack smoke (offline mode). Run against a dev server:
//   npx vite --host 127.0.0.1 --port 5373 --strictPort ; DM_QA_URL=http://127.0.0.1:5373/?offline node tools/qa/craft-n-smoke.cjs
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp';
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const phone = process.env.DM_QA_DESKTOP ? {} : { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true };
    const ctx = await browser.newContext(process.env.DM_QA_DESKTOP ? { viewport: { width: 1280, height: 800 } } : phone);
    const page = await ctx.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5373/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', 'craft_n');
    await page.fill('#cw-email', 'craftn@example.invalid');
    await page.fill('#cw-pass', 'TestingCraftN1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    const view = (fn, arg) => page.evaluate(async ([src, a]) => { const v = (await import('/src/app/GameRuntime.ts')).getRuntime().view; return eval(`(${src})`)(v, a); }, [fn.toString(), arg]);
    const count = (id) => view((v, i) => v.inventory.count(i), id);

    const until = async (fn, ms = 20000) => { const t = Date.now(); while (!(await fn())) { assert.ok(Date.now() - t < ms, 'timed out'); await page.waitForTimeout(100); } };
    await view(async (v) => { v.inventory.add({ item_id: 'ore_copper', quantity: 20 }); await v.inventory.flush(); });
    await view((v) => v.togglePanel('forge'));
    await page.waitForSelector('.cw-recipe');
    const card = page.locator('.cw-recipe', { hasText: 'Smelt Copper Ingot' });
    await page.screenshot({ path: `${out}/craft-n-workbench.png` });

    // Touch targets: every quantity control is >= 40px tall.
    for (const sel of ['[data-dec]', '[data-inc]', '[data-set$=":5"]', '[data-set$=":max"]', '.cw-qty-input', '[data-craft]']) {
      const box = await card.locator(sel).first().boundingBox();
      assert.ok(box && box.height >= 39.5, `${sel} is ${box && box.height}px tall`);
    }

    // Craft x3 by typing the quantity.
    await card.locator('.cw-qty-input').fill('3');
    assert.equal((await card.locator('[data-craft]').textContent()).trim(), 'Craft ×3');
    await card.locator('[data-craft]').click();
    await until(async () => (await count('ingot_copper')) >= 3);
    await page.waitForFunction(() => ![...document.querySelectorAll('.cw-recipe [data-craft]')].some((b) => /Crafting/.test(b.textContent)), null, { timeout: 20000 });
    assert.equal(await count('ingot_copper'), 3);
    assert.equal(await count('ore_copper'), 11);

    // +, -, x5 and Max (11 ore -> 3 more).
    await card.locator('[data-set$=":5"]').click();
    assert.equal(await card.locator('.cw-qty-input').inputValue(), '3', 'x5 clamps to what the ore allows');
    await card.locator('[data-dec]').click();
    assert.equal(await card.locator('.cw-qty-input').inputValue(), '2');
    await card.locator('[data-inc]').click();
    await card.locator('[data-set$=":max"]').click();
    assert.equal((await card.locator('[data-craft]').textContent()).trim(), 'Craft ×3');
    await card.locator('[data-craft]').click();
    await until(async () => (await count('ingot_copper')) >= 6);
    assert.equal(await count('ore_copper'), 2);
    // Out of ore: controls and craft are disabled.
    await page.waitForFunction(() => [...document.querySelectorAll('.cw-recipe')].find((r) => /Smelt Copper Ingot/.test(r.textContent))?.querySelector('[data-craft]')?.disabled, null, { timeout: 10000 });
    await page.locator('.cw-panel-float [data-close]').first().click();

    // Sell all of the ingot stack: confirm in place.
    const gold0 = await view((v) => v.progression.character.gold);
    await view((v) => v.togglePanel('inventory'));
    await page.waitForSelector('.cw-slot.filled');
    await page.locator('.cw-slot.filled[aria-label^="Copper Ingot"]').first().click();
    const sellAll = page.locator('[data-sellall]');
    const label = (await sellAll.textContent()).trim();
    assert.match(label, /^Sell all \(6 · \d+g\)$/, label);
    const box = await sellAll.boundingBox();
    assert.ok(box.height >= 39.5, `sell all is ${box.height}px`);
    await sellAll.click();
    assert.equal(await count('ingot_copper'), 6, 'first tap only asks');
    await page.screenshot({ path: `${out}/craft-n-sell-confirm.png` });
    await page.locator('[data-sellall-no]').click();
    assert.equal(await count('ingot_copper'), 6, 'cancel keeps the stack');
    await page.locator('[data-sellall]').click();
    await page.locator('.cw-detail-actions [data-sell]').filter({ hasText: 'Sell them' }).click();
    assert.equal(await count('ingot_copper'), 0);
    assert.equal(await page.locator('.cw-slot.filled[aria-label^="Copper Ingot"]').count(), 0, 'slot emptied');
    const gold1 = await view((v) => v.progression.character.gold);
    console.log(JSON.stringify({ gold0, gold1 }));
    assert.ok(gold1 > gold0, `gold rose ${gold0} -> ${gold1}`);
    assert.deepEqual(errors, []);
    console.log('craft-n smoke OK');
  } finally { await browser.close(); }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
