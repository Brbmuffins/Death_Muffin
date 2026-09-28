const assert = require('node:assert/strict');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const classes = [
  ['Grave Warden', 'Oil', 'grave_warden', 'warden', 'flail_swing'],
  ['Bell Monk', 'Resonance', 'bell_monk', 'monk', 'palm_strike'],
  ['Carrion Witch', 'Offal', 'carrion_witch', 'witch', 'hook_throw'],
  ['Hollow Knight', 'Rage', 'hollow_knight', 'knight', 'hollow_cut'],
  ['Veilwalker', 'Veil', 'veilwalker', 'veil', 'spirit_bolt'],
];

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
  });
  try {
    for (const [name, resource, slug, family, primary] of classes.filter(([label]) => !process.env.DM_QA_CLASS || label === process.env.DM_QA_CLASS)) {
      const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      const errors = [];
      const assets = [];
      page.on('pageerror', (error) => errors.push(error.message));
      page.on('response', (response) => {
        if (response.url().includes(slug) && response.url().endsWith('.glb')) assets.push([response.url(), response.status()]);
      });
      await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
      await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');
      await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
      await page.fill('#cw-user', `newblood_${slug}`);
      await page.fill('#cw-email', `${slug}@example.invalid`);
      await page.fill('#cw-pass', 'TestingNewBlood');
      await page.locator('#cw-login-btn').click();
      await page.locator('.cw-disc').filter({ hasText: name }).click();
      await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 45000 });
      const state = await page.evaluate(async () => {
        const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
        return {
          family: scene.discipline.family,
          resource: window.__cwDebug.player.resource.kind,
          hotbar: document.querySelectorAll('[data-slot]').length,
          area: window.__cwDebug.player.area,
        };
      });
      assert.equal(state.family, family, `${name}: family`);
      assert.equal(state.resource, resource.toLowerCase(), `${name}: resource`);
      assert.ok(state.hotbar >= 7, `${name}: missing hotbar slots: ${state.hotbar}`);
      assert.ok(assets.some(([, status]) => status === 200), `${name}: hero model did not load: ${JSON.stringify(assets)}`);
      const combat = await page.evaluate(async (rite) => {
        const debug = window.__cwDebug;
        debug.god(true);
        debug.goto('graves');
        const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
        const player = debug.player;
        const enemy = debug.sim().spawnEnemy('robber', 'graves', player.x + 1.5, player.z, false);
        enemy.state = 'move';
        enemy.hp = enemy.maxHp = 1000;
        const before = enemy.hp;
        const result = scene.abilities.cast(rite, { x: enemy.x, z: enemy.z, enemyId: enemy.id }, scene.now);
        debug.advance(0.05, false);
        return { result, before, after: enemy.hp };
      }, primary);
      assert.equal(combat.result, 'ok', `${name}: primary cast`);
      assert.ok(combat.after < combat.before, `${name}: primary did not damage target: ${JSON.stringify(combat)}`);
      if (slug === 'grave_warden' || slug === 'veilwalker') {
        const visual = await page.evaluate(async (classSlug) => {
          const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
          window.__cwDebug.advance(0.8, false);
          if (classSlug === 'veilwalker') scene.player.stats.level = 3;
          const rite = classSlug === 'grave_warden' ? 'lantern_cone' : 'veil_tear';
          const result = scene.abilities.cast(rite, { x: scene.player.x + 2, z: scene.player.z }, scene.now);
          window.__cwDebug.advance(0.1, true);
          return { rite, result };
        }, slug);
        assert.equal(visual.result, 'ok', `${name}: ${visual.rite}`);
      }
      if (slug === 'carrion_witch') {
        const harvest = await page.evaluate(async () => {
          const scene = (await import('/src/app/GameRuntime.ts')).getRuntime().view;
          window.__cwDebug.advance(0.8, false);
          const p = scene.player;
          scene.sim.addCorpse(p.x + 1, p.z, 'normal', 'robber', false, 0, 1, p.area);
          const result = scene.abilities.cast('harvest', { x: p.x + 1, z: p.z }, scene.now);
          window.__cwDebug.advance(0.15, true);
          return { result, offal: p.resource.value };
        });
        assert.equal(harvest.result, 'ok', `${name}: Harvest`);
        assert.ok(harvest.offal >= 30, `${name}: Harvest did not grant Offal`);
      }
      if (process.env.DM_QA_ARTIFACT_DIR) {
        await page.evaluate(() => { window.__cwDebug.zoom(0.4); window.__cwDebug.advance(0.1, true); });
        await page.screenshot({ path: path.join(process.env.DM_QA_ARTIFACT_DIR, `new-blood-${slug}.png`) });
      }
      assert.deepEqual(errors, [], `${name}: browser errors`);
      console.log(JSON.stringify({ name, resource, state, heroAsset: assets[0]?.[1], combat, errors }));
      await page.close();
    }
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
