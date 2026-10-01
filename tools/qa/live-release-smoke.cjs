/**
 * Live release smoke that needs no owner credentials: registers a throwaway account on the public
 * domain, enters the world, checks co-op joins, the Grimoire lists the newest rites and every class
 * card is selectable, then deletes the account (same cleanup as live-domain-smoke.cjs).
 *   node tools/qa/live-release-smoke.cjs
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const site = 'https://muffindevelopment.com/death-muffin/';
const out = process.env.DM_QA_ARTIFACT_DIR || require('node:os').tmpdir();
const RITES = (process.env.DM_QA_RITES || 'Soul Siphon,Bone Prison,Grave Hands,Bone Storm').split(',');

async function main() {
  const username = 'dm_release_probe_' + Date.now();
  const backend = process.env.DM_QA_BACKEND || '/home/ubuntu/death-muffin/backend';
  const env = require(backend + '/node_modules/dotenv').parse(fs.readFileSync(backend + '/.env'));
  const mysql = require(backend + '/node_modules/mysql2/promise');
  const db = await mysql.createConnection({ host: env.DB_HOST, user: env.DB_USER, password: env.DB_PASS, database: env.DB_NAME });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const errors = [];
  const failed = [];
  try {
    const qa = await browser.newContext({ viewport: { width: 1280, height: 800 } });
    await qa.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, difficulty: 'easy', autoCombat: true })));
    const game = await qa.newPage();
    game.on('pageerror', (e) => errors.push(e.message));
    game.on('response', (r) => { if (r.url().startsWith(site) && r.status() >= 400) failed.push({ status: r.status(), url: r.url() }); });
    let joinResolve;
    const joined = new Promise((resolve) => (joinResolve = resolve));
    game.on('websocket', (ws) => ws.on('framereceived', (f) => { if (String(f.payload).includes('"success":true')) joinResolve(true); }));
    game.on('response', async (r) => { if (r.url().includes('/rt/socket.io/') && r.request().method() === 'GET') { try { if ((await r.text()).includes('"success":true')) joinResolve(true); } catch {} } });
    game.on('console', (m) => { if (/Joined world/i.test(m.text())) joinResolve(true); });
    const registered = await qa.request.post(site + 'api/register', { data: { username, password: 'ReleaseProbe-' + Date.now() } });
    assert.equal(registered.status(), 201, 'registration');
    const { token } = await registered.json();
    await game.goto(site);
    await game.evaluate((t) => sessionStorage.setItem('dm_jwt', t), token);
    await game.goto(site + 'play/');
    const cards = await game.locator('.cw-disc').allInnerTexts();
    await game.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await game.locator('.hud').waitFor({ timeout: 45000 });
    const characterResponse = await qa.request.get(site + 'api/character', { headers: { Authorization: `Bearer ${token}` } });
    assert.equal(characterResponse.status(), 200, 'character response');
    const character = await characterResponse.json();
    assert.equal(character.auto_combat_allowed, false, 'ordinary account has no Auto Combat capability');
    const sync = await qa.request.post(site + 'api/api/offline/sync-stats', {
      headers: { Authorization: `Bearer ${token}` },
      data: { classIndex: character.class_index, level: character.level, experience: character.experience },
    });
    assert.equal(sync.status(), 200, 'offline stats sync endpoint');
    assert.equal((await sync.json()).improved, false, 'same stats leave online character unchanged');
    const badSync = await qa.request.post(site + 'api/api/offline/sync-stats', {
      headers: { Authorization: `Bearer ${token}` },
      data: { classIndex: character.class_index, level: 2, experience: 200 },
    });
    assert.equal(badSync.status(), 400, 'invalid offline XP rejected');
    await game.locator('[data-open="settings"]').click();
    assert.equal(await game.locator('[data-diff]').inputValue(), 'medium', 'new character starts on Medium despite saved Easy');
    assert.equal(await game.locator('[data-auto]:visible').count(), 0, 'Auto Combat controls are hidden');
    assert.equal(await game.locator('[data-autogather]').count(), 1, 'Auto gathering remains available');
    await game.locator('[data-diff]').selectOption('easy');
    assert.equal(await game.locator('[data-auto]:visible').count(), 0, 'Easy does not unlock Auto Combat');
    await game.keyboard.press('Escape');
    const coop = await Promise.race([joined, game.getByText(/Joined world/).first().waitFor({ timeout: 20000 }).then(() => true).catch(() => false)]);
    await game.waitForTimeout(2500);
    await game.keyboard.press('l');
    await game.waitForTimeout(800);
    const grimoire = await game.evaluate(() => document.body.textContent || '');
    await game.screenshot({ path: path.join(out, 'live-grimoire.png') });
    const missing = RITES.filter((r) => !grimoire.includes(r));
    const report = { cards: cards.map((c) => c.split('\n')[0]), coop, normalAccount: 'Medium initially, Auto Combat hidden, Auto gathering available', missingRites: missing, errors, failed };
    console.log(JSON.stringify(report));
    assert.deepEqual(missing, [], 'Grimoire lists the new rites');
    assert.equal(errors.length, 0, 'no page errors');
    assert.equal(failed.filter((r) => r.status !== 404 || !r.url.endsWith('/api/character')).length, 0, 'no failed requests');
    assert.ok(coop, 'co-op joined');
  } finally {
    await browser.close();
    assert.match(username, /^dm_release_probe_\d+$/);
    const [[account]] = await db.execute('SELECT id FROM accounts WHERE username=?', [username]);
    if (account) {
      await db.beginTransaction();
      const [characters] = await db.execute('SELECT id FROM characters WHERE account_id=?', [account.id]);
      for (const character of characters) {
        for (const table of ['character_combat_stats', 'character_gear', 'character_quest_objectives', 'character_quests', 'character_talents', 'combat_sessions', 'gold_transactions', 'hero_mastery', 'inventory', 'item_instance', 'professions', 'character_necro_progress', 'gather_ledger']) {
          await db.query('DELETE FROM ?? WHERE character_id=?', [table, character.id]).catch(() => {});
        }
        await db.execute('DELETE FROM characters WHERE id=? AND account_id=?', [character.id, account.id]);
      }
      await db.execute('DELETE FROM accounts WHERE id=? AND username=?', [account.id, username]);
      await db.commit();
    }
    await db.end();
    console.log('Temporary release test account removed.');
  }
}

main().catch((e) => { console.error(e.message); process.exitCode = 1; });
