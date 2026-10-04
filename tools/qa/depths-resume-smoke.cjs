// Offline end-to-end check of the Depths stair's choice: reach depth 5 (a chest floor), leave, click the stair, pick "Resume at depth 5" and land on
// depth 5 with the legion; descend to 6; take the stair again and start from depth 1; a fresh character is offered no choice; the record survives a reload.
//   npm run dev -- --host 127.0.0.1 --port 5357 --strictPort
//   flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock env DM_QA_URL=http://127.0.0.1:5357/?offline DM_PLAYWRIGHT_MODULE=... DM_CHROMIUM_PATH=... DM_QA_ARTIFACT_DIR=/tmp/depths-resume node tools/qa/depths-resume-smoke.cjs
const assert = require('node:assert/strict');
const { mkdirSync } = require('node:fs');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { watchErrors, preloadModules, shot: shotRetry } = require('./lib/qa-common.cjs');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const out = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-depths-resume';
  mkdirSync(out, { recursive: true });
  const result = {};
  const user = `resume_${Date.now() % 100000}`;
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const { errors } = watchErrors(page);
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false, autoGather: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5357/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', user);
    await page.fill('#cw-email', 'resume@example.invalid');
    await page.fill('#cw-pass', 'TestingResume1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    await preloadModules(page, { depths: '/src/content/depths.ts', areas: '/src/content/areas.ts' });
    const dbg = (fn, arg) => page.evaluate(fn, arg);
    const advance = (s) => dbg((n) => window.__cwDebug.advance(n), s);
    const shot = (name) => shotRetry(page, `${out}/${name}.png`);
    const state = () => dbg(() => window.__cwDebug.depths.state());
    const scene = (fn, arg) => dbg(({ src, arg }) => new Function('scene', 'arg', `return (${src})(scene, arg)`)(window.__qaMods.runtime.getRuntime().view, arg), { src: fn.toString(), arg });
    const screenOf = (x, y, z) => dbg(([x, y, z]) => { const cam = window.__cwDebug.camera; const v = cam.position.clone(); v.set(x, y, z).project(cam); return { x: ((v.x + 1) / 2) * window.innerWidth, y: ((1 - v.y) / 2) * window.innerHeight }; }, [x, y, z]);
    const stair = await dbg(() => { const a = window.__qaMods.areas.AREAS.warren.interactables.find((i) => i.kind === 'stair'); return { x: a.x, z: a.z }; });
    const thralls = () => dbg(() => [...window.__cwDebug.sim().thralls.values()].filter((t) => t.owner === window.__cwDebug.self()).length);
    const clickStair = async () => {
      await dbg((s) => window.__cwDebug.teleport(s.x, s.z + 3.6), stair);
      await advance(0.5);
      // A real click walks the hero to the stair; retry if a click lands while the hero is mid-teleport.
      for (let n = 0; n < 4; n++) {
        const at = await screenOf(stair.x, 1.0, stair.z);
        await page.mouse.click(at.x, at.y);
        for (let k = 0; k < 8; k++) {
          await advance(0.5);
          if ((await page.locator('.cw-depthsstair').count()) || (await state()).run) return;
        }
        await dbg((s) => window.__cwDebug.teleport(s.x, s.z + 3.6), stair);
        await advance(0.5);
      }
    };
    const waitRun = async () => { for (let n = 0; n < 40 && !(await state()).run; n++) await advance(0.5); return state(); };
    const raise = () => dbg(() => {
      const d = window.__cwDebug; const m = window.__qaMods.runtime.getRuntime().view.discipline.mods; const p = d.player;
      for (let i = 0; i < 3; i++) { d.sim().addCorpse(p.x - 1.5 + i, p.z + 2, 'normal', 'robber', false, 0, 1, 'depths'); d.sim().applyExhume({ t: 'exhume', by: d.self(), x: p.x - 1.5 + i, z: p.z + 2, r: 2, cap: m.thrallCap, kind: m.thrallKind, hp: 400, damage: 25, attackSpeedMult: 1 }); }
    });
    await dbg(() => { window.__cwDebug.god(); window.__cwDebug.unlockAll(); window.__cwDebug.zoom(0.5); });

    console.log('STEP 1: a character that has never been below depth 1 sees no choice');
    assert.equal(await scene((s) => s.depths.resumeAt()), 0);
    await clickStair();
    let st = await waitRun();
    assert.ok(st.run, 'one click starts the run');
    assert.equal(st.run.depth, 1);
    assert.equal(await page.locator('.cw-depthsstair').count(), 0, 'no card');
    result.freshNoChoice = true;

    console.log('STEP 2: descend to depth 5 (a chest floor)');
    await raise();
    for (let d = 1; d < 5; d++) {
      assert.ok(await dbg(() => window.__cwDebug.depths.fill()), `floor ${d} cleared`);
      assert.ok(await dbg(() => window.__cwDebug.depths.descend()));
    }
    st = await state();
    assert.equal(st.run.depth, 5);
    assert.equal(st.ctl.chest, true);
    await dbg(() => { window.__cwDebug.depths.leave(); return window.__cwDebug.depths.leave(); });
    await advance(1);
    st = await state();
    assert.equal(st.run, null, 'left the Depths');
    assert.equal(await scene((s) => s.depths.resumeAt()), 5, 'the record says 5');

    console.log('STEP 3: the stair now asks');
    await clickStair();
    await page.locator('.cw-depthsstair').waitFor({ timeout: 10000 });
    const card = await page.locator('.cw-depthsstair').innerText();
    assert.match(card, /Resume at depth 5/i);
    assert.match(card, /Descend from depth 1/i);
    assert.equal((await state()).run, null, 'nothing started yet');
    await shot('1-stair-choice');
    result.card = card.replace(/\s+/g, ' ');

    console.log('STEP 4: resume at depth 5');
    await page.getByRole('button', { name: /Resume at depth 5/i }).click();
    st = await waitRun();
    assert.equal(st.run.depth, 5);
    assert.equal(st.run.peak, 5);
    assert.equal(st.floor.depth, 5);
    assert.equal(st.hud.depth, 5);
    assert.equal(st.ctl.chest, true, 'depth 5 holds its chest');
    assert.equal(st.run.need, await dbg(() => window.__qaMods.depths.floorKills(5)));
    await raise();
    await advance(6);
    const lvls = await dbg(() => { const d = window.__cwDebug; return { hero: d.sim().players.get(d.self())?.level, want: window.__qaMods.depths.depthEnemyLevel(5, d.sim().players.get(d.self())?.level ?? 1), area: d.sim().areaLevel('depths'), enemies: [...d.sim().enemies.values()].filter((e) => e.area === 'depths').map((e) => e.level) }; });
    assert.ok(lvls.enemies.length > 0, 'the dead climb out');
    assert.ok(lvls.enemies.every((l) => l >= lvls.want), `enemies at depth 5 level (${JSON.stringify(lvls)})`);
    assert.equal(await thralls(), 3, 'the legion came along');
    const banner = await page.locator('.hud-banner, .cw-banner').first().innerText().catch(() => '');
    result.levels = lvls;
    await shot('2-arrival-depth-5');
    result.banner = banner;

    console.log('STEP 5: descend from the resumed floor reaches 6');
    assert.ok(await dbg(() => window.__cwDebug.depths.fill()));
    assert.ok(await dbg(() => window.__cwDebug.depths.descend()));
    st = await state();
    assert.equal(st.run.depth, 6);
    assert.equal(await thralls(), 3);
    await dbg(() => { window.__cwDebug.depths.leave(); return window.__cwDebug.depths.leave(); });
    await advance(1);
    assert.equal(await scene((s) => s.depths.resumeAt()), 6);

    console.log('STEP 6: starting at depth 1 still works for a deep character');
    await clickStair();
    await page.locator('.cw-depthsstair').waitFor({ timeout: 10000 });
    await page.getByRole('button', { name: /Descend from depth 1/i }).click();
    st = await waitRun();
    assert.equal(st.run.depth, 1);
    assert.equal(st.hud.depth, 1);
    assert.equal(await scene((s) => s.depths.resumeAt()), 6, 'the record is not lowered');

    console.log('STEP 7: dying on a floor still counts it as reached');
    await dbg(() => window.__cwDebug.depths.leave()); await dbg(() => window.__cwDebug.depths.leave());
    await advance(1);
    assert.ok(await dbg(() => window.__cwDebug.depths.enter(7, 10)), 'enter at 10 (QA hook)');
    await scene((s) => s.depths.onPlayerDeath());
    assert.equal(await scene((s) => s.depths.resumeAt()), 10);
    await scene((s) => s.depths.finishAfterDeath());

    console.log('STEP 8: the record is server-side (the mock mirrors it) and survives a reload');
    await scene((s) => s.chronicle.flush());
    await page.waitForTimeout(500);
    await page.reload();
    // The session survives the reload (straight back into the world), or the login form shows first; either way the same character loads.
    if (await page.locator('#cw-user').waitFor({ timeout: 6000 }).then(() => true, () => false)) {
      await page.fill('#cw-user', user);
      await page.fill('#cw-pass', 'TestingResume1');
      await page.locator('#cw-login-btn').click();
    }
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
    await preloadModules(page, {});
    await page.waitForFunction(() => window.__qaMods.runtime.getRuntime().view.chronicle.isLoaded, null, { timeout: 30000 });
    result.afterReload = await scene((s) => s.depths.resumeAt());
    assert.equal(result.afterReload, 10);
    assert.equal(errors.length, 0, errors.join('\n'));
    console.log(JSON.stringify(result, null, 1));
  } finally {
    await browser.close();
  }
}
main().catch((e) => { console.error(e); process.exitCode = 1; });
