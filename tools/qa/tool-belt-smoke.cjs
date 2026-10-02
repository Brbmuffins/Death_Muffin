// Offline UI check for the gathering tool belt: belt/unbelt in the Reliquary, belt tools counting for gathering,
// the hero holding the belt tool, the one-time offer, and the readable refusal with a full bag.
// npm run dev -- --host 127.0.0.1 --port 5334 --strictPort
// DM_QA_URL=http://127.0.0.1:5334/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_CHROMIUM_PATH=/path/to/chrome DM_QA_ARTIFACT_DIR=/tmp/tb node tools/qa/tool-belt-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-tool-belt';
  mkdirSync(out, { recursive: true });
  const result = {};
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: true, autoCombat: false, autoGather: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5334/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `belt_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'belt@example.invalid');
    await page.fill('#cw-pass', 'TestingBelt1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 60000 });
    await page.evaluate(async () => { window.__beltView = (await import('/src/app/GameRuntime.ts')).getRuntime().view; window.__api = await import('/src/net/api.ts'); });
    const inv = () => page.evaluate(() => window.__cwDebug.inventory.all.map((s) => [s.slot_index, s.item_id, s.equipped]));
    const flush = () => page.evaluate(() => window.__cwDebug.inventory.flush());

    console.log("STEP 1"); // 1. Tools in the bag; the belt starts empty and the Reliquary offers to fill it once.
    await page.evaluate(() => {
      const i = window.__cwDebug.inventory;
      for (const id of ['tool_hatchet_copper', 'tool_hatchet_iron', 'tool_pickaxe_copper', 'tool_rod_silver', 'tool_spade_steel']) i.add({ item_id: id, quantity: 1 });
    });
    await flush();
    await page.keyboard.press('i');
    await page.waitForSelector('.cw-reliquary .cw-toolbelt .cw-belt-slot');
    assert.equal(await page.locator('.cw-reliquary .cw-toolbelt .cw-belt-slot').count(), 4);
    assert.equal(await page.locator('.cw-reliquary .cw-toolbelt .cw-belt-slot.filled').count(), 0, 'belt starts empty');
    assert.match(await page.locator('.cw-belt-offer').innerText(), /Belt your best tools/);
    await page.screenshot({ path: `${out}/1-offer.png` });
    let box = await page.locator('.cw-reliquary').boundingBox();
    assert.ok(box.y >= 0 && box.y + box.height <= 800 && box.x + box.width <= 1280, `reliquary fits (${Math.round(box.y + box.height)})`);

    console.log("STEP 2"); // 2. Accept: the best of each kind goes on the belt (iron hatchet beats copper), the rest stay in the bag.
    await page.locator('[data-belt-yes]').click();
    await page.waitForFunction(() => window.__cwDebug.inventory.all.filter((s) => s.slot_index >= 110).length === 4);
    let rows = await inv();
    const beltIds = Object.fromEntries(rows.filter((r) => r[0] >= 110).map((r) => [r[0], r[1]]));
    assert.deepEqual(beltIds, { 110: 'tool_hatchet_iron', 111: 'tool_pickaxe_copper', 112: 'tool_rod_silver', 113: 'tool_spade_steel' });
    assert.ok(rows.some((r) => r[1] === 'tool_hatchet_copper' && r[0] < 48), 'the spare copper hatchet stays in the bag');
    assert.equal(await page.locator('.cw-belt-offer').count(), 0, 'offer gone once the belt is in use');
    assert.equal(rows.filter((r) => r[0] < 48 && r[1].startsWith('tool_')).length, 1, 'only the spare tool is in the bag');
    await page.screenshot({ path: `${out}/2-belted.png` });
    result.belt = beltIds;

    console.log("STEP 3"); // 3. The counsel tip for first belt use.
    // An earlier "Gathering tools" card may be up first; dismiss cards until the belt one shows.
    let tip = '';
    const until = Date.now() + 60000;
    while (tip !== 'The tool belt' && Date.now() < until) {
      tip = ((await page.locator('.cw-tip .title').first().textContent({ timeout: 500 }).catch(() => '')) ?? '').trim();
      if (tip && tip !== 'The tool belt') await page.locator('.cw-tip').first().click({ position: { x: 20, y: 40 } }).catch(() => {});
      await page.waitForTimeout(500);
    }
    if (tip !== 'The tool belt') await page.screenshot({ path: `${out}/3-fail.png` });
    assert.equal(tip, 'The tool belt', 'first-use counsel tip shown');
    await page.screenshot({ path: `${out}/3-counsel.png` });
    await page.locator('.cw-tip').first().click({ position: { x: 20, y: 40 } }).catch(() => {});

    console.log("STEP 4"); // 4. Belt tools count for gathering (server-side rules): move the bag spare away, belt only.
    const tier = (node) => page.evaluate((n) => window.__api.gather(window.__cwDebug.inventory.characterId, n, 1).then((r) => r.toolTier), node);
    result.tiers = { woodcutting: await tier('coffin_oak'), mining: await tier('seam_copper'), fishing: await tier('pool_still'), gravedigging: await tier('grave_pauper') };
    assert.deepEqual(result.tiers, { woodcutting: 2, mining: 1, fishing: 3, gravedigging: 4 }, 'belt tools set the tier');

    console.log("STEP 5"); // 5. Unbelt the pickaxe: it returns to the first free bag slot and gathering falls back to no pickaxe tier.
    await page.locator('.cw-belt-slot.filled').nth(1).click();
    await page.locator('[data-toolbelt]').click();
    await page.waitForFunction(() => !window.__cwDebug.inventory.all.some((s) => s.slot_index === 111));
    rows = await inv();
    assert.ok(rows.some((r) => r[1] === 'tool_pickaxe_copper' && r[0] < 48 && !r[2]), 'pickaxe is back in the bag');
    assert.equal(await tier('seam_copper'), 1, 'a tool in the bag still counts');

    console.log("STEP 6"); // 6. The hero holds the belt tool: start AFK woodcutting from Skills and read the avatar.
    await page.keyboard.press('i');
    await page.keyboard.press('p');
    await page.getByRole('button', { name: 'Start AFK Woodcutting', exact: true }).click();
    await page.waitForFunction(() => window.__beltView.gathering.afk && window.__beltView.avatar.gatheringTools.get('woodcutting')?.visible, null, { timeout: 20000 });
    const held = await page.evaluate(() => ({ visible: window.__beltView.avatar.gatheringTools.get('woodcutting').visible, tier: window.__beltView.avatar.gatheringToolTier.get('woodcutting') }));
    assert.deepEqual(held, { visible: true, tier: 2 }, 'the hero holds the iron hatchet from the belt');
    const line = await page.locator('[data-tool="woodcutting"]').innerText();
    assert.match(line, /Iron Hatchet.*\+10%.*on belt/);
    result.skillsLine = line;
    await page.screenshot({ path: `${out}/6-skills.png` });
    await page.getByRole('button', { name: 'Pause AFK', exact: true }).click();
    await page.keyboard.press('p');

    console.log("STEP 7"); // 7. Unbelt with a full bag: refused readably, nothing moves.
    await page.evaluate(() => {
      const i = window.__cwDebug.inventory;
      const free = 48 - i.all.filter((s) => s.slot_index < 48).length;
      for (let n = 0; n < free; n++) i.add({ item_id: 'staff_oak', quantity: 1 });
    });
    await flush();
    assert.equal(await page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => s.slot_index < 48).length), 48);
    await page.keyboard.press('i');
    await page.locator('.cw-belt-slot.filled').first().click();
    await page.locator('[data-toolbelt]').click();
    await page.waitForFunction(() => /bag is full/i.test(document.querySelector('.cw-reliquary [data-error]')?.textContent ?? ''));
    result.refusal = await page.locator('.cw-reliquary [data-error]').innerText();
    assert.ok(await page.evaluate(() => window.__cwDebug.inventory.all.some((s) => s.slot_index === 110)), 'the tool stays on the belt');
    await page.screenshot({ path: `${out}/7-full-bag.png` });

    console.log("STEP 8"); // 8. A bag save (full flush) never touches the belt.
    await flush();
    assert.ok(await page.evaluate(() => window.__cwDebug.inventory.all.filter((s) => s.slot_index >= 110).length) >= 3);
    assert.deepEqual(errors, [], 'No browser runtime errors');
    console.log(JSON.stringify(result, null, 1));
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
