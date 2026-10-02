/**
 * Spawn / first-use spike probe. Reports, per case, the longest main-thread task (PerformanceObserver longtask, >50 ms
 * only), the longest "frame JS" (time from a requestAnimationFrame callback starting to the next macrotask, so the
 * microtask chains of Creature construction count) and the max / median rAF-to-rAF delta.
 *   (c) first loot drop + first spell cast   (a) 20-body wave of a warm type   (b) 6 bodies of a first-ever type
 *   (d) elite wave of a warm type   (e) first load of a not-yet-seen GLB (AssetCache parse)
 * Usage: DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5404/?offline' node tools/qa/wave-spike.cjs
 * Env: DM_QA_WAVE (default 20), DM_QA_SHOT=<png path> screenshot after the warm wave.
 */
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5404/?offline';
const WAVE = +(process.env.DM_QA_WAVE || 20);
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  if (process.env.DM_QA_NOBUDGET) await page.addInitScript(() => { window.__cwNoBudget = true; });
  await page.addInitScript(() => {
    localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false }));
    const raf = window.requestAnimationFrame.bind(window);
    const ch = new MessageChannel();
    const pend = [];
    ch.port1.onmessage = () => { const t0 = pend.shift(); if (t0 !== undefined && window.__m) window.__m.js.push(performance.now() - t0); };
    window.requestAnimationFrame = (cb) => raf((ts) => { const t0 = performance.now(); try { cb(ts); } finally { pend.push(t0); ch.port2.postMessage(0); } });
    new PerformanceObserver((l) => { for (const e of l.getEntries()) if (window.__m) window.__m.lt.push(e.duration); }).observe({ type: 'longtask' });
    const loop = () => { const n = performance.now(); if (window.__m) { if (window.__m.last) window.__m.dt.push(n - window.__m.last); window.__m.last = n; } raf(loop); };
    raf(loop);
  });
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `ws_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email'); if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1'); await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); d.goto('graves'); d.advance(0.5); d.clear(); });
  await page.waitForTimeout(1500);
  const results = {};
  const cdp = process.env.DM_QA_PROFILE ? await page.context().newCDPSession(page) : null;
  if (cdp) { await cdp.send('Profiler.enable'); await cdp.send('Profiler.setSamplingInterval', { interval: 500 }); }
  const topSelf = (prof) => {
    const self = new Map(); const byId = new Map(prof.nodes.map((nd) => [nd.id, nd]));
    const dts = prof.timeDeltas; prof.samples.forEach((id, i) => { const nd = byId.get(id); const k = `${nd.callFrame.functionName || '(anon)'} ${nd.callFrame.url.split('/').slice(-2).join('/')}:${nd.callFrame.lineNumber}`; self.set(k, (self.get(k) || 0) + (dts[i] || 0) / 1000); });
    return [...self].sort((a, b) => b[1] - a[1]).slice(0, +(process.env.DM_QA_TOP || 10)).map(([k, v]) => `${v.toFixed(0)}ms ${k}`);
  };
  const measure = async (name, fn, settle = 2500) => {
    await page.evaluate(() => { window.__m = { lt: [], js: [], dt: [], last: 0 }; });
    if (cdp) await cdp.send('Profiler.start');
    await page.evaluate(fn);
    await page.waitForTimeout(settle);
    if (cdp) { const { profile } = await cdp.send('Profiler.stop'); console.log('  profile', name, '\n    ' + topSelf(profile).join('\n    ')); }
    const r = await page.evaluate(() => { const m = window.__m; window.__m = null; const s = [...m.dt].sort((a, b) => a - b); return { longestTask: Math.round(Math.max(0, ...m.lt)), tasks: m.lt.map(Math.round), maxFrameJs: +Math.max(0, ...m.js).toFixed(1), maxRafDelta: Math.round(Math.max(0, ...m.dt)), medRafDelta: Math.round(s[s.length >> 1] || 0), frames: m.dt.length }; });
    results[name] = r; console.log(name, JSON.stringify(r));
  };
  // (c) first loot + first cast, before anything else has warmed.
  await measure('c1_first_loot', () => { window.__cwDebug.dropGear('chest_iron', 10, 'kill', 1); });
  await measure('c2_first_loot_epic_batch', () => { window.__cwDebug.dropGear('helm_gold', 10, 'boss', 3); });
  await measure('c3_first_cast', () => { window.__cwDebug.freeze(true); window.__cwDebug.cast(1); });
  await measure('c4_cast_2_3', () => { window.__cwDebug.cast(2); window.__cwDebug.cast(3); });
  await page.evaluate(() => window.__cwDebug.clear());
  // let the idle area preload finish, then the warm wave
  await page.waitForTimeout(Number(process.env.DM_QA_PRELOAD_WAIT || 25000));
  await measure('a_warm_wave', `(() => { const d = window.__cwDebug; d.ring('robber', ${WAVE}, ${process.env.DM_QA_WAVE_R || 7}); d.freeze(true); })()`);
  if (process.env.DM_QA_SHOT) { await page.waitForTimeout(+(process.env.DM_QA_SHOT_WAIT || 800)); await page.screenshot({ path: process.env.DM_QA_SHOT }); }
  await page.evaluate(() => window.__cwDebug.clear());
  await page.waitForTimeout(800);
  await measure('d_warm_elite_wave', `(() => { const d = window.__cwDebug; d.ring('hound', 8, 7, true); d.freeze(true); })()`);
  await page.evaluate(() => window.__cwDebug.clear());
  await page.waitForTimeout(800);
  await measure('b_first_type_x6', `(() => { const d = window.__cwDebug; d.ring('slag_brute', 6, 7); d.freeze(true); })()`, 4000);
  await measure('e_first_glb_load', `(async () => { const { assets } = await import('/src/graphics/AssetCache.ts'); const { CREATURE_MODELS } = await import('/src/graphics/modelPaths.ts'); assets.model(CREATURE_MODELS.bog_hag.url, CREATURE_MODELS.bog_hag.height); })()`, 3000);
  console.log('SUMMARY', JSON.stringify(Object.fromEntries(Object.entries(results).map(([k, v]) => [k, [v.longestTask, v.maxFrameJs, v.maxRafDelta, v.medRafDelta]]))));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
