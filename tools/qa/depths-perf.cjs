// Perf read for the Catacomb Depths against the Warren (the zone whose chambers it reuses): the same fixed scene in each, so the numbers differ only by the zone.
// Five thralls, the ground's roster in frozen rings, ten corpses; median of N perf reads (draw calls, triangles, CPU update ms), High and Low quality.
// The plan's budget (docs/ALCHEMY-AND-WORLDS-PLAN.md "Performance guardrails"): a regression beyond +10% against the baseline blocks the deploy; the Depths are meant to be the cheapest zone.
//   npm run dev -- --host 127.0.0.1 --port 5356 --strictPort
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5356/?offline' DM_QA_ARTIFACT_DIR=/tmp/depths-perf node tools/qa/depths-perf.cjs
// Env: DM_QA_QUALITY (default high,low) DM_QA_READS (default 3) DM_QA_DEPTHS (default 1,15). Frame time under SwiftShader is meaningless: compare calls, triangles and CPU update ms.
// Do not edit src/ while it runs: Vite hot-reloads the page and the run dies.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5356/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'depths-perf');
fs.mkdirSync(OUT, { recursive: true });
const QUALITIES = (process.env.DM_QA_QUALITY || 'high,low').split(',');
const DEPTHS = (process.env.DM_QA_DEPTHS || '1,15').split(',').map(Number);
const READS = +(process.env.DM_QA_READS || 3);
const median = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = [];
  for (const q of QUALITIES) {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    page.setDefaultTimeout(150000);
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.addInitScript((qq) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: qq, tips: false, autoCombat: false })), q);
    await page.goto(URL);
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    const n = `dp_${Date.now() % 1000000}`;
    await page.fill('#cw-user', n);
    const email = page.locator('#cw-email');
    if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
    await page.fill('#cw-pass', 'TestingDepths1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
    await page.evaluate(() => import('/src/app/GameRuntime.ts').then((m) => { window.__rt = m; }));
    const scenes = [{ name: 'warren' }, ...DEPTHS.map((d) => ({ name: `depth ${d}`, depth: d }))];
    for (const s of scenes) {
      if (s.depth) {
        await page.evaluate(({ depth }) => { const d = window.__cwDebug; d.depths.leave(); d.goto('warren'); d.advance(0.5); d.depths.enter(777 + depth, depth); d.advance(0.6); d.clear(); d.sim().depths.stairOpen = true; /* no waves of its own: the load is the fixed ring */ d.zoom(0.8); d.advance(0.5); }, s);
      } else {
        await page.evaluate(() => { const d = window.__cwDebug; d.depths.state().run && d.depths.leave(); d.goto('warren'); d.advance(0.5); d.clear(); d.zoom(0.8); d.advance(1); });
      }
      // Thralls, the roster in frozen rings, corpses: the same load in every scene.
      await page.evaluate(() => {
        const sc = window.__rt.getRuntime().view; const d = window.__cwDebug; const sim = d.sim();
        const m = sc.discipline.mods; const cap = m.thrallCap; const p = d.player;
        for (let i = 0; i < cap; i++) {
          const x = p.x - 1.5 + (i % 5) * 1.0, z = p.z + 1.5 + Math.floor(i / 5) * 1.0;
          sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, p.area);
          sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap, kind: m.thrallKind, hp: 1e6, damage: 0, attackSpeedMult: 1 });
        }
        d.advance(1.5);
      });
      const roster = await page.evaluate(async ({ depth }) => {
        const areas = (await import('/server/rules/content/areas.ts')).AREAS;
        if (!depth) return areas.warren.enemies.map((e) => e.id);
        return (await import('/server/rules/content/depths.ts')).depthRoster(depth).map((e) => e.id);
      }, s);
      // The Warren's own roster is 7 kinds; the 15th floor's is 25. Cap the rings at 24 bodies (the Depths' alive cap) so the load is the zone's, not the test's.
      await page.evaluate((r) => { const d = window.__cwDebug; let left = 24; r.forEach((id, i) => { const n = Math.min(left, 3); if (n <= 0) return; left -= n; d.ring(id, n, 4 + (i % 6) * 0.8, i === 0); }); d.freeze(true); d.advance(0.6); d.freeze(true); }, roster);
      await page.evaluate(() => { const d = window.__cwDebug; const p = d.player; for (let i = 0; i < 10; i++) d.sim().addCorpse(p.x + 2 + (i % 5) * 1.2, p.z - 3 - Math.floor(i / 5) * 1.5, 'normal', 'robber', false, 0, 1, p.area); d.advance(0.3); });
      const reads = [];
      for (let i = 0; i < READS; i++) reads.push(await page.evaluate(() => { const p = window.__cwDebug.perf(60); const c = window.__cwDebug.counts(); return { calls: p.calls, tris: p.triangles, ms: +p.updateMs.toFixed(2), enemies: c.enemies, thralls: c.thralls, corpses: c.corpses }; }));
      const rec = { quality: q, scene: s.name, calls: median(reads.map((r) => r.calls)), tris: median(reads.map((r) => r.tris)), ms: median(reads.map((r) => r.ms)), enemies: reads[0].enemies, thralls: reads[0].thralls, corpses: reads[0].corpses };
      console.log(JSON.stringify(rec));
      out.push(rec);
      await page.waitForTimeout(400);
      await page.screenshot({ path: path.join(OUT, `${q}-${s.name.replace(' ', '')}.png`), timeout: 30000 });
    }
    if (errors.length) console.log('PAGE ERRORS', errors);
    await page.close();
  }
  await browser.close();
  fs.writeFileSync(path.join(OUT, 'depths-perf.json'), JSON.stringify(out, null, 1));
})().catch((e) => { console.error(e); process.exit(1); });
