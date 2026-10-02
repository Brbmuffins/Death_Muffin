// Offline UI + behaviour check for the Catacomb Depths: the stair in the Warren (glow, hover label, the counsel card), entering, a floor's readout, clearing a floor
// (the stair opens: banner, cue, minimap ping, rewards), going down with the legion, elites with two affixes and the chest at depth 5, dying (the run ends, the deepest
// floor is written to the Chronicle and shown in the Codex), leaving by the way up, the stair refusing a party, and the phone layout.
//   npm run dev -- --host 127.0.0.1 --port 5356 --strictPort
//   DM_QA_URL=http://127.0.0.1:5356/?offline DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_CHROMIUM_PATH=/path/to/chrome DM_QA_ARTIFACT_DIR=/tmp/depths node tools/qa/depths-smoke.cjs
// Do not edit src/ while it runs: Vite hot-reloads the page and the run dies.
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { watchErrors, preloadModules, shot: shotRetry } = require('./lib/qa-common.cjs');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-depths';
  mkdirSync(out, { recursive: true });
  const result = {};
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const { errors } = watchErrors(page);
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: true, autoCombat: false, autoGather: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5356/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `depths_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'depths@example.invalid');
    await page.fill('#cw-pass', 'TestingDepths1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    await preloadModules(page, { depths: '/src/content/depths.ts', areas: '/src/content/areas.ts' });
    const dbg = (fn, arg) => page.evaluate(fn, arg);
    const advance = (s) => dbg((n) => window.__cwDebug.advance(n), s);
    const shot = (name, opts) => shotRetry(page, `${out}/${name}.png`, opts);
    const state = () => dbg(() => window.__cwDebug.depths.state());
    const scene = (fn, arg) => dbg(({ src, arg }) => new Function('scene', 'arg', `return (${src})(scene, arg)`)(window.__qaMods.runtime.getRuntime().view, arg), { src: fn.toString(), arg });
    /** Where a world point lands on the screen. */
    const screenOf = (x, y, z) => dbg(([x, y, z]) => {
      const cam = window.__cwDebug.camera;
      const v = cam.position.clone();
      v.set(x, y, z).project(cam);
      return { x: ((v.x + 1) / 2) * window.innerWidth, y: ((1 - v.y) / 2) * window.innerHeight };
    }, [x, y, z]);
    const stair = await dbg(() => { const a = window.__qaMods.areas.AREAS.warren.interactables.find((i) => i.kind === 'stair'); return { x: a.x, z: a.z }; });

    console.log('STEP 1'); // 1. The stair in the Warren: lit, labelled on hover, explained by a counsel card.
    await dbg(() => { window.__cwDebug.god(); window.__cwDebug.unlockAll(); window.__cwDebug.zoom(0.45); });
    await dbg((s) => window.__cwDebug.teleport(s.x + 4.5, s.z + 2.8), stair);
    await advance(1.5);
    // Walking up to the stair queues the card (the natural trigger); danger cards about the Warren's own dead go first, so keep the hall quiet and
    // dismiss whatever is up until the calm card's turn comes (cards age in real time).
    await dbg(() => { window.__cwDebug.clear(); window.__cwDebug.freeze(true); });
    assert.ok(await scene((s) => s.onboarding.queue.some((q) => q.id === 'depths') || s.onboarding.shownIds?.has?.('depths') || !!document.querySelector('.cw-tip')), 'the stair queues its counsel card');
    // Calm cards wait behind the Warren's danger cards (and for a lull), so hold the Warren's waves off, keep it empty and dismiss whatever is up
    // until the stair's card has its turn (cards age in real time).
    let tip = '';
    for (let n = 0; n < 60 && !/A stair in the dark/.test(tip); n++) {
      await dbg(() => { const d = window.__cwDebug; d.sim().waveTimers.set('warren', 1e9); d.clear(); });
      await advance(2);
      await page.waitForTimeout(1000);
      const titles = await page.locator('.cw-tip .title').allTextContents().catch(() => []);
      tip = titles.find((t) => /A stair in the dark/.test(t)) ?? '';
      if (process.env.DM_QA_TRACE) console.log('tip loop', n, JSON.stringify(titles));
      if (!tip && titles.length) await page.locator('.cw-tip').first().click({ position: { x: 20, y: 40 } }).catch(() => {});
    }
    assert.match(tip, /A stair in the dark/, 'the counsel card explains the stair when the hero walks up to it');
    const tipText = await page.locator('.cw-tip').first().innerText();
    assert.match(tipText, /Catacomb Depths/);
    assert.match(tipText, /Solo for now/);
    await shot('1-warren-stair-tip');
    await page.locator('.cw-tip').first().click({ position: { x: 20, y: 40 } }).catch(() => {});
    await advance(0.5);
    const at = await screenOf(stair.x, 1.0, stair.z);
    await page.mouse.move(at.x, at.y);
    await advance(0.3);
    const prompt = await page.locator('.hud-prompt').innerText();
    assert.match(prompt, /Descend into the Catacomb Depths/, `hovering the stair names it (${prompt})`);
    await shot('2-warren-stair-hover');
    result.hoverLabel = prompt;

    console.log('STEP 2'); // 2. The stair says so when the hero is grouped (solo for now) and does nothing.
    await scene((s) => { s.depths.host.__realParty = s.depths.host.partySize; s.depths.host.partySize = () => 1; });
    await advance(0.3);
    const grouped = await page.locator('.hud-prompt').innerText();
    assert.match(grouped, /solo for now: leave your party/i, `the stair tells a party why not (${grouped})`);
    await page.mouse.click(at.x, at.y);
    await advance(2.5);
    assert.equal((await state()).run, null, 'a grouped click starts no run');
    assert.match(await page.locator('.hud-toasts').innerText(), /solo for now/i, 'and a toast says so');
    await shot('3-stair-grouped');
    await scene((s) => { s.depths.host.partySize = s.depths.host.__realParty; });

    console.log('STEP 3'); // 3. A real click on the stair walks the hero to it and goes down: depth 1, the readout, the arrival banner, the minimap floor.
    await dbg((s) => window.__cwDebug.teleport(s.x, s.z + 3.6), stair);
    await advance(0.5);
    const click2 = await screenOf(stair.x, 1.0, stair.z);
    await page.mouse.click(click2.x, click2.y);
    for (let n = 0; n < 30 && !(await state()).run; n++) await advance(0.5);
    let st = await state();
    assert.ok(st.run, 'clicking the stair starts a run');
    assert.equal(st.run.depth, 1);
    assert.equal(st.run.need, 10);
    assert.equal(await dbg(() => window.__cwDebug.player.area), 'depths', 'the hero stands on the Depths ground');
    await advance(1.2);
    assert.match(await page.locator('.hud-banner .t').innerText(), /Depth 1/i);
    const readout = await page.locator('.hud-depth').innerText();
    assert.match(readout, /Depth\s*1/i);
    assert.match(readout, /0\/10/);
    assert.equal(await page.locator('.hud-depth.open').count(), 0, 'the stair is not open yet');
    await shot('4-floor1-arrival');
    // The floor the generator promised: the hero is on its start, the stair down is the farthest room.
    assert.ok(Math.hypot(st.floor.start.x - (await dbg(() => window.__cwDebug.player.x)), st.floor.start.z - (await dbg(() => window.__cwDebug.player.z))) < 2.5, 'the hero arrives at the way in');
    result.floor1 = st.floor;

    console.log('STEP 4'); // 4. The dead come through the doorways; thralls follow; a fight; then the quota.
    await dbg(() => {
      const d = window.__cwDebug;
      const m = window.__qaMods.runtime.getRuntime().view.discipline.mods;
      const p = d.player;
      for (let i = 0; i < 3; i++) {
        d.sim().addCorpse(p.x - 1.5 + i, p.z + 2, 'normal', 'robber', false, 0, 1, 'depths');
        d.sim().applyExhume({ t: 'exhume', by: d.self(), x: p.x - 1.5 + i, z: p.z + 2, r: 2, cap: m.thrallCap, kind: m.thrallKind, hp: 400, damage: 25, attackSpeedMult: 1 });
      }
    });
    await dbg(() => window.__cwDebug.zoom(0.7));
    for (let n = 0; n < 40 && (await dbg(() => window.__cwDebug.sim().enemies.size)) < 6; n++) await advance(1);
    assert.ok((await dbg(() => window.__cwDebug.sim().enemies.size)) >= 6, 'the first wave climbed out');
    assert.equal(await dbg(() => [...window.__cwDebug.sim().thralls.values()].filter((t) => t.owner === window.__cwDebug.self()).length), 3, 'three thralls raised');
    // Let a fight happen for real (god mode keeps the hero up): the thralls and Bone Needle kill what comes.
    await dbg(() => window.__cwDebug.freeze(false));
    for (let n = 0; n < 12; n++) {
      await dbg(() => { window.__cwDebug.aimAtNearest?.(); window.__cwDebug.cast?.(0); });
      await advance(2);
    }
    await shot('5-floor1-fight');
    const mid = await state();
    result.killsInFight = mid.run.kills;
    // Meet the quota: what is left alive dies, and what climbs out is killed until the stair opens (real death events, real rewards).
    const opened = await dbg(() => window.__cwDebug.depths.fill());
    assert.ok(opened, 'the quota is met and the stair opens');
    await advance(1.5);
    st = await state();
    assert.equal(st.run.stairOpen, true);
    assert.equal(st.hud.open, true);
    assert.match(await page.locator('.hud-banner .t').innerText(), /The stair opens/i);
    assert.match(await page.locator('.hud-depth').innerText(), /Stair open/i);
    assert.equal(await page.locator('.hud-depth.open').count(), 1, 'the readout turns gold');
    assert.ok((await dbg(() => window.__cwDebug.lootDrops().length)) >= 1, 'the floor left loot');
    await dbg((f) => window.__cwDebug.teleport(f.x, f.z + 3.5), st.floor.stairDown);
    await advance(1.0);
    await shot('6-stair-open');
    result.floorsCleared = st.run.floors;

    console.log('STEP 5'); // 5. Down the stair with the legion; the new floor is clean and one level older.
    const thrallsBefore = await dbg(() => [...window.__cwDebug.sim().thralls.values()].filter((t) => t.owner === window.__cwDebug.self()).length);
    const lvl1 = await dbg(() => window.__cwDebug.sim().areaLevel('depths'));
    const sd = await screenOf(st.floor.stairDown.x, 1.0, st.floor.stairDown.z);
    await page.mouse.click(sd.x, sd.y);
    for (let n = 0; n < 30 && (await state()).run.depth < 2; n++) await advance(0.5);
    st = await state();
    assert.equal(st.run.depth, 2, 'the stair took the hero to depth 2');
    assert.notEqual(st.floor.seed, result.floor1.seed, 'a different floor');
    assert.equal(st.run.stairOpen, false);
    assert.equal(await dbg(() => window.__cwDebug.sim().corpses.size), 0, 'the old floor\'s corpses are gone');
    await advance(1);
    const thrallsAfter = await dbg(() => { const d = window.__cwDebug; return [...d.sim().thralls.values()].filter((t) => t.owner === d.self()).map((t) => Math.hypot(t.x - d.player.x, t.z - d.player.z)); });
    assert.equal(thrallsAfter.length, thrallsBefore, 'the legion came down with the hero');
    assert.ok(thrallsAfter.every((d) => d < 8), `and stands beside them (${thrallsAfter.map((d) => d.toFixed(1))})`);
    assert.equal(await dbg(() => window.__cwDebug.sim().areaLevel('depths')), lvl1 + 1, 'the dead are one level older');
    assert.match(await page.locator('.hud-depth').innerText(), /Depth\s*2/i);
    await shot('7-floor2-legion');
    result.legion = thrallsAfter.length;

    console.log('STEP 6'); // 6. Depth 5: elites carry a second affix, the chest waits in a side chamber; open it.
    for (let d = 2; d < 5; d++) {
      assert.ok(await dbg(() => window.__cwDebug.depths.fill()), `floor ${d} cleared`);
      assert.ok(await dbg(() => window.__cwDebug.depths.descend()), `down to ${d + 1}`);
      await advance(0.5);
    }
    st = await state();
    assert.equal(st.run.depth, 5);
    assert.ok(st.floor.chest, 'the fifth floor holds a chest');
    assert.equal(st.hud.chest, true);
    await advance(2.5);
    // An elite here carries two affixes; the target frame names both.
    const elite = await dbg(() => {
      const d = window.__cwDebug;
      const p = d.player;
      const e = d.sim().spawnEnemy('robber', 'depths', p.x + 3, p.z - 3, true, false);
      e.speed = 0;
      return { id: e.id, affixes: [e.affix, ...(e.extra ?? []).map((x) => x.affix)] };
    });
    assert.equal(elite.affixes.length, 2, `an elite on depth 5 carries two affixes (${elite.affixes})`);
    await advance(0.3);
    const eAt = await dbg((id) => { const e = window.__cwDebug.sim().enemies.get(id); return { x: e.x, z: e.z }; }, elite.id);
    const eScreen = await screenOf(eAt.x, 0.9, eAt.z);
    await page.mouse.move(eScreen.x, eScreen.y);
    await advance(0.4);
    const affixPills = await page.locator('.hud-target .affix').count();
    assert.equal(affixPills, 2, 'the target frame shows both affixes');
    await shot('8-depth5-elite-two-affixes');
    await dbg((id) => window.__cwDebug.sim().enemies.delete(id), elite.id);
    await page.mouse.move(640, 740);
    // The chest: click it for real.
    await dbg((c) => window.__cwDebug.teleport(c.x, c.z + 3.2), st.floor.chest);
    await advance(0.8);
    const cs = await screenOf(st.floor.chest.x, 0.6, st.floor.chest.z);
    // Hover the chest; a loose coin or a corpse ring beside it can win the pick, so nudge a little until the chest does.
    let hovered = '';
    for (const [dx, dy] of [[0, 0], [0, 10], [8, 4], [-8, 4], [0, -10], [14, 14], [-14, 14]]) {
      await page.mouse.move(cs.x + dx, cs.y + dy);
      await advance(0.3);
      hovered = await page.locator('.hud-prompt').innerText();
      if (/Open the chest/.test(hovered)) { cs.x += dx; cs.y += dy; break; }
    }
    await shot('9-chest');
    assert.match(hovered, /Open the chest/, `hover said '${hovered}': chest ${JSON.stringify(st.floor.chest)} stair ${JSON.stringify(st.floor.stairDown)} up ${JSON.stringify(st.floor.stairUp)} cursor ${JSON.stringify(cs)} hero ${JSON.stringify(await dbg(() => [window.__cwDebug.player.x, window.__cwDebug.player.z]))}`);
    // Finds are on the ground or already picked up (the hero stands close): count both.
    const finds = () => dbg(() => window.__cwDebug.lootDrops().length + window.__cwDebug.inventory.all.filter((r) => r.slot_index < 48).reduce((n, r) => n + r.quantity, 0));
    const lootBefore = await finds();
    await page.mouse.click(cs.x, cs.y);
    for (let n = 0; n < 20 && !(await state()).ctl.opened; n++) await advance(0.4);
    assert.equal((await state()).ctl.opened, true, 'the chest opened');
    assert.match(await page.locator('.hud-banner .t').innerText(), /The chest opens/i);
    // The gear waits for the server's roll (the offline mock answers a moment later): wait for the finds to land.
    let lootAfter = lootBefore;
    for (let n = 0; n < 40 && lootAfter - lootBefore < 3; n++) {
      await advance(0.5);
      await page.waitForTimeout(200);
      lootAfter = await finds();
    }
    assert.ok(lootAfter - lootBefore >= 3, `a chest holds at least three finds (${lootAfter - lootBefore})`);
    await shot('10-chest-open');
    result.chestDrops = lootAfter - lootBefore;
    // Spent: it no longer offers itself.
    assert.equal(await dbg(() => !!document.querySelector('.hud-prompt:not([hidden])')?.textContent?.includes('chest')), false);

    console.log('STEP 7'); // 7. Dying ends the run: the deepest floor goes to the Chronicle and the Codex shows it; the hero rises in the Chapterhouse.
    await dbg(() => { window.__cwDebug.god(false); });
    await dbg(() => { const d = window.__cwDebug; d.sim().emit({ t: 'hurt', player: d.self(), dmg: 1e7, from: 'melee', x: d.player.x, z: d.player.z }); });
    for (let n = 0; n < 10 && (await dbg(() => window.__cwDebug.player.alive)); n++) {
      await dbg(() => { const d = window.__cwDebug; d.god(false); d.sim().emit({ t: 'hurt', player: d.self(), dmg: 1e7, from: 'melee', x: d.player.x, z: d.player.z }); });
      await advance(0.4);
    }
    assert.equal(await dbg(() => window.__cwDebug.player.alive), false, 'the hero fell');
    const dead = await state();
    assert.equal(dead.ctl.over, true, `the run is over (${JSON.stringify({ run: dead.run && { depth: dead.run.depth }, ctl: dead.ctl, area: await dbg(() => window.__cwDebug.player.area) })})`);
    await shot('11-death');
    for (let n = 0; n < 40 && (await dbg(() => !window.__cwDebug.player.alive)); n++) await advance(0.5);
    await advance(0.5);
    assert.equal(await dbg(() => window.__cwDebug.player.area), 'chapterhouse', 'the hero rose in the Chapterhouse');
    st = await state();
    assert.equal(st.run, null, 'and the Depths closed behind them');
    assert.equal(await dbg(() => window.__cwDebug.sim().enemies.size), 0);
    const best = await scene((s) => s.chronicle.view().life['peak.depth']);
    assert.equal(best, 5, 'the Chronicle holds depth 5 as the deepest floor');
    assert.ok((await scene((s) => s.chronicle.view().life['depths.chests'])) >= 1);
    await scene((s) => s.chronicle.flush());
    await page.keyboard.press('k');
    await page.waitForSelector('.cw-codex');
    await page.getByRole('button', { name: 'Chronicle' }).first().click().catch(async () => { await page.locator('.cw-codex button', { hasText: 'Chronicle' }).first().click(); });
    await advance(0.3);
    const chron = await page.locator('.cw-codex').innerText();
    assert.match(chron, /Deepest descent\s*Depth 5/i, 'the Chronicle shows the deepest descent');
    await shot('12-chronicle-best-depth');
    await page.keyboard.press('k');
    await page.waitForSelector('.cw-codex', { state: 'detached', timeout: 5000 }).catch(() => {});
    result.chronicleBest = best;

    console.log('STEP 8'); // 8. The way up: asks twice, ends the run, puts the hero back at the Warren stair. Then the phone layout on a fresh floor.
    await dbg(() => { window.__cwDebug.god(); window.__cwDebug.unlockAll(); });
    await dbg((s) => window.__cwDebug.teleport(s.x, s.z + 3.6), stair);
    await advance(0.5);
    assert.ok(await dbg(() => window.__cwDebug.depths.enter(31337)), 're-entered');
    await advance(1);
    st = await state();
    const up = st.floor.stairUp;
    // The way in sits against the south wall under the hero: stand just south of it so it is mid-screen, clear of the dock.
    await dbg((u) => window.__cwDebug.teleport(u.x, u.z + 1.5), up);
    await advance(0.6);
    const upScreen = await screenOf(up.x, 0.4, up.z);
    await page.mouse.move(upScreen.x, upScreen.y);
    await advance(0.3);
    assert.match(await page.locator('.hud-prompt').innerText(), /Climb out/);
    // The phone: the same floor at 390x844 with touch.
    await page.setViewportSize({ width: 390, height: 844 });
    await dbg(() => window.__cwDebug.zoom(0.7));
    await advance(2);
    await shot('13-phone-floor');
    const box = await page.locator('.hud-depth').boundingBox();
    assert.ok(box && box.x >= 0 && box.x + box.width <= 390 && box.y >= 0 && box.y + box.height <= 844, `the depth readout fits a phone (${JSON.stringify(box)})`);
    const mapBox = await page.locator('.hud-map .frame').boundingBox();
    assert.ok(mapBox.y + mapBox.height <= box.y + 1, 'and sits below the minimap');
    result.phoneReadout = box;
    await dbg(() => window.__cwDebug.depths.fill());
    await advance(1.5);
    await shot('14-phone-stair-open');
    await page.setViewportSize({ width: 1280, height: 800 });
    await advance(0.5);
    await dbg(() => window.__cwDebug.zoom(0.45));
    const upScreen2 = await screenOf(up.x, 0.4, up.z);
    await page.mouse.move(upScreen2.x, upScreen2.y);
    await advance(0.4);
    await shot('14b-before-up-click');
    assert.match(await page.locator('.hud-prompt').innerText(), /Climb out/, `hovering the way up at ${JSON.stringify(upScreen2)}`);
    await page.mouse.click(upScreen2.x, upScreen2.y);
    await advance(2.5);
    assert.ok((await state()).run, 'the first click on the way up only asks');
    assert.match(await page.locator('.hud-toasts').innerText(), /Climbing out ends this run/);
    await page.mouse.click(upScreen2.x, upScreen2.y);
    for (let n = 0; n < 20 && (await state()).run; n++) await advance(0.4);
    st = await state();
    assert.equal(st.run, null, 'the second click ends the run');
    assert.equal(await dbg(() => window.__cwDebug.player.area), 'warren', 'the hero is back in the Warren');
    const back = await dbg((s) => Math.hypot(window.__cwDebug.player.x - s.x, window.__cwDebug.player.z - s.z), stair);
    assert.ok(back < 4, `beside the stair (${back.toFixed(1)} m)`);
    await shot('15-back-at-the-stair');

    assert.deepEqual(errors, [], `no page errors: ${errors.join(' | ')}`);
    console.log(JSON.stringify(result));
    console.log('depths smoke ok');
  } finally {
    await browser.close();
  }
}
main().then(() => process.exit(0), (e) => { console.error(e); process.exit(1); });
