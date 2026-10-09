// Read-only: expected per-area enemy mix (cap x weight share) and the average across combat areas -> /tmp or stdout JSON.
// DM_PLAYWRIGHT_MODULE=... node spawn-census.cjs  (needs a dev server at DM_QA_URL, default http://127.0.0.1:5383/?offline)
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
  const b = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox'] });
  const p = await b.newPage(); await p.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5383/?offline');
  const out = await p.evaluate(async () => {
    const { AREAS } = await import('/server/rules/content/areas.ts');
    const per = {}; const avg = {}; let n = 0;
    for (const [id, a] of Object.entries(AREAS)) {
      if (!a.cap || !a.enemies?.length) continue; n++;
      const tw = a.enemies.reduce((s, e) => s + e.weight, 0); per[id] = { cap: a.cap, waveSize: a.waveSize, mix: {} };
      for (const e of a.enemies) { const c = (a.cap * e.weight) / tw; per[id].mix[e.id] = +c.toFixed(2); avg[e.id] = (avg[e.id] || 0) + c; }
    }
    for (const k of Object.keys(avg)) avg[k] = +(avg[k] / n).toFixed(2);
    return { per, avg, areas: n };
  });
  console.log(JSON.stringify(out, null, 1)); await b.close();
})();
