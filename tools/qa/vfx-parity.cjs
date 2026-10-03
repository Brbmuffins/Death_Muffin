/**
 * Do the instanced Effects layers (flash/orbit sprites, beams, round-footprint decals) draw the same pixels as the objects they
 * replaced? Renders the same hand-placed set both ways with the game's fog (src/graphics/fxProbe.ts parity()) and prints the
 * per-channel difference per kind; fails when a kind differs by more than a few 8-bit counts.
 *   DM_QA_URL='http://127.0.0.1:5407/?offline' DM_PLAYWRIGHT_MODULE=... node tools/qa/vfx-parity.cjs
 */
const assert = require('node:assert/strict');
const { chromium } = require(process.env.DM_PLAYWRIGHT_MODULE || 'playwright');
(async () => {
  const browser = await chromium.launch({ headless: true, executablePath: process.env.DM_CHROMIUM_PATH || undefined, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 800, height: 600 } });
  page.setDefaultTimeout(240000);
  await page.addInitScript(() => localStorage.setItem('dm_settings_v1', JSON.stringify({ quality: 'high', tips: false, autoCombat: false })));
  await page.goto(process.env.DM_QA_URL || 'http://127.0.0.1:5407/?offline');
  await page.getByRole('button', { name: 'New to the Covenant? Create an account' }).click();
  await page.fill('#cw-user', `par_${Date.now() % 100000}`);
  const email = page.locator('#cw-email');
  if (await email.isVisible().catch(() => false)) await email.fill('par@example.invalid');
  await page.fill('#cw-pass', 'TestingParity1');
  await page.locator('#cw-login-btn').click();
  await page.locator('.cw-disc').filter({ hasText: 'Gravecaller' }).click();
  await page.waitForFunction(() => window.__cwDebug?.avatar.c.loaded, null, { timeout: 90000 });
  const res = await page.evaluate(async () => {
    const rt = (await import('/src/app/GameRuntime.ts')).getRuntime();
    const P = await import('/src/graphics/fxProbe.ts');
    return P.parity(rt.renderer);
  });
  if (process.env.DM_QA_OUT) {
    // Debugging aid: the old/new renders of each decal kind as PNGs (left old, right new).
    const bufs = await page.evaluate(() => Object.fromEntries(Object.entries(globalThis.__parityBufs || {}).map(([k, v]) => [k, v])));
    const sharp = require('sharp');
    for (const [k, [a, b]] of Object.entries(bufs)) {
      const raw = Buffer.alloc(512 * 384 * 4 * 2);
      for (let y = 0; y < 384; y++) for (let x = 0; x < 512; x++) for (let c = 0; c < 4; c++) { raw[(y * 1024 + x) * 4 + c] = a[((383 - y) * 512 + x) * 4 + c]; raw[(y * 1024 + 512 + x) * 4 + c] = b[((383 - y) * 512 + x) * 4 + c]; }
      await sharp(raw, { raw: { width: 1024, height: 384, channels: 4 } }).png().toFile(require('node:path').join(process.env.DM_QA_OUT, `parity-${k.replace(' ', '-')}.png`));
    }
  }
  let bad = 0;
  for (const [k, v] of Object.entries(res)) {
    console.log(k.padEnd(14), JSON.stringify(v));
    if (v.litPixels < 200) { console.log('  too little drawn to judge'); bad++; }
    // Sub-texel interpolation differences on thin line art (the sigil) show up as a few counts on a few pixels; anything bigger is a real change.
    if (v.maxAbs > 30 || v.meanAbs > 0.2) { console.log('  DIFFERS'); bad++; }
  }
  await browser.close();
  assert.equal(bad, 0, 'instanced layers must draw what the pooled objects drew');
  console.log('ok');
})().catch((e) => { console.error(e); process.exit(1); });
