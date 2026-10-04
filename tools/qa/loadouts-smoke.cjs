// Offline UI + behaviour check for loadout presets: save two loadouts from the Grimoire, change the build, apply the first back (rites, runes,
// weapon, off-hand), refuse politely when a piece is gone, and keep a full bag whole.
// npm run dev -- --host 127.0.0.1 --port 5364 --strictPort
// DM_QA_URL=http://127.0.0.1:5364/?offline DM_PLAYWRIGHT_MODULE=/opt/uptime-kuma/node_modules/playwright-core DM_CHROMIUM_PATH=... DM_QA_ARTIFACT_DIR=/tmp/loadouts node tools/qa/loadouts-smoke.cjs
// Do not edit src/ while it runs: Vite hot-reloads the page and the run dies.
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-loadouts';
  mkdirSync(out, { recursive: true });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => { if (m.type() === 'error' && !/403 \(Forbidden\)/.test(m.text())) errors.push(`console: ${m.text()}`); });
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false, autoGather: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5364/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `lo_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'lo@example.invalid');
    await page.fill('#cw-pass', 'TestingLoadouts1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    const dbg = (fn, arg) => page.evaluate(fn, arg);
    const shot = (name) => page.screenshot({ path: `${out}/${name}.png` });
    const rows = () => dbg(() => window.__cwDebug.inventory.all.map((s) => [s.slot_index, s.item_id, s.quantity, s.equipped]));
    const slotOf = async (id) => (await rows()).find((r) => r[1] === id && r[0] < 48)?.[0];
    const equip = async (id) => {
      const slot = await slotOf(id);
      assert.notEqual(slot, undefined, `${id} is in the bag`);
      await dbg(async ([s]) => { const api = await import('/src/net/api.ts'); window.__cwDebug.inventory.replace(await api.equipItem((Object.values(JSON.parse(localStorage.getItem('dm_offline_db_v1')).accounts)[0].character.id), s, 1)); }, [slot]);
    };
    const openGrimoire = async () => { if (!(await page.locator('.cw-grimoire').count())) await page.keyboard.press('l'); await page.waitForSelector('.cw-grimoire [data-loadouts] .cw-lo-grid'); };
    const closeGrimoire = async () => { if (await page.locator('.cw-grimoire').count()) await page.keyboard.press('l'); await page.waitForSelector('.cw-grimoire', { state: 'detached' }); };

    await dbg(() => { window.__cwDebug.zoom(0.32); window.__cwDebug.god(); window.__cwDebug.unlockAll(); window.__cwDebug.gold(5000); });
    await dbg(() => { const i = window.__cwDebug.inventory; for (const id of ['wand_bone', 'scythe_bone', 'skull_focus_bone', 'mourning_bell_bone', 'rune_volley', 'rune_splinter', 'rune_impale', 'rune_mass_grave', 'rune_bone_colossus']) i.add({ item_id: id, quantity: 1 }); });
    await dbg(() => window.__cwDebug.inventory.flush());
    await equip('wand_bone');
    await equip('skull_focus_bone');

    console.log('STEP 1 save the first loadout');
    await dbg(() => window.__cwDebug.loadout(['black_litany']));
    await openGrimoire();
    assert.match(await page.locator('.cw-lo').innerText(), /0\/6/);
    await page.locator('[data-act="new"]').click();
    await page.fill('.cw-lo input[name="n"]', 'Plague Doctor');
    await page.locator('.cw-lo form button[type="submit"]').click();
    await page.waitForSelector('.cw-lo-card.active');
    assert.match(await page.locator('.cw-lo-card.active').innerText(), /Plague Doctor[\s\S]*on now/i);
    await shot('1-first-saved');

    console.log('STEP 2 a second build: scythe, bell, a rune, other rites');
    await closeGrimoire();
    await equip('scythe_bone');
    await dbg(async () => { const api = await import('/src/net/api.ts'); window.__cwDebug.inventory.replace(await api.runeSocket((Object.values(JSON.parse(localStorage.getItem('dm_offline_db_v1')).accounts)[0].character.id), 'exhume', 'rune_bone_colossus')); });
    await dbg(() => window.__cwDebug.loadout(['marrow_spear']));
    await openGrimoire();
    await page.locator('[data-act="new"]').click();
    await page.fill('.cw-lo input[name="n"]', 'Colossus');
    await page.keyboard.press('Enter');
    await page.waitForFunction(() => document.querySelectorAll('.cw-lo-card[data-slot]').length === 2);
    await shot('2-two-saved');

    console.log('STEP 3 apply the first back');
    const before = await rows();
    await page.locator('.cw-lo-card', { hasText: 'Plague Doctor' }).locator('[data-act="apply"]').click();
    await page.waitForFunction(() => document.querySelector('.cw-lo-card.active')?.textContent?.includes('Plague Doctor'));
    const after = await rows();
    const at = (r, slot) => r.find((x) => x[0] === slot)?.[1];
    assert.equal(at(after, 105), 'wand_bone');
    assert.equal(at(after, 106), 'skull_focus_bone');
    assert.equal(at(after, 132), undefined, 'the Colossus rune is out of Exhume');
    assert.ok(after.some((r) => r[0] < 48 && r[1] === 'rune_bone_colossus'), 'and back in the bag');
    assert.equal(before.reduce((n, r) => n + r[2], 0), after.reduce((n, r) => n + r[2], 0), 'nothing created or lost');
    assert.equal((await dbg(() => window.__cwDebug.loadout()))[0], 'black_litany', 'the saved key order came back');
    await shot('3-applied');

    console.log('STEP 4 a piece that is gone is skipped and named, the rest applies');
    await dbg(async () => {
      const api = await import('/src/net/api.ts');
      const inv = window.__cwDebug.inventory;
      const id = Object.values(JSON.parse(localStorage.getItem('dm_offline_db_v1')).accounts)[0].character.id;
      const bag = inv.all.filter((x) => x.slot_index < 48 && x.item_id !== 'scythe_bone').map((x) => ({ slot_index: x.slot_index, item_id: x.item_id, quantity: x.quantity, equipped: 0 }));
      inv.replace(await api.saveInventory(id, bag, 48));
    });
    await page.locator('.cw-lo-card', { hasText: 'Colossus' }).locator('[data-act="apply"]').click();
    await page.waitForFunction(() => document.querySelector('.cw-lo-msg')?.textContent?.includes('except'));
    const msg = await page.locator('.cw-lo-msg').innerText();
    assert.match(msg, /Scythe.*not in your bag/i);
    assert.equal(at(await rows(), 132), 'rune_bone_colossus', 'the rest applied: the rune is back in Exhume');
    await shot('4-colossus-skipped');

    console.log('STEP 4b hotkeys: unbound by default, refuse a used key, bind F7, cycle with it');
    await closeGrimoire();
    await page.keyboard.press('Escape');
    await page.waitForSelector('[data-bind="loadout_next"]');
    assert.equal(await page.locator('[data-bind="loadout_next"]').textContent(), 'Unbound');
    await page.locator('[data-bind="loadout_next"]').click();
    await page.keyboard.press('l');
    assert.match(await page.locator('[data-bindnote]').innerText(), /L is already used for the Grimoire/);
    assert.equal(await page.locator('[data-bind="loadout_next"]').textContent(), 'Unbound');
    await page.locator('[data-bind="loadout_next"]').click();
    await page.keyboard.press('F7');
    assert.equal(await page.locator('[data-bind="loadout_next"]').textContent(), 'F7');
    await page.locator('[data-bind="loadout_1"]').click();
    await page.keyboard.press('F7');
    assert.match(await page.locator('[data-bindnote]').innerText(), /F7 is already Next loadout/);
    await page.locator('[data-bind="loadout_1"]').click();
    await page.keyboard.press('f');
    assert.equal(await page.locator('[data-bind="loadout_1"]').textContent(), 'F');
    await shot('4b-settings-keys');
    await page.keyboard.press('Escape');
    await page.waitForSelector('.cw-settings', { state: 'detached' });
    const pre = await rows();
    await page.keyboard.press('F7');
    await page.waitForFunction(() => !window.__cwDebug.inventory.all.some((s) => s.slot_index === 132), null, { timeout: 15000 });
    assert.equal(at(pre, 132), 'rune_bone_colossus', 'the Colossus rune was socketed before the hotkey (Plague Doctor has none)');
    await openGrimoire();
    assert.match(await page.locator('.cw-lo').innerText(), /F7/);
    assert.match(await page.locator('.cw-lo-card', { hasText: 'Plague Doctor' }).locator('kbd.key').textContent(), /^F$/);
    assert.match(await page.locator('.cw-lo-card', { hasText: 'Colossus' }).innerText(), /Main hand:.*Off-hand:/i);
    await shot('4c-card-keys');

    console.log('STEP 5 rename and delete');
    await page.locator('.cw-lo-card', { hasText: 'Colossus' }).locator('[data-act="rename"]').click();
    await page.fill('.cw-lo input[name="n"]', 'Tank');
    await page.keyboard.press('Enter');
    await page.waitForSelector('.cw-lo-card:has-text("Tank")');
    await page.locator('.cw-lo-card', { hasText: 'Tank' }).locator('[data-act="delete"]').click();
    await page.locator('.cw-lo-card', { hasText: 'Tank' }).locator('[data-act="delete-yes"]').click();
    await page.waitForFunction(() => document.querySelectorAll('.cw-lo-card[data-slot]').length === 1);
    const box = await page.locator('.cw-grimoire').boundingBox();
    assert.ok(box.x >= 0 && box.y >= 0 && box.x + box.width <= 1280 && box.y + box.height <= 800, `Grimoire fits 1280x800 (${JSON.stringify(box)})`);
    assert.deepEqual(errors, [], 'no page errors');
    console.log('OK');
  } finally {
    await browser.close();
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
