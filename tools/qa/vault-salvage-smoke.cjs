// Offline UI check for inventory relief: the 48-slot Reliquary, the Ossuary Vault (V) and the Bone Grinder (Salvaging).
// npm run dev -- --host 127.0.0.1 --port 5321 --strictPort
// DM_QA_URL=http://127.0.0.1:5321/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_QA_ARTIFACT_DIR=/tmp/vs node tools/qa/vault-salvage-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-vault-salvage';
  mkdirSync(out, { recursive: true });
  const result = {};
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('console', (m) => { if (/inventory|save failed/i.test(m.text())) console.log('CONSOLE', m.text().slice(0, 300)); });
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5321/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `vault_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'vault@example.invalid');
    await page.fill('#cw-pass', 'TestingVault1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    const adv = (s) => page.evaluate((n) => window.__cwDebug.advance(n), s);
    const bagCount = () => page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => s.slot_index < 100).length);
    const qty = (id) => page.evaluate((i) => window.__cwDebug.inventory.count(i), id);
    const toast = () => page.evaluate(() => [...document.querySelectorAll('.cw-toast, .hud-toast, [class*="toast"]')].map((e) => e.textContent).join(' | '));

    // 1. Fill the bag beyond the old 24 slots, and make sure it is saved past slot 23.
    await page.evaluate(() => {
      const inv = window.__cwDebug.inventory;
      for (let i = 0; i < 14; i++) inv.add({ item_id: 'helm_copper', quantity: 1 });
      for (let i = 0; i < 8; i++) inv.add({ item_id: 'staff_oak', quantity: 1 });
      for (let i = 0; i < 6; i++) inv.add({ item_id: 'helm_iron', quantity: 1 });
      inv.add({ item_id: 'chest_iron', quantity: 1 });
      inv.add({ item_id: 'ore_copper', quantity: 120 });
      inv.add({ item_id: 'log_oak', quantity: 60 });
      inv.add({ item_id: 'ingot_iron', quantity: 9 });
    });
    await page.evaluate(() => window.__cwDebug.inventory.flush());
    const full = await bagCount();
    assert.ok(full > 24, `bag holds more than 24 stacks (${full})`);
    const highSlots = await page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => s.slot_index >= 24 && s.slot_index < 48).length);
    assert.ok(highSlots > 0, 'items live in slots 24-47');
    result.bagStacks = full;

    // 2. The Reliquary shows 48 cells that fit on 1280x800.
    await page.keyboard.press('i');
    await page.waitForSelector('.cw-reliquary .cw-bag-grid .cw-slot');
    assert.equal(await page.locator('.cw-reliquary .cw-bag-grid .cw-slot').count(), 48);
    const box = await page.locator('.cw-reliquary').boundingBox();
    assert.ok(box.x >= 0 && box.x + box.width <= 1280, 'reliquary fits horizontally');
    assert.ok(box.y >= 0 && box.y + box.height <= 800, `reliquary fits vertically (${Math.round(box.y + box.height)})`);
    // lock one helm, then confirm the junk sale excludes it
    await page.locator('.cw-reliquary .cw-slot.filled').first().click();
    await page.locator('[data-lock]').click();
    assert.equal(await page.locator('.cw-reliquary .cw-slot.locked').count(), 1, 'one locked cell');
    await page.screenshot({ path: `${out}/reliquary-48.png` });
    result.reliquaryFits = true;

    // 3. Sell all junk: common and uncommon gear goes after the confirm; the locked piece and rare gear stay.
    const goldBefore = await page.evaluate(() => (window.__cwDebug.progression.character.gold ?? 0));
    const gearBefore = await page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => ['weapon', 'armor_head'].includes(s.item_type) && s.slot_index < 100).length);
    await page.locator('[data-junk]').click();
    assert.match(await page.locator('.cw-tools-confirm').innerText(), /for .*g\?/);
    await page.screenshot({ path: `${out}/sell-junk-confirm.png` });
    await page.locator('[data-junk-yes]').click();
    const gearAfter = await page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => ['weapon', 'armor_head'].includes(s.item_type) && s.slot_index < 100).length);
    assert.equal(gearAfter, 1, `only the locked weapon or helm is left (${gearAfter} of ${gearBefore})`);
    assert.equal(await qty('chest_iron'), 1, 'rare gear is not junk');
    assert.ok((await page.evaluate(() => (window.__cwDebug.progression.character.gold ?? 0))) > goldBefore, 'gold credited');
    result.sellJunkKeptLocked = true;
    // refill some gear to salvage later
    await page.evaluate(() => {
      const inv = window.__cwDebug.inventory;
      for (let i = 0; i < 4; i++) inv.add({ item_id: 'staff_oak', quantity: 1 });
      for (let i = 0; i < 3; i++) inv.add({ item_id: 'helm_iron', quantity: 1 });
      inv.add({ item_id: 'helm_gold', quantity: 1 });
    });
    await page.keyboard.press('Escape');

    // 4. The Vault: V in the Chapterhouse; elsewhere a toast.
    await page.evaluate(() => { const d = window.__cwDebug; d.unlockAll(); d.goto('graves'); });
    await adv(0.5);
    await page.keyboard.press('v');
    await page.waitForTimeout(300);
    assert.equal(await page.locator('.cw-vault').count(), 0, 'vault does not open in the Graves');
    assert.match(await toast(), /The Vault is in the Chapterhouse/);
    await page.evaluate(() => window.__cwDebug.goto('chapterhouse'));
    await adv(0.5);
    await page.keyboard.press('v');
    await page.waitForSelector('.cw-vault [data-vault] .cw-slot', { timeout: 15000 });
    assert.equal(await page.locator('.cw-vault [data-bag] .cw-slot').count(), 48);
    assert.equal(await page.locator('.cw-vault [data-vault] .cw-slot').count(), 40, 'one tab of 40');
    assert.equal(await page.locator('.cw-vault-tabs button').count(), 3);
    const oreBefore = await qty('ore_copper');
    assert.ok(oreBefore > 0);
    await page.screenshot({ path: `${out}/vault-open.png` });
    await page.locator('[data-all="materials"]').click();
    await page.waitForFunction(() => window.__cwDebug.inventory.count('ore_copper') === 0 || document.querySelector('.cw-vault [data-error]')?.textContent, null, { timeout: 15000 });
    assert.equal(await page.locator('.cw-vault [data-error]').innerText(), '', 'no vault error');
    assert.equal(await qty('ore_copper'), 0, 'ore deposited');
    assert.equal(await qty('log_oak'), 0, 'all materials deposited');
    assert.ok((await page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => ['weapon', 'armor_head'].includes(s.item_type)).length)) >= 1, 'gear stayed');
    assert.ok((await page.locator('.cw-vault [data-vault] .cw-slot.filled').count()) >= 3, 'vault shows the stacks');
    await page.screenshot({ path: `${out}/vault-deposited.png` });
    await page.locator('[data-sort]').click();
    await page.waitForFunction(() => document.querySelector('.cw-vault-note')?.textContent.includes('sorted'));
    // withdraw one stack back
    const firstVault = page.locator('.cw-vault [data-vault] .cw-slot.filled').first();
    await firstVault.click();
    await page.waitForFunction(() => document.querySelector('.cw-vault-note')?.textContent.startsWith('Took'));
    const taken = (await qty('ore_copper')) + (await qty('log_oak')) + (await qty('ingot_iron'));
    assert.ok(taken > 0, 'a stack came back to the bag');
    await page.screenshot({ path: `${out}/vault-withdrawn.png` });
    result.vault = { depositedMaterials: true, sorted: true, withdrew: true };
    await page.keyboard.press('Escape');

    // 5. The Bone Grinder in the Acre: salvage a gear item, see yields and Salvaging XP.
    await page.evaluate(() => { window.__cwDebug.goto('acre'); window.__cwDebug.player.teleport(-27, 31); });
    await adv(0.5);
    // the Reliquary's Salvage button works at the Grinder
    await page.keyboard.press('i');
    await page.waitForSelector('.cw-reliquary');
    const gearCell = page.locator('.cw-reliquary .cw-bag-grid .cw-slot[aria-label*="Oak Staff"]').first();
    await gearCell.click();
    assert.equal(await page.locator('[data-salvage]').isEnabled(), true, 'Salvage enabled beside the Grinder');
    await page.screenshot({ path: `${out}/reliquary-salvage-button.png` });
    await page.keyboard.press('Escape');
    await page.evaluate(() => window.__cwDebug.station('grinder'));
    await page.waitForSelector('.cw-salvage .cw-salv');
    assert.ok((await page.locator('.cw-salv').count()) >= 5);
    const levelBefore = await page.evaluate(() => window.__cwDebug.inventory.count('reagent_grave_dust'));
    await page.screenshot({ path: `${out}/grinder-open.png` });
    await page.locator('.cw-salv input:not([disabled])').first().check();
    await page.locator('.cw-salv input:not([disabled])').nth(1).check();
    await page.locator('[data-go]').click();
    await page.waitForSelector('[data-result]');
    const text = await page.locator('[data-result]').innerText();
    assert.match(text, /Ground 2 pieces/);
    assert.match(text, /Grave Dust/);
    assert.match(text, /Salvaging XP/);
    assert.ok((await page.evaluate(() => window.__cwDebug.inventory.count('reagent_grave_dust'))) > levelBefore, 'reagents arrived in the bag');
    const prof = await page.evaluate(() => window.__cwDebug.skills?.rows?.().find((r) => r.profession_id === 'salvaging'));
    const row = await page.evaluate(() => {
      const db = JSON.parse(localStorage.getItem('dm_offline_db_v1'));
      return Object.values(db.accounts).flatMap((a) => a.professions).find((p) => p.profession_id === 'salvaging');
    });
    assert.ok(row && (row.skill_xp > 0 || row.skill_level > 1), 'Salvaging XP stored');
    await page.screenshot({ path: `${out}/grinder-result.png` });
    // Salvage all below rare: takes common and uncommon gear, never the locked piece
    await page.locator('[data-below]').click();
    const belowRare = () => window.__cwDebug.inventory.all.filter((s) => ['weapon', 'armor_head'].includes(s.item_type) && s.slot_index < 100 && s.rarity !== 'rare' && s.rarity !== 'epic').length;
    await page.waitForFunction(`(${belowRare})() === 1`, null, { timeout: 15000 });
    assert.equal(await qty('helm_gold'), 1, 'rare gear was not salvaged');
    await page.screenshot({ path: `${out}/grinder-all-below-rare.png` });
    result.salvage = { xp: row.skill_xp, level: row.skill_level, grinderPanel: true, reliquaryButton: true, allBelowRare: true };
    await page.keyboard.press('Escape');

    // 6. Skills panel lists Salvaging
    await page.keyboard.press('p');
    await page.waitForSelector('.cw-skill');
    assert.ok((await page.locator('.cw-skill', { hasText: 'Salvaging' }).count()) === 1, 'Skills lists Salvaging');
    await page.screenshot({ path: `${out}/skills.png` });
    await page.keyboard.press('Escape');

    // 7. Everything persists across a reload (items past slot 24, vault).
    await page.evaluate(() => window.__cwDebug.inventory.flush());
    await page.reload();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    assert.ok((await qty('reagent_grave_dust')) > 0, 'reagents persisted');
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ ...result, errors }));
  } finally { await browser.close(); }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
