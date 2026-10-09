// Bot playtest: a Gravecaller plays the Hollow Graves for DM_QA_SECONDS (default 150) of GAME time through REAL keyboard and mouse
// input (WASD to kite, the mouse to aim, keys 1-4 and the right button to cast, a left click to attack, Q for a flask), once per
// reaction delay (default 120 ms and 400 ms; the bot only acts on a snapshot at least that old). It proves the game can be played
// by input alone and reports kills, damage taken and deaths per delay. Idea from Majid Manzarpour's playtest-bot.md (MIT).
//
// Detects: JS/page errors, softlocks (the bot holds a move key for two 12 s windows in a row of game time and the hero moves under 1 m both times; a panel or the
// death overlay stuck up for 12 s; a dead hero that never rises), and warnings (a single pinned window, which the bot's unstick nudge should free; no kill for 60 s while enemies are alive).
// Fails on errors, position/UI/death softlocks, or a run with zero kills. Deaths and the fast-vs-slow comparison are REPORTED, not
// asserted: Math.random is seeded but the sim is not fully deterministic, so a run is a sample (see easy-auto-balance.cjs).
//
//   npx vite --host 127.0.0.1 --port 5388 --strictPort
//   DM_PLAYWRIGHT_MODULE=... DM_CHROMIUM_PATH=... DM_QA_URL='http://127.0.0.1:5388/?offline' node tools/qa/bot-playtest-smoke.cjs
// Env: DM_QA_SECONDS=150  DM_QA_DELAYS=120,400  DM_QA_SEED=7  DM_QA_ARTIFACT_DIR (report.json + end-of-run shot per delay)
// Game time is stepped with __cwDebug.advance (no rendering between slices), so software GL speed does not change the result much.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { VIRTUAL_TIMERS, newCharacter } = require('./lib/first-hour-lib.cjs');
const { preloadModules, shot, isBenign } = require('./lib/qa-common.cjs');

const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5388/?offline';
const SECONDS = +(process.env.DM_QA_SECONDS || 150);
const DELAYS = (process.env.DM_QA_DELAYS || '120,400').split(',').map(Number);
const OUT = process.env.DM_QA_ARTIFACT_DIR || path.join(os.tmpdir(), 'bot-playtest');
fs.mkdirSync(OUT, { recursive: true });
const SLICE = 0.1;            // game seconds per step
const STUCK_WINDOW = 12;      // game seconds
const STALL_WINDOW = 60;
const VIEW = { width: 1280, height: 800 };

// Runs in the page: everything the bot is allowed to "see", plus the screen position of each enemy.
function readState() {
  const d = window.__cwDebug; const p = d.player; const cam = d.camera;
  cam.updateMatrixWorld(); cam.matrixWorldInverse.copy(cam.matrixWorld).invert();
  const V = cam.position.constructor;
  const scr = (x, z) => { const v = new V(x, 0.9, z).project(cam); return { sx: Math.round((v.x + 1) / 2 * window.innerWidth), sy: Math.round((1 - v.y) / 2 * window.innerHeight), front: v.z < 1 }; };
  const enemies = [];
  for (const e of d.sim().enemies.values()) {
    if (e.state === 'dead' || e.area !== p.area) continue;
    enemies.push({ id: e.id, x: e.x, z: e.z, dist: Math.hypot(e.x - p.x, e.z - p.z), ...scr(e.x, e.z) });
  }
  enemies.sort((a, b) => a.dist - b.dist);
  const vis = (sel) => [...document.querySelectorAll(sel)].some((el) => el.offsetParent !== null);
  return {
    x: p.x, z: p.z, hp: p.hp, maxHp: p.stats.maxHp, alive: p.alive, area: p.area, level: p.stats.level,
    kills: d.progression.kills('graves'), enemies: enemies.slice(0, 6), enemyCount: enemies.length,
    panel: vis('.cw-panel-float, .cw-panel, .cw-modal'), death: vis('.hud-death.show'),
  };
}

const onScreen = (e) => e.front && e.sx > 20 && e.sy > 20 && e.sx < VIEW.width - 20 && e.sy < VIEW.height - 120;

async function run(browser, delayMs) {
  const delay = delayMs / 1000;
  const page = await browser.newPage({ viewport: VIEW });
  page.setDefaultTimeout(150000);
  const errors = [];
  page.on('pageerror', (e) => { if (!isBenign(e.message)) errors.push(e.message); });
  page.on('console', (m) => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text()) && !isBenign(m.text())) errors.push(m.text()); });
  await page.addInitScript(VIRTUAL_TIMERS);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
  await page.goto(URL);
  await newCharacter(page, 'Gravecaller', `bot_${delayMs}_${Date.now() % 100000}`);
  await preloadModules(page, { areas: '/server/rules/content/areas.ts' });
  const home = await page.evaluate(() => { const r = window.__qaMods.areas.AREAS.graves.rect; return { x: (r.x0 + r.x1) / 2, z: (r.z0 + r.z1) / 2 + 4 }; });
  const setup = () => page.evaluate(() => { const d = window.__cwDebug; d.unlockAll(); d.clear(); d.goto('graves'); d.advance(0.5, false); });
  await setup();
  await page.evaluate(`window.__botRead = ${readState.toString()}`);

  const rep = { delayMs, seconds: SECONDS, kills: 0, damageTaken: 0, deaths: 0, firstDeathSec: null, flasks: 0, casts: 0, clicks: 0, distance: 0, softlocks: [], stalls: [], unstucks: 0, errors };
  const held = new Set();
  const setKeys = async (want) => {
    for (const k of [...held]) if (!want.has(k)) { await page.keyboard.up(k); held.delete(k); }
    for (const k of want) if (!held.has(k)) { await page.keyboard.down(k); held.add(k); }
  };
  const dirKeys = (dx, dz) => { const s = new Set(); const l = Math.hypot(dx, dz) || 1; dx /= l; dz /= l; if (dx > 0.38) s.add('d'); if (dx < -0.38) s.add('a'); if (dz > 0.38) s.add('s'); if (dz < -0.38) s.add('w'); return s; };

  let t = 0, last = await page.evaluate(() => window.__botRead());
  const startKills = last.kills;
  const history = [{ t: 0, s: last }];
  let nextAct = 0, rot = 0, acts = 0, strafe = 1, lastFlask = -99, prevHp = last.hp, prevAlive = true, deadAt = null;
  let moveWin = { t0: 0, x: last.x, z: last.z, keyTime: 0 }, lastKillT = 0, lastKills = last.kills, uiSince = null, stallReported = -99, unstickUntil = -1, unstickKeys = null;
  let prevPos = { x: last.x, z: last.z }, pinned = 0;

  while (t < SECONDS - 1e-6) {
    const s = await page.evaluate((dt) => { const d = window.__cwDebug; d.advance(dt, false); window.__vt.run(dt * 1000); return window.__botRead(); }, SLICE);
    t = +(t + SLICE).toFixed(3);
    history.push({ t, s }); while (history.length > 80) history.shift();
    rep.distance += Math.hypot(s.x - prevPos.x, s.z - prevPos.z) * (Math.hypot(s.x - prevPos.x, s.z - prevPos.z) < 3 ? 1 : 0); prevPos = { x: s.x, z: s.z };
    if (s.alive && s.hp < prevHp) rep.damageTaken += prevHp - s.hp;
    if (prevAlive && !s.alive) { rep.deaths++; rep.damageTaken += Math.max(0, prevHp); rep.firstDeathSec ??= t; deadAt = t; await setKeys(new Set()); }
    prevHp = s.hp; prevAlive = s.alive;
    if (s.kills > lastKills) { lastKills = s.kills; lastKillT = t; }

    // Dead: wait for the 4 s respawn (a hero that never rises is a softlock), then walk back by the setup hook (the Chapterhouse is far).
    if (!s.alive) {
      if (deadAt !== null && t - deadAt > 12) { rep.softlocks.push({ type: 'death-stuck', at: t }); deadAt = t; await page.evaluate(() => window.__cwDebug.player.revive()); }
      continue;
    }
    if (deadAt !== null) { deadAt = null; await page.keyboard.press('Escape').catch(() => {}); await setup(); moveWin = { t0: t, x: s.x, z: s.z, keyTime: 0 }; lastKillT = t; uiSince = null; continue; }

    // Stuck UI: a panel or the death overlay up for a long time while alive.
    if (s.panel || s.death) {
      uiSince ??= t;
      if (t - uiSince > STUCK_WINDOW) { rep.softlocks.push({ type: 'ui-stuck', at: t, panel: s.panel, death: s.death }); uiSince = t; }
      if (s.panel && t - uiSince > 3) await page.keyboard.press('Escape');
    } else uiSince = null;

    // The bot decides every `delay` of game time, from a snapshot at least `delay` old.
    if (t >= nextAct) {
      nextAct = t + Math.max(delay, SLICE);
      const seen = [...history].reverse().find((h) => h.t <= t - delay)?.s || history[0].s;
      const tgt = seen.enemies[0];
      let want = new Set();
      if (t < unstickUntil) want = unstickKeys;
      else if (tgt) {
        const dx = seen.x - tgt.x, dz = seen.z - tgt.z;
        if (tgt.dist < 4.5) {
          // Retreat, with a sideways drift that flips every 2.5 s so a wall does not trap the bot.
          const k = dirKeys(dx + -dz * 0.6 * strafe, dz + dx * 0.6 * strafe); want = k;
        } else if (tgt.dist > 8 || !onScreen(tgt)) want = dirKeys(-dx, -dz); // too far, or not yet on screen to aim at
        if (Math.floor(t / 2.5) % 2 === 0) strafe = 1; else strafe = -1;
      } else if (Math.hypot(home.x - seen.x, home.z - seen.z) > 5) want = dirKeys(home.x - seen.x, home.z - seen.z);
      if (s.hp / s.maxHp < 0.45 && t - lastFlask > 4) { await page.keyboard.press('q'); lastFlask = t; rep.flasks++; }
      await setKeys(want);
      if (tgt && onScreen(tgt)) {
        await page.mouse.move(tgt.sx, tgt.sy);
        acts++;
        if (acts % 5 === 0) { await page.mouse.click(tgt.sx, tgt.sy, { button: 'right' }); rep.casts++; }
        else if (acts % 7 === 0 && tgt.dist < 8 && want.size === 0) { await page.mouse.click(tgt.sx, tgt.sy); rep.clicks++; }
        else { await page.keyboard.press(String(1 + (rot++ % 4))); rep.casts++; }
      }
      // Softlock window: a move key held (nearly) the whole window but the hero barely moved.
      if (want.size) moveWin.keyTime += Math.max(delay, SLICE);
      if (t - moveWin.t0 >= STUCK_WINDOW) {
        const moved = Math.hypot(s.x - moveWin.x, s.z - moveWin.z);
        if (moveWin.keyTime >= STUCK_WINDOW * 0.9 && moved < 1) {
          // One pinned window can be the bot retreating into a corner; the unstick nudge below should free it. Two in a row is a softlock.
          const rec = { type: 'pinned', at: t, x: +s.x.toFixed(1), z: +s.z.toFixed(1), moved: +moved.toFixed(2) };
          pinned++;
          if (pinned >= 2) rep.softlocks.push({ ...rec, type: 'position' }); else rep.stalls.push(rec);
          rep.unstucks++; unstickUntil = t + 1.5; unstickKeys = new Set([['w', 'a', 's', 'd'][(rep.unstucks) % 4], ['w', 'a', 's', 'd'][(rep.unstucks + 1) % 4]]);
        }
        else if (moveWin.keyTime >= STUCK_WINDOW * 0.9) pinned = 0;
        moveWin = { t0: t, x: s.x, z: s.z, keyTime: 0 };
      }
    }
    if (s.enemyCount > 0 && t - lastKillT > STALL_WINDOW && t - stallReported > STALL_WINDOW) { rep.stalls.push({ type: 'no-kills', at: t, enemies: s.enemyCount }); stallReported = t; }
  }
  await setKeys(new Set());
  const end = await page.evaluate(() => window.__botRead());
  rep.kills = end.kills - startKills; rep.level = end.level; rep.endHp = Math.round(end.hp); rep.damageTaken = Math.round(rep.damageTaken); rep.distance = Math.round(rep.distance);
  await page.evaluate(() => window.__cwDebug.advance(0.1, true));
  await shot(page, path.join(OUT, `bot-${delayMs}ms.png`)).catch(() => {});
  await page.close();
  return rep;
}

(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome', args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const reports = [];
  try { for (const d of DELAYS) { const r = await run(browser, d); reports.push(r); console.log(JSON.stringify(r)); } }
  finally { await browser.close(); }
  fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(reports, null, 1));
  console.log('\ndelay   kills  damage  deaths  firstDeath  flasks  softlocks  stalls');
  for (const r of reports) console.log(`${String(r.delayMs).padStart(4)}ms ${String(r.kills).padStart(6)} ${String(r.damageTaken).padStart(7)} ${String(r.deaths).padStart(7)} ${String(r.firstDeathSec ?? '-').padStart(11)} ${String(r.flasks).padStart(7)} ${String(r.softlocks.length).padStart(10)} ${String(r.stalls.length).padStart(7)}`);
  if (reports.length >= 2) {
    const [fast, slow] = [reports[0], reports[reports.length - 1]];
    console.log(slow.damageTaken <= fast.damageTaken && slow.deaths <= fast.deaths
      ? `note: the ${slow.delayMs} ms bot took no more damage than the ${fast.delayMs} ms bot (one sample; rerun before reading it as "pressure is decorative")`
      : `the slower bot took more damage/deaths (${slow.damageTaken}/${slow.deaths} vs ${fast.damageTaken}/${fast.deaths}): reaction time matters here`);
  }
  for (const r of reports) {
    assert.deepEqual(r.errors, [], `${r.delayMs} ms: page errors`);
    assert.deepEqual(r.softlocks, [], `${r.delayMs} ms: softlocks`);
    assert.ok(r.kills > 0, `${r.delayMs} ms: the bot never killed anything in ${r.seconds} s`);
  }
  console.log('bot playtest ok');
})().catch((e) => { console.error(e); process.exitCode = 1; });
