// Mobile panel audit: at each phone/tablet size, opens every Menu-sheet panel by touch and reports
//   - panels that cannot be closed by tap (X) or the phone Back gesture,
//   - panel content wider than the panel (horizontal clipping), clipped text, and tap targets under 40 px.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL=http://127.0.0.1:5461/?offline [DM_SIZES=phone-s:360x640,...] node tools/qa/mobile-panel-audit.cjs
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { VIRTUAL_TIMERS, newCharacter, step } = require('./lib/first-hour-lib.cjs');
const SIZES = (process.env.DM_SIZES || 'phone-s:360x640,phone-p:390x844,tablet-p:768x1024,phone-l:844x390')
  .split(',').map((s) => { const [n, wh] = s.split(':'); const [w, h] = wh.split('x').map(Number); return { n, w, h }; });

const AUDIT = () => {
  const panel = [...document.querySelectorAll('.cw-panel-float')].find((e) => e.offsetParent);
  if (!panel) return null;
  const pr = panel.getBoundingClientRect();
  const vis = (el) => { const r = el.getBoundingClientRect(); const cs = getComputedStyle(el); return r.width > 0 && r.height > 0 && cs.visibility !== 'hidden' && cs.display !== 'none' && cs.opacity !== '0'; };
  const label = (el) => `${el.tagName.toLowerCase()}${el.className && typeof el.className === 'string' ? '.' + el.className.trim().split(/\s+/).slice(0, 2).join('.') : ''}${(el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 18) ? ' "' + (el.textContent || el.getAttribute('aria-label') || '').trim().slice(0, 18) + '"' : ''}`;
  // Inside a scroll container, only what is scrolled into view counts as "visible".
  const inScroll = (el) => { for (let p = el.parentElement; p && p !== panel.parentElement; p = p.parentElement) { const o = getComputedStyle(p).overflowY; if ((o === 'auto' || o === 'scroll') && p.scrollHeight > p.clientHeight) { const c = p.getBoundingClientRect(), r = el.getBoundingClientRect(); if (r.bottom < c.top || r.top > c.bottom) return false; } } return true; };
  const small = [], wide = [], clipped = [];
  for (const el of panel.querySelectorAll('button, a, [role=button], input, select, [data-open], [data-tab], [data-close], [data-back], [data-slot]')) {
    if (!vis(el) || el.disabled && false) continue;
    const r = el.getBoundingClientRect();
    if (r.width < 40 || r.height < 40) {
      // A control is fine if a parent button (>=40) contains it, or it is inline text in a row.
      if (el.closest('button') !== el && el.closest('button')) continue;
      small.push(`${label(el)} ${Math.round(r.width)}x${Math.round(r.height)}`);
    }
  }
  for (const el of panel.querySelectorAll('*')) {
    if (!vis(el)) continue;
    const r = el.getBoundingClientRect();
    if (r.right > pr.right + 2 && r.left < pr.right) wide.push(`${label(el)} right=${Math.round(r.right)} panel=${Math.round(pr.right)}`);
    const cs = getComputedStyle(el);
    if (el.scrollWidth > el.clientWidth + 2 && el.clientWidth > 0 && (cs.overflowX === 'hidden' || cs.textOverflow === 'ellipsis') && (el.textContent || '').trim()) clipped.push(`${label(el)} ${el.scrollWidth}>${el.clientWidth}`);
  }
  const x = panel.querySelector('[data-close]');
  const xr = x?.getBoundingClientRect();
  return { title: panel.querySelector('.cw-title,h2')?.textContent?.trim(), rect: [pr.left, pr.top, pr.right, pr.bottom].map(Math.round), vp: [innerWidth, innerHeight],
    x: xr ? [Math.round(xr.left), Math.round(xr.top), Math.round(xr.width), Math.round(xr.height)] : null,
    small: [...new Set(small)].slice(0, 12), wide: [...new Set(wide)].slice(0, 6), clipped: [...new Set(clipped)].slice(0, 8), scrollsX: panel.scrollWidth > panel.clientWidth + 2 };
};

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = {};
  for (const { n, w, h } of SIZES) {
    const ctx = await browser.newContext({ viewport: { width: w, height: h }, isMobile: true, hasTouch: true, deviceScaleFactor: 1 });
    const page = await ctx.newPage();
    const errors = []; page.on('pageerror', (e) => errors.push(e.message));
    await page.addInitScript(VIRTUAL_TIMERS);
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5461/?offline');
    await newCharacter(page, 'Ossuary', `pa${n.replace('-', '')}${Date.now() % 1000}`);
    await step(page, 2);
    await page.evaluate(() => { window.__cwDebug.god?.(); window.__cwDebug.unlockAll?.(); });
    await step(page, 1);
    const frame = () => page.evaluate(() => window.__cwDebug.advance(0.05));
    const tiles = await page.evaluate(() => (window.__cwDebug.advance(0), [...document.querySelectorAll('.hud-menusheet [data-open]')].map((t) => t.dataset.open)));
    const hasMenuBtn = await page.locator('.hud-menu [data-menu]').isVisible();
    const res = {};
    for (const k of tiles) {
      let tile = page.locator(`.hud-menusheet [data-open="${k}"]`);
      if (hasMenuBtn) { await page.locator('.hud-menu [data-menu]').tap(); await frame(); }
      else { tile = page.locator(`.hud-menu .hud-mi[data-open="${k}"]`); if (!(await tile.count()) || !(await tile.isVisible())) { res[k] = { unreachable: 'no Menu button and no icon in the menu row' }; continue; } }
      const tb = await tile.boundingBox();
      await tile.tap(); await step(page, 0.5);
      let a = await page.evaluate(AUDIT);
      // The Gear Atlas loads its chunk on first open: give it real time.
      for (let i = 0; !a && i < 10; i++) { await page.waitForTimeout(300); await step(page, 0.3); a = await page.evaluate(AUDIT); }
      const r = { tile: tb && [Math.round(tb.width), Math.round(tb.height)], ...(a || { open: false }) };
      if (a) {
        if (process.env.DM_SHOTS) await page.screenshot({ path: `${process.env.DM_SHOTS}/${n}-${k}.png` });
        // close by X
        const x = page.locator('.cw-panel-float [data-close]').first();
        r.closeX = (await x.count()) ? await x.isVisible() : false;
        await page.goBack().catch(() => {}); await step(page, 0.3);
        r.backCloses = !(await page.evaluate(() => [...document.querySelectorAll('.cw-panel-float')].some((e) => e.offsetParent)));
        if (!r.backCloses) { if (r.closeX) await x.tap(); await step(page, 0.3); }
      }
      res[k] = r;
    }
    // Panels the Menu does not list (reached by tapping an object or NPC): open them through the game's own hooks.
    const extras = { ascension: (v) => v.togglePanel('ascension'), salvage: (v) => v.togglePanel('salvage'), reagents: () => window.__cwDebug.station('reagents'), class: (v) => v.classPanel.open(), dialogue: () => window.__cwDebug.guidance.talk('sexton') };
    for (const k of Object.keys(extras)) {
      await page.evaluate(async ([k, src]) => { const { getRuntime } = await import('/src/app/GameRuntime.ts'); new Function('v', `return (${src})(v)`)(getRuntime().view); }, [k, extras[k].toString().replace(/window\.__cwDebug/g, 'window.__cwDebug')]);
      await step(page, 0.6);
      const a = await page.evaluate(AUDIT);
      const r = a || { open: false };
      if (a) {
        if (process.env.DM_SHOTS) await page.screenshot({ path: `${process.env.DM_SHOTS}/${n}-x-${k}.png` });
        await page.goBack().catch(() => {}); await step(page, 0.3);
        r.backCloses = !(await page.evaluate(() => [...document.querySelectorAll('.cw-panel-float')].some((e) => e.offsetParent)));
        if (!r.backCloses) { await page.keyboard.press('Escape'); await step(page, 0.3); }
      } else { await page.keyboard.press('Escape'); await step(page, 0.3); }
      res['x:' + k] = r;
    }
    out[n] = { res, errors };
    await ctx.close();
  }
  await browser.close();
  console.log(JSON.stringify(out, null, 1));
})().catch((e) => { console.error(e); process.exit(1); });
