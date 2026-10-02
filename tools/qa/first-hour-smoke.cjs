// First-hour smoke: replays the opening of a brand-new character and asserts the guidance never piles up.
//   npm run dev -- --host 127.0.0.1 --port 5343 --strictPort
//   DM_PLAYWRIGHT_MODULE=/path/to/playwright DM_QA_ARTIFACT_DIR=/tmp/fh-smoke node tools/qa/first-hour-smoke.cjs
// Checks, at 1280x800 and then 1920x1080 (HUD layout only):
//   - never more than one Covenant counsel card on screen, and the first card waits for the area banner;
//   - no two of {counsel card, conversation card, toast, banner, boss/target frame, Next box, interaction prompt, panels} overlap,
//     and the permanent HUD pieces (upgrades, orbs, XP bar, chat, hint line) do not sit on each other;
//   - calm cards wait for a fight to end, a fight-time card (Walk among the dead) appears once the dead are close, nothing stale
//     (an Acre card in the Graves) is left up;
//   - the Sexton and the hero both stay on screen and clear of the conversation card;
//   - no page errors.
// Game time and UI timers advance together (see lib/first-hour-lib.cjs); fights use a modest bot.
const assert = require('node:assert/strict');
const { mkdirSync, writeFileSync } = require('node:fs');
const { launch, newCharacter, step, overlaps } = require('./lib/first-hour-lib.cjs');

const OUT = process.env.DM_QA_ARTIFACT_DIR || '/tmp/death-muffin-first-hour-smoke';
// Overlays a player reads: none of these may sit on another. (Permanent HUD pieces are checked separately.)
const OVERLAYS = new Set(['tip', 'dialogue', 'toast', 'banner', 'target', 'boss', 'next', 'prompt', 'panel']);
const PERMANENT = new Set(['upgrades', 'altar', 'xpbar', 'currency', 'hint', 'minimap', 'area', 'prog', 'menu']);

async function main() {
  mkdirSync(OUT, { recursive: true });
  const result = {};
  const { browser, page, errors } = await launch({ width: 1280, height: 800 });
  try {
    await newCharacter(page, 'Ossuary');
    const ev = (fn, a) => page.evaluate(fn, a);
    let maxCards = 0;
    const clashes = new Map();
    const cardLog = [];
    let lastSeen = '';
    let prevClash = new Set();
    const check = async (info, label) => {
      const nowClash = new Set();
      const cards = info.rects.filter((r) => r.name === 'tip');
      maxCards = Math.max(maxCards, cards.length);
      const names = cards.map((c) => c.label).join('|');
      if (names !== lastSeen) { lastSeen = names; if (names) cardLog.push(`${Math.round(info.gt)}s ${names}`); }
      for (const o of overlaps(info.rects, ['party+minimap'])) {
        const a = o.a.split(':')[0], b = o.b.split(':')[0];
        // A fight-time card (Hurt?, an enemy telegraph) stays up over the area banner on purpose; everything else steps aside.
        const fightCard = (r) => r.name === 'tip' && (r.kind === 'danger' || r.kind === 'urgent');
        if ((a === 'banner' && fightCard(o.rb)) || (b === 'banner' && fightCard(o.ra))) continue;
        const bothOverlays = OVERLAYS.has(a) && OVERLAYS.has(b);
        const bothPermanent = PERMANENT.has(a) && PERMANENT.has(b);
        if (bothOverlays || bothPermanent) {
          const key = `${o.a} x ${o.b}`;
          nowClash.add(key);
          // CSS transitions (a card fading for a banner, toasts stepping down) run on the page's real clock, not the stepped one: only
          // an overlap seen in two samples in a row counts.
          if (prevClash.has(key) && !clashes.has(key)) clashes.set(key, `${label} @${Math.round(info.gt)}s ${o.ox}x${o.oy}`);
        }
      }
      prevClash = nowClash;
    };
    const run = (s, label = 'run') => step(page, s, (info) => check(info, label));
    const shot = async (name) => { await ev(() => window.__cwDebug.advance(0)); await page.screenshot({ path: `${OUT}/${name}.png` }); };
    const closeAll = async () => {
      for (let i = 0; i < 4; i++) {
        if (!(await ev(() => !!document.querySelector('.cw-dialogue, .cw-panel-float')))) return;
        await page.keyboard.press('Escape'); await run(0.6, 'close');
      }
    };

    // 1. The opening: one card, after the banner, saying "take your time"; the Next line says east then north.
    await run(1, 'open');
    const nextAtStart = await ev(() => document.querySelector('[data-nexttxt]')?.textContent);
    assert.match(nextAtStart, /east to the Chapterhouse, then north/, 'from the Acre the Next line goes via the Chapterhouse');
    assert.equal(await ev(() => document.querySelectorAll('.cw-tip').length), 0, 'no card while the area banner is up');
    await run(12, 'open');
    const first = await ev(() => document.querySelector('.cw-tip .title')?.textContent);
    assert.equal(first, 'Take your time', 'the first card is the welcome');
    await shot('01-welcome-card');
    result.first = first;

    // 2. The Sexton: the conversation card never hides him or the hero.
    // Stand south of him, so he is up-screen of the hero: the case the conversation card used to hide.
    await page.evaluate(() => { window.__cwDebug.player.teleport(-26, 26); });
    await run(1.5, 'sexton');
    await page.keyboard.press('e');
    await run(3, 'sexton');
    const talk = await ev(() => {
      const d = window.__cwDebug;
      const card = document.querySelector('.cw-dialogue').getBoundingClientRect();
      const [sx, sy] = d.guidance.screenOf('sexton');
      return { card: { top: card.top, bottom: card.bottom, left: card.left, right: card.right }, sexton: { x: sx, y: sy }, vw: innerWidth, vh: innerHeight, open: d.guidance.dialogue() };
    });
    assert.deepEqual(talk.open, { open: true, npc: 'sexton' });
    assert.ok(talk.sexton.x > 0 && talk.sexton.x < talk.vw && talk.sexton.y > talk.card.bottom && talk.sexton.y < talk.vh - 150, `the Sexton is on screen below the card: ${JSON.stringify(talk)}`);
    await shot('02-sexton-talking');
    result.sextonTalk = talk;
    await closeAll();

    // 3. Into the Graves: the fight-time lesson shows once, calm cards stay out of the fight, nothing stale remains.
    await page.evaluate(() => { const d = window.__cwDebug; d.goto('chapterhouse'); d.player.teleport(-1.2, 17.5); });
    await run(4, 'hall');
    await page.evaluate(() => { window.__cwDebug.goto('graves'); });
    await run(4, 'graves');
    let sawMove = false, cardInFight = 0;
    for (let t = 0; t < 70; t++) {
      await ev((k) => { const d = window.__cwDebug; if (d.player.hp < d.player.stats.maxHp / 3) d.player.hp = d.player.stats.maxHp; d.aimAtNearest(); d.attackNearest(); if (k % 2 === 0) d.cast(1 + ((k / 2) % 4)); }, t);
      await run(1, 'fight');
      const title = await ev(() => document.querySelector('.cw-tip:not(.out) .title')?.textContent ?? '');
      if (title === 'Walk among the dead') sawMove = true;
      if (title) cardInFight++;
      const stale = await ev(() => { const t = document.querySelector('.cw-tip:not(.out) .title')?.textContent ?? ''; const area = window.__cwDebug.player.area; return /Acre|Take your time/.test(t) && area !== 'acre' && area !== 'chapterhouse' ? t : ''; });
      assert.equal(stale, '', 'no Acre card is left up in the Graves');
    }
    assert.ok(sawMove, 'Walk among the dead appears once the dead are close');
    await shot('03-graves-fight');
    result.cardLog = cardLog.slice(0, 20);

    // 4. A calm card (Wave Speed: gold to spare) is held back during the fight and arrives after it.
    await ev(() => { const d = window.__cwDebug; d.gold(5000); });
    await run(3, 'fight');
    const heldDuringFight = await ev(() => !![...document.querySelectorAll('.cw-tip:not(.out) .title')].find((n) => /Wave Speed/.test(n.textContent)));
    await ev(() => { window.__cwDebug.clear(); window.__cwDebug.goto('chapterhouse'); });
    await run(30, 'after');
    result.waveAfterFight = await ev(() => !!document.querySelector('.cw-tip:not(.out)'));

    assert.ok(maxCards <= 1, `never more than one counsel card at once (saw ${maxCards})`);
    assert.deepEqual([...clashes], [], 'no overlays or permanent HUD pieces overlap at 1280x800');
    result.heldDuringFight = !heldDuringFight;

    // 5. 1920x1080: the permanent HUD and the first card.
    await page.setViewportSize({ width: 1920, height: 1080 });
    await ev(() => { const d = window.__cwDebug; d.goto('acre'); d.player.teleport(-22.5, 21); });
    await run(8, 'wide');
    await shot('04-1920');
    assert.ok(maxCards <= 1);
    assert.deepEqual([...clashes], [], 'no overlays or permanent HUD pieces overlap at 1920x1080');
    assert.deepEqual(errors, [], 'no page errors');
    result.maxCards = maxCards;
    result.errors = errors.length;
  } finally {
    await browser.close();
  }
  writeFileSync(`${OUT}/result.json`, JSON.stringify(result, null, 2));
  console.log(JSON.stringify(result, null, 2));
}

main().catch((e) => { console.error(e); process.exit(1); });
