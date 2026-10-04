'use strict';
// Screenshots for the Discord dev agent (run by shot.sh inside its no-network sandbox, against the branch's own dev server).
// Reads a scenario the agent wrote (.dm-shot.json in the worktree) and writes PNGs to .dm-shots/ there. The runner posts them in the
// thread and on the proposal, so people can see a change before they approve it.
//
// Scenario: { "discipline": "Ossuary", "shots": [ { "name": "vault", "area": "chapterhouse", "at": [x, z], "give": ["item_id"],
//   "gold": 500, "steps": [ { "key": "v" }, { "wait": 1 }, { "click": "[data-take-all]" }, { "eval": "js run in the page" } ],
//   "clip": "css selector to crop to (optional)" } ] }
// Steps run in order; `wait` advances the game clock (seconds). At most 4 shots and 30 steps each.
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE);

const WT = process.env.DM_SHOT_WT;
const URL = process.env.DM_SHOT_URL;
const OUT = path.join(WT, '.dm-shots');
const name = (s, i) => String(s || `shot-${i + 1}`).toLowerCase().replace(/[^a-z0-9-]+/g, '-').slice(0, 40) || `shot-${i + 1}`;

(async () => {
  const sc = JSON.parse(fs.readFileSync(path.join(WT, process.env.DM_SHOT_FILE || '.dm-shot.json'), 'utf8'));
  const shots = (Array.isArray(sc.shots) ? sc.shots : [sc]).slice(0, 4);
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  page.setDefaultTimeout(180000);
  const errors = [];
  page.on('pageerror', (e) => errors.push(String(e.message || e)));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false, guidance: false })));
  await page.goto(URL);
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  const n = `shot_${Date.now() % 1000000}`;
  await page.fill('#cw-user', n);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill(`${n}@example.invalid`);
  await page.fill('#cw-pass', 'ShotTaker1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: String(sc.discipline || 'Ossuary') }).first().click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded && !document.querySelector('.dm-loadveil'), null, { timeout: 180000 });
  await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); });
  for (const [i, s] of shots.entries()) {
    const file = path.join(OUT, `${name(s.name, i)}.png`);
    try {
      await page.keyboard.press('Escape').catch(() => {});
      await page.evaluate(async (s) => {
        const d = window.__cwDebug;
        if (s.area) d.goto(s.area);
        if (Array.isArray(s.at)) d.teleport(+s.at[0], +s.at[1]);
        for (const id of [].concat(s.give || [])) d.inventory.add({ item_id: String(id), quantity: 1 });
        if (s.gold) d.gold(+s.gold);
        d.advance(1.5);
      }, s);
      for (const st of (Array.isArray(s.steps) ? s.steps : []).slice(0, 30)) {
        if (st.key) await page.keyboard.press(String(st.key));
        else if (st.click) await page.locator(String(st.click)).first().click({ timeout: 15000 });
        else if (st.wait) await page.evaluate((w) => window.__cwDebug.advance(Math.min(10, +w || 0.5)), st.wait);
        else if (st.eval) await page.evaluate((code) => (0, eval)(code), String(st.eval));
        await page.evaluate(() => window.__cwDebug.advance(0.2));
      }
      const clip = s.clip ? await page.locator(String(s.clip)).first().boundingBox().catch(() => null) : null;
      const pad = 12;
      await page.screenshot({ path: file, timeout: 60000, ...(clip ? { clip: { x: Math.max(0, clip.x - pad), y: Math.max(0, clip.y - pad), width: Math.min(1280, clip.width + 2 * pad), height: Math.min(800, clip.height + 2 * pad) } } : {}) });
      console.log(`shot ${path.relative(WT, file)}${s.clip && !clip ? ' (clip selector not found: full screen)' : ''}`);
    } catch (e) {
      console.log(`shot ${name(s.name, i)} FAILED: ${String(e.message || e).split('\n')[0]}`);
    }
  }
  if (errors.length) console.log(`page errors:\n${[...new Set(errors)].slice(0, 5).join('\n')}`);
  await browser.close();
})().catch((e) => { console.error(`shot failed: ${String(e.message || e).split('\n')[0]}`); process.exit(1); });
