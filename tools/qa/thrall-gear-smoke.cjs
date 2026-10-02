// Offline UI check for thrall gear (the Legion kit): spare weapon and armour go to the legion, the stats reach new thralls, Reinforce spends
// gold, archers and bone mages carry the kit bow and staff, the kit never touches the hero, and a full bag refuses to take a piece back.
// npm run dev -- --host 127.0.0.1 --port 5352 --strictPort
// DM_QA_URL=http://127.0.0.1:5352/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_CHROMIUM_PATH=/path/to/chrome DM_QA_ARTIFACT_DIR=/tmp/tg node tools/qa/thrall-gear-smoke.cjs
// Do not edit src/ while it runs: Vite hot-reloads the page and the run dies.
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-thrall-gear';
  mkdirSync(out, { recursive: true });
  const result = {};
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: true, autoCombat: false, autoGather: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5352/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `legion_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'legion@example.invalid');
    await page.fill('#cw-pass', 'TestingLegion1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    await page.evaluate(async () => { window.__api = await import('/src/net/api.ts'); });
    const dbg = (fn, arg) => page.evaluate(fn, arg);
    const rows = () => dbg(() => window.__cwDebug.inventory.all.map((s) => [s.slot_index, s.item_id, s.equipped]));
    const stats = () => dbg(() => { const s = window.__cwDebug.player.stats; return { hp: s.thrallHp, dmg: s.thrallDamage, maxHp: s.maxHp, spell: s.spellPower }; });
    const flush = () => dbg(() => window.__cwDebug.inventory.flush());
    const advance = (s) => dbg((n) => window.__cwDebug.advance(n), s);
    const shot = (name) => page.screenshot({ path: `${out}/${name}.png` });
    const fits = async (sel, what) => {
      const box = await page.locator(sel).boundingBox();
      assert.ok(box.x >= 0 && box.y >= 0 && box.x + box.width <= 1280 && box.y + box.height <= 800, `${what} fits 1280x800 (${JSON.stringify(box)})`);
    };

    console.log('STEP 1'); // 1. Spare gear in the bag; the counsel tip offers the Legion; the Reliquary has a Legion button.
    await dbg(() => {
      const i = window.__cwDebug.inventory;
      for (const id of ['sword_copper', 'staff_iron', 'bow_oak', 'plate_copper', 'chest_iron', 'helm_iron', 'ring_copper']) i.add({ item_id: id, quantity: 1 });
      window.__cwDebug.gold(5000);
    });
    await flush();
    const base = await stats();
    // Control shot: an archer, a bone mage and a warrior with no kit (the stand-in bow and staff, no armour wash).
    // Raised in a row north of the hero and held still (speed 0), so the control and the kit shots frame the same three bodies.
    const raiseThree = async () => {
      await dbg(() => { const d = window.__cwDebug; d.raise('penitent', -2.2, -3.2); d.raise('deacon', 0, -3.6); d.raise('robber', 2.2, -3.2); });
      await advance(0.1);
      await dbg(() => { for (const t of window.__cwDebug.sim().thralls.values()) t.speed = 0; });
    };
    const clearThralls = () => dbg(() => { const t = window.__cwDebug.sim().thralls; for (const id of [...t.keys()]) t.delete(id); });
    await dbg(() => { window.__cwDebug.zoom(0.3); window.__cwDebug.god(); });
    await raiseThree();
    await advance(1.2);
    await page.screenshot({ path: `${out}/0-thralls-plain.png`, clip: { x: 300, y: 130, width: 740, height: 300 } });
    await clearThralls();
    await advance(1.2);
    let tip = '';
    for (let n = 0; n < 40 && !tip; n++) {
      await advance(8);
      const titles = await page.locator('.cw-tip .title').allTextContents().catch(() => []);
      tip = titles.find((t) => /Spare gear for your legion/.test(t)) ?? '';
      if (!tip && titles.length) await page.locator('.cw-tip').first().click({ position: { x: 20, y: 40 } }).catch(() => {});
    }
    assert.match(tip, /Spare gear for your legion/, 'the counsel tip offers the Legion');
    await page.waitForTimeout(900);
    await shot('1-tip');
    await page.locator('.cw-tip').first().click({ position: { x: 20, y: 40 } }).catch(() => {});
    await page.keyboard.press('i');
    await page.waitForSelector('.cw-reliquary [data-legion]:not([hidden])');
    assert.match(await page.locator('[data-legion]').innerText(), /Legion/i);
    assert.ok(await page.locator('[data-legion].flag').count(), 'the button flags a spare that would help');
    await shot('2-reliquary');
    await fits('.cw-reliquary', 'Reliquary');

    console.log('STEP 2'); // 2. A bag weapon shows its Legion verdict in the detail strip; "Give to legion" moves it.
    const swordCell = await dbg(() => window.__cwDebug.inventory.all.find((s) => s.item_id === 'sword_copper').slot_index);
    await page.locator('.cw-bag-grid .cw-slot').nth(swordCell).click();
    const line = await page.locator('.cw-bag-detail .lg-line').innerText();
    assert.match(line, /Legion weapon: .*\+4\.0% thrall damage/);
    result.detailLine = line;
    await shot('3-detail-verdict');

    console.log('STEP 3'); // 3. The Legion panel (Y): empty slots, spares ranked best first with arrows.
    await page.keyboard.press('i');
    await page.keyboard.press('y');
    await page.waitForSelector('.lg-panel .lg-slot');
    assert.equal(await page.locator('.lg-slot.empty').count(), 2);
    const spares = await page.locator('.lg-row .lg-name').allTextContents();
    assert.deepEqual(spares.slice(0, 2).sort(), ['Iron Chestplate', 'Crypt-Iron Crozier'].sort(), 'the two best spares lead');
    assert.equal(await page.locator('.lg-row .lg-verdict.up').count(), spares.length, 'every spare is an upgrade over an empty slot');
    assert.equal(await page.locator('.lg-row').count(), 4, 'the list shows four');
    await shot('4-legion-empty');
    await fits('.lg-panel', 'Legion panel');
    const scroll = await page.locator('.lg-panel').evaluate((el) => ({ scroll: el.scrollHeight, client: el.clientHeight }));
    assert.ok(scroll.scroll <= scroll.client + 2, `the Legion panel needs no scrolling at 1280x800 (${JSON.stringify(scroll)})`);

    console.log('STEP 4'); // 4. Give the sword: it moves out of the bag into slot 120, new thralls hit 4% harder, the hero is untouched.
    // (The sword ranks sixth, below the five rows shown: give it from the Reliquary's detail strip instead.)
    assert.equal(await page.locator('.lg-row', { hasText: 'Copper Sword' }).count(), 0, 'the weakest spares are not listed');
    await page.keyboard.press('y');
    await page.keyboard.press('i');
    await page.locator('.cw-bag-grid .cw-slot').nth(swordCell).click();
    await page.locator('[data-legiongive]').click();
    await page.waitForFunction(() => window.__cwDebug.inventory.all.some((s) => s.slot_index === 120));
    await page.keyboard.press('i');
    await page.keyboard.press('y');
    await page.waitForSelector('.lg-panel .lg-slot');
    let r = await rows();
    assert.deepEqual(r.find((x) => x[0] === 120), [120, 'sword_copper', 1]);
    assert.ok(!r.some((x) => x[0] < 48 && x[1] === 'sword_copper'), 'left the bag');
    const s1 = await stats();
    assert.ok(Math.abs(s1.dmg / base.dmg - 1.04) < 0.002, `thrall damage +4% (${s1.dmg / base.dmg})`);
    assert.equal(Math.round(s1.maxHp), Math.round(base.maxHp), 'your health is untouched');
    assert.ok(Math.abs(s1.spell - base.spell) < 1e-6, 'your spell power is untouched');
    assert.match(await page.locator('.lg-slot[data-kit="weapon"] .lg-gives').innerText(), /Thralls hit \+4% harder/);
    assert.match(await page.locator('.lg-total').innerText(), /Thralls hit \+4% harder/);
    await shot('5-sword-given');

    console.log('STEP 5'); // 5. A better weapon swaps in and the sword returns to the bag (full-bag safe); a worse one shows a down arrow.
    await page.locator('.lg-row', { hasText: 'Crypt-Iron Crozier' }).locator('[data-give]').click();
    await page.waitForFunction(() => window.__cwDebug.inventory.all.find((s) => s.slot_index === 120)?.item_id === 'staff_iron');
    r = await rows();
    assert.ok(r.some((x) => x[0] < 48 && x[1] === 'sword_copper' && !x[2]), 'the sword is back in the bag, unequipped');
    const s2 = await stats();
    assert.ok(Math.abs(s2.dmg / base.dmg - 1.1) < 0.002, `iron staff +10% (${s2.dmg / base.dmg})`);
    const down = page.locator('.lg-row .lg-verdict.down', { hasText: 'thrall damage' }).first();
    assert.ok(await down.count(), 'a weaker weapon in the bag is now a down arrow against the Crozier');
    assert.match(await down.innerText(), /^▼ -[5-9]\.\d% thrall damage/);
    result.downVerdict = await down.innerText();

    console.log('STEP 6'); // 6. Armour: the iron chestplate goes to the armour slot; a smaller piece is a down arrow.
    await page.locator('.lg-row', { hasText: 'Iron Chestplate' }).locator('[data-give]').click();
    await page.waitForFunction(() => window.__cwDebug.inventory.all.some((s) => s.slot_index === 121));
    const s3 = await stats();
    assert.ok(Math.abs(s3.hp / base.hp - 1.132) < 0.003, `iron chestplate +13.2% thrall health (${s3.hp / base.hp})`);
    assert.ok(await page.locator('.lg-row', { hasText: 'Copper Plate' }).locator('.lg-verdict.down').count(), 'the copper plate is a down arrow against the iron chestplate');
    assert.ok(await page.locator('.lg-row', { hasText: 'Iron Helm' }).locator('.lg-verdict.down').count(), 'a helm (6 points) is below the chestplate (11)');
    await shot('6-both-slots');

    console.log('STEP 7'); // 7. Reinforce: the gold sink. Two tiers cost 120 + 198, raise the numbers, and the server-side rule is the same one.
    const gold0 = await dbg(() => window.__cwDebug.player ? window.__cwDebug.progression.character.gold : 0);
    await page.locator('[data-reinforce]').click();
    await page.locator('[data-reinforce]').click();
    const gold1 = await dbg(() => window.__cwDebug.progression.character.gold);
    assert.equal(gold0 - gold1, 120 + 198, 'two tiers cost 318 gold');
    assert.equal(await dbg(() => window.__cwDebug.progression.local.legionTier), 2);
    const s4 = await stats();
    assert.ok(Math.abs(s4.dmg / s2.dmg - 1.06) < 0.003, `tier 2 adds +6% damage (${s4.dmg / s2.dmg})`);
    assert.match(await page.locator('.lg-reinforce').innerText(), /tier 2 \/ 12/i);
    assert.match(await page.locator('.lg-reinforce').innerText(), /reinforce · 327g/i);
    await shot('7-reinforced');
    // Broke: the button disables and says why.
    await dbg(() => { const p = window.__cwDebug.progression; p.character.gold = 100; });
    await page.keyboard.press('y');
    await page.keyboard.press('y');
    await page.waitForSelector('.lg-panel');
    assert.ok(await page.locator('[data-reinforce]').isDisabled(), 'cannot afford');
    assert.match((await page.locator('[data-reinforce]').getAttribute('title')) ?? '', /227 more gold/);
    await dbg(() => { window.__cwDebug.progression.character.gold = 5000; });

    console.log('STEP 8'); // 8. The Character sheet names the legion and the numbers add up; the sheet opens while Legion is closed.
    await page.keyboard.press('y');
    await page.keyboard.press('j');
    await page.waitForSelector('.gs-sheet');
    await page.locator('[data-line="thrallDamage"]').click();
    const sheet = await page.locator('.gs-sheet').innerText();
    assert.match(sheet, /Legion kit/);
    assert.match(sheet, /Legion reinforcement/);
    await shot('8-sheet');
    await page.keyboard.press('j');

    console.log('STEP 9'); // 9. New thralls carry the stats (exhume intent) and the kit bow / staff / tint; thralls raised before keep theirs.
    await clearThralls();
    await advance(1.2);
    const before = await dbg(() => window.__cwDebug.sim().thralls.size);
    await raiseThree();
    await advance(1.2);
    const th = await dbg(() => [...window.__cwDebug.sim().thralls.values()].map((t) => ({ kind: t.kind, hp: t.maxHp, dmg: t.damage, interval: t.attackInterval })));
    assert.equal(th.length, before + 3);
    const mods = await dbg(() => window.__cwDebug.legion());
    const st = await stats();
    const archer = th.find((t) => t.kind === 'archer');
    assert.ok(Math.abs(archer.dmg - st.dmg * 0.85) < 0.01, `archer damage = thrall damage x0.85 (${archer.dmg} vs ${st.dmg * 0.85})`);
    assert.ok(Math.abs(archer.hp - st.hp * 0.7) < 0.5, 'archer health follows the legion');
    result.legion = { bonus: mods.bonus, tier: mods.tier, attackSpeedMult: mods.mods.thrallAttackSpeedMult, archer, newThrall: st };
    assert.ok(mods.mods.thrallAttackSpeedMult > 1.2 * 1.0299, 'attack speed folded into the discipline mods (Gravecaller 1.2 x iron staff 1.03 x tier 2)');
    // The kit props attach to the hands: wait for the GLBs, then count them in the scene graph.
    await page.waitForFunction(() => {
      let n = 0;
      window.__cwDebug.scene.traverse((o) => { if (o.userData?.model && /Hand$/.test(o.parent?.name ?? '')) n++; });
      return n >= 2;
    }, null, { timeout: 30000 });
    const props = await dbg(() => {
      const found = [];
      window.__cwDebug.scene.traverse((o) => { if (o.userData?.model && /Hand$/.test(o.parent?.name ?? '')) found.push(o.parent.name); });
      return found;
    });
    result.props = props;
    assert.ok(props.includes('L_Hand') && props.includes('R_Hand'), 'a GLB bow on the archer (L_Hand) and a GLB staff on the bone mage (R_Hand)');
    await page.screenshot({ path: `${out}/9-thralls-with-kit.png`, clip: { x: 300, y: 130, width: 740, height: 300 } });
    await shot('9b-thralls-with-kit-full');
    // A thrall raised BEFORE a change keeps its stats: take the weapon off and check the standing archer.
    await page.keyboard.press('y');
    await page.locator('[data-take="weapon"]').click();
    await page.waitForFunction(() => !window.__cwDebug.inventory.all.some((s) => s.slot_index === 120));
    const after = await dbg(() => [...window.__cwDebug.sim().thralls.values()].find((t) => t.kind === 'archer').damage);
    assert.equal(after, archer.dmg, 'standing thralls keep the stats they were raised with');
    const s5 = await stats();
    assert.ok(Math.abs(s5.dmg / base.dmg - 1.06) < 0.003, 'new thralls lose the weapon bonus, keep the tiers');
    await page.locator('.lg-row', { hasText: 'Crypt-Iron Crozier' }).locator('[data-give]').click();
    await page.waitForFunction(() => window.__cwDebug.inventory.all.some((s) => s.slot_index === 120));

    console.log('STEP 10'); // 10. A bag save never touches the kit; salvage and sell never see it; a refused take-off with a full bag changes nothing.
    await flush();
    const server = await dbg(async () => (await window.__api.getInventory(window.__cwDebug.inventory.characterId)).filter((s) => s.slot_index >= 100).map((s) => [s.slot_index, s.item_id, s.equipped]));
    assert.deepEqual(server.filter((x) => x[0] >= 120), [[120, 'staff_iron', 1], [121, 'chest_iron', 1]], 'the stored rows survive a bag save');
    await dbg(() => {
      const i = window.__cwDebug.inventory;
      const free = 48 - i.all.filter((s) => s.slot_index < 48).length;
      for (let n = 0; n < free; n++) i.add({ item_id: 'ring_copper', quantity: 1 });
    });
    await flush();
    await page.locator('[data-take="armor"]').click();
    await page.waitForFunction(() => /bag is full/i.test(document.querySelector('.lg-panel [data-error]')?.textContent ?? ''));
    result.refusal = await page.locator('.lg-panel [data-error]').innerText();
    assert.ok((await rows()).some((x) => x[0] === 121), 'the armour stays on the legion');
    await shot('10-full-bag-refusal');

    console.log('STEP 11'); // 11. The Codex describes it.
    await page.keyboard.press('y');
    await page.keyboard.press('k');
    await page.getByRole('button', { name: 'Item affixes' }).click();
    const codex = await page.locator('.cw-codex-entry', { hasText: 'The Legion kit' }).innerText();
    assert.match(codex, /Reinforce/);
    assert.match(codex, /Copper Sword/);
    await page.locator('.cw-codex-entry', { hasText: 'The Legion kit' }).scrollIntoViewIfNeeded();
    await shot('11-codex');
    await page.keyboard.press('k');

    assert.deepEqual(errors, [], 'No browser runtime errors');
    console.log(JSON.stringify(result, null, 1));
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
