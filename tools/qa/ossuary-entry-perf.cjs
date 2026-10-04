// Room-entry stall probe: cold login, hero in the Hollow Graves, a real-time pause (DM_QA_IDLE_MS, default 8000: what idle warm-up gets before
// the player walks on), then a teleport into the Marrow Ossuary. Records long tasks (>50 ms) from just before the teleport for DM_QA_AFTER_MS,
// plus every .glb the page fetched or parsed in that window. Software GL makes frames slow everywhere: read the long-task list for model/stage work,
// not as fps. `DM_QA_TARGET` picks another room.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5378/?offline' DM_QA_TAG=after node tools/qa/ossuary-entry-perf.cjs
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5378/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'ossuary-entry');
const TARGET = process.env.DM_QA_TARGET || 'ossuary';
const IDLE = +(process.env.DM_QA_IDLE_MS || 3000);
const AFTER = +(process.env.DM_QA_AFTER_MS || 4000);
const TAG = process.env.DM_QA_TAG || 'run';
fs.mkdirSync(OUT, { recursive: true });

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(240000);
  await page.addInitScript(() => {
    localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false }));
    window.__lt = [];
    new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__lt.push([Math.round(e.startTime), Math.round(e.duration)]); }).observe({ entryTypes: ['longtask'] });
  });
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `oe_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded && !document.querySelector('.dm-loadveil'), null, { timeout: 240000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); d.goto('chapterhouse'); });
  await page.waitForTimeout(+(process.env.DM_QA_CHAPTER_MS || 3000));
  await page.evaluate(() => window.__cwDebug.goto('graves'));
  await page.waitForTimeout(IDLE);
  const res = await page.evaluate(async ([target, after]) => {
    const t0 = performance.now();
    const before = window.__lt.length;
    const rt = (await import('/src/app/GameRuntime.ts')).getRuntime();
    const progs = () => rt.renderer.info.programs?.length ?? 0;
    const p0 = progs();
    const known0 = new Set(rt.renderer.info.programs.map((p) => p.id));
    window.__cwDebug.goto(target);
    await new Promise((r) => setTimeout(r, after));
    const p1 = progs();
    // A fast player's first wave: one of every roster kind appears now. Programs compiled by it are first-draw stalls.
    const d = window.__cwDebug;
    const roster = (await import('/src/content/areas.ts')).AREAS[target].enemies.map((e) => e.id);
    roster.forEach((id, i) => d.ring(id, 1, 5 + i * 0.7, false));
    d.freeze(true);
    const tw = performance.now();
    const waits = [];
    for (let i = 0; i < 12; i++) { const a = performance.now(); d.advance(0.1); waits.push(Math.round(performance.now() - a)); await new Promise((r) => setTimeout(r, 500)); }
    const p2 = progs();
    const fresh = rt.renderer.info.programs.filter((p) => !known0.has(p.id)).map((p) => `${p.name}:${String(p.cacheKey).slice(0, 60)}`);
    const waveMs = waits;
    const glbs = performance.getEntriesByType('resource').filter((r) => /\.glb/.test(r.name) && r.startTime >= t0 - 1).map((r) => [Math.round(r.startTime - t0), r.name.split('/').slice(-2).join('/')]);
    return { fresh, programs: { before: p0, afterEntry: p1, afterFirstWave: p2 }, advanceMs: waveMs, t0: Math.round(t0), lt: window.__lt.slice(before).map(([s, d]) => [s - Math.round(t0), d]), glbs };
  }, [TARGET, AFTER]);
  const longs = res.lt.filter(([, d]) => d >= 50);
  const rec = { tag: TAG, target: TARGET, idleMs: IDLE, programs: res.programs, freshPrograms: res.fresh, advanceMs: res.advanceMs, longTasks: longs.length, longMs: longs.reduce((a, [, d]) => a + d, 0), maxLong: Math.max(0, ...longs.map(([, d]) => d)), longList: longs.slice(0, 40), glbsFetchedAfterEntry: res.glbs };
  console.log(JSON.stringify(rec));
  fs.appendFileSync(path.join(OUT, 'entry.jsonl'), JSON.stringify(rec) + '\n');
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
