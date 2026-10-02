/**
 * Spawn-hitch probe: how long does the FIRST render containing a new creature type take, and does it still compile
 * shader programs? After `new Creature(slug).ready` the model is already warmed (src/graphics/warmModel.ts), so
 * newPrograms should be 0 and firstRender close to secondRender.
 *
 * Usage (dev server on 5393, one headless browser at a time):
 *   npx vite --host 127.0.0.1 --port 5393 --strictPort &
 *   DM_PLAYWRIGHT_MODULE=<path to playwright> DM_QA_URL='http://127.0.0.1:5393/?offline' node tools/qa/spawn-warm-probe.cjs
 * DM_QA_SLUGS=a,b:spectral,c picks the types (default: five representative ones). Set DM_QA_NOWARM=1 for the old behaviour (warm context removed) to compare. Stays in the Chapterhouse acre so the
 * area-roster preload does not pre-warm the probed types.
 */
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE);
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  if (process.env.DM_QA_NOBUDGET) await page.addInitScript(() => { window.__cwNoBudget = true; });
  await page.goto(process.env.DM_QA_URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `co_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email'); if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1'); await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  const r = await page.evaluate(async ([NOW, NAMES]) => { window.__nowarm = NOW;
    const d = window.__cwDebug; d.god(true); d.unlockAll(); d.advance(0.5); d.clear(); d.freeze(true);
    const rt = (await import('/src/app/GameRuntime.ts')).getRuntime(); const v = rt.view; const R = rt.renderer;
    const { Creature } = await import('/src/graphics/Creature.ts'); const { assets } = await import('/src/graphics/AssetCache.ts');
    const NOWARM = !!window.__nowarm; if (NOWARM) (await import('/src/graphics/warmModel.ts')).setWarmContext(null);
    const out = {}; R.render(v.scene, v.camera); R.render(v.scene, v.camera); R.getContext().finish();
    window.__lt = []; new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__lt.push(Math.round(e.duration)); }).observe({ type: 'longtask' });
    for (const key of NAMES) {
      const [slug, flag] = key.split(':');
      window.__lt.length = 0;
      let t = performance.now(); const cs = []; for (let i = 0; i < 6; i++) cs.push(new Creature(slug, slug === 'choir_wraith' || flag === 'spectral' ? { spectral: true, fallback: 'penitent' } : slug.startsWith('boss_') ? { fallback: 'prelate' } : {})); await Promise.all(cs.map(c => c.ready));
      const loadMs = Math.round(performance.now() - t);
      await new Promise(r => setTimeout(r, 50));
      const lt = [...window.__lt];
      for (const [i, c] of cs.entries()) { c.root.position.set(d.player.x + i - 3, 0, d.player.z + 3); v.scene.add(c.root); }
      const p0 = R.info.programs.length;
      t = performance.now(); R.render(v.scene, v.camera); R.getContext().finish(); const first = Math.round(performance.now() - t);
      t = performance.now(); R.render(v.scene, v.camera); R.getContext().finish(); const second = Math.round(performance.now() - t);
      out[key] = { loadMs, loadLongTasks: lt, firstRender: first, secondRender: second, newPrograms: R.info.programs.length - p0 };
      for (const c of cs) v.scene.remove(c.root);
    }
    return out;
  }, [!!process.env.DM_QA_NOWARM, (process.env.DM_QA_SLUGS || 'penitent,carrion_sac,bone_hound,choir_wraith,boss_gravedigger_king').split(',')]);
  for (const [k, v] of Object.entries(r)) console.log(k, JSON.stringify(v));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
