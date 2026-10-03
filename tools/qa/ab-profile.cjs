// CPU-snappy A/B harness (copied from the ab-new regression investigation, extended with inclusive times).
// Run the same fixture against two dev servers (before/after) and compare `nonGL JS ms/frame` with tools/qa/ab-summary.cjs.
// NOTE: the dev server compiles shaders inside the window (getShaderInfoLog etc.), so summaries subtract GL compile time.
// A/B real-fight CPU profile. Env: DM_QA_THRALLS (default the discipline cap), DM_QA_ENEMIES (keep at least N alive, default 12; 0 = idle zone), DM_QA_WARM (unprofiled warm seconds, default 6), DM_QA_URL, DM_QA_AREA, DM_QA_QUALITY, DM_QA_DISC (Gravecaller|Ossuary|Mourner|...), DM_QA_SECS, DM_QA_OUT
const fs = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE);
const URL = process.env.DM_QA_URL, AREA = process.env.DM_QA_AREA || 'graves', Q = process.env.DM_QA_QUALITY || 'high';
const DISC = process.env.DM_QA_DISC || 'Gravecaller', SECS = +(process.env.DM_QA_SECS || 10), OUT = process.env.DM_QA_OUT;
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('Network.enable');
  let bytes = 0, reqs = 0; cdp.on('Network.loadingFinished', (e) => { bytes += e.encodedDataLength; reqs++; });
  await page.addInitScript((qq) => { localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: qq, tips: false, autoCombat: false })); window.__t0 = performance.now(); }, Q);
  const tStart = Date.now();
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `ab_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email'); if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: DISC }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 120000 });
  const loadMs = Date.now() - tStart;
  const loadBytes = bytes, loadReqs = reqs;
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
  await page.evaluate((a) => { const d = window.__cwDebug; d.goto(a); d.advance(0.5); d.clear(); d.zoom(0.8); d.advance(1); }, AREA);
  const setup = await page.evaluate(async ([process_thr, minEn]) => {
    const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug; const sim = d.sim();
    const m = sc.discipline.mods; const cap = process_thr >= 0 ? process_thr : m.thrallCap; const p = d.player;
    for (let i = 0; i < cap; i++) { const x = p.x - 3 + (i % 5) * 1.5, z = p.z + 2 + Math.floor(i / 5) * 1.5; sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, p.area); sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap, kind: m.thrallKind, hp: 1e6, damage: 20, attackSpeedMult: 1 }); }
    d.advance(1.5);
    const roster = (await import('/src/content/areas.ts')).AREAS[p.area].enemies.map((e) => e.id);
    window.__minEn = minEn; window.__roster = roster; window.__refill = () => { const c = d.counts(); if (window.__minEn > 0 && c.enemies < window.__minEn) roster.forEach((id, i) => d.ring(id, 3, 6 + i * 1.2, false)); };
    window.__refill(); d.advance(0.5);
    return { cap, kind: m.thrallKind, disc: sc.discipline.name, counts: d.counts() };
  }, [process.env.DM_QA_THRALLS !== undefined ? +process.env.DM_QA_THRALLS : -1, process.env.DM_QA_ENEMIES !== undefined ? +process.env.DM_QA_ENEMIES : 12]);
  await page.evaluate(() => { window.__iv = setInterval(() => window.__refill(), 1000); });
  await page.waitForTimeout(3000);
  await page.evaluate(() => { const d = window.__cwDebug; for (let i = 0; i < 6; i++) { d.advance(0.5, 1 / 60, true); window.__refill(); } });
  await page.waitForTimeout(2500);
  await page.evaluate(() => { for (let i = 0; i < 4; i++) window.__cwDebug.advance(0.1, 1 / 60, true); });
  const census0 = await page.evaluate(() => { const p = window.__cwDebug.perf(1); return { calls: p.calls, tris: p.triangles, skinned: p.skinned, meshes: p.meshes, casters: p.casters, lights: p.lights, programs: p.programs, geo: p.geometries, tex: p.textures, ...window.__cwDebug.counts(), dom: document.getElementsByTagName('*').length, heap: performance.memory?.usedJSHeapSize }; });
  // Drive time only through advance(): stop the real rAF loop (it would render with software GL between windows and let the resolution governor resize the canvas under the measurement).
  await page.evaluate(async () => { (await import('/src/app/GameRuntime.ts')).getRuntime().stop(); });
  await page.waitForTimeout(500);
  // Warm pass: a first unprofiled window absorbs shader compiles and first-touch costs so the measured window is steady state.
  await page.evaluate((secs) => { const d = window.__cwDebug; for (let i = 0; i < secs; i++) { d.advance(1, 1 / 60, true); window.__refill(); } }, +(process.env.DM_QA_WARM || 6));
  await cdp.send('Performance.enable');
  await cdp.send('HeapProfiler.enable');
  await cdp.send('HeapProfiler.startSampling', { samplingInterval: 8192, includeObjectsCollectedByMajorGC: true, includeObjectsCollectedByMinorGC: true });
  const m0 = Object.fromEntries((await cdp.send('Performance.getMetrics')).metrics.map((x) => [x.name, x.value]));
  await cdp.send('Profiler.enable'); await cdp.send('Profiler.setSamplingInterval', { interval: 500 });
  await cdp.send('Profiler.start');
  // N back-to-back windows of SECS seconds: per-window thread CPU time lets the summary take the median (the VPS is shared and noisy).
  const WINDOWS = +(process.env.DM_QA_WINDOWS || 5);
  const windows = []; const fr = { frames: 0, ms: 0, worst: 0 };
  const thread = async () => (await cdp.send('Performance.getMetrics')).metrics.find((x) => x.name === 'ThreadTime').value;
  for (let w = 0; w < WINDOWS; w++) {
    const t0 = await thread();
    const one = await page.evaluate(async (s) => { const d = window.__cwDebug; const t0 = performance.now(); let worst = 0; for (let i = 0; i < s; i++) { const a = performance.now(); d.advance(1, 1 / 60, false); worst = Math.max(worst, performance.now() - a); window.__refill(); } const ms = performance.now() - t0; return { frames: s * 60, ms, worst }; }, SECS);
    windows.push({ frames: one.frames, wallMs: one.ms, threadMs: ((await thread()) - t0) * 1000, worst: one.worst });
    fr.frames += one.frames; fr.ms += one.ms; fr.worst = Math.max(fr.worst, one.worst);
  }
  fr.updMsPerFrame = fr.ms / fr.frames;
  const { profile } = await cdp.send('Profiler.stop');
  const heapProf = (await cdp.send('HeapProfiler.stopSampling')).profile;
  let allocBytes = 0; const allocBy = {};
  (function walk(n) { allocBytes += n.selfSize; if (n.selfSize) { const cf = n.callFrame; const k = `${cf.functionName || '(anon)'} ${cf.url.replace(/^.*\/(src|node_modules)\//, '$1/').replace(/\?.*$/, '')}:${cf.lineNumber + 1}`; allocBy[k] = (allocBy[k] || 0) + n.selfSize; } (n.children || []).forEach(walk); })(heapProf.head);
  const allocTop = Object.entries(allocBy).sort((a, b) => b[1] - a[1]).slice(0, 25);
  fr.renderMs = await page.evaluate(() => { const d = window.__cwDebug; const r0 = performance.now(); for (let i = 0; i < 20; i++) d.advance(0, 1 / 60, true); return (performance.now() - r0) / 20; });
  const m1 = Object.fromEntries((await cdp.send('Performance.getMetrics')).metrics.map((x) => [x.name, x.value]));
  const census1 = await page.evaluate(() => ({ dom: document.getElementsByTagName('*').length, ...window.__cwDebug.counts() }));
  await page.evaluate(() => clearInterval(window.__iv));
  // aggregate self time
  const dt = profile.timeDeltas, byId = new Map(profile.nodes.map((x) => [x.id, x])); const agg = {}; let total = 0, idle = 0;
  profile.samples.forEach((id, i) => { const nd = byId.get(id), cf = nd.callFrame; const w = dt[i] / 1000; total += w; if (cf.functionName === '(idle)') { idle += w; return; } const k = `${cf.functionName || '(anon)'} ${cf.url.replace(/^.*\/(src|node_modules)\//, '$1/')}:${cf.lineNumber + 1}`; agg[k] = (agg[k] || 0) + w; });
  const fileAgg = {}; for (const [k, v] of Object.entries(agg)) { const f = k.replace(/^.* (.*):\d+$/, '$1'); fileAgg[f] = (fileAgg[f] || 0) + v; }
  // Inclusive time per function (each sample counted once per distinct function on its stack).
  const parent = new Map(); for (const nd of profile.nodes) for (const c of nd.children || []) parent.set(c, nd.id);
  const incl = {};
  profile.samples.forEach((id, i) => { const w = dt[i] / 1000; const seen = new Set(); for (let cur = id; cur !== undefined; cur = parent.get(cur)) { const cf = byId.get(cur).callFrame; if (cf.functionName === '(idle)') break; const k = `${cf.functionName || '(anon)'} ${cf.url.replace(/^.*\/(src|node_modules)\//, '$1/')}`; if (seen.has(k)) continue; seen.add(k); incl[k] = (incl[k] || 0) + w; } });
  const top = (o, n) => Object.entries(o).sort((a, b) => b[1] - a[1]).slice(0, n).map(([k, v]) => [k, +v.toFixed(1)]);
  const res = { url: URL, area: AREA, q: Q, loadMs, loadBytes, loadReqs, setup, census0, census1, frames: fr, upd: +fr.updMsPerFrame.toFixed(3), renderMs: +fr.renderMs.toFixed(1), busyMs: +(total - idle).toFixed(0), idleMs: +idle.toFixed(0),
    allocBytes, windows, allocTop, metricsDelta: Object.fromEntries(['ThreadTime', 'LayoutCount', 'RecalcStyleCount', 'ScriptDuration', 'TaskDuration', 'LayoutDuration', 'RecalcStyleDuration', 'JSHeapUsedSize', 'Nodes'].map((k) => [k, +(m1[k] - m0[k]).toFixed(3)])), heap0: m0.JSHeapUsedSize, heap1: m1.JSHeapUsedSize, topFn: top(agg, 40), topFile: top(fileAgg, 25), topIncl: top(incl, 60) };
  fs.writeFileSync(OUT, JSON.stringify(res, null, 1));
  console.log(JSON.stringify({ upd: res.upd, renderMs: res.renderMs, busyMs: res.busyMs, idleMs: res.idleMs, loadMs, loadBytes, metricsDelta: res.metricsDelta, census0, setup }));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
