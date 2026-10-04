// Phone vs desktop co-existence smoke: Back-to-Menu, AFK surviving menus/panels, bag item card/tooltip.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL=http://127.0.0.1:5385/?offline node tools/qa/phone-nav-smoke.cjs
// Runs every profile: desktop 1280x800 (mouse), phone 390x844 (touch), tablet 1024x768 (touch).
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { SWIFTSHADER_ARGS, watchErrors, preloadModules } = require('./lib/qa-common.cjs');
const OUT = process.env.DM_QA_ARTIFACT_DIR || '/tmp/phone-nav-shots';
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5385/?offline';
const ALL_PROFILES = [
  { name: 'desktop', opts: { viewport: { width: 1280, height: 800 } }, touch: false, menu: false },
  { name: 'phone', opts: { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }, touch: true, menu: true },
  { name: 'tablet', opts: { viewport: { width: 1024, height: 768 }, hasTouch: true }, touch: true, menu: false },
];
const PROFILES = ALL_PROFILES.filter((p) => !process.env.PN_ONLY || process.env.PN_ONLY.split(',').includes(p.name));
const results = [];
const note = (p, k, v) => results.push({ profile: p, check: k, result: v });

async function run(browser, P) {
  const ctx = await browser.newContext(P.opts); ctx.setDefaultTimeout(20000);
  const page = await ctx.newPage();
  const { errors } = watchErrors(page);
  if (process.env.PN_DEBUG) page.on('console', (m) => console.log('  [console]', m.text().slice(0, 200)));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false, autoGather: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `pn_${P.name}${Date.now() % 10000}`); await page.fill('#cw-email', 't@example.invalid'); await page.fill('#cw-pass', 'TestingControls');
  await page.locator('#cw-login-btn').click(); await page.locator('.cw-disc').first().click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await preloadModules(page, { loot: '/src/gameplay/loot.ts' });
  page.on('framenavigated', (f) => console.log(P.name, 'NAV', f.url()));
  const L = (m) => console.log(P.name, m);
  const frame = () => page.evaluate(() => window.__cwDebug.advance(0.1, false));
  const press = async (sel) => { const l = page.locator(sel).first(); await (P.touch ? l.tap({ force: true }) : l.click({ force: true })); await frame(); };
  const title = async () => { await frame(); return page.evaluate(() => [...document.querySelectorAll('.cw-panel-float')].find((e) => e.offsetParent)?.querySelector('.cw-title,h2')?.textContent?.trim() ?? null); };
  const hasBack = () => page.locator('[data-back]').count();
  const menuVisible = () => page.locator('.hud-menusheet').isVisible();
  const afk = () => page.evaluate(() => window.__cwDebug.gathering().afk);
  const openViaMenu = async (k) => { if (!(await menuVisible())) await press('.hud-menu [data-menu]'); assert.ok(await menuVisible(), 'menu opens'); await press(`.hud-menusheet [data-open="${k}"]`); };
  const compact = P.menu;

  L('afk');
  await page.keyboard.press('p');
  await page.getByRole('button', { name: 'Start AFK Woodcutting', exact: true }).click();
  await page.waitForFunction(() => window.__cwDebug.gathering().afk);
  await page.waitForFunction(() => { window.__cwDebug.advance(0.2, false); return window.__cwDebug.gathering().working; }, null, { timeout: 30000, polling: 300 });
  await page.keyboard.press('Escape'); await frame();
  assert.ok(await afk(), 'afk started');
  if (compact) {
    await press('.hud-menu [data-menu]'); assert.ok(await menuVisible()); assert.ok(await afk(), 'AFK survives opening Menu');
    await press('.hud-menusheet [data-menuclose]'); assert.ok(!(await menuVisible())); assert.ok(await afk(), 'AFK survives closing Menu');
    for (const k of ['inventory', 'professions', 'codex']) {
      await openViaMenu(k); assert.ok(await afk(), `AFK survives ${k} via Menu`);
      assert.equal(await hasBack(), 1, `${k} from Menu shows Back`);
      await press('[data-back]'); assert.ok(await menuVisible(), `Back from ${k} returns to Menu`); assert.equal(await title(), null);
      assert.ok(await afk(), `AFK survives Back from ${k}`);
      await press('.hud-menusheet [data-menuclose]');
    }
    note(P.name, 'AFK through Menu open/close, Inventory/Skills/Codex + Back', 'pass');
  } else {
    for (const key of ['i', 'j', 'c']) {
      await page.keyboard.press(key); assert.ok(await title(), `${key} opens a panel`); assert.equal(await hasBack(), 0, 'hotkey panel has no Back');
      assert.ok(await afk(), `AFK survives hotkey ${key}`);
      await page.keyboard.press(key); assert.equal(await title(), null, `${key} toggles it shut`);
    }
    await page.keyboard.press('i'); await page.keyboard.press('Escape'); assert.equal(await title(), null, 'Esc closes'); assert.ok(await afk());
    note(P.name, 'hotkeys I/J/C toggle, Esc closes, no Back, AFK survives', 'pass');
  }
  L('nav');
  if (compact) {
    // Skills/Garden/Contracts are tabs of the Acre ledger window now; nesting is a different panel opened on top of it (Codex, key K).
    await openViaMenu('professions'); const acre = await title(); assert.match(acre, /Acre ledger/);
    await page.keyboard.press('k'); await frame(); const codex = await title(); assert.ok(codex && codex !== acre, 'Codex opens on top');
    assert.equal(await hasBack(), 1);
    await page.goBack(); await frame(); assert.equal(await title(), acre, 'system back: Codex -> Acre ledger');
    await page.goBack(); await frame(); assert.ok(await menuVisible(), 'system back: Acre ledger -> Menu'); assert.equal(await title(), null);
    await page.goBack(); await frame(); assert.ok(!(await menuVisible()), 'system back: Menu -> closed');
    const u = page.url(); assert.ok(u.includes('127.0.0.1'), 'still in game');
    await openViaMenu('inventory'); await press('.cw-panel-float [data-close]'); assert.equal(await title(), null); assert.ok(!(await menuVisible()), 'Close exits fully, no Menu');
    assert.ok(await afk());
    note(P.name, 'nested Back, system Back: nested->parent->Menu->closed; Close exits', 'pass');
  } else {
    await page.keyboard.press('p'); await frame(); const acre = await title(); assert.match(acre, /Acre ledger/);
    await page.keyboard.press('k'); await frame(); assert.notEqual(await title(), acre); assert.equal(await hasBack(), 1, 'nested Back on desktop');
    await press('[data-back]'); assert.equal(await title(), acre); assert.equal(await hasBack(), 0, 'no Menu-return Back on desktop');
    await page.keyboard.press('Escape'); assert.ok(await afk());
    note(P.name, 'nested Back works; top-level panel has no Back', 'pass');
  }

  L('bag');
  await page.evaluate(async () => { const d = window.__cwDebug; for (const id of ['helm_copper', 'helm_iron', 'chest_iron', 'staff_gold']) d.inventory.add({ item_id: id, quantity: 1 }); await d.inventory.flush(); d.advance(0.5, false); });
  if (compact) await openViaMenu('inventory'); else { await page.keyboard.press('i'); await frame(); }
  const idx = await page.evaluate(() => window.__cwDebug.inventory.all.find((s) => s.item_id === 'helm_iron').slot_index);
  const cell = page.locator('.cw-bag-grid .cw-slot').nth(idx);
  if (P.touch) {
    await cell.tap({ force: true }); await frame();
    assert.equal(await page.locator('.cw-tooltip').first().isVisible(), false, 'no floating tooltip on touch tap');
    const card = page.locator('.cw-bag-detail .info'); assert.ok(await card.isVisible(), 'item card visible after tap');
    const text = await card.innerText(); assert.match(text, /VIT|STR|Armor|Health|\+\d/i, 'card shows stats');
    const vp = page.viewportSize();
    const cb = await card.boundingBox(); assert.ok(cb.y >= 0 && cb.y + cb.height <= vp.height + 1, 'card on screen');
    const btns = await page.locator('.cw-detail-actions .cw-button').all(); assert.ok(btns.length >= 2, 'action buttons present');
    for (const b of btns) {
      const bb = await b.boundingBox(); assert.ok(bb.y >= 0 && bb.y + bb.height <= vp.height + 1, 'button on screen');
      if (compact) assert.ok(bb.height >= 44, `button >=44px tall (${bb.height})`);
      assert.ok(bb.x + bb.width <= cb.x || bb.x >= cb.x + cb.width || bb.y >= cb.y + cb.height || bb.y + bb.height <= cb.y, 'card does not overlap buttons');
      const hit = await page.evaluate(({ x, y }) => { const e = document.elementFromPoint(x, y); return !!e?.closest('.cw-detail-actions'); }, { x: bb.x + bb.width / 2, y: bb.y + bb.height / 2 });
      assert.ok(hit, 'button is not covered by anything');
    }
    await page.screenshot({ path: `${OUT}/${P.name}-bag-card.png` });
    if (compact) {
      await page.locator('[data-detailclose]').tap({ force: true }); await frame();
      assert.equal(await page.locator('.cw-bag-detail .info').count(), 0, 'X dismisses the card');
    } else await cell.tap({ force: true });
    await frame();
    await cell.tap({ force: true }); await frame(); await cell.tap({ force: true }); await frame();
    assert.equal(await page.locator('.cw-bag-detail .info').count(), 0, 'tapping the item again dismisses');
    if (compact) {
      await cell.tap({ force: true }); await frame(); await page.locator('.cw-stats-line').tap({ force: true }); await frame();
      assert.equal(await page.locator('.cw-bag-detail .info').count(), 0, 'tapping elsewhere dismisses');
    }
    // equip through the card still works
    await cell.tap({ force: true }); await frame(); await page.locator('.cw-detail-actions [data-act]').tap({ force: true });
    await page.waitForFunction(() => window.__cwDebug.inventory.all.some((s) => s.item_id === 'helm_iron' && s.equipped));
    note(P.name, 'tap shows card w/ stats, no overlap w/ actions, dismiss x3, Equip works', 'pass');
  }
  if (!P.touch || P.name === 'tablet') {
    await page.mouse.move(5, 5);
    const hidx = await page.evaluate(() => window.__cwDebug.inventory.all.find((x) => x.item_id === 'chest_iron').slot_index);
    await page.mouse.move(5, 5); await frame();
    await page.locator('.cw-bag-grid .cw-slot').nth(hidx).hover(); await frame();
    assert.ok(await page.locator('.cw-tooltip').first().isVisible(), 'hover tooltip appears without a click');
    assert.equal(await page.locator('.cw-bag-detail .info').count(), 0, 'hover alone does not select');
    await page.screenshot({ path: `${OUT}/${P.name}-bag-hover.png` });
    note(P.name, 'mouse hover tooltip, no click needed', 'pass');
  }
  // Deliberate movement still ends AFK (panels closed first so the minimap move is accepted).
  for (let i = 0; i < 3 && (await title()); i++) await page.keyboard.press('Escape');
  if (await menuVisible()) await press('.hud-menusheet [data-menuclose]');
  assert.equal(await title(), null, 'all panels closed');
  if (!(await afk())) { /* AFK is allowed to have ended on its own (bag full etc.); the survival asserts above already ran */ }
  else {
    const moved = await page.evaluate(() => { const v = window.__qaMods.runtime.getRuntime().view; return v.navigateFromMinimap(v.player.x + 8, v.player.z + 1); });
    if (!moved) console.log(await page.evaluate(() => JSON.stringify({ g: window.__cwDebug.gathering(), panels: [...document.querySelectorAll('.cw-panel-float')].map((e) => [e.className, !!e.offsetParent]), area: window.__cwDebug.avatar?.area })));
    assert.ok(moved, 'minimap move accepted');
    await page.evaluate(() => window.__cwDebug.advance(0.3, false));
    assert.equal(await afk(), false, 'moving stops AFK');
    note(P.name, 'moving ends AFK', 'pass');
  }
  await page.screenshot({ path: `${OUT}/${P.name}-final.png` });
  assert.deepEqual(errors, []);
  await ctx.close();
}

(async () => {
  mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: SWIFTSHADER_ARGS });
  try { for (const P of PROFILES) { await run(browser, P); console.log('ok', P.name); } } finally { await browser.close(); }
  console.table(results);
})().catch((e) => { console.error(e); process.exit(1); });
