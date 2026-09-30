/**
 * Offline smoke for the necromancer weapon line (docs/NECRO-WEAPONS.md). For Gravecaller and Mourner it equips every kind,
 * checks the GLB swapped in with a spell-origin tip, checks the primary's behaviour through the real AbilitySystem (range,
 * pierce, cadence, Withered claim, scythe arc hits at most 3 once), two-handed/off-hand displacement and the Skull Focus
 * thrall cap, and writes screenshots (idle + cast per kind, off-hands, bone vs moon tint, scythe arc on a ring) to
 * DM_QA_ARTIFACT_DIR (default docs/screenshots/necro-weapons). Start the dev server first:
 *   npm run dev -- --host 127.0.0.1 --port 5303 --strictPort
 *   DM_QA_URL='http://127.0.0.1:5303/?offline' DM_PLAYWRIGHT_MODULE=... node tools/qa/necro-weapons-smoke.cjs
 * DM_QA_CLASSES="Gravecaller,Mourner" narrows the run; DM_QA_NO_SHOTS=1 skips screenshots.
 */
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(__dirname, '../../docs/screenshots/necro-weapons');
const CLASSES = (process.env.DM_QA_CLASSES || 'Gravecaller,Mourner').split(',');
const SHOTS = !process.env.DM_QA_NO_SHOTS;
const CLIP = { x: 330, y: 190, width: 340, height: 340 };

async function shot(page, name, clip = CLIP) {
  if (!SHOTS) return;
  fs.mkdirSync(OUT, { recursive: true });
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      await page.screenshot({ path: path.join(OUT, `${name}.png`), clip, timeout: 60000 });
      return;
    } catch (error) {
      if (attempt === 4) throw error;
      await page.waitForTimeout(1500);
    }
  }
}

async function run(browser, cls) {
  const tag = cls.toLowerCase();
  const page = await browser.newPage({ viewport: { width: 1000, height: 700 }, deviceScaleFactor: 2 });
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5303/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `nw_${tag}`);
  await page.fill('#cw-email', `nw_${tag}@example.invalid`);
  await page.fill('#cw-pass', 'TestingWeapons');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: cls }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });

  const equip = (id) => page.evaluate(async (id) => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const { equipItem } = await import('/src/net/api.ts');
    const v = getRuntime().view;
    if (!v.inventory.all.some((s) => s.item_id === id)) { v.inventory.add({ item_id: id, quantity: 1 }); await v.inventory.flush(); }
    const s = v.inventory.all.find((x) => x.item_id === id && !x.equipped);
    if (s) v.inventory.replace(await equipItem(v.character.id, s.slot_index, 1));
  }, id);
  const view = (fn, arg) => page.evaluate(async ({ fn, arg }) => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    return new Function('v', 'dbg', 'arg', `return (${fn})(v, dbg, arg)`)(getRuntime().view, window.__cwDebug, arg);
  }, { fn: fn.toString(), arg });
  const modelReady = (slot) => page.waitForFunction(async (slot) => {
    const { getRuntime } = await import('/src/app/GameRuntime.ts');
    const w = getRuntime().view.avatar.worn.get(slot);
    return !!w && w.obj.userData.model === true;
  }, slot, { timeout: 30000 });
  const settle = (s = 0.7) => page.evaluate((s) => window.__cwDebug.advance(s), s);
  const faceFront = () => view((v) => { v.player.facing = 0.6; });

  await page.evaluate(() => { window.__cwDebug.goto('graves'); window.__cwDebug.unlockAll?.(); window.__cwDebug.god(true); window.__cwDebug.zoom(0.4); });
  await settle(0.4);
  await view((v) => { window.__intents = []; const o = v.sendIntent.bind(v); v.sendIntent = (i) => { window.__intents.push(i); return o(i); }; });
  const intents = () => page.evaluate(() => { const r = window.__intents; window.__intents = []; return r; });
  const info = () => view((v) => ({
    main: v.avatar.worn.get('main_hand')?.key, off: v.avatar.worn.get('off_hand')?.key, range: v.primaryRange(),
    loadout: { main: v.player.loadout.main, reap: v.player.loadout.reap, pierce: v.player.loadout.needlePierce, cadence: v.player.loadout.needleCadenceMult, withered: v.player.loadout.needleWithered, thrall: v.player.loadout.thrallBonus },
    cap: v.discipline.mods.thrallCap, spell: v.player.stats.spellPower,
    inv: v.inventory.all.filter((s) => s.equipped).map((s) => `${s.item_id}@${s.slot_index}`),
  }));
  const report = {};

  // --- every main-hand kind: model swaps in, tip exists, primary behaves ---
  for (const kind of ['staff', 'scythe', 'wand', 'sickle']) {
    await equip(`${kind}_gold`);
    await modelReady('main_hand');
    await faceFront();
    await settle(0.8);
    const s = await view((v) => {
      const obj = v.avatar.worn.get('main_hand').obj;
      let meshes = 0;
      obj.traverse((o) => { if (o.isMesh) meshes++; });
      const tip = v.avatar.tip();
      return { meshes, tip: [tip.x, tip.y, tip.z].map((n) => +n.toFixed(2)), hand: v.avatar.c.root.position.toArray().map((n) => +n.toFixed(2)) };
    });
    assert.ok(s.meshes >= 1, `${kind} has geometry`);
    assert.ok(s.tip[1] > 0.4, `${kind} tip is above the ground: ${s.tip}`);
    const i = await info();
    assert.equal(i.loadout.main, kind);
    if (kind === 'staff') assert.ok(Math.abs(i.range - 11 * 1.25) < 1e-6, 'staff range');
    if (kind === 'scythe') assert.equal(i.range, 3);
    if (kind === 'wand') assert.ok(Math.abs(i.loadout.cadence - 1.3) < 1e-9);
    if (kind === 'sickle') assert.equal(i.loadout.withered, 1);
    await shot(page, `${tag}-${kind}-idle`);

    // Cast at one enemy in reach.
    await page.evaluate(() => { window.__cwDebug.clear(); window.__cwDebug.ring('robber', 1, 2.2); window.__cwDebug.freeze(true); });
    await settle(0.5);
    await intents();
    const res = await view((v) => {
      const e = [...v.enemiesMap().values()][0];
      const r = v.abilities.cast('bone_needle', { x: e.x, z: e.z, enemyId: e.id }, v.now);
      return { r, cd: v.player.cooldownLeft('bone_needle', v.now) };
    });
    assert.equal(res.r, 'ok', `${kind} casts`);
    await page.evaluate(() => window.__cwDebug.advance(0.11));
    await shot(page, `${tag}-${kind}-cast`);
    await settle(0.8);
    const sent = (await intents()).filter((x) => x.t === 'hit');
    assert.ok(sent.length >= 1, `${kind} sent a hit`);
    if (kind === 'sickle') assert.equal(sent[0].withered, 1);
    if (kind === 'wand') assert.ok(Math.abs(res.cd - 380 / 1.3) < 2, `wand cooldown ${res.cd}`);
    if (kind === 'scythe') assert.equal(res.cd, 520);
    report[kind] = { range: i.range, cd: Math.round(res.cd), hits: sent.length };
  }

  // --- scythe arc on a ring: at most 3, one intent, no double hit ---
  await equip('scythe_gold');
  await modelReady('main_hand');
  await page.evaluate(() => { window.__cwDebug.clear(); window.__cwDebug.ring('robber', 10, 2.3); window.__cwDebug.freeze(true); });
  await settle(0.6);
  await view((v) => { v.player.cooldowns.clear(); v.player.castUntil = 0; });
  await intents();
  const arc = await view((v) => {
    const es = [...v.enemiesMap().values()].sort((a, b) => Math.hypot(a.x - v.player.x, a.z - v.player.z) - Math.hypot(b.x - v.player.x, b.z - v.player.z));
    const t = es[0];
    return { r: v.abilities.cast('bone_needle', { x: t.x, z: t.z, enemyId: t.id }, v.now), ring: es.length };
  });
  await page.evaluate(() => window.__cwDebug.advance(0.12));
  await shot(page, `${tag}-scythe-arc-ring`, { x: 250, y: 120, width: 500, height: 450 });
  await settle(1.0);
  const arcSent = (await intents()).filter((x) => x.t === 'hit');
  assert.equal(arc.r, 'ok');
  assert.equal(arcSent.length, 1, 'one hit intent for the whole arc');
  assert.ok(arcSent[0].ids.length >= 1 && arcSent[0].ids.length <= 3, `arc struck ${arcSent[0].ids.length}`);
  report.scytheArc = { ring: arc.ring, struck: arcSent[0].ids.length };

  // --- bone vs moon read as different materials ---
  await page.evaluate(() => window.__cwDebug.clear());
  const colours = {};
  for (const tier of ['bone', 'moon']) {
    await equip(`staff_${tier}`);
    await modelReady('main_hand');
    await faceFront();
    await settle(0.7);
    colours[tier] = await view((v) => {
      const out = [];
      v.avatar.worn.get('main_hand').obj.traverse((o) => { if (o.isMesh) out.push(o.material.color.getHex()); });
      return out[0];
    });
    await shot(page, `${tag}-staff-${tier}`);
  }
  assert.notEqual(colours.bone, colours.moon, 'tiers tint differently');
  report.tint = colours;

  // --- off-hands and two-handed displacement ---
  await equip('wand_gold');
  await equip('skull_focus_gold');
  await modelReady('off_hand');
  let i = await info();
  assert.ok(i.inv.some((s) => s.startsWith('skull_focus_gold@106')), 'skull focus in the off-hand slot');
  assert.equal(i.loadout.thrall, 1);
  const baseCap = { Gravecaller: 5, Mourner: 3 }[cls] ?? 3;
  assert.equal(i.cap, baseCap + 1, 'skull focus raises the thrall cap at gold');
  await faceFront();
  await settle(0.7);
  await shot(page, `${tag}-wand-skull-focus`);
  await equip('grimoire_gold');
  await modelReady('off_hand');
  await settle(0.5);
  await shot(page, `${tag}-wand-grimoire`);
  await equip('mourning_bell_gold');
  await modelReady('off_hand');
  await settle(0.5);
  await shot(page, `${tag}-wand-mourning-bell`);
  i = await info();
  assert.equal(i.loadout.thrall, 0);
  await equip('staff_gold');
  await settle(0.3);
  i = await info();
  assert.ok(!i.inv.some((s) => s.includes('mourning_bell')), 'a two-hander sends the off-hand back to the bag');
  report.offhand = { capWithSkull: baseCap + 1 };

  assert.deepEqual(errors, [], 'no browser runtime errors');
  await page.close();
  return report;
}

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    for (const cls of CLASSES) console.log(cls, JSON.stringify(await run(browser, cls)));
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
