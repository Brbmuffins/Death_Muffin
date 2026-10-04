// Arch-crossing hitch probe: from a cold start in the Sexton's Acre, walk the hero (real pathing, one rendered 60 Hz step per frame, yielding
// to the event loop between frames like the rAF loop does) through the arches of the first rooms and record every frame's cost, the
// renderer's program count and draw calls. Software GL is slow, so read it as a before/after comparison (spike counts, programs compiled
// on crossing), not as absolute fps.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5361/?offline' node tools/qa/arch-crossing-perf.cjs
// Env: DM_QA_QUALITY (default high)  DM_QA_SPIKE_MS (default: 2x median frame, min 30)  DM_QA_ARTIFACT_DIR (writes arch-crossing.json)
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5361/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'arch-crossing');
fs.mkdirSync(OUT, { recursive: true });
// Waypoints (x, z) past the thresholds, in walk order: Acre -> Chapterhouse (west arch) -> Graves arch -> back -> east wing arch -> back to the Acre.
const ROUTE = JSON.parse(process.env.DM_QA_ROUTE || '[["acre-door-in",-17,20],["chapterhouse-mid",-4,20],["graves-arch",0,12],["graves",0,-4],["chapterhouse",0,16]]');

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(240000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript((q) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: q, tips: false, autoCombat: false })), process.env.DM_QA_QUALITY || 'high');
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `ac_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: process.env.DM_QA_CLASS || 'Ossuary' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded && !document.querySelector('.dm-loadveil'), null, { timeout: 180000 });
  await page.evaluate(async () => { window.__rt = (await import('/src/app/GameRuntime.ts')).getRuntime(); window.__d = window.__cwDebug; window.__d.god(true); window.__d.unlockAll(); });
  // Cold: no extra settling, only let the veil's own work finish (what a player gets).
  const res = await page.evaluate(async (route) => {
    const d = window.__d, rt = window.__rt, r = rt.renderer, gl = r.getContext();
    window.__sceneRef = rt.view.scene;
    const frames = [];
    let seg = 'start';
    const step = async () => {
      const t0 = performance.now();
      const progs0 = r.info.programs.length;
      const known = new Set(r.info.programs.map((p) => p.id));
      // Which shadow casters switched on this frame (a depth variant may compile for the first time when they do).
      const castNow = new Set();
      if (window.__sceneRef) window.__sceneRef.traverse((o) => { if (o.isMesh && o.castShadow && o.visible) castNow.add(o); });
      rt.advance(1 / 60, 1 / 60, false);
      const tu = performance.now() - t0;
      rt.advance(0, 1 / 60, true);
      gl.finish();
      const ms = performance.now() - t0;
      const freshP = r.info.programs.filter((p) => !known.has(p.id));
      const fresh = freshP.map((p) => `${p.name}:${String(p.cacheKey)}`);
      const who = [];
      if (freshP.length && window.__sceneRef) {
        const ids = new Set(freshP.map((p) => p.id));
        const chain = (o) => { const a = []; for (let q = o; q && a.length < 6; q = q.parent) a.push((q.name || q.type) + (q.userData && q.userData.fxId ? '#' + q.userData.fxId : '')); return a.join('<'); };
        window.__sceneRef.traverse((o) => {
          if (!o.isMesh) return;
          const mats = Array.isArray(o.material) ? o.material : [o.material];
          for (const m of mats) if (ids.has(r.properties.get(m).currentProgram?.id)) who.push(`color:${m.type}:${m.name}:${m.map && m.map.name || ''}:${chain(o)}:${o.geometry && o.geometry.type}`);
          if (o.castShadow && !castNow.has(o)) {
            const m = mats[0];
            who.push(`newCaster:${m.type}:${m.name}:map=${!!m.map}:alphaTest=${m.alphaTest}:side=${m.side}:inst=${!!o.isInstancedMesh}:skin=${!!o.isSkinnedMesh}:${chain(o)}`);
          }
        });
      }
      frames.push({ seg, upd: +tu.toFixed(1), fresh, who: [...new Set(who)].slice(0, 12), shown: d.stream().shown.join('+'), ms: +ms.toFixed(1), area: d.player.area, x: +d.player.x.toFixed(1), z: +d.player.z.toFixed(1), newProgs: r.info.programs.length - progs0, progs: r.info.programs.length, calls: r.info.render.calls });
      await new Promise((rs) => setTimeout(rs, 0));
    };
    for (let i = 0; i < 20; i++) await step();
    for (const [name, x, z] of route) {
      seg = name;
      d.player.moveTo(x, z);
      for (let i = 0; i < 900 && d.player.hasPath; i++) await step();
      for (let i = 0; i < 20; i++) await step();
    }
    return frames;
  }, ROUTE);
  const ms = res.map((f) => f.ms).sort((a, b) => a - b);
  const med = ms[Math.floor(ms.length / 2)];
  const thr = +(process.env.DM_QA_SPIKE_MS || Math.max(30, med * 2));
  const spikes = res.filter((f) => f.ms > thr);
  const bySeg = {};
  for (const f of res) { const s = (bySeg[f.seg] ??= { frames: 0, spikes: 0, worst: 0, newProgs: 0 }); s.frames++; if (f.ms > thr) s.spikes++; s.worst = Math.max(s.worst, f.ms); s.newProgs += Math.max(0, f.newProgs); }
  const progLog = res.filter((f) => f.fresh.length).map((f) => ({ seg: f.seg, x: f.x, z: f.z, area: f.area, fresh: f.fresh, who: f.who }));
  const summary = { progLog, frames: res.length, medianMs: med, spikeThresholdMs: thr, spikes: spikes.length, worstMs: ms[ms.length - 1], programsStart: res[0].progs - res[0].newProgs, programsEnd: res[res.length - 1].progs, programsCompiledWhileWalking: res.slice(20).reduce((a, f) => a + Math.max(0, f.newProgs), 0), bySeg, errors };
  console.log(JSON.stringify(summary, null, 1));
  console.log('worst frames:', JSON.stringify(spikes.sort((a, b) => b.ms - a.ms).slice(0, 15)));
  fs.writeFileSync(path.join(OUT, 'arch-crossing.json'), JSON.stringify({ summary, frames: res }));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
