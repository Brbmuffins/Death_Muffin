// Browser check for streamed music, area/boss transitions, and new environmental loops.
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));
    page.on('response', (response) => {
      if ((/\/audio\/music\//.test(response.url()) || /\/audio\/ambience\/bed_(rain|flame)\.ogg/.test(response.url())) && response.status() >= 400) {
        errors.push(`${response.status()} ${response.url()}`);
      }
    });
    await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'low', tips: false })));
    await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5365/?offline');
    await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
    await page.fill('#cw-user', 'music_review');
    await page.fill('#cw-email', 'music_review@example.invalid');
    await page.fill('#cw-pass', 'TestingMusic');
    await page.locator('#cw-login-btn').click();
    await page.locator('.cw-disc').first().click();

    const waitCue = async (cue) => page.waitForFunction((id) => {
      const a = window.__cwAudio;
      return a?.stats().musicCue === id && a.music.current?.element && !a.music.current.element.paused;
    }, cue, { timeout: 30000 });
    try {
      await page.waitForFunction(() => {
        const a = window.__cwAudio;
        return a?.music.current?.element && !a.music.current.element.paused;
      }, null, { timeout: 30000 });
    } catch (error) {
      console.error('Music state:', await page.evaluate(() => window.__cwAudio?.stats()));
      console.error('Browser errors:', errors);
      throw error;
    }
    const firstCue = await page.evaluate(() => window.__cwAudio.stats().musicCue);
    assert.ok(firstCue === 'chapterhouse' || firstCue === 'graves', `Starting-area cue: ${firstCue}`);
    const start = await page.evaluate(() => window.__cwAudio.music.current.element.currentTime);
    await page.waitForTimeout(1200);
    const after = await page.evaluate(() => window.__cwAudio.music.current.element.currentTime);
    assert.ok(after > start + 0.5, `Music media advances: ${start} -> ${after}`);

    await page.locator('[data-open="settings"]').click();
    const slider = page.locator('[data-vol-music]');
    await slider.focus();
    await page.keyboard.press('Home');
    await page.waitForFunction(() => window.__cwAudio.stats().musicCue === null);
    await page.keyboard.press('End');
    try { await waitCue(firstCue); } catch (error) {
      console.error('Music after slider:', await page.evaluate(() => window.__cwAudio.stats().musicStatus));
      throw error;
    }
    await page.keyboard.press('Escape');

    await page.evaluate(() => window.__cwAudio.setArea('fen'));
    await waitCue('graves');
    await page.waitForFunction(() => window.__cwAudio.samples.has('bed_rain'), null, { timeout: 15000 });
    await page.evaluate(() => window.__cwAudio.setArea('pyre'));
    await waitCue('pyre');
    await page.waitForFunction(() => window.__cwAudio.samples.has('bed_flame'), null, { timeout: 15000 });
    await page.evaluate(() => {
      const d = window.__cwDebug;
      d.unlockAll();
      d.god(true);
      d.boss('prelate');
      d.advance(0.5);
    });
    try { await waitCue('boss'); } catch (error) {
      console.error('Boss music state:', await page.evaluate(() => ({ audio: window.__cwAudio.stats(), boss: window.__cwDebug.bossState?.() })));
      console.error('Browser errors:', errors);
      throw error;
    }
    await page.evaluate(() => window.__cwAudio.stopArea());
    await page.waitForFunction(() => window.__cwAudio.stats().musicCue === null);
    assert.deepEqual(errors, [], 'No audio network or runtime errors');
    console.log('Music playback, area/boss transitions, and rain/flame beds: passed');
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
