// Culling diff harness: renders each frame normally, then again with every culling mechanism off, and pixel-diffs the two.
//  A  = the frame as the game draws it (after one real update step: streaming, occlusion, shadow focus)
//  B  = same state, render only, with: every built area group visible, frustumCulled=false on everything, occlusion uniform off
//  B1 = only the area groups forced visible; B2 = only frustumCulled off   (attribution when A!=B)
//  C  = occlusion off only (A vs C outside the hero's cut-out circle = the dither is hiding things it should not)
// Env: DM_QA_ENEMIES=1 rings the hero with frozen enemies (skinned-mesh culling), DM_QA_URL (default :5422), DM_QA_AREAS (default coliseum), DM_QA_ZOOMS, DM_QA_VIEWPORT (1280x800), DM_QA_OUT (dir), DM_QA_GRID (default 3 = 3x3 + border spots),
//      DM_QA_SAVE=1 saves A/B/diff PNGs for failing cases, DM_QA_THRESH (changed pixels per case that counts as a bug, default 150)
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5422/?offline';
const AREAS = (process.env.DM_QA_AREAS || 'coliseum').split(',');
const ZOOMS = (process.env.DM_QA_ZOOMS || '0.4,0.7,1,1.45,1.6').split(',').map(Number);
const VIEW = (process.env.DM_QA_VIEWPORT || '1280x800').split('x').map(Number);
const OUT = process.env.DM_QA_OUT || '/tmp/dm-culling';
const GRID = Number(process.env.DM_QA_GRID || 3);
const THRESH = Number(process.env.DM_QA_THRESH || 150);
fs.mkdirSync(OUT, { recursive: true });

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: VIEW[0], height: VIEW[1] } });
  page.setDefaultTimeout(240000);
  page.on('pageerror', (e) => console.error('pageerror', e.message));
  page.on('console', (m) => { if (m.type() === 'error' && !/403|font|favicon/i.test(m.text())) console.error('console.error', m.text().slice(0, 300)); });
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `cd_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 120000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });

  // Installs the in-page helper once.
  await page.evaluate(async () => {
    const rt = await import('/src/app/GameRuntime.ts');
    const occ = await import('/src/graphics/occlusion.ts');
    const d = window.__cwDebug;
    const AREAS = (await import('/src/content/areas.ts')).AREAS;
    const canvas = () => rt.getRuntime().renderer.domElement;
    const decode = async (url) => { const b = await (await fetch(url)).blob(); const bm = await createImageBitmap(b); const c = new OffscreenCanvas(bm.width, bm.height); const x = c.getContext('2d'); x.drawImage(bm, 0, 0); return x.getImageData(0, 0, bm.width, bm.height); };
    const grab = () => { rt.getRuntime().advance(0, 1 / 60, true); return canvas().toDataURL('image/png'); };
    const diff = (a, b, mask) => {
      const w = a.width, h = a.height; let count = 0; const cells = new Map(); const out = new Uint8ClampedArray(a.data.length);
      let minx = w, miny = h, maxx = 0, maxy = 0;
      for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        const i = (y * w + x) * 4;
        const dd = Math.max(Math.abs(a.data[i] - b.data[i]), Math.abs(a.data[i + 1] - b.data[i + 1]), Math.abs(a.data[i + 2] - b.data[i + 2]));
        if (dd > 24 && !(mask && mask(x, y, w, h))) {
          count++; out[i] = 255; out[i + 3] = 255;
          const k = `${x >> 6},${y >> 6}`; cells.set(k, (cells.get(k) || 0) + 1);
          if (x < minx) minx = x; if (x > maxx) maxx = x; if (y < miny) miny = y; if (y > maxy) maxy = y;
        } else { out[i] = a.data[i] * 0.4; out[i + 1] = a.data[i + 1] * 0.4; out[i + 2] = a.data[i + 2] * 0.4; out[i + 3] = 255; }
      }
      return { count, bbox: count ? [minx, miny, maxx, maxy] : null, cells: [...cells.entries()].filter(([, v]) => v > 40).map(([k]) => k), out };
    };
    const toUrl = (data, w, h) => { const c = document.createElement('canvas'); c.width = w; c.height = h; c.getContext('2d').putImageData(new ImageData(data, w, h), 0, 0); return c.toDataURL('image/png'); };
    window.__cd = {
      async run(keep) {
        const scene = d.scene;
        const groups = []; const all = [];
        scene.traverse((o) => { if (o.name && o.name.startsWith('area:')) groups.push(o); });
        scene.traverse((o) => all.push(o));
        const gVis = groups.map((g) => g.visible);
        const fc = all.map((o) => o.frustumCulled);
        const builtIds = d.stream().built;
        const forceGroups = () => groups.forEach((g) => { if (builtIds.includes(g.name.slice(5))) g.visible = true; });
        const restoreGroups = () => groups.forEach((g, i) => (g.visible = gVis[i]));
        const noFrustum = () => all.forEach((o) => (o.frustumCulled = false));
        const restoreFrustum = () => all.forEach((o, i) => (o.frustumCulled = fc[i]));
        // distance-gated shadow casting (props beyond SHADOW_RANGE of the hero): force tall props to cast, to see shadows that are cut
        const sc = all.map((o) => o.castShadow);
        const forceShadows = () => all.forEach((o) => { if (o.userData && o.userData.tallProp) o.castShadow = true; });
        const restoreShadows = () => all.forEach((o, i) => (o.castShadow = sc[i]));
        // Every comparison renders its own reference immediately before (the pentagram ring etc. animate on the wall clock, so an old reference would differ).
        const U = occ.occlusionUniforms; const wasOn = U.uOccOn.value;
        const pair = async (setup, restore, mask) => { const a = grab(); setup(); const b = grab(); restore(); const ia = await decode(a), ib = await decode(b); return { a, b, d: diff(ia, ib, mask(ia)) }; };
        const none = () => null;
        const full = await pair(() => { forceGroups(); noFrustum(); forceShadows(); }, () => { restoreGroups(); restoreFrustum(); restoreShadows(); }, none);
        const res = { ab: { count: full.d.count, bbox: full.d.bbox, cells: full.d.cells } };
        if (keep && !(full.d.count > 0)) res.A = full.a;
        if (full.d.count > 0) {
          const g = await pair(forceGroups, restoreGroups, none); const f = await pair(noFrustum, restoreFrustum, none); const sh = await pair(forceShadows, restoreShadows, none);
          res.groupsOnly = g.d.count; res.frustumOnly = f.d.count; res.shadowsOnly = sh.d.count;
          res.diffPng = toUrl(full.d.out, 0 + (await decode(full.a)).width, (await decode(full.a)).height);
          res.A = full.a; res.B = full.b;
        }
        // occlusion off, ignoring the hero's own cut-out circle (NDC radius * 1.15)
        const pl = U.uOccPlayer.value; const asp = U.uOccAspect.value;
        const heroMask = () => { const rad = U.uOccRadius.value * 1.15; return (x, y, w, h) => { const nx = (x / w) * 2 - 1, ny = 1 - (y / h) * 2; return Math.hypot((nx - pl.x) * asp, ny - pl.y) < rad; }; };
        const oc = await pair(() => { U.uOccOn.value = 0; }, () => { U.uOccOn.value = wasOn; }, heroMask);
        res.occ = { count: oc.d.count, bbox: oc.d.bbox, cells: oc.d.cells };
        if (oc.d.count > 0) { const w = (await decode(oc.a)).width, h = (await decode(oc.a)).height; res.occDiffPng = toUrl(oc.d.out, w, h); res.occA = oc.a; res.occC = oc.b; }
        // positive control: hiding the area the hero stands in MUST register
        const first = groups.find((g) => g.visible && g.name === 'area:' + d.player.area);
        const ctl = first ? await pair(() => { first.visible = false; }, () => { first.visible = true; }, none) : null;
        res.control = ctl ? ctl.d.count : -1;
        // Geometry-only coverage metrics (no pixels): share of the screen's ground that lies outside the moon's shadow box, and inside an area whose group is hidden.
        {
          const cam = d.camera; const moon = scene.children.find((o) => o.isDirectionalLight && o.castShadow);
          let n = 0, outShadow = 0, hiddenArea = 0; const o = cam.position;
          const inv = cam.projectionMatrixInverse; const mw = cam.matrixWorld;
          for (let i = 0; i <= 24; i++) for (let j = 0; j <= 14; j++) {
            const nx = (i / 24) * 2 - 1, ny = (j / 14) * 2 - 1;
            const v = { x: nx, y: ny, z: 0.5 }; // unproject by hand
            const e = inv.elements; const w = e[3] * v.x + e[7] * v.y + e[11] * v.z + e[15];
            const vx = (e[0] * v.x + e[4] * v.y + e[8] * v.z + e[12]) / w, vy = (e[1] * v.x + e[5] * v.y + e[9] * v.z + e[13]) / w, vz = (e[2] * v.x + e[6] * v.y + e[10] * v.z + e[14]) / w;
            const m = mw.elements; const wx = m[0] * vx + m[4] * vy + m[8] * vz + m[12], wy = m[1] * vx + m[5] * vy + m[9] * vz + m[13], wz = m[2] * vx + m[6] * vy + m[10] * vz + m[14];
            let dx = wx - o.x, dy = wy - o.y, dz = wz - o.z; if (dy > -1e-3) continue; const t = -o.y / dy; const gx = o.x + dx * t, gz = o.z + dz * t; n++;
            if (moon) { const sc = moon.shadow.camera; const l = sc.matrixWorldInverse.elements; const lx = l[0] * gx + l[8] * gz + l[12], ly = l[1] * gx + l[9] * gz + l[13]; if (Math.abs(lx) > sc.right || Math.abs(ly) > sc.top) outShadow++; }
            for (const [id, a] of Object.entries(AREAS)) { const r = a.rect; if (gx >= r.x0 && gx <= r.x1 && gz >= r.z0 && gz <= r.z1) { const g = groups.find((q) => q.name === 'area:' + id); if (g && !g.visible) hiddenArea++; } }
          }
          res.cover = { groundSamples: n, outsideShadowBoxPct: +(100 * outShadow / n).toFixed(1), hiddenAreaPct: +(100 * hiddenArea / n).toFixed(1) };
        }
        res.shown = d.stream().shown; res.built = d.stream().built;
        grab();
        return res;
      },
    };
  });

  if (process.env.DM_QA_ENEMIES) await page.evaluate(() => (window.__cdEnemies = true));
  const results = [];
  let bugs = 0;
  for (const area of AREAS) {
    const rect = await page.evaluate(async (a) => (await import('/src/content/areas.ts')).AREAS[a].rect, area);
    const spots = [];
    const xs = Array.from({ length: GRID }, (_, i) => rect.x0 + 2 + ((rect.x1 - rect.x0 - 4) * i) / Math.max(1, GRID - 1));
    const zs = Array.from({ length: GRID }, (_, i) => rect.z0 + 2 + ((rect.z1 - rect.z0 - 4) * i) / Math.max(1, GRID - 1));
    for (const x of xs) for (const z of zs) spots.push([x, z]);
    spots.push([(rect.x0 + rect.x1) / 2, (rect.z0 + rect.z1) / 2]);
    await page.evaluate((a) => { const d = window.__cwDebug; d.goto(a); d.advance(1); d.clear(); d.freeze(true); }, area);
    await page.waitForTimeout(6000);
    for (const z of ZOOMS) {
      for (const [x, zz] of spots) {
        await page.evaluate(([x, zz, z]) => { const d = window.__cwDebug; d.zoom(z); d.teleport(x, zz); d.advance(0.5); d.clear(); if (window.__cdEnemies) { for (const [def, n, r] of [['robber', 10, 9], ['rat', 12, 17], ['robber', 14, 27]]) d.ring(def, n, r); d.freeze(true); } d.advance(0.1); }, [x, zz, z]);
        const r = await page.evaluate((k) => window.__cd.run(k), process.env.DM_QA_SAVE === 'all');
        const tag = `${area}_z${z}_${Math.round(x)}_${Math.round(zz)}`;
        const row = { area, zoom: z, x: Math.round(x), z: Math.round(zz), ab: r.ab.count, bbox: r.ab.bbox, groupsOnly: r.groupsOnly, shadowsOnly: r.shadowsOnly, frustumOnly: r.frustumOnly, control: r.control, cover: r.cover, occOutsideHero: r.occ.count, occBbox: r.occ.bbox, shown: r.shown.join('|') };
        results.push(row);
        const bad = r.ab.count > THRESH || r.occ.count > THRESH;
        if (bad) bugs++;
        console.log(bad ? 'BUG ' : 'ok  ', JSON.stringify(row));
        if ((bad && process.env.DM_QA_SAVE) || process.env.DM_QA_SAVE === 'all') {
          const w = (k, u) => u && fs.writeFileSync(path.join(OUT, `${tag}_${k}.png`), Buffer.from(u.split(',')[1], 'base64'));
          w('A', r.A); w('B', r.B); w('diff', r.diffPng); w('occA', r.occA); w('occC', r.occC); w('occdiff', r.occDiffPng);
        }
      }
    }
  }
  fs.writeFileSync(path.join(OUT, 'results.json'), JSON.stringify(results, null, 1));
  console.log(`cases ${results.length}, failing ${bugs}`);
  await browser.close();
  process.exit(bugs ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(2); });
