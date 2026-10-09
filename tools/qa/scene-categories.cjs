// Read-only audit: same fixed-fight scene as fixed-fight-perf.cjs; attributes draw calls / triangles to categories by hiding each category
// and measuring the renderer.info delta (main pass = shadows off, shadow pass = shadows-on minus shadows-off).
// Env: DM_QA_URL (default :5383), DM_QA_AREAS, DM_QA_QUALITY (high|low), DM_QA_VIEWPORT, DM_QA_OUT (json)
const fs = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5383/?offline';
const AREAS = (process.env.DM_QA_AREAS || 'nave').split(',');
const q = process.env.DM_QA_QUALITY || 'high';
const VIEW = (process.env.DM_QA_VIEWPORT || '1280x800').split('x').map(Number);
const OUT = process.env.DM_QA_OUT || '/tmp/dmaudit/categories.json';
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: VIEW[0], height: VIEW[1] } });
  page.setDefaultTimeout(150000);
  page.on('pageerror', (e) => console.error('pageerror', e.message));
  await page.addInitScript((qq) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: qq, tips: false, autoCombat: false })), q);
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `cat_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
  const all = [];
  for (const area of AREAS) {
    await page.evaluate((a) => { const d = window.__cwDebug; d.goto(a); d.advance(0.5); d.clear(); d.zoom(0.8); d.advance(1); }, area);
    await page.evaluate(async () => {
      const sc = (await import('/src/app/GameRuntime.ts')).getRuntime().view; const d = window.__cwDebug; const sim = d.sim();
      const m = sc.discipline.mods; const cap = m.thrallCap; const p = d.player;
      for (let i = 0; i < cap; i++) {
        const x = p.x - 3 + (i % 5) * 1.5, z = p.z + 2 + Math.floor(i / 5) * 1.5;
        sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, p.area);
        sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap, kind: m.thrallKind, hp: 1e6, damage: 0, attackSpeedMult: 1 });
      }
      d.advance(1.5);
    });
    const roster = await page.evaluate(async (a) => (await import('/server/rules/content/areas.ts')).AREAS[a].enemies.map((e) => e.id), area);
    await page.evaluate((r) => { const d = window.__cwDebug; r.forEach((id, i) => d.ring(id, 3, 6 + i * 1.2, i === 0)); d.freeze(true); d.advance(0.6); d.freeze(true); }, roster);
    await page.evaluate(() => { const d = window.__cwDebug; const p = d.player; for (let i = 0; i < 10; i++) d.sim().addCorpse(p.x + 4 + (i % 5) * 1.2, p.z - 3 - Math.floor(i / 5) * 1.5, 'normal', 'robber', false, 0, 1, p.area); d.advance(0.3); });
    await page.waitForTimeout(500);
    const res = await page.evaluate(async () => {
      const rt = (await import('/src/app/GameRuntime.ts')).getRuntime();
      const sc = rt.view; const scene = sc.scene; const r = rt.renderer; const d = window.__cwDebug; d.advance(0.1);
      const roots = (map) => [...(map?.values?.() ?? [])].map((v) => v.c?.root).filter(Boolean);
      const sets = {};
      const collect = (name, objs) => { const s = (sets[name] ||= new Set()); for (const o of objs) o && o.traverse((x) => s.add(x)); };
      collect('enemies', roots(sc.views.enemies));
      collect('thralls', roots(sc.views.thralls));
      collect('corpses', roots(sc.views.corpses));
      collect('player', [sc.avatar?.root ?? sc.avatar?.group, sc.avatar?.c?.root]);
      collect('npcs', [sc.npcViews?.group]);
      collect('nodes(gather)', [sc.nodeViews?.group]);
      collect('loot', [sc.loot?.group]);
      collect('bosses', [...(sc.bossViews?.values?.() ?? [])].map((b) => b.c?.root));
      collect('laborers', [sc.laborers?.group]);
      // world view: instanced prop batches vs. rest
      const wv = sc.worldView.group; const wprops = new Set(), wrest = new Set();
      wv.traverse((x) => { if (x.isInstancedMesh) wprops.add(x); else wrest.add(x); });
      sets['world:prop batches (instanced GLB props)'] = wprops;
      const geo = new Set(); wv.traverse((x) => { if ((x.isMesh) && !x.isInstancedMesh) geo.add(x); });
      sets['world:architecture meshes (floors/walls/gates/etc)'] = geo;
      const wpts = new Set(); wv.traverse((x) => { if (x.isPoints || x.isSprite) wpts.add(x); });
      sets['world:flames/mist points'] = wpts;
      // everything else
      const claimed = new Set(); Object.values(sets).forEach((s) => s.forEach((x) => claimed.add(x)));
      const rest = new Set(); scene.traverse((x) => { if ((x.isMesh || x.isPoints || x.isSprite || x.isLine) && !claimed.has(x)) rest.add(x); });
      sets['other (effects/VFX/decals/rings/etc)'] = rest;
      const measure = (shadow) => {
        r.shadowMap.enabled = shadow; r.shadowMap.needsUpdate = true;
        r.info.autoReset = false; r.info.reset(); r.render(scene, sc.rig.camera);
        const o = { calls: r.info.render.calls, tris: r.info.render.triangles }; r.info.autoReset = true; return o;
      };
      const shadowWas = r.shadowMap.enabled;
      const base = { on: measure(true), off: measure(false) };
      const rows = [];
      for (const [name, set] of Object.entries(sets)) {
        const meshes = [...set].filter((x) => x.isMesh || x.isPoints || x.isSprite || x.isLine);
        const vis = meshes.map((m) => m.visible); meshes.forEach((m) => (m.visible = false));
        const on = measure(true), off = measure(false);
        meshes.forEach((m, i) => (m.visible = vis[i]));
        let inst = 0, skinned = 0, plain = 0; meshes.forEach((m) => { if (m.isInstancedMesh) inst++; else if (m.isSkinnedMesh) skinned++; else plain++; });
        rows.push({ name, objects: meshes.length, inst, skinned, plain, mainCalls: base.off.calls - off.calls, mainTris: base.off.tris - off.tris, shadowCalls: (base.on.calls - base.off.calls) - (on.calls - off.calls), shadowTris: (base.on.tris - base.off.tris) - (on.tris - off.tris) });
      }
      r.shadowMap.enabled = shadowWas;
      // per-slug census for enemies/thralls
      const slugs = {};
      for (const [k, map] of [['enemies', sc.views.enemies], ['thralls', sc.views.thralls], ['corpses', sc.views.corpses]]) for (const v of map.values()) { const key = k + ':' + (v.def || v.c?.slug || '?'); slugs[key] = (slugs[key] || 0) + 1; }
      // instanced props census: geometry tris, instance count, in-range (distance to camera) etc
      const propRows = [];
      wv.traverse((x) => { if (x.isInstancedMesh) { const g = x.geometry; const t = (g.index ? g.index.count : g.attributes.position.count) / 3; propRows.push({ tris: Math.round(t), inst: x.count, cast: x.castShadow, total: Math.round(t * x.count) }); } });
      propRows.sort((a, b) => b.total - a.total);
      return { base, rows, slugs, propRows: propRows.slice(0, 25), propTotals: { batches: propRows.length, tris: propRows.reduce((a, b) => a + b.total, 0), inst: propRows.reduce((a, b) => a + b.inst, 0) }, area: sc.player?.area };
    });
    res.areaName = area; res.quality = q;
    all.push(res);
    console.log(`== ${q} ${area} base shadows-on`, JSON.stringify(res.base.on), 'off', JSON.stringify(res.base.off), 'propTotals', JSON.stringify(res.propTotals));
    for (const x of res.rows) console.log(x.name.padEnd(52), 'obj', String(x.objects).padStart(4), 'main', String(x.mainCalls).padStart(4) + 'c', String(x.mainTris).padStart(8) + 't', ' shadow', String(x.shadowCalls).padStart(4) + 'c', String(x.shadowTris).padStart(8) + 't');
    console.log('slugs', JSON.stringify(res.slugs));
    await page.screenshot({ path: `/tmp/dmaudit/${q}-${area}-cat.png` });
  }
  await browser.close();
  fs.writeFileSync(OUT, JSON.stringify(all, null, 1));
})().catch((e) => { console.error(e); process.exit(1); });
