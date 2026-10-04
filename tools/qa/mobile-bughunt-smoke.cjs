// Mobile bug-hunt smoke (touch emulated, sizes 360x640 / 390x844 / 768x1024 / 844x390). One assertion block per bug that was fixed:
//   menu     every panel has a touch path (Menu button + sheet tile) at phone AND tablet sizes, tiles >= 40 px;
//   atlas    the Gear Atlas is a single readable column on a phone (names not squeezed to a few px), Back returns to the list;
//   ...      (further blocks are added below as they land; see docs/polish/mobile-bug-hunt.md)
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL=http://127.0.0.1:5461/?offline [DM_ONLY=menu,atlas] node tools/qa/mobile-bughunt-smoke.cjs
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { VIRTUAL_TIMERS, newCharacter, step } = require('./lib/first-hour-lib.cjs');

const SIZES = { 'phone-s': [360, 640], 'phone-p': [390, 844], 'tablet-p': [768, 1024], 'phone-l': [844, 390] };
const ONLY = (process.env.DM_ONLY || '').split(',').filter(Boolean);
const want = (k) => !ONLY.length || ONLY.includes(k);

async function session(browser, size, discipline, fn, settings = {}) {
  const [w, h] = SIZES[size];
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, isMobile: true, hasTouch: true, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript(VIRTUAL_TIMERS);
  await page.addInitScript((s) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false, ...s })), settings);
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5461/?offline');
  await newCharacter(page, discipline, `bh${size.replace('-', '')}${Date.now() % 10000}`);
  await step(page, 2);
  await page.evaluate(() => { window.__cwDebug.god?.(); window.__cwDebug.unlockAll?.(); });
  await step(page, 1);
  const frame = () => page.evaluate(() => window.__cwDebug.advance(0.05));
  const openPanel = async () => [...document.querySelectorAll('.cw-panel-float')].find((e) => e.offsetParent);
  try { await fn({ page, ctx, w, h, frame, size }); } finally { await ctx.close(); }
  assert.deepEqual(errors, [], `page errors at ${size}`);
}
const panelOpen = (page) => page.evaluate(() => !![...document.querySelectorAll('.cw-panel-float')].find((e) => e.offsetParent));
const settle = async (page, pred, tries = 12) => { for (let i = 0; i < tries; i++) { await step(page, 0.3); if (await page.evaluate(pred)) return true; await page.waitForTimeout(250); } return false; };

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const done = [];
  try {
    if (want('menu')) for (const size of ['phone-p', 'tablet-p']) await session(browser, size, 'Ossuary', async ({ page, frame }) => {
      // A Menu button exists and every sheet tile is a >= 40 px target; each tile opens its panel; the phone Back closes it.
      const btn = page.locator('.hud-menu [data-menu]');
      assert.ok(await btn.isVisible(), `${size}: Menu button visible`);
      const bb = await btn.boundingBox();
      assert.ok(bb.width >= 40 && bb.height >= 36, `${size}: Menu button size ${bb.width}x${bb.height}`);
      const keys = await page.evaluate(() => [...document.querySelectorAll('.hud-menusheet [data-open]')].map((t) => t.dataset.open));
      for (const need of ['sheet', 'contracts', 'garden', 'labor', 'legion', 'cosmetics', 'vault', 'atlas', 'grimoire']) assert.ok(keys.includes(need), `${size}: Menu has ${need}`);
      for (const k of keys) {
        await btn.tap(); await frame();
        const tile = page.locator(`.hud-menusheet [data-open="${k}"]`);
        const tb = await tile.boundingBox();
        assert.ok(tb && tb.width >= 40 && tb.height >= 40, `${size}: ${k} tile ${tb && tb.width}x${tb && tb.height}`);
        assert.ok(tb.x >= 0 && tb.x + tb.width <= SIZES[size][0] && tb.y >= 0 && tb.y + tb.height <= SIZES[size][1], `${size}: ${k} tile on screen`);
        await tile.tap();
        assert.ok(await settle(page, () => !![...document.querySelectorAll('.cw-panel-float')].find((e) => e.offsetParent)), `${size}: ${k} opens`);
        await page.goBack(); await step(page, 0.3);
        assert.ok(!(await panelOpen(page)), `${size}: phone Back closes ${k}`);
        // Back from a panel opened on the Menu returns to the Menu (phone-nav); close it so the next tile starts clean.
        if (await page.evaluate(() => !!document.querySelector('.hud-menusheet') && !document.querySelector('.hud-menusheet').hidden)) await page.locator('.hud-menusheet [data-menuclose]').tap();
      }
      done.push(`menu@${size}`);
    });
    if (want('atlas')) for (const size of ['phone-s', 'phone-l']) await session(browser, size, 'Ossuary', async ({ page, frame, w }) => {
      await page.locator('.hud-menu [data-menu]').tap(); await frame();
      await page.locator('.hud-menusheet [data-open="atlas"]').tap();
      assert.ok(await settle(page, () => !!document.querySelector('.cw-atlas .at-row')), 'atlas rows render');
      const m = await page.evaluate(() => {
        const row = document.querySelector('.cw-atlas .at-row'); const nm = row.querySelector('.at-name'); const panel = document.querySelector('.cw-atlas');
        const d = document.querySelector('.cw-atlas .at-detail');
        return { rowW: row.getBoundingClientRect().width, rowH: row.getBoundingClientRect().height, nameW: nm.clientWidth, panelW: panel.clientWidth, detailShown: d.offsetParent !== null, sx: panel.scrollWidth - panel.clientWidth };
      });
      assert.ok(m.nameW >= 90, `${size}: item names readable (${m.nameW}px)`);
      assert.ok(m.rowW >= m.panelW * 0.85, `${size}: list uses the width (${m.rowW}/${m.panelW})`);
      assert.ok(m.rowH >= 40, `${size}: rows are tap targets (${m.rowH})`);
      assert.equal(m.detailShown, false, `${size}: detail pane hidden until an item is tapped`);
      assert.ok(m.sx <= 2, `${size}: no sideways scroll (${m.sx})`);
      await page.locator('.cw-atlas .at-row').first().tap(); await step(page, 0.3);
      assert.ok(await page.evaluate(() => document.querySelector('.cw-atlas .at-detail').offsetParent !== null), `${size}: tap opens the detail`);
      await page.locator('.cw-atlas [data-back]').first().tap(); await step(page, 0.3);
      assert.ok(await page.evaluate(() => document.querySelector('.cw-atlas .at-list').offsetParent !== null), `${size}: Back returns to the list`);
      done.push(`atlas@${size}`);
    });
    if (want('targets')) for (const size of ['phone-s', 'phone-p']) await session(browser, size, 'Ossuary', async ({ page, frame, w }) => {
      // Panel controls are >= 40 px tall and nothing in Settings runs past the panel's right edge.
      const open = async (k) => { if (!(await page.evaluate(() => { const m = document.querySelector('.hud-menusheet'); return !!m && !m.hidden; }))) { await page.locator('.hud-menu [data-menu]').tap(); await frame(); } await page.locator(`.hud-menusheet [data-open="${k}"]`).tap(); await step(page, 0.4); };
      const small = (sel) => page.evaluate((q) => [...document.querySelectorAll(`.cw-panel-float ${q}`)].filter((e) => e.offsetParent).map((e) => e.getBoundingClientRect()).filter((r) => r.height < 39.5 || r.width < 39.5).length, sel);
      await open('settings');
      const over = await page.evaluate(() => { const p = document.querySelector('.cw-panel-float').getBoundingClientRect(); return [...document.querySelectorAll('.cw-panel-float *')].filter((e) => e.offsetParent && e.getBoundingClientRect().right > p.right + 1 && e.getBoundingClientRect().left < p.right).map((e) => e.tagName + '.' + e.className).slice(0, 4); });
      assert.deepEqual(over, [], `${size}: Settings content inside the panel`);
      assert.equal(await small('select'), 0, `${size}: Settings dropdowns >= 40 px`);
      await page.goBack(); await step(page, 0.3);
      await open('grimoire');
      assert.equal(await small('.cw-grim-key, .cw-chip'), 0, `${size}: Grimoire keys and filters >= 40 px`);
      const gOver = await page.evaluate(() => { const p = document.querySelector('.cw-panel-float'); const r = p.getBoundingClientRect(); return [...p.querySelectorAll('*')].filter((e) => e.offsetParent && e.getBoundingClientRect().right > r.right + 1 && e.getBoundingClientRect().left < r.right).map((e) => e.className).slice(0, 4); });
      assert.deepEqual(gOver, [], `${size}: the 40 px Grimoire keys stay inside the panel`);
      await page.goBack(); await step(page, 0.3);
      await open('vault');
      assert.equal(await small('.cw-vault-tabs button, .cw-button'), 0, `${size}: Vault tabs and buttons >= 40 px`);
      await page.goBack(); await step(page, 0.3);
      await open('inventory');
      assert.equal(await small('.cw-button'), 0, `${size}: Reliquary buttons >= 40 px`);
      await page.goBack(); await step(page, 0.3);
      await page.evaluate(async () => { const { getRuntime } = await import('/src/app/GameRuntime.ts'); getRuntime().view.togglePanel('ascension'); });
      await step(page, 0.5);
      assert.equal(await small('.cw-button'), 0, `${size}: Altar of Ascension buttons >= 40 px`);
      done.push(`targets@${size}`);
    });
    if (want('hud')) for (const size of ['phone-p', 'tablet-p', 'phone-l']) await session(browser, size, 'Ossuary', async ({ page }) => {
      // HUD buttons a thumb must hit: Menu, full-screen, flask, upgrades, Spells (tablet) and the wave dial are >= 40 px; no HUD overlaps.
      const small = await page.evaluate(() => [...document.querySelectorAll('.hud-menubtn, .hud-fullscreen, .hud-flask, .hud-up-toggle, .hud-up .buy, [data-dial]')]
        .filter((e) => e.offsetParent).map((e) => [e.className.toString().split(' ')[0] || e.dataset.dial, e.getBoundingClientRect()]).filter(([, r]) => r.height < 39.5 || r.width < 39.5).map(([n, r]) => `${n} ${Math.round(r.width)}x${Math.round(r.height)}`));
      assert.deepEqual(small, [], `${size}: HUD buttons >= 40 px`);
      done.push(`hud@${size}`);
    });
    if (want('taps')) for (const size of ['phone-p', 'phone-l']) await session(browser, size, 'Ossuary', async ({ page, frame, w, h }) => {
      // Nothing decorative swallows a tap meant for the game: floating numbers, and the empty middle of the currency/Upgrades strip.
      const hit = await page.evaluate(async () => {
        const { getRuntime } = await import('/src/app/GameRuntime.ts');
        const v = getRuntime().view;
        v.floating.spawn(v.player.x, 1.5, v.player.z, '1234', 'crit');
        window.__cwDebug.advance(0.1);
        const n = document.querySelector('.cw-num'); const r = n.getBoundingClientRect();
        const top = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
        const strip = document.querySelector('.hud-right'); const sr = strip.getBoundingClientRect();
        const mid = document.elementFromPoint(sr.left + sr.width / 2, sr.top + sr.height / 2);
        return { num: top && (top.id || top.className), mid: mid && (mid.id || mid.className), wide: sr.width > innerWidth * 0.6 };
      });
      assert.equal(hit.num, 'scene', `${size}: a floating number lets the tap through (${hit.num})`);
      if (hit.wide) assert.equal(hit.mid, 'scene', `${size}: the middle of the HUD strip lets the tap through (${hit.mid})`);
      done.push(`taps@${size}`);
    });
    if (want('picker')) for (const size of ['phone-s', 'phone-p', 'phone-l']) {
      // Discipline picker on a phone: the Recommended badge and the NECROMANCER tag do not overlap, nothing runs past the card.
      const [w, h] = SIZES[size];
      const ctx = await browser.newContext({ viewport: { width: w, height: h }, isMobile: true, hasTouch: true });
      const page = await ctx.newPage();
      await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false })));
      await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5461/?offline');
      await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
      await page.fill('#cw-user', `pk${size.replace('-', '')}${Date.now() % 100000}`); await page.fill('#cw-email', 'a@example.invalid'); await page.fill('#cw-pass', 'TestingFirstHour1');
      await page.locator('#cw-login-btn').tap(); await page.waitForSelector('.cw-disc.recommended'); await page.waitForTimeout(500);
      const m = await page.evaluate(() => {
        const card = document.querySelector('.cw-disc.recommended'); const c = card.getBoundingClientRect();
        const b = card.querySelector('.rec-badge').getBoundingClientRect(); const l = card.querySelector('.legacy').getBoundingClientRect();
        return { overlap: !(b.right <= l.left || l.right <= b.left || b.bottom <= l.top || l.bottom <= b.top), badgeInside: b.left >= c.left - 1 && b.right <= c.right + 1, docSW: document.documentElement.scrollWidth, vw: innerWidth };
      });
      assert.equal(m.overlap, false, `${size}: Recommended badge covers the family tag`);
      assert.ok(m.badgeInside, `${size}: badge inside its card`);
      assert.ok(m.docSW <= m.vw + 1, `${size}: picker has no sideways scroll`);
      await ctx.close();
      done.push(`picker@${size}`);
    }
    if (want('next')) for (const size of ['phone-s', 'phone-p', 'phone-l']) await session(browser, size, 'Ossuary', async ({ page, frame }) => {
      // The minimap column's "Next" line (here the soul-shard hint of the Hollow Graves): portrait shows all of it, landscape grows
      // without running into the Menu/Upgrades buttons below it.
      await page.evaluate(() => { const d = window.__cwDebug; d.goto('graves'); d.advance(2); d.advance(2); d.guidance.refresh(); d.advance(1); });
      const m = await page.evaluate(() => {
        const t = document.querySelector('[data-nexttxt]'); const menu = document.querySelector('.hud-menu').getBoundingClientRect(); const up = document.querySelector('.hud-up-toggle').getBoundingClientRect();
        return { text: t.textContent, clipped: t.scrollHeight > t.clientHeight + 1, menuBottom: menu.bottom, upTop: up.top, upLeft: up.left, menuLeft: menu.left, menuRight: menu.right, upRight: up.right };
      });
      assert.ok(m.text.length > 20, `${size}: a Next line shows (${m.text})`);
      if (size !== 'phone-l') assert.equal(m.clipped, false, `${size}: Next line is not cut off ("${m.text}")`);
      else assert.ok(m.menuBottom <= m.upTop + 1 || m.upRight < m.menuLeft || m.upLeft > m.menuRight, `${size}: Menu row (${m.menuBottom}) stays clear of Upgrades (${m.upTop})`);
      done.push(`next@${size}`);
    });
    if (want('contracts')) for (const size of ['phone-s', 'phone-p']) await session(browser, size, 'Ossuary', async ({ page, frame }) => {
      // A day whose hard order is a relic (trade-goods) order: every order card holds its DELIVER button, the name is not squeezed
      // into a few letters per line, and the skill tag does not sit on the name.
      const t = await page.evaluate(async () => {
        const cr = await import('/src/gameplay/contractRules.ts'); const v = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
        const lv = {}; for (const k of ['woodcutting', 'mining', 'fishing', 'herbalism', 'smithing', 'carpentry', 'alchemy', 'cooking', 'gardening', 'gravedigging', 'forestry']) lv[k] = 99;
        for (let d = 0; d < 400; d++) { const at = Date.now() + d * 86400000; if (cr.generateBoard(v.character.id, cr.dayKey(at), lv).some((c) => cr.orderInfo(c.itemId)?.relicQty)) { for (const k of Object.keys(lv)) window.__cwDebug.skill(k, 99); Date.now = () => at; return at; } }
        return null;
      });
      assert.ok(t, 'a relic-order day exists');
      await page.locator('.hud-menu [data-menu]').tap(); await frame();
      await page.locator('.hud-menusheet [data-open="contracts"]').tap();
      assert.ok(await settle(page, () => document.querySelectorAll('.cw-ctr').length === 3), 'three orders render');
      const m = await page.evaluate(() => [...document.querySelectorAll('.cw-ctr')].map((c) => {
        const cr = c.getBoundingClientRect(); const b = c.querySelector('button').getBoundingClientRect(); const hd = c.querySelector('.hd').getBoundingClientRect(); const meta = c.querySelector('.hd .meta').getBoundingClientRect();
        return { text: c.querySelector('.hd').innerText.replace(/\n/g, ' | '), btnInside: b.left >= cr.left && b.right <= cr.right, btnH: b.height, hdW: hd.width, metaOnName: meta.top < hd.top + hd.height / 2 && c.querySelector('.hd').children.length > 1 && meta.top < c.querySelector('.hd').children[0].getBoundingClientRect().bottom - 1 };
      }));
      for (const o of m) { assert.ok(o.btnInside, `${size}: DELIVER inside its order (${o.text})`); assert.ok(o.btnH >= 40, `${size}: DELIVER is a tap target (${o.btnH})`); assert.ok(o.hdW >= 150, `${size}: order name has room (${o.hdW}px, ${o.text})`); assert.equal(o.metaOnName, false, `${size}: skill tag clear of the name (${o.text})`); }
      done.push(`contracts@${size}`);
    });
  } finally { await browser.close(); }
  console.log('mobile-bughunt-smoke: ok', done.join(' '));
})().catch((e) => { console.error(e); process.exit(1); });
