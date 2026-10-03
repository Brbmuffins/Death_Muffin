// Close-up of a Gravecaller thrall legion holding its weapons (the check that attachment steadying still keeps props in hand).
// Raises the discipline's full thrall cap standing in a loose block next to the hero, lets them idle, then walks the hero a few
// steps (so the legs and arms move) and captures a close-up. Writes <OUT>/legion-<tag>-idle.webp and -walk.webp.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5407/?offline' DM_QA_TAG=after DM_QA_OUT=docs/screenshots/cpu-snappy node tools/qa/thrall-legion-shot.cjs
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5407/?offline';
const TAG = process.env.DM_QA_TAG || 'after';
const OUT = process.env.DM_QA_OUT || 'docs/screenshots/cpu-snappy';
const ZOOM = +(process.env.DM_QA_ZOOM || 0.42);
fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `ls_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 120000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); d.goto('graves'); d.advance(0.5); d.clear(); d.advance(1); });
  await page.evaluate(async () => {
    const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug; const sim = d.sim();
    const m = sc.discipline.mods; const cap = m.thrallCap; const p = d.player;
    for (let i = 0; i < Math.min(cap, 15); i++) { const x = p.x - 2 + (i % 5) * 1.2, z = p.z + 1.6 + Math.floor(i / 5) * 1.2; sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, p.area); sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap, kind: m.thrallKind, hp: 1e6, damage: 0, attackSpeedMult: 1 }); }
    d.advance(2.5); d.freeze(true); d.zoom(0);
  });
  await page.evaluate((z) => { const d = window.__cwDebug; d.zoom(z); d.advance(3, 1 / 60, true); }, ZOOM);
  await page.waitForTimeout(500);
  const shot = async (name) => { await page.screenshot({ path: path.join(OUT, `legion-${TAG}-${name}.png`), timeout: 60000 }); };
  await shot('idle');
  const info = await page.evaluate(() => window.__cwDebug.counts());
  await page.evaluate(() => { const d = window.__cwDebug; d.freeze(false); d.advance(1.2, 1 / 60, true); });
  await page.waitForTimeout(500);
  await shot('moving');
  console.log(JSON.stringify(info));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
