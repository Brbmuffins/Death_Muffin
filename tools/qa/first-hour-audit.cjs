// Plays the first hour of a brand-new character and records what appears when (counsel cards, toasts, banners, the Next line,
// panels, conversations), screenshots at every new popup, and reports overlapping HUD elements. UI timers run on game time
// (see lib). Fighting is real (the Hollow Graves, the Marrow Ossuary); the long stretches between are compressed with
// __cwDebug (xp, kills, gold, gear drops), and the log says where.
//   npm run dev -- --host 127.0.0.1 --port 5343 --strictPort
//   DM_DISC=Ossuary DM_PHASES=A,B,C,D,E,F,G,H DM_W=1280 DM_H=800 DM_OUT=/tmp/fh node tools/qa/first-hour-audit.cjs
// Phases: A Acre, B Chapterhouse + Prior, C Graves fight, D panels (I J L K P), E levels/seals/gear, F Ossuary, G Wing, H Acre bag + Sexton.
const { mkdirSync, writeFileSync } = require('node:fs');
const { launch, newCharacter, step, overlaps } = require('./lib/first-hour-lib.cjs');

const DISC = process.env.DM_DISC || 'Ossuary';
const PHASES = (process.env.DM_PHASES || 'A,B,C,D,E,F,G,H').split(',');
const W = Number(process.env.DM_W || 1280), H = Number(process.env.DM_H || 800);
const OUT = process.env.DM_OUT || '/tmp/death-muffin-first-hour';
const FIGHT_S = Number(process.env.DM_FIGHT || 150);
const MAX_SHOTS = Number(process.env.DM_MAX_SHOTS || 70);

(async () => {
  mkdirSync(OUT, { recursive: true });
  const { browser, page, errors } = await launch({ width: W, height: H });
  const log = [];
  const L = (m) => { log.push(m); console.log(m); };
  try {
    await newCharacter(page, DISC);
    const ev = (fn, a) => page.evaluate(fn, a);
    const gt = () => ev(() => window.__fhGt);
    let shots = 0, seenEvents = 0;
    const overlapLog = new Map();
    let overlapShots = 0;
    const seenTitles = new Set();
    const shot = async (label) => {
      if (shots >= MAX_SHOTS) return;
      const t = Math.round(await gt());
      const name = `${String(shots++).padStart(3, '0')}-t${String(t).padStart(4, '0')}-${label.replace(/[^a-z0-9]+/gi, '_').slice(0, 40)}`;
      await ev(() => window.__cwDebug.advance(0));
      await page.screenshot({ path: `${OUT}/${name}.png` });
    };
    const STATIC = /^(upgrades|altar|xpbar|currency|menu|minimap|area|prog|party|hint|omen|ward|brews|chain)/;
    const sample = async (info) => {
      if (info.n > seenEvents) {
        const fresh = await ev((n) => window.__fhEvents.slice(n), seenEvents);
        seenEvents = info.n;
        for (const e of fresh) L(`t=${e.t}s ${e.ev} ${e.name}: ${e.label}${e.dur ? ` (${e.dur}s)` : ''}`);
        const big = fresh.find((e) => e.ev === 'on' && ['tip', 'dialogue', 'banner'].includes(e.name) && !seenTitles.has(e.name + e.label));
        if (big) { seenTitles.add(big.name + big.label); await shot(`${big.name}-${big.label}`); }
      }
      for (const o of overlaps(info.rects, ['party+minimap', 'target+boss'])) {
        const key = `${o.a} x ${o.b}`;
        if (overlapLog.has(key)) continue;
        overlapLog.set(key, info.gt);
        L(`OVERLAP t=${Math.round(info.gt)}s ${key} (${o.ox}x${o.oy})`);
        if (!(STATIC.test(o.a) && STATIC.test(o.b)) && !/^(panel|death)/.test(o.a) && !/^(panel|death)/.test(o.b) && overlapShots++ < 8) await shot('overlap');
      }
    };
    const run = (s) => step(page, s, sample);
    const state = () => ev(() => { const d = window.__cwDebug; return { lvl: d.progression.character.level, kills: d.progression.local.totalKills, area: d.player.area, hp: Math.round(d.player.hp), gold: d.progression.character.gold, bag: d.inventory.all.length }; });
    // A modest bot: face and strike the nearest enemy, rotate rites, drink a flask (set hp) when below a third, and walk back to the hall
    // it is meant to be fighting in after a death. It is a stand-in for a player, not a measure of how hard the game is.
    const fight = async (seconds, area = null) => {
      for (let t = 0; t < seconds; t += 1) {
        await ev(([k, want]) => {
          const d = window.__cwDebug;
          if (want && d.player.area !== want && d.player.alive) d.goto(want);
          if (d.player.hp < d.player.stats.maxHp / 3) d.player.hp = d.player.stats.maxHp;
          d.aimAtNearest(); d.attackNearest(); if (k % 2 === 0) d.cast(1 + ((k / 2) % 4));
        }, [t, area]);
        await run(1);
        if (t % 20 === 19) L(`state t=${Math.round(await gt())}s ${JSON.stringify(await state())}`);
      }
    };
    // Close whatever is open, one Escape at a time, never opening Settings by accident.
    const closeAll = async () => {
      for (let i = 0; i < 4; i++) {
        const open = await ev(() => !!document.querySelector('.cw-dialogue, .cw-panel-float'));
        if (!open) return;
        await page.keyboard.press('Escape'); await run(0.6);
      }
    };
    const key = async (k, wait = 1.5, label) => { L(`action: press ${k}`); await page.keyboard.press(k); await run(wait); await shot(label || `key-${k}`); await closeAll(); };
    const phase = (p) => PHASES.includes(p);
    const note = async (s) => L(`## t=${Math.round(await gt())}s ${s}`);

    L(`# ${DISC} @ ${W}x${H}  phases ${PHASES.join(',')}`);
    if (phase('A')) {
      await note('A: spawn in the Sexton\'s Acre');
      await run(2); await shot('spawn');
      await run(22); await shot('acre-25s');
      L('action: gather at a tree');
      await ev(() => window.__cwDebug.gatherAt('oak') ?? window.__cwDebug.gatherAt('copper'));
      await run(14); await shot('acre-gathering');
    }
    if (phase('B')) {
      await note('B: walk to the Chapterhouse, talk to the Prior');
      await ev(() => { const d = window.__cwDebug; d.goto('chapterhouse'); d.player.teleport(-1.2, 17.5); });
      await run(3); await shot('chapterhouse');
      await page.keyboard.press('e'); await run(1.5); await shot('prior-greet');
      await page.locator('.cw-dialogue .choice', { hasText: 'Where should I go next?' }).first().click().catch(() => {});
      await run(2); await shot('prior-advice');
      await closeAll();
    }
    if (phase('C')) {
      await note('C: north to the Hollow Graves, fight');
      await ev(() => { window.__cwDebug.goto('graves'); });
      await run(5); await shot('graves-arrive');
      await fight(FIGHT_S, 'graves');
      await shot('graves-after-fight');
    }
    if (phase('D')) {
      await note('D: a curious player opens the panels');
      await key('i', 1.5, 'inventory');
      await key('j', 1.5, 'character-sheet');
      await key('l', 1.5, 'grimoire');
      await key('k', 1.5, 'codex');
      await key('p', 1.5, 'skills');
      await run(10);
    }
    if (phase('E')) {
      await note('E: COMPRESSED to about minute 12: levels, graves kills, gear drops');
      await ev(() => { const d = window.__cwDebug; d.xp(1500); d.gold(600); for (let i = 0; i < 150; i++) d.progression.recordKill('graves'); });
      await run(3);
      for (const [item, lvl, src] of [['helm_copper', 6, 'kill'], ['chest_iron', 10, 'elite']]) {
        await ev(([i, l, s]) => window.__cwDebug.dropGear(i, l, s), [item, lvl, src]);
        await page.waitForFunction(() => window.__cwDebug.rollsPending() === 0, null, { timeout: 20000 }).catch(() => {});
        await run(3);
      }
      await fight(30, 'graves');
      await shot('after-compress-1');
      await key('i', 1.5, 'inventory-with-gear');
      await note('E2: COMPRESSED to about minute 20: 300 graves kills (Ossuary seal), a Gravedigger trophy, shards');
      await ev(() => { const d = window.__cwDebug; for (let i = 0; i < 160; i++) d.progression.recordKill('graves'); d.progression.unlock('ossuary'); d.shards(3); d.xp(2500); });
      await run(3);
    }
    if (phase('F')) {
      await note('F: the Marrow Ossuary in depth');
      await ev(() => { const d = window.__cwDebug; d.goto('ossuary'); });
      await run(5); await shot('ossuary-arrive');
      await fight(120, 'ossuary');
      await shot('ossuary-after-fight');
      await ev(() => { const d = window.__cwDebug; d.spawn('wraith', true); d.spawn('golem'); d.spawn('censer'); });
      await fight(40, 'ossuary');
    }
    if (phase('G')) {
      await note('G: the Alchemist\'s Wing with Grave Dust');
      await ev(() => { const d = window.__cwDebug; d.inventory.add({ item_id: 'reagent_grave_dust', quantity: 6 }); d.goto('alchemist_wing'); d.player.teleport(40.6, 20); });
      await run(6); await shot('wing');
      await page.keyboard.press('e'); await run(1.5); await shot('apothecary-greet');
      await page.locator('.cw-dialogue .choice', { hasText: 'What should I brew?' }).first().click().catch(() => {});
      await run(2); await shot('apothecary-advice');
      await closeAll();
      await run(20);
    }
    if (phase('H')) {
      await note('H: back to the Acre with a filling bag, talk to the Sexton');
      await ev(() => { const d = window.__cwDebug; d.goto('acre'); d.player.teleport(-21.5, 27); for (let i = 0; i < 36; i++) d.inventory.add({ item_id: i % 2 ? 'helm_copper' : 'staff_oak', quantity: 1 }); });
      await run(8); await shot('acre-bag-filling');
      await page.keyboard.press('e'); await run(1.5); await shot('sexton-greet');
      await page.locator('.cw-dialogue .choice', { hasText: 'What needs doing?' }).first().click().catch(() => {});
      await run(2); await shot('sexton-advice');
      await closeAll();
      await run(30);
    }
    await shot('end');
    writeFileSync(`${OUT}/timeline.json`, JSON.stringify(await ev(() => window.__fhEvents), null, 1));
  } catch (e) {
    L('FAILED ' + e.stack);
    try { await page.screenshot({ path: `${OUT}/zz-failure.png` }); } catch {}
  } finally {
    writeFileSync(`${OUT}/log.txt`, log.join('\n') + '\nERRORS ' + JSON.stringify(errors, null, 1));
    console.log('errors:', errors.length, errors.slice(0, 5));
    await browser.close();
  }
})();
