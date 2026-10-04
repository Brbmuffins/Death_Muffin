// GPU-memory leak smoke: fights N waves with auto-combat and prints renderer.info.memory textures/geometries after each wave.
// Fails when the counts keep climbing after a warm-up (new content is cached per kind, so a steady fight must plateau).
//   DM_PLAYWRIGHT_MODULE=... DM_QA_URL='http://127.0.0.1:5352/?offline' node tools/qa/gpu-leak-smoke.cjs
// Env: DM_QA_WAVES (default 12)  DM_QA_AREA (default graves)  DM_QA_WAVE_SIZE (default 8)  DM_QA_WARMUP (waves ignored, default 3)
//      DM_QA_TEX_SLACK / DM_QA_GEO_SLACK (allowed growth after warm-up, default 12 / 20)  DM_QA_ARTIFACT_DIR (writes gpu-leak.json)
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5352/?offline';
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'gpu-leak');
const WAVES = +(process.env.DM_QA_WAVES || 12), AREA = process.env.DM_QA_AREA || 'graves', SIZE = +(process.env.DM_QA_WAVE_SIZE || 8), WARM = +(process.env.DM_QA_WARMUP || 8);
const TEX_SLACK = +(process.env.DM_QA_TEX_SLACK || 12), GEO_SLACK = +(process.env.DM_QA_GEO_SLACK || 20);
fs.mkdirSync(OUT, { recursive: true });

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 960, height: 600 } });
  page.setDefaultTimeout(150000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  const glbs = new Map(); let glbOn = false; // model/texture files fetched during the measured waves: a re-fetch is a cache miss
  page.on('request', (r) => { if (glbOn && /\.(glb|png|jpe?g|webp)(\?|$)/.test(r.url())) glbs.set(r.url().split('/').slice(-2).join('/'), (glbs.get(r.url().split('/').slice(-2).join('/')) || 0) + 1); });
  if (process.env.DM_QA_TEXLOG) await page.addInitScript(() => { globalThis.__texLog = []; });
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: true })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `gl_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'TestingTour1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded && !document.querySelector('.dm-loadveil'), null, { timeout: 120000 });
  await page.evaluate((a) => { const d = window.__cwDebug; d.god(true); d.unlockAll(); d.goto(a); d.advance(1); d.clear(); }, AREA);
  const roster = await page.evaluate(async (a) => (await import('/src/content/areas.ts')).AREAS[a].enemies.map((e) => e.id), AREA);
  const rows = [];
  const read = () => page.evaluate(() => { const r = window.__cwDebug.perf(1); return { tex: r.textures, geo: r.geometries, enemies: window.__cwDebug.counts().enemies }; });
  rows.push({ wave: 0, kills: 0, ...(await read()) });
  let kills = 0, warmSnap = new Map();
  const liveByCreator = async () => {
    await page.evaluate(async () => { window.__qaRt = (await import('/src/app/GameRuntime.ts')).getRuntime(); });
    const entries = await page.evaluate(() => {
      const props = window.__qaRt.renderer.properties, g = new Map();
      for (const r of globalThis.__texLog || []) {
        if (!props.get(r.t).__webglTexture) continue; // uploaded and not freed (whether or not it was ever disposed)
        const k = r.s.split('\n').slice(2, 7).map((l) => l.trim().replace(/^at /, '').replace(/\(?https?:\/\/[^/]+/, '(').replace(/\?[tv]=\w+/g, '')).join(' <- ');
        g.set(k, (g.get(k) || 0) + 1);
      }
      return [...g.entries()];
    });
    return new Map(entries);
  };
  for (let w = 1; w <= WAVES; w++) {
    const spawned = await page.evaluate(([r, size]) => { const d = window.__cwDebug; let c = 0; for (let i = 0; i < size; i++) c += d.ring(r[i % r.length], 1, 4 + (i % 3), i % 7 === 6).length; return c; }, [roster, SIZE]);
    for (let t = 0; t < 60; t++) {
      const left = await page.evaluate(() => { const d = window.__cwDebug; d.advance(1); return d.counts().enemies; });
      if (!left) break;
      if (t > 8 && t % 4 === 0) await page.evaluate(() => { const d = window.__cwDebug; for (const e of d.sim().enemies.values()) if (e.state !== 'dead') e.hp = 0; });
    }
    kills += spawned;
    // Settle: kill stragglers (the count must not include live bodies), let corpses/dying views finish, then drop the corpses.
    await page.evaluate(() => { const d = window.__cwDebug; for (const e of d.sim().enemies.values()) if (e.state !== 'dead') e.hp = 0; d.advance(6); d.clear(); d.advance(3); d.clear(); d.advance(2); });
    const row = { wave: w, kills, ...(await read()) };
    rows.push(row);
    if (w === WARM) glbOn = true;
    if (w === WARM && process.env.DM_QA_TEXLOG) warmSnap = await liveByCreator();
    console.log(`wave ${w} kills=${kills} textures=${row.tex} geometries=${row.geo} enemiesLeft=${row.enemies}`);
  }
  if (process.env.DM_QA_TEXLOG) {
    // Needs a three build patched to push every Texture into globalThis.__texLog (see tools/qa/README.md); groups what is still on the GPU by creator.
    const end = await liveByCreator();
    console.log('live textures by creator, growth since warm-up:');
    const diff = [...end.entries()].map(([k, c]) => [k, c - (warmSnap.get(k) || 0)]).filter(([, d]) => d > 0).sort((x, y) => y[1] - x[1]).slice(0, 12);
    for (const [k, c] of diff) console.log(String(c).padStart(5), k);
  }
  await browser.close();
  fs.writeFileSync(path.join(OUT, 'gpu-leak.json'), JSON.stringify(rows, null, 1));
  const base = rows[Math.min(WARM, rows.length - 1)], last = rows[rows.length - 1];
  const dT = last.tex - base.tex, dG = last.geo - base.geo;
  console.log(`after warm-up (wave ${base.wave}) -> wave ${last.wave}: textures ${dT >= 0 ? '+' : ''}${dT}, geometries ${dG >= 0 ? '+' : ''}${dG}`);
  if (glbs.size) console.log('files fetched after warm-up:', JSON.stringify([...glbs.entries()].slice(0, 25)));
  let failed = 0;
  if (dT > TEX_SLACK) { console.log(`FAIL textures grew by ${dT} (> ${TEX_SLACK})`); failed++; }
  if (dG > GEO_SLACK) { console.log(`FAIL geometries grew by ${dG} (> ${GEO_SLACK})`); failed++; }
  if (errors.length) { console.log('page errors:', errors.slice(0, 5)); failed++; }
  if (!failed) console.log('ok   no texture/geometry growth under sustained combat');
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
