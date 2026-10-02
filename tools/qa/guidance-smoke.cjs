// Offline check for gentle guidance: the Prior, the Sexton and the Apothecary, the conversation card, and the "Next" line.
//   npm run dev -- --host 127.0.0.1 --port 5338 --strictPort
//   DM_QA_URL=http://127.0.0.1:5338/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_QA_ARTIFACT_DIR=/tmp/guidance node tools/qa/guidance-smoke.cjs
// A fresh character: talk to each person (a real mouse click for the Sexton, the E key for the others), then change the real
// state (kills, a broken seal, shards, a first-kill trophy, the Prelate, a full bag, ready laborers) and watch the line change.
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-guidance';
  mkdirSync(out, { recursive: true });
  const result = {};
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()); });
    // A failed request is an error unless it is the @fontsource files a symlinked node_modules cannot serve from outside the Vite root (known, docs in HANDOFF).
    page.on('response', (r) => { if (r.status() >= 400 && !/\/node_modules\/@fontsource\//.test(r.url())) errors.push(`HTTP ${r.status()} ${r.url()}`); });
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5338/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `guide_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'guide@example.invalid');
    await page.fill('#cw-pass', 'TestingGuide1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    const adv = (s) => page.evaluate((n) => window.__cwDebug.advance(n), s);
    const G = (fn, arg) => page.evaluate(([f, a]) => { const g = window.__cwDebug.guidance; return a === undefined ? g[f]() : g[f](a); }, [fn, arg]);
    const nextText = async () => { await G('refresh'); return (await page.locator('[data-next]').isVisible()) ? (await page.locator('[data-nexttxt]').innerText()) : null; };
    const say = () => page.locator('.cw-dialogue .say').innerText();
    const choices = () => page.locator('.cw-dialogue .choice').allInnerTexts();
    const pick = async (label) => { await page.locator('.cw-dialogue .choice', { hasText: label }).first().click(); await adv(0.1); };

    // 0. The world: three people, stand-in models, nameplates.
    await adv(1);
    let npcs = await G('npcs');
    assert.equal(npcs.length, 3);
    result.models = Object.fromEntries(npcs.map((n) => [n.id, n.model]));
    assert.ok(npcs.every((n) => n.model), 'every person has a model once the player is near');
    assert.deepEqual(result.models, { prior: 'npc_prior', sexton: 'npc_sexton', apothecary: 'npc_apothecary' }, 'the real NPC models are in use (stand-ins are only the fallback)');

    // 1. Fresh character, starting in the Acre: the Sexton is in view, the line points to the Graves.
    assert.match(await nextText(), /Hollow Graves/);
    result.firstLine = await nextText();
    await page.waitForFunction(() => window.__cwDebug.guidance.npcs().find((n) => n.id === 'sexton')?.loaded, null, { timeout: 30000 });
    await adv(1);
    npcs = await G('npcs');
    const sexton0 = npcs.find((n) => n.id === 'sexton');
    assert.ok(sexton0.visible && sexton0.bang && sexton0.plate, 'sexton visible with a "!" and a nameplate');
    // Look at the Acre with the Sexton and the line.
    await page.evaluate(() => { const d = window.__cwDebug; d.player.teleport(-22.5, 21); });
    await adv(1.5);
    await page.screenshot({ path: `${out}/01-acre-sexton-next-line.png` });

    // 2. A real click on the Sexton walks up and opens the conversation.
    await page.evaluate(() => { window.__cwDebug.player.teleport(-21.5, 27); });
    await adv(0.3);
    const [sx, sy] = await G('screenOf', 'sexton');
    await page.mouse.move(sx, sy);
    await adv(0.2);
    await page.mouse.move(sx + 1, sy);
    await page.mouse.click(sx + 1, sy);
    for (let i = 0; i < 20 && !(await G('dialogue')).open; i++) await adv(0.3);
    assert.deepEqual(await G('dialogue'), { open: true, npc: 'sexton' });
    assert.match(await say(), /Sexton/);
    assert.equal((await choices()).length, 3);
    result.sextonGreeting = await say();
    {
      const sx0 = (await G('npcs')).find((n) => n.id === 'sexton');
      assert.ok(sx0.talking && sx0.hasTalk, 'the Sexton plays his talk clip while the card is open');
    }
    await page.screenshot({ path: `${out}/02-sexton-greeting.png` });
    // facing: the sexton has turned toward the player
    await adv(1);
    const yawSexton = (await G('npcs')).find((n) => n.id === 'sexton').yaw;
    assert.notEqual(yawSexton, Math.PI / 2, 'sexton turned to face the player');
    assert.equal((await G('npcs')).find((n) => n.id === 'sexton').bang, false, '"!" is gone while talking');
    await pick('What needs doing?');
    result.sextonAdvice = await say();
    assert.match(await say(), /Graves|gather|Click a Coffin/i, 'the advice is about gathering to a fresh character');
    await page.screenshot({ path: `${out}/03-sexton-advice.png` });
    await pick('Tell me about');
    assert.equal((await choices()).length, 4, 'three topics and a Back');
    await page.screenshot({ path: `${out}/04-sexton-topics.png` });
    await pick('The Bone Grinder');
    assert.match(await say(), /Bone Grinder/);
    await pick('Goodbye');
    assert.equal((await G('dialogue')).open, false);
    assert.equal((await G('npcs')).find((n) => n.id === 'sexton').bang, false, 'no "!" once told');

    // 3. The Prior: walk up in the Chapterhouse and press E.
    await page.evaluate(() => { window.__cwDebug.player.teleport(-1.2, 17.5); });
    await adv(1.5);
    assert.equal((await G('npcs')).find((n) => n.id === 'prior').bang, true, 'the stranger has a welcome waiting');
    await page.screenshot({ path: `${out}/05-chapterhouse-people.png` });
    assert.match(await page.locator('[data-prompt]').innerText(), /Talk to The Prior/);
    await page.keyboard.press('e');
    await adv(0.2);
    assert.deepEqual(await G('dialogue'), { open: true, npc: 'prior' });
    assert.match(await say(), /Welcome to the Chapterhouse/);
    await pick('Where should I go next?');
    result.priorAdvice1 = await say();
    assert.match(await say(), /Hollow Graves/);
    await page.screenshot({ path: `${out}/06-prior-advice.png` });
    await page.keyboard.press('e'); // E again ends it
    await adv(0.2);
    assert.equal((await G('dialogue')).open, false);

    // 4. The Apothecary, with dust in the bag (a few kills first: the very first steps outrank everything).
    await page.evaluate(() => { const p = window.__cwDebug.progression; for (let i = 0; i < 12; i++) p.recordKill('graves'); });
    await page.evaluate(() => { const d = window.__cwDebug; d.inventory.add({ item_id: 'reagent_grave_dust', quantity: 6 }); d.player.teleport(9.8, 19.2); });
    await adv(1.5);
    // (the HUD line stays on the seal: the road outranks a brew; the Apothecary still answers about the dust)
    assert.equal(((await G('suggestions')).find((x) => x.kind === 'brew-dust') || {}).text, 'You carry 6 Grave Dust: brew a tonic at the Workbench (C)');
    await page.keyboard.press('e');
    await adv(0.2);
    assert.deepEqual(await G('dialogue'), { open: true, npc: 'apothecary' });
    await pick('What should I brew?');
    assert.match(await say(), /6 Grave Dust/);
    result.apothecaryAdvice = await say();
    await page.screenshot({ path: `${out}/07-apothecary.png` });
    // Walking away ends the talk.
    await page.evaluate(() => { window.__cwDebug.player.teleport(0, 12); });
    await adv(0.6);
    assert.equal((await G('dialogue')).open, false, 'walking away closes the conversation');

    // 5. The line follows the real state.
    const seen = [];
    const record = async (label) => { const t = await nextText(); seen.push([label, t]); return t; };
    await page.evaluate(() => { window.__cwDebug.inventory.all.forEach((s) => window.__cwDebug.inventory.consume(s.item_id)); });
    await page.evaluate(() => { const p = window.__cwDebug.progression; for (let i = 0; i < 160; i++) p.recordKill('graves'); });
    assert.equal(await record('172 kills in the Graves'), 'Hollow Graves: 172 / 300 to open the Marrow Ossuary');
    await adv(0.6);
    await page.screenshot({ path: `${out}/08-chapterhouse-next-seal.png` });
    await page.evaluate(() => { window.__cwDebug.progression.addShards(2); });
    assert.match(await record('2 shards'), /Gravedigger King waits at the King's Grave — 2 soul shards/);
    await G('beatBoss', 'gravedigger');
    assert.match(await record('King buried'), /Hollow Graves: 172 \/ 300/);
    await page.evaluate(() => { const p = window.__cwDebug.progression; for (let i = 0; i < 128; i++) p.recordKill('graves'); p.unlock('ossuary'); for (let i = 0; i < 33; i++) p.recordKill('ossuary'); });
    assert.equal(await record('Ossuary open, 33 kills'), 'Marrow Ossuary: 33 / 420 to open the Drowned Nave');
    // The Prior has news: a broken seal and a buried king.
    assert.equal((await G('npcs')).find((n) => n.id === 'prior').bang, true, 'the Prior has a new seal to speak of');
    await page.evaluate(() => { window.__cwDebug.player.teleport(-1.2, 17.5); });
    await adv(0.5);
    await page.keyboard.press('e');
    await adv(0.2);
    assert.match(await say(), /Gravedigger King is buried|seal has broken|Marrow Ossuary/);
    result.priorNews = await say();
    await page.screenshot({ path: `${out}/09-prior-news.png` });
    await pick('Tell me about');
    await pick('The kings of the dead');
    assert.match(await say(), /The Bone Abbess/);
    await page.keyboard.press('Escape');
    await adv(0.2);
    assert.equal((await G('dialogue')).open, false, 'Esc ends the conversation');
    await page.keyboard.press('Escape'); // the Esc that closed the card does not leave Settings open
    await page.keyboard.press('Escape');
    await adv(0.2);
    await page.evaluate(() => { const p = window.__cwDebug.progression; p.recordPrelateKill(); });
    assert.match(await record('Prelate felled'), /Altar of Ascension is ready: \+\d+ Ashes/);
    await page.evaluate(() => { const d = window.__cwDebug; for (let i = 0; i < 46; i++) d.inventory.add({ item_id: i % 2 ? 'helm_copper' : 'staff_oak', quantity: 1 }); });
    assert.match(await record('bag nearly full'), /bag is nearly full/);
    await adv(0.6); // let the minimap redraw with the ping
    await page.screenshot({ path: `${out}/10-next-bag-full.png` });
    await page.evaluate(() => { const d = window.__cwDebug; d.inventory.all.filter((s) => s.item_id === 'helm_copper' || s.item_id === 'staff_oak').forEach((s) => { while (d.inventory.count(s.item_id) > 0) d.inventory.consume(s.item_id); }); });
    await G('setLabor', { unlocked: 2, assigned: 2, ready: 2 });
    assert.equal(await record('laborers ready'), 'Your laborers are ready in the Acre (H)');
    await G('setLabor', { unlocked: 2, assigned: 2, ready: 0 });
    await G('setContracts', { open: 3, total: 3 });
    await record('contracts (outranked by the seal, still listed)');
    assert.match(((await G('suggestions')).find((x) => x.kind === 'contracts') || {}).text, /3 Sexton.s Contracts wait/);
    result.sequence = seen;

    // 6. Dismiss, and the Settings toggles.
    await page.locator('[data-nextx]').click();
    await adv(0.7);
    const afterDismiss = await nextText();
    assert.notEqual(afterDismiss, seen[seen.length - 1][1], 'the dismissed line steps aside');
    await G('setContracts', { open: 0, total: 3 });
    await page.keyboard.press('Escape');
    await adv(0.2);
    await page.locator('[data-guidance]').uncheck();
    await adv(0.8);
    assert.equal(await page.locator('[data-next]').isVisible(), false, 'Settings turns the line off');
    await page.screenshot({ path: `${out}/11-settings-toggle.png` });
    await page.locator('[data-guidance]').check();
    await page.evaluate(() => document.activeElement && document.activeElement.blur()); // keys are ignored while a checkbox has focus
    await page.keyboard.press('Escape');
    await adv(0.8);
    assert.equal(await page.locator('[data-next]').isVisible(), true, 'and back on');

    // 7. Memory is kept per character in browser storage.
    const mem = await page.evaluate(() => {
      const id = window.__cwDebug.progression.character.id;
      return JSON.parse(localStorage.getItem(`dm_guidance_v1:${id}`));
    });
    assert.ok(mem.met.includes('prior') && mem.met.includes('sexton') && mem.met.includes('apothecary'));
    assert.ok(mem.heard.some((h) => h.startsWith('topic:sexton')));
    result.memory = mem;

    // 8. The Codex has the People tab.
    await page.keyboard.press('k');
    await page.locator('[data-tab="people"]').click();
    assert.match(await page.locator('.cw-codex-note').first().innerText(), /Click one/);
    assert.equal(await page.locator('.cw-codex-entry').count(), 3);
    await page.screenshot({ path: `${out}/12-codex-people.png` });
    await page.keyboard.press('Escape');

    // 9. A last look at the Acre and the HUD at full state.
    await page.evaluate(() => { window.__cwDebug.player.teleport(-22.5, 21); });
    await adv(1.5);
    await page.screenshot({ path: `${out}/13-acre-final.png` });

    assert.deepEqual(errors, [], `page errors: ${errors.join(' | ')}`);
    console.log(JSON.stringify(result, null, 2));
    console.log('guidance smoke: OK');
  } finally {
    await browser.close();
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
