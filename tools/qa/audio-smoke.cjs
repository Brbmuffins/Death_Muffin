// Combat audio check (offline preview, Chromium, real WebAudio):
//   npm run dev -- --host 127.0.0.1 --port 5324 --strictPort
//   DM_QA_URL=http://127.0.0.1:5324/?offline node tools/qa/audio-smoke.cjs
// Verifies sample buffers load, the per-bus voice caps / thrall thinning / hurt ducking hold
// during a busy necromancer fight, the Settings sliders persist, the post-limiter peak stays
// below clipping, and nothing throws. Uses the DEV-only window.__cwAudio.stats() getter.
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || '/home/ubuntu/.npm/_npx/e41f203b7505f1fb/node_modules/playwright');

const CAP = { combat: 14, enemies: 9, thralls: 5, ui: 8, ambience: 10 };
const RESERVE = 3;

async function main() {
  const browser = await chromium.launch({
    headless: true,
    executablePath: process.env.DM_CHROMIUM_PATH || '/home/ubuntu/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome',
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--autoplay-policy=no-user-gesture-required'],
  });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (e) => errors.push(e.message));
    const badResponses = new Set();
    page.on('response', (r) => { if (r.status() >= 400) badResponses.add(`${r.status()} ${r.url()}`); });
    page.on('console', (m) => { if (m.type() === 'error' && !/favicon|Failed to load resource/.test(m.text())) errors.push('console: ' + m.text()); });
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false, autoCombat: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5324/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', `aud_${Date.now() % 100000}`);
    await page.fill('#cw-email', 'aud@example.invalid');
    await page.fill('#cw-pass', 'TestingAudioPass1');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').filter({ hasText: 'Ossuary' }).first().click();
    await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });

    // One click unlocks the AudioContext (browsers require a gesture).
    await page.mouse.click(640, 400);
    await page.waitForFunction(() => window.__cwAudio?.stats().state === 'running', null, { timeout: 15000 });
    await page.waitForFunction(() => window.__cwAudio.stats().samplesLoaded > 0 && window.__cwAudio.stats().samplesLoaded + window.__cwAudio.stats().samplesFailed >= window.__cwAudio.stats().samplesExpected, null, { timeout: 30000 });
    const loaded = await page.evaluate(() => window.__cwAudio.stats());
    assert.equal(loaded.samplesLoaded, loaded.samplesExpected, `sample buffers loaded: ${loaded.samplesLoaded}/${loaded.samplesExpected}`);
    assert.equal(loaded.samplesFailed, 0, 'no sample failed to load');

    // --- the recorded zone beds replace the synthesised ones once loaded -----------
    await page.evaluate(() => { window.__cwDebug.goto('graves'); window.__cwDebug.advance(1); });
    await page.waitForFunction(() => window.__cwAudio.stats().bedKind === 'loops', null, { timeout: 15000 });

    // --- every new sound plays (gathering, processing, rites, interface, details) ----
    const NEW_SOUNDS = ['chop', 'pick', 'shovel', 'splash', 'reel', 'sawpit', 'kiln', 'cook', 'grind', 'craft', 'vaultOpen', 'vaultClose',
      'frost', 'siphon', 'prison', 'hands', 'storm', 'soulRelease', 'sigWall', 'sigRend', 'sigDirge', 'sigBloom',
      'flail', 'chain', 'palm', 'pyre', 'ward', 'choir', 'bloodRite', 'spiritBolt', 'crow',
      'panelOpen', 'panelClose', 'equip', 'lootRare', 'lootEpic', 'levelUp',
      'distantBell', 'waterDrip', 'emberCrackle', 'bogBubble', 'crowCaw', 'windGust', 'crowdMoan', 'dustFall'];
    const newPlay = await page.evaluate(async (names) => {
      const a = window.__cwAudio;
      a.resetStats();
      for (const n of names) { a.play(n); await new Promise((r) => setTimeout(r, 140)); }
      const st = a.stats();
      return { played: st.played, samplePlays: st.samplePlays, dropped: st.droppedByReason, total: names.length, peakOut: st.peakOut };
    }, NEW_SOUNDS);
    assert.ok(newPlay.played >= NEW_SOUNDS.length - 2, `new sounds played ${newPlay.played}/${newPlay.total}`);
    assert.ok(newPlay.samplePlays >= NEW_SOUNDS.length - 2, `new sounds used their samples ${newPlay.samplePlays}/${newPlay.total}`);
    assert.ok(newPlay.peakOut < 0.7, `one-at-a-time sounds peak ${newPlay.peakOut}`);

    // --- Settings sliders ------------------------------------------------------
    await page.keyboard.press('Escape');
    for (const sel of ['[data-vol]', '[data-vol-combat]', '[data-vol-amb]', '[data-vol-ui]']) assert.equal(await page.locator(sel).count(), 1, `${sel} slider present`);
    await page.locator('[data-vol-combat]').evaluate((el) => { el.value = '0.4'; el.dispatchEvent(new Event('input', { bubbles: true })); });
    await page.locator('[data-vol-ui]').evaluate((el) => { el.value = '0.25'; el.dispatchEvent(new Event('input', { bubbles: true })); });
    const stored = await page.evaluate(() => JSON.parse(localStorage.getItem('dm_settings_v1')));
    assert.equal(stored.combatVolume, 0.4);
    assert.equal(stored.interfaceVolume, 0.25);
    await page.locator('[data-vol-combat]').evaluate((el) => { el.value = '1'; el.dispatchEvent(new Event('input', { bubbles: true })); });
    await page.locator('[data-vol-ui]').evaluate((el) => { el.value = '1'; el.dispatchEvent(new Event('input', { bubbles: true })); });
    await page.keyboard.press('Escape');

    // --- hurt ducks, thrall hits are thinned (synthetic burst at one instant) ----
    await page.evaluate(() => { window.__cwDebug.god(); window.__cwDebug.goto('graves'); window.__cwDebug.advance(1); });
    const burst = await page.evaluate(() => {
      const a = window.__cwAudio;
      a.resetStats();
      const p = window.__cwDebug.player;
      for (let i = 0; i < 40; i++) a.play('thrallMelee', p.x + 2, p.z + 1);
      const afterThralls = a.stats();
      for (let i = 0; i < 40; i++) a.play('enemyDeath', p.x + 3, p.z);
      a.play('hurt');
      return { afterThralls, after: a.stats() };
    });
    assert.ok(burst.afterThralls.played <= 3, `thrall hits thinned to <=3 per 100ms, played ${burst.afterThralls.played}`);
    assert.ok(burst.afterThralls.droppedByReason.thin >= 30, 'thinning counted');
    assert.ok(burst.after.peakVoices.enemies <= CAP.enemies, `enemy bus cap held: ${burst.after.peakVoices.enemies}`);
    assert.ok(burst.after.ducks >= 1, 'player hurt ducked thralls/enemies');

    // --- busy fight: 40 enemies, thralls, every necromancer rite -----------------
    await page.evaluate(() => {
      const d = window.__cwDebug;
      d.clear();
      window.__cwAudio.resetStats();
      d.ring('robber', 24, 5);
      d.ring('hound', 16, 7);
      d.ring('robber', 4, 3.5, true);
    });
    const samples = [];
    let minBedDuck = 1;
    for (let i = 0; i < 60; i++) {
      await page.evaluate((i) => {
        const d = window.__cwDebug;
        d.aimAtNearest();
        d.cast(1 + (i % 5));
        if (i % 4 === 0) d.cast(0);
        d.advance(0.4);
      }, i);
      if (i === 30) await page.evaluate(() => window.__cwDebug.boss('prelate'));
      samples.push(await page.evaluate(() => window.__cwAudio.stats()));
      minBedDuck = Math.min(minBedDuck, samples[samples.length - 1].bedDuck);
      await page.waitForTimeout(80);
    }
    const end = samples[samples.length - 1];
    assert.ok(minBedDuck < 0.8, `ambience bed ducks under combat: min gain ${minBedDuck.toFixed(2)}`);
    assert.ok(end.peakOut < 0.7, `busy fight post-limiter peak ${end.peakOut.toFixed(3)} must stay under 0.7`);
    const peakVoices = end.peakVoices;
    for (const [bus, cap] of Object.entries(CAP)) assert.ok(peakVoices[bus] <= cap + RESERVE, `${bus} peak ${peakVoices[bus]} exceeds cap ${cap + RESERVE}`);
    assert.ok(peakVoices.thralls <= CAP.thralls, 'thrall bus never above its cap');
    assert.ok(end.played > 40, `sounds played during fight: ${end.played}`);
    assert.ok(end.samplePlays > 20, `sample layer used: ${end.samplePlays}`);
    const counts = await page.evaluate(() => window.__cwDebug.counts());

    // --- ambient-only mix per zone: bed plus one of each sparse detail, no fighting -----
    await page.evaluate(() => { window.__cwDebug.clear(); window.__cwDebug.god(); window.__cwDebug.unlockAll(); });
    // The fight's activity decays (half-life 2.5 s) and the bed comes back up.
    await page.waitForFunction(() => window.__cwAudio.stats().bedDuck > 0.9, null, { timeout: 30000 });
    const afterFight = await page.evaluate(() => window.__cwAudio.stats());
    const ambient = {};
    for (const area of ['chapterhouse', 'acre', 'graves', 'ossuary', 'nave', 'sanctum', 'cloister', 'pyre', 'warren', 'coliseum', 'fen']) {
      for (let tries = 0; tries < 6; tries++) {
        await page.evaluate((a) => { window.__cwDebug.unlockAll(); window.__cwDebug.goto(a); window.__cwDebug.advance(1.5); window.__cwDebug.clear(); window.__cwDebug.advance(0.5); }, area);
        if (await page.evaluate(() => window.__cwAudio.stats().area) === area) break;
        await page.waitForTimeout(500);
      }
      await page.waitForTimeout(3500); // crossfade settles
      const bedOnly = await page.evaluate(async () => {
        const a = window.__cwAudio;
        a.resetStats();
        await new Promise((r) => setTimeout(r, 2000));
        const st = a.stats();
        return { bedPeak: +st.busPeak.ambience.toFixed(3), bedRms: +st.busRms.ambience.toFixed(4), bedPostPeak: +st.peakOut.toFixed(3) };
      });
      ambient[area] = await page.evaluate(async () => {
        const a = window.__cwAudio;
        a.resetStats();
        const p = window.__cwDebug.player;
        for (const n of ['distantBell', 'crowCaw', 'waterDrip', 'emberCrackle', 'bogBubble', 'windGust', 'crowdMoan', 'dustFall', 'graveCreak']) {
          a.play(n, p.x + 8, p.z + 5);
          await new Promise((r) => setTimeout(r, 450));
        }
        await new Promise((r) => setTimeout(r, 1200));
        const st = a.stats();
        return { area: st.area, bed: st.bedKind, ambiencePeak: +st.busPeak.ambience.toFixed(3), ambienceRms: +st.busRms.ambience.toFixed(4), prePeak: +st.peakPre.toFixed(3), postPeak: +st.peakOut.toFixed(3) };
      });
      Object.assign(ambient[area], bedOnly);
      assert.equal(ambient[area].area, area);
      assert.equal(ambient[area].bed, 'loops', `${area} plays the recorded bed`);
      assert.ok(ambient[area].postPeak < 0.7, `${area} ambient peak ${ambient[area].postPeak}`);
    }
    const worstAmbient = Object.entries(ambient).reduce((m, [k, v]) => (v.postPeak > m.v ? { k, v: v.postPeak } : m), { k: '', v: 0 });
    assert.deepEqual(errors, []);
    // Failed requests must not be audio files (other 4xx, e.g. optional art, are reported but not fatal).
    assert.deepEqual([...badResponses].filter((u) => /\.(ogg|mp3|wav)\b/.test(u)), [], 'audio files all served');
    console.log(JSON.stringify({
      samplesLoaded: loaded.samplesLoaded, peakVoices, played: end.played, samplePlays: end.samplePlays, dropped: end.dropped,
      droppedByReason: end.droppedByReason, droppedByBus: end.droppedByBus, ducks: end.ducks, peakPreLimiter: +end.peakPre.toFixed(3), peakPostLimiter: +end.peakOut.toFixed(3),
      mixReport: {
        busyFight: { busPeak: Object.fromEntries(Object.entries(end.busPeak).map(([k, v]) => [k, +v.toFixed(3)])), busRms: Object.fromEntries(Object.entries(end.busRms).map(([k, v]) => [k, +v.toFixed(4)])), minBedDuck: +minBedDuck.toFixed(2) },
        ambientOnly: ambient, worstAmbient,
        newSounds: newPlay,
      },
      sceneCounts: counts, thrallThinning: { played: burst.afterThralls.played, thinned: burst.afterThralls.droppedByReason.thin }, errors, otherFailedRequests: [...badResponses].slice(0, 5),
    }, null, 1));
  } finally {
    await browser.close();
  }
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
