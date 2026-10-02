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
    await page.waitForFunction(() => window.__cwAudio.stats().samplesLoaded > 0 && window.__cwAudio.stats().samplesLoaded + window.__cwAudio.stats().samplesFailed >= 48, null, { timeout: 30000 });
    const loaded = await page.evaluate(() => window.__cwAudio.stats());
    assert.ok(loaded.samplesLoaded >= 45, `sample buffers loaded: ${loaded.samplesLoaded}`);
    assert.equal(loaded.samplesFailed, 0, 'no sample failed to load');

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
      await page.waitForTimeout(80);
    }
    const end = samples[samples.length - 1];
    const peakVoices = end.peakVoices;
    for (const [bus, cap] of Object.entries(CAP)) assert.ok(peakVoices[bus] <= cap + RESERVE, `${bus} peak ${peakVoices[bus]} exceeds cap ${cap + RESERVE}`);
    assert.ok(peakVoices.thralls <= CAP.thralls, 'thrall bus never above its cap');
    assert.ok(end.played > 40, `sounds played during fight: ${end.played}`);
    assert.ok(end.samplePlays > 20, `sample layer used: ${end.samplePlays}`);
    assert.ok(end.peakOut < 0.99, `post-limiter peak ${end.peakOut.toFixed(3)} must stay below clipping`);
    const counts = await page.evaluate(() => window.__cwDebug.counts());
    assert.deepEqual(errors, []);
    // Failed requests must not be audio files (other 4xx, e.g. optional art, are reported but not fatal).
    assert.deepEqual([...badResponses].filter((u) => /\.(ogg|mp3|wav)\b/.test(u)), [], 'audio files all served');
    console.log(JSON.stringify({
      samplesLoaded: loaded.samplesLoaded, peakVoices, played: end.played, samplePlays: end.samplePlays, dropped: end.dropped,
      droppedByReason: end.droppedByReason, droppedByBus: end.droppedByBus, ducks: end.ducks, peakPreLimiter: +end.peakPre.toFixed(3), peakPostLimiter: +end.peakOut.toFixed(3),
      sceneCounts: counts, thrallThinning: { played: burst.afterThralls.played, thinned: burst.afterThralls.droppedByReason.thin }, errors, otherFailedRequests: [...badResponses].slice(0, 5),
    }, null, 1));
  } finally {
    await browser.close();
  }
}

main().catch((e) => { console.error(e); process.exitCode = 1; });
