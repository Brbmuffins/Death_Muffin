// Screenshots the web game's DEV Binbun gallery (window.__cwDebug.vfxGallery(page)) for side-by-side comparison with the Godot gallery.
//   (npx vite --port 5232 &)   then, under the renderer lock:
//   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock node tools/godot/fx-web-gallery.cjs <outDir> <page,page,...> [t1,t2]
const { createRequire } = require('node:module');
const req = createRequire('/home/ubuntu/.npm/_npx/e41f203b7505f1fb/node_modules/');
const { chromium } = req('playwright');
(async () => {
  const out = process.argv[2] || 'godot/shots/fx/web';
  const pages = (process.argv[3] || '0').split(',').map(Number);
  const times = (process.argv[4] || '0.5,1.2').split(',').map(Number);
  require('node:fs').mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(240000);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5232/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `fxg_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('fxg@example.invalid');
  await page.fill('#cw-pass', 'TestingGallery1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(() => window.__cwDebug.god?.());
  for (const p of pages) {
    await page.evaluate(async (p) => { await window.__cwDebug.vfxGallery(p); }, p);
    await page.waitForTimeout(3000); // JSON + textures load while the game clock stands still
    let at = 0;
    for (const t of times) {
      await page.evaluate((dt) => window.__cwDebug.advance(dt), t - at + (at === 0 ? 0.04 : 0));
      at = t;
      await page.screenshot({ path: `${out}/w${p}_t${Math.round(t * 100)}.png` });
      console.log('saved', p, t);
    }
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
