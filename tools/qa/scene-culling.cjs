// Read-only audit: same fixed-fight scene; (1) what the 'other' draw calls are, (2) ideal per-instance culling of the instanced props vs what is drawn
// (main camera + shadow camera), (3) GPU texture / geometry memory estimate for what is loaded.
// Env: DM_QA_URL (default :5383), DM_QA_AREAS, DM_QA_QUALITY (high|low), DM_QA_VIEWPORT, DM_QA_OUT (json)
const fs = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5383/?offline';
const AREAS = (process.env.DM_QA_AREAS || 'nave').split(',');
const q = process.env.DM_QA_QUALITY || 'high';
const VIEW = (process.env.DM_QA_VIEWPORT || '1280x800').split('x').map(Number);
const OUT = process.env.DM_QA_OUT || '/tmp/dmaudit/culling.json';
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: VIEW[0], height: VIEW[1] } });
  page.setDefaultTimeout(150000);
  page.on('pageerror', (e) => console.error('pageerror', e.message));
  await page.addInitScript((qq) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: qq, tips: false, autoCombat: false })), q);
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `cul_${Date.now() % 1000000}`;
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
      const T = await import('/node_modules/three/build/three.module.js');
      const sc = rt.view; const scene = sc.scene; const r = rt.renderer; const cam = sc.rig.camera; const d = window.__cwDebug; d.advance(0.1);
      scene.updateMatrixWorld(true);
      const wv = sc.worldView.group;
      const worldSet = new Set(); wv.traverse((x) => worldSet.add(x));
      const entSet = new Set(); for (const m of [sc.views.enemies, sc.views.thralls, sc.views.corpses]) for (const v of m.values()) v.c.root.traverse((x) => entSet.add(x));
      for (const g of [sc.avatar?.root, sc.avatar?.group, sc.npcViews?.group, sc.nodeViews?.group, sc.loot?.group]) g && g.traverse((x) => entSet.add(x));
      // (1) other draw objects
      const other = {};
      scene.traverse((o) => {
        if (!(o.isMesh || o.isPoints || o.isSprite || o.isLine) || worldSet.has(o) || entSet.has(o)) return;
        let vis = true; for (let p = o; p; p = p.parent) if (!p.visible) vis = false; if (!vis) return;
        const mat = Array.isArray(o.material) ? o.material[0] : o.material;
        const g = o.geometry; const key = [o.type, g?.type, mat?.type, mat?.transparent ? 'transp' : 'opaque', mat?.blending === 2 ? 'additive' : '', o.parent?.name || o.parent?.type, o.isInstancedMesh ? 'inst' : ''].join(' | ');
        const t = g ? (g.index ? g.index.count : g.attributes.position?.count || 0) / 3 * (o.isInstancedMesh ? o.count : 1) : 0;
        const e = (other[key] ||= { n: 0, tris: 0 }); e.n++; e.tris += t;
      });
      // (2) ideal culling
      const fr = new T.Frustum(); const pm = new T.Matrix4();
      const frustumOf = (c) => { c.updateMatrixWorld(); pm.multiplyMatrices(c.projectionMatrix, c.matrixWorldInverse); const f = new T.Frustum(); f.setFromProjectionMatrix(pm); return f; };
      const camF = frustumOf(cam);
      let shF = null, shCam = null; scene.traverse((o) => { if (o.isDirectionalLight && o.castShadow && !shF) { o.shadow.updateMatrices(o); shCam = o.shadow.camera; shF = frustumOf(shCam); } });
      const m4 = new T.Matrix4(), sph = new T.Sphere(), c3 = new T.Vector3();
      let inst = { total: 0, drawnMain: 0, idealMain: 0, casterTotal: 0, idealShadow: 0, instances: 0, instMain: 0, instShadow: 0 };
      wv.traverse((o) => {
        if (!o.isInstancedMesh) return; const g = o.geometry; if (!g.boundingSphere) g.computeBoundingSphere();
        const t = (g.index ? g.index.count : g.attributes.position.count) / 3;
        inst.total += t * o.count; inst.instances += o.count; if (o.castShadow) inst.casterTotal += t * o.count;
        // is the whole batch inside the camera frustum? (what three actually tests)
        const bs = o.boundingSphere.clone().applyMatrix4(o.matrixWorld);
        const batchIn = camF.intersectsSphere(bs); if (batchIn) inst.drawnMain += t * o.count;
        for (let i = 0; i < o.count; i++) {
          o.getMatrixAt(i, m4); m4.premultiply(o.matrixWorld);
          sph.copy(g.boundingSphere).applyMatrix4(m4);
          if (camF.intersectsSphere(sph)) { inst.idealMain += t; inst.instMain++; }
          if (o.castShadow && shF && shF.intersectsSphere(sph)) { inst.idealShadow += t; inst.instShadow++; }
        }
      });
      // (3) memory
      const texs = new Set(), geos = new Set(); let skinnedMats = 0;
      scene.traverse((o) => { if (o.geometry) geos.add(o.geometry); const ms = o.material ? (Array.isArray(o.material) ? o.material : [o.material]) : []; for (const m of ms) for (const k in m) { const v = m[k]; if (v && v.isTexture) texs.add(v); } });
      let texBytes = 0, nTex = 0; const sizes = {};
      for (const t of texs) { const im = t.image; const w = im?.width || im?.videoWidth || 0, h = im?.height || 0; if (!w) continue; nTex++; const b = w * h * 4 * (t.generateMipmaps === false ? 1 : 1.333); texBytes += b; const k = w + 'x' + h; sizes[k] = (sizes[k] || 0) + 1; }
      let geoBytes = 0; for (const g of geos) { for (const a of Object.values(g.attributes)) geoBytes += a.array.byteLength; if (g.index) geoBytes += g.index.array.byteLength; }
      // (4) what are the additive plane draw calls? group by owner (nearest known entity root / world), texture, size, colour
      const roots = []; for (const [k, m] of [['enemy', sc.views.enemies], ['thrall', sc.views.thralls], ['corpse', sc.views.corpses]]) for (const v of m.values()) roots.push({ k, x: v.c.root.position.x, z: v.c.root.position.z });
      const planes = {}; const wp = new T.Vector3(), sc3 = new T.Vector3();
      scene.traverse((o) => {
        if (!o.isMesh || o.geometry?.type !== 'PlaneGeometry' || worldSet.has(o)) return;
        let vis = true; for (let p = o; p; p = p.parent) if (!p.visible) vis = false; if (!vis) return;
        const mat = o.material; o.getWorldPosition(wp); o.getWorldScale(sc3);
        let near = 'none', best = 1.2; for (const r of roots) { const dd = Math.hypot(r.x - wp.x, r.z - wp.z); if (dd < best) { best = dd; near = r.k; } }
        const key = [near, mat.map ? 'tex' : 'notex', mat.color ? '#' + mat.color.getHexString() : '', 'op' + (mat.opacity ?? 1).toFixed(2), 'sz' + (o.geometry.parameters.width * sc3.x).toFixed(1) + 'x' + (o.geometry.parameters.height * sc3.z || o.geometry.parameters.height * sc3.y).toFixed(1), 'y' + wp.y.toFixed(2), 'ro' + o.renderOrder, 'dw' + mat.depthWrite].join(' ');
        planes[key] = (planes[key] || 0) + 1;
      });
      // (5) texture MB by owner
      const own = (o) => (worldSet.has(o) ? (o.isInstancedMesh ? 'world props' : 'world architecture') : entSet.has(o) ? 'entities (creatures/avatar/npc/nodes)' : 'other');
      const byOwner = {}; const counted = new Set();
      scene.traverse((o) => { const ms = o.material ? (Array.isArray(o.material) ? o.material : [o.material]) : []; for (const m of ms) for (const k in m) { const v = m[k]; if (v && v.isTexture && v.image && !counted.has(v)) { counted.add(v); const w = v.image.width || 0, h = v.image.height || 0; const b = w * h * 4 * 1.333; const e = (byOwner[own(o)] ||= { n: 0, MB: 0 }); e.n++; e.MB += b / 1048576; } } });
      for (const e of Object.values(byOwner)) e.MB = +e.MB.toFixed(1);
      return { planes: Object.entries(planes).map(([k, n]) => ({ k, n })).sort((a, b) => b.n - a.n).slice(0, 25), byOwner, other: Object.entries(other).map(([k, v]) => ({ k, ...v })).sort((a, b) => b.n - a.n), inst, shadowCam: shCam ? { l: shCam.left, r: shCam.right, t: shCam.top, b: shCam.bottom, near: shCam.near, far: shCam.far } : null, mem: { textures: nTex, texMB: +(texBytes / 1048576).toFixed(1), sizes, geoMB: +(geoBytes / 1048576).toFixed(1), geometries: geos.size, rendererTextures: r.info.memory.textures }, camPos: cam.position.toArray(), fov: cam.fov };
    });
    all.push({ area, ...res });
    console.log('PLANES'); for (const p of res.planes) console.log(String(p.n).padStart(4), p.k); console.log('TEXBYOWNER', JSON.stringify(res.byOwner));
    console.log('INST', JSON.stringify(res.inst), 'SHADOWCAM', JSON.stringify(res.shadowCam)); console.log('MEM', JSON.stringify(res.mem));
    for (const o of res.other.slice(0, 25)) console.log(String(o.n).padStart(4), String(Math.round(o.tris)).padStart(7), o.k);
  }
  await browser.close();
  fs.writeFileSync(OUT, JSON.stringify(all, null, 1));
})().catch((e) => { console.error(e); process.exit(1); });
