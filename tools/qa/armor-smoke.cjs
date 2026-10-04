const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const setPrefix = process.env.DM_QA_ASCENDED ? 'set_knight_ascended' : 'set_knight';
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', 'armor_review');
    await page.fill('#cw-email', 'armor@example.invalid');
    await page.fill('#cw-pass', 'TestingArmor');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Hollow Knight' }).click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 45000 });
    const added = await page.evaluate(async (prefix) => {
      const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
      const ok = scene.inventory.add({ item_id: `${prefix}_head`, quantity: 1 }) &&
        scene.inventory.add({ item_id: `${prefix}_chest`, quantity: 1 });
      await scene.inventory.flush();
      return ok && scene.inventory.state === 'saved';
    }, setPrefix);
    assert.equal(added, true, 'armor added and saved');
    await page.keyboard.press('i');
    for (const part of ['head', 'chest']) {
      await page.locator('.cw-bag-grid .cw-slot').filter({ has: page.locator(`img[src*="${setPrefix}_${part}.svg"]`) }).click();
      await page.locator('.cw-bag-detail [data-act]').click();
      await page.waitForFunction(({ prefix, part, reserved }) => {
        const db = JSON.parse(localStorage.getItem('dm_offline_db_v1'));
        return Object.values(db.accounts).some(acc => acc.slots.some(s => s.item_id === `${prefix}_${part}` && s.slot_index === reserved));
      }, { prefix: setPrefix, part, reserved: part === 'head' ? 100 : 101 });
      await page.locator(`.cw-equip img[src*="${setPrefix}_${part}.svg"]`).waitFor();
    }
    await page.waitForFunction(async (prefix) => {
      const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
      return scene.avatar.worn.has('head') && scene.inventory.all.some(s => s.item_id === `${prefix}_chest` && s.equipped);
    }, setPrefix);
    const state = await page.evaluate(async (prefix) => {
      const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
      const icon = document.querySelector(`.cw-equip img[src*="${prefix}_head.svg"]`);
      let headMeshes = 0;
      scene.avatar.worn.get('head')?.obj.traverse(obj => { if (obj.isMesh) headMeshes++; });
      return { head: scene.avatar.worn.get('head')?.key, headMeshes,
        chest: scene.inventory.all.find(s => s.item_id === `${prefix}_chest`)?.slot_index,
        armorSlots: scene.inventory.all.filter(s => s.item_id.startsWith('set_knight')).map(s => ({ id: s.item_id, slot: s.slot_index, equipped: s.equipped })),
        headTint: scene.avatar.c.gearTint.head.w, chestTint: scene.avatar.c.gearTint.tint[0].w, chestGlow: scene.avatar.c.gearTint.glow[0].length(), iconLoaded: icon?.complete && icon.naturalWidth > 0,
        setText: document.querySelector('.cw-bag-detail')?.textContent };
    }, setPrefix);
    assert.equal(state.head, `${setPrefix}_head`);
    // The Hollow Knight's own helmet is the head: a worn helm tints it (no dome), so check the tint instead of meshes.
    assert.ok(state.headTint > 0, 'worn helm tints the built-in helmet');
    assert.equal(state.chest, 101);
    assert.ok(state.chestTint > 0);
    if (process.env.DM_QA_ASCENDED) {
      assert.ok(state.chestGlow > 0);
    }
    assert.equal(state.iconLoaded, true);
    assert.deepEqual(errors, []);
    if (process.env.DM_QA_ARTIFACT_DIR) await page.screenshot({ path: `${process.env.DM_QA_ARTIFACT_DIR}/armor-${process.env.DM_QA_ASCENDED ? 'ascended-' : ''}knight.png` });
    console.log(JSON.stringify({ ...state, errors }));
  } finally { await browser.close(); }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
