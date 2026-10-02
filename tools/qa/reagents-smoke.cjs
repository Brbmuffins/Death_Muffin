// Reagents smoke (offline preview): kill Graves mobs until Grave Dust drops, brew the starter tonic at the Workbench Alchemy tab,
// drink it from the belt, forage a Rot-cap patch in the Cloister, brew a top-tier mock recipe, and screenshot the tray + tab.
//   npm run dev -- --host 127.0.0.1 --port 5305 --strictPort
//   DM_QA_URL=http://127.0.0.1:5305/?offline node tools/qa/reagents-smoke.cjs
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { SWIFTSHADER_ARGS, watchErrors, shot: shotFile } = require('./lib/qa-common.cjs');

async function main() {
  const out = process.env.DM_QA_ARTIFACT_DIR || 'docs/screenshots/reagents';
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: SWIFTSHADER_ARGS });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const { errors } = watchErrors(page);
    const shot = (file) => shotFile(page, file);
    // Mark every counsel tip but 'reagent' as seen (for likely character ids), so the reagent tip is not stuck in the queue.
    const onboardingSrc = require('node:fs').readFileSync(require('node:path').join(__dirname, '../../src/ui/Onboarding.ts'), 'utf8');
    const union = onboardingSrc.slice(onboardingSrc.indexOf('export type TipId ='), onboardingSrc.indexOf(';', onboardingSrc.indexOf('export type TipId =')));
    const tipIds = [...union.matchAll(/'([A-Za-z_]+)'/g)].map((m) => m[1]).filter((t) => t !== 'reagent');
    await page.addInitScript((ids) => {
      localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: true, autoCombat: false }));
      for (let c = 0; c < 40; c++) localStorage.setItem(`dm_tips_v1_${c}`, JSON.stringify(ids));
    }, tipIds);
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5305/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `reag_${Date.now() % 100000}`);
    const email = page.locator('#cw-email');
    if (await email.isVisible().catch(() => false)) await email.fill('reagents@example.invalid');
    await page.fill('#cw-pass', 'TestingReagents1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    const dust = () => page.evaluate(() => window.__cwDebug.inventory.count('reagent_grave_dust'));

    // --- 1. Kill Graves mobs until Grave Dust drops (1% per kill, 1-2 dust). The first batch pins Math.random low for
    // the kill so the real reagent roll succeeds on the first kill; later batches (a safety net if the drop table
    // changed) are unpinned. Loot is then collected through the real pickup path: items wait where they land and the
    // hero walks over them (pickup radius 1.3 m; only gold and shards fly to the player).
    await page.evaluate(() => { const d = window.__cwDebug; d.god(true); d.unlockAll(); d.goto('graves'); d.advance(0.5); d.clear(); d.advance(0.2); });
    let kills = 0;
    let batches = 0;
    const killBatch = (pin) => page.evaluate((pin) => {
      const d = window.__cwDebug;
      const sim = d.sim();
      const real = Math.random;
      if (pin) Math.random = () => 0.0005;
      try {
        d.ring('robber', pin ? 2 : 30, 1.5);
        let n = 0;
        for (const e of [...sim.enemies.values()]) { sim.damageEnemy(e, 1e9, d.self(), { x: d.player.x, z: d.player.z }); n++; }
        d.advance(1.5, false);
        return n;
      } finally { Math.random = real; }
    }, pin);
    const sweepLoot = async () => {
      // Walk the hero over every item on the ground (re-read each step: a pickup removes it).
      for (let guard = 0; guard < 60; guard++) {
        const left = await page.evaluate(() => {
          const d = window.__cwDebug;
          const item = d.lootDrops().find((x) => x.kind === 'item');
          if (!item) return 0;
          d.teleport(item.x, item.z);
          d.advance(0.5, false);
          return d.lootDrops().filter((x) => x.kind === 'item').length;
        });
        if (!left) return;
      }
    };
    while ((await dust()) === 0 && batches < 12) {
      kills += await killBatch(batches === 0);
      batches++;
      await sweepLoot();
    }
    assert.ok((await dust()) > 0, `no Grave Dust after ${kills} kills`);
    await page.evaluate(() => window.__cwDebug.advance(2));
    const found = await dust();
    assert.ok(found > 0, `no Grave Dust in ${kills} kills`);
    console.log(JSON.stringify({ gravesKills: kills, batches, graveDust: found }));
    // The first reagent pickup places its counsel next after the current card.
    let tipShown = false;
    for (let i = 0; i < 40 && !tipShown; i++) {
      const title = await page.locator('.cw-tip:not(.out) .title').first().textContent({ timeout: 1000 }).catch(() => '');
      tipShown = title === 'Reagents';
      if (!tipShown) { await page.locator('.cw-tip:not(.out)').first().click({ timeout: 1000 }).catch(() => {}); await page.waitForTimeout(750); }
    }
    if (!tipShown) console.log('DEBUG tips', JSON.stringify(await page.evaluate(() => [...document.querySelectorAll('.cw-tip')].map((e) => e.className + ' | ' + e.textContent.slice(0, 80)))));
    assert.ok(tipShown, 'first reagent pickup shows its counsel after the current card');
    console.log(JSON.stringify({ reagentTipShown: tipShown }));
    // Screenshots come after the tip check: counsel cards expire on wall-clock time and a screenshot can take 10+ s on a loaded box.
    await shot(`${out}/02-reagent-tip.png`);

    // --- 2. Give exactly the starter cost and brew it at the Workbench, Alchemy tab.
    await page.evaluate(async () => {
      const inv = window.__cwDebug.inventory;
      const have = inv.count('reagent_grave_dust');
      if (have < 8) inv.add({ item_id: 'reagent_grave_dust', quantity: 8 - have });
      await inv.flush();
    });
    await page.keyboard.press('Escape');
    await page.keyboard.press('c');
    await page.locator('[data-tab="alchemy"]').click();
    await page.waitForTimeout(400);
    await page.waitForSelector('[data-craft="brew_grave_dust_tonic"]');
    const tabText = await page.locator('.cw-recipes').innerText();
    assert.match(tabText, /Grave-Dust Tonic/, 'starter recipe listed');
    for (const name of ['Wraithquick', 'Bloodmoon', "Regent's Vigil"]) assert.match(tabText, new RegExp(name), `${name} recipe listed`);
    await shot(`${out}/03-workbench-alchemy.png`);
    await page.locator('[data-craft="brew_grave_dust_tonic"]').click();
    await page.waitForFunction(() => window.__cwDebug.inventory.count('tonic_grave_dust') > 0, null, { timeout: 15000 });
    await shot(`${out}/04-brewed-starter.png`);
    await page.locator('.cw-panel-float [data-close]').first().click();
    await page.waitForTimeout(300);

    // --- 3. Drink it from the belt: tray chip + essence buff.
    const before = await page.evaluate(() => window.__cwDebug.inventory.count('tonic_grave_dust'));
    await page.evaluate(() => { window.__cwDebug.inventory.add({ item_id: 'elixir_wraithquick', quantity: 1 }); });
    await page.keyboard.press('x');
    await page.waitForSelector('.brew-chip.on');
    const tonic = await page.evaluate(() => window.__cwDebug.player.brews.tonic?.id);
    assert.equal(tonic, 'tonic_grave_dust');
    const essenceMult = await page.evaluate(() => window.__cwDebug.player.brewValue('essence', performance.now() + 0));
    await page.waitForTimeout(500);
    await page.keyboard.press('z');
    await page.evaluate(() => window.__cwDebug.advance(0.3));
    await page.waitForFunction(() => window.__cwDebug.player.brews.elixir?.id === 'elixir_wraithquick', null, { timeout: 10000 });
    await page.evaluate(() => window.__cwDebug.advance(0.5));
    await page.waitForTimeout(700);
    await shot(`${out}/05-tray-active.png`);
    const chips = await page.$$eval('.brew-chip', (els) => els.map((e) => e.textContent.replace(/\s+/g, ' ').trim()));
    assert.ok(chips.length >= 1, 'tray shows the active brews');
    console.log(JSON.stringify({ before, chips, essenceMult }));

    // --- 4. Forage a Rot-cap patch in the Cloister as a level-1 gardener.
    await page.evaluate(() => { const d = window.__cwDebug; d.unlockAll(); d.goto('cloister'); d.advance(0.5); d.clear(); d.zoom(1); d.advance(0.5); });
    const patches = await page.evaluate(() => window.__cwDebug.nodes('cloister').filter((n) => n.type === 'rot_cap_patch'));
    assert.ok(patches.length >= 2, 'rot-cap patches placed in the Cloister');
    let start = '';
    for (const p of patches) {
      start = await page.evaluate((p) => { const d = window.__cwDebug; d.teleport(p.x + 1.6, p.z + 1.6); d.advance(0.3); return d.gatherAt('rot_cap_patch'); }, p);
      if (!/cannot|no such/i.test(start)) break;
    }
    console.log('gatherAt', start);
    for (let i = 0; i < 12; i++) await page.evaluate(() => window.__cwDebug.advance(1.5));
    await page.evaluate(() => window.__cwDebug.flushGather());
    await page.waitForTimeout(800);
    await shot(`${out}/06-rotcap-patch.png`);
    assert.ok(typeof start === 'string' && !/cannot|no such/i.test(start), `gather started: ${start}`);
    const herbs = await page.evaluate(() => window.__cwDebug.inventory.count('herb_rot_cap'));
    const gardening = await page.evaluate(() => window.__cwDebug.gathering().skills.find((s) => s.id === 'gardening' || s.profession_id === 'gardening'));
    console.log(JSON.stringify({ herbs, gardening }));
    assert.ok(herbs > 0, 'foraged Rot-cap');

    assert.deepEqual(errors, []);
  } finally { await browser.close(); }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
