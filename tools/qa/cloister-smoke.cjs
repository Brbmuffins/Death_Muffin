/**
 * Plague Cloister smoke (offline preview, High quality): the zone and its props, the new mobs, the Plague Saint's
 * Rot Rain, and a perf check against the Graves roster.
 *   npm run dev -- --host 127.0.0.1 --port 5199 --strictPort
 *   node tools/qa/cloister-smoke.cjs
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
  const errors = [];
  const models = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => m.type() === 'error' && errors.push(m.text()));
  page.on('response', (r) => r.url().endsWith('.glb') && models.push([r.url().split('/').slice(-2).join('/'), r.status()]));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `clqa_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('clqa@example.invalid');
  await page.fill('#cw-pass', 'TestingCloister1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
  const shot = async (name) => page.screenshot({ path: path.join(OUT, `qa-${name}.png`) });

  // --- The zone: walk in through the Sanctum door.
  await page.evaluate(() => {
    const d = window.__cwDebug;
    d.god(true);
    d.unlockAll();
    d.goto('cloister');
    d.advance(0.5);
    d.clear();
    d.zoom(1);
    d.advance(1);
  });
  await page.waitForTimeout(2500);
  await page.evaluate(() => window.__cwDebug.advance(0.5));
  await shot('cloister-zone');
  const area = await page.evaluate(() => window.__cwDebug.player.area);
  assert.equal(area, 'cloister');

  // --- The new mobs around the hero.
  await page.evaluate(() => {
    const d = window.__cwDebug;
    const p = d.player;
    ['plague_doctor', 'flagellant', 'plague_doctor', 'flagellant'].forEach((def, i) => {
      const e = d.sim().spawnEnemy(def, 'cloister', p.x + Math.sin(i * 1.57 + 0.4) * 3.5, p.z + Math.cos(i * 1.57 + 0.4) * 3.5, false, false);
      e.attackCd = 99;
    });
    d.freeze(true);
    d.zoom(0.55);
    d.advance(2);
  });
  await page.waitForTimeout(1500);
  await page.evaluate(() => window.__cwDebug.advance(0.5));
  await shot('cloister-mobs');

  // --- The Plague Saint: summon and let her rain.
  const boss = await page.evaluate(() => {
    const d = window.__cwDebug;
    d.freeze(false);
    d.clear();
    d.boss('saint');
    d.zoom(0.8);
    for (let i = 0; i < 16; i++) d.advance(0.5);
    const b = d.sim().bossState;
    return { id: b.id, active: b.active, pools: [...d.sim().zones.values()].filter((z) => z.hostile).length };
  });
  await page.waitForTimeout(2500);
  await page.evaluate(() => window.__cwDebug.advance(0.3));
  await shot('cloister-saint');
  console.log('boss', JSON.stringify(boss));
  assert.equal(boss.id, 'saint');
  assert.ok(boss.active, 'the Saint woke');

  // --- Perf: 36 enemies, Graves roster vs the Cloister roster.
  const perf = await page.evaluate(() => {
    const d = window.__cwDebug;
    d.sim().bosses.saint.state.active = false;
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
    return { graves: run(['robber', 'hound', 'penitent', 'rat'], 'cloister'), cloister: run(['plague_doctor', 'flagellant', 'sac', 'rat'], 'cloister') };
  });
  console.log('perf', JSON.stringify(perf));
  console.log('models', JSON.stringify(models.filter(([f]) => /plague|flagell|rot_garden|saints/.test(f))));
  assert.ok(models.every(([, s]) => s === 200 || s === 304), 'a model failed to load');
  assert.deepEqual(errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e)), [], 'page errors');
  await browser.close();
  console.log('ok — screenshots in', OUT);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
