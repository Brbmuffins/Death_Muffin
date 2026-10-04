// Screenshots of the Sexton's Acre floor around the gathering nodes (z-fighting / sunk or floating bases), at a few spots.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5361/?offline' DM_QA_ARTIFACT_DIR=/tmp/acre-floor node tools/qa/acre-floor-shot.cjs
// Env: DM_QA_SPOTS='name:x:z,...' (default a handful)  DM_QA_ZOOM (default 0.75)  DM_QA_QUALITY (default high)
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5361/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'acre-floor');
const SPOTS = (process.env.DM_QA_SPOTS || 'seams:-36:12,lane:-31:19,grove:-40:17,pond:-37:26,graves:-34:30,door:-24:20').split(',').map((s) => { const [n, x, z] = s.split(':'); return { n, x: +x, z: +z }; });
fs.mkdirSync(OUT, { recursive: true });
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(240000);
  await page.addInitScript((q) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: q, tips: false, autoCombat: false })), process.env.DM_QA_QUALITY || 'high');
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `af_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded && !document.querySelector('.dm-loadveil'), null, { timeout: 180000 });
  await page.evaluate((z) => { const d = window.__cwDebug; d.god(true); d.unlockAll(); d.freeze?.(true); d.zoom(z); }, +(process.env.DM_QA_ZOOM || 0.75));
  for (const s of SPOTS) {
    await page.evaluate(([x, z]) => { const d = window.__cwDebug; d.teleport(x, z); d.advance(1.2); }, [s.x, s.z]);
    await page.screenshot({ path: path.join(OUT, `${process.env.DM_QA_TAG || 'shot'}-${s.n}.png`), timeout: 60000 });
    console.log('shot', s.n);
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
