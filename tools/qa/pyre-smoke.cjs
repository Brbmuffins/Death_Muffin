/**
 * Cinder Pyre smoke (offline preview, High quality): the zone and its props, the four fire mobs, fire effects (pools, slam, death)
 * and a perf check against the Cloister roster.
 *   npm run dev -- --host 127.0.0.1 --port 5199 --strictPort
 *   node tools/qa/pyre-smoke.cjs
 * Screenshots go to DM_QA_ARTIFACT_DIR (default: the system temp dir).
 */
const assert = require('node:assert/strict');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const OUT = process.env.DM_QA_ARTIFACT_DIR || os.tmpdir();

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(150000);
  const errors = [];
  const models = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  page.on('response', (r) => r.url().endsWith('.glb') && models.push([r.url().split('/').slice(-2).join('/'), r.status()]));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `pyqa_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('pyqa@example.invalid');
  await page.fill('#cw-pass', 'TestingPyre1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
  const shot = async (name) => page.screenshot({ path: path.join(OUT, `qa-${name}.png`) });

  const shots = [];
  process.on('exit', () => errors.length && console.log('PAGE ERRORS', errors.slice(0, 5)));
  const settle = async () => { await page.waitForTimeout(2200); await page.evaluate(() => window.__cwDebug.advance(0.4)); };

  // --- The zone.
  await page.evaluate(() => {
    const d = window.__cwDebug;
    d.god(true);
    d.unlockAll();
    d.goto('pyre');
    d.advance(0.5);
    d.clear();
    d.zoom(1);
    d.advance(1);
  });
  await settle();
  await shot('pyre-zone');
  assert.equal(await page.evaluate(() => window.__cwDebug.player.area), 'pyre');

  // --- The four mobs around the hero (frozen, so the models are seen at rest).
  await page.evaluate(() => {
    const d = window.__cwDebug;
    const p = d.player;
    ['cinder_husk', 'pyre_priest', 'cinderhound', 'slag_brute'].forEach((def, i) => {
      const e = d.sim().spawnEnemy(def, 'pyre', p.x + Math.sin(i * 1.57 + 0.4) * 3.6, p.z + Math.cos(i * 1.57 + 0.4) * 3.6, false, false);
      e.attackCd = 99;
    });
    d.freeze(true);
    d.zoom(0.55);
    d.advance(2);
  });
  await settle();
  await shot('pyre-mobs');

  // --- Live combat: priest coal + brute slam + husk death, screenshots mid-effect.
  const fx = await page.evaluate(() => {
    const d = window.__cwDebug;
    d.freeze(false);
    d.clear();
    const p = d.player;
    d.sim().spawnEnemy('pyre_priest', 'pyre', p.x + 5, p.z, false, false);
    d.sim().spawnEnemy('slag_brute', 'pyre', p.x - 3, p.z + 2, false, false);
    const husk = d.sim().spawnEnemy('cinder_husk', 'pyre', p.x, p.z - 3, false, false);
    d.zoom(0.7);
    for (let i = 0; i < 14; i++) d.advance(0.25);
    husk.hp = 0;
    d.advance(0.3);
    return { pools: [...d.sim().zones.values()].filter((z) => z.kind === 'ember').length };
  });
  await settle();
  await shot('pyre-fx');
  console.log('fx', JSON.stringify(fx));
  assert.ok(fx.pools > 0, 'no ember pools appeared');

  // --- Perf: 36 enemies, Cloister roster vs the Pyre roster.
  const perf = await page.evaluate(() => {
    const d = window.__cwDebug;
    const run = (defs, area) => {
      d.clear();
      d.advance(0.2);
      const p = d.player;
      for (let i = 0; i < 36; i++) {
        const e = d.sim().spawnEnemy(defs[i % defs.length], area, p.x + Math.sin(i) * (4 + (i % 5)), p.z + Math.cos(i) * (4 + (i % 5)), false, false);
        e.hp = e.maxHp = 1e6;
      }
      d.advance(1);
      const r = d.perf(120);
      return { calls: r.calls, triangles: r.triangles, updateMs: +r.updateMs.toFixed(3), programs: r.programs };
    };
    return { cloister: run(['plague_doctor', 'flagellant', 'sac', 'rat'], 'pyre'), pyre: run(['cinder_husk', 'pyre_priest', 'cinderhound', 'slag_brute'], 'pyre') };
  });
  console.log('perf', JSON.stringify(perf));
  console.log('models', JSON.stringify(models.filter(([f]) => /cinder|pyre|slag/.test(f))));
  assert.ok(models.every(([, s]) => s === 200 || s === 304), 'a model failed to load');
  assert.deepEqual(errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e)), [], 'page errors');
  await browser.close();
  console.log('ok — screenshots in', OUT);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
