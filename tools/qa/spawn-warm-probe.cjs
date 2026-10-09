/**
 * Spawn-hitch probe: how long does the FIRST render containing a new creature type take, and does it still compile
 * shader programs? After `new Creature(slug).ready` the model is already warmed (src/graphics/warmModel.ts), so
 * newPrograms should be 0 and firstRender close to secondRender.
 *
 * Usage (dev server on 5393, one headless browser at a time):
 *   npx vite --host 127.0.0.1 --port 5393 --strictPort &
 *   DM_PLAYWRIGHT_MODULE=<path to playwright> DM_QA_URL='http://127.0.0.1:5393/?offline' node tools/qa/spawn-warm-probe.cjs
 * REAL-SPAWN MODE (DM_QA_REAL=1): after the login warm-up render (src/graphics/warmRender.ts) it spawns every enemy of the start area within two doors (plain and elite)
 * through the real sim -> EntityViews path and reports, per type, the programs / textures / geometries created from the
 * spawn to the body's first frames, the first-frame time against the median steady frame, and whether the body actually appeared. Bone textures
 * (one tiny per-skeleton upload that no warm can share) are reported apart from real textures. DM_QA_NOWARMRENDER=1 adds ?nowarmrender (the old
 * behaviour) for comparison; newPrograms excludes Binbun effect shaders (reported as effectPrograms: coldWarm owns them); DM_QA_ONLY=a,b restricts the types; DM_QA_SHOT=path takes a screenshot the moment the veil lifts.
 * DM_QA_SLUGS=a,b:spectral,c picks the types (default: five representative ones). Set DM_QA_NOWARM=1 for the old behaviour (warm context removed) to compare. Stays in the Chapterhouse acre so the
 * area-roster preload does not pre-warm the probed types.
 */
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE);
(async () => {
  if (process.env.DM_QA_ONLY) { /* handled in page */ }
  const browser = await chromium.launch({ headless: true, executablePath: '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  if (process.env.DM_QA_ONLY) await page.addInitScript((o) => { window.__only = o; }, process.env.DM_QA_ONLY);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  if (process.env.DM_QA_NOBUDGET) await page.addInitScript(() => { window.__cwNoBudget = true; });
  const url = process.env.DM_QA_URL + (process.env.DM_QA_NOWARMRENDER ? (process.env.DM_QA_URL.includes('?') ? '&' : '?') + 'nowarmrender' : '');
  await page.goto(url);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `co_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email'); if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1'); await page.locator('#cw-login-btn').click();
  const tPick = Date.now();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  if (process.env.DM_QA_REAL) {
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded && !document.querySelector('.dm-loadveil'), null, { timeout: 120000, polling: 25 });
    const veilMs = Date.now() - tPick;
    if (process.env.DM_QA_SHOT) await page.screenshot({ path: process.env.DM_QA_SHOT });
    console.log('veil+load ms', veilMs, 'stage', JSON.stringify(await page.evaluate(() => { const w = window.__dmWarmStage; return w ? { staged: w.staged, skipped: w.skipped, outOfView: w.outOfView, ms: w.ms, keys: w.keys.length } : null; })));
    const rows = await page.evaluate(async () => {
      const wr = { warmPending: () => window.__dmWarmPending?.() ?? 0, stageLog: window.__dmStageLog };
      for (let i = 0; i < 600 && wr.warmPending() > 0; i++) await new Promise((r) => setTimeout(r, 100));
      const stillPending = wr.warmPending();
      const d = window.__cwDebug; d.god(true); d.unlockAll(); d.clear(); d.advance(0.5);
      const rt = (await import('/src/app/GameRuntime.ts')).getRuntime(); const R = rt.renderer; const scene = rt.view.scene;
      const { AREAS, DOORS } = await import('/server/rules/content/areas.ts');
      // Everything within two door-steps of the start (what the login warm-up covers).
      const areasWithin = (start, hops) => { const out = [start]; let fr = [start]; for (let h = 0; h < hops; h++) { const nx = []; for (const a of fr) for (const dr of DOORS) { const n = dr.a === a ? dr.b : dr.b === a ? dr.a : null; if (n && !out.includes(n)) { out.push(n); nx.push(n); } } fr = nx; } return out; };
      const ids = [...new Set(areasWithin('acre', 2).flatMap((a) => AREAS[a].enemies.map((e) => e.id)))];
      const only = (window.__only || '').split(',').filter(Boolean);
      const skins = () => { let n = 0; scene.traverse((o) => { if (o.isSkinnedMesh) n++; }); return n; };
      const bones = () => { const s = new Set(); scene.traverse((o) => { if (o.isSkinnedMesh && o.skeleton?.boneTexture) s.add(o.skeleton.boneTexture); }); return s.size; };
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const med = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)] ?? 0;
      // Counted INSIDE each frame call (render is synchronous), so idle-time work between frames never pollutes a spawn's numbers.
      // Texture creations are caught at the source: composer render targets (bloom mips, resized with the resolution governor) are not body uploads.
      const acc = { fx: 0, static: 0, skinned: [], t: 0, rt: 0, g: 0, progs: [] };
      const origRBD = R.renderBufferDirect.bind(R);
      R.renderBufferDirect = (cam, sc, geo, mat, obj, grp) => { const n0 = R.info.programs.length; const r = origRBD(cam, sc, geo, mat, obj, grp); if (inFrame && R.info.programs.length > n0) { const k = R.info.programs[R.info.programs.length - 1].cacheKey; if (k.includes('BB_KNEE')) acc.fx++; else if (obj.isSkinnedMesh) acc.skinned.push((mat.isMeshDepthMaterial ? 'depth ' : '') + (mat.name || obj.name)); else acc.static++; } return r; };
      let tv = R.info.memory.textures, inFrame = false;
      Object.defineProperty(R.info.memory, 'textures', { get: () => tv, set: (v) => { if (inFrame && v > tv) { if (new Error().stack.includes('setupRenderTarget')) acc.rt++; else acc.t++; } tv = v; } });
      const frame = () => {
        const g0 = R.info.memory.geometries, b0 = bones();
        const t = performance.now(); inFrame = true; d.advance(1 / 60); R.getContext().finish(); inFrame = false; const ms = performance.now() - t;
        acc.g += R.info.memory.geometries - g0;
        acc.t -= Math.max(0, bones() - b0);
        return ms;
      };
      for (let i = 0; i < 20; i++) frame();
      const steady = med(Array.from({ length: 15 }, frame));
      const out = [];
      const kinds = [...ids.flatMap((id) => [[id, false], [id, true]]), ['thrall', false], [ids.includes('ghoul') ? 'ghoul' : ids[0], 'shrouded']];
      for (const [id, elite] of kinds) {
        if (only.length && !only.includes(id)) continue;
        d.clear(); d.freeze(true); for (let i = 0; i < 14; i++) { frame(); await sleep(40); }
        acc.t = acc.rt = acc.g = 0; acc.progs = []; acc.skinned = []; acc.static = 0; acc.fx = 0;
        const before = skins();
        if (id === 'thrall') d.raise('robber', 3, 1); else d.spawn(id, !!elite, elite === 'shrouded' ? 'shrouded' : elite ? 'bellTolled' : undefined);
        const ms = []; let appeared = false, appearedAt = -1;
        for (let i = 0; i < 150 && !(appeared && i > appearedAt + 6); i++) {
          ms.push(frame()); await sleep(25);
          if (id !== 'thrall') d.freeze(true);
          if (!appeared && skins() > before) { appeared = true; appearedAt = i; }
        }
        // What the window created, by who triggered it: a skinned mesh (a creature body: colour or skinned-depth program), a static mesh (props, world,
        // effect meshes), or Binbun shader effects (coldWarm's job).
        out.push({ id: id + (elite === 'shrouded' ? '+shrouded(informational)' : elite ? '+elite' : ''), newBodyPrograms: acc.skinned.length, bodyNames: acc.skinned, staticMeshPrograms: acc.static, effectPrograms: acc.fx, newTextures: acc.t, rtTextures: acc.rt, newGeometries: acc.g, firstMs: +ms[0].toFixed(1), maxMs: +Math.max(...ms).toFixed(1), steadyMs: +steady.toFixed(1), appeared });
      }
      out.unshift({ id: '(late stage pending when measuring)', n: stillPending, stageLog: wr.stageLog });
      return out;
    });
    for (const r of rows) console.log(JSON.stringify(r));
    const bad = rows.filter((r) => r.newBodyPrograms !== undefined && !r.id.includes('informational')).filter((r) => r.newBodyPrograms || r.newTextures);
    console.log(bad.length ? `NOT CLEAN: ${bad.length}/${rows.length - 1} spawns created body programs or textures (see rows)` : `CLEAN: ${rows.length - 1}/${rows.length - 1} spawns created 0 body programs (colour or skinned depth), 0 textures (static-mesh programs, geometry uploads, effect shaders and render targets are reported apart)`);
    await browser.close();
    return;
  }
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  const r = await page.evaluate(async ([NOW, NAMES]) => { window.__nowarm = NOW;
    const d = window.__cwDebug; d.god(true); d.unlockAll(); d.advance(0.5); d.clear(); d.freeze(true);
    const rt = (await import('/src/app/GameRuntime.ts')).getRuntime(); const v = rt.view; const R = rt.renderer;
    const { Creature } = await import('/src/graphics/Creature.ts'); const { assets } = await import('/src/graphics/AssetCache.ts');
    const NOWARM = !!window.__nowarm; if (NOWARM) (await import('/src/graphics/warmModel.ts')).setWarmContext(null);
    const out = {}; R.render(v.scene, v.camera); R.render(v.scene, v.camera); R.getContext().finish();
    window.__lt = []; new PerformanceObserver((l) => { for (const e of l.getEntries()) window.__lt.push(Math.round(e.duration)); }).observe({ type: 'longtask' });
    for (const key of NAMES) {
      const [slug, flag] = key.split(':');
      window.__lt.length = 0;
      let t = performance.now(); const cs = []; for (let i = 0; i < 6; i++) cs.push(new Creature(slug, slug === 'choir_wraith' || flag === 'spectral' ? { spectral: true, fallback: 'penitent' } : slug.startsWith('boss_') ? { fallback: 'prelate' } : {})); await Promise.all(cs.map(c => c.ready));
      const loadMs = Math.round(performance.now() - t);
      await new Promise(r => setTimeout(r, 50));
      const lt = [...window.__lt];
      for (const [i, c] of cs.entries()) { c.root.position.set(d.player.x + i - 3, 0, d.player.z + 3); v.scene.add(c.root); }
      const p0 = R.info.programs.length;
      t = performance.now(); R.render(v.scene, v.camera); R.getContext().finish(); const first = Math.round(performance.now() - t);
      t = performance.now(); R.render(v.scene, v.camera); R.getContext().finish(); const second = Math.round(performance.now() - t);
      out[key] = { loadMs, loadLongTasks: lt, firstRender: first, secondRender: second, newPrograms: R.info.programs.length - p0 };
      for (const c of cs) v.scene.remove(c.root);
    }
    return out;
  }, [!!process.env.DM_QA_NOWARM, (process.env.DM_QA_SLUGS || 'penitent,carrion_sac,bone_hound,choir_wraith,boss_gravedigger_king').split(',')]);
  for (const [k, v] of Object.entries(r)) console.log(k, JSON.stringify(v));
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
