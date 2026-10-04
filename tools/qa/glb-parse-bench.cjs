// Main-thread cost of parsing creature GLBs through AssetCache (long tasks and the longest single block while each model loads).
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5378/?offline' DM_QA_MODELS=deacon,bone_golem node tools/qa/glb-parse-bench.cjs
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5378/?offline';
const MODELS = (process.env.DM_QA_MODELS || 'deacon,bone_golem,grave_robber,hero_gravecaller,penitent').split(',');
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
  page.setDefaultTimeout(240000);
  await page.goto(URL);
  await page.waitForTimeout(8000);
  const out = await page.evaluate(async (models) => {
    const { assets } = await import('/src/graphics/AssetCache.ts');
    const res = [];
    for (const slug of models) {
      await new Promise((r) => setTimeout(r, 1500));
      // Longest block: a 0 ms timer chain measures the largest gap between turns of the event loop.
      let maxGap = 0, last = performance.now(), run = true;
      const tick = () => { const n = performance.now(); maxGap = Math.max(maxGap, n - last); last = n; if (run) setTimeout(tick, 0); };
      tick();
      const t0 = performance.now();
      const t = await assets.model(`models/${slug}/character.glb`, 1.8);
      const total = performance.now() - t0;
      run = false;
      res.push({ slug, ok: !!t, totalMs: Math.round(total), longestBlockMs: Math.round(maxGap) });
    }
    return res;
  }, MODELS);
  for (const r of out) console.log(JSON.stringify(r));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
