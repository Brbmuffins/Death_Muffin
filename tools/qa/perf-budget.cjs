// Performance budget check: measures the fixed fight (same fixture as fixed-fight-perf.cjs / scene-categories.cjs) per tier and prints
// measured vs the contract in docs/PERF-BUDGET.md. Report-only by default (exit 0 even when over budget); `--strict` exits 1 on any
// over-budget row. It is expected to be over budget today: the budgets are the finish line for Performance Phase 1.
//
//   DM_PLAYWRIGHT_MODULE=... DM_CHROMIUM_PATH=... DM_QA_URL='http://127.0.0.1:5388/?offline' node tools/qa/perf-budget.cjs [--strict]
// Env: DM_QA_TIERS=desktop-high,desktop-low,phone   DM_QA_AREAS=nave (comma list, each is a "worst active-play view")
//      DM_QA_READS=3 (median of N CPU reads)        DM_QA_ARTIFACT_DIR (writes perf-budget.json + one screenshot per tier/area)
// Measured, per tier, in the fixed fight (five thralls, the zone roster in rings frozen in place, ten corpses):
//   calls      renderer.info.render.calls for one direct render (shadow pass included on High)
//   trisMain   triangles with shadows off; trisShadow = total with shadows on minus trisMain (0 where shadows are off)
//   texMB      estimated decoded texture memory of every texture the scene's materials reference (RGBA8 + mips)
//   jsMs       CPU cost of one game update (sim + views + effects, no rendering), median of N reads. Machine-load sensitive.
//   fetchMB    bytes of /models /art /fx /audio fetched from a cold start until the fight is on screen
//   payloadMB  size of those folders in public/ (what a full offline copy downloads)
// Frame time under SwiftShader is meaningless and is NOT measured; GPU cost on a phone needs a real device.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { preloadModules } = require('./lib/qa-common.cjs');

const STRICT = process.argv.includes('--strict');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5388/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'perf-budget');
const AREAS = (process.env.DM_QA_AREAS || 'nave').split(',');
const READS = +(process.env.DM_QA_READS || 3);
const ROOT = path.resolve(__dirname, '../..');

// The contract. Keep in step with docs/PERF-BUDGET.md.
const TIERS = [
  { id: 'desktop-high', label: 'Desktop High', quality: 'high', viewport: { width: 1280, height: 800 }, mobile: false,
    budget: { calls: 300, trisMain: 350000, trisShadow: 200000, texMB: 256, jsMs: 8, fetchMB: 60, payloadMB: 85 } },
  { id: 'desktop-low', label: 'Desktop Low', quality: 'low', viewport: { width: 1280, height: 800 }, mobile: false,
    budget: { calls: 220, trisMain: 350000, trisShadow: 0, texMB: 192, jsMs: 6, fetchMB: 50, payloadMB: 85 } },
  { id: 'phone', label: 'Phone (Low, 844x390)', quality: 'low', viewport: { width: 844, height: 390 }, mobile: true,
    budget: { calls: 150, trisMain: 300000, trisShadow: 0, texMB: 128, jsMs: 4, fetchMB: 40, payloadMB: 85 } },
];
const METRICS = [
  ['calls', 'Draw calls', '', 0],
  ['trisMain', 'Triangles, main pass', 'k', 0],
  ['trisShadow', 'Triangles, shadow pass', 'k', 0],
  ['texMB', 'Texture memory (decoded est.)', 'MB', 0],
  ['jsMs', 'JS update time per frame', 'ms', 2],
  ['fetchMB', 'Assets fetched to reach the fight', 'MB', 1],
  ['payloadMB', 'public/ asset payload on disk', 'MB', 1],
];
const median = (a) => [...a].sort((x, y) => x - y)[Math.floor(a.length / 2)];

function dirMB(dirs) {
  let bytes = 0;
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p); else bytes += fs.statSync(p).size; } };
  for (const d of dirs) if (fs.existsSync(path.join(ROOT, 'public', d))) walk(path.join(ROOT, 'public', d));
  return bytes / 1048576;
}

async function measure(browser, tier, area) {
  const ctx = await browser.newContext({ viewport: tier.viewport, isMobile: tier.mobile, hasTouch: tier.mobile, deviceScaleFactor: 1 });
  const page = await ctx.newPage();
  page.setDefaultTimeout(150000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  let fetched = 0;
  const pending = [];
  page.on('response', (r) => {
    const u = new globalThis.URL(r.url());
    if (!/^\/(models|art|fx|audio)\//.test(u.pathname)) return;
    const cl = +(r.headers()['content-length'] || 0);
    if (cl) fetched += cl; else pending.push(r.body().then((b) => { fetched += b.length; }).catch(() => {}));
  });
  await page.addInitScript((q) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: q, tips: false, autoCombat: false })), tier.quality);
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `pb_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingBudget1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
  await preloadModules(page, { areas: '/src/content/areas.ts' });
  await page.evaluate((a) => { const d = window.__cwDebug; d.goto(a); d.advance(0.5); d.clear(); d.zoom(0.8); d.advance(1); }, area);
  await page.evaluate(() => {
    const sc = window.__qaMods.runtime.getRuntime().view; const d = window.__cwDebug; const sim = d.sim();
    const m = sc.discipline.mods; const cap = m.thrallCap; const p = d.player;
    for (let i = 0; i < cap; i++) {
      const x = p.x - 3 + (i % 5) * 1.5, z = p.z + 2 + Math.floor(i / 5) * 1.5;
      sim.addCorpse(x, z, 'normal', 'robber', false, 0, 1, p.area);
      sim.applyExhume({ t: 'exhume', by: d.self(), x, z, r: 2, cap, kind: m.thrallKind, hp: 1e6, damage: 0, attackSpeedMult: 1 });
    }
    d.advance(1.5);
  });
  const roster = await page.evaluate((a) => window.__qaMods.areas.AREAS[a].enemies.map((e) => e.id), area);
  await page.evaluate((r) => { const d = window.__cwDebug; r.forEach((id, i) => d.ring(id, 3, 6 + i * 1.2, i === 0)); d.freeze(true); d.advance(0.6); d.freeze(true); }, roster);
  await page.evaluate(() => { const d = window.__cwDebug; const p = d.player; for (let i = 0; i < 10; i++) d.sim().addCorpse(p.x + 4 + (i % 5) * 1.2, p.z - 3 - Math.floor(i / 5) * 1.5, 'normal', 'robber', false, 0, 1, p.area); d.advance(0.3); });
  await page.waitForTimeout(500);
  await Promise.all(pending);
  const fetchMB = fetched / 1048576;

  const r = await page.evaluate(() => {
    const rt = window.__qaMods.runtime.getRuntime(); const sc = rt.view; const scene = sc.scene; const rd = rt.renderer; const d = window.__cwDebug;
    d.advance(0.1);
    const was = rd.shadowMap.enabled;
    const render = (shadow) => {
      rd.shadowMap.enabled = shadow; rd.shadowMap.needsUpdate = true;
      rd.info.autoReset = false; rd.info.reset(); rd.render(scene, sc.rig.camera);
      const o = { calls: rd.info.render.calls, tris: rd.info.render.triangles }; rd.info.autoReset = true; return o;
    };
    const cur = render(was);          // what the tier really draws
    const off = render(false);
    rd.shadowMap.enabled = was; rd.shadowMap.needsUpdate = true;
    // Decoded texture memory of every texture a material references (RGBA8; x4/3 with mips).
    const seen = new Set(); let bytes = 0;
    scene.traverse((o) => {
      for (const m of Array.isArray(o.material) ? o.material : [o.material]) {
        if (!m) continue;
        for (const k in m) {
          const t = m[k];
          if (!t || !t.isTexture || seen.has(t)) continue;
          seen.add(t);
          const im = t.image; const w = im?.width || im?.videoWidth || 0, h = im?.height || im?.videoHeight || 0;
          bytes += w * h * 4 * (t.generateMipmaps && t.minFilter !== 1003 && t.minFilter !== 1006 ? 4 / 3 : 1);
        }
      }
    });
    let lights = 0, casters = 0; scene.traverse((o) => { if (o.isLight) { lights++; if (o.castShadow) casters++; } });
    return { calls: cur.calls, trisTotal: cur.tris, trisMain: off.tris, trisShadow: was ? cur.tris - off.tris : 0, texMB: bytes / 1048576, texCount: seen.size,
      gpuTextures: rd.info.memory.textures, geometries: rd.info.memory.geometries, lights, shadowLights: casters, shadows: was, dpr: rd.getPixelRatio(), size: [window.innerWidth, window.innerHeight] };
  });
  fs.mkdirSync(OUT, { recursive: true });
  await page.screenshot({ path: path.join(OUT, `${tier.id}-${area}.png`), timeout: 60000 }).catch(() => {});
  // CPU reads last: each runs 60 sim frames, during which the thralls would thin out the frozen roster.
  const cpu = [];
  for (let i = 0; i < READS; i++) cpu.push(await page.evaluate(() => window.__cwDebug.perf(60).updateMs));
  await ctx.close();
  return { tier: tier.id, area, ...r, jsMs: median(cpu), fetchMB, errors };
}

(async () => {
  const wanted = (process.env.DM_QA_TIERS || TIERS.map((t) => t.id).join(',')).split(',');
  const payloadMB = dirMB(['models', 'art', 'fx', 'audio']);
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const results = [];
  let over = 0, pageErrors = 0;
  try {
    for (const tier of TIERS.filter((t) => wanted.includes(t.id))) {
      for (const area of AREAS) {
        const m = await measure(browser, tier, area);
        m.payloadMB = payloadMB;
        pageErrors += m.errors.length;
        console.log(`\n== ${tier.label} · ${area} · shadows ${m.shadows ? 'on' : 'off'} · DPR ${m.dpr} · ${m.size.join('x')} · ${m.texCount} textures (${m.gpuTextures} on GPU) · ${m.geometries} geometries · ${m.lights} lights (${m.shadowLights} cast)`);
        console.log('metric'.padEnd(36) + 'current'.padStart(12) + 'budget'.padStart(12) + '  status');
        const rows = [];
        for (const [key, label, unit, dp] of METRICS) {
          const v = m[key], b = tier.budget[key];
          const f = (x) => (unit === 'k' ? `${Math.round(x / 1000)}k` : `${x.toFixed(dp)}${unit ? ' ' + unit : ''}`);
          const bad = v > b;
          if (bad) over++;
          rows.push({ key, value: +v.toFixed(3), budget: b, over: bad });
          console.log(label.padEnd(36) + f(v).padStart(12) + ('<= ' + f(b)).padStart(12) + '  ' + (bad ? `OVER (${Math.round((v / b - 1) * 100)}%)` : 'ok'));
        }
        results.push({ ...m, rows });
      }
    }
  } finally { await browser.close(); }
  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(path.join(OUT, 'perf-budget.json'), JSON.stringify(results, null, 1));
  console.log(`\n${over} budget rows over, ${pageErrors} page errors. ${STRICT ? '(--strict)' : '(report only; pass --strict to fail on over-budget rows)'}\nwrote ${OUT}`);
  process.exit(pageErrors ? 1 : STRICT && over ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
