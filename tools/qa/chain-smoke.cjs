/**
 * Kill Chain smoke (offline preview, High quality): a run of own kills in the Graves builds the chain HUD, tiers pay their bonus and a milestone is paid once.
 *   npm run dev -- --host 127.0.0.1 --port 5199 --strictPort
 *   node tools/qa/chain-smoke.cjs
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

  const settle = async () => { await page.waitForTimeout(2000); await page.evaluate(() => window.__cwDebug.advance(0.05)); };
  await page.evaluate(() => {
    const d = window.__cwDebug;
    d.god(true);
    d.unlockAll();
    d.goto('graves');
    d.advance(0.5);
    d.clear();
    d.zoom(0.8);
  });
  // Kill 14 enemies in a row as the player: one every 0.4 s.
  const out = await page.evaluate(() => {
    const d = window.__cwDebug;
    const p = d.player;
    const seen = [];
    for (let i = 0; i < 14; i++) {
      const e = d.sim().spawnEnemy('robber', 'graves', p.x + Math.sin(i) * 4, p.z + Math.cos(i) * 4, false, false);
      e.attackCd = 99;
      e.hp = 0;
      e.lastHitBy = d.self();
      d.advance(0.4);
      seen.push(document.querySelector('[data-chain-n]')?.textContent ?? '');
    }
    return { seen, lbl: document.querySelector('[data-chain-lbl]')?.textContent, hidden: document.querySelector('[data-chain]')?.hidden };
  });
  console.log('chain', JSON.stringify(out));
  const omen = await page.evaluate(() => ({ hidden: document.querySelector('[data-omen]')?.hidden, name: document.querySelector('[data-omen-name]')?.textContent, title: document.querySelector('[data-omen]')?.title }));
  console.log('omen', JSON.stringify(omen));
  assert.equal(omen.hidden, false, 'the omen chip should show');
  assert.equal(out.hidden, false, 'chain readout should be visible');
  assert.equal(out.seen[13], '×14');
  assert.match(out.lbl, /Rampage/);
  await settle();
  await shot('chain-hud');
  // Let it break.
  const after = await page.evaluate(() => {
    const d = window.__cwDebug;
    for (let i = 0; i < 12; i++) d.advance(0.5);
    return { hidden: document.querySelector('[data-chain]')?.hidden, claimed: localStorage.getItem(Object.keys(localStorage).find((k) => k.startsWith('dm_milestones_')) || '') };
  });
  console.log('after', JSON.stringify(after));
  assert.equal(after.hidden, true, 'chain readout should hide once broken');
  assert.ok(models.every(([, s]) => s === 200 || s === 304), 'a model failed to load');
  assert.deepEqual(errors.filter((e) => !/favicon|WebSocket|socket\.io|ERR_CONNECTION_REFUSED|Failed to load resource/.test(e)), [], 'page errors');
  await browser.close();
  console.log('ok — screenshots in', OUT);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
