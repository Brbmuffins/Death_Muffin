/**
 * Necro animation smoke (N2): for each necromancer discipline, play every new combat clip through the real
 * avatar.cast() path with the weapon that selects it, assert the intended clip actually played (and that a
 * sword falls back to today's cast), and write a 4-frame strip per clip to DM_QA_ARTIFACT_DIR
 * (default docs/screenshots/necro-anim). Also flinches (hurt) and both deaths.
 *
 *   DM_PLAYWRIGHT_MODULE=... DM_QA_URL=http://127.0.0.1:5304/?offline node tools/qa/necro-anim-smoke.cjs
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
const { SWIFTSHADER_ARGS, preloadModules } = require('./lib/qa-common.cjs');

const OUT = process.env.DM_QA_ARTIFACT_DIR || 'docs/screenshots/necro-anim';
const URL = process.env.DM_QA_URL || 'http://127.0.0.1:5304/?offline';
const DISCIPLINES = [['Gravecaller', 'hero_gravecaller'], ['Ossuary', 'hero_ossuary'], ['Mourner', 'hero_mourner'], ['Rotweaver', 'hero_rotweaver']];
// clip -> [weapon item id (null = none), ability, cast kind]
const CASES = {
  slam: [null, 'corpse_explosion', 'cast'],
  sweep: ['scythe_bone', 'bone_needle', 'cast'],
  flick: ['wand_bone', 'bone_needle', 'cast'],
  channel: ['staff_oak', 'black_litany', 'cast'],
  summon: [null, 'exhume', 'dig'],
};
const FRAMES = 4;
const ONLY = process.env.DM_QA_ONLY; // e.g. hero_ossuary
const log = (...a) => console.error(new Date().toISOString().slice(11, 19), ...a);

async function withRetry(fn, tries = 3) {
  let last;
  for (let i = 0; i < tries; i++) {
    try { return await fn(); } catch (e) { last = e; await new Promise(r => setTimeout(r, 1500)); }
  }
  throw last;
}

async function strip(frames, label, file) {
  const W = 360, H = 360;
  const base = sharp({ create: { width: W * frames.length, height: H + 26, channels: 3, background: '#14101c' } });
  const comps = await Promise.all(frames.map(async (f, i) => ({ input: await sharp(f.buf).resize(W, H, { kernel: 'lanczos3' }).toBuffer(), left: i * W, top: 0 })));
  comps.push(...frames.map((f, i) => ({ input: Buffer.from(`<svg width="${W}" height="26" xmlns="http://www.w3.org/2000/svg"><text x="8" y="18" font-size="14" font-family="monospace" fill="#d9cfff">${label} ${f.t.toFixed(2)}s</text></svg>`), left: i * W, top: H })));
  await base.composite(comps).png().toFile(file);
}

async function main() {
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH,
    args: SWIFTSHADER_ARGS });
  const report = [];
  try {
    for (const [disc, slug] of DISCIPLINES) {
      if (ONLY && ONLY !== slug) continue;
      log('start', slug);
      const page = await browser.newPage({ viewport: { width: 720, height: 480 } });
      const errors = [];
      page.on('pageerror', error => errors.push(error.message));
      await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
      await page.goto(URL);
      await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
      await page.fill('#cw-user', `necro_anim_${slug}`);
      await page.fill('#cw-email', `${slug}@example.invalid`);
      await page.fill('#cw-pass', 'TestingAnim');
      await page.locator('#cw-login-btn').click();
      await page.locator('.cw-disc').filter({ hasText: disc }).click();
      await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
      await preloadModules(page, { combatFlow: '/src/content/combatFlow.ts' });
      await page.evaluate(() => { window.__cwDebug.god?.(true); window.__cwDebug.zoom(0.4); window.__cwDebug.advance(0.5); });
      const have = await page.evaluate(() => ['slam', 'sweep', 'flick', 'channel', 'summon', 'hurt', 'death'].filter(n => window.__cwDebug.avatar.c.has(n)));
      assert.deepEqual(have, ['slam', 'sweep', 'flick', 'channel', 'summon', 'hurt', 'death'], `${slug} clips`);

      // Hide the HUD and frame the hero: project its body centre through the game camera.
      await page.addStyleTag({ content: '#ui-root { display: none !important; }' });
      await page.evaluate(() => window.__cwDebug.advance(0.3));
      const at = await page.evaluate(() => {
        const scene = window.__qaMods.runtime.getRuntime().view;
        const v = scene.avatar.c.root.position.clone();
        v.y += 1.0;
        v.project(scene.rig.camera);
        return { x: (v.x * 0.5 + 0.5) * innerWidth, y: (-v.y * 0.5 + 0.5) * innerHeight };
      });
      const clip = { x: Math.max(0, Math.min(720 - 220, Math.round(at.x - 110))), y: Math.max(0, Math.min(480 - 220, Math.round(at.y - 120))), width: 220, height: 220 };
      const shot = () => withRetry(() => page.screenshot({ clip, timeout: 90000 }));

      for (const [clip, [weapon, ability, kind]] of Object.entries(CASES)) {
        const equip = await page.evaluate(({ weapon, ability, kind }) => {
          const scene = window.__qaMods.runtime.getRuntime().view;
          const { CAST_FLOW } = window.__qaMods.combatFlow;
          scene.avatar.setEquipment(weapon ? { main_hand: { item_id: weapon } } : {});
          window.__cwDebug.advance(0.3);
          scene.avatar.cast(kind, 2, scene.avatar.c.root.rotation.y, CAST_FLOW[ability].gestureSeconds, ability);
          const a = scene.avatar.c.oneShot;
          return { played: a.getClip().name, speed: a.timeScale, t0: a.time, dur: a.getClip().duration, gesture: CAST_FLOW[ability].gestureSeconds };
        }, { weapon, ability, kind });
        assert.equal(equip.played, clip, `${slug}: ${weapon ?? 'none'} + ${ability} should play ${clip}`);
        const total = Math.max(0.3, (equip.dur - equip.t0) / equip.speed);
        const frames = [];
        for (let i = 0; i < FRAMES; i++) {
          const t = (total * i) / (FRAMES - 1);
          if (i) await page.evaluate(dt => window.__cwDebug.advance(dt), total / (FRAMES - 1));
          frames.push({ buf: await shot(), t });
        }
        await strip(frames, `${clip}(${weapon ?? 'none'}/${ability})`, path.join(OUT, `${slug}-${clip}.png`));
        log('done', slug, clip);
        report.push({ slug, clip, ...equip, total: +total.toFixed(2) });
        await page.evaluate(() => window.__cwDebug.advance(1.0));
      }

      // A sword (or any kind without an entry) keeps today's gesture.
      const legacy = await page.evaluate(() => {
        const scene = window.__qaMods.runtime.getRuntime().view;
        const { CAST_FLOW } = window.__qaMods.combatFlow;
        scene.avatar.setEquipment({ main_hand: { item_id: 'sword_copper' } });
        scene.avatar.cast('cast', 3, 0, CAST_FLOW.black_litany.gestureSeconds, 'black_litany');
        return scene.avatar.c.oneShot.getClip().name;
      });
      assert.equal(legacy, 'cast', `${slug}: sword falls back to cast`);
      await page.evaluate(() => window.__cwDebug.advance(1.0));

      // Flinch + deaths.
      for (const [label, anim] of [['hurt', 'hurt'], ['death', 'death'], ['death2', 'death2']]) {
        await page.evaluate(() => window.__cwDebug.advance(0.5));
        const dur = await page.evaluate((anim) => {
          const c = window.__cwDebug.avatar.c;
          // The hit-react is an additive overlay (Creature.flinch), not a one-shot: assert the overlay runs.
          if (anim === 'hurt') {
            c.oneShot = null;
            c.actions.forEach(a => a.stop());
            if (!c.playOnce('hurt', 1) || !c.flinchAct || !c.flinchAct.isRunning()) throw new Error('flinch overlay did not start');
            return c.flinchAct.getClip().duration;
          }
          // Variants are picked at random: retry until the wanted one plays.
          for (let i = 0; i < 60; i++) {
            c.oneShot = null;
            c.actions.forEach(a => a.stop());
            c.playOnce(anim.startsWith('death') ? 'death' : anim, 1);
            if (c.oneShot?.getClip().name === anim) return c.oneShot.getClip().duration;
          }
          throw new Error('could not play ' + anim);
        }, anim);
        const span = Math.min(2.4, dur);
        const frames = [];
        for (let i = 0; i < FRAMES; i++) {
          const t = (span * i) / (FRAMES - 1);
          if (i) await page.evaluate(dt => window.__cwDebug.advance(dt), span / (FRAMES - 1));
          frames.push({ buf: await shot(), t });
        }
        await strip(frames, label, path.join(OUT, `${slug}-${label}.png`));
        await page.evaluate(() => { const c = window.__cwDebug.avatar.c; c.oneShot = null; c.setLoop('idle'); c.actions.forEach(a => a.stop()); c.playOnce('dig', 1); window.__cwDebug.advance(2.5); });
      }
      assert.deepEqual(errors, [], `${slug} page errors`);
      await page.close();
    }
    console.log(JSON.stringify(report, null, 1));
  } finally { await browser.close(); }
}

main().catch(error => { console.error(error); process.exitCode = 1; });
