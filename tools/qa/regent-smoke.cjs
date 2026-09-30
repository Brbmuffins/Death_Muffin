/**
 * Cinder Regent smoke (offline preview, High quality): the Catacomb Warren, the Bone Coliseum and the Cinder Pyre: zone screenshots,
 * a mob-mix spawn in each, and page errors.
 *   npm run dev -- --host 127.0.0.1 --port 5199 --strictPort
 *   node tools/qa/regent-smoke.cjs
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

  const settle = async () => { await page.waitForTimeout(2200); await page.evaluate(() => window.__cwDebug.advance(0.05)); };
  await page.evaluate(() => {
    const d = window.__cwDebug;
    d.god(true);
    d.unlockAll();
    d.goto('pyre');
    d.advance(0.5);
    d.clear();
    d.boss('regent');
    d.zoom(0.85);
    for (let i = 0; i < 6; i++) d.advance(0.5);
  });
  await settle();
  await shot('regent-awake');
  // Step until a Conflagration is telegraphed, then look at the windup and at the eruption.
  const seen = await page.evaluate(() => {
    const d = window.__cwDebug;
    const b = d.sim().bosses.regent;
    for (let i = 0; i < 400; i++) {
      d.advance(0.1);
      if (b.pending.some((p) => p.kind === 'conflagration')) return { ok: true, targets: b.pending.find((p) => p.kind === 'conflagration').targets.length, phase: d.sim().bossState.phase };
    }
    return { ok: false };
  });
  console.log('conflagration', JSON.stringify(seen));
  assert.ok(seen.ok, 'no Conflagration was telegraphed');
  await page.evaluate(() => window.__cwDebug.advance(1.2));
  await settle();
  await shot('regent-windup');
  await page.evaluate(() => window.__cwDebug.advance(1.7));
  await settle();
  await shot('regent-eruption');
  assert.ok(models.every(([, s]) => s === 200 || s === 304), 'a model failed to load');
  assert.deepEqual(errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e)), [], 'page errors');
  await browser.close();
  console.log('ok — screenshots in', OUT);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
