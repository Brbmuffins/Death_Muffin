// Offline UI check for the legendary armor sets (items, set bonuses, tooltip, Character sheet, Codex, DEV giveLegendary, set glow).
//   npx vite --host 127.0.0.1 --port 5381 --strictPort
//   DM_QA_URL=http://127.0.0.1:5381/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_QA_ARTIFACT_DIR=/tmp/legendary-data node tools/qa/legendary-data-smoke.cjs
// Runs the whole flow at desktop 1280x800 (hover + double-click) and phone 390x844 (tap, select + Equip) and screenshots both.
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const SET = { id: 'legion_unburied', discipline: 'Gravecaller', name: 'Legion of the Unburied', prefix: 'leg_legion_unburied_' };
const PARTS = ['head', 'chest', 'hands', 'legs', 'feet'];

async function run(browser, label, ctxOptions, phone) {
  let page;
  try { return await run1(browser, label, ctxOptions, phone, (p) => { page = p; }); } catch (e) { if (page) await page.screenshot({ path: `${process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-legendary-data'}/${label}-FAIL.png` }).catch(() => {}); throw e; }
}

async function run1(browser, label, ctxOptions, phone, setPage) {
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-legendary-data';
  mkdirSync(out, { recursive: true });
  const ctx = await browser.newContext(ctxOptions);
  ctx.setDefaultTimeout(90000);
  const page = await ctx.newPage();
  setPage(page);
  ctx.setDefaultTimeout(phone ? 25000 : 90000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5381/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `leg_${label}_${Date.now() % 100000}`);
  await page.fill('#cw-email', 'leg@example.invalid');
  await page.fill('#cw-pass', 'TestingLegendary1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: SET.discipline }).first().click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });

  // The set's numbers come from the game's own table (and are pinned against the design doc by the unit tests).
  const BON = await page.evaluate(async () => (await import('/src/content/setBonuses.ts')).SET_BONUSES.legion_unburied);
  const at = (n) => BON.filter((b) => b.pieces <= n);
  const multAt = (n, k) => at(n).reduce((m, b) => m * ((b.effect.mult || {})[k] ?? 1), 1);
  const addAt = (n, k) => at(n).reduce((a, b) => a + ((b.effect.add || {})[k] ?? 0), 0);
  const mods = () => page.evaluate(async () => {
    const m = (await import('/src/app/GameRuntime.ts')).getRuntime().view.discipline.mods;
    const keys = ['thrallDamageMult', 'thrallCap', 'thrallDeathBurst', 'championEvery', 'spearRally', 'wardReflect', 'soulHarvestRateMult'];
    return Object.fromEntries(keys.map((k) => [k, m[k]]));
  });
  const base = await mods();
  assert.equal(base.thrallDeathBurst, 0, 'mechanics start off');

  // DEV helper: all five pieces in the bag.
  const given = await page.evaluate((s) => window.__cwDebug.giveLegendary(s), SET.id);
  assert.deepEqual(given, PARTS.map((p) => SET.prefix + p));
  await page.evaluate(() => window.__cwDebug.advance(1));
  await page.keyboard.press('i');
  await page.waitForSelector('.cw-bag-grid');

  const bagOf = (id) => page.evaluate((i) => window.__cwDebug.inventory.all.find((s) => s.item_id === i)?.slot_index, id);
  const wornCount = () => page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => s.equipped).length);
  const cell = async (id) => page.locator('.cw-bag-grid .cw-slot').nth(await bagOf(id));
  const wear = async (part) => {
    const before = await wornCount();
    const c = await cell(SET.prefix + part);
    if (phone) {
      // A tap on a piece that is already selected deselects it, so retry until the detail shows the Equip button for THIS piece.
      for (let i = 0; i < 4; i++) {
        await c.tap();
        if (await page.locator('[data-detail] [data-act]').first().waitFor({ timeout: 3000 }).then(() => true, () => false)) break;
      }
      await page.locator('[data-detail] [data-act]').first().tap();
    } else await c.dblclick();
    await page.waitForFunction((n) => window.__cwDebug.inventory.all.filter((s) => s.equipped).length === n, before + 1);
    await page.waitForTimeout(150);
  };
  const detailText = async () => (await page.locator('[data-detail]').innerText()) + (await page.locator('.cw-tooltip').allInnerTexts().catch(() => [])).join('\n');
  const look = async (id) => { const c = await cell(id); if (phone) await c.tap(); else await c.hover(); await page.waitForTimeout(200); };

  // Piece data: legendary rarity, the amber mark, the set tracker "0 / 5".
  await look(SET.prefix + 'chest');
  let t = await detailText();
  assert.match(t, /Cuirass of the Unburied/);
  assert.match(t, /legendary armor chest/i);
  assert.match(t, /Legion of the Unburied/);
  assert.match(t, /0 \/ 5 worn/);
  const color = await page.evaluate(() => getComputedStyle(document.querySelector('[data-detail] .name, .cw-tooltip .name')).color);
  assert.equal(color, 'rgb(255, 154, 46)', 'legendary amber name colour');
  await page.screenshot({ path: `${out}/${label}-1-piece-tooltip.png` });

  await wear('head');
  await wear('chest');
  let m2 = await mods();
  assert.ok(Math.abs(m2.thrallDamageMult - base.thrallDamageMult * multAt(2, 'thrallDamageMult')) < 1e-9, '2-piece: thralls +25%');
  assert.equal(m2.thrallDeathBurst, 0, 'no burst at 2');
  await look(SET.prefix + 'hands');
  t = await detailText();
  assert.match(t, /2 \/ 5 worn/);
  assert.match(t, /Thralls hit \+25% harder/);
  assert.match(t, /Bursting Dead/);

  await wear('hands');
  await wear('legs');
  const m4 = await mods();
  assert.ok(Math.abs(m4.thrallDeathBurst - addAt(4, 'thrallDeathBurst')) < 1e-9 && m4.thrallDeathBurst === 0.8, '4-piece: death burst 0.8');
  assert.equal(m4.championEvery, 0, 'champions need 5');
  await look(SET.prefix + 'feet');
  t = await detailText();
  assert.match(t, /4 \/ 5 worn/);
  assert.match(t, /Thralls burst when they die \(80% of their health/);
  await page.screenshot({ path: `${out}/${label}-2-tooltip-four-pieces.png` });

  // Four pieces: the set glow is on (a uniform on the body regions).
  const glow4 = await page.evaluate(() => window.__cwDebug.avatar.c.gearTint.glow.map((g) => +(g.x + g.y + g.z).toFixed(3)));
  assert.ok(glow4.some((v) => v > 0), `set glow at 4 pieces: ${glow4}`);

  await wear('feet');
  const m5 = await mods();
  assert.equal(m5.thrallCap, base.thrallCap + 2, '5-piece: +2 thrall cap');
  assert.equal(m5.championEvery, 4);
  assert.equal(m5.spearRally, 1);
  assert.ok(Math.abs(m5.thrallDamageMult - base.thrallDamageMult * 1.25) < 1e-9);

  // Character sheet: the set is listed, 5 / 5, all three tiers active, in plain words.
  if (phone) await page.locator('.cw-equip-sheet').tap(); else await page.locator('.cw-equip-sheet').click();
  await page.locator('.gs-sheet').waitFor();
  const sheet = await page.locator('.gs-sheet').innerText();
  assert.match(sheet, /set bonuses/i);
  assert.match(sheet, /legion of the unburied/i);
  assert.match(sheet, /5 \/ 5/);
  assert.match(sheet, /Every 4th thrall you raise is a Champion/);
  assert.equal(await page.locator('.gs-line.set .r.up').count(), 3, 'all three tiers active');
  await page.locator('.gs-line.set').first().scrollIntoViewIfNeeded();
  await page.screenshot({ path: `${out}/${label}-3-character-sheet.png` });

  // Codex: Armor sets tab has a Legendary section with all four sets.
  await page.keyboard.press('Escape');
  await page.locator('.gs-sheet').waitFor({ state: 'hidden' });
  if (phone) { await page.locator('.hud-menu [data-menu]').tap(); await page.locator('.hud-menusheet [data-open="codex"]').tap(); } else await page.keyboard.press('k');
  await page.locator('[data-tab="sets"]').click();
  const codex = await page.locator('[role="dialog"][aria-label="Codex"]').innerText();
  assert.match(codex, /Legendary sets/i);
  for (const n of ['Legion of the Unburied', 'Colossus Mantle', 'Requiem of Wraiths', 'Plague Choir', 'Chain Plague', 'Area bosses']) assert.ok(codex.toLowerCase().includes(n.toLowerCase()), `${n} in the Codex`);
  await page.locator('.cw-codex-section').scrollIntoViewIfNeeded();
  await page.screenshot({ path: `${out}/${label}-4-codex-legendary.png` });

  assert.deepEqual(errors, []);
  await ctx.close();
  return { label, glow4 };
}

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const results = [];
    if (process.env.DM_QA_ONLY !== 'phone') results.push(await run(browser, 'desktop', { viewport: { width: 1280, height: 800 } }, false));
    if (process.env.DM_QA_ONLY !== 'desktop') results.push(await run(browser, 'phone', { viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true }, true));
    console.log(JSON.stringify(results));
  } finally { await browser.close(); }
})().catch((e) => { console.error(e); process.exitCode = 1; });
