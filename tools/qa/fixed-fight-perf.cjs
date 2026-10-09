// Controlled perf read: one zone, fixed state (five thralls, the zone roster in rings frozen in place, corpses), median of N perf reads.
// The zone tour's own numbers swing with random wave content; this holds the scene constant so before/after differences are real.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5351/?offline' DM_QA_AREAS=nave DM_QA_QUALITY=high,low node tools/qa/fixed-fight-perf.cjs
// Env: DM_QA_STATIC=1 (skip thralls/enemies/corpses: the bare zone, fully deterministic)  DM_QA_AREAS (default nave)  DM_QA_QUALITY (default high,low)  DM_QA_READS (default 3)  DM_QA_ARTIFACT_DIR (writes <q>-<area>-fixed.png + fixed-perf.json)
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5351/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'fixed-fight');
fs.mkdirSync(OUT, { recursive: true });
const AREAS = (process.env.DM_QA_AREAS || 'nave').split(',');
const QUALITIES = (process.env.DM_QA_QUALITY || 'high,low').split(',');
const STATIC = process.env.DM_QA_STATIC === '1';
const READS = +(process.env.DM_QA_READS || 3);
const median = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = [];
  for (const q of QUALITIES) {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    page.setDefaultTimeout(150000);
    await page.addInitScript((qq) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: qq, tips: false, autoCombat: false })), q);
    await page.goto(URL);
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    const n = `fp_${Date.now() % 1000000}`;
    await page.fill('#cw-user', n);
    const email = page.locator('#cw-email');
    if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
    await page.fill('#cw-pass', 'TestingTour1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
    for (const area of AREAS) {
      await page.evaluate((a) => { const d = window.__cwDebug; d.goto(a); d.advance(0.5); d.clear(); d.zoom(0.8); d.advance(1); }, area);
      if (!STATIC) await page.evaluate(async () => {
        const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug; const sim = d.sim();
        const m = sc.discipline.mods; const cap = m.thrallCap; const p = d.player;
        for (let i = 0; i < cap; i++) {
          const x = p.x - 3 + (i % 5) * 1.5, z = p.z + 2 + Math.floor(i / 5) * 1.5;
          sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, p.area);
          sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap, kind: m.thrallKind, hp: 1e6, damage: 0, attackSpeedMult: 1 });
        }
        d.advance(1.5);
      });
      const roster = STATIC ? [] : await page.evaluate(async (a) => (await import('/server/rules/content/areas.ts')).AREAS[a].enemies.map((e) => e.id), area);
      if (!STATIC) await page.evaluate((r) => { const d = window.__cwDebug; r.forEach((id, i) => d.ring(id, 3, 6 + i * 1.2, i === 0)); d.freeze(true); d.advance(0.6); d.freeze(true); }, roster);
      // Fresh corpses for the ring marks.
      if (!STATIC) await page.evaluate(() => { const d = window.__cwDebug; const p = d.player; for (let i = 0; i < 10; i++) d.sim().addCorpse(p.x + 4 + (i % 5) * 1.2, p.z - 3 - Math.floor(i / 5) * 1.5, 'normal', 'robber', false, 0, 1, p.area); d.advance(0.3); });
      const reads = [];
      for (let i = 0; i < READS; i++) reads.push(await page.evaluate(() => { const p = window.__cwDebug.perf(60); const c = window.__cwDebug.counts(); return { calls: p.calls, tris: p.triangles, ms: +p.updateMs.toFixed(2), points: p.points, casters: p.casters, casterTris: p.casterTris, lights: p.lights, programs: p.programs, ratio: JSON.stringify(window.__cwDebug.ratio()), skinned: p.skinned, enemies: c.enemies, thralls: c.thralls, corpses: c.corpses }; }));
      const rec = { quality: q, area, calls: median(reads.map((r) => r.calls)), tris: median(reads.map((r) => r.tris)), ms: median(reads.map((r) => r.ms)), enemies: reads[0].enemies, thralls: reads[0].thralls, corpses: reads[0].corpses, casters: reads[0].casters, casterTris: reads[0].casterTris, lights: reads[0].lights, programs: reads[0].programs, ratio: reads[0].ratio, skinned: reads[0].skinned };
      console.log(JSON.stringify(rec));
      out.push(rec);
      await page.waitForTimeout(400);
      await page.screenshot({ path: path.join(OUT, `${q}-${area}-fixed.png`), timeout: 30000 });
    }
    await page.close();
  }
  await browser.close();
  fs.writeFileSync(path.join(OUT, 'fixed-perf.json'), JSON.stringify(out, null, 1));
})().catch((e) => { console.error(e); process.exit(1); });
