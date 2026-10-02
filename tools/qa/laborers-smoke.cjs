// Visible Grave Laborers: assigns all four laborers in the offline mock, enters the Acre, checks placement/animation/hover/ready marker
// and writes close-up screenshots. Run against `npm run dev -- --host 127.0.0.1 --port 5325 --strictPort` (DM_QA_URL overrides).
const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const artifactDir = process.env.DM_QA_ARTIFACT_DIR || require('node:os').tmpdir();
const { watchErrors } = require('./lib/qa-common.cjs');
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5325/?offline';
const POSTS = [['woodcutting', 'coffin_oak'], ['mining', 'seam_iron'], ['gravedigging', 'grave_crypt'], ['fishing', 'pool_carp']];

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = { shots: [] };
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    page.setDefaultTimeout(120000);
    const { errors, bad } = watchErrors(page); // @fontsource 403s are ignored (node_modules symlinked outside the Vite root)
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false, autoGather: false })));
    await page.goto(URL);
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', 'laborer_qa'); await page.fill('#cw-email', 'laborer_qa@example.invalid'); await page.fill('#cw-pass', 'TestingControls');
    await page.locator('#cw-login-btn').click(); await page.locator('.cw-disc').first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded);
    await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.skill('woodcutting', 50); d.skill('mining', 50); d.skill('gravedigging', 50); d.skill('fishing', 40); });

    // Baseline: the Acre with no laborers assigned.
    const sample = async () => page.evaluate(() => {
      const d = window.__cwDebug; let sum = 0; const n = 30;
      for (let i = 0; i < n; i++) { d.advance(0.1, true); sum += d.counts().frameMs; }
      return { frameMs: +(sum / n).toFixed(2), counts: d.counts() };
    });
    await page.evaluate(() => window.__cwDebug.teleport(-40, 20));
    out.before = await sample();
    assert.deepEqual(await page.evaluate(() => window.__cwDebug.laborers()), [], 'no laborers drawn before any are assigned');

    // Assign through the real panel.
    await page.keyboard.press('h');
    await page.waitForSelector('.cw-labor [data-post="3"]');
    for (let slot = 0; slot < 4; slot++) {
      await page.selectOption(`.cw-labor [data-post="${slot}"]`, POSTS[slot][1]);
      await page.$eval(`.cw-labor [data-send="${slot}"]`, b => b.click());
      await page.waitForSelector(`.cw-labor [data-recall="${slot}"]`);
    }
    await page.screenshot({ path: path.join(artifactDir, 'laborers-panel.png') });
    await page.keyboard.press('h');
    // Age the posts in the offline db: slot 0 working, 1 ready (3 h), 2 ready (3 h 12 m), 3 full (9 h).
    await page.evaluate(() => {
      const db = JSON.parse(localStorage.getItem('dm_offline_db_v1'));
      const ago = [5 * 60e3, 3 * 3600e3, 3 * 3600e3 + 12 * 60e3, 9 * 3600e3];
      for (const acc of Object.values(db.accounts)) if (acc.labor) for (const [s, row] of Object.entries(acc.labor)) row.startedAt = Date.now() - ago[s];
      localStorage.setItem('dm_offline_db_v1', JSON.stringify(db));
    });
    await page.keyboard.press('h'); await page.waitForFunction(() => document.querySelector('.cw-labor')?.textContent.includes('(full)')); await page.keyboard.press('h');
    await page.evaluate(() => window.__cwDebug.advance(2.5, true));
    const labs = await page.evaluate(() => window.__cwDebug.laborers());
    out.laborers = labs;
    assert.equal(labs.length, 4, 'four laborers created');
    assert.equal(new Set(labs.map(l => l.model)).size, 4, 'distinct models');
    for (const l of labs) {
      assert.ok(l.loaded && l.visible, `slot ${l.slot} loaded`);
      assert.ok(Math.hypot(l.x - l.nodeX, l.z - l.nodeZ) >= 1.3, `slot ${l.slot} not on its node`);
      assert.ok(l.tools.length === 1, `slot ${l.slot} holds a tool: ${l.tools}`);
    }
    assert.deepEqual(labs.map(l => l.ready), [true, true, true, true], 'ready flags');
    assert.equal(labs[3].mode, 'rest', 'full laborer rests');
    assert.equal(labs[0].mode, 'work');
    out.after = await sample();

    // Wide shot.
    await page.evaluate(() => { window.__cwDebug.teleport(-42, 22); window.__cwDebug.zoom(1.7); window.__cwDebug.advance(0.5, true); });
    await page.screenshot({ path: path.join(artifactDir, 'laborers-wide.png') }); out.shots.push('laborers-wide.png');

    // Close-ups, mid-swing (the hero is hidden so only the laborer and node are in frame).
    await page.evaluate(async () => { (await import('/src/app/GameRuntime.ts')).getRuntime().view.avatar.c.root.visible = false; });
    for (const l of labs) {
      // The camera looks 1.5 north of the player: stand 1.5 south of the laborer to centre it (hero hidden).
      await page.evaluate(([x, z]) => { window.__cwDebug.teleport(x, z); window.__cwDebug.zoom(0.55); }, [l.x, l.z + 1.5]);
      await page.evaluate(() => window.__cwDebug.advance(1.2, true));
      // Advance until the chop is mid-swing (or just advance for the others).
      await page.evaluate(() => window.__cwDebug.advance(1.2, true));
      if (l.type !== 'grave_crypt' && l.type !== 'pool_carp') {
        for (let i = 0; i < 40; i++) {
          const h = await page.evaluate(s => window.__cwDebug.laborers()[s].head, l.slot);
          if (h > 1.7 && h < 2.2) break;
          await page.evaluate(() => window.__cwDebug.advance(0.05, true));
        }
      }
      const name = `laborer-${l.slot}-${l.type}.png`;
      const at = await page.evaluate(s => { const d = window.__cwDebug; const p = d.hoverLaborer(s); d.mouse(0, 0); return p; }, l.slot);
      await page.evaluate(() => window.__cwDebug.advance(0.02, true));
      const clip = { x: Math.max(0, at[0] - 260), y: Math.max(0, at[1] - 260), width: 520, height: 380 };
      await page.screenshot({ path: path.join(artifactDir, name), clip }); out.shots.push(name);
      // Hover card.
      const pt = await page.evaluate(s => window.__cwDebug.hoverLaborer(s), l.slot);
      assert.ok(pt, `hover point for slot ${l.slot}`);
      await page.evaluate(() => window.__cwDebug.advance(0.05, true));
      const tip = await page.locator('[data-nodetip]').innerText();
      assert.ok(tip.startsWith('Grave Laborer'), `tip: ${tip}`);
      out['tip' + l.slot] = tip.replace(/\n/g, ' | ');
      const hname = `laborer-${l.slot}-hover.png`;
      await page.screenshot({ path: path.join(artifactDir, hname) }); out.shots.push(hname);
      if (l.slot === 1) {
        // Clicking a laborer opens the Laborers panel.
        await page.mouse.move(pt[0], pt[1]); await page.mouse.click(pt[0], pt[1]);
        await page.waitForSelector('.cw-labor');
        await page.keyboard.press('h');
        await page.waitForSelector('.cw-labor', { state: 'detached' });
        out.clickOpensPanel = true;
      }
    }
    // Leaving the Acre stops everything: no update work, group hidden.
    await page.evaluate(() => window.__cwDebug.goto('chapterhouse'));
    await page.evaluate(() => window.__cwDebug.advance(1, true));
    out.hiddenOutside = await page.evaluate(async () => !(await import('/src/app/GameRuntime.ts')).getRuntime().view.laborers.group.visible);
    assert.ok(out.hiddenOutside, 'laborers hidden outside the Acre');
    out.badResponses = [...bad];
    assert.equal(errors.length, 0, JSON.stringify(errors));
    out.errors = errors;
    console.log(JSON.stringify(out, null, 1));
  } finally { await browser.close(); }
}
main().catch(e => { console.error(e); process.exitCode = 1; });
