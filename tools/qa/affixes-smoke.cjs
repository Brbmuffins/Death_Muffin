// Offline UI check for item level and affixes: rolled drops, tooltip, compare arrows, equip -> stats, Character sheet, Vault, Bone Grinder,
// sell price, a forged save, reload persistence and the portable save. Rolls come from the offline mock (the same affixRules the server uses).
// npm run dev -- --host 127.0.0.1 --port 5339 --strictPort
// DM_QA_URL=http://127.0.0.1:5339/?offline DM_PLAYWRIGHT_MODULE=/home/ubuntu/.npm/_npx/e41f203b7505f1fb/node_modules/playwright \
//   DM_CHROMIUM_PATH=/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome DM_QA_ARTIFACT_DIR=/tmp/affixes node tools/qa/affixes-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-affixes';
  mkdirSync(out, { recursive: true });
  const result = {};
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5339/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `affix_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'affix@example.invalid');
    await page.fill('#cw-pass', 'TestingAffix1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    const adv = (s) => page.evaluate((n) => window.__cwDebug.advance(n), s);
    const bag = () => page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => s.slot_index < 100).map((s) => ({ item_id: s.item_id, name: s.name, rarity: s.rarity, slot: s.slot_index, inst: s.inst ?? null, sell: s.sell_value, base: s.base_sell ?? s.sell_value })));

    // Drops go through the mock's POST /api/loot/roll-gear. A fixed Math.random makes the rolls predictable:
    //   0.58 -> two affixes: Gravebound (thralls hit harder) + a stat suffix;  0.0 -> one stat prefix;  0.99 -> three necromancer affixes.
    async function drop(item, level, source, rnd) {
      await page.evaluate(([r]) => { window.__realRandom = Math.random; if (r !== null) Math.random = () => r; }, [rnd]);
      await page.evaluate(([i, l, s]) => window.__cwDebug.dropGear(i, l, s), [item, level, source]);
      await page.waitForFunction(() => window.__cwDebug.rollsPending() === 0, null, { timeout: 15000 });
      await page.evaluate(() => { Math.random = window.__realRandom; });
      await adv(1.5); // the piece lands beside the hero and is picked up
    }
    await page.evaluate(() => window.__cwDebug.god());
    await drop('helm_iron', 10, 'boss', 0.58);
    await drop('helm_iron', 10, 'boss', 0.0);
    await drop('ring_copper', 10, 'first_kill', 0.99);
    await drop('chest_iron', 10, 'elite', 0.58);
    await drop('staff_moon', 10, 'boss', 0.99);
    await drop('plate_copper', 6, 'kill', null);
    // Ground view: a three-affix drop and a one-affix drop glow in their affix-count colours (the hero steps away so they are not picked up yet).
    {
      const at = await page.evaluate(() => ({ x: window.__cwDebug.player.x, z: window.__cwDebug.player.z }));
      for (const [item, rnd] of [['staff_oak', 0.99], ['helm_copper', 0.0]]) {
        await page.evaluate(([r]) => { window.__realRandom = Math.random; Math.random = () => r; }, [rnd]);
        await page.evaluate(([i]) => window.__cwDebug.dropGear(i, 10, 'boss'), [item]);
        await page.waitForFunction(() => window.__cwDebug.rollsPending() === 0, null, { timeout: 15000 });
        await page.evaluate(() => { Math.random = window.__realRandom; });
        await page.evaluate(([x, z]) => window.__cwDebug.player.teleport(x, z), [at.x + 3.5 * (rnd === 0.99 ? 1 : 2), at.z + 4]);
        await adv(0.4);
      }
      assert.equal(await page.evaluate(() => window.__cwDebug.counts().loot), 2, 'both rolled drops wait on the ground');
      await adv(0.3);
      await page.screenshot({ path: `${out}/ground-beams.png` });
      await page.evaluate(([x, z]) => window.__cwDebug.player.teleport(x, z), [at.x, at.z]);
      await adv(1.5);
    }
    await page.evaluate(() => window.__cwDebug.inventory.flush());
    let items = await bag();
    const rolled = items.filter((i) => i.inst);
    assert.ok(rolled.length >= 5, `rolled pieces landed in the bag (${rolled.length})`);
    const grave = items.find((i) => i.inst && i.inst.affixes[0]?.id === 'p_thrall_dmg' && i.item_id === 'helm_iron');
    assert.ok(grave, 'the Gravebound helm exists');
    assert.match(grave.name, /^Gravebound Iron Helm/);
    assert.equal(grave.inst.ilvl, 14, 'boss +4 on a level-10 drop');
    assert.equal(grave.rarity, 'rare', 'two affixes read as rare');
    const one = items.find((i) => i.inst && i.item_id === 'helm_iron' && i.inst.affixes.length === 1);
    assert.ok(one && one.name.startsWith('Brutal') && one.rarity === 'uncommon', `one affix reads as uncommon (${one?.name})`);
    const three = items.find((i) => i.inst && i.item_id === 'ring_copper');
    assert.equal(three.inst.affixes.length, 3);
    assert.equal(three.rarity, 'epic', 'three affixes read as epic');
    assert.ok(grave.sell > grave.base, 'rolled pieces sell for more');
    result.drops = rolled.map((r) => `${r.name} ilvl ${r.inst.ilvl}`);

    // Reliquary: rarity colours reflect affix count; tooltip lists ilvl and affixes; the arrow counts affixes.
    await page.keyboard.press('i');
    await page.waitForSelector('.cw-reliquary .cw-bag-grid .cw-slot.filled');
    const cell = (name) => page.locator(`.cw-reliquary .cw-bag-grid .cw-slot[aria-label^="${name}"]`).first();
    await cell(grave.name).hover();
    await page.waitForSelector('.cw-tooltip .gs-ilvl');
    const tip = await page.locator('.cw-tooltip').innerText();
    assert.match(tip, /Item level 14/);
    assert.match(tip, /2 affixes/);
    assert.match(tip, /Thralls hit \+/, 'the necromancer affix is spelled out');
    assert.ok((await page.locator('.cw-tooltip .gs-affix.necro').count()) >= 1, 'necro affix is tinted');
    assert.match(tip, /Upgrade for your Gravecaller/);
    await page.screenshot({ path: `${out}/tooltip-gravebound.png` });
    await page.mouse.move(5, 5);
    await cell(three.name).hover();
    await page.waitForSelector('.cw-tooltip .gs-ilvl');
    assert.equal(await page.locator('.cw-tooltip .gs-affix.necro').count(), 3, 'all three affixes are necromancer levers');
    await page.screenshot({ path: `${out}/tooltip-three-affixes.png` });
    await page.mouse.move(5, 5);
    const colours = await page.evaluate(() => [...document.querySelectorAll('.cw-reliquary .cw-bag-grid .cw-slot.filled')].map((c) => c.style.getPropertyValue('--rarity')));
    assert.ok(new Set(colours).size >= 3, `several rarity colours in the bag (${[...new Set(colours)].join(' ')})`);
    // select a bag piece: the detail strip shows the compare block
    await cell(grave.name).click();
    await page.waitForSelector('.cw-bag-detail .gs-cmp');
    const detail = await page.locator('.cw-bag-detail').innerText();
    assert.match(detail, /Item level 14/);
    assert.match(detail, /equip/i);
    await page.mouse.move(5, 5);
    const noScroll = () => page.evaluate(() => { const el = document.querySelector('.cw-reliquary'); return { scroll: el.scrollHeight, client: el.clientHeight, bottom: Math.round(el.getBoundingClientRect().bottom) }; });
    const fit = await noScroll();
    await page.screenshot({ path: `${out}/reliquary-fit-check.png` }); // captured before the assertion, so a failure shows why
    assert.ok(fit.scroll <= fit.client + 1, `the detail strip fits without scrolling (${fit.scroll} > ${fit.client})`);
    assert.ok(fit.bottom <= 680, `and stays clear of the hotbar (bottom ${fit.bottom})`);
    await page.screenshot({ path: `${out}/reliquary-selected.png` });
    // the longest case: three necromancer affixes plus the compare block
    await cell(three.name).click();
    await page.waitForSelector('.cw-bag-detail .gs-cmp');
    const fit3 = await noScroll();
    assert.ok(fit3.scroll <= fit3.client + 1, `three affixes fit without scrolling (${fit3.scroll} > ${fit3.client})`);
    await page.screenshot({ path: `${out}/reliquary-selected-three.png` });
    await cell(grave.name).click();
    await page.waitForSelector('.cw-bag-detail .gs-cmp');
    const bw = await page.locator('.cw-reliquary').boundingBox();
    assert.ok(bw.x >= 0 && bw.x + bw.width <= 1280 && bw.y >= 0 && bw.y + bw.height <= 800, 'the Reliquary fits 1280x800 with the longest tooltip content');

    // Equip it: the affix reaches the stat pipeline (thrall damage up) and the worn row keeps its roll.
    const dmgBefore = await page.evaluate(() => window.__cwDebug.player.stats.thrallDamage);
    await page.mouse.move(5, 5);
    await page.locator('.cw-bag-detail [data-act]').click();
    await page.waitForFunction((n) => !!document.querySelector('.cw-equip-slot.filled') && window.__cwDebug.inventory.all.some((s) => s.equipped && s.inst), null, { timeout: 15000 });
    await page.waitForTimeout(300);
    const dmgAfter = await page.evaluate(() => window.__cwDebug.player.stats.thrallDamage);
    assert.ok(dmgAfter > dmgBefore, `worn Gravebound raised thrall damage (${dmgBefore} -> ${dmgAfter})`);
    const worn = await page.evaluate(() => window.__cwDebug.inventory.all.find((s) => s.equipped && s.inst).inst);
    assert.equal(worn.id, grave.inst.id, 'the worn row still points at the same roll');
    result.thrallDamage = [Math.round(dmgBefore * 10) / 10, Math.round(dmgAfter * 10) / 10];
    await page.screenshot({ path: `${out}/reliquary-equipped.png` });
    await page.keyboard.press('Escape');

    // Character sheet: an Item affixes block, and the rows inside the formulas that carry them.
    await page.keyboard.press('j');
    await page.waitForSelector('.gs-sheet .gs-body h3');
    const sheet = await page.locator('.gs-sheet').innerText();
    assert.match(sheet, /Item affixes/);
    assert.match(sheet, /Gravebound Iron Helm/);
    assert.match(sheet, /ilvl 14/);
    await page.locator('.gs-line [data-line="thrallDamage"]').click();
    const rows = await page.locator('.gs-line [data-line="thrallDamage"]').locator('xpath=..').innerText();
    assert.match(rows, /Item affixes/, 'Thrall damage names the affix source');
    await page.screenshot({ path: `${out}/character-sheet.png` });
    await page.keyboard.press('Escape');

    // Vault: the roll travels with the piece, both ways.
    const before = (await bag()).find((i) => i.name === three.name).inst.id;
    await page.evaluate(() => { const d = window.__cwDebug; d.unlockAll(); d.goto('chapterhouse'); });
    await adv(0.5);
    await page.keyboard.press('v');
    await page.waitForSelector('.cw-vault [data-bag] .cw-slot');
    await page.locator(`.cw-vault [data-bag] .cw-slot[aria-label^="${three.name}"]`).first().click();
    await page.waitForFunction((n) => [...document.querySelectorAll('.cw-vault [data-vault] .cw-slot.filled')].some((c) => c.getAttribute('aria-label').startsWith(n)), three.name, { timeout: 15000 });
    const vaultTitle = await page.locator(`.cw-vault [data-vault] .cw-slot[aria-label^="${three.name}"]`).first().getAttribute('title');
    assert.match(vaultTitle, /Item level/);
    assert.match(vaultTitle, /†/, 'necromancer affix marked in the Vault title');
    await page.screenshot({ path: `${out}/vault-rolled.png` });
    await page.locator('[data-sort]').click();
    await page.waitForFunction(() => document.querySelector('.cw-vault-note')?.textContent.includes('sorted'));
    await page.locator(`.cw-vault [data-vault] .cw-slot[aria-label^="${three.name}"]`).first().click();
    await page.waitForFunction((n) => window.__cwDebug.inventory.all.some((s) => s.name === n && s.slot_index < 100), three.name, { timeout: 15000 });
    const after = (await bag()).find((i) => i.name === three.name).inst;
    assert.equal(after.id, before, 'the same roll came back from the Vault');
    assert.equal(after.affixes.length, 3);
    await page.keyboard.press('Escape');
    result.vault = true;

    // Bone Grinder: a rolled piece shows a better preview and pays more XP than its plain twin.
    await page.evaluate(() => { window.__cwDebug.goto('acre'); window.__cwDebug.player.teleport(-27, 31); });
    await adv(0.5);
    await page.evaluate(() => window.__cwDebug.inventory.add({ item_id: 'ring_copper', quantity: 1 }));
    await page.evaluate(() => window.__cwDebug.station('grinder'));
    await page.waitForSelector('.cw-salvage .cw-salv');
    const lines = await page.locator('.cw-salv').evaluateAll((els) => els.map((e) => ({ name: e.querySelector('.nm b')?.textContent, yl: e.querySelector('.yl')?.textContent, ilvl: /ilvl/.test(e.querySelector('.nm')?.textContent ?? '') })));
    const rolledLine = lines.find((l) => l.name === three.name);
    const plainLine = lines.find((l) => l.name === 'Copper Ring');
    assert.ok(rolledLine?.ilvl, 'the grinder lists the item level');
    assert.match(rolledLine.yl, /\(\+1 \d+%\)/, 'a rolled piece advertises its extra-material chance');
    assert.ok(plainLine && !/\(\+1/.test(plainLine.yl), 'a plain piece does not');
    await page.screenshot({ path: `${out}/grinder-rolled.png` });
    await page.locator(`.cw-salv:has-text("${three.name}") input`).check();
    await page.locator('[data-go]').click();
    await page.waitForSelector('[data-result]');
    assert.match(await page.locator('[data-result]').innerText(), /Ground 1 piece/);
    assert.equal((await bag()).some((i) => i.inst && i.inst.id === before), false, 'the salvaged roll is gone');
    await page.keyboard.press('Escape');
    result.salvage = true;

    // A forged save is refused with a readable error and changes nothing.
    const forged = await page.evaluate(async () => {
      const api = await import('/src/net/api.ts');
      const cid = window.__cwDebug.progression.character.id;
      const slots = window.__cwDebug.inventory.all.filter((s) => s.slot_index < 48).map((s) => ({ slot_index: s.slot_index, item_id: s.item_id, quantity: s.quantity, equipped: 0, instance_id: s.instance_id ?? null }));
      const target = slots.find((s) => s.instance_id);
      try { await api.saveInventory(cid, [{ ...target, instance_id: 777777 }], 48); return 'accepted'; } catch (e) { return e.message; }
    });
    assert.match(forged, /could not be verified/);
    result.forgedSave = forged;

    // The portable save carries each roll inline for an online import.
    const portable = await page.evaluate(async () => {
      const m = await import('/src/net/mockBackend.ts');
      const snap = m.exportLocalSave(localStorage.getItem('dm_jwt') ?? `offline:${Object.keys(JSON.parse(localStorage.getItem('dm_offline_db_v1')).accounts)[0]}`);
      return snap.slots.filter((s) => s.inst).map((s) => ({ id: s.item_id, ilvl: s.inst.ilvl, n: s.inst.affixes.length, hasId: 'instance_id' in s }));
    });
    assert.ok(portable.length >= 3 && portable.every((p) => !p.hasId), `portable save carries ${portable.length} rolls inline`);

    // Everything persists across a reload.
    await page.evaluate(() => window.__cwDebug.inventory.flush());
    await page.reload();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    const reloaded = await bag();
    assert.ok(reloaded.some((i) => i.inst && /^Gravebound/.test(i.name)), 'rolled gear survived a reload');
    assert.ok(await page.evaluate(() => window.__cwDebug.inventory.all.some((s) => s.equipped && s.inst)), 'and so did the worn one');
    await page.keyboard.press('i');
    await page.waitForSelector('.cw-reliquary .cw-bag-grid .cw-slot.filled');
    await page.screenshot({ path: `${out}/reliquary-reloaded.png` });
    assert.deepEqual(errors, []);
    console.log(JSON.stringify({ ...result, errors }));
  } finally { await browser.close(); }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
