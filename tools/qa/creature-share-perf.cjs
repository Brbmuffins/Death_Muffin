// Crowded-zone perf read for material/instancing work: a Gravecaller with a legion, N bodies of every roster kind in rings (frozen), corpses.
// Prints draw calls, triangles, programs, textures, geometries, unique materials on skinned meshes, update ms/frame, JS ms/frame of renderer.render
// (command encoding only; GPU time is not measured) and writes a screenshot. Optionally flashes every enemy (DM_QA_FLASH=1) to exercise hit-flash state.
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5378/?offline' DM_QA_AREA=graves DM_QA_PER=5 DM_QA_TAG=before node tools/qa/creature-share-perf.cjs
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5378/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'creature-share');
const AREA = process.env.DM_QA_AREA || 'graves';
const PER = +(process.env.DM_QA_PER || 8);
const TAG = process.env.DM_QA_TAG || 'run';
const READS = +(process.env.DM_QA_READS || 3);
fs.mkdirSync(OUT, { recursive: true });
const median = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(240000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `cs_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 120000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
  await page.evaluate((a) => { const d = window.__cwDebug; d.goto(a); d.advance(0.5); d.clear(); d.zoom(0.8); d.advance(1); }, AREA);
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
  const roster = await page.evaluate(async (a) => (await import('/server/rules/content/areas.ts')).AREAS[a].enemies.map((e) => e.id), AREA);
  await page.evaluate(([r, per]) => { const d = window.__cwDebug; r.forEach((id, i) => d.ring(id, per, 5 + i * 1.1, false)); d.freeze(true); d.advance(0.6); d.freeze(true); d.advance(1.5); }, [roster, PER]);
  await page.evaluate(() => { const d = window.__cwDebug; const p = d.player; for (let i = 0; i < 10; i++) d.sim().addCorpse(p.x + 4 + (i % 5) * 1.2, p.z - 3 - Math.floor(i / 5) * 1.5, 'normal', 'robber', false, 0, 1, p.area); d.advance(0.5); });
  // Wait for every body to finish loading (clone + warm): the skinned-mesh count has to hold still.
  let last = -1, stable = 0;
  for (let i = 0; i < 60 && stable < 3; i++) {
    const k = await page.evaluate(() => { const d = window.__cwDebug; d.advance(0.2); return d.perf(1).skinned; });
    stable = k === last ? stable + 1 : 0;
    last = k;
    await page.waitForTimeout(2000);
  }
  if (process.env.DM_QA_FLASH === '1') await page.evaluate(() => { for (const e of window.__cwDebug.sim().enemies.values()) e.flash = 1; window.__cwDebug.advance(0.01); });
  const reads = [];
  for (let i = 0; i < READS; i++) reads.push(await page.evaluate(async () => {
    const d = window.__cwDebug; const rt = (await import('/src/app/GameRuntime.ts')).getRuntime(); const r = rt.renderer;
    const p = d.perf(60);
    const sc = rt.view.scene; const cam = rt.view.rig.camera;
    const mats = new Set(); const progs = new Set();
    let flashed = 0;
    sc.traverse((o) => { if (o.isSkinnedMesh && o.visible) { if (o.material.emissive && o.material.emissive.r > 0.1) flashed++; const m = o.material; for (const x of Array.isArray(m) ? m : [m]) mats.add(x.uuid); } });
    // GL traffic of one frame, counted by wrapping the context's methods (deterministic, unlike software-GL time).
    const gl = r.getContext(); const proto = Object.getPrototypeOf(gl); const cnt = { uniform: 0, useProgram: 0, bindTexture: 0, draw: 0, other: 0 }; const orig = {};
    for (const k of Object.getOwnPropertyNames(proto)) { const dsc = Object.getOwnPropertyDescriptor(proto, k); if (!dsc || typeof dsc.value !== 'function' || k === 'constructor' || k === 'getError') continue; orig[k] = dsc.value;
      const bucket = k.startsWith('uniform') ? 'uniform' : k === 'useProgram' ? 'useProgram' : k === 'bindTexture' ? 'bindTexture' : k.startsWith('draw') ? 'draw' : 'other';
      proto[k] = function (...a) { cnt[bucket]++; return orig[k].apply(this, a); }; }
    r.shadowMap.needsUpdate = true; r.render(sc, cam);
    for (const k of Object.keys(orig)) proto[k] = orig[k];
    const t0 = performance.now(); const N = 15;
    for (let k = 0; k < N; k++) { r.shadowMap.needsUpdate = true; r.render(sc, cam); }
    const renderMs = (performance.now() - t0) / N;
    return { calls: p.calls, tris: p.triangles, ms: p.updateMs, programs: p.programs, textures: p.textures, geometries: p.geometries, skinnedMats: mats.size, flashed, glUniform: cnt.uniform, glUseProgram: cnt.useProgram, glBindTexture: cnt.bindTexture, glOther: cnt.other, skinned: p.skinned, renderMs, enemies: p.enemies, thralls: p.thralls, corpses: p.corpses };
  }));
  const rec = { tag: TAG, area: AREA, per: PER, skinned: reads[0].skinned, enemies: reads[0].enemies, thralls: reads[0].thralls, corpses: reads[0].corpses };
  for (const k of ['calls', 'tris', 'ms', 'programs', 'textures', 'geometries', 'skinnedMats', 'flashed', 'glUniform', 'glUseProgram', 'glBindTexture', 'glOther', 'renderMs']) rec[k] = +median(reads.map((r) => r[k])).toFixed(2);
  rec.errors = errors.slice(0, 3);
  console.log(JSON.stringify(rec));
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(OUT, `${TAG}-${AREA}.png`), timeout: 150000 });
  fs.appendFileSync(path.join(OUT, 'results.jsonl'), JSON.stringify(rec) + '\n');
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
