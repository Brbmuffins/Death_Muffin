// Verify cached music supports byte-range requests and playback without a network connection.
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');

async function main() {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined,
    args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  try {
    const context = await browser.newContext({ serviceWorkers: 'allow' });
    const page = await context.newPage();
    const base = process.env.DM_OFFLINE_URL || 'http://127.0.0.1:5366/death-muffin/offline/';
    const music = `${base}audio/music/chapterhouse.mp3`;
    await page.goto(base);
    await page.evaluate(() => navigator.serviceWorker.ready);
    await page.waitForFunction(() => !!navigator.serviceWorker.controller, null, { timeout: 15000 });
    await page.evaluate(async (url) => {
      const cache = await caches.open('dm-music-smoke');
      await cache.add(url);
    }, music);
    await context.setOffline(true);
    const result = await page.evaluate(async (url) => {
      const response = await fetch(url, { headers: { Range: 'bytes=0-1023' } });
      return { status: response.status, length: (await response.arrayBuffer()).byteLength,
        range: response.headers.get('content-range') };
    }, music);
    assert.equal(result.status, 206);
    assert.equal(result.length, 1024);
    assert.match(result.range || '', /^bytes 0-1023\/\d+$/);

    await page.evaluate((url) => {
      const button = document.createElement('button');
      button.id = 'offline-music-play';
      button.textContent = 'Play cached music';
      button.style.cssText = 'position:fixed;top:20px;left:20px;z-index:2147483647';
      button.onclick = () => {
        window.offlineMusic = new Audio(url);
        window.offlineMusic.play().catch((error) => { window.offlineMusicError = error.message; });
      };
      document.body.append(button);
    }, music);
    await page.locator('#offline-music-play').click();
    await page.waitForFunction(() => window.offlineMusic?.currentTime > 0.5 || window.offlineMusicError, null, { timeout: 15000 });
    const playback = await page.evaluate(() => ({ time: window.offlineMusic.currentTime,
      paused: window.offlineMusic.paused, error: window.offlineMusicError }));
    assert.equal(playback.error, undefined, JSON.stringify(playback));
    assert.equal(playback.paused, false, JSON.stringify(playback));
    assert.ok(playback.time > 0.5, JSON.stringify(playback));
    console.log('Offline cached byte range and music playback: passed');
  } finally {
    await browser.close();
  }
}

main().catch((error) => { console.error(error); process.exitCode = 1; });
