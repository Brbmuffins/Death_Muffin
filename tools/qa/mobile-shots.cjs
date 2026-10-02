// Mobile/tablet layout check: enters the world at phone and tablet sizes (touch emulated), screenshots the HUD and a few panels,
// and lists HUD pieces that sit on each other.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL=http://127.0.0.1:5360/?offline DM_QA_ARTIFACT_DIR=/tmp/mobile node tools/qa/mobile-shots.cjs
const { mkdirSync, writeFileSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { WATCH, VIRTUAL_TIMERS, overlaps, newCharacter, step } = require('./lib/first-hour-lib.cjs');

const OUT = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-mobile';
const SIZES = (process.env.DM_SIZES || 'phone-p:390x844,phone-l:844x390,tablet-p:820x1180,tablet-l:1180x820')
  .split(',').map((s) => { const [n, wh] = s.split(':'); const [w, h] = wh.split('x').map(Number); return { n, w, h }; });
const PANELS = (process.env.DM_PANELS || 'i,j,k,escape').split(',');
// Wrappers that legitimately contain other watched pieces.
const IGNORE = ['party+minimap', 'minimap+area', 'area+minimap'];

async function run(browser, { n, w, h }) {
  const ctx = await browser.newContext({ viewport: { width: w, height: h }, isMobile: true, hasTouch: true, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript(VIRTUAL_TIMERS);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: true, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5360/?offline');
  await page.screenshot({ path: `${OUT}/${n}-0-login.png` });
  await newCharacter(page, 'Ossuary', `mb_${n.replace('-', '')}${Date.now() % 1000}`);
  await step(page, 6);
  await page.evaluate(() => window.__cwDebug.advance(0));
  await page.screenshot({ path: `${OUT}/${n}-1-hud.png` });
  const rects = await page.evaluate(() => window.__fhRects());
  const clash = overlaps(rects, IGNORE).map((o) => `${o.a} x ${o.b} (${o.ox}x${o.oy})`);
  const off = rects.filter((r) => r.x < -2 || r.y < -2 || r.x + r.w > w + 2 || r.y + r.h > h + 2).map((r) => `${r.name} ${r.x},${r.y} ${r.w}x${r.h}`);
  const panels = {};
  for (const k of PANELS) {
    await page.keyboard.press(k === 'escape' ? 'Escape' : k);
    await page.evaluate(() => window.__cwDebug.advance(0));
    await page.screenshot({ path: `${OUT}/${n}-p-${k}.png` });
    panels[k] = await page.evaluate(([vw, vh]) => [...document.querySelectorAll('.cw-panel-float, .cw-panel, .cw-modal')].filter((el) => el.offsetParent).map((el) => {
      const r = el.getBoundingClientRect(); return { cls: el.className, x: Math.round(r.left), y: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height), fits: r.left >= -1 && r.top >= -1 && r.right <= vw + 1 && r.bottom <= vh + 1, sw: el.scrollWidth > el.clientWidth + 2 };
    }), [w, h]);
    await page.keyboard.press('Escape');
    await page.evaluate(() => window.__cwDebug.advance(0));
  }
  const docOverflow = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, sh: document.documentElement.scrollHeight }));
  await ctx.close();
  return { size: `${w}x${h}`, clash, off, panels, docOverflow, errors };
}

(async () => {
  mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const report = {};
  for (const s of SIZES) { try { report[s.n] = await run(browser, s); } catch (e) { report[s.n] = { error: String(e.message || e).slice(0, 400) }; } }
  await browser.close();
  writeFileSync(`${OUT}/report.json`, JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));
  const bad = Object.values(report).some((r) => r.error || r.clash?.length || r.off?.length || Object.values(r.panels || {}).flat().some((p) => !p.fits));
  process.exit(bad && process.env.DM_STRICT ? 1 : 0);
})();
