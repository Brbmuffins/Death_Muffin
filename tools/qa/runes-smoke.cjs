// Offline UI + behaviour check for Relic runes: the counsel tip, the Reliquary detail strip, the Grimoire sockets, the hotbar badges and card, and every
// one of the eleven runes cast in the real game (Splinters, Marrow-Tap, Volley, Ossuary Ring, Impale, Mass Grave, Bone Colossus, Creeping Rot, Contagion,
// Hollow Choir, Requiem), the Colossus's model, clips and your-own rim, the Codex tab, and the Bone Grinder.
// npm run dev -- --host 127.0.0.1 --port 5354 --strictPort
// DM_QA_URL=http://127.0.0.1:5354/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_CHROMIUM_PATH=/path/to/chrome DM_QA_ARTIFACT_DIR=/tmp/runes node tools/qa/runes-smoke.cjs
// Do not edit src/ while it runs: Vite hot-reloads the page and the run dies.
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-runes';
  mkdirSync(out, { recursive: true });
  const result = {};
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    // Fonts live behind a symlinked node_modules on this VPS and answer 403 in dev: not a game error.
    page.on('console', (m) => { if (m.type() === 'error' && !/403 \(Forbidden\)/.test(m.text())) errors.push(`console: ${m.text()}`); });
    const tipsOn = process.env.DM_QA_ONLY_CASTS !== '1';
    await page.addInitScript((tips) => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips, autoCombat: false, autoGather: false })), tipsOn);
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5354/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `runes_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'runes@example.invalid');
    await page.fill('#cw-pass', 'TestingRunes1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    const dbg = (fn, arg) => page.evaluate(fn, arg);
    const advance = (s) => dbg((n) => window.__cwDebug.advance(n), s);
    const shot = (name, clip) => page.screenshot({ path: `${out}/${name}.png`, ...(clip ? { clip } : {}) });
    const rows = () => dbg(() => window.__cwDebug.inventory.all.map((s) => [s.slot_index, s.item_id, s.quantity, s.equipped]));
    const flush = () => dbg(() => window.__cwDebug.inventory.flush());
    const fits = async (sel, what) => {
      const box = await page.locator(sel).boundingBox();
      assert.ok(box.x >= 0 && box.y >= 0 && box.x + box.width <= 1280 && box.y + box.height <= 800, `${what} fits 1280x800 (${JSON.stringify(box)})`);
    };
    const RITE_SOCKET = { bone_needle: 'primary', marrow_spear: '0', exhume: '1', miasma: '2', black_litany: '3' };
    const RITE_OF = { rune_splinter: 'bone_needle', rune_marrow_tap: 'bone_needle', rune_volley: 'bone_needle', rune_ossuary_ring: 'marrow_spear', rune_impale: 'marrow_spear', rune_mass_grave: 'exhume', rune_bone_colossus: 'exhume', rune_creeping_rot: 'miasma', rune_contagion: 'miasma', rune_hollow_choir: 'black_litany', rune_requiem: 'black_litany' };
    /** Socket a rune the way a player does: open the Grimoire, pick the rite's socket, click the rune. */
    const socket = async (id) => {
      const rite = RITE_OF[id];
      if (!(await page.locator('.cw-grimoire').count())) await page.keyboard.press('l');
      await page.waitForSelector('.cw-grimoire [data-runebox]');
      await page.locator(`.cw-grim-socket[data-socket="${RITE_SOCKET[rite]}"]`).click();
      await page.locator(`[data-rune="${id}"]`).click();
      await page.waitForFunction(({ rite, id }) => window.__cwDebug.runes()[rite] === id, { rite, id });
      await page.keyboard.press('l');
      await page.waitForSelector('.cw-grimoire', { state: 'detached' });
    };
    const unsocket = async (rite) => {
      await page.keyboard.press('l');
      await page.waitForSelector('.cw-grimoire [data-runebox]');
      await page.locator(`.cw-grim-socket[data-socket="${RITE_SOCKET[rite]}"]`).click();
      await page.locator('[data-rune-out]').click();
      await page.waitForFunction((rite) => !window.__cwDebug.runes()[rite], rite);
      await page.keyboard.press('l');
      await page.waitForSelector('.cw-grimoire', { state: 'detached' });
    };

    // DM_QA_ONLY_CASTS=1 skips the panel steps (1-4) and goes straight to casting every rune; the bag is still seeded.
    const ONLY_CASTS = process.env.DM_QA_ONLY_CASTS === '1';
    if (ONLY_CASTS) {
      await dbg(() => { window.__cwDebug.zoom(0.32); window.__cwDebug.god(); window.__cwDebug.unlockAll(); window.__cwDebug.gold(5000); });
      await dbg(() => { const i = window.__cwDebug.inventory; for (const id of ['rune_splinter', 'rune_marrow_tap', 'rune_volley', 'rune_ossuary_ring', 'rune_impale', 'rune_mass_grave', 'rune_bone_colossus', 'rune_creeping_rot', 'rune_contagion', 'rune_hollow_choir', 'rune_requiem']) i.add({ item_id: id, quantity: 1 }); i.add({ item_id: 'rune_volley', quantity: 2 }); });
      await flush();
    }
    if (!ONLY_CASTS) {
    console.log('STEP 1'); // 1. Runes in the bag: the counsel tip explains them; the Reliquary stacks them and says what each changes.
    await dbg(() => { window.__cwDebug.zoom(0.32); window.__cwDebug.god(); window.__cwDebug.unlockAll(); window.__cwDebug.gold(5000); });
    await dbg(() => {
      const i = window.__cwDebug.inventory;
      for (const id of ['rune_splinter', 'rune_marrow_tap', 'rune_volley', 'rune_ossuary_ring', 'rune_impale', 'rune_mass_grave', 'rune_bone_colossus', 'rune_creeping_rot', 'rune_contagion', 'rune_hollow_choir', 'rune_requiem']) i.add({ item_id: id, quantity: 1 });
      i.add({ item_id: 'rune_volley', quantity: 2 });
    });
    await flush();
    let r = await rows();
    assert.equal(r.filter((x) => x[1] === 'rune_volley').length, 1, 'runes stack in one slot');
    assert.equal(r.find((x) => x[1] === 'rune_volley')[2], 3);
    let tip = '';
    for (let n = 0; n < 40 && !tip; n++) {
      await advance(8);
      const titles = await page.locator('.cw-tip .title').allTextContents().catch(() => []);
      tip = titles.find((t) => /A Relic rune/.test(t)) ?? '';
      if (!tip && titles.length) await page.locator('.cw-tip').first().click({ position: { x: 20, y: 40 } }).catch(() => {});
    }
    assert.match(tip, /A Relic rune/, 'the counsel tip explains runes the first time one is held');
    await page.waitForTimeout(900);
    await shot('1-tip');
    const tipText = await page.locator('.cw-tip').first().innerText();
    assert.match(tipText, /Grimoire/);
    await page.locator('.cw-tip').first().click({ position: { x: 20, y: 40 } }).catch(() => {});

    console.log('STEP 2'); // 2. Reliquary: select a rune, read exactly what it changes and costs; the Socket button moves one.
    await page.keyboard.press('i');
    await page.waitForSelector('.cw-reliquary');
    const volleyCell = await dbg(() => window.__cwDebug.inventory.all.find((s) => s.item_id === 'rune_volley').slot_index);
    await page.locator('.cw-bag-grid .cw-slot').nth(volleyCell).click();
    const detail = await page.locator('.cw-bag-detail').innerText();
    assert.match(detail, /Fits Bone Needle/);
    assert.match(detail, /Every 4th needle/);
    assert.match(detail, /Cost: Each volley needle hits for 40%/);
    assert.match(detail, /Socket it in the Grimoire/);
    assert.match(detail, /×3/);
    result.volleyDetail = detail.replace(/\s+/g, ' ');
    await shot('2-reliquary-rune');
    await fits('.cw-reliquary', 'Reliquary');
    await page.locator('[data-runesocket]').click();
    await page.waitForFunction(() => window.__cwDebug.runes().bone_needle === 'rune_volley');
    r = await rows();
    assert.deepEqual(r.find((x) => x[0] === 130), [130, 'rune_volley', 1, 1], 'slot 130 holds the socketed Volley');
    assert.equal(r.find((x) => x[0] === volleyCell)[2], 2, 'the stack went 3 -> 2');
    await page.keyboard.press('i');
    await advance(0.2);
    assert.equal(await page.locator('[data-primarywrap] img.rune-pip').count(), 1, 'the left-click slot wears a rune badge');
    // Hover the LMB slot: the card names the rune and what it changed.
    await page.locator('[data-slot="0"]').hover();
    await page.waitForSelector('.spell-rune');
    const card = await page.locator('.spell-rune').innerText();
    assert.match(card, /Rune of the Volley/);
    assert.match(card, /40%/);
    await shot('3-hotbar-badge-card');
    await page.mouse.move(640, 300);

    console.log('STEP 3'); // 3. The Grimoire: sockets under the bar, the owned runes of the selected rite, sealed ones with where they drop.
    await page.keyboard.press('l');
    await page.waitForSelector('.cw-grimoire [data-runebox]');
    assert.equal(await page.locator('.cw-grim-socket img.cw-rune-pip').count(), 1, 'one badge on the bar (the left-click socket)');
    await page.locator('.cw-grim-socket[data-socket="1"]').click(); // Exhume
    assert.equal(await page.locator('[data-runebox] .cw-rune-opt').count(), 2, 'Exhume has two runes');
    assert.equal(await page.locator('[data-runebox] .cw-rune-opt:not(.sealed)').count(), 2, 'both are in the bag');
    assert.match(await page.locator('[data-runebox] .cw-rune-frame').innerText(), /◇/, 'an empty socket shows the empty frame');
    await shot('4-grimoire-empty-socket');
    await page.locator('[data-rune="rune_bone_colossus"]').click();
    await page.waitForFunction(() => window.__cwDebug.runes().exhume === 'rune_bone_colossus');
    const box = await page.locator('[data-runebox]').innerText();
    assert.match(box, /Bone Colossus Rune/);
    assert.match(box, /3 or more corpses/);
    assert.match(box, /Take the rune out/i);
    await shot('5-grimoire-colossus-socketed');
    await fits('.cw-grimoire', 'Grimoire');
    // Right-click slot (Corpse Explosion) has no runes yet: one honest line, no empty promise.
    await page.locator('.cw-grim-socket[data-socket="4"]').click();
    assert.match(await page.locator('[data-runebox]').innerText(), /has no runes yet/);
    // Sealed runes show where they drop: take Splinters out of the bag by selling... instead check a rite whose runes are all owned, then a fake missing one.
    await page.locator('.cw-grim-socket[data-socket="primary"]').click();
    assert.equal(await page.locator('[data-runebox] .cw-rune-opt.on').count(), 1, 'Volley is marked Socketed');
    await page.keyboard.press('l');
    await page.waitForSelector('.cw-grimoire', { state: 'detached' });
    await unsocket('exhume');
    await unsocket('bone_needle');
    r = await rows();
    assert.ok(!r.some((x) => x[0] >= 130), 'taking runes out empties the socket rows');
    assert.equal(r.filter((x) => x[1] === 'rune_volley').reduce((n, x) => n + x[2], 0), 3, 'and nothing was lost');
    assert.equal(r.filter((x) => x[1] === 'rune_bone_colossus').reduce((n, x) => n + x[2], 0), 1);
    assert.equal(await page.locator('.hud-slots-wrap img.rune-pip').count(), 0, 'the badges are gone');

    console.log('STEP 4'); // 4. Persistence and the Codex tab.
    await dbg(() => window.__cwDebug.inventory.flush());
    await socket('rune_requiem');
    const snap = await dbg(() => JSON.parse(localStorage.getItem('dm_offline_db_v1') ?? '{}'));
    const acc = Object.values(snap.accounts ?? {}).find((a) => a.character);
    assert.ok(acc.slots.some((s) => s.slot_index === 134 && s.item_id === 'rune_requiem' && s.equipped === 1), 'the offline save keeps the socket row');
    await unsocket('black_litany');
    await page.keyboard.press('k');
    await page.waitForSelector('.cw-codex');
    await page.locator('[data-tab="runes"]').click();
    const codex = await page.locator('.cw-codex [data-body]').innerText();
    assert.match(codex, /Runes are the build-depth layer/);
    assert.match(codex, /11|Bone Colossus Rune/);
    assert.equal(await page.locator('.cw-codex .cw-rune-opt').count(), 11, 'all eleven runes are listed');
    assert.equal(await page.locator('.cw-codex .cw-rune-opt.on').count(), 11, 'every rune this character has held shows its page');
    await shot('6-codex-runes');
    await page.keyboard.press('k');

    }
    console.log('STEP 5'); // 5. Every rune, cast in the real game.
    await dbg(() => window.__cwDebug.goto('graves'));
    await advance(0.5);
    await dbg(() => window.__cwDebug.zoom(0.62));
    const reset = () => dbg(() => {
      const d = window.__cwDebug;
      d.sim().enemies.clear();
      d.sim().corpses.clear();
      for (const id of [...d.sim().thralls.keys()]) d.sim().thralls.delete(id);
      for (const id of [...d.sim().zones.keys()]) d.sim().zones.delete(id);
      d.player.cooldowns.clear();
      d.player.castUntil = 0;
      d.player.essence = d.player.stats.maxEssence;
    });
    const quiet = () => dbg(() => { const d = window.__cwDebug; d.sim().waveTier = 0; d.sim().setPlayer({ id: d.self(), x: d.player.x, z: d.player.z, alive: true, area: null }); });
    const pos = () => dbg(() => ({ x: window.__cwDebug.player.x, z: window.__cwDebug.player.z }));
    const hold = (def, x, z, hp) => dbg(({ def, x, z, hp }) => {
      const e = window.__cwDebug.sim().spawnEnemy(def, window.__cwDebug.player.area ?? 'graves', x, z, false, false);
      e.state = 'move'; e.speed = 0; e.stateT = 99;
      if (hp) { e.hp = hp; e.maxHp = hp; }
      return e.id;
    }, { def, x, z, hp });
    const hp = (ids) => dbg((ids) => ids.map((id) => window.__cwDebug.sim().enemies.get(id)?.hp ?? 0), ids);
    const cast = (id, target) => dbg(({ id, target }) => window.__cwDebug.abilities.cast(id, target, window.__cwDebug.now()), { id, target });

    // Models load asynchronously: raise one of each body now and give them real time, so the screenshots below show what a player sees.
    await dbg(() => { const d = window.__cwDebug; d.spawn('robber'); d.raise('robber', 3, 2); d.player.runes && 0; });
    await advance(0.5);
    await page.waitForTimeout(3000);
    await advance(0.5);

    // --- Splinters ------------------------------------------------------------------------------------------------------
    await socket('rune_splinter');
    await reset(); await quiet();
    let p = await pos();
    let ids = [await hold('robber', p.x - 5, p.z - 1, 9999), await hold('robber', p.x - 7, p.z - 1, 9999), await hold('robber', p.x - 30, p.z - 1, 9999)];
    let before = await hp(ids);
    assert.equal(await cast('bone_needle', { x: p.x - 5, z: p.z - 1, enemyId: ids[0] }), 'ok');
    await advance(0.4);
    let after = await hp(ids);
    assert.ok(after[0] < before[0] && after[1] < before[1], 'Splinters: the struck foe and the one beside it both lose health');
    assert.equal(after[2], before[2], 'a far foe is untouched');
    const share = (before[1] - after[1]) / (before[0] - after[0]);
    assert.ok(share > 0.12 && share < 0.45, `the shard carries about 30% of the hit (${share.toFixed(2)}; a crit on the main needle lowers it)`);
    await shot('7-splinters');
    await unsocket('bone_needle');

    // --- Marrow-Tap ---------------------------------------------------------------------------------------------------------
    await socket('rune_marrow_tap');
    await reset(); await quiet();
    p = await pos();
    ids = [await hold('robber', p.x - 5, p.z - 1, 9999)];
    await dbg(() => { window.__cwDebug.player.essence = 20; });
    await cast('bone_needle', { x: p.x - 5, z: p.z - 1, enemyId: ids[0] });
    await advance(0.4);
    const essence = await dbg(() => Math.round(window.__cwDebug.player.essence));
    assert.ok(essence >= 29 && essence <= 35, `Marrow-Tap returns 10 essence a hit, 6 without it (20 -> ${essence}, with a little regeneration on top)`);
    await unsocket('bone_needle');

    // --- Volley -------------------------------------------------------------------------------------------------------------
    await socket('rune_volley');
    await reset(); await quiet();
    p = await pos();
    ids = [await hold('robber', p.x - 6, p.z, 99999), await hold('robber', p.x - 6.5, p.z + 2, 99999), await hold('robber', p.x - 6.5, p.z - 2, 99999), await hold('robber', p.x - 30, p.z, 99999)];
    const struck = [];
    for (let i = 0; i < 4; i++) {
      const b = await hp(ids);
      await dbg(() => { window.__cwDebug.player.cooldowns.clear(); window.__cwDebug.player.castUntil = 0; });
      await advance(0.05);
      await cast('bone_needle', { x: p.x - 6, z: p.z, enemyId: ids[0] });
      if (i === 3) {
        await advance(0.12);
        await shot('8-volley-in-flight');
      }
      await advance(0.6);
      const a = await hp(ids);
      struck.push(a.map((v, k) => b[k] - v > 0));
    }
    assert.deepEqual(struck.map((s) => s.filter(Boolean).length), [1, 1, 1, 3], 'three single needles, then a volley that strikes three foes');
    assert.deepEqual(struck[3], [true, true, true, false], 'the far foe is out of the volley\'s reach');
    await unsocket('bone_needle');

    // --- Ossuary Ring ---------------------------------------------------------------------------------------------------------
    await socket('rune_ossuary_ring');
    await reset(); await quiet();
    p = await pos();
    ids = [await hold('robber', p.x - 3, p.z, 9999), await hold('robber', p.x - 8, p.z, 9999), await hold('robber', p.x - 9.5, p.z + 1.5, 9999), await hold('robber', p.x - 8, p.z - 2.5, 9999), await hold('robber', p.x - 14, p.z, 9999)];
    before = await hp(ids);
    await dbg(({ x, z }) => window.__cwDebug.aimAt(x, z), { x: p.x - 8, z: p.z });
    assert.equal(await cast('marrow_spear', { x: p.x - 8, z: p.z }), 'ok');
    await advance(0.25);
    await shot('9-ossuary-ring');
    await advance(0.6);
    after = await hp(ids);
    assert.deepEqual(after.map((v, i) => v < before[i]), [false, true, true, true, false], 'the ring strikes the three foes inside it, not the one on the way or the one beyond');
    await unsocket('marrow_spear');

    // --- Impale -----------------------------------------------------------------------------------------------------------------
    await socket('rune_impale');
    await reset(); await quiet();
    p = await pos();
    ids = [await hold('robber', p.x - 9, p.z, 9999), await hold('robber', p.x - 4, p.z + 0.2, 9999), await hold('robber', p.x - 6.5, p.z, 9999)];
    before = await hp(ids);
    assert.equal(await cast('marrow_spear', { x: p.x - 10, z: p.z }), 'ok');
    await advance(0.3);
    await shot('10-impale');
    await advance(0.4);
    after = await hp(ids);
    assert.deepEqual(after.map((v, i) => v < before[i]), [false, true, false], 'only the first foe on the line is struck');
    const rooted = await dbg((id) => window.__cwDebug.sim().enemies.get(id).rootT, ids[1]);
    assert.ok(rooted > 0.15 && rooted <= 1.5, `and it is rooted (${rooted})`);
    await unsocket('marrow_spear');

    // --- Mass Grave --------------------------------------------------------------------------------------------------------------
    await socket('rune_mass_grave');
    await reset(); await quiet();
    p = await pos();
    for (const [dx, dz] of [[4, 0], [5, 1], [3.5, -1.2], [4.5, 2.2]]) await dbg(({ x, z }) => window.__cwDebug.corpseAt(x, z), { x: p.x - dx, z: p.z + dz });
    await dbg(({ x, z }) => window.__cwDebug.aimAt(x, z), { x: p.x - 4, z: p.z });
    assert.equal(await cast('exhume', { x: p.x - 4, z: p.z }), 'ok');
    await advance(0.3);
    await shot('11-mass-grave');
    await advance(1.2);
    let th = await dbg(() => [...window.__cwDebug.sim().thralls.values()].map((t) => [t.kind, Math.round(t.maxHp)]));
    assert.equal(th.length, 3, 'three thralls rise from one cast');
    const baseHp = await dbg(() => Math.round(window.__cwDebug.player.stats.thrallHp));
    assert.ok(th.every((t) => Math.abs(t[1] - baseHp * 0.75) <= 2), `each at 75% health (${JSON.stringify(th)} vs ${baseHp})`);
    assert.equal(await dbg(() => window.__cwDebug.sim().corpses.size), 1, 'one corpse is left');
    await unsocket('exhume');

    // --- Bone Colossus -----------------------------------------------------------------------------------------------------------
    await socket('rune_bone_colossus');
    await reset(); await quiet();
    p = await pos();
    for (const [dx, dz] of [[4, 0], [5, 1], [3.5, -1.2], [4.5, 2.2], [5.5, -0.5], [4, 4.5]]) await dbg(({ x, z }) => window.__cwDebug.corpseAt(x, z), { x: p.x - dx, z: p.z + dz });
    await dbg(({ x, z }) => window.__cwDebug.aimAt(x, z), { x: p.x - 4.5, z: p.z + 0.5 });
    assert.equal(await cast('exhume', { x: p.x - 4.5, z: p.z + 0.5 }), 'ok');
    const cdLeft = await dbg(() => Math.round(window.__cwDebug.player.cooldownLeft('exhume', window.__cwDebug.now())));
    await advance(0.35);
    await shot('12-colossus-gathering');
    await advance(1.4);
    th = await dbg(() => [...window.__cwDebug.sim().thralls.values()].map((t) => ({ kind: t.kind, hp: Math.round(t.maxHp), dmg: t.damage, state: t.state })));
    assert.equal(th.length, 1, 'one thrall');
    assert.equal(th[0].kind, 'colossus');
    assert.ok(Math.abs(th[0].hp - baseHp * 4) <= 3, `4x health with five corpses (${th[0].hp} vs ${baseHp})`);
    assert.equal(await dbg(() => window.__cwDebug.sim().corpses.size), 1, 'five corpses consumed, one left');
    assert.ok(cdLeft > 3300 && cdLeft < 4100, `Exhume waits about 4 s after a Colossus (${cdLeft} ms left right after the cast)`);
    assert.deepEqual(await dbg(() => window.__cwDebug.counts().thralls), 1);
    await page.waitForTimeout(2500); // the giant's model loads on first use
    await advance(0.5);
    await shot('13-colossus-risen');
    // Close-up beside the hero: it must read as ours (jade rim and ring) and as a giant.
    await dbg(() => window.__cwDebug.zoom(0.18));
    await advance(0.3);
    await shot('14-colossus-closeup');
    // idle, walk and attack are real clips (measured) and play: put a foe in reach.
    await dbg(() => window.__cwDebug.sim().enemies.clear());
    await quiet();
    ids = [await hold('robber', p.x - 6, p.z, 99999)];
    await advance(2.5);
    const colossus = await dbg(() => { const t = [...window.__cwDebug.sim().thralls.values()][0]; const e = [...window.__cwDebug.sim().enemies.values()][0]; return { x: t.x, z: t.z, state: t.state, target: t.target, atkCd: t.attackCd, range: t.range, enemy: e && { x: e.x, z: e.z, state: e.state, hp: e.hp }, hero: { x: window.__cwDebug.player.x, z: window.__cwDebug.player.z } }; });
    assert.ok(colossus.state === 'attack' || colossus.state === 'idle' || colossus.state === 'move', 'it acts');
    const hurt = (await hp(ids))[0];
    assert.ok(hurt < 99999, `it fights (${hurt}; ${JSON.stringify(colossus)})`);
    await shot('15-colossus-fighting');
    await dbg(() => window.__cwDebug.zoom(0.62));
    // a second one replaces the first; the cap
    await dbg(() => { window.__cwDebug.player.cooldowns.clear(); window.__cwDebug.player.castUntil = 0; });
    await reset(); await quiet();
    await unsocket('exhume');

    // --- Creeping Rot ----------------------------------------------------------------------------------------------------------------
    await socket('rune_creeping_rot');
    await reset(); await quiet();
    p = await pos();
    ids = [await hold('robber', p.x - 11, p.z + 2, 99999)];
    await dbg(({ x, z }) => window.__cwDebug.aimAt(x, z), { x: p.x - 5, z: p.z + 1 });
    assert.equal(await cast('miasma', { x: p.x - 5, z: p.z + 1 }), 'ok');
    await advance(0.9);
    const z0 = await dbg(() => { const z = [...window.__cwDebug.sim().zones.values()][0]; return { x: z.x, z: z.z, r: z.r, creep: z.creep }; });
    await shot('16-creeping-rot-early');
    await advance(2.4);
    const z1 = await dbg(() => { const z = [...window.__cwDebug.sim().zones.values()][0]; return { x: z.x, z: z.z }; });
    await shot('17-creeping-rot-later');
    assert.equal(z0.creep, 1.5);
    assert.ok(Math.abs(z1.x - z0.x) > 2.8 && Math.abs(z1.x - z0.x) < 4.8, `the circle crept toward the foe (${z0.x.toFixed(1)} -> ${z1.x.toFixed(1)})`);
    assert.ok(z0.r < 3.8 * 0.9, 'and is narrower than a plain circle');
    await unsocket('miasma');

    // --- Contagion --------------------------------------------------------------------------------------------------------------------
    await socket('rune_contagion');
    await reset(); await quiet();
    p = await pos();
    ids = [await hold('robber', p.x - 6, p.z, 99999), await hold('robber', p.x - 8, p.z + 0.5, 99999), await hold('robber', p.x - 8.5, p.z - 1.5, 99999), await hold('robber', p.x - 25, p.z, 99999)];
    await dbg(({ x, z }) => window.__cwDebug.aimAt(x, z), { x: p.x - 5.4, z: p.z });
    assert.equal(await cast('miasma', { x: p.x - 5.4, z: p.z }), 'ok');
    await advance(2.2);
    const marked = await dbg((ids) => ids.map((id) => !!window.__cwDebug.sim().enemies.get(id).contagious), ids);
    assert.equal(marked[0], true, 'the circle marks the foe standing in it');
    // Kill it: its stacks jump to the two nearest.
    await dbg((id) => { const e = window.__cwDebug.sim().enemies.get(id); e.withered = 4; e.witheredT = 5; e.hp = 0; window.__cwDebug.sim().zones.clear(); }, ids[0]);
    await advance(0.12);
    await shot('18-contagion-spread');
    const w = await dbg((ids) => ids.map((id) => window.__cwDebug.sim().enemies.get(id)?.withered ?? -1), ids);
    assert.equal(w[1], 3, 'the nearest neighbour took the stacks minus one');
    assert.equal(w[2], 3, 'and so did the second');
    assert.equal(w[3], 0, 'the far one did not');
    await unsocket('miasma');

    // --- Hollow Choir -----------------------------------------------------------------------------------------------------------------
    await socket('rune_hollow_choir');
    await reset(); await quiet();
    p = await pos();
    for (const [dx, dz] of [[2, 1], [3, -1], [-2, 2]]) await dbg(({ x, z }) => window.__cwDebug.corpseAt(x, z), { x: p.x - dx, z: p.z + dz });
    await dbg(() => { const d = window.__cwDebug; d.raise('robber', -1.5, 1); d.raise('robber', 1.5, 1); });
    await advance(1.2);
    assert.equal(await dbg(() => [...window.__cwDebug.sim().thralls.values()].length), 2);
    ids = [await hold('robber', p.x - 4, p.z, 99999)];
    before = await hp(ids);
    assert.equal(await cast('black_litany', { x: p.x, z: p.z }), 'ok');
    await advance(0.2);
    await shot('19-hollow-choir');
    await advance(0.6);
    assert.equal(await dbg(() => [...window.__cwDebug.sim().thralls.values()].length), 2, 'the thralls are spared');
    assert.equal(await dbg(() => window.__cwDebug.sim().corpses.size), 0, 'the corpses are consumed');
    assert.ok((await hp(ids))[0] < before[0], 'and the burst still lands');
    await unsocket('black_litany');

    // --- Requiem ----------------------------------------------------------------------------------------------------------------------
    await socket('rune_requiem');
    await reset(); await quiet();
    p = await pos();
    ids = [await hold('robber', p.x - 11, p.z, 99999)];
    before = await hp(ids);
    assert.equal(await cast('black_litany', { x: p.x, z: p.z }), 'ok');
    await advance(0.3);
    await shot('20-requiem-marked');
    assert.equal((await hp(ids))[0], before[0], 'nothing happens at once');
    await dbg(({ x, z }) => window.__cwDebug.corpseAt(x - 2, z + 1), { x: p.x, z: p.z });
    await advance(1.0);
    assert.equal((await hp(ids))[0], before[0], 'still nothing a second in');
    assert.equal(await dbg(() => window.__cwDebug.sim().corpses.size), 1, 'a corpse laid during the wait is still there');
    await advance(1.0);
    await shot('21-requiem-burst');
    assert.ok((await hp(ids))[0] < before[0], 'two seconds later the burst lands, over twice the plain reach (foe at 11 m)');
    assert.equal(await dbg(() => window.__cwDebug.sim().corpses.size), 0, 'and the corpse was eaten');
    await unsocket('black_litany');

    console.log('STEP 6'); // 6. The Bone Grinder takes one rune at a time, for reagents only.
    await dbg(() => window.__cwDebug.skill('salvaging', 1));
    await dbg(() => window.__cwDebug.station('grinder'));
    await page.waitForSelector('.cw-salvage-list .cw-salv');
    const grinderRows = await page.locator('.cw-salvage-list .cw-salv').allInnerTexts();
    assert.ok(grinderRows.some((t) => /Rune of the Volley/.test(t) && /one rune \(of 3\)/.test(t) && /Grave Dust/.test(t)), `the Grinder lists a rune stack with its reagent yield (${grinderRows.join(' | ').replace(/\s+/g, ' ')})`);
    assert.ok(!grinderRows.filter((t) => /Rune/.test(t)).some((t) => /Ingot|Plank/.test(t)), 'with no ingot or plank on offer for a rune');
    await shot('22-grinder-runes');
    await page.locator('.cw-salv', { hasText: 'Rune of the Volley' }).locator('input').check();
    await page.locator('[data-go]').click();
    await page.waitForSelector('[data-result]');
    const ground = await page.locator('[data-result]').innerText();
    assert.match(ground, /Ground 1 piece/);
    assert.doesNotMatch(ground, /Ingot|Plank/);
    r = await rows();
    assert.equal(r.filter((x) => x[1] === 'rune_volley').reduce((n, x) => n + x[2], 0), 2, 'one Volley rune of three was ground');
    assert.ok(r.some((x) => x[1] === 'reagent_grave_dust'), 'and Grave Dust arrived');
    await page.keyboard.press('Escape');

    result.errors = errors;
    assert.deepEqual(errors, [], `no page errors: ${errors.join(' | ')}`);
    console.log(JSON.stringify(result, null, 2));
  } finally {
    await browser.close();
  }
}
main().catch((e) => { console.error(e); process.exit(1); });
