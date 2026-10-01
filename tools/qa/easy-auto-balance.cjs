const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const names = ['Ossuary', 'Grave Warden', 'Bell Monk', 'Carrion Witch', 'Hollow Knight', 'Veilwalker'];

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    for (const name of names.filter((n) => !process.env.DM_QA_CLASS || n === process.env.DM_QA_CLASS)) {
      const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
      page.setDefaultTimeout(180000);
      const errors = [];
      page.on('pageerror', (e) => errors.push(e.message));
      await page.addInitScript((seed) => {
        let state = seed >>> 0;
        Math.random = () => {
          state += 0x6D2B79F5;
          let t = state;
          t = Math.imul(t ^ t >>> 15, t | 1);
          t ^= t + Math.imul(t ^ t >>> 7, t | 61);
          return ((t ^ t >>> 14) >>> 0) / 4294967296;
        };
        localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoGather: false }));
      }, Number(process.env.DM_QA_SEED || 42));
      await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5199/?offline');
      await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
      const slug = name.toLowerCase().replaceAll(' ', '_');
      await page.fill('#cw-user', 'brbmuffins');
      await page.fill('#cw-email', `auto_${slug}@example.invalid`);
      await page.fill('#cw-pass', 'TestingEasyAuto');
      await page.locator('#cw-login-btn').click();
      await page.locator('.cw-disc').filter({ hasText: name }).click();
      await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 45000 });
      await page.evaluate(async () => {
        const { updateSettings } = await import('/src/app/settings.ts');
        updateSettings({ difficulty: 'easy' });
      });
      const result = await page.evaluate((seconds) => {
        const dbg = window.__cwDebug;
        dbg.clear(); dbg.goto('graves');
        let deaths = 0, firstDeath = null, wasAlive = dbg.player.alive;
        const startKills = dbg.progression.kills('graves');
        let flasksUsed = 0;
        const consume = dbg.inventory.consume.bind(dbg.inventory);
        dbg.inventory.consume = (id) => { const ok = consume(id); if (ok && id.startsWith('flask_hp_')) flasksUsed++; return ok; };
        const samples = [];
        for (let sec = 1; sec <= seconds; sec++) {
          dbg.advance(1, false);
          const alive = dbg.player.alive;
          if (wasAlive && !alive) { deaths++; firstDeath ??= sec; }
          wasAlive = alive;
          if (sec % 10 === 0 || sec === seconds) samples.push({ sec, kills: dbg.progression.kills('graves') - startKills,
            hp: Math.round(dbg.player.hp), alive, x: Math.round(dbg.player.x), z: Math.round(dbg.player.z) });
        }
        return { kills: dbg.progression.kills('graves') - startKills, deaths, firstDeath, samples,
          flasksUsed,
          hp: dbg.player.hp, maxHp: dbg.player.stats.maxHp, level: dbg.player.stats.level };
      }, Number(process.env.DM_QA_SECONDS || 180));
      assert.deepEqual(errors, [], `${name}: browser errors`);
      console.log(JSON.stringify({ name, ...result, errors }));
      await page.close();
    }
  } finally { await browser.close(); }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
