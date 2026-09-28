const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const site = 'https://muffindevelopment.com/death-muffin/';
const backend = process.env.DM_QA_BACKEND || '/home/ubuntu/death-muffin/backend';
const env = require(backend + '/node_modules/dotenv').parse(fs.readFileSync(backend + '/.env'));
const mysql = require(backend + '/node_modules/mysql2/promise');
const names = ['Grave Warden', 'Bell Monk', 'Carrion Witch', 'Hollow Knight', 'Veilwalker'];
const slugs = ['grave_warden', 'bell_monk', 'carrion_witch', 'hollow_knight', 'veilwalker'];
const username = 'dm_newblood_probe_' + Date.now();

async function main() {
  assert.equal(env.DB_NAME, 'death_muffin', 'QA cleanup must target Death Muffin only');
  const db = await mysql.createConnection({ host: env.DB_HOST, user: env.DB_USER, password: env.DB_PASS, database: env.DB_NAME });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    const api = context.request;
    const registered = await api.post(site + 'api/register', { data: { username,
      email: username + '@example.invalid', password: crypto.randomBytes(24).toString('base64url') } });
    assert.equal(registered.status(), 201, await registered.text());
    let { token } = await registered.json();
    const page = await context.newPage();
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    await page.goto(site);
    await page.evaluate((value) => sessionStorage.setItem('dm_jwt', value), token);
    await page.goto(site + 'play/');
    for (const name of names) assert.equal(await page.locator('.cw-disc').filter({ hasText: name }).count(), 1, name + ' selection');
    await page.locator('.cw-disc').filter({ hasText: names[0] }).click();
    await page.locator('.hud').waitFor({ timeout: 45000 });
    const headers = { Authorization: 'Bearer ' + token };
    const created = await api.get(site + 'api/character', { headers });
    assert.equal(created.status(), 200);
    const character = await created.json();
    assert.ok(character.id, 'Character ID');
    assert.equal(character.class_index, 5, 'Selecting Grave Warden creates that discipline');
    assert.equal(character.class_name, names[0]);

    for (let i = 0; i < names.length; i++) {
      const index = i + 5;
      const switched = await api.post(site + 'api/character/discipline', { headers,
        data: { characterId: character.id, class_index: index } });
      assert.equal(switched.status(), 200, names[i] + ': switch');
      const data = await switched.json();
      assert.equal(data.id, character.id);
      assert.equal(data.class_index, index);
      assert.equal(data.class_name, names[i]);
      const modelPath = `/models/hero_${slugs[i]}/character.glb`;
      const model = page.waitForResponse((response) => response.url().includes(modelPath) && response.status() === 200,
        { timeout: 45000 });
      await page.goto(site + 'play/');
      await page.locator('.hud').waitFor({ timeout: 45000 });
      await model;
      assert.equal((await page.locator('[data-slot]').count()) >= 7, true, names[i] + ': hotbar');
      console.log(JSON.stringify({ class: names[i], index, model: 200, world: true }));
    }
    assert.deepEqual(errors, [], 'No browser runtime errors');
    const leaderboard = await api.get(site + 'api/leaderboard');
    assert.equal(leaderboard.status(), 200);
    const entry = (await leaderboard.json()).players.find((p) => p.username === username);
    assert.ok(entry && entry.classIndex === 9 && entry.hasDiscipline, 'Leaderboard identifies Veilwalker');
    await page.getByRole('button', { name: 'Settings', exact: true }).click();
    await page.getByRole('button', { name: 'Change class', exact: true }).click();
    await page.getByRole('button', { name: 'Grave Warden', exact: true }).click();
    await page.getByRole('dialog', { name: 'Change class', exact: true }).waitFor({ state: 'hidden', timeout: 30000 });
    const viaUi = await api.get(site + 'api/character', { headers });
    assert.equal((await viaUi.json()).class_index, 5, 'In-game class switch persists');
    assert.deepEqual(errors, [], 'No browser runtime errors after the class switch');
    console.log(JSON.stringify({ selection: 5, newClassCreation: true, classesLoaded: 5,
      classSwitchUi: true, leaderboard: true, browserErrors: errors }));
  } finally {
    await browser.close();
    assert.match(username, /^dm_newblood_probe_\d+$/);
    try {
      const [[account]] = await db.execute('SELECT id FROM accounts WHERE username=?', [username]);
      if (account) {
        await db.beginTransaction();
        try {
          const [characters] = await db.execute('SELECT id FROM characters WHERE account_id=?', [account.id]);
          for (const character of characters) {
            for (const table of ['character_combat_stats', 'character_gear', 'character_quest_objectives',
              'character_quests', 'character_talents', 'combat_sessions', 'gold_transactions', 'hero_mastery',
              'inventory', 'item_instance', 'professions', 'character_necro_progress', 'gather_ledger'])
              await db.query('DELETE FROM ?? WHERE character_id=?', [table, character.id]);
            await db.execute('DELETE FROM characters WHERE id=? AND account_id=?', [character.id, account.id]);
          }
          await db.execute('DELETE FROM accounts WHERE id=? AND username=?', [account.id, username]);
          await db.commit();
        } catch (error) { await db.rollback(); throw error; }
      }
      const [[remaining]] = await db.execute('SELECT COUNT(*) AS total FROM accounts WHERE username=?', [username]);
      assert.equal(remaining.total, 0, 'Temporary account removed');
      console.log('Temporary New Blood test account removed.');
    } finally { await db.end(); }
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
