// World-load cost report: time from character pick to playable, main-thread long tasks, bytes/requests (CDP Network, GLB/texture split),
// scene object/mesh/texture/geometry counts, per-frame scene traversal cost, and what the idle prefetch adds in the 12 s after play.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5405/?offline' node tools/qa/world-load.cjs
// Env: DM_QA_QUALITY (high|low, default high)  DM_QA_OUT (json path)  DM_QA_SETTLE (ms of post-play watch, default 12000)
const fs = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5405/?offline';
const Q = process.env.DM_QA_QUALITY || 'high';
const SETTLE = +(process.env.DM_QA_SETTLE || 12000);

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  await page.addInitScript((qq) => {
    localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: qq, tips: false, autoCombat: false }));
    window.__lt = [];
    try { new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__lt.push([e.startTime, e.duration]); }).observe({ type: 'longtask', buffered: true }); } catch {}
  }, Q);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Network.enable');
  const reqs = new Map();
  const net = { requests: 0, bytes: 0, glb: 0, glbBytes: 0, tex: 0, texBytes: 0, other: 0, otherBytes: 0 };
  cdp.on('Network.requestWillBeSent', (e) => reqs.set(e.requestId, e.request.url));
  cdp.on('Network.loadingFinished', (e) => {
    const url = reqs.get(e.requestId) || ''; const b = e.encodedDataLength || 0;
    net.requests++; net.bytes += b;
    if (/\.glb(\?|$)/.test(url)) { net.glb++; net.glbBytes += b; }
    else if (/\.(webp|png|jpg|ktx2)(\?|$)/.test(url)) { net.tex++; net.texBytes += b; }
    else { net.other++; net.otherBytes += b; }
  });
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `wl_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).waitFor();
  const snap = () => ({ ...net });
  const before = snap();
  const t0 = await page.evaluate(() => performance.now());
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded && !document.querySelector('.dm-loadveil'), null, { timeout: 120000, polling: 50 });
  const tPlay = await page.evaluate(() => performance.now());
  const atPlay = snap();
  const lt = await page.evaluate((t) => window.__lt.filter(([s]) => s >= t), t0);
  await page.waitForTimeout(SETTLE);
  const settled = snap();
  const ltAll = await page.evaluate((t) => window.__lt.filter(([s]) => s >= t), t0);
  const sum = (a) => Math.round(a.reduce((x, [, d]) => x + d, 0));
  const diff = (a, b) => Object.fromEntries(Object.keys(a).map((k) => [k, a[k] - b[k]]));
  const scene = await page.evaluate(async () => {
    const rt = (await import('/src/app/GameRuntime.ts')).getRuntime();
    const sc = rt.view; const scene = sc.scene; const r = rt.renderer; const d = window.__cwDebug;
    d.advance(0.5);
    let objects = 0, meshes = 0, inst = 0, instMeshVisible = 0, hiddenRoots = 0, tris = 0;
    scene.traverse((o) => { objects++; if (o.isMesh) { meshes++; if (o.isInstancedMesh) inst++; } });
    let vis = 0; scene.traverseVisible(() => vis++);
    const t1 = performance.now(); for (let i = 0; i < 50; i++) scene.updateMatrixWorld(true); const umw = (performance.now() - t1) / 50;
    const t2 = performance.now(); for (let i = 0; i < 50; i++) scene.traverseVisible(() => {}); const tv = (performance.now() - t2) / 50;
    const p = d.perf(60);
    return { objects, meshes, instancedMeshes: inst, visibleObjects: vis, updateMatrixWorldMs: +umw.toFixed(3), traverseVisibleMs: +tv.toFixed(3), geometries: r.info.memory.geometries, textures: r.info.memory.textures, programs: r.info.programs?.length, calls: p.calls, tris: p.triangles, updateMs: +p.updateMs.toFixed(2) };
  });
  const res = { quality: Q, timeToPlayMs: Math.round(tPlay - t0), longTasksToPlay: { count: lt.length, totalMs: sum(lt), maxMs: Math.round(Math.max(0, ...lt.map((x) => x[1]))) }, longTasksPlus: { count: ltAll.length, totalMs: sum(ltAll), maxMs: Math.round(Math.max(0, ...ltAll.map((x) => x[1]))) }, netToPlay: diff(atPlay, before), netAfterSettle: diff(settled, before), scene };
  console.log(JSON.stringify(res, null, 1));
  if (process.env.DM_QA_OUT) fs.writeFileSync(process.env.DM_QA_OUT, JSON.stringify(res, null, 1));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
