// Zone tour (offline dev build, driven through __cwDebug): for every zone it takes an arrival shot, a busy-fight shot
// (full legion + the zone's own roster + corpses) and, where the zone has a boss, a sequence of boss shots that catch
// its telegraphs; it records draw calls / triangles / update time for each. Report-only, no assertions beyond "no page errors".
//   npm run dev -- --host 127.0.0.1 --port 5350 --strictPort
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5350/?offline' DM_QA_ARTIFACT_DIR=/tmp/tour/before node tools/qa/zone-tour.cjs
// Env: DM_QA_QUALITY=high,low   DM_QA_AREAS=graves,pyre   DM_QA_BOSSES=0 to skip bosses   DM_QA_VISIT=0 to skip the zone shots (bosses only)   DM_QA_BOSS_SHOTS=8   DM_QA_DISC=Gravecaller
// For before/after perf numbers use tools/qa/fixed-fight-perf.cjs instead (the tour's random wave content swings calls +-30%).
// Pixel metrics (tools/qa/lib/pixel-metrics.cjs) of every arrival and fight shot are compared with the per-zone baselines in
// tools/qa/baselines/pixel-metrics.json and printed + written to <dir>/pixels.json (report only). DM_QA_PIXELS=0 skips,
// DM_QA_PIXELS_UPDATE=1 rewrites the baselines (do that only after an intended look change; boss shots are not baselined).
// Writes <dir>/<quality>-<area>-{arrival,fight}.png, <quality>-boss-<id>-<n>.png and <dir>/tour.json.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const pixels = require('./lib/pixel-metrics.cjs');

const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5350/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'zone-tour');
fs.mkdirSync(OUT, { recursive: true });
const DISC = process.env.DM_QA_DISC || 'Gravecaller';
const QUALITIES = (process.env.DM_QA_QUALITY || 'high,low').split(',');
const ALL = ['chapterhouse', 'acre', 'alchemist_wing', 'graves', 'warren', 'ossuary', 'coliseum', 'nave', 'sanctum', 'cloister', 'pyre', 'fen'];
const AREAS = (process.env.DM_QA_AREAS || ALL.join(',')).split(',');
const BOSS_OF = { graves: 'gravedigger', ossuary: 'abbess', nave: 'congregation', sanctum: 'prelate', cloister: 'saint', pyre: 'regent', fen: 'mire' };
const BOSS_SHOTS = +(process.env.DM_QA_BOSS_SHOTS || 8);
const results = [];
const errors = [];

async function boot(browser, quality) {
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  await page.addInitScript((q) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: q, tips: false, autoCombat: false })), quality);
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `zt_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: DISC }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
  return page;
}

const pixelShots = [];
async function shot(page, name) {
  await page.waitForTimeout(400);
  for (let i = 0; i < 4; i++) {
    try { await page.screenshot({ path: path.join(OUT, `${name}.png`), timeout: 30000 }); if (/-(arrival|fight)$/.test(name)) pixelShots.push({ key: name, file: path.join(OUT, `${name}.png`) }); return; }
    catch (e) { if (i === 3) throw e; await page.waitForTimeout(1500); }
  }
}

const perf = (page) => page.evaluate(() => {
  const d = window.__cwDebug; const p = d.perf(60); const c = d.counts();
  return { calls: p.calls, triangles: p.triangles, updateMs: +p.updateMs.toFixed(2), simMs: +p.simMs.toFixed(2), lights: p.lights, skinned: p.skinned, enemies: c.enemies, thralls: c.thralls, corpses: c.corpses, frameMs: +(c.frameMs || 0).toFixed(1) };
});

/** A full legion beside the hero plus a few corpses (the necromancer's resource) on the ground. */
const legion = (page, area) => page.evaluate(async () => {
  const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug; const sim = d.sim();
  const m = sc.discipline.mods; const n = m.thrallCap; const p = d.player; const area = p.area;
  for (let i = 0; i < n; i++) {
    const x = p.x - 3 + (i % 5) * 1.5, z = p.z + 2 + Math.floor(i / 5) * 1.5;
    sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, area);
    sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap: n, kind: m.thrallKind, hp: 1e6, damage: 8, attackSpeedMult: 1 });
  }
  d.advance(1.5);
  return n;
});

async function visit(page, quality, area) {
  const tag = `${quality}-${area}`;
  await page.evaluate((a) => { const d = window.__cwDebug; d.unlockAll(); d.goto(a); d.advance(0.5); d.clear(); d.zoom(1.15); d.advance(1); }, area);
  const here = await page.evaluate(() => window.__cwDebug.player.area);
  if (here !== area) console.log('WARNING: wanted', area, 'but the hero is in', here);
  await page.waitForTimeout(1500);
  await page.evaluate(() => window.__cwDebug.advance(0.4));
  const rec = { quality, area };
  rec.arrivalPerf = await perf(page);
  await shot(page, `${tag}-arrival`);
  const roster = await page.evaluate(async (a) => (await import('/src/content/areas.ts')).AREAS[a].enemies.map((e) => e.id), area);
  const safe = await page.evaluate(async (a) => (await import('/src/content/areas.ts')).AREAS[a].safe, area);
  if (!roster.length || safe) { rec.fight = null; results.push(rec); return; }
  await legion(page, area);
  await page.evaluate((r) => {
    const d = window.__cwDebug; d.zoom(0.8);
    r.forEach((id, i) => d.ring(id, 3, 6 + i * 1.2, i === 0));
    d.advance(2.2);
  }, roster);
  await page.evaluate(() => { const d = window.__cwDebug; d.aimAtNearest(); d.cast(1); d.advance(0.3); d.cast(2); d.advance(0.5); });
  rec.fightPerf = await perf(page);
  await shot(page, `${tag}-fight`);
  results.push(rec);
}

async function bossRun(browser, quality, area) {
  const id = BOSS_OF[area];
  const page = await boot(browser, quality);
  const rec = { quality, area, boss: id, shots: [] };
  await page.evaluate((a) => { const d = window.__cwDebug; d.unlockAll(); d.goto(a); d.advance(0.5); d.clear(); d.advance(0.3); }, area);
  await page.evaluate((b) => { const d = window.__cwDebug; d.zoom(0.85); d.boss(b); d.advance(0.5); }, id);
  const n = quality === 'high' ? BOSS_SHOTS : Math.min(3, BOSS_SHOTS);
  for (let i = 0; i < n; i++) {
    await page.evaluate(() => window.__cwDebug.advance(1.4));
    await shot(page, `${quality}-boss-${id}-${i}`);
    if (i === Math.floor(n / 2)) rec.perf = await perf(page);
  }
  results.push(rec);
  fs.writeFileSync(path.join(OUT, 'tour.json'), JSON.stringify(results, null, 1));
  await page.close();
}

(async () => {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  for (const q of QUALITIES) {
    let page = process.env.DM_QA_VISIT !== '0' ? await boot(browser, q) : null;
    if (process.env.DM_QA_VISIT !== '0') for (const a of AREAS) {
      console.log(q, a);
      for (let attempt = 0; attempt < 2; attempt++) {
        try { await visit(page, q, a); break; }
        catch (e) {
          // A crashed or stalled page is replaced by a fresh one (new offline account) and the zone is retried once.
          console.log('  retry after:', String(e.message).split('\n')[0]);
          await page.close().catch(() => {});
          page = await boot(browser, q);
        }
      }
      fs.writeFileSync(path.join(OUT, 'tour.json'), JSON.stringify(results, null, 1));
    }
    await page?.close().catch(() => {});
    if (process.env.DM_QA_BOSSES !== '0') for (const a of AREAS) if (BOSS_OF[a]) { console.log(q, 'boss', BOSS_OF[a]); await bossRun(browser, q, a); }
  }
  let pixelRows = [];
  if (process.env.DM_QA_PIXELS !== '0' && pixelShots.length) {
    try {
      pixelRows = await pixels.checkShots(browser, 'zone-tour', pixelShots, { meta: { viewport: '1280x800', note: 'zone-tour arrival + fight shots, offline mock, Gravecaller' } });
      console.log('pixel metrics vs baselines:'); pixels.printRows(pixelRows);
    } catch (e) { console.log('pixel check failed (ignored):', String(e.message).slice(0, 200)); }
  }
  await browser.close();
  fs.writeFileSync(path.join(OUT, 'tour.json'), JSON.stringify(results, null, 1));
  if (pixelRows.length) fs.writeFileSync(path.join(OUT, 'pixels.json'), JSON.stringify(pixelRows, null, 1));
  const bad = errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e));
  console.log(bad.length ? 'page errors:\n' + bad.slice(0, 10).join('\n') : 'no page errors', '\nwrote', OUT);
})().catch((e) => { console.error(e); process.exit(1); });
